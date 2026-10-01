/// Which reducer sequence numbers Swift has already turned into a played
/// moment (docs/decisions/0006, extended by 0007), so old events never replay
/// and a burst of them between recomputes collapses into one moment.
struct PetWatermarks {
    private var completion: Int64?
    private var save: Int64?
    private var agentWaiting: Int64?

    /// The "seen" values to feed `PetInputs`, seeding (and remembering) any
    /// watermark not yet read to `snapshot`'s current value: at startup,
    /// history isn't a new event.
    mutating func seenValues(
        for snapshot: PetSnapshot
    ) -> (completion: Int64, save: Int64, agentWaiting: Int64) {
        if completion == nil { completion = snapshot.completionSeq }
        if save == nil { save = snapshot.saveSeq }
        if agentWaiting == nil { agentWaiting = snapshot.agentWaitingSeq }
        return (completion: completion!, save: save!, agentWaiting: agentWaiting!)
    }

    /// Marks every event up to `snapshot` as consumed, whether or not it was
    /// played: work finished while something else is due is never celebrated
    /// later.
    mutating func consume(_ snapshot: PetSnapshot) {
        completion = snapshot.completionSeq
        save = snapshot.saveSeq
        agentWaiting = snapshot.agentWaitingSeq
    }
}
