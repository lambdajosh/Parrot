import SwiftUI
import SwiftData

/// The source list: Today, then meetings grouped by day, with the native
/// sidebar search field and Settings pinned at the bottom. Rows carry what a
/// list needs to scan (name, time, length, who) and nothing decorative; the
/// day is in the section header, so it never repeats in the row.
struct SidebarView: View {
    @Binding var selectedMeeting: Meeting?
    @Binding var showDashboard: Bool
    /// Settings render in the main detail pane (the old sheet was a cramped
    /// 520pt popup that made the Profiles editor unusable).
    @Binding var showSettings: Bool
    @Binding var searchText: String

    @Environment(RecordingManager.self) private var recordingManager
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    /// Edit → Find (⌘F) lands here.
    @FocusState private var searchFocused: Bool

    enum Item: Hashable {
        case today
        case meeting(UUID)
    }

    /// One selection for the list, mapped onto the three pieces of window
    /// state ContentView already owns.
    private var selection: Binding<Item?> {
        Binding(
            get: {
                if showSettings { return nil }
                if showDashboard { return .today }
                if let meeting = selectedMeeting { return .meeting(meeting.id) }
                return nil
            },
            set: { item in
                switch item {
                case .today?:
                    showDashboard = true
                    showSettings = false
                    selectedMeeting = nil
                case .meeting(let id)?:
                    selectedMeeting = meetings.first { $0.id == id }
                    showDashboard = false
                    showSettings = false
                case nil:
                    break
                }
            })
    }

    var body: some View {
        List(selection: selection) {
            Label("Today", systemImage: "sun.max")
                .tag(Item.today)

            ForEach(orderedGroups, id: \.0) { key, group in
                let rows = filtered(group)
                if !rows.isEmpty {
                    Section(key) {
                        ForEach(rows) { meeting in
                            MeetingRow(meeting: meeting)
                                .tag(Item.meeting(meeting.id))
                                .meetingContextMenu(meeting, onDeleted: {
                                    if selectedMeeting?.id == meeting.id {
                                        selectedMeeting = nil
                                        showDashboard = true
                                    }
                                })
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search meetings")
        .modifier(SearchFocus(focused: $searchFocused))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            settingsRow
        }
        .onReceive(NotificationCenter.default.publisher(for: .parrotFocusSearch)) { _ in
            searchFocused = true
        }
    }

    /// Pinned below the list like Mail's account footer: always one click,
    /// never scrolls away, and highlighted while the settings pane is up.
    private var settingsRow: some View {
        Button {
            showSettings = true
            showDashboard = false
            selectedMeeting = nil
        } label: {
            Label("Settings", systemImage: "gearshape")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(showSettings ? Theme.Colors.selection : Color.clear,
                            in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .background(.bar)
    }

    // Group by day label, ordered most-recent-first (meetings already sorted desc).
    private var orderedGroups: [(String, [Meeting])] {
        let groups = Dictionary(grouping: meetings) { dateGroupLabel(for: $0.date) }
        return groups.sorted {
            ($0.value.first?.date ?? .distantPast) > ($1.value.first?.date ?? .distantPast)
        }
    }

    private func filtered(_ list: [Meeting]) -> [Meeting] {
        guard !searchText.isEmpty else { return list }
        return list.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(searchText) ||
            meeting.attendeeNames.contains { $0.localizedCaseInsensitiveContains(searchText) } ||
            meeting.segments.contains { $0.text.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private func dateGroupLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now), date > weekAgo {
            return "This Week"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
}

/// ⌘F focuses the sidebar search field. The API is macOS 15+; on 14 the
/// field is still there, it just has to be clicked.
private struct SearchFocus: ViewModifier {
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.searchFocused(focused)
        } else {
            content
        }
    }
}

// MARK: - Meeting row

/// Two lines: what the meeting is, then when, how long, and with whom. A
/// meeting still carrying its generated "Meeting <date>" title shows as
/// "Meeting", since the section header already says the day and the second
/// line the time. Status replaces the second line while it matters.
struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.hasCustomTitle ? meeting.title : "Meeting")
                    .font(Theme.Typography.sans(13, .medium))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(meeting.status == .failed ? Theme.Colors.stop : Theme.Colors.ink2)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var trailing: some View {
        switch meeting.status {
        case .recording:
            HStack(spacing: 4) {
                Circle().fill(Theme.Colors.stop).frame(width: 6, height: 6)
                Text(meeting.date, style: .timer)
                    .font(Theme.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.stop)
            }
        case .processing:
            ProgressView().controlSize(.mini)
        default:
            EmptyView()
        }
    }

    private var subtitle: String {
        switch meeting.status {
        case .recording:
            return "Recording now"
        case .processing:
            return "Finishing up…"
        case .failed:
            return meeting.errorMessage ?? "Couldn't finish"
        case .done:
            var parts = [meeting.date.formatted(date: .omitted, time: .shortened)]
            if meeting.duration > 0 { parts.append(meeting.formattedDuration) }
            if let who = meeting.whoLine { parts.append(who) }
            return parts.joined(separator: " · ")
        }
    }
}
