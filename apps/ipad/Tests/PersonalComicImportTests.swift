import XCTest
import UIKit
import ImageIO
@testable import KoharuPad

final class PersonalComicImportTests: XCTestCase {
    @MainActor private func image(_ width: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: width, height: 300), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: 300))
        }.pngData())
    }
    @MainActor func testFolderImportsOnlyImagesInNumericPageOrderIncludingSubfolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("My chapter")
        let nested = folder.appendingPathComponent("extras")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try image(100).write(to: folder.appendingPathComponent("page10.png"))
        try image(200).write(to: folder.appendingPathComponent("page2.png"))
        try image(150).write(to: nested.appendingPathComponent("page1.png"))
        try Data("ignored PDF".utf8).write(to: folder.appendingPathComponent("readme.pdf"))
        let disk = try LibraryDisk(root: root.appendingPathComponent("library"))
        let chapter = try await PersonalComicImporter.load([folder], title: "Title", id: UUID(), target: "en-US", disk: disk, progress: { _ in })
        XCTAssertEqual(chapter.pages.count, 3); XCTAssertEqual(chapter.title, "Title")
        XCTAssertEqual(URL(string: chapter.sourceURL)?.scheme, "imported")
        let widths = chapter.pages.map { UIImage(contentsOfFile: disk.pageURL(chapter.id, $0.original).path)?.size.width }
        XCTAssertEqual(widths, [150, 200, 100])
    }
    @MainActor func testDirectPDFAndEmptyFoldersAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("chapter.pdf")
        try Data("PDF not supported".utf8).write(to: pdf)
        let disk = try LibraryDisk(root: root.appendingPathComponent("library"))
        for urls in [[pdf], []] as [[URL]] {
            do { _ = try await PersonalComicImporter.load(urls, title: "", id: UUID(), target: "en-US", disk: disk, progress: { _ in }); XCTFail("Unsupported input accepted") } catch {}
        }
    }
}
