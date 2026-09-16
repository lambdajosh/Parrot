import Foundation
import SwiftData
import os

/// Watches the calendar while Parrot runs in the background and turns it into
/// actions: a "meeting is about to start" notification, and, when the user
/// opts in, starting a recording as each video call begins and stopping it
/// once the call has ended and gone quiet. Back-to-back calls become separate
/// meetings because the next event's start ends the previous recording.
///
/// The decision logic is a pure function of a snapshot (`plan`) so the
/// harness can drive it with fake clocks; this class only gathers the
/// snapshot every `tickInterval` and performs the actions.
@MainActor
@Observable
final class MeetingScheduler {
    static let remindKey = "meetingRemindersEnabled"
    static let autoRecordKey = "autoRecordMeetings"
    static let oslog = Logger(subsystem: "com.uygar.parrot", category: "scheduler")

    /// Reminder lead: two minutes is enough to open the call and not so long
    /// that the banner is forgotten. A UX choice, not measured.
    nonisolated static let reminderLead: TimeInterval = 120
    /// Auto-record begins one minute before the scheduled start so the
    /// opening words are never missed. A UX choice, not measured.
    nonisolated static let startLead: TimeInterval = 60
    /// After the scheduled end, stop once the transcript has been idle this
    /// long: the call is over and everyone left. Two minutes tolerates the
    /// usual goodbyes and a short overrun pause; a meeting that runs long
    /// keeps producing lines and is never cut. A UX choice, not measured.
    nonisolated static let endIdle: TimeInterval = 120
    nonisolated static let tickInterval: TimeInterval = 20

    /// Everything a decision needs, captured at one instant.
    struct Snapshot {
        var now: Date
        /// Video call covering now (with `startLead` applied by the caller).
        var current: ScheduledMeeting?
        /// Next video call that has not started.
        var next: ScheduledMeeting?
        var isRecording: Bool
        /// The calendar event the running recording was matched to, if any.
        var recordingEvent: ScheduledMeeting?
        var recordingStartedAt: Date?
        /// Last transcript line from either side.
        var lastActivityAt: Date?
        var remindersEnabled: Bool
        var autoRecordEnabled: Bool
        var reminded: Set<String>
        /// Events not to auto-start (again): stopped by hand or already recorded.
        var suppressed: Set<String>
    }

    enum Action: Equatable {
        case remind(ScheduledMeeting)
        case start(ScheduledMeeting)
        case switchTo(ScheduledMeeting)
        case stop(ScheduledMeeting)
    }

    nonisolated static func plan(_ s: Snapshot) -> [Action] {
        var actions: [Action] = []
        if s.remindersEnabled, let next = s.next, !s.reminded.contains(next.id),
           next.start > s.now, next.start.timeIntervalSince(s.now) <= reminderLead {
            actions.append(.remind(next))
        }
        guard s.autoRecordEnabled else { return actions }
        if !s.isRecording {
            if let current = s.current, !s.suppressed.contains(current.id) {
                actions.append(.start(current))
            }
        } else if let event = s.recordingEvent {
            if let current = s.current, current.id != event.id, s.now >= current.start,
               !s.suppressed.contains(current.id) {
                actions.append(.switchTo(current))
            } else if s.now > event.end {
                let idleSince = s.lastActivityAt ?? s.recordingStartedAt ?? s.now
                if s.now.timeIntervalSince(idleSince) >= endIdle {
                    actions.append(.stop(event))
                }
            }
        }
        return actions
    }

    let calendar: CalendarService
    private weak var recordingManager: RecordingManager?
    private let modelContext: ModelContext
    private var timer: Timer?
    private var reminded: Set<String> = []
    private var suppressed: Set<String> = []
    /// The event of the recording seen on the previous tick, to notice a stop
    /// the user made by hand and not restart that meeting.
    private var observedRecordingEventID: String?
    private var stoppingBySchedule = false
    /// One line for the dashboard: the last thing the scheduler did.
    private(set) var lastAction: String?

