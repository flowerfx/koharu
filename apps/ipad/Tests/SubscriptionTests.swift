import XCTest
import StoreKit
import SwiftUI
@testable import KoharuPad

final class SubscriptionTests: XCTestCase {
    @MainActor func testContinueWorksWithoutCatalogAndAuthenticationCannotGrantPremium() throws {
        let credits = CreditStore(authentication: NakamaAuthentication(), policy: try CreditConfiguration.bundled())
        let store = SubscriptionStore(credits: credits, environment: .production)
        XCTAssertFalse(store.hasPremium)
        XCTAssertFalse(credits.tier.allows(.gemini))
        store.showOffer = true
        store.continueWithoutSubscription()
        XCTAssertFalse(store.showOffer)
        XCTAssertTrue(store.launchOfferFinished)
        XCTAssertEqual(store.productID, "com.kurubyInteractive.aimanga.premium.monthly")
        let staging = SubscriptionStore(credits: credits, environment: .staging)
        XCTAssertEqual(staging.productID, "com.kurubyInteractive.aimanga.staging.premium.monthly")
    }
    @MainActor func testCloudAccountSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MangaLibrary(disk: try LibraryDisk(root: root))
        await library.backendAuthentication.restore()
        if library.backendAuthentication.user != nil { try await library.credits.load() }
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.language = previous }
        AppLocalization.shared.language = .vietnamese
        let view = NavigationStack {
            Form {
                NakamaAccountSection()
                if library.credits.loaded { CreditAccountSection() }
            }.navigationTitle(L("Credits and membership"))
        }.environment(library)
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 1100)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Cloud account Vietnamese"; attachment.lifetime = .keepAlways; add(attachment)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try XCTUnwrap(image.pngData()).write(to: documents.appendingPathComponent("cloud-account-vi.png"))
        window.isHidden = true
    }

    @MainActor func testOfferSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credits = CreditStore(authentication: NakamaAuthentication(), policy: try CreditConfiguration.bundled())
        let store = SubscriptionStore(credits: credits, environment: .staging)
        await store.prepareLaunchOffer()
        let previousLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.language = previousLanguage }
        AppLocalization.shared.language = .vietnamese
        let host = UIHostingController(rootView: SubscriptionOfferScreen(subscriptions: store, policy: credits.policy))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 1100)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Premium offer Vietnamese"
        attachment.lifetime = .keepAlways
        add(attachment)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try XCTUnwrap(image.pngData()).write(to: documents.appendingPathComponent("subscription-offer-vi.png"))
        window.isHidden = true
    }
}
