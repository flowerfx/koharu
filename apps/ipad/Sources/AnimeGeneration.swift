import Foundation
import UIKit

// The native job synchronizes cancellation with context teardown. A strong
// reference spans both the actor call and its cancellation handler.
final class AnimeGenerationJob: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    init() throws {
        guard let pointer = koharu_anima_job_new() else { throw AppError.message(L("Not enough available RAM")) }
        self.pointer = pointer
    }
    deinit { koharu_anima_job_free(pointer) }
    func cancel() { koharu_anima_job_cancel(pointer) }
    func progress() -> (step: Int, steps: Int, phase: Int32) {
        var step: Int32 = 0, steps: Int32 = 0
        let phase = koharu_anima_job_progress(pointer, &step, &steps)
        return (Int(step), Int(steps), phase)
    }
}

struct GeneratedAnimeImage: Codable, Identifiable {
    var id = UUID()
    var created = Date()
    let prompt: String
    let seed: Int64
    let modelID: String
    let width: Int
    let height: Int
    let steps: Int
    var filename: String { id.uuidString + ".png" }
}

extension PagePipeline {
    func generateAnime(_ configuration: AnimeConfiguration, settings: AnimeGenerationSettings, root: URL, prompt: String, seed: Int64, job: AnimeGenerationJob) throws -> Data {
        // Anima needs the RAM held by any cached OCR/cleanup sessions.
        releaseCachedModels()
        return try performVisionInference {
            try Task.checkCancellation()
            let model = configuration.model
            guard model.ready(root) else { throw AppError.message(L("Download the selected model in Settings first")) }
            if let upscaler = settings.upscaler.model, !upscaler.ready(root) {
                throw AppError.message(L("Download the selected upscaler first"))
            }
            // A conservative admission estimate, separate from the physical
            // device target; CPU-mapped weights and tiled Metal compute share RAM.
            guard GGUFMemory.available > UInt64(model.bytes) + settings.memoryHeadroomBytes else {
                throw AppError.message(L("Not enough available RAM"))
            }
            func path(_ role: AnimeConfiguration.Component.Role) throws -> String {
                guard let component = configuration.components.first(where: { $0.role == role }) else {
                    throw AppError.message(L("Invalid Anima model configuration"))
                }
                return model.directory(root).appendingPathComponent(component.file.path).path
            }
            let (width, height) = settings.size.dimensions
            var rgb = [UInt8](repeating: 0, count: width * height * 3)
            var error = [CChar](repeating: 0, count: 8192)
            let ok = try koharu_anima_generate(job.pointer, path(.diffusion), path(.textEncoder), path(.vae), prompt,
                                               Int32(width), Int32(height), Int32(settings.steps), seed,
                                               &rgb, &error, error.count)
            try Task.checkCancellation()
            guard ok != 0 else { throw AppError.message(L(String(cString: error))) }
            let raster = try upscaleAnimeRaster(VisionRaster(width: width, height: height, rgb: rgb), selection: settings.upscaler, root: root, job: job)
            let image = try raster.image()
            guard let data = image.pngData() else { throw AppError.message(L("Could not generate anime image")) }
            return data
        }
    }
    private func upscaleAnimeRaster(_ raster: VisionRaster, selection: AnimeUpscaler, root: URL, job: AnimeGenerationJob) throws -> VisionRaster {
        guard let model = selection.model else { return raster }
        try Task.checkCancellation()
        guard model.ready(root) else { throw AppError.message(L("Download the selected upscaler first")) }
        let width = raster.width * selection.scale, height = raster.height * selection.scale
        guard GGUFMemory.available > UInt64(model.bytes) + 512 * 1024 * 1024 + UInt64(width * height) * 32 else {
            throw AppError.message(L("Not enough available RAM"))
        }
        var output = [UInt8](repeating: 0, count: width * height * 3)
        var error = [CChar](repeating: 0, count: 8192)
        let ok = koharu_anima_upscale(job.pointer, model.directory(root).appendingPathComponent(model.files[0].path).path,
                                     raster.rgb, Int32(raster.width), Int32(raster.height), Int32(selection.scale),
                                     &output, output.count, &error, error.count)
        try Task.checkCancellation()
        guard ok != 0 else { throw AppError.message(L(String(cString: error))) }
        return VisionRaster(width: width, height: height, rgb: output)
    }
}

