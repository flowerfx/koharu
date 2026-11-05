import Foundation
import UIKit
import OnnxRuntimeBindings
import os

struct InpaintTile: Equatable {
    let x: Int
    let y: Int
    static let edge = 512
    var rect: CGRect { CGRect(x: x, y: y, width: Self.edge, height: Self.edge) }
    static func covering(_ boxes: [CGRect], size: CGSize) -> [InpaintTile] {
        var result: [InpaintTile] = []
        for box in boxes {
            for y in stride(from: Int(box.minY), to: max(Int(box.minY) + 1, Int(ceil(box.maxY))), by: 384) {
                for x in stride(from: Int(box.minX), to: max(Int(box.minX) + 1, Int(ceil(box.maxX))), by: 384) {
                    let part = CGRect(x: CGFloat(x), y: CGFloat(y), width: min(384, box.maxX - CGFloat(x)), height: min(384, box.maxY - CGFloat(y)))
                    if result.contains(where: { $0.rect.insetBy(dx: 32, dy: 32).contains(part) }) { continue }
                    let left = max(0, min(max(0, Int(size.width) - edge), Int(part.midX) - edge / 2))
                    let top = max(0, min(max(0, Int(size.height) - edge), Int(part.midY) - edge / 2))
                    let tile = InpaintTile(x: left, y: top)
                    if !result.contains(tile) { result.append(tile) }
                }
            }
        }
        return result
    }
}

