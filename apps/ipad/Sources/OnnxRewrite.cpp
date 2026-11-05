#include "VisionNative.h"
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <string>
#include <string_view>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>

// ONNX Runtime 1.24's Core ML EP rejects several LaMa ops, which splits the
// model into dozens of partitions and pushes memory past the app's limit.
// Each is replaced with an exact equivalent: Einsum ij,jk->ik → MatMul,
// Neg → Mul −1, scalar Gather → Slice + Squeeze, reflect Pad → Slice + Concat,
// ConvTranspose pads/output_padding → zero pads + Slice. Only the protobuf
// fields these edits need are decoded; the weights are copied byte for byte.
namespace {
struct Field { uint32_t number = 0, wire = 0; uint64_t value = 0; std::string_view bytes, raw; };

bool readVarint(std::string_view &in, uint64_t &out) {
    out = 0;
    for (int shift = 0; shift < 64 && !in.empty(); shift += 7) {
        uint8_t byte = uint8_t(in[0]);
        in.remove_prefix(1);
        out |= uint64_t(byte & 0x7f) << shift;
        if (!(byte & 0x80)) return true;
    }
    return false;
}
bool readFields(std::string_view in, std::vector<Field> &out) {
    while (!in.empty()) {
        const char *start = in.data();
        Field field;
        uint64_t key, size;
        if (!readVarint(in, key)) return false;
        field.number = uint32_t(key >> 3);
        field.wire = uint32_t(key & 7);
        switch (field.wire) {
        case 0: if (!readVarint(in, field.value)) return false; break;
        case 1: case 5:
            size = field.wire == 1 ? 8 : 4;
            if (in.size() < size) return false;
            field.bytes = in.substr(0, size); in.remove_prefix(size); break;
        case 2:
            if (!readVarint(in, size) || size > in.size()) return false;
            field.bytes = in.substr(0, size); in.remove_prefix(size); break;
        default: return false;
        }
        field.raw = std::string_view(start, size_t(in.data() - start));
        out.push_back(field);
    }
    return true;
}
void putVarint(std::string &out, uint64_t value) {
    while (value >= 0x80) { out += char(value | 0x80); value >>= 7; }
    out += char(value);
}
void putInt(std::string &out, uint32_t number, int64_t value) { putVarint(out, uint64_t(number) << 3); putVarint(out, uint64_t(value)); }
void putBytes(std::string &out, uint32_t number, std::string_view bytes) {
    putVarint(out, uint64_t(number) << 3 | 2);
    putVarint(out, bytes.size());
    out.append(bytes);
}
std::vector<int64_t> repeatedInts(const Field &field) {
    std::vector<int64_t> values;
    uint64_t value;
    if (field.wire == 0) values.push_back(int64_t(field.value));
    else if (field.wire == 2) for (std::string_view in = field.bytes; !in.empty() && readVarint(in, value);) values.push_back(int64_t(value));
    return values;
}

struct Attribute { std::string name, s, raw; int64_t i = 0; std::vector<int64_t> ints; };
Attribute parseAttribute(std::string_view bytes) {
    Attribute attribute;
    attribute.raw = bytes;
    std::vector<Field> fields;
    readFields(bytes, fields);
    for (const Field &field : fields) {
        if (field.number == 1) attribute.name = field.bytes;
        else if (field.number == 3) attribute.i = int64_t(field.value);
        else if (field.number == 4) attribute.s = field.bytes;
        else if (field.number == 8) for (int64_t value : repeatedInts(field)) attribute.ints.push_back(value);
    }
    return attribute;
}
Attribute intAttribute(std::string_view name, int64_t value) {
    Attribute attribute;
    putBytes(attribute.raw, 1, name); putInt(attribute.raw, 3, value); putInt(attribute.raw, 20, 2);
    return attribute;
}
Attribute intsAttribute(std::string_view name, const std::vector<int64_t> &values) {
    Attribute attribute;
    putBytes(attribute.raw, 1, name);
    for (int64_t value : values) putInt(attribute.raw, 8, value);
    putInt(attribute.raw, 20, 7);
    return attribute;
}

struct Node { std::vector<std::string> inputs, outputs; std::string name, op, extra; std::vector<Attribute> attributes; };
Node parseNode(std::string_view bytes) {
    Node node;
    std::vector<Field> fields;
    readFields(bytes, fields);
    for (const Field &field : fields) {
        if (field.number == 1) node.inputs.emplace_back(field.bytes);
        else if (field.number == 2) node.outputs.emplace_back(field.bytes);
        else if (field.number == 3) node.name = field.bytes;
        else if (field.number == 4) node.op = field.bytes;
        else if (field.number == 5) node.attributes.push_back(parseAttribute(field.bytes));
        else node.extra.append(field.raw);
    }
    return node;
}
std::string serialize(const Node &node) {
    std::string out;
    for (const auto &input : node.inputs) putBytes(out, 1, input);
    for (const auto &output : node.outputs) putBytes(out, 2, output);
    putBytes(out, 3, node.name);
    putBytes(out, 4, node.op);
    for (const auto &attribute : node.attributes) putBytes(out, 5, attribute.raw);
    out += node.extra;
    return out;
}
const Attribute *find(const Node &node, std::string_view name) {
    for (const auto &attribute : node.attributes) if (attribute.name == name) return &attribute;
    return nullptr;
}

struct Constant { std::vector<int64_t> dims, values; };

struct Rewriter {
    std::unordered_map<std::string, Constant> constants; // small int64 initializers
    std::vector<std::string> initializers, nodes;
    int counter = 0;

