import Foundation
import UserNotifications

/// Native macOS notifications for the few events the user must see even
/// while Parrot sits behind the call window: the other side's audio going
/// dead mid-recording, a meeting about to start, a recording started or saved
/// on the user's behalf. Requests permission lazily. A silent no-op in the
/// CLI harnesses: the bare `swift build` binary has no bundle, and
/// UNUserNotificationCenter aborts without one.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// One identifier per topic, so an update replaces the banner instead of
    /// stacking a second one.
    static let systemAudioID = "system-audio"
    /// Category whose banner carries a "Start Recording" button.
    static let meetingStartCategory = "meeting-start"
    static let startRecordingAction = "start-recording"

    /// Invoked on the main queue when the user taps "Start Recording" on a
    /// meeting reminder. Set by MeetingScheduler.
    var onStartRecording: (() -> Void)?

    private var authorizationRequested = false
    /// False in the CLI harnesses (no bundle), where UNUserNotificationCenter aborts.
    var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
    private var available: Bool { isAvailable }

    /// Registers the action category and takes the delegate role, so taps on
    /// banners come back to us and banners still show while Parrot is
    /// frontmost. Call once, at launch, from the app delegate.
    func install() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let start = UNNotificationAction(identifier: Self.startRecordingAction, title: "Start Recording",
                                         options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.meetingStartCategory, actions: [start],
                                   intentIdentifiers: [], options: []),
        ])
    }

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
    func post(id: String, title: String, body: String, category: String? = nil) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AudioCaptureManager.oslog.error("notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == Self.startRecordingAction {
            await MainActor.run { onStartRecording?() }
        }
    }
}
