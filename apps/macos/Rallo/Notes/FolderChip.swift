import SwiftUI

/// `[folder] Work ⌄` under the "Notes" title (0019 §10, mockup B). Its menu
/// picks the scope or makes a new folder.
struct FolderChip: View {
    @ObservedObject var model: NotesViewModel

    var body: some View {
        Menu {
            if let overview = model.overview {
                let items = FolderMenus.scopeItems(current: model.scope, overview: overview)
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    MenuChoice(title: item.title, checked: item.checked) { Task { await model.setScope(item.scope) } }
                    if index == 0 { Divider() }
                }
                Divider()
            }
            Button("New Folder…") { Task { await model.newFolderAndSwitch() } }
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
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a folder")
        .accessibilityLabel("Folder: \(model.scopeTitle)")
    }
}
