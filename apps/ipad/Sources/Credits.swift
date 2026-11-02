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
    var supportsFreeVideo: Bool { [.translate, .image].contains(self) }
    case translate, image, enhance, generatePrompt
    var title: String {
        switch self {
        case .translate: return L("Translate chapter")
        case .image: return L("Generate image")
        case .enhance: return L("Enhance prompt")
        case .generatePrompt: return L("Random character")
        }
    }
}

struct CreditConfiguration: Decodable {
    let daily_free_user: Int
    let daily_premium_user: Int
    let reward_video_multiplier: Double
    let reward_video_credit: Int
    let cost_translate: Int
    let cost_api_prompt: Int
    let cost_image: Int
    let cost_image_premium: Int
    let cost_gen_prompt: Int
    let cost_enhance_free: Int
    let cost_enhance_premium: Int

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        let amounts = [value.daily_free_user, value.daily_premium_user, value.reward_video_credit, value.cost_translate,
                      value.cost_api_prompt, value.cost_image, value.cost_image_premium, value.cost_gen_prompt,
                      value.cost_enhance_free, value.cost_enhance_premium]
        guard amounts.allSatisfy({ (0...100_000).contains($0) }), value.daily_free_user > 0,
              value.daily_premium_user > 0, value.reward_video_credit > 0,
              value.reward_video_multiplier.isFinite, (1...10).contains(value.reward_video_multiplier) else {
            throw AppError.message(L("Invalid credit configuration"))
        }
        return value
    }
    static func bundled() throws -> Self {
        guard let file = Bundle.main.url(forResource: "credit-config", withExtension: "json") else {
            throw AppError.message(L("Invalid credit configuration"))
        }
        return try decode(Data(contentsOf: file))
    }
    func daily(_ tier: CreditTier) -> Int { tier == .free ? daily_free_user : daily_premium_user }
    func cost(_ action: CreditAction, tier: CreditTier) -> Int {
        switch action {
        case .translate: return cost_translate
        case .image: return tier == .premium ? cost_image_premium : cost_image
        case .enhance: return tier == .premium ? cost_enhance_premium : cost_enhance_free
        case .generatePrompt: return cost_gen_prompt
        }
    }
    func rerunCost(provider: TranslationProvider) -> Int {
        provider == .backend ? cost_api_prompt : 0
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
    private(set) var videoAccess: [String: Int] = [:]
    private(set) var canClaimDaily = false
    var tier: CreditTier { profile.account_type }
    var nextDaily: Date { profile.reset_daily_reward }
    init(authentication: NakamaAuthentication, policy: CreditConfiguration) {
        self.authentication = authentication; self.policy = policy
    }
    func clear() {
        loaded = false; canClaimDaily = false; videoAccess = [:]; failure = nil; revision = -1
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
                loaded = true; failure = nil
            }
            return response
        } catch {
            if authentication.user?.id == userID { failure = error.localizedDescription }
            throw error
        }
    }
    func load() async throws { _ = try await command("profile_load") }
    func claimDaily() async throws { _ = try await command("profile_daily", ["operation_id": UUID().uuidString]) }
    func startVideo(purpose: String, action: CreditAction) async throws -> String {
        guard let id = try await command("profile_video_start", ["purpose": purpose, "action": action.rawValue]).video_id else {
            throw AppError.message(L("Could not open credit profile"))
        }
        return id
    }
    func completeVideo(_ id: String) async throws { _ = try await command("profile_video_complete", ["operation_id": id]) }
    func hasVideoAccess(_ action: CreditAction) -> Bool { tier == .free && action.supportsFreeVideo && videoAccess[action.rawValue, default: 0] > 0 }
    func canAfford(_ amount: Int, action: CreditAction) -> Bool { loaded && failure == nil && (profile.credit >= amount || hasVideoAccess(action)) }
    func reserve(action: CreditAction, provider: TranslationProvider, rerun: Bool = false) async throws -> String? {
        try await command("profile_reserve", ["operation_id": UUID().uuidString, "action": action.rawValue, "provider": provider.rawValue, "rerun": rerun]).reservation_id
    }
    func settle(_ id: String?, success: Bool) async throws {
        guard let id else { return }
        _ = try await command("profile_settle", ["operation_id": id, "success": success])
    }
    func validateSubscription(_ jws: String) async throws { _ = try await command("profile_subscription", ["receipt": jws]) }
}

struct CreditRequest: Identifiable {
    let id = UUID()
    let action: CreditAction
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
            error = L("Backend API is not connected in this offline build. Choose another provider in Settings. No credits were spent.")
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
    func creditCost(_ action: CreditAction) -> Int {
        credits.policy.cost(action, tier: credits.tier)
    }
    var rerunCreditCost: Int { credits.policy.rerunCost(provider: preferences.provider) }
    func requestCredits(_ action: CreditAction, cost: Int, explanation: String = "", changeProvider: Bool = false, proceed: @escaping @MainActor () -> Void) {
        guard credits.loaded else { error = L("Could not open credit profile"); return }
        if let failure = credits.failure { error = failure; return }
        if cost == 0 { proceed(); return }
        creditRequest = CreditRequest(action: action, cost: cost, explanation: explanation, canChangeProvider: changeProvider, proceed: proceed)
    }
    func finishCredits(_ ticket: String?, success: Bool) async {
        // Settlement must survive cancellation of the generation/translation task.
        await Task { @MainActor in
            do { try await credits.settle(ticket, success: success) }
            catch { self.error = error.localizedDescription }
        }.value
    }
    func loginCredits() async {
        guard backendAuthentication.user != nil else { return }
        do {
            try await credits.load()
            if credits.canClaimDaily { showCreditRewards = true }
        } catch { self.error = error.localizedDescription }
    }
    func requestBackendTranslation(cost: Int) {
        requestCredits(.translate, cost: cost, explanation: L("Translating from Rawkuma costs credits. Reruns cost credits only with Backend API. Reading downloaded chapters is free."), changeProvider: true) {
            self.error = L("Backend API is not connected in this offline build. Choose another provider in Settings. No credits were spent.")
            self.showCreditProviderSettings = true
        }
    }
}
