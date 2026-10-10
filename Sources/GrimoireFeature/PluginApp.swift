import AinkradAppKit
import SwiftUI

/// Grimoire: a native GUI for CLI coding harnesses. Read theme via
/// `host.theme.tokens` and persist via `host.documents` — never host internals.
public struct GrimoireApp: AinkradApp, AinkradAppTeardown {
    public static let id = "grimoire"
    public static let displayName = "Grimoire"
    public static let icon = "book.closed"

    /// One store per host-minted instance, so the settings page and every open
    /// window of that instance observe the same value, and `teardown` can drop it.
    private static let stores = PluginInstanceStorage<SettingsStore>()

    /// The instance a host stands for. A host that does not identify itself
    /// (see `PluginInstanceIdentity`) gets one id minted per process.
    private static let fallbackInstance = PluginInstanceID()

    private static func store(host: HostServices) -> SettingsStore {
        let instance = (host as? PluginInstanceIdentity)?.instanceID ?? fallbackInstance
        return stores.value(for: instance) { SettingsStore(documents: host.documents) }
    }

    public static func teardown(instance: PluginInstanceID) {
        stores.remove(instance)
    }

    public static func makeRootView(host: HostServices) -> AnyView {
        AnyView(RootView(store: store(host: host), theme: host.theme))
    }

    public static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(AinkradCaption("Your own settings view goes here."))
    }

    /// Worked example of the additive settings contract: declare the fields
    /// you can as real descriptors (searchable, deep-linkable, laid out with
    /// every other setting), and leave anything bespoke as a single
    /// `.custom` field wrapping your own view. Returning `nil` here (the
    /// protocol default) is also valid — it just falls back to rendering
    /// `makeSettingsView(host:)` as-is, searchable by app name only.
    public static func settingsCatalog(host: HostServices) -> SettingsPage? {
        let root = SettingsPath(["app", id])
        let general = root.appending("general")
        let settings = store(host: host)

        return SettingsPage(
            path: root, title: displayName, icon: icon,
            group: .installedApps, order: 0,
            groups: [
                SettingsGroup(
                    path: general, title: "General",
                    fields: [
                        // A real, declared field: shows up in search and gets
                        // the shared toggle UI for free.
                        SettingsField(
                            path: general.appending("greeting"),
                            label: "Show greeting",
                            help: "Show the \"Hello from Grimoire\" banner.",
                            keywords: ["greeting", "hello", "banner"],
                            kind: .toggle(
                                Binding(
                                    get: { settings.showGreeting },
                                    set: { settings.showGreeting = $0 })),
                            defaultDescription: "On",
                            isModified: { settings.showGreeting != true },
                            reset: { settings.showGreeting = true }),
                        // The escape hatch: anything that isn't a toggle/select/
                        // slider/text field can still be indexed and found by
                        // wrapping your existing view in `.custom`.
                        SettingsField(
                            path: general.appending("advanced"),
                            label: "Advanced",
                            help: "The plugin's own settings pane.",
                            keywords: ["advanced", "custom"],
                            kind: .custom(makeSettingsView(host: host))),
                    ])
            ],
            appID: id)
    }
}
