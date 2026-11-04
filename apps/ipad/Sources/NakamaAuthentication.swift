import Foundation
import Security
import Observation

struct NakamaConnection: Decodable {
    let endpoint: URL
    let server_key: String
    let credential_namespace: String
    let apple_bundle_ids: [String]
    func validate(bundleID: String) throws {
        guard endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil, endpoint.path.isEmpty || endpoint.path == "/",
              endpoint.port.map({ (1...65535).contains($0) }) ?? true,
              !server_key.isEmpty, server_key.utf8.count <= 256,
              credential_namespace.hasPrefix("nakama:"), (8...256).contains(credential_namespace.utf8.count),
              !credential_namespace.contains(where: { $0.isWhitespace || $0.isNewline }),
              !apple_bundle_ids.isEmpty, apple_bundle_ids.count <= 8,
              Set(apple_bundle_ids).count == apple_bundle_ids.count,
              apple_bundle_ids.allSatisfy({ $0.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil }),
              apple_bundle_ids.contains(bundleID) else {
            throw AppError.message(L("Invalid backend connection configuration"))
        }
    }
    static func configured(_ endpoint: URL) throws -> (Self, Data) {
        struct Identity: Decodable {
            let server_key: String
            let credential_namespace: String
            let apple_bundle_ids: [String]
        }
        guard let config = Bundle.main.url(forResource: "nakama-connection", withExtension: "json"),
              let cert = Bundle.main.url(forResource: "nakama-connection", withExtension: "cer") else {
            throw AppError.message(L("The authentication backend has not been configured for this build."))
        }
        let identity = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: config))
        let value = Self(endpoint: endpoint, server_key: identity.server_key, credential_namespace: identity.credential_namespace, apple_bundle_ids: identity.apple_bundle_ids)
        try value.validate(bundleID: Bundle.main.bundleIdentifier ?? "")
        return (value, try Data(contentsOf: cert))
    }
}

// Accept a publicly trusted chain or the bundled development CA for this host.
// Hostname, validity and certificate-chain checks remain enforced in both cases.
final class NakamaTLS: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let certificate: Data
    let host: String
    init(certificate: Data, host: String) { self.certificate = certificate; self.host = host }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust,
              let anchor = SecCertificateCreateWithData(nil, certificate as CFData) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        guard SecTrustEvaluateWithError(trust, nil) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct NakamaSession: Codable, Sendable {
    let token: String
    let refresh_token: String
}
struct NakamaAccount: Decodable, Sendable {
    struct User: Codable, Sendable {
        let id: String
        let username: String
        let apple_id: String?
    }
    let user: User
}
struct NakamaAppleChallenge: Decodable, Sendable {
    let nonce: String
    let user_id: String
    let expires_at: Int
    var usable: Bool { expires_at > Int(Date().timeIntervalSince1970) + 10 }
}
struct NakamaFailure: Error, LocalizedError {
    let status: Int
    var errorDescription: String? {
        switch status {
        case 401: return L("Backend authentication was rejected. Sign in again.")
        case 409: return L("This Apple ID belongs to another backend account. Your current account has not been merged.")
        default: return String(format: L("Backend request failed (HTTP %d)."), status)
        }
    }
}

