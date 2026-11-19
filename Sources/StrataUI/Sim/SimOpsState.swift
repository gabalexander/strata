import Foundation
import Observation
import StrataCore

/// What the operations UI shares between the inspector, the stage, the menus and the palette, one per
/// session: the op detail that replaces the inspector, the row under the pointer, and a pinned path.
/// Each is anchored to the stage selection it was opened from, so selecting something else hides it.
@MainActor
@Observable
final class SimOpsState {
    struct Detail: Equatable {
        /// The selection the detail replaces in the inspector; Back returns to it.
        let anchor: StageSelection?
        /// Ops opened in turn ("Called by", "Reaches"); the last one is on screen.
        var trail: [OpRef]
        var current: OpRef { trail[trail.count - 1] }
    }

    struct Pin: Equatable {
        let anchor: StageSelection?
        let ref: OpRef
    }

    private(set) var detail: Detail?
    private(set) var pin: Pin?
    /// The op row under the pointer, anywhere in the inspector.
    var hovered: OpRef?

    @ObservationIgnored let index: SimOpsIndex
    @ObservationIgnored private var highlights: [OpRef: StageHighlight] = [:]

    private init(sim: Simulation) {
        index = SimOpsIndex(level: sim.level, inherited: sim.manifest.inheritedOps(at: sim.path))
    }

    private static let stores = NSMapTable<Simulation, SimOpsState>.weakToStrongObjects()

    static func of(_ sim: Simulation) -> SimOpsState {
        if let store = stores.object(forKey: sim) { return store }
        let store = SimOpsState(sim: sim)
        stores.setObject(store, forKey: sim)
        return store
    }

    /// The op detail to show while `selection` is selected.
    func detail(for selection: StageSelection?) -> Detail? {
        guard let detail, detail.anchor == selection else { return nil }
        return detail
    }

    func open(_ ref: OpRef, from anchor: StageSelection?) {
        guard index.entry(ref) != nil else { return }
        hovered = nil
        detail = Detail(anchor: anchor, trail: [ref])
    }

    /// Jumps to another op from the detail; Back returns to the one before.
    func push(_ ref: OpRef) {
        guard var detail, index.entry(ref) != nil, detail.current != ref else { return }
        hovered = nil
        detail.trail.append(ref)
        self.detail = detail
    }

    func back() {
        guard var detail else { return }
        hovered = nil
        detail.trail.removeLast()
        self.detail = detail.trail.isEmpty ? nil : detail
    }

    func close() {
        hovered = nil
        detail = nil
    }

    func isPinned(_ ref: OpRef, at anchor: StageSelection?) -> Bool { pin == Pin(anchor: anchor, ref: ref) }

    /// "Highlight path": keeps an op's path lit on the stage while `anchor` stays selected.
    func togglePin(_ ref: OpRef, at anchor: StageSelection?) {
        pin = isPinned(ref, at: anchor) ? nil : Pin(anchor: anchor, ref: ref)
    }

    /// Forgets what belonged to an earlier selection, so coming back to it starts fresh.
    func selectionChanged(to selection: StageSelection?) {
        hovered = nil
        if let detail, detail.anchor != selection { self.detail = nil }
        if let pin, pin.anchor != selection { self.pin = nil }
    }

    /// Escape on the stage: back out of the op detail, then drop a pinned path. False if neither is up.
    func escape(_ selection: StageSelection?) -> Bool {
        if detail(for: selection) != nil { back(); return true }
        if let pin, pin.anchor == selection { self.pin = nil; return true }
        return false
    }

    /// The op whose path the stage shows: the hovered row, else the open detail, else a pinned path.
    func lit(for selection: StageSelection?) -> OpRef? {
        hovered ?? detail(for: selection)?.current ?? pin.flatMap { $0.anchor == selection ? $0.ref : nil }
    }

    func highlight(for selection: StageSelection?) -> StageHighlight? {
        guard let ref = lit(for: selection) else { return nil }
        if let cached = highlights[ref] { return cached }
        let highlight = index.highlight(ref)
        highlights[ref] = highlight
        return highlight
    }
}

/// Offscreen snapshots: open an op detail, hover or pin an op, and show a node's menu.
@_spi(Snapshots) @MainActor
public enum SimOpsSnapshot {
    public static func open(_ sim: Simulation, node: String, op: String, from anchor: String?) {
        SimOpsState.of(sim).open(OpRef(node: node, op: op), from: anchor.map(StageSelection.node))
    }

    public static func hover(_ sim: Simulation, node: String, op: String) {
        SimOpsState.of(sim).hovered = OpRef(node: node, op: op)
    }

    public static func pin(_ sim: Simulation, node: String, op: String, at anchor: String?) {
        SimOpsState.of(sim).togglePin(OpRef(node: node, op: op), at: anchor.map(StageSelection.node))
    }

    /// The stage's right-click menu for a node, as a right-click would show it.
    public static func nodeMenu(_ sim: Simulation, model: AppModel, node: String) -> [MenuItem] {
        SimActions(model: model, sim: sim, fit: {}, dive: { _ in }).menu(for: .node(node))
    }

    /// Selects a node of the open root level once the sim screen appears.
    public static func select(_ node: String, in id: String, model: AppModel) {
        SimFocus.of(model).reveal(node, in: id, path: [], model: model)
    }
}
