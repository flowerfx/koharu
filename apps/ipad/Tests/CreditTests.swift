import XCTest
@testable import KoharuPad

final class CreditTests: XCTestCase {
    private func policyData() throws -> Data {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: AppConfiguration.bundledData()) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: XCTUnwrap(root["credit"]))
    }
    func testServerProfileDecodesUTCAndNullableSubscriptionExpiry() throws {
        let policy = try policyData()
        let body = """
        {"revision":7,"profile":{"id":"33fa303e-757c-4c32-b1a3-61225a18b590","credit":100,"account_type":"premium","reset_daily_reward":"2026-11-03 00:00:00","next_subscription_date":"2026-12-02 09:20:30"},"policy":\(String(decoding: policy, as: UTF8.self)),"server_time":"2026-11-02 09:20:30","can_claim_daily":false,"video_access":{}}
        """
        let response = try CreditResponse.decoder().decode(CreditResponse.self, from: Data(body.utf8))
        XCTAssertEqual(response.profile.reset_daily_reward.ISO8601Format(), "2026-11-03T00:00:00Z")
        XCTAssertEqual(response.profile.next_subscription_date?.ISO8601Format(), "2026-12-02T09:20:30Z")
        XCTAssertEqual(response.profile.account_type, .premium)
        XCTAssertEqual(response.revision, 7)
        let free = body.replacingOccurrences(of: "\"2026-12-02 09:20:30\"", with: "null")
        XCTAssertNil(try CreditResponse.decoder().decode(CreditResponse.self, from: Data(free.utf8)).profile.next_subscription_date)
    }
    @MainActor func testUnauthenticatedStoreCannotGrantCreditsOrPremium() async throws {
        let account = CreditStore(authentication: NakamaAuthentication(), policy: try AppConfiguration.decode(AppConfiguration.bundledData()).credit)
        XCTAssertFalse(account.loaded)
        XCTAssertFalse(account.canAfford(0, action: .image))
        do { try await account.claimDaily(); XCTFail("Authentication is required") } catch { }
        XCTAssertEqual(account.profile.credit, 0)
        XCTAssertEqual(account.tier, .free)
        account.clear()
        XCTAssertFalse(account.loaded)
    }
    func testTierCostsProviderRestrictionsAndInvalidConfiguration() throws {
        let config = try AppConfiguration.decode(AppConfiguration.bundledData()).credit
        XCTAssertEqual(config.cost(.enhance, tier: .free), 2)
        XCTAssertEqual(config.cost(.enhance, tier: .premium), 1)
        XCTAssertEqual(config.cost(.image, tier: .premium), 0)
        XCTAssertEqual(config.cost(.image, tier: .free), 1)
        XCTAssertEqual(config.cost(.translate, tier: .free), 1)
        XCTAssertEqual(config.cost(.translate, tier: .premium), 1)
        XCTAssertEqual(config.cost(.generatePrompt, tier: .free), 1)
        XCTAssertEqual(config.cost(.generatePrompt, tier: .premium), 1)
        XCTAssertTrue(CreditTier.free.allows(.local))
        XCTAssertTrue(CreditTier.free.allows(.backend))
        XCTAssertFalse(CreditTier.free.allows(.gemini))
        XCTAssertTrue(TranslationProvider.allCases.allSatisfy(CreditTier.premium.allows))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: policyData()) as? [String: Any])
        object["cost_api_prompt"] = -1
        XCTAssertThrowsError(try CreditConfiguration.decode(JSONSerialization.data(withJSONObject: object)))
    }
    @MainActor func testImportAndRerunPricingUseSeparatePolicyFields() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: policyData()) as? [String: Any])
        object["cost_translate"] = 3
        object["cost_api_prompt"] = 7
        let config = try CreditConfiguration.decode(JSONSerialization.data(withJSONObject: object))
        for tier in CreditTier.allCases { XCTAssertEqual(config.cost(.translate, tier: tier), 3) }
        for provider in TranslationProvider.allCases {
            XCTAssertEqual(config.rerunCost(provider: provider), provider == .backend ? 7 : 0)
        }
    }
}
