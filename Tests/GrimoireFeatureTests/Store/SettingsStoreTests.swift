import AinkradAppKit
import Foundation
import XCTest

@testable import GrimoireFeature

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testOpenedFoldersSurviveAReloadWithoutDuplicates() {
        let docs = MemoryDocs()
        XCTAssertEqual(SettingsStore(documents: docs).openedFolders, [], "an empty store reads the default")

        let store = SettingsStore(documents: docs)
        store.addFolder("/work/a")
        store.addFolder("/work/a")

        XCTAssertEqual(SettingsStore(documents: docs).openedFolders, ["/work/a"])
    }

    func testOnlyTheMostRecentProjectStartsExpandedUntilTheUserToggles() {
        let docs = MemoryDocs()
        let store = SettingsStore(documents: docs)
        XCTAssertTrue(store.isExpanded("/a", mostRecent: "/a"))
        XCTAssertFalse(store.isExpanded("/b", mostRecent: "/a"))

        store.toggle("/b", mostRecent: "/a")
        let reloaded = SettingsStore(documents: docs)
        XCTAssertTrue(reloaded.isExpanded("/a", mostRecent: "/a"), "the default stays expanded after the first toggle")
        XCTAssertTrue(reloaded.isExpanded("/b", mostRecent: "/a"))

        reloaded.toggle("/a", mostRecent: "/a")
        XCTAssertFalse(SettingsStore(documents: docs).isExpanded("/a", mostRecent: "/a"))
    }

    func testAnOlderDocumentStillLoads() {
        let docs = MemoryDocs()
        docs.storage[SettingsStore.key] = Data(#"{"showGreeting":false}"#.utf8)
        XCTAssertEqual(SettingsStore(documents: docs).openedFolders, [])
        XCTAssertNil(docs.storage.keys.first { $0.contains(".corrupt-") }, "a known-but-old document is not corrupt")
    }

    func testUnreadableSettingsAreSetAsideNotOverwritten() {
        let docs = MemoryDocs()
        let garbage = Data("not json".utf8)
        docs.storage[SettingsStore.key] = garbage

        let settings = SettingsStore(documents: docs)
        XCTAssertEqual(settings.openedFolders, [], "unreadable settings fall back to the default")
        XCTAssertEqual(
            docs.storage.first { $0.key.hasPrefix("\(SettingsStore.key).corrupt-") }?.value, garbage,
            "the unreadable bytes must be kept under a .corrupt- key")

        settings.addFolder("/x")
        XCTAssertNotNil(docs.storage[SettingsStore.key], "after setting aside, saving works again")
    }
}
