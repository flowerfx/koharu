import XCTest
import UIKit
@testable import KoharuPad

final class ChapterNavigationChecks: XCTestCase {
    @MainActor func testChapterDeletionKeepsModelsSettingsAndUnselectedChapters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root), library = MangaLibrary(disk: disk)
        let settings = root.appendingPathComponent("preferences.json")
        try disk.save(library.preferences, to: settings)
        let settingsData = try Data(contentsOf: settings)
        let model = disk.modelsURL.appendingPathComponent("keep-model.gguf")
        try Data([1, 2, 3]).write(to: model)
        var ids: [UUID] = []
        for index in 1...3 {
            let chapter = Chapter(title: "Disposable chapter \(index)", sourceURL: "https://rawkuma.net/manga/check/\(index)/", target: "vi-VN", pages: [])
            try library.update(chapter)
            for name in ["original.image", "render.png", "undo.json"] {
                try Data([4, 5, 6]).write(to: disk.chapterURL(chapter.id).appendingPathComponent(name))
            }
            ids.append(chapter.id)
        }
        library.busy = true
        library.delete(ids)
        XCTAssertEqual(library.chapters.count, 3)
        library.busy = false
        library.delete([ids[0]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.chapterURL(ids[0]).path))
        XCTAssertEqual(Set(try disk.chapters().map(\.id)), Set(ids.dropFirst()))
        library.delete(library.chapters.map(\.id))
        XCTAssertTrue(library.chapters.isEmpty)
        XCTAssertTrue(try disk.chapters().isEmpty)
        for id in ids { XCTAssertFalse(FileManager.default.fileExists(atPath: disk.chapterURL(id).path)) }
        XCTAssertEqual(try Data(contentsOf: settings), settingsData)
        XCTAssertEqual(try Data(contentsOf: model), Data([1, 2, 3]))
        XCTAssertNil(library.error)
    }
    @MainActor func testBatchSizePersistsWithoutChangingProcessingPreferences() throws {
        let previous = UserDefaults.standard.object(forKey: "translationBatchSize")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "translationBatchSize") }
            else { UserDefaults.standard.removeObject(forKey: "translationBatchSize") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        UserDefaults.standard.removeObject(forKey: "translationBatchSize")
        let disk = try LibraryDisk(root: root), library = MangaLibrary(disk: disk)
        XCTAssertEqual(library.translationBatchSize, 300)
        let preferences = library.preferences
        library.translationBatchSize = 1000
        XCTAssertEqual(library.preferences, preferences)
        XCTAssertEqual(MangaLibrary(disk: disk).translationBatchSize, 1000)
        library.translationBatchSize = 99
        XCTAssertEqual(library.translationBatchSize, 100)
        library.translationBatchSize = 1001
        XCTAssertEqual(MangaLibrary(disk: disk).translationBatchSize, 1000)
    }
    @MainActor func testImageImportPublishesReadyChapterWithoutStartingTranslation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root), library = MangaLibrary(disk: disk)
        let old = Chapter(title: "Old chapter", sourceURL: "imported://old", target: library.preferences.target, pages: [])
        try library.update(old)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let input = root.appendingPathComponent("page1.png")
        try XCTUnwrap(image.pngData()).write(to: input)
        var ready: [UUID] = []
        library.importPersonalComic([input], title: "New chapter") { id in
            ready.append(id)
            XCTAssertTrue(library.busy)
            XCTAssertNil(library.error)
            let chapter = library.chapters.first { $0.id == id }
            XCTAssertEqual(chapter?.pages.count, 1)
            XCTAssertTrue(chapter?.pages.allSatisfy { $0.rendered == nil } == true)
        }
        try await XCTUnwrap(library.activeTask).value
        XCTAssertEqual(ready.count, 1); XCTAssertNotEqual(ready.first, old.id)
        XCTAssertNil(library.error)
        XCTAssertTrue(library.chapters.contains { $0.id == old.id })
        let invalid = root.appendingPathComponent("invalid.pdf")
        try Data("not supported".utf8).write(to: invalid)
        ready = []
        library.importPersonalComic([invalid], title: "Invalid") { ready.append($0) }
        try await XCTUnwrap(library.activeTask).value
        XCTAssertTrue(ready.isEmpty, "A rejected import must not replace the reader route")
    }
}
