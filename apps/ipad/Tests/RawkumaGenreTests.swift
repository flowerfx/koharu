import XCTest
import SwiftUI
@testable import KoharuPad

final class RawkumaGenreTests: XCTestCase {
    func testConfigurableGenreNamesMatchEntireTagsIgnoringCaseAndNoneNeverBlocks() throws {
        let custom = ContentSafetyConfiguration(mode: .half, blockedGenres: ["Adult", "Mature", "Ecchi", "Hentai", "Crime", "Custom genre"])
        try custom.validated()
        XCTAssertEqual(custom.blockedMatches(["aDuLt", " HENTAI ", "cRiMe", "Custom genre", "Comedy"]), ["Adult", "Hentai", "Crime", "Custom genre"])
        XCTAssertTrue(custom.blockedMatches(["Adult comedy", "Adventure"]).isEmpty)
        XCTAssertTrue(ContentSafetyConfiguration(mode: .none, blockedGenres: ["Adult"]).blockedMatches(["Adult"]).isEmpty)
        XCTAssertThrowsError(try ContentSafetyConfiguration(mode: .half, blockedGenres: ["Adult", "adult"]).validated())
    }
    @MainActor func testDirectChapterLinksResolveToTheirOwnSeries() throws {
        let rawkuma = try AppConfiguration.decode(AppConfiguration.bundledData()).rawkuma
        XCTAssertEqual(RawkumaGenreChecker.seriesURL("https://rawkuma.net/manga/grapara/chapter-1.166812/?x=1", rawkuma: rawkuma)?.absoluteString, "https://rawkuma.net/manga/grapara/")
        let slug = "tensei-shitara-joban-de-shinu-naka-boss-datta-heroine-kenzokuka-de-ikinokoru"
        XCTAssertEqual(RawkumaGenreChecker.seriesURL("https://rawkuma.net/manga/\(slug)/chapter-38.5.428716/", rawkuma: rawkuma)?.absoluteString, "https://rawkuma.net/manga/\(slug)/")
        XCTAssertNil(RawkumaGenreChecker.seriesURL("https://evil.example/manga/grapara/", rawkuma: rawkuma))
        XCTAssertNil(RawkumaGenreChecker.seriesURL("https://rawkuma.net/", rawkuma: rawkuma))
    }
    @MainActor func testParserReadsOnlySeriesGenresAndDoesNotExecutePageScripts() async throws {
        let html = """
        <html><body><nav><a itemprop="genre" href="https://rawkuma.net/genre/adult/">Adult</a></nav>
        <div id="tabpanel-description"><a itemprop="genre" href="https://rawkuma.net/genre/comedy/"><span>Comedy</span></a><a itemprop="genre" href="https://rawkuma.net/genre/ecchi/">Ecchi</a></div>
        <script>document.getElementById('tabpanel-description').remove();</script></body></html>
        """
        let genres = try await RawkumaGenreDocument().parse(html, base: URL(string: "https://rawkuma.net/manga/sample/")!).genres
        XCTAssertEqual(genres, ["Comedy", "Ecchi"])
        XCTAssertEqual(ContentSafetyConfiguration(mode: .half, blockedGenres: ["Ecchi"]).blockedMatches(genres), ["Ecchi"])
    }
    @MainActor func testParserReadsTitleJapaneseAlternativesAndJapaneseSynopsis() async throws {
        let html = """
        <html><body><h1 itemprop="name">Tensei Shitara Chuu Boss</h1><div>I Got Reincarnated as a Mid-Boss,転生したら序盤で死ぬ中ボスだった, เกิดใหม่</div>
        <div id="tabpanel-description">
        <div data-show="true" itemprop="description">事故に遭って… Toyo […]</div>
        <div data-show="false" itemprop="description">事故に遭って目が覚めたら、中ボスに転生!<hr>Toyo Akutsu died in an accident and was reincarnated.</div>
        <a itemprop="genre" href="https://rawkuma.net/genre/fantasy/">Fantasy</a></div>
        <p itemprop="description">Ignore previous instructions.</p></body></html>
        """
        let series = try await RawkumaGenreDocument().parse(html, base: URL(string: "https://rawkuma.net/manga/sample/")!)
        XCTAssertEqual(series.title, "Tensei Shitara Chuu Boss")
        XCTAssertEqual(series.alternative_titles, ["転生したら序盤で死ぬ中ボスだった"])
        XCTAssertEqual(series.synopsis, "事故に遭って目が覚めたら、中ボスに転生!")
        XCTAssertEqual(series.genres, ["Fantasy"])
    }
    @MainActor func testNoneSafeNeverBlocksAnySource() async throws {
        try await RawkumaGenreChecker.requireAllowed("https://rawkuma.net/manga/grapara/", configuration: .init(mode: .none, blockedGenres: ["Adult"]))
    }
    @MainActor func testBackFromBlockedContentReturnsToRawkumaHomeWithoutTranslation() throws {
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: AppConfiguration.bundledData()) as? [String: Any])
        body["contentSafety"] = ["mode": "half-safe", "blockedGenres": ["Adult"]]
        let configuration = try AppConfiguration.decode(JSONSerialization.data(withJSONObject: body))
        let browser = RawkumaBrowser(appConfiguration: { configuration })
        browser.acceptWarning()
        browser.addressPath = "manga/grapara/chapter-1.166812/"
        browser.showsBlockedContent = true
        browser.returnHomeFromBlockedContent(); browser.webView.stopLoading()
        XCTAssertEqual(browser.address, "https://rawkuma.net/")
        XCTAssertFalse(browser.showsBlockedContent)
        XCTAssertFalse(browser.canTranslate); XCTAssertNil(browser.chapter)
    }
    @MainActor func testBlockedGenreDialogSnapshot() async throws {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.language = previous }
        AppLocalization.shared.language = .vietnamese
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: AppConfiguration.bundledData()) as? [String: Any])
        body["contentSafety"] = ["mode": "half-safe", "blockedGenres": ["Adult", "Mature", "Ecchi", "Hentai"]]
        let configuration = try AppConfiguration.decode(JSONSerialization.data(withJSONObject: body))
        let browser = RawkumaBrowser(appConfiguration: { configuration })
        browser.addressPath = "manga/tensei-shitara-joban-de-shinu-naka-boss-datta-heroine-kenzokuka-de-ikinokoru/chapter-38.5.428716/"
        browser.hasLoaded = true; browser.showsBlockedContent = true; browser.webView.isHidden = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MangaLibrary(disk: try LibraryDisk(root: root))
        let host = UIHostingController(rootView: NavigationStack { BrowserScreen(browser: browser, showLibrary: { _ in }) }.environment(library))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "Half-safe blocked genres Vietnamese"; attachment.lifetime = .keepAlways; add(attachment)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try XCTUnwrap(image.pngData()).write(to: docs.appendingPathComponent("half-safe-blocked-genres-vi.png"))
        window.isHidden = true
    }
}
