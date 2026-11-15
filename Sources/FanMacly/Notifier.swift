import Foundation
import UserNotifications

/// Local notifications for changes that happen while the panel is closed.
@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let resumeAction = "RESUME"
    nonisolated static let category = "CONTROL"
    var onResume: (() -> Void)?
    private var authorized: Bool?
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter requires a bundled app (not `swift run`/tests).
        Bundle.main.bundleIdentifier == nil || Bundle.main.bundleURL.pathExtension != "app" ? nil : .current()
    }

    func configure() {
        guard let center else { return }
        center.delegate = self
        let resume = UNNotificationAction(identifier: Self.resumeAction, title: "Вернуть режим", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [resume], intentIdentifiers: [])])
    }

    func post(title: String, body: String, resumable: Bool = false, id: String = UUID().uuidString) {
        guard let center else { return }
        Task {
            if authorized == nil {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if resumable { content.categoryIdentifier = Self.category }
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == Self.resumeAction else { return }
        await MainActor.run { onResume?() }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
