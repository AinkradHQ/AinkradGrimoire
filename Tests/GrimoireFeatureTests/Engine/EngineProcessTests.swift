import Foundation
import Testing

@testable import GrimoireFeature

// A hang here (GD25) must fail the run, not stall it for minutes.
@Suite("HarnessProcess", .timeLimit(.minutes(1)))
struct HarnessProcessTests {
    private func collect(_ script: String, input: [String] = []) async throws -> [HarnessProcess.Output] {
        let process = HarnessProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), environment: [:])
        try process.run()
        for line in input { try process.write(line) }
        if !input.isEmpty { process.stop() }
        var outputs: [HarnessProcess.Output] = []
        for await output in process.output { outputs.append(output) }
        return outputs
    }

    @Test("lines arrive in order, the last one without a newline too, then the exit with stderr")
    func linesThenExit() async throws {
        let outputs = try await collect(#"printf 'one\ntwo\nthree'; echo oops >&2; exit 3"#)
        #expect(outputs == [.line("one"), .line("two"), .line("three"), .exited(code: 3, stderr: "oops\n")])
    }

    /// The bug this guards (GD12): writing to a CLI that already exited raised SIGPIPE, which kills the
    /// whole process — here the test runner, in the app the host. It must throw instead.
    @Test("writing to a CLI that already exited throws instead of killing the process")
    func writeAfterExitThrows() async throws {
        let process = HarnessProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"],
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), environment: [:])
        try process.run()
        for await _ in process.output {}
        #expect(throws: (any Error).self) { try process.write("hello") }
    }

    /// The bug this guards (GD25): the readers and `waitUntilExit` sat on GCD's global pool, so a run under
    /// load (pool busy with other blocked work) waited minutes for the exit. They must not need that pool.
    @Test("the exit arrives while GCD's global pool is saturated")
    func exitWithBusyPool() async throws {
        let blocker = DispatchSemaphore(value: 0)
        for _ in 0..<128 { DispatchQueue.global().async { _ = blocker.wait(timeout: .now() + 5) } }
        defer { for _ in 0..<128 { blocker.signal() } }
        let started = ContinuousClock.now
        let outputs = try await collect("echo hi; exit 2")
        #expect(outputs == [.line("hi"), .exited(code: 2, stderr: "")])
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    /// The bug this guards: `FileHandle.bytes` held a running child's output
    /// back, so a live session saw its first chunk and then nothing.
    @Test("a line arrives while the child is still running")
    func lineBeforeExit() async throws {
        let process = HarnessProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo first; sleep 5; echo second"],
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), environment: [:])
        try process.run()
        let started = ContinuousClock.now
        var iterator = process.output.makeAsyncIterator()
        #expect(await iterator.next() == .line("first"))
        #expect(ContinuousClock.now - started < .seconds(3))
        process.stop(grace: .zero)
    }

    @Test("what is written to stdin reaches the child; closing stdin ends it")
    func stdinRoundTrip() async throws {
        let outputs = try await collect("cat", input: [#"{"a":1}"#, "second"])
        #expect(outputs.prefix(2) == [.line(#"{"a":1}"#), .line("second")])
        #expect(outputs.last == .exited(code: 0, stderr: ""))
    }
}

@Suite("LineBuffer")
struct LineBufferTests {
    @Test("lines split across reads, including mid-character, are joined")
    func splits() {
        var buffer = LineBuffer()
        let bytes = Array("héllo\nwor".utf8)
        #expect(buffer.append(Data(bytes[0..<2])) == [])  // ends inside "é"
        #expect(buffer.append(Data(bytes[2...])) == ["héllo"])
        #expect(buffer.append(Data("ld\n\nnext".utf8)) == ["world"])
        #expect(buffer.flush() == "next")
        #expect(buffer.flush() == nil)
    }
}

@Suite("CLILocator")
struct CLILocatorTests {
    @Test("env -0 output parses, keeping '=' and newlines inside values")
    func parseEnv0() {
        let data = Data("PATH=/a:/b\0EQ=x=y\0MULTI=line1\nline2\0=bad\0".utf8)
        #expect(CLILocator.parseEnv0(data) == ["PATH": "/a:/b", "EQ": "x=y", "MULTI": "line1\nline2"])
    }

    @Test("the first executable on PATH wins; empty segments are skipped")
    func locate() {
        let present: Set = ["/opt/homebrew/bin/opencode", "/Users/me/.local/bin/claude", "/usr/local/bin/claude"]
        let path = "/usr/bin::/Users/me/.local/bin:/usr/local/bin:/opt/homebrew/bin"
        #expect(
            CLILocator.locate("claude", path: path, isExecutable: present.contains)?.path
                == "/Users/me/.local/bin/claude")
        #expect(
            CLILocator.locate("opencode", path: path, isExecutable: present.contains)?.path
                == "/opt/homebrew/bin/opencode")
        #expect(CLILocator.locate("agy", path: path, isExecutable: present.contains) == nil)
    }

    @Test("the login shell's environment has a PATH")
    func loginEnvironment() {
        #expect(CLILocator.loginEnvironment()["PATH"]?.isEmpty == false)
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test("round-trips through one compact line")
    func roundTrip() throws {
        let value: JSONValue = ["a": [true, .null, .number(1.5), "x/y"], "b": ["c": "d"]]
        let line = try value.line()
        #expect(!line.contains("\n"))
        #expect(line.contains("x/y"))
        #expect(try JSONValue.parse(line) == value)
    }

    @Test("booleans stay booleans and numbers stay numbers")
    func types() throws {
        #expect(try JSONValue.parse("[true, 1, 0]") == [true, .number(1), .number(0)])
    }
}
