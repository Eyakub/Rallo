import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Why the note field didn't take an image (0018); `message` is shown as is.
struct ImageRefusal: Error, Equatable {
    let message: String
}

/// Turns what the user pastes or drops into bytes the core stores (0018).
/// PNG, JPEG, HEIC, GIF and WebP pass through untouched; any other image
/// ImageIO reads (TIFF is what many apps copy) becomes PNG; one over 10 MB is
/// re-encoded as HEIC (JPEG if HEIC isn't available) when that makes it fit,
/// as screenshots from a 5K or 6K display can. The core checks
/// formats and limits again; the checks here only make the panel's refusal
/// immediate.
enum ImageClipboard {
    static let maxBytes = 10 * 1024 * 1024
    static let maxImages = 10

    private static let stored: Set<String> = [
        UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier,
        UTType.gif.identifier, UTType.webP.identifier,
    ]

    /// The images on `pasteboard`, ready to store; `[]` when it holds none
    /// (so ⌘V pastes text as usual). Copied files win over image data, since
    /// Finder also puts each file's icon on the clipboard.
    static func images(from pasteboard: NSPasteboard) throws -> [Data] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            return try urls.filter(isImageFile).compactMap { url in
                do {
                    return storable(try Data(contentsOf: url))
                } catch {
                    throw ImageRefusal(message: "Couldn’t read \(url.lastPathComponent).")
                }
            }
        }
        let types: [NSPasteboard.PasteboardType] = [.png, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier),
                                                     .init(UTType.gif.identifier), .init(UTType.webP.identifier), .tiff]
        return (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.availableType(from: types).flatMap { item.data(forType: $0) }.flatMap(storable)
        }
    }

    /// `data` as Rallo stores it, or nil when it isn't an image.
    static func storable(_ data: Data) -> Data? {
        normalized(data).map(fitted)
    }

    /// An image over 10 MB re-encoded at full resolution (HEIC, else JPEG, at
    /// quality 0.85) if the result fits; otherwise `data` unchanged, so
    /// `check` refuses it with its message.
    static func fitted(_ data: Data) -> Data {
        guard data.count > maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return data }
        for type in [UTType.heic, UTType.jpeg] {
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(
                destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
            )
            if CGImageDestinationFinalize(destination), encoded.length <= maxBytes { return encoded as Data }
        }
        return data
    }

    private static func normalized(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?
        else { return nil }
        if stored.contains(type) { return data }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? png as Data : nil
    }

    /// Refuses the whole batch if any image is over 10 MB or the note would
    /// hold more than 10.
    static func check(_ new: [Data], staged: Int) throws {
        if staged + new.count > maxImages {
            throw ImageRefusal(message: "A note can hold \(maxImages) images.")
        }
        if let big = new.first(where: { $0.count > maxBytes }) {
            let size = String(format: "%.1f", Double(big.count) / 1_048_576)
            throw ImageRefusal(message: "That image is \(size) MB; Rallo keeps images up to 10 MB.")
        }
    }

    /// Images dropped on the panel: image files from Finder and image data
    /// from other apps both arrive as `public.image` representations.
    static func load(_ providers: [NSItemProvider]) async -> [Data] {
        var images: [Data] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if let data, let image = storable(data) { images.append(image) }
        }
        return images
    }

    private static func isImageFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) ?? false
    }
}
