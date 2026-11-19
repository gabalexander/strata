import Foundation

// Playing a mechanism (docs/manifest.md, How it works): the ordered steps of a path with the state
// after each one, TTLs aged by `at`. Additive helpers next to the contract types; the validator, the
// CLI (`strata how`) and the player UI all replay a sequence the same way.

/// A key that exists at some moment of the sequence.
public struct MechKey: Sendable, Hashable {
    public var key: String
    public var value: String
    /// Seconds left before it expires; nil when it has no TTL.
    public var ttl: Double?
    /// The TTL it was last set or renewed with, for drawing how much of it is left.
    public var span: Double?

    public init(key: String, value: String, ttl: Double? = nil, span: Double? = nil) {
        self.key = key; self.value = value; self.ttl = ttl; self.span = span
    }

    /// The share of its TTL still left, 0...1; nil without a TTL.
    public var remaining: Double? {
        guard let ttl, let span, span > 0 else { return nil }
        return min(1, max(0, ttl / span))
    }
}

/// What one step did to one key.
public struct MechChange: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// Created, or given a new value.
        case set
        /// Same value, new TTL (a heartbeat).
        case renew
        /// Removed by the step (`value: null`).
        case delete
        /// Its TTL ran out before the step.
        case expire
    }

    public var key: String
    public var kind: Kind
    public init(key: String, kind: Kind) { self.key = key; self.kind = kind }
}

/// One played step: where it sits in the path, when it happens, and the state after it.
public struct MechFrame: Sendable {
    /// Position in the path, from 0.
    public var index: Int
    public var step: MechStep
    /// The branch this step belongs to; nil on the main sequence.
    public var branch: String?
    /// Seconds since the start: the step's `at`, or the time of the step before it.
    public var time: Double
    /// Every key after the step, in the order keys first appeared.
    public var state: [MechKey]
    /// Expiries first (TTLs that ran out before the step), then what the step itself changed.
    public var changes: [MechChange]

    public func change(of key: String) -> MechChange.Kind? { changes.last { $0.key == key }?.kind }
}

/// A mechanism played along one path: the main sequence, or the main sequence up to a branch point
/// followed by that branch.
public struct MechPlayback: Sendable {
    public let mechanism: Mechanism
    public let branch: MechBranch?
    public let initial: [MechKey]
    public let frames: [MechFrame]
    /// Index of the first branch frame; nil on the main sequence.
    public let branchStart: Int?
    /// Any step has `at`, so the sequence has a timeline.
    public let timed: Bool

    public var duration: Double { frames.last?.time ?? 0 }

    /// The keys after frame `index` (-1: the initial state) aged to `time`, and the keys whose TTL
    /// ran out between that frame and `time`.
    public func state(after index: Int, at time: Double) -> (keys: [MechKey], expired: [String]) {
        let base = index < 0 ? initial : frames[min(index, frames.count - 1)].state
        let since = index < 0 ? 0 : frames[min(index, frames.count - 1)].time
        return MechPlayback.age(base, by: time - since)
    }

    /// The time of frame `index` (-1: the start).
    public func time(of index: Int) -> Double {
        index < 0 ? 0 : frames[min(index, frames.count - 1)].time
    }

    static func age(_ keys: [MechKey], by elapsed: Double) -> (keys: [MechKey], expired: [String]) {
        guard elapsed > 0 else { return (keys, []) }
        var live: [MechKey] = []
        var expired: [String] = []
        for var key in keys {
            if let ttl = key.ttl {
                let left = ttl - elapsed
                if left <= 1e-9 { expired.append(key.key); continue }
                key.ttl = left
            }
            live.append(key)
        }
        return (live, expired)
    }
}

public extension Mechanism {
    func branch(_ id: String) -> MechBranch? { branches.first { $0.id == id } }

    /// Any step of the main sequence or a branch has `at`.
    var timed: Bool { steps.contains { $0.at != nil } || branches.contains { $0.steps.contains { $0.at != nil } } }

    /// The steps of a path: the main sequence, or (with a branch id) the main sequence up to and including
    /// the branch's `after` step, then the branch. nil for an unknown branch.
    func path(branch id: String? = nil) -> (steps: [(step: MechStep, branch: String?)], branchStart: Int?)? {
        guard let id else { return (steps.map { ($0, nil) }, nil) }
        guard let branch = self.branch(id) else { return nil }
        var prefix: [MechStep] = []
        if let after = branch.after {
            guard let end = steps.firstIndex(where: { $0.id == after }) else { return nil }
            prefix = Array(steps[...end])
        }
        return (prefix.map { ($0, nil) } + branch.steps.map { ($0, id) }, prefix.count)
    }

