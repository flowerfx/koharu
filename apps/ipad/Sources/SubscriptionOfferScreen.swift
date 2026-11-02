import SwiftUI
import StoreKit

struct SubscriptionOfferScreen: View {
    let subscriptions: SubscriptionStore
    let policy: CreditConfiguration
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(spacing: 12) {
                        Image(systemName: "crown.fill").font(.system(size: 46)).foregroundStyle(.pink)
                        Text(L("Unlock Premium")).font(.largeTitle.bold()).multilineTextAlignment(.center)
                        Text(L("More room to translate and create.")).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 18) {
                        benefit("gift", String(format: L("%lld daily credits instead of %lld"), Int64(policy.daily(.premium)), Int64(policy.daily(.free))))
                        benefit("paintpalette", String(format: L("Image generation: %lld credits per image"), Int64(policy.cost(.image, tier: .premium))))
                        benefit("wand.and.stars", String(format: L("Prompt enhancement: %lld credits instead of %lld"), Int64(policy.cost(.enhance, tier: .premium)), Int64(policy.cost(.enhance, tier: .free))))
                        benefit("character.bubble", L("Access all supported translation providers"))
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.pink.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                    Text(L("Daily credits must be claimed. Provider accounts, API fees, model downloads and device requirements may still apply."))
                        .font(.footnote).foregroundStyle(.secondary)
                    if subscriptions.loading { ProgressView(L("Loading subscription…")).frame(maxWidth: .infinity) }
                    if let product = subscriptions.product {
                        VStack(spacing: 8) {
                            Text(product.displayName).font(.headline)
                            Text(String(format: L("%@ / month"), product.displayPrice)).font(.title2.bold())
                        }.frame(maxWidth: .infinity)
                    }
                    if let message = subscriptions.message {
                        Text(message).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("subscription-message")
                    }
                    VStack(spacing: 14) {
                        Button {
                            Task { await subscriptions.purchase() }
                        } label: {
                            HStack {
                                if subscriptions.purchasing { ProgressView() }
                                Text(L("Subscribe monthly")).font(.headline)
                            }.frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent).tint(.pink)
                        .disabled(subscriptions.product == nil || subscriptions.loading || subscriptions.purchasing)
                        .accessibilityIdentifier("subscription-purchase")
                        Button(L("Continue for free")) { subscriptions.continueWithoutSubscription() }
                            .font(.headline).accessibilityIdentifier("subscription-continue")
                        HStack(spacing: 24) {
                            Button(L("Restore purchases")) { Task { await subscriptions.restore() } }
                                .disabled(subscriptions.purchasing)
                            if subscriptions.product == nil {
                                Button(L("Try again")) { Task { await subscriptions.refresh() } }
                                    .disabled(subscriptions.loading || subscriptions.purchasing)
                            }
                        }.font(.footnote)
                    }
                    Text(L("Payment is charged to your Apple Account. Renews automatically each month unless canceled at least 24 hours before the period ends. Manage or cancel in your Apple Account settings."))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 24) {
                        Link(L("Privacy Policy"), destination: URL(string: "https://www.kuruby.com/privacy-policy")!)
                        Link(L("Terms of Service"), destination: URL(string: "https://www.kuruby.com/terms-of-service")!)
                    }.font(.caption).frame(maxWidth: .infinity)
                }
                .padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            .navigationTitle(L("Premium"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    private func benefit(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: symbol).foregroundStyle(.pink).frame(width: 28)
        }
    }
}
