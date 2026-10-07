import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Carried by every thumbnail drag: images dragged out of Rallo never attach to a note.
let ownDragType = "com.razlio.rallo.image"

/// An expanded note's images (0018): 56 pt thumbnails that open Quick Look,
/// drag out as files, and offer Copy Image, Show in Finder and Remove Image.
struct ImageStrip: View {
    let item: ItemSnapshot
    @ObservedObject var model: NotesViewModel
    @FocusState private var focused: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(item.images.enumerated()), id: \.element.id) { index, image in
                    RowThumbnail(image: image, label: "Image \(index + 1) of \(item.images.count), \(Self.kind(image))")
                        .focusable()
                        .focused($focused, equals: image.id)
                        .onKeyPress(.space) { open(index) }
                        .onKeyPress(.return) { open(index) }
                        .onKeyPress(.delete) { remove(image) }
                        .onKeyPress(.deleteForward) { remove(image) }
                        .onTapGesture { QuickLookPresenter.shared.show(item.images, at: index) }
                        .onDrag { Self.dragProvider(image, index: index) }
                        .contextMenu {
                            Button("Copy Image") { Self.copy(image) }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: image.path)])
                            }
                            Divider()
                            Button("Remove Image", role: .destructive) { Task { await model.removeImage(image, from: item) } }
                        }
                        .accessibilityAction { QuickLookPresenter.shared.show(item.images, at: index) }
                        .accessibilityAction(named: "Remove Image") { Task { await model.removeImage(image, from: item) } }
                }
            }
        }
        .frame(height: ThumbnailCache.points)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ImageStripFrameKey.self, value: proxy.frame(in: .named(ImageStripFrameKey.space)))
        })
        .onChange(of: focused) { _, id in model.thumbnailFocused = id != nil }
        .onDisappear { model.thumbnailFocused = false }
    }

    private func open(_ index: Int) -> KeyPress.Result {
        QuickLookPresenter.shared.show(item.images, at: index)
        return .handled
    }

    private func remove(_ image: ImageSnapshot) -> KeyPress.Result {
        Task { await model.removeImage(image, from: item) }
        return .handled
    }

    /// "PNG", "JPEG", "HEIC", "GIF", "WEBP" for VoiceOver.
    private static func kind(_ image: ImageSnapshot) -> String {
        image.mimeType.split(separator: "/").last.map { $0.uppercased() } ?? "image"
    }

    /// A file representation rather than the file's URL: whoever receives the
    /// drop gets a copy, so dropping on Finder can never move the file out of
    /// Rallo's data directory.
    private static func dragProvider(_ image: ImageSnapshot, index: Int) -> NSItemProvider {
        let url = URL(fileURLWithPath: image.path)
        let provider = NSItemProvider()
        provider.suggestedName = "Rallo image \(index + 1)"
        // Marks the drag as Rallo's own, so a row never re-attaches it.
        provider.registerDataRepresentation(forTypeIdentifier: ownDragType, visibility: .ownProcess) { completion in
            completion(Data(image.id.utf8), nil)
            return nil
        }
        let type = UTType(mimeType: image.mimeType) ?? .image
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    /// The image's bytes in its own format (for Slack, Mail, Preview) and its
    /// file URL (Finder pastes a copy).
    private static func copy(_ image: ImageSnapshot) {
        let url = URL(fileURLWithPath: image.path)
        guard let data = try? Data(contentsOf: url), let type = UTType(mimeType: image.mimeType) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        item.setString(url.absoluteString, forType: .fileURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }
}

private struct RowThumbnail: View {
    let image: ImageSnapshot
    let label: String
    @State private var thumbnail: NSImage?
    @State private var missing = false

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: missing ? "exclamationmark.triangle" : "photo")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.bark)
            }
        }
        .frame(width: ThumbnailCache.points, height: ThumbnailCache.points)
        .background(Theme.field)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.fieldStroke))
        .contentShape(Rectangle())
        .help(missing ? "This image’s file is missing. Run rallo doctor in Terminal." : "Click to preview")
        .task(id: image.path) {
            thumbnail = await ThumbnailCache.shared.image(for: image.path)
            missing = thumbnail == nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(missing ? "\(label), file missing" : label)
        .accessibilityAddTraits(.isButton)
    }
}
