import XCTest

/// How the sleeping pet tells petting (slow strokes) from tickling (a fast
/// jiggle); see PetView's play(with:).
final class StrokeTests: XCTestCase {
    /// Moves back and forth across `width` points, `passes` times, one
    /// sample every `step` seconds at `speed` points per second.
    private func sweep(_ stroke: inout Stroke, width: CGFloat, speed: CGFloat, passes: Int,
                       step: TimeInterval = 1.0 / 60, start: TimeInterval = 100) -> TimeInterval? {
        var x: CGFloat = 0, time = start, direction: CGFloat = 1, lastTurn: TimeInterval?
        _ = stroke.add(x: x, at: time)
        for _ in 0..<passes {
            var travelled: CGFloat = 0
            while travelled < width {
                let delta = speed * CGFloat(step)
                x += direction * delta
                travelled += delta
                time += step
                if let turn = stroke.add(x: x, at: time) { lastTurn = turn }
            }
            direction = -direction
        }
        return lastTurn
    }

    func testSlowStrokesArePettingNotTickling() throws {
        var stroke = Stroke()
        let now = try XCTUnwrap(sweep(&stroke, width: 80, speed: 200, passes: 3))
        XCTAssertEqual(stroke.turns(slowerThan: 400, within: 3, now: now), 2)
        XCTAssertEqual(stroke.turns(fasterThan: 500, within: 1.2, now: now), 0)
    }

    func testFastJiggleIsTickling() throws {
        var stroke = Stroke()
        let now = try XCTUnwrap(sweep(&stroke, width: 20, speed: 900, passes: 5))
        XCTAssertGreaterThanOrEqual(stroke.turns(fasterThan: 500, within: 1.2, now: now), 3)
        XCTAssertEqual(stroke.turns(slowerThan: 400, within: 3, now: now), 0)
    }

    func testSubPointStepsStillCountAsMovement() throws {
        var stroke = Stroke()
        // 0.6 pt per sample (36 pt/s): no single step reaches the 1 pt
        // threshold, yet it's faster than the 30 pt/s petting floor.
        let now = try XCTUnwrap(sweep(&stroke, width: 40, speed: 36, passes: 3))
        XCTAssertEqual(stroke.turns(slowerThan: 400, within: 3, now: now), 2)
    }

    func testOneWaySwipeIsNeither() {
        var stroke = Stroke()
        XCTAssertNil(sweep(&stroke, width: 140, speed: 1500, passes: 1))
    }
}
