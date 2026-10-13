import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import GrimoireFeature

@MainActor
@Suite("Image attachments")
struct ImageAttachmentTests {
    /// A `width`×`height` image encoded as `type`.
    static func image(_ type: UTType, width: Int = 4, height: Int = 3) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    @Test("PNG and JPEG go as they are; TIFF becomes PNG; anything else is not an image")
    func formats() throws {
        let png = Self.image(.png)
        let attached = try #require(ImageAttachment.make(data: png, name: "a.png"))
        #expect(attached.image == EngineImage(mediaType: "image/png", base64: png.base64EncodedString()))
        #expect(ImageAttachment.make(data: Self.image(.jpeg), name: "b.jpg")?.image.mediaType == "image/jpeg")
        let tiff = try #require(ImageAttachment.make(data: Self.image(.tiff), name: "c.tiff"))
        #expect(tiff.image.mediaType == "image/png")
        #expect(Data(base64Encoded: tiff.image.base64).flatMap { ImageAttachment.make(data: $0, name: "") } != nil)
        #expect(ImageAttachment.make(data: Data("not an image".utf8), name: "x.txt") == nil)
    }

    @Test("a huge image is scaled down under the wire limit")
    func huge() throws {
        let big = try #require(ImageAttachment.make(data: Self.image(.bmp, width: 3000, height: 2000), name: "big.bmp"))
        let data = try #require(Data(base64Encoded: big.image.base64))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let width = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth]
        #expect(width as? Int == ImageAttachment.maxPixels)
        #expect(data.count <= ImageAttachment.maxBytes)
    }

    @Test("⌘V attaches image data with no text; text on the pasteboard pastes as text")
    func paste() async throws {
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo")),
            makeEngine: { FakeEngine() })
        let board = NSPasteboard(name: NSPasteboard.Name("grimoire-test-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("some text", forType: .string)
        #expect(!Attach.paste(board, into: live))
        board.clearContents()
        board.setData(Self.image(.png), forType: .png)
        #expect(Attach.paste(board, into: live))
        for _ in 0..<100 where live.attachments.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(live.attachments.map(\.name) == ["Pasted image.png"])
    }

    @Test("images go with the message to the agent")
    func send() {
        let engine = FakeEngine()
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo")),
            makeEngine: { engine })
        let image = EngineImage(mediaType: "image/png", base64: "AAA")
        live.send("look", images: [image], imageNames: ["sidebar.png"])
        live.send("and?")
        #expect(engine.images == [[image], []])
        // The transcript's bubble shows what went with each message.
        #expect(live.sentImages == [0: ["sidebar.png"]])
        #expect(Harness.allCases.filter(\.acceptsImages) == [.claude, .codex, .opencode])
    }

