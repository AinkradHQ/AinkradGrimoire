import Foundation

/// Runs `git` (and `gh`) in a working tree, with the login shell's environment.
struct Git: Sendable {
    let directory: String
    let environment: [String: String]

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Paths come back as they are, not C-quoted octal (GD37): non-ASCII names list, commit and open as themselves.
    func run(_ arguments: [String]) async throws -> String {
        try await exec(["git", "-c", "core.quotePath=false"] + arguments)
    }
    func gh(_ arguments: [String]) async throws -> String { try await exec(["gh"] + arguments) }

    /// stdout on exit 0; otherwise throws with stderr (or stdout) as the message.
    private func exec(_ command: [String]) async throws -> String {
        let directory = directory
        let environment = environment
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let out = Pipe()
            let err = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.environment = environment.isEmpty ? nil : environment
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try process.run()
            // Read before waiting: a full pipe would block the child forever.
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: output, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errors, as: UTF8.self)
                throw Failure(
                    message: (message.isEmpty ? text : message).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return text
        }.value
    }
}
