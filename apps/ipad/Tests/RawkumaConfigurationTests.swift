import XCTest
@testable import KoharuPad

final class RawkumaConfigurationTests: XCTestCase {
    private func config(_ rawkuma: Any?, mode: String = "half-safe") throws -> AppConfiguration {
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: AppConfiguration.bundledData()) as? [String: Any])
        body["rawkuma"] = rawkuma
        var safety = try XCTUnwrap(body["contentSafety"] as? [String: Any]); safety["mode"] = mode; body["contentSafety"] = safety
        return try AppConfiguration.decode(JSONSerialization.data(withJSONObject: body))
    }
    func testMissingNullAndBlankSourceDisableRawkumaInEveryMode() throws {
        for mode in ["half-safe", "none-safe", "full-safe"] {
            for value in [nil, NSNull(), [:], ["url": NSNull()], ["url": ""], ["url": " \n "]] as [Any?] {
                let configuration = try config(value, mode: mode)
                XCTAssertFalse(configuration.allowsRawkuma)
                XCTAssertNil(configuration.rawkuma?.url)
            }
        }
        XCTAssertTrue(try config(["url": "https://manga.example/"]).allowsRawkuma)
        XCTAssertFalse(try config(["url": "https://manga.example/"], mode: "full-safe").allowsRawkuma)
    }
    func testConfiguredOriginControlsPathsAndRejectsForeignOrAmbiguousURLs() throws {
        let rawkuma = try XCTUnwrap(config(["url": "https://manga.example"]).rawkuma)
        XCTAssertEqual(rawkuma.url?.absoluteString, "https://manga.example/")
        let path = "manga/example/chapter-38.5/?language=ja#page-2"
        XCTAssertEqual(rawkuma.address(forPath: path)?.absoluteString, "https://manga.example/" + path)
        XCTAssertEqual(rawkuma.address(forPath: "/" + path), rawkuma.address(forPath: path))
        XCTAssertEqual(rawkuma.path(from: "https://manga.example/" + path), path)
        XCTAssertEqual(rawkuma.path(from: "https://manga.example/manga/a%20b/"), "manga/a%20b/")
        for value in ["https://evil.example/path", "//evil.example/path", "\\\\evil.example/path", "https://manga.example@evil.example/", "http://manga.example/"] {
            XCTAssertNil(rawkuma.address(forPath: value), value)
        }
        for value in ["https://rawkuma.net/", "https://manga.example.evil.test/", "https://user@manga.example/", "https://manga.example:443/", "http://manga.example/"] {
            XCTAssertFalse(rawkuma.contains(value), value)
        }
        for value in ["http://manga.example", "https://user@manga.example", "https://manga.example:444", "https://manga.example/manga/", "https://manga.example/?q=test", "https://manga.example/#test"] {
            XCTAssertThrowsError(try config(["url": value]), value)
        }
    }
    @MainActor func testDisabledSourceDoesNotLoadAndCustomDomainResolvesParentSeries() throws {
        let disabled = try config(["url": NSNull()])
        let browser = RawkumaBrowser(appConfiguration: { disabled })
        browser.go("https://rawkuma.net/manga/example/")
        XCTAssertFalse(browser.hasLoaded); XCTAssertFalse(browser.showsWarning)
        let rawkuma = try config(["url": "https://manga.example/"]).rawkuma
        XCTAssertEqual(RawkumaGenreChecker.seriesURL("https://manga.example/manga/example/chapter-38.5/?x=1", rawkuma: rawkuma)?.absoluteString,
                       "https://manga.example/manga/example/")
        XCTAssertNil(RawkumaGenreChecker.seriesURL("https://rawkuma.net/manga/example/", rawkuma: rawkuma))
    }
    @MainActor func testHalfModeAllowsLocalImportsButDoesNotSkipChecksForUnknownSavedSources() async throws {
        let configuration = try config(["url": "https://manga.example/"])
        try await RawkumaGenreChecker.requireAllowed("imported://test/page-1", configuration: configuration.contentSafety, rawkuma: configuration.rawkuma)
        do {
            try await RawkumaGenreChecker.requireAllowed("https://other.example/manga/test/", configuration: configuration.contentSafety, rawkuma: configuration.rawkuma)
            XCTFail("Unknown external sources must fail closed before credits or translation")
        } catch RawkumaGenreFailure.unavailable {}
    }
}
