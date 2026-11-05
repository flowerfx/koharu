import Foundation
import ImageIO
import Security
import Darwin
import Network

enum Credentials {
    private static let service = Bundle.main.bundleIdentifier!
    static func read(_ account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String, _ account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.message(L("Could not save credential in Keychain")) }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AppError.message(L("Could not save credential in Keychain")) }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw AppError.message(L("Could not save credential in Keychain")) }
    }
}

final class RedirectBoundary: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowed: @Sendable (URL) -> Bool
    init(_ allowed: @escaping @Sendable (URL) -> Bool) { self.allowed = allowed }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(allowed) == true ? request : nil)
    }
}

actor SourceImages {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config, delegate: RedirectBoundary { SourceChapter.isImage($0.absoluteString) }, delegateQueue: nil)
    }()
    func fetch(url: String, referer: String, chapter: UUID, previous: MangaPage?, revalidate: Bool, disk: LibraryDisk) async throws -> MangaPage {
        guard SourceChapter.isImage(url), AppConfiguration.current.rawkuma?.contains(referer) == true, let address = URL(string: url) else { throw AppError.message(L("Invalid source image")) }
        let existing = previous.map { disk.pageURL(chapter, $0.original) }
        let cached = existing.map { FileManager.default.fileExists(atPath: $0.path) } == true
        if cached && !revalidate, let previous { return previous }
        var request = URLRequest(url: address)
        request.setValue("KoharuPad/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        if cached, let previous {
            if let etag = previous.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = previous.modified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse else { throw AppError.message(L("Invalid image response")) }
        if http.statusCode == 304, cached, let previous { return previous }
        guard http.statusCode == 200 else { throw AppError.message("HTTP \(http.statusCode): \(address.lastPathComponent)") }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 32 * 1024 * 1024 else { throw AppError.message(L("Image is invalid or too large for on-device processing")) }
        var page = try Self.store(Data(contentsOf: temporary, options: .mappedIfSafe), source: url, chapter: chapter, previous: previous, disk: disk)
        page.etag = http.value(forHTTPHeaderField: "ETag")
        page.modified = http.value(forHTTPHeaderField: "Last-Modified")
        return page
    }
    static func store(_ data: Data, source: String, chapter: UUID, previous: MangaPage? = nil, disk: LibraryDisk) throws -> MangaPage {
        guard !data.isEmpty, data.count <= 32 * 1024 * 1024,
              let image = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 30000, width * height <= 24_000_000 else {
            throw AppError.message(L("Image is invalid or too large for on-device processing"))
        }
        var bytes = data
        // Name by the source bytes so revalidation and de-duplication stay stable.
        let filename = digest(bytes) + ".image"
        // OCR crops and inpainting read raw pixels, while layout uses the oriented
        // size. Store EXIF-rotated sources upright so both agree.
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation != 1 {
            bytes = try Self.upright(image, longestSide: max(width, height))
        }
        let destination = disk.pageURL(chapter, filename)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: destination.path) { try bytes.write(to: destination, options: .atomic) }
        return previous?.original == filename ? previous! : MangaPage(source: source, original: filename)
    }
    private static func upright(_ source: CGImageSource, longestSide: Int) throws -> Data {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longestSide]
        let output = NSMutableData()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw AppError.message(L("Image is invalid or too large for on-device processing"))
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppError.message(L("Image is invalid or too large for on-device processing")) }
        return output as Data
    }
}

func isConnectivityError(_ error: Error) -> Bool {
    guard let error = error as? URLError else { return false }
    return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
            .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive].contains(error.code)
}

