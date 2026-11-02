import Foundation

struct AnimeConfiguration: Decodable {
    struct Generation: Decodable {
        let width: Int
        let height: Int
        let steps: Int
        let cfg: Float
        let sampler: String
        let scheduler: String
        let backend: String
    }
    struct Component: Decodable, Identifiable {
        enum Role: String, Decodable, CaseIterable { case diffusion, textEncoder, vae }
        let role: Role
        let file: VisionModel.File
        var id: String { role.rawValue }
        var title: String {
            switch role {
            case .diffusion: return L("Diffusion model")
            case .textEncoder: return L("Text encoder")
            case .vae: return L("VAE")
            }
        }
    }
    let id: String
    let name: String
    let minimumDeviceMemoryBytes: UInt64
    let source: URL
    let license: URL
    let components: [Component]
    let generation: Generation

    static var deviceMemory: UInt64? {
        #if targetEnvironment(simulator)
        // ProcessInfo returns the Mac's RAM in Simulator, not the iPad's RAM.
        return nil
        #else
        return ProcessInfo.processInfo.physicalMemory
        #endif
    }

    var model: VisionModel {
        VisionModel(id: id, name: name, enable: true, builtIn: false, source: source,
                    ramRequirementMB: nil, files: components.map(\.file))
    }
    func supportsDevice(memory: UInt64) -> Bool { memory >= minimumDeviceMemoryBytes }

    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "anima-config", withExtension: "json") else {
            throw AppError.message(L("Invalid Anima model configuration"))
        }
        return try decode(Data(contentsOf: url))
    }
    static func decode(_ data: Data) throws -> Self {
        do {
            let value = try JSONDecoder().decode(Self.self, from: data)
            _ = try AnimeGenerationSettings(configuration: value.generation)
            func secure(_ url: URL) -> Bool {
                url.scheme == "https" && url.host == "huggingface.co" && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
            }
            guard value.id == "anima-turbo-v1-1-q8-0", !value.name.isEmpty,
                  value.minimumDeviceMemoryBytes == 8_000_000_000,
                  value.generation.cfg == 1,
                  value.generation.sampler == "euler", value.generation.scheduler == "sgm_uniform", value.generation.backend == "metal",
                  secure(value.source), secure(value.license),
                  value.components.count == Component.Role.allCases.count,
                  Set(value.components.map(\.role)) == Set(Component.Role.allCases),
                  Set(value.components.map { $0.file.path }).count == value.components.count,
                  Set(value.components.map { $0.file.url }).count == value.components.count,
                  value.components.allSatisfy({ component in
                      let file = component.file
                      let parts = file.url.pathComponents
                      guard secure(file.url), !file.path.contains(".."),
                            file.path.range(of: "^[a-zA-Z0-9_.-]+\\.(gguf|safetensors)$", options: .regularExpression) != nil,
                            file.url.pathExtension == (component.role == .diffusion ? "gguf" : "safetensors"),
                            file.url.lastPathComponent == file.path,
                            let resolve = parts.firstIndex(of: "resolve"), parts.count > resolve + 2,
                            parts[resolve + 1].range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else { return false }
                      return file.bytes > 0 && file.bytes < 100_000_000_000 &&
                          file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
                  }) else { throw AppError.message(L("Invalid Anima model configuration")) }
            return value
        } catch { throw AppError.message(L("Invalid Anima model configuration")) }
    }
}
