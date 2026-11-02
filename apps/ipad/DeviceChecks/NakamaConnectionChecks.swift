import XCTest
@testable import KoharuPad

final class NakamaConnectionChecks: XCTestCase {
    @MainActor func testBundledBackendAuthenticatesAndRestoresSession() async throws {
        let (connection, certificate) = try NakamaConnection.bundled()
        let client = NakamaClient(connection: connection, certificate: certificate)
        // An isolated smoke identity leaves the user's Keychain session alone.
        let session = try await client.device(UUID().uuidString + UUID().uuidString)
        let first = try await client.account(session)
        let refreshed = try await client.refresh(session)
        let restored = try await client.account(refreshed)
        XCTAssertEqual(first.user.id, restored.user.id)
        let challenge = try await client.challenge(refreshed)
        XCTAssertTrue(challenge.usable)
        XCTAssertEqual(challenge.user_id, first.user.id)
        let report: [String: Any] = [
            "environment": try ConfigurationTarget(bundle: .main).environment.rawValue,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "endpoint": connection.endpoint.absoluteString,
            "allowedBundleIDs": connection.apple_bundle_ids,
            "deviceAuthentication": true,
            "sessionRefresh": true,
            "accountRestoration": first.user.id == restored.user.id,
            "appleNonce": challenge.usable,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Shared backend authentication"
        attachment.lifetime = .keepAlways
        add(attachment)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try data.write(to: documents.appendingPathComponent("backend-auth-check.json"))
    }
}
