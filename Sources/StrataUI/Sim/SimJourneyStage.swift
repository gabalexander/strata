import SwiftUI
import StrataCore

// A journey on the stage: the current step's node lit in the accent with a numbered marker, the edge it
// came along and the node it talks to lit too, and the route so far faintly lit, every node it visited
// carrying the number of its latest step. The camera follows a step whose node is off screen.

/// A numbered disc on a node's top-left corner: a journey step that happened there.
struct StageMarker: Equatable, Sendable {
    var node: String
    var number: Int
    var current: Bool
}

@MainActor
enum SimJourneyStage {
    /// Where a step shows on the level at `path`: its node there, the node holding a deeper level it
    /// happens in, or nothing when it happens above or beside this level.
    static func node(of frame: JourneyFrame, on path: [String]) -> String? {
        guard let node = frame.node else { return nil }
        if frame.path == path { return node }
        if frame.path.count > path.count, Array(frame.path.prefix(path.count)) == path {
            return frame.path[path.count].split(separator: "#").first.map(String.init)
        }
        return nil
    }

    /// The step's node, the node it talks to, and the queue its message goes to, on this level.
    static func places(of frame: JourneyFrame, on path: [String]) -> (node: String?, target: String?, buffer: String?) {
        let node = self.node(of: frame, on: path)
        guard frame.path == path else { return (node, nil, nil) }
        return (node, frame.target, frame.buffer)
    }

    private static var cache: [Key: StageHighlight] = [:]
    private struct Key: Hashable {
        let player: ObjectIdentifier
        let shown: Int
        let path: [String]
        let routes: Int
    }

    /// The stage highlight for the open journey at its current step, on this level.
    static func highlight(_ player: SimJourneyPlayer, path: [String], layout: StageLayout) -> StageHighlight? {
        let key = Key(player: ObjectIdentifier(player), shown: player.shown, path: path, routes: layout.routesByID.count)
        if let cached = cache[key] { return cached }
        let value = compute(player, path: path, layout: layout)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = value
        return value
    }

    private static func compute(_ player: SimJourneyPlayer, path: [String], layout: StageLayout) -> StageHighlight? {
        var highlight = StageHighlight()
        highlight.dimsRest = true
        let frames = player.playback.frames
        guard player.shown >= 0 else {
            // The start: where the first step happens, so the eye knows where the story begins.
            if let first = frames.first, let node = node(of: first, on: path), layout.cardsByID[node] != nil {
                highlight.nodes = [node]
                highlight.tints[node] = StageTint(color: Theme.accent, strength: 0.55)
                highlight.markers = [StageMarker(node: node, number: 1, current: false)]
            }
            return highlight
        }
        var exit: String?
        var numbers: [String: Int] = [:]
        for index in 0...player.shown {
            let frame = frames[index]
            let current = index == player.shown
            let (node, target, buffer) = places(of: frame, on: path)
            // The current step in the accent; the route so far in a faint accent trail (`strength` 0 on
            // a weaker colour), which reads as visited without competing with the step on screen.
            func tint(_ value: Double?) -> StageTint {
                value.map { StageTint(color: Theme.accent, strength: $0) } ?? StageTint(color: Theme.accent.opacity(0.55), strength: 0)
            }
            func rank(_ tint: StageTint?) -> Double { tint.map { $0.strength + ($0.color == Theme.accent ? 1 : 0) } ?? -1 }
            func light(_ id: String?, _ value: Double?) {
                guard let id, layout.cardsByID[id] != nil else { return }
                highlight.nodes.insert(id)
                let next = tint(value)
                if rank(next) >= rank(highlight.tints[id]) { highlight.tints[id] = next }
            }
            func lightEdge(_ id: String, _ value: Double?) {
                highlight.edges.insert(id)
                let next = tint(value)
                if rank(next) >= rank(highlight.edgeTints[id]) { highlight.edgeTints[id] = next }
            }
            if let node {
                // The way it came: from where the step before left off (its queue, else its node).
                if let exit, exit != node {
                    for edge in route(from: exit, to: node, layout: layout) { lightEdge(edge, current ? 1 : nil) }
                    for hop in hops(from: exit, to: node, layout: layout) { light(hop, current ? 0.55 : nil) }
                }
                light(node, current ? 1 : nil)
                numbers[node] = index + 1
                // What it talks to lights for the current step only; a queue stays on the route.
                if let buffer, buffer != node {
                    light(buffer, current ? 0.7 : nil)
                    if let edge = edge(between: node, and: buffer, layout: layout) { lightEdge(edge, current ? 0.75 : nil) }
                }
                if current, let target, target != node, target != buffer {
                    light(target, 0.6)
                    if let edge = edge(between: node, and: target, layout: layout) { lightEdge(edge, 0.75) }
                }
                exit = buffer ?? node
            }
        }
        let currentNode = node(of: frames[player.shown], on: path)
        highlight.markers = numbers.compactMap { node, number in
            layout.cardsByID[node] == nil ? nil : StageMarker(node: node, number: number, current: node == currentNode && number == player.shown + 1)
        }.sorted { $0.number < $1.number }
        return highlight
    }

