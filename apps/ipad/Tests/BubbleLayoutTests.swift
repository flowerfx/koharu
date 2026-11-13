import XCTest
import UIKit
@testable import KoharuPad

final class BubbleLayoutTests: XCTestCase {
    /// 400×400 mid-gray page with a white ellipse bubble (black outline) centred at
    /// (200,200), radii 120×150, and a white open area on the right edge.
    private func page() -> [UInt8] {
        var gray = [UInt8](repeating: 120, count: 400 * 400)
        for y in 0..<400 { for x in 0..<400 {
            let d = pow(Double(x - 200) / 120, 2) + pow(Double(y - 200) / 150, 2)
            if d <= 1 { gray[y * 400 + x] = d > 0.93 ? 0 : 255 }
            if x >= 360 { gray[y * 400 + x] = 255 }
        } }
        // Dark vertical "text" strokes inside the OCR boxes.
        for y in 150..<250 { for x in 192..<198 { gray[y * 400 + x] = 20 } }
        return gray
    }

    func testNarrowVerticalBoxUsesTheBubbleInterior() {
        let box = CGRect(x: 188, y: 140, width: 14, height: 120)
        let groups = BubbleLayout.groups(gray: page(), width: 400, height: 400, boxes: [box])
        XCTAssertEqual(groups.count, 1)
        let rect = groups[0].rect
        XCTAssertGreaterThan(rect.width, 120, "text should spread across the bubble, not the 14px column")
        XCTAssertGreaterThan(rect.height, 150)
        // Stays inside the ellipse.
        for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            XCTAssertLessThanOrEqual(pow(Double(corner.x - 200) / 120, 2) + pow(Double(corner.y - 200) / 150, 2), 1)
        }
    }

    func testRegionsInOneBubbleAreJoinedAndOthersStayAlone() {
        let boxes = [CGRect(x: 210, y: 140, width: 14, height: 120), CGRect(x: 176, y: 150, width: 14, height: 100),
                     CGRect(x: 370, y: 100, width: 20, height: 60), CGRect(x: 20, y: 20, width: 30, height: 30)]
        let groups = BubbleLayout.groups(gray: page(), width: 400, height: 400, boxes: boxes)
        XCTAssertEqual(groups.map(\.members), [[0, 1], [2], [3]])
        // Open white area and dark art keep their original boxes.
        XCTAssertEqual(groups[1].rect, boxes[2])
        XCTAssertEqual(groups[2].rect, boxes[3])
    }

    func testFlashBubbleWithGapsInItsOutlineIsStillABubble() {
        // White page; the bubble outline has a 2px gap every 12px, as between spikes.
        var gray = [UInt8](repeating: 255, count: 400 * 400)
        for y in 0..<400 { for x in 0..<400 {
            let d = pow(Double(x - 200) / 120, 2) + pow(Double(y - 200) / 150, 2)
            if d > 0.9 && d <= 1 && (x + y) % 12 >= 2 { gray[y * 400 + x] = 0 }
        } }
        let box = CGRect(x: 190, y: 150, width: 16, height: 100)
        let groups = BubbleLayout.groups(gray: gray, width: 400, height: 400, boxes: [box])
        XCTAssertGreaterThan(groups[0].rect.width, 100)
        XCTAssertLessThan(groups[0].rect.width, 240)
    }

    func testRenderPlacementJoinsBubbleTextInReadingOrder() throws {
        let gray = page()
        let data = gray.withUnsafeBufferPointer { Data(buffer: $0) }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let cgImage = try XCTUnwrap(CGImage(width: 400, height: 400, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceGray(),
                                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let image = UIImage(cgImage: cgImage)
        func segment(_ id: Int, _ rect: CGRect, _ text: String?) -> TextSegment {
            TextSegment(id: id, source: "", text: text, rect: CGRect(x: rect.minX / 400, y: rect.minY / 400, width: rect.width / 400, height: rect.height / 400))
        }
        let placements = PagePipeline.textPlacements(image, segments: [
            segment(0, CGRect(x: 210, y: 140, width: 14, height: 120), "Racrima"),
            segment(1, CGRect(x: 176, y: 150, width: 14, height: 100), "đến rồi."),
            segment(2, CGRect(x: 20, y: 20, width: 30, height: 30), ""),
        ])
        XCTAssertEqual(placements.map(\.1), ["Racrima đến rồi."])
        XCTAssertGreaterThan(placements[0].0.width, 120)
    }
}
