import SwiftUI
import StrataCore

/// A database's tables at a glance: a card per table (name, volume, key columns) in two columns,
/// parents above children, with each foreign key drawn from its column to the column it refers to
/// through the gutter between the columns. Clicking a card opens its table below.
@MainActor
struct SimDataDiagram: View {
    let index: SimDataIndex
    let node: String
    let open: SimTableRef?
    let join: SimDataJoin?
    var still = false
    let tap: (SimTableRef) -> Void
    let menu: (SimTableRef, CGPoint) -> Void

    var body: some View {
        let layout = SimDataDiagramLayout(index: index, node: node)
        GeometryReader { proxy in
            let frames = layout.frames(width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in connectors(layout, frames, in: &context) }
                ForEach(layout.cards, id: \.ref) { card in
                    if let frame = frames[card.ref] {
                        SimDataTableCard(card: card, tint: index.tint(card.ref), isOpen: open == card.ref,
                                         joined: join?.count(in: card.ref) ?? 0, still: still,
                                         tap: { tap(card.ref) }, menu: { menu(card.ref, $0) })
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
        }
        .frame(height: layout.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tables and their foreign keys")
    }

    /// Each foreign key runs from its column to the column it refers to: out of the card into its own
    /// lane in the gutter, along it, and into the referenced card with an arrowhead.
    private func connectors(_ layout: SimDataDiagramLayout, _ frames: [SimTableRef: CGRect], in context: inout GraphicsContext) {
        // Quiet lines first, then the open table's, then the lit join's on top.
        let ranked = layout.keys.map { key -> (SimForeignKey, Int) in
            if join?.keys.contains(key) == true { return (key, 2) }
            if let open, key.from == open || key.to == open { return (key, 1) }
            return (key, 0)
        }.sorted { $0.1 < $1.1 }
        for (key, rank) in ranked {
            guard let from = frames[key.from], let to = frames[key.to], let lane = layout.laneX(key, frames: frames) else { continue }
            let color: Color = switch rank {
            case 2: Theme.accent
            case 1: Theme.muted
            default: Color.white.opacity(0.26)
            }
            let toRight = layout.column(of: key.to) == 1
            let start = CGPoint(x: layout.column(of: key.from) == 1 ? from.minX : from.maxX,
                                y: from.minY + layout.anchor(key.from, column: key.fromColumn))
            let end = CGPoint(x: toRight ? to.minX : to.maxX, y: to.minY + layout.anchor(key.to, column: key.toColumn))
            var path = Path()
            path.move(to: start)
            if abs(start.y - end.y) < 0.5 {
                path.addLine(to: end)
            } else {
                let bend1 = CGPoint(x: lane, y: start.y), bend2 = CGPoint(x: lane, y: end.y)
                let radius = min(5, abs(end.y - start.y) / 2, max(0.5, abs(lane - start.x)), max(0.5, abs(end.x - lane)))
                path.addArc(tangent1End: bend1, tangent2End: bend2, radius: radius)
                path.addArc(tangent1End: bend2, tangent2End: end, radius: radius)
                path.addLine(to: end)
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: rank == 2 ? 1.5 : 1.1, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: start.x - 2, y: start.y - 2, width: 4, height: 4)), with: .color(color))
            // Arrowhead into the referenced column.
            let inward: CGFloat = toRight ? 1 : -1
            var head = Path()
            head.move(to: end)
            head.addLine(to: CGPoint(x: end.x - inward * 5, y: end.y - 3))
            head.addLine(to: CGPoint(x: end.x - inward * 5, y: end.y + 3))
            head.closeSubpath()
            context.fill(head, with: .color(color))
        }
    }
}

/// Where each card goes. Heights depend only on the cards' content, so the diagram's height is known
/// before its width and the connectors can be drawn from the same numbers the cards are laid out by.
struct SimDataDiagramLayout {
    struct KeyRow: Hashable {
        let column: String
        let pk: Bool
        let fk: Bool
    }

    struct Card {
        let ref: SimTableRef
        let volume: String?
        let rows: [KeyRow]
        let more: Int
        var height: CGFloat {
            SimDataDiagramLayout.top + SimDataDiagramLayout.nameHeight + (volume == nil ? 0 : SimDataDiagramLayout.volumeHeight)
                + (rows.isEmpty ? 0 : SimDataDiagramLayout.gap) + CGFloat(rows.count + (more > 0 ? 1 : 0)) * SimDataDiagramLayout.rowHeight
                + SimDataDiagramLayout.bottom
        }
    }

