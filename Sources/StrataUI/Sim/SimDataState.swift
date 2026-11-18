import AppKit
import Observation
import SwiftUI
import StrataCore

/// What the data UI shares between the inspector, the menus and the palette, one per session: the
/// table open in each database's Data section, the key cell whose joins are lit, which entities are
/// expanded and on which root row, and where the inspector should scroll next. Opening a table or
/// lighting a join is observed state, so it shows on the frame it changes.
@MainActor
@Observable
final class SimDataState {
    /// The table open in each node's Data section, by node id.
    private(set) var open: [String: SimTableRef] = [:]
    /// The key cell whose joins are lit (a pk or fk cell, or a field followed from an entity).
    private(set) var focus: SimCellRef?
    /// Expanded entities, by `SimDataState.entityKey`.
    private(set) var expanded: Set<String> = []
    /// The root row each entity is assembled from, by `SimDataState.entityKey`; the first row by default.
    private(set) var roots: [String: Int] = [:]
    /// Where the inspector scrolls next: a table landing, the joined rows, an entity.
    private(set) var scroll: SimScrollTarget?

    @ObservationIgnored let index: SimDataIndex
    @ObservationIgnored private var joins: [SimRowRef: SimDataJoin] = [:]

    private init(level: Level) { index = SimDataIndex(level: level) }

    private static let stores = NSMapTable<Simulation, SimDataState>.weakToStrongObjects()

    static func of(_ sim: Simulation) -> SimDataState {
        if let store = stores.object(forKey: sim) { return store }
        let store = SimDataState(level: sim.level)
        stores.setObject(store, forKey: sim)
        return store
    }

    static func entityKey(node: String, entity: String) -> String { "\(node)/\(entity)" }

    // Scroll anchors in the inspector.
    static func tableAnchor(_ ref: SimTableRef) -> String { "data.table.\(ref.id)" }
    static func rowsAnchor(_ ref: SimTableRef) -> String { "data.rows.\(ref.id)" }
    static func joinedAnchor(_ node: String) -> String { "data.joined.\(node)" }
    static func entityAnchor(_ key: String) -> String { "data.entity.\(key)" }
    /// The inspector shows a node's anchors while that node is selected.
    private static func context(_ node: String) -> AnyHashable { AnyHashable(StageSelection.node(node)) }

    // MARK: Tables

    /// Opens a table in its node's Data section; `scroll` brings it to the top of the inspector.
    func openTable(_ ref: SimTableRef, scroll: Bool = false) {
        guard index.table(ref) != nil else { return }
        open[ref.node] = ref
        if scroll { self.scroll = SimScrollTarget(id: Self.tableAnchor(ref), anchor: .top, context: Self.context(ref.node), animated: false) }
    }

    /// A diagram card: opens its table, or closes it when it is already open.
    func toggleTable(_ ref: SimTableRef) {
        if open[ref.node] == ref { open[ref.node] = nil } else { openTable(ref) }
    }

    func closeTable(node: String) {
        if let focus, focus.table.node == node { self.focus = nil }
        open[node] = nil
    }

    // MARK: Joins

    /// Lights the rows a key cell joins to and brings the joined rows into view; the same cell again
    /// turns it off.
    func toggleFocus(_ cell: SimCellRef) {
        if focus == cell { focus = nil; return }
        focus = cell
        scroll = SimScrollTarget(id: Self.joinedAnchor(cell.table.node), anchor: nil, context: Self.context(cell.table.node))
    }

    func clearFocus() { focus = nil }

    /// Opens a row's table with its joins lit and its grid at the top of the inspector: where an
    /// entity's field or a palette entry lands.
    func land(_ cell: SimCellRef) {
        guard index.table(cell.table) != nil else { return }
        open[cell.table.node] = cell.table
        focus = cell
        scroll = SimScrollTarget(id: Self.rowsAnchor(cell.table), anchor: .top, context: Self.context(cell.table.node), animated: false)
    }

    /// The rows the focused cell's row joins to (cached per row).
    func join() -> SimDataJoin? {
        guard let row = focus?.row else { return nil }
        if let cached = joins[row] { return cached }
        let join = index.join(from: row)
        joins[row] = join
        return join
    }

    // MARK: Entities

    func isExpanded(_ key: String) -> Bool { expanded.contains(key) }

