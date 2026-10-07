import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Export and import from the menu bar (docs/decisions/0004). The core does
/// validation, classification, the pre-import snapshot, and the atomic
/// write; this only picks files and shows the result.
@MainActor
final class TransferController {
    private let core: CoreClient
    private let log: DiagnosticsLog
    private let model = TransferModel()
    private var panel: NSPanel?
    /// Opens the notes panel after a successful import.
    var onShowNotes: () -> Void = {}

    init(core: CoreClient, log: DiagnosticsLog) {
        self.core = core
        self.log = log
        model.onImport = { [weak self] url in Task { await self?.apply(url) } }
        model.onShowNotes = { [weak self] in
            self?.close()
            self?.onShowNotes()
        }
        model.onReveal = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        model.onClose = { [weak self] in self?.close() }
    }

    func export(_ format: TransferFormat) {
        NSApp.activate()
        let save = NSSavePanel()
        let date = Date().formatted(.iso8601.year().month().day())
        switch format {
        case .json:
            save.title = "Export Backup"
            save.nameFieldStringValue = "Rallo Backup \(date).json"
            save.allowedContentTypes = [.json]
        case .csv:
            save.title = "Export Spreadsheet"
            save.nameFieldStringValue = "Rallo Notes \(date).csv"
            save.allowedContentTypes = [.commaSeparatedText]
        case .zip:
            save.title = "Export Archive"
            save.nameFieldStringValue = "Rallo Archive \(date).zip"
            save.allowedContentTypes = [.zip]
        }
        save.canCreateDirectories = true
        save.level = .floating
        save.begin { [weak self] response in
            guard response == .OK, let url = save.url else { return }
            // The save panel has already asked before replacing a file.
            Task { await self?.write(url, format) }
        }
    }

    func importFile() {
        NSApp.activate()
        let open = NSOpenPanel()
        open.title = "Import Notes"
        open.message = "Choose a Rallo archive (.zip), backup (.json) or spreadsheet (.csv)."
        open.allowedContentTypes = [.zip, .json, .commaSeparatedText]
        open.allowsMultipleSelection = false
        open.canChooseDirectories = false
        open.level = .floating
        open.begin { [weak self] response in
            guard response == .OK, let url = open.url else { return }
            Task { await self?.preview(url) }
        }
    }

    private func write(_ url: URL, _ format: TransferFormat) async {
        do {
            let result = try await core.exportToFile(url.path, format: format, overwrite: true)
            log.record("export_completed", ["format": "\(format)", "items": result.items])
            show(.exported(result, URL(fileURLWithPath: result.path)))
        } catch {
            log.record("export_failed", ["error": "\(error)"])
            show(.failed("Couldn’t export your notes", Self.message(error)))
        }
    }

    private func preview(_ url: URL) async {
        do {
            let summary = try await core.previewImportFile(url.path)
            show(.review(summary, url))
        } catch {
            log.record("import_preview_failed", ["error": "\(error)"])
            show(.failed("Couldn’t read that file", Self.message(error)))
        }
    }

    private func apply(_ url: URL) async {
        model.stage = .importing
        do {
            let summary = try await core.applyImportFile(url.path)
            log.record("import_completed", ["new": summary.new, "identical": summary.identical])
            show(.imported(summary))
        } catch {
            log.record("import_failed", ["error": "\(error)"])
            show(.failed("Nothing was imported", Self.message(error)))
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? RalloError)?.displayMessage ?? error.localizedDescription
    }

    private func show(_ stage: TransferModel.Stage) {
        model.stage = stage
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let wasVisible = panel.isVisible
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // SwiftUI applies the new stage on the next pass; size to it then.
        DispatchQueue.main.async {
            guard let size = panel.contentView?.fittingSize else { return }
            panel.setContentSize(size)
            if !wasVisible { panel.center() }
        }
    }

    private func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Rallo"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: TransferView(model: model))
        return panel
    }
}

@MainActor
final class TransferModel: ObservableObject {
    enum Stage {
        case idle
        case exported(ExportResult, URL)
        case review(ImportSummary, URL)
        case importing
        case imported(ImportSummary)
        case failed(String, String)
    }

    @Published var stage: Stage = .idle
    var onImport: (URL) -> Void = { _ in }
    var onShowNotes: () -> Void = {}
    var onReveal: (URL) -> Void = { _ in }
    var onClose: () -> Void = {}
}

