import Foundation
import CryptoKit
import os

struct VisionModel: Decodable, Identifiable {
    struct File: Decodable { let path: String; let url: URL; let bytes: Int64; let sha256: String }
    let id: String
    let name: String
    let enable: Bool
    let builtIn: Bool
    let source: URL
    let ramRequirementMB: UInt64?
    let files: [File]
    var displayName: String { L(name) }
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    static func named(_ id: String) throws -> VisionModel {
        let config = AppConfiguration.current
        guard let model = (config.ocr + config.inpainting).first(where: { $0.id == id && $0.enable }) else {
            throw AppError.message(L("This provider or model is disabled in app-config.json. Choose another option in Settings."))
        }
        return model
    }
    func directory(_ root: URL) -> URL { root.appendingPathComponent("vision/" + id, isDirectory: true) }
    func ready(_ root: URL) -> Bool {
        files.allSatisfy { file in
            let size = try? directory(root).appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return size == Int(file.bytes)
        }
    }
    static var availableMemory: UInt64 {
        #if os(iOS)
        return UInt64(os_proc_available_memory())
        #else
        return ProcessInfo.processInfo.physicalMemory
        #endif
    }
    func checkMemory() throws {
        guard let ramRequirementMB else { return }
        let available = Self.availableMemory
        guard available >= ramRequirementMB * 1024 * 1024 else {
            throw AppError.message("\(name): \(L("Not enough available RAM")) — \(ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .memory)) / \(L("estimated requirement")) \(ramRequirementMB) MB")
        }
    }
}

extension MangaLibrary {
    func removeVisionModel(_ model: VisionModel) {
        guard !busy && !downloadingModel else { return }
        do { try FileManager.default.removeItem(at: model.directory(disk.modelsURL)); status = L("Deleted") }
        catch { self.error = error.localizedDescription }
    }
    func downloadVisionModel(_ model: VisionModel) {
        guard !busy && !downloadingModel else { return }
        guard !model.builtIn, (try? VisionModel.named(model.id)) != nil else { error = L("This provider or model is disabled in app-config.json. Choose another option in Settings."); return }
        downloadModelFiles(model)
    }
    func downloadAnimeModels() {
        guard !busy && !downloadingModel else { return }
        do {
            let configuration = try AnimeConfiguration.bundled()
            guard let memory = AnimeConfiguration.deviceMemory else {
                throw AppError.message(L("Device RAM can only be checked on a physical iPad or iPhone."))
            }
            guard configuration.supportsDevice(memory: memory) else {
                throw AppError.message(L("Anime Studio requires a device with at least 8 GB RAM."))
            }
            downloadModelFiles(configuration.model)
        } catch { self.error = error.localizedDescription }
    }
    func downloadModelFiles(_ model: VisionModel) {
        downloadingModel = true
        modelTask = Task {
            defer { downloadingModel = false; modelTask = nil }
            let staging = disk.root.appendingPathComponent("downloads/" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                let space = try disk.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                guard space > model.bytes + 256 * 1024 * 1024 else { throw AppError.message(L("Not enough storage for this model")) }
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 86_400
                let session = URLSession(configuration: config, delegate: RedirectBoundary { $0.scheme == "https" && $0.user == nil && $0.password == nil }, delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                for (index, file) in model.files.enumerated() {
                    try Task.checkCancellation()
                    guard file.url.scheme == "https", file.url.host == "huggingface.co", !file.path.contains(".."), !file.path.contains("/") else { throw AppError.message(L("Invalid vision model manifest")) }
                    status = "\(L("Downloading model")): \(model.name) \(index + 1)/\(model.files.count)"
                    let (temporary, response) = try await session.download(from: file.url)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message(L("Vision model download failed")) }
                    let verification = Task.detached {
                        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size == file.bytes else { throw AppError.message(L("Model size verification failed")) }
                        let reader = try FileHandle(forReadingFrom: temporary); defer { try? reader.close() }
                        var hash = SHA256()
                        while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
                        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw AppError.message(L("Model checksum verification failed")) }
                    }
                    try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: temporary, to: staging.appendingPathComponent(file.path))
                }
                let destination = model.directory(disk.modelsURL)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
                } else { try FileManager.default.moveItem(at: staging, to: destination) }
                var resource = destination; var values = URLResourceValues(); values.isExcludedFromBackup = true; try resource.setResourceValues(values)
                status = L("Model ready")
            } catch {
                if Task.isCancelled { status = L("Stopped") }
                else { self.error = error.localizedDescription }
            }
        }
    }
}
