import Foundation
import Observation

enum CreditTier: String, Codable, CaseIterable, Identifiable {
    case free, premium
    var id: String { rawValue }
    var title: String { L(self == .free ? "Free" : "Premium") }
    func allows(_ provider: TranslationProvider) -> Bool {
        self == .premium || [.local, .backend, .openAI, .anthropic].contains(provider)
    }
}

enum CreditAction: String, Codable, CaseIterable, Identifiable {
    var id: String { rawValue }
    case translate, translateEnhanced, image, enhance, generatePrompt
    var title: String {
        switch self {
        case .translate: return L("Translate chapter")
        case .translateEnhanced: return L("Enhanced translation")
        case .image: return L("Generate image")
        case .enhance: return L("Enhance prompt")
        case .generatePrompt: return L("Random character")
        }
    }
}

struct CreditConfiguration: Codable {
    let daily_free_user: Int
    let daily_premium_user: Int
    let reward_video_multiplier: Double
    let cost_translate_free: Int
    let cost_translate_premium: Int
    let cost_backend_surcharge: Int
    let cost_rerun_backend: Int
    let cost_image_free: Int
    let cost_image_premium: Int
    let cost_gen_prompt: Int
    let cost_enhance_free: Int
    let cost_enhance_premium: Int

    static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data).validated()
    }
    func validated() throws -> Self {
        let value = self
        let amounts = [value.daily_free_user, value.daily_premium_user, value.cost_translate_free, value.cost_translate_premium, value.cost_backend_surcharge, value.cost_rerun_backend, value.cost_image_free, value.cost_image_premium, value.cost_gen_prompt, value.cost_enhance_free, value.cost_enhance_premium]
        guard amounts.allSatisfy({ (0...100_000).contains($0) }), value.daily_free_user > 0,
              value.daily_premium_user > 0,
              value.reward_video_multiplier.isFinite, (1...10).contains(value.reward_video_multiplier) else {
            throw AppError.message(L("Invalid credit configuration"))
        }
        return value
    }
    func daily(_ tier: CreditTier) -> Int { tier == .free ? daily_free_user : daily_premium_user }
    func cost(_ action: CreditAction, tier: CreditTier, provider: TranslationProvider) -> Int {
        let premium = tier == .premium
        let surcharge = provider == .backend ? cost_backend_surcharge : 0
        switch action {
        case .translate: return (premium ? cost_translate_premium : cost_translate_free) + surcharge
        // Two backend passes (translate, then review the draft): twice an initial backend translation.
        case .translateEnhanced: return 2 * ((premium ? cost_translate_premium : cost_translate_free) + cost_backend_surcharge)
        case .image: return premium ? cost_image_premium : cost_image_free
        case .enhance: return (premium ? cost_enhance_premium : cost_enhance_free) + surcharge
        case .generatePrompt: return cost_gen_prompt
        }
    }
    func rerunCost(provider: TranslationProvider) -> Int {
        provider == .backend ? cost_rerun_backend : 0
    }
}

struct CreditProfile: Codable {
    let id: UUID
    var credit: Int
    var account_type: CreditTier
    var reset_daily_reward: Date
    var next_subscription_date: Date?
}

struct CreditResponse: Decodable {
    let revision: Int
    let profile: CreditProfile
    let policy: CreditConfiguration
    let server_time: Date
    let can_claim_daily: Bool
    let daily_video_available: Bool
    let daily_video_bonus: Int
    let video_access: [String: Int]
    let reservation_id: String?
    let video_id: String?
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid UTC profile timestamp"))
            }
            return date
        }
        return decoder
    }
}

