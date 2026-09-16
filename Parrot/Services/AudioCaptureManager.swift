import AVFoundation
import ScreenCaptureKit
import CoreAudio
import Combine
import os

/// Captures system audio via ScreenCaptureKit and microphone via AVAudioEngine.
/// Provides mixed PCM audio for transcription and saves separate tracks to disk.
@Observable
final class AudioCaptureManager: NSObject {
    private var stream: SCStream?
    private var audioEngine: AVAudioEngine?
    // Write uncompressed PCM (.caf) via AVAudioFile rather than AAC/.m4a via
    // AVAssetWriter: on recent macOS the AAC encoder fails to initialize
    // (AudioCodecInitialize failed / -12651), producing silent 0-byte files.
    // PCM has no codec to fail. Each file is written only from its own serial
    // queue, off the audio render thread.
    private var systemAudioFile: AVAudioFile?
    private var micAudioFile: AVAudioFile?
    /// Set true before stopCapture's sync barriers. A straggler write block that
    /// was enqueued after the barriers must not lazily recreate an AVAudioFile on
    /// the finished URL — AVAudioFile(forWriting:) truncates, destroying the
    /// recording, and the stale file object would hijack the NEXT recording's
    /// audio. Plain Bool across threads, same accepted pattern as `isCapturing`.
    private var filesClosed = true
    private let systemWriteQueue = DispatchQueue(label: "com.uygar.parrot.audio.system")
    private let micWriteQueue = DispatchQueue(label: "com.uygar.parrot.audio.mic")
    /// Acoustic echo canceller, created per recording when enabled. Removes the
    /// speaker bleed from the mic using the system audio as the reference. nil =
    /// disabled (mic passes through untouched).
    private var echoCanceller: EchoCanceller?

    /// Which system-audio engine is live. The Core Audio process tap (macOS 15+,
    /// audio-only TCC — no Screen Recording ask) is preferred; ScreenCaptureKit
    /// is the 14.x path and the silent-tap rescue fallback.
    enum CaptureBackend: String { case none, tap, sck }
    @ObservationIgnored private(set) var captureBackend: CaptureBackend = .none
    /// The live SystemAudioTap on macOS 15+. Typed AnyObject because
    /// @available(macOS 15) types can't be stored properties at target 14.
    private var processTap: AnyObject?
    /// True once the tap delivered any nonzero sample this recording. An
    /// unauthorized tap "works" but produces exact zeros forever (measured, no
    /// error/status API exists), so first real audio is the only proof of the
    /// "System Audio Recording Only" grant — it also feeds the silence rescue.
    @ObservationIgnored private var tapEverHadSignal = false

    /// Throttle timestamps for pushing audio levels to the UI — the waveform needs
    /// only ~10 updates/sec, not one per ~20 ms audio buffer per stream.
    @ObservationIgnored private var lastSystemLevelAt = Date.distantPast
    @ObservationIgnored private var lastMicLevelAt = Date.distantPast

    /// Per-stream health lines in the unified log: mean level, buffer count,
    /// and all-zero buffer count per interval, enough to tell OS-delivered
    /// silence apart from a quiet room or AEC suppression after the fact.
    /// Always on at one line per stream per minute ("health"), because the
    /// 2026-09-16 dead-system-audio incident left no trace to read back: the
    /// opt-in AUDIODBG mode (PARROT_AUDIO_DEBUG=1 env, or
    /// `defaults write com.uygar.parrot audioDebug -bool YES`) tightens the
    /// same lines to every 5 s.
    static let audioDebugEnabled =
        ProcessInfo.processInfo.environment["PARROT_AUDIO_DEBUG"] != nil
        || UserDefaults.standard.bool(forKey: "audioDebug")
    static var healthInterval: TimeInterval { audioDebugEnabled ? 5 : 60 }
    @ObservationIgnored private var dbgMic = DebugAccumulator(label: "mic")
    @ObservationIgnored private var dbgSck = DebugAccumulator(label: "sck")

    /// Capture events and AUDIODBG lines go through os_log with explicit public
    /// privacy: NSLog from the sandboxed app is redacted to "<private>" in
    /// `log show`, which silently made the field diagnostics uncollectable.
    static let oslog = Logger(subsystem: "com.uygar.parrot", category: "capture")

    /// Accumulates levels between log flushes. Each instance is only touched
    /// from its own stream's callback thread.
    struct DebugAccumulator {
        let label: String
        let interval: TimeInterval
        let prefix: String
        var rawSum: Float = 0; var rawN = 0
        var cleanSum: Float = 0; var cleanN = 0
        var buffers = 0; var zeroBuffers = 0
        var lastFlush = Date()

        init(label: String) {
            self.label = label
            interval = AudioCaptureManager.healthInterval
            prefix = AudioCaptureManager.audioDebugEnabled ? "AUDIODBG" : "health"
        }

