// Minimal Settings (v0.7): goal, menu bar privacy, recognition consent,
// launch at login, data controls, diagnostics. Grows tabs in the next round.

import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmingDelete = false
    @State private var dataMessage = ""
    @State private var removedMeetings = 0

    var body: some View {
        Form {
            Section("Goal") {
                HStack {
                    Slider(value: $model.targetRate, in: 0.5 ... 8.0, step: 0.5)
                    Text(String(format: "%.1f per 100 words", model.targetRate))
                        .monospacedDigit()
                        .frame(width: 130, alignment: .trailing)
                }
            }
            Section("Menu bar") {
                Toggle("Show the live count in the menu bar", isOn: $model.showCountWhileListening)
                Text("Off keeps your count private during screen shares — the "
                    + "menu bar is visible to others even when the alert pill isn't.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Recognition") {
                Toggle("Allow Apple's servers when on-device isn't available",
                       isOn: $model.allowServerRecognition)
                Text("Off means recognition is on-device only: if the offline "
                    + "model is missing, Filler Killer asks instead of sending "
                    + "audio anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("My voice") {
                Toggle("Only count my voice", isOn: $model.onlyMyVoice)
                    .disabled(model.myVoiceBand == nil)
                HStack {
                    Button(model.calibrating
                        ? "Listening…"
                        : (model.myVoiceBand == nil ? "Calibrate…" : "Recalibrate")) {
                        model.startCalibration()
                    }
                    .disabled(model.calibrating || model.state != .idle)
                    if let band = model.myVoiceBand {
                        Text("Your range: \(Int(band.lowF0))–\(Int(band.highF0)) Hz")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !model.calibrationStatus.isEmpty {
                    Text(model.calibrationStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Calibration reads your pitch for ten seconds; sessions "
                    + "then skip speech that sits outside your range. Works "
                    + "best when the other voices around you are higher or "
                    + "lower than yours — a similar-pitch voice can still be "
                    + "counted. Speaker audio is already filtered out by echo "
                    + "cancellation either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section("Privacy & data") {
                Text("Everything stays on your Mac. Recognition runs on-device; "
                    + "transcripts live in a local database you can delete below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reveal Data Folder") { model.revealDataFolder() }
                    Button("Delete All Data…", role: .destructive) {
                        confirmingDelete = true
                    }
                }
                if removedMeetings > 0 {
                    HStack {
                        Text("\(removedMeetings) removed meeting"
                            + "\(removedMeetings == 1 ? "" : "s") won't "
                            + "re-import from Granola.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Allow Re-import") {
                            model.allowRemovedMeetingsReimport()
                            removedMeetings = 0
                        }
                    }
                }
                if !dataMessage.isEmpty {
                    Text(dataMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Advanced") {
                Button("Copy Diagnostics") { model.copyDiagnostics() }
                Text(AppModel.versionLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { removedMeetings = model.removedMeetingCount() }
        .confirmationDialog(
            "Delete all Filler Killer data?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete Everything", role: .destructive) {
                dataMessage = model.deleteAllData()
                    ? "All data deleted."
                    : "Couldn't delete — see diagnostics."
            }
        } message: {
            Text("Every session, meeting, and transcript stored on this Mac "
                + "will be permanently removed. This can't be undone.")
        }
    }
}
