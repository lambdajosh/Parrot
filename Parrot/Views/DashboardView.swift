import SwiftUI
import SwiftData

/// The Today pane: what is happening or coming up according to the calendar,
/// the one action that matters (record), and what was captured today. It
/// answers "what should I do right now?" rather than showing lifetime totals.
struct DashboardView: View {
    @Binding var selectedMeeting: Meeting?
    @Binding var showDashboard: Bool

    @Environment(RecordingManager.self) private var recordingManager
    @Environment(CalendarService.self) private var calendar
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Query(sort: \CallProfile.sortOrder) private var allProfiles: [CallProfile]

    @State private var errorMessage: String?
    @State private var showImporter = false
    @AppStorage("copilotEnabled") private var copilotEnabled = false
    @AppStorage(MeetingScheduler.autoRecordKey) private var autoRecord = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionGap) {
                header
                heroCard
                if copilotEnabled { copilotSetup }
                meetingsSection
                footer
            }
            .frame(maxWidth: Theme.Metrics.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Metrics.pad)
            .padding(.vertical, Theme.Metrics.pad)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.canvas)
        .navigationTitle("Today")
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: AudioImport.contentTypes) { result in
            if case .success(let url) = result { startImport(url) }
        }
        // A real binding, not .constant: SwiftUI writes false into it on any
        // system-initiated dismissal, which a constant silently drops.
        .alert("Recording Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Header

    /// The date, large: the navigation title already says "Today".
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(Theme.Typography.title(26))
                .foregroundStyle(Theme.Colors.ink)
            modelStatus
        }
    }

    // MARK: - Hero

    private var current: ScheduledMeeting? {
        calendar.currentMeeting(at: .now, leadIn: MeetingScheduler.startLead)
    }

    private var next: ScheduledMeeting? { calendar.nextMeeting() }

    /// One card, three states: a call is on now, one is coming up, or the day
    /// is clear. The record action lives here in every state.
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let current {
                eyebrow("Now")
                eventSummary(current, timeText: timeRange(current))
                if autoRecord {
                    Label("Parrot records this call automatically.", systemImage: "checkmark.circle")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.good)
                }
            } else if let next {
                eyebrow("Up next")
                eventSummary(next, timeText: "\(next.start.formatted(date: .omitted, time: .shortened)) · \(relative(next.start))")
                if autoRecord {
                    Label("Recording starts on its own a minute before.", systemImage: "checkmark.circle")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.good)
                }
            } else {
                eyebrow(calendar.isActive ? "Clear" : "Ready")
                Text(calendar.isActive ? "No more video calls today" : "Ready to record")
                    .font(Theme.Typography.title())
                    .foregroundStyle(Theme.Colors.ink)
                Text("Recording captures the other side of the call and your mic, transcribed on this Mac.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                recordButton
                Button("Import a recording…") { showImporter = true }
                    .disabled(recordingManager.importProgress != nil || !recordingManager.transcriptionEngine.isReady)
                if !calendar.isActive {
                    SettingsLink {
                        Text("Connect your calendar…")
                    }
                    .help("Name recordings after the meeting, know who was invited, and let Parrot record on schedule. Settings → Meetings.")
                }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(Theme.Metrics.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius).strokeBorder(Theme.Colors.line))
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .textCase(.uppercase)
            .font(Theme.Typography.cap)
            .foregroundStyle(Theme.Colors.ink3)
    }

    private func eventSummary(_ event: ScheduledMeeting, timeText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title)
                .font(Theme.Typography.title())
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(2)
            Text(timeText)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink2)
                .monospacedDigit()
            if !event.otherNames.isEmpty {
                Label(event.otherNames.joined(separator: ", "), systemImage: "person.2")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(1)
            }
            if let agenda = event.agenda {
                Text(agenda)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
    }

    /// ⌘R belongs to the Recording menu; this button is the visible twin.
    private var recordButton: some View {
        Button {
            Task {
                do {
                    try await recordingManager.preflightPermissionsAndStart(modelContext: modelContext)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } label: {
            Label("Record", systemImage: "record.circle")
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.Colors.stop)
        .disabled(!recordingManager.transcriptionEngine.isReady || recordingManager.importProgress != nil)
    }

    private func timeRange(_ event: ScheduledMeeting) -> String {
        "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    // MARK: - Model status

    /// Only speaks up while something is in the way of recording.
    @ViewBuilder
    private var modelStatus: some View {
        switch recordingManager.transcriptionEngine.modelState {
        case .ready:
            EmptyView()
        case .notLoaded:
            Label("Model not loaded", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.Colors.warn)
                .font(Theme.Typography.secondary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing \(recordingManager.transcriptionEngine.loadingModelName ?? "the transcription model")… The first load can take a few minutes.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
            }
        case .downloading(let progress):
            ModelDownloadProgressView(progress: progress,
                                      modelName: recordingManager.transcriptionEngine.loadingModelName)
        case .error(let message):
            Label(message, systemImage: "xmark.circle")
                .foregroundStyle(Theme.Colors.stop)
                .font(Theme.Typography.secondary)
        }
    }

    // MARK: - Copilot setup

    private var copilotSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow("Copilot")
            profilePicker
            callBriefField
        }
    }

    private var profilePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allProfiles.sorted { $0.sortOrder < $1.sortOrder }) { profile in
                    let isActive = profileStore.activeProfile?.id == profile.id
                    Button { profileStore.setActive(profile) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: profile.iconSystemName).font(.appCaption)
                            Text(profile.name).font(Theme.Typography.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(isActive ? Theme.Colors.accent : Theme.Colors.chip,
                                    in: Capsule())
                        .foregroundStyle(isActive ? .white : Theme.Colors.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    /// Optional one-line context the copilot gets from second one of the call.
    /// The calendar fills this in when it is left empty.
    private var callBriefField: some View {
        @Bindable var recordingManager = recordingManager
        return TextField(
            calendar.isActive ? "Brief the copilot (the calendar agenda is used when this is empty)"
                              : "Brief the copilot (optional), e.g. \"Call with Westfield PM about AC replacement\"",
            text: $recordingManager.nextCallBrief
        )
        .textFieldStyle(.roundedBorder)
        .font(Theme.Typography.secondary)
        .frame(maxWidth: 520)
    }

    // MARK: - Meetings

    private var todaysMeetings: [Meeting] {
        meetings.filter { Calendar.current.isDateInToday($0.date) }
    }

    /// Today's recordings when there are any, otherwise the last few, so the
    /// pane is never empty on a quiet day.
    private var meetingsSection: some View {
        let today = todaysMeetings
        let rows = today.isEmpty ? Array(meetings.prefix(5)) : today
        return VStack(alignment: .leading, spacing: 8) {
            if !rows.isEmpty {
                eyebrow(today.isEmpty ? "Recent" : "Recorded today")
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, meeting in
                        Button {
                            selectedMeeting = meeting
                            showDashboard = false
                        } label: {
                            HStack(spacing: 8) {
                                MeetingRow(meeting: meeting)
                                Image(systemName: "chevron.right")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.ink3)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .meetingContextMenu(meeting, onDeleted: {
                            if selectedMeeting?.id == meeting.id { selectedMeeting = nil }
                        })
                        if index < rows.count - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius).strokeBorder(Theme.Colors.line))
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        let hours = meetings.reduce(0) { $0 + $1.duration } / 3600
        let count = meetings.count == 1 ? "1 meeting" : "\(meetings.count) meetings"
        return Text("\(count) · \(hours.formatted(.number.precision(.fractionLength(1)))) hours · everything stays on this Mac")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.ink3)
            .monospacedDigit()
    }

    private func startImport(_ url: URL) {
        guard let meeting = recordingManager.importAudioFile(from: url, modelContext: modelContext) else {
            errorMessage = "Couldn't import that file. Make sure it's an audio file and nothing else is recording."
            return
        }
        selectedMeeting = meeting
        showDashboard = false
    }
}
