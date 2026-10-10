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

    init(openedFolders: [String] = [], expandedProjects: [String]? = nil) {
        self.openedFolders = openedFolders
        self.expandedProjects = expandedProjects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        openedFolders = try container.decodeIfPresent([String].self, forKey: .openedFolders) ?? []
        expandedProjects = try container.decodeIfPresent([String].self, forKey: .expandedProjects)
    }
}
