import SwiftUI

struct CreditSummary: View {
    @Environment(MangaLibrary.self) private var library
    var body: some View {
        HStack(spacing: 12) {
            if library.credits.loaded {
                Label("\(library.credits.profile.credit) \(L("credits"))", systemImage: "sparkles").monospacedDigit()
                Text(library.credits.tier.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L(library.credits.canClaimDaily ? "Daily reward" : "Get credits")) { library.showCreditRewards = true }
                    .disabled(library.busy || library.downloadingModel)
            } else {
                Label(L("Offline · saved chapters only"), systemImage: "wifi.slash").foregroundStyle(.secondary)
                Spacer()
                if library.credits.working { ProgressView().controlSize(.small) }
                Button(L("Try again")) { Task { await library.loginCredits() } }
                    .disabled(library.credits.working)
            }
        }
        .font(.subheadline).padding(.horizontal).padding(.vertical, 8).background(.bar)
    }
}

struct CreditAccountSection: View {
    @Environment(MangaLibrary.self) private var library
    var body: some View {
        Section(L("Credits and membership")) {
            LabeledContent(L("Credits"), value: String(library.credits.profile.credit))
            LabeledContent(L("Membership"), value: library.credits.tier.title)
            Button(L("Daily reward"), systemImage: "gift") { library.showCreditRewards = true }
            Text(L("Daily rewards reset at 00:00 UTC. Unused credits carry over; missed days are not accumulated."))
                .font(.caption).foregroundStyle(.secondary)
            if library.subscriptions.hasPremium {
                Link(L("Manage subscription"), destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
            } else {
                Button(L("View Premium")) { library.subscriptions.showOffer = true }
            }
            if library.rewardedAds.privacyOptionsRequired {
                Button(L("Ad privacy choices")) {
                    Task { do { try await library.rewardedAds.showPrivacyOptions() } catch { library.error = error.localizedDescription } }
                }
            }
            LabeledContent(L("Profile ID"), value: library.credits.profile.id.uuidString).font(.caption).textSelection(.enabled)
            LabeledContent(L("Next reward (UTC)"), value: library.credits.nextDaily.ISO8601Format()).font(.caption)
            if let expiry = library.credits.profile.next_subscription_date {
                LabeledContent(L("Subscription ends (UTC)"), value: expiry.ISO8601Format()).font(.caption)
            }
            if let failure = library.credits.failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
    }
}

struct CreditPanel: View {
    @Environment(MangaLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var notice: String?
    private var account: CreditStore { library.credits }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(L("Membership")) {
                        HStack {
                            Text(account.tier.title)
                            if account.tier == .free {
                                Button(L("Upgrade to Premium")) {
                                    library.subscriptions.offerAfterCredits = true
                                    dismiss()
                                }
                                .buttonStyle(.borderedProminent)
                                .font(.subheadline)
                                .accessibilityIdentifier("credit-upgrade-premium")
                            }
                        }
                    }
                    LabeledContent(L("Credits"), value: String(account.profile.credit)).font(.title2)
                }
                if let request = library.creditRequest {
                    Section(request.action.title) {
                        LabeledContent(L("Cost"), value: "\(request.cost) \(L("credits"))")
                        if !request.explanation.isEmpty { Text(request.explanation).font(.callout) }
                        if account.canAfford(request.cost, operation: request.operation) {
                            Button(L("Continue")) { approve(request) }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("credit-continue")
                        } else {
                            Label(L("Not enough credits"), systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                            Text(L("Watch a rewarded video to continue this action without spending credits. It starts automatically after you earn the reward."))
                                .font(.callout)
                            Button(L("Watch video and continue"), systemImage: "play.rectangle") {
                                watchAction(request)
                            }.buttonStyle(.borderedProminent).accessibilityIdentifier("credit-action-video")
                            Button(L("Return"), role: .cancel) { dismiss() }
                                .accessibilityIdentifier("credit-return")
                        }
                        if request.canChangeProvider {
                            Button(L("Change provider"), systemImage: "arrow.triangle.swap") {
                                library.showCreditProviderSettings = true
                                dismiss()
                            }
                        }
                    }
                } else {
                    Section(L("Daily reward")) {
                        LabeledContent(L("Today's reward"), value: "\(account.policy.daily(account.tier)) \(L("credits"))")
                        if account.canClaimDaily {
                            Button(L("Claim daily reward"), systemImage: "gift") { claimDaily() }
                                .accessibilityIdentifier("credit-claim-daily")
                        } else {
                            Label(L("Today's reward has already been claimed."), systemImage: "checkmark.circle")
                        }
                        Button {
                            watchDaily()
                        } label: {
                            Label(String(format: L("Claim ×%g credits with video"), account.policy.reward_video_multiplier), systemImage: "play.rectangle")
                        }
                        .disabled(!account.dailyVideoAvailable)
                        .accessibilityIdentifier("credit-daily-video")
                        if account.dailyVideoAvailable {
                            Text(String(format: L("Watch a video to receive %d more credits today. You can also do this after claiming the normal reward."), account.dailyVideoBonus))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label(L("The video bonus is available again at the next daily reset."), systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        LabeledContent(L("Next reward (UTC)"), value: account.nextDaily.ISO8601Format()).font(.caption)
                    }
                }
                Section {
                    if library.rewardedAds.testing { Text(L("AdMob test ads")).font(.caption).foregroundStyle(.secondary) }
                    if library.rewardedAds.working { ProgressView(library.rewardedAds.status) }
                    if library.creditRequest == nil {
                        Text(L("Daily rewards reset at 00:00 UTC. Unused credits carry over; missed days are not accumulated."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(account.working || library.rewardedAds.working)
            .navigationTitle(L(library.creditRequest == nil ? "Daily reward" : "Confirm credit use"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L(library.creditRequest == nil ? "Close" : "Return")) { dismiss() }
                        .disabled(library.rewardedAds.working)
                }
            }
            .alert(L("Credits"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button(L("OK")) { notice = nil }
            } message: { Text(notice ?? "") }
        }
        .interactiveDismissDisabled(library.rewardedAds.working)
        .presentationSizing(.page)
    }
    private func approve(_ request: CreditRequest) {
        guard library.creditRequest?.id == request.id else { return }
        library.approvedCreditRequest = request
        dismiss()
    }
    private func claimDaily() {
        Task {
            do { try await account.claimDaily() }
            catch { notice = error.localizedDescription }
        }
    }
    private func watchAction(_ request: CreditRequest) {
        Task {
            do {
                let earned = try await library.rewardedAds.watch(purpose: "action", operation: request.operation, credits: account)
                if earned { approve(request) }
            } catch { notice = error.localizedDescription }
        }
    }
    private func watchDaily() {
        Task {
            do {
                _ = try await library.rewardedAds.watch(purpose: "daily", operation: CreditOperation(action: .translate, provider: .local, rerun: false), credits: account)
            } catch { notice = error.localizedDescription }
        }
    }
}
