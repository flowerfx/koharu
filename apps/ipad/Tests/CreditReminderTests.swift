import XCTest
import UserNotifications
@testable import KoharuPad

final class CreditReminderTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func requests(_ reset: String, now: String, zone: String) -> [UNNotificationRequest] {
        CreditReminder.requests(nextReset: date(reset), now: date(now), timeZone: TimeZone(identifier: zone)!, title: "Daily reward", body: "Claim your credits", namespace: "test")
    }
    private func components(_ request: UNNotificationRequest) throws -> DateComponents {
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertFalse(trigger.repeats)
        return trigger.dateComponents
    }
    func testServerMidnightBecomesLocalTimeIncludingFractionalOffsets() throws {
        for (zone, hour, minute) in [("Asia/Ho_Chi_Minh", 7, 0), ("Asia/Kathmandu", 5, 45), ("UTC", 0, 0)] {
            let plan = requests("2026-11-03T00:00:00Z", now: "2026-11-02T12:00:00Z", zone: zone)
            XCTAssertEqual(plan.count, 30)
            let value = try components(XCTUnwrap(plan.first))
            XCTAssertEqual(value.hour, hour); XCTAssertEqual(value.minute, minute)
            XCTAssertEqual(try XCTUnwrap(value.calendar).date(from: value), date("2026-11-03T00:00:00Z"))
        }
    }
    func testDSTChangesLocalHourWhilePreservingEveryUTCDay() throws {
        let plan = requests("2027-03-13T00:00:00Z", now: "2027-03-12T12:00:00Z", zone: "America/Los_Angeles")
        let dates = try plan.prefix(3).map { try components($0) }
        XCTAssertEqual(dates.compactMap(\.hour), [16, 16, 17])
        for (index, value) in dates.enumerated() {
            XCTAssertEqual(try XCTUnwrap(value.calendar).date(from: value), date("2027-03-13T00:00:00Z").addingTimeInterval(Double(index) * 86_400))
        }
    }
    func testStaleProfileSkipsPastRewardsAndEverySlotIsUnique() throws {
        let plan = requests("2026-10-31T00:00:00Z", now: "2026-11-02T12:00:00Z", zone: "Asia/Ho_Chi_Minh")
        let first = try components(XCTUnwrap(plan.first))
        XCTAssertEqual(try XCTUnwrap(first.calendar).date(from: first), date("2026-11-03T00:00:00Z"))
        XCTAssertEqual(Set(plan.map(\.identifier)).count, 30)
        XCTAssertTrue(plan.allSatisfy { $0.identifier.hasPrefix(CreditReminder.prefix) })
        let other = CreditReminder.requests(nextReset: date("2026-11-03T00:00:00Z"), now: date("2026-11-02T12:00:00Z"), title: "Title", body: "Body", namespace: "new-account")
        XCTAssertTrue(Set(plan.map(\.identifier)).isDisjoint(with: other.map(\.identifier)))
    }
}
