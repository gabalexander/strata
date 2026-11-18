import Foundation
import Observation
import SwiftUI
import StrataCore

// The Pressure tab's shared state, one per session (docs/manifest.md, Traffic, SLOs and pressure):
// the section on screen, heat mode, a pinned blast radius, scale steps tried from the tab, and the
// static capacity report, computed once per `sim.revision`.

/// Where the pressure numbers come from: the simulation's analysis API in the app, a hand-built
/// preview in snapshot scenes.
@_spi(Snapshots) @MainActor
public protocol SimPressureSource {
    func capacityReport(_ sim: Simulation) -> CapacityReport
    func culprits(_ sim: Simulation) -> [Culprit]
    func blastRadius(_ node: String, in sim: Simulation) -> BlastRadius
}

@MainActor
private struct SimPressureLive: SimPressureSource {
    func capacityReport(_ sim: Simulation) -> CapacityReport { sim.capacityReport() }
    func culprits(_ sim: Simulation) -> [Culprit] { sim.culprits() }
    func blastRadius(_ node: String, in sim: Simulation) -> BlastRadius { sim.blastRadius(node) }
}

@_spi(Snapshots) public enum SimPressureSection: String, CaseIterable {
    case now = "Right now"
    case bottlenecks = "Bottlenecks"
    case scale = "Scale next"
    case stores = "Data stores"
    case volumes = "Volumes"
    case capacity = "Capacity"

    var icon: String {
        switch self {
        case .now: "waveform.path.ecg"
        case .bottlenecks: "gauge.with.dots.needle.67percent"
        case .scale: "plus.square.on.square"
        case .stores: "cylinder.split.1x2"
        case .volumes: "chart.bar"
        case .capacity: "rectangle.stack"
        }
    }
}

/// What a stage overlay of the Pressure tab shows. The ops path highlight is the third contender.
enum SimPressureOverlay: Equatable {
    case heat
    case blast(String)
}

@MainActor
@Observable
final class SimPressureState {
    /// A scale step run from the tab ("Try it" or "Scale to fix"), kept for Undo.
    struct Tried: Identifiable, Equatable {
        let id = UUID()
        let node: String
        let from: Int
        let to: Int
    }

    /// The report with lookups the sections need, for one revision.
    struct Analysis {
        let report: CapacityReport
        let nodes: [String: NodeCapacity]
        /// Flows whose bottleneck is the node.
        let bottleneckFor: [String: [FlowCapacity]]
        let steps: [String: ScaleStep]
    }

    var section: SimPressureSection = .now
    private(set) var heat = false
    /// "Show blast radius": shown while this selection (a node) stays selected, tab open or not.
    private(set) var pin: StageSelection?
    /// Escape hid the blast radius the open tab shows for this selection, until the selection changes.
    private(set) var dismissed: StageSelection?
    /// Bumped to ask the workspace to open the dock on the Pressure tab.
    private(set) var tabRequest = 0
    private(set) var tried: [Tried] = []

    @ObservationIgnored var source: any SimPressureSource = SimPressureLive()
    @ObservationIgnored private var cached: (revision: Int, analysis: Analysis)?
    @ObservationIgnored private var blasts: [String: BlastRadius] = [:]
    @ObservationIgnored private var heatHighlight: (revision: Int, highlight: StageHighlight)?
    @ObservationIgnored private var blastHighlights: [String: StageHighlight] = [:]

    // "The last one requested wins": every request takes the next number; the highest active one shows.
    @ObservationIgnored private var clock = 0
    @ObservationIgnored private var heatSeq = 0
    @ObservationIgnored private var pinSeq = 0
    @ObservationIgnored private var tabSeq = 0
    @ObservationIgnored private var opsSeq = 0
    @ObservationIgnored private var lastTabNode: String?
    @ObservationIgnored private var lastOps: OpRef?

    private init() {}

    private static let stores = NSMapTable<Simulation, SimPressureState>.weakToStrongObjects()

    static func of(_ sim: Simulation) -> SimPressureState {
        if let store = stores.object(forKey: sim) { return store }
        let store = SimPressureState()
        stores.setObject(store, forKey: sim)
        return store
    }

    private func tick() -> Int {
        clock += 1
        return clock
    }

    // MARK: Data

    /// The static capacity report, computed at most once per revision. Reading it observes `revision`.
    func analysis(_ sim: Simulation) -> Analysis {
        let revision = sim.revision
        if let cached, cached.revision == revision { return cached.analysis }
        let report = source.capacityReport(sim)
        var bottleneckFor: [String: [FlowCapacity]] = [:]
        for flow in report.flows { if let node = flow.bottleneck { bottleneckFor[node, default: []].append(flow) } }
        let analysis = Analysis(report: report,
                                nodes: Dictionary(report.nodes.map { ($0.node, $0) }, uniquingKeysWith: { first, _ in first }),
                                bottleneckFor: bottleneckFor,
                                steps: Dictionary(report.scalePlan.map { ($0.node, $0) }, uniquingKeysWith: { first, _ in first }))
        cached = (revision, analysis)
        return analysis
    }

