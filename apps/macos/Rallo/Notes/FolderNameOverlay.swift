import SwiftUI

/// The New Folder dialog (0019 §10): a card on a blurred backdrop, drawn
/// inside the panel. Everything it shows comes from `FolderNamePrompter`.
struct FolderNameOverlay: View {
    @ObservedObject var prompter: FolderNamePrompter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let request = prompter.request {
                // The panel behind is blurred by NotesView; this only dims it.
                Theme.scrim
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    // Swallows every click; Cancel by backdrop is a no-op while saving.
                    .onTapGesture { prompter.cancel() }
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
                FolderNameCard(prompter: prompter, request: request)
                    .id(request.id)
                    .transition(.asymmetric(
                        insertion: reduceMotion
                            ? .opacity
                            : AnyTransition.scale(scale: 0.94).combined(with: .opacity)
                                .animation(.spring(response: 0.28, dampingFraction: 0.86)),
                        removal: .opacity.animation(.easeIn(duration: 0.12))
                    ))
            }
        }
        .animation(.easeOut(duration: 0.18), value: prompter.request?.id)
    }
}

private struct FolderNameCard: View {
    @ObservedObject var prompter: FolderNamePrompter
    let request: FolderNamePrompter.Request
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name: String
    @State private var shakes = 0
    @FocusState private var focused: Bool

    init(prompter: FolderNamePrompter, request: FolderNamePrompter.Request) {
        self.prompter = prompter
        self.request = request
        _name = State(initialValue: request.initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.rust)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.highlight))
                    .accessibilityHidden(true)
                Text(request.title)
                    .font(Theme.rounded(16, .semibold))
                    .foregroundStyle(Theme.ink)
            }
            field.padding(.top, 14)
            helper.padding(.top, 6)
            buttons.padding(.top, 16)
        }
        .padding(18)
        .frame(width: 292)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
                .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.menuStroke))
        .keyframeAnimator(initialValue: CGFloat(0), trigger: shakes) { content, x in
            content.offset(x: x)
        } keyframes: { _ in
            LinearKeyframe(-6, duration: 0.06)
            LinearKeyframe(6, duration: 0.06)
            LinearKeyframe(-4, duration: 0.06)
            LinearKeyframe(4, duration: 0.06)
            LinearKeyframe(0, duration: 0.06)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(request.title)
        .onExitCommand { prompter.cancel() }
        // Keyed on the count, not the text: an identical repeated error still counts.
        .onChange(of: prompter.errorCount) { _, _ in
            if !reduceMotion { shakes += 1 }
            if let message = prompter.error { AccessibilityNotification.Announcement(message).post() }
            // `.disabled` while saving dropped the field's focus.
            Task { @MainActor in
                await Task.yield()
                focused = true
            }
        }
    }

    private var field: some View {
        TextField("Folder name", text: $name)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($focused)
            .disabled(prompter.isSaving)
            .onSubmit { submit() }
            .onChange(of: name) { _, _ in prompter.clearError() }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        prompter.error != nil ? Theme.error : focused ? Theme.rust : Theme.fieldStroke,
                        lineWidth: prompter.error != nil || focused ? 1.5 : 1
                    )
            )
            .accessibilityLabel("Folder name")
            .onAppear {
                Task { @MainActor in
                    focused = true
                    // The initial name (Rename, later) arrives selected.
                    if !name.isEmpty {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                }
            }
    }

    private var helper: some View {
        ZStack(alignment: .topLeading) {
            if let message = prompter.error {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(message).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.error)
                .transition(.opacity)
            } else {
                Text("Up to 50 characters")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.bark)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: prompter.error)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button { prompter.cancel() } label: {
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.fieldStroke))
            }
            .buttonStyle(PressedFadeStyle())
            .disabled(prompter.isSaving)

            Button { submit() } label: {
                Text(request.confirmTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.onRust)
                    .opacity(prompter.isSaving ? 0 : 1)
                    .overlay {
                        if prompter.isSaving {
                            ProgressView().controlSize(.small).tint(Theme.onRust)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.rust))
            }
            .buttonStyle(PressedFadeStyle())
            .disabled(prompter.isSaving)
        }
    }

    private func submit() {
        let name = name
        Task { await prompter.submit(name) }
    }
}

private struct PressedFadeStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension View {
    /// Draws `prompter`'s card over this view (0019 §10). While it shows, the
    /// view behind is blurred, disabled and hidden from VoiceOver, so nothing
    /// there (an Undo toast, a toolbar button) reacts; when it goes, the
    /// keyboard returns to whatever had it. The panel wires the same fence
    /// itself, because its scope dropdown shares it.
    func folderNamePrompt(_ prompter: FolderNamePrompter) -> some View {
        modifier(FolderNamePromptModifier(prompter: prompter))
    }
}

private struct FolderNamePromptModifier: ViewModifier {
    @ObservedObject var prompter: FolderNamePrompter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The first responder when the card appeared (the list, the text view, …).
    @State private var returnFocus: WeakResponder?

    func body(content: Content) -> some View {
        let shown = prompter.request != nil
        content
            .disabled(shown)
            .accessibilityHidden(shown)
            .blur(radius: shown ? 4 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: shown)
            .overlay { FolderNameOverlay(prompter: prompter) }
            .onChange(of: shown) { _, isShown in
                if isShown {
                    returnFocus = NSApp.keyWindow.map { WeakResponder(window: $0, responder: $0.firstResponder) }
                } else if let saved = returnFocus {
                    returnFocus = nil
                    if let window = saved.window, let responder = saved.responder { window.makeFirstResponder(responder) }
                }
            }
    }
}

private struct WeakResponder {
    weak var window: NSWindow?
    weak var responder: NSResponder?
}
