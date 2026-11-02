import Foundation

// Only RGB RRDB models supported by the pinned native runtime are offered.
// Each choice has its own immutable download and a native, fixed scale.
enum AnimeUpscaler: String, CaseIterable, Identifiable, Sendable {
    case none, anime4, general4
    var id: String { rawValue }
    var scale: Int { self == .none ? 1 : 4 }
    var title: String {
        switch self {
        case .none: return L("No upscale")
        case .anime4: return "RealESRGAN anime 6B · 4×"
        case .general4: return "RealESRGAN x4plus · 4×"
        }
    }
    var detail: String {
        L(self == .anime4 ? "Optimized for anime illustrations; smaller 6-block model."
          : "General image model; larger 23-block network.")
    }
    var model: VisionModel? {
        let file: VisionModel.File
        let source: URL
        switch self {
        case .none: return nil
        case .anime4:
            source = URL(string: "https://huggingface.co/amd/realesrgan-x4plus-anime-6b")!
            file = .init(path: "RealESRGAN_x4plus_anime_6B.pth",
                         url: URL(string: source.absoluteString + "/resolve/b14ff5f8ecb5a4b56ce4049a58d0bca1f8814690/RealESRGAN_x4plus_anime_6B.pth")!,
                         bytes: 17_938_799, sha256: "f872d837d3c90ed2e05227bed711af5671a6fd1c9f7d7e91c911a61f155e99da")
        case .general4:
            source = URL(string: "https://huggingface.co/lllyasviel/Annotators")!
            file = .init(path: "RealESRGAN_x4plus.pth",
                         url: URL(string: source.absoluteString + "/resolve/982e7edaec38759d914a963c48c4726685de7d96/RealESRGAN_x4plus.pth")!,
                         bytes: 67_040_989, sha256: "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1")
        }
        return VisionModel(id: "anime-upscale-" + rawValue, name: title, enable: true, builtIn: false,
                           source: source, ramRequirementMB: nil, files: [file])
    }
}

extension MangaLibrary {
    func downloadAnimeUpscaler(_ selection: AnimeUpscaler) {
        guard !busy && !downloadingModel, let model = selection.model else { return }
        downloadModelFiles(model)
    }
}
