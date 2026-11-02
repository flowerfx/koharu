import Foundation
import Observation
import StoreKit

@MainActor @Observable final class SubscriptionStore {
    let productID: String
    private let credits: CreditStore
    private(set) var product: Product?
    private(set) var loading = false
    private(set) var purchasing = false
    private(set) var message: String?
    private(set) var launchOfferFinished = false
    var showOffer = false
    var offerAfterCredits = false
    var hasPremium: Bool { credits.tier == .premium }

    init(credits: CreditStore, environment: ConfigurationTarget.Environment) {
        self.credits = credits
        productID = environment == .production
            ? "com.kurubyInteractive.aimanga.premium.monthly"
            : "com.kurubyInteractive.aimanga.staging.premium.monthly"
    }

    func prepareLaunchOffer() async {
        guard !launchOfferFinished else { return }
        // Offline, membership is unknown: never present the paywall to a member.
        // RootScreen calls this again once the credit profile loads.
        guard credits.loaded else { await loadProduct(); return }
        await refreshEntitlements()
        guard !Task.isCancelled else { return }
        if hasPremium { launchOfferFinished = true }
        else if let shown = UserDefaults.standard.object(forKey: Self.offerShownKey) as? Date, Date().timeIntervalSince(shown) < 86_400 {
            // The launch offer is shown at most once a day; Premium stays in Settings.
            launchOfferFinished = true
        } else {
            showOffer = true
            UserDefaults.standard.set(Date(), forKey: Self.offerShownKey)
        }
        await loadProduct()
    }
    private static let offerShownKey = "subscriptionOfferShownAt"

    func resetAccount() {
        showOffer = false; offerAfterCredits = false; launchOfferFinished = false; message = nil
    }

    func continueWithoutSubscription() {
        showOffer = false
        launchOfferFinished = true
    }

    func refresh() async {
        // Entitlements are checked independently of product/network availability.
        await refreshEntitlements()
        await loadProduct()
    }

    private func loadProduct() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            product = try await Product.products(for: [productID]).first {
                $0.id == productID && $0.type == .autoRenewable &&
                $0.subscription?.subscriptionPeriod.unit == .month && $0.subscription?.subscriptionPeriod.value == 1
            }
            message = product == nil ? L("The subscription is currently unavailable. You can continue for free and try again later.") : nil
        } catch {
            message = L("Could not load the subscription. You can continue for free and try again later.")
        }
    }

    func refreshEntitlements() async {
        guard credits.loaded else { return }
        do {
            for await result in Transaction.unfinished {
                await receive(result)
            }
            for await result in Transaction.currentEntitlements(for: productID) {
                if case .verified(let transaction) = result, transaction.productID == productID {
                    try await credits.validateSubscription(result.jwsRepresentation)
                }
            }
            // A subscription purchased on another device remains a server-owned entitlement.
            try await credits.load()
            if hasPremium { showOffer = false; launchOfferFinished = true }
        } catch { message = error.localizedDescription }
    }

    func observeChanges() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await result in Transaction.updates {
                    guard !Task.isCancelled, let self else { return }
                    await self.receive(result)
                }
            }
            group.addTask { [weak self] in
                for await status in Product.SubscriptionInfo.Status.updates {
                    guard !Task.isCancelled, let self else { return }
                    if case .verified(let transaction) = status.transaction,
                       transaction.productID == self.productID {
                        await self.refreshEntitlements()
                    }
                }
            }
            await group.waitForAll()
        }
    }

    private func receive(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result, transaction.productID == productID else { return }
        do {
            try await credits.validateSubscription(result.jwsRepresentation)
            if hasPremium { showOffer = false; launchOfferFinished = true }
            // Acknowledge only after Nakama has verified and stored the transaction.
            await transaction.finish()
        } catch { message = error.localizedDescription }
    }

    func purchase() async {
        guard let product, credits.loaded, !purchasing else { return }
        purchasing = true
        message = nil
        defer { purchasing = false }
        do {
            switch try await product.purchase(options: [.appAccountToken(credits.profile.id)]) {
            case .success(let result):
                guard case .verified(let transaction) = result, transaction.productID == productID else {
                    message = L("The purchase could not be verified. Premium has not been unlocked.")
                    return
                }
                await receive(result)
            case .pending:
                message = L("Your purchase is awaiting approval. You can continue for free while it is pending.")
            case .userCancelled: break
            @unknown default:
                message = L("The purchase could not be completed. Please try again.")
            }
        } catch {
            message = L("The purchase could not be completed. Please try again.")
        }
    }

    func restore() async {
        guard !purchasing else { return }
        purchasing = true
        message = nil
        defer { purchasing = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !hasPremium { message = L("No active subscription was found for this Apple Account.") }
        } catch {
            message = L("Could not restore purchases. Please try again.")
        }
    }
}
