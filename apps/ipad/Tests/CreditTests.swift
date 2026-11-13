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
        {"revision":7,"profile":{"id":"33fa303e-757c-4c32-b1a3-61225a18b590","credit":100,"account_type":"premium","reset_daily_reward":"2026-11-03 00:00:00","next_subscription_date":"2026-12-02 09:20:30"},"policy":\(String(decoding: policy, as: UTF8.self)),"server_time":"2026-11-02 09:20:30","can_claim_daily":false,"daily_video_available":true,"daily_video_bonus":100,"video_access":{}}
        """
        let response = try CreditResponse.decoder().decode(CreditResponse.self, from: Data(body.utf8))
        XCTAssertEqual(response.profile.reset_daily_reward.ISO8601Format(), "2026-11-03T00:00:00Z")
        XCTAssertEqual(response.profile.next_subscription_date?.ISO8601Format(), "2026-12-02T09:20:30Z")
        XCTAssertEqual(response.profile.account_type, .premium)
        XCTAssertEqual(response.revision, 7)
        XCTAssertTrue(response.daily_video_available)
        XCTAssertEqual(response.daily_video_bonus, 100)
        let free = body.replacingOccurrences(of: "\"2026-12-02 09:20:30\"", with: "null")
        XCTAssertNil(try CreditResponse.decoder().decode(CreditResponse.self, from: Data(free.utf8)).profile.next_subscription_date)
    }
    @MainActor func testUnauthenticatedStoreCannotGrantCreditsOrPremium() async throws {
        let account = CreditStore(authentication: NakamaAuthentication(), policy: try AppConfiguration.decode(AppConfiguration.bundledData()).credit)
        XCTAssertFalse(account.loaded)
        XCTAssertFalse(account.canAfford(0, operation: CreditOperation(action: .image, provider: .local, rerun: false)))
        do { try await account.claimDaily(); XCTFail("Authentication is required") } catch { }
        XCTAssertEqual(account.profile.credit, 0)
        XCTAssertEqual(account.tier, .free)
        account.clear()
        XCTAssertFalse(account.loaded)
    }
    func testCompleteFreePremiumProviderPriceMatrix() throws {
        let config = try AppConfiguration.decode(AppConfiguration.bundledData()).credit
        for provider in TranslationProvider.allCases {
            let backend = provider == .backend
            XCTAssertEqual(config.cost(.translate, tier: .free, provider: provider), backend ? 2 : 1)
            XCTAssertEqual(config.cost(.translate, tier: .premium, provider: provider), backend ? 1 : 0)
            XCTAssertEqual(config.rerunCost(provider: provider), backend ? 1 : 0)
            XCTAssertEqual(config.cost(.image, tier: .free, provider: provider), 1)
            XCTAssertEqual(config.cost(.image, tier: .premium, provider: provider), 0)
            XCTAssertEqual(config.cost(.enhance, tier: .free, provider: provider), backend ? 2 : 1)
            XCTAssertEqual(config.cost(.enhance, tier: .premium, provider: provider), backend ? 1 : 0)
            for tier in CreditTier.allCases { XCTAssertEqual(config.cost(.generatePrompt, tier: tier, provider: provider), 1) }
            // Enhanced translation is always two backend passes, whatever provider is selected.
            XCTAssertEqual(config.cost(.translateEnhanced, tier: .free, provider: provider), 4)
            XCTAssertEqual(config.cost(.translateEnhanced, tier: .premium, provider: provider), 2)
        }
        XCTAssertTrue(CreditTier.free.allows(.local))
        XCTAssertTrue(CreditTier.free.allows(.backend))
        XCTAssertFalse(CreditTier.free.allows(.gemini))
        XCTAssertTrue(TranslationProvider.allCases.allSatisfy(CreditTier.premium.allows))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: policyData()) as? [String: Any])
        object["cost_backend_surcharge"] = -1
        XCTAssertThrowsError(try CreditConfiguration.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testInitialTranslationAndRerunHaveIndependentConfigurableFees() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: policyData()) as? [String: Any])
        object["cost_translate_free"] = 3
        object["cost_translate_premium"] = 2
        object["cost_backend_surcharge"] = 4
        object["cost_rerun_backend"] = 7
        let config = try CreditConfiguration.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(config.cost(.translate, tier: .free, provider: .backend), 7)
        XCTAssertEqual(config.cost(.translate, tier: .premium, provider: .backend), 6)
        XCTAssertEqual(config.cost(.translate, tier: .free, provider: .local), 3)
        for provider in TranslationProvider.allCases {
            XCTAssertEqual(config.rerunCost(provider: provider), provider == .backend ? 7 : 0)
        }
    }
}
