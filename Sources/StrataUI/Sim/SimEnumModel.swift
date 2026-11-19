import AppKit
import Observation
import SwiftUI
import StrataCore

// Enums as the sim screen sees them (docs/manifest.md, Enums): which column holds which enum, the
// values found in each query and payload (cached per text, so nothing scans on a frame), the hover
// card and the detail panel that are open, and the ways in (a value, a column chip, the inspector
// row, ⌘K). Views reach the session through `SimEnumScope` in the environment.

/// The enum colour: chips, glyphs and the detail's header. Tables are teal, the accent is selection.
let simEnumTint = Theme.token(2)

/// Enum lookups for one session, built once per simulation.
@MainActor
final class SimEnumIndex {
    let manifest: Manifest
    let level: Level
    private var occurrences: [String: [EnumOccurrence]] = [:]
    private var usages: [String: EnumUsage] = [:]

    private init(sim: Simulation) {
        manifest = sim.manifest
        level = sim.level
    }

    private static let stores = NSMapTable<Simulation, SimEnumIndex>.weakToStrongObjects()

    static func of(_ sim: Simulation) -> SimEnumIndex {
        if let store = stores.object(forKey: sim) { return store }
        let store = SimEnumIndex(sim: sim)
        stores.setObject(store, forKey: sim)
        return store
    }

    var isEmpty: Bool { manifest.enums.isEmpty }

    func def(_ id: String) -> EnumDef? { manifest.enumDef(id) }

    /// The enum a column of this level holds.
    func enumOf(_ table: SimTableRef, column: String) -> EnumDef? {
        guard !isEmpty else { return nil }
        return level.table(table.node, table.table)?.column(column)?.enumRef.flatMap(def)
    }

    /// The enums a node's tables hold, in column order.
    func enums(of node: Node) -> [EnumDef] {
        var ids: [String] = []
        for table in node.schema {
            for column in table.columns { if let id = column.enumRef, !ids.contains(id) { ids.append(id) } }
        }
        return ids.compactMap(def)
    }

    /// The enum values in a query or payload, found once per text and tables.
    func occurrences(in text: String, tables: [TableRef]) -> [EnumOccurrence] {
        guard !isEmpty else { return [] }
        let key = tables.map(\.description).joined(separator: ",") + "\u{0}" + text
        if let cached = occurrences[key] { return cached }
        let found = manifest.enumOccurrences(in: text, level: level, tables: tables)
        occurrences[key] = found
        return found
    }

    func usage(_ id: String) -> EnumUsage {
        if let cached = usages[id] { return cached }
        let usage = manifest.enumUsage(id)
        usages[id] = usage
        return usage
    }

    /// `orders-svc · Capture payment` for `orders/capture-payment`, `scheduler` for a node.
    func actorTitle(_ by: String) -> String {
        guard let actor = manifest.resolveActor(by), let level = manifest.level(at: actor.path),
              let node = level.node(actor.node) else { return by }
        guard let op = actor.op else { return node.label }
        return "\(node.label) · \(node.ops.first { $0.id == op }?.label ?? op)"
    }
}

/// What a hover card shows for one literal of one enum.
struct SimEnumCardContent {
    struct Next: Identifiable {
        let id: Int
        let code: String
        let name: String?
        let label: String?
        let by: String?
        let terminal: Bool
    }

    let label: String
    let literal: String
    let value: EnumValue?
    /// The value's code differs from its name (`3200 scheduled`); string enums often use the name.
    let coded: Bool
    let next: [Next]
    let starts: Bool

    init(def: EnumDef, literal: String) {
        label = def.label
        self.literal = literal
        let value = def.resolve(literal)
        self.value = value
        coded = def.values.contains { $0.value != $0.name }
        let code = value?.value ?? literal
        next = def.transitions(from: code).enumerated().map { offset, transition in
            let target = def.value(transition.to)
            return Next(id: offset, code: transition.to, name: target?.name, label: transition.label, by: transition.by,
                        terminal: target?.terminal ?? false)
        }
        starts = value != nil && def.transitions(to: code).isEmpty && !def.transitions(from: code).isEmpty
    }
}

