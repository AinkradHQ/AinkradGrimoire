import Foundation
import Testing

@testable import GrimoireFeature

@Suite("ThreadEntries")
struct ThreadEntriesTests {
    @Test("a tool result fills in its call; orphans and empty blocks are dropped; todos become a plan")
    func grouping() {
        let entries = ThreadEntries.build([
            .user("fix it"),
            .assistant(.thinking("let me look")),
            .assistant(.text("  \n")),
            .assistant(.toolUse(id: "t1", name: "Read", input: ["file_path": "/repo/a.swift"])),
            .assistant(
                .toolUse(
                    id: "t2", name: "TodoWrite",
                    input: [
                        "todos": [
                            ["content": "Find it", "status": "completed"],
                            ["content": "Fix it", "status": "in_progress"],
                            ["content": "Ship it", "status": "pending"],
                        ]
                    ])),
            .toolResult(toolUseID: "t1", content: "1\tlet a = 1", isError: false),
            .toolResult(toolUseID: "nobody", content: "stray", isError: false),
            .assistant(.text("Done.")),
        ])
        #expect(
            entries == [
                .user("fix it"),
                .thinking("let me look"),
                .tool(
                    ToolCall(
                        id: "t1", name: "Read", input: ["file_path": "/repo/a.swift"],
                        result: ToolOutput(content: "1\tlet a = 1", isError: false))),
                .plan([
                    PlanStep(title: "Find it", status: .completed), PlanStep(title: "Fix it", status: .inProgress),
                    PlanStep(title: "Ship it", status: .pending),
                ]),
                .text("Done."),
            ])
    }

    @Test("tool headers show the argument that matters, relative to the project")
    func arguments() {
        let cwd = "/repo"
        #expect(
            ToolSummary.argument(name: "Bash", input: ["command": "make build"], workingDirectory: cwd) == "make build")
        #expect(
            ToolSummary.argument(name: "Edit", input: ["file_path": "/repo/Sources/A.swift"], workingDirectory: cwd)
                == "Sources/A.swift")
        #expect(
            ToolSummary.argument(name: "Read", input: ["file_path": "/elsewhere/B.swift"], workingDirectory: cwd)
                == "/elsewhere/B.swift")
        #expect(
            ToolSummary.argument(
                name: "Grep", input: ["pattern": "stroke", "path": "/repo/Sources"], workingDirectory: cwd)
                == "\"stroke\" in Sources")
        #expect(
            ToolSummary.argument(name: "mcp__x__y", input: ["b": "second", "a": "first"], workingDirectory: cwd)
                == "first")
        #expect(ToolSummary.argument(name: "mcp__x__y", input: .null, workingDirectory: cwd) == "")
    }

    @Test("result notes: running, line counts, edit +/−, the first line of an error")
    func results() {
        #expect(ToolSummary.result(name: "Bash", input: .null, output: nil) == "running…")
        #expect(
            ToolSummary.result(name: "Read", input: .null, output: ToolOutput(content: "a\nb\nc", isError: false))
                == "3 lines")
        #expect(
            ToolSummary.result(name: "Bash", input: .null, output: ToolOutput(content: "ok", isError: false))
                == "1 line")
        // GD18: the newline that ends the output is not one more line.
        #expect(
            ToolSummary.result(name: "Bash", input: .null, output: ToolOutput(content: "ok\n", isError: false))
                == "1 line")
        #expect(
            ToolSummary.result(name: "Read", input: .null, output: ToolOutput(content: "a\n\nc\n", isError: false))
                == "3 lines")
        #expect(ToolSummary.lines("\n") == [""])
        #expect(
            ToolSummary.result(name: "Write", input: ["content": "hello\n"], output: ToolOutput(content: "", isError: false))
                == "1 line")
        #expect(
            ToolSummary.result(name: "Bash", input: .null, output: ToolOutput(content: "exit 1\nmore", isError: true))
                == "exit 1")
        #expect(
            ToolSummary.result(name: "Grep", input: .null, output: ToolOutput(content: "a:1\nb:2\nc:3", isError: false))
                == "3 matches")
        #expect(
            ToolSummary.result(name: "Glob", input: .null, output: ToolOutput(content: "a.swift", isError: false))
                == "1 file")
        let edit: JSONValue = ["old_string": "a\nb\nc", "new_string": "a\nB\nc\nd"]
        #expect(
            ToolSummary.result(name: "Edit", input: edit, output: ToolOutput(content: "", isError: false)) == "+2 −1")
    }
}
