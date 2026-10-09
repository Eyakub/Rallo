import SwiftUI

/// "Remind Me → Custom…" (0016): type a time, see when it lands, set it.
/// Shared by the panel's rows and the notes window; the caller says what
/// setting and cancelling do.
struct CustomRemindPopover: View {
    let onSet: (Date) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var preview: CustomRemindPreview { CustomRemindPreview(text: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("When?", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(set)
            Text(preview.message)
                .font(.caption)
                .foregroundStyle(preview.date == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Set", action: set)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.date == nil)
            }
        }
        .padding(12)
        .frame(width: 260)
        .onAppear { focused = true }
        .onExitCommand(perform: onCancel)
    }

    private func set() {
        // Recomputed now, so a preview left open still sets the time it says.
        guard let date = CustomRemindPreview(text: text).date else { return }
        onSet(date)
    }
}
