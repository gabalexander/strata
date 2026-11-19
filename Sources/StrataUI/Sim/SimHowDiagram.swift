import SwiftUI
import StrataCore

// The mechanism player's sequence diagram: participants as columns with lifelines, steps as arrows
// (self-steps as loops), each with its label and the exact command → reply. Rows sit on a time axis
// when the steps have `at`, so heartbeats 5 s apart look like a rhythm, and a dashed line marks where
// each live TTL would run out.

/// Where everything goes, from a playback and a width. Pure geometry, rebuilt only when either changes.
struct SimHowLayout: Equatable {
    static let rowHeight: CGFloat = 62
    /// Extra height for a step whose `command → reply` wraps onto a second line.
    static let secondLine: CGFloat = 22
    /// Advance of one character of the 11 pt mono chip text.
    static let monoAdvance: CGFloat = 6.65
    static let firstRow: CGFloat = 36
    static let pointsPerSecond: CGFloat = 6
    static let maxGap: CGFloat = 96

    let width: CGFloat
    let columns: [String: CGFloat]
    let rows: [CGFloat]
    let times: [Double]
    let height: CGFloat
    /// x of the time axis; nil when no step has `at`.
    let axis: CGFloat?
    /// Participants drawn at the right edge put their self-loops and labels on the left.
    let rightmost: String?
    /// Steps whose reply goes on its own line under the command.
    let wrapped: Set<Int>

    init(playback: MechPlayback, participants: [Participant], width: CGFloat) {
        self.width = width
        axis = playback.timed ? 58 : nil
        let left: CGFloat = (playback.timed ? 58 : 16) + 72
        let right: CGFloat = max(left + 1, width - 86)
        var columns: [String: CGFloat] = [:]
        let count = CGFloat(max(1, participants.count - 1))
        for (index, participant) in participants.enumerated() {
            let share: CGFloat = participants.count == 1 ? 0.5 : CGFloat(index) / count
            let x: CGFloat = left + (right - left) * share
            columns[participant.id] = x.rounded()
        }
        self.columns = columns
        let rightmost = participants.count > 1 ? participants.last?.id : nil
        self.rightmost = rightmost
        times = playback.frames.map(\.time)
        let axis = self.axis
        var wrapped: Set<Int> = []
        for (index, frame) in playback.frames.enumerated() {
            guard let command = frame.step.command, let reply = frame.step.reply,
                  let anchor = Self.textAnchor(frame.step, columns: columns, rightmost: rightmost, axis: axis, width: width) else { continue }
            let estimate = CGFloat(command.count + reply.count + 5) * Self.monoAdvance + 12
            if estimate > anchor.room { wrapped.insert(index) }
        }
        self.wrapped = wrapped
        var rows: [CGFloat] = []
        var y = Self.firstRow
        var previous = 0.0
        for (index, time) in times.enumerated() {
            let gap = min(Self.maxGap, CGFloat(time - previous) * Self.pointsPerSecond)
            let above = index > 0 && wrapped.contains(index - 1) ? Self.secondLine : 0
            y += (index == 0 ? 0 : Self.rowHeight + above) + gap
            rows.append(y)
            previous = time
        }
        self.rows = rows
        var bottom = (rows.last ?? Self.firstRow) + 44
        if playback.timed {
            // Room for the furthest TTL deadline the path ever shows.
            let latest = playback.frames.flatMap { frame in frame.state.compactMap { $0.ttl.map { frame.time + $0 } } }.max() ?? 0
            let reach = (rows.last ?? Self.firstRow) + CGFloat(max(0, latest - (times.last ?? 0))) * Self.pointsPerSecond
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
            if step.from == rightmost { return (x1 - 36, true, x1 - 48 - (axis ?? 0)) }
            return (x1 + 36, false, width - x1 - 48)
        }
        let left = min(x1, x2) + 12
        return (left, false, width - left - 12)
    }

    func textAnchor(_ step: MechStep) -> (x: CGFloat, right: Bool, room: CGFloat)? {
        Self.textAnchor(step, columns: columns, rightmost: rightmost, axis: axis, width: width)
    }

