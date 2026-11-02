import Foundation
import UserNotifications

struct CreditReminder {
    static let prefix = "daily-credit-"
    static let days = 30

    static func requests(nextReset: Date, now: Date = .now, timeZone: TimeZone = .current,
                         title: String, body: String, namespace: String = UUID().uuidString) -> [UNNotificationRequest] {
        // Nakama resets on UTC days. Convert each absolute reset separately so
        // local DST changes cannot move the reminder away from that instant.
        let elapsed = now.timeIntervalSince(nextReset)
        let first = elapsed < 0 ? nextReset : nextReset.addingTimeInterval((floor(elapsed / 86_400) + 1) * 86_400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return (0..<days).map { day in
            let date = first.addingTimeInterval(Double(day) * 86_400)
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            components.calendar = calendar; components.timeZone = timeZone
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.sound = .default
            content.userInfo = ["kind": "daily_credit"]
            return UNNotificationRequest(identifier: prefix + namespace + "-" + String(Int(date.timeIntervalSince1970)), content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        }
    }
}
