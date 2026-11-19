import SwiftUI
import StrataCore

// An enum's state machine, left to right in lifecycle order (`EnumDef.lifecycle`): values as rounded
// nodes, terminal ones with a double border, transitions as arrows with a pill naming the transition
// and who performs it. Forward arrows run between columns, a transition that skips a column runs in a
// free lane, and one that goes back (resume, retry) arcs over the nodes.

struct SimEnumDiagramLayout {
    struct Box {
        let code: String
        let name: String
        let rect: CGRect
        let terminal: Bool
    }

    struct Arrow {
        let index: Int               // into `EnumDef.transitions`
        let from: String
        let to: String
        let path: Path
        let tip: CGPoint
        /// Direction of travel at the tip, in radians.
        let angle: Double
        let label: CGPoint
        let back: Bool
    }

    var boxes: [Box] = []
    var arrows: [Arrow] = []
    /// Start markers: a dot and the point its arrow reaches.
    var starts: [(dot: CGPoint, tip: CGPoint)] = []
    var size: CGSize = .zero
    var coded = false

    static let padding: CGFloat = 14

    /// Rough text widths (SF Pro and SF Mono), enough to size the gaps between columns; the pills and
    /// nodes size themselves.
    static func uiWidth(_ text: String, _ size: CGFloat, bold: Bool = false) -> CGFloat {
        CGFloat(text.count) * size * (bold ? 0.6 : 0.55)
    }
    static func monoWidth(_ text: String, _ size: CGFloat) -> CGFloat { CGFloat(text.count) * size * 0.61 }

    static func pillSize(label: String?, by: String?) -> CGSize {
        let width = max(label.map { uiWidth($0, 11) } ?? 0, by.map { monoWidth("by " + $0, 10) } ?? 0) + 16
        let lines = (label == nil ? 0 : 1) + (by == nil ? 0 : 1)
        return CGSize(width: width, height: CGFloat(lines) * 14 + 8)
    }

    init() {}

