import AinkradAppKit
import Foundation
import SwiftUI
import Testing

@testable import GrimoireFeature

/// Smoke test: the app's root view builds from a fake host and draws in both
/// greeting states. It renders to pixels instead of inspecting the view tree,
/// so it needs no extra dependency; "differs" proves the toggle changes what
/// is on screen.
@MainActor
@Suite("Root view")
struct RootViewTests {
    @Test func rendersForBothGreetingStates() throws {
        let shown = try render(host: FakeHost())

        let hiddenDocs = MemoryDocs()
        hiddenDocs.storage[SettingsStore.key] = try JSONEncoder().encode(SettingsDocument(showGreeting: false))
        let hidden = try render(host: FakeHost(docs: hiddenDocs))

        #expect(!shown.isEmpty && !hidden.isEmpty, "the view drew nothing")
        #expect(shown != hidden, "the greeting toggle did not change what is drawn")
    }

    /// The root view's pixels at a fixed size, or an error if it cannot render.
    private func render(host: FakeHost) throws -> Data {
        let renderer = ImageRenderer(content: GrimoireApp.makeRootView(host: host).frame(width: 320, height: 240))
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "the root view did not render")
        let data = try #require(image.dataProvider?.data, "the rendered image has no pixels")
        return data as Data
    }
}