    static let rowGap: CGFloat = 12
    static let top: CGFloat = 7
    static let nameHeight: CGFloat = 16
    static let volumeHeight: CGFloat = 13
    static let gap: CGFloat = 5
    static let rowHeight: CGFloat = 15
    static let bottom: CGFloat = 7
    static let maxRows = 5

    /// In grid order: row by row, two to a row.
    let cards: [Card]
    let height: CGFloat
    /// The foreign keys between the cards, each with its own lane in the gutter.
    let keys: [SimForeignKey]
    /// Wide enough for every lane.
    let gutter: CGFloat
    private let positions: [SimTableRef: Int]
    private let rowHeights: [CGFloat]
    private let lanes: [SimForeignKey: Int]

    init(index: SimDataIndex, node: String) {
        let refs = index.tables(of: node)
        let local = index.keys.filter { $0.from.node == node && $0.to.node == node }
        // Parents above children: a table's rank is one more than its deepest parent's.
        var ranks: [SimTableRef: Int] = [:]
        func rank(_ ref: SimTableRef, _ depth: Int) -> Int {
            if let known = ranks[ref] { return known }
            guard depth < refs.count else { return 0 }
            let parents = local.filter { $0.from == ref && $0.to != ref }.map(\.to)
            let value = parents.map { rank($0, depth + 1) + 1 }.max() ?? 0
            ranks[ref] = value
            return value
        }
        let ordered = refs.enumerated().sorted { a, b in
            let (x, y) = (rank(a.element, 0), rank(b.element, 0))
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
        let targets = Set(local.map { "\($0.to.table).\($0.toColumn)" })
        let cards = ordered.map { ref in
            let schema = index.table(ref)
            let keyed = (schema?.columns ?? []).filter { column in
                column.pk || index.key(ref, column: column.name) != nil || targets.contains("\(ref.table).\(column.name)")
            }
            let rows = keyed.prefix(Self.maxRows).map { column in
                KeyRow(column: column.name, pk: column.pk, fk: column.ref != nil)
            }
            return Card(ref: ref, volume: SimDataText.volume(schema?.volume), rows: Array(rows), more: max(0, keyed.count - rows.count))
        }
        let rowHeights = stride(from: 0, to: cards.count, by: 2).map { i in
            cards[i..<min(i + 2, cards.count)].map(\.height).max() ?? 0
        }
        self.cards = cards
        self.rowHeights = rowHeights
        let positions = Dictionary(uniqueKeysWithValues: cards.enumerated().map { ($0.element.ref, $0.offset) })
        self.positions = positions
        height = rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1)) * Self.rowGap

        // Lanes, left to right: keys within the left column (shortest nearest it), keys across, then keys
        // within the right column (shortest nearest it), so lines on one side rarely cross the other's.
        let keys = local.filter { positions[$0.from] != nil && positions[$0.to] != nil }
        var tops: [CGFloat] = []
        var top: CGFloat = 0
        for rowHeight in rowHeights { tops.append(top); top += rowHeight + Self.rowGap }
        func y(_ ref: SimTableRef, _ column: String) -> CGFloat {
            let position = positions[ref] ?? 0
            return tops[position / 2] + Self.anchor(in: cards[position], column: column)
        }
        func span(_ key: SimForeignKey) -> CGFloat { abs(y(key.from, key.fromColumn) - y(key.to, key.toColumn)) }
        func side(_ key: SimForeignKey) -> Int {
            let (a, b) = ((positions[key.from] ?? 0) % 2, (positions[key.to] ?? 0) % 2)
            return a == b ? (a == 0 ? 0 : 2) : 1
        }
        let order = keys.filter { side($0) == 0 }.sorted { span($0) < span($1) }
            + keys.filter { side($0) == 1 }.sorted { span($0) < span($1) }
            + keys.filter { side($0) == 2 }.sorted { span($0) > span($1) }
        self.keys = order
        lanes = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        gutter = min(48, max(28, 12 + 5 * CGFloat(order.count)))
    }

