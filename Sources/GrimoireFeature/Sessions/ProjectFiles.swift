import Foundation

/// The files of a project, for the composer's `@` suggestions.
enum ProjectFiles {
    /// Directories never worth suggesting from.
    static let skipped: Set<String> = [
        ".git", ".build", "build", "DerivedData", "node_modules", ".swiftpm", "Pods", ".next", "dist", "vendor",
    ]

    // ponytail: one walk per project per run, capped; watch the tree (FSEvents) if suggestions go stale.
    /// Paths relative to `root`, hidden files and `skipped` directories left out.
    static func list(root: URL, limit: Int = 20_000) -> [String] {
        guard
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        let prefix = root.standardizedFileURL.path + "/"
        var files: [String] = []
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { continue }
            let path = url.standardizedFileURL.path
            files.append(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path)
            if files.count >= limit { break }
        }
        return files
    }

    /// Best matches for `query`: file names starting with it first, then names
    /// containing it, then paths containing it; shorter paths first within each.
    static func search(_ files: [String], query: String, limit: Int = 8) -> [String] {
        let query = query.lowercased()
        guard !query.isEmpty else { return Array(files.sorted { $0.count < $1.count }.prefix(limit)) }
        func rank(_ path: String) -> Int? {
            let name = (path as NSString).lastPathComponent.lowercased()
            if name.hasPrefix(query) { return 0 }
            if name.contains(query) { return 1 }
            if path.lowercased().contains(query) { return 2 }
            return nil
        }
        let ranked: [(path: String, rank: Int)] = files.compactMap { path in
            guard let rank = rank(path) else { return nil }
            return (path, rank)
        }
        let sorted = ranked.sorted { lhs, rhs in
            lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.path.count < rhs.path.count
        }
        return sorted.prefix(limit).map(\.path)
    }
}
