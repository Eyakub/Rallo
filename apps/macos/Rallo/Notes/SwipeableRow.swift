import AppKit
import SwiftUI

/// Where an expanded row's image strip sits, in the row's coordinate space.
/// A mouse drag that starts there drags an image out: AppKit takes it over
/// and the row's gesture never ends, so it must not swipe the row.
struct ImageStripFrameKey: PreferenceKey {
    static let space = "swipeableRow"
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

/// Swipe right for reminder presets, left to delete. Works with a mouse
/// (click and drag) and a trackpad (two-finger swipe, via `SwipeScrollMonitor`),
/// because SwiftUI's `swipeActions` only responds to the trackpad.
struct SwipeableRow<Content: View>: View {
    let item: ItemSnapshot
    @ObservedObject var model: NotesViewModel
    @ViewBuilder var content: Content
    @State private var dragAxis: Axis?
    @State private var dragStart: CGFloat = 0
    @State private var rowWidth: CGFloat = 340
    @State private var stripFrame: CGRect?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLive: Bool { model.liveSwipe?.id == item.id }

    private var offset: CGFloat {
        if let live = model.liveSwipe, live.id == item.id { return live.offset }
        return SwipeMetrics.restingOffset(model.openSwipe?.id == item.id ? model.openSwipe?.side : nil)
    }

    var body: some View {
        ZStack {
            trays
            content
                .offset(x: offset)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { rowWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in rowWidth = width }
        })
        .onHover { inside in
            if inside {
                model.hoveredID = item.id
            } else if model.hoveredID == item.id {
                model.hoveredID = nil
            }
        }
        .onChange(of: rowWidth) { _, width in model.rowWidth = width }
        .simultaneousGesture(drag)
        // Springs only when a swipe settles or a tray closes; while live, the
        // row tracks the pointer exactly.
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: model.openSwipe)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: isLive)
        .accessibilityAction(named: "Delete") { Task { await model.delete(item) } }
        .accessibilityAction(named: "Remind Me in 20 Minutes") { Task { await model.remind(item, .inTwentyMinutes) } }
        .accessibilityAction(named: "Remind Me in 1 Hour") { Task { await model.remind(item, .inOneHour) } }
        .accessibilityAction(named: "Remind Me Tomorrow at 9:00") { Task { await model.remind(item, .tomorrowMorning) } }
        .onPreferenceChange(ImageStripFrameKey.self) { stripFrame = $0 }
        .coordinateSpace(.named(ImageStripFrameKey.space))
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(ImageStripFrameKey.space))
            .onChanged { value in
                if dragAxis == nil {
                    if stripFrame?.contains(value.startLocation) == true { return }
                    dragAxis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                    dragStart = offset
                }
                guard dragAxis == .horizontal else { return }
                model.trackSwipe(item.id, offset: dragStart + value.translation.width)
            }
            .onEnded { value in
                defer { dragAxis = nil }
                guard dragAxis == .horizontal else { return }
                let projected = dragStart + value.predictedEndTranslation.width
                model.endSwipe(item, offset: dragStart + value.translation.width, projected: projected)
            }
    }

    /// Only the uncovered strip is painted, so the row needs no opaque fill.
    private var trays: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(RemindPreset.allCases) { preset in
                    TrayButton(title: preset.shortTitle, symbol: preset.symbol, tint: preset.tint,
                               width: max(0, offset) / CGFloat(RemindPreset.allCases.count)) {
                        model.openSwipe = nil
                        Task { await model.remind(item, preset) }
                    }
                }
            }
            .frame(width: max(0, offset), alignment: .leading)
            Spacer(minLength: 0)
            TrayButton(title: "Delete", symbol: "trash", tint: Theme.swipeDelete, width: max(0, -offset)) {
                Task { await model.delete(item) }
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

private struct TrayButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                Text(title).font(Theme.rounded(11, .semibold)).lineLimit(1)
            }
            .foregroundStyle(Color.white)
            .opacity(width > 40 ? 1 : 0)
            .frame(width: max(width, 0))
            .frame(maxHeight: .infinity)
            .background(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension RemindPreset {
    var tint: Color {
        switch self {
        case .inTwentyMinutes: Theme.swipeSoon
        case .inOneHour: Theme.swipeLater
        case .tomorrowMorning: Theme.swipeTomorrow
        }
    }
}

/// Turns horizontal two-finger trackpad (or Magic Mouse) swipes over a row
/// into the same live offset a mouse drag produces. Vertical scrolls, and
/// ordinary mouse wheels (no scroll phase), pass through to the list.
@MainActor
final class SwipeScrollMonitor {
    private weak var model: NotesViewModel?
    private var monitor: Any?
    private var trackingID: String?
    private var axis: Axis?
    private var start: CGFloat = 0
    private var accumulated = CGSize.zero
    private var swallowMomentum = false

    func start(model: NotesViewModel) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.hasPreciseScrollingDeltas else { return event }
            let sample = ScrollSample(event)
            // Local monitors run on the main thread.
            let consumed = MainActor.assumeIsolated { self.handle(sample) }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns whether the event was used for a swipe (and must not scroll).
    private func handle(_ event: ScrollSample) -> Bool {
        guard let model else { return false }
        if event.isMomentum {
            return swallowMomentum
        }
        let dx = event.dx
        let dy = event.dy
        switch event.phase {
        case .began:
            trackingID = model.hoveredID
            axis = nil
            accumulated = .zero
            swallowMomentum = false
            start = trackingID.map(model.swipeOffset(for:)) ?? 0
            return false
        case .changed:
            guard let id = trackingID else { return false }
            accumulated.width += dx
            accumulated.height += dy
            if axis == nil, hypot(accumulated.width, accumulated.height) > 4 {
                axis = abs(accumulated.width) > abs(accumulated.height) ? .horizontal : .vertical
            }
            guard axis == .horizontal else { return false }
            model.trackSwipe(id, offset: start + accumulated.width)
            return true
        case .ended, .cancelled:
            defer {
                trackingID = nil
                axis = nil
            }
            guard axis == .horizontal, let id = trackingID,
                  let item = model.items.first(where: { $0.id == id }) else { return false }
            swallowMomentum = true
            let offset = start + accumulated.width
            model.endSwipe(item, offset: offset, projected: offset + dx * 6)
            return true
        default:
            return false
        }
    }
}

private struct ScrollSample: Sendable {
    let phase: NSEvent.Phase
    let isMomentum: Bool
    let dx: CGFloat
    let dy: CGFloat

    init(_ event: NSEvent) {
        phase = event.phase
        isMomentum = !event.momentumPhase.isEmpty
        // Follow the fingers whatever the "natural scrolling" setting is.
        dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        dy = event.scrollingDeltaY
    }
}