/// The hover card and the detail panel, one per window.
@MainActor
@Observable
final class SimEnumState {
    struct Card {
        let manifest: String
        let enumID: String
        let literal: String
        /// Window coordinates, top-left origin.
        let anchor: CGRect
        let content: SimEnumCardContent
    }

    struct Detail: Equatable {
        let manifest: String
        let enumID: String
        /// The value the panel highlights (a code), from the value that was clicked or picked.
        var value: String?
    }

    private(set) var card: Card?
    private(set) var detail: Detail?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var hovered: String?
    /// The value under the pointer, for a click on selectable code (which AppKit draws, links and all).
    @ObservationIgnored private var target: (key: String, index: SimEnumIndex, enumID: String, literal: String, anchor: () -> CGRect)?
    @ObservationIgnored private var pressedAt: CGPoint?
    /// Snapshots only: show the card on the first anchor that holds this literal, once it is laid out.
    @ObservationIgnored var previewLiteral: String?
    @ObservationIgnored var previewAnchors: [(index: SimEnumIndex, enumID: String, literal: String, anchor: () -> CGRect)] = []

    private static let stores = NSMapTable<AppModel, SimEnumState>.weakToStrongObjects()

    static func of(_ model: AppModel) -> SimEnumState {
        if let store = stores.object(forKey: model) { return store }
        let store = SimEnumState()
        stores.setObject(store, forKey: model)
        return store
    }

    static let hoverDelay = Duration.milliseconds(250)

    /// The pointer entered a value: its card shows after a short delay, as a glossary term's does.
    func hover(_ key: String, index: SimEnumIndex, enumID: String, literal: String, anchor: @escaping () -> CGRect) {
        guard hovered != key else { return }
        pending?.cancel()
        hovered = key
        target = (key, index, enumID, literal, anchor)
        if card != nil { card = nil }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: SimEnumState.hoverDelay)
            guard let self, !Task.isCancelled, self.hovered == key else { return }
            self.show(index: index, enumID: enumID, literal: literal, anchor: anchor())
        }
    }

    /// The pointer left the value with this key.
    func unhover(_ key: String) {
        guard hovered == key else { return }
        pending?.cancel()
        hovered = nil
        target = nil
        card = nil
    }

    func show(index: SimEnumIndex, enumID: String, literal: String, anchor: CGRect) {
        guard let def = index.def(enumID) else { return }
        card = Card(manifest: index.manifest.id, enumID: enumID, literal: literal, anchor: anchor,
                    content: SimEnumCardContent(def: def, literal: literal))
    }

    func hideCard() {
        pending?.cancel()
        hovered = nil
        target = nil
        card = nil
    }

    /// A mouse down or up in the window (content coordinates). A click that starts and ends on a value
    /// in selectable code opens its enum; a drag that selects text doesn't.
    func mouse(_ type: NSEvent.EventType, at point: CGPoint?, model: AppModel) {
        guard let point else { return }
        if type == .leftMouseDown { pressedAt = point; return }
        defer { pressedAt = nil }
        guard let target, target.key.hasPrefix("code."), let pressedAt, hypot(point.x - pressedAt.x, point.y - pressedAt.y) < 4 else { return }
        let rect = target.anchor().insetBy(dx: -2, dy: -3)
        guard rect.contains(point), rect.contains(pressedAt) else { return }
        open(target.index, enumID: target.enumID, value: target.literal, model: model)
    }

    /// Opens the enum's detail over the stage with `value` (a code or a name) highlighted.
    func open(_ index: SimEnumIndex, enumID: String, value: String?, model: AppModel) {
        pending?.cancel()
        card = nil
        model.overlays.dismissMenu()
        let code = value.flatMap { index.def(enumID)?.resolve($0)?.value } ?? value
        detail = Detail(manifest: index.manifest.id, enumID: enumID, value: code)
    }

    func highlight(_ value: String?) {
        guard var detail, detail.value != value else { return }
        detail.value = value
        self.detail = detail
    }

    func close() { detail = nil }

    /// Snapshots: anchors offer themselves while a preview is pending; the first match shows its card.
    func offerPreview(_ index: SimEnumIndex, enumID: String, literal: String, anchor: @escaping () -> CGRect) {
        guard previewLiteral == literal else { return }
        previewAnchors.append((index, enumID, literal, anchor))
    }

    func showPreview() {
        guard let first = previewAnchors.first else { return }
        show(index: first.index, enumID: first.enumID, literal: first.literal, anchor: first.anchor())
        previewLiteral = nil
        previewAnchors.removeAll()
    }
}

