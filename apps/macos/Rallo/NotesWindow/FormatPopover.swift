import AppKit
import SwiftUI

/// The toolbar's "Aa" popover (0023 §5): paragraph styles, inline marks and lists.
/// Actions go straight to the text view: this popover's window can become key,
/// so a responder-chain send would miss it.
struct FormatPopover: View {
    let textView: PlainTextView?
    /// Bumped after each click so the on-states are read again.
    @State private var tick = 0

    private struct Entry: Identifiable {
        let title: String
        let symbol: String
        let shortcut: String
        let action: Selector
        var id: String { title }
        var help: String { shortcut.isEmpty ? title : "\(title) \(shortcut)" }
    }

    private let styles: [(title: String, shortcut: String, action: Selector)] = [
        ("Heading", "⇧⌘H", #selector(PlainTextView.formatHeading(_:))),
        ("Subheading", "⇧⌘J", #selector(PlainTextView.formatSubheading(_:))),
        ("Body", "⇧⌘B", #selector(PlainTextView.formatBody(_:))),
        ("Monostyled", "⇧⌘M", #selector(PlainTextView.formatMonostyled(_:))),
    ]
    private let marks: [Entry] = [
        Entry(title: "Bold", symbol: "bold", shortcut: "⌘B", action: #selector(PlainTextView.formatBold(_:))),
        Entry(title: "Italic", symbol: "italic", shortcut: "⌘I", action: #selector(PlainTextView.formatItalic(_:))),
        Entry(title: "Strikethrough", symbol: "strikethrough", shortcut: "⇧⌘X", action: #selector(PlainTextView.formatStrikethrough(_:))),
        Entry(title: "Code", symbol: "chevron.left.forwardslash.chevron.right", shortcut: "⌘E", action: #selector(PlainTextView.formatCode(_:))),
        Entry(title: "Link", symbol: "link", shortcut: "⌘K", action: #selector(PlainTextView.formatAddLink(_:))),
    ]
    private let blocks: [Entry] = [
        Entry(title: "Bulleted List", symbol: "list.bullet", shortcut: "⇧⌘7", action: #selector(PlainTextView.formatBulletedList(_:))),
        Entry(title: "Numbered List", symbol: "list.number", shortcut: "⇧⌘9", action: #selector(PlainTextView.formatNumberedList(_:))),
        Entry(title: "Checklist", symbol: "checklist", shortcut: "⇧⌘L", action: #selector(PlainTextView.formatChecklist(_:))),
        Entry(title: "Block Quote", symbol: "text.quote", shortcut: "⌘'", action: #selector(PlainTextView.formatBlockQuote(_:))),
        Entry(title: "Increase Indent", symbol: "increase.indent", shortcut: "⌘]", action: #selector(PlainTextView.formatIncreaseIndent(_:))),
    ]

    private func isOn(_ action: Selector) -> Bool {
        _ = tick
        return textView?.isActive(action) ?? false
    }

    private func send(_ action: Selector) {
        guard let textView else { return }
        NSApp.sendAction(action, to: textView, from: nil)
        textView.window?.makeFirstResponder(textView)
        tick += 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                ForEach(styles, id: \.title) { style in
                    Button { send(style.action) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .opacity(isOn(style.action) ? 1 : 0)
                                .frame(width: 14)
                                .accessibilityHidden(true)
                            Text(style.title).font(Theme.rounded(13, .medium))
                            Spacer(minLength: 16)
                            Text(style.shortcut).font(.system(size: 12)).foregroundStyle(Theme.bark)
                        }
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.title)
                    .accessibilityAddTraits(isOn(style.action) ? .isSelected : [])
                }
            }
            Divider()
            row(marks)
            row(blocks)
        }
        .padding(10)
        .frame(width: 240)
    }

    private func row(_ entries: [Entry]) -> some View {
        HStack(spacing: 6) {
            ForEach(entries) { entry in
                let on = isOn(entry.action)
                Button { send(entry.action) } label: {
                    Image(systemName: entry.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? Theme.rust : Theme.ink)
                        .frame(width: 36, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.selection : Theme.hover))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(entry.help)
                .accessibilityLabel(entry.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
