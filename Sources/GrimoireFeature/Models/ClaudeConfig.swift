import Foundation

/// What Claude Code's own files configure (mockup 8's "4 servers · 2 hooks · 14 skills"), read from the CLI's home —
/// `~/.claude` and `~/.claude.json` — never by running the CLI.
struct ClaudeConfig: Equatable {
    var servers = 0
    var hooks = 0
    var skills = 0
    /// `~/.claude.json` names a signed-in account.
    var isSignedIn = false
    /// The account's plan ("Max", "Pro", "Team"), from its `organizationType` (`claude_max`); nil when unknown.
    var plan: String?

    /// `claudeHome` is `~/.claude` (its parent holds `.claude.json`). Missing or unreadable files count as none.
    static func read(claudeHome: URL) -> ClaudeConfig {
        var config = ClaudeConfig()
        let fm = FileManager.default
        if let settings = json(claudeHome.appendingPathComponent("settings.json")),
            let hooks = settings["hooks"] as? [String: Any]
        {
            // `hooks: { Event: [ { matcher, hooks: [ … ] } ] }` — every command counts.
            config.hooks = hooks.values.reduce(0) { total, matchers in
                total + ((matchers as? [[String: Any]]) ?? []).reduce(0) { $0 + (($1["hooks"] as? [Any])?.count ?? 0) }
            }
        }
        if let state = json(claudeHome.deletingLastPathComponent().appendingPathComponent(".claude.json")) {
            config.servers = (state["mcpServers"] as? [String: Any])?.count ?? 0
            let account = state["oauthAccount"] as? [String: Any]
            config.isSignedIn = account != nil
            config.plan = (account?["organizationType"] as? String).flatMap(plan)
        }
        let skills = (try? fm.contentsOfDirectory(atPath: claudeHome.appendingPathComponent("skills").path)) ?? []
        config.skills = skills.filter { !$0.hasPrefix(".") }.count
        return config
    }

    /// "4 servers · 2 hooks · 14 skills".
    var summary: String {
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        return [count(servers, "server"), count(hooks, "hook"), count(skills, "skill")].joined(separator: " · ")
    }

    /// `claude_max` → "Max"; anything not shaped `claude_<plan>` is unknown.
    static func plan(_ organizationType: String) -> String? {
        guard organizationType.hasPrefix("claude_"), organizationType.count > 7 else { return nil }
        return organizationType.dropFirst(7).capitalized
    }

    private static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
