import SwiftUI
import StrataCore

/// The inspector's data sections for a node: a database's tables (`SimDataSection`) and a service's
/// entities (`SimEntitiesSection`), each drawn only when the node has them. Nothing here is live: it
/// changes with the selection and `SimDataState`, on the frame they change.
@MainActor
struct SimDataSections: View {
    let model: AppModel
    let sim: Simulation
    let terms: TermIndex
    let node: Node
    let selection: StageSelection?
    let select: (StageSelection?) -> Void
    var pulse: SimPulse?
    var still = false

    var body: some View {
        SimDataSection(model: model, sim: sim, terms: terms, node: node, selection: selection, select: select, pulse: pulse, still: still)
        SimEntitiesSection(model: model, sim: sim, terms: terms, node: node, select: select, still: still)
    }
}

/// A database's Data section: the tables at a glance, and the table open below it.
@MainActor
struct SimDataSection: View {
    let model: AppModel
    let sim: Simulation
    let terms: TermIndex
    let node: Node
    let selection: StageSelection?
    let select: (StageSelection?) -> Void
    var pulse: SimPulse?
    var still = false

    var body: some View {
        let state = SimDataState.of(sim)
        let tables = state.index.tables(of: node.id)
        if !tables.isEmpty {
            let open = state.open[node.id]
            let join = state.focus?.table.node == node.id ? state.join() : nil
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("Data").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted)
                    Text("\(tables.count) tables").font(Theme.mono(10)).foregroundStyle(Theme.faint)
                    Spacer(minLength: 0)
                    if open == nil {
                        Text("Click a table to open it").font(Theme.small).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                }
                SimDataDiagram(index: state.index, node: node.id, open: open, join: join, still: still,
                               tap: { state.toggleTable($0) },
                               menu: { ref, point in model.overlays.showMenu(SimDataMenus.table(ref, sim: sim, model: model), at: point) })
                if let open, let schema = state.index.table(open) {
                    SimDataTableView(model: model, sim: sim, terms: terms, ref: open, schema: schema, join: join,
                                     focus: state.focus, selection: selection, select: select, pulse: pulse, still: still)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One table: its columns, indexes, sample rows, the rows a key joins to, who writes it and the ops
/// that touch it.
@MainActor
struct SimDataTableView: View {
    let model: AppModel
    let sim: Simulation
    let terms: TermIndex
    let ref: SimTableRef
    let schema: TableSchema
    let join: SimDataJoin?
    let focus: SimCellRef?
    let selection: StageSelection?
    let select: (StageSelection?) -> Void
    var pulse: SimPulse?
    var still = false

    private var state: SimDataState { SimDataState.of(sim) }
    private var index: SimDataIndex { state.index }
    private var tint: Color { index.tint(ref) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Anchors sit a little above what they mark, so a landing leaves headroom.
            header.simDataAnchor(SimDataState.tableAnchor(ref))
            if let doc = schema.doc { SimMarkdown(source: doc, model: model, terms: terms, size: 12) }
            writers
            columns
            if !schema.indexes.isEmpty { indexes }
            rows.simDataAnchor(SimDataState.rowsAnchor(ref))
            if let join { joined(join).id(SimDataState.joinedAnchor(ref.node)) }
            entities
            usage
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "tablecells")
                .font(Theme.ui(13, .semibold)).foregroundStyle(tint).frame(width: 32, height: 32)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            VStack(alignment: .leading, spacing: 5) {
                Text(ref.table).font(Theme.mono(14, .semibold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let volume = SimDataText.volume(schema.volume) { SimDataBadge(title: volume) }
                    Text("\(schema.columns.count) columns").font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            SimButton(title: "Close table", icon: "xmark", iconOnly: true) { state.closeTable(node: ref.node) }
        }
        .simOpsMenu(still: still) { model.overlays.showMenu(SimDataMenus.table(ref, sim: sim, model: model), at: $0) }
    }

    /// Who writes the table: its `owner`, or the services whose ops write it, flagging a second writer.
    @ViewBuilder
    private var writers: some View {
        let owners = index.owners(of: ref)
        let others = index.writers(of: ref).filter { !owners.contains($0) }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Written by").font(Theme.ui(11)).foregroundStyle(Theme.muted)
            if owners.isEmpty {
                Text("no op on this level").font(Theme.ui(12)).foregroundStyle(Theme.faint)
            } else {
                ForEach(Array(owners.enumerated()), id: \.offset) { offset, id in
                    SimDataLink(title: (sim.level.node(id)?.label ?? id)) { select(.node(id)) }
                    if offset < owners.count - 1 { Text("·").font(Theme.ui(12)).foregroundStyle(Theme.faint) }
                }
            }
            Spacer(minLength: 0)
        }
        let shared = owners.count + others.count > 1
        if shared {
            let names = (owners.count > 1 ? owners : others).map { sim.level.node($0)?.label ?? $0 }
            Label(owners.count > 1 ? "Shared write · \(owners.count) services" : "Also written by \(names.joined(separator: ", "))",
                  systemImage: "exclamationmark.triangle.fill")
                .font(Theme.ui(11, .medium)).foregroundStyle(Theme.warn)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.warn.opacity(0.10), in: Capsule())
                .padding(.top, -6)
        }
    }

    // MARK: Columns and indexes

    private var columns: some View {
        SimSection(title: "Columns") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(schema.columns.enumerated()), id: \.offset) { offset, column in
                    if offset > 0 { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 30) }
                    columnRow(column)
                }
            }
            .card(radius: 8)
        }
    }

    private func columnRow(_ column: Column) -> some View {
        let key = index.key(ref, column: column.name)
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            HStack(spacing: 1) {
                if column.pk { Image(systemName: "key.fill").font(Theme.ui(9, .semibold)).foregroundStyle(Theme.text.opacity(0.85)) }
                if column.ref != nil { Image(systemName: "arrow.up.right").font(Theme.ui(9, .bold)).foregroundStyle(Theme.token(3)) }
            }
            .frame(width: 14, alignment: .leading)
            .accessibilityLabel([column.pk ? "primary key" : nil, column.ref != nil ? "foreign key" : nil].compactMap { $0 }.joined(separator: ", "))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(column.name).font(Theme.mono(11.5, column.pk ? .semibold : .regular)).foregroundStyle(Theme.text)
                        .lineLimit(1).layoutPriority(1)
                    if let type = column.type { Text(type).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1) }
                    Spacer(minLength: 4)
                    if column.unique { flag("unique") }
                    if let nullable = column.nullable { flag(nullable ? "null" : "not null") }
                }
                if let reference = column.ref {
                    if let key {
                        SimDataLink(title: "→ \(key.from.node == key.to.node ? key.to.table : key.to.id).\(key.toColumn)", mono: true,
                                    tint: Theme.token(3)) {
                            if key.to.node == ref.node { state.openTable(key.to, scroll: true) }
                            else { SimDataNav.open(key.to, sim: sim, model: model, select: select) }
                        }
                    } else {
                        Text("→ \(reference) (not found)").font(Theme.mono(10.5)).foregroundStyle(Theme.bad)
                    }
                }
                if let note = column.note {
                    Text(note).font(Theme.ui(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
    }

    private func flag(_ title: String) -> some View {
        Text(title).font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.border))
            .fixedSize()
    }

    private var indexes: some View {
        SimSection(title: "Indexes") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(schema.indexes.enumerated()), id: \.offset) { offset, text in
                    if offset > 0 { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 30) }
                    let parts = Self.split(index: text)
                    let name = Text(parts.name).font(Theme.mono(10.5)).foregroundStyle(Theme.text)
                    let rest = Text(parts.rest ?? "").font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "list.number").font(Theme.ui(9, .medium)).foregroundStyle(Theme.faint).frame(width: 14)
                        // One line when it fits, the columns under the name when it doesn't.
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) { name.fixedSize(); rest.fixedSize() }
                            VStack(alignment: .leading, spacing: 2) {
                                name.fixedSize(horizontal: false, vertical: true)
                                if parts.rest != nil { rest.fixedSize(horizontal: false, vertical: true) }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                }
            }
            .card(radius: 8)
        }
    }

    /// `orders_user_id_idx (user_id)` → the name and the rest.
    static func split(index text: String) -> (name: String, rest: String?) {
        guard let space = text.firstIndex(of: " ") else { return (text, nil) }
        let rest = text[text.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return (String(text[..<space]), rest.isEmpty ? nil : rest)
    }

    // MARK: Rows and joins

    private var rows: some View {
        let hasKeys = schema.columns.contains { $0.pk || $0.ref != nil }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Sample rows").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted)
                Text(sampleCount).font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1)
                Spacer(minLength: 0)
                if hasKeys, focus == nil {
                    Text("Click a key to follow it").font(Theme.small).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            if schema.rows.isEmpty {
                Text("No sample rows.").font(Theme.small).foregroundStyle(Theme.faint)
            } else {
                SimDataGrid(ref: ref, schema: schema, rows: Array(schema.rows.indices), join: join, focus: focus, still: still,
                            tap: { state.toggleFocus($0) }, menu: cellMenu)
            }
        }
    }

    private var sampleCount: String {
        let count = schema.rows.count
        guard let total = schema.volume?.rows else { return "\(count)" }
        return "\(count) of \(SimDataText.count(total))"
    }

    private func cellMenu(_ cell: SimCellRef, _ point: CGPoint) {
        model.overlays.showMenu(SimDataMenus.cell(cell, sim: sim, model: model), at: point)
    }

    /// The rows the lit key joins to, a small grid per table, origin first when it lives in another table.
    private func joined(_ join: SimDataJoin) -> some View {
        let origin = index.table(join.origin.table)
        var groups = join.byTable.filter { $0.table != ref }
        if join.origin.table != ref { groups.insert(.init(table: join.origin.table, rows: [join.origin.row], keys: []), at: 0) }
        let total = groups.reduce(0) { $0 + $1.rows.count }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(Theme.ui(10, .semibold)).foregroundStyle(Theme.accent)
                Text("Joined rows").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.text)
                Text(total == 0 ? "none" : "\(total) in \(groups.count) \(groups.count == 1 ? "table" : "tables")")
                    .font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1)
                Spacer(minLength: 0)
                SimButton(title: "Clear", icon: "xmark") { state.clearFocus() }
            }
            HStack(spacing: 5) {
                Text("from").font(Theme.ui(11)).foregroundStyle(Theme.muted)
                SimDataLink(title: "\(join.origin.table.table) \(origin.map { SimDataText.label($0, row: join.origin.row) } ?? "")",
                            mono: true, tint: Theme.accent) { state.openTable(join.origin.table) }
                Spacer(minLength: 0)
            }
            if groups.isEmpty {
                Text("No other sample row joins to it.").font(Theme.small).foregroundStyle(Theme.faint)
            }
            ForEach(groups) { group in
                if let schema = index.table(group.table) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Circle().fill(index.tint(group.table)).frame(width: 6, height: 6)
                            SimDataLink(title: group.table.table, mono: true) { state.openTable(group.table) }
                            Text(String(group.rows.count)).font(Theme.mono(10)).foregroundStyle(Theme.faint)
                            if let omitted = join.omitted[group.table], omitted > 0 {
                                Text("+\(omitted) not shown").font(Theme.mono(10)).foregroundStyle(Theme.faint)
                            }
                            Spacer(minLength: 0)
                        }
                        ForEach(group.keys, id: \.self) { key in
                            Text(key.title).font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SimDataGrid(ref: group.table, schema: schema, rows: group.rows, join: join, focus: focus, dimsOthers: false,
                                    still: still, tap: { state.toggleFocus($0) }, menu: cellMenu)
                    }
                }
            }
        }
        .padding(10)
        .background(Theme.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(0.22)))
    }

    // MARK: Entities and ops

    /// Entities on the level built from this table.
    @ViewBuilder
    private var entities: some View {
        let users = sim.level.nodes.flatMap { node in
            node.entities.filter { entity in
                index.source(of: entity, on: node) == ref.node && ([entity.root] + entity.includes).contains(ref.table)
            }.map { (node, $0) }
        }
        if !users.isEmpty {
            SimSection(title: "In entities") {
                SimOpsChips {
                    ForEach(Array(users.enumerated()), id: \.offset) { _, pair in
                        let (node, entity) = pair
                        SimDataChipButton(title: "\(node.label) · \(entity.name)", symbol: "cube", tint: Theme.muted) {
                            SimDataNav.open(entity: entity.name, on: node.id, sim: sim, model: model, select: select)
                        }
                    }
                }
            }
        }
    }

    /// The ops that name this table, one line each (the Operations section below has their live numbers).
    @ViewBuilder
    private var usage: some View {
        let ops = SimOpsState.of(sim)
        let entries = index.usage(of: ref, ops: ops.index)
        if !entries.isEmpty {
            SimSection(title: "Read and written by") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.ref) { offset, entry in
                        if offset > 0 { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 33) }
                        SimDataOpLine(sim: sim, entry: entry, still: still,
                                      open: { SimOpsMenus.open(entry.ref, sim: sim, model: model, anchor: selection) },
                                      menu: { point in
                                          model.overlays.showMenu(SimOpsMenus.row(entry, sim: sim, model: model, anchor: selection), at: point)
                                      })
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .card(radius: 8)
            }
        }
    }
}