    var remindersEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.remindKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.remindKey) }
    }
    var autoRecordEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoRecordKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoRecordKey) }
    }

    init(calendar: CalendarService, recordingManager: RecordingManager, modelContext: ModelContext) {
        self.calendar = calendar
        self.recordingManager = recordingManager
        self.modelContext = modelContext
        Notifier.shared.onStartRecording = { [weak self] in
            Task { @MainActor [weak self] in await self?.startFromNotification() }
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tick() }
        }
        Task { await tick() }
    }

    func tick(now: Date = .now) async {
        guard let recordingManager, calendar.isActive else { return }
        if remindersEnabled || autoRecordEnabled {
            Notifier.shared.requestAuthorizationIfNeeded()
        }
        // Periodic re-read: EventKit posts change notifications, but a window
        // that slides with the clock needs its own refresh.
        if let last = calendar.lastRefresh, now.timeIntervalSince(last) > 10 * 60 { calendar.refresh(now: now) }

        let recordingEvent = recordingManager.currentMeeting?.calendarEventID
            .flatMap { id in calendar.meetings.first { $0.id == id } }
        // A recording that ended without the scheduler stopping it was stopped
        // by the user: leave that meeting alone for the rest of its window.
        if !recordingManager.isRecording, let seen = observedRecordingEventID, !stoppingBySchedule {
            suppressed.insert(seen)
        }
        observedRecordingEventID = recordingManager.isRecording ? recordingEvent?.id : nil
        stoppingBySchedule = false

        let snapshot = Snapshot(
            now: now,
            current: calendar.currentMeeting(at: now, leadIn: Self.startLead, videoOnly: true),
            next: calendar.nextMeeting(after: now),
            isRecording: recordingManager.isRecording,
            recordingEvent: recordingEvent,
            recordingStartedAt: recordingManager.recordingStartTime,
            lastActivityAt: recordingManager.lastSegmentAt,
            remindersEnabled: remindersEnabled,
            autoRecordEnabled: autoRecordEnabled,
            reminded: reminded,
            suppressed: suppressed)
        for action in Self.plan(snapshot) {
            await perform(action, now: now)
        }
    }

    private func perform(_ action: Action, now: Date) async {
        guard let recordingManager else { return }
        switch action {
        case .remind(let event):
            reminded.insert(event.id)
            let minutes = max(1, Int((event.start.timeIntervalSince(now) / 60).rounded()))
            let body = autoRecordEnabled
                ? "Parrot will start recording in \(minutes) min."
                : "Starts in \(minutes) min. Start recording now?"
            Notifier.shared.post(id: "meeting-\(event.id)", title: event.title, body: body,
                                 category: autoRecordEnabled ? nil : Notifier.meetingStartCategory)
            Self.oslog.log("reminded: \(event.title, privacy: .public)")
        case .start(let event):
            do {
                try await recordingManager.preflightPermissionsAndStart(modelContext: modelContext)
                guard recordingManager.isRecording else { return }
                lastAction = "Recording \(event.title)"
                Self.oslog.log("auto-started: \(event.title, privacy: .public)")
                Notifier.shared.post(id: "recording-\(event.id)", title: "Recording \(event.title)",
                                     body: "Parrot started with your calendar. Stop it from the menu bar if this is wrong.")
            } catch {
                // Model still loading, permission flow pending: try again next tick.
                Self.oslog.error("auto-start failed: \(error.localizedDescription, privacy: .public)")
            }
        case .switchTo(let event):
            stoppingBySchedule = true
            if let previous = recordingManager.currentMeeting?.calendarEventID { suppressed.insert(previous) }
            await recordingManager.stopRecording()
            Self.oslog.log("switching recordings at the start of: \(event.title, privacy: .public)")
            await perform(.start(event), now: now)
        case .stop(let event):
            stoppingBySchedule = true
            suppressed.insert(event.id)
            await recordingManager.stopRecording()
            lastAction = "Saved \(event.title)"
            Self.oslog.log("auto-stopped after the call went quiet: \(event.title, privacy: .public)")
            Notifier.shared.post(id: "recording-\(event.id)", title: "Saved \(event.title)",
                                 body: "The call ended and went quiet, so Parrot stopped and is writing the report.")
        }
    }

    private func startFromNotification() async {
        guard let recordingManager, !recordingManager.isRecording else { return }
        do {
            try await recordingManager.preflightPermissionsAndStart(modelContext: modelContext)
        } catch {
            Self.oslog.error("start from notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
