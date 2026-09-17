import Foundation
import SwiftData

enum MeetingStatus: String, Codable {
    case recording
    case processing
    case done
    case failed
}

@Model
final class Meeting {
    var id: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var systemAudioPath: String
    var micAudioPath: String?
    var status: MeetingStatus
    var errorMessage: String?
    /// AI-generated post-call report; set shortly after recording stops.
    var summary: String?
    /// AI coaching + follow-ups report (talk ratio, what to improve, commitments).
    var coaching: String?
    /// User-assigned name for the other party ("Them"), e.g. "Sam". When set, it
    /// replaces "Them"/"Speaker N" labels in the transcript and reports.
    var themName: String?
    /// The user's own typed notes for this call — live during recording (side
    /// panel) and editable afterwards (Notes tab). Defaulted → old rows migrate.
    var notes: String = ""

    /// True when this meeting was salvaged from an interrupted recording (crash or
    /// force-quit) on the next launch, rather than finished cleanly. Drives the
    /// "Recovered" badge/banner. Defaulted → old rows migrate.
    var wasRecovered: Bool = false

    /// Profile recorded under (nil for pre-Phase-C meetings).
    var profile: CallProfile?
    /// One-line brief for this specific call (was ephemeral nextCallBrief).
    var brief: String?
    /// Denormalized [ProfileKind] used at record time, so the report renders with
    /// the right kind labels/colors even if the profile is later edited/deleted.
    var profileSnapshotData: Data?
    /// Per-call AI usage/cost snapshot (AIUsage JSON); nil for meetings recorded
    /// before cost tracking existed — those show no cost row.
    var aiUsageData: Data?
    /// Mean voice embedding per speaker label (JSON [String: [Float]]), written
    /// by diarization; feeds voice profiles later. Defaulted → old rows migrate.
    var speakerEmbeddingsData: Data? = nil
    /// Per-speaker display names (JSON [label: name]); set from the naming UI.
    /// Defaulted → old rows migrate.
    var speakerNamesData: Data? = nil
    /// One-time "name the voices" card dismissed. Defaulted → old rows migrate.
    var speakerPromptDismissed: Bool = false
    /// Labels whose name was applied by voice recognition rather than the
    /// user (JSON [String]). Shown as "recognized" with an undo until
    /// confirmed. Defaulted → old rows migrate.
    var autoNamedLabelsData: Data? = nil

    /// When the user last trimmed the tail off this transcript, nil if never.
    /// Drives the footer note — a transcript that stops mid-call should say why
    /// it stops there. Defaulted → old rows migrate.
    var truncatedAt: Date? = nil
    /// Call time of the last line kept by that trim.
    var truncatedAfterTime: TimeInterval = 0
    /// Lines removed, summed over every trim on this meeting.
    var truncatedLineCount: Int = 0

