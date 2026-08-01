// Filler Killer — macOS menu bar app.
// M2: live listening. Start a session from the menu bar; the count ticks as
// you speak. Sessions are in-memory for now (persistence lands in M3).

import SessionKit
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

    private var counter = LiveSessionCounter()
    private var transcriber: SpeechTranscriber?

    var barTitle: String {
        switch state {
        case .idle: return "FK —"
        case .listening: return "FK \(fillerCount)"
        case .paused: return "FK ⏸ \(fillerCount)"
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
            let transcriber = try SpeechTranscriber()
            transcriber.onFinal = { [weak self] text in
                // SFSpeechRecognizer delivers on the main queue already, but
                // hop explicitly so this stays correct if that ever changes.
                DispatchQueue.main.async { self?.ingest(text) }
            }
            try transcriber.start()
            self.transcriber = transcriber
            state = .listening
            status = transcriber.onDevice
                ? "Listening — on-device recognition"
                : "Listening — server recognition (enable Dictation once for on-device)"
        } catch {
            status = error.localizedDescription
        }
    }

    private func ingest(_ text: String) {
        guard state == .listening else { return } // paused: drop, don't count
        let newHits = counter.addFinal(text)
        fillerCount = counter.fillerCount
        wordCount = counter.wordCount
        rate = counter.per100Words
        if !newHits.isEmpty {
            lastHits = newHits.map { $0.term }
        }
    }

    func togglePause() {
        switch state {
        case .listening: state = .paused
        case .paused: state = .listening
        case .idle: break
        }
    }

    func endSession() {
        transcriber?.stop()
        transcriber = nil
        status = "Session ended: \(fillerCount) fillers in \(wordCount) words "
            + "(\(rate)/100w). Saving arrives in the next build."
        state = .idle
    }
}

struct SessionMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.state {
        case .idle:
            Button("Start Session") { model.startSession() }
        case .listening, .paused:
            Text("\(model.fillerCount) fillers · \(model.wordCount) words · "
                + String(format: "%.2f", model.rate) + "/100w")
            if !model.lastHits.isEmpty {
                Text("last: " + model.lastHits.joined(separator: ", "))
            }
            Button(model.state == .paused ? "Resume" : "Pause") {
                model.togglePause()
            }
            Button("End Session") { model.endSession() }
        }
        if !model.status.isEmpty {
            Divider()
            Text(model.status)
        }
        Divider()
        Button("Quit Filler Killer") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