    /// The x of a key's lane, between the columns.
    func laneX(_ key: SimForeignKey, frames: [SimTableRef: CGRect]) -> CGFloat? {
        guard let lane = lanes[key], let left = frames.values.filter({ $0.minX == 0 }).first else { return nil }
        return left.maxX + CGFloat(lane + 1) * gutter / CGFloat(lanes.count + 1)
    }

    func column(of ref: SimTableRef) -> Int { (positions[ref] ?? 0) % 2 }

    func frames(width: CGFloat) -> [SimTableRef: CGRect] {
        let cardWidth = max(60, (width - gutter) / 2)
        var frames: [SimTableRef: CGRect] = [:]
        var y: CGFloat = 0
        for (row, rowHeight) in rowHeights.enumerated() {
            for col in 0..<2 {
                let i = row * 2 + col
                guard i < cards.count else { continue }
                frames[cards[i].ref] = CGRect(x: col == 0 ? 0 : cardWidth + gutter, y: y, width: cardWidth, height: cards[i].height)
            }
            y += rowHeight + Self.rowGap
        }
        return frames
    }

    /// The y of a column's key row within its card, or the name line's when the column isn't listed.
    func anchor(_ ref: SimTableRef, column: String) -> CGFloat {
        guard let position = positions[ref] else { return Self.top + Self.nameHeight / 2 }
        return Self.anchor(in: cards[position], column: column)
    }

    private static func anchor(in card: Card, column: String) -> CGFloat {
        guard let row = card.rows.firstIndex(where: { $0.column == column }) else { return Self.top + Self.nameHeight / 2 }
        return Self.top + Self.nameHeight + (card.volume == nil ? 0 : Self.volumeHeight) + Self.gap
            + CGFloat(row) * Self.rowHeight + Self.rowHeight / 2
    }
}

/// One table in the diagram.
@MainActor
private struct SimDataTableCard: View {
    let card: SimDataDiagramLayout.Card
    let tint: Color
    let isOpen: Bool
    /// Rows of this table in the lit join.
    let joined: Int
    let still: Bool
    let tap: () -> Void
    let menu: (CGPoint) -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(card.ref.table).font(Theme.mono(11, .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .frame(height: SimDataDiagramLayout.nameHeight)
                if let volume = card.volume {
                    Text(volume).font(Theme.mono(9.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        .frame(height: SimDataDiagramLayout.volumeHeight)
                }
                if !card.rows.isEmpty { Color.clear.frame(height: SimDataDiagramLayout.gap) }
                ForEach(card.rows, id: \.self) { row in
                    HStack(spacing: 4) {
                        HStack(spacing: 1) {
                            if row.pk { Image(systemName: "key.fill").font(Theme.ui(7.5, .semibold)).foregroundStyle(Theme.text.opacity(0.75)) }
                            if row.fk { Image(systemName: "arrow.up.right").font(Theme.ui(7.5, .bold)).foregroundStyle(Theme.token(3)) }
                            if !row.pk && !row.fk { Circle().fill(Theme.faint).frame(width: 3, height: 3) }
                        }
                        .frame(width: 18, alignment: .leading)
                        Text(row.column).font(Theme.mono(10)).foregroundStyle(row.pk ? Theme.text.opacity(0.9) : Theme.muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(height: SimDataDiagramLayout.rowHeight)
                }
                if card.more > 0 {
                    Text("+\(card.more) keys").font(Theme.mono(9.5)).foregroundStyle(Theme.faint)
                        .frame(height: SimDataDiagramLayout.rowHeight)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, SimDataDiagramLayout.top)
            .padding(.bottom, SimDataDiagramLayout.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isOpen ? Theme.accent.opacity(0.07) : hovered ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isOpen ? Theme.accent : joined > 0 ? Theme.accent.opacity(0.5) : hovered ? Theme.borderStrong : Theme.border,
                              lineWidth: isOpen ? 1.5 : 1))
            // Rows of this table in the lit join, as a badge on the corner so the name keeps its room.
            .overlay(alignment: .topTrailing) {
                if joined > 0 {
                    Text(String(joined)).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.bg)
                        .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                        .background(Theme.accent, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.surface, lineWidth: 1.5))
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("\(joined) joined rows")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .simOpsMenu(still: still, menu)
        .accessibilityLabel("\(card.ref.table) table\(card.volume.map { ", \($0) rows" } ?? "")")
        .accessibilityHint(isOpen ? "Closes the table" : "Opens the table below")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}
