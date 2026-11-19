import AppKit
import SwiftUI
import StrataCore

// The mechanism player's sequence diagram: participants as columns with lifelines, steps as arrows
// (self-steps as loops), each with its label and the exact command → reply. Rows sit on a time axis
// when the steps have `at`, so heartbeats 5 s apart look like a rhythm, and a dashed line marks where
// each live TTL would run out. Text is measured once per path and width (`SimHowLayout`): labels wrap
// onto a second line and rows grow to fit them, long commands are shortened to one line (a long key is
// cut in the middle), and whatever was cut shows the expand glyph. A click opens the step detail.

/// Text measured with the fonts the diagram draws in.
@MainActor
enum SimHowMeasure {
    static let label = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let participant = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// Advance of one character of the 11 pt mono chip text, and of the 9.5 pt participant subtitle.
    static let monoAdvance = advance(NSFont.monospacedSystemFont(ofSize: 11, weight: .regular))
    static let subtitleAdvance = advance(NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular))

    static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// A key cut in the middle to `limit` characters (`TextFit.middle`), kept: the state panel and the
    /// diagram's deadlines redraw on every frame while the clock runs.
    static func middle(_ key: String, _ limit: Int) -> String {
        let id = "\(limit)|\(key)"
        if let hit = cuts[id] { return hit }
        if cuts.count > 400 { cuts.removeAll(keepingCapacity: true) }
        let cut = TextFit.middle(key, limit: limit)
        cuts[id] = cut
        return cut
    }

    private static var cuts: [String: String] = [:]

    /// The width of one character of a monospaced font, unrounded: it is multiplied by a count.
    static func advance(_ font: NSFont) -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }
}

/// Where everything goes, from a playback and a width. Pure geometry, built once per path and width
/// (`SimHowLayoutCache`), never per frame.
struct SimHowLayout {
    static let labelLine: CGFloat = 15
    static let chipHeight: CGFloat = 18
    /// Extra height for a step whose reply goes on its own line under the command.
    static let secondLine: CGFloat = 22
    /// Clear space between one row's text and the next row's.
    static let rowSpacing: CGFloat = 16
    static let minPitch: CGFloat = 46
    static let top: CGFloat = 14
    static let pointsPerSecond: CGFloat = 6
    static let maxGap: CGFloat = 96
    /// The expand glyph at the end of a chip whose text was cut.
    static let expandGlyph: CGFloat = 14
    /// How far the lower tier of header boxes sits below the upper one: a 32 pt box and a 4 pt gap.
    static let headerTier: CGFloat = 36

    /// One line of `command → reply` in its box. `\0` separates the command from the reply.
    struct Chip: Equatable {
        var text: String
        var box: CGRect
        var cut: Bool
    }

    struct Row: Equatable {
        /// The arrow.
        var y: CGFloat
        /// The text above and below it.
        var top: CGFloat
        var bottom: CGFloat
        var label: [String]
        var labelX: CGFloat
        var labelBottom: CGFloat
        var hangsLeft: Bool
        var chips: [Chip]
        /// The label was cut short (the step detail has all of it): its last line ends in the expand glyph.
        var labelCut: Bool
        /// How far the label's last line reaches from `labelX`.
        var labelEnd: CGFloat
        /// Where its text is, so a TTL deadline's label never lands on it.
        var textRects: [CGRect]
        /// Where its arrow (or loop) is, for the same reason.
        var arrowRect: CGRect = .zero
    }

    let width: CGFloat
    let columns: [String: CGFloat]
    /// Header boxes: their width, and whether they sit on the lower tier.
    let boxes: [String: (width: CGFloat, lower: Bool)]
    let tiers: Int
    /// Header boxes too narrow for their icons show a tinted edge instead.
    let compact: Bool
    /// Each participant's name as its header box shows it, fitted to the box.
    let names: [String: String]
    let rows: [Row]
    let times: [Double]
    let height: CGFloat
    /// x of the time axis; nil when no step has `at`.
    let axis: CGFloat?
    /// Participants drawn at the right edge put their self-loops and labels on the left.
    let rightmost: String?

    var headerHeight: CGFloat { tiers > 1 ? 48 + Self.headerTier : 48 }