    /// The y of a mechanism time: on a row at that row's time, in between proportionally.
    func y(at time: Double) -> CGFloat {
        guard let first = times.first, !rows.isEmpty else { return Self.firstRow }
        if time <= first { return rows[0] - CGFloat(first - time) * Self.pointsPerSecond }
        guard let i = times.lastIndex(where: { $0 <= time }) else { return rows[0] }
        if i == times.count - 1 { return rows[i] + CGFloat(time - times[i]) * Self.pointsPerSecond }
        let j = i + 1
        return rows[i] + CGFloat((time - times[i]) / (times[j] - times[i])) * (rows[j] - rows[i])
    }

    /// Where the "now" line is: it eases from one row to the next as the clock runs and the arrow flies.
    func nowY(_ position: Double, schedule: SimHowSchedule) -> CGFloat {
        guard !rows.isEmpty else { return Self.firstRow }
        if position >= schedule.end { return rows[rows.count - 1] }
        let phase = schedule.phase(at: position)
        let from = phase.k < 0 ? Self.firstRow - 22 : rows[phase.k]
        let to = rows[phase.k + 1]
        let leg = schedule.legs[phase.k + 1]
        let moving = leg.gap + leg.travel
        let done = moving <= 0 ? 1 : (phase.gap * leg.gap + phase.travel * leg.travel) / moving
        let eased = done * done * (3 - 2 * done)
        return from + (to - from) * eased
    }

    func row(near y: CGFloat) -> Int? {
        guard let nearest = rows.indices.min(by: { abs(rows[$0] - y) < abs(rows[$1] - y) }) else { return nil }
        return abs(rows[nearest] - y) <= Self.rowHeight * 0.6 ? nearest : nil
    }
}

/// The participants' header boxes, above the scrolling diagram. Linked ones select their node.
@MainActor
struct SimHowHeader: View {
    let mechanism: Mechanism
    let layout: SimHowLayout
    let sim: Simulation
    let active: Set<String>
    let select: (StageSelection?) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let axis = layout.axis {
                Text("time").font(Theme.ui(10, .medium)).foregroundStyle(Theme.faint)
                    .position(x: axis - 22, y: 24)
            }
            ForEach(mechanism.participants) { participant in
                if let x = layout.columns[participant.id] {
                    SimHowParticipant(participant: participant, node: participant.node.flatMap(sim.level.node),
                                      active: active.contains(participant.id), select: select)
                        .frame(maxWidth: max(70, columnSpacing - 10))
                        .fixedSize()
                        .position(x: x, y: 24)
                }
            }
        }
        .frame(width: layout.width, height: 48)
    }

    private var columnSpacing: CGFloat {
        let xs = layout.columns.values.sorted()
        return zip(xs, xs.dropFirst()).map { $1 - $0 }.min() ?? 200
    }
}

@MainActor
private struct SimHowParticipant: View {
    let participant: Participant
    let node: Node?
    let active: Bool
    let select: (StageSelection?) -> Void
    @State private var hovered = false

    var body: some View {
        let kind = node?.kind ?? participant.kind ?? .service
        let tint = Node(id: participant.id, kind: kind).simTint
        let content = HStack(spacing: 6) {
            Image(systemName: node?.icon ?? kind.symbol)
                .font(Theme.ui(10, .semibold)).foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 0) {
                Text(participant.label).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if let node {
                    HStack(spacing: 3) {
                        Text(node.label).lineLimit(1)
                        Image(systemName: "arrow.up.forward").font(Theme.ui(7, .bold))
                    }
                    .font(Theme.mono(9.5)).foregroundStyle(hovered ? Theme.accent : Theme.faint)
                }
            }
        }
        .padding(.leading, 5).padding(.trailing, 9).padding(.vertical, 4)
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
    let cache: SimHowTextCache

