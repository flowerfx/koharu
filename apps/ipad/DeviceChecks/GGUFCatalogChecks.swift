import XCTest
@testable import KoharuPad

final class GGUFCatalogChecks: XCTestCase {
    func testBundledCatalogHasPinnedSingleFileDownloadsAndContextBudgets() throws {
        let models = AppConfiguration.current.gguf
        XCTAssertFalse(models.isEmpty)
        XCTAssertEqual(Set(models.map(\.id)).count, models.count)
        for model in models {
            let url = try XCTUnwrap(URL(string: model.url))
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "huggingface.co")
            let parts = url.pathComponents
            let resolve = try XCTUnwrap(parts.firstIndex(of: "resolve"))
            XCTAssertEqual(parts[resolve + 1].count, 40)
            XCTAssertTrue(parts.last?.hasSuffix(".gguf") == true)
            XCTAssertFalse(parts.last?.contains("-of-") == true)
            XCTAssertGreaterThan(model.bytes, 0)
            XCTAssertGreaterThan(model.contextBytesPerToken, 0)
            let short = model.estimatedMemory(context: 2048)
            let long = model.estimatedMemory(context: 16384)
            XCTAssertGreaterThan(short, UInt64(model.bytes))
            XCTAssertGreaterThan(long, short)
        }
        // A context change must not be presented as the same memory budget.
        // Unknown/custom files still get headroom rather than file size alone.
        XCTAssertGreaterThan(GGUFMemory.estimate(bytes: 4_000_000_000, context: 4096), 4_000_000_000)
    }
    private func modified(_ edit: (inout [String: Any]) -> Void) throws -> AppConfiguration {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "app-config", withExtension: "json"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&json)
        return try AppConfiguration.decode(JSONSerialization.data(withJSONObject: json))
    }

    func testDisabledEntriesAreHiddenAndRejectSavedSelections() throws {
        let base = AppConfiguration.current
        let provider = try XCTUnwrap(base.providers.first { $0 != base.defaults.provider })
        let ocr = try XCTUnwrap(base.ocr.first { $0.id != base.defaults.ocr })
        let model = try XCTUnwrap(base.gguf.first)
        let inpaint = try XCTUnwrap(base.inpainting.first)
        let config = try modified { json in
            for (section, id) in [("provider", provider.rawValue), ("gguf", model.id), ("ocr", ocr.id), ("inpainting", inpaint.id)] {
                var entries = json[section] as! [[String: Any]]
                entries[entries.firstIndex { $0["id"] as? String == id }!]["enable"] = false
                json[section] = entries
            }
        }
        XCTAssertFalse(config.providers.contains(provider))
        XCTAssertFalse(config.enabledGGUF.contains { $0.id == model.id })
        XCTAssertFalse(config.enabledOCR.contains { $0.id == ocr.id })
        XCTAssertFalse(config.enabledInpainting.contains { $0.id == inpaint.id })
        XCTAssertThrowsError(try config.requireProvider(provider))
        XCTAssertThrowsError(try config.requireVision(ocr.id))
        XCTAssertThrowsError(try config.requireVision(inpaint.id, inpainting: true))
        XCTAssertThrowsError(try config.catalog(for: LocalModel(id: UUID(), name: model.name, bytes: model.bytes, source: model.url, catalogID: model.id)))
        XCTAssertThrowsError(try config.catalog(for: LocalModel(id: UUID(), name: model.name, bytes: model.bytes, source: model.url)))
        XCTAssertNil(try config.catalog(for: LocalModel(id: UUID(), name: "custom", bytes: 100, source: nil)))
    }

    func testInvalidConfigurationFailsClosed() throws {
        XCTAssertThrowsError(try AppConfiguration.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try modified { json in
            var providers = json["provider"] as! [[String: Any]]
            providers.append(providers[0]); json["provider"] = providers
        })
        XCTAssertThrowsError(try modified { json in
            var models = json["gguf"] as! [[String: Any]]
            models[0]["maxTokens"] = 0; json["gguf"] = models
        })
        XCTAssertThrowsError(try modified { json in
            var models = json["ocr"] as! [[String: Any]]
            let index = models.firstIndex { $0["builtIn"] as? Bool == false }!
            models[index]["files"] = []; json["ocr"] = models
        })
    }

    func testConfiguredTokenCapIsEnforcedBeforeLocalInference() async throws {
        let config = try modified { json in
            var models = json["gguf"] as! [[String: Any]]
            models[0]["maxTokens"] = 2048; json["gguf"] = models
        }
        let model = try XCTUnwrap(config.gguf.first)
        var preferences = Preferences(); preferences.provider = .local; preferences.contextSize = 4096
        do {
            _ = try await TranslationEngine().translate([], config: preferences, model: nil, catalog: model, batchSize: 100)
            XCTFail("The configured cap must reject the request before loading a model")
        } catch {
            XCTAssertEqual(error.localizedDescription, L("Context tokens exceed this GGUF model’s configured maximum."))
        }
    }
}
