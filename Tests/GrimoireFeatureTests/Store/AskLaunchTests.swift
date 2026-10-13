import AinkradAppKit
import Foundation
import Testing

@testable import GrimoireFeature

/// Forge's Ask Agent: its payload opens a new thread inline on the project with the request.
@MainActor
@Suite("Ask launch")
struct AskLaunchTests {
    @Test func anAskOpensANewThreadOnItsProjectWithTheRequest() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-ask-\(UUID().uuidString.prefix(8))")
        let model = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), sessionsRoot: root)
        model.handleLaunch(#"{"kind":"askAgent","path":"/Users/me/Projects/Ainkrad","prompt":"In a.swift, line 3:\n\nMake it faster."}"#)
        #expect(!model.isComposingNewThread)
        #expect(model.forgeAsk == ForgeAsk(project: "/Users/me/Projects/Ainkrad", prompt: "In a.swift, line 3:\n\nMake it faster."))
        #expect(model.settings.openedFolders.contains("/Users/me/Projects/Ainkrad"))
    }

    @Test func otherPayloadsAreNotOurs() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-ask-\(UUID().uuidString.prefix(8))")
        let model = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), sessionsRoot: root)
        model.handleLaunch(AinkradLaunchIntent(kind: "openDirectory", path: "/tmp").json)
        model.handleLaunch("not json")
        model.handleLaunch(nil)
        #expect(!model.isComposingNewThread)
        #expect(model.forgeAsk == nil)
    }

    @Test("GD31: an edited ask is set aside for a confirm, not dropped, when a thread opens or a newer ask arrives")
    func editedAskAsksFirst() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-ask-\(UUID().uuidString.prefix(8))")
        let model = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), sessionsRoot: root)
        let first = #"{"kind":"askAgent","path":"/p","prompt":"Explain this"}"#
        // Unedited: opening a thread just leaves it, as before.
        model.handleLaunch(first)
        model.selectedThreadID = "s1"
        #expect(model.forgeAsk == nil && model.setAsideForgeAsk == nil)

        // Edited, then a thread opens: it waits for the confirm; Cancel brings it back with the edits.
        model.handleLaunch(first)
        model.forgeAsk?.request = "Explain this, briefly"
        model.forgeAsk?.mode = .plan
        #expect(model.forgeAsk?.isEdited == true)
        model.selectedThreadID = "s2"
        #expect(model.forgeAsk == nil)
        #expect(model.setAsideForgeAsk?.request == "Explain this, briefly")
        model.keepEditingAsk()
        #expect(model.selectedThreadID == nil && model.setAsideForgeAsk == nil)
        #expect(model.forgeAsk?.request == "Explain this, briefly")
        #expect(model.forgeAsk?.mode == .plan)

        // A newer ⌘I replaces it on screen, the edited one waits; Discard drops it.
        model.handleLaunch(#"{"kind":"askAgent","path":"/p","prompt":"Second"}"#)
        #expect(model.forgeAsk?.prompt == "Second")
        #expect(model.setAsideForgeAsk?.request == "Explain this, briefly")
        model.setAsideForgeAsk = nil  // the confirm's Discard
        model.keepEditingAsk()  // the dialog closing afterwards changes nothing
        #expect(model.forgeAsk?.prompt == "Second")
    }
}