    func draw(_ context: GraphicsContext, size: CGSize) {
        let current = schedule.current(at: position)
        let flight = schedule.flight(at: position)
        drawBranchBand(context)
        if let axis = layout.axis { drawAxis(context, axis: axis, now: layout.nowY(position, schedule: schedule)) }
        drawLifelines(context, size: size)
        if current >= 0, current < layout.rows.count {
            let y = layout.rows[current]
            let band = CGRect(x: 6, y: y - 26, width: size.width - 12, height: 50)
            context.fill(Path(roundedRect: band, cornerRadius: 8), with: .color(Theme.accent.opacity(0.055)))
        }
        if let hoveredRow, hoveredRow != current, hoveredRow < layout.rows.count {
            let y = layout.rows[hoveredRow]
            context.fill(Path(roundedRect: CGRect(x: 6, y: y - 26, width: size.width - 12, height: 50), cornerRadius: 8),
                         with: .color(Theme.hover))
        }
        if layout.axis != nil { drawDeadlines(context, size: size) }
        drawNow(context, size: size)
        for (index, frame) in playback.frames.enumerated() {
            let emphasis: SimHowRowEmphasis = index == current ? .active : index < current ? .past : .future
            drawStep(frame, index: index, emphasis: emphasis, in: context, size: size)
        }
        if let flight { drawToken(flight.step, progress: flight.progress, in: context) }
    }

    // MARK: Background

    private func drawBranchBand(_ context: GraphicsContext) {
        guard let start = playback.branchStart, start < layout.rows.count else { return }
        let top = layout.rows[start] - 28
        let bottom = (layout.rows.last ?? top) + 28
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
        for (index, time) in layout.times.enumerated() where seen.insert(time).inserted {
            let y = layout.rows[index]
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

    /// Where each live TTL would run out, if nothing renews it.
    private func drawDeadlines(_ context: GraphicsContext, size: CGSize) {
        let k = Int(floor(min(schedule.end, max(-1, position)) + 1e-9))
        let now = schedule.time(at: position)
        let state = playback.state(after: k, at: now)
        guard let axis = layout.axis else { return }
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
            let label = cache.text("deadline-\(key.key)-\(when)", in: context) {
                Text("\(Image(systemName: "hourglass.bottomhalf.filled")) \(key.key) expires at \(when)")
                    .font(Theme.mono(9.5)).foregroundStyle(color)
            }
            let size = label.measure(in: CGSize(width: 400, height: 20))
            let box = CGRect(x: self.layout.width - 14 - size.width - 8, y: y - 8, width: size.width + 8, height: 15)
            context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(Theme.surface))
            context.draw(label, at: CGPoint(x: box.midX, y: box.midY))
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
        let y = layout.rows[index]
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

        // Label above, command → reply below. Self-loops put both beside the loop.
        guard let anchor = layout.textAnchor(step) else { return }
        let textLeft = anchor.x, anchorRight = anchor.right, room = anchor.room
        let opacity = emphasis == .future ? 0.42 : 1
        var faded = context
        faded.opacity = opacity
        let label = fitted("label-\(index)-\(emphasis)", step.label, room: room, in: context) { value in
            Text(verbatim: value)
                .font(Theme.ui(12, emphasis == .active ? .semibold : .medium))
                .foregroundStyle(emphasis == .active ? Theme.text : Theme.text.opacity(0.82))
        }
        let labelY = selfStep ? y - 9 : y - 7
        faded.draw(label, at: CGPoint(x: textLeft, y: labelY), anchor: anchorRight ? .bottomTrailing : .bottomLeading)
        guard step.command != nil || step.reply != nil else { return }
        let chipY = selfStep ? y + 5 : y + 6
        if layout.wrapped.contains(index), let command = step.command, let reply = step.reply {
            // Too long for one line: the command, then the reply under it, so the reply is never cut off.
            let first = fitted("cmd-\(index)", command, room: room - 12, in: context) { commandText($0, step: step) }
            let second = fitted("reply-\(index)", "\u{0}" + reply, room: room - 12, in: context) { commandText($0, step: step) }
            chipBox(first, top: chipY, left: textLeft, right: anchorRight, room: room, emphasis: emphasis, in: faded)
            chipBox(second, top: chipY + SimHowLayout.secondLine, left: textLeft, right: anchorRight, room: room, emphasis: emphasis, in: faded)
        } else {
            let chip = fitted("chip-\(index)", chipText(step), room: room - 12, in: context) { commandText($0, step: step) }
            chipBox(chip, top: chipY, left: textLeft, right: anchorRight, room: room, emphasis: emphasis, in: faded)
        }
    }

    private func chipBox(_ chip: GraphicsContext.ResolvedText, top: CGFloat, left: CGFloat, right: Bool, room: CGFloat,
                         emphasis: SimHowRowEmphasis, in context: GraphicsContext) {
        let measured = chip.measure(in: CGSize(width: max(10, room), height: 20))
        let box = CGRect(x: right ? left - measured.width - 12 : left - 6, y: top, width: measured.width + 12, height: 18)
        context.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(Theme.raised))
        context.stroke(Path(roundedRect: box, cornerRadius: 5), with: .color(emphasis == .active ? Theme.accent.opacity(0.4) : Theme.border), lineWidth: 1)
        context.draw(chip, at: CGPoint(x: box.minX + 6, y: box.midY), anchor: .leading)
    }

