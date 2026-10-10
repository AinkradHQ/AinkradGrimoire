import AinkradAppKit
import Foundation
import Observation

/// Small `Codable` state through the host's key→data store — see
/// `HostServices.documents`. Observable, so a view that reads it re-renders the
/// moment the settings page changes it. Setting `showGreeting` is the store's
/// one action: it updates the value and persists it.
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

    /// Whether the root view shows its greeting.
    var showGreeting: Bool {
        get { document.showGreeting }
        set {
            document.showGreeting = newValue
            save()
        }
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
