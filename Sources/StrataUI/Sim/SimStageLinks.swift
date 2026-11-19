import SwiftUI
import StrataCore

/// The toolbar's Links control (docs/design.md, Edges), per map: AppModel.linkOptions, saved in state.json
/// without `showAll`, which lasts for the session.
public struct StageLinkOptions: Codable, Equatable, Sendable {
    /// Edges into one store over one protocol draw as one link (EdgeBundling).
    public var bundle = true
    /// Links into datastores draw thinner and fainter, their pills only when they are relevant.
    public var quiet = true
    /// For now, everything at full: every bundle opened up, every pill, nothing quiet or faded.
    public var showAll = false

    public init(bundle: Bool = true, quiet: Bool = true, showAll: Bool = false) {
        self.bundle = bundle; self.quiet = quiet; self.showAll = showAll
    }

    private enum CodingKeys: String, CodingKey { case bundle, quiet }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bundle = try values.decodeIfPresent(Bool.self, forKey: .bundle) ?? true
        quiet = try values.decodeIfPresent(Bool.self, forKey: .quiet) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(bundle, forKey: .bundle)
        try values.encode(quiet, forKey: .quiet)
    }

    /// What the stage does now: Show all links overrides both.
    var bundles: Bool { bundle && !showAll }
    var quiets: Bool { quiet && !showAll }
    /// What state.json keeps: nothing for the defaults.
    public var saved: Bool { !bundle || !quiet }
}

extension StageLayout {
    /// A drawn bundle (EdgeRouter.BundleRoute): its line into the target and, for a trunk, its members'
    /// lines into the junction (a group's box hides them).
    struct Bundle {
        let bundle: EdgeBundle
        let trunk: Route
        let stubs: [String: Route]
        /// Into a datastore, so "Quiet data links" draws it quieter (its count pill stays).
        let data: Bool

        init(_ bundle: EdgeBundle, geometry: EdgeRouter.BundleRoute, data: Bool) {
            self.bundle = bundle
            self.data = data
            var edge = StrataCore.Edge(from: bundle.id, to: bundle.target)
            edge.label = bundle.label()
            trunk = Route(edge: edge, geometry: geometry.trunk)
            stubs = bundle.group != nil ? [:]
                : geometry.stubs.mapValues { Route(edge: StrataCore.Edge(from: bundle.id, to: bundle.id), geometry: $0) }
        }

        /// A token on folded member `edge`: along its stub into the junction and on down the trunk, or only
        /// along the line from the group's border (inside the box nothing is drawn to travel on).
        func point(_ edge: String, at progress: Double) -> CGPoint {
            guard let stub = stubs[edge] else { return trunk.point(at: progress) }
            let total = stub.length + trunk.length
            guard total > 0.5 else { return trunk.point(at: progress) }
            let distance = CGFloat(min(1, max(0, progress))) * total
            return distance < stub.length ? stub.point(at: Double(distance / max(0.001, stub.length)))
                : trunk.point(at: Double((distance - stub.length) / max(0.001, trunk.length)))
        }

        var bounds: CGRect { stubs.values.reduce(trunk.path.boundingRect) { $0.union($1.path.boundingRect) } }
    }
}

/// How the stage draws links each frame (docs/design.md, Edges): which edges a bundle folds away, how
/// strong each line and pill is, and the fade between one focus and the next.
///
/// - **Focus.** A hovered or selected node keeps its edges at full strength and fades the rest; a selected
///   edge or flow does the same for its edges. An op path or pressure overlay that dims the stage owns the
///   emphasis while it shows, so focus doesn't fade on top of it, but its edges still leave their bundles.
/// - **Quiet.** Links into datastores draw thinner and fainter, without their pill unless relevant.
/// - **Fade.** Strengths ease to their new values on `Theme.snappy`'s spring (none with reduced motion).
@MainActor
@Observable
final class StageLinks {
    /// A fade is playing: the stage keeps drawing frames while paused.
    private(set) var fading = false
    @ObservationIgnored var options = StageLinkOptions()
    @ObservationIgnored var reduceMotion = false
    /// Offscreen snapshots: what to draw as hovered.
    @ObservationIgnored var pinnedHover: StageSelection?

    struct Style: Equatable {
        var alpha: Double
        var width: CGFloat
        var pill: Double