    /// `subtitles`: the line under each participant's name in its header box (the node it stands for).
    @MainActor
    init(playback: MechPlayback, participants: [Participant], subtitles: [String: String], width: CGFloat) {
        self.width = width
        let axis: CGFloat? = playback.timed ? 58 : nil
        self.axis = axis
        // Header boxes: icon, name (or subtitle) and padding, centred on their columns. When even two
        // tiers would cut names short, the boxes go compact: a tinted edge for the icon, and the name on
        // up to two lines in place of the subtitle.
        let names = participants.map { SimHowMeasure.width($0.label, SimHowMeasure.participant) }
        let text = participants.enumerated().map { index, participant -> CGFloat in
            let sub = subtitles[participant.id].map { ceil(CGFloat($0.count) * SimHowMeasure.subtitleAdvance) + 12 } ?? 0
            return max(names[index], sub)
        }
        let left = (axis ?? 0) + 8
        func place(_ widths: [CGFloat]) -> SequenceGeometry.Columns {
            SequenceGeometry.columns(widths: widths.map(Double.init), left: Double(left), right: Double(width - 8), gap: 10)
        }
        // Insets 5 + 7, the icon and its spacing, and a point of slack for rounding. Only cut names count:
        // a long subtitle may end in an ellipsis.
        let chrome: CGFloat = 5 + 20 + 6 + 7 + 2
        var placed = place(text.map { $0 + chrome })
        compact = zip(placed.caps, names).contains { $0 < Double($1 + chrome) - 0.5 }
        let measure = { (text: String) in Double(SimHowMeasure.width(text, SimHowMeasure.participant)) }
        let compactChrome: CGFloat = 4 + 2.5 + 6 + 7 + 2
        if compact {
            let twoLines = participants.map { participant -> CGFloat in
                let widest = participant.label.split(separator: " ").map { measure(String($0)) }.max() ?? 0
                var room = widest
                while TextFit.wrap(participant.label, width: room, maxLines: 2, measure: measure).truncated { room += 4 }
                return CGFloat(room)
            }
            placed = place(twoLines.map { $0 + compactChrome })
        }
        // What each box shows: the name on one line, or (compact) on two. When every word (and every part
        // of a hyphenated one) fits, the text wraps there by itself; else the lines break between words and
        // a word too long for the box ends in an ellipsis, never broken in the middle.
        var shownNames: [String: String] = [:]
        for (index, participant) in participants.enumerated() where index < placed.caps.count {
            let room = Double(CGFloat(placed.caps[index]) - (compact ? compactChrome : chrome))
            let parts = participant.label.replacingOccurrences(of: "-", with: "- ").split(separator: " ")
            if compact, parts.allSatisfy({ measure(String($0)) <= room }) {
                shownNames[participant.id] = participant.label
                continue
            }
            shownNames[participant.id] = TextFit.wrap(participant.label, width: room, maxLines: compact ? 2 : 1, breakWords: false,
                                                 measure: measure).lines.joined(separator: "\n")
        }
        self.names = shownNames
        var columns: [String: CGFloat] = [:]
        var boxes: [String: (width: CGFloat, lower: Bool)] = [:]
        for (index, participant) in participants.enumerated() where index < placed.xs.count {
            columns[participant.id] = CGFloat(placed.xs[index])
            boxes[participant.id] = (CGFloat(placed.caps[index]), placed.tiers > 1 && index % 2 == 1)
        }
        self.columns = columns
        self.boxes = boxes
        tiers = placed.tiers
        let rightmost = participants.count > 1 ? participants.last?.id : nil
        self.rightmost = rightmost
        times = playback.frames.map(\.time)

        // Each row's text, fitted to its room, then the rows spaced so no text touches the next row's.
        let leftmost = (axis ?? 0) + 24
        var drafts: [(row: Row, extent: SequenceGeometry.RowExtent)] = []
        var previous = 0.0
        for frame in playback.frames {
            let step = frame.step
            let gap = Double(min(Self.maxGap, CGFloat(frame.time - previous) * Self.pointsPerSecond))
            previous = frame.time
            guard let anchor = Self.textAnchor(step, columns: columns, rightmost: rightmost, axis: axis, width: width) else {
                drafts.append((Row(y: 0, top: 0, bottom: 0, label: [], labelX: 0, labelBottom: 0, hangsLeft: false, chips: [],
                                   labelCut: false, labelEnd: 0, textRects: []), .init(above: 22, below: 8, gap: gap)))
                continue
            }
            let selfStep = step.from == step.to
            let measureLabel = { (text: String) in Double(SimHowMeasure.width(text, SimHowMeasure.label)) }
            var wrapped = TextFit.wrap(step.label, width: Double(max(40, anchor.room)), maxLines: 2, measure: measureLabel)
            if wrapped.truncated {
                // Cut short: leave room for the expand glyph after it.
                wrapped = TextFit.wrap(step.label, width: Double(max(40, anchor.room - Self.expandGlyph)), maxLines: 2, measure: measureLabel)
            }
            let label = wrapped.lines.isEmpty ? [step.label] : wrapped.lines
            let wide = anchor.right ? anchor.room : width - 12 - leftmost
            let chars = max(8, Int((wide - 12 - Self.expandGlyph) / SimHowMeasure.monoAdvance))
            let lines = StepCommand.lines(command: step.command, reply: step.reply, chars: chars)
            let above = (selfStep ? 9 : 7) + CGFloat(label.count) * Self.labelLine
            let chipTop: CGFloat = selfStep ? 5 : 6
            let below = lines.isEmpty ? (selfStep ? 12 : 8) : chipTop + Self.chipHeight + CGFloat(lines.count - 1) * Self.secondLine
            // Positions relative to the arrow; shifted to its y once the rows are spaced.
            var rects: [CGRect] = []
            let labelWidth = (label.map { SimHowMeasure.width($0, SimHowMeasure.label) }.max() ?? 0) + (wrapped.truncated ? Self.expandGlyph : 0)
            let labelBottom: CGFloat = selfStep ? -9 : -7
            rects.append(CGRect(x: anchor.right ? anchor.x - labelWidth : anchor.x, y: labelBottom - CGFloat(label.count) * Self.labelLine,
                                width: labelWidth, height: CGFloat(label.count) * Self.labelLine))
            var chips: [Chip] = []
            for (offset, line) in lines.enumerated() {
                let textWidth = CGFloat(line.text.replacingOccurrences(of: "\u{0}", with: line.text.hasPrefix("\u{0}") ? "→ " : "  →  ").count)
                    * SimHowMeasure.monoAdvance
                let boxWidth = ceil(textWidth) + 12 + (line.cut ? Self.expandGlyph : 0)
                // A chip too wide for the space right of its arrow slides left into the empty part of its row.
                let x = anchor.right ? anchor.x - boxWidth : max(leftmost, min(anchor.x - 6, width - 12 - boxWidth))
                let box = CGRect(x: x, y: chipTop + CGFloat(offset) * Self.secondLine, width: boxWidth, height: Self.chipHeight)
                chips.append(Chip(text: line.text, box: box, cut: line.cut))
                rects.append(box)
            }
            var row = Row(y: 0, top: -above, bottom: below, label: label, labelX: anchor.x, labelBottom: labelBottom,
                          hangsLeft: anchor.right, chips: chips, labelCut: wrapped.truncated,
                          labelEnd: SimHowMeasure.width(label.last ?? "", SimHowMeasure.label), textRects: rects)
            if let x1 = columns[step.from], let x2 = columns[step.to] {
                row.arrowRect = selfStep
                    ? CGRect(x: step.from == rightmost ? x1 - 30 : x1 - 3, y: -11, width: 33, height: 22)
                    : CGRect(x: min(x1, x2) - 4, y: -5, width: abs(x2 - x1) + 8, height: 10)
            }
            drafts.append((row, .init(above: Double(above), below: Double(below), gap: gap)))
        }
        let ys = SequenceGeometry.rows(drafts.map(\.extent), top: Double(Self.top), spacing: Double(Self.rowSpacing),
                                       minPitch: Double(Self.minPitch)).map { CGFloat($0) }
        rows = zip(drafts, ys).map { draft, y in
            var row = draft.row
            row.y = y
            row.top += y
            row.bottom += y
            row.labelBottom += y
            row.chips = row.chips.map { var chip = $0; chip.box = chip.box.offsetBy(dx: 0, dy: y); return chip }
            row.textRects = row.textRects.map { $0.offsetBy(dx: 0, dy: y) }
            row.arrowRect = row.arrowRect.offsetBy(dx: 0, dy: y)
            return row
        }
        var bottom = (rows.last?.bottom ?? Self.top) + 30
        if playback.timed, let last = rows.last {
            // Room for the furthest TTL deadline the path ever shows.
            let latest = playback.frames.flatMap { frame in frame.state.compactMap { $0.ttl.map { frame.time + $0 } } }.max() ?? 0
            let reach = last.y + CGFloat(max(0, latest - (times.last ?? 0))) * Self.pointsPerSecond
            bottom = max(bottom, reach + 30)
        }
        height = bottom
    }