    /// Live: call from a `SimLive` leaf.
    func culprits(_ sim: Simulation) -> [Culprit] {
        source.culprits(sim).sorted { $0.severity > $1.severity }
    }

    /// Pure graph analysis of the level, so one per node for the session.
    func blastRadius(_ node: String, sim: Simulation) -> BlastRadius {
        if let known = blasts[node] { return known }
        let radius = source.blastRadius(node, in: sim)
        blasts[node] = radius
        return radius
    }

    /// Of the flows a node is the bottleneck for, the one closest to its limit (rate / max rate).
    func primaryFlow(for node: String, sim: Simulation) -> FlowCapacity? {
        analysis(sim).bottleneckFor[node]?.max { load($0) < load($1) }
    }

    func load(_ flow: FlowCapacity) -> Double { flow.maxRate.map { flow.rate / max($0, 0.000_001) } ?? 0 }

    func replicas(_ node: String, sim: Simulation) -> Int {
        sim.effective(node).replicas ?? sim.nodeState(node)?.replicas ?? 1
    }

    // MARK: Requests

    func openTab(_ section: SimPressureSection? = nil) {
        if let section { self.section = section }
        tabRequest += 1
    }

    func toggleHeat() {
        heat.toggle()
        if heat { heatSeq = tick() }
    }

    /// Pins a node's blast radius while it stays selected (the caller selects it).
    func showBlast(_ node: String) {
        pin = .node(node)
        dismissed = nil
        pinSeq = tick()
    }

    func selectionChanged(to selection: StageSelection?) {
        if pin != nil, pin != selection { pin = nil }
        if dismissed != nil, dismissed != selection { dismissed = nil }
    }

    /// Runs `scale <node> <replicas>`; Undo returns it to where it was before the first try.
    func scale(_ node: String, to target: Int, sim: Simulation) {
        let current = replicas(node, sim: sim)
        guard target != current, target >= 1 else { return }
        let from = tried.first { $0.node == node }?.from ?? current
        tried.removeAll { $0.node == node }
        sim.perform([.scale(node, target, relative: false)])
        if from != target { tried.append(Tried(node: node, from: from, to: target)) }
    }

    func undo(_ step: Tried, sim: Simulation) {
        tried.removeAll { $0.id == step.id }
        sim.perform([.scale(step.node, step.from, relative: false)])
    }

    /// Tries that still hold (a reset or another scale command makes them stale).
    func liveTries(_ sim: Simulation) -> [Tried] {
        tried.filter { replicas($0.node, sim: sim) == $0.to }
    }

    // MARK: Stage

    /// The pressure overlay that wins on the stage, or nil when the ops path (or nothing) shows.
    /// Requests are ordered: heat on, a pinned blast radius, the open tab meeting a newly selected
    /// node, and a newly lit op path each take the next number, and the highest one still active wins.
    func overlay(for selection: StageSelection?, tabOpen: Bool, opsLit: OpRef?, level: Level) -> SimPressureOverlay? {
        if opsLit != lastOps {
            lastOps = opsLit
            if opsLit != nil { opsSeq = tick() }
        }
        var node: String?
        if case .node(let id) = selection, let found = level.node(id),
           found.kind.role == .server || found.kind.role == .buffer { node = id }
        let tabNode = tabOpen && dismissed != selection ? node : nil
        if tabNode != lastTabNode {
            lastTabNode = tabNode
            if tabNode != nil { tabSeq = tick() }
        }
        var best: (seq: Int, overlay: SimPressureOverlay?)?
        if opsLit != nil { best = (opsSeq, nil) }
        if heat, heatSeq > best?.seq ?? -1 { best = (heatSeq, .heat) }
        if let node {
            let seq = max(pin == selection ? pinSeq : -1, tabNode != nil ? tabSeq : -1)
            if seq >= 0, seq > best?.seq ?? -1 { best = (seq, .blast(node)) }
        }
        return best?.overlay
    }

    /// What the stage brightens: the winning overlay's highlight, else the ops path's. Cheap enough
    /// for every frame: heat is cached per revision, a blast radius per node.
    func highlight(for selection: StageSelection?, tabOpen: Bool, sim: Simulation) -> StageHighlight? {
        let ops = SimOpsState.of(sim)
        switch overlay(for: selection, tabOpen: tabOpen, opsLit: ops.lit(for: selection), level: sim.level) {
        case .heat: return heat(sim)
        case .blast(let node): return blast(node, sim: sim)
        case nil: return ops.highlight(for: selection)
        }
    }

    /// Escape on the stage clears whichever overlay is showing: heat, the blast radius, or (through
    /// SimOpsState) the op detail and pinned path. False if nothing was showing.
    func escape(_ selection: StageSelection?, tabOpen: Bool, sim: Simulation) -> Bool {
        let ops = SimOpsState.of(sim)
        switch overlay(for: selection, tabOpen: tabOpen, opsLit: ops.lit(for: selection), level: sim.level) {
        case .heat:
            heat = false
            return true
        case .blast:
            pin = nil
            dismissed = selection
            return true
        case nil:
            return ops.escape(selection)
        }
    }

