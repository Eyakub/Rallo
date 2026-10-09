import Combine
import Foundation

/// The note open in the notes window's editor and when its text is saved
/// (0019 §11). Typing saves 0.6 s after it stops (`SaveScheduler`), and
/// `leave()` saves what's pending before the selection changes or the window
/// closes. It never saves an emptied note, never overwrites unsaved typing
/// with a reload, and turns a stale revision into the conflict bar.
@MainActor
final class NoteEditorSession: ObservableObject {
    enum Target {
        case none
        case note(ItemSnapshot)
        /// The "New Note" row: created by the first non-empty save, in `folderID`.
        /// `seed` is text the editor starts with (`#tag ` in a tag's scope);
        /// a draft that still reads as its seed is empty.
        case draft(folderID: String?, seed: String)
    }

    /// What the text view shows. The text view writes it through `textChanged`.
    @Published private(set) var text = ""
    @Published private(set) var target: Target = .none
    /// "This note changed somewhere else." is showing.
    @Published private(set) var conflict = false
    /// A refused save (`TEXT_TOO_LONG`, …), shown inline; the text stays.
    @Published private(set) var error: String?
    /// Moves the caret to the text view; bumped for a new note.
    @Published private(set) var focusToken = 0
    /// Counts `show` calls, so the text view knows a different note arrived.
    private(set) var showCount = 0
    /// The text view has an input method's marked text: never save mid-composition.
    var isComposing = false
    /// Set by the text view: turns marked text into ordinary text and pushes it
    /// through `textChanged`, as AppKit does when focus leaves the view.
    var commitComposition: () -> Void = {}
    /// A draft's first save created this note.
    var onCreated: (ItemSnapshot) -> Void = { _ in }
    /// A save reached the database; the window reloads.
    var onSaved: (ItemSnapshot) -> Void = { _ in }

    private let core: CoreClient
    private var scheduler: SaveScheduler
    private var timer: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var runningToken = 0

    init(core: CoreClient, saveDelay: TimeInterval = 0.6, now: @escaping () -> Date = Date.init) {
        self.core = core
        scheduler = SaveScheduler(delay: saveDelay, now: now)
    }

    var note: ItemSnapshot? {
        if case let .note(note) = target { return note }
        return nil
    }

    var isDraft: Bool {
        if case .draft = target { return true }
        return false
    }

    /// A deleted note can be read, not edited (Restore it first).
    var isEditable: Bool {
        switch target {
        case .none: false
        case let .note(note): note.deletedAtMs == nil
        case .draft: true
        }
    }

    var hasUnsavedText: Bool { scheduler.hasUnsavedText }

    /// Opens a note, nothing, or a draft. Call `leave()` first.
    func show(_ target: Target, focus: Bool = false) {
        timer?.cancel()
        scheduler.reset()
        conflict = false
        error = nil
        isComposing = false
        self.target = target
        switch target {
        case .none: text = ""
        case let .note(note): text = note.text
        case let .draft(_, seed): text = seed
        }
        showCount += 1
        if focus { focusToken += 1 }
    }

    /// The text view changed (the user typed, pasted or deleted).
    func textChanged(_ newText: String) {
        if case .none = target { return }
        text = newText
        error = nil
        scheduler.edited()
        armTimer()
    }

    /// A reload brought the note's latest state. Unsaved typing is never
    /// overwritten: it saves on the revision it started from, and the
    /// conflict bar answers if the note moved on.
    func sync(_ latest: ItemSnapshot) {
        guard case let .note(current) = target, current.id == latest.id else { return }
        guard latest.revision >= current.revision else { return }
        guard !scheduler.hasUnsavedText, !isComposing else { return }
        target = .note(latest)
        if text != latest.text { text = latest.text }
    }

    /// Show Theirs: the note as it is now.
    func showTheirs(_ latest: ItemSnapshot) {
        show(.note(latest))
    }

