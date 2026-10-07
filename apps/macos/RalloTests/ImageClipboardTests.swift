import AppKit
import UniformTypeIdentifiers
import XCTest

/// 0018: what the note field accepts from ⌘V and drops.
final class ImageClipboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("rallo-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    /// A real 2×2 image, encoded as `type`. Build each fixture once per test:
    /// the bitmap's memory isn't guaranteed zero-filled, so two calls can differ.
    private func image(_ type: NSBitmapImageRep.FileType) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: type, properties: [:])!
    }

    func testPNGAndJPEGPassThroughUntouched() {
        let png = image(.png)
        let jpeg = image(.jpeg)
        XCTAssertEqual(ImageClipboard.storable(png), png)
        XCTAssertEqual(ImageClipboard.storable(jpeg), jpeg)
    }

    func testTIFFBecomesPNG() throws {
        let png = try XCTUnwrap(ImageClipboard.storable(image(.tiff)))
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    func testTextIsNotAnImage() throws {
        XCTAssertNil(ImageClipboard.storable(Data("hello".utf8)))
        pasteboard.setString("just text", forType: .string)
        XCTAssertEqual(try ImageClipboard.images(from: pasteboard), [], "text pastes as text")
    }

    func testImageWinsOverTextOnTheClipboard() throws {
        // What a browser's Copy Image puts on the clipboard: the image and its address.
        let png = image(.png)
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setString("https://example.com/shot.png", forType: .string)
        pasteboard.writeObjects([item])
        XCTAssertEqual(try ImageClipboard.images(from: pasteboard), [png])
    }

    func testCopiedImageFilesAreRead() throws {
        let png = image(.png)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shot = dir.appendingPathComponent("shot.png")
        let notes = dir.appendingPathComponent("notes.txt")
        try png.write(to: shot)
        try Data("x".utf8).write(to: notes)
        // Finder's Copy: file URLs (plus an icon, which must not be taken for the image).
        pasteboard.writeObjects([shot as NSURL, notes as NSURL])
        XCTAssertEqual(try ImageClipboard.images(from: pasteboard), [png], "image files only")
    }

    func testOversizedImageIsRefusedWhenStaged() {
        let png = image(.png)
        var big = png
        big.append(Data(count: 12 * 1024 * 1024))
        XCTAssertThrowsError(try ImageClipboard.check([big], staged: 0)) { error in
            XCTAssertEqual(error as? ImageRefusal, ImageRefusal(message: "That image is 12.0 MB; Rallo keeps images up to 10 MB."))
        }
        XCTAssertNoThrow(try ImageClipboard.check([png], staged: 0))
    }

    func testAnEleventhImageIsRefused() {
        let png = image(.png)
        XCTAssertNoThrow(try ImageClipboard.check([png], staged: 9))
        XCTAssertThrowsError(try ImageClipboard.check([png, png], staged: 9)) { error in
            XCTAssertEqual(error as? ImageRefusal, ImageRefusal(message: "A note can hold 10 images."))
        }
    }

    func testThumbnailsAreSmall() throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let thumbnail = try XCTUnwrap(Thumbnails.image(data: rep.representation(using: .png, properties: [:])!, points: 56))
        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), 56)
        XCTAssertNil(Thumbnails.image(data: Data("x".utf8), points: 56))
        XCTAssertNil(Thumbnails.image(url: URL(fileURLWithPath: "/nonexistent.png"), points: 56))
    }

    @MainActor
    func testMissingFileHasNoThumbnail() async {
        let image = await ThumbnailCache().image(for: "/nonexistent/\(UUID().uuidString).png")
        XCTAssertNil(image, "the row shows its missing-file placeholder")
    }

    @MainActor
    func testThumbnailsAreCachedByPath() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-tests-\(UUID().uuidString).png")
        try image(.png).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = ThumbnailCache()
        let first = await cache.image(for: url.path)
        XCTAssertNotNil(first)
        let second = await cache.image(for: url.path)
        XCTAssertTrue(first === second)
    }

    @MainActor
    func testDeletedFileDropsOutOfTheCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-tests-\(UUID().uuidString).png")
        try image(.png).write(to: url)
        let cache = ThumbnailCache()
        let cached = await cache.image(for: url.path)
        XCTAssertNotNil(cached)
        try FileManager.default.removeItem(at: url)
        let after = await cache.image(for: url.path)
        XCTAssertNil(after)
    }
}