        mutating func add(raw: Float, clean: Float?, refBacklog: Int?, extra: String = "") {
            rawSum += raw; rawN += 1
            if let clean { cleanSum += clean; cleanN += 1 }
            buffers += 1
            if raw == 0 { zeroBuffers += 1 }
            let now = Date()
            guard now.timeIntervalSince(lastFlush) >= interval else { return }
            let rawAvg = rawN > 0 ? rawSum / Float(rawN) : 0
            let cleanAvg = cleanN > 0 ? cleanSum / Float(cleanN) : 0
            let cleanPart = clean != nil ? String(format: " clean=%.5f", cleanAvg) : ""
            let refPart = refBacklog.map { " refq=\($0)" } ?? ""
            let line = String(format: "%@ %@ raw=%.5f%@ bufs=%d zerobufs=%d%@%@",
                              prefix, label, rawAvg, cleanPart, buffers, zeroBuffers, refPart, extra)
            AudioCaptureManager.oslog.log("\(line, privacy: .public)")
            rawSum = 0; rawN = 0; cleanSum = 0; cleanN = 0
            buffers = 0; zeroBuffers = 0
            lastFlush = now
        }
    }

    /// Detects the OS silently cutting the mic feed (issue #12): a call app that
    /// grabs the microphone (Safari/Zoom voice processing) makes CoreAudio deliver
    /// exact digital zeros to every other client — the engine keeps running and no
    /// configuration-change notification fires, so the samples are the only tell.
    /// A real mic in a silent room still carries dither noise; a sustained run of
    /// *exact* zeros is always artificial. Pure logic so --profile-test can drive
    /// it with a fake clock.
    struct SignalWatchdog {
        enum Verdict: Equatable { case ok, lost, stillLost, recovered }
        /// Mic fuse: long enough to skip transient device glitches, short
        /// enough that the warning appears before the user wonders where their
        /// words went. The system stream uses a much longer fuse, see
        /// `systemRebuildAfter`.
        static let micLostAfter: TimeInterval = 2
        let lostAfter: TimeInterval
        private var zeroRunStartedAt: Date?
        private(set) var isLost = false

        init(lostAfter: TimeInterval = SignalWatchdog.micLostAfter) { self.lostAfter = lostAfter }

        mutating func observe(meanAbs: Float, at now: Date) -> Verdict {
            guard meanAbs == 0 else {
                zeroRunStartedAt = nil
                if isLost { isLost = false; return .recovered }
                return .ok
            }
            let start = zeroRunStartedAt ?? now
            zeroRunStartedAt = start
            if isLost { return .stillLost }
            guard now.timeIntervalSince(start) >= lostAfter else { return .ok }
            isLost = true
            return .lost
        }
    }

    /// True while the OS is delivering exact digital zeros on the mic — another
    /// app (typically a call) holds the microphone. Drives the device-bar warning
    /// and the periodic reclaim attempts. Issue #12.
    private(set) var micSignalLost = false
    /// Tap-callback thread only, like the debug accumulators.
    @ObservationIgnored private var micWatchdog = SignalWatchdog()
    /// Main thread only — collapses the per-buffer verdicts into one pending retry.
    @ObservationIgnored private var micRecoveryScheduled = false

    /// The system-audio twin of the mic watchdog. Two real failures (2026-09-15
    /// and 2026-09-16) had the tap keep delivering buffers of exact digital
    /// zeros for 6 and 61 minutes until the recording was stopped, while the
    /// mic kept working; no error surfaced anywhere. Calibrated on the six
    /// recordings around them (4.7 h of calls): normal call audio never held
    /// exact zeros longer than 59 s. So 20 s of zeros starts a quiet capture
    /// rebuild (harmless if the lull was real), and 90 s of zeros tells the
    /// user, since by then it has outlasted every healthy silence measured.
    static let systemRebuildAfter: TimeInterval = 20
    static let systemNotifyAfter: TimeInterval = 90
    /// True while the system feed is exact zeros past `systemRebuildAfter`.
    /// Drives the device-bar warning and the periodic rebuilds.
    private(set) var systemSignalLost = false
    /// Tap/SCK callback thread only.
    @ObservationIgnored private var systemWatchdog = SignalWatchdog(lostAfter: AudioCaptureManager.systemRebuildAfter)
    /// Main thread only.
    @ObservationIgnored private var systemLostAt: Date?
    @ObservationIgnored private var systemRecoveryScheduled = false
    @ObservationIgnored private var systemRecoveryAttempts = 0
    @ObservationIgnored private var systemLossNotified = false
    @ObservationIgnored private var systemRestartInFlight = false
    /// Listener on the system object for default-output-device changes.
    @ObservationIgnored private var outputDeviceListener: AudioObjectPropertyListenerBlock?

    enum SystemRecoveryStep: Equatable { case rebuildTap, screenCaptureKit }

    /// Which backend the next rebuild should use: the tap again, or, once the
    /// outage has outlasted every healthy silence and Screen Recording is
    /// granted, ScreenCaptureKit, which captures by a different mechanism.
    /// Pure so --profile-test can cover it.
    nonisolated static func systemRecoveryStep(outage: TimeInterval, screenGranted: Bool) -> SystemRecoveryStep {
        screenGranted && outage >= systemNotifyAfter ? .screenCaptureKit : .rebuildTap
    }