    /// Keep Mine: the typed text saves again on the note's new revision.
    func keepMine(_ latest: ItemSnapshot) {
        guard conflict, case let .note(current) = target, current.id == latest.id else { return }
        target = .note(latest)
        conflict = false
        scheduler.keepMine()
        armTimer()
    }

    /// Saves what's pending, now, and waits for it. Safe to call anytime.
    func flush() async {
        if isComposing { commitComposition() }
        timer?.cancel()
        while true {
            if let running {
                await running.value
                continue
            }
            guard scheduler.takeFlush() else { return }
            start()
        }
    }

    /// Saves what's pending before the selection changes. False when that save
    /// just hit a conflict or was refused: the bar or the message now shows and
    /// the text stays, so the caller keeps the note open. A bar or message the
    /// user had already seen doesn't hold them back; `leave()` then says what was lost.
    func readyToLeave() async -> Bool {
        if isComposing { commitComposition() }
        let alreadyShown = conflict || error != nil
        await flush()
        return alreadyShown || (!conflict && error == nil)
    }

    /// Saves what's pending, then lets go of the note: an emptied note gets
    /// its saved text back. Returns a sentence when typing couldn't be saved.
    @discardableResult
    func leave() async -> String? {
        if isComposing { commitComposition() }
        await flush()
        defer {
            scheduler.reset()
            conflict = false
            error = nil
        }
        let name = note?.name ?? "the note"
        switch scheduler.phase {
        case .held where error == nil:
            if let note { text = note.text }
            return nil
        case .held, .conflict:
            return "Your last changes to “\(name)” weren’t saved."
        default:
            return nil
        }
    }

    // MARK: Saving

    private func armTimer() {
        timer?.cancel()
        guard let due = scheduler.dueAt else { return }
        timer = Task { [weak self] in
            let wait = max(0, due.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timerFired()
        }
    }

    private func timerFired() {
        if isComposing {
            scheduler.edited()  // look again after the input method commits
            armTimer()
        } else if scheduler.takeDue() {
            start()
        } else if scheduler.dueAt != nil {
            armTimer()
        }
    }

    private func start() {
        runningToken += 1
        let token = runningToken
        running = Task { [weak self] in
            await self?.save()
            if self?.runningToken == token { self?.running = nil }
        }
    }

    private func save() async {
        let sent = text
        let shown = showCount
        let blank = sent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        do {
            switch target {
            case .none:
                scheduler.reset()
            case let .note(note):
                // An emptied note is never saved (unless it has images to stand on).
                // `refused()` may go back to dirty (typed meanwhile): the timer must look again.
                if blank, note.images.isEmpty {
                    scheduler.refused()
                    return armTimer()
                }
                let updated = try await core.editItemText(note, text: sent)
                guard showCount == shown else { return }
                finish(with: updated)
                onSaved(updated)
            case let .draft(folderID, seed):
                if blank || sent.trimmingCharacters(in: .whitespacesAndNewlines) == seed.trimmingCharacters(in: .whitespacesAndNewlines) {
                    scheduler.refused()
                    return armTimer()
                }
                let created = try await core.createNote(sent, images: [], folderID: folderID)
                guard showCount == shown else { return }
                finish(with: created)
                onCreated(created)
            }
        } catch let failure as RalloError {
            guard showCount == shown else { return }
            if case let .Conflict(code, _) = failure, code == "REVISION_CONFLICT" {
                scheduler.conflicted()
                conflict = true
            } else {
                scheduler.refused()
                error = failure.displayMessage
            }
            armTimer()
        } catch {
            guard showCount == shown else { return }
            scheduler.refused()
            self.error = error.localizedDescription
            armTimer()
        }
    }

    /// The save went through: keep its revision, and save again if more was typed meanwhile.
    private func finish(with saved: ItemSnapshot) {
        target = .note(saved)
        error = nil
        scheduler.saved()
        armTimer()
    }
}