    init(_ def: EnumDef) {
        let life = def.lifecycle()
        coded = def.values.contains { $0.value != $0.name }
        let nodeHeight: CGFloat = coded ? 40 : 30
        // Two arrows leaving one node for neighbouring rows put their pills half a row apart: leave room.
        let tallest = def.transitions.map { Self.pillSize(label: $0.label, by: $0.by).height }.max() ?? 0
        let rowGap: CGFloat = max(coded ? 40 : 34, tallest * 2 + 8 - nodeHeight)
        let pad = Self.padding
        let values = Dictionary(def.values.map { ($0.value, $0) }, uniquingKeysWith: { first, _ in first })
        func width(_ value: EnumValue) -> CGFloat {
            max(64, max(Self.uiWidth(value.name, 12, bold: true), coded ? Self.monoWidth(value.value, 10) : 0) + 26)
        }
        let layers = max(life.layers, 1)
        var columns = [CGFloat](repeating: 64, count: layers)
        for value in def.values { columns[life.layer[value.value] ?? 0] = max(columns[life.layer[value.value] ?? 0], width(value)) }

        let valid = def.transitions.indices.filter { values[def.transitions[$0].from] != nil && values[def.transitions[$0].to] != nil }
        let forward = valid.filter { !life.back.contains($0) }
        let backward = valid.filter { life.back.contains($0) }

        // Gaps fit the pills of the arrows whose pill sits in them (an arrow that skips columns has its
        // pill in its lane, over the columns it skips).
        var gaps = [CGFloat](repeating: 52, count: max(layers - 1, 0))
        for index in forward {
            let transition = def.transitions[index]
            let from = life.layer[transition.from] ?? 0, to = life.layer[transition.to] ?? 0
            guard to - from == 1, gaps.indices.contains(from) else { continue }
            gaps[from] = max(gaps[from], Self.pillSize(label: transition.label, by: transition.by).width + 56)
        }
        let startCodes = Set(def.values.map(\.value).filter { code in
            !valid.contains { def.transitions[$0].to == code && def.transitions[$0].from != code } &&
                valid.contains { def.transitions[$0].from == code }
        })
        let startMargin: CGFloat = startCodes.isEmpty ? 0 : 28
        var columnX: [CGFloat] = []
        var x = pad + startMargin
        for layer in 0..<layers {
            columnX.append(x)
            x += columns[layer] + (layer < gaps.count ? gaps[layer] : 0)
        }

        // Back arcs go over the nodes when either end is in the first row, under them otherwise.
        let over = backward.filter { min(life.row[def.transitions[$0].from] ?? 0, life.row[def.transitions[$0].to] ?? 0) == 0 }
        let under = backward.filter { !over.contains($0) }
        func rise(_ count: Int) -> CGFloat { 34 + CGFloat(max(count - 1, 0)) * 16 }
        let top: CGFloat = over.isEmpty ? 0 : rise(over.count) * 0.75 + 18
        let maxRow = def.values.compactMap { life.row[$0.value] }.max() ?? 0
        let rowPitch = nodeHeight + rowGap
        func rowY(_ row: Int) -> CGFloat { pad + top + CGFloat(row) * rowPitch }
        let bottom: CGFloat = under.isEmpty ? 0 : rise(under.count) * 0.75 + 18

        var rects: [String: CGRect] = [:]
        for value in def.values {
            let layer = life.layer[value.value] ?? 0
            let w = width(value)
            let rect = CGRect(x: columnX[layer] + (columns[layer] - w) / 2, y: rowY(life.row[value.value] ?? 0), width: w, height: nodeHeight)
            rects[value.value] = rect
            boxes.append(Box(code: value.value, name: value.name, rect: rect, terminal: value.terminal))
        }
        for code in startCodes.sorted() {
            guard let rect = rects[code] else { continue }
            starts.append((CGPoint(x: rect.minX - 24, y: rect.midY), CGPoint(x: rect.minX - 1, y: rect.midY)))
        }

        // Ports: arrows leaving or entering one side of a node spread a little, ordered by the other end.
        func spread(_ indices: [Int], by other: (Int) -> CGFloat) -> [Int: CGFloat] {
            let sorted = indices.sorted { other($0) < other($1) }
            let step: CGFloat = min(8, (nodeHeight - 14) / CGFloat(max(sorted.count - 1, 1)))
            var result: [Int: CGFloat] = [:]
            for (i, index) in sorted.enumerated() { result[index] = (CGFloat(i) - CGFloat(sorted.count - 1) / 2) * step }
            return result
        }
        var outOffset: [Int: CGFloat] = [:], inOffset: [Int: CGFloat] = [:]
        for code in rects.keys {
            let leaving = forward.filter { def.transitions[$0].from == code }
            let entering = forward.filter { def.transitions[$0].to == code }
            outOffset.merge(spread(leaving) { rects[def.transitions[$0].to]?.midY ?? 0 }) { a, _ in a }
            inOffset.merge(spread(entering) { rects[def.transitions[$0].from]?.midY ?? 0 }) { a, _ in a }
        }

        for index in forward {
            let transition = def.transitions[index]
            guard let source = rects[transition.from], let target = rects[transition.to] else { continue }
            let from = life.layer[transition.from] ?? 0, to = life.layer[transition.to] ?? 0
            let start = CGPoint(x: source.maxX, y: source.midY + (outOffset[index] ?? 0))
            let end = CGPoint(x: target.minX - 1, y: target.midY + (inOffset[index] ?? 0))
            var path = Path()
            path.move(to: start)
            var label: CGPoint
            if to - from <= 1 {
                if abs(start.y - end.y) < 0.5 {
                    path.addLine(to: end)
                } else {
                    let dx = (end.x - start.x) * 0.5
                    path.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y), control2: CGPoint(x: end.x - dx, y: end.y))
                }
                label = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            } else {
                // A lane through the skipped columns: the target's row when it is free there, else below them.
                let skipped = (from + 1)..<to
                let busy = def.values.filter { skipped.contains(life.layer[$0.value] ?? 0) }.compactMap { life.row[$0.value] }
                let targetRow = life.row[transition.to] ?? 0
                let lane = busy.contains(targetRow) ? rowY((busy.max() ?? 0) + 1) - rowGap / 2 : end.y
                let laneStart = columnX[from + 1] - 6
                let laneEnd = columnX[to - 1] + columns[to - 1] + 6
                let dx1 = (laneStart - start.x) * 0.5
                path.addCurve(to: CGPoint(x: laneStart, y: lane), control1: CGPoint(x: start.x + dx1, y: start.y),
                              control2: CGPoint(x: laneStart - dx1, y: lane))
                path.addLine(to: CGPoint(x: laneEnd, y: lane))
                if abs(lane - end.y) < 0.5 {
                    path.addLine(to: end)
                } else {
                    let dx2 = (end.x - laneEnd) * 0.5
                    path.addCurve(to: end, control1: CGPoint(x: laneEnd + dx2, y: lane), control2: CGPoint(x: end.x - dx2, y: end.y))
                }
                label = CGPoint(x: (laneStart + laneEnd) / 2, y: lane)
            }
            arrows.append(Arrow(index: index, from: transition.from, to: transition.to, path: path, tip: end, angle: 0,
                                label: label, back: false))
        }

        for (group, above) in [(over, true), (under, false)] {
            for (rank, index) in group.enumerated() {
                let transition = def.transitions[index]
                guard let source = rects[transition.from], let target = rects[transition.to] else { continue }
                let sign: CGFloat = above ? -1 : 1
                let h = rise(rank + 1)
                var path = Path()
                let label: CGPoint
                let tip: CGPoint
                let angle: Double
                if transition.from == transition.to {
                    let edge = above ? source.minY : source.maxY
                    let start = CGPoint(x: source.midX - 9, y: edge)
                    tip = CGPoint(x: source.midX + 9, y: edge + sign * -1)
                    path.move(to: start)
                    path.addCurve(to: tip, control1: CGPoint(x: source.midX - 26, y: edge + sign * 30),
                                  control2: CGPoint(x: source.midX + 26, y: edge + sign * 30))
                    label = CGPoint(x: source.midX, y: edge + sign * 24)
                    angle = above ? .pi * 0.62 : -.pi * 0.62
                } else {
                    let s = CGPoint(x: source.midX - 6, y: above ? source.minY : source.maxY)
                    tip = CGPoint(x: target.midX + 6, y: (above ? target.minY : target.maxY) + sign * 1)
                    let c1 = CGPoint(x: s.x, y: s.y + sign * h), c2 = CGPoint(x: tip.x, y: tip.y + sign * h)
                    path.move(to: s)
                    path.addCurve(to: tip, control1: c1, control2: c2)
                    label = CGPoint(x: (s.x + tip.x) / 2, y: (s.y + tip.y) / 2 + sign * h * 0.75)
                    angle = above ? .pi / 2 : -.pi / 2
                }
                arrows.append(Arrow(index: index, from: transition.from, to: transition.to, path: path, tip: tip, angle: angle,
                                    label: label, back: true))
            }
        }

        let right = (columnX.last ?? pad) + (columns.last ?? 0) + pad
        size = CGSize(width: right, height: rowY(maxRow) + nodeHeight + bottom + pad)
    }
}