    private(set) var isCapturing = false
    private(set) var systemAudioURL: URL?
    private(set) var micAudioURL: URL?
    private(set) var audioLevel: Float = 0
    /// Live mic input level (separate from system audio) so the UI can show
    /// whether the user's own voice is actually being picked up.
    private(set) var micLevel: Float = 0
    /// Loudest mic buffer seen this recording. Separates "the mic delivers
    /// nothing" (dead/denied → micSeemsDead) from "the mic delivers a whisper"
    /// (input volume set very low → micVeryQuiet).
    private(set) var micPeakLevel: Float = 0
    /// Whether the mic stream is actually capturing (false = system audio only).
    private(set) var micActive = false
    private(set) var inputDeviceName = ""
    private(set) var outputDeviceName = ""
    /// Capture-start time, or the last moment the mic carried real signal. While the
    /// mic has never been heard it stays at capture start, so it doubles as "how long
    /// the mic has been silent since recording began".
    private(set) var lastMicSignalAt = Date.distantPast

    /// True once the mic has produced any real signal this recording. A user who is
    /// merely listening (normal while the other side talks) just hasn't spoken yet —
    /// that is not a dead mic — so once we've heard signal we never warn.
    private(set) var micEverHadSignal = false

    /// True when echo cancellation is enabled but the system-audio reference never
    /// arrives in the expected format — the AEC is then a silent no-op and the
    /// far end's voice can transcribe as "Me". Shown in the live device bar.
    private(set) var echoCancellerStarved = false

    /// True only when the mic has been on for a while but has never produced any
    /// signal — a genuinely dead, muted, or misrouted mic. We key off "never heard"
    /// rather than recent silence, because in a call the user is routinely silent for
    /// far longer than a few seconds while the other side is speaking.
    var micSeemsDead: Bool {
        isCapturing && micActive && !micEverHadSignal && micPeakLevel < 0.0008
            && Date().timeIntervalSince(lastMicSignalAt) > 15
    }

    /// True when the mic is alive but everything it has heard sits far below
    /// speech level — almost always the input volume slider set very low (a
    /// real session at 49% volume measured speech at ~0.0014 mean-abs,
    /// 2026-08-04). Transcription survives this (adaptive floor + decode
    /// normalization), but accuracy is better with real signal, so the device
    /// bar nudges the user. One healthy-loudness buffer flips
    /// `micEverHadSignal` and clears the hint for the session; mutually
    /// exclusive with `micSeemsDead` via the same peak split.
    var micVeryQuiet: Bool {
        isCapturing && micActive && !micEverHadSignal && micPeakLevel >= 0.0008
            && Date().timeIntervalSince(lastMicSignalAt) > 15
    }

    /// Called with PCM audio buffers suitable for WhisperKit, tagged with which
    /// stream they came from (mic = the user, system = everyone else).
    var onAudioBuffer: ((AVAudioPCMBuffer, AudioSource) -> Void)?

    /// Called after the mic engine is rebuilt following an input-device change,
    /// so the transcription clock for "Me" can be re-anchored past the dead gap.
    var onMicRestarted: (() -> Void)?
    /// Observer for AVAudioEngineConfigurationChange on the current engine.
    private var micRestartObserver: NSObjectProtocol?

    private let sampleRate: Double = 16000
    private let channels: UInt32 = 1

    /// Dev-harness only (--help-shots): make the device bar look mid-call
    /// without touching any real audio device.
    @MainActor
    func seedForSnapshot(input: String, output: String, micLevel: Float, systemLevel: Float) {
        inputDeviceName = input
        outputDeviceName = output
        micActive = true
        isCapturing = true
        micEverHadSignal = true
        lastMicSignalAt = Date()
        self.micLevel = micLevel
        audioLevel = systemLevel
    }

    // MARK: - Start Capture