// MARK: - Small parts

extension View {
    /// A scroll target a little above this view, so landing on it leaves some headroom.
    func simDataAnchor(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 12).id(id)
            self
        }
        .padding(.top, -12)
    }
}

/// `[W] orders-svc · INSERT order + outbox`: an op that names a table. Opens the op's detail; hovering
/// lights its path on the stage like any op row.
@MainActor
private struct SimDataOpLine: View {
    let sim: Simulation
    let entry: SimOpsIndex.Entry
    let still: Bool
    let open: () -> Void
    let menu: (CGPoint) -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Group {
                    if let access = SimOpsText.access(entry.op) { SimOpAccessBadge(access: access) }
                    else { Image(systemName: entry.op.kind.symbol).font(Theme.ui(10)).foregroundStyle(Theme.muted) }
                }
                .frame(width: 16)
                Text(entry.node.label).font(Theme.ui(11, .medium)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
                Text(entry.op.label).font(Theme.ui(12, .medium)).foregroundStyle(hovered ? Theme.text : Theme.text.opacity(0.9))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(Theme.ui(9, .semibold)).foregroundStyle(hovered ? Theme.muted : Theme.faint)
            }
            .padding(.horizontal, 9).frame(minHeight: 28)
            .background(hovered ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            let state = SimOpsState.of(sim)
            if inside { state.hovered = entry.ref } else if state.hovered == entry.ref { state.hovered = nil }
        }
        .onDisappear {
            let state = SimOpsState.of(sim)
            if state.hovered == entry.ref { state.hovered = nil }
        }
        .simOpsMenu(still: still, menu)
        .accessibilityLabel("\(entry.node.label), \(entry.op.label)")
        .accessibilityHint("Opens the operation")
    }
}

