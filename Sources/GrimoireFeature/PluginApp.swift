import AinkradAppKit
import SwiftUI

/// Grimoire: a native GUI for CLI coding harnesses. Read theme via
/// `host.theme.tokens` and persist via `host.documents` — never host internals.
public struct GrimoireApp: AinkradApp, AinkradAppTeardown {
    public static let id = "grimoire"
    public static let displayName = "Grimoire"
    public static let icon = "book.closed"

    /// One settings store and one window model per host-minted instance, so
    /// every open window of that instance shares them and `teardown` drops them.
    private static let stores = PluginInstanceStorage<SettingsStore>()
    private static let models = PluginInstanceStorage<GrimoireModel>()

    /// The instance a host stands for. A host that does not identify itself
    /// (see `PluginInstanceIdentity`) gets one id minted per process.
    private static let fallbackInstance = PluginInstanceID()

    private static func instance(of host: HostServices) -> PluginInstanceID {
        (host as? PluginInstanceIdentity)?.instanceID ?? fallbackInstance
    }

    private static func model(host: HostServices) -> GrimoireModel {
        models.value(for: instance(of: host)) {
            GrimoireModel(
                settings: stores.value(for: instance(of: host)) { SettingsStore(documents: host.documents) },
                signals: host.signals)
        }
    }

    public static func teardown(instance: PluginInstanceID) {
        models.remove(instance)
        stores.remove(instance)
    }

    public static func makeRootView(host: HostServices) -> AnyView {
        AnyView(RootView(model: model(host: host), theme: host.theme))
    }

    /// Grimoire reads the CLIs' own settings; its own page arrives with the settings screen.
    public static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(AinkradCaption("Grimoire uses each agent's own settings files."))
    }
}