        static let full = Style(alpha: 1, width: 1.5, pill: 1)
        static let hidden = Style(alpha: 0, width: 1.5, pill: 0)

        func mix(_ other: Style, _ t: Double) -> Style {
            Style(alpha: alpha + (other.alpha - alpha) * t, width: width + (other.width - width) * CGFloat(t),
                  pill: pill + (other.pill - pill) * t)
        }
    }

    /// How faint a line out of focus is, and a quiet data link.
    static let faded = 0.2
    static let quietAlpha = 0.6
    static let quietWidth: CGFloat = 1.1

    private struct Key: Equatable {
        var generation: Int
        var nodes: Set<String>
        var edges: Set<String>
        var lit: Set<String>
        var bundle: String?
        var hovered: StageSelection?
        var selected: StageSelection?
        var options: StageLinkOptions
        var dims: Bool
    }

    @ObservationIgnored private var key: Key?
    @ObservationIgnored private var targets: [String: Style] = [:]
    @ObservationIgnored private var from: [String: Style] = [:]
    @ObservationIgnored private var start: Date?
    @ObservationIgnored private var flowEdges: [String: Set<String>] = [:]
    /// The members each bundle stands for now, and the count it showed last (kept while it fades out).
    @ObservationIgnored private(set) var drawn = EdgeBundling.Drawn()
    @ObservationIgnored private var counts: [String: Int] = [:]
    @ObservationIgnored private var hidden: Set<String> = []
    @ObservationIgnored private var focusNodes: Set<String> = []
    @ObservationIgnored private var focusEdges: Set<String> = []
    @ObservationIgnored private var focusing = false

    /// Works out the frame's links: call once per frame before asking for styles. `alerts` are edges whose
    /// state must show (cut, breaker open), so they leave their bundles too.
    func update(_ layout: StageLayout, generation: Int, level: Level, selected: StageSelection?, hovered: StageSelection?,
                highlight: StageHighlight?, alerts: Set<String> = [], at now: Date) {
        var nodes: Set<String> = [], edges: Set<String> = []
        var bundle: String?
        if case .node(let id) = selected { nodes.insert(id) }
        if case .node(let id) = hovered { nodes.insert(id) }
        if case .edge(let id) = selected, layout.bundlesByID[id] == nil { edges.insert(id) }
        if case .edge(let id) = hovered, layout.bundlesByID[id] != nil { bundle = id }
        if case .flow(let id) = selected, let flow = level.flow(id) {
            if flowEdges[id] == nil { flowEdges[id] = level.edgeIDs(of: flow) }
            edges.formUnion(flowEdges[id] ?? [])
        }
        let dims = highlight?.dimsRest ?? false
        // A token under the pointer changes nothing here.
        var pointer = hovered
        if case .flow = hovered { pointer = nil }
        let next = Key(generation: generation, nodes: nodes, edges: edges, lit: (highlight?.edges ?? []).union(edges).union(alerts),
                       bundle: bundle, hovered: pointer, selected: selected, options: options, dims: dims)
        guard next != key else { return }
        let blended = targets.keys.reduce(into: [String: Style]()) { $0[$1] = style($1, at: now) }
        let first = key == nil || key?.generation != generation
        key = next
        retarget(layout, next)
        from = first ? targets : blended
        start = first || reduceMotion ? nil : now
        guard let start else { return }
        Task { @MainActor [weak self] in
            self?.fading = true
            try? await Task.sleep(for: .milliseconds(Int(Self.settle * 1000) + 40))
            guard let self, self.start == start else { return }
            self.fading = false
        }
    }

    /// Redraws a paused stage after an option changes, so it fades to the new look.
    func nudge() {
        let before = start
        Task { @MainActor [weak self] in
            guard let self, !self.fading else { return }
            self.fading = true
            try? await Task.sleep(for: .milliseconds(80))
            // A fade that began meanwhile ends itself.
            if self.start == before { self.fading = false }
        }
    }

