import XCTest
@testable import KoharuPad

final class ContentSafetyTests: XCTestCase {
    private func configuration(_ mode: String?) throws -> AppConfiguration {
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: AppConfiguration.bundledData()) as? [String: Any])
        body["contentSafety"] = mode.map { ["mode": $0, "blockedGenres": ["Adult", "Mature", "Ecchi", "Hentai"]] as [String: Any] }
        return try AppConfiguration.decode(JSONSerialization.data(withJSONObject: body))
    }
    @MainActor func testNoneModeDoesNotRequireBackendSignInButHalfAndFullFailClosed() async throws {
        let auth = NakamaAuthentication()
        let none = try configuration("none-safe")
        let safety = ContentSafety(authentication: auth, configuration: { none })
        try await safety.checkText("An unchecked prompt")
        XCTAssertFalse(safety.needsConsent)
        for mode in ["half-safe", "full-safe"] {
            let config = try configuration(mode)
            do { try await ContentSafety(authentication: auth, configuration: { config }).checkText("A flower garden"); XCTFail("Missing backend authentication must block the action") }
            catch ContentSafetyFailure.unavailable {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }
    func testUnknownOrMissingModeCannotTurnOffSafety() throws {
        for mode in [nil, "", "off", "non-safe"] as [String?] { XCTAssertThrowsError(try configuration(mode)) }
        XCTAssertEqual(try configuration("full-safe").contentSafety.mode, .full)
    }
    @MainActor func testHalfModeRequiresWarningBeforeLoadingRawkuma() throws {
        let config = try configuration("half-safe")
        let browser = RawkumaBrowser(appConfiguration: { config })
        browser.go("https://rawkuma.net/")
        XCTAssertTrue(browser.showsWarning); XCTAssertFalse(browser.hasLoaded)
        XCTAssertNil(browser.webView.url)
    }
    @MainActor func testFullModeBlocksRawkumaNavigationBeforeNetworkLoad() throws {
        XCTAssertEqual(AppConfiguration.current.contentSafety.mode, .full)
        let browser = RawkumaBrowser()
        browser.go("https://rawkuma.net/")
        XCTAssertFalse(browser.hasLoaded); XCTAssertNil(browser.chapter); XCTAssertTrue(browser.webView.isHidden)
    }
}