    private func chipText(_ step: MechStep) -> String {
        switch (step.command, step.reply) {
        case let (command?, reply?): "\(command)\u{0}\(reply)"
        case let (command?, nil): command
        case let (nil, reply?): "\u{0}\(reply)"
        default: ""
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

    /// A Text that fits `room`, cut short with an ellipsis when it doesn't.
    private func fitted(_ key: String, _ raw: String, room: CGFloat, in context: GraphicsContext,
                        _ make: (String) -> Text) -> GraphicsContext.ResolvedText {
        let width = max(24, room)
        return cache.text("\(key)|\(raw)|\(Int(width))", in: context) {
            let full = context.resolve(make(raw))
            guard full.measure(in: CGSize(width: CGFloat.infinity, height: 30)).width > width else { return make(raw) }
            var low = 0, high = raw.count
            while low < high {
                let mid = (low + high + 1) / 2
                let candidate = String(raw.prefix(mid)) + "…"
                if context.resolve(make(candidate)).measure(in: CGSize(width: CGFloat.infinity, height: 30)).width <= width { low = mid } else { high = mid - 1 }
            }
            return make(String(raw.prefix(low)) + "…")
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
        guard index < playback.frames.count else { return }
        let step = playback.frames[index].step
        guard let x1 = layout.columns[step.from], let x2 = layout.columns[step.to] else { return }
        let y = layout.rows[index]
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

    /// The running clock: one decimal for seconds; whole milliseconds for a sequence that lives below a second.
    static func clock(_ seconds: Double, short: Bool = false) -> String {
        if short { return "\(Int((seconds * 1000).rounded())) ms" }
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
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var hoveredRow: Int?
    @State private var viewport: CGFloat = 400

    var body: some View {
        GeometryReader { proxy in
            let layout = SimHowLayout(playback: player.playback, participants: player.mechanism.participants, width: proxy.size.width)
            VStack(spacing: 0) {
                SimHowHeader(mechanism: player.mechanism, layout: layout, sim: sim, active: activeParticipants, select: select)
                Rectangle().fill(Theme.border).frame(height: 1)
                if still {
                    canvas(layout)
                        .frame(height: layout.height)
                        .offset(y: -scrollTarget(layout, viewport: proxy.size.height - 49))
                        .frame(height: max(0, proxy.size.height - 49), alignment: .top)
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
        TimelineView(.animation(paused: !player.playing || still)) { tick in
            let position = player.position(at: tick.date)
            Canvas { context, size in
                SimHowCanvasPainter(playback: player.playback, schedule: player.schedule, layout: layout, position: position,
                                    keyColors: keyColors, hoveredRow: hoveredRow, cache: cache)
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
        .gesture(SpatialTapGesture().onEnded { event in
            if let row = layout.row(near: event.location.y) { player.seek(to: Double(row)) }
        })
        .accessibilityElement()
        .accessibilityLabel("Sequence diagram, step \(max(0, player.shown) + 1) of \(player.playback.frames.count)")
    }

    /// Keeps the current step in the upper part of the view.
    private func scrollTarget(_ layout: SimHowLayout, viewport: CGFloat) -> CGFloat {
        let index = max(0, player.shown)
        guard index < layout.rows.count else { return 0 }
        let wanted = layout.rows[index] - viewport * 0.45
        return min(max(0, layout.height - viewport), max(0, wanted))
    }

    private func follow(_ layout: SimHowLayout) {
        let y = scrollTarget(layout, viewport: viewport)
        withAnimation(Theme.gentle) { scroll.scrollTo(y: y) }
    }
}