@MainActor @Observable final class CreditStore {
    private let authentication: NakamaAuthentication
    private(set) var policy: CreditConfiguration
    private(set) var profile = CreditProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, credit: 0, account_type: .free, reset_daily_reward: .distantPast)
    private(set) var loaded = false
    private var operations = 0
    private var revision = -1
    var working: Bool { operations > 0 }
    private(set) var failure: String?
    // The last backend command could not reach the server. The local library
    // remains usable; credit-gated actions wait for a successful reload.
    private(set) var offline = false
    private(set) var videoAccess: [String: Int] = [:]
    private(set) var canClaimDaily = false
    private(set) var dailyVideoAvailable = false
    private(set) var dailyVideoBonus = 0
    var tier: CreditTier { profile.account_type }
    var nextDaily: Date { profile.reset_daily_reward }
    init(authentication: NakamaAuthentication, policy: CreditConfiguration) {
        self.authentication = authentication; self.policy = policy
    }
    func clear() {
        loaded = false; canClaimDaily = false; dailyVideoAvailable = false; dailyVideoBonus = 0; videoAccess = [:]; failure = nil; offline = false; revision = -1
        profile = CreditProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, credit: 0, account_type: .free, reset_daily_reward: .distantPast)
    }
    private func command(_ name: String, _ payload: [String: Any] = [:]) async throws -> CreditResponse {
        guard let userID = authentication.user?.id else { throw AppError.message(L("Backend authentication was rejected. Sign in again.")) }
        operations += 1
        defer { operations -= 1 }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try await authentication.profileCommand(name, payload: String(decoding: data, as: UTF8.self))
            guard authentication.user?.id == userID, response.profile.id.uuidString.lowercased() == userID.lowercased() else {
                throw AppError.message(L("Backend authentication was rejected. Sign in again."))
            }
            if response.revision >= revision {
                revision = response.revision
                profile = response.profile; policy = response.policy
                videoAccess = response.video_access; canClaimDaily = response.can_claim_daily
                dailyVideoAvailable = response.daily_video_available; dailyVideoBonus = response.daily_video_bonus
                loaded = true; failure = nil
            }
            offline = false
            return response
        } catch {
            if authentication.user?.id == userID { failure = error.localizedDescription; offline = isConnectivityError(error) }
            throw error
        }
    }
    func load() async throws { _ = try await command("profile_load") }
    func claimDaily() async throws { _ = try await command("profile_daily", ["operation_id": UUID().uuidString]) }
    func startVideo(purpose: String, operation: CreditOperation) async throws -> String {
        guard let id = try await command("profile_video_start", ["purpose": purpose, "action": operation.action.rawValue, "provider": operation.provider.rawValue, "rerun": operation.rerun]).video_id else {
            throw AppError.message(L("Could not open credit profile"))
        }
        return id
    }
    func completeVideo(_ id: String) async throws { _ = try await command("profile_video_complete", ["operation_id": id]) }
    func hasVideoAccess(_ operation: CreditOperation) -> Bool { videoAccess[operation.fingerprint, default: 0] > 0 }
    func canAfford(_ amount: Int, operation: CreditOperation) -> Bool { loaded && failure == nil && (profile.credit >= amount || hasVideoAccess(operation)) }
    func reserve(action: CreditAction, provider: TranslationProvider, rerun: Bool = false) async throws -> String? {
        try await command("profile_reserve", ["operation_id": UUID().uuidString.lowercased(), "action": action.rawValue, "provider": provider.rawValue, "rerun": rerun]).reservation_id
    }
    func settle(_ id: String?, success: Bool) async throws {
        guard let id else { return }
        _ = try await command("profile_settle", ["operation_id": id, "success": success])
    }
    func finishBackend(_ id: String?) async throws {
        guard let id else { return }
        _ = try await command("ai_finish", ["reservation_id": id.lowercased()])
    }
    func validateSubscription(_ jws: String) async throws { _ = try await command("profile_subscription", ["receipt": jws]) }
}

struct CreditOperation {
    let action: CreditAction
    let provider: TranslationProvider
    let rerun: Bool
    var fingerprint: String { "\(action.rawValue):\(provider.rawValue):\(rerun)" }
}

