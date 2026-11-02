import Foundation
import Observation
import CryptoKit

struct ConfigurationTarget: Equatable, Sendable {
    enum Environment: String, Sendable { case staging, production }
    let environment: Environment
    let version: String
    static let bucket = URL(string: "https://kem-solution-public.s3.us-east-1.amazonaws.com")!
    var prefix: String { "apps/aimangatranslator/env/\(environment.rawValue)/\(version)/configs/" }
    var key: String { prefix + "app-config.json" }
    var objectURL: URL { Self.bucket.appendingPathComponent(key) }
    var signatureURL: URL { Self.bucket.appendingPathComponent(key + ".sig") }
    init(environment: Environment, version: String) throws {
        guard version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else { throw ConfigurationSyncError.invalidTarget }
        self.environment = environment; self.version = version
    }
    init(bundle: Bundle) throws {
        guard let name = bundle.object(forInfoDictionaryKey: "KoharuEnvironment") as? String,
              let environment = Environment(rawValue: name),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { throw ConfigurationSyncError.invalidTarget }
        try self.init(environment: environment, version: version)
    }
    func listURL(continuation: String? = nil) -> URL {
        var url = URLComponents(url: Self.bucket, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "list-type", value: "2"), URLQueryItem(name: "prefix", value: prefix), URLQueryItem(name: "max-keys", value: "1000")]
        if let continuation { url.queryItems?.append(URLQueryItem(name: "continuation-token", value: continuation)) }
        return url.url!
    }
}

enum ConfigurationSyncError: Error {
    case invalidTarget, invalidListing, missingObject, invalidResponse, oversized, changedDuringDownload, invalidSignature
}

// Remote app-config.json can redirect model downloads, so a build that bundles
// a public key (KoharuConfigSigningKey, base64 raw Ed25519) only accepts a remote
// configuration accompanied by app-config.json.sig: a base64 Ed25519 signature
// over the exact bytes. scripts/sign_config.py creates keys and signatures.
// Builds without a key keep the previous unsigned behaviour.
enum ConfigurationSignature {
    static var publicKey: Curve25519.Signing.PublicKey? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "KoharuConfigSigningKey") as? String,
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }
    static func verify(_ body: Data, signature: Data, key: Curve25519.Signing.PublicKey) throws {
        guard let text = String(data: signature, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(raw, for: body) else { throw ConfigurationSyncError.invalidSignature }
    }
}

struct ConfigurationObject: Equatable, Sendable {
    let key: String
    let etag: String
    let modified: Date
    let size: Int
}

// S3 folder URLs are object keys, not directory listings. ListObjectsV2 is
// called on the bucket root with the exact environment/version prefix.
final class ConfigurationListing: NSObject, XMLParserDelegate {
    private var inObject = false
    private var values: [String: String] = [:]
    private var root = false
    private var invalid = false
    private(set) var objects: [ConfigurationObject] = []
    private(set) var continuation: String?
    private var truncated = false
    private var text = ""
    static func parse(_ data: Data) throws -> ConfigurationListing {
        let listing = ConfigurationListing()
        let parser = XMLParser(data: data); parser.delegate = listing
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), listing.root, !listing.invalid,
              !listing.truncated || listing.continuation?.isEmpty == false else { throw ConfigurationSyncError.invalidListing }
        return listing
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "ListBucketResult" { root = true }
        if name == "Contents" { inObject = true; values = [:] }
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if inObject && ["Key", "ETag", "LastModified", "Size"].contains(name) { values[name] = text }
        if name == "IsTruncated" { truncated = text == "true" }
        if name == "NextContinuationToken" { continuation = text }
        if name == "Contents" {
            inObject = false
            guard let key = values["Key"], let etag = values["ETag"], !etag.isEmpty,
                  let raw = values["LastModified"], let modified = Self.date(raw),
                  let size = values["Size"].flatMap(Int.init), size >= 0 else { invalid = true; return }
            objects.append(ConfigurationObject(key: key, etag: etag, modified: modified, size: size))
        }
        text = ""
    }
    static func date(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value)
    }
    static func httpDate(_ value: String) -> Date? {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return format.date(from: value)
    }
}

actor ConfigurationClient {
    private let session: URLSession
    private let signingKey: Curve25519.Signing.PublicKey?
    init(session: URLSession? = nil, signingKey: Curve25519.Signing.PublicKey? = ConfigurationSignature.publicKey) {
        self.signingKey = signingKey
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: config, delegate: RedirectBoundary { $0.scheme == "https" && $0.host == ConfigurationTarget.bucket.host }, delegateQueue: nil)
        }
    }
    private func read(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ConfigurationSyncError.invalidResponse }
        guard response.expectedContentLength <= limit else { throw ConfigurationSyncError.oversized }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ConfigurationSyncError.oversized }
            data.append(byte)
        }
        return (data, http)
    }
    func fetch(target: ConfigurationTarget, etag: String?, modified: Date?) async throws -> (Data, ConfigurationObject)? {
        let deadline = Date().addingTimeInterval(15)
        var continuation: String?
        var seen = Set<String>()
        for _ in 0..<8 {
            var request = URLRequest(url: target.listURL(continuation: continuation), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(0.1, deadline.timeIntervalSinceNow))
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, _) = try await read(request, limit: 2_097_152)
            let listing = try ConfigurationListing.parse(data)
            if let object = listing.objects.first(where: { $0.key == target.key }) {
                guard object.size > 0, object.size <= 2_097_152 else { throw ConfigurationSyncError.oversized }
                if etag == object.etag && modified == object.modified { return nil }
                guard Date() < deadline else { throw URLError(.timedOut) }
                var download = URLRequest(url: target.objectURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: deadline.timeIntervalSinceNow)
                // List comparison uses OR semantics: either validator changing
                // forces a body download, even if its ETag stayed the same.
                download.setValue(object.etag, forHTTPHeaderField: "If-Match")
                download.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                let (body, http) = try await read(download, limit: 2_097_152)
                guard body.count == object.size, http.value(forHTTPHeaderField: "ETag") == object.etag,
                      let date = http.value(forHTTPHeaderField: "Last-Modified").flatMap(ConfigurationListing.httpDate),
                      floor(date.timeIntervalSince1970) == floor(object.modified.timeIntervalSince1970) else { throw ConfigurationSyncError.changedDuringDownload }
                if let key = signingKey {
                    var signed = URLRequest(url: target.signatureURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(0.1, deadline.timeIntervalSinceNow))
                    signed.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    let (signature, _) = try await read(signed, limit: 1024)
                    try ConfigurationSignature.verify(body, signature: signature, key: key)
                }
                return (body, object)
            }
            guard let next = listing.continuation else { throw ConfigurationSyncError.missingObject }
            guard seen.insert(next).inserted, Date() < deadline else { throw ConfigurationSyncError.invalidListing }
            continuation = next
        }
        throw ConfigurationSyncError.invalidListing
    }
}

