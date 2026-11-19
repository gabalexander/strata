import AppKit
import Foundation
import Observation
import SwiftUI
import StrataCore

/// Which mechanism a player shows: one of a node's, or one of an operation's.
struct SimHowRef: Hashable {
    let node: String
    let op: String?
    let mechanism: String
}

/// The open mechanism player, one per session. It stays open while the stage selection changes, so a
/// participant can select its node behind the panel.
@MainActor
@Observable
final class SimHowState {
    private(set) var player: SimHowPlayer?
    /// A click on a node's ƒ badge asks the inspector to bring the formula section into view.
    private(set) var reveal: SimScrollTarget?
    /// The data UI's scroll request when the reveal was asked for: a newer one of those wins.
    @ObservationIgnored private var revealOver: UUID?

    private init() {}

    func revealFormula(of node: String, over data: SimScrollTarget?) {
        reveal = SimScrollTarget(id: "formula", anchor: .top, context: AnyHashable(StageSelection.node(node)), animated: false)
        revealOver = data?.request
    }

    /// Where the inspector scrolls next: a formula reveal, unless the data UI asked for something since.
    func scrollTarget(over data: SimScrollTarget?) -> SimScrollTarget? {
        guard let reveal, data?.request == revealOver else { return data }
        return reveal
    }

    private static let stores = NSMapTable<Simulation, SimHowState>.weakToStrongObjects()

    static func of(_ sim: Simulation) -> SimHowState {
        if let store = stores.object(forKey: sim) { return store }
        let store = SimHowState()
        stores.setObject(store, forKey: sim)
        return store
    }

    func open(_ mechanism: Mechanism, ref: SimHowRef, owner: String, branch: String? = nil, autoplay: Bool = true) {
        guard let player = SimHowPlayer(mechanism: mechanism, ref: ref, owner: owner, branch: branch) else { return }
        self.player = player
        if autoplay { player.play() }
    }

    func close() {
        player?.pause()
        player = nil
    }

    /// Escape closes; Space plays or pauses; ← and → step; Home restarts. False when no player is open
    /// or the key isn't one of these.
    func key(_ event: NSEvent) -> Bool {
        guard let player else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 53: close()
        case 49: if !event.isARepeat { player.toggle() }
        case 123: player.step(-1)
        case 124: player.step(1)
        case 115: player.restart()
        case 119: player.seek(to: Double(player.playback.frames.count - 1))
        default: return false
        }
        return true
    }
}

/// Real-time pacing of a playback: each move from one step to the next dwells on the state just
/// applied, lets the mechanism clock run through the `at` gap (TTLs count down), then flies the arrow.
/// A position is a step index with a fraction: 2 is "step 3 done", 2.5 is halfway to step 4, -1 the
/// initial state.
struct SimHowSchedule {
    struct Leg {
        let dwell: Double
        let gap: Double
        let travel: Double
        var total: Double { dwell + gap + travel }
    }

    /// `legs[k + 1]` leads from position k to k + 1.
    let legs: [Leg]
    let times: [Double]

    static let travel = 0.75

    init(_ playback: MechPlayback) {
        times = playback.frames.map(\.time)
        var previous = 0.0
        let gaps = times.map { time -> Double in
            defer { previous = time }
            return time - previous
        }
        let positive = gaps.filter { $0 > 0 }.sorted()
        // About 1.5 s of real time for a typical gap, so heartbeats 5 s apart read as a rhythm.
        let median = positive.isEmpty ? 1 : positive[positive.count / 2]
        let rate = median / 1.5
        legs = gaps.enumerated().map { index, gap in
            let real = gap > 0 ? min(3.4, max(0.45, gap / rate)) : 0
            return Leg(dwell: index == 0 ? 0.25 : 0.6, gap: real, travel: Self.travel)
        }
    }

    var end: Double { Double(legs.count - 1) }

    /// The position after `seconds` of real time at `speed`.
    func advance(_ position: Double, by seconds: Double) -> Double {
        var position = min(end, max(-1, position))
        var left = seconds
        while left > 0, position < end {
            let k = Int(floor(position))
            let leg = legs[k + 1]
            let remaining = (Double(k + 1) - position) * leg.total
            if left < remaining { return position + left / leg.total }
            left -= remaining
            position = Double(k + 1)
        }
        return position
    }