    func toggleEntity(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    func expandEntity(_ key: String, scroll: Bool) {
        expanded.insert(key)
        if scroll {
            let node = String(key.prefix { $0 != "/" })
            self.scroll = SimScrollTarget(id: Self.entityAnchor(key), anchor: .top, context: Self.context(node), animated: false)
        }
    }

    func root(_ key: String) -> Int { roots[key] ?? 0 }
    func setRoot(_ key: String, row: Int) { roots[key] = row }

    /// Escape on the stage: drop the lit join, then close the open table. False if neither is up.
    func escape(_ selection: StageSelection?) -> Bool {
        guard case .node(let node)? = selection else { return false }
        if let focus, focus.table.node == node { self.focus = nil; return true }
        if open[node] != nil { open[node] = nil; return true }
        return false
    }
}

/// Moves to data from elsewhere: an op's table chip, an entity's field, the menus and the palette.
@MainActor
enum SimDataNav {
    /// Selects the table's node and opens the table at the top of its inspector, with `focus` lit.
    /// Without a `select` (menus, the palette) the node is revealed through `SimFocus`.
    static func open(_ ref: SimTableRef, focus: SimCellRef? = nil, sim: Simulation, model: AppModel,
                     select: ((StageSelection?) -> Void)?) {
        let state = SimDataState.of(sim)
        guard state.index.table(ref) != nil else { return }
        reveal(ref.node, sim: sim, model: model, select: select)
        if let focus { state.land(focus) } else { state.openTable(ref, scroll: true) }
    }

    /// Selects a service and expands one of its entities at the top of the inspector.
    static func open(entity: String, on node: String, sim: Simulation, model: AppModel, select: ((StageSelection?) -> Void)?) {
        reveal(node, sim: sim, model: model, select: select)
        SimDataState.of(sim).expandEntity(SimDataState.entityKey(node: node, entity: entity), scroll: true)
    }

    private static func reveal(_ node: String, sim: Simulation, model: AppModel, select: ((StageSelection?) -> Void)?) {
        model.inspectorVisible = true
        if let select { select(.node(node)) } else { SimFocus.of(model).reveal(node, in: sim.manifest.id, path: sim.path, model: model) }
    }
}

// MARK: - Menus

@MainActor
enum SimDataMenus {
    static let tablesTitle = "Tables"
    static let entitiesTitle = "Entities"

    /// A node's "Tables ›" (databases with a schema) and "Entities ›" (services with entities) submenus.
    /// The right-click has already selected the node.
    static func node(_ node: Node, sim: Simulation, model: AppModel) -> [MenuItem] {
        let state = SimDataState.of(sim)
        var items: [MenuItem] = []
        let tables = state.index.tables(of: node.id)
        if !tables.isEmpty {
            items.append(.submenu(tablesTitle, icon: "tablecells", tables.map { ref in
                let rows = state.index.table(ref)?.volume?.rows.map(SimDataText.count)
                return MenuItem(ref.table, icon: "tablecells", shortcut: rows) {
                    SimDataNav.open(ref, sim: sim, model: model, select: nil)
                }
            }))
        }
        if !node.entities.isEmpty {
            items.append(.submenu(entitiesTitle, icon: "cube", node.entities.map { entity in
                MenuItem(entity.name, icon: "cube") {
                    SimDataNav.open(entity: entity.name, on: node.id, sim: sim, model: model, select: nil)
                }
            }))
        }
        return items
    }

    /// A diagram card's or a table header's menu.
    static func table(_ ref: SimTableRef, sim: Simulation, model: AppModel) -> [MenuItem] {
        let state = SimDataState.of(sim)
        guard let schema = state.index.table(ref) else { return [] }
        let isOpen = state.open[ref.node] == ref
        return [
            .header(ref.table),
            MenuItem(isOpen ? "Close table" : "Open table", icon: isOpen ? "xmark" : "tablecells") { state.toggleTable(ref) },
            .separator,
            copy("Copy table name", ref.table, model: model),
            copy("Copy column names", schema.columns.map(\.name).joined(separator: ", "), model: model),
            copy("Copy rows as TSV", tsv(schema), model: model),
        ]
    }

    /// A sample cell's menu.
    static func cell(_ cell: SimCellRef, sim: Simulation, model: AppModel) -> [MenuItem] {
        let state = SimDataState.of(sim)
        guard let schema = state.index.table(cell.table) else { return [] }
        let value = schema.simDataValue(cell.row.row, cell.column)
        let column = schema.simDataColumn(cell.column)
        let isKey = column?.pk == true || column?.ref != nil
        var items: [MenuItem] = [.header("\(cell.table.table).\(cell.column)")]
        if isKey {
            let lit = state.focus == cell
            items.append(MenuItem(lit ? "Clear joined rows" : "Show joined rows", icon: "point.3.connected.trianglepath.dotted",
                                  checked: lit) { state.toggleFocus(cell) })
        }
        if let key = state.index.key(cell.table, column: cell.column), let value,
           let target = state.index.table(key.to)?.simDataRows(where: key.toColumn, equals: value).first {
            items.append(MenuItem("Open \(key.to.table) row", icon: "arrow.up.right") {
                state.land(SimCellRef(row: SimRowRef(table: key.to, row: target), column: key.toColumn))
            })
        }
        if items.count > 1 { items.append(.separator) }
        items.append(copy("Copy value", value ?? "NULL", model: model))
        items.append(copy("Copy row as JSON", json(schema, row: cell.row.row), model: model))
        return items
    }

