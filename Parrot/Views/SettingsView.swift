import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ServiceManagement
import EventKit
import AVFoundation
import UserNotifications

/// Settings pages, System Settings-style: topics on the left, ONE topic per
/// page on the right. Content rules: controls at body size, hints one line at
/// secondary size — long explanations live in the control's own label instead.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, meetings, recording, transcription, copilot, knowledge, profiles, apiKeys

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .meetings: "Meetings"
        case .transcription: "Transcription"
        case .copilot: "Copilot"
        case .apiKeys: "API Keys"
        case .knowledge: "Knowledge"
        case .profiles: "Profiles"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .recording: "mic"
        case .meetings: "calendar"
        case .transcription: "text.quote"
        case .copilot: "sparkles"
        case .apiKeys: "key"
        case .knowledge: "books.vertical"
        case .profiles: "person.2"
        }
    }
}

struct SettingsView: View {
    /// True when rendered inside the main window's detail pane (wide, fills the
    /// space); false for the standalone Cmd-, Settings window, which needs a
    /// fixed sane size.
    var isEmbedded = false

    init(isEmbedded: Bool = false, initialSection: SettingsSection = .general) {
        self.isEmbedded = isEmbedded
        _section = State(initialValue: initialSection)
    }

    @Environment(RecordingManager.self) private var recordingManager
    @Environment(CalendarService.self) private var calendar
    @AppStorage("whisperModel") private var selectedModel = "base"
    @AppStorage(CalendarService.enabledKey) private var calendarContextEnabled = false
    @AppStorage(MeetingScheduler.remindKey) private var meetingReminders = false
    @AppStorage(MeetingScheduler.autoRecordKey) private var autoRecordMeetings = false
    /// Mirrors SMAppService so the toggle survives a relaunch without a
    /// second copy of the truth, like the Sparkle toggle below.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// nil until the async notification-settings read lands.
    @State private var notificationsGranted: Bool?
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("copilotEnabled") private var copilotEnabled = false
    @AppStorage("copilotProvider") private var copilotProvider = CopilotProviderKind.claude.rawValue
    @AppStorage("copilotPace") private var copilotPace = CopilotPace.fast.rawValue
    @AppStorage("copilotWindow") private var copilotWindow = CopilotWindow.standard.rawValue
    /// "" = same backend as live cards.
    @AppStorage("reportsProvider") private var reportsProvider = ""
    @AppStorage("copilotOllamaModel") private var copilotOllamaModel = "llama3.2:3b"
    @AppStorage("copilotCustomBaseURL") private var copilotCustomBaseURL = ""
    @AppStorage("copilotCustomModel") private var copilotCustomModel = ""
    /// True after picking "Custom…" in the Ollama model dropdown, so the free
    /// text field stays visible even while the typed name matches nothing.
    @State private var ollamaCustomModelEditing = false
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage = "auto"
    @AppStorage("customVocabulary") private var customVocabulary = ""
    @AppStorage("echoCancellationEnabled") private var echoCancellation = true
    @AppStorage(TranscriptionBackend.defaultsKey) private var transcriptionBackend = TranscriptionBackend.local.rawValue
    @AppStorage("polishAfterCall") private var polishAfterCall = false
    @AppStorage("livePreview") private var livePreview = true
    @AppStorage(TranscriptExportLocation.autoSaveKey) private var autoSaveTranscripts = false
    /// Mirrors the bookmark in UserDefaults so the row redraws after a pick.
    @State private var transcriptDirectory = TranscriptExportLocation.directory()
    @State private var showTranscriptFolderPicker = false
    @State private var section: SettingsSection = .general
    @State private var diarizerDownloading = false
    @AppStorage("rememberVoices") private var rememberVoices = false
    @AppStorage(SpeakerProfileStore.autoNameKey) private var autoNameVoices = true
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SpeakerProfile.name) private var voiceProfiles: [SpeakerProfile]
    /// Recent meetings, for the addresses the calendar handed over that still
    /// have no name.
    @Query(sort: \Meeting.date, order: .reverse) private var recentMeetings: [Meeting]
    /// Bumped when an alias changes so the lists below re-read the directory.
    @State private var peopleVersion = 0
    @State private var aliasEditingIdentity: String?
    @State private var newPersonIdentity = ""
    @State private var newPersonName = ""
    @State private var showFileImporter = false
    /// There's no Save button — @AppStorage persists on every change. This
    /// drives a small transient "Saved" chip so that's visible, debounced so
    /// typing in a field shows one toast when the user pauses, not per key.
    @State private var showSavedToast = false
    @State private var savedToastTask: Task<Void, Never>?
    /// Mirrors Sparkle's own setting so the toggle survives a relaunch without
    /// us storing a second copy of the truth.
    @State private var automaticUpdates = AppUpdater.shared.automaticallyUpdates

    /// Opens the bundled Help Book at a specific page anchor (hiutil indexes
    /// anchors — the -a in assemble-help.sh). Dev binaries carry no book, so
    /// Help Viewer just no-ops there.
    static func openHelp(anchor: String) {
        let book = Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String
        NSHelpManager.shared.openHelpAnchor(anchor, inBook: book)
    }

    /// One Equatable snapshot of every auto-saved setting on this screen —
    /// a single onChange instead of one per field.
    private var settingsFingerprint: String {
        "\(selectedModel)|\(appearance)|\(copilotEnabled)|\(transcriptionLanguage)|"
            + "\(customVocabulary)|\(echoCancellation)|\(transcriptionBackend)|\(polishAfterCall)|"
            + "\(copilotPace)|\(copilotWindow)|\(livePreview)|\(autoSaveTranscripts)|\(transcriptDirectory)|"
            + "\(calendarContextEnabled)|\(meetingReminders)|\(autoRecordMeetings)|\(launchAtLogin)"
    }

    /// Addresses from the last 30 meetings' invites that have no alias yet.
    private var unnamedInviteeIdentities: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for meeting in recentMeetings.prefix(30) {
            for identity in meeting.attendeeIdentities
            where PeopleDirectory.looksLikeEmail(identity) && PeopleDirectory.alias(for: identity) == nil {
                let k = PeopleDirectory.canonical(identity)
                if seen.insert(k).inserted { result.append(identity) }
            }
        }
        return result
    }

    private func flashSavedToast() {
        savedToastTask?.cancel()
        savedToastTask = Task {
            // Debounce: wait for the user to pause before announcing the save.
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { showSavedToast = true }
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { showSavedToast = false }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: Section nav
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { item in
                    SettingsNavRow(title: item.title, icon: item.icon, selected: section == item) {
                        section = item
                    }
                }
                Spacer()
                // Pinned at the bottom: a hello from the author (jumps to the
                // help book's "Hi from Uygar" page) and the standard macOS
                // help button for the guide itself.
                HStack(spacing: 6) {
                    SettingsNavRow(title: "About", icon: "hand.wave", selected: false) {
                        Self.openHelp(anchor: "hi-from-uygar")
                    }
                    HelpCircleButton { NSApp.showHelp(nil) }
                }
            }
            .padding(8)
            .frame(width: 168)
            .background(Theme.Colors.panel)

            Divider()

            // MARK: Page
            Group {
                switch section {
                case .general: generalPage
                case .recording: recordingPage
                case .meetings: meetingsPage
                case .transcription: transcriptionPage
                case .copilot: copilotPage
                case .apiKeys: apiKeysPage
                case .knowledge: knowledgePage
                case .profiles: ProfilesSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .formStyle(.grouped)
        .onChange(of: settingsFingerprint) { flashSavedToast() }
        .overlay(alignment: .bottom) {
            if showSavedToast {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.Colors.line))
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: isEmbedded ? nil : 780, height: isEmbedded ? nil : 540)
        .frame(maxWidth: isEmbedded ? .infinity : nil,
               maxHeight: isEmbedded ? .infinity : nil)
    }

    // MARK: - General

    private var generalPage: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("Follow System").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                .pickerStyle(.radioGroup)
            }

            Section("Storage") {
                let path = AudioCaptureManager.storageDirectory().path
                LabeledContent("Audio files") {
                    Text(path)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                }

                LabeledContent("Transcripts") {
                    Text(transcriptDirectory.path)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 6) {
                    Button("Choose Folder…") { showTranscriptFolderPicker = true }
                    if TranscriptExportLocation.isCustom() {
                        Button("Use Downloads") {
                            try? TranscriptExportLocation.set(nil)
                            transcriptDirectory = TranscriptExportLocation.directory()
                        }
                        .buttonStyle(.link)
                        .font(Theme.Typography.secondary)
                    }
                }

                Toggle("Save a transcript here after each call", isOn: $autoSaveTranscripts)
                Hint("Writes a TXT once transcription and speaker detection finish. Right-click a meeting → Export for a one-off.")
            }

            Section("About") {
                LabeledContent("Version", value: "Parrot \(AppUpdater.currentVersion)")
                Toggle("Keep Parrot up to date", isOn: $automaticUpdates)
                    .onChange(of: automaticUpdates) {
                        AppUpdater.shared.automaticallyUpdates = automaticUpdates
                    }
                Hint("Downloads new versions in the background and installs them when you quit. Never during a recording.")
                HStack(spacing: 6) {
                    Hint("Or look right now.")
                    Button("Check Now") { AppUpdater.shared.checkForUpdates() }
                        .buttonStyle(.link)
                        .font(Theme.Typography.secondary)
                }
                HStack(spacing: 6) {
                    Hint("Every screen explained, with setup and troubleshooting.")
                    Button("Open User Guide") {
                        NSApp.showHelp(nil)
                    }
                    .buttonStyle(.link)
                    .font(Theme.Typography.secondary)
                }
                HStack(spacing: 6) {
                    Hint("The first-run tour: permissions and model choice.")
                    Button("Show Welcome Tour") { MeetingActions.showWelcomeTour() }
                        .buttonStyle(.link)
                        .font(Theme.Typography.secondary)
                }
            }
        }
        .fileImporter(
            isPresented: $showTranscriptFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            // The picked URL carries a one-run grant; `set` turns it into a
            // bookmark so exports keep landing there after a relaunch.
            if case .success(let urls) = result, let url = urls.first {
                do {
                    try TranscriptExportLocation.set(url)
                } catch {
                    NSLog("Parrot: couldn't bookmark transcript folder: \(error.localizedDescription)")
                }
                transcriptDirectory = TranscriptExportLocation.directory()
            }
        }
    }

    // MARK: - Recording

    private var recordingPage: some View {
        Form {
            Section("Echo Cancellation") {
                Toggle("Cancel speaker echo from the mic", isOn: $echoCancellation)
                Hint("On speakers, this keeps the other person's voice out of your \"Me\" track. Turn off with headphones.")
            }

            Section("Input") {
                Hint("The other side comes from a system audio tap (macOS 15+) or ScreenCaptureKit; your side from the default microphone.")
            }

            Section("Permissions") {
                PermissionStatusRow(
                    title: "System Audio Recording",
                    granted: PermissionFlow.systemAudioLooksGranted(),
                    detail: PermissionFlow.systemAudioLooksGranted() ? "Granted" : "Confirmed by the first real recording",
                    pane: "Privacy_ScreenCapture")
                PermissionStatusRow(
                    title: "Microphone",
                    granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                    detail: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "Granted" : "Not granted",
                    pane: "Privacy_Microphone")
                PermissionStatusRow(
                    title: "Calendars",
                    granted: EKEventStore.authorizationStatus(for: .event) == .fullAccess,
                    detail: EKEventStore.authorizationStatus(for: .event) == .fullAccess ? "Granted"
                        : (calendarContextEnabled ? "Not granted" : "Off (Meetings page)"),
                    pane: "Privacy_Calendars")
                PermissionStatusRow(
                    title: "Notifications",
                    granted: notificationsGranted == true,
                    detail: notificationsGranted.map { $0 ? "Granted" : "Not granted" } ?? "Asked on the first recording",
                    pane: nil)
                Hint("Each row opens the matching System Settings pane. macOS forgets grants when the app is re-signed.")
            }
        }
        .task {
            // The notification center aborts in an unbundled binary (the
            // snapshot harnesses); Notifier knows whether it is safe to ask.
            guard Notifier.shared.isAvailable else { return }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsGranted = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        }
    }

    // MARK: - Meetings

    private var meetingsPage: some View {
        Form {
            Section("Calendar") {
                Toggle("Use my calendar for meeting details", isOn: $calendarContextEnabled)
                    .onChange(of: calendarContextEnabled) { _, on in
                        calendar.isEnabled = on
                        if on { Task { _ = await calendar.requestAccess() } }
                    }
                Hint("Names each recording after its event, keeps the invitees, and briefs the copilot with the agenda. Reads the Calendar app on this Mac.")
                if calendarContextEnabled {
                    LabeledContent("Access") {
                        if calendar.hasAccess {
                            Text("Granted").foregroundStyle(Theme.Colors.good)
                        } else {
                            Button("Grant Calendar Access…") { Task { _ = await calendar.requestAccess() } }
                        }
                    }
                    if calendar.hasAccess {
                        LabeledContent("Up next") {
                            Text(calendar.nextMeeting().map { "\($0.title) at \($0.start.formatted(date: .omitted, time: .shortened))" }
                                 ?? "No video calls in the next 24 hours")
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(Theme.Colors.ink2)
                        }
                    }
                    if copilotEnabled, copilotProvider != CopilotProviderKind.ollama.rawValue {
                        Hint("Invitee names and the agenda join the brief, so a cloud copilot receives them with the transcript.")
                    }
                }
            }

            Section("Hands-free") {
                Toggle("Remind me when a video call is about to start", isOn: $meetingReminders)
                    .disabled(!calendarContextEnabled)
                Hint("A notification \(Int(MeetingScheduler.reminderLead / 60)) minutes before, with a Start Recording button.")
                Toggle("Record scheduled video calls automatically", isOn: $autoRecordMeetings)
                    .disabled(!calendarContextEnabled)
                Hint("Starts a minute before each Meet, Zoom, or Teams call and stops once it has ended and gone quiet. Stopping by hand leaves that meeting alone.")
                Toggle("Open Parrot at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("Parrot: login item change failed: \(error.localizedDescription)")
                        }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                Hint("Hands-free only works while Parrot runs; the menu bar icon stays with the window closed.")
            }
        }
    }

    // MARK: - Transcription

    private var transcriptionPage: some View {
        Form {
            Section("Engine") {
                Picker("Engine", selection: $transcriptionBackend) {
                    Text("On-device Whisper — private, free").tag(TranscriptionBackend.local.rawValue)
                    Text("Groq cloud — big-model accuracy, ~$0.04/hr").tag(TranscriptionBackend.groq.rawValue)
                    Text("Deepgram cloud — word-by-word streaming, ~$1/hr").tag(TranscriptionBackend.deepgram.rawValue)
                }
                .pickerStyle(.radioGroup)

                if transcriptionBackend == TranscriptionBackend.local.rawValue {
                    Hint("Every second of audio stays on this Mac.")
                } else {
                    HStack(spacing: 6) {
                        Hint("Cloud engines need a key, and fall back to on-device if it's missing.")
                        Button("Open API Keys") { section = .apiKeys }
                            .buttonStyle(.link)
                            .font(Theme.Typography.secondary)
                    }
                }

                Divider()

                Toggle("Polish transcript after each call", isOn: $polishAfterCall)
                Hint("Re-transcribes the saved audio with a large Groq model (~$0.04/hr) and regenerates the report.")

                Divider()

                Toggle("Show words as they're spoken", isOn: $livePreview)
                Hint("Gray preview text mid-sentence, replaced by the final line. On-device only; turn off if calls make your Mac run hot.")
            }

            Section("On-Device Model") {
                Picker("Model", selection: $selectedModel) {
                    Text("Tiny — 40 MB, fastest").tag("tiny")
                    Text("Base — 140 MB, good balance").tag("base")
                    Text("Small — 460 MB, better accuracy").tag("small")
                    Text("Large V3 Turbo Compressed — 626 MB, fast, low memory").tag("large-v3-v20240930_626MB")
                    Text("Large V3 Turbo — 1.6 GB, best accuracy").tag("large-v3-turbo")
                }
                .pickerStyle(.radioGroup)

                modelStatusView

                Button("Download / Reload Model") {
                    Task {
                        await recordingManager.transcriptionEngine.loadModel(selectedModel)
                    }
                }
            }

            Section("Speaker Detection") {
                if DiarizationEngine.modelsInstalled {
                    LabeledContent("Models", value: "Downloaded (~13 MB)")
                    Button("Remove Models") { DiarizationEngine.removeModels() }
                } else {
                    LabeledContent("Models", value: "Not downloaded")
                    Button(diarizerDownloading ? "Downloading…" : "Download (~13 MB)") {
                        diarizerDownloading = true
                        Task {
                            try? await recordingManager.diarizationEngine.ensureModels()
                            diarizerDownloading = false
                        }
                    }
                    .disabled(diarizerDownloading)
                }
                Text("Tells apart the different people on a call, on this Mac. Downloads automatically after a call if missing. Uses pyannote models via FluidAudio (CC-BY-4.0).")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)

                Toggle("Remember voices", isOn: $rememberVoices)
                Text("When on, naming a speaker saves their voiceprint on this Mac so future calls can suggest who's talking. Never leaves your Mac; delete anytime.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
                if rememberVoices {
                    Toggle("Name voices automatically when confident", isOn: $autoNameVoices)
                    Hint("A very close match is named without asking and marked so you can undo it; looser matches stay one-click suggestions.")
                    ForEach(voiceProfiles) { profile in
                        HStack {
                            // The name is a button: click it to give this
                            // identity (often an address) a readable alias.
                            PersonNameButton(identity: profile.name, editing: $aliasEditingIdentity)
                            Text("heard \(profile.sampleCount)×")
                                .foregroundStyle(Theme.Colors.ink2)
                            Spacer()
                            Button("Forget") {
                                SpeakerProfileStore.delete(profile, in: modelContext)
                            }
                        }
                        .font(Theme.Typography.caption)
                    }
                    if !voiceProfiles.isEmpty {
                        Button("Forget All Voices") {
                            SpeakerProfileStore.deleteAll(in: modelContext)
                        }
                    }
                }
            }

            Section("People") {
                Hint("Calendar invites often carry only an address. Give it a name here and every transcript, report, and export shows the name instead.")
                let aliases = PeopleDirectory.aliases().sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
                ForEach(aliases, id: \.key) { identity, name in
                    HStack {
                        PersonNameButton(identity: identity, editing: $aliasEditingIdentity)
                        Text(identity)
                            .foregroundStyle(Theme.Colors.ink2)
                            .lineLimit(1)
                        Spacer()
                        Button("Forget") { PeopleDirectory.setAlias(nil, for: identity) }
                    }
                    .font(Theme.Typography.caption)
                }
                // Addresses seen in recent invites with no name yet: one click
                // to name them, instead of remembering who is who.
                let unnamed = unnamedInviteeIdentities
                if !unnamed.isEmpty {
                    ForEach(unnamed, id: \.self) { identity in
                        HStack {
                            PersonNameButton(identity: identity, editing: $aliasEditingIdentity)
                            Text("from a recent invite, no name yet")
                                .foregroundStyle(Theme.Colors.ink3)
                            Spacer()
                        }
                        .font(Theme.Typography.caption)
                    }
                }
                HStack(spacing: 8) {
                    TextField("email or identity", text: $newPersonIdentity)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    TextField("Name", text: $newPersonName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                    Button("Add") {
                        PeopleDirectory.setAlias(newPersonName, for: newPersonIdentity)
                        newPersonIdentity = ""
                        newPersonName = ""
                    }
                    .disabled(newPersonIdentity.trimmingCharacters(in: .whitespaces).isEmpty
                              || newPersonName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .font(Theme.Typography.caption)
            }
            .id(peopleVersion)
            .onReceive(NotificationCenter.default.publisher(for: .parrotPeopleChanged)) { _ in
                peopleVersion &+= 1
            }

            Section("Language") {
                Picker("Language", selection: $transcriptionLanguage) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("en")
                    Text("Turkish").tag("tr")
                    Text("Spanish").tag("es")
                    Text("German").tag("de")
                    Text("French").tag("fr")
                    Text("Italian").tag("it")
                    Text("Portuguese").tag("pt")
                    Text("Dutch").tag("nl")
                    Text("Russian").tag("ru")
                    Text("Arabic").tag("ar")
                    Text("Chinese").tag("zh")
                    Text("Japanese").tag("ja")
                    Text("Korean").tag("ko")
                    Text("Hindi").tag("hi")
                }
                Hint("Applies to the next recording. Pick a language only if auto-detect keeps guessing wrong.")
            }

            Section("Custom Vocabulary") {
                TextEditor(text: $customVocabulary)
                    .frame(height: 64)
                    .font(Theme.Typography.secondary)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.line))
                Hint("Names and jargon Whisper mis-hears — comma or line separated (e.g. LaunchEase, Uygar).")
            }
        }
    }

    @ViewBuilder
    private var modelStatusView: some View {
        switch recordingManager.transcriptionEngine.modelState {
        case .ready:
            Label("Model loaded and ready", systemImage: "checkmark.circle")
                .foregroundStyle(Theme.Colors.good)
                .font(Theme.Typography.secondary)
        case .loading:
            HStack(alignment: .top) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preparing \(recordingManager.transcriptionEngine.loadingModelName ?? "model")…")
                    Text("The first load can take a few minutes.")
                        .font(Theme.Typography.caption)
                }
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)
            }
        case .downloading(let progress):
            ModelDownloadProgressView(progress: progress,
                                      modelName: recordingManager.transcriptionEngine.loadingModelName)
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle")
                .foregroundStyle(Theme.Colors.stop)
                .font(Theme.Typography.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: - Copilot

    private var copilotPage: some View {
        Form {
            Section("Live Call Copilot") {
                Toggle("Enable Copilot during recordings", isOn: $copilotEnabled)
                Hint("Suggests answers, flags blockers, and captures action items live — no button needed.")

                HStack(spacing: 6) {
                    Hint("What it says and watches for is set per call profile.")
                    Button("Open Profiles") { section = .profiles }
                        .buttonStyle(.link)
                        .font(Theme.Typography.secondary)
                }
            }

            // What each call costs, in the user's hands: how often the model is
            // asked, and how much conversation each request carries. Both apply
            // live, mid-call. Fast + Standard = the original behavior.
            Section("Pace") {
                Picker("How often Copilot asks the model", selection: $copilotPace) {
                    ForEach(CopilotPace.allCases) { pace in
                        Text(pace.label).tag(pace.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                Hint((CopilotPace(rawValue: copilotPace) ?? .fast).caption)

                Picker("Conversation sent per request", selection: $copilotWindow) {
                    ForEach(CopilotWindow.allCases) { window in
                        Text(window.label).tag(window.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Hint("Only recent talk is sent; insight cards always go along. Smaller is cheaper and faster, especially on local models.")
            }

            Section("Model") {
                // Two jobs, two backends: live cards need speed and sharpness;
                // reports run after the call where a slow local model costs nothing.
                Picker("Live cards", selection: $copilotProvider) {
                    ForEach(CopilotProviderKind.allCases) { kind in
                        Text(kind.label).tag(kind.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                providerConfig(for: CopilotProviderKind(rawValue: copilotProvider) ?? .claude)

                Picker("Post-call reports", selection: $reportsProvider) {
                    Text("Same as live cards").tag("")
                    ForEach(CopilotProviderKind.allCases) { kind in
                        Text(kind.label).tag(kind.rawValue)
                    }
                }
                .pickerStyle(.menu)

                if let reportsKind = CopilotProviderKind(rawValue: reportsProvider),
                   reportsKind != (CopilotProviderKind(rawValue: copilotProvider) ?? .claude) {
                    providerConfig(for: reportsKind)
                }
                Hint("Reports run after the call, so a local model keeps them free and private. Falls back to the live backend if unset.")
            }
        }
    }

    /// Per-backend configuration rows, shared by the live and reports pickers.
    @ViewBuilder
    private func providerConfig(for kind: CopilotProviderKind) -> some View {
                switch kind {
                case .claude:
                    HStack(spacing: 6) {
                        Hint("Best quality. Needs a key — transcript text is sent, audio never.")
                        Button("Open API Keys") { section = .apiKeys }
                            .buttonStyle(.link)
                            .font(Theme.Typography.secondary)
                    }
                case .ollama:
                    Picker("Model", selection: ollamaModelSelection) {
                        ForEach(OllamaCatalog.models, id: \.id) { entry in
                            Text(entry.label).tag(entry.id)
                        }
                        Divider()
                        Text("Custom…").tag("custom")
                    }
                    .pickerStyle(.menu)

                    if showsOllamaCustomField {
                        LabeledContent("Model name") {
                            // Empty title + prompt: a titled TextField in a Form
                            // renders its title as a second trailing label.
                            TextField("", text: $copilotOllamaModel, prompt: Text("model:tag"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 220)
                        }
                        Hint("Any model from ollama.com/library. Prefer small instruct models; thinking models are too slow for live cards.")
                    }

                    OllamaModelStatusView(model: copilotOllamaModel)

                    Hint("Runs on this Mac: free, private, offline. Live cards arrive slower and read rougher than Claude's; reports are unaffected.")
                case .custom:
                    LabeledContent("Server URL") {
                        TextField("", text: $copilotCustomBaseURL, prompt: Text("https://api.openai.com/v1"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                    }
                    LabeledContent("Model") {
                        TextField("", text: $copilotCustomModel, prompt: Text("gpt-5-mini"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    }
                    ProviderKeyField(
                        label: "API key",
                        account: "custom-llm-api-key",
                        placeholder: "optional — not needed for local servers",
                        hint: "Any OpenAI-compatible server: OpenAI, Gemini, Groq, OpenRouter, LM Studio… Costs aren't estimated for custom servers."
                    )
                }
    }

    /// Dropdown selection for the Ollama model: catalog id, or "custom" when the
    /// stored model isn't in the catalog (or the user picked Custom…).
    private var ollamaModelSelection: Binding<String> {
        Binding(
            get: {
                if ollamaCustomModelEditing { return "custom" }
                return OllamaCatalog.ids.contains(copilotOllamaModel) ? copilotOllamaModel : "custom"
            },
            set: { picked in
                if picked == "custom" {
                    ollamaCustomModelEditing = true
                } else {
                    ollamaCustomModelEditing = false
                    copilotOllamaModel = picked
                }
            }
        )
    }

    private var showsOllamaCustomField: Bool {
        ollamaCustomModelEditing || !OllamaCatalog.ids.contains(copilotOllamaModel)
    }

    // MARK: - API Keys

    private var apiKeysPage: some View {
        Form {
            Section("Claude — powers the copilot") {
                ProviderKeyField(
                    label: "Claude API key",
                    account: nil,
                    placeholder: "sk-ant-…",
                    hint: "Only transcript text is sent — audio never leaves your Mac. Keys: console.anthropic.com"
                )
            }

            Section("Groq — cloud transcription & polish") {
                ProviderKeyField(
                    label: "Groq API key",
                    account: TranscriptionBackend.groq.keychainAccount!,
                    placeholder: "gsk_…",
                    hint: "Used when the Groq engine or polish is on. Keys: console.groq.com"
                )
            }

            Section("Deepgram — streaming transcription") {
                ProviderKeyField(
                    label: "Deepgram API key",
                    account: TranscriptionBackend.deepgram.keychainAccount!,
                    placeholder: "40-character hex key",
                    hint: "Billed per audio track. New accounts include $200 credit. Keys: console.deepgram.com"
                )
            }

            Section {
                Hint("All keys are stored in your macOS keychain, never in the app's files.")
            }
        }
    }

    // MARK: - Knowledge

    private var knowledgePage: some View {
        Form {
            Section("Documents") {
                Hint("The copilot grounds its answers in these and cites the source. Indexed on this Mac, never uploaded.")

                if recordingManager.knowledgeBase.documents.isEmpty {
                    Text("No documents yet")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink3)
                } else {
                    ForEach(recordingManager.knowledgeBase.documents) { document in
                        KBDocumentRow(document: document, knowledgeBase: recordingManager.knowledgeBase)
                    }
                }

                HStack {
                    Button("Add Documents…") {
                        showFileImporter = true
                    }

                    if recordingManager.knowledgeBase.isIndexing {
                        ProgressView()
                            .controlSize(.small)
                        Text("Indexing…")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Colors.ink2)
                    }
                }

                if let error = recordingManager.knowledgeBase.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.warn)
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .plainText, .text],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task {
                    await recordingManager.knowledgeBase.addDocuments(at: urls)
                }
            }
        }
    }
}

enum Appearance: String, CaseIterable {
    case system, light, dark
}

// MARK: - Settings nav row

/// The guide button. macOS's stock HelpLink is a hairline grey circle nobody
/// sees, so this is a filled accent disc with a white glyph that lifts on
/// hover — the one control in the sidebar that should catch a lost eye.
private struct HelpCircleButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.Colors.accent.opacity(hovering ? 1 : 0.9), in: Circle())
                .shadow(color: Theme.Colors.accent.opacity(hovering ? 0.45 : 0.25),
                        radius: hovering ? 5 : 3, y: 1)
                .scaleEffect(hovering ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help("Parrot Help")
        .accessibilityLabel("Parrot Help")
    }
}

private struct SettingsNavRow: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.Colors.accent : Theme.Colors.ink2)
                Text(title)
                    .font(Theme.Typography.sans(13, .medium))
                    .foregroundStyle(Theme.Colors.ink)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Theme.Colors.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - One-line hint

/// The ONE way explanatory text appears on a settings page: a single readable
/// line at secondary size. Anything longer belongs in the control's own label.
/// One permission: a colored status dot, the state in words, and a button to
/// the System Settings pane that changes it. Read-only by design; every grant
/// is made in System Settings, never by a prompt from a settings screen.
struct PermissionStatusRow: View {
    let title: String
    let granted: Bool
    let detail: String
    /// Privacy pane id for PermissionFlow.openSettings; nil opens Notifications.
    let pane: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(detail)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(granted ? Theme.Colors.good : Theme.Colors.ink2)
                Button("Open…") {
                    if let pane {
                        PermissionFlow.openSettings(pane: pane)
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                Circle()
                    .fill(granted ? Theme.Colors.good : Theme.Colors.ink3)
                    .frame(width: 8, height: 8)
            }
        }
    }
}

/// A person's name as a button: click to set or change the alias for the
/// identity behind it. Shows the alias when there is one, the identity
/// otherwise, and the identity in grey next to an alias so both are visible.
struct PersonNameButton: View {
    let identity: String
    @Binding var editing: String?
    @State private var draft = ""

    private var isEditing: Binding<Bool> {
        Binding(get: { editing == identity }, set: { if !$0 { editing = nil } })
    }

    var body: some View {
        Button {
            draft = PeopleDirectory.alias(for: identity) ?? ""
            editing = identity
        } label: {
            HStack(spacing: 6) {
                Text(PeopleDirectory.displayName(for: identity))
                    .foregroundStyle(Theme.Colors.accent)
                    .underline(pattern: .dot)
                if PeopleDirectory.alias(for: identity) != nil,
                   PeopleDirectory.canonical(identity) != PeopleDirectory.canonical(PeopleDirectory.displayName(for: identity)) {
                    Text(identity)
                        .foregroundStyle(Theme.Colors.ink3)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Set the name shown for \(identity)")
        .popover(isPresented: isEditing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Name for \(identity)")
                    .font(Theme.Typography.caption)
                    .fontWeight(.semibold)
                TextField("e.g. Andrew Laski", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                HStack {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if PeopleDirectory.alias(for: identity) != nil {
                        Button("Clear") {
                            PeopleDirectory.setAlias(nil, for: identity)
                            editing = nil
                        }
                    }
                    Spacer()
                }
                Text("Applies everywhere this identity appears, in past meetings too.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink3)
            }
            .padding(12)
            .frame(width: 300)
        }
    }

    private func save() {
        PeopleDirectory.setAlias(draft, for: identity)
        editing = nil
    }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.Typography.secondary)
            .foregroundStyle(Theme.Colors.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Knowledge Base Document Row

struct KBDocumentRow: View {
    let document: KBDocument
    let knowledgeBase: KnowledgeBaseService

    @State private var note: String

    init(document: KBDocument, knowledgeBase: KnowledgeBaseService) {
        self.document = document
        self.knowledgeBase = knowledgeBase
        _note = State(initialValue: document.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: document.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text")
                    .foregroundStyle(Theme.Colors.ink2)

                Text(document.name)
                    .font(Theme.Typography.sans(13, .medium))
                    .lineLimit(1)

                Text("\(document.chunkCount) chunks")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink3)

                Spacer()

                Button {
                    knowledgeBase.removeDocument(document)
                } label: {
                    Image(systemName: "trash")
                        .font(Theme.Typography.caption)
                }
                .buttonStyle(.plain)
                .help("Remove from knowledge base")
            }

            TextField(
                "When should the copilot use this? e.g. \"use for pricing questions\"",
                text: $note
            )
            .textFieldStyle(.roundedBorder)
            .font(Theme.Typography.secondary)
            .onSubmit {
                knowledgeBase.updateNote(note, for: document)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Provider API key field

/// Reusable BYO-key field: Keychain-backed, explicit Save, and a visible error
/// when the write fails. `account: nil` targets the default (Claude) slot.
struct ProviderKeyField: View {
    let label: String
    let account: String?
    let placeholder: String
    let hint: String

    @State private var key: String
    @State private var saved = false
    @State private var failed = false

    init(label: String, account: String?, placeholder: String, hint: String) {
        self.label = label
        self.account = account
        self.placeholder = placeholder
        self.hint = hint
        let stored = account.map { APIKeyStore.load(account: $0) } ?? APIKeyStore.load()
        _key = State(initialValue: stored ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField(placeholder, text: $key, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .onChange(of: key) {
                    saved = false
                    failed = false
                }

            HStack {
                Button("Save Key") {
                    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    let ok = account.map { APIKeyStore.save(trimmed, account: $0) }
                        ?? APIKeyStore.save(trimmed)
                    failed = !ok
                    saved = ok
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if saved {
                    Label("Saved", systemImage: "checkmark.circle")
                        .foregroundStyle(Theme.Colors.good)
                        .font(Theme.Typography.secondary)
                } else if failed {
                    Label("Keychain rejected the key — try again", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Colors.warn)
                        .font(Theme.Typography.secondary)
                }
            }

            Hint(hint)
        }
    }
}
