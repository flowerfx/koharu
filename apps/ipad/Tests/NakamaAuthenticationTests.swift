import XCTest
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
}
