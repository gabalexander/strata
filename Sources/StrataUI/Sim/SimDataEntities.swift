import SwiftUI
import StrataCore

/// A service's Entities section: the domain objects it assembles from tables. Each shows its tables as
/// chips; expanded, it shows the object built from one sample row of its root table, each field
/// tinted by the table it comes from.
@MainActor
struct SimEntitiesSection: View {
    let model: AppModel
    let sim: Simulation
    let terms: TermIndex
    let node: Node
    let select: (StageSelection?) -> Void
    var still = false

    var body: some View {
        if !node.entities.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("Entities").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted)
                    Text(String(node.entities.count)).font(Theme.mono(10)).foregroundStyle(Theme.faint)
                    Spacer(minLength: 0)
                }
                ForEach(node.entities) { entity in
                    SimEntityCard(model: model, sim: sim, terms: terms, node: node, entity: entity, select: select, still: still)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
private struct SimEntityCard: View {
    let model: AppModel
    let sim: Simulation
    let terms: TermIndex
    let node: Node
    let entity: Entity
    let select: (StageSelection?) -> Void
    let still: Bool
    /// The tree line under the pointer: its table and column show in the footer.
    @State private var hovered: String?
    @State private var headerHovered = false

    init(model: AppModel, sim: Simulation, terms: TermIndex, node: Node, entity: Entity,
         select: @escaping (StageSelection?) -> Void, still: Bool) {
        self.model = model; self.sim = sim; self.terms = terms; self.node = node; self.entity = entity
        self.select = select; self.still = still
        _hovered = State(initialValue: SimDataState.of(sim).previewHover[SimDataState.entityKey(node: node.id, entity: entity.name)])
    }

    private var state: SimDataState { SimDataState.of(sim) }
    private var index: SimDataIndex { state.index }
    private var key: String { SimDataState.entityKey(node: node.id, entity: entity.name) }

    var body: some View {
        let source = index.source(of: entity, on: node)
        let expanded = state.isExpanded(key)
        VStack(alignment: .leading, spacing: 9) {
            header(source: source, expanded: expanded)
            SimBriefText(brief: nil, detail: entity.doc, key: SimBriefKey.item(sim, "entity:" + key), model: model, terms: terms, size: 12)
            SimOpsChips {
                ForEach([entity.root] + entity.includes, id: \.self) { table in
                    if let source, let ref = index.table(named: table, on: source) {
                        SimDataChipButton(title: table, mono: true, tint: index.tint(ref)) {
                            SimDataNav.open(ref, sim: sim, model: model, select: select)
                        }
                        .accessibilityHint("Opens the table")
                    } else {
                        SimOpsChip(title: "\(table) · not found", mono: true, tint: Theme.bad)
                    }
                }
            }
            ForEach(entity.code, id: \.self) { path in
                SimButton(title: path, icon: "chevron.left.forwardslash.chevron.right") { model.openCode(path, repo: sim.manifest.repo) }
            }
            if expanded {
                Rectangle().fill(Theme.border).frame(height: 1).padding(.horizontal, -10)
                assembled(source: source)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 8)
        .simDataAnchor(SimDataState.entityAnchor(key))
    }

    private func header(source: String?, expanded: Bool) -> some View {
        let root = source.flatMap { index.table(named: entity.root, on: $0) }
        let tint = root.map(index.tint) ?? Theme.muted
        let tables = 1 + entity.includes.count
        let sourceLabel = source.flatMap { sim.level.node($0)?.label }
        return Button { state.toggleEntity(key) } label: {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "cube")
                    .font(Theme.ui(12, .semibold)).foregroundStyle(tint).frame(width: 28, height: 28)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                VStack(alignment: .leading, spacing: 3) {
                    Text(entity.name).font(Theme.ui(13, .semibold)).foregroundStyle(Theme.text)
                    Text(["\(tables) \(tables == 1 ? "table" : "tables")", sourceLabel].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(expanded ? "Hide object" : "Show object").font(Theme.ui(11, .medium))
                    .foregroundStyle(headerHovered ? Theme.text : Theme.muted)
                Image(systemName: "chevron.right").font(Theme.ui(9, .semibold))
                    .foregroundStyle(headerHovered ? Theme.text : Theme.muted)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { headerHovered = $0 }
        .accessibilityLabel("\(entity.name) entity")
        .accessibilityHint(expanded ? "Hides the assembled object" : "Shows the object assembled from a sample row")
    }

    // MARK: Assembled object

    @ViewBuilder
    private func assembled(source: String?) -> some View {
        let rootRef = source.flatMap { index.table(named: entity.root, on: $0) }
        if let rootRef, let rootSchema = index.table(rootRef), !rootSchema.rows.isEmpty {
            let row = min(state.root(key), rootSchema.rows.count - 1)
            VStack(alignment: .leading, spacing: 9) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Root row · \(entity.root)").font(Theme.label).foregroundStyle(Theme.faint)
                    SimOpsChips {
                        ForEach(rootSchema.rows.indices, id: \.self) { candidate in
                            SimDataRootChip(title: SimDataText.label(rootSchema, row: candidate), selected: candidate == row) {
                                state.setRoot(key, row: candidate)
                                hovered = nil
                            }
                        }
                    }
                }
                if let object = index.assemble(entity, on: node, root: row) {
                    let lines = SimDataTree.lines(object, index: index, enums: SimEnumIndex.of(sim))
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            SimDataTreeRow(line: line, hovered: hovered == line.id) { inside in
                                if inside { hovered = line.id } else if hovered == line.id { hovered = nil }
                            } open: {
                                guard let cell = line.cell else { return }
                                SimDataNav.open(cell.table, focus: cell, sim: sim, model: model, select: select)
                            }
                        }
                    }
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.border))
                    legend(SimDataTree.tables(object))
                    footer(lines.first { $0.id == hovered })
                }
            }
        } else {
            Text(rootRef == nil ? "\(entity.root) isn't a table of the source database." : "\(entity.root) has no sample rows to assemble from.")
                .font(Theme.small).foregroundStyle(Theme.faint)
        }
    }

    private func legend(_ tables: [SimTableRef]) -> some View {
        SimOpsChips {
            ForEach(tables) { table in
                HStack(spacing: 5) {
                    Circle().fill(index.tint(table)).frame(width: 6, height: 6)
                    Text(table.table).font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .padding(.trailing, 4)
            }
        }
    }

    private func footer(_ line: SimDataTreeLine?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: line == nil ? "cursorarrow.rays" : "tablecells").font(Theme.ui(9.5, .medium))
                .foregroundStyle(line.map { $0.tint } ?? Theme.faint)
            VStack(alignment: .leading, spacing: 2) {
                if let line, let info = line.info {
                    Text(info.source).font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = info.detail {
                        Text(detail).font(Theme.ui(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    if let cell = line.cell {
                        Text("Click to open this row of \(cell.table.table)").font(Theme.ui(11)).foregroundStyle(Theme.faint)
                    }
                } else {
                    Text("Hover a field to see its table and column; click it to open the row.")
                        .font(Theme.ui(11)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 30, alignment: .topLeading)
    }
}

/// A root row to assemble the entity from.
@MainActor
private struct SimDataRootChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.mono(10.5, selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : hovered ? Theme.text : Theme.muted)
                .lineLimit(1)
                .padding(.horizontal, 7).frame(height: 21)
                .background(selected ? Theme.accent.opacity(0.13) : hovered ? Theme.hover : Theme.raised,
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Theme.accent.opacity(0.3) : Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Tree

/// One line of an assembled object: `user: User {`, `status: "paid"`, `},`.
struct SimDataTreeLine: Identifiable {
    struct Info {
        /// `orders.total_cents · bigint`, `users via orders.user_id → users.id`.
        let source: String
        /// The column's note, or what the relation holds.
        let detail: String?
    }

    let id: String
    let depth: Int
    var key: String?
    var type: String?
    var value: String?
    var isNull = false
    /// The name of an enum value (`paid` for `20`), shown faint after it.
    var enumName: String?
    var punctuation = ""
    /// The source table's colour.
    let tint: Color
    /// Where a click goes: the field's cell, or an object's row.
    var cell: SimCellRef?
    var info: Info?
}

enum SimDataTree {
    @MainActor static func lines(_ object: SimDataObject, index: SimDataIndex, enums: SimEnumIndex? = nil) -> [SimDataTreeLine] {
        var lines: [SimDataTreeLine] = []
        func rowInfo(_ row: SimRowRef, via key: SimForeignKey?) -> SimDataTreeLine.Info {
            let label = index.table(row.table).map { SimDataText.label($0, row: row.row) } ?? ""
            return .init(source: "\(row.table.table) row \(label)", detail: key.map { "Joined by \($0.title)" })
        }
        func keyCell(_ row: SimRowRef) -> SimCellRef? {
            index.table(row.table).flatMap(SimDataText.keyColumn).map { SimCellRef(row: row, column: $0) }
        }
        func emit(_ object: SimDataObject, key: String?, via: SimForeignKey?, depth: Int, path: String, comma: Bool) {
            let tint = index.tint(object.row.table)
            let schema = index.table(object.row.table)
            lines.append(.init(id: path, depth: depth, key: key, type: object.type, punctuation: " {", tint: tint,
                               cell: keyCell(object.row), info: rowInfo(object.row, via: via)))
            for field in object.fields {
                let fieldPath = "\(path).\(field.name)"
                let fieldTint = index.tint(field.table)
                switch field.value {
                case .scalar(let value):
                    let column = schema?.column(field.name)
                    let source = ["\(field.table.table).\(field.name)", column?.type].compactMap { $0 }.joined(separator: " · ")
                    let def = enums?.enumOf(field.table, column: field.name)
                    let known = value.flatMap { def?.value($0) }
                    let meaning = known.map { known in
                        "\(def?.label ?? "") · \(def?.title(known) ?? known.name)" + (known.doc.map { ": " + $0 } ?? "")
                    }
                    lines.append(.init(id: fieldPath, depth: depth + 1, key: field.name, value: SimDataText.literal(value, column: column),
                                       isNull: value == nil, enumName: known.flatMap { $0.name == $0.value ? nil : $0.name },
                                       tint: fieldTint, cell: field.cell,
                                       info: .init(source: source, detail: column?.note ?? meaning)))
                case .one(let nested):
                    if let nested {
                        emit(nested, key: field.name, via: field.key, depth: depth + 1, path: fieldPath, comma: false)
                    } else {
                        lines.append(.init(id: fieldPath, depth: depth + 1, key: field.name, value: "null", isNull: true, tint: fieldTint,
                                           info: .init(source: "\(field.table.table): no row", detail: field.key.map { "Nothing joins by \($0.title)" })))
                    }
                case .cut:
                    lines.append(.init(id: fieldPath, depth: depth + 1, key: field.name, value: "…", isNull: true, tint: fieldTint,
                                       info: .init(source: field.table.table, detail: "More rows join here, below the depth the object is assembled to")))
                case .many(let items, let omitted):
                    let detail = field.key.map { "\(items.count + omitted) \(items.count + omitted == 1 ? "row" : "rows") by \($0.title)" }
                    lines.append(.init(id: fieldPath, depth: depth + 1, key: field.name, punctuation: items.isEmpty && omitted == 0 ? "[]" : "[",
                                       tint: fieldTint, info: .init(source: field.table.table, detail: detail)))
                    guard !items.isEmpty || omitted > 0 else { continue }
                    for (offset, item) in items.enumerated() {
                        emit(item, key: nil, via: field.key, depth: depth + 2, path: "\(fieldPath)[\(offset)]",
                             comma: offset < items.count - 1 || omitted > 0)
                    }
                    if omitted > 0 {
                        lines.append(.init(id: "\(fieldPath).more", depth: depth + 2, value: "… \(omitted) more", isNull: true, tint: fieldTint))
                    }
                    lines.append(.init(id: "\(fieldPath).end", depth: depth + 1, punctuation: "]", tint: fieldTint))
                }
            }
            lines.append(.init(id: "\(path).end", depth: depth, punctuation: comma ? "}," : "}", tint: tint))
        }
        emit(object, key: nil, via: nil, depth: 0, path: "root", comma: false)
        return lines
    }

    /// The tables an object draws from, in the order they first appear.
    static func tables(_ object: SimDataObject) -> [SimTableRef] {
        var order: [SimTableRef] = []
        func visit(_ object: SimDataObject) {
            if !order.contains(object.row.table) { order.append(object.row.table) }
            for field in object.fields {
                switch field.value {
                case .scalar, .cut: break
                case .one(let nested): if let nested { visit(nested) }
                case .many(let items, _): items.forEach(visit)
                }
            }
        }
        visit(object)
        return order
    }
}

@MainActor
private struct SimDataTreeRow: View {
    let line: SimDataTreeLine
    let hovered: Bool
    let hover: (Bool) -> Void
    let open: () -> Void

    private static let indent: CGFloat = 14

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(text).font(Theme.mono(11)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10 + CGFloat(line.depth) * Self.indent).padding(.trailing, 8)
            .frame(minHeight: 17)
            // Indent guides, as an editor draws them, through every line of a wrapped value.
            .background(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(0..<line.depth, id: \.self) { _ in
                        Rectangle().fill(Theme.border).frame(width: 1).frame(maxHeight: .infinity).padding(.trailing, Self.indent - 1)
                    }
                }
                .padding(.leading, 10)
            }
            .background(hovered && line.info != nil ? line.tint.opacity(0.10) : .clear)
            .overlay(alignment: .leading) {
                if hovered && line.info != nil { Rectangle().fill(line.tint).frame(width: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(line.cell == nil && line.info == nil)
        .onHover(perform: hover)
        .accessibilityLabel(accessibility)
        .accessibilityHint(line.cell == nil ? "" : "Opens the row in its table")
    }

    private var text: AttributedString {
        var result = AttributedString()
        func run(_ string: String, _ color: Color, bold: Bool = false, italic: Bool = false) {
            var part = AttributedString(string)
            part.foregroundColor = color
            if bold { part.font = Theme.mono(11, .semibold) }
            if italic { part.font = Theme.mono(11).italic() }
            result += part
        }
        if let key = line.key {
            run(key, line.tint)
            run(": ", Theme.faint)
        }
        if let type = line.type { run(type, line.tint, bold: true) }
        if let value = line.value { run(value, line.isNull ? Theme.faint : Theme.text, italic: line.isNull) }
        if let name = line.enumName { run(" · \(name)", Theme.faint) }
        if !line.punctuation.isEmpty { run(line.punctuation, Theme.faint) }
        return result
    }

    private var accessibility: String {
        [line.key, line.type, line.value, line.enumName].compactMap { $0 }.joined(separator: " ")
    }
}