/// The diagram: arrows on a canvas, nodes and pills as views on top. Clicking a node highlights its
/// value; clicking `by` jumps to whoever performs the transition.
struct SimEnumDiagram: View {
    let def: EnumDef
    let layout: SimEnumDiagramLayout
    /// The highlighted value (clicked or picked), and the one under the pointer.
    let highlight: String?
    let hovered: String?
    let select: (String) -> Void
    let hover: (String?) -> Void
    let openActor: (String) -> Void
    let actorTitle: (String) -> String

    private var focus: String? { hovered ?? highlight }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in draw(&context) }
                .frame(width: layout.size.width, height: layout.size.height)
                .allowsHitTesting(false)
            ForEach(layout.boxes, id: \.code) { box in
                SimEnumNode(box: box, coded: layout.coded, highlighted: highlight == box.code, hovered: hovered == box.code,
                            dimmed: focus != nil && focus != box.code && !neighbours.contains(box.code))
                    .frame(width: box.rect.width, height: box.rect.height)
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                    .onTapGesture { select(box.code) }
                    .onHover { inside in hover(inside ? box.code : (hovered == box.code ? nil : hovered)) }
                    .position(x: box.rect.midX, y: box.rect.midY)
            }
            ForEach(layout.arrows, id: \.index) { arrow in
                let transition = def.transitions[arrow.index]
                if transition.label != nil || transition.by != nil {
                    SimEnumPill(label: transition.label, by: transition.by, lit: focus == arrow.from,
                                actorTitle: actorTitle, open: openActor)
                        .fixedSize()
                        .position(arrow.label)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    /// The focused value and the values one transition away, which stay bright.
    private var neighbours: Set<String> {
        guard let focus else { return [] }
        var result: Set<String> = [focus]
        for transition in def.transitions where transition.from == focus { result.insert(transition.to) }
        return result
    }

    private func draw(_ context: inout GraphicsContext) {
        for (dot, tip) in layout.starts {
            let color = Theme.muted.opacity(0.85)
            context.fill(Path(ellipseIn: CGRect(x: dot.x - 3.5, y: dot.y - 3.5, width: 7, height: 7)), with: .color(color))
            var line = Path()
            line.move(to: CGPoint(x: dot.x + 4, y: dot.y))
            line.addLine(to: CGPoint(x: tip.x - 5, y: tip.y))
            context.stroke(line, with: .color(color), lineWidth: 1.2)
            context.fill(arrowhead(at: tip, angle: 0, size: 6), with: .color(color))
        }
        // Dim arrows first, lit ones on top.
        let ordered = layout.arrows.sorted { (focus == $0.from ? 1 : 0) < (focus == $1.from ? 1 : 0) }
        for arrow in ordered {
            let lit = focus == arrow.from
            let into = focus != nil && focus == arrow.to
            let color: Color = lit ? Theme.accent : into ? Theme.text.opacity(0.42) : focus == nil ? Theme.text.opacity(0.32) : Theme.text.opacity(0.16)
            let style = StrokeStyle(lineWidth: lit ? 1.6 : 1.2, lineCap: .round, dash: arrow.back ? [4, 3] : [])
            context.stroke(arrow.path, with: .color(color), style: style)
            // Forward arrows end level; back arcs come down (or up) into their target.
            context.fill(arrowhead(at: arrow.tip, angle: arrow.angle, size: lit ? 7 : 6), with: .color(color))
        }
    }

    private func arrowhead(at tip: CGPoint, angle: Double, size: CGFloat) -> Path {
        var head = Path()
        let back = CGPoint(x: tip.x - cos(angle) * size, y: tip.y - sin(angle) * size)
        let spread = size * 0.55
        head.move(to: tip)
        head.addLine(to: CGPoint(x: back.x + sin(angle) * spread, y: back.y - cos(angle) * spread))
        head.addLine(to: CGPoint(x: back.x - sin(angle) * spread, y: back.y + cos(angle) * spread))
        head.closeSubpath()
        return head
    }
}

/// One value: its code over its name (or the name alone), a double border when terminal.
private struct SimEnumNode: View {
    let box: SimEnumDiagramLayout.Box
    let coded: Bool
    let highlighted: Bool
    let hovered: Bool
    let dimmed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        VStack(spacing: 1) {
            if coded {
                Text(box.code).font(Theme.mono(10, .medium)).foregroundStyle(highlighted ? Theme.accent : Theme.muted)
            }
            Text(box.name).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text)
        }
        .lineLimit(1)
        .fixedSize()
        .frame(width: box.rect.width, height: box.rect.height)
        .background(highlighted ? Theme.accent.opacity(0.10) : Theme.raised, in: shape)
        .overlay(shape.strokeBorder(highlighted ? Theme.accent : hovered ? Theme.text.opacity(0.4) : Theme.borderStrong,
                                    lineWidth: highlighted ? 1.5 : 1))
        .overlay {
            if box.terminal {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(highlighted ? Theme.accent.opacity(0.7) : Theme.borderStrong, lineWidth: 1)
                    .padding(3)
            }
        }
        .shadow(color: highlighted ? Theme.accent.opacity(0.35) : .clear, radius: 8)
        .opacity(dimmed ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(box.terminal ? "Terminal value" : "")
    }
}

/// A transition's name and who performs it, sitting on its arrow. `by` is a link.
private struct SimEnumPill: View {
    let label: String?
    let by: String?
    let lit: Bool
    let actorTitle: (String) -> String
    let open: (String) -> Void
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 1) {
            if let label {
                Text(label).font(Theme.ui(11, .medium)).foregroundStyle(lit ? Theme.accent : Theme.text.opacity(0.85))
            }
            if let by {
                Button { open(by) } label: {
                    Text("by \(by)").font(Theme.mono(10)).foregroundStyle(hovered ? Theme.accent : Theme.muted)
                        .underline(hovered, color: Theme.accent.opacity(0.6))
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .accessibilityLabel("Performed by \(actorTitle(by))")
                .accessibilityHint("Opens it")
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(lit ? Theme.accent.opacity(0.35) : Theme.border))
    }
}