    /// Where a step's label and command start, whether they hang to the left of that point, and the
    /// width they may use.
    static func textAnchor(_ step: MechStep, columns: [String: CGFloat], rightmost: String?, axis: CGFloat?,
                           width: CGFloat) -> (x: CGFloat, right: Bool, room: CGFloat)? {
        guard let x1 = columns[step.from], let x2 = columns[step.to] else { return nil }
        if step.from == step.to {
            if step.from == rightmost { return (x1 - 36, true, x1 - 36 - (axis ?? 0) - 24) }
            return (x1 + 36, false, width - x1 - 48)
        }
        let left = min(x1, x2) + 12
        return (left, false, width - left - 12)
    }

    /// The y of a mechanism time: on a row at that row's time, in between proportionally.
    func y(at time: Double) -> CGFloat {
        guard let first = times.first, !rows.isEmpty else { return Self.top + 22 }
        if time <= first { return rows[0].y - CGFloat(first - time) * Self.pointsPerSecond }
        guard let i = times.lastIndex(where: { $0 <= time }) else { return rows[0].y }
        if i == times.count - 1 { return rows[i].y + CGFloat(time - times[i]) * Self.pointsPerSecond }
        let j = i + 1
        return rows[i].y + CGFloat((time - times[i]) / (times[j] - times[i])) * (rows[j].y - rows[i].y)
    }

    /// Where the "now" line is: it eases from one row to the next as the clock runs and the arrow flies.
    func nowY(_ position: Double, schedule: SimHowSchedule) -> CGFloat {
        guard !rows.isEmpty else { return Self.top + 22 }
        if position >= schedule.end { return rows[rows.count - 1].y }
        let phase = schedule.phase(at: position)
        let from = phase.k < 0 ? Self.top : rows[phase.k].y
        let to = rows[phase.k + 1].y
        let leg = schedule.legs[phase.k + 1]
        let moving = leg.gap + leg.travel
        let done = moving <= 0 ? 1 : (phase.gap * leg.gap + phase.travel * leg.travel) / moving
        let eased = done * done * (3 - 2 * done)
        return from + (to - from) * eased
    }

    /// The row whose text band holds `y` (with a little slack between rows).
    func row(near y: CGFloat) -> Int? {
        let hits = rows.indices.filter { y >= rows[$0].top - 8 && y <= rows[$0].bottom + 8 }
        return hits.min { abs(rows[$0].y - y) < abs(rows[$1].y - y) }
    }
}

/// The layout of the open path at the diagram's width, kept until either changes.
@MainActor
final class SimHowLayoutCache {
    private var key: String?
    private var value: SimHowLayout?

    func layout(_ player: SimHowPlayer, subtitles: [String: String], width: CGFloat) -> SimHowLayout {
        let key = "\(player.branch ?? "")|\(player.playback.frames.count)|\(Int(width.rounded()))"
        if key == self.key, let value { return value }
        let made = SimHowLayout(playback: player.playback, participants: player.mechanism.participants, subtitles: subtitles,
                                width: width)
        self.key = key
        value = made
        return made
    }
}

