import SwiftUI

/// The chip's bounds, so the dropdown can sit under it (0019 §10).
struct FolderChipAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The folder dropdown (mockup B `.menu`): drawn inside the panel so a long
/// folder name can never carry it past the panel's edge, as a native menu would.
struct FolderScopeMenu: View {
    @ObservedObject var model: NotesViewModel
    let chip: CGRect
    let panelSize: CGSize

    static let width: CGFloat = 214
    private static let rowHeight: CGFloat = 24
    /// Padding, both pinned rows and both separators (1 pt line + 5 pt margins).
    private static let pinnedHeight: CGFloat = 10 + rowHeight * 2 + 11 * 2

    @FocusState private var focused: Bool
    @State private var highlighted: Int?

    private var items: [ScopeMenuItem] {
        model.overview.map { FolderMenus.scopeItems(current: model.scope, overview: $0) } ?? []
    }

    var body: some View {
        let items = items
        // Selectable rows: every scope, then New Folder….
        let rowCount = items.count + 1
        let folderRows = Array(items.enumerated().dropFirst())
        let top = chip.maxY + 6
        let available = panelSize.height - 12 - top - Self.pinnedHeight
        let folderHeight = min(CGFloat(folderRows.count) * Self.rowHeight, max(Self.rowHeight, available))

        VStack(spacing: 0) {
            if let first = items.first {
                row(first, index: 0)
                separator
            }
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(folderRows, id: \.offset) { index, item in
                            row(item, index: index).id(index)
                        }
                    }
                }
                .frame(height: folderHeight)
                .onChange(of: highlighted) { _, index in
                    if let index { proxy.scrollTo(index) }
                }
            }
            separator
            MenuRow(
                title: "New Folder…", count: nil, symbol: nil, checked: false,
                highlighted: highlighted == items.count, accessibilityLabel: "New Folder…"
            )
            .onHover { if $0 { highlighted = items.count } }
            .onTapGesture { activate(items.count) }
            .accessibilityAction { activate(items.count) }
        }
        .padding(5)
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.menu))
        )
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.menuStroke))
        .shadow(color: .black.opacity(0.25), radius: 17, y: 12)
        .onHover { if !$0 { highlighted = nil } }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        // Deferred: set during the appear pass, focus doesn't stick after a mouse click.
        .onAppear { Task { @MainActor in focused = true } }
        .onKeyPress(.downArrow) { move(forward: true, count: rowCount); return .handled }
        .onKeyPress(.upArrow) { move(forward: false, count: rowCount); return .handled }
        .onKeyPress(.return) { activateHighlighted() }
        .onKeyPress(.space) { activateHighlighted() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folders")
    }

    private var separator: some View {
        Rectangle().fill(Theme.menuStroke).frame(height: 1).padding(.horizontal, 6).padding(.vertical, 5)
    }

    private func row(_ item: ScopeMenuItem, index: Int) -> some View {
        MenuRow(
            title: item.title, count: item.count, symbol: item.symbol, checked: item.checked,
            highlighted: highlighted == index,
            accessibilityLabel: "\(item.title), \(NotesScope.countLine(open: item.count))"
        )
        .onHover { if $0 { highlighted = index } }
        .onTapGesture { activate(index) }
        .accessibilityAction { activate(index) }
    }

    private func move(forward: Bool, count: Int) {
        highlighted = MenuHighlight.next(from: highlighted, count: count, forward: forward)
    }

    private func activateHighlighted() -> KeyPress.Result {
        guard let highlighted else { return .ignored }
        activate(highlighted)
        return .handled
    }

    private func activate(_ index: Int) {
        let items = items
        if index < items.count {
            model.closeScopeMenu()
            let scope = items[index].scope
            Task { await model.setScope(scope) }
        } else {
            // The dialog takes the keyboard itself; refocusing the note field would race it.
            model.closeScopeMenu(refocus: false)
            Task { await model.newFolderAndSwitch() }
        }
    }
}

private struct MenuRow: View {
    let title: String
    /// nil for New Folder…, which has neither icon nor count.
    let count: Int?
    let symbol: String?
    let checked: Bool
    let highlighted: Bool
    let accessibilityLabel: String

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if checked { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
            }
            .frame(width: 13)
            .padding(.trailing, 5)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(highlighted ? Color.white : Theme.rust)
                    .frame(width: 14)
                    .padding(.trailing, 7)
            }
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)
            Spacer(minLength: 14)
            if let count {
                Text("\(count)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(highlighted ? Color.white.opacity(0.85) : Theme.bark)
            }
        }
        .foregroundStyle(highlighted ? Color.white : Theme.ink)
        .padding(.leading, 6)
        .padding(.trailing, 9)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(highlighted ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(checked ? [.isButton, .isSelected] : .isButton)
    }
}
