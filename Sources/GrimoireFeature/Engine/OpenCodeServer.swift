import AppKit
import Foundation

/// One `opencode serve` for the whole app, started on first use and stopped
/// when the app quits. Every OpenCode thread and the session listing talk to
/// it over HTTP, naming the project with `?directory=`.
// ponytail: unsecured on 127.0.0.1 like OpenCode's own default; set OPENCODE_SERVER_PASSWORD if that matters.
final class OpenCodeServer: @unchecked Sendable {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case didNotStart(String)
        case http(Int, String)

        var description: String {
            switch self {
            case .didNotStart(let output): "opencode serve did not start: \(output)"
            case .http(let code, let body): "OpenCode answered \(code): \(body)"
            }
        }
    }

    private let executable: URL
    private let environment: [String: String]
    private let lock = NSLock()
    private var process: Process?
    private var base: URL?
    private var quit: NSObjectProtocol?

    init(executable: URL, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    /// The server's address, starting it the first time (blocks until it listens).
    func url() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        if let base, process?.isRunning == true { return base }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["serve", "--port", "0", "--hostname", "127.0.0.1"]
        process.environment = environment.isEmpty ? nil : environment
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let listening = DispatchSemaphore(value: 0)
        let printed = Printed()
        // Keeps draining after the address shows, so a full pipe never stalls the server.
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                listening.signal()
                return
            }
            if printed.append(data) { listening.signal() }
        }
        try process.run()
        _ = listening.wait(timeout: .now() + 20)
        guard let found = printed.url else {
            process.terminate()
            throw Failure.didNotStart(printed.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        self.process = process
        base = found
        if quit == nil {
            quit = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.stop() }
        }
        return found
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        process?.terminate()
        process = nil
        base = nil
    }

    /// One HTTP call; the reply as JSON (`true` for an empty 204).
    func call(_ method: String, _ path: String, directory: String?, body: JSONValue? = nil) async throws -> JSONValue {
        var request = URLRequest(url: try endpoint(path, directory: directory))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(try body.line().utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(code) else { throw Failure.http(code, String(text.prefix(300))) }
        return text.isEmpty ? true : try JSONValue.parse(text)
    }

    /// The `/event` stream for `directory`, one JSON event per element. Connected
    /// when this returns, so nothing sent afterwards is missed.
    func events(directory: String) async throws -> AsyncThrowingStream<JSONValue, Error> {
        var request = URLRequest(url: try endpoint("/event", directory: directory))
        request.timeoutInterval = .infinity
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.http(code, "event stream") }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines where line.hasPrefix("data: ") {
                        if let event = try? JSONValue.parse(String(line.dropFirst(6))) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func endpoint(_ path: String, directory: String?) throws -> URL {
        // `path` may carry its own query (`/session?roots=true`).
        guard var components = URLComponents(string: try url().absoluteString + path) else {
            throw Failure.didNotStart("bad path \(path)")
        }
        if let directory {
            let query = components.queryItems ?? []
            components.queryItems = query + [URLQueryItem(name: "directory", value: directory)]
        }
        guard let url = components.url else { throw Failure.didNotStart("bad path \(path)") }
        return url
    }

    /// What the server printed while starting, and the address once it says it listens.
    private final class Printed: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private(set) var url: URL?

        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }

        /// True when this chunk revealed the address.
        func append(_ chunk: Data) -> Bool {
            lock.withLock {
                guard url == nil else { return false }
                data.append(chunk)
                url = Self.address(in: String(decoding: data, as: UTF8.self))
                return url != nil
            }
        }

        /// `opencode server listening on http://127.0.0.1:4096` → that URL.
        static func address(in output: String) -> URL? {
            guard let range = output.range(of: "listening on ") else { return nil }
            let rest = output[range.upperBound...]
            guard let end = rest.firstIndex(where: \.isNewline) else { return nil }
            return URL(string: String(rest[..<end]).trimmingCharacters(in: .whitespaces))
        }
    }
}