/// The participants' header boxes, above the scrolling diagram. Linked ones select their node. When
/// neighbours' boxes don't fit side by side they alternate between two tiers, each with a short lifeline
/// down to the diagram.
@MainActor
struct SimHowHeader: View {
    let mechanism: Mechanism
    let layout: SimHowLayout
    let sim: Simulation
    let active: Set<String>
    let select: (StageSelection?) -> Void

    var body: some View {
        let height = layout.headerHeight
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for participant in mechanism.participants {
                    guard let x = layout.columns[participant.id], let box = layout.boxes[participant.id] else { continue }
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: (box.lower ? 24 + SimHowLayout.headerTier : 24) + 15))
                    line.addLine(to: CGPoint(x: x, y: height))
                    context.stroke(line, with: .color(Theme.borderStrong), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
            }
            if let axis = layout.axis {
                Text("time").font(Theme.ui(10, .medium)).foregroundStyle(Theme.faint)
                    .position(x: axis - 22, y: 24)
            }
            ForEach(mechanism.participants) { participant in
                if let x = layout.columns[participant.id], let box = layout.boxes[participant.id] {
                    SimHowParticipant(participant: participant, node: participant.node.flatMap(sim.level.node),
                                      name: layout.names[participant.id] ?? participant.label,
                                      active: active.contains(participant.id), compact: layout.compact, select: select)
                        .frame(width: box.width, height: 32)
                        .position(x: x, y: box.lower ? 24 + SimHowLayout.headerTier : 24)
                }
            }
        }
        .frame(width: layout.width, height: height)
    }

    /// The line under a participant's name: the node it stands for, or that node's kind when the names match.
    static func subtitles(_ mechanism: Mechanism, sim: Simulation) -> [String: String] {
        var out: [String: String] = [:]
        for participant in mechanism.participants {
            guard let node = participant.node.flatMap(sim.level.node) else { continue }
            out[participant.id] = subtitle(participant, node: node)
        }
        return out
    }

    static func subtitle(_ participant: Participant, node: Node) -> String {
        node.label.lowercased() == participant.label.lowercased() ? node.tech ?? node.kind.rawValue : node.label
    }
}

@MainActor
private struct SimHowParticipant: View {
    let participant: Participant
    let node: Node?
    /// The name fitted to the box (`SimHowLayout.names`): one line, or two when compact.
    let name: String
    let active: Bool
    var compact = false
    let select: (StageSelection?) -> Void
    @State private var hovered = false

    var body: some View {
        let kind = node?.kind ?? participant.kind ?? .service
        let tint = Node(id: participant.id, kind: kind).simTint
        let content = HStack(spacing: 6) {
            if compact {
                Capsule().fill(tint.opacity(0.8)).frame(width: 2.5, height: 20)
            } else {
                Image(systemName: node?.icon ?? kind.symbol)
                    .font(Theme.ui(10, .semibold)).foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(compact ? 2 : 1).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: compact)
                if let node, !compact {
                    HStack(spacing: 3) {
                        Text(SimHowHeader.subtitle(participant, node: node)).lineLimit(1).truncationMode(.tail)
                        Image(systemName: "arrow.up.forward").font(Theme.ui(7, .bold))
                    }
                    .font(Theme.mono(9.5)).foregroundStyle(hovered ? Theme.accent : Theme.faint)
                }
            }
        }
        .padding(.leading, compact ? 4 : 5).padding(.trailing, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(active ? Theme.accent.opacity(0.10) : Theme.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? Theme.accent.opacity(0.55) : hovered ? Theme.borderStrong : Theme.border))
        if let node {
            Button { select(.node(node.id)) } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .accessibilityLabel("\(participant.label), select \(node.label) on the stage")
        } else {
            content
        }
    }
}

/// Resolved text, kept between frames: the diagram redraws every frame while playing.
@MainActor
final class SimHowTextCache {
    private var cache: [String: GraphicsContext.ResolvedText] = [:]

    func text(_ key: String, in context: GraphicsContext, _ make: () -> Text) -> GraphicsContext.ResolvedText {
        if let hit = cache[key] { return hit }
        if cache.count > 600 { cache.removeAll(keepingCapacity: true) }
        let resolved = context.resolve(make())
        cache[key] = resolved
        return resolved
    }
}

/// How a reply reads at a glance.
enum SimHowReply {
    case ok, empty, failed, neutral

    init(_ reply: String) {
        let text = reply.lowercased().trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("(error") || text.hasPrefix("error") || text.contains("timeout") || text.hasPrefix("(no reply") {
            self = .failed
        } else if ["0", "(integer) 0", "(nil)", "nil", "(0 rows)", "(empty array)", "false"].contains(text) {
            self = .empty
        } else if ["ok", "1", "(integer) 1", "true", "+ok"].contains(text) || text.hasPrefix("(integer)") || text.hasPrefix("update ") {
            self = .ok
        } else {
            self = .neutral
        }
    }

    var color: Color {
        switch self {
        case .ok: Theme.good
        case .empty: Theme.warn
        case .failed: Theme.bad
        case .neutral: Theme.info
        }
    }
}

/// Draws the diagram at one playback position.
@MainActor
struct SimHowCanvasPainter {
    let playback: MechPlayback
    let schedule: SimHowSchedule
    let layout: SimHowLayout
    let position: Double
    let keyColors: [String: Color]
    let hoveredRow: Int?
    /// The step the detail beside the diagram shows.
    let inspected: Int?
    let cache: SimHowTextCache

