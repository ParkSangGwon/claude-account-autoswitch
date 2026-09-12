import Foundation
import UserNotifications
import AutoSwitchCore

/// Posts alerts through UNUserNotificationCenter. A no-op outside a bundle
/// (`swift run` has no bundle identifier and the centre would crash).
@MainActor
final class Notifier {
    static let shared = Notifier()
    private var authorized = false
    private let available = Bundle.main.bundleIdentifier != nil

    func requestAuthorization() {
        guard available else { return }
        // The async API answers on the main actor; the completion-handler form calls back on a
        // private queue, which Swift 6.1 builds trap on when the closure is inferred @MainActor.
        Task {
            let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            authorized = ok
        }
    }

    func post(_ alert: Alert) {
        guard available else { NSLog("[ClaudeAutoSwitch] alert %@: %@ — %@", alert.id, alert.title, alert.body); return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        if alert.sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
