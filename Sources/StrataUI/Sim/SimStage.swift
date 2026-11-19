import AppKit
import Observation
import SwiftUI
import StrataCore

@MainActor
@Observable
final class StageViewport {
    var camera: StageCamera?
    var size = CGSize.zero
    /// "Fit view" asked for the whole diagram, however small that makes it.
    private var fitAll = false
    /// The smallest zoom a level opens at: cards stay legible, and a large map opens on its sources.
    static let readableZoom: CGFloat = 0.62

    func fitted(_ layout: StageLayout, in size: CGSize, compact: Bool) -> StageCamera {
        StageCamera(fitting: layout.bounds, in: size, inset: compact ? 14 : 32)
    }

    /// Fits the diagram when that keeps it readable; otherwise opens at a readable zoom on the left
    /// (where flows start), centred vertically.
    func opening(_ layout: StageLayout, in size: CGSize, compact: Bool) -> StageCamera {
        let fit = fitted(layout, in: size, compact: compact)
        guard !compact, !fitAll, fit.zoom < Self.readableZoom, size.width > 0 else { return fit }
        let zoom = Self.readableZoom, bounds = layout.bounds
        var camera = StageCamera(zoom: zoom)
        let top = bounds.height * zoom <= size.height - 64 ? size.height / 2 - bounds.midY * zoom : 32 - bounds.minY * zoom
        camera.offset = CGPoint(x: 32 - bounds.minX * zoom, y: top)
        return camera
    }

    func current(_ layout: StageLayout, in size: CGSize, compact: Bool) -> StageCamera {
        camera ?? opening(layout, in: size, compact: compact)
    }

    func fit() {
        camera = nil
        fitAll = true
    }

    func zoom(_ factor: CGFloat, at point: CGPoint? = nil, layout: StageLayout, compact: Bool) {
        var next = current(layout, in: size, compact: compact)
        next.magnify(by: factor, around: point ?? CGPoint(x: size.width / 2, y: size.height / 2))
        camera = next
    }

    func origin(for node: String?, in layout: StageLayout, compact: Bool) -> UnitPoint {
        guard let node = node.map(SimOpsPath.node), let rect = layout.cardsByID[node]?.rect,
              size.width > 0, size.height > 0 else { return .center }
        let screen = current(layout, in: size, compact: compact).screen(rect)
        return UnitPoint(x: min(1, max(0, screen.midX / size.width)), y: min(1, max(0, screen.midY / size.height)))
    }
}

@MainActor
private final class StageClock {
    private var last: Date?
    private var lastBeat: Date?

    func advance(to date: Date, in sim: Simulation, pulse: SimPulse?) {
        defer { last = date }
        guard let last else { return }
        let delta = date.timeIntervalSince(last)
        if delta > 0 { sim.tick(delta) }
        guard let pulse, lastBeat.map({ date.timeIntervalSince($0) >= SimPulse.interval }) ?? true else { return }
        lastBeat = date
        pulse.advance()
    }

    func suspend() { last = nil }
}

/// What a left mouse down on the stage started, kept by the event layer until mouse up.
struct StagePress {
    /// The press began on empty space (tokens aside), so dragging pans.
    let pans: Bool
    /// Nothing was under the press: a click without dragging clears the selection on mouse up.
    let empty: Bool
    let camera: StageCamera
}

@MainActor
struct SimStage: View {
    let sim: Simulation
    let model: AppModel
    let terms: TermIndex
    let renderer: StageRenderer
    let viewport: StageViewport
    var selection: StageSelection?
    var noteIDs: Set<String> = []
    var compact = false
    var visible = true
    var still = false
    var onSelect: (StageSelection?) -> Void = { _ in }
    var onDive: (String) -> Void = { _ in }
    var menu: ((StageSelection?) -> [MenuItem])?
    var onKey: ((NSEvent) -> Bool)?
    /// Beaten by the frame clock while playing, for the live numbers in the panels around the stage.
    var pulse: SimPulse?
    /// The dock's Pressure tab is open: a selected node shows its blast radius (SimPressureState).
    var pressureOpen = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = StageClock()
    @State private var hovered: StageSelection?
    @State private var hoverTask: Task<Void, Never>?
    @State private var hoveredBadge = false