    private func retarget(_ layout: StageLayout, _ key: Key) {
        let all = layout.bundles.map(\.bundle)
        drawn = key.options.bundles ? EdgeBundling.drawn(all, focus: key.nodes, lit: key.lit) : EdgeBundling.Drawn()
        if !key.options.bundles { for bundle in all { drawn.loose.formUnion(bundle.edges) } }
        for (id, kept) in drawn.bundles { counts[id] = kept.count }
        hidden = Set(drawn.bundles.values.joined())
        focusNodes = key.nodes
        focusEdges = key.edges
        focusing = !key.options.showAll && !key.dims && (!key.nodes.isEmpty || !key.edges.isEmpty)
        let data = Set(layout.cards.filter { EdgeBundling.dataKinds.contains($0.node.kind) }.map(\.node.id))
        var next: [String: Style] = [:]
        for route in layout.routes {
            let edge = route.edge
            if hidden.contains(edge.id) { next[edge.id] = .hidden; continue }
            let touches = touches(edge.id, from: edge.from, to: edge.to)
            let relevant = touches || key.lit.contains(edge.id) || key.hovered == .edge(edge.id) || key.selected == .edge(edge.id)
            let quiet = key.options.quiets && data.contains(edge.to) && !relevant
            let alpha = focusing && !touches ? Self.faded : quiet ? Self.quietAlpha : 1
            next[edge.id] = Style(alpha: alpha, width: quiet ? Self.quietWidth : 1.5, pill: quiet ? 0 : alpha)
        }
        for bundle in layout.bundles {
            guard drawn.bundles[bundle.bundle.id] != nil else { next[bundle.bundle.id] = .hidden; continue }
            let hot = key.bundle == bundle.bundle.id
            let quiet = key.options.quiets && bundle.data && !hot
            let alpha = focusing && !hot ? Self.faded : quiet ? Self.quietAlpha : 1
            next[bundle.bundle.id] = Style(alpha: alpha, width: quiet ? Self.quietWidth : 1.5, pill: focusing && !hot ? Self.faded : 1)
        }
        targets = next
    }

    private func touches(_ id: String, from: String, to: String) -> Bool {
        focusNodes.contains(from) || focusNodes.contains(to) || focusEdges.contains(id)
    }

    /// How long the fade takes to settle, and its curve: `Theme.snappy`'s spring (response 0.28, damping 0.86).
    static let settle = 0.42
    static func spring(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < settle else { return 1 }
        let omega = 2 * Double.pi / 0.28, zeta = 0.86
        let damped = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
    }

    /// The strength of an edge's or a bundle's line and pill now.
    func style(_ id: String, at now: Date = Date()) -> Style {
        let target = targets[id] ?? .full
        guard let start else { return target }
        let t = Self.spring(now.timeIntervalSince(start))
        guard t < 1 else { return target }
        return (from[id] ?? target).mix(target, t)
    }

    /// The count a bundle shows: its members now, or the last it showed while it fades out.
    func count(_ bundle: String) -> Int? { drawn.bundles[bundle]?.count ?? counts[bundle] }

    /// Whether `edge` is folded into a bundle now.
    func folds(_ edge: String) -> Bool { hidden.contains(edge) }

    /// Whether `stub` (a trunk member) is drawn: its edge is still in the bundle.
    func keeps(_ edge: String, in bundle: String) -> Bool { drawn.bundles[bundle]?.contains(edge) ?? (counts[bundle] != nil) }

    /// Tokens off the focus draw dimmed, like the lines they travel.
    func fades(_ edge: String) -> Bool {
        guard focusing else { return false }
        let ends = edge.components(separatedBy: "->")
        return !(ends.count == 2 && touches(edge, from: ends[0], to: ends[1]))
    }

    /// Where a token is when its edge is folded into a bundle; nil when the edge has its own line.
    func point(_ token: TokenView, in layout: StageLayout) -> CGPoint? {
        guard hidden.contains(token.edge) else { return nil }
        for (id, kept) in drawn.bundles where kept.contains(token.edge) {
            return layout.bundlesByID[id]?.point(token.edge, at: token.progress)
        }
        return nil
    }
}

