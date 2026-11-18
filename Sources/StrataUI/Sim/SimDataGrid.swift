import SwiftUI
import StrataCore

/// Sample rows as a real grid: aligned mono cells with hairlines, numbers right-aligned, NULL in faint
/// italics, scrolling sideways when the table is wider than the panel. Cells in pk and fk columns are
/// buttons that light the rows their row joins to. With a join lit, its rows take the accent: the
/// origin row strongly, joined rows softly, and the key cells that make each join in accent text.
@MainActor
struct SimDataGrid: View {
    let ref: SimTableRef
    let schema: TableSchema
    /// Row indices to show, in order.
    let rows: [Int]
    var join: SimDataJoin?
    var focus: SimCellRef?
    /// Dim rows outside a lit join (the table's own grid). Joined-row strips show only joined rows.
    var dimsOthers = true
    var still = false
    let tap: (SimCellRef) -> Void
    let menu: (SimCellRef, CGPoint) -> Void

    static let rowHeight: CGFloat = 22
    private static let maxCharacters = 30

    @State private var hovered: SimCellRef?
    @State private var moreRight = false

    var body: some View {
        Group {
            if still {
                // Offscreen stills can't draw a scroll view: clip, and fade the edge when columns run past it.
                GeometryReader { proxy in
                    grid.fixedSize()
                        .frame(width: proxy.size.width, alignment: .leading)
                        .clipped()
                        .overlay(alignment: .trailing) { if estimatedWidth > proxy.size.width + 1 { fade } }
                }
                .frame(height: height)
            } else {
                // No scroller: it would reserve a band under the rows. The trailing fade says there's more.
                ScrollView(.horizontal) { grid.fixedSize() }
                    .scrollIndicators(.never)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentSize.width - geometry.contentOffset.x - geometry.containerSize.width > 1
                    } action: { _, more in moreRight = more }
                    .overlay(alignment: .trailing) { if moreRight { fade } }
            }
        }
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).strokeBorder(Theme.border))
    }

    private var height: CGFloat { Self.rowHeight + CGFloat(rows.count) * (Self.rowHeight + 1) }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(schema.columns.enumerated()), id: \.offset) { offset, column in
                    header(column, last: offset == schema.columns.count - 1)
                }
            }
            ForEach(rows, id: \.self) { row in
                Rectangle().fill(Theme.border).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(schema.columns.enumerated()), id: \.offset) { offset, column in
                        cell(row, column, last: offset == schema.columns.count - 1)
                    }
                }
            }
        }
    }

    private func header(_ column: Column, last: Bool) -> some View {
        HStack(spacing: 3) {
            if column.pk { Image(systemName: "key.fill").font(Theme.ui(7.5, .semibold)).foregroundStyle(Theme.text.opacity(0.8)) }
            if column.ref != nil { Image(systemName: "arrow.up.right").font(Theme.ui(7.5, .bold)).foregroundStyle(Theme.token(3)) }
            Text(column.name).font(Theme.mono(10, .semibold)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: SimDataText.isNumeric(column) ? .trailing : .leading)
        .background(Theme.raised)
        .overlay(alignment: .trailing) { if !last { Rectangle().fill(Theme.border).frame(width: 1) } }
    }

    @ViewBuilder
    private func cell(_ row: Int, _ column: Column, last: Bool) -> some View {
        let cell = SimCellRef(row: SimRowRef(table: ref, row: row), column: column.name)
        let value = schema.simDataValue(row, column.name)
        let isKey = column.pk || column.ref != nil
        let origin = join?.origin == cell.row
        let joined = join?.rows.contains(cell.row) ?? false
        let lit = join?.cells.contains(cell) ?? false
        let focused = focus == cell
        let dimmed = dimsOthers && join != nil && !joined
        let tint: Color = focused || lit ? Theme.accent : dimmed ? Theme.muted.opacity(0.7) : Theme.text
        let content = HStack(spacing: 0) {
            if let value {
                Text(display(value))
                    .font(Theme.mono(11, focused ? .semibold : .regular))
                    .foregroundStyle(tint)
                    .underline(isKey && hovered == cell, color: tint.opacity(0.6))
            } else {
                Text("NULL").font(Theme.mono(10.5).italic()).foregroundStyle(Theme.faint.opacity(dimmed ? 0.7 : 1))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: SimDataText.isNumeric(column) ? .trailing : .leading)
        .background(origin ? Theme.accent.opacity(0.15) : joined ? Theme.accent.opacity(0.07) : hovered == cell && isKey ? Theme.hover : .clear)
        .overlay(alignment: .trailing) { if !last { Rectangle().fill(Theme.border).frame(width: 1) } }
        .overlay(alignment: .leading) {
            if origin && column.name == schema.columns.first?.name { Rectangle().fill(Theme.accent).frame(width: 2) }
        }
        .contentShape(Rectangle())
        Group {
            if isKey && value != nil {
                Button { tap(cell) } label: { content }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? cell : (hovered == cell ? nil : hovered) }
                    .accessibilityLabel("\(column.name) \(value ?? "NULL")")
                    .accessibilityHint(focused ? "Clears the joined rows" : "Shows the rows this row joins to")
            } else {
                content.accessibilityLabel("\(column.name) \(value ?? "NULL")")
            }
        }
        .simOpsMenu(still: still) { menu(cell, $0) }
    }

    private func display(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        return flat.count > Self.maxCharacters ? String(flat.prefix(Self.maxCharacters - 1)) + "…" : flat
    }

    private var fade: some View {
        LinearGradient(colors: [Theme.bg.opacity(0), Theme.bg.opacity(0.92)], startPoint: .leading, endPoint: .trailing)
            .frame(width: 26)
            .allowsHitTesting(false)
    }

    /// The grid's width from SF Mono's advance (0.6 em), for stills that can't measure a scroll view.
    private var estimatedWidth: CGFloat {
        schema.columns.reduce(0) { total, column in
            let glyphs = CGFloat((column.pk ? 1 : 0) + (column.ref != nil ? 1 : 0)) * 11
            let header = CGFloat(column.name.count) * 6.0 + glyphs
            let values = rows.map { row in
                schema.simDataValue(row, column.name).map { CGFloat(display($0).count) * 6.6 } ?? 4 * 6.3
            }.max() ?? 0
            return total + max(header, values) + 17
        }
    }
}
