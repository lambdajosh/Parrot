import Foundation
import UserNotifications

/// Native macOS notifications for the few events the user must see even
/// while Parrot sits behind the call window, above all the other side's
/// audio going dead mid-recording. Requests permission lazily, on the first
/// recording. A silent no-op in the CLI harnesses: the bare `swift build`
/// binary has no bundle, and UNUserNotificationCenter aborts without one.
final class Notifier {
    static let shared = Notifier()

    /// One identifier per topic, so an update replaces the banner instead of
    /// stacking a second one.
    static let systemAudioID = "system-audio"

    private var authorizationRequested = false
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorizationIfNeeded() {
        guard available, !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AudioCaptureManager.oslog.error("notification permission: \(error.localizedDescription, privacy: .public)")
            } else {
                AudioCaptureManager.oslog.log("notification permission \(granted ? "granted" : "declined", privacy: .public)")
            }
        }
    }

    /// Posts, or replaces, the notification with `id`.
    func post(id: String, title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AudioCaptureManager.oslog.error("notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
