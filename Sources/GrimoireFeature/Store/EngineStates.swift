import Foundation

/// One line of the startup list shown while an engine comes up (E6 B).
struct StartupStep: Equatable {
    var title: String
    /// The mono part of the line: the CLI and version, or the branch.
    var code: String?
    var done: Bool

    /// Found the CLI → loaded the history → starting (the current step).
    static func steps(
        harness: Harness, cli: CLIStatus, loadedMessages: Int, location: String
    ) -> [StartupStep] {
        var steps: [StartupStep] = []
        if case .found(_, let version) = cli {
            steps.append(StartupStep(title: "Found", code: version.isEmpty ? harness.command : "\(harness.command) \(version)", done: true))
        }
        if loadedMessages > 0 {
            steps.append(
                StartupStep(
                    title: "Loaded \(loadedMessages) message\(loadedMessages == 1 ? "" : "s") from the session", code: nil,
                    done: true))
        }
        steps.append(StartupStep(title: "Starting \(harness.displayName) in", code: location, done: false))
        return steps
    }
}

/// Why an engine stopped, as the in-transcript failure card shows it (E6 C).
struct EngineFailure: Equatable {
    enum Kind: Equatable {
        /// Not logged in, or a bad key: the fix is logging in in a terminal.
        case auth
        case usageLimit
        case other
    }

    /// The CLI's exit code; `nil` when it never ran or is still running.
    var code: Int32?
    /// How long it ran before it stopped.
    var after: TimeInterval
    /// The last stderr lines, or the error the CLI reported.
    var output: String
    /// It stopped before it ever answered the startup handshake.
    var beforeStart: Bool
    /// The unanswered message went back to the composer.
    var restoredDraft: Bool = false

    var kind: Kind { Self.classify(output) }

    static func classify(_ text: String) -> Kind {
        let text = text.lowercased()
        let limit = ["usage limit", "hit your limit", "hit your session limit", "usagelimitexceeded"]
        if limit.contains(where: text.contains) { return .usageLimit }
        let auth = [
            "api key", "/login", "not logged in", "log in", "login", "authenticat", "unauthorized", "credentials",
            "oauth",
        ]
        return auth.contains(where: text.contains) ? .auth : .other
    }

    /// The card's one plain sentence.
    func headline(_ harness: Harness) -> String {
        if beforeStart { return "\(harness.displayName) stopped before it could start" }
        return code == nil ? "\(harness.displayName) couldn't answer" : "\(harness.displayName) stopped unexpectedly"
    }

    func detail() -> String {
        var parts: [String] = []
        if let code { parts.append("The CLI exited with code \(code) after \(String(format: "%.1f", after)) s.") }
        parts.append(
            restoredDraft
                ? "Nothing in this thread was lost; your last message is still in the composer."
                : "Nothing in this thread was lost.")
        return parts.joined(separator: " ")
    }

    /// What Copy details puts on the pasteboard.
    func details(_ harness: Harness) -> String {
        headline(harness) + "\n" + detail() + "\n\n" + output
    }

    /// Where a person logs `harness` in, for the fix-it's tooltip.
    static func loginHint(_ harness: Harness) -> String {
        switch harness {
        case .claude: "Opens a terminal here (Rune) — run `claude`, then /login"
        case .codex: "Opens a terminal here (Rune) — run `codex login`"
        case .opencode: "Opens a terminal here (Rune) — run `opencode auth login`"
        case .agy: "Opens a terminal here (Rune) — run `agy` to sign in"
        }
    }
}

/// An agent that can't answer until a usage window resets (E6 D), read from
/// the windows the engines report (`UsageWindow`).
struct UsageLimit: Equatable {
    var harness: Harness
    var resetsAt: Date?
    /// "5-hour", "7-day", …
    var window: String?
    var utilization: Double

    /// The window that is used up and resets last — the one that decides when
    /// the agent can answer again. A used-up window whose reset has passed no
    /// longer counts.
    static func current(_ harness: Harness, windows: [UsageWindow], now: Date) -> UsageLimit? {
        let full = windows.filter { $0.utilization >= 0.999 && ($0.resetsAt.map { $0 > now } ?? true) }
        guard let window = full.max(by: { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) })
        else { return nil }
        return UsageLimit(
            harness: harness, resetsAt: window.resetsAt, window: window.name == "Usage" ? nil : window.name,
            utilization: window.utilization)
    }

    /// The windows after a turn failed on the limit: the busiest still-open window
    /// is marked used up, or — when none was reported — one window resetting at
    /// `hint` (parsed from the CLI's message) is.
    static func exhausting(_ windows: [UsageWindow], resetHint hint: Date?, now: Date) -> [UsageWindow] {
        let open = windows.indices.filter { windows[$0].resetsAt.map { $0 > now } ?? true }
        guard let busiest = open.max(by: { windows[$0].utilization < windows[$1].utilization }) else {
            return windows + [UsageWindow(name: "Usage", utilization: 1, resetsAt: hint)]
        }
        var windows = windows
        windows[busiest].utilization = 1
        if windows[busiest].resetsAt == nil { windows[busiest].resetsAt = hint }
        return windows
    }

    /// `Claude AI usage limit reached|1791700000` carries its reset as epoch seconds.
    static func resetHint(in message: String) -> Date? {
        guard let bar = message.lastIndex(of: "|"),
            let seconds = TimeInterval(message[message.index(after: bar)...].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Another installed agent that isn't limited for a carried-over thread: Codex
    /// first (the approved default), then the rest in the sidebar's order.
    static func alternative(
        to harness: Harness, statuses: [Harness: CLIStatus], limited: Set<Harness>
    ) -> Harness? {
        ([.codex] + Harness.allCases).first { candidate in
            guard candidate != harness, !limited.contains(candidate), case .found = statuses[candidate] else {
                return false
            }
            return true
        }
    }

    /// "in 1 h 12 min", "in 4 min", "now".
    static func countdown(to date: Date, now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return "now" }
        return minutes < 60 ? "in \(minutes) min" : "in \(minutes / 60) h \(minutes % 60) min"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
