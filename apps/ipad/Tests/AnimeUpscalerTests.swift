import XCTest
@testable import KoharuPad

final class AnimeUpscalerTests: XCTestCase {
    func testDefaultAndFinalDimensionsForEveryPreset() throws {
        let expected = [(2048, 2048), (3072, 4096), (2880, 5120), (4096, 4096), (4096, 5120)]
        for (size, dimensions) in zip(AnimeImageSize.allCases, expected) {
            let unchanged = try AnimeGenerationSettings(steps: 6, size: size)
            XCTAssertEqual(unchanged.upscaler, .none)
            XCTAssertEqual(unchanged.outputDimensions.width, size.dimensions.width)
            XCTAssertEqual(unchanged.outputDimensions.height, size.dimensions.height)
            for choice in [AnimeUpscaler.anime4, .general4] {
                let request = try AnimeGenerationSettings(steps: 6, size: size, upscaler: choice)
                XCTAssertEqual(request.outputDimensions.width, dimensions.0)
                XCTAssertEqual(request.outputDimensions.height, dimensions.1)
                XCTAssertEqual(request.steps, 6)
                XCTAssertEqual(request.size, size, "Upscaling must not change Anima's input dimensions")
            }
        }
    }
    func testDownloadsAreSeparatePinnedAndVerified() throws {
        XCTAssertNil(AnimeUpscaler.none.model)
        for choice in [AnimeUpscaler.anime4, .general4] {
            let model = try XCTUnwrap(choice.model)
            XCTAssertTrue(model.enable)
            XCTAssertEqual(model.files.count, 1)
            let file = try XCTUnwrap(model.files.first)
            XCTAssertEqual(file.url.scheme, "https")
            XCTAssertEqual(file.url.host, "huggingface.co")
            XCTAssertNotNil(file.url.path.range(of: "/resolve/[a-f0-9]{40}/", options: .regularExpression))
            XCTAssertNotNil(file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression))
            XCTAssertGreaterThan(file.bytes, 0)
            XCTAssertFalse(file.path.contains("/"))
            XCTAssertNotEqual(model.id, try AnimeConfiguration.bundled().model.id)
        }
    }
    func testUpscaleCancellationAndOutputCapacityBoundary() throws {
        let job = try AnimeGenerationJob(); job.cancel()
        let input: [UInt8] = [100, 120, 140]
        var output = [UInt8](repeating: 37, count: 48)
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(koharu_anima_upscale(job.pointer, "/missing.pth", input, 1, 1, 4, &output, 48, &error, error.count), 0)
        XCTAssertTrue(String(cString: error).isEmpty, "Cancellation must return before accessing the model")
        XCTAssertTrue(output.allSatisfy { $0 == 37 })
        XCTAssertEqual(koharu_anima_upscale(job.pointer, "/missing.pth", input, 1, 1, 4, &output, 47, &error, error.count), 0)
        XCTAssertFalse(String(cString: error).isEmpty)
    }
}
