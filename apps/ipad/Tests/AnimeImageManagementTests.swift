import XCTest
@testable import KoharuPad

final class AnimeImageManagementTests: XCTestCase {
    private func record(_ prompt: String) -> GeneratedAnimeImage {
        GeneratedAnimeImage(prompt: prompt, seed: 42, modelID: "anima-turbo-v1-1-q8-0", width: 512, height: 512, steps: 6)
    }
    @MainActor func testSingleAndBulkDeletionPersistAndPreserveOtherAssets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        let directory = root.appendingPathComponent("anime")
        let records = [record("first prompt"), record("second prompt"), record("missing PNG")]
        try disk.save(records, to: directory.appendingPathComponent("images.json"))
        for image in records.prefix(2) { try Data([1, 2, 3]).write(to: directory.appendingPathComponent(image.filename)) }
        let model = disk.modelsURL.appendingPathComponent("keep-model.bin")
        try Data([4, 5, 6]).write(to: model)
        let library = MangaLibrary(disk: disk)
        library.deleteAnimeImages([records[0].id])
        XCTAssertNil(library.error)
        XCTAssertEqual(library.animeImages.map(\.id), Array(records.dropFirst()).map(\.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(records[0].filename).path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(records[1].filename)), Data([1, 2, 3]))
        let reopened = MangaLibrary(disk: disk)
        XCTAssertEqual(reopened.animeImages.map(\.prompt), ["second prompt", "missing PNG"])
        reopened.deleteAnimeImages(Set(reopened.animeImages.map(\.id)))
        XCTAssertNil(reopened.error)
        XCTAssertTrue(MangaLibrary(disk: disk).animeImages.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(records[1].filename).path))
        XCTAssertEqual(try Data(contentsOf: model), Data([4, 5, 6]))
    }
    @MainActor func testFailedInventoryCommitKeepsImagesAndVisibleRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        let directory = root.appendingPathComponent("anime")
        let image = record("keep this image")
        let inventory = directory.appendingPathComponent("images.json")
        try disk.save([image], to: inventory)
        let file = directory.appendingPathComponent(image.filename)
        try Data([1, 2, 3]).write(to: file)
        let library = MangaLibrary(disk: disk)
        try FileManager.default.removeItem(at: inventory)
        try FileManager.default.createDirectory(at: inventory, withIntermediateDirectories: false)
        library.deleteAnimeImages([image.id])
        XCTAssertNotNil(library.error)
        XCTAssertEqual(library.animeImages.map(\.id), [image.id])
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
    }
    @MainActor func testBusyAndUnknownDeletionCannotChangeInventory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        let image = record("keep this image")
        let inventory = root.appendingPathComponent("anime/images.json")
        try disk.save([image], to: inventory)
        let before = try Data(contentsOf: inventory)
        let library = MangaLibrary(disk: disk)
        library.busy = true; library.deleteAnimeImages([image.id])
        library.busy = false; library.downloadingModel = true; library.deleteAnimeImages([image.id])
        library.downloadingModel = false; library.deleteAnimeImages([UUID()])
        XCTAssertEqual(library.animeImages.map(\.id), [image.id])
        XCTAssertEqual(try Data(contentsOf: inventory), before)
        XCTAssertNil(library.error)
    }
}
