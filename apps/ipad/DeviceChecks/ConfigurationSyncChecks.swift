import XCTest
@testable import KoharuPad

private final class ConfigurationHTTP: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var headers: [String: String] = [:]; let data: Data }
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> Reply)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = Self.lock.withLock { Self.handler }
            let reply = try XCTUnwrap(handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class ConfigurationSyncChecks: XCTestCase {
    private let date1 = "2026-11-02T02:37:09.000Z"
    private let date2 = "2026-11-02T02:37:10.000Z"
    private func listing(_ target: ConfigurationTarget, etag: String, date: String, size: Int, continuation: String? = nil) -> Data {
        let escaped = etag.replacingOccurrences(of: "\"", with: "&quot;")
        let extra = continuation.map { "<NextContinuationToken>\($0)</NextContinuationToken>" } ?? ""
        return Data("<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><IsTruncated>\(continuation != nil)</IsTruncated>\(extra)<Contents><Key>\(target.key)</Key><ETag>\(escaped)</ETag><LastModified>\(date)</LastModified><Size>\(size)</Size></Contents></ListBucketResult>".utf8)
    }
    private func session(_ handler: @escaping (URLRequest) throws -> ConfigurationHTTP.Reply) -> URLSession {
        ConfigurationHTTP.lock.withLock { ConfigurationHTTP.handler = handler }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ConfigurationHTTP.self]
        return URLSession(configuration: config)
    }
    private func changedData() throws -> Data {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: AppConfiguration.bundledData()) as? [String: Any])
        var providers = value["provider"] as! [[String: Any]]
        providers.firstIndex { $0["id"] as? String == "lmStudio" }.map { providers[$0]["enable"] = false }
        value["provider"] = providers
        return try JSONSerialization.data(withJSONObject: value)
    }
    private func body(_ data: Data, etag: String, date: String) -> ConfigurationHTTP.Reply {
        let http = date == date1 ? "Mon, 02 Nov 2026 02:37:09 GMT" : "Mon, 02 Nov 2026 02:37:10 GMT"
        return .init(headers: ["ETag": etag, "Last-Modified": http], data: data)
    }

    @MainActor func testDownloadPublishRelaunchAndUnchangedListingSkipsBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try ConfigurationTarget(environment: .staging, version: "1.0.0")
        let remote = try changedData()
        var downloads = 0
        let session = session { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            if query?.contains(where: { $0.name == "list-type" && $0.value == "2" }) == true {
                XCTAssertEqual(query?.first { $0.name == "prefix" }?.value, target.prefix)
                return .init(data: self.listing(target, etag: "\"v1\"", date: self.date1, size: remote.count))
            }
            downloads += 1
            XCTAssertEqual(request.url, target.objectURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"v1\"")
            return self.body(remote, etag: "\"v1\"", date: self.date1)
        }
        defer { session.invalidateAndCancel() }
        let client = ConfigurationClient(session: session)
        let store = try ConfigurationStore(target: target, root: root, bundled: AppConfiguration.bundledData(), client: client)
        await store.refresh()
        XCTAssertEqual(store.status, .updated)
        XCTAssertFalse(store.configuration.providers.contains(.lmStudio))
        XCTAssertEqual(try Data(contentsOf: store.activeFile), remote)
        let reopened = try ConfigurationStore(target: target, root: root, bundled: AppConfiguration.bundledData(), client: client)
        XCTAssertEqual(reopened.status, .saved)
        await reopened.refresh()
        XCTAssertEqual(reopened.status, .unchanged)
        XCTAssertEqual(downloads, 1)
    }

    @MainActor func testEitherValidatorChangingDownloadsAndInvalidOrOfflineKeepsLastGood() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try ConfigurationTarget(environment: .staging, version: "1.0.0")
        var payload = try changedData(), etag = "\"v1\"", date = date1
        var downloads = 0, offline = false
        let session = session { request in
            if offline { throw URLError(.notConnectedToInternet) }
            if request.url?.query != nil { return .init(data: self.listing(target, etag: etag, date: date, size: payload.count)) }
            downloads += 1; return self.body(payload, etag: etag, date: date)
        }
        defer { session.invalidateAndCancel() }
        let client = ConfigurationClient(session: session)
        let store = try ConfigurationStore(target: target, root: root, bundled: AppConfiguration.bundledData(), client: client)
        await store.refresh()
        etag = "\"v2\""; await store.refresh()
        XCTAssertEqual(downloads, 2)
        date = date2; await store.refresh()
        XCTAssertEqual(downloads, 3)
        let valid = try Data(contentsOf: store.activeFile)
        let active = store.activeFile
        payload = Data("{}".utf8); etag = "\"invalid\""; await store.refresh()
        XCTAssertEqual(store.status, .failed)
        XCTAssertEqual(store.activeFile, active)
        XCTAssertEqual(try Data(contentsOf: active), valid)
        offline = true; await store.refresh()
        XCTAssertEqual(store.status, .failed)
        let reopened = try ConfigurationStore(target: target, root: root, bundled: AppConfiguration.bundledData(), client: client)
        XCTAssertEqual(reopened.etag, "\"v2\"")
        XCTAssertEqual(try Data(contentsOf: reopened.activeFile), valid)
    }

    @MainActor func testEnvironmentVersionIsolationAndRecoveryFromDamagedActiveSlot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try ConfigurationTarget(environment: .staging, version: "1.0.0")
        let data = try changedData()
        let session = session { request in
            request.url?.query != nil ? .init(data: self.listing(target, etag: "\"v1\"", date: self.date1, size: data.count)) : self.body(data, etag: "\"v1\"", date: self.date1)
        }
        defer { session.invalidateAndCancel() }
        let store = try ConfigurationStore(target: target, root: root, bundled: AppConfiguration.bundledData(), client: ConfigurationClient(session: session))
        await store.refresh()
        for target in [try ConfigurationTarget(environment: .production, version: "1.0.0"), try ConfigurationTarget(environment: .staging, version: "1.0.1")] {
            let other = try ConfigurationStore(target: target, root: root, bundled: AppConfiguration.bundledData())
            XCTAssertNil(other.etag)
            XCTAssertNotEqual(other.directory, store.directory)
            XCTAssertTrue(other.configuration.providers.contains(.lmStudio))
        }
        try Data("broken".utf8).write(to: store.activeFile)
        let recovered = try ConfigurationStore(target: target, root: root, bundled: AppConfiguration.bundledData())
        XCTAssertTrue(recovered.configuration.providers.contains(.lmStudio))
        XCTAssertNil(recovered.etag)
    }

    @MainActor func testPaginatedListAndMetadataRaceDoNotPublishUnverifiedBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try ConfigurationTarget(environment: .staging, version: "1.0.0")
        let data = try changedData()
        var pages = 0
        let session = session { request in
            if request.url?.query != nil {
                pages += 1
                let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "continuation-token" }?.value
                if token == nil { return .init(data: Data("<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>next&amp;page</NextContinuationToken></ListBucketResult>".utf8)) }
                XCTAssertEqual(token, "next&page")
                return .init(data: self.listing(target, etag: "\"listed\"", date: self.date1, size: data.count))
            }
            return self.body(data, etag: "\"different\"", date: self.date1)
        }
        defer { session.invalidateAndCancel() }
        let store = try ConfigurationStore(target: target, root: root, bundled: AppConfiguration.bundledData(), client: ConfigurationClient(session: session))
        let initial = try Data(contentsOf: store.activeFile)
        await store.refresh()
        XCTAssertEqual(pages, 2)
        XCTAssertEqual(store.status, .failed)
        XCTAssertEqual(try Data(contentsOf: store.activeFile), initial)
    }

    func testMalformedListAndUnsafeVersionFailClosed() throws {
        XCTAssertThrowsError(try ConfigurationListing.parse(Data("<ListBucketResult>".utf8)))
        XCTAssertThrowsError(try ConfigurationListing.parse(Data("<Error/>".utf8)))
        XCTAssertThrowsError(try ConfigurationListing.parse(Data("<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>".utf8)))
        XCTAssertThrowsError(try ConfigurationTarget(environment: .staging, version: "../production"))
    }
}