extension PagePipeline {
    func inpaintImage(_ image: UIImage, boxes: [CGRect], modelID: String, modelRoot: URL, onProgress: @Sendable (CleanupProgress) -> Void = { _ in }) throws -> UIImage {
        let model = try AppConfiguration.current.requireVision(modelID, inpainting: true)
        guard model.ready(modelRoot) else { throw AppError.message(L("Download the selected model in Settings first")) }
        onProgress(.loading)
        let directory = model.directory(modelRoot)
        let onnx = try visionRuntime()
        let diffusionKey = directory.path + (modelID == "flux" ? "|flux" : "|sdxl")
        if !onnx.isLoaded(directory) && cachedDiffusion?.key != diffusionKey {
            releaseDiffusion()
            try onnx.admit(model, at: directory)
        }
        var error = [CChar](repeating: 0, count: 4096)
        let session: ORTSession?
        if modelID == "lama" {
            // LaMa runs through Core ML on the GPU, which rejects the published
            // model's dynamic batch axis (error -14) and several of its ops, so
            // load a copy fixed to batch 1 with those ops rewritten.
            let fixed = directory.appendingPathComponent("model-coreml.onnx")
            if !FileManager.default.fileExists(atPath: fixed.path) {
                let batched = directory.appendingPathComponent("model-b1.partial.onnx")
                let partial = directory.appendingPathComponent("model-coreml.partial.onnx")
                defer { try? FileManager.default.removeItem(at: batched) }
                guard koharu_onnx_fix_batch(directory.appendingPathComponent("model.onnx").path, batched.path, &error, error.count) != 0,
                      koharu_onnx_rewrite_coreml(batched.path, partial.path, &error, error.count) != 0 else {
                    throw AppError.message(String(cString: error))
                }
                try FileManager.default.moveItem(at: partial, to: fixed)
            }
            // ONNX Runtime keys its Core ML cache by model path, so name the cache
            // after the file's size and date to drop programs built from an older copy.
            let stamp = try fixed.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let cache = "coreml-gpu-\(stamp.fileSize ?? 0)-\(Int(stamp.contentModificationDate?.timeIntervalSince1970 ?? 0))"
            session = try onnx.session(fixed, coreMLCache: directory.appendingPathComponent(cache), computeUnits: "CPUAndGPU")
        } else if modelID == "aot" {
            session = try onnx.session(directory.appendingPathComponent("model.onnx"), coreMLCache: directory.appendingPathComponent("coreml-" + model.files[0].sha256))
        } else {
            session = nil
        }
        var diffusionHandle: UnsafeMutableRawPointer?
        if session == nil {
            if let cachedDiffusion, cachedDiffusion.key == diffusionKey { diffusionHandle = cachedDiffusion.handle }
            else {
                releaseDiffusion()
                guard let opened = koharu_diffusion_open(directory.path, modelID == "flux" ? 1 : 0, &error, error.count) else { throw AppError.message(L(String(cString: error))) }
                cachedDiffusion = (diffusionKey, opened); diffusionHandle = opened
            }
        }
        let source = try VisionRaster(image)
        var result = source
        let edge = InpaintTile.edge, count = edge * edge
        let tiles = InpaintTile.covering(boxes, size: image.size)
        onProgress(.tiles(completed: 0, total: tiles.count))
        let started = ContinuousClock.now
        for (index, tile) in tiles.enumerated() {
            try Task.checkCancellation()
            var pixels = [UInt8](repeating: 255, count: count * 3), mask = [UInt8](repeating: 0, count: count)
            for y in 0..<edge where tile.y + y < source.height { for x in 0..<edge where tile.x + x < source.width {
                let src = ((tile.y + y) * source.width + tile.x + x) * 3, dst = (y * edge + x) * 3
                for c in 0..<3 { pixels[dst + c] = source.rgb[src + c] }
            } }
            for box in boxes {
                let intersection = box.intersection(tile.rect).integral
                guard !intersection.isNull && !intersection.isEmpty else { continue }
                for y in max(0, Int(intersection.minY) - tile.y)..<min(edge, Int(intersection.maxY) - tile.y) {
                    for x in max(0, Int(intersection.minX) - tile.x)..<min(edge, Int(intersection.maxX) - tile.x) { mask[y * edge + x] = 255 }
                }
            }
            // Metal/Core ML create autoreleased buffers during each inference.
            // Drain those per tile instead of retaining every tile's temporaries
            // until the entire page finishes.
            let output: [UInt8] = try autoreleasepool {
                if let session {
                    var values = VisionRaster(width: edge, height: edge, rgb: pixels).normalized(mean: modelID == "aot" ? [0.5,0.5,0.5] : [0,0,0], std: modelID == "aot" ? [0.5,0.5,0.5] : [1,1,1])
                    let maskValues = mask.map { Float($0) / 255 }
                    if modelID == "aot" { for i in 0..<count where mask[i] != 0 { for c in 0..<3 { values[c * count + i] = 0 } } }
                    let prediction = try VisionONNX.output("output", from: VisionONNX.run(session, [modelID == "aot" ? "img" : "image": VisionONNX.floats(values, [1,3,edge,edge]), "mask": VisionONNX.floats(maskValues, [1,1,edge,edge])]))
                    let data = try prediction.tensorData()
                    guard data.length == count * 3 * 4 else { throw AppError.message(L("Unexpected cleanup model output")) }
                    let floats = data.bytes.assumingMemoryBound(to: Float.self)
                    var rgb = [UInt8](repeating: 0, count: count * 3)
                    for i in 0..<count { for c in 0..<3 {
                        let value = floats[c * count + i]
                        guard value.isFinite else { throw AppError.message(L("Unexpected cleanup model output")) }
                        let normalized = modelID == "aot" ? (value + 1) / 2 : value
                        rgb[i * 3 + c] = UInt8(clamping: Int((normalized * 255).rounded()))
                    } }
                    return rgb
                } else {
                    var rgb = [UInt8](repeating: 0, count: count * 3)
                    guard let diffusionHandle, koharu_diffusion_run(diffusionHandle, pixels, mask, Int32(edge), &rgb, &error, error.count) != 0 else { throw AppError.message(L(String(cString: error))) }
                    return rgb
                }
            }
            try Task.checkCancellation()
            // Composite only replaced pixels at native resolution. No whole-page
            // downscale/upscale or VAE roundtrip can alter the original artwork.
            for y in 0..<edge where tile.y + y < source.height { for x in 0..<edge where tile.x + x < source.width && mask[y * edge + x] != 0 {
                let src = (y * edge + x) * 3, dst = ((tile.y + y) * source.width + tile.x + x) * 3
                for c in 0..<3 { result.rgb[dst + c] = output[src + c] }
            } }
            onProgress(.tiles(completed: index + 1, total: tiles.count))
        }
        let elapsed = started.duration(to: .now).components
        Logger(subsystem: "KoharuPad", category: "Cleanup").notice("cleanup \(modelID, privacy: .public) tiles=\(tiles.count, privacy: .public) seconds=\(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18, privacy: .public)")
        return try result.image()
    }
}