/// The session's enums, for views deep inside the inspector (grid cells, code blocks, entity trees).
@MainActor
struct SimEnumScope: Equatable {
    let model: AppModel
    let sim: Simulation

    var index: SimEnumIndex { SimEnumIndex.of(sim) }
    var state: SimEnumState { SimEnumState.of(model) }

    func open(_ enumID: String, value: String?) {
        state.open(index, enumID: enumID, value: value, model: model)
    }

    nonisolated static func == (lhs: SimEnumScope, rhs: SimEnumScope) -> Bool {
        lhs.model === rhs.model && lhs.sim === rhs.sim
    }
}

private struct SimEnumScopeKey: EnvironmentKey {
    static let defaultValue: SimEnumScope? = nil
}

private struct SimEnumTablesKey: EnvironmentKey {
    static let defaultValue: [TableRef] = []
}

extension EnvironmentValues {
    /// The session whose enums values link to; nil outside a sim's inspector.
    var simEnums: SimEnumScope? {
        get { self[SimEnumScopeKey.self] }
        set { self[SimEnumScopeKey.self] = newValue }
    }

    /// The tables the code below is about (an op's `tables`), preferred when a column is ambiguous.
    var simEnumTables: [TableRef] {
        get { self[SimEnumTablesKey.self] }
        set { self[SimEnumTablesKey.self] = newValue }
    }
}

extension View {
    /// Links enum values inside this view (grid cells, code blocks, entity trees) to the session's enums.
    func simEnumScope(model: AppModel, sim: Simulation) -> some View {
        environment(\.simEnums, SimEnumIndex.of(sim).isEmpty ? nil : SimEnumScope(model: model, sim: sim))
    }

    /// The tables an op names, so a `status` in its query or payload resolves to their enum first.
    func simEnumTables(_ op: StrataCore.Operation, on node: String, level: Level) -> some View {
        let tables = level.tables(touchedBy: op, on: node).compactMap { touched in
            touched.node.map { TableRef(node: $0, table: touched.name) }
        }
        return environment(\.simEnumTables, tables)
    }
}

// MARK: - Navigation

/// Moves from the enum detail to what uses it: a column's table, an op, the node or op behind a transition.
@MainActor
enum SimEnumNav {
    /// Opens a column's table, selecting its node on that column's level.
    static func open(_ column: EnumColumn, sim: Simulation, model: AppModel) {
        SimEnumState.of(model).close()
        let id = sim.manifest.id
        let key = AppModel.sessionKey(id, column.path)
        let ref = SimTableRef(node: column.column.node, table: column.column.table)
        if let session = model.sessions[key] {
            SimDataNav.open(ref, sim: session, model: model, select: nil)
        } else {
            SimFocus.of(model).reveal(column.column.node, in: id, path: column.path, model: model)
        }
    }

    /// Opens an op's detail on its node, on the op's level.
    static func open(op: String, node: String, path: [String], sim: Simulation, model: AppModel) {
        SimEnumState.of(model).close()
        let id = sim.manifest.id
        if let session = model.sessions[AppModel.sessionKey(id, path)] {
            SimOpsMenus.open(OpRef(node: node, op: op), sim: session, model: model, anchor: .node(node))
        }
        model.inspectorVisible = true
        SimFocus.of(model).reveal(node, in: id, path: path, model: model)
    }

