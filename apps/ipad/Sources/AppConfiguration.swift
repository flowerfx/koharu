import Foundation

struct AppConfiguration: Decodable {
    struct Server: Decodable, Equatable, Sendable {
        let active: Bool
        let endpoint: URL
        func validated() throws {
            guard endpoint.scheme == "https", let host = endpoint.host, !host.isEmpty,
                  endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
                  endpoint.path.isEmpty || endpoint.path == "/",
                  endpoint.port.map({ (1...65535).contains($0) }) ?? true else {
                throw AppError.message(L("Invalid backend connection configuration"))
            }
        }
    }
    let server: Server
    struct Provider: Decodable { let id: TranslationProvider; let enable: Bool }
    struct Defaults: Decodable {
        let provider: TranslationProvider
        let ocr: String
        let inpainting: String
        let aiInpainting: Bool
        let contextTokens: Int
    }
    let defaults: Defaults
    let credit: CreditConfiguration
    let provider: [Provider]
    let gguf: [GGUFDownload]
    let ocr: [VisionModel]
    let inpainting: [VisionModel]

    static func bundledData() throws -> Data {
        guard let url = Bundle.main.url(forResource: "app-config", withExtension: "json") else {
            throw AppError.message(L("Invalid app configuration (app-config.json)"))
        }
        return try Data(contentsOf: url)
    }
    // Every consumer reads the currently published immutable snapshot.
    // KoharuPadApp shows a startup error instead of the library when the store
    // cannot open, so the bundled fallback only covers early or test callers.
    static var current: Self {
        if let configuration = try? ConfigurationStore.shared.get().configuration { return configuration }
        guard let bundled = bundledFallback else { preconditionFailure("The bundled app-config.json is missing or invalid") }
        return bundled
    }
    private static let bundledFallback: Self? = try? decode(bundledData())
    var providers: [TranslationProvider] { provider.filter { $0.enable && (server.active || $0.id != .backend) }.map(\.id) }
    var enabledGGUF: [GGUFDownload] { gguf.filter(\.enable) }
    var enabledOCR: [VisionModel] { ocr.filter(\.enable) }
    var enabledInpainting: [VisionModel] { inpainting.filter(\.enable) }

    static func decode(_ data: Data) throws -> Self {
        do {
            let config = try JSONDecoder().decode(Self.self, from: data)
            _ = try config.credit.validated()
            try config.server.validated()
            func unique(_ ids: [String]) -> Bool { Set(ids).count == ids.count }
            func secure(_ url: URL) -> Bool { url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil }
            let vision = config.ocr + config.inpainting
            guard !config.provider.filter(\.enable).isEmpty, !config.enabledOCR.isEmpty,
                  unique(config.provider.map { $0.id.rawValue }), unique(config.gguf.map(\.id)), unique(config.gguf.map(\.url)), unique(vision.map(\.id)),
                  config.provider.contains(where: { $0.enable && $0.id == config.defaults.provider }),
                  config.enabledOCR.contains(where: { $0.id == config.defaults.ocr }),
                  config.inpainting.contains(where: { $0.id == config.defaults.inpainting && (!config.defaults.aiInpainting || $0.enable) }),
                  (1024...1_048_576).contains(config.defaults.contextTokens),
                  config.gguf.allSatisfy({ model in
                      guard let url = URL(string: model.url) else { return false }
                      return !model.id.isEmpty && !model.name.isEmpty && secure(url) && url.pathExtension == "gguf" &&
                          (model.sha256.map { $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil } ?? true) &&
                          model.bytes > 0 && model.bytes < 1_000_000_000_000 && (1024...1_048_576).contains(model.maxTokens) &&
                          (1...1_048_576).contains(model.ramReferenceTokens) && model.contextBytesPerToken > 0 && model.contextBytesPerToken < 16_777_216 &&
                          model.ramRequirementMB < 1_048_576 && model.ramRequirementMB * 1024 * 1024 > UInt64(model.bytes) + UInt64(model.ramReferenceTokens) * model.contextBytesPerToken
                  }),
                  config.ocr.allSatisfy({ ["apple", "manga", "baberu", "hayai", "paddle"].contains($0.id) }),
                  config.inpainting.allSatisfy({ ["lama", "aot", "flux", "rorem"].contains($0.id) }),
                  vision.allSatisfy({ model in
                      guard !model.name.isEmpty, secure(model.source), model.builtIn == (model.id == "apple") else { return false }
                      if model.builtIn { return model.files.isEmpty && model.ramRequirementMB == nil }
                      guard let ram = model.ramRequirementMB, ram > 0 && ram < 1_048_576 else { return false }
                      return !model.files.isEmpty && unique(model.files.map(\.path)) && model.files.allSatisfy { file in
                          secure(file.url) && file.bytes > 0 && file.bytes < 1_000_000_000_000 &&
                          file.path.range(of: "^[a-zA-Z0-9_-]+\\.[a-z0-9]+$", options: .regularExpression) != nil &&
                          file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
                      }
                  }) else { throw AppError.message(L("Invalid app configuration (app-config.json)")) }
            return config
        } catch { throw AppError.message(L("Invalid app configuration (app-config.json)")) }
    }

    func requireProvider(_ id: TranslationProvider) throws {
        guard providers.contains(id) else { throw AppError.message(L("This provider or model is disabled in app-config.json. Choose another option in Settings.")) }
    }
    func requireVision(_ id: String, inpainting: Bool = false) throws -> VisionModel {
        guard let model = (inpainting ? self.inpainting : ocr).first(where: { $0.id == id && $0.enable }) else {
            throw AppError.message(L("This provider or model is disabled in app-config.json. Choose another option in Settings."))
        }
        return model
    }
    func catalog(for model: LocalModel) throws -> GGUFDownload? {
        let entry = gguf.first { model.catalogID != nil ? $0.id == model.catalogID : $0.url == model.source }
        guard model.catalogID == nil || entry != nil, entry?.enable != false else {
            throw AppError.message(L("This provider or model is disabled in app-config.json. Choose another option in Settings."))
        }
        return entry
    }
}
