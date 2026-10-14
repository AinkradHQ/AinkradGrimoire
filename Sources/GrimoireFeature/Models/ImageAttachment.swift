import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image in the composer's chips row, ready for the wire.
struct ImageAttachment: Identifiable, Equatable, Sendable {
    let id = UUID()
    var name: String
    var image: EngineImage

    /// The formats every image-taking CLI accepts as they are.
    static let wireTypes: [String: String] = [
        UTType.png.identifier: "image/png", UTType.jpeg.identifier: "image/jpeg", UTType.gif.identifier: "image/gif",
        UTType.webP.identifier: "image/webp",
    ]
    /// The images `make` can attach: the types ImageIO reads. SVG is an image to UTType but not to ImageIO (GD47).
    static let attachableTypes: [UTType] = ((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        .compactMap { UTType($0) }
        .filter { $0.conforms(to: .image) && !$0.conforms(to: .svg) }

    /// Whether the file at `url` is an image `make` can attach, by its extension.
    static func canAttach(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return attachableTypes.contains { type.conforms(to: $0) }
    }

    /// What the composer says when `name` couldn't be attached.
    static func problem(_ name: String) -> String {
        "“\(name)” can’t be attached — only images can (PNG, JPEG, GIF, WebP, HEIC…)."
    }
    /// Claude takes at most 5 MB of base64 per image (3.75 MB raw); the others take less or the same.
    static let maxBytes = 3_750_000
    /// Anthropic's vision API rejects an image with a side over this, whatever its file size (GD48).
    static let maxSide = 8000
    /// Longer sides are scaled down to this before re-encoding; models downscale past ~1.5k anyway.
    static let maxPixels = 2048

    /// `data` as an attachment: sent as it is when it's PNG, JPEG, GIF or WebP and small enough in bytes and pixels, otherwise
    /// (TIFF from the pasteboard, HEIC, a huge screenshot) scaled and re-encoded as PNG, or JPEG when PNG is too
    /// big. Nil when it isn't an image. Runs off the main thread (ImageIO is thread-safe).
    static func make(data: Data, name: String) -> ImageAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sides = [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight].compactMap { properties?[$0] as? Int }
        if let mediaType = wireTypes[type as String], data.count <= maxBytes, sides.count == 2,
            sides.allSatisfy({ $0 <= maxSide })
        {
            return ImageAttachment(name: name, image: EngineImage(mediaType: mediaType, base64: data.base64EncodedString()))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        for (type, mediaType) in [(UTType.png, "image/png"), (UTType.jpeg, "image/jpeg")] {
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
                continue
            }
            CGImageDestinationAddImage(
                destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination), out.length <= maxBytes else { continue }
            return ImageAttachment(
                name: name, image: EngineImage(mediaType: mediaType, base64: (out as Data).base64EncodedString()))
        }
        return nil
    }

    /// The image file at `url`, read and converted off the main thread.
    static func load(_ url: URL) async -> ImageAttachment? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return make(data: data, name: url.lastPathComponent)
        }.value
    }

    static func load(_ data: Data, name: String) async -> ImageAttachment? {
        await Task.detached(priority: .userInitiated) { make(data: data, name: name) }.value
    }
}

extension Harness {
    /// Whether the CLI takes images with a message: Claude (image blocks), Codex (`image` input), OpenCode (`file`
    /// parts). agy's print mode takes text only.
    var acceptsImages: Bool { self != .agy }
}
