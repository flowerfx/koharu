import Foundation
import CryptoKit
import os

struct GGUFDownload: Decodable, Identifiable {
    let id: String
    let name: String
    let url: String
    let enable: Bool
    let maxTokens: Int
    let ramRequirementMB: UInt64
    let ramReferenceTokens: Int
    let bytes: Int64
    let contextBytesPerToken: UInt64
    // Optional pinned SHA-256 of the file; verified after download when present.
    let sha256: String?
    func estimatedMemory(context: Int) -> UInt64 {
        let reference = ramRequirementMB * 1024 * 1024
        return context >= ramReferenceTokens ? reference + UInt64(context - ramReferenceTokens) * contextBytesPerToken : reference - UInt64(ramReferenceTokens - max(0, context)) * contextBytesPerToken
    }
}

enum GGUFMemory {
    static var available: UInt64 {
        #if os(iOS)
        return UInt64(os_proc_available_memory())
        #else
        return ProcessInfo.processInfo.physicalMemory
        #endif
    }
    static func estimate(bytes: Int64, context: Int, contextBytesPerToken: UInt64 = 262144) -> UInt64 {
        let weights = UInt64(max(0, bytes))
        // GGUF metadata budgets F16 KV for layers owning cache, using per-layer
        // dimensions. b12024 defaults to swa_full=true, so sliding layers also
        // reserve the full context. 25% covers runtime/recurrent state; 768 MiB
        // is reserved for OCR/rendering. This remains a planning estimate.
        let cache = UInt64(max(0, context)) * contextBytesPerToken
        return weights + weights / 4 + cache + 768 * 1024 * 1024
    }
    static func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

extension MangaLibrary {
    func importModel(_ source: URL) {
        guard !downloadingModel else { return }
        do { try AppConfiguration.current.requireProvider(.local) } catch { self.error = error.localizedDescription; return }
        downloadingModel = true
        modelTask = Task {
            defer { downloadingModel = false; modelTask = nil }
            let granted = source.startAccessingSecurityScopedResource()
            defer { if granted { source.stopAccessingSecurityScopedResource() } }
            do {
                let id = UUID(); let destination = disk.modelsURL.appendingPathComponent(id.uuidString + ".gguf")
                let size = try await Task.detached {
                    try Self.validateGGUF(source)
                    try FileManager.default.copyItem(at: source, to: destination)
                    return Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                }.value
                models.append(LocalModel(id: id, name: source.deletingPathExtension().lastPathComponent, bytes: size, source: nil))
                preferences.localModel = id
                try disk.save(models, to: disk.root.appendingPathComponent("models.json")); savePreferences()
            } catch { self.error = error.localizedDescription }
        }
    }
    func downloadModel(_ address: String) {
        guard !downloadingModel else { return }
        let catalog = AppConfiguration.current.gguf.first { $0.url == address }
        do {
            try AppConfiguration.current.requireProvider(.local)
            guard catalog?.enable != false else { throw AppError.message(L("This provider or model is disabled in app-config.json. Choose another option in Settings.")) }
        } catch { self.error = error.localizedDescription; return }
        guard let url = URL(string: address), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { error = L("Enter an HTTPS GGUF download URL"); return }
        downloadingModel = true
        modelTask = Task {
            defer { downloadingModel = false; modelTask = nil }
            do {
                status = L("Downloading model")
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 86_400
                let session = URLSession(configuration: config, delegate: RedirectBoundary { $0.scheme == "https" && $0.user == nil && $0.password == nil }, delegateQueue: nil); defer { session.invalidateAndCancel() }
                let (file, response) = try await session.download(from: url)
                defer { try? FileManager.default.removeItem(at: file) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message(L("Model download failed")) }
                try Task.checkCancellation(); try Self.validateGGUF(file)
                if let expected = catalog?.sha256 {
                    status = L("Verifying model")
                    let verification = Task.detached { try Self.sha256(of: file) }
                    let actual = try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
                    guard actual == expected else { throw AppError.message(L("Model checksum verification failed")) }
                }
                let id = UUID(); let destination = disk.modelsURL.appendingPathComponent(id.uuidString + ".gguf")
                try FileManager.default.moveItem(at: file, to: destination)
                var excluded = destination; var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true; try excluded.setResourceValues(attributes)
                let size = Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                models.append(LocalModel(id: id, name: url.deletingPathExtension().lastPathComponent, bytes: size, source: url.absoluteString, catalogID: catalog?.id))
                preferences.localModel = id
                if let catalog { preferences.contextSize = min(preferences.contextSize, catalog.maxTokens) }
                try disk.save(models, to: disk.root.appendingPathComponent("models.json")); savePreferences()
                status = L("Model ready")
            } catch is CancellationError { status = L("Stopped") }
            catch { self.error = error.localizedDescription }
        }
    }
    nonisolated private static func sha256(of url: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
        var hash = SHA256()
        while let data = try reader.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    nonisolated private static func validateGGUF(_ url: URL) throws {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        guard try file.read(upToCount: 4) == Data("GGUF".utf8) else { throw AppError.message(L("This file is not a GGUF model")) }
    }
    func removeModel(_ model: LocalModel) async {
        guard !busy && !downloadingModel else { return }
        await translator.unload()
        do {
            try FileManager.default.removeItem(at: disk.modelsURL.appendingPathComponent(model.filename))
            models.removeAll { $0.id == model.id }
            if preferences.localModel == model.id { preferences.localModel = nil }
            try disk.save(models, to: disk.root.appendingPathComponent("models.json")); savePreferences()
        } catch { self.error = error.localizedDescription }
    }
}
