import XCTest

/// The watermark seeding/consuming rules PetStateDriver relies on: old
/// events at startup are history, and a burst of events between recomputes
/// collapses into one played moment (0006, extended by 0007).
final class PetWatermarksTests: XCTestCase {
    private func snapshot(
        completion: Int64 = 0, save: Int64 = 0, agentWaiting: Int64 = 0
    ) -> PetSnapshot {
        PetSnapshot(openCount: 0, dueCount: 0, nextDueAtMs: nil, completionSeq: completion, saveSeq: save,
                    agentsWaiting: 0, agentWaitingSeq: agentWaiting)
    }

    func testFirstReadSeedsToTheCurrentSnapshotSoHistoryNeverReplays() {
        var watermarks = PetWatermarks()
        let seen = watermarks.seenValues(for: snapshot(completion: 5, save: 3, agentWaiting: 2))
        XCTAssertEqual(seen.completion, 5)
        XCTAssertEqual(seen.save, 3)
        XCTAssertEqual(seen.agentWaiting, 2)
    }

    func testUnconsumedReadsKeepReturningTheSameSeenValue() {
        var watermarks = PetWatermarks()
        _ = watermarks.seenValues(for: snapshot(agentWaiting: 2))
        // A second recompute before anything is consumed (e.g. the moment is
        // still playing) must not silently seed again at the new value.
        let seen = watermarks.seenValues(for: snapshot(agentWaiting: 4))
        XCTAssertEqual(seen.agentWaiting, 2)
    }

    func testConsumeAdvancesEveryWatermarkEvenWhenNothingWasPlayed() {
        var watermarks = PetWatermarks()
        _ = watermarks.seenValues(for: snapshot(completion: 1, save: 1, agentWaiting: 1))
        watermarks.consume(snapshot(completion: 1, save: 1, agentWaiting: 1))
        // Two more waiting agents arrive before the next recompute: they
        // collapse into a single new event, not two.
        let seen = watermarks.seenValues(for: snapshot(completion: 1, save: 1, agentWaiting: 3))
        XCTAssertEqual(seen.agentWaiting, 1, "unseen until the decision that covers it is consumed")
        watermarks.consume(snapshot(completion: 1, save: 1, agentWaiting: 3))
        XCTAssertEqual(watermarks.seenValues(for: snapshot(agentWaiting: 3)).agentWaiting, 3)
    }

    func testWatermarksAreIndependent() {
        var watermarks = PetWatermarks()
        _ = watermarks.seenValues(for: snapshot(completion: 1, save: 1, agentWaiting: 1))
        watermarks.consume(snapshot(completion: 1, save: 1, agentWaiting: 1))
        // Only the save sequence moves; the rest must stay put.
        let seen = watermarks.seenValues(for: snapshot(completion: 1, save: 9, agentWaiting: 1))
        XCTAssertEqual(seen.completion, 1)
        XCTAssertEqual(seen.save, 1, "unseen until consumed")
        XCTAssertEqual(seen.agentWaiting, 1)
    }
}
