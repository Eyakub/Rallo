import Foundation

/// Where the caret may rest when Markdown marks are hidden (0023 §3): a hidden
/// run is one visual spot, so the caret snaps to one position of it and steps
/// over it with a key press. Pure: UTF-16 offsets, as `markdownSpans` counts.
enum NoteCaret {
    enum Side { case start, end, line }
    struct Run: Equatable { var range: NSRange; var side: Side }

    private static func range(_ span: MarkdownSpan, in length: Int) -> NSRange {
        NSIntersectionRange(NSRange(location: Int(span.utf16Start), length: Int(span.utf16Len)), NSRange(location: 0, length: length))
    }

    /// The hidden runs, sorted. `shown` (a revealed link) keeps its marks out. Inline and prefix runs may
    /// touch; `adjust` treats touching runs as one spot. A hidden line at the very end of the text drops its
    /// missing line break, so a caret after a trailing newline stays on a real line.
    static func runs(text: NSString, marks: [MarkdownSpan], shown: NSRange?) -> [Run] {
        let length = text.length
        let spans = marks.map { (kind: $0.kind, range: range($0, in: length)) }
        func hit(_ r: NSRange) -> Bool { shown.map { NSIntersectionRange($0, r).length > 0 } ?? false }
        func paragraphStart(_ at: Int) -> Int { text.paragraphRange(for: NSRange(location: at, length: 0)).location }
        let markers = spans.filter { $0.kind == .marker && $0.range.length > 0 }.map(\.range)

        var prefixes: [NSRange] = []
        for (kind, r) in spans where r.length > 0 {
            switch kind {
            case .listContent:
                prefixes.append(NSRange(location: paragraphStart(r.location), length: r.location - paragraphStart(r.location)))
            case .heading, .quote:
                guard let m = markers.filter({ $0.location >= r.location && NSMaxRange($0) <= NSMaxRange(r) }).min(by: { $0.location < $1.location })
                else { continue }
                let start = paragraphStart(m.location)
                prefixes.append(NSRange(location: start, length: NSMaxRange(m) - start))
            default: break
            }
        }
        var out = prefixes.filter { $0.length > 0 && !hit($0) }.map { Run(range: $0, side: .end) }

        let content = spans.filter { [.bold, .italic, .strike, .code, .linkText].contains($0.kind) }.map(\.range)
        for m in markers where !hit(m) && !prefixes.contains(where: { NSLocationInRange(m.location, $0) && NSMaxRange(m) <= NSMaxRange($0) }) {
            let escape = m.length == 1 && text.character(at: m.location) == 0x5C
            let side: Side = escape || content.contains { $0.location == NSMaxRange(m) } ? .start
                : content.contains { NSMaxRange($0) == m.location } ? .end : .start
            out.append(Run(range: m, side: side))
        }

        for (kind, r) in spans where (kind == .codeFence || kind == .divider) && r.length > 0 {
            var p = text.paragraphRange(for: r)
            if NSMaxRange(p) == length, length > p.location, [0x0A, 0x0D].contains(text.character(at: length - 1)) { p.length -= 1 }
            if p.length > 0, !hit(p) { out.append(Run(range: p, side: .line)) }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// One visual spot (inline/prefix class: positions lo...hi) or a hidden line (`back`/`fwd` are its exits).
    private struct Spot {
        var lo: Int, hi: Int, rest: Int
        var isLine = false
        var back: Int?, fwd: Int?
    }

    private static func spots(_ runs: [Run], length: Int) -> [Spot] {
        var out: [Spot] = []
        var open: Spot?
        func flush() { if let s = open { out.append(s); open = nil } }
        for run in runs {
            let a = run.range.location, b = NSMaxRange(run.range)
            if run.side == .line {
                let hasNewline = b < length
                out.append(Spot(lo: a, hi: hasNewline ? b - 1 : b, rest: a, isLine: true, back: a > 0 ? a - 1 : nil, fwd: hasNewline ? b : nil))
                continue
            }
            let restHere = run.side == .end ? b : nil
            if var s = open, a <= s.hi {
                s.hi = max(s.hi, b)
                if let r = restHere { s.rest = r }
                open = s
            } else {
                flush()
                open = Spot(lo: a, hi: b, rest: restHere ?? a)
            }
        }
        flush()
        return out.sorted { $0.lo < $1.lo }
    }

    private static func spot(at p: Int, _ spots: [Spot]) -> Spot? { spots.first { $0.lo <= p && p <= $0.hi } }

    /// Where a click (or a landing after a step) rests.
    private static func settle(_ p: Int, _ spots: [Spot]) -> Int {
        guard let s = spot(at: p, spots) else { return p }
        return s.isLine ? (s.fwd ?? s.back ?? p) : s.rest
    }

    private static func caret(from o: Int, to p: Int, _ spots: [Spot], length: Int, mouse: Bool) -> Int {
        guard let s = spot(at: p, spots) else { return p }
        if s.isLine {
            if !mouse {
                if p > o { return s.fwd ?? s.hi }
                if p < o { return s.back ?? s.fwd ?? p }
            }
            return s.fwd ?? s.back ?? p
        }
        guard !mouse, s.lo <= o, o <= s.hi, p != o else { return s.rest }
        let q = p > o ? s.hi + 1 : s.lo - 1
        return q < 0 || q > length ? s.rest : settle(q, spots)
    }

    /// The selection to use instead of `new`, so the caret never sits inside a hidden run.
    static func adjust(from old: NSRange, to new: NSRange, runs: [Run], length: Int, mouse: Bool) -> NSRange {
        let spots = spots(runs, length: length)
        guard !spots.isEmpty else { return new }
        if new.length == 0 {
            return NSRange(location: caret(from: NSMaxRange(old), to: new.location, spots, length: length, mouse: mouse), length: 0)
        }
        let startMoved = new.location != old.location, endMoved = NSMaxRange(new) != NSMaxRange(old)
        guard startMoved != endMoved else { return new }
        if endMoved {
            let end = caret(from: NSMaxRange(old), to: NSMaxRange(new), spots, length: length, mouse: mouse)
            return end < new.location ? NSRange(location: new.location, length: 0) : NSRange(location: new.location, length: end - new.location)
        }
        let start = caret(from: old.location, to: new.location, spots, length: length, mouse: mouse)
        return start > NSMaxRange(new) ? NSRange(location: NSMaxRange(new), length: 0) : NSRange(location: start, length: NSMaxRange(new) - start)
    }
}
