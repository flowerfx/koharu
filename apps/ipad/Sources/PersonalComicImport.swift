import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct PersonalComicImportScreen: View {
    @Environment(MangaLibrary.self) private var library
    var onReady: (UUID) -> Void
    @State private var title = ""
    @State private var selectingFiles = false
    var body: some View {
        Form {
            Section {
                Text(L("Import images or an image folder from Files, then translate them in your library."))
                TextField(L("Chapter title (optional)"), text: $title)
            }
            Section(L("Files")) {
                Button(L("Import images or folder"), systemImage: "folder.badge.plus") { selectingFiles = true }
                    .disabled(library.busy || library.downloadingModel).accessibilityIdentifier("personal-comic-import-files")
                Text(L("Images in a folder are sorted by filename and page number. Importing is free; open the chapter and choose Run to translate."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if library.busy {
                Section { ProgressView(value: library.progress); Text(library.status); Button(L("Stop")) { library.activeTask?.cancel() } }
            }
        }.navigationTitle(L("Import manga"))
        .fileImporter(isPresented: $selectingFiles, allowedContentTypes: [.image, .folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): library.importPersonalComic(urls, title: title, onReady: onReady)
            case .failure(let error): library.error = error.localizedDescription
            }
        }
    }
}

extension MangaLibrary {
    func importPersonalComic(_ urls: [URL], title: String, onReady: @escaping (UUID) -> Void) {
        guard !busy, !downloadingModel else { return }
        busy = true; progress = 0; status = L("Importing manga…")
        let id = UUID(), target = preferences.target
        activeTask = Task {
            do {
                let chapter = try await PersonalComicImporter.load(urls, title: title, id: id, target: target, disk: disk) { self.progress = $0 }
                try Task.checkCancellation(); try update(chapter)
                status = L("Chapter imported"); progress = 1; onReady(chapter.id)
            } catch {
                try? FileManager.default.removeItem(at: disk.chapterURL(id))
                if Task.isCancelled { status = L("Stopped") } else { self.error = error.localizedDescription; status = L("Failed") }
            }
            busy = false; activeTask = nil
        }
    }
}

enum PersonalComicImporter {
    static func load(_ urls: [URL], title: String, id: UUID, target: String, disk: LibraryDisk, progress: @escaping @MainActor (Double) -> Void) async throws -> Chapter {
        guard !urls.isEmpty, urls.count <= 500 else { throw invalid() }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        var files: [URL] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey, .fileSizeKey]
        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            try Task.checkCancellation()
            let properties = try url.resourceValues(forKeys: keys)
            guard properties.isSymbolicLink != true else { throw invalid() }
            if properties.isDirectory == true {
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw invalid() }
                var folder: [URL] = []
                var entries = 0
                for case let file as URL in enumerator {
                    try Task.checkCancellation()
                    entries += 1; guard entries <= 10000 else { throw invalid() }
                    let info = try file.resourceValues(forKeys: keys)
                    if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    if info.isRegularFile == true, info.contentType?.conforms(to: .image) == true { folder.append(file) }
                    guard files.count + folder.count <= 500 else { throw invalid() }
                }
                files += folder.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else {
                guard properties.isRegularFile == true, properties.contentType?.conforms(to: .image) == true else { throw invalid() }
                files.append(url)
            }
            guard files.count <= 500 else { throw invalid() }
        }
        guard !files.isEmpty else { throw invalid() }
        var chapter = Chapter(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? urls[0].deletingPathExtension().lastPathComponent : title,
                              sourceURL: "imported://" + id.uuidString, target: target, pages: [])
        var total = 0
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size > 0, size <= 32 * 1024 * 1024, total <= 512 * 1024 * 1024 - size else { throw invalid() }
            total += size
            let page = try SourceImages.store(Data(contentsOf: file, options: .mappedIfSafe), source: chapter.sourceURL + "/\(index + 1)", chapter: chapter.id, disk: disk)
            chapter.pages.append(page); await progress(Double(index + 1) / Double(files.count))
        }
        return chapter
    }
    private static func invalid() -> AppError { .message(L("Choose image files or a folder containing up to 500 images. PDFs and links are not supported.")) }
}
