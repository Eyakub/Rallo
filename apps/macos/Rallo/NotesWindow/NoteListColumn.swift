
import AppKit
import SwiftUI

/// The middle column (0019 §11): the scope's name and counts, notes grouped by
/// date, a collapsed "N done" row, the Undo toast, and the Delete and New Note
/// toolbar buttons. ⌘N lives in the File menu, ⌫ and the arrow keys here.
struct NoteListColumn: View {
    @ObservedObject var model: NotesWindowModel
    @FocusState private var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasDoneRow: Bool { !model.isSearching && model.done.totalCount > 0 }

    private var isEmpty: Bool { model.visibleItems.isEmpty && !model.isDrafting && !hasDoneRow }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isEmpty { emptyState } else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastBar(message: toast.message, undoable: toast.undo != nil, undoShortcut: false) { Task { await model.undo() } }
                    .id(toast.id)
                    .padding(12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.toast?.id)
        .toolbar { toolbar }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.header.title)
                .font(Theme.rounded(20, .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Text(model.header.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.bark)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        let text: String = if model.isSearching {
            "No results"
        } else {
            switch model.selection {
            case .deleted: "Nothing deleted"
            case .done: "Nothing done yet"
            case .due: "No reminders waiting"
            default: "No notes here yet"
            }
        }
        return Text(text)
            .font(Theme.rounded(14, .medium))
            .foregroundStyle(Theme.bark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sections: [DateSection<ItemSnapshot>] {
        DateGrouping.sections(model.visibleItems, timestampMs: model.groupTimestamp, now: .now, calendar: .current)
    }

    /// The rows in the order they are drawn, for the arrow keys.
    private var order: [ItemSnapshot] {
        model.visibleItems + (model.doneExpanded && hasDoneRow ? model.doneItems : [])
    }

    private var list: some View {
        ScrollViewReader { proxy in
            listBody
                .onKeyPress(.upArrow) { step(-1, proxy) }
                .onKeyPress(.downArrow) { step(1, proxy) }
        }
    }

    private var listBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.isDrafting { DraftRow().id("draft") }
                if model.listIsGrouped {
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(Theme.rounded(11.5, .bold))
                            .foregroundStyle(Theme.bark)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.elements, id: \.id) { row($0, dimmed: false) }
                    }
                } else {
                    ForEach(model.visibleItems, id: \.id) { row($0, dimmed: false) }
                }
                sentinel(model.isSearching ? model.found : model.open, done: false)
                if hasDoneRow {
                    doneRow
                    if model.doneExpanded {
                        ForEach(model.doneItems, id: \.id) { row($0, dimmed: true) }
                        sentinel(model.done, done: true)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, model.toast == nil ? 8 : 64)
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: Self.deleteKeys) { _ in deleteSelected() }
    }

    private func row(_ item: ItemSnapshot, dimmed: Bool) -> some View {
        NoteListRow(
            item: item, selected: !model.isDrafting && model.selectedNoteID == item.id, dimmed: dimmed, listFocused: listFocused, model: model
        )
        .id(item.id)
        .onTapGesture { open(item) }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(item) }
    }

    private func open(_ item: ItemSnapshot) {
        Task {
            await model.selectNote(item.id)
            // A declined switch (a conflict bar) leaves the keyboard where it was.
            if model.selectedNoteID == item.id { listFocused = true }
        }
    }

    /// Below a list's rows: when it comes into view the list's next page loads (0019 §9).
    /// Keyed on the cursor and the reload generation, so a page that was dropped or failed re-arms it.
    @ViewBuilder
    private func sentinel(_ list: PagedItems, done: Bool) -> some View {
        if let cursor = list.nextCursor {
            Color.clear.frame(height: 1)
                .id("more-\(done)-\(cursor)-\(model.generation)")
                .onAppear { Task { await model.loadMore(done: done) } }
        }
    }

    /// "N done": collapsed by default; expanding shows the scope's finished notes, dimmed.
    private var doneRow: some View {
        Button {
            model.doneExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(model.doneExpanded ? 90 : 0))
                Text("\(model.done.totalCount) done")
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.bark)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .padding(.top, 10)
        .padding(.horizontal, 6)
        .accessibilityLabel("\(model.done.totalCount) done")
        .accessibilityValue(model.doneExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides the finished notes")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if case .deleted = model.selection {
                Button {
                    if let item = model.selectedItem { Task { await model.restore(item) } }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .disabled(model.selectedItem == nil)
                .help("Restore")
            } else {
                Button {
                    if let item = model.selectedItem { Task { await model.delete(item) } }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(model.selectedItem == nil)
                .help("Delete")
            }
            Button {
                Task { await model.beginNewNote() }
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .disabled(!model.canCreateNote)
            .help("New Note (⌘N)")
        }
    }

    // MARK: Keys

    private func step(_ delta: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = order.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let current = model.selectedNoteID.flatMap { ids.firstIndex(of: $0) }
        let next = current.map { min(max($0 + delta, 0), ids.count - 1) } ?? (delta > 0 ? 0 : ids.count - 1)
        let target = ids[next]
        Task {
            await model.selectNote(target)
            guard model.selectedNoteID == target else { return }
            // Minimal scroll: nothing moves when the row is already in view.
            if reduceMotion { proxy.scrollTo(target) } else { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target) } }
        }
        return .handled
    }

    /// The Mac's ⌫ sends U+007F, not the U+0008 behind `KeyEquivalent.delete`.
    private static let deleteKeys: Set<KeyEquivalent> = [.delete, .deleteForward, KeyEquivalent("\u{7F}")]

    /// ⌫ in the list deletes the selected note; Deleted offers Restore, no delete.
    private func deleteSelected() -> KeyPress.Result {
        if case .deleted = model.selection { return .ignored }
        guard let item = model.selectedItem else { return .ignored }
        Task { await model.delete(item) }
        return .handled
    }
}