    @Test("GD30: a failed turn puts the images back with the message, and Retry sends them")
    func retryKeepsImages() {
        let engine = FakeEngine()
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo")),
            makeEngine: { engine })
        let image = EngineImage(mediaType: "image/png", base64: "AAA")
        live.draft = "look"
        live.attachments = [ImageAttachment(name: "sidebar.png", image: image)]
        live.sendDraft()
        #expect(live.attachments.isEmpty)
        live.apply(.exited(code: 1))
        #expect(live.failure != nil)
        #expect(live.draft == "look")
        #expect(live.attachments.map(\.name) == ["sidebar.png"])
        live.retry()
        #expect(engine.images == [[image], [image]])
        #expect(live.attachments.isEmpty)
    }

    @Test("GD30: a usage-limited turn keeps the images in the composer, and Send at reset sends them")
    func sendAtResetKeepsImages() {
        let engine = FakeEngine()
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo")),
            makeEngine: { engine })
        let image = EngineImage(mediaType: "image/png", base64: "AAA")
        live.draft = "look"
        live.attachments = [ImageAttachment(name: "sidebar.png", image: image)]
        live.sendDraft()
        live.apply(
            .turnFinished(
                TurnResult(outcome: .failed("Claude AI usage limit reached|1791704320"), sessionID: "s", costUSD: nil, text: nil)))
        #expect(live.hitLimit)
        #expect(live.attachments.map(\.name) == ["sidebar.png"])
        live.sendAtReset(Date(timeIntervalSince1970: 1_791_704_320))
        live.sendQueued()
        #expect(engine.images == [[image], [image]])
        #expect(live.sentImages[2] == ["sidebar.png"])
    }

    @Test("GD30: New thread with Codex carries the composer's images")
    func carryOverKeepsImages() throws {
        let model = GrimoireModel(
            settings: SettingsStore(documents: MemoryDocs()),
            sessionsRoot: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-none-\(UUID())"))
        model.cli = .found(path: "/usr/bin/true", version: "2.1.296")
        model.otherCLIs[.codex] = .found(path: "/usr/bin/true", version: "0.154.0")
        var engines: [FakeEngine] = []
        model.engineOverride = {
            let engine = FakeEngine()
            engines.append(engine)
            return engine
        }
        model.startThread(project: "/repo", prompt: "first", model: nil, mode: .ask, worktree: false)
        let claude = try #require(model.selectedThread)
        let live = try #require(model.current)
        let image = EngineImage(mediaType: "image/png", base64: "AAA")
        live.draft = "look"
        live.attachments = [ImageAttachment(name: "sidebar.png", image: image)]
        model.carryOver(claude, to: .codex)
        #expect(engines.last?.sent == ["look"])
        #expect(engines.last?.images == [[image]])
        #expect(live.attachments.isEmpty)
    }

    @Test("GD32: ⌘V attaches only when the focused text view is inside Grimoire's composer, not another app's field")
    func pasteOnlyInOwnComposer() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [], backing: .buffered, defer: true)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        window.contentView = root
        // Grimoire's composer on the right; another tiled app's multi-line field on the left.
        let monitor = PasteImageMonitor.MonitorView(frame: NSRect(x: 420, y: 10, width: 360, height: 80))
        // Both scrollable, as the kit's composer field is.
        let composerScroll = NSTextView.scrollableTextView()
        composerScroll.frame = NSRect(x: 440, y: 30, width: 320, height: 40)
        let otherScroll = NSTextView.scrollableTextView()
        otherScroll.frame = NSRect(x: 20, y: 30, width: 320, height: 40)
        [monitor, composerScroll, otherScroll].forEach(root.addSubview)
        let composer = composerScroll.documentView!, other = otherScroll.documentView!
        #expect(monitor.contains(composer))
        #expect(!monitor.contains(other))
        #expect(!monitor.contains(NSTextView(frame: composerScroll.frame)), "not in this window")
    }

    @Test("Couldn't send: a message the engine refused stays in the composer with its images")
    func sendFailureKeepsMessage() {
        let engine = FakeEngine()
        engine.sendError = CocoaError(.fileWriteUnknown)
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo")),
            makeEngine: { engine })
        let image = EngineImage(mediaType: "image/png", base64: "AAA")
        live.draft = "look"
        live.attachments = [ImageAttachment(name: "sidebar.png", image: image)]
        live.sendDraft()
        guard case .failed(let message) = live.status else { return #expect(Bool(false), "not failed") }
        #expect(message.hasPrefix("Couldn't send"))
        #expect(live.entries.isEmpty)
        #expect(live.draft == "look")
        #expect(live.attachments.map(\.name) == ["sidebar.png"])
        #expect(live.attachments.map(\.image) == [image])
        // An agent that never started keeps it the same way, and its card says so.
        let dead = FakeEngine()
        dead.startError = CocoaError(.fileNoSuchFile)
        let unstarted = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo")),
            makeEngine: { dead })
        unstarted.draft = "look"
        unstarted.attachments = [ImageAttachment(name: "sidebar.png", image: image)]
        unstarted.sendDraft()
        #expect(unstarted.draft == "look")
        #expect(unstarted.attachments.map(\.name) == ["sidebar.png"])
        #expect(unstarted.failure?.restoredDraft == true)
    }
}

