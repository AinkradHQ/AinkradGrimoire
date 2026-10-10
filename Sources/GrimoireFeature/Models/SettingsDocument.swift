import Foundation

/// What Grimoire remembers between launches. Every field decodes with a
/// default, so a document written by an older build still loads.
struct SettingsDocument: Codable, Equatable, Sendable {
    /// Folders added with "Open folder…". Projects with sessions are found on
    /// their own; these keep a folder listed before it has any.
    var openedFolders: [String] = []
    /// Projects whose threads are shown. `nil` until the user first toggles
    /// one: then the most recent project starts expanded.
    var expandedProjects: [String]?
    /// A `claude` binary chosen in Settings, instead of the one on the PATH.
    var cliPathOverride: String?
    /// New-thread defaults.
    var defaultModel = "opus"
    var defaultMode = PermissionMode.ask.rawValue
    var worktreeByDefault = false
    /// Post a Signal when a thread you aren't looking at waits on an approval.
    var notifyWhenNeeded = true

    init(openedFolders: [String] = [], expandedProjects: [String]? = nil) {
        self.openedFolders = openedFolders
        self.expandedProjects = expandedProjects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SettingsDocument()
        openedFolders = try container.decodeIfPresent([String].self, forKey: .openedFolders) ?? []
        expandedProjects = try container.decodeIfPresent([String].self, forKey: .expandedProjects)
        cliPathOverride = try container.decodeIfPresent(String.self, forKey: .cliPathOverride)
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? defaults.defaultModel
        defaultMode = try container.decodeIfPresent(String.self, forKey: .defaultMode) ?? defaults.defaultMode
        worktreeByDefault = try container.decodeIfPresent(Bool.self, forKey: .worktreeByDefault) ?? false
        notifyWhenNeeded = try container.decodeIfPresent(Bool.self, forKey: .notifyWhenNeeded) ?? true
    }
}
