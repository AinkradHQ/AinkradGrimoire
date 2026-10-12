import Foundation

/// Walking the sidebar from the keyboard (⌘⇧] / ⌘⇧[).
extension GrimoireModel {
    /// Whether the sidebar lists `project`'s threads: always while searching, else as it was left.
    func isExpanded(_ project: ClaudeProject) -> Bool {
        !searchText.isEmpty || settings.isExpanded(project.path, mostRecent: mostRecentProject)
    }

    /// Selects the thread `offset` rows from the selected one, as the sidebar lists them.
    func selectAdjacentThread(_ offset: Int) {
        if let id = Self.adjacentThread(offset, from: selectedThreadID, in: visibleProjects, isExpanded: isExpanded) {
            selectedThreadID = id
        }
    }

    /// The thread `offset` rows from `selected` among those `projects` show — a collapsed project's are
    /// skipped — clamped at both ends. With no listed selection, next is the first thread and previous the last.
    static func adjacentThread(
        _ offset: Int, from selected: String?, in projects: [ClaudeProject], isExpanded: (ClaudeProject) -> Bool
    ) -> String? {
        let ids = projects.filter(isExpanded).flatMap { $0.sessions.map(\.id) }
        guard let index = selected.flatMap(ids.firstIndex(of:)) else { return offset > 0 ? ids.first : ids.last }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }
}