    /// The calendar event this recording was matched to at start (EventKit
    /// identifier), its video-call link, and the invitees as JSON
    /// [ScheduledMeeting.Attendee]. All defaulted → old rows migrate.
    var calendarEventID: String? = nil
    var meetingLink: String? = nil
    var attendeesData: Data? = nil

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.meeting)
    var segments: [TranscriptSegment]

    @Relationship(deleteRule: .cascade, inverse: \CallInsight.meeting)
    var insights: [CallInsight]

    init(
        title: String? = nil,
        date: Date = .now,
        systemAudioPath: String = "",
        micAudioPath: String? = nil
    ) {
        self.id = UUID()
        self.title = title ?? Self.defaultTitle(for: date)
        self.date = date
        self.duration = 0
        self.systemAudioPath = systemAudioPath
        self.micAudioPath = micAudioPath
        self.status = .recording
        self.errorMessage = nil
        self.summary = nil
        self.segments = []
        self.insights = []
    }

    var sortedInsights: [CallInsight] {
        insights.sorted { $0.callTime < $1.callTime }
    }

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return "Meeting \(formatter.string(from: date))"
    }

    var sortedSegments: [TranscriptSegment] {
        segments.sorted { $0.startTime < $1.startTime }
    }

    /// The tail of the transcript below `segment` — what a truncate removes.
    /// Judged by start time, the order the user is reading, not by insertion
    /// order. A line sharing the anchor's exact start time stays: nothing above
    /// the clicked line should ever disappear.
    func segments(after segment: TranscriptSegment) -> [TranscriptSegment] {
        segments.filter { $0.startTime > segment.startTime }
    }

    /// Drops everything after `segment`, for the run of invented text Whisper
    /// produces when a recording is left running on an empty room. The audio
    /// file is deliberately left alone — storage is cheap, and it means a
    /// mis-clicked line costs the transcript, not the recording. Returns how
    /// many lines went.
    @discardableResult
    func truncate(after segment: TranscriptSegment, in context: ModelContext) -> Int {
        // A meeting still being transcribed is having segments appended to it as
        // we work — a cut would be undone by the next batch to land, leaving a
        // receipt that lies about what the transcript holds. Enforced here, not
        // just in the menu, so no caller can get it wrong.
        guard status == .done else { return 0 }
        // Snapshot first: deleting mutates the relationship we're filtering.
        let tail = segments(after: segment)
        guard !tail.isEmpty else { return 0 }
        for stale in tail { context.delete(stale) }
        // Stamped so the transcript can say why it stops where it stops. Trims
        // accumulate: the count is every line this meeting has lost, the time is
        // the most recent cut — which is always the earliest one.
        truncatedAt = .now
        truncatedAfterTime = segment.startTime
        truncatedLineCount += tail.count
        try? context.save()
        return tail.count
    }

    /// False while the title is still the generated "Meeting <date>": lists
    /// then show a short label and let the section and time carry the date.
    var hasCustomTitle: Bool { title != Self.defaultTitle(for: date) }

    /// Who was on the call, for list rows: named speakers first, then the
    /// legacy collective name, then the calendar invitees, then a head count.
    var whoLine: String? {
        if let named = participantsSummary { return named }
        if let them = themName?.nilIfEmpty { return them }
        let invited = attendeeNames
        if !invited.isEmpty {
            return invited.count <= 3 ? invited.joined(separator: ", ")
                : "\(invited.prefix(2).joined(separator: ", ")) +\(invited.count - 2)"
        }
        return speakerCount > 1 ? "\(speakerCount) people" : nil
    }

    // MARK: - Calendar context

    var attendees: [ScheduledMeeting.Attendee] {
        guard let data = attendeesData else { return [] }
        return (try? JSONDecoder().decode([ScheduledMeeting.Attendee].self, from: data)) ?? []
    }

    /// Invitees other than the user, for the header and as naming candidates.
    var attendeeNames: [String] {
        attendees.filter { !$0.isMe && !$0.name.isEmpty }.map(\.name)
    }

    /// Takes the calendar's word for what this meeting is. The title is only
    /// replaced while it is still the generated default, so a title the user
    /// typed stays; the brief fills in only when none was typed.
    func applyCalendarContext(_ event: ScheduledMeeting) {
        if title == Self.defaultTitle(for: date) { title = event.title }
        if brief?.nilIfEmpty == nil { brief = event.brief }
        calendarEventID = event.id
        meetingLink = event.videoLink?.absoluteString
        attendeesData = try? JSONEncoder().encode(event.attendees)
    }

    // MARK: - Split

    /// Shortest piece a split may leave on either side, in seconds. Below this
    /// a part has no audio worth diarizing and the cut is almost certainly a
    /// mis-click at the very start or end of the scrubber. Chosen as a UX
    /// guard, not measured.
    static let minimumSplitPart: TimeInterval = 1

    /// True when `time` is a legal cut point for this meeting: finished, and
    /// leaving at least `minimumSplitPart` of audio on both sides.
    func canSplit(at time: TimeInterval) -> Bool {
        status == .done
            && time >= Self.minimumSplitPart
            && duration - time >= Self.minimumSplitPart
    }

    /// Moves everything from `time` onward into a new meeting and returns it,
    /// or nil when the cut is not allowed (see `canSplit`). This is the data
    /// half of a split; the caller cuts the audio files and runs diarization.
    ///
    /// Lines and insights are partitioned by their start time, and the moved
    /// ones are re-based so the second meeting starts at 00:00. A line that
    /// straddles the cut stays in the first part with its end clamped, since
    /// the words before the cut are what the first meeting's audio holds. Both
    /// reports are cleared: a summary of the whole recording describes neither
    /// half. Notes stay with the first part, since they were typed during it
    /// and there is no timestamp to divide them by.
    @discardableResult
    func split(at time: TimeInterval, in context: ModelContext) -> Meeting? {
        guard canSplit(at: time) else { return nil }

        let second = Meeting(title: "\(title) (part 2)", date: date.addingTimeInterval(time))
        // Insert before touching any relationship, the same SwiftData rule
        // addSegment follows.
        context.insert(second)
        second.duration = duration - time
        second.status = .processing
        second.profile = profile
        second.brief = brief
        second.profileSnapshotData = profileSnapshotData
        second.themName = themName
        second.speakerNamesData = speakerNamesData
        second.speakerPromptDismissed = speakerPromptDismissed
        second.wasRecovered = wasRecovered

        // Snapshot first: reassigning a segment's meeting mutates the array
        // being iterated.
        for segment in Array(segments) {
            if segment.startTime >= time {
                segment.startTime -= time
                segment.endTime = max(segment.endTime - time, segment.startTime)
                segment.meeting = second
            } else if segment.endTime > time {
                segment.endTime = time
            }
        }
        for insight in Array(insights) where insight.callTime >= time {
            insight.callTime -= time
            insight.meeting = second
        }

        // A tail-trim receipt names a call time; it follows the half that
        // still contains that point.
        if truncatedAt != nil, truncatedAfterTime >= time {
            second.truncatedAt = truncatedAt
            second.truncatedAfterTime = truncatedAfterTime - time
            second.truncatedLineCount = truncatedLineCount
            truncatedAt = nil
            truncatedAfterTime = 0
            truncatedLineCount = 0
        }

        duration = time
        summary = nil
        coaching = nil
        // Diarization re-labels each half on its own audio; stale means are
        // worse than none until it runs.
        speakerEmbeddingsData = nil
        try? context.save()
        return second
    }

    /// Parses a clock string the way the transcript shows times: "ss",
    /// "mm:ss", or "h:mm:ss", with optional fractional seconds. Nil for
    /// anything else, including negative or out-of-range fields.
    static func parseClock(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total: TimeInterval = 0
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            guard !part.isEmpty, let value = Double(part), value >= 0 else { return nil }
            // Minutes and seconds after a colon must be a full 0-59 field.
            if index > 0, value >= 60 { return nil }
            if !isLast, value != value.rounded() { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// The inverse of `parseClock` for prefilled fields: mm:ss, or h:mm:ss
    /// past an hour, whole seconds.
    static func clockString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func noteLines(_ count: Int) -> String {
        count == 1 ? "1 line" : "\(count) lines"
    }

    /// Footer line for a trimmed transcript; nil when nothing was ever cut.
    /// The call time is formatted like the transcript rows (mm:ss, minutes
    /// running past 60) so it names a timestamp the user can actually see.
    var truncationNote: String? {
        guard let truncatedAt, truncatedLineCount > 0 else { return nil }
        let stamp = String(format: "%02d:%02d",
                           Int(truncatedAfterTime) / 60, Int(truncatedAfterTime) % 60)
        let lines = Self.noteLines(truncatedLineCount)
        let when = truncatedAt.formatted(date: .abbreviated, time: .shortened)
        return "You deleted \(lines) after \(stamp) on \(when). The recording still has the full audio."
    }

    var snapshotKinds: [ProfileKind] {
        guard let data = profileSnapshotData else { return [] }
        return (try? JSONDecoder().decode([ProfileKind].self, from: data)) ?? []
    }

    var aiUsage: AIUsage? {
        guard let data = aiUsageData else { return nil }
        return try? JSONDecoder().decode(AIUsage.self, from: data)
    }

    /// Number of distinct participants by display name. Counting display names
    /// (not raw labels) means that once the other party is named, the imperfect
    /// diarization splitting one voice into "Speaker 1"/"Speaker 2" collapses back
    /// to a single person — so a 1-on-1 reads as 2, not 3.
    var speakerCount: Int {
        Set(segments.map { displayName(forSpeaker: $0.speakerLabel) }).count
    }

    /// Human-facing speaker name. Precedence: a per-speaker name from the
    /// naming UI wins; "Me" stays "Me"; before any per-speaker naming the
    /// legacy collective `themName` still covers the whole other side; once
    /// naming has started, unnamed voices show their raw "Speaker N" label
    /// (mixing "Gürkan" with a collective name would misattribute lines).
    func displayName(forSpeaker label: String?) -> String {
        let names = speakerNames
        guard let label, !label.isEmpty else {
            return names.isEmpty ? (themName ?? "Them") : "Them"
        }
        if let assigned = names[label] { return assigned }
        if label == "Me" { return "Me" }
        return names.isEmpty ? (themName ?? label) : label
    }

    /// Mean voice embedding per label, as written by diarization.
    var speakerEmbeddings: [String: [Float]] {
        guard let data = speakerEmbeddingsData else { return [:] }
        return (try? JSONDecoder().decode([String: [Float]].self, from: data)) ?? [:]
    }

    /// Per-speaker display names (see `speakerNamesData`).
    var speakerNames: [String: String] {
        get {
            guard let data = speakerNamesData else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        set { speakerNamesData = try? JSONEncoder().encode(newValue) }
    }

    var autoNamedLabels: Set<String> {
        get {
            guard let data = autoNamedLabelsData else { return [] }
            return Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
        }
        set { autoNamedLabelsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(Array(newValue).sorted()) }
    }

    /// Sets or clears one voice's name. A name the user chose (or confirmed)
    /// clears the automatic mark; a recognized one sets it, so the card can
    /// show it as reversible.
    func setSpeakerName(_ name: String?, for label: String, automatic: Bool = false) {
        var names = speakerNames
        names[label] = name?.nilIfEmpty
        speakerNames = names
        var auto = autoNamedLabels
        if automatic, name?.nilIfEmpty != nil { auto.insert(label) } else { auto.remove(label) }
        autoNamedLabels = auto
    }

    /// Distinct non-Me speaker labels, "Speaker 1" first.
    var otherSpeakerLabels: [String] {
        Set(segments.compactMap(\.speakerLabel)).subtracting(["Me"])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// This voice's longest utterances — the clips the naming UI plays.
    func longestSegments(for label: String, count: Int = 3) -> [TranscriptSegment] {
        segments.filter { $0.speakerLabel == label }
            .sorted { ($0.endTime - $0.startTime) > ($1.endTime - $1.startTime) }
            .prefix(count).map { $0 }
    }

    /// Named participants joined for list subtitles; nil until someone is
    /// named (callers fall back to `themName`).
    var participantsSummary: String? {
        let named = otherSpeakerLabels.compactMap { speakerNames[$0] }
        return named.isEmpty ? nil : named.joined(separator: ", ")
    }

    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