    func draw(_ context: GraphicsContext, size: CGSize) {
        let current = schedule.current(at: position)
        let flight = schedule.flight(at: position)
        drawBranchBand(context)
        if let axis = layout.axis { drawAxis(context, axis: axis, now: layout.nowY(position, schedule: schedule)) }
        drawLifelines(context, size: size)
        if current >= 0, current < layout.rows.count {
            context.fill(Path(roundedRect: band(current, size: size), cornerRadius: 8), with: .color(Theme.accent.opacity(0.055)))
            if inspected == current {
                context.stroke(Path(roundedRect: band(current, size: size).insetBy(dx: 0.5, dy: 0.5), cornerRadius: 8),
                               with: .color(Theme.accent.opacity(0.28)), lineWidth: 1)
            }
        }
        if let hoveredRow, hoveredRow != current, hoveredRow < layout.rows.count {
            context.fill(Path(roundedRect: band(hoveredRow, size: size), cornerRadius: 8), with: .color(Theme.hover))
        }
        if layout.axis != nil { drawDeadlines(context, size: size) }
        drawNow(context, size: size)
        for (index, frame) in playback.frames.enumerated() where index < layout.rows.count {
            let emphasis: SimHowRowEmphasis = index == current ? .active : index < current ? .past : .future
            drawStep(frame, index: index, emphasis: emphasis, in: context, size: size)
        }
        if let hoveredRow, hoveredRow < layout.rows.count, inspected != hoveredRow { drawHint(hoveredRow, in: context, size: size) }
        if let flight { drawToken(flight.step, progress: flight.progress, in: context) }
    }

    private func band(_ index: Int, size: CGSize) -> CGRect {
        let row = layout.rows[index]
        return CGRect(x: 6, y: row.top - 5, width: size.width - 12, height: row.bottom - row.top + 10)
    }

    // MARK: Background

