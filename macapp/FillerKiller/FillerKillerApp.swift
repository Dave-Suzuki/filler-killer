// Filler Killer — macOS menu bar app (M0 skeleton).
// Proves the build/distribute loop: shows "FK —" in the menu bar and can
// run the ported detector on demand from the debug menu item.

import DetectorKit
import SwiftUI

@main
struct FillerKillerApp: App {
    @State private var selfTest = selfTestResult()

    var body: some Scene {
        MenuBarExtra {
            Text("Filler Killer — skeleton build")
            Text(selfTest)
                .font(.caption)
            Divider()
            Button("Quit Filler Killer") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Text("FK —")
        }
    }
}

/// Quick in-app proof that DetectorKit is linked and behaving: analyze the
/// onboarding aha sentence and report the hit count.
private func selfTestResult() -> String {
    let hits = analyzeText("Um, so I think, you know, this could actually work.")
    let terms = hits.map { $0.term }.joined(separator: ", ")
    return "detector self-test: \(hits.count) hits (\(terms))"
}
