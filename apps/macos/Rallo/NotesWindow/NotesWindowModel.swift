import Combine
import Foundation

/// A transient message at the bottom of the window's list, optionally undoable.
struct WindowToast: Identifiable {
    let id = UUID()
    let message: String
    let undo: (() async -> Void)?
}

/// A folder the delete sheet (0019 §12) is asking about.
struct PendingFolderDelete: Identifiable {
    let folder: FolderSnapshot
    /// Open + done, nondeleted: the core's `note_count` (0019 §9), what `folder delete` calls "holds".
    var noteCount: Int { Int(folder.noteCount) }

    var id: String { folder.id }
}

/// The loaded pages of one list and how to get the next (0019 §9).
struct PagedItems {
    var items: [ItemSnapshot] = []
    var nextCursor: String?
    /// The whole list's length, however much of it has loaded.
    var totalCount = 0
    /// Pages fetched so far: a reload fetches as many again, so a note selected on page 3 stays loaded.
    var pages = 0

    var hasMore: Bool { nextCursor != nil }
}

/// The notes window's state (0019 §11): what the sidebar selected, what the
/// list shows, the open note, folder changes, and the reload that keeps all of
/// it in step with the change signal. Views read it; AppKit prompts and
/// panels stay out of it, so it runs against a real store in tests.
@MainActor
final class NotesWindowModel: ObservableObject {
    @Published private(set) var overview: FolderOverview?
    @Published private(set) var tags: [TagSnapshot] = []
    /// The selection's list: open notes for a folder, tag or All Notes; the
    /// whole view for Due, Done and Deleted.
    @Published private(set) var open = PagedItems()
    /// Done notes of the same folder or tag, behind the "N done" row.
    @Published private(set) var done = PagedItems()
    /// Search results, across every folder.
    @Published private(set) var found = PagedItems()
    @Published private(set) var selection: NotesWindowSelection = .scope(.all)
    @Published private(set) var selectedNoteID: String?
    /// The "New Note" row is showing.
    @Published private(set) var isDrafting = false
    @Published var query = ""
    @Published var doneExpanded = false
    @Published private(set) var toast: WindowToast?
    @Published var errorMessage: String?
    @Published var renamingFolderID: String?
    @Published var pendingFolderDelete: PendingFolderDelete?
    /// The Custom… reminder popover is open on the selected note.
    @Published var customRemindOpen = false

    let core: CoreClient
    let editor: NoteEditorSession
    /// The window's New Folder… card (0019 §10), drawn over the whole window (Task 11).
    let namePrompter = FolderNamePrompter()
    /// Rows per page (tests pass 2 to exercise paging).
    let pageSize: UInt32
    private var generation = 0
    /// The cursor being fetched, so a last row appearing twice doesn't load its page twice.
    private var loadingCursor: String?
    private var searchTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(core: CoreClient, saveDelay: TimeInterval = 0.6, pageSize: UInt32 = CoreClient.pageSize) {
        self.core = core
        self.pageSize = pageSize
        editor = NoteEditorSession(core: core, saveDelay: saveDelay)
        editor.onSaved = { [weak self] _ in Task { await self?.reload() } }
        editor.onCreated = { [weak self] note in self?.draftCreated(note) }
    }

    // MARK: What the window shows

    var items: [ItemSnapshot] { open.items }
    var doneItems: [ItemSnapshot] { done.items }
    var results: [ItemSnapshot] { found.items }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var visibleItems: [ItemSnapshot] { isSearching ? results : items }

    /// Every note the list has loaded, done ones included.
    private var loaded: [ItemSnapshot] { isSearching ? results : items + doneItems }

    func loadedItem(_ id: String) -> ItemSnapshot? { loaded.first { $0.id == id } }

    /// The open note: its row, or (once the row has left the list, say a tag edited out of it) the editor's copy.
    var selectedItem: ItemSnapshot? {
        selectedNoteID.flatMap { loadedItem($0) ?? (editor.note?.id == $0 ? editor.note : nil) }
    }

