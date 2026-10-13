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
        live.send("look", images: [image])
        #expect(engine.images == [[image]])
        #expect(Harness.allCases.filter(\.acceptsImages) == [.claude, .codex, .opencode])
    }
}