/// The "New Note" row at the top while a draft is open.
private struct DraftRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(Theme.rust)
                .frame(width: 26, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("New Note").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Start typing…").font(.system(size: 12)).foregroundStyle(Theme.bark)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.highlight))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New Note, not saved yet")
    }
}

/// One note in the list: completion circle, title, then the time (or the
/// reminder) and a body preview, with the first image as a 38 pt thumbnail.
private struct NoteListRow: View {
    let item: ItemSnapshot
    let selected: Bool
    let dimmed: Bool
    let listFocused: Bool
    @ObservedObject var model: NotesWindowModel
    @State private var hovering = false

    private let text: RowText

    init(item: ItemSnapshot, selected: Bool, dimmed: Bool, listFocused: Bool, model: NotesWindowModel) {
        self.item = item
        self.listFocused = listFocused
        self.selected = selected
        self.dimmed = dimmed
        self.model = model
        text = RowText(item.text)
    }
    private var isDone: Bool { item.status == .done }
    private var isDeleted: Bool { item.deletedAtMs != nil }
    private var date: Date { Date(timeIntervalSince1970: TimeInterval(model.groupTimestamp(item)) / 1000) }

    private var activeReminder: ReminderSnapshot? {
        guard let reminder = item.reminder, reminder.state == .active else { return nil }
        return reminder
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(text.displayTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(text.title.isEmpty ? Theme.bark : Theme.ink)
                    .lineLimit(1)
                meta
            }
            Spacer(minLength: 0)
            if let image = item.images.first { ListThumbnail(path: image.path) }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? (listFocused ? Theme.selection : Theme.selectionSoft) : (hovering ? Theme.hover : .clear))
        )
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .modifier(DragIfLive(id: item.id, enabled: !isDeleted))
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// What the row shows: the title, then the reminder or time, then the preview.
    private var accessibilityText: String {
        var parts = [text.displayTitle]
        if let reminder = activeReminder {
            parts.append("Reminder " + ReminderLabel.text(for: reminder.deadline))
        } else {
            parts.append(RowTimeLabel.text(for: date, now: .now, calendar: .current))
        }
        if !text.preview.isEmpty { parts.append(text.preview) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var leading: some View {
        if isDeleted {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(Theme.bark)
                .frame(width: 26, height: 22)
                .accessibilityHidden(true)
        } else if isDone {
            Button {
                Task { await model.toggleDone(item) }
            } label: {
                ZStack {
                    Circle().fill(Theme.bamboo)
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white)
                }
                .frame(width: 18, height: 18)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reopen")
            .accessibilityLabel("Reopen “\(item.name)”")
        } else {
            CompletionButton(completing: false) { Task { await model.toggleDone(item) } }
                .accessibilityLabel("Mark “\(item.name)” as done")
        }
    }

    private var meta: some View {
        HStack(spacing: 5) {
            if let reminder = activeReminder {
                Image(systemName: "bell")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.rust)
                Text(Self.capitalized(ReminderLabel.text(for: reminder.deadline)))
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.rust)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text(RowTimeLabel.text(for: date, now: .now, calendar: .current))
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            if !text.preview.isEmpty {
                Text(text.preview)
                    .foregroundStyle(Theme.bark)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 12))
    }

    private static func capitalized(_ string: String) -> String {
        string.prefix(1).uppercased() + string.dropFirst()
    }

    @ViewBuilder
    private var menu: some View {
        if isDeleted {
            Button("Restore") { Task { await model.restore(item) } }
        } else {
            Button(isDone ? "Reopen" : "Mark as Done") { Task { await model.toggleDone(item) } }
            Menu("Remind Me") {
                RemindMenuItems(
                    onPreset: { preset in Task { await model.remind(item, preset) } },
                    onCustom: {
                        Task {
                            await model.selectNote(item.id)
                            // A fresh conflict bar can decline the switch: then the popover would hit the wrong note.
                            guard model.selectedNoteID == item.id else { return }
                            model.customRemindOpen = true
                        }
                    }
                )
            }
            Menu("Move to") {
                FolderMoveMenu(
                    currentFolderID: item.folderId,
                    folders: model.folders,
                    onMove: { id in Task { await model.move(item, toFolder: id) } },
                    onNewFolder: { Task { await WindowFolderPrompt.newFolder(for: item, model: model) } }
                )
            }
            Divider()
            Button("Copy Text") { copy(item.text) }
            Button("Copy ID for the Terminal") { copy(item.id) }
            Divider()
            Button("Delete", role: .destructive) { Task { await model.delete(item) } }
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// The first image, 38 pt on the right of a row.
private struct ListThumbnail: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(Theme.bark)
            }
        }
        .frame(width: 38, height: 38)
        .background(Theme.field)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: path) { image = await ThumbnailCache.shared.image(for: path, points: 38) }
        .accessibilityHidden(true)
    }
}

/// Deleted notes can't be dragged into a folder.
private struct DragIfLive: ViewModifier {
    let id: String
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled { content.draggable(id) } else { content }
    }
}
