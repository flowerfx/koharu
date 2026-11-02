import Foundation
import Observation
import UIKit
import GoogleMobileAds
import UserMessagingPlatform

@MainActor @Observable final class RewardedAds: NSObject, FullScreenContentDelegate {
    private(set) var working = false
    private(set) var status = ""
    private(set) var privacyOptionsRequired = false
    @ObservationIgnored private var consentRequested = false
    @ObservationIgnored private var consentTask: Task<Void, Never>?
    @ObservationIgnored private var initialized = false
    @ObservationIgnored private var ad: RewardedAd?
    @ObservationIgnored private var earned = false
    @ObservationIgnored private var presentation: CheckedContinuation<Bool, Error>?
    var testing: Bool { (Bundle.main.object(forInfoDictionaryKey: "KoharuAdsTesting") as? String)?.uppercased() == "YES" }
    private var unit: String {
        testing ? "ca-app-pub-3940256099942544/1712485313" : (Bundle.main.object(forInfoDictionaryKey: "KoharuRewardedAdUnit") as? String ?? "")
    }
    func refreshConsent() async {
        if let consentTask { await consentTask.value; return }
        guard !consentRequested else { return }
        consentRequested = true
        let task = Task {
            do { try await ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters()) }
            catch { consentRequested = false }
            privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        }
        consentTask = task
        await task.value
        consentTask = nil
    }
    func showPrivacyOptions() async throws {
        try await ConsentForm.presentPrivacyOptionsForm(from: nil)
        privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
    }
    func watch(purpose: String, action: CreditAction, credits: CreditStore) async throws {
        guard !working else { return }
        guard credits.loaded else { throw AppError.message(L("Could not open credit profile")) }
        let userID = credits.profile.id
        working = true; status = L("Loading rewarded ad…")
        defer { working = false; status = ""; ad = nil }
        do {
            await refreshConsent()
            try await ConsentForm.loadAndPresentIfRequired(from: nil)
            guard ConsentInformation.shared.canRequestAds else { throw unavailable }
            if !initialized { _ = await MobileAds.shared.start(); initialized = true }
            ad = try await RewardedAd.load(with: unit, request: Request())
            ad?.fullScreenContentDelegate = self
        } catch { throw unavailable }
        try Task.checkCancellation()
        guard credits.profile.id == userID, let ad else { throw NakamaFailure(status: 401) }
        let ticket = try await credits.startVideo(purpose: purpose, action: action)
        guard credits.profile.id == userID else { throw NakamaFailure(status: 401) }
        earned = false
        status = L("Watching rewarded ad…")
        let completed = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            presentation = continuation
            ad.present(from: nil) { [weak self] in self?.earned = true }
        }
        guard completed else { return } // Closing before the SDK reward event earns nothing.
        guard credits.profile.id == userID else { throw NakamaFailure(status: 401) }
        status = L("Updating reward…")
        // The SDK's earned callback is the sole ad-completion check. The existing
        // profile command persists the reward; no SSV callback or timer grants it.
        try await credits.completeVideo(ticket)
    }
    private var unavailable: AppError { .message(L("Rewarded ads are unavailable right now. Please try again later.")) }
    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        let continuation = presentation; presentation = nil
        continuation?.resume(returning: earned)
    }
    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        let continuation = presentation; presentation = nil
        continuation?.resume(throwing: unavailable)
    }
}
