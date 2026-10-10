import AinkradAppKit
import Foundation
import Observation

/// Small `Codable` state through the host's key→data store — see
/// `HostServices.documents`. Observable, so views re-render when it changes;
/// every mutation persists.
@MainActor
@Observable
final class SettingsStore {
    static let key = "settings"

    private let documents: PluginDocumentStore
    private var document: SettingsDocument
    /// False only when unreadable settings could not be set aside — then no
    /// save may overwrite the user's only copy (see `loadDocument`).
    private let canSave: Bool

    /// Reads the saved document and nothing else; no work starts here.
    init(documents: PluginDocumentStore) {
        self.documents = documents
        let loaded = loadDocument(SettingsDocument.self, key: Self.key, from: documents)
        self.document = loaded.value ?? SettingsDocument()
        self.canSave = loaded.canSave
    }

    var openedFolders: [String] { document.openedFolders }

    func addFolder(_ path: String) {
        guard !document.openedFolders.contains(path) else { return }
        document.openedFolders.append(path)
        save()
    }

    /// Whether `project` shows its threads. Before the user has toggled any,
    /// only `mostRecent` is expanded.
    func isExpanded(_ project: String, mostRecent: String?) -> Bool {
        document.expandedProjects?.contains(project) ?? (project == mostRecent)
    }

    func toggle(_ project: String, mostRecent: String?) {
        var expanded = document.expandedProjects ?? mostRecent.map { [$0] } ?? []
        if let index = expanded.firstIndex(of: project) {
            expanded.remove(at: index)
        } else {
            expanded.append(project)
        }
        document.expandedProjects = expanded
        save()
    }

    private func save() {
        guard canSave else { return }
        do {
            documents.setData(try JSONEncoder().encode(document), forKey: Self.key)
        } catch {
            Log.persistence.error("settings were not saved: \(error)")
        }
    }
}
