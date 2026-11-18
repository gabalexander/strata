import AppKit
import SwiftUI

@MainActor
struct GraphScreen: View {
    let catalog: ShellCatalog

    @State private var graph = GraphData()
    @State private var layout = ForceLayout(graph: GraphData())
    @State private var filters = Filters()
    @State private var viewport = GraphViewport()
    @State private var size = CGSize.zero
    @State private var hoverPoint: CGPoint?
    @State private var drag: Drag?
    @State private var lastMagnification: CGFloat = 1
    @State private var layoutRun = 0

    private struct Filters: Equatable {
        var notes = true
        var sims = true
        var orphans = true
    }

    private struct Revision: Equatable {
        let library: Int
        let vault: Int
    }

    private struct Drag {
        let node: Int?
        let start: CGPoint
        let offset: CGSize
    }

    private var model: AppModel { catalog.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            header
            chart
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .strokeBorder(Theme.border)
                        .allowsHitTesting(false)
                }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 20)
        .task(id: Revision(library: model.library.revision, vault: model.vault.revision)) {
            graph = GraphData(catalog: catalog)
            rebuildLayout(preserveUnchangedLinks: true)
        }
        .onChange(of: filters) { rebuildLayout() }
        .task(id: layoutRun) {
            while !Task.isCancelled, layout.advance(pinning: drag?.node) {
                do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Graph").font(Theme.title).accessibilityAddTraits(.isHeader)
                let count = layout.graph.nodes.count
                let edges = layout.graph.edges.count
                Text("\(count) \(count == 1 ? "item" : "items") · \(edges) \(edges == 1 ? "link" : "links")")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
            }
            Spacer()
            filter("Notes", symbol: "note.text", enabled: $filters.notes)
            filter("Sims", symbol: "waveform.path", enabled: $filters.sims)
            filter("Orphans", symbol: "circle.dotted", enabled: $filters.orphans)
            Rectangle().fill(Theme.border).frame(width: 1, height: 20)
            StrataIconButton("minus", title: "Zoom out") { zoom(1 / 1.22) }
            StrataIconButton("plus", title: "Zoom in") { zoom(1.22) }
            StrataIconButton("arrow.up.left.and.arrow.down.right", title: "Fit graph") { viewport.fit(layout.positions, in: size) }
        }
        .zIndex(1)
    }

    private func filter(_ title: String, symbol: String, enabled: Binding<Bool>) -> some View {
        let active = enabled.wrappedValue
        return Button {
            enabled.wrappedValue.toggle()
        } label: {
            Label(title, systemImage: symbol)
                .font(Theme.label)
                .foregroundStyle(active ? Theme.accent : Theme.muted)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(active ? Theme.accent.opacity(0.10) : Theme.raised,
                            in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                        .strokeBorder(active ? Theme.accent.opacity(0.24) : Theme.border)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var chart: some View {
        ZStack(alignment: .bottomLeading) {
            Canvas { context, size in
                let hovered = drag?.node ?? hoverPoint.flatMap { node(at: $0) }
                GraphDrawing(layout: layout, viewport: viewport, hovered: hovered).draw(context, size: size)
            }
            .background(Theme.surface)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { old, new in
                size = new
                if old == .zero { viewport.fit(layout.positions, in: new) }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverPoint = point
                case .ended: hoverPoint = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged(move)
                    .onEnded(endDrag)
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let point = CGPoint(x: value.startAnchor.x * size.width, y: value.startAnchor.y * size.height)
                        viewport.zoom(by: value.magnification / lastMagnification, at: point, in: size)
                        lastMagnification = value.magnification
                    }
                    .onEnded { _ in lastMagnification = 1 }
            )
            .onRightClick { local, global in
                guard let hit = node(at: local) else { return }
                let node = layout.graph.nodes[hit]
                model.overlays.showMenu([
                    .header(node.title),
                    MenuItem("Open", icon: "arrow.up.right") { model.open(node.route) },
                ], at: global)
            }
            .background {
                WindowEvents(matching: .scrollWheel) { event, view in
                    let point = view.convert(event.locationInWindow, from: nil)
                    guard view.bounds.contains(point), model.overlays.menu == nil,
                          !model.paletteOpen, !model.switcherOpen else { return event }
                    if event.modifierFlags.contains(.command) {
                        let anchor = CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
                        viewport.zoom(by: exp(event.scrollingDeltaY * 0.016), at: anchor, in: size)
                    } else {
                        viewport.offset.width += event.scrollingDeltaX
                        viewport.offset.height += event.scrollingDeltaY
                    }
                    hoverPoint = nil
                    return nil
                }
            }
            .accessibilityLabel("Graph canvas")
            .accessibilityHint("Drag to move nodes or pan the canvas. Use the note and simulator switcher to open items by name.")

            if layout.graph.nodes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(Theme.ui(23, .medium))
                        .foregroundStyle(Theme.muted)
                    Text(graph.nodes.isEmpty ? "No notes or simulators yet" : "No items match these filters")
                        .font(Theme.heading)
                    if graph.nodes.isEmpty {
                        Text("Notes and simulators appear here when you add them to the library.")
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            } else {
                legend
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem("Notes", color: Theme.text)
            legendItem("Simulators and maps", color: Theme.accent)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .card(Theme.bg, radius: Theme.radiusSmall)
        .padding(12)
        .allowsHitTesting(false)
    }

    private func legendItem(_ label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(Theme.small).foregroundStyle(Theme.muted)
        }
    }

    private func rebuildLayout(preserveUnchangedLinks: Bool = false) {
        let visible = graph.filtered(notes: filters.notes, sims: filters.sims, orphans: filters.orphans)
        if preserveUnchangedLinks, !layout.graph.nodes.isEmpty, layout.graph.hasSameLinks(as: visible) {
            if !layout.graph.nodes.elementsEqual(visible.nodes, by: { $0.route == $1.route }) {
                drag = nil
                hoverPoint = nil
            }
            layout.updateGraph(visible)
            return
        }
        drag = nil
        hoverPoint = nil
        layout = ForceLayout(graph: visible)
        if catalog.fixtureNotes != nil {
            while layout.advance() {}
        }
        if size != .zero { viewport.fit(layout.positions, in: size) }
        layoutRun += 1
    }

    private func node(at point: CGPoint) -> Int? {
        let drawing = GraphDrawing(layout: layout, viewport: viewport, hovered: nil)
        var nearest: Int?
        var distance = drawing.radius + 4
        for (index, position) in layout.positions.enumerated() {
            let centre = viewport.point(position, in: size)
            let next = hypot(centre.x - point.x, centre.y - point.y)
            if next < distance {
                nearest = index
                distance = next
            }
        }
        return nearest
    }

    private func move(_ value: DragGesture.Value) {
        if drag == nil {
            let hit = node(at: value.startLocation)
            drag = Drag(node: hit, start: hit.map { layout.positions[$0] } ?? .zero, offset: viewport.offset)
        }
        guard hypot(value.translation.width, value.translation.height) > 3, let drag else { return }
        if let index = drag.node {
            layout.positions[index] = CGPoint(x: drag.start.x + value.translation.width / viewport.scale,
                                              y: drag.start.y + value.translation.height / viewport.scale)
        } else {
            viewport.offset = CGSize(width: drag.offset.width + value.translation.width,
                                     height: drag.offset.height + value.translation.height)
        }
    }

    private func endDrag(_ value: DragGesture.Value) {
        defer { drag = nil }
        guard let drag else { return }
        if hypot(value.translation.width, value.translation.height) <= 3 {
            if let index = drag.node { model.open(layout.graph.nodes[index].route) }
        } else if drag.node != nil {
            layout.reheat()
            layoutRun += 1
        }
    }

    private func zoom(_ factor: CGFloat) {
        viewport.zoom(by: factor, at: CGPoint(x: size.width / 2, y: size.height / 2), in: size)
    }
}

@MainActor
private struct GraphDrawing {
    let layout: ForceLayout
    let viewport: GraphViewport
    let hovered: Int?

    var radius: CGFloat {
        let base: CGFloat = layout.graph.nodes.count <= 36 ? 12 : 6
        return max(3, min(18, base * viewport.scale))
    }

    func draw(_ context: GraphicsContext, size: CGSize) {
        drawGrid(context, size: size)
        let graph = layout.graph
        let points = layout.positions.map { viewport.point($0, in: size) }
        let neighbours = hovered.map { graph.neighbours[$0] } ?? []
        var links = Path()
        var highlighted = Path()
        for edge in graph.edges {
            if hovered == edge.a || hovered == edge.b {
                highlighted.move(to: points[edge.a])
                highlighted.addLine(to: points[edge.b])
            } else {
                links.move(to: points[edge.a])
                links.addLine(to: points[edge.b])
            }
        }
        context.stroke(links, with: .color(Theme.borderStrong.opacity(hovered == nil ? 1 : 0.34)), lineWidth: 1)
        context.stroke(highlighted, with: .color(Theme.accent.opacity(0.7)), lineWidth: 1.5)

        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -45, dy: -45)
        let drawAllTitles = graph.nodes.count <= 28 && viewport.scale >= 0.56
        for index in graph.nodes.indices where bounds.contains(points[index]) {
            let active = hovered == nil || hovered == index || neighbours.contains(index)
            let node = graph.nodes[index]
            let showTitle = drawAllTitles || hovered == index || (neighbours.count <= 24 && neighbours.contains(index))
            drawNode(node, at: points[index], context: context, active: active, selected: hovered == index, showTitle: showTitle)
        }
    }

    private func drawNode(_ node: GraphData.Node, at point: CGPoint, context: GraphicsContext,
                          active: Bool, selected: Bool, showTitle: Bool) {
        let color = node.isNote ? Theme.text : Theme.accent
        let frame = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        let circle = Path(ellipseIn: frame)
        let opacity = active ? 1.0 : 0.24
        if radius < 8 {
            context.fill(circle, with: .color(color.opacity(opacity * 0.8)))
        } else {
            context.fill(circle, with: .color(Theme.raised))
            context.stroke(circle, with: .color(color.opacity(opacity * (selected ? 0.95 : 0.48))), lineWidth: selected ? 1.5 : 1)
            let glyph = Text(Image(systemName: node.symbol)).font(Theme.ui(radius, .medium))
                .foregroundStyle(color.opacity(opacity))
            context.draw(glyph, at: point)
        }
        if showTitle {
            let title = node.title.count > 27 ? String(node.title.prefix(26)) + "…" : node.title
            let label = Text(title).font(Theme.ui(selected ? 12 : 11, selected ? .semibold : .regular))
                .foregroundStyle(color.opacity(opacity))
            context.draw(label, at: CGPoint(x: point.x, y: point.y + radius + 5), anchor: .top)
        }
    }

    private func drawGrid(_ context: GraphicsContext, size: CGSize) {
        let step: CGFloat = 24
        let x = viewport.offset.width.truncatingRemainder(dividingBy: step)
        let y = viewport.offset.height.truncatingRemainder(dividingBy: step)
        var dots = Path()
        for row in stride(from: y, to: size.height, by: step) {
            for column in stride(from: x, to: size.width, by: step) {
                dots.addEllipse(in: CGRect(x: column, y: row, width: 1.5, height: 1.5))
            }
        }
        context.fill(dots, with: .color(Theme.grid))
    }
}
