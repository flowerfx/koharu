import XCTest
@testable import KoharuPad

final class NakamaProfileChecks: XCTestCase {
    @MainActor func testProfileLivesOnSharedBackend() async throws {
        let (connection, certificate) = try NakamaConnection.configured(AppConfiguration.current.server.endpoint)
        let client = NakamaClient(connection: connection, certificate: certificate)
        let session = try await client.device(UUID().uuidString + UUID().uuidString)
        let account = try await client.account(session)
        func command(_ name: String, _ payload: [String: Any] = [:], session: NakamaSession) async throws -> CreditResponse {
            let body = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            let result = try await client.rpc(name, payload: body, auth: session)
            return try CreditResponse.decoder().decode(CreditResponse.self, from: Data(result.utf8))
        }
        let first = try await command("profile_load", session: session)
        XCTAssertEqual(first.profile.id.uuidString.lowercased(), account.user.id.lowercased())
        XCTAssertEqual(first.profile.credit, 0)
        XCTAssertEqual(first.profile.account_type, .free)
        XCTAssertNil(first.profile.next_subscription_date)
        let operation = UUID().uuidString
        let claimed = try await command("profile_daily", ["operation_id": operation], session: session)
        let retried = try await command("profile_daily", ["operation_id": operation], session: session)
        XCTAssertEqual(claimed.profile.credit, first.policy.daily_free_user)
        XCTAssertEqual(retried.profile.credit, claimed.profile.credit)
        let refreshed = try await client.refresh(session)
        let restored = try await command("profile_load", session: refreshed)
        XCTAssertEqual(restored.profile.id, first.profile.id)
        XCTAssertEqual(restored.profile.credit, claimed.profile.credit)
        XCTAssertGreaterThan(restored.revision, claimed.revision)
        let report: [String: Any] = [
            "environment": try ConfigurationTarget(bundle: .main).environment.rawValue,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "endpoint": connection.endpoint.absoluteString,
            "cloudProfile": true, "dailyClaimIdempotent": true, "restoredCloudBalance": true,
            "resetUTC": restored.profile.reset_daily_reward.ISO8601Format(),
            "subscriptionTransactionPerformed": false
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Nakama cloud profile"
        attachment.lifetime = .keepAlways
        add(attachment)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try data.write(to: documents.appendingPathComponent("nakama-profile-check.json"))
    }
}