    /// Plays a path: each step with the cumulative state after it. Between steps every TTL counts down
    /// by the time that passed (`at`); a key whose TTL runs out is gone before the next step applies.
    /// Time never goes backwards: an `at` earlier than the step before it plays at that earlier step's time.
    func play(branch id: String? = nil) -> MechPlayback? {
        guard let path = path(branch: id) else { return nil }
        var state: [MechKey] = []
        _ = Self.apply(initial, to: &state)
        let initialState = state
        var time = 0.0
        var frames: [MechFrame] = []
        for (index, item) in path.steps.enumerated() {
            let next = max(time, item.step.at ?? time)
            let aged = MechPlayback.age(state, by: next - time)
            state = aged.keys
            time = next
            var changes = aged.expired.map { MechChange(key: $0, kind: .expire) }
            changes += Self.apply(item.step.state, to: &state)
            frames.append(MechFrame(index: index, step: item.step, branch: item.branch, time: time, state: state, changes: changes))
        }
        return MechPlayback(mechanism: self, branch: id.flatMap { self.branch($0) }, initial: initialState, frames: frames,
                            branchStart: path.branchStart, timed: timed)
    }

    /// Applies state entries in order and returns what each one changed.
    private static func apply(_ entries: [StateEntry], to state: inout [MechKey]) -> [MechChange] {
        var changes: [MechChange] = []
        for entry in entries {
            let index = state.firstIndex { $0.key == entry.key }
            guard let value = entry.value else {
                if let index {
                    state.remove(at: index)
                    changes.append(MechChange(key: entry.key, kind: .delete))
                }
                continue
            }
            let key = MechKey(key: entry.key, value: value, ttl: entry.ttl, span: entry.ttl)
            if let index {
                let renew = state[index].value == value && entry.ttl != nil
                state[index] = key
                changes.append(MechChange(key: entry.key, kind: renew ? .renew : .set))
            } else {
                state.append(key)
                changes.append(MechChange(key: entry.key, kind: .set))
            }
        }
        return changes
    }
}

public extension Formula {
    /// Whether `name` appears in `expr` as a symbol of its own: not inside a longer name, though it may
    /// carry a subscript or a superscript (`w` in `w_r`, `x` in `x^2`).
    func mentions(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        func isNameCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var search = expr.startIndex..<expr.endIndex
        while let range = expr.range(of: name, range: search) {
            let before = range.lowerBound == expr.startIndex ? nil : expr[expr.index(before: range.lowerBound)]
            let after = range.upperBound == expr.endIndex ? nil : expr[range.upperBound]
            let startsClean = before.map { !isNameCharacter($0) } ?? true
            let endsClean = after.map { !($0.isLetter || $0.isNumber) } ?? true
            if startsClean && endsClean { return true }
            search = expr.index(after: range.lowerBound)..<expr.endIndex
        }
        return false
    }
}

/// Where a mechanism is described: a node, or an operation of a node, on some level.
public struct MechanismSite: Sendable {
    /// The level path (`[]` for the root, `orders`, `orders#insert-order`), as `Manifest.level(at:)` takes it.
    public var path: [String]
    public var node: String
    public var op: String?
    public var mechanism: Mechanism

    /// `node` or `node/op`.
    public var owner: String { op.map { "\(node)/\($0)" } ?? node }
}

public extension Manifest {
    /// Every mechanism on every level, in document order (a level's nodes before its deep dives).
    func mechanisms() -> [MechanismSite] {
        var sites: [MechanismSite] = []
        func walk(_ level: Level, path: [String]) {
            for node in level.nodes {
                sites += node.how.map { MechanismSite(path: path, node: node.id, op: nil, mechanism: $0) }
                for op in node.ops {
                    sites += op.how.map { MechanismSite(path: path, node: node.id, op: op.id, mechanism: $0) }
                }
            }
            for node in level.nodes {
                if let inside = node.inside { walk(inside, path: path + [node.id]) }
                for op in node.ops { if let inside = op.inside { walk(inside, path: path + ["\(node.id)#\(op.id)"]) } }
            }
        }
        walk(root, path: [])
        return sites
    }
}
