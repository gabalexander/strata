import SwiftUI
import StrataCore

@MainActor
final class StageRenderer {
    let layout: StageLayout
    private let flowColors = (1...6).map(Theme.token)
    private var textCache: [TextKey: GraphicsContext.ResolvedText] = [:]
    private var imageCache: [String: GraphicsContext.ResolvedImage] = [:]
    private var runtimeRoutes: [String: StageLayout.Route] = [:]
    private var gridCache: (camera: StageCamera, size: CGSize, path: Path)?

    enum Lettering: Hashable {
        case label, node, compactNode, badge, live, mutedLive, failure, hint
    }

    private struct TextKey: Hashable {
        let text: String
        let style: Lettering
        let width: CGFloat?
    }

    init(level: Level) { layout = StageLayout(level: level) }

    func hit(_ point: CGPoint, camera: StageCamera, frame: SimFrame, includeTokens: Bool) -> StageSelection? {
        updateRoutes(frame)
        return layout.hit(point, camera: camera, tokens: includeTokens ? frame.tokens : [], runtimeRoutes: runtimeRoutes)
    }

    private func updateRoutes(_ frame: SimFrame) {
        // Redirects can add edges after the level topology was laid out.
        runtimeRoutes = runtimeRoutes.filter { frame.edges[$0.key] != nil }
        for id in frame.edges.keys where layout.routesByID[id] == nil && runtimeRoutes[id] == nil {
            runtimeRoutes[id] = layout.connect(id)
        }
    }

