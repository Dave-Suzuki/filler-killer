// Granola connect: paste a grn_ API key, validate against the live API, store
// in the Keychain. Per the product spec, explains the workspace-admin gate.

import SwiftUI

struct GranolaConnectView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.granolaConnected {
                Text("Granola is connected.").font(.headline)
                Text("Meetings sync in the background on launch and every 6 hours.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Sync Now") { model.syncGranolaNow() }
                    Button("Disconnect", role: .destructive) { model.disconnectGranola() }
                }
            } else {
                Text("Analyze months of past meetings").font(.headline)
                Text("In Granola: Settings → API keys → create a key, then paste it "
                    + "here. Don't see API keys? On some workspace plans an admin must "
                    + "enable personal API keys first — Filler Killer works fully "
                    + "without it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("grn_…", text: $key)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(busy ? "Validating…" : "Validate & Connect") {
                        busy = true
                        message = ""
                        Task {
                            if let error = await model.connectGranola(key: key) {
                                message = error
                            } else {
                                message = "Connected — first sync is running."
                            }
                            busy = false
                        }
                    }
                    .disabled(busy || key.isEmpty)
                    Button("Cancel") { dismiss() }
                }
            }
            if !message.isEmpty {
                Text(message).font(.callout)
                    .foregroundStyle(message.hasPrefix("Connected") ? .green : .red)
            }
            if !model.granolaStatus.isEmpty {
                Text(model.granolaStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 400)
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