    var body: some View {
        let _ = SimOpsState.of(sim).lit(for: selection)   // a hovered op row repaints a paused stage
        let _ = SimPressureState.of(sim).watch()          // so do heat mode and a pinned blast radius
        GeometryReader { proxy in
            let camera = viewport.current(renderer.layout, in: proxy.size, compact: compact)
            let canvas = stageCanvas(camera)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let target = hit(point, camera)
                        let badge = SimFormulaStage.onBadge(target, point: point, camera: camera, layout: renderer.layout)
                        guard hovered != target || hoveredBadge != badge else { return }
                        clearHover()
                        hovered = target
                        hoveredBadge = badge
                        // The ƒ badge shows the node's formula; the rest of the card its term, else its formula.
                        if case .node(let id) = target,
                           let card = renderer.layout.cardsByID[id],
                           let show = SimFormulaStage.hoverCard(card.node, badge: badge, terms: terms) {
                            hoverTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(300))
                                guard !Task.isCancelled, hovered == target else { return }
                                let rect = viewport.current(renderer.layout, in: proxy.size, compact: compact).screen(card.rect)
                                let origin = proxy.frame(in: .global).origin
                                show(model.overlays, rect.offsetBy(dx: origin.x, dy: origin.y))
                            }
                        }
                    case .ended: clearHover()
                    }
                }
                .overlay {
                    if !still {
                        StageEvents(compact: compact, scroll: { event, point in
                            clearHover()
                            model.overlays.dismissMenu()
                            if event.modifierFlags.contains(.command) {
                                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
                                viewport.zoom(exp(delta * 0.011), at: point, layout: renderer.layout, compact: compact)
                            } else {
                                var next = viewport.current(renderer.layout, in: proxy.size, compact: compact)
                                let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                                next.pan(CGSize(width: event.scrollingDeltaX * multiplier, height: event.scrollingDeltaY * multiplier))
                                viewport.camera = next
                            }
                        }, magnify: { amount, point in
                            clearHover()
                            model.overlays.dismissMenu()
                            viewport.zoom(1 + amount, at: point, layout: renderer.layout, compact: compact)
                        }, press: { point, clicks in
                            press(point, clicks: clicks, camera: camera)
                        }, drag: { press, translation, first in
                            if first { clearHover() }
                            var next = press.camera
                            next.pan(translation)
                            viewport.camera = next
                        }, release: { press, dragged in
                            if press.empty && !dragged { onSelect(nil) }
                        }, key: onKey)
                        .accessibilityHidden(true)
                    }
                }
            ZStack(alignment: .topTrailing) {
                if let menu, !still {
                    canvas.onRightClick { point, global in
                        clearHover()
                        let target = hit(point, camera)
                        onSelect(target)
                        model.overlays.showMenu(menu(target), at: global)
                    }
                } else {
                    canvas
                }

                if !sim.playing && !compact {
                    SimPill(title: "Paused", icon: "pause.fill", tint: Theme.warn).padding(12)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if !compact { SimPressureLegend(sim: sim, selection: selection, tabOpen: pressureOpen) }
            }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { viewport.size = $0 }
            .onAppear { SimFormulaStage.showRequested(sim, layout: renderer.layout, camera: { viewport.current(renderer.layout, in: proxy.size, compact: compact) }, frame: { proxy.frame(in: .global) }, overlays: model.overlays) }
        }
        .clipped()
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            if !compact, let narration = sim.narration ?? sim.level.narration, !narration.isEmpty {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "text.bubble").font(Theme.ui(12)).foregroundStyle(Theme.accent)
                        .padding(.top, 1)
                    SimMarkdown(source: narration, model: model, terms: terms, color: Theme.text, lineLimit: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(Theme.overlay.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.border))
                .id(narration)
                .transition(.opacity)
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .animation(reduceMotion ? nil : Theme.snappy, value: sim.narration ?? sim.level.narration)
        .onDisappear {
            clock.suspend()
            clearHover()
        }
    }

    @ViewBuilder
    private func stageCanvas(_ camera: StageCamera) -> some View {
        if still {
            paint(camera)
        } else {
            let _ = sim.playing ? 0 : sim.revision
            TimelineView(.animation(paused: !visible || !sim.playing && !renderer.animating)) { tick in
                paint(camera)
                    .onChange(of: tick.date) { _, date in clock.advance(to: date, in: sim, pulse: pulse) }
            }
            .onChange(of: sim.playing) { _, _ in clock.suspend() }
            .onChange(of: visible) { _, _ in clock.suspend() }
            .accessibilityLabel("System diagram")
            .accessibilityValue("\(renderer.layout.cards.count) components")
        }
    }

    private func paint(_ camera: StageCamera) -> some View {
        // An op row's path (SimOpsState) or a pressure overlay (heat, blast radius): the last requested wins.
        let highlight = compact ? SimOpsState.of(sim).highlight(for: selection)
            : SimPressureState.of(sim).highlight(for: selection, tabOpen: pressureOpen, sim: sim)
        return Canvas(opaque: true) { context, size in
            let frame = sim.frame()
            renderer.draw(context, size: size, camera: camera, frame: frame, selected: selection,
                          hovered: hovered, notes: noteIDs, labels: sim.speed <= 2, highlight: highlight)
        }
    }

    private func hit(_ point: CGPoint, _ camera: StageCamera, includeTokens: Bool = true) -> StageSelection? {
        renderer.hit(point, camera: camera, frame: sim.frame(), includeTokens: includeTokens)
    }

    /// Selects on mouse down, so a click never waits out the double-click interval; the second click
    /// of a double-click on a node dives in. A press on empty space waits for mouse up, so dragging
    /// to pan keeps the selection.
    private func press(_ point: CGPoint, clicks: Int, camera: StageCamera) -> StagePress {
        let target = hit(point, camera)
        if let target {
            onSelect(target)
            if clicks == 2, case .node(let id) = target { onDive(id) }
            if case .node(let id) = target, SimFormulaStage.onBadge(target, point: point, camera: camera, layout: renderer.layout) {
                SimHowState.of(sim).revealFormula(of: id, over: SimDataState.of(sim).scroll)
            }
        }
        return StagePress(pans: hit(point, camera, includeTokens: false) == nil, empty: target == nil, camera: camera)
    }

    private func clearHover() {
        hoverTask?.cancel()
        if hovered != nil { model.overlays.hideTerm() }
        hovered = nil
        hoveredBadge = false
    }
}

