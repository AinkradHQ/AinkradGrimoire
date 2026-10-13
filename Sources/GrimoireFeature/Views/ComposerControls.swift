import AinkradAppKit
import SwiftUI

extension Harness {
    /// The reasoning efforts the CLI takes, in its own words; empty hides the control. Claude and agy list theirs in
    /// `--help` (`--effort`); Codex's `turn/start` takes an `effort` its models advertise; OpenCode's prompt takes a
    /// provider-specific `variant` (`opencode run --variant`).
    var efforts: [String] {
        switch self {
        case .claude, .agy: ["low", "medium", "high", "xhigh", "max"]
        case .codex: ["low", "medium", "high", "xhigh"]
        case .opencode: ["low", "medium", "high", "max"]
        }
    }
}

enum Effort {
    /// "High", "Extra high"; nil (the CLI's default) is "Default".
    static func title(_ effort: String?) -> String {
        switch effort {
        case nil: "Default"
        case "xhigh": "Extra high"
        case let effort?: effort.capitalized
        }
    }
}

/// The composer strip's "EFFORT High" (mockups 1–3): how hard the agent thinks, for this thread.
struct EffortMenu: View {
    let live: LiveThread
    let harness: Harness
    let captions: Bool

    var body: some View {
        if !harness.efforts.isEmpty {
            AinkradMenuButton(
                items: harness.efforts.map { effort in
                    AinkradMenuItem(title: Effort.title(effort), systemName: effort == live.effort ? "checkmark" : nil) {
                        live.setEffort(effort)
                    }
                }
            ) {
                PullDownLabel(showsChevron: false) {
                    MenuValue(caption: captions ? "Effort" : nil, value: Effort.title(live.effort))
                }
            }
            .fixedSize()
            .help("Effort")
        }
    }
}
