import XCTest
@testable import KoharuPad

final class AnimeConfigurationTests: XCTestCase {
    private func bundledData() throws -> Data {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "anima-config", withExtension: "json"))
        return try Data(contentsOf: url)
    }
    func testCompletePackageAndDeviceAdmission() throws {
        let configuration = try AnimeConfiguration.decode(bundledData())
        XCTAssertEqual(Set(configuration.components.map(\.role)), [.diffusion, .textEncoder, .vae])
        XCTAssertEqual(configuration.model.bytes, 3_685_413_086)
        XCTAssertNil(configuration.model.ramRequirementMB, "A physical RAM target is not a measured inference requirement")
        XCTAssertFalse(configuration.supportsDevice(memory: 7_999_999_999))
        XCTAssertTrue(configuration.supportsDevice(memory: 8_000_000_000))
        XCTAssertTrue(configuration.supportsDevice(memory: 16_000_000_000))
    }
    func testInvalidOrMutableDownloadsFailClosed() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: bundledData()) as? [String: Any])
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["minimumDeviceMemoryBytes"] = 0 },
            { $0["components"] = [] },
            { value in
                var generation = value["generation"] as! [String: Any]
                generation["backend"] = "npu"; value["generation"] = generation
            },
            { value in
                var generation = value["generation"] as! [String: Any]
                generation["width"] = 1024; value["generation"] = generation
            },
            { value in
                var components = value["components"] as! [[String: Any]]
                components[1]["role"] = "diffusion"
                value["components"] = components
            }
        ]
        for mutation in mutations {
            var value = original; mutation(&value)
            XCTAssertThrowsError(try AnimeConfiguration.decode(JSONSerialization.data(withJSONObject: value)))
        }
        let firstFile = (original["components"] as! [[String: Any]])[0]["file"] as! [String: Any]
        let address = firstFile["url"] as! String
        for (key, replacement) in [
            ("url", address.replacingOccurrences(of: "https://", with: "http://")),
            ("url", address.replacingOccurrences(of: "/resolve/[a-f0-9]{40}/", with: "/resolve/main/", options: .regularExpression)),
            ("path", "../model.safetensors"),
            ("sha256", "incorrect"),
            ("bytes", 0 as Any)
        ] {
            var value = original
            var components = value["components"] as! [[String: Any]]
            var file = components[0]["file"] as! [String: Any]
            file[key] = replacement; components[0]["file"] = file; value["components"] = components
            XCTAssertThrowsError(try AnimeConfiguration.decode(JSONSerialization.data(withJSONObject: value)))
        }
    }
    func testCancellationBeforeLoadingDoesNotTouchOutput() throws {
        let job = try AnimeGenerationJob()
        job.cancel()
        for size in AnimeImageSize.allCases {
            let (width, height) = size.dimensions
            for steps in [5, 20] {
                var output = [UInt8](repeating: 37, count: width * height * 3)
                var error = [CChar](repeating: 0, count: 256)
                XCTAssertEqual(koharu_anima_generate(job.pointer, "/missing.gguf", "/missing.safetensors", "/missing.safetensors",
                                                     "a cat", Int32(width), Int32(height), Int32(steps), 42, &output, &error, error.count), 0)
                XCTAssertTrue(String(cString: error).isEmpty, "The native boundary must admit this preset before checking cancellation")
                XCTAssertTrue(output.allSatisfy { $0 == 37 })
            }
        }
    }
    func testGenerationSettingsSnapshotBoundsAndPixelMemoryReserve() throws {
        var selectedSize = AnimeImageSize.square512
        let request = try AnimeGenerationSettings(steps: 5, size: selectedSize)
        selectedSize = .portrait1024
        let next = try AnimeGenerationSettings(steps: 20, size: selectedSize)
        XCTAssertEqual(request.size, .square512)
        XCTAssertEqual(request.steps, 5)
        XCTAssertGreaterThan(next.memoryHeadroomBytes, request.memoryHeadroomBytes)
        XCTAssertThrowsError(try AnimeGenerationSettings(steps: 4, size: .square512))
        XCTAssertThrowsError(try AnimeGenerationSettings(steps: 21, size: .square512))
    }
}
