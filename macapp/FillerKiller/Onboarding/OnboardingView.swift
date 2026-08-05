// First-run onboarding: four screens ending in the aha moment — the user
// reads a filler-stuffed sentence aloud and watches the REAL product count
// it live (actual transcriber, actual HUD). Granola is deliberately absent.

import SessionKit
import SpeechEngine
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let finish: () -> Void
    @State private var page = 0
    @StateObject private var demo = AhaDemo()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: privacy
                case 2: permissions
                default: aha
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls
        }
        .padding(24)
        .frame(width: 520, height: 460)
        .onChange(of: page) { _, newPage in
            if newPage == 3 { demo.start(model: model) } else { demo.stop() }
        }
        .onDisappear { demo.stop() }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 160, height: 160)
            }
            Text("Meet your um-counter.")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Filler Killer listens while you talk and counts the "
                + "you-knows, likes, and ums — so your next meeting has "
                + "fewer of them.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
        }
    }

    private var privacy: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Your voice stays here.")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Recognition runs on-device with Apple's speech engine. No "
                + "audio or transcripts ever leave your Mac, and the on-screen "
                + "counter is invisible to screen sharing.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Two permissions, both local.")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
            permissionRow(
                symbol: "mic.fill",
                title: "Microphone",
                reason: "To hear you during sessions you start.",
                granted: demo.micGranted
            ) {
                Task { demo.micGranted = await SpeechAuth.requestMicAuthorization() }
            }
            permissionRow(
                symbol: "waveform",
                title: "Speech Recognition",
                reason: "To turn speech into countable words, on-device.",
                granted: demo.speechGranted
            ) {
                Task { demo.speechGranted = await SpeechAuth.requestSpeechAuthorization() }
            }
        }
        .frame(maxWidth: 400)
    }

    private func permissionRow(
        symbol: String, title: String, reason: String, granted: Bool,
        request: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 20))
            } else {
                Button("Allow", action: request)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var aha: some View {
        VStack(spacing: 16) {
            Text(demo.hitCount >= 3 ? "See how that felt?" : "Say this out loud:")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("“So, um, I think this is, like, actually working, you know?”")
                .font(.system(size: 17, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: 420)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            if demo.available {
                Text("\(demo.hitCount)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: demo.hitCount)
                    .foregroundStyle(demo.hitCount > 0 ? Color.accentColor : .secondary)
                Text(demo.hitCount >= 3
                    ? "That's the whole app — a quiet count while you talk."
                    : "fillers heard so far")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !demo.lastTerms.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(demo.lastTerms.prefix(4), id: \.self) { term in
                            Text("“\(term)”")
                                .font(.system(size: 11))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                    }
                }
            } else {
                Text("Grant the permissions on the previous page to try it "
                    + "live — or just continue; you'll see the counter pill "
                    + "whenever a filler slips out.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
    }

    private var controls: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0 ..< 4, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if page == 2, !(demo.micGranted && demo.speechGranted) {
                Button("I'll do this later") { page += 1 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Button(page == 3 ? "Start using Filler Killer" : "Continue") {
                if page == 3 {
                    demo.stop()
                    finish()
                } else {
                    page += 1
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.top, 12)
    }
}

/// Drives the screen-4 live demo with a throwaway transcriber + counter.
@MainActor
final class AhaDemo: ObservableObject {
    @Published var hitCount = 0
    @Published var lastTerms: [String] = []
    @Published var available = false
    @Published var micGranted = false
    @Published var speechGranted = false

    private var transcriber: SpeechTranscriber?
    private var counter = LiveSessionCounter()

    func start(model: AppModel) {
        guard transcriber == nil else { return }
        counter = LiveSessionCounter()
        hitCount = 0
        lastTerms = []
        do {
            let transcriber = try SpeechTranscriber(allowServer: model.allowServerRecognition)
            // Voice stats are ignored here: the demo counts whoever reads
            // the sentence.
            transcriber.onFinal = { [weak self, weak model] text, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let hits = self.counter.addFinal(text)
                    guard !hits.isEmpty else { return }
                    self.hitCount = self.counter.fillerCount
                    self.lastTerms = hits.map { $0.term }
                    // Fire the REAL product pill so the aha is the real thing.
                    model?.previewHUD(
                        terms: hits.map { $0.term },
                        count: self.counter.fillerCount,
                        rate: self.counter.per100Words
                    )
                }
            }
            try transcriber.start()
            self.transcriber = transcriber
            available = true
        } catch {
            available = false
        }
    }

    func stop() {
        transcriber?.stop()
        transcriber = nil
    }
}