    var folders: [FolderSnapshot] { overview?.folders ?? [] }

    func folder(_ id: String) -> FolderSnapshot? { folders.first { $0.id == id } }

    /// "Notes" for no folder, else the folder's name.
    func folderName(_ id: String?) -> String {
        id.flatMap { folder($0)?.name } ?? "Notes"
    }

    struct Header: Equatable {
        let title: String
        let subtitle: String
    }

    /// Counts are the core's `totalCount`s: the whole list, never what has loaded.
    var header: Header {
        if isSearching { return Header(title: "Results", subtitle: Self.notes(found.totalCount)) }
        let openAndDone = "\(open.totalCount) open · \(done.totalCount) done"
        switch selection {
        case let .scope(scope):
            let title = switch scope {
            case .all: "All Notes"
            case .unfiled: "Notes"
            case let .folder(id): folderName(id)
            }
            return Header(title: title, subtitle: openAndDone)
        case let .tag(name): return Header(title: "#\(name)", subtitle: openAndDone)
        case .due: return Header(title: "Due", subtitle: Self.notes(open.totalCount))
        case .done: return Header(title: "Done", subtitle: Self.notes(open.totalCount))
        case .deleted: return Header(title: "Deleted", subtitle: Self.notes(open.totalCount))
        }
    }

    private static func notes(_ count: Int) -> String {
        "\(count) \(count == 1 ? "note" : "notes")"
    }

    /// Due has no date groups; the others group by a date (`groupTimestamp`).
    var listIsGrouped: Bool {
        if isSearching { return false }
        if case .due = selection { return false }
        return true
    }

    /// Open notes group by creation, Done by completion, Deleted by deletion.
    func groupTimestamp(_ item: ItemSnapshot) -> Int64 {
        switch selection {
        case .done: item.completedAtMs ?? item.updatedAtMs
        case .deleted: item.deletedAtMs ?? item.updatedAtMs
        default: item.createdAtMs
        }
    }

    /// New Note (⌘N) works in a folder, Notes, All Notes or a tag, not in
    /// Due, Done, Deleted or search results.
    var canCreateNote: Bool {
        if isSearching { return false }
        switch selection {
        case .scope, .tag: return true
        case .due, .done, .deleted: return false
        }
    }

    // MARK: Opening, selecting

    /// The window opened (or came forward): show `requested` (the panel's
    /// scope), reload, and select `noteID` if it's in the list.
    func opened(selection requested: NotesWindowSelection?, noteID: String?) async {
        if let requested, requested != selection {
            await select(requested)
        } else {
            await reload()
        }
        if let noteID, loadedItem(noteID) != nil { await selectNote(noteID) }
    }

    /// The window closed: save typing; an emptied note gets its text back, and
    /// an untouched "New Note" goes (one that got text was already created).
    func closed() async {
        namePrompter.cancel()
        toastTask?.cancel()
        toast = nil
        pendingFolderDelete = nil
        customRemindOpen = false
        renamingFolderID = nil
        if let message = await editor.leave() { errorMessage = message }
        if isDrafting {
            isDrafting = false
            editor.show(.none)
        }
    }

    func select(_ new: NotesWindowSelection) async {
        guard new != selection else { return }
        guard await letGoOfNote() else { return }
        selection = new
        query = ""
        open = PagedItems()
        done = PagedItems()
        found = PagedItems()
        doneExpanded = false
        await reload()
    }

    func selectNote(_ id: String?) async {
        guard id != selectedNoteID || isDrafting else { return }
        guard await letGoOfNote() else { return }
        selectedNoteID = id
        if let item = selectedItem { editor.show(.note(item)) } else { editor.show(.none) }
    }

