// The window-style menu bar popover — the app's primary surface.
// Three states (idle / listening / paused) per the design spec. Raw engine
// diagnostics never appear here; they're copyable from Settings.

import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingEnd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch model.state {
            case .idle:
                idleBody
            case .listening, .paused:
                sessionBody
            }
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            granolaRow
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform")
                .foregroundStyle(Color.accentColor)
            Text("Filler Killer")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            statePill
        }
    }

    private var statePill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(model.state == .listening ? Color.green
                    : model.state == .paused ? Color.orange : Color.secondary)
                .frame(width: 6, height: 6)
            Text(model.state == .listening ? "Listening"
                : model.state == .paused ? "Paused" : "Idle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Idle

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.onDeviceBlocked {
                consentCard
            }
            Button {
                model.startSession()
            } label: {
                Text("Start Listening")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if let reportId = model.lastSavedReportId {
                Button {
                    model.openReport(reportId) { openWindow(id: "retro") }
                } label: {
                    Label("View Session Report", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            Text("On-device. Nothing leaves your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Explicit consent — the ONLY path to server recognition.
    private var consentCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("On-device speech isn't ready", systemImage: "waveform.badge.exclamationmark")
                .font(.callout.weight(.medium))
            Text("Enable Dictation once (System Settings → Keyboard) to keep "
                + "everything on your Mac — or allow Apple's servers for now.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Settings") {
                    model.openDictationSettings()
                }
                Button("Use Apple's servers") {
                    model.consentToServerRecognition()
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Listening / paused

    private var sessionBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(model.fillerCount)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: model.fillerCount)
                    .opacity(model.state == .paused ? 0.6 : 1)
                Text("fillers this session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.wordCount > 0 {
                HStack(spacing: 6) {
                    Text("\(model.wordCount) words ·")
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f per 100", model.rate))
                        .foregroundStyle(judgment(rate: model.rate, target: model.targetRate))
                }
                .font(.system(size: 12))
                .monospacedDigit()
                goalGauge
            } else if model.state == .listening {
                Text("Listening for ums…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if model.state == .paused {
                Text("Paused — nothing is being heard or counted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.lastHits.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LAST HEARD")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach(model.lastHits.prefix(3), id: \.self) { term in
                            Text("“\(term)”")
                                .font(.system(size: 11))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                    }
                }
            }

            if model.bestCleanRun > 0 {
                Label("Best clean run: \(model.bestCleanRun) words",
                      systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if confirmingEnd {
                HStack {
                    Button("Save session") {
                        confirmingEnd = false
                        model.endSession(save: true)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Discard") {
                        confirmingEnd = false
                        model.endSession(save: false)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Button(model.state == .paused ? "Resume" : "Pause") {
                        model.togglePause()
                    }
                    Button("End Session") {
                        confirmingEnd = true
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Button {
                        model.alertsMuted.toggle()
                    } label: {
                        Image(systemName: model.alertsMuted ? "bell.slash.fill" : "bell.slash")
                    }
                    .buttonStyle(.plain)
                    .help("Silence the on-screen pill for this session")
                }
            }
        }
    }

    private var granolaRow: some View {
        HStack(spacing: 8) {
            if model.granolaConnected {
                Button {
                    model.syncGranolaNow()
                } label: {
                    Label(model.syncing ? "Syncing…" : "Sync Granola",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)
                .disabled(model.syncing)
                Spacer()
                if !model.granolaStatus.isEmpty {
                    Text(model.granolaStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                Button {
                    model.openTrends { openWindow(id: "granola") }
                } label: {
                    Label("Connect Granola…", systemImage: "link")
                }
                .controlSize(.small)
                Spacer()
                Text("Analyze past meetings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var goalGauge: some View {
        GeometryReader { proxy in
            let fraction = model.targetRate > 0
                ? min(model.rate / (model.targetRate * 2), 1.0) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.5))
                Capsule()
                    .fill(judgment(rate: model.rate, target: model.targetRate))
                    .frame(width: max(proxy.size.width * fraction, 3))
            }
        }
        .frame(height: 4)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                model.openTrends { openWindow(id: "retro") }
            } label: {
                Label("Trends", systemImage: "chart.xyaxis.line")
            }
            .buttonStyle(.plain)
            Spacer()
            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.plain)
            .help(AppModel.versionLine)
        }
        .font(.system(size: 12))
    }
}
