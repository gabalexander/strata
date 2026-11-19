import SwiftUI
import StrataCore

// The journey's entity panel: the entity's row and its related rows as they are after the step on
// screen, then the other rows the journey has touched so far. A cell the step changed is lit with its
// old value struck through above; status codes show their enum names. Each card lists the key, the
// status columns and the columns the journey changes, with the rest one click away.

@MainActor
struct SimJourneyRows: View {
    let model: AppModel
    let sim: Simulation
    let player: SimJourneyPlayer
    let width: CGFloat
    var still = false

    var body: some View {
        let playback = player.playback
        let shown = player.shown
        let rows = playback.rows(after: shown)
        let frame = player.frame
        let followed = [playback.entity].compactMap { $0 } + playback.related
        // Other rows appear once a step has touched them (or a step before the start, for sample rows).
        let touched = Set(playback.frames.prefix(max(0, shown + 1)).flatMap { $0.diffs.map(\.row) })
        let others = rows.map(\.id).filter { !followed.contains($0) && touched.contains($0) }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(shown < 0 ? "Rows at the start" : "Rows after step \(shown + 1)")
                    .font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.22)).frame(width: 10, height: 10)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.accent.opacity(0.5)))
                    Text("changed here").font(Theme.ui(10.5)).foregroundStyle(Theme.faint)
                }
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            Rectangle().fill(Theme.border).frame(height: 1)
            SimPanelScroll(still: still) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(followed, id: \.self) { id in
                        if let row = rows.first(where: { $0.id == id }) { card(row, frame: frame, entity: id == playback.entity) }
                    }
                    if !others.isEmpty {
                        Text("Also touched").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted).padding(.top, 4)
                        ForEach(others, id: \.self) { id in
                            if let row = rows.first(where: { $0.id == id }) { card(row, frame: frame, entity: false) }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.surface)
    }

    private func card(_ row: JourneyRow, frame: JourneyFrame?, entity: Bool) -> some View {
        // While a step changes other rows, an unchanged one folds to its key and status, so the change is in view.
        let folded = !(frame?.diffs.isEmpty ?? true) && frame?.diff(row.id) == nil && !player.expanded.contains(row.id)
        return SimJourneyRowCard(row: row, diff: frame?.diff(row.id), playback: player.playback, manifest: sim.manifest,
                          shown: player.shown, entity: entity, width: width - 20, expanded: player.expanded.contains(row.id), folded: folded) {
            if player.expanded.contains(row.id) { player.expanded.remove(row.id) } else { player.expanded.insert(row.id) }
        }
    }

    // MARK: Shared helpers

    /// Column → enum id for a row's table.
    static func enumColumns(_ id: JourneyRowID, in manifest: Manifest) -> [String: String] {
        guard let schema = manifest.journeyTables("\(id.node).\(id.table)").first?.schema else { return [:] }
        return Dictionary(schema.columns.compactMap { column in column.enumRef.map { (column.name, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// A value as the panel shows it: NULL, or an enum code with its name.
    static func display(_ value: String?, enum id: String?, _ manifest: Manifest) -> String {
        guard let value else { return "NULL" }
        if let id, let def = manifest.enumDef(id), def.value(value) != nil { return def.title(of: value) }
        return value
    }
}

@MainActor
private struct SimJourneyRowCard: View {
    let row: JourneyRow
    let diff: JourneyRowDiff?
    let playback: JourneyPlayback
    let manifest: Manifest
    let shown: Int
    let entity: Bool
    let width: CGFloat
    let expanded: Bool
    var folded = false
    let toggle: () -> Void

    var body: some View {
        let schema = manifest.journeyTables("\(row.id.node).\(row.id.table)").first?.schema
        let enums = SimJourneyRows.enumColumns(row.id, in: manifest)
        let changed = Set(diff?.cells.map(\.column) ?? [])
        let columns = folded ? row.columns.filter { enums[$0] != nil } : visibleColumns(schema: schema, enums: enums, changed: changed)
        let hidden = folded ? 0 : row.columns.count - columns.count
        VStack(alignment: .leading, spacing: 7) {
            header
            if row.exists || diff?.kind == .delete {
                let nameWidth = min(136, max(70, width * 0.3))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(columns, id: \.self) { column in
                        cell(column, enumID: enums[column], key: isKey(column, schema), changed: changed.contains(column), nameWidth: nameWidth)
                    }
                }
                if !folded, hidden > 0 || expanded {
                    Button(action: toggle) {
                        HStack(spacing: 4) {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(Theme.ui(8, .semibold))
                            Text(expanded ? "Fewer columns" : "\(hidden) more column\(hidden == 1 ? "" : "s")").font(Theme.ui(10.5, .medium))
                        }
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6).frame(height: 18)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text(absence).font(Theme.ui(11)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(row.exists ? Theme.raised.opacity(entity ? 0.9 : 0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(diff != nil ? Theme.accent.opacity(0.32) : Theme.border,
                                                                style: StrokeStyle(lineWidth: 1, dash: row.exists || diff?.kind == .delete ? [] : [4, 3])))
        .opacity(row.exists || diff != nil ? 1 : 0.75)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let role = playback.role(row.id) {
                Text(role).font(Theme.ui(11, .semibold)).foregroundStyle(entity ? Theme.accent : Theme.muted).lineLimit(1).fixedSize()
            }
            Text(playback.title(row.id)).font(Theme.mono(11, .medium)).foregroundStyle(Theme.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            if let diff { SimJourneyKindTag(kind: diff.kind) }
        }
    }

    /// Why a row isn't there: not inserted yet, or deleted earlier.
    private var absence: String {
        if let insert = playback.insertion(of: row.id), insert > shown { return "Not inserted yet: step \(insert + 1) inserts it." }
        if row.sample != nil { return "Deleted." }
        return "Not in the table at this step."
    }

    private func isKey(_ column: String, _ schema: TableSchema?) -> Bool {
        schema?.primaryKey.contains { $0.name == column } ?? (column == row.columns.first)
    }

    /// The key, the enum columns, and the columns any step of the journey changes; all when expanded.
    private func visibleColumns(schema: TableSchema?, enums: [String: String], changed: Set<String>) -> [String] {
        if expanded { return row.columns }
        let journeyChanges = Set(playback.frames.flatMap { frame in frame.diffs.filter { $0.row == row.id && $0.kind == .update }.flatMap { $0.cells.map(\.column) } })
        let wanted = row.columns.filter { column in
            isKey(column, schema) || enums[column] != nil || journeyChanges.contains(column) || changed.contains(column)
        }
        return wanted.isEmpty ? Array(row.columns.prefix(4)) : wanted
    }

    private func cell(_ column: String, enumID: String?, key: Bool, changed: Bool, nameWidth: CGFloat) -> some View {
        let value = row.value(column)
        let before = diff?.cells.first { $0.column == column }?.before
        let deleted = diff?.kind == .delete
        let showBefore = changed && diff?.kind == .update
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(column).font(Theme.mono(10.5, key ? .semibold : .regular)).foregroundStyle(key ? Theme.muted : Theme.faint)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: nameWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                if showBefore {
                    Text(SimJourneyRows.display(before, enum: enumID, manifest)).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                        .strikethrough(color: Theme.faint).lineLimit(2)
                }
                valueText(deleted ? (diff?.cells.first { $0.column == column }?.before) : value, enumID: enumID, changed: changed && !deleted)
                    .strikethrough(deleted, color: Theme.bad.opacity(0.7))
                    .lineLimit(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 5).padding(.vertical, changed ? 3 : 1.5)
        .background(changed && !deleted ? Theme.accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(changed && !deleted ? Theme.accent.opacity(0.28) : .clear))
        .strataSelectable("Copy value") { value ?? "NULL" }
    }

    private func valueText(_ value: String?, enumID: String?, changed: Bool) -> Text {
        guard let value else { return Text("NULL").font(Theme.mono(11)).foregroundColor(Theme.faint) }
        if let enumID, let def = manifest.enumDef(enumID), let entry = def.value(value) {
            let code = Text(value).font(Theme.mono(11, .semibold)).foregroundColor(changed ? Theme.accent : Theme.text)
            guard entry.name != value else { return code }
            let name = Text("  " + entry.name).font(Theme.ui(11, .medium)).foregroundColor(changed ? Theme.accent.opacity(0.85) : Theme.muted)
            return Text("\(code)\(name)")
        }
        let shown = value.count > 160 ? String(value.prefix(159)) + "…" : value
        return Text(shown).font(Theme.mono(11)).foregroundColor(changed ? Theme.text : Theme.text.opacity(0.85))
    }
}
