import UIKit
import ImageIO

// Page images can be 24 MP (≈96 MB decoded). Decoding happens off the main
// thread, and scrolling views request a display-sized thumbnail instead.
enum PageImageLoader {
    static func load(_ url: URL, maxPixel: CGFloat? = nil) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { decode(url, maxPixel: maxPixel) }.value
    }
    static func decode(_ url: URL, maxPixel: CGFloat?) -> UIImage? {
        guard let maxPixel else { return UIImage(contentsOfFile: url.path)?.preparingForDisplay() }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixel.rounded(.up))),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
