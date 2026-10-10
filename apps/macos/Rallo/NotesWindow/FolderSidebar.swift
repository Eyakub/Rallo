import SwiftUI

/// The window's left column (0019 §11): Folders (Notes first, then
/// alphabetical, each a drop target for notes), Views, and Tags.
struct FolderSidebar: View {
    @ObservedObject var model: NotesWindowModel

    @FocusState private var focused: Bool
    @State private var pendingTarget: NotesWindowSelection?

    /// A declined select (editor conflict) leaves `selection` alone, so the highlight stays on the row that owns it.
    private func select(_ new: NotesWindowSelection) {
        focused = true
        Task { await model.select(new) }
    }

    private func move(_ direction: SidebarOrder.Direction, scroll: ScrollViewProxy) -> KeyPress.Result {
        guard model.renamingFolderID == nil else { return .ignored }
        // A held arrow must not start a second reload while the first select is in flight.
        guard pendingTarget == nil else { return .handled }
        let rows = SidebarOrder.rows(folderIDs: model.folders.map(\.id), tagNames: model.tags.map(\.name))
        guard let next = SidebarOrder.next(after: model.selection, in: rows, direction: direction) else { return .handled }
        pendingTarget = next
        focused = true
        Task {
            await model.select(next)
            pendingTarget = nil
            if model.selection == next { scroll.scrollTo(next) }
        }
        return .handled
    }

    var body: some View {
        // The sidebar draws selection itself: the native List highlight is a solid accent fill
        // and can't be a soft wash.
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                List {
                    Section {
                        FolderRow(model: model, folder: nil, count: Int(model.overview?.unfiledOpen ?? 0), focused: focused, select: select)
                        ForEach(model.folders, id: \.id) { folder in
                            FolderRow(model: model, folder: folder, count: Int(folder.openCount), focused: focused, select: select)
                        }
                    } header: {
                        Text("Folders")
                    }
                    Section("Views") {
                        SidebarLabel(model: model, tag: .scope(.all), focused: focused, select: select, symbol: "tray.full", title: "All Notes", count: Int(model.overview?.allOpen ?? 0))
                        SidebarLabel(model: model, tag: .due, focused: focused, select: select, symbol: "bell", title: "Due", count: Int(model.overview?.due ?? 0))
                        SidebarLabel(model: model, tag: .done, focused: focused, select: select, symbol: "checkmark.circle", title: "Done", count: Int(model.overview?.done ?? 0))
                        SidebarLabel(model: model, tag: .deleted, focused: focused, select: select, symbol: "trash", title: "Deleted", count: Int(model.overview?.deleted ?? 0))
                    }
                    if !model.tags.isEmpty {
                        Section("Tags") {
                            ForEach(model.tags, id: \.name) { tag in
                                SidebarLabel(model: model, tag: .tag(tag.name), focused: focused, select: select, hash: tag.name, count: Int(tag.openCount))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { move(.up, scroll: scroll) }
                .onKeyPress(.downArrow) { move(.down, scroll: scroll) }
                }
            // Stacked, not an inset: the list ends where the footer starts, so no row scrolls under it.
            footer
        }
        // One material for the whole column, so the list and footer read as one surface.
        .background(SidebarMaterial().ignoresSafeArea())
        // The titlebar is transparent, so rows would scroll under the traffic lights; this
        // band of the same material (as tall as the safe-area inset) keeps that strip clean.
        .overlay(alignment: .top) {
            GeometryReader { proxy in
                SidebarMaterial()
                    .frame(height: proxy.safeAreaInsets.top)
                    .offset(y: -proxy.safeAreaInsets.top)
            }
            // Drawn above its own bounds on purpose; clicks pass through to the
            // sidebar toggle and the window's drag area.
            .allowsHitTesting(false)
        }
    }

    private var footer: some View {
        Button {
            Task { await model.newFolderInline() }
        } label: {
            // Same 18 pt icon column, 8 pt gap and 12 pt count font as the rows above, so glyph, title and hint line up with them.
            HStack(spacing: 8) {
                Image(systemName: "plus.circle").frame(width: 18)
                Text("New Folder")
                Spacer(minLength: 4)
                Text("⇧⌘N")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.bark)
        }
        .buttonStyle(.plain)
        // Measured against the rows: content sits 13 pt in on the left and 20 pt on the right.
        .padding(.leading, 13)
        .padding(.trailing, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .help("New Folder (⇧⌘N)")
    }
}

/// The sidebar's material, drawn once behind the whole column.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        NSVisualEffectView(frame: .zero).configured()
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private extension NSVisualEffectView {
    func configured() -> Self {
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        return self
    }
}

/// One Views or Tags row: icon (or `#`), name, open count.
private struct SidebarLabel: View {
    @ObservedObject var model: NotesWindowModel
    let tag: NotesWindowSelection
    let focused: Bool
    let select: (NotesWindowSelection) -> Void
    var symbol: String?
    var hash: String?
    let title: String
    let count: Int

    init(model: NotesWindowModel, tag: NotesWindowSelection, focused: Bool, select: @escaping (NotesWindowSelection) -> Void, symbol: String, title: String, count: Int) {
        self.model = model
        self.tag = tag
        self.focused = focused
        self.select = select
        self.symbol = symbol
        hash = nil
        self.title = title
        self.count = count
    }

    init(model: NotesWindowModel, tag: NotesWindowSelection, focused: Bool, select: @escaping (NotesWindowSelection) -> Void, hash name: String, count: Int) {
        self.model = model
        self.tag = tag
        self.focused = focused
        self.select = select
        symbol = nil
        hash = name
        title = name
        self.count = count
    }

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(Theme.rust).frame(width: 18)
            } else {
                Text("#").fontWeight(.bold).foregroundStyle(Theme.rust).frame(width: 18)
            }
            Text(title).lineLimit(1).fontWeight(selected ? .semibold : .regular).foregroundStyle(Theme.ink)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.bark)
        }
        .sidebarRow(tag: tag, selected: selected, focused: focused, select: select)
        .sidebarRowChrome(tag: tag)
    }

    private var selected: Bool { model.selection == tag }
}