    private func drawBranchBand(_ context: GraphicsContext) {
        guard let start = playback.branchStart, start < layout.rows.count else { return }
        let top = layout.rows[start].top - 4
        let bottom = (layout.rows.last?.bottom ?? top) + 4
        let x = (layout.axis ?? 12) + 8
        let bar = CGRect(x: x, y: top, width: 3, height: bottom - top)
        context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(Theme.warn.opacity(0.45)))
        let label = cache.text("branch-label", in: context) {
            Text("branch").font(Theme.ui(9.5, .semibold)).foregroundStyle(Theme.warn.opacity(0.9))
        }
        var rotated = context
        rotated.translateBy(x: x + 12, y: top + 4)
        rotated.rotate(by: .degrees(90))
        rotated.draw(label, at: .zero, anchor: .leading)
    }

    private func drawAxis(_ context: GraphicsContext, axis: CGFloat, now: CGFloat) {
        var line = Path()
        line.move(to: CGPoint(x: axis, y: 8))
        line.addLine(to: CGPoint(x: axis, y: layout.height - 8))
        context.stroke(line, with: .color(Theme.borderStrong), lineWidth: 1)
        var seen: Set<Double> = []
        for (index, time) in layout.times.enumerated() where index < layout.rows.count && seen.insert(time).inserted {
            let y = layout.rows[index].y
            guard abs(y - now) > 22 else { continue }   // the clock pill shows this time
            var tick = Path()
            tick.move(to: CGPoint(x: axis - 4, y: y))
            tick.addLine(to: CGPoint(x: axis, y: y))
            context.stroke(tick, with: .color(Theme.borderStrong), lineWidth: 1)
            let label = cache.text("t-\(time)", in: context) {
                Text(SimHowFormat.time(time)).font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            context.draw(label, at: CGPoint(x: axis - 8, y: y), anchor: .trailing)
        }
    }

    private func drawLifelines(_ context: GraphicsContext, size: CGSize) {
        for x in layout.columns.values {
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(Theme.borderStrong), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        }
    }

    /// Where each live TTL would run out, if nothing renews it. Its label goes where no step's text or
    /// arrow is: at the right edge, without the key's name if need be, else just right of the time axis,
    /// else nowhere (the dot on the axis and the state panel still tell).
    private func drawDeadlines(_ context: GraphicsContext, size: CGSize) {
        let k = Int(floor(min(schedule.end, max(-1, position)) + 1e-9))
        let now = schedule.time(at: position)
        let state = playback.state(after: k, at: now)
        guard let axis = layout.axis else { return }
        var placed: [CGRect] = []
        if let start = playback.branchStart, start < layout.rows.count {
            placed.append(CGRect(x: axis + 4, y: layout.rows[start].top - 4, width: 20, height: 56))   // the rotated "branch"
        }
        for key in state.keys {
            guard let ttl = key.ttl else { continue }
            let deadline = now + ttl
            let y = layout.y(at: deadline)
            guard y < size.height - 4 else { continue }
            let color = keyColors[key.key] ?? Theme.warn
            var line = Path()
            line.move(to: CGPoint(x: axis, y: y))
            line.addLine(to: CGPoint(x: size.width - 10, y: y))
            context.stroke(line, with: .color(color.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            let dot = CGRect(x: axis - 3.5, y: y - 3.5, width: 7, height: 7)
            context.fill(Path(ellipseIn: dot), with: .color(color))
            let when = SimHowFormat.time((deadline * 100).rounded() / 100)
            let short = SimHowMeasure.middle(key.key, 28)
            let variants = [("long", "\(short) expires at \(when)", false), ("short", "expires at \(when)", false),
                            ("short", "expires at \(when)", true)]
            for (variant, text, left) in variants {
                let label = cache.text("deadline-\(variant)-\(key.key)-\(when)", in: context) {
                    Text("\(Image(systemName: "hourglass.bottomhalf.filled")) \(text)").font(Theme.mono(9.5)).foregroundStyle(color)
                }
                let measured = label.measure(in: CGSize(width: 1000, height: 20))
                let x = left ? axis + 16 : size.width - 14 - measured.width - 8
                let box = CGRect(x: x, y: y - 8, width: measured.width + 8, height: 15)
                let clear = !placed.contains { $0.intersects(box) } && !layout.rows.contains { row in
                    row.arrowRect.intersects(box) || row.textRects.contains { $0.insetBy(dx: -4, dy: -2).intersects(box) }
                }
                guard clear else { continue }
                placed.append(box)
                context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(Theme.surface))
                context.draw(label, at: CGPoint(x: box.midX, y: box.midY))
                break
            }
        }
    }

    private func drawNow(_ context: GraphicsContext, size: CGSize) {
        guard position > -1 || schedule.legs.first.map({ $0.gap > 0 }) == true else { return }
        let y = layout.nowY(position, schedule: schedule)
        let start = layout.axis ?? 8
        var line = Path()
        line.move(to: CGPoint(x: start, y: y))
        line.addLine(to: CGPoint(x: size.width - 8, y: y))
        context.stroke(line, with: .color(Theme.accent.opacity(0.32)), lineWidth: 1)
        guard let axis = layout.axis else { return }
        let time = schedule.time(at: position)
        let clock = SimHowFormat.clock(time, short: playback.duration < 1)
        let label = cache.text("now-\(clock)", in: context) {
            Text(clock).font(Theme.mono(10, .semibold)).foregroundStyle(Theme.bg)
        }
        let measured = label.measure(in: CGSize(width: 80, height: 16))
        let pill = CGRect(x: axis - measured.width - 12, y: y - 8, width: measured.width + 10, height: 16)
        context.fill(Path(roundedRect: pill, cornerRadius: 5), with: .color(Theme.accent))
        context.draw(label, at: CGPoint(x: pill.midX, y: pill.midY))
    }

    // MARK: Steps

    private func drawStep(_ frame: MechFrame, index: Int, emphasis: SimHowRowEmphasis, in context: GraphicsContext, size: CGSize) {
        let step = frame.step
        guard let x1 = layout.columns[step.from], let x2 = layout.columns[step.to] else { return }
        let row = layout.rows[index]
        let y = row.y
        let reply = step.reply.map(SimHowReply.init)
        let failed = reply == .failed
        let ink: Color = switch emphasis {
        case .active: failed ? Theme.bad : Theme.accent
        case .past: failed ? Theme.bad.opacity(0.7) : Theme.text.opacity(0.5)
        case .future: Theme.text.opacity(0.17)
        }
        let width: CGFloat = emphasis == .active ? 2 : 1.4
        let dash: [CGFloat] = failed ? [5, 4] : []
        let selfStep = step.from == step.to
        let leftLoop = selfStep && step.from == layout.rightmost
        if emphasis == .active {
            let glow = selfStep ? loop(x1, y, left: leftLoop) : straight(x1, x2, y)
            context.stroke(glow, with: .color(ink.opacity(0.18)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
        }
        if selfStep {
            context.stroke(loop(x1, y, left: leftLoop), with: .color(ink), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
            context.stroke(arrowhead(at: CGPoint(x: x1 + (leftLoop ? -2 : 2), y: y + 9), direction: leftLoop ? 1 : -1),
                           with: .color(ink), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        } else {
            let direction: CGFloat = x2 > x1 ? 1 : -1
            context.stroke(straight(x1, x2 - direction * 2, y), with: .color(ink),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
            context.stroke(arrowhead(at: CGPoint(x: x2 - direction * 1.5, y: y), direction: direction),
                           with: .color(ink), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            let origin = CGRect(x: x1 - 3, y: y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: origin), with: .color(ink))
        }

        // Label above (one or two lines), command → reply below. Self-loops put both beside the loop.
        var faded = context
        faded.opacity = emphasis == .future ? 0.42 : 1
        for (line, text) in row.label.enumerated() {
            let resolved = cache.text("label-\(index)-\(line)-\(emphasis)|\(text)", in: context) {
                Text(verbatim: text)
                    .font(Theme.ui(12, emphasis == .active ? .semibold : .medium))
                    .foregroundStyle(emphasis == .active ? Theme.text : Theme.text.opacity(0.82))
            }
            let bottom = row.labelBottom - CGFloat(row.label.count - 1 - line) * SimHowLayout.labelLine
            faded.draw(resolved, at: CGPoint(x: row.labelX, y: bottom), anchor: row.hangsLeft ? .bottomTrailing : .bottomLeading)
        }
        if row.labelCut {
            let x = row.hangsLeft ? row.labelX - row.labelEnd - 9 : row.labelX + row.labelEnd + 9
            faded.draw(expandGlyph(active: emphasis == .active || hoveredRow == index, in: context),
                       at: CGPoint(x: x, y: row.labelBottom - SimHowLayout.labelLine / 2))
        }
        for (line, chip) in row.chips.enumerated() {
            let resolved = cache.text("chip-\(index)-\(line)|\(chip.text)", in: context) { commandText(chip.text, step: step) }
            let box = chip.box
            faded.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(Theme.raised))
            faded.stroke(Path(roundedRect: box, cornerRadius: 5), with: .color(emphasis == .active ? Theme.accent.opacity(0.4) : Theme.border),
                         lineWidth: 1)
            faded.draw(resolved, at: CGPoint(x: box.minX + 6, y: box.midY), anchor: .leading)
            if chip.cut {
                faded.draw(expandGlyph(active: emphasis == .active || hoveredRow == index, in: context), at: CGPoint(x: box.maxX - 9, y: box.midY))
            }
        }
    }

    /// The mark of text cut short: a click on the row shows all of it.
    private func expandGlyph(active: Bool, in context: GraphicsContext) -> GraphicsContext.ResolvedText {
        cache.text("expand-\(active)", in: context) {
            Text(Image(systemName: "arrow.up.left.and.arrow.down.right")).font(Theme.ui(8, .semibold))
                .foregroundStyle(active ? Theme.accent : Theme.muted)
        }
    }

    /// The command in mono, then `→ reply` coloured by what the reply means. `\0` separates the two.
    private func commandText(_ value: String, step: MechStep) -> Text {
        let parts = value.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let command = Text(verbatim: parts[0]).foregroundStyle(Theme.text.opacity(0.88))
        guard parts.count == 2 else { return command.font(Theme.mono(11)) }
        let tint = step.reply.map { SimHowReply($0).color } ?? Theme.muted
        let arrow = Text(verbatim: parts[0].isEmpty ? "→ " : "  →  ").foregroundStyle(Theme.faint)
        return Text("\(command)\(arrow)\(Text(verbatim: parts[1]).foregroundStyle(tint))").font(Theme.mono(11))
    }

    /// "Details ›" at the right end of a hovered row: on its label's line, else on its arrow's, wherever
    /// that end of the line is empty.
    private func drawHint(_ index: Int, in context: GraphicsContext, size: CGSize) {
        let row = layout.rows[index]
        let step = playback.frames[index].step
        let label = cache.text("hint", in: context) {
            Text("Details \(Image(systemName: "chevron.right"))").font(Theme.ui(10, .medium)).foregroundStyle(Theme.muted)
        }
        let measured = label.measure(in: CGSize(width: 200, height: 20))
        let x = size.width - 14 - measured.width - 12
        let labelLine = row.labelBottom - SimHowLayout.labelLine / 2 - 1
        let reach = [layout.columns[step.from], layout.columns[step.to]].compactMap { $0 }.max() ?? 0
        let arrowEnd = step.from == step.to && step.from != layout.rightmost ? reach + 30 : reach
        let candidates = [(y: labelLine, clear: true), (y: row.y, clear: arrowEnd + 10 < x)]
        for candidate in candidates where candidate.clear {
            let box = CGRect(x: x, y: candidate.y - 7.5, width: measured.width + 12, height: 15)
            guard !row.textRects.contains(where: { $0.insetBy(dx: -4, dy: 0).intersects(box) }) else { continue }
            context.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(Theme.surface))
            context.stroke(Path(roundedRect: box, cornerRadius: 5), with: .color(Theme.borderStrong), lineWidth: 1)
            context.draw(label, at: CGPoint(x: box.midX, y: box.midY))
            return
        }
    }

    private func straight(_ x1: CGFloat, _ x2: CGFloat, _ y: CGFloat) -> Path {
        Path { p in p.move(to: CGPoint(x: x1, y: y)); p.addLine(to: CGPoint(x: x2, y: y)) }
    }

    private func loop(_ x: CGFloat, _ y: CGFloat, left: Bool) -> Path {
        let s: CGFloat = left ? -1 : 1
        return Path { p in
            p.move(to: CGPoint(x: x, y: y - 9))
            p.addLine(to: CGPoint(x: x + s * 18, y: y - 9))
            p.addQuadCurve(to: CGPoint(x: x + s * 26, y: y), control: CGPoint(x: x + s * 26, y: y - 9))
            p.addQuadCurve(to: CGPoint(x: x + s * 18, y: y + 9), control: CGPoint(x: x + s * 26, y: y + 9))
            p.addLine(to: CGPoint(x: x + s * 2, y: y + 9))
        }
    }

    private func arrowhead(at tip: CGPoint, direction: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: tip.x - direction * 7, y: tip.y - 4))
            p.addLine(to: tip)
            p.addLine(to: CGPoint(x: tip.x - direction * 7, y: tip.y + 4))
        }
    }

    // MARK: Token

    /// The request flies from sender to receiver, then the reply (a ring, like responses on the stage) flies back.
    private func drawToken(_ index: Int, progress: Double, in context: GraphicsContext) {
        guard index < playback.frames.count, index < layout.rows.count else { return }
        let step = playback.frames[index].step
        guard let x1 = layout.columns[step.from], let x2 = layout.columns[step.to] else { return }
        let y = layout.rows[index].y
        let hasReply = step.reply != nil && step.from != step.to
        let split = hasReply ? 0.62 : 1.0
        let point: CGPoint
        let reply: Bool
        if step.from == step.to {
            let left = step.from == layout.rightmost
            point = loop(x1, y, left: left).trimmedPath(from: 0, to: max(0.001, progress)).currentPoint ?? CGPoint(x: x1, y: y)
            reply = false
        } else if progress < split {
            let t = ease(progress / split)
            point = CGPoint(x: x1 + (x2 - x1) * t, y: y)
            reply = false
        } else {
            let t = ease((progress - split) / (1 - split))
            point = CGPoint(x: x2 + (x1 - x2) * t, y: y)
            reply = true
        }
        let failed = step.reply.map { SimHowReply($0) == .failed } ?? false
        let color = reply && failed ? Theme.bad : Theme.token(1)
        let r: CGFloat = 4.5
        let box = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        context.fill(Path(ellipseIn: box.insetBy(dx: -5, dy: -5)), with: .color(color.opacity(0.10)))
        context.fill(Path(ellipseIn: box.insetBy(dx: -2.5, dy: -2.5)), with: .color(color.opacity(0.22)))
        if reply {
            context.fill(Path(ellipseIn: box), with: .color(Theme.bg))
            context.stroke(Path(ellipseIn: box), with: .color(color), lineWidth: 1.6)
        } else {
            context.fill(Path(ellipseIn: box), with: .color(color))
        }
    }

    private func ease(_ t: Double) -> CGFloat { CGFloat(t * t * (3 - 2 * t)) }
}

enum SimHowRowEmphasis { case past, active, future }

enum SimHowFormat {
    private static let one = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
    private static let upToTwo = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))

    static func time(_ seconds: Double) -> String {
        if seconds == 0 { return "0 s" }
        if seconds < 1 { return "\((seconds * 1000).formatted(upToTwo)) ms" }
        return "\(seconds.formatted(upToTwo)) s"
    }

    /// The running clock: whole milliseconds below a second (so it agrees with the step's `at 10 ms`), else
    /// one decimal for seconds; always milliseconds for a sequence that lives below a second.
    static func clock(_ seconds: Double, short: Bool = false) -> String {
        if short || seconds < 0.9995 { return "\(Int((seconds * 1000).rounded())) ms" }
        return "\(seconds.formatted(one)) s"
    }

    /// One decimal below 10 s, whole seconds above: how long a TTL has left.
    static func ttl(_ seconds: Double) -> String {
        seconds < 10 ? "\(seconds.formatted(one)) s" : "\(Int(seconds.rounded())) s"
    }
}

