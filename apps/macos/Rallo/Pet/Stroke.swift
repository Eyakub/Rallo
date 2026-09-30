import CoreGraphics
import Foundation

/// The cursor's horizontal back-and-forth over the pet: each change of
/// direction is a turn, with the speed of the stroke that ended there.
struct Stroke {
    private var lastX: CGFloat?
    private var lastTime: TimeInterval = 0
    private var direction: CGFloat = 0
    private var strokeStart: (x: CGFloat, time: TimeInterval) = (0, 0)
    private var turns: [(time: TimeInterval, speed: CGFloat)] = []

    /// Records a position; returns the time if this move reversed direction.
    mutating func add(x: CGFloat, at time: TimeInterval) -> TimeInterval? {
        guard let lastX else {
            (self.lastX, lastTime, strokeStart) = (x, time, (x, time))
            return nil
        }
        // Sub-point steps (slow trackpad strokes) add up until they count.
        guard abs(x - lastX) >= 1 else { return nil }
        let now: CGFloat = x > lastX ? 1 : -1
        let previous = direction
        direction = now
        defer { (self.lastX, lastTime) = (x, time) }
        guard previous != 0, now != previous else { return nil }
        let elapsed = max(lastTime - strokeStart.time, 0.01)
        turns.append((lastTime, abs(lastX - strokeStart.x) / elapsed))
        turns.removeAll { time - $0.time > 3 }
        strokeStart = (lastX, lastTime)
        return time
    }

    func turns(fasterThan speed: CGFloat, within window: TimeInterval, now: TimeInterval) -> Int {
        turns.filter { now - $0.time <= window && $0.speed > speed }.count
    }

    func turns(slowerThan speed: CGFloat, within window: TimeInterval, now: TimeInterval) -> Int {
        turns.filter { now - $0.time <= window && (30...speed).contains($0.speed) }.count
    }
}