    /// Saves typing and closes the editor's note; what couldn't be saved is said once.
    /// False (nothing changed) when the save hit a conflict or was refused: the
    /// bar or message shows and the note stays open. `force` is for a note that's gone.
    @discardableResult
    private func letGoOfNote(force: Bool = false) async -> Bool {
        if !force, !(await editor.readyToLeave()) { return false }
        if let message = await editor.leave() { errorMessage = message }
        isDrafting = false
        selectedNoteID = nil
        editor.show(.none)
        return true
    }

    // MARK: Reload

    /// Reads everything the window shows. Overlapping reloads settle on the
    /// newest, and a note being edited keeps its unsaved typing (the editor
    /// session decides). Each list fetches as many pages as it had loaded, so
    /// a note selected on a later page stays selected.
    func reload() async {
        generation += 1
        let mine = generation
        do {
            let overview = try await core.folderOverview()
            let tags = try await core.listTags()
            let target = SelectionFallback.resolve(
                selection, folderIDs: Set(overview.folders.map(\.id)), tagNames: Set(tags.map(\.name))
            )
            let keep = target == selection  // a fallback starts over on page 1
            let openList = try await fetch(pages: keep ? open.pages : 1) { try await page(target, done: false, cursor: $0) }
            var doneList = PagedItems()
            if Self.hasDoneList(target) {
                doneList = try await fetch(pages: keep ? done.pages : 1) { try await page(target, done: true, cursor: $0) }
            }
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            var foundList = PagedItems()
            if !text.isEmpty {
                foundList = try await fetch(pages: found.pages) { try await core.searchItems(text, cursor: $0, limit: pageSize) }
            }
            guard mine == generation else { return }
            self.overview = overview
            self.tags = tags
            if target != selection {
                selection = target
                doneExpanded = false
            }
            open = openList
            done = doneList
            found = foundList
            await syncSelectedNote()
        } catch {
            guard mine == generation else { return }
            errorMessage = "Couldn’t load notes: \(error.localizedDescription)"
        }
    }

    /// One page of the selection's list (`done`: the "N done" list of a folder,
    /// Notes, All Notes or tag). The core orders every list: newest first, Done
    /// by completion, Deleted by deletion, Due by deadline.
    private func page(_ selection: NotesWindowSelection, done: Bool, cursor: String?) async throws -> ItemPage {
        let kind: ItemListKind = done ? .done : .open
        switch selection {
        case let .scope(scope): return try await core.listItems(kind, scope: scope.folderScope, cursor: cursor, limit: pageSize)
        case let .tag(name): return try await core.listItems(kind, tag: name, cursor: cursor, limit: pageSize)
        case .due: return try await core.listItems(.due, cursor: cursor, limit: pageSize)
        case .done: return try await core.listItems(.done, cursor: cursor, limit: pageSize)
        case .deleted: return try await core.listItems(.deleted, cursor: cursor, limit: pageSize)
        }
    }

    /// Folders, Notes, All Notes and tags have the second "N done" list; Due, Done and Deleted don't.
    private static func hasDoneList(_ selection: NotesWindowSelection) -> Bool {
        switch selection {
        case .scope, .tag: true
        case .due, .done, .deleted: false
        }
    }

    /// `pages` pages (at least one) of one list, following the core's cursors.
    private func fetch(pages: Int, _ next: (String?) async throws -> ItemPage) async throws -> PagedItems {
        var loaded = PagedItems()
        var cursor: String?
        repeat {
            let got = try await next(cursor)
            loaded.items += got.items
            loaded.totalCount = Int(got.totalCount)
            loaded.pages += 1
            cursor = got.nextCursor
        } while cursor != nil && loaded.pages < max(1, pages)
        loaded.nextCursor = cursor
        return loaded
    }