/// `12M · +40k/day`.
struct SimDataBadge: View {
    let title: String

    var body: some View {
        Text(title).font(Theme.mono(10, .medium)).foregroundStyle(Theme.text.opacity(0.82)).lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
    }
}

/// A name that goes somewhere: a node, a table, a referenced column.
@MainActor
struct SimDataLink: View {
    let title: String
    var mono = false
    var tint: Color = Theme.text
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title).font(mono ? Theme.mono(10.5, .medium) : Theme.ui(12, .medium))
                .foregroundStyle(hovered ? Theme.accent : tint)
                .underline(hovered, color: Theme.accent.opacity(0.6))
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A chip that opens something: an op's table, an entity's table, an entity.
@MainActor
struct SimDataChipButton: View {
    let title: String
    var symbol: String?
    var mono = false
    var tint: Color = Theme.token(3)
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(Theme.ui(9, .medium)) }
                Text(title).font(mono ? Theme.mono(10.5) : Theme.ui(11, .medium)).lineLimit(1)
                if hovered { Image(systemName: "arrow.up.right").font(Theme.ui(8, .semibold)) }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(hovered ? 0.18 : 0.10), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(hovered ? 0.34 : 0.18)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// An op's table chip: opens the table in its database's Data section when that database describes it,
/// else stays a plain chip.
@MainActor
struct SimDataTableChip: View {
    let model: AppModel
    let sim: Simulation
    /// The node the op talks to.
    let node: String?
    let table: String
    let select: (StageSelection?) -> Void

    var body: some View {
        if let ref = SimDataState.of(sim).index.table(named: table, on: node) {
            SimDataChipButton(title: table, symbol: "tablecells", mono: true) {
                SimDataNav.open(ref, sim: sim, model: model, select: select)
            }
            .accessibilityHint("Opens the table")
        } else {
            SimOpsChip(title: table, symbol: "tablecells", mono: true)
        }
    }
}