    std::string fresh(std::string_view tag) { return "koharu_rw_" + std::to_string(counter++) + "_" + std::string(tag); }
    std::string tensor(int32_t type, const std::vector<int64_t> &dims, const void *data, size_t size) {
        std::string name = fresh("const"), out;
        for (int64_t dim : dims) putInt(out, 1, dim);
        putInt(out, 2, type);
        putBytes(out, 8, name);
        putBytes(out, 9, std::string_view(static_cast<const char *>(data), size));
        initializers.push_back(std::move(out));
        return name;
    }
    std::string ints(const std::vector<int64_t> &values) { return tensor(7, {int64_t(values.size())}, values.data(), values.size() * 8); }
    std::string scalar(float value) { return tensor(1, {}, &value, 4); }
    void emit(std::string op, std::vector<std::string> inputs, std::vector<std::string> outputs, std::vector<Attribute> attributes = {}) {
        Node node;
        node.name = fresh(op);
        node.op = std::move(op);
        node.inputs = std::move(inputs);
        node.outputs = std::move(outputs);
        node.attributes = std::move(attributes);
        nodes.push_back(serialize(node));
    }
    std::string slice(const std::string &input, std::vector<int64_t> starts, std::vector<int64_t> ends, std::vector<int64_t> axes, std::string output = {}) {
        if (output.empty()) output = fresh("slice");
        emit("Slice", {input, ints(starts), ints(ends), ints(axes)}, {output});
        return output;
    }
    const Constant *constant(const Node &node, size_t index) {
        if (index >= node.inputs.size()) return nullptr;
        auto found = constants.find(node.inputs[index]);
        return found == constants.end() ? nullptr : &found->second;
    }

    bool rewrite(Node &node) {
        if (node.op == "Einsum") {
            const Attribute *equation = find(node, "equation");
            if (!equation || equation->s != "ij,jk->ik" || node.inputs.size() != 2) return false;
            node.op = "MatMul";
            node.attributes.clear();
            nodes.push_back(serialize(node));
            return true;
        }
        if (node.op == "Neg" && node.inputs.size() == 1) {
            emit("Mul", {node.inputs[0], scalar(-1)}, node.outputs);
            return true;
        }
        if (node.op == "Gather") {
            const Constant *index = constant(node, 1);
            const Attribute *axisAttribute = find(node, "axis");
            int64_t axis = axisAttribute ? axisAttribute->i : 0;
            if (!index || !index->dims.empty() || index->values.size() != 1 || index->values[0] < 0 || axis < 0) return false;
            int64_t k = index->values[0];
            std::string part = slice(node.inputs[0], {k}, {k + 1}, {axis});
            emit("Squeeze", {part, ints({axis})}, node.outputs);
            return true;
        }
        if (node.op == "Pad") {
            const Attribute *mode = find(node, "mode");
            const Constant *pads = constant(node, 1);
            if (!mode || mode->s != "reflect" || !pads || pads->values.size() != 8 || node.inputs.size() > 3) return false;
            const auto &p = pads->values;
            if (p[0] || p[1] || p[4] || p[5]) return false;
            for (int64_t value : p) if (value < 0) return false;
            std::string current = node.inputs[0];
            for (int64_t axis : {2, 3}) {
                int64_t before = p[size_t(axis)], after = p[size_t(axis) + 4];
                if (!before && !after) continue;
                std::vector<std::string> parts;
                for (int64_t i = before; i >= 1; --i) parts.push_back(slice(current, {i}, {i + 1}, {axis}));
                parts.push_back(current);
                for (int64_t i = 1; i <= after; ++i) parts.push_back(slice(current, {-1 - i}, {-i}, {axis}));
                std::string joined = fresh("concat");
                emit("Concat", parts, {joined}, {intAttribute("axis", axis)});
                current = joined;
            }
            emit("Identity", {current}, node.outputs);
            return true;
        }
        if (node.op == "ConvTranspose") {
            const Attribute *autoPad = find(node, "auto_pad");
            if (find(node, "output_shape") || (autoPad && autoPad->s != "NOTSET")) return false;
            const Attribute *padsAttribute = find(node, "pads"), *paddingAttribute = find(node, "output_padding");
            std::vector<int64_t> pads = padsAttribute ? padsAttribute->ints : std::vector<int64_t>(4, 0);
            std::vector<int64_t> padding = paddingAttribute ? paddingAttribute->ints : std::vector<int64_t>(2, 0);
            if (pads.size() != 4 || padding.size() != 2) return false;
            bool symmetric = pads[0] == pads[2] && pads[1] == pads[3] && !padding[0] && !padding[1];
            int64_t endH = pads[2] - padding[0], endW = pads[3] - padding[1];
            if (symmetric || endH < 0 || endW < 0) return false;
            // The full transposed convolution is cropped to what pads and
            // output_padding would have produced.
            std::vector<Attribute> attributes;
            for (const auto &attribute : node.attributes)
                if (attribute.name != "pads" && attribute.name != "output_padding" && attribute.name != "auto_pad") attributes.push_back(attribute);
            attributes.push_back(intsAttribute("pads", {0, 0, 0, 0}));
            std::string full = fresh("full");
            emit("ConvTranspose", node.inputs, {full}, attributes);
            const int64_t open = std::numeric_limits<int64_t>::max();
            slice(full, {pads[0], pads[1]}, {endH ? -endH : open, endW ? -endW : open}, {2, 3}, node.outputs[0]);
            return true;
        }
        return false;
    }