/// The scrolling diagram. Its canvas redraws on the player's own timeline, only while playing.
@MainActor
struct SimHowDiagram: View {
    let player: SimHowPlayer
    let sim: Simulation
    let keyColors: [String: Color]
    let select: (StageSelection?) -> Void
    var still = false
    @State private var cache = SimHowTextCache()
    @State private var layouts = SimHowLayoutCache()
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var hoveredRow: Int?
    @State private var viewport: CGFloat = 400

    init(player: SimHowPlayer, sim: Simulation, keyColors: [String: Color], select: @escaping (StageSelection?) -> Void, still: Bool = false) {
        self.player = player
        self.sim = sim
        self.keyColors = keyColors
        self.select = select
        self.still = still
        _hoveredRow = State(initialValue: SimHowSnapshot.hovered[ObjectIdentifier(player)])
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = layouts.layout(player, subtitles: SimHowHeader.subtitles(player.mechanism, sim: sim), width: proxy.size.width)
            let header = layout.headerHeight + 1
            VStack(spacing: 0) {
                SimHowHeader(mechanism: player.mechanism, layout: layout, sim: sim, active: activeParticipants, select: select)
                Rectangle().fill(Theme.border).frame(height: 1)
                if still {
                    canvas(layout)
                        .frame(height: layout.height)
                        .offset(y: -scrollTarget(layout, viewport: proxy.size.height - header))
                        .frame(height: max(0, proxy.size.height - header), alignment: .top)
                        .clipped()
                } else {
                    ScrollView(.vertical) {
                        canvas(layout).frame(height: layout.height)
                    }
                    .scrollPosition($scroll)
                    .scrollIndicators(.automatic)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewport = $0 }
                    .onChange(of: player.shown, initial: true) { _, _ in follow(layout) }
                    .onChange(of: player.branch) { _, _ in follow(layout) }
                }
            }
        }
    }

    private var activeParticipants: Set<String> {
        let index = player.shown
        guard index >= 0, index < player.playback.frames.count else { return [] }
        let step = player.playback.frames[index].step
        return [step.from, step.to]
    }

    private func canvas(_ layout: SimHowLayout) -> some View {
        let inspected = player.inspecting ? player.shown : nil
        return TimelineView(.animation(paused: !player.playing || still)) { tick in
            let position = player.position(at: tick.date)
            Canvas { context, size in
                SimHowCanvasPainter(playback: player.playback, schedule: player.schedule, layout: layout, position: position,
                                    keyColors: keyColors, hoveredRow: hoveredRow, inspected: inspected, cache: cache)
                    .draw(context, size: size)
            }
            .onChange(of: tick.date) { _, date in player.sync(at: date) }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): if layout.row(near: point.y) != hoveredRow { hoveredRow = layout.row(near: point.y) }
            case .ended: hoveredRow = nil
            }
        }
        .pointerStyle(hoveredRow == nil ? nil : .link)
        // A click on a step opens its detail, paused there; a click anywhere else closes the detail.
        .gesture(SpatialTapGesture().onEnded { event in
            if let row = layout.row(near: event.location.y) { player.inspect(row) } else { player.closeInspector() }
        })
        .accessibilityElement()
        .accessibilityLabel("Sequence diagram, step \(max(0, player.shown) + 1) of \(player.playback.frames.count)")
        .accessibilityHint("Click a step to see all of it")
    }

    /// Keeps the current step in the upper part of the view.
    private func scrollTarget(_ layout: SimHowLayout, viewport: CGFloat) -> CGFloat {
        let index = max(0, player.shown)
        guard index < layout.rows.count else { return 0 }
        let wanted = layout.rows[index].top - viewport * 0.4
        return min(max(0, layout.height - viewport), max(0, wanted))
    }

    private func follow(_ layout: SimHowLayout) {
        let y = scrollTarget(layout, viewport: viewport)
        withAnimation(Theme.gentle) { scroll.scrollTo(y: y) }
    }
}
