import SwiftUI

struct NotesView: View {
    @ObservedObject var model: NotesViewModel
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swipeMonitor = SwipeScrollMonitor()
    @StateObject private var agentsClock = AgentsClock()
    @State private var newlineMonitor: Any?
    @State private var dropTargeted = false

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
            let messages = [model.captureError, model.errorMessage].compactMap { $0 }
            if !messages.isEmpty {
                let message = messages.joined(separator: "\n")
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Theme.error)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .accessibilityLabel("Error: \(message)")
            }
        }
        .disabled(model.namePromptShown)
        .accessibilityHidden(model.namePromptShown)
        .blur(radius: model.namePromptShown ? 4 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.namePromptShown)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastBar(message: toast.message, undoable: toast.undo != nil) { Task { await model.undo() } }
                    .id(toast.id)
                    // Its Undo (and ⌘Z) must not fire behind the dialog or dropdown.
                    .disabled(model.namePromptShown || model.scopeMenuOpen)
                    .accessibilityHidden(model.namePromptShown || model.scopeMenuOpen)
                    .padding(12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.toast?.id)
        .foregroundStyle(Theme.ink)
        .frame(width: 360, height: 460)
        .overlay(alignment: .topTrailing) {
            // The content sits below the title bar (full-size content view); the
            // button lives in that strip, centred in it, so it clears the panda.
            GeometryReader { proxy in
                let bar = proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : 28
                Button {
                    model.onExpand()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.bark)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Notes Window")
                .accessibilityLabel("Open Notes Window")
                .frame(height: bar)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .ignoresSafeArea(.container, edges: .top)
            .disabled(model.namePromptShown || model.scopeMenuOpen)
            .accessibilityHidden(model.namePromptShown || model.scopeMenuOpen)
            .blur(radius: model.namePromptShown ? 4 : 0)
        }
        .overlayPreferenceValue(FolderChipAnchorKey.self) { anchor in
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    if model.scopeMenuOpen, let anchor {
                        let chip = proxy[anchor]
                        // Any click outside the menu closes it, the chip's own included.
                        Color.clear
                            .contentShape(Rectangle())
                            .ignoresSafeArea()
                            .onTapGesture { model.closeScopeMenu() }
                        FolderScopeMenu(model: model, chip: chip, panelSize: proxy.size)
                            .offset(
                                x: min(max(chip.minX, 8), 360 - FolderScopeMenu.width - 8),
                                y: chip.maxY + 6
                            )
                            .transition(.asymmetric(
                                insertion: reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(
                    model.scopeMenuOpen ? .easeOut(duration: 0.16) : .easeIn(duration: 0.10),
                    value: model.scopeMenuOpen
                )
            }
        }
        .overlay { FolderNameOverlay(prompter: model.namePrompter) }
        .background(Theme.surface)
        .onChange(of: model.focusToken) { _, _ in
            if model.namePrompter.request == nil { composerFocused = true }
        }
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
                HStack(spacing: 8) {
                    FolderChip(model: model)
                    Text(model.scopeCountLine)
                        .font(Theme.rounded(13))
                        .foregroundStyle(Theme.bark)
                        .lineLimit(1)
                        .fixedSize()
                }
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

    private var hasDraft: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.stagedImages.isEmpty
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.stagedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.stagedImages.enumerated()), id: \.element.id) { index, image in
                            StagedThumbnail(image: image, label: "Image \(index + 1) of \(model.stagedImages.count)") {
                                model.unstage(image.id)
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(text: $model.draft, prompt: Text(model.stagedImages.isEmpty ? model.composerPlaceholder : "Add a note, or press Return").foregroundStyle(Theme.bark), axis: .vertical) {
                    Text("New note")
                }
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...5)
                .focused($composerFocused)
                .onAppear {
                    // ⇧↩ inserts a line break (0018), as ⌥↩ already does; ↩ saves.
                    newlineMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        // Local monitors see every window (popovers, Settings): act on the notes panel only.
                        guard event.window is NotesWindow else { return event }
                        // Nothing behind the dialog or dropdown reacts.
                        guard !model.namePromptShown, !model.scopeMenuOpen else { return event }
                        if composerFocused, flags == .command, event.charactersIgnoringModifiers == "v",
                           model.pasteImages(from: .general) {
                            return nil
                        }
                        if !composerFocused, !model.thumbnailFocused, model.editingID == nil, event.keyCode == 49, flags.isEmpty,
                           !(event.window?.firstResponder is NSText),
                           let item = model.items.first(where: { $0.id == model.expandedID }), !item.images.isEmpty {
                            QuickLookPresenter.shared.toggle(item.images)
                            return nil
                        }
                        guard composerFocused, event.keyCode == 36, flags == .shift else { return event }
                        NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                        return nil
                    }
                }
                .onDisappear {
                    if let newlineMonitor { NSEvent.removeMonitor(newlineMonitor) }
                    newlineMonitor = nil
                }
                .onSubmit { Task { await model.save() } }
                .accessibilityLabel("New note")
                .accessibilityHint("Press Return to save, Shift-Return for a new line")

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
            if composerFocused {
                Text("⇧↩ new line")
                    .font(Theme.rounded(11))
                    .foregroundStyle(Theme.bark)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(composerFocused || dropTargeted ? Theme.rust : Theme.fieldStroke, lineWidth: composerFocused || dropTargeted ? 1.5 : 1)
        )
        .onDrop(of: [.image], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in model.stage(await ImageClipboard.load(providers)) }
            return true
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hasDraft)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func scrollToHighlight(_ proxy: ScrollViewProxy) {
        guard let id = model.highlightedItemID, model.items.contains(where: { $0.id == id }) else { return }
        withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id, anchor: .center) }
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
            // A list built (or refilled by a scope switch) with the highlight already set
            // gets no highlight change, so scroll to it here too.
            .onAppear { scrollToHighlight(proxy) }
            .onChange(of: model.items.map(\.id)) { _, _ in scrollToHighlight(proxy) }
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

/// A transient message with an optional Undo, at the bottom of the panel and
/// of the notes window's list (0019 §11).
struct ToastBar: View {
    let message: String
    let undoable: Bool
    /// ⌘Z presses Undo in the panel; in the notes window ⌘Z belongs to the text.
    var undoShortcut = true
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if undoable {
                Button("Undo", action: undo)
                    .buttonStyle(.plain)
                    .font(Theme.rounded(13, .semibold))
                    .foregroundStyle(Theme.toastAccent)
                    .keyboardShortcut(undoShortcut ? KeyboardShortcut("z", modifiers: .command) : nil)
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

/// A staged image in the note field: 44 pt, rounded, × to remove (0018).
private struct StagedThumbnail: View {
    let image: StagedImage
    let label: String
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = image.thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").foregroundStyle(Theme.bark)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.fieldStroke))

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.onToast)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Theme.toast))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .accessibilityLabel("Remove \(label)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}