/// Notes (`folder == nil`) or a folder. Rename is inline; a note dropped on
/// the row is filed in the folder.
private struct FolderRow: View {
    @ObservedObject var model: NotesWindowModel
    let folder: FolderSnapshot?
    let count: Int
    let focused: Bool
    let select: (NotesWindowSelection) -> Void
    @State private var targeted = false
    @State private var name = ""
    @FocusState private var fieldFocused: Bool
    /// The field has held focus once, so a `false` is a loss, not the first appearance.
    @State private var hadFocus = false
    /// A rename is in flight: a second Return is ignored and the focus change it causes is not an abandon.
    @State private var submitting = false

    private var renaming: Bool { folder != nil && model.renamingFolderID == folder?.id }
    private var tag: NotesWindowSelection { .scope(folder.map { .folder($0.id) } ?? .unfiled) }
    private var selected: Bool { model.selection == tag }

    /// Submits the typed name. Return keeps a refused field editable; a click-away has no
    /// field to keep, so a refusal ends the rename and leaves the core's message in the banner.
    private func commit(_ folder: FolderSnapshot, endOnRefusal: Bool) {
        guard !submitting else { return }
        submitting = true
        Task {
            let renamed = await model.renameFolder(folder, to: name)
            submitting = false
            if !renamed, endOnRefusal, model.renamingFolderID == folder.id { model.renamingFolderID = nil }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(Theme.rust).frame(width: 18)
            if renaming, let folder {
                TextField("Folder name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit {
                        commit(folder, endOnRefusal: false)
                    }
                    .onExitCommand {
                        model.renamingFolderID = nil
                        model.clearError()
                    }
                    .onAppear {
                        name = folder.name
                        hadFocus = false
                        fieldFocused = true
                    }
                    // Select the name once the field really has focus (selecting from
                    // onAppear races the focus change and can land nowhere).
                    .onChange(of: fieldFocused) { _, focused in
                        if focused {
                            hadFocus = true
                            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                        } else if hadFocus, !submitting, model.renamingFolderID == folder.id {
                            // Clicked elsewhere: a changed name commits like Return (Esc cancels first by
                            // clearing `renamingFolderID`, so its own focus loss lands here as a no-op).
                            hadFocus = false
                            if name.trimmingCharacters(in: .whitespacesAndNewlines) == folder.name {
                                model.renamingFolderID = nil
                            } else {
                                commit(folder, endOnRefusal: true)
                            }
                        }
                    }
                    .accessibilityLabel("Folder name")
            } else {
                Text(folder?.name ?? "Notes").lineLimit(1).fontWeight(selected ? .semibold : .regular).foregroundStyle(Theme.ink)
            }
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.bark)
        }
        .sidebarRow(tag: tag, selected: selected, focused: focused, targeted: targeted, enabled: !renaming, select: select)
        // After the row's padding and fill, so the whole washed rect is the drop target and menu anchor.
        .dropDestination(for: String.self) { ids, _ in
            guard model.canDrop(ids) else { return false }  // an unknown id is ignored
            Task { await model.drop(ids, onto: folder?.id) }
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            if let folder {
                Button("Rename") { model.renamingFolderID = folder.id }
                Divider()
                Button("Delete Folder…", role: .destructive) { model.requestDelete(folder) }
            }
        }
        .sidebarRowChrome(tag: tag)
    }
}

private extension View {
    /// The soft rust wash, the click-to-select and the button semantics of one sidebar row.
    /// `enabled` is off while the row hosts the inline rename field, which keeps its own clicks.
    @ViewBuilder
    func sidebarRow(
        tag: NotesWindowSelection, selected: Bool, focused: Bool, targeted: Bool = false, enabled: Bool = true,
        select: @escaping (NotesWindowSelection) -> Void
    ) -> some View {
        // The sidebar list indents rows ~12 pt past its headers, so `sidebarRowChrome` pulls them back; this padding places the icon level with the section header text.
        let row = padding(.leading, 5)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(targeted ? Theme.selection : selected ? (focused ? Theme.selection : Theme.selectionSoft) : .clear)
            )
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded { select(tag) }, including: enabled ? .all : .subviews)
        if enabled {
            row.accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { select(tag) }
        } else {
            row.accessibilityElement(children: .contain)
        }
    }

    /// List-level chrome; applied last so it sits outside the drop target and context menu.
    func sidebarRowChrome(tag: NotesWindowSelection) -> some View {
        listRowBackground(Color.clear)
            .id(tag)
            // Negative: undoes the sidebar style's built-in ~12 pt indent, so with
            // `sidebarRow`'s padding the icons line up with the section headers.
            .listRowInsets(EdgeInsets(top: 1, leading: -8, bottom: 1, trailing: -4))
    }
}