    /// Where a position is within its leg.
    func phase(at position: Double) -> (k: Int, dwell: Double, gap: Double, travel: Double) {
        let clamped = min(end, max(-1, position))
        let k = min(Int(floor(clamped)), legs.count - 2)
        guard k + 1 < legs.count, k + 1 >= 0 else { return (k, 1, 1, 1) }
        let leg = legs[k + 1]
        let t = (clamped - Double(k)) * leg.total
        func part(_ start: Double, _ length: Double) -> Double {
            length <= 0 ? (t >= start ? 1 : 0) : min(1, max(0, (t - start) / length))
        }
        return (k, part(0, leg.dwell), part(leg.dwell, leg.gap), part(leg.dwell + leg.gap, leg.travel))
    }

    /// The mechanism clock at a position: it runs only through each gap.
    func time(at position: Double) -> Double {
        guard !times.isEmpty else { return 0 }
        if position >= end { return times[times.count - 1] }
        let p = phase(at: position)
        let from = p.k < 0 ? 0 : times[p.k]
        let to = times[p.k + 1]
        return from + (to - from) * p.gap
    }

    /// The step whose arrow is in flight, with its progress 0...1.
    func flight(at position: Double) -> (step: Int, progress: Double)? {
        guard position < end else { return nil }
        let p = phase(at: position)
        guard p.travel > 0, p.travel < 1 else { return nil }
        return (p.k + 1, p.travel)
    }

    /// The step to highlight: the one in flight, else the last one done (-1 before the first).
    func current(at position: Double) -> Int {
        if let flight = flight(at: position) { return flight.step }
        return Int(floor(min(end, max(-1, position)) + 1e-9))
    }

    /// Real seconds (at 1×) since the last step done at `position` landed.
    func sinceLanding(at position: Double) -> Double {
        let clamped = min(end, max(-1, position))
        let k = Int(floor(clamped + 1e-9))
        guard k + 1 < legs.count else { return 0 }
        return max(0, clamped - Double(k)) * legs[k + 1].total
    }
}

/// One open player: a mechanism, the chosen path, and where playback is.
@MainActor
@Observable
final class SimHowPlayer {
    let ref: SimHowRef
    let mechanism: Mechanism
    let owner: String
    private(set) var branch: String?
    private(set) var playback: MechPlayback
    private(set) var schedule: SimHowSchedule
    /// The position playback is anchored at; while playing it moves on from `anchor`.
    private(set) var cursor: Double = -1
    private(set) var anchor: Date?
    /// The step the notes and the step list show. Updated when playback crosses a step, never per frame.
    private(set) var shown: Int = -1
    var speed: Double = 1 {
        didSet { if let anchor { cursor = schedule.advance(cursor, by: Date().timeIntervalSince(anchor) * oldValue); self.anchor = Date() } }
    }

    var playing: Bool { anchor != nil }
    var atEnd: Bool { cursor >= schedule.end && anchor == nil }

    init?(mechanism: Mechanism, ref: SimHowRef, owner: String, branch: String?) {
        guard let playback = mechanism.play(branch: branch), !playback.frames.isEmpty else { return nil }
        self.mechanism = mechanism
        self.ref = ref
        self.owner = owner
        self.branch = branch
        self.playback = playback
        schedule = SimHowSchedule(playback)
    }

    /// The live position at `date`.
    func position(at date: Date) -> Double {
        guard let anchor else { return cursor }
        return schedule.advance(cursor, by: max(0, date.timeIntervalSince(anchor)) * speed)
    }

    /// Called by the player's timeline on each frame while playing: moves `shown` when a step lands and
    /// stops at the end.
    func sync(at date: Date) {
        let position = position(at: date)
        let current = schedule.current(at: position)
        if current != shown { shown = current }
        if position >= schedule.end, anchor != nil {
            cursor = schedule.end
            anchor = nil
        }
    }

    func play() {
        guard anchor == nil else { return }
        if cursor >= schedule.end { cursor = -1 }
        anchor = Date()
    }

