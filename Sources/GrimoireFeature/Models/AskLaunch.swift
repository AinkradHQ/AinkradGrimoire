import Foundation

/// Another app asking Grimoire to start a thread: Forge's Ask Agent sends the project folder and the request
/// (the place, the code, the words). Its own payload kind on the launcher's opaque string — like Rune's
/// launches — so apps that read only `AinkradLaunchIntent` ignore it.
struct AskLaunch: Codable, Equatable {
    static let kind = "askAgent"

    let kind: String
    /// The project folder.
    let path: String
    let prompt: String

    /// The payload, when it is one of these (anything else is not ours, and is not an error).
    static func decode(_ payload: String?) -> AskLaunch? {
        guard let data = payload?.data(using: .utf8), let launch = try? JSONDecoder().decode(AskLaunch.self, from: data),
            launch.kind == kind
        else { return nil }
        return launch
    }
}

/// What the New Thread sheet starts with when another app asked.
struct NewThreadPreset: Equatable {
    let project: String
    let prompt: String
}
