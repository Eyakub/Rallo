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
        case let .InvalidInput(_, message), let .NotFound(_, message), let .Conflict(_, message),
             let .Storage(_, message), let .IncompatibleSchema(_, _, message):
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
            if model.items.isEmpty {
                EmptyNotesView()
            } else {
                list
            }
            if let message = model.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Theme.error)
                    .padding(10)
                    .accessibilityLabel("Error: \(message)")
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .frame(minWidth: 320, minHeight: 360)
        .background(Theme.background)
        .onChange(of: model.focusToken) { _, _ in composerFocused = true }
        .onAppear { composerFocused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: Bundle.main.image(forResource: "pet-idle") ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 47)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Rallo").font(.title3.weight(.semibold))
                Text(model.items.isEmpty ? "All clear" : "\(model.items.count) open")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 30)
        .padding(.bottom, 12)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(text: $model.draft, prompt: Text("Jot something down…").foregroundStyle(Theme.textSecondary), axis: .vertical) {
                Text("New note")
            }
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .focused($composerFocused)
            .onSubmit { Task { await model.save() } }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.fieldBorder, lineWidth: 1))
            .accessibilityLabel("New note")
            Button {
                Task { await model.save() }
            } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 24))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .opacity(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Save note")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.items, id: \.id) { item in
                        NoteRow(item: item, highlighted: item.id == model.highlightedItemID)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            .onChange(of: model.highlightedItemID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

private struct NoteRow: View {
    let item: ItemSnapshot
    let highlighted: Bool

    private var created: Date { Date(timeIntervalSince1970: TimeInterval(item.createdAtMs) / 1000) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.text)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(item.displayId).font(.caption.monospaced())
                Text("·")
                Text(created, format: .relative(presentation: .named, unitsStyle: .abbreviated))
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(highlighted ? Theme.rowHighlight : Theme.row))
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyNotesView: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            // Uses the idle art until matching sleep-pose art exists.
            Image(nsImage: Bundle.main.image(forResource: "pet-idle") ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 120)
                .accessibilityHidden(true)
            Text("Nothing on your mind").font(.title3.weight(.semibold))
            Text("Type a note above, or run `rallo note \"…\"` in a terminal.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