struct TransferView: View {
    @ObservedObject var model: TransferModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: Bundle.main.image(forResource: pose) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(Theme.rounded(18, .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    details
                }
                .padding(.top, 6)
            }
            buttons
                .padding(.top, 20)
        }
        .padding(.horizontal, 22)
        .padding(.top, 30)
        .padding(.bottom, 18)
        .frame(width: 380)
        .foregroundStyle(Theme.ink)
        .background(Theme.surface)
    }

    private var pose: String {
        switch model.stage {
        case .exported, .imported: "pet-celebrate"
        case .failed: "pet-nudge"
        case let .review(summary, _) where !summary.conflicts.isEmpty: "pet-nudge"
        default: "pet-idle"
        }
    }

    private var title: String {
        switch model.stage {
        case .idle: ""
        case let .exported(result, _): "Exported \(Self.notes(result.items))"
        case let .review(summary, _):
            if !summary.conflicts.isEmpty {
                "This file conflicts with your notes"
            } else if summary.new == 0 {
                "Nothing new to import"
            } else {
                "Import \(Self.notes(summary.new))?"
            }
        case .importing: "Importing…"
        case let .imported(summary): "Imported \(Self.notes(summary.new))"
        case let .failed(title, _): title
        }
    }

    @ViewBuilder
    private var details: some View {
        switch model.stage {
        case .idle, .importing:
            EmptyView()
        case let .exported(result, url):
            paragraph(url.lastPathComponent)
            ForEach(result.warnings, id: \.self) { warning in
                Text(warning).font(Theme.rounded(12)).foregroundStyle(Theme.bark)
            }
        case let .review(summary, url):
            if !summary.conflicts.isEmpty {
                paragraph("\(Self.records(summary.conflictTotal)) in \(url.lastPathComponent) share an ID with a note in Rallo but differ from it, so nothing will be imported.")
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(summary.conflicts.prefix(4).enumerated()), id: \.offset) { _, conflict in
                        Text(Self.describe(conflict))
                            .font(Theme.rounded(12))
                            .foregroundStyle(Theme.bark)
                    }
                }
            } else if summary.new == 0 {
                paragraph("All \(Self.notes(summary.identical)) in \(url.lastPathComponent) are already in Rallo.")
            } else {
                paragraph(summary.identical > 0
                     ? "From \(url.lastPathComponent). \(Self.notes(summary.identical)) already in Rallo will be skipped."
                     : "From \(url.lastPathComponent).")
                paragraph("Reminders come in switched off. Rallo keeps a copy of your current notes first.")
            }
            ForEach(summary.warnings, id: \.self) { warning in
                Text(warning).font(Theme.rounded(12)).foregroundStyle(Theme.bark)
            }
        case let .imported(summary):
            paragraph(summary.backupPath.map {
                "Your notes from before the import are saved in \(URL(fileURLWithPath: $0).lastPathComponent)."
            } ?? "")
        case let .failed(_, message):
            paragraph(message)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            Spacer()
            switch model.stage {
            case .idle, .importing:
                ProgressView().controlSize(.small)
            case let .exported(_, url):
                secondary("Show in Finder") { model.onReveal(url) }
                primary("Done") { model.onClose() }
            case let .review(summary, url) where summary.conflicts.isEmpty && summary.new > 0:
                secondary("Cancel") { model.onClose() }
                primary("Import \(Self.notes(summary.new))") { model.onImport(url) }
            case .review, .failed:
                primary("Done") { model.onClose() }
            case .imported:
                secondary("Done") { model.onClose() }
                primary("Show Notes") { model.onShowNotes() }
            }
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(Theme.rounded(13))
            .foregroundStyle(Theme.bark)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.rounded(13, .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.swipeSoon))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.rounded(13, .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.hover))
                .overlay(Capsule().strokeBorder(Theme.fieldStroke))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }

    private static func notes(_ count: some BinaryInteger) -> String {
        count == 1 ? "1 note" : "\(count) notes"
    }

    private static func records(_ count: some BinaryInteger) -> String {
        count == 1 ? "1 record" : "\(count) records"
    }

    private static func describe(_ conflict: ImportConflict) -> String {
        let place = conflict.line.map { "Line \($0)" } ?? conflict.index.map { "Record \($0 + 1)" } ?? "A record"
        return conflict.id.map { "\(place), ID \($0.prefix(8))…" } ?? place
    }
}
