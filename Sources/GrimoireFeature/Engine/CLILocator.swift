import Foundation

/// Finds harness CLIs the way the user's terminal would. An app launched from
/// the Dock inherits launchd's minimal `PATH`, not the shell's, so
/// `~/.local/bin/claude` and `/opt/homebrew/bin/opencode` are invisible to it.
/// The login shell's environment is read once and also handed to the child, so
/// the CLI finds `node`, `git` and friends too.
enum CLILocator {
    /// The login shell's environment, falling back to this process's own when
    /// the shell cannot be run.
    static func loginEnvironment() -> [String: String] {
        let fallback = ProcessInfo.processInfo.environment
        let shell = fallback["SHELL"] ?? "/bin/zsh"
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "/usr/bin/env -0"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return fallback }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return fallback }
        let parsed = parseEnv0(data)
        return parsed["PATH"] == nil ? fallback : parsed
    }

    /// Parses `env -0` output: `KEY=value` entries separated by NUL. Values may
    /// contain `=` and newlines.
    static func parseEnv0(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            result[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return result
    }

    /// The first executable named `name` on `path` (a colon-separated list).
    static func locate(_ name: String, path: String, isExecutable: (String) -> Bool = defaultIsExecutable) -> URL? {
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = (String(directory) as NSString).appendingPathComponent(name)
            if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    static func defaultIsExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
