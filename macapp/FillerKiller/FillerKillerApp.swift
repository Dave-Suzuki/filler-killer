// Filler Killer — macOS menu bar app.
// M3: sessions persist. Segments are written incrementally (crash-safe), End
// & Save finalizes, Discard deletes. The Python tool's fk.db imports on first
// launch as a file copy.

import SessionKit
import SessionStore
import SpeechEngine
import SwiftUI

@main
struct FillerKillerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            SessionMenu(model: model)
        } label: {
            Text(model.barTitle)
        }
        Window("Filler Killer — Trends", id: "retro") {
            RetroView(model: RetroModel(store: model.sessionStore))
        }
        .defaultSize(width: 780, height: 720)
        Window("Connect Granola", id: "granola") {
            GranolaConnectView(model: model)
        }
        .defaultSize(width: 420, height: 220)
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
    @Published var events: [String] = [] // rolling speech-engine diagnostics
    @Published var micLevel: Float = 0
    @Published var alertsMuted = false
    @Published var bestCleanRun = 0

    @AppStorage("targetRate") var targetRate = 3.0

    private let hud = HUDController()
    private var cleanRunWords = 0
    private var firedCleanThresholds: Set<Int> = []
    private static let cleanThresholds = [50, 100, 250, 500]

    static let versionLine: String = {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "?"
        return "Filler Killer v\(short) (b\(build))"
    }()

    private var counter = LiveSessionCounter()
    private var transcriber: SpeechTranscriber?
    private var store: SessionStore?
    private var recorder: LiveSessionRecorder?

    var sessionStore: SessionStore? { store }

    @Published var granolaConnected = GranolaKeychain.load() != nil
    @Published var granolaStatus = ""
    private var granolaTimer: Timer?
    private var syncing = false

    func startGranolaSchedule() {
        guard granolaConnected else { return }
        syncGranolaNow()
        granolaTimer?.invalidate()
        granolaTimer = Timer.scheduledTimer(
            withTimeInterval: 6 * 3600, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.syncGranolaNow() }
        }
    }

    func syncGranolaNow() {
        guard !syncing, let store, let key = GranolaKeychain.load() else { return }
        syncing = true
        granolaStatus = "Syncing Granola…"
        let engine = GranolaSyncEngine(store: store, client: GranolaClient(apiKey: key))
        Task {
            do {
                let stats = try await engine.sync()
                self.granolaStatus =
                    "Granola: +\(stats.added) new, \(stats.updated) updated, \(stats.skipped) unchanged"
                self.importedMeetings = (try? store.meetingCount()) ?? self.importedMeetings
            } catch {
                self.granolaStatus = "Granola sync failed: \(error.localizedDescription)"
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
        granolaStatus = ""
    }

    init() {
        openStore()
        startGranolaSchedule()
    }

    private func openStore() {
        do {
            let url = try SessionStore.defaultURL()
            let imported = try LegacyImport.importIfNeeded(to: url)
            let store = try SessionStore(url: url)
            self.store = store
            savedSessions = (try? store.savedSessionCount()) ?? 0
            importedMeetings = (try? store.meetingCount()) ?? 0
            if imported {
                status = "Imported your existing filler-killer data: "
                    + "\(importedMeetings) meetings, \(savedSessions) sessions."
            }
        } catch {
            status = "Storage unavailable: \(error.localizedDescription)"
        }
    }

    var barTitle: String {
        switch state {
        case .idle: return "FK —"
        case .listening: return "FK \(fillerCount) \(levelGlyph)"
        case .paused: return "FK ⏸ \(fillerCount)"
        }
    }

    /// Visible proof the mic is being heard, right in the menu bar.
    private var levelGlyph: String {
        switch micLevel {
        case ..<0.02: return "▁"
        case ..<0.1: return "▂"
        case ..<0.25: return "▃"
        case ..<0.5: return "▄"
        default: return "▅"
        }
    }

    func startSession() {
        Task { await doStart() }
    }

    private func doStart() async {
        status = ""
        guard await SpeechAuth.requestSpeechAuthorization() else {
            status = "Speech Recognition permission denied. Enable it for Filler "
                + "Killer in System Settings → Privacy & Security → Speech Recognition."
            return
        }
        guard await SpeechAuth.requestMicAuthorization() else {
            status = "Microphone permission denied. Enable it for Filler Killer "
                + "in System Settings → Privacy & Security → Microphone."
            return
        }
        do {
            counter = LiveSessionCounter()
            fillerCount = 0
            wordCount = 0
            rate = 0
            lastHits = []
            cleanRunWords = 0
            bestCleanRun = 0
            firedCleanThresholds = []
            if let store {
                let recorder = LiveSessionRecorder(store: store)
                try recorder.begin()
                self.recorder = recorder
            }
            events = []
            let transcriber = try SpeechTranscriber()
            transcriber.onFinal = { [weak self] text in
                DispatchQueue.main.async { self?.ingest(text) }
            }
            transcriber.onEvent = { [weak self] event in
                DispatchQueue.main.async { self?.pushEvent(event) }
            }
            transcriber.onLevel = { [weak self] level in
                self?.micLevel = level
            }
            try transcriber.start()
            self.transcriber = transcriber
            state = .listening
            status = transcriber.onDevice
                ? "Listening — on-device recognition"
                : "Listening — server recognition (enable Dictation once for on-device)"
        } catch {
            try? recorder?.discard()
            recorder = nil
            status = error.localizedDescription
        }
    }

    private func ingest(_ text: String) {
        guard state == .listening else { return } // paused: drop, don't count
        let wordsBefore = counter.wordCount
        let newHits = counter.addFinal(text)
        let segmentIdx = counter.segments.count - 1
        try? recorder?.record(segmentIdx: segmentIdx, text: text, at: Date(), hits: newHits)
        fillerCount = counter.fillerCount
        wordCount = counter.wordCount
        rate = counter.per100Words

        if newHits.isEmpty {
            // Clean run: consecutive words without a filler (positive
            // reinforcement — each threshold fires once per session).
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

    private func pushEvent(_ event: String) {
        events.append(event)
        if events.count > 6 {
            events.removeFirst(events.count - 6)
        }
    }

    func togglePause() {
        switch state {
        case .listening: state = .paused
        case .paused: state = .listening
        case .idle: break
        }
    }

    func endSession(save: Bool) {
        transcriber?.stop()
        transcriber = nil
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
                status = "Session #\(id) saved: \(fillerCount) fillers in "
                    + "\(wordCount) words (\(rate)/100w)."
            } else {
                status = "Session ended (not saved — storage unavailable)."
            }
        } else {
            try? recorder?.discard()
            status = "Session discarded."
        }
        recorder = nil
        state = .idle
    }
}

struct SessionMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.state {
        case .idle:
            Button("Start Session") { model.startSession() }
            if model.savedSessions > 0 || model.importedMeetings > 0 {
                Text("\(model.savedSessions) sessions · \(model.importedMeetings) meetings stored")
            }
        case .listening, .paused:
            Text("\(model.fillerCount) fillers · \(model.wordCount) words · "
                + String(format: "%.2f", model.rate) + "/100w")
            if !model.lastHits.isEmpty {
                Text("last: " + model.lastHits.joined(separator: ", "))
            }
            if model.bestCleanRun > 0 {
                Text("best clean run: \(model.bestCleanRun) words")
            }
            Button(model.state == .paused ? "Resume" : "Pause") {
                model.togglePause()
            }
            Button(model.alertsMuted ? "Unmute Alerts" : "Mute Alerts") {
                model.alertsMuted.toggle()
            }
            Button("End & Save") { model.endSession(save: true) }
            Button("Discard Session") { model.endSession(save: false) }
            if !model.events.isEmpty {
                Divider()
                Text(model.events.joined(separator: "\n"))
            }
        }
        if !model.status.isEmpty {
            Divider()
            Text(model.status)
        }
        Divider()
        Button("Open Trends") {
            openWindow(id: "retro")
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        if model.granolaConnected {
            Button("Sync Granola Now") { model.syncGranolaNow() }
            if !model.granolaStatus.isEmpty {
                Text(model.granolaStatus)
            }
        } else {
            Button("Connect Granola…") {
                openWindow(id: "granola")
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        Text(AppModel.versionLine)
        Button("Quit Filler Killer") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