    static func edge(between a: String, and b: String, layout: StageLayout) -> String? {
        if layout.routesByID["\(a)->\(b)"] != nil { return "\(a)->\(b)" }
        if layout.routesByID["\(b)->\(a)"] != nil { return "\(b)->\(a)" }
        return nil
    }

    /// The edges of the shortest way from one node to another (along edges first, then either way),
    /// up to four hops; none when they aren't connected.
    static func route(from start: String, to end: String, layout: StageLayout) -> [String] {
        path(from: start, to: end, layout: layout).edges
    }

    /// The nodes passed through on the way, not counting the ends.
    static func hops(from start: String, to end: String, layout: StageLayout) -> [String] {
        Array(path(from: start, to: end, layout: layout).nodes.dropFirst().dropLast())
    }

    private static func path(from start: String, to end: String, layout: StageLayout) -> (edges: [String], nodes: [String]) {
        let edges = layout.routesByID.values.map(\.edge)
        for directed in [true, false] {
            var previous: [String: (node: String, edge: String)] = [:]
            var frontier = [start]
            var seen: Set<String> = [start]
            var depth = 0
            while !frontier.isEmpty, depth < 4, previous[end] == nil {
                var next: [String] = []
                for node in frontier {
                    for edge in edges {
                        var other: String?
                        if edge.from == node { other = edge.to }
                        else if !directed, edge.to == node { other = edge.from }
                        guard let other, !seen.contains(other) else { continue }
                        seen.insert(other)
                        previous[other] = (node, edge.id)
                        next.append(other)
                    }
                }
                frontier = next.sorted()
                depth += 1
            }
            guard previous[end] != nil else { continue }
            var edgesOnPath: [String] = []
            var nodes = [end]
            var cursor = end
            while let step = previous[cursor] {
                edgesOnPath.insert(step.edge, at: 0)
                nodes.insert(step.node, at: 0)
                cursor = step.node
            }
            return (edgesOnPath, nodes)
        }
        return ([], [])
    }

    // MARK: Camera

    /// The node the camera should keep on screen, with the step, so each step asks once.
    static func focus(_ player: SimJourneyPlayer?, path: [String]) -> String? {
        guard let player, let frame = player.frame ?? player.playback.frames.first else { return nil }
        return node(of: frame, on: path).map { "\(player.shown)#\($0)" }
    }

    /// Pans (gliding unless `animated` is false) so the step's node is on screen, keeping the zoom.
    static func follow(_ focus: String?, viewport: StageViewport, layout: StageLayout, animated: Bool) {
        guard let focus, let node = focus.split(separator: "#", maxSplits: 1).last.map(String.init),
              let card = layout.cardsByID[node], viewport.size.width > 0 else { return }
        let camera = viewport.current(layout, in: viewport.size, compact: false)
        let screen = camera.screen(card.rect)
        let room = CGRect(origin: .zero, size: viewport.size).insetBy(dx: min(48, viewport.size.width / 6), dy: min(36, viewport.size.height / 6))
        guard !room.contains(screen) else { return }
        var target = camera
        target.offset = CGPoint(x: viewport.size.width / 2 - card.rect.midX * camera.zoom,
                                y: viewport.size.height / 2 - card.rect.midY * camera.zoom)
        guard animated else { viewport.camera = target; return }
        glide?.cancel()
        glide = Task { @MainActor in
            let start = camera.offset, frames = 14
            for i in 1...frames {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                let t = Double(i) / Double(frames)
                let eased = 1 - pow(1 - t, 3)
                var next = target
                next.offset = CGPoint(x: start.x + (target.offset.x - start.x) * eased, y: start.y + (target.offset.y - start.y) * eased)
                viewport.camera = next
            }
        }
    }

