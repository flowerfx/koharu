import Foundation
import Observation
import SwiftUI

enum ContentSafetyMode: String, Decodable, CaseIterable, Sendable {
    case none = "none-safe", half = "half-safe", full = "full-safe"
    var checksPrompts: Bool { self != .none }
    var allowsRawkuma: Bool { self != .full }
    var warnsAboutRawkuma: Bool { self == .half }
}

struct ContentSafetyConfiguration: Decodable, Equatable, Sendable {
    let mode: ContentSafetyMode
    let blockedGenres: [String]
    func validated() throws {
        let keys = blockedGenres.map(Self.normalized)
        guard blockedGenres.count <= 100, blockedGenres.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 80 }),
              Set(keys).count == keys.count else { throw AppError.message(L("Invalid app configuration (app-config.json)")) }
    }
    func blockedMatches(_ genres: [String]) -> [String] {
        guard mode == .half else { return [] }
        let names = Set(genres.map(Self.normalized))
        return blockedGenres.filter { names.contains(Self.normalized($0)) }
    }
    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

enum ContentSafetyFailure: Error, LocalizedError {
    case blocked, unavailable, consent
    var errorDescription: String? {
        switch self {
        case .blocked: return L("This prompt contains restricted content. Please change it before generating an image.")
        case .unavailable: return L("Kuruby's content review service is unavailable. Please try again before using prompt assistance or generating images.")
        case .consent: return L("Allow Kuruby to review your prompt before using prompt assistance or generating images.")
        }
    }
}

@MainActor @Observable final class ContentSafety {
    private let configuration: () -> AppConfiguration
    private let authentication: NakamaAuthentication
    private(set) var needsConsent = false
    @ObservationIgnored private var consentWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var tail: Task<Void, Error>?
    @ObservationIgnored private var tailID: UUID?
    private var consentKey: String { "promptSafetyConsent-v1:" + (authentication.user?.id ?? "signed-out") }
    init(authentication: NakamaAuthentication, configuration: @escaping () -> AppConfiguration = { AppConfiguration.current }) { self.authentication = authentication; self.configuration = configuration }
    func resolveConsent(_ allow: Bool) {
        guard needsConsent else { return }
        if allow { UserDefaults.standard.set(true, forKey: consentKey) }
        needsConsent = false
        let waiters = consentWaiters; consentWaiters = []
        for waiter in waiters { waiter.resume(returning: allow) }
    }
    private func requireConsent() async throws {
        guard authentication.user != nil else { throw ContentSafetyFailure.unavailable }
        if UserDefaults.standard.bool(forKey: consentKey) { return }
        let accepted = await withCheckedContinuation { continuation in
            consentWaiters.append(continuation)
            needsConsent = true
        }
        try Task.checkCancellation()
        guard accepted else { throw ContentSafetyFailure.consent }
    }
    // No cached approvals: half/full mode requires a reachable backend for
    // every new prompt action, even if the same text passed previously.
    func checkText(_ text: String) async throws {
        guard configuration().contentSafety.mode.checksPrompts else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard text.count <= 24000 else { throw ContentSafetyFailure.blocked }
        do { try configuration().requireProvider(.backend) } catch { throw ContentSafetyFailure.unavailable }
        try await requireConsent()
        struct Request: Encodable { let text: String }
        struct Verdict: Decodable { let allowed: Bool; let policy: String }
        let payload = try JSONEncoder().encode(Request(text: text))
        let previous = tail, id = UUID(), account = authentication.user?.id
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            guard authentication.user?.id == account, account != nil else { throw ContentSafetyFailure.unavailable }
            let response: String
            do { response = try await authentication.rpcCommand("content_moderate", payload: String(decoding: payload, as: UTF8.self)) }
            catch { throw ContentSafetyFailure.unavailable }
            guard authentication.user?.id == account,
                  let verdict = try? JSONDecoder().decode(Verdict.self, from: Data(response.utf8)), verdict.policy == "sexual-prompt-v1" else {
                throw ContentSafetyFailure.unavailable
            }
            guard verdict.allowed else { throw ContentSafetyFailure.blocked }
        }
        tail = task; tailID = id
        defer { if tailID == id { tail = nil; tailID = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

struct ContentSafetyConsentScreen: View {
    let safety: ContentSafety
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(L("Prompt review"), systemImage: "checkmark.shield")
                    Text(L("Kuruby reviews your prompt before creating an image. If it meets the platform's content requirements, you can continue. Otherwise, please use a different prompt."))
                    Text(L("For this review, prompt text is sent through Kuruby Server to OpenAI. Internet access is required. Manga pages and generated images are not sent for this review."))
                    Text(L("You can decline. Prompt assistance and image generation can continue after you allow prompt review."))
                    Link(L("Privacy Policy"), destination: URL(string: "https://www.kuruby.com/privacy-policy")!)
                    Link("OpenAI", destination: URL(string: "https://openai.com/policies/privacy-policy/")!)
                }
                Section {
                    Button(L("Allow prompt review")) { safety.resolveConsent(true) }.buttonStyle(.borderedProminent)
                    Button(L("Not now"), role: .cancel) { safety.resolveConsent(false) }
                }
            }
            .navigationTitle(L("Prompt review"))
        }.interactiveDismissDisabled().presentationSizing(.page)
    }
}
