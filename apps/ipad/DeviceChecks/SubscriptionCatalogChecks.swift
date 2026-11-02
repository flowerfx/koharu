import XCTest
import StoreKit
@testable import KoharuPad

final class SubscriptionCatalogChecks: XCTestCase {
    // This check talks to Apple's catalog without a StoreKit configuration or
    // purchasing anything. Run it in the matching signed app environment.
    @MainActor func testLiveMonthlyProduct() async throws {
        let environment = try ConfigurationTarget(bundle: .main).environment
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credits = CreditStore(authentication: NakamaAuthentication(), policy: try AppConfiguration.decode(AppConfiguration.bundledData()).credit)
        let store = SubscriptionStore(credits: credits, environment: environment)
        await store.prepareLaunchOffer()
        let report: [String: Any] = [
            "environment": environment.rawValue,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "requestedProductID": store.productID,
            "returnedProductID": store.product?.id ?? "",
            "displayName": store.product?.displayName ?? "",
            "displayPrice": store.product?.displayPrice ?? "",
            "currency": store.product?.priceFormatStyle.currencyCode ?? "",
            "price": store.product?.price.description ?? "",
            "message": store.message ?? "",
            "hasPremium": store.hasPremium,
            "offerPresented": store.showOffer,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Live subscription catalog \(environment.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try data.write(to: documents.appendingPathComponent("subscription-catalog-\(environment.rawValue).json"))
        store.continueWithoutSubscription()
        XCTAssertFalse(store.showOffer)
        XCTAssertTrue(store.launchOfferFinished)
        let product = try XCTUnwrap(store.product, "Apple's live catalog did not return \(store.productID): \(store.message ?? "")")
        XCTAssertEqual(product.id, store.productID)
        XCTAssertEqual(product.type, .autoRenewable)
        XCTAssertEqual(product.subscription?.subscriptionPeriod.value, 1)
        XCTAssertEqual(product.subscription?.subscriptionPeriod.unit, .month)
    }
}
