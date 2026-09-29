import SwiftUI

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var items: [ItemSnapshot] = []
    @Published var draft = ""
    @Published var errorMessage: String?
    @Published var highlightedItemID: String?
    @Published var focusToken = 0

    private let core: CoreClient

    init(core: CoreClient) {
        self.core = core
    }

    func requestFocus() {
        focusToken += 1
    }

    func reload() async {
        do {
            items = try await core.openItems()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t load notes: \(error.localizedDescription)"
        }
    }

    func save() async {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let item = try await core.createNote(text)
            draft = ""
            highlightedItemID = item.id
            await reload()
        } catch let error as RalloError {
            errorMessage = error.displayMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension RalloError {
    var displayMessage: String {
        switch self {
        case let .InvalidInput(_, message), let .NotFound(_, message), let .Storage(_, message),
             let .IncompatibleSchema(_, _, message):
            return message
        }
    }
}

struct NotesView: View {
    @ObservedObject var model: NotesViewModel
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            composer
            Divider().opacity(0.4)
            if model.items.isEmpty {
                EmptyNotesView()
            } else {
                list
            }
            if let message = model.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(10)
                    .accessibilityLabel("Error: \(message)")
            }
        }
        .frame(minWidth: 320, minHeight: 360)
        .background(
            LinearGradient(colors: [Color(red: 1.0, green: 0.96, blue: 0.91), Color(red: 0.99, green: 0.90, blue: 0.82)],
                           startPoint: .top, endPoint: .bottom)
        )
        .onChange(of: model.focusToken) { _, _ in composerFocused = true }
        .onAppear { composerFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: Bundle.main.image(forResource: "pet-idle") ?? NSImage())
                .resizable()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Rallo").font(.headline)
                Text(model.items.isEmpty ? "All clear" : "\(model.items.count) open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .padding(.bottom, 10)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Jot something down…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($composerFocused)
                .onSubmit { Task { await model.save() } }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.85)))
                .accessibilityLabel("New note")
            Button {
                Task { await model.save() }
            } label: {
                Image(systemName: "plus.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(red: 0.84, green: 0.45, blue: 0.22))
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Save note")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(model.items, id: \.id) { item in
                NoteRow(item: item, highlighted: item.id == model.highlightedItemID)
                    .id(item.id)
                    .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: model.highlightedItemID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

private struct NoteRow: View {
    let item: ItemSnapshot
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.text)
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(item.displayId).font(.caption.monospaced())
                Text("·")
                Text(Date(timeIntervalSince1970: TimeInterval(item.createdAtMs) / 1000), style: .relative)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Color.orange.opacity(0.18) : .clear))
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyNotesView: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: Bundle.main.image(forResource: "pet-sleep") ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Nothing on your mind").font(.title3.weight(.semibold))
            Text("Type a note above, or run `rallo note \"…\"` in a terminal.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
