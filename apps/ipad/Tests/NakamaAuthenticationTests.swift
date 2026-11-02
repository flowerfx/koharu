import XCTest
import SwiftUI
@testable import KoharuPad

final class NakamaAuthenticationTests: XCTestCase {
    func testCredentialsCannotBeSentToAnInsecureOrDifferentApplicationEndpoint() throws {
        let bundle = "com.kurubyInteractive.aimanga.staging"
        func connection(_ address: String, bundleID: String? = nil) -> NakamaConnection {
            NakamaConnection(endpoint: URL(string: address)!, server_key: "test-public-server-key", credential_namespace: "nakama:test-cluster", apple_bundle_ids: [bundleID ?? bundle])
        }
        XCTAssertNoThrow(try connection("https://192.168.31.23:8443").validate(bundleID: bundle))
        for address in ["http://192.168.31.23:8443", "https://user:password@localhost:8443", "https://localhost:8443/path", "https://localhost:8443?redirect=example.com", "https://localhost:8443#fragment"] {
            XCTAssertThrowsError(try connection(address).validate(bundleID: bundle))
        }
        XCTAssertThrowsError(try connection("https://localhost:8443", bundleID: "com.kurubyInteractive.aimanga").validate(bundleID: bundle))
    }

    func testSharedConnectionAcceptsBothAppsButRejectsUnknownOrDuplicateAudiences() throws {
        let production = "com.kurubyInteractive.aimanga", staging = production + ".staging"
        func connection(_ ids: [String]) -> NakamaConnection {
            NakamaConnection(endpoint: URL(string: "https://54.165.230.197")!, server_key: "test-public-server-key", credential_namespace: "nakama:test-cluster", apple_bundle_ids: ids)
        }
        let shared = connection([production, staging])
        XCTAssertNoThrow(try shared.validate(bundleID: production))
        XCTAssertNoThrow(try shared.validate(bundleID: staging))
        XCTAssertThrowsError(try shared.validate(bundleID: "unrelated.application"))
        for ids in [[], [production, production], [production, "invalid audience"]] {
            XCTAssertThrowsError(try connection(ids).validate(bundleID: production))
        }
    }
    func testSharedAppConfigRequiresAValidServerEvenDuringMaintenance() throws {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: AppConfiguration.bundledData()) as? [String: Any])
        for endpoint in ["http://192.0.2.10", "https://user:pass@example.com", "https://example.com/path", "https://example.com?token=x", "https://example.com#x", "https://example.com:0", "https://example.com:65536"] {
            value["server"] = ["active": false, "endpoint": endpoint]
            XCTAssertThrowsError(try AppConfiguration.decode(JSONSerialization.data(withJSONObject: value)))
        }
        value.removeValue(forKey: "server")
        XCTAssertThrowsError(try AppConfiguration.decode(JSONSerialization.data(withJSONObject: value)))
        value["server"] = ["active": false, "endpoint": "https://192.0.2.10:8443"]
        let offline = try AppConfiguration.decode(JSONSerialization.data(withJSONObject: value))
        XCTAssertFalse(offline.server.active)
        XCTAssertThrowsError(try offline.requireProvider(.backend))
    }

    @MainActor func testEndpointMigrationKeepsTheBundledAuthenticationIdentity() async throws {
        let first = URL(string: "https://192.0.2.10:8443")!, second = URL(string: "https://example.com:9443")!
        let (a, _) = try NakamaConnection.configured(first), (b, _) = try NakamaConnection.configured(second)
        XCTAssertEqual(a.endpoint, first); XCTAssertEqual(b.endpoint, second)
        XCTAssertTrue(a.server_key == b.server_key)
        XCTAssertTrue(a.credential_namespace == b.credential_namespace)
        let account = NakamaAuthentication()
        try await account.reconfigure(endpoint: first)
        XCTAssertEqual(account.endpoint, first.absoluteString)
        try await account.reconfigure(endpoint: second)
        XCTAssertEqual(account.endpoint, second.absoluteString)
        XCTAssertNil(account.user); XCTAssertNil(account.auth)
    }

    @MainActor func testMaintenanceSnapshot() async throws {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.language = previous }
        AppLocalization.shared.language = .vietnamese
        let host = UIHostingController(rootView: ServerMaintenanceScreen(refreshing: false, refresh: {})
            .environment(\.locale, AppLocalization.shared.locale))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "Server maintenance Vietnamese"; attachment.lifetime = .keepAlways; add(attachment)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try XCTUnwrap(image.pngData()).write(to: documents.appendingPathComponent("server-maintenance-vi.png"))
        window.isHidden = true
    }

}