    /// Clears an overlay from its legend chip.
    func clear(_ overlay: SimPressureOverlay, selection: StageSelection?) {
        switch overlay {
        case .heat: heat = false
        case .blast:
            pin = nil
            dismissed = selection
        }
    }

    /// Observed by the stage so a paused canvas repaints when an overlay changes.
    func watch() -> Watch { Watch(heat: heat, pin: pin, dismissed: dismissed) }

    struct Watch: Equatable {
        let heat: Bool
        let pin: StageSelection?
        let dismissed: StageSelection?
    }

    private func heat(_ sim: Simulation) -> StageHighlight {
        let analysis = analysis(sim)
        if let heatHighlight, heatHighlight.revision == sim.revision { return heatHighlight.highlight }
        var highlight = StageHighlight()
        highlight.dimsRest = false
        for capacity in analysis.report.nodes where capacity.slots != nil {
            let util = capacity.utilization
            highlight.nodes.insert(capacity.node)
            highlight.tints[capacity.node] = StageTint(color: SimPressureStyle.heat(util),
                                                       strength: util < 0.5 ? 0.3 : util < 0.8 ? 0.65 : 1,
                                                       tag: "util \(SimPressureFormat.percent(util))")
        }
        heatHighlight = (sim.revision, highlight)
        return highlight
    }

    private func blast(_ node: String, sim: Simulation) -> StageHighlight {
        if let known = blastHighlights[node] { return known }
        let radius = blastRadius(node, sim: sim)
        var highlight = StageHighlight()
        highlight.nodes = Set([node] + radius.upstream + radius.absorbers + radius.lagging)
        highlight.edges = Set(radius.edges)
        // Nearest callers strongest: they saturate first. Hops back from the node along the edges.
        var distance: [String: Int] = [node: 0]
        var frontier = [node]
        while !frontier.isEmpty {
            var next: [String] = []
            for id in radius.edges {
                let ends = id.components(separatedBy: "->")
                guard ends.count == 2, frontier.contains(ends[1]), distance[ends[0]] == nil,
                      radius.upstream.contains(ends[0]) else { continue }
                distance[ends[0]] = distance[ends[1]]! + 1
                next.append(ends[0])
            }
            frontier = next
        }
        func strength(_ hops: Int) -> Double { max(0.3, 1.05 - Double(hops) * 0.22) }
        for (offset, id) in radius.upstream.enumerated() {
            let hops = distance[id] ?? offset + 1
            distance[id] = hops
            highlight.tints[id] = StageTint(color: Theme.bad, strength: strength(hops), tag: offset == 0 ? "backs up first" : nil)
        }
        highlight.tints[node] = StageTint(color: Theme.bad, strength: 1, tag: "slow here")
        for id in radius.absorbers { highlight.tints[id] = StageTint(color: Theme.warn, strength: 0.8, tag: "stops here", ring: true) }
        for id in radius.lagging where highlight.tints[id] == nil {
            highlight.tints[id] = StageTint(color: Theme.warn, strength: 0.6, tag: "lag grows")
        }
        let hot = Set([node] + radius.upstream)
        for id in radius.edges {
            let ends = id.components(separatedBy: "->")
            guard ends.count == 2 else { continue }
            if hot.contains(ends[0]), hot.contains(ends[1]) {
                highlight.edgeTints[id] = StageTint(color: Theme.bad, strength: strength(max(distance[ends[0]] ?? 9, distance[ends[1]] ?? 9)))
            } else {
                highlight.edgeTints[id] = StageTint(color: Theme.warn, strength: 0.5)
            }
        }
        blastHighlights[node] = highlight
        return highlight
    }
}

/// Offscreen snapshots: a preview source, a section, heat mode, a pinned blast radius, a tried step.
@_spi(Snapshots) @MainActor
public enum SimPressureSnapshot {
    public static func preview(_ sim: Simulation, source: any SimPressureSource) {
        SimPressureState.of(sim).source = source
    }

    public static func section(_ sim: Simulation, _ section: SimPressureSection) {
        SimPressureState.of(sim).section = section
    }

    public static func heat(_ sim: Simulation) {
        let state = SimPressureState.of(sim)
        if !state.heat { state.toggleHeat() }
    }

    public static func blast(_ sim: Simulation, node: String) {
        SimPressureState.of(sim).showBlast(node)
    }

    /// The tab on its own, taller than the dock, to check a section past the dock's fold.
    public static func tab(_ sim: Simulation, model: AppModel) -> AnyView {
        AnyView(SimPressureTab(sim: sim, model: model, still: true, select: { _ in }).background(Theme.surface))
    }

    /// Runs the first step of the scale plan, as "Try it" would.
    public static func tryFirstStep(_ sim: Simulation) {
        let state = SimPressureState.of(sim)
        guard let step = state.analysis(sim).report.scalePlan.first else { return }
        state.scale(step.node, to: step.replicas, sim: sim)
    }
}
