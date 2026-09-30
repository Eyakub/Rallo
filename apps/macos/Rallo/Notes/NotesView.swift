import SwiftUI

/// Quick reminder choices offered by the swipe and the context menu.
enum RemindPreset: CaseIterable, Identifiable {
    case inTwentyMinutes, inOneHour, tomorrowMorning

    var id: Self { self }

    var title: String {
        switch self {
        case .inTwentyMinutes: "In 20 Minutes"
        case .inOneHour: "In 1 Hour"
        case .tomorrowMorning: "Tomorrow at 9:00"
        }
    }

    var shortTitle: String {
        switch self {
        case .inTwentyMinutes: "20 min"
        case .inOneHour: "1 hour"
        case .tomorrowMorning: "Tomorrow"
        }
    }

    var symbol: String {
        switch self {
        case .inTwentyMinutes: "bell"
        case .inOneHour: "clock"
        case .tomorrowMorning: "sunrise"
        }
    }

    static func tomorrowMorning(after now: Date = .now, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
    }
}

/// A transient confirmation at the bottom of the panel, optionally undoable.
struct Toast: Identifiable {
    enum Undo {
        case reopen(ItemSnapshot)
        case restore(ItemSnapshot)
    }

    let id = UUID()
    let message: String
    let undo: Undo?
}

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var items: [ItemSnapshot] = []
    @Published var agentSessions: [AgentSessionSnapshot] = []
    @Published var draft = ""
    @Published var errorMessage: String?
    @Published var highlightedItemID: String?
    @Published var completingIDs: Set<String> = []
    /// The last panel action: "done" and "deleted" can be undone.
    @Published var toast: Toast?
    /// At most one row shows its full text; at most one is being edited.
    @Published var expandedID: String?
    @Published var editingID: String?
    @Published var editDraft = ""
    @Published var focusToken = 0
    /// Swipe state: at most one row shows a tray; `liveSwipe` follows the
    /// pointer or fingers while a swipe is in progress.
    @Published var openSwipe: OpenSwipe?
    @Published var liveSwipe: (id: String, offset: CGFloat)?
    var hoveredID: String?
    var rowWidth: CGFloat = 340
    @Published var authorization: NotificationAuthorization?
    /// Asks for permission (never asked yet) or opens System Settings (denied).
    var onEnableNotifications: () -> Void = {}

    /// Reminders exist but macOS won't show their alerts.
    var alertsBlocked: Bool {
        guard authorization == .denied || authorization == .notDetermined else { return false }
        return items.contains { $0.reminder?.state == .active }
    }

    private let core: CoreClient
    private var highlightTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

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

    func swipeOffset(for id: String) -> CGFloat {
        if let live = liveSwipe, live.id == id { return live.offset }
        return SwipeMetrics.restingOffset(openSwipe?.id == id ? openSwipe?.side : nil)
    }

    func trackSwipe(_ id: String, offset: CGFloat) {
        if let open = openSwipe, open.id != id { openSwipe = nil }
        liveSwipe = (id, SwipeMetrics.rubberBanded(offset, rowWidth: rowWidth))
    }

    /// Settles a released swipe: open a tray, close it, or — pulled far
    /// enough left — delete (undoable).
    func endSwipe(_ item: ItemSnapshot, offset: CGFloat, projected: CGFloat) {
        let settled = SwipeMetrics.rubberBanded(offset, rowWidth: rowWidth)
        if settled <= -rowWidth * SwipeMetrics.fullDeleteFraction {
            liveSwipe = (item.id, -rowWidth)
            openSwipe = nil
            Task { await delete(item) }
            return
        }
        let target = abs(projected - offset) > abs(settled) ? projected : settled
        let side: SwipeSide? = if target > SwipeMetrics.remindWidth / 3 {
            .remind
        } else if target < -SwipeMetrics.deleteWidth / 2 {
            .delete
        } else {
            nil
        }
        openSwipe = side.map { OpenSwipe(id: item.id, side: $0) }
        liveSwipe = nil
    }

    /// Esc steps back one level: close a swipe tray, stop editing, then
    /// collapse, then close. Returns whether it handled the key.
    func handleEscape() -> Bool {
        if openSwipe != nil {
            openSwipe = nil
            return true
        }
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
            agentSessions = try await core.agentSessions()
            authorization = try await core.notificationAuthorization()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t load notes: \(error.localizedDescription)"
        }
    }

    /// Brings the session's terminal app forward; a no-op if Rallo couldn't
    /// identify one (`appPath` is nil, so the row isn't clickable).
    func activateAgent(_ session: AgentSessionSnapshot) {
        guard let appPath = session.appPath else { return }
        AgentSessionActivation.activate(appPath: appPath)
    }

    func dismissAgent(_ session: AgentSessionSnapshot) async {
        do {
            _ = try await core.dismissAgentSession(session)
            await reload()
        } catch {
            await report(error)
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
            show(Toast(message: "Marked “\(NoteParts(done.text).title)” as done", undo: .reopen(done)))
            await reload()
        } catch {
            await report(error)
        }
    }

    /// Soft delete; the toast's Undo restores it (its reminder stays off).
    func delete(_ item: ItemSnapshot) async {
        do {
            let deleted = try await core.deleteItem(item)
            if openSwipe?.id == item.id { openSwipe = nil }
            if liveSwipe?.id == item.id { liveSwipe = nil }
            if expandedID == item.id { expandedID = nil }
            if editingID == item.id { editingID = nil }
            show(Toast(message: "Deleted “\(NoteParts(deleted.text).title)”", undo: .restore(deleted)))
            await reload()
        } catch {
            await report(error)
        }
    }

    func remind(_ item: ItemSnapshot, _ preset: RemindPreset) async {
        do {
            let updated: ItemSnapshot
            switch preset {
            case .inTwentyMinutes: updated = try await core.remindIn(item, duration: "20m")
            case .inOneHour: updated = try await core.remindIn(item, duration: "1h")
            case .tomorrowMorning: updated = try await core.remindAt(item, date: RemindPreset.tomorrowMorning())
            }
            if let reminder = updated.reminder {
                show(Toast(message: "Reminder set for \(ReminderLabel.text(for: reminder.deadline))", undo: nil))
            }
            await reload()
            highlight(updated.id)
        } catch {
            await report(error)
        }
    }

    func snooze(_ item: ItemSnapshot) async {
        do {
            let snoozed = try await core.snoozeReminder(item, duration: "10m")
            if let reminder = snoozed.reminder {
                show(Toast(message: "Snoozed until \(ReminderLabel.text(for: reminder.deadline))", undo: nil))
            }
            await reload()
        } catch {
            await report(error)
        }
    }

    /// Stops the reminder alerting; the note itself stays open.
    func dismissReminder(_ item: ItemSnapshot) async {
        do {
            _ = try await core.acknowledgeReminder(item)
            await reload()
        } catch {
            await report(error)
        }
    }

    func undo() async {
        guard let undo = toast?.undo else { return }
        toastTask?.cancel()
        toast = nil
        do {
            let item: ItemSnapshot
            switch undo {
            case let .reopen(done): item = try await core.reopenItem(done)
            case let .restore(deleted): item = try await core.restoreItem(deleted)
            }
            await reload()
            highlight(item.id)
        } catch {
            await report(error)
        }
    }

    /// A plain message in the toast position (nothing to undo).
    func inform(_ message: String) {
        show(Toast(message: message, undo: nil))
    }

    private func show(_ toast: Toast) {
        toastTask?.cancel()
        self.toast = toast
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func report(_ error: Error) async {
        if let error = error as? RalloError {
            if case let .Conflict(code, _) = error, code == "REVISION_CONFLICT" {
                errorMessage = "That note changed elsewhere; here’s the latest."
            } else {
                errorMessage = error.displayMessage
            }
        } else {
            errorMessage = error.localizedDescription
        }
        await reload()
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
    @State private var swipeMonitor = SwipeScrollMonitor()
    @StateObject private var agentsClock = AgentsClock()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            composer
            if model.alertsBlocked, let authorization = model.authorization {
                AlertsBlockedBanner(authorization: authorization, action: model.onEnableNotifications)
            }
            if !model.agentSessions.isEmpty {
                AgentsSection(sessions: model.agentSessions, now: agentsClock.now, onActivate: model.activateAgent) {
                    session in Task { await model.dismissAgent(session) }
                }
            }
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
            if let toast = model.toast {
                ToastBar(toast: toast) { Task { await model.undo() } }
                    .id(toast.id)
                    .padding(12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.toast?.id)
        .foregroundStyle(Theme.ink)
        .frame(width: 360, height: 460)
        .background(Theme.surface)
        .onChange(of: model.focusToken) { _, _ in composerFocused = true }
        .onAppear {
            composerFocused = true
            swipeMonitor.start(model: model)
            agentsClock.start()
        }
        .onDisappear {
            swipeMonitor.stop()
            agentsClock.stop()
        }
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
                        SwipeableRow(item: item, model: model) {
                            NoteRow(item: item, model: model)
                        }
                        .id(item.id)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, model.toast == nil ? 8 : 64)
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

/// One explanation for every "won't alert" row, with the way to fix it.
private struct AlertsBlockedBanner: View {
    let authorization: NotificationAuthorization
    let action: () -> Void

    private var denied: Bool { authorization == .denied }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.rust)
                .accessibilityHidden(true)
            Text(denied
                 ? "Reminders won’t alert you: notifications for Rallo are off in System Settings."
                 : "Reminders won’t alert you until you allow notifications.")
                .font(Theme.rounded(12))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: action) {
                Text(denied ? "Turn On" : "Allow")
                    .font(Theme.rounded(12, .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.swipeSoon))
            }
            .buttonStyle(.plain)
            .help(denied ? "Opens Rallo’s notification settings" : "Asks macOS for permission to show alerts")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.highlight))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct ToastBar: View {
    let toast: Toast
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if toast.undo != nil {
                Button("Undo", action: undo)
                    .buttonStyle(.plain)
                    .font(Theme.rounded(13, .semibold))
                    .foregroundStyle(Theme.toastAccent)
                    .keyboardShortcut("z", modifiers: .command)
            }
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