    /// The last loaded row of a list came into view: its next page (0019 §9).
    /// `done` picks the "N done" list; while searching it's the results.
    func loadMore(done wantDone: Bool = false) async {
        let searching = isSearching  // the field can change while the page loads
        let list = searching ? found : (wantDone ? done : open)
        guard let cursor = list.nextCursor, cursor != loadingCursor else { return }
        loadingCursor = cursor
        defer { if loadingCursor == cursor { loadingCursor = nil } }
        let mine = generation
        do {
            let next: ItemPage
            if searching {
                let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
                next = try await core.searchItems(text, cursor: cursor, limit: pageSize)
            } else {
                next = try await page(selection, done: wantDone, cursor: cursor)
            }
            guard mine == generation, searching == isSearching else { return }  // the list was replaced meanwhile
            var updated = list
            updated.items += next.items
            updated.nextCursor = next.nextCursor
            updated.totalCount = Int(next.totalCount)
            updated.pages += 1
            if searching { found = updated } else if wantDone { done = updated } else { open = updated }
        } catch {
            await report(error)
        }
    }

    /// After a reload: the open note takes its latest state. A row that left the
    /// list (a tag edited out, a move, a search no longer matching) keeps the note
    /// open, so typing is never lost; only a note that's gone (or deleted, outside
    /// the Deleted view) clears the selection (0019 §11).
    private func syncSelectedNote() async {
        guard let id = selectedNoteID else { return }
        if let item = loadedItem(id) { editor.sync(item); return }
        let started = generation
        do {
            let latest = try await core.item(id)
            // The lookup is late if the user picked another note, or another reload landed, meanwhile.
            guard selectedNoteID == id, generation == started, loadedItem(id) == nil else { return }
            if latest.deletedAtMs != nil, selection != .deleted {
                await letGoOfNote(force: true)
            } else {
                editor.sync(latest)
            }
        } catch let error as RalloError {
            guard selectedNoteID == id, generation == started, loadedItem(id) == nil else { return }
            if case .NotFound = error { await letGoOfNote(force: true) }
        } catch {}
    }

    /// The note as the core has it, for the conflict bar's answers.
    private func latestItem(_ id: String) async -> ItemSnapshot? {
        if let item = loadedItem(id) { return item }
        return try? await core.item(id)
    }

