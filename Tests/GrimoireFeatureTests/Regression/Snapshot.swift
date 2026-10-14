import AinkradAppKit
import AppKit
import SwiftUI
import XCTest

/// Off-screen snapshots: a view in a borderless window that is never ordered
/// in, drawn with `cacheDisplay`. Neon only — off-screen drawing can't show
/// Liquid Glass. Motion is frozen and the system face stands in for Exo 2, so
/// nothing depends on animation or the fonts the host registers.
@MainActor
enum Snapshot {
    static let skin = AinkradSkin.standard

    /// The host's Neon theme, with the theme's own status colours.
    static let theme: HostTheme = {
        let theme = HostTheme(HostThemeTokens(skin: skin))
        theme.updateStatusColors(
            HostStatusColors(
                success: skin.color(skin.palette.success), warning: skin.color(skin.palette.warning),
                danger: skin.color(skin.palette.danger)))
        return theme
    }()

    /// The view in an off-screen window, settled: tasks and `onAppear` work run
    /// on the main queue for `settle` before the window lays out again.
    static func host(_ view: some View, size: CGSize, settle: TimeInterval = 0.3) -> (NSWindow, NSView) {
        // The goldens draw mono text in JetBrains Mono, which only the host registers: without it they depend on
        // whether the glass sweep happened to run first in the same process.
        _ = registeredFonts
        let content =
            view
            .frame(width: size.width, height: size.height)
            .background(skin.color(skin.palette.background))
            .ainkradSkin(skin)
            .ainkradHostTheme(theme)
            .environment(\.ainkradTypography, AinkradTypography(fontFamilyName: nil))
            .environment(\.ainkradMotionBudget, .frozen)
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        // Closed by the caller; ARC owns it, so `close()` must not release it again.
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        settleLayout(hosting, for: settle)
        return (window, hosting)
    }

    private static let registeredFonts: Void = GlassSweepTests.registerHostFonts()

    static func settleLayout(_ view: NSView, for interval: TimeInterval) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
        view.layoutSubtreeIfNeeded()
    }

    /// `view` drawn into a 2x RGBA bitmap.
    static func capture(_ view: NSView) -> CGImage? {
        let scale: CGFloat = 2
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)
        else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    // MARK: - Goldens

    /// Goldens live beside this file; `TEST_RUNNER_GRIMOIRE_GOLDEN_RECORD=1 make test` rewrites them.
    static let goldens = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Goldens")
    static var isRecording: Bool { ProcessInfo.processInfo.environment["GRIMOIRE_GOLDEN_RECORD"] == "1" }

    /// A pixel differs when any channel is off by more than this (of 255)…
    static let channelTolerance = 24
    /// …and a snapshot fails when more than this share of its pixels differ.
    static let pixelTolerance = 0.002

    /// Renders `view` and checks it against `Goldens/<name>.png`. On a mismatch
    /// the render and a diff mask are written to the temporary directory.
    static func assertMatches(
        _ view: some View, named name: String, size: CGSize, file: StaticString = #filePath, line: UInt = #line
    ) {
        let (window, hosting) = host(view, size: size)
        defer { window.close() }
        assertMatches(hosted: hosting, named: name, file: file, line: line)
    }

    /// Checks a view already hosted (and put in the state to shoot) against `Goldens/<name>.png`.
    static func assertMatches(hosted hosting: NSView, named name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let image = capture(hosting), let png = pngData(image) else {
            return XCTFail("\(name) did not render", file: file, line: line)
        }
        let golden = goldens.appendingPathComponent("\(name).png")
        if isRecording {
            XCTAssertNoThrow(try FileManager.default.createDirectory(at: goldens, withIntermediateDirectories: true))
            XCTAssertNoThrow(try png.write(to: golden), file: file, line: line)
            return
        }
        guard let data = try? Data(contentsOf: golden), let source = CGImageSourceCreateWithData(data as CFData, nil),
            let expected = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return XCTFail(
                "no golden for \(name) — record with TEST_RUNNER_GRIMOIRE_GOLDEN_RECORD=1 make test", file: file,
                line: line)
        }
        guard expected.width == image.width, expected.height == image.height else {
            return XCTFail(
                "\(name) is \(image.width)×\(image.height), its golden \(expected.width)×\(expected.height)",
                file: file,
                line: line)
        }
        let actual = rgba(image)
        let wanted = rgba(expected)
        // Identical bytes need no per-pixel pass (slow in a Debug build).
        let identical = actual.withUnsafeBytes { a in
            wanted.withUnsafeBytes { memcmp(a.baseAddress, $0.baseAddress, a.count) == 0 }
        }
        if identical { return }
        var mask = [UInt8](repeating: 0, count: actual.count)
        var differing = 0
        actual.withUnsafeBufferPointer { a in
            wanted.withUnsafeBufferPointer { w in
                for pixel in stride(from: 0, to: a.count, by: 4) {
                    var off = false
                    for channel in pixel..<pixel + 4 where abs(Int(a[channel]) - Int(w[channel])) > channelTolerance {
                        off = true
                    }
                    if off {
                        differing += 1
                        mask[pixel] = 255
                        mask[pixel + 3] = 255
                    }
                }
            }
        }
        let share = Double(differing) / Double(image.width * image.height)
        guard share > pixelTolerance else { return }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-snapshots")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? png.write(to: out.appendingPathComponent("\(name).png"))
        if let diff = makeImage(mask, width: image.width, height: image.height).flatMap(pngData) {
            try? diff.write(to: out.appendingPathComponent("\(name)-diff.png"))
        }
        XCTFail(
            "\(name) differs from its golden in \(differing) pixels (\(String(format: "%.3f", share * 100))%) — see \(out.path)",
            file: file, line: line)
    }

    /// The image as straight RGBA8 bytes in sRGB, whatever it was encoded as.
    static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    static func makeImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
