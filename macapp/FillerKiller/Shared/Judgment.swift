// Single source of truth for rate judgment colors. Rule from the design
// system: accent is identity/interactivity only — these three colors are the
// ONLY things that judge, and every surface (HUD, popover, Trends) agrees.

import SwiftUI

func judgment(rate: Double, target: Double) -> Color {
    if rate <= target { return .green }
    if rate <= target * 1.5 { return .orange }
    return .red
}
