import SwiftUI

struct CreditSummary: View {
    @Environment(MangaLibrary.self) private var library
    var body: some View {
        HStack(spacing: 12) {
            Label("\(library.credits.profile.credit) \(L("credits"))", systemImage: "sparkles").monospacedDigit()
            Text(library.credits.tier.title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(L(library.credits.canClaimDaily ? "Daily reward" : "Get credits")) { library.showCreditRewards = true }
                .disabled(library.busy || library.downloadingModel)
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
            Text(L("Rewarded videos are simulated in this build. No real advertisement is shown."))
                .font(.caption).foregroundStyle(.orange)
            LabeledContent(L("Profile ID"), value: library.credits.profile.id.uuidString).font(.caption).textSelection(.enabled)
            LabeledContent(L("Next reward (UTC)"), value: library.credits.nextDaily.ISO8601Format()).font(.caption)
            if let expiry = library.credits.profile.next_subscription_date {
                LabeledContent(L("Subscription ends (UTC)"), value: expiry.ISO8601Format()).font(.caption)
            }
            if let failure = library.credits.failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
    }
}

private struct CreditVideo: Identifiable { let id: String }

struct CreditPanel: View {
    @Environment(MangaLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var video: CreditVideo?
    @State private var notice: String?
    @State private var freeVideoAction: CreditAction = .translate
    private var account: CreditStore { library.credits }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(L("Membership"), value: account.tier.title)
                    LabeledContent(L("Credits"), value: String(account.profile.credit)).font(.title2)
                }
                if let request = library.creditRequest {
                    Section(request.action.title) {
                        LabeledContent(L("Cost"), value: "\(request.cost) \(L("credits"))")
                        if !request.explanation.isEmpty { Text(request.explanation).font(.callout) }
                        if account.hasVideoAccess(request.action) {
                            Label(L("One video access will be used instead of credits."), systemImage: "play.rectangle")
                        }
                        if account.canAfford(request.cost, action: request.action) {
                            Button(L("Continue")) {
                                library.approvedCreditRequest = request
                                dismiss()
                            }.buttonStyle(.borderedProminent).accessibilityIdentifier("credit-continue")
                        } else {
                            Label(L("Not enough credits"), systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                            rewardVideoButton(for: request.action)
                            if account.tier == .premium || request.action.supportsFreeVideo || account.canClaimDaily {
                                Text(L("Claim an available daily reward, watch a rewarded video, or wait until the next UTC day."))
                                    .font(.callout)
                            }
                        }
                        if request.canChangeProvider {
                            Button(L("Change provider"), systemImage: "arrow.triangle.swap") {
                                library.showCreditProviderSettings = true
                                dismiss()
                            }
                            Text(L("Translating from Rawkuma costs credits. Reruns cost credits only with Backend API. Reading downloaded chapters is free."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section(L("Daily reward")) {
                    if account.canClaimDaily {
                        LabeledContent(L("Today's reward"), value: "\(account.policy.daily(account.tier)) \(L("credits"))")
                        Button(L("Claim daily reward"), systemImage: "gift") { claimDaily() }
                            .accessibilityIdentifier("credit-claim-daily")
                        Button {
                            startVideo("daily", action: .translate)
                        } label: {
                            Label(String(format: L("Watch video and claim %d credits"), Int((Double(account.policy.daily(account.tier)) * account.policy.reward_video_multiplier).rounded(.down))), systemImage: "play.rectangle")
                        }.accessibilityIdentifier("credit-daily-video")
                        Text(L("The video multiplier applies to today's daily reward. Claiming either option uses today's reward."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label(L("Today's reward has already been claimed."), systemImage: "checkmark.circle")
                        LabeledContent(L("Next reward (UTC)"), value: account.nextDaily.ISO8601Format()).font(.caption)
                    }
                }
                if library.creditRequest == nil {
                    Section(L("Rewarded video")) {
                        if account.tier == .free {
                            Picker(L("Video reward"), selection: $freeVideoAction) {
                                ForEach(CreditAction.allCases.filter(\.supportsFreeVideo)) { Text($0.title).tag($0) }
                            }
                        }
                        rewardVideoButton(for: freeVideoAction)
                        if account.tier == .premium {
                            Text(L("You can watch again whenever you need more credits. Credits are awarded only after the video completes."))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(L("Free videos unlock one translation or image without adding credits. Enhance and random prompts need credits."))
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(CreditAction.allCases.filter(\.supportsFreeVideo)) { action in
                                LabeledContent(action.title, value: String(account.videoAccess[action.rawValue, default: 0]))
                            }
                        }
                    }
                }
                Section {
                    Text(L("Rewarded videos are simulated in this build. No real advertisement is shown."))
                        .font(.caption).foregroundStyle(.orange)
                    Text(L("Daily rewards reset at 00:00 UTC. Unused credits carry over; missed days are not accumulated."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(account.working)
            .navigationTitle(L(library.creditRequest == nil ? "Daily reward" : "Confirm credit use"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
            .sheet(item: $video) { purpose in
                OfflineRewardVideo {
                    Task {
                        do { try await account.completeVideo(purpose.id) }
                        catch { notice = error.localizedDescription }
                        video = nil
                    }
                }
            }
            .alert(L("Credits"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button(L("OK")) { notice = nil }
            } message: { Text(notice ?? "") }
        }
        .presentationSizing(.page)
    }
    private func claimDaily() {
        Task {
            do { try await account.claimDaily() }
            catch { notice = error.localizedDescription }
        }
    }
    private func startVideo(_ purpose: String, action: CreditAction) {
        Task {
            do { video = CreditVideo(id: try await account.startVideo(purpose: purpose, action: action)) }
            catch { notice = error.localizedDescription }
        }
    }
    @ViewBuilder private func rewardVideoButton(for action: CreditAction) -> some View {
        if account.tier == .premium {
            Button { startVideo("bonus", action: freeVideoAction) } label: {
                Label(String(format: L("Watch video to get %d credits"), account.policy.reward_video_credit), systemImage: "play.rectangle")
            }.accessibilityIdentifier("credit-bonus-video")
        } else if action.supportsFreeVideo {
            Button(L("Watch video to unlock this action"), systemImage: "play.rectangle") {
                freeVideoAction = action; startVideo("bonus", action: freeVideoAction)
            }.accessibilityIdentifier("credit-bonus-video")
        } else {
            Text(L("Free videos unlock one translation or image without adding credits. Enhance and random prompts need credits."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct OfflineRewardVideo: View {
    let complete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ready = false
    @State private var awarded = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "play.rectangle.fill").font(.system(size: 64)).foregroundStyle(.pink)
                Text(L("Rewarded video simulation")).font(.title2)
                Text(L("This is a short offline preview. Closing it early gives no reward.")).multilineTextAlignment(.center)
                if ready {
                    Button(L("Complete video and claim")) {
                        guard !awarded else { return }
                        awarded = true; complete()
                    }.buttonStyle(.borderedProminent).disabled(awarded).accessibilityIdentifier("credit-video-complete")
                } else { ProgressView(L("Playing demo video…")) }
            }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } } }
            .task {
                do { try await Task.sleep(for: .seconds(3)); try Task.checkCancellation(); ready = true }
                catch { }
            }
        }
        .presentationSizing(.page)
        .interactiveDismissDisabled(awarded)
    }
}