    func pause() {
        guard anchor != nil else { return }
        cursor = position(at: Date())
        anchor = nil
        shown = schedule.current(at: cursor)
    }

    func toggle() { playing ? pause() : play() }

    /// To the next or previous step, paused there.
    func step(_ direction: Int) {
        let position = position(at: Date())
        anchor = nil
        let target = direction > 0 ? floor(position + 1e-9) + 1 : ceil(position - 1e-9) - 1
        seek(to: target)
    }

    func seek(to position: Double) {
        let clamped = min(schedule.end, max(-1, position))
        cursor = clamped
        if anchor != nil { anchor = Date() }
        shown = schedule.current(at: clamped)
    }

    func restart() {
        seek(to: -1)
        if anchor == nil { play() }
    }

    /// Switches the path and replays from the step the branch leaves after (the start for the main sequence).
    func choose(branch id: String?) {
        guard let next = mechanism.play(branch: id), !next.frames.isEmpty else { return }
        let resume: Double
        if let id, let after = mechanism.branch(id)?.after, let index = next.frames.firstIndex(where: { $0.step.id == after && $0.branch == nil }) {
            resume = Double(index)
        } else if id == nil, let previous = branch, let after = mechanism.branch(previous)?.after,
                  let index = next.frames.firstIndex(where: { $0.step.id == after }) {
            resume = Double(index)
        } else {
            resume = -1
        }
        branch = id
        playback = next
        schedule = SimHowSchedule(next)
        cursor = resume
        shown = schedule.current(at: resume)
        anchor = Date()
    }
}

/// Offscreen snapshots: open a mechanism at a step, and hover a node's formula.
@_spi(Snapshots) @MainActor
public enum SimHowSnapshot {
    /// Opens the player paused with `step` (1-based in the path; 0 is the initial state) landed.
    /// `progress` moves on toward the next step, 0...1.
    public static func open(_ sim: Simulation, node: String, op: String? = nil, mechanism: String, branch: String? = nil,
                            step: Int, progress: Double = 0) {
        guard let owner = sim.level.node(node) else { return }
        let list = op.flatMap { id in owner.ops.first { $0.id == id }?.how } ?? owner.how
        guard let found = list.first(where: { $0.id == mechanism }) else { return }
        let state = SimHowState.of(sim)
        state.open(found, ref: SimHowRef(node: node, op: op, mechanism: mechanism), owner: owner.label, branch: branch, autoplay: false)
        state.player?.seek(to: Double(step - 1) + progress)
    }

    /// Shows the formula card of `node` as a hover after the delay would, once the stage is laid out.
    public static func hoverFormula(_ sim: Simulation, node: String) {
        SimFormulaStage.requested[ObjectIdentifier(sim)] = node
    }
}

@_spi(Snapshots) extension SimHowSnapshot {
    /// The open player's state panel on its own.
    public static func statePanel(_ sim: Simulation) -> AnyView {
        guard let player = SimHowState.of(sim).player else { return AnyView(EmptyView()) }
        let keys = player.playback.initial.map(\.key) + player.playback.frames.flatMap { $0.state.map(\.key) }
        var order: [String] = []
        for key in keys where !order.contains(key) { order.append(key) }
        let palette = [Theme.token(5), Theme.token(1), Theme.token(3), Theme.token(2), Theme.token(4), Theme.token(6)]
        let colors = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, palette[$0 % palette.count]) })
        return AnyView(SimHowStatePanel(player: player, keyColors: colors, still: true)
            .background(Theme.surface)
            .foregroundStyle(Theme.text))
    }

    /// Formulas typeset one under another, each with its `where` table and example, at inspector width.
    public static func formulas(_ formulas: [(title: String, formula: Formula)]) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(formulas.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted)
                    SimFormulaFit(expr: item.formula.expr, sizes: [19, 16, 14])
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .card()
                    if !item.formula.vars.isEmpty { SimFormulaWhere(vars: item.formula.vars) }
                    if let example = item.formula.example { SimFormulaExample(text: example) }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .foregroundStyle(Theme.text))
    }
}