    private static func copy(_ title: String, _ text: String, model: AppModel) -> MenuItem {
        MenuItem(title, icon: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            model.overlays.toast(title.replacingOccurrences(of: "Copy", with: "Copied"))
        }
    }

    private static func tsv(_ schema: TableSchema) -> String {
        ([schema.columns.map(\.name)] + schema.rows.map { row in schema.columns.indices.map { row.indices.contains($0) ? row[$0] ?? "NULL" : "" } })
            .map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }

    private static func json(_ schema: TableSchema, row: Int) -> String {
        let fields = schema.columns.map { column in
            "\"\(column.name)\": \(SimDataText.literal(schema.simDataValue(row, column.name), column: column))"
        }
        return "{ " + fields.joined(separator: ", ") + " }"
    }
}

// MARK: - Palette

/// The ⌘K palette's "Data" group: every table of the current level (`orders db · order_items`) and
/// every entity (`orders-svc · Order`). Choosing one selects its node and opens it in the inspector.
@MainActor
enum SimDataPalette {
    static func entries(model: AppModel, manifest: Manifest?) -> [PaletteEntry] {
        guard case .sim(let id, let path) = model.route, let level = manifest?.level(at: path) else { return [] }
        let key = AppModel.sessionKey(id, path)
        let index = model.sessions[key].map { SimDataState.of($0).index } ?? SimDataIndex(level: level)
        let tables = index.tables.compactMap { ref -> PaletteEntry? in
            guard let node = level.node(ref.node), let schema = index.table(ref) else { return nil }
            let subtitle = [SimDataText.volume(schema.volume).map { "\($0) rows" }, "\(schema.columns.count) columns"]
                .compactMap { $0 }.joined(separator: " · ")
            return PaletteEntry(id: "table/\(key)/\(ref.id)", group: .data, title: "\(node.label) · \(ref.table)",
                                symbol: "tablecells", subtitle: subtitle,
                                keywords: ([node.id, ref.table, "table"] + schema.columns.map(\.name)).joined(separator: " ")) {
                if let sim = model.sessions[key] { SimDataNav.open(ref, sim: sim, model: model, select: nil) }
                else { SimFocus.of(model).reveal(ref.node, in: id, path: path, model: model) }
            }
        }
        let entities = level.nodes.flatMap { node in
            node.entities.map { entity in
                PaletteEntry(id: "entity/\(key)/\(node.id)/\(entity.name)", group: .data, title: "\(node.label) · \(entity.name)",
                             symbol: "cube", subtitle: ([entity.root] + entity.includes).joined(separator: ", "),
                             keywords: ([node.id, entity.name, "entity"] + [entity.root] + entity.includes).joined(separator: " ")) {
                    if let sim = model.sessions[key] { SimDataNav.open(entity: entity.name, on: node.id, sim: sim, model: model, select: nil) }
                    else { SimFocus.of(model).reveal(node.id, in: id, path: path, model: model) }
                }
            }
        }
        return tables + entities
    }
}

// MARK: - Snapshots

/// Offscreen snapshots: open a table, light a key's joins, expand an entity, land from an op's chip.
@_spi(Snapshots) @MainActor
public enum SimDataSnapshot {
    public static func openTable(_ sim: Simulation, node: String, table: String) {
        SimDataState.of(sim).openTable(SimTableRef(node: node, table: table))
    }

    /// Lights the joins of the row whose `column` holds `value`, as a click on that cell does.
    public static func focus(_ sim: Simulation, node: String, table: String, column: String, value: String) {
        let ref = SimTableRef(node: node, table: table)
        let state = SimDataState.of(sim)
        guard let row = state.index.table(ref)?.simDataRows(where: column, equals: value).first else { return }
        state.openTable(ref)
        state.toggleFocus(SimCellRef(row: SimRowRef(table: ref, row: row), column: column))
    }

    public static func expandEntity(_ sim: Simulation, node: String, entity: String, rootRow: Int = 0) {
        let key = SimDataState.entityKey(node: node, entity: entity)
        let state = SimDataState.of(sim)
        state.expandEntity(key, scroll: false)
        state.setRoot(key, row: rootRow)
    }

    /// What clicking a table chip in an op detail does, through the menus' path (there is no stage
    /// selection callback offscreen): select the database and land on the table.
    public static func landOnTable(_ sim: Simulation, model: AppModel, node: String, table: String) {
        SimDataNav.open(SimTableRef(node: node, table: table), sim: sim, model: model, select: nil)
    }

    /// The stage's right-click menu for a node, as a right-click would show it.
    public static func nodeMenu(_ sim: Simulation, model: AppModel, node: String) -> [MenuItem] {
        SimActions(model: model, sim: sim, fit: {}, dive: { _ in }).menu(for: .node(node))
    }
}
