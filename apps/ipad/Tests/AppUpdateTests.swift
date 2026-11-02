import XCTest
@testable import KoharuPad

final class AppUpdateTests: XCTestCase {
    private let store = "https://apps.apple.com/app/id123456789"

    func testNumericVersionBoundary() {
        XCTAssertNotNil(AppUpdate.required(current: "1.0.9", minimum: "1.0.10", enabled: true, store: store, allowTestFlight: false))
        XCTAssertNil(AppUpdate.required(current: "1.0", minimum: "1.0.0", enabled: true, store: store, allowTestFlight: false))
        XCTAssertNil(AppUpdate.required(current: "2.0.0", minimum: "1.99.99", enabled: true, store: store, allowTestFlight: false))
    }

    func testDisabledOrMalformedPolicyNeverBlocks() {
        XCTAssertNil(AppUpdate.required(current: "1.0.0", minimum: "2.0.0", enabled: false, store: store, allowTestFlight: false))
        for version in ["", "1..2", "1.0.beta", "1.0.0.1", "-2", String(repeating: "9", count: 80)] {
            XCTAssertNil(AppUpdate.required(current: "1.0.0", minimum: version, enabled: true, store: store, allowTestFlight: false))
        }
        for url in ["", "https://example.com/app/id123", "http://apps.apple.com/app/id123", "https://apps.apple.com/app/id", "https://apps.apple.com/app/idabc", "https://user:pass@apps.apple.com/app/id123"] {
            XCTAssertNil(AppUpdate.required(current: "1.0.0", minimum: "2.0.0", enabled: true, store: url, allowTestFlight: false))
        }
    }

    func testTestFlightOnlyForStaging() {
        let url = "https://testflight.apple.com/join/AbCd1234"
        XCTAssertNotNil(AppUpdate.required(current: "1.0.0", minimum: "2.0.0", enabled: true, store: url, allowTestFlight: true))
        XCTAssertNil(AppUpdate.required(current: "1.0.0", minimum: "2.0.0", enabled: true, store: url, allowTestFlight: false))
        XCTAssertNil(AppUpdate.required(current: "1.0.0", minimum: "2.0.0", enabled: true, store: "https://testflight.apple.com/join", allowTestFlight: true))
    }
}
