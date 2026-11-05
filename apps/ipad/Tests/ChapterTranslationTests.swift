import XCTest
@testable import KoharuPad

final class ChapterTranslationTests: XCTestCase {
    func testRepeatedPageLocalIDsMapBackAndManualEditsSurvive() throws {
        var first = MangaPage(source: "first", original: "first.png")
        var second = MangaPage(source: "second", original: "second.png")
        first.segments = [.init(id: 0, source: "A", rect: .zero), .init(id: 5, source: "Edited", text: "Keep", rect: .zero, edited: true)]
        second.segments = [.init(id: 0, source: "B", rect: .zero)]
        let plan = try ChapterTranslationPlan(pages: [first, second])
        XCTAssertEqual(plan.targets.map(\.source), ["A", "B"])
        var pages = [first, second]
        try plan.apply(["First translation", "Second translation"], to: &pages, fingerprint: "checked")
        XCTAssertEqual(pages[0].segments.map(\.text), ["First translation", "Keep"])
        XCTAssertEqual(pages[1].segments[0].text, "Second translation")
        XCTAssertTrue(pages.allSatisfy { $0.translationFingerprint == "checked" })
        var changed = [first, second]; changed[1].segments[0].source = "Changed"
        XCTAssertThrowsError(try plan.apply(["A", "B"], to: &changed, fingerprint: "wrong"))
        XCTAssertNil(changed[0].segments[0].text, "Do not publish any page from a stale result")
        XCTAssertThrowsError(try plan.apply(["Missing one"], to: &changed, fingerprint: "wrong"))
    }
}