@Observable final class ConfigurationStore: @unchecked Sendable {
    enum Status: Equatable { case bundled, saved, checking, unchanged, updated, failed }
    private struct Record: Codable {
        let key: String
        let etag: String?
        let modified: Date?
        let checksum: String
    }
    static let shared = Result {
        try ConfigurationStore(target: ConfigurationTarget(bundle: .main),
                               root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Koharu/RemoteConfiguration"),
                               bundled: AppConfiguration.bundledData())
    }
    let target: ConfigurationTarget
    let directory: URL
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var snapshot: AppConfiguration
    @ObservationIgnored private var slot: Int
    @ObservationIgnored private var record: Record
    @ObservationIgnored private let client: ConfigurationClient
    @ObservationIgnored var refreshDeferred = false
    private(set) var status: Status
    private(set) var isRefreshing = false
    private(set) var lastChecked: Date?
    var configuration: AppConfiguration {
        access(keyPath: \.configuration)
        return lock.withLock { snapshot }
    }
    var activeFile: URL { directory.appendingPathComponent("\(slot)/app-config.json") }
    var etag: String? { record.etag }
    var modified: Date? { record.modified }
    var statusText: String {
        switch status {
        case .bundled: return L("Using bundled configuration")
        case .saved: return L("Using saved configuration")
        case .checking: return L("Checking configuration…")
        case .unchanged: return L("Configuration is up to date")
        case .updated: return L("Configuration updated")
        case .failed: return L("Could not refresh configuration. Using the last valid configuration.")
        }
    }
    init(target: ConfigurationTarget, root: URL, bundled: Data, client: ConfigurationClient = ConfigurationClient()) throws {
        let baseline = try AppConfiguration.decode(bundled)
        self.target = target; self.directory = root.appendingPathComponent(target.environment.rawValue).appendingPathComponent(target.version)
        self.client = client
        let pointer = directory.appendingPathComponent("active.json")
        let preferred = (try? JSONDecoder().decode(Int.self, from: Data(contentsOf: pointer))) ?? 0
        var loaded: (Int, Record, AppConfiguration)?
        for index in [preferred, 0, 1] where index == 0 || index == 1 {
            let folder = directory.appendingPathComponent(String(index))
            if let record = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: folder.appendingPathComponent("metadata.json"))),
               record.key == target.key, let data = try? Data(contentsOf: folder.appendingPathComponent("app-config.json")),
               digest(data) == record.checksum, let config = try? AppConfiguration.decode(data) {
                loaded = (index, record, config); break
            }
        }
        if let loaded {
            slot = loaded.0; record = loaded.1; snapshot = loaded.2
            status = record.etag == nil ? .bundled : .saved
        } else {
            // A validated bundled seed is the offline baseline. Remote JSON is
            // never allowed to replace it until validation and publication pass.
            snapshot = baseline; slot = 1
            record = Record(key: target.key, etag: nil, modified: nil, checksum: "")
            status = .bundled
            try publish(bundled, object: nil, configuration: baseline)
        }
    }
    private func publish(_ data: Data, object: ConfigurationObject?, configuration: AppConfiguration) throws {
        let next = 1 - slot
        let folder = directory.appendingPathComponent(String(next))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metadata = Record(key: target.key, etag: object?.etag, modified: object?.modified, checksum: digest(data))
        try data.write(to: folder.appendingPathComponent("app-config.json"), options: .atomic)
        try JSONEncoder().encode(metadata).write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
        // This pointer is the sole commit point; interrupted writes only touch
        // the inactive slot. The previous valid generation remains recoverable.
        try JSONEncoder().encode(next).write(to: directory.appendingPathComponent("active.json"), options: .atomic)
        slot = next; record = metadata
        withMutation(keyPath: \.configuration) { lock.withLock { snapshot = configuration } }
    }
    @MainActor func refresh(canApply: () -> Bool = { true }) async {
        guard !isRefreshing else { return }
        guard canApply() else { refreshDeferred = true; return }
        let previousStatus = status
        refreshDeferred = false; isRefreshing = true; status = .checking
        defer { isRefreshing = false; lastChecked = Date() }
        do {
            if let (data, object) = try await client.fetch(target: target, etag: record.etag, modified: record.modified) {
                let config = try AppConfiguration.decode(data)
                try Task.checkCancellation()
                guard canApply() else { refreshDeferred = true; status = previousStatus; return }
                try publish(data, object: object, configuration: config)
                status = .updated
            } else { status = .unchanged }
        } catch { status = .failed }
    }
}
