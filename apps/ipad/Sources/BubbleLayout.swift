import CoreGraphics

/// Finds the speech bubble around each OCR box so a translation can use the
/// bubble's interior instead of the box. Japanese text is usually a narrow
/// vertical column; fitting horizontal text into that column makes it tiny.
struct BubbleLayout {
    struct Group: Equatable {
        /// Indices into the input boxes, in input (reading) order.
        var members: [Int]
        /// Where the text goes, in pixel coordinates.
        var rect: CGRect
    }

    static let brightness: UInt8 = 190
    static let coverage = 0.98

    /// `gray` is a row-major 8-bit luminance image. Boxes are in the same pixel
    /// space. Boxes reached by one flood fill share a bubble and form one group.
    static func groups(gray: [UInt8], width: Int, height: Int, boxes: [CGRect]) -> [Group] {
        let image = CGRect(x: 0, y: 0, width: width, height: height)
        let cells = boxes.map { $0.intersection(image).integral }
        var groups: [Group] = [], grouped = Set<Int>()
        for (index, box) in cells.enumerated() where !grouped.contains(index) {
            guard !box.isNull, box.width >= 1, box.height >= 1,
                  let bubble = fill(gray: gray, width: width, height: height, from: box, boxes: cells) else {
                groups.append(Group(members: [index], rect: boxes[index])); grouped.insert(index); continue
            }
            let members = cells.indices.filter { !grouped.contains($0) && bubble.contains(cells[$0]) }
            grouped.formUnion(members)
            let union = members.map { boxes[$0] }.reduce(boxes[index]) { $0.union($1) }
            // Keep the original box when the bubble interior is not larger.
            let rect = bubble.interior.width * bubble.interior.height > union.width * union.height ? bubble.interior : union
            groups.append(Group(members: members.isEmpty ? [index] : members, rect: rect))
        }
        return groups.sorted { $0.members[0] < $1.members[0] }
    }

    private struct Bubble {
        var mask: [Bool]
        var area: CGRect   // search window in image pixels
        var interior: CGRect
        func contains(_ box: CGRect) -> Bool {
            guard area.contains(CGPoint(x: box.midX, y: box.midY)) else { return false }
            let x = Int(box.midX - area.minX), y = Int(box.midY - area.minY)
            return mask[y * Int(area.width) + x]
        }
    }

