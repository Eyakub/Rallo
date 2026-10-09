import SwiftUI

/// The window's left column (0019 §11): Folders (Notes first, then
/// alphabetical, each a drop target for notes), Views, and Tags.
struct FolderSidebar: View {
    @ObservedObject var model: NotesWindowModel

    private var selection: Binding<NotesWindowSelection?> {
        Binding(
            get: { model.selection },
            set: { new in
                if let new {
                    Task {
                        await model.select(new)
                        // A declined select (editor conflict) leaves `selection` alone; redraw so the row snaps back.
                        if model.selection != new { model.objectWillChange.send() }
                    }
                }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                FolderRow(model: model, folder: nil, count: Int(model.overview?.unfiledOpen ?? 0))
                    .tag(NotesWindowSelection.scope(.unfiled))
                ForEach(model.folders, id: \.id) { folder in
                    FolderRow(model: model, folder: folder, count: Int(folder.openCount))
                        .tag(NotesWindowSelection.scope(.folder(folder.id)))
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button {
                        Task { await model.newFolderInline() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("New Folder")
                    .accessibilityLabel("New Folder")
                }
            }
            Section("Views") {
                SidebarLabel(symbol: "tray.full", title: "All Notes", count: Int(model.overview?.allOpen ?? 0))
                    .tag(NotesWindowSelection.scope(.all))
                SidebarLabel(symbol: "bell", title: "Due", count: Int(model.overview?.due ?? 0))
                    .tag(NotesWindowSelection.due)
                SidebarLabel(symbol: "checkmark.circle", title: "Done", count: Int(model.overview?.done ?? 0))
                    .tag(NotesWindowSelection.done)
                SidebarLabel(symbol: "trash", title: "Deleted", count: Int(model.overview?.deleted ?? 0))
                    .tag(NotesWindowSelection.deleted)
            }
            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags, id: \.name) { tag in
                        SidebarLabel(hash: tag.name, count: Int(tag.openCount))
                            .tag(NotesWindowSelection.tag(tag.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private var footer: some View {
        Button {
            Task { await model.newFolderInline() }
        } label: {
            Label("New Folder", systemImage: "plus.circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.bark)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .help("New Folder (⇧⌘N)")
    }
}

/// One Views or Tags row: icon (or `#`), name, open count.
private struct SidebarLabel: View {
    var symbol: String?
    var hash: String?
    let title: String
    let count: Int

    init(symbol: String, title: String, count: Int) {
        self.symbol = symbol
        hash = nil
        self.title = title
        self.count = count
    }

    init(hash name: String, count: Int) {
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
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.bark)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Notes (`folder == nil`) or a folder. Rename is inline; a note dropped on
/// the row is filed in the folder.
private struct FolderRow: View {
    @ObservedObject var model: NotesWindowModel
    let folder: FolderSnapshot?
    let count: Int
    @State private var targeted = false
    @State private var name = ""
    @FocusState private var fieldFocused: Bool
    /// The field has held focus once, so a `false` is a loss, not the first appearance.
    @State private var hadFocus = false
    /// A rename is in flight: a second Return is ignored and the focus change it causes is not an abandon.
    @State private var submitting = false

    private var renaming: Bool { folder != nil && model.renamingFolderID == folder?.id }

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
                        model.errorMessage = nil
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
                Text(folder?.name ?? "Notes").lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.bark)
        }
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(targeted ? Theme.highlight : .clear))
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
        .accessibilityElement(children: renaming ? .contain : .combine)
    }
}
