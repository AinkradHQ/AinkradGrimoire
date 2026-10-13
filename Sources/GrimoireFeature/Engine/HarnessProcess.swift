import Foundation

/// Splits a byte stream into newline-terminated lines. Works on bytes, so a
/// read that ends mid-character or mid-line carries over to the next one.
struct LineBuffer {
    private var pending = Data()

    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        return lines
    }

    /// What is left when the stream closes without a final newline.
    mutating func flush() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

/// A child CLI speaking line-delimited JSON on stdin/stdout. stdout is read to
/// EOF before the exit is reported, so the last line (the turn's result) is
/// never lost; stderr is kept as a bounded tail so a crash can say why.
final class HarnessProcess: @unchecked Sendable {
    enum Output: Sendable, Equatable {
        case line(String)
        case exited(code: Int32, stderr: String)
    }

    let output: AsyncStream<Output>
    private let continuation: AsyncStream<Output>.Continuation
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    static let stderrLimit = 8_192
    // Written by the stderr reader, read once after it finished.
    private let tailLock = NSLock()
    private var stderrTail = Data()

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        (output, continuation) = AsyncStream.makeStream(of: Output.self)
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // A CLI that exits before we write to it (bad config, old version) closes the pipe; by default the
        // write then raises SIGPIPE, which terminates the WHOLE host (exit 141). Without it the write throws
        // EPIPE instead, which the caller handles. Same guard as the host's LSP/MCP transports.
        Self.disableSigPipe(stdin)
    }

    static func disableSigPipe(_ pipe: Pipe) {
        var on: Int32 = 1
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, &on)
    }

    func run() throws {
        // Nothing here needs GCD's global pool (GD25): the readers block on threads of their own, the exit
        // comes from `terminationHandler` and is reported on a private queue. Blocking reads plus
        // `waitUntilExit` on that pool stalled for minutes once it was busy with other blocked work.
        let finished = DispatchGroup()
        finished.enter()  // stdout at EOF
        finished.enter()  // stderr at EOF
        finished.enter()  // the child exited
        process.terminationHandler = { _ in finished.leave() }
        try process.run()
        // Blocking reads: `availableData` returns as soon as the child writes
        // anything. (`FileHandle.bytes` holds pipe data back until its buffer
        // fills, which stalls a live session.)
        Thread.detachNewThread { [self] in
            while case let data = stderr.fileHandleForReading.availableData, !data.isEmpty {
                tailLock.withLock {
                    stderrTail.append(data)
                    if stderrTail.count > Self.stderrLimit * 2 { stderrTail = stderrTail.suffix(Self.stderrLimit) }
                }
            }
            finished.leave()
        }
        Thread.detachNewThread { [self] in
            var buffer = LineBuffer()
            while case let data = stdout.fileHandleForReading.availableData, !data.isEmpty {
                for line in buffer.append(data) { continuation.yield(.line(line)) }
            }
            if let last = buffer.flush() { continuation.yield(.line(last)) }
            finished.leave()
        }
        finished.notify(queue: DispatchQueue(label: "HarnessProcess.exit")) { [self] in
            let tail = tailLock.withLock { stderrTail.suffix(Self.stderrLimit) }
            continuation.yield(.exited(code: process.terminationStatus, stderr: String(decoding: tail, as: UTF8.self)))
            continuation.finish()
        }
    }

    /// Writes one line; the newline is added here.
    func write(_ line: String) throws {
        try stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Closes stdin — a well-behaved CLI finishes and exits on EOF — and
    /// terminates it only if it is still running after `grace`.
    func stop(grace: Duration = .seconds(3)) {
        try? stdin.fileHandleForWriting.close()
        Task.detached { [process] in
            try? await Task.sleep(for: grace)
            if process.isRunning { process.terminate() }
        }
    }
}
