import AinkradAppKit
import Foundation
import SwiftUI

/// In-memory `PluginDocumentStore`, standing in for the host's.
final class MemoryDocs: PluginDocumentStore {
    var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func setData(_ data: Data?, forKey key: String) { storage[key] = data }
}

/// The smallest `HostServices` that lets `GrimoireApp.makeRootView(host:)` run: real
/// in-memory documents and a fixed theme, no-op everything else. Each fake has
/// its own `instanceID`, so two fakes never share a store.
@MainActor
struct FakeHost: HostServices, PluginInstanceIdentity {
    let docs: MemoryDocs
    let instanceID = PluginInstanceID()

    init(docs: MemoryDocs = MemoryDocs()) { self.docs = docs }

    var documents: PluginDocumentStore { docs }
    var secrets: PluginSecretStore { NoSecrets() }
    var theme: HostTheme {
        HostTheme(
            .init(
                themeID: "test", background: .black, surface: .black, surfaceElevated: .black,
                accentPrimary: .white, accentSecondary: .white, accentTertiary: .white, foreground: .white))
    }
    var log: PluginLogger { NoLog() }
    var context: PluginContextRegistry { NoContext() }
    var actions: AgentActionProvider { NoActions() }
    var apps: PluginAppLauncher { NoLauncher() }
    var presentation: PluginPresentationControl { NoPresentation() }
    var overlaySize: PluginOverlaySizeControl { NoOverlaySize() }
    var mode: PluginModeControl { NoMode() }
    var signals: PluginSignalEmitter { NoopSignalEmitter() }
}

private struct NoSecrets: PluginSecretStore {
    func secret(forKey key: String) -> String? { nil }
    func setSecret(_ value: String?, forKey key: String) {}
}
private struct NoLog: PluginLogger {
    func info(_ message: String) {}
    func error(_ message: String) {}
}
@MainActor private struct NoContext: PluginContextRegistry {
    func register(_ source: @escaping @MainActor () -> AgentContextSnapshot?) -> PluginContextToken {
        PluginContextToken(id: UUID())
    }
    func remove(_ token: PluginContextToken) {}
}
@MainActor private struct NoActions: AgentActionProvider {
    func register(
        actionID: String, handler: @escaping @MainActor (String) async -> AgentActionResult
    ) -> AgentActionToken {
        AgentActionToken(id: UUID())
    }
    func remove(_ token: AgentActionToken) {}
}
@MainActor private struct NoLauncher: PluginAppLauncher {
    func open(appID: String, payload: String?) {}
    func takePendingLaunch() -> String? { nil }
}
@MainActor private struct NoPresentation: PluginPresentationControl {
    var current: PluginPresentation { .pane }
    func set(_ presentation: PluginPresentation) {}
    func reset() {}
}
@MainActor private struct NoMode: PluginModeControl {
    var current: PluginMode { .advanced }
    func set(_ mode: PluginMode) {}
    func reset() {}
}
@MainActor private struct NoOverlaySize: PluginOverlaySizeControl {
    var current: PluginOverlaySize { .medium }
    func set(_ size: PluginOverlaySize) {}
    func reset() {}
}
