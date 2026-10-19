import Foundation

/// Replace `range` with `replacement`, then select `selection` (in the new text).
/// `range.length == 0 && replacement.isEmpty` = move the selection only.
struct FormatEdit: Equatable {
    var range: NSRange
    var replacement: String
    var selection: NSRange
}

enum InlineMark: String {
    case bold = "**", italic = "*", strike = "~~", code = "`"

    fileprivate var kind: MarkdownKind {
        switch self {
        case .bold: return .bold
        case .italic: return .italic
        case .strike: return .strike
        case .code: return .code
        }
    }
}

enum BlockStyle: Equatable { case heading, subheading, body, bulleted, numbered, checklist, quote }

/// The Format menu's string edits (0023 §4). Pure: ranges are UTF-16, as
/// `NSTextView` and the core's `markdown_spans` count; the text view applies
/// the returned `FormatEdit`.
enum NoteFormatting {
    // MARK: Lines and prefixes

    private struct Line {
        var start: Int
        var end: Int      // before the terminator
        var fullEnd: Int  // after it
    }

    private struct Prefix {
        var style: BlockStyle
        var length: Int
        var indent = ""
        var bullet = "-"
        var delimiter = "."
        var checked = false
    }

    // `#…# `, a bullet then `[ ] `/`[x] ` (or the box at line end), a bullet, `N. `/`N) `, `> `.
    private static let prefixPattern = try! NSRegularExpression(
        pattern: #"^(?:(#+) |([ \t]*)([-*+]) \[([ xX])\](?: |$)|([ \t]*)([-*+]) |([ \t]*)(\d+)([.)]) |> )"#)

    private static func prefix(of line: String) -> Prefix? {
        let ns = line as NSString
        guard let m = prefixPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        if let hashes = group(1) { return Prefix(style: hashes.count == 1 ? .heading : .subheading, length: m.range.length) }
        if let bullet = group(3), let box = group(4) {
            return Prefix(style: .checklist, length: m.range.length, indent: group(2) ?? "", bullet: bullet, checked: box != " ")
        }
        if let bullet = group(6) { return Prefix(style: .bulleted, length: m.range.length, indent: group(5) ?? "", bullet: bullet) }
        if let delimiter = group(9) { return Prefix(style: .numbered, length: m.range.length, indent: group(7) ?? "", delimiter: delimiter) }
        return Prefix(style: .quote, length: m.range.length)
    }

    private static func line(at location: Int, in ns: NSString) -> Line {
        var start = 0, end = 0, contents = 0
        ns.getLineStart(&start, end: &end, contentsEnd: &contents, for: NSRange(location: min(max(location, 0), ns.length), length: 0))
        return Line(start: start, end: contents, fullEnd: end)
    }

    /// The lines a selection touches; a selection ending right after a line break doesn't touch the next line.
    private static func lines(in ns: NSString, _ selection: NSRange) -> [Line] {
        let location = min(max(selection.location, 0), ns.length)
        let probe = selection.length > 0 ? max(location, NSMaxRange(selection) - 1) : location
        var result = [line(at: location, in: ns)]
        while let last = result.last, last.fullEnd <= probe, last.fullEnd < ns.length {
            result.append(line(at: last.fullEnd, in: ns))
        }
        return result
    }

    private static func string(_ ns: NSString, _ start: Int, _ end: Int) -> String {
        ns.substring(with: NSRange(location: start, length: end - start))
    }

    /// Replaces each line's contents, keeping the line breaks between them.
    private static func rebuild(_ ns: NSString, _ lines: [Line], _ contents: [String]) -> (range: NSRange, text: String) {
        var out = ""
        for (i, line) in lines.enumerated() {
            out += contents[i]
            if i + 1 < lines.count { out += string(ns, line.end, lines[i + 1].start) }
        }
        let start = lines[0].start
        return (NSRange(location: start, length: lines.last!.end - start), out)
    }

    private static func leadingSpace(_ s: String) -> String { String(s.prefix { $0 == " " || $0 == "\t" }) }

    private static func nop(_ selection: NSRange) -> FormatEdit {
        FormatEdit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
    }

    // MARK: Inline marks

    /// Where a span's delimiters sit: the content is flanked by `delimiter` on both sides.
    private static func delimiterLength(of span: NSRange, mark: InlineMark, in ns: NSString) -> Int {
        guard mark == .code else { return mark.rawValue.utf16.count }
        var n = 0 // a backtick run of any length opens a code span
        while span.location - n - 1 >= 0, ns.character(at: span.location - n - 1) == 0x60 { n += 1 }
        return max(n, 1)
    }

    private static func contents(_ mark: InlineMark, _ marks: [MarkdownSpan]) -> [NSRange] {
        marks.filter { $0.kind == mark.kind }.map { NSRange(location: Int($0.utf16Start), length: Int($0.utf16Len)) }
    }

    static func toggle(_ mark: InlineMark, text: String, selection: NSRange, marks: [MarkdownSpan]) -> FormatEdit {
        let ns = text as NSString
        let d = mark.rawValue.utf16.count
        let spans = contents(mark, marks)
        // Each line's part of the selection, without surrounding blanks.
        var segments: [NSRange] = []
        if selection.length > 0 {
            for line in lines(in: ns, selection) {
                var s = max(line.start, selection.location), e = min(line.end, NSMaxRange(selection))
                while s < e, [0x20, 0x09].contains(ns.character(at: s)) { s += 1 }
                while e > s, [0x20, 0x09].contains(ns.character(at: e - 1)) { e -= 1 }
                if e > s { segments.append(NSRange(location: s, length: e - s)) }
            }
        }
        guard !segments.isEmpty else { return toggleAtCaret(mark, ns, selection.location, spans) }

        // Unwrap when every segment lies in a span of this mark (delimiters included).
        var covering: [NSRange] = []
        for seg in segments {
            guard let span = spans.first(where: {
                let dl = delimiterLength(of: $0, mark: mark, in: ns)
                return seg.location >= $0.location - dl && NSMaxRange(seg) <= NSMaxRange($0) + dl
            }) else { covering = []; break }
            if !covering.contains(span) { covering.append(span) }
        }
        if !covering.isEmpty {
            covering.sort { $0.location < $1.location }
            let first = covering[0], last = covering[covering.count - 1]
            let regionStart = first.location - delimiterLength(of: first, mark: mark, in: ns)
            let regionEnd = NSMaxRange(last) + delimiterLength(of: last, mark: mark, in: ns)
            var out = "", prev = regionStart, newStart = 0, newEnd = 0
            for (i, span) in covering.enumerated() {
                let dl = delimiterLength(of: span, mark: mark, in: ns)
                out += string(ns, prev, span.location - dl)
                if i == 0 { newStart = out.utf16.count }
                out += string(ns, span.location, NSMaxRange(span))
                newEnd = out.utf16.count
                prev = NSMaxRange(span) + dl
            }
            return FormatEdit(range: NSRange(location: regionStart, length: regionEnd - regionStart), replacement: out,
                              selection: NSRange(location: regionStart + newStart, length: newEnd - newStart))
        }

        var out = "", prev = segments[0].location
        for seg in segments {
            out += string(ns, prev, seg.location) + mark.rawValue + string(ns, seg.location, NSMaxRange(seg)) + mark.rawValue
            prev = NSMaxRange(seg)
        }
        let start = segments[0].location
        let region = NSRange(location: start, length: prev - start)
        let selected = segments.count == 1
            ? NSRange(location: start + d, length: segments[0].length)
            : NSRange(location: start, length: out.utf16.count)
        return FormatEdit(range: region, replacement: out, selection: selected)
    }

    private static func toggleAtCaret(_ mark: InlineMark, _ ns: NSString, _ caret: Int, _ spans: [NSRange]) -> FormatEdit {
        let d = mark.rawValue.utf16.count
        // Right before the closing mark: step past it.
        if let span = spans.first(where: { NSMaxRange($0) == caret }) {
            let dl = delimiterLength(of: span, mark: mark, in: ns)
            return nop(NSRange(location: caret + dl, length: 0))
        }
        // On an empty pair: remove it.
        let before = NSRange(location: caret - d, length: d), after = NSRange(location: caret, length: d)
        if before.location >= 0, NSMaxRange(after) <= ns.length,
           ns.substring(with: before) == mark.rawValue, ns.substring(with: after) == mark.rawValue {
            return FormatEdit(range: NSRange(location: before.location, length: 2 * d), replacement: "",
                              selection: NSRange(location: before.location, length: 0))
        }
        return FormatEdit(range: NSRange(location: caret, length: 0), replacement: mark.rawValue + mark.rawValue,
                          selection: NSRange(location: caret + d, length: 0))
    }

    static func isInside(_ mark: InlineMark, location: Int, marks: [MarkdownSpan]) -> Bool {
        contents(mark, marks).contains { location >= $0.location && location <= NSMaxRange($0) }
    }

    // MARK: Blocks

    static func blockStyle(text: String, at location: Int) -> BlockStyle {
        let ns = text as NSString
        let l = line(at: location, in: ns)
        return prefix(of: string(ns, l.start, l.end))?.style ?? .body
    }

    static func setBlock(_ style: BlockStyle, text: String, selection: NSRange) -> FormatEdit {
        let ns = text as NSString
        let ls = lines(in: ns, selection)
        let strings = ls.map { string(ns, $0.start, $0.end) }
        let prefixes = strings.map(prefix(of:))
        let allHave = style != .body && prefixes.allSatisfy { ($0?.style ?? .body) == style }
        let target = allHave ? BlockStyle.body : style

        var results: [String] = [], restStarts: [Int] = []
        for (i, s) in strings.enumerated() {
            let old = prefixes[i]
            var rest = old.map { String(s.utf16.dropFirst($0.length))! } ?? s
            let isList = [.bulleted, .numbered, .checklist].contains(target)
            let indent = old?.indent ?? leadingSpace(s)
            if isList || (target == .body && old == nil) {
                if old == nil, isList { rest = String(rest.dropFirst(indent.count)) }
            } else {
                rest = String(rest.drop { $0 == " " || $0 == "\t" })
            }
            let bullet = [.bulleted, .checklist].contains(old?.style) ? old!.bullet : "-"
            let head: String
            switch target {
            case .heading: head = "# "
            case .subheading: head = "## "
            case .body: head = ""
            case .bulleted: head = "\(indent)\(bullet) "
            case .numbered: head = "\(indent)\(i + 1). "
            case .checklist: head = "\(indent)\(bullet) [\(old?.style == .checklist && old!.checked ? "x" : " ")] "
            case .quote: head = "> "
            }
            // A plain line asked for body keeps its text and its leading space.
            results.append(target == .body && old == nil ? s : head + rest)
            restStarts.append(head.utf16.count)
        }
        let (range, out) = rebuild(ns, ls, results)
        if selection.length > 0 {
            return FormatEdit(range: range, replacement: out, selection: NSRange(location: range.location, length: out.utf16.count))
        }
        let delta = results[0].utf16.count - strings[0].utf16.count
        let restStart = ls[0].start + (target == .body && prefixes[0] == nil ? 0 : restStarts[0])
        let caret = max(restStart, selection.location + delta)
        return FormatEdit(range: range, replacement: out, selection: NSRange(location: caret, length: 0))
    }

    static func toggleCodeBlock(text: String, selection: NSRange, marks: [MarkdownSpan]) -> FormatEdit {
        let ns = text as NSString
        let caret = selection.location
        let block = marks.first {
            $0.kind == .codeBlock && caret >= Int($0.utf16Start) && caret <= Int($0.utf16Start + $0.utf16Len)
        }
        guard let block else {
            let ls = lines(in: ns, selection)
            let inner = string(ns, ls[0].start, ls.last!.end)
            return FormatEdit(range: NSRange(location: ls[0].start, length: inner.utf16.count), replacement: "```\n\(inner)\n```",
                              selection: NSRange(location: ls[0].start + 4, length: inner.utf16.count))
        }
        let start = Int(block.utf16Start), end = Int(block.utf16Start + block.utf16Len)
        let opener = line(at: start, in: ns), last = line(at: max(start, end - 1), in: ns)
        let closed = last.start != opener.start && string(ns, last.start, last.end).trimmingCharacters(in: .whitespaces).hasPrefix("```")
        var inner = string(ns, opener.fullEnd, closed ? last.start : last.fullEnd)
        if closed, last.fullEnd == last.end, inner.hasSuffix("\n") { inner.removeLast() } // closer at the very end of the text
        let range = NSRange(location: opener.start, length: last.fullEnd - opener.start)
        let at = min(max(caret - (opener.fullEnd - opener.start), 0), inner.utf16.count)
        return FormatEdit(range: range, replacement: inner, selection: NSRange(location: opener.start + at, length: 0))
    }

    static func toggleChecked(text: String, selection: NSRange) -> FormatEdit? {
        let ns = text as NSString
        let ls = lines(in: ns, selection)
        let strings = ls.map { string(ns, $0.start, $0.end) }
        let prefixes = strings.map(prefix(of:))
        let tasks = prefixes.compactMap { $0 }.filter { $0.style == .checklist }
        guard !tasks.isEmpty else { return nil }
        let check = tasks.contains { !$0.checked }
        let results = strings.enumerated().map { i, s -> String in
            guard let p = prefixes[i], p.style == .checklist else { return s }
            let box = p.indent.utf16.count + 3 // `- [` then the mark
            return (s as NSString).replacingCharacters(in: NSRange(location: box, length: 1), with: check ? "x" : " ")
        }
        let (range, out) = rebuild(ns, ls, results)
        return FormatEdit(range: range, replacement: out, selection: selection)
    }

    static func indent(text: String, selection: NSRange, outdent: Bool) -> FormatEdit? {
        let ns = text as NSString
        let ls = lines(in: ns, selection)
        let strings = ls.map { string(ns, $0.start, $0.end) }
        let isList = strings.map { [.bulleted, .numbered, .checklist].contains(prefix(of: $0)?.style) }
        guard isList.contains(true) else { return nil }
        var changes: [(line: Int, delta: Int)] = []
        let results = strings.enumerated().map { i, s -> String in
            guard isList[i] else { return s }
            if !outdent { changes.append((i, 2)); return "  " + s }
            let n = s.hasPrefix("\t") ? 1 : s.hasPrefix("  ") ? 2 : s.hasPrefix(" ") ? 1 : 0
            if n > 0 { changes.append((i, -n)) }
            return String(s.dropFirst(n))
        }
        if changes.isEmpty { return nop(selection) } // nothing left to outdent; still a list line, so Tab is handled
        func shift(_ p: Int, inclusive: Bool) -> Int {
            changes.reduce(p) { acc, c in
                let start = ls[c.line].start
                guard inclusive ? start <= p : start < p else { return acc }
                return acc + (c.delta < 0 ? -min(-c.delta, p - start) : c.delta)
            }
        }
        let (range, out) = rebuild(ns, ls, results)
        let caret = selection.length == 0
        let newStart = shift(selection.location, inclusive: caret)
        let newEnd = caret ? newStart : shift(NSMaxRange(selection), inclusive: true)
        return FormatEdit(range: range, replacement: out, selection: NSRange(location: newStart, length: newEnd - newStart))
    }

    // MARK: Insertions

    static func addLink(text: String, selection: NSRange) -> FormatEdit {
        let selected = (text as NSString).substring(with: selection)
        if selection.length == 0 {
            return FormatEdit(range: selection, replacement: "[]()", selection: NSRange(location: selection.location + 1, length: 0))
        }
        return FormatEdit(range: selection, replacement: "[\(selected)]()",
                          selection: NSRange(location: selection.location + selection.length + 3, length: 0))
    }

    static func insertDivider(text: String, selection: NSRange) -> FormatEdit {
        let end = line(at: selection.location, in: text as NSString).end
        return FormatEdit(range: NSRange(location: end, length: 0), replacement: "\n\n---\n", selection: NSRange(location: end + 6, length: 0))
    }

    // MARK: Return

    static func newline(text: String, selection: NSRange, marks: [MarkdownSpan]) -> FormatEdit? {
        guard selection.length == 0 else { return nil }
        let caret = selection.location
        if marks.contains(where: { $0.kind == .codeBlock && caret >= Int($0.utf16Start) && caret <= Int($0.utf16Start + $0.utf16Len) }) {
            return nil
        }
        let ns = text as NSString
        let l = line(at: caret, in: ns)
        let s = string(ns, l.start, l.end)
        guard let p = prefix(of: s), p.style != .heading, p.style != .subheading, caret - l.start >= p.length else { return nil }
        if s.utf16.dropFirst(p.length).allSatisfy({ $0 == 0x20 || $0 == 0x09 }), caret == l.end {
            return FormatEdit(range: NSRange(location: l.start, length: l.end - l.start), replacement: "",
                              selection: NSRange(location: l.start, length: 0))
        }
        let next: String
        switch p.style {
        case .numbered:
            let digits = s.dropFirst(p.indent.count).prefix { $0.isNumber }
            next = "\(p.indent)\((Int(digits) ?? 0) + 1)\(p.delimiter) "
        case .checklist: next = "\(p.indent)\(p.bullet) [ ] "
        case .bulleted: next = "\(p.indent)\(p.bullet) "
        default: next = "> "
        }
        return FormatEdit(range: selection, replacement: "\n" + next, selection: NSRange(location: caret + 1 + next.utf16.count, length: 0))
    }
}