    /// A transition's `by`: its op's detail, or its node.
    static func open(actor by: String, sim: Simulation, model: AppModel) {
        guard let actor = sim.manifest.resolveActor(by) else { return }
        if let op = actor.op {
            open(op: op, node: actor.node, path: actor.path, sim: sim, model: model)
        } else {
            SimEnumState.of(model).close()
            SimFocus.of(model).reveal(actor.node, in: sim.manifest.id, path: actor.path, model: model)
        }
    }
}

// MARK: - Menus

@MainActor
enum SimEnumMenus {
    /// A sample cell's "Open Order status · paid", when its column holds an enum.
    static func cell(_ column: Column?, value: String?, sim: Simulation, model: AppModel) -> [MenuItem] {
        let index = SimEnumIndex.of(sim)
        guard let id = column?.enumRef, let def = index.def(id) else { return [] }
        let name = value.flatMap { def.value($0)?.name }
        return [MenuItem("Open \(def.label)" + (name.map { " · \($0)" } ?? ""), icon: "tag") {
            SimEnumState.of(model).open(index, enumID: id, value: value, model: model)
        }]
    }
}

// MARK: - Palette

/// The ⌘K palette's "Enums" group: every value of the current manifest's enums, titled
/// `Campaign status · 3200 scheduled`. Typing a code, a name or the enum's label finds it; choosing
/// one opens the enum with that value highlighted.
@MainActor
enum SimEnumPalette {
    static func entries(model: AppModel, manifest: Manifest?) -> [PaletteEntry] {
        guard case .sim(let id, let path) = model.route, let manifest, !manifest.enums.isEmpty else { return [] }
        return manifest.enums.flatMap { def in
            def.values.map { value in
                let next = def.transitions(from: value.value).compactMap { def.value($0.to)?.name }
                let subtitle = value.doc ?? (value.terminal ? "terminal" : next.isEmpty ? def.id : "→ " + next.joined(separator: ", "))
                return PaletteEntry(id: "enum/\(id)/\(def.id)/\(value.value)", group: .enums,
                                    title: "\(def.label) · \(def.title(value))", symbol: "tag",
                                    subtitle: subtitle,
                                    keywords: [def.id, def.label, value.value, value.name, "enum", "status"].joined(separator: " ")) {
                    open(def.id, value: value.value, manifest: id, path: path, model: model)
                }
            }
        }
    }

    private static func open(_ enumID: String, value: String, manifest id: String, path: [String], model: AppModel) {
        let key = AppModel.sessionKey(id, path)
        guard let sim = model.sessions[key] else { return }
        SimEnumState.of(model).open(SimEnumIndex.of(sim), enumID: enumID, value: value, model: model)
    }
}

// MARK: - Snapshots

/// Offscreen snapshots: open an enum's detail, or show a value's hover card on the first anchor that
/// holds it once the window has laid out.
@_spi(Snapshots) @MainActor
public enum SimEnumSnapshot {
    public static func open(_ sim: Simulation, model: AppModel, enumID: String, value: String?) {
        SimEnumState.of(model).open(SimEnumIndex.of(sim), enumID: enumID, value: value, model: model)
    }

    /// Anchors that show `literal` register as they appear; `show()` then puts up the first one's card.
    public static func previewCard(_ model: AppModel, literal: String) {
        let state = SimEnumState.of(model)
        state.previewLiteral = literal
        state.previewAnchors.removeAll()
    }

    public static func showPreview(_ model: AppModel) { SimEnumState.of(model).showPreview() }

    /// Where the first anchor that holds the previewed literal is, in window coordinates (top-left origin).
    public static func previewRect(_ model: AppModel) -> CGRect? { SimEnumState.of(model).previewAnchors.first?.anchor() }

    /// Whether an enum's detail is open, and on which value.
    public static func openDetail(_ model: AppModel) -> (enumID: String, value: String?)? {
        SimEnumState.of(model).detail.map { ($0.enumID, $0.value) }
    }
}
