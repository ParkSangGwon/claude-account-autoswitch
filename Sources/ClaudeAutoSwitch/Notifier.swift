import AppKit
import Foundation
import UserNotifications
import AutoSwitchCore

/// Posts alerts through UNUserNotificationCenter. A no-op outside a bundle
/// (`swift run` has no bundle identifier and the centre would crash).
@MainActor
@Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// What the system says about permission, so the settings screen can stop promising alerts
    /// the Mac will never show. Unknown until the first check answers.
    private(set) var permission: UNAuthorizationStatus?
    private let available = Bundle.main.bundleIdentifier != nil
    /// Set by the app so a tapped notification can open the popover.
    @ObservationIgnored var onOpen: (() -> Void)?

    private override init() {
        super.init()
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        guard available else { return }
        // The async API answers on the main actor; the completion-handler form calls back on a
        // private queue, which Swift 6.1 builds trap on when the closure is inferred @MainActor.
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refreshPermission()
        }
    }

    func refreshPermission() async {
        guard available else { return }
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Alerts are switched on in Settings but the Mac will not show them.
    var isBlocked: Bool {
        guard let permission else { return false }
        return permission == .denied
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

    /// Clicking an alert opens the popover — otherwise the alert says something happened and
    /// leaves the person to go and find the menu bar item themselves.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in Notifier.shared.onOpen?() }
        completionHandler()
    }

    /// The app has no windows, so an alert that arrives while it is frontmost would otherwise be dropped.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