    /// Flood fills bright pixels (and every OCR box, whose text will be erased)
    /// from `box`. A fill that reaches the search window edge is open art or
    /// page background, not a closed bubble. Spiky "flash" bubbles have narrow
    /// white gaps between their spikes, so a leak is retried with the bright
    /// area eroded, which closes gaps a few pixels wide.
    private static func fill(gray: [UInt8], width: Int, height: Int, from box: CGRect, boxes: [CGRect]) -> Bubble? {
        let margin = max(2 * max(box.width, box.height), 0.12 * CGFloat(min(width, height)))
        let area = box.insetBy(dx: -margin, dy: -margin).intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        let w = Int(area.width), h = Int(area.height), ox = Int(area.minX), oy = Int(area.minY)
        guard w > 2, h > 2 else { return nil }
        var bright = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w { bright[y * w + x] = gray[(y + oy) * width + x + ox] >= brightness } }
        let gap = max(2, min(width, height) / 300)
        for radius in [0, gap, 2 * gap] {
            var open = radius == 0 ? bright : erode(bright, width: w, height: h, radius: radius)
            for other in boxes where other.intersects(area) {
                let r = other.intersection(area)
                for y in Int(r.minY) - oy..<Int(r.maxY) - oy { for x in Int(r.minX) - ox..<Int(r.maxX) - ox { open[y * w + x] = true } }
            }
            if let mask = flood(open, width: w, height: h, seed: box.intersection(area).offsetBy(dx: -area.minX, dy: -area.minY)) {
                return bubble(mask, area: area)
            }
        }
        return nil
    }

    private static func flood(_ open: [Bool], width w: Int, height h: Int, seed: CGRect) -> [Bool]? {
        var mask = [Bool](repeating: false, count: w * h), stack: [Int] = []
        for y in Int(seed.minY)..<Int(seed.maxY) { for x in Int(seed.minX)..<Int(seed.maxX) { mask[y * w + x] = true; stack.append(y * w + x) } }
        while let p = stack.popLast() {
            let x = p % w, y = p / w
            if x == 0 || y == 0 || x == w - 1 || y == h - 1 { return nil }
            for q in [p - 1, p + 1, p - w, p + w] where open[q] && !mask[q] { mask[q] = true; stack.append(q) }
        }
        return mask
    }

    /// A pixel stays open only if its whole (2r+1)² neighbourhood is bright.
    private static func erode(_ value: [Bool], width w: Int, height h: Int, radius r: Int) -> [Bool] {
        func pass(_ input: [Bool], horizontal: Bool) -> [Bool] {
            var output = [Bool](repeating: false, count: w * h)
            let (lines, length) = horizontal ? (h, w) : (w, h)
            var left = [Int](repeating: 0, count: length), right = [Int](repeating: 0, count: length)
            for line in 0..<lines {
                let index: (Int) -> Int = horizontal ? { line * w + $0 } : { $0 * w + line }
                // Distance to the nearest dark pixel on each side along the line.
                var last = -length
                for i in 0..<length { if !input[index(i)] { last = i }; left[i] = i - last }
                last = 2 * length
                for i in stride(from: length - 1, through: 0, by: -1) { if !input[index(i)] { last = i }; right[i] = last - i }
                for i in 0..<length { output[index(i)] = left[i] > r && right[i] > r }
            }
            return output
        }
        return pass(pass(value, horizontal: true), horizontal: false)
    }

    private static func bubble(_ mask: [Bool], area: CGRect) -> Bubble {
        let w = Int(area.width), h = Int(area.height)
        var stack: [Int] = []
        // Dark marks enclosed by the bubble (missed furigana, punctuation, stray
        // strokes) count as interior: only what the window edge reaches is outside.
        var outside = [Bool](repeating: false, count: w * h)
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
        while let p = stack.popLast() {
            guard !mask[p], !outside[p] else { continue }
            outside[p] = true
            let x = p % w, y = p / w
            if x > 0 { stack.append(p - 1) }; if x < w - 1 { stack.append(p + 1) }
            if y > 0 { stack.append(p - w) }; if y < h - 1 { stack.append(p + w) }
        }
        let solid = outside.map { !$0 }
        return Bubble(mask: mask, area: area, interior: interior(mask: solid, width: w, height: h).offsetBy(dx: area.minX, dy: area.minY))
    }

    /// The largest rectangle with the bubble's bounding-box aspect, centred on the
    /// bubble's centroid, that lies (almost) entirely inside the bubble.
    private static func interior(mask: [Bool], width w: Int, height h: Int) -> CGRect {
        var sum = [Int](repeating: 0, count: (w + 1) * (h + 1))
        var minX = w, minY = h, maxX = 0, maxY = 0, cx = 0, cy = 0, count = 0
        for y in 0..<h {
            var row = 0
            for x in 0..<w {
                if mask[y * w + x] { row += 1; count += 1; cx += x; cy += y; minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y) }
                sum[(y + 1) * (w + 1) + x + 1] = sum[y * (w + 1) + x + 1] + row
            }
        }
        guard count > 0 else { return .zero }
        let centre = CGPoint(x: CGFloat(cx) / CGFloat(count) + 0.5, y: CGFloat(cy) / CGFloat(count) + 0.5)
        let full = CGSize(width: maxX - minX + 1, height: maxY - minY + 1)
        func rect(_ scale: CGFloat) -> CGRect {
            CGRect(x: centre.x - full.width * scale / 2, y: centre.y - full.height * scale / 2, width: full.width * scale, height: full.height * scale).integral
        }
        func fits(_ r: CGRect) -> Bool {
            guard r.minX >= 0, r.minY >= 0, r.maxX <= CGFloat(w), r.maxY <= CGFloat(h), r.width >= 1, r.height >= 1 else { return false }
            let x0 = Int(r.minX), y0 = Int(r.minY), x1 = Int(r.maxX), y1 = Int(r.maxY)
            let inside = sum[y1 * (w + 1) + x1] - sum[y0 * (w + 1) + x1] - sum[y1 * (w + 1) + x0] + sum[y0 * (w + 1) + x0]
            return Double(inside) >= coverage * Double((x1 - x0) * (y1 - y0))
        }
        var lo: CGFloat = 0, hi: CGFloat = 1
        for _ in 0..<12 { let mid = (lo + hi) / 2; if fits(rect(mid)) { lo = mid } else { hi = mid } }
        // Leave a little breathing room from the bubble outline.
        let best = rect(lo)
        return best.insetBy(dx: best.width * 0.05, dy: best.height * 0.05)
    }
}
