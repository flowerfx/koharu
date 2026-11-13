import Foundation
import UIKit
import Vision
import ImageIO

enum CleanupProgress: Sendable {
    case loading
    case tiles(completed: Int, total: Int)
}

// OCR, cleanup and Anima inference run synchronously for seconds to minutes.
// The actor's own serial queue keeps that work off the cooperative pool.
actor PagePipeline {
    private nonisolated let queue = DispatchSerialQueue(label: "koharu.page-pipeline", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    // Vision/cleanup models stay loaded across the pages of one run.
    var vision: VisionONNX?
    var cachedDiffusion: (key: String, handle: UnsafeMutableRawPointer)?
    deinit { if let cachedDiffusion { koharu_diffusion_close(cachedDiffusion.handle) } }
    func visionRuntime() throws -> VisionONNX {
        if let vision { return vision }
        let runtime = try VisionONNX()
        vision = runtime
        return runtime
    }
    func releaseDiffusion() {
        if let cachedDiffusion { koharu_diffusion_close(cachedDiffusion.handle) }
        cachedDiffusion = nil
    }
    // Called at the end of a run and before another large model is loaded.
    func releaseCachedModels() {
        vision = nil
        releaseDiffusion()
    }
    func recognize(_ url: URL, modelID: String? = nil, modelRoot: URL? = nil) async throws -> [TextSegment] {
        try Task.checkCancellation()
        _ = try AppConfiguration.current.requireVision(modelID ?? "apple")
        // Document recognition exposes vertical CJK lines and their direction;
        // the legacy text request missed most speech on the same manga page.
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "ja-JP"), Locale.Language(identifier: "en-US")]
        request.textRecognitionOptions.automaticallyDetectLanguage = false
        request.textRecognitionOptions.useLanguageCorrection = false
        request.textRecognitionOptions.minimumTextHeightFraction = 0.004
        request.barcodeDetectionOptions.enabled = false
        let documents = try await request.perform(on: url)
        try Task.checkCancellation()
        var regions = documents.flatMap { $0.document.text.lines }.compactMap { item -> (CGRect, String, Bool)? in
            let text = item.transcript
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let r = item.boundingBox.cgRect
            return (CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height), text, item.textDirection == .topToBottom)
        }.sorted { a, b in
            if abs(a.0.minY - b.0.minY) > 0.04 { return a.0.minY < b.0.minY }
            return a.0.maxX > b.0.maxX
        }
        // Join nearby lines/columns only when they share orientation and overlap.
        var merged: [(CGRect, String, Bool)] = []
        while !regions.isEmpty {
            var region = regions.removeFirst()
            var changed = true
            while changed {
                changed = false
                for index in regions.indices {
                    let next = regions[index]
                    let vertical = region.2
                    guard vertical == next.2 else { continue }
                    let overlap = region.0.intersection(next.0)
                    let along = vertical ? min(region.0.maxY, next.0.maxY) - max(region.0.minY, next.0.minY) : min(region.0.maxX, next.0.maxX) - max(region.0.minX, next.0.minX)
                    let length = vertical ? min(region.0.height, next.0.height) : min(region.0.width, next.0.width)
                    let gap = vertical ? max(region.0.minX, next.0.minX) - min(region.0.maxX, next.0.maxX) : max(region.0.minY, next.0.minY) - min(region.0.maxY, next.0.maxY)
                    let thickness = vertical ? min(region.0.width, next.0.width) : min(region.0.height, next.0.height)
                    if (overlap.isNull || overlap.isEmpty) && along > length * 0.6 && gap >= 0 && gap < thickness * 0.8 {
                        region.1 = (vertical && next.0.maxX > region.0.maxX) ? next.1 + region.1 : region.1 + (vertical ? "" : " ") + next.1
                        region.0 = region.0.union(next.0)
                        regions.remove(at: index); changed = true; break
                    }
                }
            }
            merged.append(region)
        }
        var segments = merged.enumerated().map { TextSegment(id: $0.offset, source: $0.element.1, rect: $0.element.0) }
        if let modelID, !segments.isEmpty {
            guard let modelRoot, let image = UIImage(contentsOfFile: url.path)?.cgImage else { throw AppError.message(L("Could not decode source image")) }
            let crops = try segments.map { segment -> UIImage in
                let rect = CGRect(x: segment.rect.minX * CGFloat(image.width), y: segment.rect.minY * CGFloat(image.height), width: segment.rect.width * CGFloat(image.width), height: segment.rect.height * CGFloat(image.height)).insetBy(dx: -2, dy: -2).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard let crop = image.cropping(to: rect) else { throw AppError.message(L("Could not prepare OCR crop")) }
                return UIImage(cgImage: crop)
            }
            let texts = try performVisionInference { try visionRuntime().read(crops, model: VisionModel.named(modelID), root: modelRoot) }
            for index in segments.indices { segments[index].source = texts[index] }
        }
        return segments
    }
    func render(_ source: URL, segments: [TextSegment], inpaint: Bool, modelID: String = AppConfiguration.current.defaults.inpainting, modelRoot: URL, onCleanupProgress: @escaping @Sendable (CleanupProgress) -> Void = { _ in }) async throws -> Data {
        try Task.checkCancellation()
        if inpaint { _ = try AppConfiguration.current.requireVision(modelID, inpainting: true) }
        guard let image = UIImage(contentsOfFile: source.path) else { throw AppError.message(L("Could not decode source image")) }
        let size = image.size
        let boxes = segments.filter { $0.text != nil }.map { segment in
            CGRect(x: segment.rect.minX * size.width, y: segment.rect.minY * size.height, width: segment.rect.width * size.width, height: segment.rect.height * size.height).insetBy(dx: -3, dy: -3).intersection(CGRect(origin: .zero, size: size))
        }
        let background: UIImage?
        if inpaint && !boxes.isEmpty {
            background = try performVisionInference { try inpaintImage(image, boxes: boxes, modelID: modelID, modelRoot: modelRoot, onProgress: onCleanupProgress) }
        } else { background = nil }
        try Task.checkCancellation()
        let placements = Self.textPlacements(image, segments: segments)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            if let background {
                context.cgContext.saveGState()
                for box in boxes { context.cgContext.addRect(box) }
                context.cgContext.clip()
                background.draw(in: CGRect(origin: .zero, size: size))
                context.cgContext.restoreGState()
            } else {
                // Cover the same padded OCR mask before drawing any translation;
                // overlapping cards must never erase text drawn for another region.
                UIColor.white.setFill()
                for box in boxes { context.cgContext.fill(box) }
                UIColor(white: 0.5, alpha: 1).setStroke()
                context.cgContext.setLineWidth(1)
                for box in boxes where box.width > 1 && box.height > 1 {
                    context.cgContext.stroke(box.insetBy(dx: 0.5, dy: 0.5))
                }
            }
            for (rect, text) in placements {
                guard rect.width > 1 && rect.height > 1 else { continue }
                let width = max(0.1, rect.width - 4)
                let layout = PageTypography(text, size: CGSize(width: width, height: max(0.1, rect.height - 2)))
                layout.text.draw(in: CGRect(x: rect.minX + 2, y: rect.midY - layout.bounds.height / 2, width: width, height: layout.bounds.height))
            }
        }
        guard let data = rendered.pngData() else { throw AppError.message(L("Could not render translated page")) }
        return data
    }
    /// Places each translation in its speech bubble when the OCR box sits in a
    /// closed bubble; regions sharing one bubble are joined in reading order.
    /// Anything else keeps the padded OCR box.
    static func textPlacements(_ image: UIImage, segments: [TextSegment]) -> [(CGRect, String)] {
        let size = image.size, page = CGRect(origin: .zero, size: size)
        let shown = segments.filter { $0.text != nil }
        let boxes = shown.map { segment in
            CGRect(x: segment.rect.minX * size.width, y: segment.rect.minY * size.height, width: segment.rect.width * size.width, height: segment.rect.height * size.height).insetBy(dx: -2, dy: -2).intersection(page)
        }
        func plain() -> [(CGRect, String)] { zip(boxes, shown).compactMap { $1.text!.isEmpty ? nil : ($0, $1.text!) } }
        guard let cgImage = image.cgImage, size.width > 0, size.height > 0 else { return plain() }
        let width = cgImage.width, height = cgImage.height
        var gray = [UInt8](repeating: 255, count: width * height)
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return plain() }
        let scale = CGFloat(width) / size.width
        let pixels = boxes.map { CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale) }
        return BubbleLayout.groups(gray: gray, width: width, height: height, boxes: pixels).compactMap { group in
            let text = group.members.compactMap { shown[$0].text }.filter { !$0.isEmpty }.joined(separator: " ")
            guard !text.isEmpty else { return nil }
            let rect = group.members.count == 1 && group.rect == pixels[group.members[0]] ? boxes[group.members[0]] :
                CGRect(x: group.rect.minX / scale, y: group.rect.minY / scale, width: group.rect.width / scale, height: group.rect.height / scale)
            return (rect, text)
        }
    }
    func performVisionInference<T>(_ operation: () throws -> T) throws -> T {
        do { return try autoreleasepool(invoking: operation) }
        catch {
            let message = error.localizedDescription.lowercased()
            let allocationFailed = message.contains("bad_alloc") || message.contains("out of memory") || message.contains("failed to allocate memory") ||
                ((error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(ENOMEM))
            guard allocationFailed else { throw error }
            // Drop every cached session; unwinding + the autorelease pool then
            // unload them before a fresh memory check in the one retry.
            releaseCachedModels()
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.15)
            try Task.checkCancellation()
            return try autoreleasepool(invoking: operation)
        }
    }

}