extension StageRenderer {
    /// Bundles' lines (and a trunk's stubs) with a dot where each starts, under the tokens.
    func drawBundles(_ layout: StageLayout, viewport: CGRect, hovered: StageSelection?, in context: GraphicsContext) {
        for bundle in layout.bundles where viewport.intersects(bundle.bounds.insetBy(dx: -2, dy: -2)) {
            let style = links.style(bundle.bundle.id)
            guard style.alpha > 0.01 else { continue }
            var layer = context
            layer.opacity = context.opacity * style.alpha
            let hot = hovered == .edge(bundle.bundle.id)
            let ink = Theme.text.opacity(hot ? 0.62 : 0.42)
            if hot { layer.stroke(bundle.trunk.path, with: .color(ink.opacity(0.12)), style: StrokeStyle(lineWidth: 8, lineCap: .round)) }
            let width = hot ? 2.2 : style.width + 0.5
            for (edge, stub) in bundle.stubs.sorted(by: { $0.key < $1.key }) where links.keeps(edge, in: bundle.bundle.id) {
                layer.stroke(stub.path, with: .color(ink), style: StrokeStyle(lineWidth: style.width, lineCap: .round))
            }
            layer.stroke(bundle.trunk.path, with: .color(ink), style: StrokeStyle(lineWidth: width, lineCap: .round))
            layer.stroke(bundle.trunk.arrow, with: .color(ink), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let origin = bundle.trunk.samples.first ?? .zero
            layer.fill(Path(ellipseIn: CGRect(x: origin.x - 2.6, y: origin.y - 2.6, width: 5.2, height: 5.2)), with: .color(ink))
        }
    }

    /// Each bundle's count pill (`sql · 8`).
    func drawBundleLabels(_ layout: StageLayout, viewport: CGRect, hovered: StageSelection?, in context: GraphicsContext) {
        for bundle in layout.bundles where viewport.intersects(bundle.bounds.insetBy(dx: -2, dy: -2)) {
            let style = links.style(bundle.bundle.id)
            guard style.pill > 0.01, let count = links.count(bundle.bundle.id) else { continue }
            var layer = context
            layer.opacity = context.opacity * style.pill
            let hot = hovered == .edge(bundle.bundle.id)
            pill(bundle.bundle.label(count: count), at: bundle.trunk.labelPoint, width: bundle.trunk.labelWidth + 6,
                 color: hot ? Theme.borderStrong : Theme.border, fill: Theme.overlay.opacity(0.96), in: layer)
        }
    }

    /// A click on a bundle selects its target, which draws every member on its own line.
    func selectable(_ hit: StageSelection?) -> StageSelection? {
        if case .edge(let id) = hit, let bundle = layout.bundlesByID[id] { return .node(bundle.bundle.target) }
        return hit
    }
}

/// The toolbar's Links button: an in-window menu with the three switches.
@MainActor
struct SimLinksButton: View {
    let options: StageLinkOptions
    let overlays: Overlays
    let items: () -> [MenuItem]
    @State private var frame: CGRect = .zero

    var body: some View {
        SimButton(title: "Links", icon: SimLinksMenus.icon, iconOnly: true, active: options.showAll || !options.bundle || !options.quiet,
                  hint: options.showAll ? "Showing all links (click for the options)" : "Links: bundling, quiet data links, show all",
                  shortcut: options.showAll ? Shortcuts.showAllLinks : nil) {
            overlays.showMenu(items(), at: CGPoint(x: frame.minX, y: frame.maxY + 4))
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $0 }
    }
}

@MainActor
enum SimLinksMenus {
    static let icon = "point.topleft.down.to.point.bottomright.curvepath"

    /// The switches, checked where on. `set` stores and applies new options for the map.
    static func items(_ options: StageLinkOptions, set: @escaping @MainActor (StageLinkOptions) -> Void, header: Bool) -> [MenuItem] {
        var bundle = options, quiet = options, all = options
        bundle.bundle.toggle()
        quiet.quiet.toggle()
        all.showAll.toggle()
        return (header ? [MenuItem.header("Links")] : []) + [
            MenuItem("Bundle shared links", icon: "arrow.triangle.merge", checked: options.bundle) { set(bundle) },
            MenuItem("Quiet data links", icon: "cylinder", checked: options.quiet) { set(quiet) },
            MenuItem("Show all links", icon: "eye", shortcut: Shortcuts.showAllLinks.display, checked: options.showAll) { set(all) },
        ]
    }
}

/// Offscreen snapshots: the stage drawn as if the pointer were on a node (or on a bundle, by its id).
@_spi(Snapshots) @MainActor
public enum SimLinksSnapshot {
    public static func hover(_ sim: Simulation, _ target: String) {
        SimSessions.renderer(for: sim).links.pinnedHover = target.hasPrefix("bundle:") ? .edge(target) : .node(target)
    }
}