actor NakamaClient {
    let connection: NakamaConnection
    private let session: URLSession
    init(connection: NakamaConnection, certificate: Data) {
        self.connection = connection
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil; config.urlCache = nil
        session = URLSession(configuration: config, delegate: NakamaTLS(certificate: certificate, host: connection.endpoint.host!), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func close() { session.invalidateAndCancel() }
    private func send(_ path: String, body: [String: Any]?, token: String? = nil, query: [URLQueryItem] = [], method: String? = nil) async throws -> Data {
        var url = URLComponents(url: connection.endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!)
        request.httpMethod = method ?? (body == nil ? "GET" : "POST")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        else { request.setValue("Basic " + Data((connection.server_key + ":").utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NakamaFailure(status: 0) }
        guard (200...299).contains(http.statusCode) else { throw NakamaFailure(status: http.statusCode) }
        guard data.count <= 1_048_576 else { throw NakamaFailure(status: 0) }
        return data
    }
    func device(_ id: String) async throws -> NakamaSession {
        let data = try await send("v2/account/authenticate/device", body: ["id": id], query: [.init(name: "create", value: "true")])
        return try JSONDecoder().decode(NakamaSession.self, from: data)
    }
    func email(_ address: String, password: String) async throws -> NakamaSession {
        let data = try await send("v2/account/authenticate/email", body: ["email": address, "password": password], query: [.init(name: "create", value: "false")])
        return try JSONDecoder().decode(NakamaSession.self, from: data)
    }
    func account(_ auth: NakamaSession) async throws -> NakamaAccount {
        try JSONDecoder().decode(NakamaAccount.self, from: await send("v2/account", body: nil, token: auth.token))
    }
    func refresh(_ auth: NakamaSession) async throws -> NakamaSession {
        try JSONDecoder().decode(NakamaSession.self, from: await send("v2/account/session/refresh", body: ["token": auth.refresh_token]))
    }
    func rpc(_ name: String, payload: String, auth: NakamaSession) async throws -> String {
        var request = URLRequest(url: connection.endpoint.appendingPathComponent("v2/rpc/" + name))
        request.httpMethod = "POST"
        request.setValue("Bearer " + auth.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        for attempt in 0...1 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw NakamaFailure(status: 0) }
                guard (200...299).contains(http.statusCode), data.count <= 1_048_576 else { throw NakamaFailure(status: http.statusCode) }
                struct RPC: Decodable { let payload: String }
                return try JSONDecoder().decode(RPC.self, from: data).payload
            } catch let error as URLError where attempt == 0 && (name.hasPrefix("profile_") || ["ai_generate", "ai_result", "ai_catalog", "ai_cancel", "ai_finish"].contains(name)) &&
                [.networkConnectionLost, .timedOut, .cannotConnectToHost].contains(error.code) {
                // Reuse the operation ID: a lost response cannot charge or award twice.
                try Task.checkCancellation()
            }
        }
        throw NakamaFailure(status: 0)
    }
    func challenge(_ auth: NakamaSession) async throws -> NakamaAppleChallenge {
        let payload = try await rpc("apple_challenge", payload: "", auth: auth)
        return try JSONDecoder().decode(NakamaAppleChallenge.self, from: Data(payload.utf8))
    }
    func linkApple(_ identityToken: String, challenge: NakamaAppleChallenge, auth: NakamaSession) async throws {
        _ = try await send("v2/account/link/apple", body: ["token": identityToken, "vars": ["challenge_user_id": challenge.user_id]], token: auth.token)
    }
    func apple(_ identityToken: String, challenge: NakamaAppleChallenge) async throws -> NakamaSession {
        try JSONDecoder().decode(NakamaSession.self, from: await send("v2/account/authenticate/apple",
            body: ["token": identityToken, "vars": ["challenge_user_id": challenge.user_id]], query: [.init(name: "create", value: "true")]))
    }
    // Nakama's DeleteAccount removes the user and the storage objects it owns,
    // including the credit profile, ledger and Apple/device links.
    func deleteAccount(_ auth: NakamaSession) async throws {
        _ = try await send("v2/account", body: nil, token: auth.token, method: "DELETE")
    }
    func logout(_ auth: NakamaSession) async throws {
        _ = try await send("v2/session/logout", body: ["token": auth.token, "refresh_token": auth.refresh_token], token: auth.token)
    }
}

@MainActor @Observable final class NakamaAuthentication {
    private var client: NakamaClient?
    private let credentialScope: String
    private(set) var auth: NakamaSession?
    private(set) var user: NakamaAccount.User?
    private(set) var challenge: NakamaAppleChallenge?
    private(set) var working = false
    private(set) var endpoint: String?
    private(set) var unavailable: String?
    // True when a saved session was restored without reaching the backend.
    // Reading the local library stays available; credit actions need a connection.
    private(set) var offline = false
    var message: String?
    init() {
        do {
            let (connection, certificate) = try NakamaConnection.configured(AppConfiguration.current.server.endpoint)
            client = NakamaClient(connection: connection, certificate: certificate)
            endpoint = connection.endpoint.absoluteString
            // Backend identity survives a transport migration from LAN to EC2.
            credentialScope = connection.credential_namespace
        } catch {
            client = nil; credentialScope = ""; unavailable = error.localizedDescription
        }
    }
    func reconfigure(endpoint: URL) async throws {
        guard self.endpoint != endpoint.absoluteString else { return }
        working = true
        defer { working = false }
        let (connection, certificate) = try NakamaConnection.configured(endpoint)
        guard connection.credential_namespace == credentialScope else { throw NakamaFailure(status: 401) }
        let previous = client
        client = NakamaClient(connection: connection, certificate: certificate)
        self.endpoint = connection.endpoint.absoluteString
        challenge = nil; offline = false; message = nil
        await previous?.close()
    }
    func profileCommand(_ name: String, payload: String) async throws -> CreditResponse {
        let result = try await rpcCommand(name, payload: payload)
        return try CreditResponse.decoder().decode(CreditResponse.self, from: Data(result.utf8))
    }
    func rpcCommand(_ name: String, payload: String) async throws -> String {
        guard let client, let auth, let userID = user?.id else { throw NakamaFailure(status: 401) }
        let result: String
        do { result = try await client.rpc(name, payload: payload, auth: auth) }
        catch let failure as NakamaFailure where failure.status == 401 {
            let refreshed = try await client.refresh(auth)
            guard user?.id == userID, self.client === client else { throw NakamaFailure(status: 401) }
            try await publish(refreshed, client: client, expectedUserID: userID)
            result = try await client.rpc(name, payload: payload, auth: refreshed)
        }
        guard user?.id == userID, self.client === client else { throw NakamaFailure(status: 401) }
        return result
    }
    private func publish(_ session: NakamaSession, client: NakamaClient, expectedUserID: String? = nil) async throws {
        guard self.client === client else { throw CancellationError() }
        let account = try await client.account(session)
        guard self.client === client else { throw CancellationError() }
        guard UUID(uuidString: account.user.id) != nil else { throw NakamaFailure(status: 0) }
        if let expectedUserID {
            guard user?.id == expectedUserID, account.user.id == expectedUserID else { throw NakamaFailure(status: 401) }
        }
        let saved = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        try Credentials.save(saved, credentialScope + ":session")
        if let cached = try? JSONEncoder().encode(account.user) {
            try? Credentials.save(String(decoding: cached, as: UTF8.self), credentialScope + ":user")
        }
        auth = session; user = account.user; offline = false
    }
    func restore() async {
        guard !working, user == nil, let client else { return }
        let value = Credentials.read(credentialScope + ":session")
        guard let saved = try? JSONDecoder().decode(NakamaSession.self, from: Data(value.utf8)) else { return }
        working = true; defer { working = false }
        do {
            do { try await publish(saved, client: client) }
            catch let failure as NakamaFailure where failure.status == 401 { try await publish(client.refresh(saved), client: client) }
        } catch {
            if (error as? NakamaFailure)?.status == 401 { try? clearSession() }
            else if isConnectivityError(error), let cached = cachedUser() {
                // The saved session is revalidated (and refreshed) on the next
                // backend command; until then only local reading is unlocked.
                auth = saved; user = cached; offline = true; message = nil
                return
            }
            message = error.localizedDescription
        }
        await prepareChallenge()
    }
    func signInDevice() async {
        guard !working, let client else { return }
        working = true; defer { working = false }
        do {
            try await publish(client.device(deviceCredential()), client: client)
            message = nil
            await prepareChallenge()
        } catch { message = error.localizedDescription }
    }
    func signInEmail(_ address: String, password: String) async {
        guard !working, let client else { return }
        let email = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.count <= 254, email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil,
              (8...128).contains(password.count) else { message = L("Enter a valid email address and password."); return }
        working = true; defer { working = false }
        do {
            try await publish(client.email(email, password: password), client: client)
            message = nil
            await prepareChallenge()
        } catch { message = L("Email sign-in failed. Check your email and password.") }
    }
    private func deviceCredential() throws -> String {
        var id = Credentials.read(credentialScope + ":device")
        if id.isEmpty {
            id = UUID().uuidString + UUID().uuidString
            try Credentials.save(id, credentialScope + ":device")
        }
        return id
    }
    func prepareAppleSignIn() async {
        guard !working, let client else { return }
        if auth != nil { await prepareChallenge(); return }
        working = true; defer { working = false }
        do {
            // A device session authorizes the nonce RPC only. Publishing it here
            // would unlock the app before the user completes Apple sign-in.
            let bootstrap = try await client.device(deviceCredential())
            challenge = try await client.challenge(bootstrap)
        } catch {
            challenge = nil
            message = error.localizedDescription
        }
    }
    func prepareChallenge() async {
        guard let client, let auth else { return }
        do {
            do { challenge = try await client.challenge(auth) }
            catch let failure as NakamaFailure where failure.status == 401 {
                let refreshed = try await client.refresh(auth)
                try await publish(refreshed, client: client)
                challenge = try await client.challenge(refreshed)
            }
        } catch {
            challenge = nil
            if (error as? NakamaFailure)?.status == 401 { try? clearSession() }
            message = error.localizedDescription
        }
    }
    func signInApple(identityToken: String) async {
        guard !working, let client, let challenge, challenge.usable else { return }
        working = true; self.challenge = nil
        defer { working = false }
        do {
            if let auth, user?.apple_id?.isEmpty != false {
                var linked = auth
                do { try await client.linkApple(identityToken, challenge: challenge, auth: linked) }
                catch let failure as NakamaFailure where failure.status == 401 {
                    linked = try await client.refresh(auth)
                    try await client.linkApple(identityToken, challenge: challenge, auth: linked)
                }
                try await publish(client.refresh(linked), client: client)
            } else { try await publish(client.apple(identityToken, challenge: challenge), client: client) }
            message = L("Apple sign-in succeeded. The backend account ID is shown below.")
        } catch { message = error.localizedDescription }
        working = false
        await prepareAppleSignIn()
    }
    private func cachedUser() -> NakamaAccount.User? {
        let value = Credentials.read(credentialScope + ":user")
        guard let user = try? JSONDecoder().decode(NakamaAccount.User.self, from: Data(value.utf8)), UUID(uuidString: user.id) != nil else { return nil }
        return user
    }
    private func clearSession() throws {
        try Credentials.save("", credentialScope + ":session")
        try? Credentials.save("", credentialScope + ":user")
        auth = nil; user = nil; challenge = nil; offline = false
    }
    func deleteAccount() async -> Bool {
        guard !working, let client, let auth else { return false }
        working = true; defer { working = false }
        do {
            do { try await client.deleteAccount(auth) }
            catch let failure as NakamaFailure where failure.status == 401 {
                try await client.deleteAccount(client.refresh(auth))
            }
            try clearSession()
            // A new guest sign-in must create a new account, not reuse this one.
            try? Credentials.save("", credentialScope + ":device")
            message = L("Your account has been deleted.")
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }
    func signOut() async {
        guard !working, let client, let auth else { return }
        working = true; defer { working = false }
        do {
            do { try await client.logout(auth) }
            catch let failure as NakamaFailure where failure.status == 401 {
                do { try await client.logout(client.refresh(auth)) }
                catch let expired as NakamaFailure where expired.status == 401 { }
            }
            try clearSession()
            message = nil
        } catch let error where isConnectivityError(error) {
            // Signing out must work offline; the server session simply expires.
            try? clearSession()
            message = nil
        } catch { message = error.localizedDescription }
    }
}