    /// @MainActor for the same reason as TranscriptionEngine.loadModel: these
    /// lifecycle funcs mutate UI-observed state (`isCapturing`, `micActive`,
    /// device names…), and a nonisolated async func runs on the global executor
    /// — off-main observation mutations race SwiftUI/SwiftData invalidation.
    /// The tap/stream hot path is untouched: it stays off-main and already hops
    /// via DispatchQueue.main.async for every observable write.
    @MainActor
    func startCapture() async throws {
        let storageDir = Self.storageDirectory()
        let timestamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")

        systemAudioURL = storageDir.appendingPathComponent("system_\(timestamp).caf")
        micAudioURL = storageDir.appendingPathComponent("mic_\(timestamp).caf")

        inputDeviceName = Self.defaultDeviceName(input: true)
        outputDeviceName = Self.defaultDeviceName(input: false)
        Self.oslog.log("starting capture: input \(self.inputDeviceName, privacy: .public), output \(self.outputDeviceName, privacy: .public)")

        // Echo cancellation on by default (defeats speaker bleed without headphones).
        let aecEnabled = UserDefaults.standard.object(forKey: "echoCancellationEnabled") as? Bool ?? true
        echoCanceller = aecEnabled ? EchoCanceller() : nil

        // Reset both watchdogs before any tap can fire.
        micWatchdog = SignalWatchdog()
        micSignalLost = false
        micRecoveryScheduled = false
        systemWatchdog = SignalWatchdog(lostAfter: Self.systemRebuildAfter)
        systemSignalLost = false
        systemLostAt = nil
        systemRecoveryScheduled = false
        systemRecoveryAttempts = 0
        systemLossNotified = false
        tapEverHadSignal = false
        dbgMic = DebugAccumulator(label: "mic")
        // The alert for a dead system feed has to reach the user behind the
        // call window; ask on the first recording, not at launch.
        Notifier.shared.requestAuthorizationIfNeeded()

        filesClosed = false  // fresh URLs above; queues are idle, so no race

        try await startSystemAudioCapture()
        dbgSck = DebugAccumulator(label: captureBackend.rawValue)
        installOutputDeviceListener()

        // The microphone is optional. System audio ("Them") is the core capture;
        // a missing or denied mic must NOT abort the whole recording. If mic setup
        // fails we just don't get the user's own voice ("Me") and carry on.
        do {
            try startMicCapture()
            micActive = true
        } catch {
            micActive = false
            micAudioURL = nil
            Self.oslog.error("microphone unavailable, recording system audio only: \(error.localizedDescription, privacy: .public)")
        }

        lastMicSignalAt = Date()  // capture start; the "dead mic" warning waits on this
        micEverHadSignal = false
        micPeakLevel = 0
        echoCancellerStarved = false
        isCapturing = true
    }

    // MARK: - Stop Capture

    @MainActor
    func stopCapture() async {
        isCapturing = false
        micActive = false
        micEverHadSignal = false
        micSignalLost = false
        systemSignalLost = false
        audioLevel = 0
        micLevel = 0
        micPeakLevel = 0
        echoCanceller = nil
        removeOutputDeviceListener()

        // Stop system audio stream (whichever backend is live)
        if #available(macOS 15.0, *), let tap = processTap as? SystemAudioTap {
            tap.stop()
        }
        processTap = nil
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        captureBackend = .none

        // Stop mic engine
        if let micRestartObserver { NotificationCenter.default.removeObserver(micRestartObserver) }
        micRestartObserver = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        // Flush queued writes, then close the files. AVAudioFile finalizes the
        // .caf header when it deallocates; the sync barrier guarantees every
        // pending write has landed first. filesClosed goes up BEFORE the
        // barriers so any write block enqueued after them no-ops instead of
        // recreating (= truncating) the finished file.
        filesClosed = true
        systemWriteQueue.sync { systemAudioFile = nil }
        micWriteQueue.sync { micAudioFile = nil }

