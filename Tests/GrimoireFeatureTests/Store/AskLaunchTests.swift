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

    @Test("GD39: Cancel keeps the edited ask and the newer one, which waits behind it and is never dropped unseen")
    func cancelKeepsBoth() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-ask-\(UUID().uuidString.prefix(8))")
        let model = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), sessionsRoot: root)
        model.handleLaunch(#"{"kind":"askAgent","path":"/p","prompt":"First"}"#)
        model.forgeAsk?.request = "First, edited"
        model.handleLaunch(#"{"kind":"askAgent","path":"/p","prompt":"Second"}"#)
        model.keepEditingAsk()  // the confirm's Cancel
        #expect(model.forgeAsk?.request == "First, edited")
        #expect(model.queuedForgeAsks.map(\.prompt) == ["Second"])

        // "1 more request from Forge": the edited ask asks first; Cancel puts the newer one back in line.
        model.showNextForgeAsk()
        #expect(model.forgeAsk?.prompt == "Second")
        #expect(model.setAsideForgeAsk?.request == "First, edited")
        model.keepEditingAsk()
        #expect(model.forgeAsk?.request == "First, edited")
        #expect(model.queuedForgeAsks.map(\.prompt) == ["Second"])

        // Done with this one (sent or discarded): the next comes up.
        model.forgeAsk = nil
        model.showQueuedAsk(model.queuedForgeAsks)
        #expect(model.forgeAsk?.prompt == "Second")
        #expect(model.queuedForgeAsks.isEmpty && model.selectedThreadID == nil)

        // An unedited ask switched away from waits in line too.
        model.handleLaunch(#"{"kind":"askAgent","path":"/p","prompt":"Third"}"#)
        #expect(model.forgeAsk?.prompt == "Third")
        model.queuedForgeAsks = [ForgeAsk(project: "/p", prompt: "Fourth")]
        model.showNextForgeAsk()
        #expect(model.forgeAsk?.prompt == "Fourth")
        #expect(model.queuedForgeAsks.map(\.prompt) == ["Third"])

        // Opening a thread lets unedited asks go, as it always has (GD31).
        model.selectedThreadID = "s1"
        #expect(model.forgeAsk == nil && model.queuedForgeAsks.isEmpty)
    }
}