extension MangaLibrary {
    var animeDirectory: URL { disk.root.appendingPathComponent("anime", isDirectory: true) }
    func deleteAnimeImages(_ ids: Set<UUID>) {
        guard !busy && !downloadingModel else { return }
        let removed = animeImages.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        do {
            let remaining = animeImages.filter { !ids.contains($0.id) }
            // Commit the inventory before unlinking PNGs, so a failed save
            // cannot leave a visible record pointing at an image we deleted.
            try disk.save(remaining, to: animeDirectory.appendingPathComponent("images.json"))
            animeImages = remaining
            for image in removed {
                let file = animeDirectory.appendingPathComponent(image.filename)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            status = L("Deleted")
        } catch { self.error = error.localizedDescription }
    }
    func generateAnime(prompt: String, settings: AnimeGenerationSettings) {
        guard !busy && !downloadingModel else { return }
        requestCredits(.image, cost: creditCost(.image), explanation: L("Free image generation costs credits or one image video access. Premium image generation has no credit fee. Failed or canceled generation is refunded.")) {
            self.startGenerateAnime(prompt: prompt, settings: settings)
        }
    }
    private func startGenerateAnime(prompt: String, settings: AnimeGenerationSettings) {
        guard !busy && !downloadingModel else { return }
        do {
            let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty, prompt.count <= 4096 else {
                throw AppError.message(L("Enter an image description of up to 4,096 characters."))
            }
            let configuration = try AnimeConfiguration.bundled()
            guard let memory = AnimeConfiguration.deviceMemory, configuration.supportsDevice(memory: memory) else {
                throw AppError.message(L("Anime Studio requires a device with at least 8 GB RAM."))
            }
            guard configuration.model.ready(disk.modelsURL) else {
                throw AppError.message(L("Download Anima models first"))
            }
            if let model = settings.upscaler.model, !model.ready(disk.modelsURL) {
                throw AppError.message(L("Download the selected upscaler first"))
            }
            let job = try AnimeGenerationJob()
            let image = GeneratedAnimeImage(prompt: prompt, seed: Int64.random(in: 0...Int64.max), modelID: configuration.id,
                                           width: settings.outputDimensions.width, height: settings.outputDimensions.height, steps: settings.steps)
            busy = true; activeJobUsesGPU = true; progress = 0; status = L("Generating anime image")
            activeTask = Task {
                var succeeded = false
                var ticket: String?
                do {
                    if AppConfiguration.current.contentSafety.mode.checksPrompts { status = L("Reviewing prompt…") }
                    try await safety.checkText(prompt)
                    ticket = try await credits.reserve(action: .image, provider: .local)
                    try Task.checkCancellation()
                    await translator.unload()
                    try Task.checkCancellation()
                    let reporting = Task { @MainActor in
                        while !Task.isCancelled {
                            let (step, steps, phase) = job.progress()
                            if phase == 4 { progress = 0; status = L("Upscaling image") }
                            else if phase == 1 { progress = 0; status = L("Loading Anima model") }
                            // The runtime also reports weight-loading counters.
                            // Only the configured sampling pass belongs in this bar.
                            else if phase == 2 && steps == settings.steps && (1...steps).contains(step) {
                                progress = min(1, max(0, Double(step) / Double(steps)))
                                status = "\(L("Generating anime image")) · \(step)/\(steps)"
                            } else { status = L("Generating anime image") }
                            do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                        }
                    }
                    defer { reporting.cancel() }
                    let png = try await withTaskCancellationHandler {
                        try await pipeline.generateAnime(configuration, settings: settings, root: disk.modelsURL, prompt: prompt, seed: image.seed, job: job)
                    } onCancel: { job.cancel() }
                    reporting.cancel()
                    try Task.checkCancellation()
                    try FileManager.default.createDirectory(at: animeDirectory, withIntermediateDirectories: true)
                    let destination = animeDirectory.appendingPathComponent(image.filename)
                    try png.write(to: destination, options: .atomic)
                    do { try disk.save([image] + animeImages, to: animeDirectory.appendingPathComponent("images.json")) }
                    catch { try? FileManager.default.removeItem(at: destination); throw error }
                    animeImages.insert(image, at: 0)
                    succeeded = true
                    progress = 1; status = L("Image saved")
                } catch {
                    if Task.isCancelled { status = L("Stopped") }
                    else { self.error = error.localizedDescription; status = L("Failed") }
                }
                await finishCredits(ticket, success: succeeded)
                busy = false; activeTask = nil
            }
        } catch { self.error = error.localizedDescription }
    }
}
