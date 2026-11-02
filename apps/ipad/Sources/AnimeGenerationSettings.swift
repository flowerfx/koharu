import Foundation

enum AnimeImageSize: String, CaseIterable, Identifiable, Sendable {
    case square512 = "512x512"
    case portrait768 = "768x1024"
    case portrait720 = "720x1280"
    case square1024 = "1024x1024"
    case portrait1024 = "1024x1280"
    var id: String { rawValue }
    var dimensions: (width: Int, height: Int) {
        switch self {
        case .square512: return (512, 512)
        case .portrait768: return (768, 1024)
        case .portrait720: return (720, 1280)
        case .square1024: return (1024, 1024)
        case .portrait1024: return (1024, 1280)
        }
    }
    var title: String { "\(dimensions.width) × \(dimensions.height)" }
}

struct AnimeGenerationSettings: Equatable, Sendable {
    let steps: Int
    let size: AnimeImageSize
    init(steps: Int, size: AnimeImageSize) throws {
        guard (5...20).contains(steps) else { throw AppError.message(L("Invalid image generation settings")) }
        self.steps = steps; self.size = size
    }
    init(configuration: AnimeConfiguration.Generation) throws {
        guard let size = AnimeImageSize.allCases.first(where: {
            $0.dimensions.width == configuration.width && $0.dimensions.height == configuration.height
        }) else { throw AppError.message(L("Invalid image generation settings")) }
        try self.init(steps: configuration.steps, size: size)
    }
    // Working-buffer reserve scales with pixels. This is conservative admission
    // guidance, not a measured peak or a guarantee that larger frames fit.
    var memoryHeadroomBytes: UInt64 {
        512 * 1024 * 1024 * UInt64(size.dimensions.width) * UInt64(size.dimensions.height) / (512 * 512)
    }
}
