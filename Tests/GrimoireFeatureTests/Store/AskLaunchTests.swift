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
}
