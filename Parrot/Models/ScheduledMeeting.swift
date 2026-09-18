import Foundation

/// A calendar event as Parrot sees it: what the meeting is, when it runs, who
/// was invited, and the video-call link if it has one. Built from EventKit
/// by CalendarService; everything here is a plain value so the matching and
/// brief-building rules can run in the harness without a calendar.
struct ScheduledMeeting: Identifiable, Equatable, Codable {
    struct Attendee: Equatable, Codable {
        var name: String
        var email: String?
        var isMe: Bool
    }

    /// EventKit's event identifier.
    var id: String
    var title: String
    var start: Date
    var end: Date
    var attendees: [Attendee] = []
    var notes: String?
    var location: String?
    var videoLink: URL?
    /// The user declined this invitation; never record or remind for it.
    var isDeclined = false

    var isVideoCall: Bool { videoLink != nil }

    /// Everyone but the user, in invitation order, as people read them
    /// (aliases from PeopleDirectory applied, so a brief says "Andrew Laski",
    /// not an address).
    var otherNames: [String] {
        attendees.filter { !$0.isMe && !$0.name.isEmpty }.map { PeopleDirectory.displayName(for: $0.name) }
    }

    /// The event's description with Google's Meet boilerplate removed, or nil
    /// when nothing human-written remains.
    var agenda: String? { Self.agenda(from: notes) }

    /// The copilot brief Parrot writes when the user typed none: enough for
    /// the model to know the purpose and the people before anyone speaks.
    var brief: String {
        var parts = ["Calendar event: \(title)."]
        let names = otherNames
        if !names.isEmpty { parts.append("With \(names.joined(separator: ", ")).") }
        if let agenda { parts.append("Agenda: \(agenda)") }
        return parts.joined(separator: " ")
    }

    // MARK: - Matching

    /// The meeting that is happening at `now`: not declined, started (or
    /// starting within `leadIn`) and not yet ended. Video calls win over
    /// events without a link, then the most recently started one, so a
    /// back-to-back second call takes over from the first at its start time.
    static func current(in meetings: [ScheduledMeeting], at now: Date,
                        leadIn: TimeInterval = 0, videoOnly: Bool = false) -> ScheduledMeeting? {
        meetings
            .filter { !$0.isDeclined && (!videoOnly || $0.isVideoCall)
                && $0.start.addingTimeInterval(-leadIn) <= now && now < $0.end }
            .sorted { a, b in
                if a.isVideoCall != b.isVideoCall { return a.isVideoCall }
                return a.start > b.start
            }
            .first
    }

    /// The next video call that has not started yet.
    static func next(in meetings: [ScheduledMeeting], after now: Date) -> ScheduledMeeting? {
        meetings
            .filter { !$0.isDeclined && $0.isVideoCall && $0.start > now }
            .min { $0.start < $1.start }
    }

    // MARK: - Text helpers

    private static let linkPatterns = [
        #"https?://meet\.google\.com/[A-Za-z0-9\-/?=&_.]+"#,
        #"https?://[A-Za-z0-9.\-]*zoom\.us/j/[A-Za-z0-9?=&_.\-]+"#,
        #"https?://teams\.microsoft\.com/l/meetup-join/[^\s<>"]+"#,
    ]

    /// The first video-call link found in any of `texts` (location, URL,
    /// notes). Google Meet first, since that is what the calendar puts in the
    /// event; Zoom and Teams links count too, so auto-record works for them.
    static func videoLink(in texts: [String?]) -> URL? {
        let haystack = texts.compactMap { $0 }.joined(separator: "\n")
        for pattern in linkPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)),
                  let range = Range(match.range, in: haystack) else { continue }
            // Trailing punctuation from prose ("...hij.") is not part of the link.
            let raw = haystack[range].trimmingCharacters(in: CharacterSet(charactersIn: ".,;)"))
            if let url = URL(string: String(raw)) { return url }
        }
        return nil
    }

    /// Google Calendar wraps its Meet block in "-::~:~::~..." separator lines
    /// and adds dial-in lines outside them; none of that is agenda.
    private static let boilerplate = [
        "join with google meet", "meet.google.com", "or dial", "pin:", "more phone numbers",
        "learn more about meet", "join by phone", "joining notes", "meeting host",
    ]

    static func agenda(from notes: String?) -> String? {
        guard let notes else { return nil }
        var kept: [String] = []
        var inMeetBlock = false
        for rawLine in notes.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.contains("~:~") {
                inMeetBlock.toggle()
                continue
            }
            if inMeetBlock { continue }
            let lower = line.lowercased()
            if boilerplate.contains(where: { lower.contains($0) }) { continue }
            kept.append(line)
        }
        let text = kept.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // A brief is a heads-up, not a document; long agendas are cut.
        return text.count > 600 ? String(text.prefix(600)) + "…" : text
    }
}
