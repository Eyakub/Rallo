import SwiftUI

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var items: [ItemSnapshot] = []
    @Published var draft = ""
    @Published var errorMessage: String?
    @Published var highlightedItemID: String?
    @Published var completingIDs: Set<String> = []
    /// The last note marked done from the panel, offered for undo.
    @Published var undoable: ItemSnapshot?
    /// At most one row shows its full text; at most one is being edited.
    @Published var expandedID: String?
    @Published var editingID: String?
    @Published var editDraft = ""
    @Published var focusToken = 0

    private let core: CoreClient
    private var highlightTask: Task<Void, Never>?
    private var undoTask: Task<Void, Never>?

    init(core: CoreClient) {
        self.core = core
    }

    func requestFocus() {
        focusToken += 1
    }

    /// Highlights a row briefly (a just-saved note, or the item a
    /// notification pointed at), then lets it settle back.
    func highlight(_ id: String?, for seconds: Double = 2) {
        highlightTask?.cancel()
        highlightedItemID = id
        guard id != nil else { return }
        highlightTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.highlightedItemID = nil
        }
    }

    func toggleExpanded(_ item: ItemSnapshot) {
        if expandedID == item.id {
            expandedID = nil
            editingID = nil
        } else {
            expandedID = item.id
            editingID = nil
        }
    }

    func beginEditing(_ item: ItemSnapshot) {
        expandedID = item.id
        editDraft = item.text
        editingID = item.id
    }

    func cancelEditing() {
        editingID = nil
    }

    func saveEdit(_ item: ItemSnapshot) async {
        let text = editDraft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let updated = try await core.editItemText(item, text: text)
            editingID = nil
            await reload()
            highlight(updated.id)
        } catch let error as RalloError {
            if case let .Conflict(code, _) = error, code == "REVISION_CONFLICT" {
                errorMessage = "That note changed elsewhere; here’s the latest. Your edit wasn’t saved."
                editingID = nil
            } else {
                errorMessage = error.displayMessage
            }
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Esc steps back one level: stop editing, then collapse, then close.
    /// Returns whether it handled the key.
    func handleEscape() -> Bool {
        if editingID != nil {
            editingID = nil
            return true
        }
        if expandedID != nil {
            expandedID = nil
            return true
        }
        return false
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
            await reload()
            highlight(item.id)
        } catch let error as RalloError {
            errorMessage = error.displayMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Shows the check first, then removes the row, so the action reads.
    func complete(_ item: ItemSnapshot) async {
        completingIDs.insert(item.id)
        try? await Task.sleep(nanoseconds: 450_000_000)
        defer { completingIDs.remove(item.id) }
        do {
            let done = try await core.completeItem(item)
            offerUndo(done)
            await reload()
        } catch let error as RalloError {
            if case let .Conflict(code, _) = error, code == "REVISION_CONFLICT" {
                errorMessage = "That note changed elsewhere; here’s the latest."
            } else {
                errorMessage = error.displayMessage
            }
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undo() async {
        guard let item = undoable else { return }
        undoTask?.cancel()
        undoable = nil
        do {
            let reopened = try await core.reopenItem(item)
            await reload()
            highlight(reopened.id)
        } catch let error as RalloError {
            errorMessage = error.displayMessage
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func offerUndo(_ item: ItemSnapshot) {
        undoTask?.cancel()
        undoable = item
        undoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.undoable = nil
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .accessibilityLabel("Error: \(message)")
            }
        }
        .overlay(alignment: .bottom) {
            if let item = model.undoable {
                UndoBar(item: item) { Task { await model.undo() } }
                    .padding(12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.undoable?.id)
        .foregroundStyle(Theme.ink)
        .frame(width: 360, height: 460)
        .background(Theme.surface)
        .onChange(of: model.focusToken) { _, _ in composerFocused = true }
        .onAppear { composerFocused = true }
    }

    /// Title on the left; the panda perches on the note field at the right.
    private var header: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Notes").font(Theme.rounded(22, .semibold))
                Text(countLine)
                    .font(Theme.rounded(13))
                    .foregroundStyle(Theme.bark)
            }
            .padding(.bottom, 12)
            Spacer(minLength: 0)
            Image(nsImage: Bundle.main.image(forResource: "pet-idle") ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96)
                // Feet and contact shadow rest on the field's top edge.
                .offset(y: 7)
                .zIndex(1)
                .accessibilityHidden(true)
        }
        .padding(.leading, 20)
        .padding(.trailing, 26)
        .padding(.top, 6)
        .zIndex(1)
    }

    private var countLine: String {
        switch model.items.count {
        case 0: "Nothing held right now"
        case 1: "1 open note"
        case let count: "\(count) open notes"
        }
    }

    /// A question prompts offloading what's on someone's mind better than a
    /// label does; it changes only with whether notes already exist.
    private var prompt: String {
        model.items.isEmpty ? "What’s on your mind?" : "Something else on your mind?"
    }

    private var hasDraft: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(text: $model.draft, prompt: Text(prompt).foregroundStyle(Theme.bark), axis: .vertical) {
                Text("New note")
            }
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(1...5)
            .focused($composerFocused)
            .onSubmit { Task { await model.save() } }
            .accessibilityLabel("New note")
            .accessibilityHint("Press Return to save")

            if hasDraft {
                Button {
                    Task { await model.save() }
                } label: {
                    Text("Save")
                        .font(Theme.rounded(12, .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.rust))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Save note")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(composerFocused ? Theme.rust : Theme.fieldStroke, lineWidth: composerFocused ? 1.5 : 1)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hasDraft)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            // Inset to the text column, as in Reminders.
                            Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 44).padding(.trailing, 10)
                        }
                        NoteRow(item: item, model: model)
                        .id(item.id)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, model.undoable == nil ? 8 : 64)
            }
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85), value: model.items.map(\.id))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: model.highlightedItemID)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88), value: model.expandedID)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.editingID)
            .onChange(of: model.highlightedItemID) { _, id in
                if let id { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

private struct UndoBar: View {
    let item: ItemSnapshot
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Marked “\(item.text.trimmingCharacters(in: .whitespacesAndNewlines))” as done")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Undo", action: undo)
                .buttonStyle(.plain)
                .font(Theme.rounded(13, .semibold))
                .foregroundStyle(Theme.toastAccent)
                .keyboardShortcut("z", modifiers: .command)
        }
        .font(Theme.rounded(13))
        .foregroundStyle(Theme.onToast)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.toast))
        .accessibilityElement(children: .contain)
    }
}

private struct EmptyNotesView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes you add here stay with Rallo until you mark them done.")
                .font(Theme.rounded(15, .medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text("From a terminal:")
                Text("rallo note \"…\"")
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.hover))
            }
            .font(Theme.rounded(13))
            .foregroundStyle(Theme.bark)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
