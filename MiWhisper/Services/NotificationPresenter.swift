import Foundation
import UserNotifications

final class NotificationPresenter {
    static let shared = NotificationPresenter()

    private let center = UNUserNotificationCenter.current()

    private init() {}

    func requestAuthorizationIfNeeded() {
        let center = self.center
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func refreshAuthorizationStatus(_ handler: @escaping @MainActor (Bool) -> Void) {
        center.getNotificationSettings { settings in
            let authorized =
                settings.authorizationStatus == .authorized ||
                settings.authorizationStatus == .provisional

            Task { @MainActor in
                handler(authorized)
            }
        }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "miwhisper-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request)
    }
}