    /// A debounced search: the field's text changed.
    func queryChanged() {
        searchTask?.cancel()
        // New words start over on page 1; the old results stay up until the new ones land.
        if isSearching { found.pages = 0 } else { found = PagedItems() }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    // MARK: Toasts and errors

    func announce(_ message: String, undo: (() async -> Void)? = nil) {
        errorMessage = nil
        toastTask?.cancel()
        toast = WindowToast(message: message, undo: undo)
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func undo() async {
        guard let undo = toast?.undo else { return }
        toastTask?.cancel()
        toast = nil
        await undo()
    }

    /// Runs one core change, then reloads; a failure reloads and says why.
    func run(_ work: (CoreClient) async throws -> Void) async {
        errorMessage = nil
        do {
            try await work(core)
            await reload()
        } catch {
            await report(error)
        }
    }

    func report(_ error: Error) async {
        await reload()
        if let error = error as? RalloError {
            if error.code == "REVISION_CONFLICT" {
                errorMessage = "That note changed elsewhere; here’s the latest."
            } else {
                errorMessage = error.displayMessage
            }
        } else {
            errorMessage = error.localizedDescription
        }
    }

    /// A note as the database has it now: typing is saved first, so a change
    /// made from the toolbar never trips over the editor's own revision.
    func fresh(_ item: ItemSnapshot) async -> ItemSnapshot {
        if item.id == editor.note?.id, editor.hasUnsavedText {
            await editor.flush()
            await reload()
        }
        let listed = loadedItem(item.id)
        // A save a moment ago may not have reached the list yet: the editor's copy is newer.
        if let saved = editor.note, saved.id == item.id, saved.revision > (listed?.revision ?? 0) { return saved }
        if let listed { return listed }
        // Off the list (moved out of the scope, deleted): the core still has it.
        return (try? await core.item(item.id)) ?? item
    }

    // MARK: A new note

    /// ⌘N: a "New Note" draft at the top of the list, selected, editor focused.
    func beginNewNote() async {
        guard canCreateNote else { return }
        guard await letGoOfNote() else { return }
        isDrafting = true
        let folderID: String? = if case let .scope(.folder(id)) = selection { id } else { nil }
        let seed = if case let .tag(name) = selection { "#\(name) " } else { "" }
        editor.show(.draft(folderID: folderID, seed: seed), focus: true)
    }

    /// The draft's first save created the note: select it.
    private func draftCreated(_ note: ItemSnapshot) {
        generation += 1  // a reload already running can't know the note
        isDrafting = false
        selectedNoteID = note.id
        Task { await reload() }
    }

    // MARK: Conflict bar

    /// Show Theirs: the note as it is now.
    func showTheirs() async {
        guard let id = editor.note?.id else { return }
        await reload()
        if let latest = await latestItem(id) { editor.showTheirs(latest) } else { await letGoOfNote() }
    }

    /// Keep Mine: the typed text saves again on the note's new revision.
    func keepMine() async {
        guard let id = editor.note?.id else { return }
        await reload()
        if let latest = await latestItem(id) { editor.keepMine(latest) } else { await letGoOfNote() }
    }

    // MARK: Folders

    /// "+ New Folder" and ⌘⇧N: creates "New Folder" (or "New Folder 2", …) and
    /// starts an inline rename. The local name is a guess; the core's
    /// `FOLDER_EXISTS` decides, and the next guess is tried.
    func newFolderInline() async {
        var name = FolderNaming.newFolderName(existing: folders.map(\.name))
        for _ in 0..<20 {
            do {
                let folder = try await core.createFolder(name)
                await select(.scope(.folder(folder.id)))
                renamingFolderID = folder.id
                return
            } catch let error as RalloError where error.code == "FOLDER_EXISTS" {
                await reload()  // someone else made it first (the CLI); try the next free name
                name = FolderNaming.newFolderName(existing: folders.map(\.name))
            } catch {
                await report(error)
                return
            }
        }
    }

    /// Inline rename. The core judges the name: a refusal shows its message
    /// and the field stays editable.
    func renameFolder(_ folder: FolderSnapshot, to name: String) async {
        do {
            _ = try await core.renameFolder(folder, to: name)
            renamingFolderID = nil
            errorMessage = nil
            await reload()
        } catch {
            await report(error)
        }
    }

    /// Delete Folder…: the sheet asks (0019 §12), counting `folder.noteCount`.
    func requestDelete(_ folder: FolderSnapshot) {
        pendingFolderDelete = PendingFolderDelete(folder: folder)
    }

    /// Keep Notes (`keepNotes`) files them in Notes; Delete Notes sends them to Deleted.
    func confirmDelete(_ pending: PendingFolderDelete, keepNotes: Bool) async {
        pendingFolderDelete = nil
        do {
            _ = try await core.deleteFolder(pending.folder.id, keepNotes: keepNotes)
            announce("Deleted “\(pending.folder.name)”")
            await reload()  // a deleted scope folder falls back to Notes
        } catch {
            await report(error)
        }
    }

    // MARK: Moving notes

    func move(_ item: ItemSnapshot, toFolder folderID: String?) async {
        let item = await fresh(item)
        guard item.folderId != folderID else { return }
        do {
            let moved = try await core.moveItem(item, folderID: folderID)
            let before = item.folderId
            announce("Moved to \(folderName(folderID))") { [weak self] in
                guard let self else { return }
                let latest = await self.fresh(moved)
                await self.run { _ = try await $0.moveItem(latest, folderID: before) }
            }
            await reload()
        } catch {
            await report(error)
        }
    }

    /// A note dragged onto a sidebar folder. Ids that aren't a nondeleted note in the list are ignored.
    func canDrop(_ ids: [String]) -> Bool { ids.contains { loadedItem($0).map { $0.deletedAtMs == nil } ?? false } }

    func drop(_ ids: [String], onto folderID: String?) async {
        guard let item = ids.compactMap(loadedItem).first(where: { $0.deletedAtMs == nil }) else { return }
        await move(item, toFolder: folderID)
    }
}
