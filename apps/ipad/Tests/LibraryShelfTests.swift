import XCTest
@testable import KoharuPad

@MainActor
final class LibraryShelfTests: XCTestCase {
    private func rawkuma(_ slug: String, _ number: String, title: String? = nil, series: String? = nil, created: TimeInterval = 0) -> Chapter {
        var chapter = Chapter(title: title ?? "Series \(slug) Chapter \(number) – Rawkuma", sourceURL: "https://rawkuma.net/manga/\(slug)/chapter-\(number)/", target: "vi-VN", pages: [])
        chapter.seriesTitle = series; chapter.created = Date(timeIntervalSince1970: created)
        return chapter
    }
    private func imported(_ title: String, project: UUID? = nil, created: TimeInterval = 0) -> Chapter {
        var chapter = Chapter(title: title, sourceURL: "imported://" + UUID().uuidString, target: "vi-VN", pages: [])
        chapter.projectID = project; chapter.created = Date(timeIntervalSince1970: created)
        return chapter
    }

    func testSeriesNameFallsBackToTheChapterTitle() {
        XCTAssertEqual(rawkuma("x", "35", title: "Tensei Babaa wa Misugosenai!: Moto Akutoku Jotei no Nishuume Life Chapter 35 – Rawkuma").seriesName,
                       "Tensei Babaa wa Misugosenai!: Moto Akutoku Jotei no Nishuume Life")
        XCTAssertEqual(rawkuma("x", "35", series: "転生ババァは見過ごせない！").seriesName, "転生ババァは見過ごせない！")
        XCTAssertEqual(imported("My scans").seriesName, "My scans")
        XCTAssertEqual(rawkuma("x", "38.5").number, 38.5)
    }

    func testShelvesGroupSeriesAndProjectsAndKeepLooseImports() {
        let project = MangaProject(name: "Scans", created: Date(timeIntervalSince1970: 1))
        let orphan = UUID()
        let chapters = [rawkuma("a", "10", created: 5), rawkuma("a", "2", series: "Alpha", created: 6), rawkuma("b", "1", created: 3),
                        imported("p1", project: project.id, created: 4), imported("loose", created: 7), imported("deleted project", project: orphan, created: 2)]
        let shelves = LibraryShelf.shelves(chapters, projects: [project])
        XCTAssertEqual(shelves.map(\.id), ["series:https://rawkuma.net/manga/a/", "project:" + project.id.uuidString, "series:https://rawkuma.net/manga/b/",
                                           "chapter:" + chapters[4].id.uuidString, "chapter:" + chapters[5].id.uuidString])
        guard case .series(_, let name, let grouped) = shelves[0] else { return XCTFail() }
        XCTAssertEqual(name, "Alpha")
        XCTAssertEqual(grouped.map(\.number), [2, 10], "chapters are in reading order")
        guard case .project(_, let inProject) = shelves[1] else { return XCTFail() }
        XCTAssertEqual(inProject.map(\.title), ["p1"])
    }

    func testShelfSortByDateAndChapterNumber() {
        let chapters = [rawkuma("a", "10", created: 1), rawkuma("a", "2", created: 3), rawkuma("a", "5", created: 2)]
        XCTAssertEqual(ShelfSort.newest.apply(chapters).map(\.number), [2, 5, 10])
        XCTAssertEqual(ShelfSort.oldest.apply(chapters).map(\.number), [10, 5, 2])
        XCTAssertEqual(ShelfSort.chapterDescending.apply(chapters).map(\.number), [10, 5, 2])
        XCTAssertEqual(ShelfSort.chapterAscending.apply(chapters).map(\.number), [2, 5, 10])
    }

    func testOldChapterJSONWithoutSeriesOrProjectStillDecodes() throws {
        let json = #"{"id":"6F9F4E4E-1C1B-4E54-9E1A-6A1C3E0B9F11","title":"T","sourceURL":"imported://x","created":0,"target":"vi-VN","pages":[],"readPage":0}"#
        let chapter = try JSONDecoder().decode(Chapter.self, from: Data(json.utf8))
        XCTAssertNil(chapter.seriesTitle); XCTAssertNil(chapter.projectID); XCTAssertTrue(chapter.isImported)
    }
}