        if let url = systemAudioURL {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            Self.oslog.log("system audio file finalized: \(size, privacy: .public) bytes")
        }
    }

    // MARK: - System Audio

    /// Tap-first on macOS 15+ (audio-only permission), ScreenCaptureKit on 14.x
    /// or whenever the tap can't start. Both paths feed handleSystemAudio with
    /// identical 16 kHz mono buffers, so everything downstream is unaware.
    @MainActor
    private func startSystemAudioCapture() async throws {
        // ponytail: escape hatch for field debugging of the new path —
        // `defaults write com.uygar.parrot forceSCKCapture -bool YES`.
        if #available(macOS 15.0, *), !UserDefaults.standard.bool(forKey: "forceSCKCapture") {
            do {
                try startTapCapture()
                return
            } catch {
                Self.oslog.log("process-tap capture unavailable (\(error.localizedDescription, privacy: .public)), falling back to ScreenCaptureKit")
            }
            do {
                try await startSCKCapture()
            } catch {
                // Neither path came up. Report in the language of the new
                // permission, not the legacy Screen Recording one.
                throw CaptureError.systemAudioUnavailable
            }
            return
        }
        try await startSCKCapture()
    }

    @available(macOS 15.0, *)
    @MainActor
    private func startTapCapture() throws {
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!
        let tap = SystemAudioTap(targetFormat: targetFormat)
        tap.onBuffer = { [weak self] buffer in
            guard let self, self.isCapturing else { return }
            self.handleSystemAudio(buffer)
        }
        try tap.start()
        processTap = tap
        captureBackend = .tap
        scheduleTapSilenceRescue()
    }

    /// An unauthorized tap "succeeds" and delivers silence forever, with no way
    /// to ask TCC (measured). So while the tap stays all-zeros, every 15 s:
    /// swap to ScreenCaptureKit if Screen Recording IS granted (typical for
    /// users upgrading from the SCK era) — same buffers, same files, nothing
    /// downstream notices; otherwise recreate the tap, because a "System
    /// Audio" grant the user clicks mid-recording may only take effect on a
    /// tap created after it. Either way a recording converges to real audio
    /// within ~15 s of the user clicking Allow, and a false trigger (call
    /// genuinely silent for 15 s) is harmless for the same reason.
    @available(macOS 15.0, *)
    private func scheduleTapSilenceRescue() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.isCapturing, self.captureBackend == .tap, !self.tapEverHadSignal,
                  let tap = self.processTap as? SystemAudioTap else { return }
            tap.stop()
            self.processTap = nil
            if CGPreflightScreenCaptureAccess() {
                Self.oslog.log("system tap silent for 15 s — swapping to the ScreenCaptureKit backend")
                do {
                    try await self.startSCKCapture()
                } catch {
                    Self.oslog.error("SCK rescue failed — \(error.localizedDescription, privacy: .public)")
                }
            } else {
                Self.oslog.log("system tap silent for 15 s — recreating it to pick up a fresh System Audio grant")
                try? self.startTapCapture()  // re-arms this rescue
            }
        }
    }

    /// Tears down whichever system backend is live and starts one again:
    /// tap-first (or ScreenCaptureKit when asked), files and downstream
    /// untouched. Used by the watchdog, the output-device listener, and the
    /// "retry now" control in the device bar.
    @MainActor
    func restartSystemAudioCapture(reason: String, preferSCK: Bool = false) async {
        guard isCapturing, !systemRestartInFlight else { return }
        systemRestartInFlight = true
        defer { systemRestartInFlight = false }
        Self.oslog.log("restarting system audio capture (\(reason, privacy: .public))")
        if #available(macOS 15.0, *), let tap = processTap as? SystemAudioTap {
            tap.stop()
        }
        processTap = nil
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        captureBackend = .none
        do {
            if preferSCK {
                do { try await startSCKCapture() } catch { try await startSystemAudioCapture() }
            } else {
                try await startSystemAudioCapture()
            }
            dbgSck = DebugAccumulator(label: captureBackend.rawValue)
            Self.oslog.log("system audio capture restarted on \(self.captureBackend.rawValue, privacy: .public)")
        } catch {
            Self.oslog.error("system audio restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tap/SCK thread → main. Mirrors the mic watchdog: flip the observable
    /// flag, log with the facts a postmortem needs, and keep rebuilding until
    /// audio flows again.
    private func handleSystemWatchdog(_ verdict: SignalWatchdog.Verdict) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCapturing else { return }
            switch verdict {
            case .lost:
                self.systemSignalLost = true
                self.systemLostAt = Date().addingTimeInterval(-Self.systemRebuildAfter)
                self.systemRecoveryAttempts = 0
                Self.oslog.warning("system audio went to digital zeros for \(Int(Self.systemRebuildAfter), privacy: .public) s on \(self.captureBackend.rawValue, privacy: .public), output \(self.outputDeviceName, privacy: .public): rebuilding the capture")
                self.scheduleSystemRecovery(delay: 0)
            case .stillLost:
                self.scheduleSystemRecovery(delay: Self.systemRebuildAfter)
            case .recovered:
                let outage = self.systemLostAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
                self.systemSignalLost = false
                self.systemLostAt = nil
                Self.oslog.log("system audio recovered after \(outage, privacy: .public) s on \(self.captureBackend.rawValue, privacy: .public)")
                if self.systemLossNotified {
                    Notifier.shared.post(id: Notifier.systemAudioID,
                                         title: "System audio is back",
                                         body: "Parrot is hearing the other side again after \(outage) seconds of silence.")
                }
                self.systemLossNotified = false
            case .ok:
                break
            }
        }
    }

    /// Main thread. One pending attempt at a time, `systemRebuildAfter` apart.
    /// Once the outage passes `systemNotifyAfter` the user gets a notification
    /// and, with Screen Recording granted, the rebuild switches mechanism.
    private func scheduleSystemRecovery(delay: TimeInterval) {
        guard !systemRecoveryScheduled, isCapturing, systemSignalLost else { return }
        systemRecoveryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.systemRecoveryScheduled = false
            guard self.isCapturing, self.systemSignalLost else { return }
            let outage = self.systemLostAt.map { Date().timeIntervalSince($0) } ?? 0
            if !self.systemLossNotified, outage >= Self.systemNotifyAfter {
                self.systemLossNotified = true
                Self.oslog.error("system audio still zeros after \(Int(outage), privacy: .public) s and \(self.systemRecoveryAttempts, privacy: .public) rebuilds: notifying the user")
                Notifier.shared.post(id: Notifier.systemAudioID,
                                     title: "Parrot stopped hearing the other side",
                                     body: "System audio has been silent for \(Int(outage)) seconds. Parrot keeps reconnecting; if the other side is talking and this doesn't clear, stop and restart the recording.")
            }
            self.systemRecoveryAttempts += 1
            let step = Self.systemRecoveryStep(outage: outage, screenGranted: CGPreflightScreenCaptureAccess())
            let attempt = self.systemRecoveryAttempts
            Task { @MainActor in
                await self.restartSystemAudioCapture(
                    reason: "zero signal for \(Int(outage)) s, attempt \(attempt)",
                    preferSCK: step == .screenCaptureKit)
            }
        }
    }

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// The process tap follows the output route it was created on. When the
    /// default output device changes mid-call (AirPods connect or drop, a dock
    /// wakes up, the call app switches devices) the tap can keep delivering
    /// buffers that are all zeros. Log the switch, which is exactly the fact a
    /// postmortem needs, and rebuild the capture on the new route right away
    /// instead of waiting for the watchdog's fuse.
    private func installOutputDeviceListener() {
        removeOutputDeviceListener()
        var addr = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCapturing else { return }
                let name = Self.defaultDeviceName(input: false)
                Self.oslog.log("default output device changed: \(self.outputDeviceName, privacy: .public) -> \(name, privacy: .public)")
                self.outputDeviceName = name
                if self.captureBackend == .tap {
                    await self.restartSystemAudioCapture(reason: "output device changed to \(name)")
                }
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener) == noErr {
            outputDeviceListener = listener
        }
    }

    private func removeOutputDeviceListener() {
        guard let listener = outputDeviceListener else { return }
        var addr = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
        outputDeviceListener = nil
    }

    // MARK: - System Audio (ScreenCaptureKit)

    private func startSCKCapture() async throws {
        // Pre-check screen capture permission
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            throw CaptureError.screenRecordingDenied
        }

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = Int(channels)
        // We only want audio, minimize video overhead
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        // The system audio file is created lazily from the first buffer's format
        // (see the SCStreamOutput handler), so it always matches what we write.

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        self.stream = stream
        captureBackend = .sck
    }

    // MARK: - System audio ingest (shared by both backends)

    /// Everything downstream of capture: persist "Them" to disk, prove the tap
    /// grant, feed the echo-canceller reference, update the level, and hand the
    /// buffer to transcription. Buffers arrive as 16 kHz mono Float32 from
    /// either backend; runs on that backend's own audio queue.
    private func handleSystemAudio(_ pcmBuffer: AVAudioPCMBuffer) {
        // Persist everyone else's voice ("Them") as PCM.
        appendAudio(pcmBuffer, to: .system)

        let level = Self.meanAbs(Self.floats(from: pcmBuffer))

        // First nonzero sample through the tap is the only readable proof of
        // the System Audio TCC grant — persist it for PermissionFlow.
        if captureBackend == .tap, !tapEverHadSignal, level > 0 {
            tapEverHadSignal = true
            UserDefaults.standard.set(true, forKey: PermissionFlow.tapProvenKey)
        }

        // A tap that has never carried signal belongs to the silent-tap rescue
        // (an unproven grant); the watchdog covers a feed that was working and
        // then went to exact zeros.
        if captureBackend != .tap || tapEverHadSignal {
            let verdict = systemWatchdog.observe(meanAbs: level, at: Date())
            if verdict != .ok { handleSystemWatchdog(verdict) }
        }

        dbgSck.add(
            raw: level,
            clean: nil,
            refBacklog: nil,
            extra: String(format: " fmt=%.0fHz x%dch",
                          pcmBuffer.format.sampleRate, pcmBuffer.format.channelCount))

        // Feed the same audio to the echo canceller as the far-end reference, so it
        // can subtract this from the mic. Only when it's the expected 16 kHz mono.
        if pcmBuffer.format.sampleRate == sampleRate, pcmBuffer.format.channelCount == channels {
            echoCanceller?.pushReference(Self.floats(from: pcmBuffer))
        } else if echoCanceller != nil, !echoCancellerStarved {
            // Without a reference the AEC is silently a no-op and speaker bleed
            // transcribes as "Me" — surface it once instead of hiding it.
            Self.oslog.warning("echo canceller starved: system audio is \(pcmBuffer.format.sampleRate, privacy: .public) Hz x\(pcmBuffer.format.channelCount, privacy: .public)ch, expected \(self.sampleRate, privacy: .public) Hz mono")
            DispatchQueue.main.async { self.echoCancellerStarved = true }
        }

        // Update audio level
        updateAudioLevel(buffer: pcmBuffer)

        // Send everyone else's speech to transcription as "Them"
        onAudioBuffer?(pcmBuffer, .them)
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // NOTE: we previously enabled setVoiceProcessingEnabled(true) for acoustic
        // echo cancellation, but on this hardware it cancelled ALL mic input (the
        // user's own voice was lost — every recording came back with only "Them").
        // Reverted. Echo (mic picking up the speakers) is avoided by using
        // headphones; a safer AEC approach can be revisited and tested later.

        let inputFormat = inputNode.outputFormat(forBus: 0)

        // When mic access is denied/unavailable the input format collapses to 0
        // channels; installing a tap on that would crash. Bail out cleanly so the
        // caller can continue with system audio only.
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw CaptureError.noMicrophone
        }

        // The mic file is created lazily from the converted (16 kHz mono) format.

        // Convert mic audio to our target format for WhisperKit
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.isCapturing else { return }

            // Convert to target format
            guard let converter else { return }
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate
            )
            guard frameCount > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
                return
            }

            var error: NSError?
            var consumed = false
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                // Contract: the converter may call this more than once per
                // convert() during rate conversion — handing it the same buffer
                // again duplicates ~20 ms of mic audio (stutter in "Me").
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil {
                // Echo-cancel the mic using the system audio as reference. With AEC
                // off, this returns the mic unchanged. With it on, it returns cleaned
                // 10 ms frames (possibly empty until a frame fills) — fail-safe.
                let micFloats = Self.floats(from: convertedBuffer)
                // Watch the RAW mic, pre-AEC: the canceller legitimately emits
                // empty/quiet frames, but only the OS produces exact zeros.
                let verdict = self.micWatchdog.observe(meanAbs: Self.meanAbs(micFloats), at: Date())
                if verdict != .ok { self.handleMicWatchdog(verdict) }
                let cleaned = self.echoCanceller?.process(mic: micFloats) ?? micFloats
                self.dbgMic.add(
                    raw: Self.meanAbs(micFloats),
                    clean: cleaned.isEmpty ? nil : Self.meanAbs(cleaned),
                    refBacklog: self.echoCanceller?.referenceBacklog,
                    extra: String(format: " devfmt=%.0fHz", inputFormat.sampleRate))
                guard !cleaned.isEmpty,
                      let cleanedBuffer = Self.makeBuffer(cleaned, format: targetFormat) else { return }

                // Persist the user's voice ("Me") as 16 kHz mono PCM.
                self.appendAudio(cleanedBuffer, to: .mic)

                // Update the mic level so the UI can show the user's voice landing.
                self.updateAudioLevel(buffer: cleanedBuffer, isMic: true)

                // Send the user's speech to transcription as "Me"
                self.onAudioBuffer?(cleanedBuffer, .me)
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine

        // AVAudioEngine stops itself when the input device changes or vanishes
        // (dead AirPods, a manual input switch in System Settings) and never
        // comes back on its own — a 1-hour call once lost its mic at minute 44
        // this way. Rebuild the tap on whatever the new default input is.
        if let micRestartObserver { NotificationCenter.default.removeObserver(micRestartObserver) }
        micRestartObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartMicCapture()
        }
    }

    /// Tear down the stopped engine and rebuild the mic tap on the current
    /// default input. Retries for a while — a Bluetooth handoff takes seconds
    /// to settle, and mid-transition there may briefly be no input device.
    private func restartMicCapture(attempt: Int = 0) {
        guard isCapturing else { return }
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        do {
            try startMicCapture()
            micActive = true
            inputDeviceName = Self.defaultDeviceName(input: true)
            Self.oslog.log("mic restarted after device change: input \(self.inputDeviceName, privacy: .public)")
            // ponytail: the mic .caf keeps writing continuously, so its file
            // timeline compresses by the dead gap (post-call polish would place
            // late "Me" words early); pad silence on restart if that matters.
            onMicRestarted?()
        } catch {
            micActive = false
            guard attempt < 10 else {
                Self.oslog.error("mic restart gave up after \(attempt, privacy: .public) retries: \(error.localizedDescription, privacy: .public)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.restartMicCapture(attempt: attempt + 1)
            }
        }
    }

    /// Tap thread → main. Flips the observable flag and, while the mic stays
    /// zeroed, periodically rebuilds the input engine: if the app that held the
    /// mic is gone, the rebuild reclaims it instantly; if not, the fresh tap
    /// keeps reporting zeros and we simply try again. Either way the state is
    /// visible instead of the recording dying in silence.
    private func handleMicWatchdog(_ verdict: SignalWatchdog.Verdict) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch verdict {
            case .lost:
                self.micSignalLost = true
                Self.oslog.warning("mic feed went to digital zeros — another app likely holds the microphone")
                self.scheduleMicReclaim()
            case .stillLost:
                self.scheduleMicReclaim()
            case .recovered:
                self.micSignalLost = false
                Self.oslog.log("mic feed recovered")
            case .ok:
                break
            }
        }
    }

    /// Main thread. One pending reclaim at a time, 4 s apart — a rebuild is
    /// cheap but not free, and the common case (call app still holds the mic)
    /// needs patience, not a tight loop.
    private func scheduleMicReclaim() {
        guard !micRecoveryScheduled, isCapturing, micSignalLost else { return }
        micRecoveryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.micRecoveryScheduled = false
            guard self.isCapturing, self.micSignalLost else { return }
            Self.oslog.log("mic still zeroed — rebuilding the input engine to try to reclaim it")
            self.restartMicCapture()
        }
    }

    // MARK: - Audio File Writing

    private enum AudioStream { case system, mic }

    /// Appends a PCM buffer to a stream's .caf file off the capture/render thread.
    /// The file is created lazily from the first buffer's own format, so writes can
    /// never fail on a format mismatch and there is no codec to initialize. The
    /// buffer is deep-copied because the audio system reuses it after we return.
    private func appendAudio(_ buffer: AVAudioPCMBuffer, to stream: AudioStream) {
        guard let copy = buffer.deepCopy() else { return }
        let queue = stream == .system ? systemWriteQueue : micWriteQueue
        let url = stream == .system ? systemAudioURL : micAudioURL
        guard let url else { return }

        queue.async { [weak self] in
            guard let self, !self.filesClosed else { return }
            do {
                let file: AVAudioFile
                if stream == .system {
                    if self.systemAudioFile == nil {
                        self.systemAudioFile = try AVAudioFile(forWriting: url, settings: copy.format.settings)
                    }
                    file = self.systemAudioFile!
                } else {
                    if self.micAudioFile == nil {
                        self.micAudioFile = try AVAudioFile(forWriting: url, settings: copy.format.settings)
                    }
                    file = self.micAudioFile!
                }
                try file.write(from: copy)
            } catch {
                Self.oslog.error("\(String(describing: stream), privacy: .public) audio write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func updateAudioLevel(buffer: AVAudioPCMBuffer, isMic: Bool = false) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames {
            sum += abs(channelData[i])
        }
        let avg = sum / Float(max(frames, 1))

        // Throttle the main-thread hop per stream: the waveform only needs ~10
        // updates/sec, and dispatching every ~20 ms buffer (×2 streams) thrashed
        // SwiftUI. Sampling at 10 Hz still detects a live mic well within the
        // 15 s dead-mic window.
        let now = Date()
        if isMic {
            guard now.timeIntervalSince(lastMicLevelAt) >= 0.1 else { return }
            lastMicLevelAt = now
        } else {
            guard now.timeIntervalSince(lastSystemLevelAt) >= 0.1 else { return }
            lastSystemLevelAt = now
        }

        DispatchQueue.main.async {
            if isMic {
                self.micLevel = avg
                self.micPeakLevel = max(self.micPeakLevel, avg)
                // Speech sits well above room noise; treat this as "mic is alive".
                if avg > 0.004 {
                    self.lastMicSignalAt = Date()
                    self.micEverHadSignal = true
                }
            } else {
                self.audioLevel = avg
            }
        }
    }

    /// Name of the current system default input or output device (CoreAudio).
    static func defaultDeviceName(input: Bool) -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return "Unknown" }

        // The property is a CFString reference; fetch it through an Unmanaged
        // slot rather than &CFString (which the compiler rightly flags — taking
        // a raw pointer to an object reference is UB territory).
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &nameRef) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, ptr)
        }
        guard status == noErr, let name = nameRef?.takeRetainedValue() else {
            return "Unknown"
        }
        return name as String
    }

    // MARK: - Buffer helpers

    /// Mean absolute sample value — the same "energy" measure the transcription
    /// loop gates on (against its rolling adaptive floor).
    private static func meanAbs(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(into: Float(0)) { $0 += abs($1) } / Float(samples.count)
    }

    /// Mono float samples from a PCM buffer.
    private static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
    }

    /// Mono PCM buffer from float samples in the given format.
    private static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            ch[0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    // MARK: - Storage

    static func storageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Parrot/Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - SCStreamOutput

extension AudioCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isCapturing else { return }

        // Convert CMSampleBuffer to AVAudioPCMBuffer for WhisperKit
        guard let pcmBuffer = sampleBuffer.toAVAudioPCMBuffer(sampleRate: sampleRate, channels: channels) else {
            return
        }

        handleSystemAudio(pcmBuffer)
    }
}

