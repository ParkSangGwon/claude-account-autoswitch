import AppKit
import Foundation
import UserNotifications
import AutoSwitchCore

/// Posts alerts through UNUserNotificationCenter. A no-op outside a bundle
/// (`swift run` has no bundle identifier and the centre would crash).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let available = Bundle.main.bundleIdentifier != nil
    /// Set by the app so a clicked notification can open the popover.
    var onOpen: (() -> Void)?

    private override init() { super.init() }

    func requestAuthorization() {
        guard available else { return }
        // Everything that touches the centre waits until here: `Notifier.shared` is reached during
        // launch, and a centre call from an initialiser takes the app down where there is no bundle.
        UNUserNotificationCenter.current().delegate = self
        // The async API answers on the main actor; the completion-handler form calls back on a
        // private queue, which Swift 6.1 builds trap on when the closure is inferred @MainActor.
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Whether the Mac will actually show what the alert switches promise. `UNNotificationSettings`
    /// is not Sendable, so only the status crosses back.
    func isBlocked() async -> Bool {
        guard available else { return false }
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<UNAuthorizationStatus, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { continuation.resume(returning: $0.authorizationStatus) }
        }
        return status == .denied
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