    func draw(_ source: GraphicsContext, size: CGSize, camera: StageCamera, frame: SimFrame,
              selected: StageSelection?, hovered: StageSelection?, notes: Set<String>, labels: Bool) {
        source.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.bg))
        drawGrid(in: source, size: size, camera: camera)
        var context = source
        context.translateBy(x: camera.offset.x, y: camera.offset.y)
        context.scaleBy(x: camera.zoom, y: camera.zoom)
        let viewport = CGRect(origin: camera.world(.zero), size: CGSize(width: size.width / camera.zoom, height: size.height / camera.zoom))
            .insetBy(dx: -35, dy: -35)

        for region in layout.regions where viewport.intersects(region.rect) { drawRegion(region, in: context) }

        updateRoutes(frame)
        let routes = layout.routes + runtimeRoutes.values.sorted { $0.edge.id < $1.edge.id }
        let visibleEdges = routes.filter { viewport.intersects($0.path.boundingRect.insetBy(dx: -1, dy: -1)) }
        for route in visibleEdges {
            let hit = StageSelection.edge(route.edge.id)
            drawEdge(route, state: frame.edges[route.edge.id] ?? EdgeState(), selected: selected == hit,
                     hovered: hovered == hit, in: context)
        }

        // One fill per color and mark keeps dense traffic from issuing a draw call for each token.
        var marks = Array(repeating: TokenMarks(), count: flowColors.count * 2 + 1)
        var focusToken: (token: TokenView, point: CGPoint)?
        for token in frame.tokens {
            guard let route = layout.routesByID[token.edge] ?? runtimeRoutes[token.edge] else { continue }
            let point = route.point(at: token.progress)
            guard viewport.contains(point) else { continue }
            let focused = selected == .flow(token.flow) || hovered == .flow(token.flow)
            let index = (max(1, token.color) - 1) % flowColors.count
            let layer = switch token.kind {
            case .failure: marks.count - 1
            case .orphan: index + flowColors.count
            default: index
            }
            marks[layer].add(token.kind, at: point, focused: focused)
            if focusToken == nil, labels, focused, token.label != nil, frame.tokens.count < 24 { focusToken = (token, point) }
        }

        for i in marks.indices where !marks[i].halo.isEmpty {
            let tint = i == marks.count - 1 ? Theme.bad : flowColors[i % flowColors.count]
            let faded = i >= flowColors.count && i < marks.count - 1
            marks[i].draw(in: context, color: tint, alpha: faded ? 0.34 : 1, dense: frame.tokens.count >= 120)
        }

        for route in visibleEdges {
            drawEdgeLabel(route, state: frame.edges[route.edge.id] ?? EdgeState(), in: context)
        }
        for card in layout.cards where viewport.intersects(card.rect) {
            let hit = StageSelection.node(card.node.id)
            drawNode(card, state: frame.nodes[card.node.id] ?? NodeState(), time: frame.t,
                     selected: selected == hit, hovered: hovered == hit, note: notes.contains(card.node.id), in: context)
        }
        if let focusToken, let label = focusToken.token.label {
            pill(label, at: focusToken.point + CGPoint(x: 9, y: -18), width: 144, color: Theme.borderStrong,
                 fill: Theme.overlay, style: .node, in: context)
        }
    }

    private func drawGrid(in context: GraphicsContext, size: CGSize, camera: StageCamera) {
        if gridCache?.camera != camera || gridCache?.size != size {
            let pitch = 24 * camera.zoom * (camera.zoom < 0.52 ? 2 : 1)
            let x = camera.offset.x.truncatingRemainder(dividingBy: pitch)
            let y = camera.offset.y.truncatingRemainder(dividingBy: pitch)
            let dots = Path { path in
                for column in stride(from: x, through: size.width, by: pitch) {
                    for row in stride(from: y, through: size.height, by: pitch) {
                        path.addEllipse(in: CGRect(x: column, y: row, width: 1.35, height: 1.35))
                    }
                }
            }
            gridCache = (camera, size, dots)
        }
        if let gridCache { context.fill(gridCache.path, with: .color(Theme.grid)) }
    }

    private func drawRegion(_ region: StageLayout.Region, in context: GraphicsContext) {
        let r = region.rect
        let shape = Path(roundedRect: r, cornerRadius: Theme.radius + Theme.radiusSmall)
        let fill = region.group.kind == .cluster ? Theme.hover.opacity(0.5) : Theme.hover.opacity(0.32)
        context.fill(shape, with: .color(fill))
        let dashed = region.group.kind == .vpc || region.group.kind == .region
        context.stroke(shape, with: .color(Theme.border), style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 5] : []))
        context.draw(text(region.group.label, .label, width: r.width - 28, in: context),
                     at: CGPoint(x: r.minX + 14, y: r.minY + 15), anchor: .leading)
    }

    private func drawEdge(_ route: StageLayout.Route, state: EdgeState, selected: Bool, hovered: Bool,
                          in context: GraphicsContext) {
        let ink = state.cut ? Theme.bad : state.breakerOpen ? Theme.warn : selected ? Theme.accent :
            Theme.text.opacity(hovered ? 0.58 : 0.20 + min(0.38, log1p(max(0, state.rate)) * 0.08))
        if selected || hovered {
            context.stroke(route.path, with: .color(ink.opacity(0.12)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
        }
        context.stroke(route.path, with: .color(ink),
                       style: StrokeStyle(lineWidth: selected || hovered ? 2 : 1.5, lineCap: .round,
                                          dash: state.cut ? [4, 5] : []))
        context.stroke(route.arrow, with: .color(ink), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    private func drawEdgeLabel(_ route: StageLayout.Route, state: EdgeState, in context: GraphicsContext) {
        let point = route.midpoint
        if state.cut {
            let r = CGRect(x: point.x - 10, y: point.y - 9, width: 20, height: 18)
            context.fill(Path(roundedRect: r, cornerRadius: Theme.radiusSmall), with: .color(Theme.overlay))
            symbol("scissors", at: point, size: 10, tint: Theme.bad, in: context)
        } else if state.breakerOpen {
            pill("open", at: point, width: route.labelWidth, color: Theme.warn.opacity(0.35), fill: Theme.overlay, in: context)
        } else if let label = route.edge.label ?? route.edge.protocol, !label.isEmpty {
            pill(label, at: route.labelPoint, width: route.labelWidth, color: Theme.border,
                 fill: Theme.overlay.opacity(0.96), in: context)
        }
    }

    private struct TokenMarks {
        var halo = Path()
        private var glow = Path()
        private var body = Path()
        private var ring = Path()
        private var cross = Path()

        mutating func add(_ kind: TokenView.Kind, at point: CGPoint, focused: Bool) {
            let radius: CGFloat = focused ? 4.6 : 3.5
            let box = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            halo.addEllipse(in: box.insetBy(dx: -3.5, dy: -3.5))
            glow.addEllipse(in: box.insetBy(dx: -1.8, dy: -1.8))
            switch kind {
            case .request: body.addEllipse(in: box)
            case .response, .orphan: ring.addEllipse(in: box)
            case .message: body.addRoundedRect(in: box, cornerSize: CGSize(width: 2, height: 2))
            case .failure:
                cross.move(to: box.origin)
                cross.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
                cross.move(to: CGPoint(x: box.minX, y: box.maxY))
                cross.addLine(to: CGPoint(x: box.maxX, y: box.minY))
            }
        }

        func draw(in context: GraphicsContext, color: Color, alpha: Double, dense: Bool) {
            if !dense { context.fill(halo, with: .color(color.opacity(alpha * 0.08))) }
            context.fill(glow, with: .color(color.opacity(alpha * 0.19)))
            if !body.isEmpty { context.fill(body, with: .color(color)) }
            if !ring.isEmpty {
                context.fill(ring, with: .color(Theme.bg.opacity(alpha)))
                context.stroke(ring, with: .color(color.opacity(alpha)), lineWidth: 1.35)
            }
            if !cross.isEmpty {
                context.stroke(cross, with: .color(color), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            }
        }
    }

    private func drawNode(_ card: StageLayout.Card, state: NodeState, time: Double, selected: Bool,
                          hovered: Bool, note: Bool, in context: GraphicsContext) {
        let node = card.node
        let r = card.rect
        let shape = Path(roundedRect: r, cornerRadius: Theme.radius)
        let down = state.health == .down
        let tint = node.simTint
        let elapsed = state.lastFailure.map { time - $0 } ?? .infinity
        let flash = max(0, 1 - elapsed / 0.5)
        if selected {
            let halo = Path(roundedRect: r.insetBy(dx: -3, dy: -3), cornerRadius: Theme.radius + 3)
            context.fill(halo, with: .color(Theme.accent.opacity(0.10)))
            context.stroke(halo, with: .color(Theme.accent.opacity(0.12)), lineWidth: 3)
        }
        context.fill(shape, with: .color(node.kind == .note ? Theme.surface : Theme.raised))
        let stroke = selected ? Theme.accent : down ? Theme.bad.opacity(0.38) : hovered ? Theme.text.opacity(0.37) : Theme.borderStrong
        let dashes: [CGFloat] = node.kind == .external && !selected ? [4, 3] : []
        context.stroke(shape, with: .color(stroke), style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: dashes))
        if flash > 0 || state.health == .failing {
            let pulse = 0.38 + sin(time * 14) * 0.16
            context.stroke(shape, with: .color(Theme.bad.opacity(max(pulse, flash))), lineWidth: 1.5)
        }

        var content = context
        content.opacity = down ? 0.45 : 1
        let glyph = CGRect(x: r.minX + 10, y: r.minY + 9, width: 28, height: 28)
        content.fill(Path(roundedRect: glyph, cornerRadius: Theme.radiusSmall), with: .color(tint.opacity(0.14)))
        symbol(node.icon ?? node.kind.symbol, at: CGPoint(x: glyph.midX, y: glyph.midY), size: 15, tint: tint, in: content)
        let markerCount = CGFloat((note ? 1 : 0) + (state.health == .slow ? 1 : 0))
        let x = r.minX + 46
        let titleWidth = r.maxX - 10 - x - markerCount * 15
        content.draw(text(node.label, .node, width: titleWidth, in: content),
                     at: CGPoint(x: x, y: r.minY + 16), anchor: .leading)

        var statusX = r.maxX - 14
        if state.health == .slow {
            symbol("tortoise", at: CGPoint(x: statusX, y: r.minY + 16), size: 11, tint: Theme.warn, in: context)
            statusX -= 15
        }
        if note {
            symbol("note.text", at: CGPoint(x: statusX, y: r.minY + 16), size: 10, tint: Theme.muted, in: content)
        }

        if node.kind == .note {
            if let doc = node.doc {
                let resolved = text(doc.replacingOccurrences(of: "\n", with: " "), .hint, in: content)
                content.draw(resolved, in: CGRect(x: x, y: r.minY + 25, width: r.maxX - x - 8, height: 33))
            }
            return
        }

        if let tech = node.tech, !tech.isEmpty {
            badge(tech, at: CGPoint(x: x, y: r.minY + 31), width: down ? 64 : 84, in: content)
        } else {
            content.draw(text(node.kind.rawValue, .mutedLive, in: content),
                         at: CGPoint(x: x, y: r.minY + 31), anchor: .leading)
        }
        if down {
            pill("down", at: CGPoint(x: r.maxX - 27, y: r.minY + 32), width: 42,
                 color: Theme.bad.opacity(0.38), fill: Theme.bad.opacity(0.13), style: .failure, in: context)
        } else if state.replicas > 1 {
            drawReplicas(state.replicas, at: CGPoint(x: r.maxX - 10, y: r.minY + 32), tint: tint, in: content)
        }

        let summary: String
        switch node.kind.role {
        case .source: summary = "\(SimFormat.number(state.arrivals))/s sent"
        case .buffer:
            if node.kind == .topic { summary = "depth \(state.depth) · lag \(state.groupLag.values.reduce(0, +))" }
            else { summary = "depth \(state.depth) · \(state.unacked) unacked" }
        case .server:
            summary = state.slots > 0 ? "\(state.busy)/\(state.slots) busy · \(SimFormat.number(state.throughput))/s" :
                "\(SimFormat.number(state.throughput))/s"
        case .annotation: summary = ""
        }

        let footerY = node.kind.role == .buffer ? r.maxY - 17 : r.maxY - 13
        content.draw(text(summary, .live, width: r.width - (node.canDeepDive ? 37 : 20), in: content),
                     at: CGPoint(x: r.minX + 10, y: footerY), anchor: .leading)
        if node.canDeepDive {
            symbol("square.3.layers.3d", at: CGPoint(x: r.maxX - 15, y: footerY), size: 12,
                   tint: selected ? Theme.accent : Theme.muted, in: content)
        }
        if node.kind.role == .buffer {
            drawSlots(state, in: content, at: CGPoint(x: r.minX + 10, y: r.maxY - 7))
        } else if node.kind.role == .server && state.slots > 0 && !down {
            let util = min(1, max(0, state.utilization))
            let base = CGRect(x: r.minX + 10, y: r.maxY - 4, width: r.width - 20, height: 2)
            let used = CGRect(origin: base.origin, size: CGSize(width: base.width * util, height: 2))
            content.fill(Path(roundedRect: base, cornerRadius: 1), with: .color(Theme.border))
            content.fill(Path(roundedRect: used, cornerRadius: 1),
                         with: .color(util < 0.7 ? Theme.good : util < 0.9 ? Theme.warn : Theme.bad))
        }
    }

    private func drawReplicas(_ count: Int, at point: CGPoint, tint: Color, in context: GraphicsContext) {
        let extra = count > 5
        let dots = min(5, count)
        let origin = point.x - (extra ? 20 : 0)
        for i in 0..<dots {
            let dot = CGRect(x: origin - CGFloat(i) * 5 - 3, y: point.y - 1.5, width: 3, height: 3)
            context.fill(Path(ellipseIn: dot), with: .color(tint.opacity(0.70)))
        }
        if extra {
            context.draw(text("+\(count - dots)", .badge, in: context), at: point, anchor: .trailing)
        }
    }

    private func drawSlots(_ state: NodeState, in context: GraphicsContext, at point: CGPoint) {
        let held = state.held.prefix(12)
        for i in 0..<12 {
            let r = CGRect(x: point.x + CGFloat(i) * 8, y: point.y - 2.5, width: 6, height: 5)
            let color = i < held.count ? flow(held[i]).opacity(0.8) : Theme.borderStrong
            context.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(color))
        }
        if state.depth > 12 {
            context.draw(text("+\(state.depth - 12)", .badge, width: 44, in: context),
                         at: point + CGPoint(x: 101, y: 0), anchor: .leading)
        }
    }

    private func badge(_ label: String, at point: CGPoint, width: CGFloat, in context: GraphicsContext) {
        let label = text(label, .badge, width: width - 8, in: context)
        let s = label.measure(in: CGSize(width: width - 8, height: 14))
        let r = CGRect(x: point.x, y: point.y - 6, width: s.width + 8, height: 12)
        context.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Theme.hover))
        context.draw(label, at: point + CGPoint(x: 4, y: 0), anchor: .leading)
    }

    private func pill(_ value: String, at point: CGPoint, width: CGFloat, color: Color, fill: Color,
                      style: Lettering = .badge, in context: GraphicsContext) {
        let pad: CGFloat = width < 44 ? 3 : 5
        let resolved = text(value, style, width: width - pad * 2, in: context)
        let size = resolved.measure(in: CGSize(width: width - pad * 2, height: 18))
        let r = CGRect(x: point.x - size.width / 2 - pad, y: point.y - 8, width: size.width + pad * 2, height: 16)
        let p = Path(roundedRect: r, cornerRadius: Theme.radiusSmall)
        context.fill(p, with: .color(fill))
        context.stroke(p, with: .color(color), lineWidth: 1)
        context.draw(resolved, at: point)
    }

    private func text(_ raw: String, _ style: Lettering, width: CGFloat? = nil,
                      in context: GraphicsContext) -> GraphicsContext.ResolvedText {
        let key = TextKey(text: raw, style: style, width: width)
        if let cached = textCache[key] { return cached }
        let font: Font
        let color: Color
        switch style {
        case .label: (font, color) = (Theme.label, Theme.muted)
        case .node: (font, color) = (Theme.ui(13, .semibold), Theme.text)
        case .compactNode: (font, color) = (Theme.ui(12, .semibold), Theme.text)
        case .badge: (font, color) = (Theme.mono(10), Theme.muted)
        case .live: (font, color) = (Theme.mono(11), Theme.text.opacity(0.78))
        case .mutedLive: (font, color) = (Theme.small, Theme.muted)
        case .failure: (font, color) = (Theme.mono(10, .medium), Theme.bad)
        case .hint: (font, color) = (Theme.small, Theme.muted)
        }
        func resolve(_ value: String) -> GraphicsContext.ResolvedText {
            context.resolve(Text(verbatim: value).font(font).foregroundStyle(color))
        }
        var resolved = resolve(raw)
        if style == .node, let width, resolved.measure(in: CGSize(width: CGFloat.infinity, height: 22)).width > width {
            let fitted = text(raw, .compactNode, width: width, in: context)
            textCache[key] = fitted
            return fitted
        }
        if let width, resolved.measure(in: CGSize(width: CGFloat.infinity, height: 22)).width > width {
            var lower = 0
            var upper = raw.count
            while lower < upper {
                let i = (lower + upper + 1) / 2
                if resolve(String(raw.prefix(i)) + "…").measure(in: CGSize(width: CGFloat.infinity, height: 22)).width <= width { lower = i }
                else { upper = i - 1 }
            }
            resolved = resolve(String(raw.prefix(lower)) + "…")
        }
        if textCache.count >= 1_024 { textCache.removeAll(keepingCapacity: true) }
        textCache[key] = resolved
        return resolved
    }

    private func symbol(_ name: String, at point: CGPoint, size: CGFloat, tint: Color, in context: GraphicsContext) {
        let image: GraphicsContext.ResolvedImage
        if let cached = imageCache[name] { image = cached }
        else {
            image = context.resolve(Image(systemName: name).symbolRenderingMode(.monochrome))
            imageCache[name] = image
        }
        let width = size * min(1.5, image.size.width / max(1, image.size.height))
        let rect = CGRect(x: point.x - width / 2, y: point.y - size / 2, width: width, height: size)
        var colored = image
        colored.shading = .color(tint)
        context.draw(colored, in: rect)
    }

    private func flow(_ color: Int) -> Color { flowColors[(max(1, color) - 1) % flowColors.count] }
}

extension Node {
    var simTint: Color {
        switch kind {
        case .client, .user, .cron, .external: Theme.muted
        case .database: Theme.token(3)
        case .cache: Theme.token(5)
        case .queue, .topic: Theme.token(2)
        case .note: Theme.warn
        default: Theme.info
        }
    }
}
