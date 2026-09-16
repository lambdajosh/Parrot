import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AppSession.self) private var appSession
    @Environment(\.modelContext) private var modelContext
    @State private var selectedMeeting: Meeting?
    @State private var showDashboard = true
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var hasLoadedModel = false
    /// File → Import Audio… (⌘O); the dashboard has its own importer button.
    @State private var showMenuImporter = false
    @State private var showBugReport = false
    /// Grabbed when the button is pressed, before the sheet covers the thing
    /// the user wants to show us.
    @State private var reportScreenshot: NSImage?
    @State private var recordError: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedMeeting: $selectedMeeting,
                showDashboard: $showDashboard,
                showSettings: $showSettings,
                searchText: $searchText
            )
            .navigationSplitViewColumnWidth(min: 215, ideal: 236, max: 320)
        } detail: {
            Group {
                if recordingManager.isRecording {
                    LiveRecordingView()
                        .navigationTitle("Recording")
                } else if showSettings {
                    settingsPane
                        .navigationTitle("Settings")
                } else if showDashboard {
                    DashboardView(
                        selectedMeeting: $selectedMeeting,
                        showDashboard: $showDashboard
                    )
                } else if let meeting = selectedMeeting {
                    // .id forces a fresh view identity per meeting: @State (title/name
                    // drafts, audio players, tab) must not leak from one meeting to the
                    // next, and onAppear/onDisappear must re-fire to stop playback.
                    MeetingDetailView(meeting: meeting, onDelete: {
                        // Clear the selection first so the detail view is gone
                        // before its model object is deleted.
                        selectedMeeting = nil
                        showDashboard = true
                        recordingManager.delete(meeting)
                    })
                    .id(meeting.id)
                    .navigationTitle(meeting.hasCustomTitle ? meeting.title : "Meeting")
                } else {
                    EmptyStateView()
                        .navigationTitle("Parrot")
                }
            }
            // The app's primary actions live in the toolbar, where a Mac user
            // looks for them, and stay put whatever the pane shows.
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if recordingManager.isRecording {
                        Button {
                            Task { await recordingManager.stopRecording() }
                        } label: {
                            Label(recordingManager.isStopping ? "Finalizing…" : "Stop", systemImage: "stop.fill")
                        }
                        .disabled(recordingManager.isStopping)
                        .help("Stop recording (⌘.)")
                    } else {
                        Button {
                            showMenuImporter = true
                        } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                        .disabled(recordingManager.importProgress != nil || !recordingManager.transcriptionEngine.isReady)
                        .help("Import an audio file as a meeting (⌘O)")

                        Button {
                            Task {
                                do {
                                    try await recordingManager.preflightPermissionsAndStart(modelContext: modelContext)
                                } catch {
                                    recordError = error.localizedDescription
                                }
                            }
                        } label: {
                            Label("Record", systemImage: "record.circle")
                                .foregroundStyle(recordingManager.transcriptionEngine.isReady ? Theme.Colors.stop : Theme.Colors.ink3)
                        }
                        .disabled(!recordingManager.transcriptionEngine.isReady)
                        .help("Start recording (⌘R)")
                    }
                }
            }
        }
        .alert("Couldn't start recording", isPresented: Binding(
            get: { recordError != nil },
            set: { if !$0 { recordError = nil } }
        )) {
            Button("OK") { recordError = nil }
        } message: {
            Text(recordError ?? "")
        }
        // Drop an audio file anywhere in the window to import it — off while
        // recording, which owns the shared WhisperKit.
        .audioImportDrop(enabled: !recordingManager.isRecording) { url in
            startImport(url)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let progress = recordingManager.importProgress {
                    ImportingBanner(progress: progress)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 12)
        }
        // Bug reports live in the Help menu (Help → Report a Bug…), where a
        // Mac user expects them; a floating button over the content is not
        // part of the platform's vocabulary.
        .sheet(isPresented: $showBugReport) {
            BugReportSheet(screenshot: reportScreenshot)
        }
        .onReceive(NotificationCenter.default.publisher(for: .parrotReportBug)) { _ in
            presentBugReport()
        }
        .animation(.easeInOut(duration: 0.2), value: recordingManager.importProgress)
        // Mirror the selection for the File → Export menu items.
        .onChange(of: selectedMeeting) { _, meeting in
            appSession.selectedMeeting = meeting
        }
        .onReceive(NotificationCenter.default.publisher(for: .parrotImportAudio)) { _ in
            if !recordingManager.isRecording { showMenuImporter = true }
        }
        .fileImporter(
            isPresented: $showMenuImporter,
            allowedContentTypes: AudioImport.contentTypes
        ) { result in
            if case .success(let url) = result { startImport(url) }
        }
        .task {
            guard !hasLoadedModel else { return }
            hasLoadedModel = true
            await recordingManager.prepare(modelContext: modelContext)
        }
    }

    private func presentBugReport() {
        reportScreenshot = BugReport.captureWindow()
        showBugReport = true
    }

    private func startImport(_ url: URL) {
        guard let meeting = recordingManager.importAudioFile(from: url, modelContext: modelContext) else { return }
        selectedMeeting = meeting
        showDashboard = false
        showSettings = false
    }

    /// Settings in the main pane — the old sheet was a cramped 520pt popup.
    /// The title is the navigation title, so the pane starts with content.
    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Full bleed — no width cap, no centering. A wider window means a
            // wider editor, period. Base font is the body scale; controls
            // without an explicit font inherit it.
            SettingsView(isEmbedded: true)
                .font(Theme.Typography.body)
                .padding(.horizontal, Theme.Metrics.pad)
                .padding(.vertical, Theme.Metrics.pad)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.canvas)
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(Theme.Colors.ink3)
            Text("Select a meeting or start recording")
                .font(.appTitle3)
                .foregroundStyle(Theme.Colors.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
