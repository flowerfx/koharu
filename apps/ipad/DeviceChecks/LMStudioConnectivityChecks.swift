import XCTest
@testable import KoharuPad

final class LMStudioConnectivityChecks: XCTestCase {
    // Install a LAN HTTP fixture and its endpoint file before running this on
    // a fresh app identity. Grant the system LAN prompt after several seconds
    // to exercise the request that originally failed during authorization.
    func testFirstLANDiscoveryContinuesAfterPermission() async throws {
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let evidence = documents.appendingPathComponent("LMStudioChecks")
        let fixture = evidence.appendingPathComponent("endpoint.txt")
        guard let text = try? String(contentsOf: fixture, encoding: .utf8) else {
            throw XCTSkip("Install the LAN model-list fixture and endpoint.txt first")
        }
        let endpoint = try LMStudio.baseURL(text)
        let started = Date()
        let servers = try await LMStudio.discover(port: try XCTUnwrap(endpoint.port))
        let server = try XCTUnwrap(servers.first { $0.url == endpoint.absoluteString })
        XCTAssertEqual(server.models, ["lan-permission-fixture"])
        let models = try await LMStudio.models(server.url)
        XCTAssertEqual(models, server.models)
        let result: [String: Any] = ["endpoint": server.url, "models": models,
                                     "firstDiscoverySucceeded": true,
                                     "secondsIncludingPermissionPrompt": Date().timeIntervalSince(started)]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("result.json"), options: .atomic)
    }
}
