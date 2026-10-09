import SwiftUI

/// A transient confirmation at the bottom of the panel, optionally undoable.
struct Toast: Identifiable {
    enum Undo {
        case reopen(ItemSnapshot)
        case restore(ItemSnapshot)
        case reattach(ItemSnapshot, Data)
        /// The note as moved, and the folder it came from (nil = Notes).
        case move(ItemSnapshot, backTo: String?)
    }

    let id = UUID()
    let message: String
    let undo: Undo?
}

/// An image waiting in the note field (0018).
struct StagedImage: Identifiable {
    let id = UUID()
    let data: Data
    let thumbnail: NSImage?
}

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var items: [ItemSnapshot] = []
    @Published var agentSessions: [AgentSessionSnapshot] = []
    @Published var draft = ""
    @Published var stagedImages: [StagedImage] = []
    @Published var errorMessage: String?
    /// A failed Services save (0017); reload() leaves it alone.
    @Published var captureError: String?
    @Published var highlightedItemID: String?
    @Published var completingIDs: Set<String> = []
    /// The last panel action: done, deleted, moved and a removed image can be undone.
    @Published var toast: Toast?
    /// At most one row shows its full text; at most one is being edited.
    @Published var expandedID: String?
    @Published var editingID: String?
    @Published var editDraft = ""
    /// The note whose "Custom…" reminder popover is open (0016).
    @Published var customRemindID: String?
    @Published var focusToken = 0
    /// The folder the panel shows and files new notes into (0019 §10). It is
    /// All Notes again if that folder is gone (see `reload`).
    @Published private(set) var scope: NotesScope
    /// Folders and counts from the core, refreshed with every reload.
    @Published private(set) var overview: FolderOverview?
    /// The New Folder dialog (and Rename, in the window later).
    let namePrompter = FolderNamePrompter()
    /// The New Folder dialog is up: the panel behind it takes no focus or clicks.
    @Published private(set) var namePromptShown = false
    /// The folder dropdown under the chip is showing.
    @Published var scopeMenuOpen = false
    /// Swipe state: at most one row shows a tray; `liveSwipe` follows the
    /// pointer or fingers while a swipe is in progress.
    @Published var openSwipe: OpenSwipe?
    @Published var liveSwipe: (id: String, offset: CGFloat)?
    var hoveredID: String?
    /// A row thumbnail has keyboard focus and handles Space itself.
    var thumbnailFocused = false
    var rowWidth: CGFloat = 340
    @Published var authorization: NotificationAuthorization?
    /// Asks for permission (never asked yet) or opens System Settings (denied).
    var onEnableNotifications: () -> Void = {}
    /// The title bar's expand button: close the panel, open the Notes window (0019 §11).
    var onExpand: () -> Void = {}

    /// Reminders exist but macOS won't show their alerts.
    var alertsBlocked: Bool {
        guard authorization == .denied || authorization == .notDetermined else { return false }
        return items.contains { $0.reminder?.state == .active }
    }

    private let core: CoreClient
    private let defaults: UserDefaults
    private var highlightTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(core: CoreClient, defaults: UserDefaults = .standard) {
        self.core = core
        self.defaults = defaults
        scope = NotesScope.load(from: defaults)
        namePrompter.$request.map { $0 != nil }.removeDuplicates().assign(to: &$namePromptShown)
    }

    var folders: [FolderSnapshot] { overview?.folders ?? [] }
    var scopeTitle: String { scope.title(in: folders) }

    /// "5 open notes": the core's count, so it also holds past the list's 50-note limit.
    var scopeCountLine: String {
        NotesScope.countLine(open: overview.map { scope.openCount(in: $0) } ?? items.count)
    }

    var composerPlaceholder: String { scope.placeholder(in: folders, hasNotes: !items.isEmpty) }

    /// On All Notes each row names its folder; inside a folder it would only repeat the chip.
    var showsFolderLabel: Bool { scope == .all }

    func requestFocus() {
        focusToken += 1
    }

    /// Highlights a row briefly (a just-saved note, or the item a
    /// notification pointed at), then lets it settle back.
    func highlight(_ id: String?, for seconds: Double = 2) {
        highlightTask?.cancel()
        highlightedItemID = id
        guard id != nil else { return }
        highlightTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.highlightedItemID = nil
        }
    }

    func toggleExpanded(_ item: ItemSnapshot) {
        if expandedID == item.id {
            expandedID = nil
            editingID = nil
        } else {
            expandedID = item.id
            editingID = nil
        }
    }

    func beginEditing(_ item: ItemSnapshot) {
        expandedID = item.id
        editDraft = item.text
        editingID = item.id
    }

    func cancelEditing() {
        editingID = nil
    }

    func saveEdit(_ item: ItemSnapshot) async {
        let text = editDraft
        // An image note's caption can be cleared; a text-only note can't be empty.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !item.images.isEmpty else { return }
        do {
            let updated = try await core.editItemText(item, text: text)
            editingID = nil
            await reload()
            highlight(updated.id)
        } catch let error as RalloError {
            if case let .Conflict(code, _) = error, code == "REVISION_CONFLICT" {
                errorMessage = "That note changed elsewhere; here’s the latest. Your edit wasn’t saved."
                editingID = nil
            } else {
                errorMessage = error.displayMessage
            }
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func swipeOffset(for id: String) -> CGFloat {
        if let live = liveSwipe, live.id == id { return live.offset }
        return SwipeMetrics.restingOffset(openSwipe?.id == id ? openSwipe?.side : nil)
    }

    func trackSwipe(_ id: String, offset: CGFloat) {
        if let open = openSwipe, open.id != id { openSwipe = nil }
        liveSwipe = (id, SwipeMetrics.rubberBanded(offset, rowWidth: rowWidth))
    }

    /// Settles a released swipe: open a tray, close it, or — pulled far
    /// enough left — delete (undoable).
    func endSwipe(_ item: ItemSnapshot, offset: CGFloat, projected: CGFloat) {
        let settled = SwipeMetrics.rubberBanded(offset, rowWidth: rowWidth)
        if settled <= -rowWidth * SwipeMetrics.fullDeleteFraction {
            liveSwipe = (item.id, -rowWidth)
            openSwipe = nil
            Task { await delete(item) }
            return
        }
        let target = abs(projected - offset) > abs(settled) ? projected : settled
        let side: SwipeSide? = if target > SwipeMetrics.remindWidth / 3 {
            .remind
        } else if target < -SwipeMetrics.deleteWidth / 2 {
            .delete
        } else {
            nil
        }
        openSwipe = side.map { OpenSwipe(id: item.id, side: $0) }
        liveSwipe = nil
    }

    /// Esc steps back one level: the New Folder dialog, the folder dropdown,
    /// staged images, a swipe tray, editing, then collapse, then close. Returns whether it handled the key.
    func handleEscape() -> Bool {
        if namePrompter.request != nil {
            namePrompter.cancel()
            requestFocus()
            return true
        }
        if scopeMenuOpen {
            closeScopeMenu()
            return true
        }
        if !stagedImages.isEmpty {
            stagedImages = []
            return true
        }
        if openSwipe != nil {
            openSwipe = nil
            return true
        }
        if editingID != nil {
            editingID = nil
            return true
        }
        if expandedID != nil {
            expandedID = nil
            return true
        }
        return false
    }

    func reload() async {
        let requested = scope
        do {
            let overview = try await core.folderOverview()
            let shown = requested.resolved(in: overview.folders)
            let listed = try await core.openItems(scope: shown.folderScope)
            agentSessions = try await core.agentSessions()
            authorization = try await core.notificationAuthorization()
            // If setScope ran meanwhile, its own reload owns the overview and list.
            if scope == requested {
                self.overview = overview
                if shown != requested {
                    // The folder was deleted (maybe by the CLI): back to All Notes.
                    scope = shown
                    shown.save(to: defaults)
                }
                items = listed
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t load notes: \(error.localizedDescription)"
        }
    }

    /// Highlights a note a notification pointed at. If the panel's folder
    /// doesn't hold it, shows All Notes so it can be seen.
    func reveal(_ id: String?) async {
        // Highlight last: the list scrolls to the highlighted row, which must be in it by then.
        if let id, scope != .all {
            await reload()
            if !items.contains(where: { $0.id == id }) { await setScope(.all) }
        }
        highlight(id, for: 4)
    }

    /// The panel went away: nothing it was showing may stay half-open.
    func panelDidHide() {
        scopeMenuOpen = false
        namePrompter.cancel()
    }

    /// Closes the dropdown and hands the keyboard back to the note field.
    func closeScopeMenu(refocus: Bool = true) {
        scopeMenuOpen = false
        if refocus { requestFocus() }
    }

    func setScope(_ new: NotesScope) async {
        guard new != scope else { return }
        scope = new
        new.save(to: defaults)
        expandedID = nil
        editingID = nil
        openSwipe = nil
        await reload()
    }

    /// New Folder… (0019 §10): asks for a name, creates the folder, then hands
    /// it to `use`. The core validates the name, so its own error stays in the dialog.
    private func askForFolder(then use: (FolderSnapshot) async -> Void) async {
        var created: FolderSnapshot?
        _ = await namePrompter.ask(title: "New Folder", initial: "", confirmTitle: "Create") { [core] name in
            created = try await core.createFolder(name)
        }
        // Every exit (Create, Cancel, backdrop) leaves the keyboard in the note field.
        requestFocus()
        if let created { await use(created) }
    }

    /// The chip's New Folder…: create it and switch to it.
    func newFolderAndSwitch() async {
        await askForFolder { await setScope(.folder($0.id)) }
    }

    /// Move to (0019 §10). The toast's Undo moves it back; a note already in
    /// that folder (the menu disables it) is not announced.
    func move(_ item: ItemSnapshot, to folderID: String?) async {
        do {
            let moved = try await core.moveItem(item, folderID: folderID)
            if moved.revision != item.revision {
                show(Toast(message: "Moved to \(moved.folderName ?? "Notes")", undo: .move(moved, backTo: item.folderId)))
            }
            if scope != .all {
                // The row leaves the list: drop its swipe tray and edit state, as delete() does.
                if openSwipe?.id == item.id { openSwipe = nil }
                if liveSwipe?.id == item.id { liveSwipe = nil }
                if expandedID == item.id { expandedID = nil }
                if editingID == item.id { editingID = nil }
            }
            await reload()
            highlight(moved.id)
        } catch {
            await report(error)
        }
    }

    /// The row menu's New Folder…: create it, then move the note into it. The
    /// panel keeps its scope (inside a folder scope the row leaves the list).
    func newFolder(moving item: ItemSnapshot) async {
        await askForFolder { await move(item, to: $0.id) }
    }

    /// Brings the session's terminal app forward; a no-op if Rallo couldn't
    /// identify one (`appPath` is nil, so the row isn't clickable). Opening
    /// a ClickUp conversation counts as reading it: the row goes until a
    /// newer message arrives (0010).
    func activateAgent(_ session: AgentSessionSnapshot) {
        AgentSessionActivation.activate(session)
        if session.isClickUp { Task { await dismissAgent(session) } }
    }

    func dismissAgent(_ session: AgentSessionSnapshot) async {
        do {
            _ = try await core.dismissAgentSession(session)
            await reload()
        } catch {
            await report(error)
        }
    }

    /// Adds images to the note field (0018). A refusal shows in the panel and
    /// stages nothing.
    func stage(_ images: [Data]) {
        guard !images.isEmpty else { return }
        do {
            try ImageClipboard.check(images, staged: stagedImages.count)
            stagedImages += images.map { StagedImage(data: $0, thumbnail: Thumbnails.image(data: $0, points: 44)) }
            errorMessage = nil
        } catch {
            errorMessage = (error as? ImageRefusal)?.message ?? error.localizedDescription
        }
    }

    /// ⌘V in the note field: true when the clipboard held images (staged or
    /// refused), so the text paste is skipped.
    func pasteImages(from pasteboard: NSPasteboard) -> Bool {
        do {
            let images = try ImageClipboard.images(from: pasteboard)
            guard !images.isEmpty else { return false }
            stage(images)
        } catch {
            errorMessage = (error as? ImageRefusal)?.message ?? error.localizedDescription
        }
        return true
    }

    func unstage(_ id: UUID) {
        stagedImages.removeAll { $0.id == id }
    }

    func save() async {
        let text = draft
        let images = stagedImages.map(\.data)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        do {
            let item = try await core.createNote(text, images: images, folderID: scope.newNoteFolderID)
            draft = ""
            stagedImages = []
            await reload()
            highlight(item.id)
        } catch let error as RalloError {
            errorMessage = error.displayMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Remove Image (0018). The bytes are read first so Undo can attach the
    /// image again; a file already missing is removed without an Undo.
    func removeImage(_ image: ImageSnapshot, from item: ItemSnapshot) async {
        let data = try? Data(contentsOf: URL(fileURLWithPath: image.path))
        do {
            let updated = try await core.detachImage(item, imageID: image.id)
            show(Toast(message: "Removed the image", undo: data.map { Toast.Undo.reattach(updated, $0) }))
            await reload()
        } catch {
            await report(error)
        }
    }

    /// Images dropped on a note's row (0018).
    func attach(_ images: [Data], to item: ItemSnapshot) async {
        guard !images.isEmpty else { return }
        do {
            try ImageClipboard.check(images, staged: item.images.count)
            let updated = try await core.attachImages(item, images: images)
            await reload()
            highlight(updated.id)
        } catch let refusal as ImageRefusal {
            errorMessage = refusal.message
        } catch {
            await report(error)
        }
    }

    /// Shows the check first, then removes the row, so the action reads.
    func complete(_ item: ItemSnapshot) async {
        completingIDs.insert(item.id)
        try? await Task.sleep(nanoseconds: 450_000_000)
        defer { completingIDs.remove(item.id) }
        do {
            let done = try await core.completeItem(item)
            show(Toast(message: "Marked “\(done.name)” as done", undo: .reopen(done)))
            await reload()
        } catch {
            await report(error)
        }
    }

    /// Soft delete; the toast's Undo restores it (its reminder stays off).
    func delete(_ item: ItemSnapshot) async {
        do {
            let deleted = try await core.deleteItem(item)
            if openSwipe?.id == item.id { openSwipe = nil }
            if liveSwipe?.id == item.id { liveSwipe = nil }
            if expandedID == item.id { expandedID = nil }
            if editingID == item.id { editingID = nil }
            show(Toast(message: "Deleted “\(deleted.name)”", undo: .restore(deleted)))
            await reload()
        } catch {
            await report(error)
        }
    }

    func remind(_ item: ItemSnapshot, _ preset: RemindPreset) async {
        await setReminder { [core] in
            switch preset {
            case .inTwentyMinutes: return try await core.remindIn(item, duration: "20m")
            case .inOneHour: return try await core.remindIn(item, duration: "1h")
            case .tomorrowMorning: return try await core.remindAt(item, date: RemindPreset.tomorrowMorning())
            }
        }
    }

    /// "Custom…" (0016): `date` is what the popover previewed.
    func remind(_ item: ItemSnapshot, at date: Date) async {
        await setReminder { [core] in try await core.remindAt(item, date: date) }
    }

    private func setReminder(_ change: () async throws -> ItemSnapshot) async {
        do {
            let updated = try await change()
            if let reminder = updated.reminder {
                show(Toast(message: "Reminder set for \(ReminderLabel.text(for: reminder.deadline))", undo: nil))
            }
            await reload()
            highlight(updated.id)
        } catch {
            await report(error)
        }
    }

    func snooze(_ item: ItemSnapshot) async {
        do {
            let snoozed = try await core.snoozeReminder(item, duration: "10m")
            if let reminder = snoozed.reminder {
                show(Toast(message: "Snoozed until \(ReminderLabel.text(for: reminder.deadline))", undo: nil))
            }
            await reload()
        } catch {
            await report(error)
        }
    }

    /// Stops the reminder alerting; the note itself stays open.
    func dismissReminder(_ item: ItemSnapshot) async {
        do {
            _ = try await core.acknowledgeReminder(item)
            await reload()
        } catch {
            await report(error)
        }
    }

    func undo() async {
        guard let undo = toast?.undo else { return }
        toastTask?.cancel()
        toast = nil
        do {
            let item: ItemSnapshot
            switch undo {
            case let .reopen(done): item = try await core.reopenItem(done)
            case let .restore(deleted): item = try await core.restoreItem(deleted)
            case let .reattach(note, data): item = try await core.attachImages(note, images: [data])
            case let .move(moved, back): item = try await core.moveItem(moved, folderID: back)
            }
            await reload()
            highlight(item.id)
        } catch {
            await report(error)
        }
    }

    /// A plain message in the toast position (nothing to undo).
    func inform(_ message: String) {
        show(Toast(message: message, undo: nil))
    }

    private func show(_ toast: Toast) {
        toastTask?.cancel()
        self.toast = toast
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func report(_ error: Error) async {
        await reload()
        if let error = error as? RalloError {
            if case let .Conflict(code, _) = error, code == "REVISION_CONFLICT" {
                errorMessage = "That note changed elsewhere; here’s the latest."
            } else {
                errorMessage = error.displayMessage
            }
        } else {
            errorMessage = error.localizedDescription
        }
    }
}
