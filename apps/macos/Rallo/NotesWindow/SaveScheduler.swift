import Foundation

/// When the notes window's editor saves (0019 §11): 0.6 s after typing
/// stops, or right away when the selection changes or the window closes. A
/// pure state machine; the editor session owns the timer and the core call.
struct SaveScheduler {
    enum Phase: Equatable {
        /// Nothing unsaved.
        case clean
        /// Typed; due `delay` after the last keystroke.
        case dirty(lastEdit: Date)
        /// A save is running; `editedMeanwhile` keystrokes arrived after it began.
        case saving(editedMeanwhile: Bool)
        /// The core refused (empty note, too long): nothing to retry until the next keystroke.
        case held
        /// The note changed somewhere else; the bar decides, so nothing saves.
        case conflict
    }

    let delay: TimeInterval
    private let now: () -> Date
    private(set) var phase: Phase = .clean

    init(delay: TimeInterval = 0.6, now: @escaping () -> Date = Date.init) {
        self.delay = delay
        self.now = now
    }

    /// Typing that hasn't reached the database (or was refused).
    var hasUnsavedText: Bool { phase != .clean }

    /// When the pending save falls due; nil when none is waiting.
    var dueAt: Date? {
        if case let .dirty(lastEdit) = phase { return lastEdit.addingTimeInterval(delay) }
        return nil
    }

    mutating func edited() {
        switch phase {
        case .saving: phase = .saving(editedMeanwhile: true)
        case .conflict: break
        case .clean, .dirty, .held: phase = .dirty(lastEdit: now())
        }
    }

    /// The timer fired. True when a save must start now.
    mutating func takeDue() -> Bool {
        guard let due = dueAt, now() >= due else { return false }
        phase = .saving(editedMeanwhile: false)
        return true
    }

    /// The selection changes or the window closes. True when a save must start now.
    mutating func takeFlush() -> Bool {
        guard case .dirty = phase else { return false }
        phase = .saving(editedMeanwhile: false)
        return true
    }

    mutating func saved() {
        if case .saving(editedMeanwhile: true) = phase {
            phase = .dirty(lastEdit: now())
        } else {
            phase = .clean
        }
    }

    mutating func refused() {
        if case .saving(editedMeanwhile: true) = phase {
            phase = .dirty(lastEdit: now())
        } else {
            phase = .held
        }
    }

    mutating func conflicted() { phase = .conflict }

    /// Keep Mine: save again, now, on the new revision.
    mutating func keepMine() {
        guard phase == .conflict else { return }
        phase = .dirty(lastEdit: .distantPast)
    }

    /// Show Theirs, or leaving the note.
    mutating func reset() { phase = .clean }
}
