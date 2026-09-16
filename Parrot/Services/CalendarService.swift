import EventKit
import Foundation
import os

/// Reads the user's calendars through EventKit so a recording can know what
/// meeting it is (title, invitees, agenda, video link) and so the scheduler
/// can see what is coming. No Google account or cloud API: the macOS
/// Calendar app already syncs Google Calendar, and EventKit reads that copy
/// locally after one Calendars permission prompt. Opt-in via
/// `calendarContextEnabled`, because attendee names and agenda text become
/// part of the copilot brief, which leaves the Mac when a cloud copilot is on.
@MainActor
@Observable
final class CalendarService {
    static let enabledKey = "calendarContextEnabled"
    static let oslog = Logger(subsystem: "com.uygar.parrot", category: "calendar")

    /// How far around "now" `refresh` looks: enough for a late-running
    /// morning meeting and the rest of today's schedule.
    static let lookBehind: TimeInterval = 12 * 3600
    static let lookAhead: TimeInterval = 24 * 3600

    private let store = EKEventStore()
    private(set) var authorization = EKEventStore.authorizationStatus(for: .event)
    /// Timed, non-all-day events in the refresh window, soonest first.
    private(set) var meetings: [ScheduledMeeting] = []
    private(set) var lastRefresh: Date?
    private var changeObserver: NSObjectProtocol?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey); if newValue { refresh() } }
    }
    var hasAccess: Bool { authorization == .fullAccess }
    /// Enabled and permitted: the only state in which any caller reads events.
    var isActive: Bool { isEnabled && hasAccess }

    init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        if isActive { refresh() }
    }

    /// notDetermined → the one OS prompt; denied → the Settings pane, like the
    /// other permission flows. Returns whether reading is now possible.
    func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            authorization = .fullAccess
        case .notDetermined:
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            authorization = EKEventStore.authorizationStatus(for: .event)
            Self.oslog.log("calendar permission \(granted ? "granted" : "declined", privacy: .public)")
        default:
            PermissionFlow.openSettings(pane: "Privacy_Calendars")
            authorization = EKEventStore.authorizationStatus(for: .event)
        }
        if hasAccess { refresh() }
        return hasAccess
    }

    func refresh(now: Date = .now) {
        guard isActive else { meetings = []; return }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-Self.lookBehind),
            end: now.addingTimeInterval(Self.lookAhead),
            calendars: nil)
        meetings = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map(Self.meeting(from:))
            .sorted { $0.start < $1.start }
        lastRefresh = now
    }

    /// The meeting happening now, video calls first. `leadIn` lets a caller
    /// treat a meeting as current shortly before its start.
    func currentMeeting(at now: Date = .now, leadIn: TimeInterval = 0, videoOnly: Bool = false) -> ScheduledMeeting? {
        guard isActive else { return nil }
        return ScheduledMeeting.current(in: meetings, at: now, leadIn: leadIn, videoOnly: videoOnly)
    }

    func nextMeeting(after now: Date = .now) -> ScheduledMeeting? {
        guard isActive else { return nil }
        return ScheduledMeeting.next(in: meetings, after: now)
    }

    nonisolated static func meeting(from event: EKEvent) -> ScheduledMeeting {
        let attendees: [ScheduledMeeting.Attendee] = (event.attendees ?? []).compactMap { participant in
            guard participant.participantType == .person else { return nil }
            let email = participant.url.absoluteString.hasPrefix("mailto:")
                ? String(participant.url.absoluteString.dropFirst("mailto:".count)) : nil
            let name = participant.name ?? email ?? ""
            return ScheduledMeeting.Attendee(name: name, email: email, isMe: participant.isCurrentUser)
        }
        let declined = (event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
        return ScheduledMeeting(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Meeting",
            start: event.startDate,
            end: event.endDate,
            attendees: attendees,
            notes: event.notes,
            location: event.location,
            videoLink: ScheduledMeeting.videoLink(in: [event.location, event.url?.absoluteString, event.notes]),
            isDeclined: declined)
    }
}
