// Floating HUD: a small always-on-top pill that flashes when a finalized
// segment contains fillers, per the product spec:
//   - non-activating (never steals focus), click-through
//   - one flash per SEGMENT batch; a batch arriving while visible updates the
//     pill in place and resets the hold (coalesce, never queue)
//   - hold 1.8s (2.6s for 3+ hits); fade 120ms in / 400ms out
//   - sharingType = .none hides it from ScreenCaptureKit-based screen shares
//     (Zoom/Meet/Teams); not from HDMI/AirPlay mirroring
//   - green "clean run" variant for positive reinforcement

import AppKit
import SwiftUI

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUDContentModel: ObservableObject {
    @Published var headline = ""
    @Published var detail = ""
    @Published var isCleanRun = false
    @Published var rateColor: Color = .secondary
}

@MainActor
final class HUDController {
    private var panel: HUDPanel?
    private let model = HUDContentModel()
    private var hideWorkItem: DispatchWorkItem?

    func flashFillers(terms: [String], sessionCount: Int, rate: Double, target: Double) {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for term in terms {
            if counts[term] == nil { order.append(term) }
            counts[term, default: 0] += 1
        }
        let headline = order.map { term in
            let n = counts[term] ?? 1
            return n > 1 ? "“\(term)” ×\(n)" : "“\(term)”"
        }.joined(separator: " · ")

        model.isCleanRun = false
        model.headline = headline
        model.detail = "\(sessionCount) this session · "
            + String(format: "%.1f", rate) + "/100w"
        model.rateColor = rate <= target ? .green : (rate <= target * 1.5 ? .orange : .red)
        show(holdFor: terms.count >= 3 ? 2.6 : 1.8)
    }

    func flashCleanRun(words: Int) {
        model.isCleanRun = true
        model.headline = "✓ \(words) clean words"
        model.detail = "keep going"
        model.rateColor = .green
        show(holdFor: 1.2)
    }

    func hideNow() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    // MARK: - Internals

    private func show(holdFor hold: TimeInterval) {
        let panel = ensurePanel()
        layout(panel)
        hideWorkItem?.cancel()

        if panel.isVisible {
            panel.alphaValue = 1 // update in place, reset the hold
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.4
                panel.animator().alphaValue = 0
            }, completionHandler: {
                if panel.alphaValue == 0 {
                    panel.orderOut(nil)
                }
            })
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: workItem)
    }

    private func ensurePanel() -> HUDPanel {
        if let panel { return panel }
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none // invisible to software screen capture
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        self.panel = panel
        return panel
    }

    private func layout(_ panel: HUDPanel) {
        guard let screen = NSScreen.main else { return }
        panel.contentView?.layout()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 64)
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 12
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDContentModel

    var body: some View {
        VStack(spacing: 2) {
            Text(model.headline)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(model.isCleanRun ? Color.green : Color.primary)
            Text(model.detail)
                .font(.system(size: 11))
                .foregroundStyle(model.rateColor)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                model.isCleanRun ? Color.green.opacity(0.5) : Color.primary.opacity(0.1),
                lineWidth: 1
            )
        )
        .padding(6)
        .fixedSize()
    }
}
