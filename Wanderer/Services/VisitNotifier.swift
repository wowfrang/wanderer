import Foundation
import UserNotifications

/// A quiet local notification when a visit is detected while the phone is in your pocket.
enum VisitNotifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func notify(visited: String, next: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Visited \(visited)"
        if let next { content.body = "Next: \(next)" }
        content.interruptionLevel = .passive
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