    private static var glide: Task<Void, Never>?

    /// Offscreen there is no follow-up frame to glide in: the opening camera, moved so the step's node
    /// is on screen. nil when no journey is open or the node is already in view.
    static func stillCamera(_ player: SimJourneyPlayer?, path: [String], viewport: StageViewport, layout: StageLayout, size: CGSize) -> StageCamera? {
        guard let focus = focus(player, path: path), let node = focus.split(separator: "#", maxSplits: 1).last.map(String.init),
              let card = layout.cardsByID[node], size.width > 0 else { return nil }
        let camera = viewport.current(layout, in: size, compact: false)
        let room = CGRect(origin: .zero, size: size).insetBy(dx: min(48, size.width / 6), dy: min(36, size.height / 6))
        guard !room.contains(camera.screen(card.rect)) else { return nil }
        var moved = camera
        moved.offset = CGPoint(x: size.width / 2 - card.rect.midX * camera.zoom, y: size.height / 2 - card.rect.midY * camera.zoom)
        return moved
    }
}

/// Keeps the open journey's current node on screen. Its own view, so a step change re-renders this
/// and not the workspace around the stage.
@MainActor
struct SimJourneyFollower: View {
    let model: AppModel
    let sim: Simulation
    let viewport: StageViewport
    let renderer: StageRenderer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let focus = SimJourneyStage.focus(SimJourneyState.of(model).player(for: sim.manifest.id), path: sim.path)
        Color.clear
            .onChange(of: focus) { _, focus in
                SimJourneyStage.follow(focus, viewport: viewport, layout: renderer.layout, animated: !reduceMotion)
            }
            .onAppear(perform: openPendingHow)
            .accessibilityHidden(true)
    }

    /// A step's How it works on another level: this level was opened for it, so play it here.
    private func openPendingHow() {
        let state = SimJourneyState.of(model)
        guard let pending = state.pendingHow, pending.manifest == sim.manifest.id, pending.path == sim.path,
              let owner = sim.level.node(pending.node) else { return }
        state.pendingHow = nil
        let mechanisms = pending.op.flatMap { op in owner.ops.first { $0.id == op }?.how } ?? owner.how
        guard let mechanism = mechanisms.first(where: { $0.id == pending.mechanism }) else { return }
        let label = pending.op.flatMap { op in owner.ops.first { $0.id == op }?.label } ?? owner.label
        SimHowState.of(sim).open(mechanism, ref: SimHowRef(node: owner.id, op: pending.op, mechanism: mechanism.id), owner: label)
    }
}

extension StageRenderer {
    /// The journey's numbered markers, on each node's top-left corner; the current step's is filled.
    func drawMarkers(_ markers: [StageMarker], layout: StageLayout, in context: GraphicsContext) {
        for marker in markers {
            guard let card = layout.cardsByID[marker.node] else { continue }
            let radius: CGFloat = marker.current ? 10.5 : 8.5
            let center = CGPoint(x: card.rect.minX + 3, y: card.rect.minY + 3)
            let disc = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            if marker.current {
                context.fill(Path(ellipseIn: disc.insetBy(dx: -5, dy: -5)), with: .color(Theme.accent.opacity(0.16)))
                context.fill(Path(ellipseIn: disc), with: .color(Theme.accent))
            } else {
                context.fill(Path(ellipseIn: disc), with: .color(Theme.overlay))
                context.stroke(Path(ellipseIn: disc), with: .color(Theme.accent.opacity(0.6)), lineWidth: 1.2)
            }
            let size: CGFloat = marker.number >= 100 ? 7.5 : marker.number >= 10 ? (marker.current ? 9.5 : 8) : (marker.current ? 11 : 9.5)
            let text = context.resolve(Text("\(marker.number)").font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundStyle(marker.current ? Theme.bg : Theme.accent))
            context.draw(text, at: center)
        }
    }
}