struct CreditRequest: Identifiable {
    let id = UUID()
    let operation: CreditOperation
    var action: CreditAction { operation.action }
    let cost: Int
    let explanation: String
    let canChangeProvider: Bool
    let proceed: @MainActor () -> Void
}

extension MangaLibrary {
    var allowedProviders: [TranslationProvider] { AppConfiguration.current.providers.filter { credits.tier.allows($0) } }
    func selectCreditProvider(_ provider: TranslationProvider) {
        guard credits.tier.allows(provider) else {
            error = L("This provider requires Premium. Choose Local GGUF, Backend API, OpenAI or Claude.")
            return
        }
        guard AppConfiguration.current.providers.contains(provider) else {
            error = L("This provider or model is disabled in app-config.json. Choose another option in Settings.")
            return
        }
        preferences.provider = provider
        savePreferences()
    }
    func requireCreditProvider() throws {
        guard credits.tier.allows(preferences.provider) else {
            throw AppError.message(L("This provider requires Premium. Choose Local GGUF, Backend API, OpenAI or Claude."))
        }
        try AppConfiguration.current.requireProvider(preferences.provider)
    }
    var translationCreditExplanation: String {
        L("Translating from Rawkuma costs credits. Reruns cost credits only with Backend API. Reading downloaded chapters is free.") + "\n" +
        (preferences.provider == .backend
         ? L("Backend API uses credits when AI output is returned, even if you stop or rendering fails afterwards. Requests that fail without AI output are refunded.")
         : L("If you stop or a later page fails, pages already translated are kept and the credits are used. Credits are refunded only when no page was translated."))
    }
    var enhancedCreditExplanation: String {
        L("Enhanced translation uses Backend API twice: it translates the chapter, then reviews every line against the original to fix mistakes and keep names consistent.") + "\n" +
        L("Backend API uses credits when AI output is returned, even if you stop or rendering fails afterwards. Requests that fail without AI output are refunded.")
    }
    func creditCost(_ action: CreditAction) -> Int {
        credits.policy.cost(action, tier: credits.tier, provider: preferences.provider)
    }
    var rerunCreditCost: Int { credits.policy.rerunCost(provider: preferences.provider) }
    func requestCredits(_ action: CreditAction, cost: Int, explanation: String = "", changeProvider: Bool = false, rerun: Bool = false, provider: TranslationProvider? = nil, proceed: @escaping @MainActor () -> Void) {
        guard credits.loaded else {
            error = credits.offline ? L("You're offline. Saved chapters can still be read; translating and generating need a connection.") : L("Could not open credit profile")
            return
        }
        if let failure = credits.failure {
            // A failed command blocks spending until the profile reloads; start it now
            // so the next attempt can proceed without waiting for a relaunch.
            error = failure
            Task { try? await credits.load() }
            return
        }
        if cost == 0 { proceed(); return }
        creditRequest = CreditRequest(operation: CreditOperation(action: action, provider: provider ?? (action == .image ? .local : preferences.provider), rerun: rerun), cost: cost, explanation: explanation, canChangeProvider: changeProvider, proceed: proceed)
    }
    func finishCredits(_ ticket: String?, success: Bool, provider: TranslationProvider = .local) async {
        // Settlement must survive cancellation of the generation/translation task.
        await Task { @MainActor in
            do {
                if provider == .backend { try await credits.finishBackend(ticket) }
                else { try await credits.settle(ticket, success: success) }
            }
            catch { self.error = error.localizedDescription }
        }.value
    }
    func loginCredits() async {
        guard backendAuthentication.user != nil else { return }
        do {
            try await credits.load()
            if credits.canClaimDaily { showCreditRewards = true }
        } catch {
            // Offline is shown in the credit bar; don't raise an alert on every launch.
            if !credits.offline { self.error = error.localizedDescription }
        }
    }
}