    void collectConstant(std::string_view bytes) {
        std::vector<Field> fields;
        if (!readFields(bytes, fields)) return;
        Constant constant;
        std::string name;
        int64_t type = 0;
        std::string_view raw;
        bool external = false;
        for (const Field &field : fields) {
            if (field.number == 1) for (int64_t dim : repeatedInts(field)) constant.dims.push_back(dim);
            else if (field.number == 2) type = int64_t(field.value);
            else if (field.number == 7) for (int64_t value : repeatedInts(field)) constant.values.push_back(value);
            else if (field.number == 8) name = field.bytes;
            else if (field.number == 9) raw = field.bytes;
            else if (field.number == 13) external = true;
        }
        if (type != 7 || external || raw.size() > 128) return;
        for (size_t offset = 0; offset + 8 <= raw.size(); offset += 8) {
            int64_t value;
            memcpy(&value, raw.data() + offset, 8);
            constant.values.push_back(value);
        }
        constants[name] = std::move(constant);
    }
};

void report(char *out, size_t capacity, const std::string &message) { if (out && capacity) snprintf(out, capacity, "%s", message.c_str()); }
}

extern "C" int koharu_onnx_rewrite_coreml(const char *source, const char *target, char *error, size_t capacity) {
    int input = open(source, O_RDONLY);
    struct stat info {};
    if (input < 0 || fstat(input, &info) != 0 || info.st_size <= 0) {
        if (input >= 0) close(input);
        report(error, capacity, std::string("Cannot read ") + source);
        return 0;
    }
    void *mapped = mmap(nullptr, size_t(info.st_size), PROT_READ, MAP_PRIVATE, input, 0);
    close(input);
    if (mapped == MAP_FAILED) { report(error, capacity, "Cannot map the ONNX model"); return 0; }
    std::string_view model(static_cast<const char *>(mapped), size_t(info.st_size));
    auto finish = [&](int ok, const std::string &message) {
        munmap(mapped, size_t(info.st_size));
        if (!ok) report(error, capacity, message);
        return ok;
    };

    std::vector<Field> modelFields, graphFields;
    const Field *graph = nullptr;
    if (!readFields(model, modelFields)) return finish(0, "The ONNX model is not a valid protobuf");
    for (const Field &field : modelFields) if (field.number == 7 && field.wire == 2) graph = &field;
    if (!graph || !readFields(graph->bytes, graphFields)) return finish(0, "The ONNX model has no readable graph");

    Rewriter rewriter;
    for (const Field &field : graphFields) if (field.number == 5 && field.wire == 2) rewriter.collectConstant(field.bytes);
    for (const Field &field : graphFields) {
        if (field.number != 1 || field.wire != 2) continue;
        Node node = parseNode(field.bytes);
        if (!rewriter.rewrite(node)) rewriter.nodes.emplace_back(field.bytes);
    }

    std::string rebuilt;
    rebuilt.reserve(graph->bytes.size() + (1 << 20));
    bool nodesWritten = false;
    for (const Field &field : graphFields) {
        if (field.number == 1 && field.wire == 2) {
            if (!nodesWritten) for (const auto &node : rewriter.nodes) putBytes(rebuilt, 1, node);
            nodesWritten = true;
        } else rebuilt.append(field.raw);
    }
    for (const auto &initializer : rewriter.initializers) putBytes(rebuilt, 5, initializer);

    FILE *output = fopen(target, "wb");
    if (!output) return finish(0, std::string("Cannot write ") + target);
    bool ok = true;
    for (const Field &field : modelFields) {
        if (&field == graph) {
            std::string header;
            putVarint(header, uint64_t(7) << 3 | 2);
            putVarint(header, rebuilt.size());
            ok = ok && fwrite(header.data(), 1, header.size(), output) == header.size();
            ok = ok && fwrite(rebuilt.data(), 1, rebuilt.size(), output) == rebuilt.size();
        } else ok = ok && fwrite(field.raw.data(), 1, field.raw.size(), output) == field.raw.size();
    }
    ok = (fclose(output) == 0) && ok;
    return finish(ok, std::string("Cannot write ") + target);
}
