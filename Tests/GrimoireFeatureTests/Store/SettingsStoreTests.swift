import AinkradAppKit
import Foundation
import XCTest

@testable import GrimoireFeature

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testSettingsDocumentRoundTripsThroughTheDocumentStore() {
        let docs = MemoryDocs()
        XCTAssertTrue(SettingsStore(documents: docs).showGreeting, "an empty store reads the default")

        SettingsStore(documents: docs).showGreeting = false

        XCTAssertFalse(SettingsStore(documents: docs).showGreeting, "the saved value did not survive a reload")
        let saved = try? JSONDecoder().decode(SettingsDocument.self, from: docs.storage[SettingsStore.key] ?? Data())
        XCTAssertEqual(saved, SettingsDocument(showGreeting: false))
    }

    func testUnreadableSettingsAreSetAsideNotOverwritten() {
        let docs = MemoryDocs()
        let garbage = Data("not json".utf8)
        docs.storage[SettingsStore.key] = garbage

        let settings = SettingsStore(documents: docs)
        XCTAssertTrue(settings.showGreeting, "unreadable settings fall back to the default")
        XCTAssertEqual(
            docs.storage.first { $0.key.hasPrefix("\(SettingsStore.key).corrupt-") }?.value, garbage,
            "the unreadable bytes must be kept under a .corrupt- key")

        settings.showGreeting = false
        XCTAssertNotNil(docs.storage[SettingsStore.key], "after setting aside, saving works again")
    }
}
