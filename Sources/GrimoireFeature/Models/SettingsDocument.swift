import Foundation

/// Example persisted document for the settings page. Swap it for whatever your
/// plugin actually needs to remember.
struct SettingsDocument: Codable, Equatable, Sendable {
    var showGreeting: Bool = true
}
