import Foundation

/// What the bubble says for one alert (0021 §3), after the call rule (§8).
struct SummonBubbleContent: Equatable {
    var kindLine: String
    /// Nil in a call: no note text, repo, or time on a shared screen.
    var text: String?
    var isAgent: Bool
    var moreCount: Int

    static func make(for alert: AttentionAlert, showsDetails: Bool, moreCount: Int, now: Date,
                     timeText: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) -> SummonBubbleContent {
        switch alert.kind {
        case let .reminder(deadline):
            return SummonBubbleContent(kindLine: showsDetails ? "⏰ Reminder · \(timeText(deadline))" : "⏰ Reminder",
                                       text: showsDetails ? excerpt(alert.text) : nil, isAgent: false, moreCount: moreCount)
        case let .agent(waitingSince):
            let minutes = max(1, Int(now.timeIntervalSince(waitingSince) / 60))
            return SummonBubbleContent(kindLine: showsDetails ? "🤖 Agent waiting · \(minutes) min" : "🤖 An agent is waiting",
                                       text: showsDetails ? alert.text : nil, isAgent: true, moreCount: moreCount)
        }
    }

    /// The banner-preview rule: line breaks flattened, at most 160 grapheme clusters.
    static func excerpt(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.count > 160 ? String(flat.prefix(159)) + "…" : flat
    }

    /// "Claude Code needs you in rallo".
    static func agentText(for session: AgentSessionSnapshot) -> String {
        let name = AgentSessionFormatting.agentName(session.agent)
        guard let place = AgentSessionFormatting.place(for: session) else { return "\(name) needs you" }
        return "\(name) needs you in \(place)"
    }
}
