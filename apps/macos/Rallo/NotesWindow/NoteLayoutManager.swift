import AppKit

extension NSAttributedString.Key {
    /// A `NoteDecoration` raw value: what the layout manager draws for the run.
    static let noteDecoration = NSAttributedString.Key("rallo.noteDecoration")
}

enum NoteDecoration: String {
    case bullet, taskOpen, taskDone, quote, codeBlock, divider
}

/// Draws what attributes alone can't: code block and quote backgrounds, list
/// bullets, task boxes and dividers (0023 §3). The glyphs under them are clear.
final class NoteLayoutManager: NSLayoutManager {
    /// The glyphs' bounds in text-container coordinates.
    func boxRect(forCharacterRange range: NSRange) -> NSRect? {
        guard let container = textContainers.first else { return nil }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return boundingRect(forGlyphRange: glyphs, in: container)
    }

    /// Each run of `decoration` that touches `glyphs`, as a character range.
    /// `whole`: the run's full extent, not just its dirty part (a block's rect is drawn in one piece).
    private func runs(_ decoration: NoteDecoration, in glyphs: NSRange, whole: Bool = false) -> [NSRange] {
        guard let storage = textStorage else { return [] }
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var out: [NSRange] = []
        storage.enumerateAttribute(.noteDecoration, in: chars) { value, run, _ in
            guard value as? String == decoration.rawValue else { return }
            var full = run
            if whole {
                storage.attribute(.noteDecoration, at: run.location, longestEffectiveRange: &full, in: NSRange(location: 0, length: storage.length))
            }
            if !out.contains(full) { out.append(full) }
        }
        return out
    }

    /// The line fragments of `chars`, united, at full container width.
    private func fullWidthRect(of chars: NSRange, origin: NSPoint) -> NSRect? {
        guard let container = textContainers.first else { return nil }
        var rect = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: chars, actualCharacterRange: nil)) { frag, _, _, _, _ in
            rect = rect.union(frag)
        }
        guard !rect.isNull else { return nil }
        return NSRect(x: origin.x, y: rect.minY + origin.y, width: container.size.width, height: rect.height)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        for run in runs(.codeBlock, in: glyphsToShow, whole: true) {
            guard let rect = fullWidthRect(of: run, origin: origin) else { continue }
            Theme.codeBackgroundNS.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }
        for run in runs(.quote, in: glyphsToShow, whole: true) {
            guard let rect = fullWidthRect(of: run, origin: origin) else { continue }
            Theme.quoteBarNS.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height).fill()
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        let body = NSFont.systemFont(ofSize: EditorStyling.bodySize)
        /// A square centered on the span's glyphs horizontally and on the text's
        /// baseline (not the line fragment, whose bottom is `lineSpacing`) vertically.
        func centered(_ run: NSRange, _ size: CGFloat, rise: CGFloat) -> NSRect? {
            guard let box = boxRect(forCharacterRange: run) else { return nil }
            let glyph = glyphIndexForCharacter(at: run.location)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = line.minY + location(forGlyphAt: glyph).y
            return NSRect(x: box.midX - size / 2 + origin.x, y: baseline - rise - size / 2 + origin.y, width: size, height: size)
        }
        for run in runs(.bullet, in: glyphsToShow) {
            guard let dot = centered(run, 5, rise: body.xHeight / 2) else { continue }
            Theme.rustNS.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        for run in runs(.taskOpen, in: glyphsToShow) {
            guard let box = centered(run, 14, rise: body.capHeight / 2) else { continue }
            let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: 3.5, yRadius: 3.5)
            outline.lineWidth = 1.5
            Theme.barkNS.setStroke()
            outline.stroke()
        }
        for run in runs(.taskDone, in: glyphsToShow) {
            guard let box = centered(run, 14, rise: body.capHeight / 2) else { continue }
            Theme.rustNS.setFill()
            NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5).fill()
            let check = NSBezierPath()  // the view is flipped: +y is down
            check.move(to: NSPoint(x: box.minX + 3.5, y: box.midY))
            check.line(to: NSPoint(x: box.minX + 6, y: box.midY + 2.7))
            check.line(to: NSPoint(x: box.maxX - 3.5, y: box.midY - 3))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            Theme.windowBackgroundNS.setStroke()
            check.stroke()
        }
        for run in runs(.divider, in: glyphsToShow) {
            guard let storage = textStorage, run.location < storage.length,
                (storage.attribute(.foregroundColor, at: run.location, effectiveRange: nil) as? NSColor)?.alphaComponent == 0,
                let rect = fullWidthRect(of: run, origin: origin)
            else { continue }
            Theme.dividerNS.setFill()
            NSRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1).fill()
        }
    }
}