// MARK: - Capture Error

enum CaptureError: LocalizedError {
    case noDisplay
    case noMicrophone
    case screenRecordingDenied
    case systemAudioUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display found for audio capture"
        case .noMicrophone: "No microphone available"
        case .screenRecordingDenied: "Screen Recording permission is required. Please grant it in System Settings > Privacy & Security > Screen & System Audio Recording, then restart Parrot."
        case .systemAudioUnavailable: "System audio capture could not start. Allow Parrot in System Settings > Privacy & Security > Screen & System Audio Recording, then try again."
        }
    }
}

// MARK: - Buffer Conversion Extensions

extension CMSampleBuffer {
    func toAVAudioPCMBuffer(sampleRate: Double, channels: UInt32) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        guard let avFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.pointee.mSampleRate,
            channels: AVAudioChannelCount(asbd.pointee.mChannelsPerFrame),
            interleaved: false
        ) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer, let channelData = pcmBuffer.floatChannelData else { return nil }

        // Copy audio data — handle float32 format
        let byteCount = min(length, Int(pcmBuffer.frameCapacity) * MemoryLayout<Float>.size)
        memcpy(channelData[0], data, byteCount)

        return pcmBuffer
    }
}

extension AVAudioPCMBuffer {
    /// Independent copy of the samples. Tap/conversion buffers are owned by the
    /// audio system and reused on the next callback, so we must copy before
    /// handing the data to an async writer.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        copy.frameLength = frameLength
        let frames = Int(frameLength)
        let channelCount = Int(format.channelCount)
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size)
            }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Int16>.size)
            }
        }
        return copy
    }

    func toCMSampleBuffer(presentationTime: AVAudioTime) -> CMSampleBuffer? {
        let format = self.format
        guard let formatDesc = format.formatDescription as CMFormatDescription? else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameLength), timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: CMTime(seconds: Double(presentationTime.sampleTime) / format.sampleRate, preferredTimescale: CMTimeScale(format.sampleRate)),
            decodeTimeStamp: .invalid
        )

        guard let data = floatChannelData?[0] else { return nil }
        let dataSize = Int(frameLength) * MemoryLayout<Float>.size

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard let block = blockBuffer else { return nil }
        CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: dataSize)

        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }
}
