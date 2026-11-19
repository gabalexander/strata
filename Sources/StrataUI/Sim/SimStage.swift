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

    /// Fits the diagram when that keeps it readable; otherwise opens at a readable zoom where flows start:
    /// on the left, centred vertically, or at the top, centred across, for a level that runs top to bottom.
    func opening(_ layout: StageLayout, in size: CGSize, compact: Bool) -> StageCamera {
        let fit = fitted(layout, in: size, compact: compact)
        guard !compact, !fitAll, fit.zoom < Self.readableZoom, size.width > 0 else { return fit }
        let zoom = Self.readableZoom, bounds = layout.bounds
        var camera = StageCamera(zoom: zoom)
        if layout.direction == .down {
            let left = bounds.width * zoom <= size.width - 64 ? size.width / 2 - bounds.midX * zoom : 32 - bounds.minX * zoom
            camera.offset = CGPoint(x: left, y: 32 - bounds.minY * zoom)
            return camera
        }
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
    /// A component chip was clicked: the card's node and the component (nil for "+N"). Dives in.
    var onComponent: ((String, String?) -> Void)?
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
    @State private var glyphHover = StageGlyphHover()

    var body: some View {
        let _ = SimOpsState.of(sim).lit(for: selection)   // a hovered op row repaints a paused stage
        let _ = SimPressureState.of(sim).watch()          // so do heat mode and a pinned blast radius
        let _ = SimDriftState.of(model).watch(sim.manifest.id)   // and a drift check finishing
        GeometryReader { proxy in
            let camera = still ? SimJourneyStage.stillCamera(SimJourneyState.of(model).player(for: sim.manifest.id), path: sim.path,
                                                             viewport: viewport, layout: renderer.layout, size: proxy.size)
                ?? viewport.current(renderer.layout, in: proxy.size, compact: compact)
                : viewport.current(renderer.layout, in: proxy.size, compact: compact)
            let canvas = stageCanvas(camera)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let target = hit(point, camera)
                        let glyph = still ? nil : renderer.glyph(at: camera.world(point), on: target)
                        // A glyph explains itself with a hint, which counts as the badge: no card under it.
                        let badge = glyph != nil || SimFormulaStage.onBadge(target, point: point, camera: camera, layout: renderer.layout)
                        trackComponents(target, at: point, camera, badge: badge)
                        hintGlyph(glyph, on: target, camera: camera, origin: { proxy.frame(in: .global).origin })
                        guard hovered != target || hoveredBadge != badge else { return }
                        clearTermHover()
                        hovered = target
                        hoveredBadge = badge
                        if glyph != nil { return }
                        // One card at a time, so none covers another: the ƒ badge shows the node's formula
                        // (and hides the processes card); the rest of a card with process chips shows its
                        // processes; the rest of any other card its term, else its formula.
                        if case .node(let id) = target,
                           let card = renderer.layout.cardsByID[id],
                           let show = SimFormulaStage.hoverCard(card.node, badge: badge, chips: StageLayout.hasChips(card.node),
                                                                terms: terms) {
                            hoverTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(badge ? 120 : 300))
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
                        let target = renderer.selectable(hit(point, camera))
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
            .overlay(alignment: .topLeading) {
                if !compact { componentsCard(camera, size: proxy.size) }
            }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { viewport.size = $0 }
            .onAppear {
                // Offscreen: once the cards are drawn (and their glyphs recorded), hover the requested one.
                guard let id = SimGlyphSnapshot.node else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard let glyph = renderer.glyphs[id]?.first else { return }
                    hintGlyph(glyph, on: .node(id), camera: viewport.current(renderer.layout, in: proxy.size, compact: compact),
                              origin: { proxy.frame(in: .global).origin }, now: true)
                }
            }
            .onAppear { SimFormulaStage.showRequested(sim, layout: renderer.layout, camera: { viewport.current(renderer.layout, in: proxy.size, compact: compact) }, frame: { proxy.frame(in: .global) }, overlays: model.overlays, terms: terms) }
        }
        .clipped()
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            // A journey's panel tells the story while it is open, so the strip steps aside.
            if !compact, SimJourneyState.of(model).player(for: sim.manifest.id) == nil,
               let narration = stripText, !narration.isEmpty {
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
        .animation(reduceMotion ? nil : Theme.snappy, value: stripText)
        .onDisappear {
            clock.suspend()
            clearHover()
        }
    }

    /// The narration strip: a scenario's narration, else the level's brief (or its narration's first
    /// sentence when long; "This level" in the inspector has all of it).
    private var stripText: String? {
        sim.narration ?? Brief.parts(brief: sim.level.brief, detail: sim.level.narration)?.lead
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
        let highlight = journeyHighlight ?? (compact ? SimOpsState.of(sim).highlight(for: selection)
            : SimPressureState.of(sim).highlight(for: selection, tabOpen: pressureOpen, sim: sim))
        renderer.hoveredChip = SimComponentsHover.of(sim).chip
        renderer.drifted = SimDriftState.of(model).badges(for: sim)
        renderer.links.reduceMotion = reduceMotion
        return Canvas(opaque: true) { context, size in
            let frame = sim.frame()
            renderer.draw(context, size: size, camera: camera, frame: frame, selected: selection,
                          hovered: hovered, notes: noteIDs, labels: sim.speed <= 2, highlight: highlight)
        }
    }

    /// An open journey's route on this level (SimJourneyStage), unless an op row's path is lit.
    private var journeyHighlight: StageHighlight? {
        guard !compact, SimOpsState.of(sim).lit(for: selection) == nil,
              let player = SimJourneyState.of(model).player(for: sim.manifest.id) else { return nil }
        return SimJourneyStage.highlight(player, path: sim.path, layout: renderer.layout)
    }

    private func hit(_ point: CGPoint, _ camera: StageCamera, includeTokens: Bool = true) -> StageSelection? {
        renderer.hit(point, camera: camera, frame: sim.frame(), includeTokens: includeTokens)
    }

    /// Selects on mouse down, so a click never waits out the double-click interval; the second click
    /// of a double-click on a node dives in. A press on empty space waits for mouse up, so dragging
    /// to pan keeps the selection.
    private func press(_ point: CGPoint, clicks: Int, camera: StageCamera) -> StagePress {
        if let onComponent, let chip = renderer.chip(at: camera.world(point)) {
            onSelect(.node(chip.node))
            onComponent(chip.node, chip.component)
            return StagePress(pans: false, empty: false, camera: camera)
        }
        let raw = hit(point, camera)
        let target = renderer.selectable(raw)
        if let target {
            onSelect(target)
            if clicks == 2, case .node(let id) = raw { onDive(id) }
            if case .node(let id) = target, SimFormulaStage.onBadge(target, point: point, camera: camera, layout: renderer.layout) {
                SimHowState.of(sim).revealFormula(of: id, over: SimDataState.of(sim).scroll)
            }
        }
        return StagePress(pans: hit(point, camera, includeTokens: false) == nil, empty: target == nil, camera: camera)
    }

    private func clearHover() {
        clearTermHover()
        SimComponentsHover.of(sim).clear()
        hintGlyph(nil, on: nil, camera: StageCamera(), origin: { .zero })
    }

    /// Shows the hint of the card glyph under the pointer, above it, and ends the last one's.
    private func hintGlyph(_ glyph: StageGlyph?, on target: StageSelection?, camera: StageCamera, origin: @escaping () -> CGPoint,
                           now: Bool = false) {
        let hints = model.overlays.hints
        let key: String? = if let glyph, case .node(let id)? = target { "\(id)|\(glyph.kind)" } else { nil }
        guard key != glyphHover.key else { return }
        if let old = glyphHover.key { hints.leave(old) }
        glyphHover.key = key
        guard let glyph, let key, case .node(let id)? = target else { return }
        // Anchored on the glyph's column of the whole card, so the hint sits above the card (or below it, for
        // a glyph on the lower half) and never over its title or numbers.
        let card = renderer.layout.cardsByID[id]?.rect ?? glyph.rect
        let column = CGRect(x: glyph.rect.minX, y: min(card.minY, glyph.rect.minY), width: glyph.rect.width,
                            height: max(card.maxY, glyph.rect.maxY) - min(card.minY, glyph.rect.minY))
        let rect = camera.screen(column)
        hints.enter(key, text: glyph.hint, shortcut: glyph.shortcut, above: glyph.rect.midY < card.midY, now: now) {
            let o = origin()
            return rect.offsetBy(dx: o.x, dy: o.y)
        }
    }

    /// Ends the term or formula hover, but not the components hover that `trackComponents` keeps, so
    /// moving onto the ƒ badge or another card doesn't restart the components card's delay.
    private func clearTermHover() {
        hoverTask?.cancel()
        if hovered != nil { model.overlays.hideTerm() }
        hovered = nil
        hoveredBadge = false
    }

    /// Lights the chip under the pointer and, after a moment, lists the components of the card under it.
    /// On the card's ƒ badge the list hides for the formula card, and comes back off it without a delay.
    private func trackComponents(_ target: StageSelection?, at point: CGPoint, _ camera: StageCamera, badge: Bool) {
        var node: String?
        if case .node(let id) = target, let card = renderer.layout.cardsByID[id], StageLayout.hasChips(card.node) { node = id }
        let hover = SimComponentsHover.of(sim)
        hover.track(node: node, chip: node == nil || badge ? nil : renderer.chip(at: camera.world(point)))
        hover.suppress(badge && node != nil)
    }

    /// The components card, above the node's card when it fits there, else below it.
    @ViewBuilder
    private func componentsCard(_ camera: StageCamera, size: CGSize) -> some View {
        let hover = SimComponentsHover.of(sim)
        if hover.showsCard, !hover.suppressed, let id = hover.node, let card = renderer.layout.cardsByID[id], StageLayout.hasChips(card.node) {
            let rect = camera.screen(card.rect)
            let x = min(max(8, rect.minX), max(8, size.width - StageComponentsCard.width - 8))
            let above = rect.minY - 8 - StageComponentsCard.estimatedHeight(card.node) >= 8
            StageComponentsCard(node: card.node, highlighted: hover.chip?.component)
                .fixedSize()
                .offset(x: x)
                .frame(width: size.width, height: max(0, above ? rect.minY - 8 : size.height - rect.maxY - 8),
                       alignment: above ? .bottomLeading : .topLeading)
                .offset(y: above ? 0 : rect.maxY + 8)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
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
