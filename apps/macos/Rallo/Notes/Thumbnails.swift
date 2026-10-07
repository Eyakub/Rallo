import AppKit
import ImageIO

/// Small images for the note field and rows (0018), decoded at the size
/// they're shown (2× for Retina) so a 10 MB screenshot never decodes whole.
enum Thumbnails {
    static func image(data: Data, points: CGFloat) -> NSImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { make($0, points: points) }
    }

    static func image(url: URL, points: CGFloat) -> NSImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { make($0, points: points) }
    }

    private static func make(_ source: CGImageSource, points: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: points * 2,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let scale = CGFloat(max(image.width, image.height)) / points
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }
}