enum LMStudio {
    struct Server: Identifiable { var url: String; var models: [String]; var id: String { url } }
    private final class LANAccess: @unchecked Sendable {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "LMStudio.LANAccess")
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false
        init(host: String) { connection = NWConnection(host: NWEndpoint.Host(host), port: 9, using: .udp) }
        func wait() async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    queue.async {
                        guard !self.finished else { continuation.resume(throwing: CancellationError()); return }
                        self.continuation = continuation
                        self.connection.stateUpdateHandler = { [weak self] state in
                            switch state {
                            case .ready: self?.finish(.success(()))
                            case .failed(let error): self?.finish(.failure(error))
                            case .cancelled: self?.finish(.failure(CancellationError()))
                            default: break
                            }
                        }
                        self.connection.start(queue: self.queue)
                        self.queue.asyncAfter(deadline: .now() + 60) { [weak self] in
                            self?.finish(.failure(URLError(.notConnectedToInternet)))
                        }
                    }
                }
            } onCancel: { self.queue.async { self.finish(.failure(CancellationError())) } }
        }
        private func finish(_ result: Result<Void, Error>) {
            guard !finished else { return }
            finished = true
            let pending = continuation; continuation = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            pending?.resume(with: result)
        }
    }
    static func baseURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme ?? ""), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw AppError.message(L("Enter a server root URL without /v1")) }
        // App Transport Security only permits plain HTTP on the local network.
        guard url.scheme == "https" || isLocalHost(host) else {
            throw AppError.message(L("HTTP is only allowed for local network addresses. Use HTTPS for other servers."))
        }
        return url
    }
    static func isLocalHost(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if !name.contains(".") || name.hasSuffix(".local") { return true }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, name, &v4) == 1 || inet_pton(AF_INET6, name, &v6) == 1
    }
    static func session(timeout: Double = 120, waitsForConnectivity: Bool = true) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // The first LAN request must survive the system permission prompt.
        // Keep the normal inactivity limit once connected, with a bounded
        // resource lifetime that leaves time for the user to grant access.
        config.waitsForConnectivity = waitsForConnectivity
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = waitsForConnectivity ? max(timeout, 60) : timeout
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: RedirectBoundary { _ in false }, delegateQueue: nil)
    }
    static func models(_ server: String, token: String = "") async throws -> [String] {
        let base = try baseURL(server)
        var request = URLRequest(url: base.appendingPathComponent("api/v1/models"))
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let session = session(timeout: 5); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let models = root["models"] as? [[String: Any]] else { throw AppError.message(L("LM Studio model list is unavailable")) }
        return translationModels(models)
    }
    private static func translationModels(_ rows: [[String: Any]]) -> [String] {
        rows.filter { ["llm", "vlm"].contains($0["type"] as? String ?? "") }
            .sorted {
                let left = ($0["loaded_instances"] as? [Any])?.isEmpty == false
                let right = ($1["loaded_instances"] as? [Any])?.isEmpty == false
                if left != right { return left }
                return ($0["key"] as? String ?? "") < ($1["key"] as? String ?? "")
            }.compactMap { $0["key"] as? String }
    }
    static func privateSubnets() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var result = Set<String>(); var item = list
        while let pointer = item {
            defer { item = pointer.pointee.ifa_next }
            guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), let mask = pointer.pointee.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard bits == 0xffffff00 else { continue }
            let a = ip >> 24, b = (ip >> 16) & 255, c = (ip >> 8) & 255
            guard a == 10 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b)) else { continue }
            result.insert("\(a).\(b).\(c)")
        }
        return result.sorted()
    }
    static func discover(port: Int) async throws -> [Server] {
        let subnets = privateSubnets()
        guard !subnets.isEmpty, subnets.count <= 4, (1...65535).contains(port) else { throw AppError.message(L("No private /24 network found. Enter the server URL manually.")) }
        // A connected UDP socket needs no remote handshake or packets. Network
        // framework waits here for LAN permission (Apple TN3179), before the
        // short per-host HTTP probes start consuming their timeout budgets.
        for subnet in subnets { try await LANAccess(host: subnet + ".1").wait() }
        let addresses = subnets.flatMap { subnet in (1...254).map { "http://\(subnet).\($0):\(port)" } }
        let session = session(timeout: 1.2, waitsForConnectivity: false); defer { session.invalidateAndCancel() }
        return try await withThrowingTaskGroup(of: Server?.self) { group in
            var iterator = addresses.makeIterator()
            func probe(_ address: String) { group.addTask {
                guard let url = URL(string: address + "/api/v1/models") else { return nil }
                do {
                    let (data, response) = try await session.data(from: url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_048_576,
                          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let models = root["models"] as? [[String: Any]], models.allSatisfy({ $0["key"] is String && $0["type"] is String }) else { return nil }
                    return Server(url: address, models: translationModels(models))
                } catch { return nil }
            } }
            for _ in 0..<32 { if let address = iterator.next() { probe(address) } }
            var result: [Server] = []
            while let server = try await group.next() {
                try Task.checkCancellation()
                if let server { result.append(server) }
                if let address = iterator.next() { probe(address) }
            }
            return result.sorted { $0.url < $1.url }
        }
    }
}
