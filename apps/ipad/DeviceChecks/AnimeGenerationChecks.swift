import XCTest
import UIKit
@testable import KoharuPad

final class AnimeGenerationChecks: XCTestCase {
    func testRealESRGANMetal512To2048() throws {
        let disk = try LibraryDisk()
        let baseDirectory = disk.root.appendingPathComponent("anime")
        let inventory = try JSONDecoder().decode([GeneratedAnimeImage].self, from: Data(contentsOf: baseDirectory.appendingPathComponent("images.json")))
        let record = try XCTUnwrap(inventory.first(where: { $0.width == 512 && $0.height == 512 }))
        let source = try XCTUnwrap(UIImage(contentsOfFile: baseDirectory.appendingPathComponent(record.filename).path))
        let raster = try VisionRaster(source)
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let evidence = documents.appendingPathComponent("UpscaleChecks")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        for choice in [AnimeUpscaler.anime4, .general4] {
            let model = try XCTUnwrap(choice.model)
            guard model.ready(disk.modelsURL) else { throw XCTSkip("Install optional upscaler fixtures first") }
            let job = try AnimeGenerationJob()
            var output = [UInt8](repeating: 0, count: 2048 * 2048 * 3)
            var error = [CChar](repeating: 0, count: 8192)
            let start = Date()
            XCTAssertEqual(koharu_anima_upscale(job.pointer, model.directory(disk.modelsURL).appendingPathComponent(model.files[0].path).path,
                                              raster.rgb, 512, 512, 4, &output, output.count, &error, error.count), 1, String(cString: error))
            let duration = Date().timeIntervalSince(start)
            XCTAssertGreaterThan(Set(output).count, 32)
            let png = try XCTUnwrap(try VisionRaster(width: 2048, height: 2048, rgb: output).image().pngData())
            try png.write(to: evidence.appendingPathComponent(choice.rawValue + ".png"), options: .atomic)
            let metadata: [String: Any] = ["model": model.id, "inputWidth": 512, "inputHeight": 512, "width": 2048, "height": 2048,
                                           "secondsIncludingLoad": duration, "backend": "Metal GPU", "tileSize": 128]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent(choice.rawValue + ".json"))
            print("UPSCALER_METAL_SMOKE \(choice.rawValue) \(duration) seconds, \(png.count) PNG bytes")
        }
    }
    func testAnimaTurboMetal512() async throws {
        let configuration = try AnimeConfiguration.bundled()
        let disk = try LibraryDisk()
        guard configuration.model.ready(disk.modelsURL) else { throw XCTSkip("Install the optional Anima Turbo fixtures first") }
        let job = try AnimeGenerationJob()
        let prompt = "1girl, anime illustration, blue eyes, long silver hair, white dress, flower garden, soft sunlight, detailed background"
        let start = Date()
        let settings = try AnimeGenerationSettings(configuration: configuration.generation)
        let png = try await PagePipeline().generateAnime(configuration, settings: settings, root: disk.modelsURL, prompt: prompt, seed: 42, job: job)
        let duration = Date().timeIntervalSince(start)
        let image = try XCTUnwrap(UIImage(data: png))
        XCTAssertEqual(image.cgImage?.width, 512); XCTAssertEqual(image.cgImage?.height, 512)
        let pixels = try VisionRaster(image).rgb
        XCTAssertGreaterThan(Set(pixels).count, 32, "Reject blank or constant output")
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let evidence = documents.appendingPathComponent("AnimaChecks")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try png.write(to: evidence.appendingPathComponent("anima-turbo-seed42.png"), options: .atomic)
        let metadata: [String: Any] = ["model": configuration.id, "prompt": prompt, "seed": 42, "width": 512, "height": 512,
                                       "steps": configuration.generation.steps, "secondsIncludingLoad": duration,
                                       "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory, "backend": "Metal GPU"]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("generation.json"))
        print("ANIMA_METAL_SMOKE \(duration) seconds, \(png.count) PNG bytes")
    }
}
