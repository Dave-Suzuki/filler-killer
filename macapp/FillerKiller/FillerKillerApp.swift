// Filler Killer — macOS menu bar app.
// v0.7: product polish — window-style popover, SF Symbol bar states,
// privacy-consented recognition, discreet mode, onboarding, microcopy.

import AppKit
import SessionKit
import SessionStore
import SpeechEngine
import SwiftUI

@main
struct FillerKillerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            BarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Trends", id: "retro") {
            RetroView(app: model)
        }
        .defaultSize(width: 780, height: 720)

        Window("Connect Granola", id: "granola") {
            GranolaConnectView(model: model)
        }
        .defaultSize(width: 420, height: 220)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Menu bar label: template images, never judgment colors, count hidden
/// by default while listening (it's visible to screen shares). Idle shows
/// the brand glyph (the app icon's slashed speech bubble as a template
/// image); listening switches to the live waveform, which doubles as a
/// mic-level meter.
struct BarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.state {
        case .idle:
            if model.onDeviceBlocked {
                Image(systemName: "waveform.badge.exclamationmark")
            } else {
                Image("MenuBarIcon")
            }
        case .paused:
            Image(systemName: "waveform.slash")
        case .listening:
            if model.showCountWhileListening {
                HStack(spacing: 3) {
                    Image(systemName: "waveform", variableValue: Double(model.micLevel))
                    Text("\(model.fillerCount)").monospacedDigit()
                }
            } else {
                Image(systemName: "waveform", variableValue: Double(model.micLevel))
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum SessionState {
        case idle, listening, paused
    }

    @Published var state: SessionState = .idle
    @Published var status = ""
    @Published var fillerCount = 0
    @Published var wordCount = 0
    @Published var rate = 0.0
    @Published var lastHits: [String] = []
    @Published var savedSessions = 0
    @Published var importedMeetings = 0
    @Published var micLevel: Float = 0
    @Published var alertsMuted = false
    @Published var bestCleanRun = 0
    @Published var onDeviceBlocked = false

    @AppStorage("targetRate") var targetRate = 3.0
    @AppStorage("showCountWhileListening") var showCountWhileListening = false
    @AppStorage("allowServerRecognition") var allowServerRecognition = false
    @AppStorage("onboarded") var onboarded = false
    // Names Granola may label the user with in meetings captured by someone
    // else (comma-separated). Empty falls back to the macOS account name.
    @AppStorage("granolaMyNames") var granolaMyNames = ""
    // Granola account email: matched against note owner metadata so meetings
    // captured by someone else where the user never speaks aren't counted.
    @AppStorage("granolaMyEmail") var granolaMyEmail = ""

    var granolaSelfNames: [String] {
        let configured = granolaMyNames.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return configured.isEmpty ? [NSFullUserName()] : configured
    }

    var granolaSelfEmail: String? {
        let trimmed = granolaMyEmail.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    @Published var granolaConnected = GranolaKeychain.load() != nil
    @Published var granolaStatus = ""
    @Published var syncing = false

    // Post-session report: the just-saved session's retro id ("l:<id>"),
    // and a one-shot navigation request the Trends window consumes.
    @Published var lastSavedReportId: String?
    @Published var pendingRetroItemId: String?

    private let hud = HUDController()
    private var counter = LiveSessionCounter()
    private var transcriber: SpeechTranscriber?
    private var store: SessionStore?
    private var recorder: LiveSessionRecorder?
    private var events: [String] = [] // diagnostics: Settings-only, never UI
    private var granolaTimer: Timer?
    private var granolaProbeTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var cleanRunWords = 0
    private var firedCleanThresholds: Set<Int> = []
    private var onboardingWindow: NSWindow?
    private static let cleanThresholds = [50, 100, 250, 500]

    var sessionStore: SessionStore? { store }

    static let versionLine: String = {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "?"
        return "Filler Killer v\(short) (b\(build))"
    }()

    init() {
        openStore()
        startGranolaSchedule()
        DispatchQueue.main.async { [weak self] in
            self?.showOnboardingIfNeeded()
        }
    }

    // MARK: - Storage

    private func openStore() {
        do {
            let url = try SessionStore.defaultURL()
            let imported = try LegacyImport.importIfNeeded(to: url)
            let store = try SessionStore(url: url)
            self.store = store
            savedSessions = (try? store.savedSessionCount()) ?? 0
            importedMeetings = (try? store.meetingCount()) ?? 0
            if imported {
                status = "Welcome back — imported \(importedMeetings) meetings "
                    + "and \(savedSessions) sessions from the filler-killer tool."
            }
        } catch {
            logEvent("store open failed: \(error)")
            status = "Filler Killer can't open its database, so sessions won't be saved."
        }
    }

    func deleteAllData() -> Bool {
        do {
            try store?.deleteAllData()
            savedSessions = 0
            importedMeetings = 0
            return true
        } catch {
            logEvent("delete-all failed: \(error)")
            return false
        }
    }

    func revealDataFolder() {
        if let url = try? SessionStore.defaultURL() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Sessions

    func startSession() {
        Task { await doStart() }
    }

    private func doStart() async {
        status = ""
        guard await SpeechAuth.requestSpeechAuthorization() else {
            status = "Speech Recognition is off for Filler Killer. Turn it on in "
                + "System Settings → Privacy & Security → Speech Recognition."
            return
        }
        guard await SpeechAuth.requestMicAuthorization() else {
            status = "Microphone access is off for Filler Killer. Turn it on in "
                + "System Settings → Privacy & Security → Microphone."
            return
        }
        counter = LiveSessionCounter()
        fillerCount = 0
        wordCount = 0
        rate = 0
        lastHits = []
        lastSavedReportId = nil
        cleanRunWords = 0
        bestCleanRun = 0
        firedCleanThresholds = []
        events = []
        if let store {
            let recorder = LiveSessionRecorder(store: store)
            try? recorder.begin()
            self.recorder = recorder
        }
        if startEngine() {
            state = .listening
        } else {
            try? recorder?.discard()
            recorder = nil
        }
    }

    /// Creates and starts a transcriber. Never falls back silently: if the
    /// on-device model is missing and the user hasn't consented to server
    /// recognition, this surfaces the consent card instead.
    @discardableResult
    private func startEngine() -> Bool {
        do {
            let transcriber = try SpeechTranscriber(allowServer: allowServerRecognition)
            transcriber.onFinal = { [weak self] text in
                DispatchQueue.main.async { self?.ingest(text) }
            }
            transcriber.onEvent = { [weak self] event in
                DispatchQueue.main.async { self?.logEvent(event) }
            }
            transcriber.onLevel = { [weak self] level in
                self?.micLevel = level
            }
            try transcriber.start()
            self.transcriber = transcriber
            onDeviceBlocked = false
            if !transcriber.onDevice {
                status = "Listening — using Apple's servers this once. Turn on "
                    + "Dictation in System Settings for fully on-device."
            }
            return true
        } catch is OnDeviceUnavailableError {
            onDeviceBlocked = true
            status = ""
            return false
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    func consentToServerRecognition() {
        allowServerRecognition = true
        onDeviceBlocked = false
        startSession()
    }

    func openDictationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func ingest(_ text: String) {
        guard state == .listening else { return }
        let wordsBefore = counter.wordCount
        let newHits = counter.addFinal(text)
        let segmentIdx = counter.segments.count - 1
        try? recorder?.record(segmentIdx: segmentIdx, text: text, at: Date(), hits: newHits)
        fillerCount = counter.fillerCount
        wordCount = counter.wordCount
        rate = counter.per100Words

        if newHits.isEmpty {
            cleanRunWords += counter.wordCount - wordsBefore
            bestCleanRun = max(bestCleanRun, cleanRunWords)
            if !alertsMuted,
               let crossed = Self.cleanThresholds.last(where: {
                   cleanRunWords >= $0 && !firedCleanThresholds.contains($0)
               }) {
                firedCleanThresholds.insert(crossed)
                hud.flashCleanRun(words: crossed)
            }
        } else {
            lastHits = newHits.map { $0.term }
            cleanRunWords = 0
            if !alertsMuted {
                hud.flashFillers(
                    terms: newHits.map { $0.term },
                    sessionCount: fillerCount,
                    rate: rate,
                    target: targetRate
                )
            }
        }
    }

    /// Pause STOPS the audio engine — the mic indicator goes dark, because
    /// "paused but still listening" reads as spying.
    func togglePause() {
        switch state {
        case .listening:
            // stop() returns un-finalized speech; count it before pausing so
            // the words right before the pause aren't dropped.
            if let pending = transcriber?.stop() {
                ingest(pending)
            }
            transcriber = nil
            micLevel = 0
            state = .paused
        case .paused:
            if startEngine() {
                state = .listening
            }
        case .idle:
            break
        }
    }

    func endSession(save: Bool) {
        // Count pending speech BEFORE teardown: stop() returns it because an
        // async onFinal delivery would arrive after the session is saved.
        if let pending = transcriber?.stop(), state == .listening {
            ingest(pending)
        }
        transcriber = nil
        micLevel = 0
        hud.hideNow()
        if save {
            let id = try? recorder?.finish(
                label: nil,
                wordCount: counter.wordCount,
                fillerCount: counter.fillerCount,
                per100Words: counter.per100Words
            )
            savedSessions = (try? store?.savedSessionCount()) ?? savedSessions
            if let id {
                // Retro hides zero-word items, so only offer a report with words.
                lastSavedReportId = counter.wordCount > 0 ? "l:\(id)" : nil
                let lead = bestCleanRun > 0 ? "Best clean run: \(bestCleanRun) words. " : ""
                status = lead + "Saved. \(fillerCount) fillers in \(wordCount) words — "
                    + String(format: "%.1f", rate) + " per 100."
            } else {
                status = "Session finished, but it couldn't be saved — Filler "
                    + "Killer can't reach its database."
            }
        } else {
            try? recorder?.discard()
            lastSavedReportId = nil
            status = "Discarded — like it never happened."
        }
        recorder = nil
        state = .idle
        // A live session usually parallels a meeting whose Granola note lands
        // a few minutes later — probe soon instead of waiting for the timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            Task { @MainActor in self?.probeGranolaNow() }
        }
    }

    /// "View Report" after a saved session: ask the Trends window to open
    /// drilled into that session's transcript.
    func openReport(_ itemId: String, _ open: () -> Void) {
        pendingRetroItemId = itemId
        openTrends(open)
    }

    func previewHUD(terms: [String], count: Int, rate: Double) {
        hud.flashFillers(terms: terms, sessionCount: count, rate: rate, target: targetRate)
    }

    // MARK: - Diagnostics (Settings-only)

    private func logEvent(_ event: String) {
        events.append(event)
        if events.count > 50 {
            events.removeFirst(events.count - 50)
        }
    }

    func copyDiagnostics() {
        let text = ([AppModel.versionLine] + events).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Windows

    func openTrends(_ open: () -> Void) {
        open()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showOnboardingIfNeeded() {
        guard !onboarded, onboardingWindow == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(model: self) {
            [weak self] in
            self?.finishOnboarding()
        })
        window.center()
        onboardingWindow = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finishOnboarding() {
        onboarded = true
        onboardingWindow?.close()
        onboardingWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Granola

    func startGranolaSchedule() {
        guard granolaConnected else { return }
        syncGranolaNow()
        granolaTimer?.invalidate()
        granolaTimer = Timer.scheduledTimer(
            withTimeInterval: 6 * 3600, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.syncGranolaNow() }
        }
        // New notes land minutes after meetings end — a cheap freshness probe
        // (one tiny API page) every 15 minutes keeps the dashboard current
        // without waiting for the 6-hour full sync.
        granolaProbeTimer?.invalidate()
        granolaProbeTimer = Timer.scheduledTimer(
            withTimeInterval: 15 * 60, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.probeGranolaNow() }
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.probeGranolaNow() }
            }
        }
    }

    /// Sync only if the newest notes differ from the store — cheap enough to
    /// run often; a full sync fires only when there's actually something new.
    func probeGranolaNow() {
        guard granolaConnected, !syncing, let store,
              let key = GranolaKeychain.load() else { return }
        let engine = GranolaSyncEngine(
            store: store, client: GranolaClient(apiKey: key),
            myNames: granolaSelfNames, myEmail: granolaSelfEmail
        )
        Task {
            if (try? await engine.needsSync()) == true {
                self.logEvent("granola probe: new notes, syncing")
                self.syncGranolaNow()
            }
        }
    }

    func syncGranolaNow() {
        guard !syncing, let store, let key = GranolaKeychain.load() else { return }
        syncing = true
        granolaStatus = "Syncing…"
        let engine = GranolaSyncEngine(
            store: store, client: GranolaClient(apiKey: key),
            myNames: granolaSelfNames, myEmail: granolaSelfEmail
        )
        Task {
            do {
                let stats = try await engine.sync()
                self.granolaStatus = stats.added > 0
                    ? "Synced \(stats.added) new meeting\(stats.added == 1 ? "" : "s") just now"
                    : "Meetings up to date"
                self.logEvent("granola sync: +\(stats.added) ~\(stats.updated) =\(stats.skipped)")
                self.importedMeetings = (try? store.meetingCount()) ?? self.importedMeetings
            } catch {
                self.granolaStatus = "Granola sync didn't finish — will retry in 6 hours."
                self.logEvent("granola sync failed: \(error)")
            }
            self.syncing = false
        }
    }

    func connectGranola(key: String) async -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("grn_") else {
            return "That doesn't look like a Granola API key (grn_…)."
        }
        do {
            _ = try await GranolaClient(apiKey: trimmed).ping()
        } catch {
            return error.localizedDescription
        }
        GranolaKeychain.save(trimmed)
        granolaConnected = true
        startGranolaSchedule()
        return nil
    }

    func disconnectGranola() {
        GranolaKeychain.delete()
        granolaConnected = false
        granolaTimer?.invalidate()
        granolaProbeTimer?.invalidate()
        granolaStatus = ""
    }
}
