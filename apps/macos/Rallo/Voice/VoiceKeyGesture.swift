import Foundation

enum VoiceKeyAction: Equatable { case startHold, endHold, startHandsFree, stop }

/// The press/release logic, with no AppKit and caller-supplied times so it is
/// unit-testable. The caller runs a `holdDelay` timer per press and calls
/// `holdDeadline` when it fires.
struct VoiceKeyGesture {
    static let holdDelay: TimeInterval = 0.3
    static let tapWindow: TimeInterval = 0.4

    private var pressedAt: TimeInterval?
    /// The current press may still become a hold or a tap.
    private var pending = false
    private var holding = false
    private var holdEnabled = true
    private var lastTapRelease: TimeInterval?

    mutating func keyDown(at t: TimeInterval, listening: Bool, hold: Bool, doubleTap: Bool) -> VoiceKeyAction? {
        pressedAt = t
        holding = false
        pending = false
        if listening {
            lastTapRelease = nil
            return .stop
        }
        if doubleTap, let last = lastTapRelease, t - last <= Self.tapWindow {
            lastTapRelease = nil
            return .startHandsFree
        }
        lastTapRelease = nil
        pending = true
        holdEnabled = hold
        return nil
    }

    mutating func keyUp(at t: TimeInterval) -> VoiceKeyAction? {
        guard let down = pressedAt else { return nil }
        pressedAt = nil
        defer { pending = false; holding = false }
        if holding { return .endHold }
        // A long press with hold disabled is neither a hold nor a tap.
        if pending, t - down < Self.holdDelay { lastTapRelease = t }
        return nil
    }

    mutating func otherModifierChanged() {
        guard pending else { return }
        pending = false
        lastTapRelease = nil
    }

    mutating func holdDeadline(at t: TimeInterval) -> VoiceKeyAction? {
        guard pending, holdEnabled, !holding, let down = pressedAt, t - down >= Self.holdDelay else { return nil }
        holding = true
        pending = false
        return .startHold
    }
}
