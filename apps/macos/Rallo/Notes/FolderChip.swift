import SwiftUI

/// `[folder] Work ⌄` under the "Notes" title (0019 §10, mockup B). It opens
/// the in-panel folder dropdown (`FolderScopeMenu`, drawn by `NotesView`).
struct FolderChip: View {
    @ObservedObject var model: NotesViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let open = model.scopeMenuOpen
        Button {
            if open { model.closeScopeMenu() } else { model.scopeMenuOpen = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.scope.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.rust)
                Text(model.scopeTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.bark)
                    .rotationEffect(.degrees(open && !reduceMotion ? 180 : 0))
                    .animation(.easeOut(duration: 0.16), value: open)
            }
            .font(Theme.rounded(12.5, .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.leading, 7)
            .padding(.trailing, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.hover))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.fieldStroke))
            // A long folder name must not push the count line or the pet.
            .frame(maxWidth: 110, alignment: .leading)
            // Mockup `.chip.open`: a 2 pt rust outline, 1 pt off the chip.
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.rust, lineWidth: 2)
                    .padding(-3)
                    .opacity(open ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: open)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .anchorPreference(key: FolderChipAnchorKey.self, value: .bounds) { $0 }
        .help("Choose a folder")
        .accessibilityLabel("Folder: \(model.scopeTitle)")
        .accessibilityHint("Shows folders")
    }
}