@MainActor
private struct StageEvents: NSViewRepresentable {
    let compact: Bool
    let scroll: (NSEvent, CGPoint) -> Void
    let magnify: (CGFloat, CGPoint) -> Void
    let press: (CGPoint, Int) -> StagePress
    /// The press, the translation since it, and whether this is the first move past the slop.
    let drag: (StagePress, CGSize, Bool) -> Void
    /// The press, and whether it moved far enough to pan.
    let release: (StagePress, Bool) -> Void
    let key: ((NSEvent) -> Bool)?

    func makeNSView(context: Context) -> EventView { EventView(events: self) }
    func updateNSView(_ view: EventView, context: Context) { view.events = self }

    final class EventView: NSView {
        var events: StageEvents
        private var keyMonitor: Any?
        private var pressed: (press: StagePress, start: CGPoint, dragged: Bool)?

        init(events: StageEvents) {
            self.events = events
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .scrollWheel where !events.compact || event.modifierFlags.contains(.command), .magnify:
                return super.hitTest(point)
            case .leftMouseDown where !event.modifierFlags.contains(.control): // control-click is the right click
                return super.hitTest(point)
            default: return nil
            }
        }

        // A click that brings the window forward selects too, instead of only activating it.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            pressed = (events.press(point, event.clickCount), point, false)
        }

        override func mouseDragged(with event: NSEvent) {
            guard var pressed, pressed.press.pans else { return }
            let point = convert(event.locationInWindow, from: nil)
            let translation = CGSize(width: point.x - pressed.start.x, height: point.y - pressed.start.y)
            let first = !pressed.dragged
            guard !first || hypot(translation.width, translation.height) >= 5 else { return }
            pressed.dragged = true
            self.pressed = pressed
            events.drag(pressed.press, translation, first)
        }

        override func mouseUp(with event: NSEvent) {
            guard let pressed else { return }
            self.pressed = nil
            events.release(pressed.press, pressed.dragged)
        }

        override func scrollWheel(with event: NSEvent) {
            events.scroll(event, convert(event.locationInWindow, from: nil))
        }

        override func magnify(with event: NSEvent) {
            events.magnify(event.magnification, convert(event.locationInWindow, from: nil))
        }

        override func viewWillMove(toWindow target: NSWindow?) {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            super.viewWillMove(toWindow: target)
            if target != nil, events.key != nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let window = self.window, event.window === window,
                          !(window.firstResponder is NSText), self.events.key?(event) == true else { return event }
                    return nil
                }
            }
        }
    }
}
