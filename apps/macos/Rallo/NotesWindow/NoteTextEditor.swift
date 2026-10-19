import AppKit
import SwiftUI

/// The note's text in an `NSTextView` (0019 §11): plain text, paste drops
/// formatting, the `NoteParts` title in 24 pt semibold rounded and `#tags`
/// tinted, all by attributes (`NoteTextStyler`), never by replacing the
/// string. It sizes itself to its text so the date above and the images below
/// scroll with it in one `ScrollView`.
struct NoteTextEditor: NSViewRepresentable {
    @ObservedObject var session: NoteEditorSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> PlainTextView {
        let view = PlainTextView.make()
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Note text")
        view.insertionPointColor = Theme.rustNS
        context.coordinator.attach(view)
        session.textView = view
        return view
    }

    func updateNSView(_ view: PlainTextView, context: Context) {
        let coordinator = context.coordinator
        _ = session.layoutRevision  // the parent view observes the session; a reveal bumps it so SwiftUI re-measures
        if view.isEditable != session.isEditable { view.isEditable = session.isEditable }
        coordinator.applying = true
        defer { coordinator.applying = false }
        var changed = false
        let length = (session.text as NSString).length
        if coordinator.shown != session.showCount {
            // Another note: the composition (if any) was committed to the old
            // note before the switch; end a leftover one, then show the new text
            // unconditionally. No undo across notes, caret at the start.
            coordinator.shown = session.showCount
            coordinator.endMarkedText(in: view)
            view.string = session.text
            view.undoManager?.removeAllActions()
            view.setSelectedRange(NSRange(location: session.isDraft ? length : 0, length: 0))
            changed = true
            if session.wantsFocus { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
        } else if !view.hasMarkedText(), view.string != session.text {  // never replace while an input method is composing
            let kept = view.selectedRange()
            view.string = session.text
            view.undoManager?.removeAllActions()  // undo across a programmatic replace would hit stale ranges
            view.setSelectedRange(NSRange(location: min(kept.location, length), length: 0))
            changed = true
        }
        if changed { coordinator.restyle(view) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlainTextView, context: Context) -> CGSize? {
        let width = max(proposal.width ?? 480, 80)
        guard let height = Self.fittingHeight(of: nsView, width: width, cache: context.coordinator.measurements) else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// The view's height at `width`, inset included. The view's own container follows its frame, so a
    /// probe at another width is measured in a throwaway layout (cached per width and text revision).
    static func fittingHeight(of view: PlainTextView, width: CGFloat, cache: MeasureCache? = nil) -> CGFloat? {
        guard let container = view.textContainer, let layout = view.layoutManager, let storage = view.textStorage
        else { return nil }
        let height: CGFloat
        if container.containerSize.width == width {
            layout.ensureLayout(for: container)
            height = layout.usedRect(for: container).height
        } else if let cache, let hit = cache.height(width: width) {
            height = hit
        } else {
            height = textHeight(storage, width: width)
            cache?.store(height, width: width)
        }
        return max(ceil(height) + view.textContainerInset.height * 2, 200)
    }

    /// The last throwaway measurement, dropped when the text or its styling changes.
    final class MeasureCache {
        private var last: (width: CGFloat, height: CGFloat)?

        func height(width: CGFloat) -> CGFloat? {
            guard let last, last.width == width else { return nil }
            return last.height
        }

        func store(_ height: CGFloat, width: CGFloat) { last = (width, height) }
        func invalidate() { last = nil }
    }

    /// The height `text` needs at `width`, measured in a throwaway layout.
    static func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return layout.usedRect(for: container).height
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: NoteEditorSession
        var applying = false
        var shown = -1
        let measurements = MeasureCache()
        /// Where Markdown marks were last shown (nil: nowhere).
        private(set) var lastReveal: NSRange?
        /// Length of the string `view.marks` describe; differs while an edit is in flight.
        private var markedLength = -1

        init(session: NoteEditorSession) {
            self.session = session
        }

        func attach(_ view: PlainTextView) {
            view.onFocusChange = { [weak self, weak view] in
                guard let self, let view else { return }
                self.updateReveal(view)
            }
            view.onMouseUp = view.onFocusChange
            session.commitComposition = { [weak self, weak view] in
                guard let self, let view else { return }
                self.commitComposition(view)
            }
        }

        /// Ends an input method's composition, keeping the marked text as plain text.
        func endMarkedText(in view: PlainTextView) {
            guard view.hasMarkedText() else { return }
            view.inputContext?.discardMarkedText()
            view.unmarkText()
        }

        /// Makes the underlined run ordinary text of the current note and tells
        /// the session; unmarking may not post `textDidChange` by itself.
        func commitComposition(_ view: PlainTextView) {
            // Usually the marked text is already gone (focus loss ended it); the flag must still clear.
            guard view.hasMarkedText() else {
                session.isComposing = false
                if view.string != session.text { session.textChanged(view.string) }
                return
            }
            let wasApplying = applying
            applying = true
            endMarkedText(in: view)
            applying = wasApplying
            session.isComposing = false
            session.textChanged(view.string)
            restyle(view)
        }

        func textDidChange(_ notification: Notification) {
            guard !applying, let view = notification.object as? PlainTextView else { return }
            session.isComposing = view.hasMarkedText()
            session.textChanged(view.string)
            restyle(view)
        }

        private func currentReveal(_ view: PlainTextView) -> NSRange? {
            view.window?.firstResponder === view && !view.isResigning
                ? NoteTextStyler.revealRange(in: view.string as NSString, selection: view.selectedRange(), marks: view.marks) : nil
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let view = notification.object as? PlainTextView, !view.isTrackingMouse, !view.hasMarkedText()
            else { return }
            // AppKit posts this before `textDidChange`: marks are stale; the full restyle follows.
            // ponytail: a same-length replacement still slips through, it costs one wasted range restyle.
            guard (view.string as NSString).length == markedLength else { return }
            updateReveal(view)
        }

        /// Moves the revealed marks to the caret's line: restyles only the old and new paragraphs.
        func updateReveal(_ view: PlainTextView) {
            guard !view.hasMarkedText() else { return }
            let new = currentReveal(view)
            guard new != lastReveal else { return }
            // Only marker, fence and divider spans change with the reveal: none on either line, nothing to restyle.
            let revealed = { (r: NSRange?) -> Bool in
                guard let r else { return false }
                return view.marks.contains { span in
                    switch span.kind {
                    case .marker, .codeFence, .divider:
                        return NSIntersectionRange(NSRange(location: Int(span.utf16Start), length: Int(span.utf16Len)), r).length > 0
                    default: return false
                    }
                }
            }
            guard revealed(lastReveal) || revealed(new) else { lastReveal = new; return }
            let palette = NoteTextStyler.Palette(ink: Theme.inkNS, rust: Theme.rustNS)
            let tags = tagRanges(text: view.string)
            let text = view.string as NSString
            for r in [lastReveal, new].compactMap({ $0 }) {
                let r = NSIntersectionRange(r, NSRange(location: 0, length: text.length))
                NoteTextStyler.restyle(view, tags: tags, marks: view.marks, reveal: new, palette: palette, in: text.paragraphRange(for: r))
            }
            lastReveal = new
            measurements.invalidate()
            if !applying { session.layoutRevision += 1 }
        }

        /// Dynamic colours: Light/Dark switches redraw them without a restyle.
        func restyle(_ view: PlainTextView) {
            measurements.invalidate()  // every text change and style change comes through here
            let palette = NoteTextStyler.Palette(ink: Theme.inkNS, rust: Theme.rustNS)
            let marks = markdownSpans(text: view.string)
            view.marks = marks
            markedLength = (view.string as NSString).length
            let reveal = currentReveal(view)
            NoteTextStyler.restyle(view, tags: tagRanges(text: view.string), marks: marks, reveal: reveal, palette: palette)
            lastReveal = reveal
        }
    }
}
