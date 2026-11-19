import Foundation

// Validation of node `ops:` and step `op:` references (docs/manifest.md, Operations).
extension LevelValidation {
    /// Node kinds that naturally serve an op of this kind when it has no target.
    private static let servedBy: [OpKind: Set<NodeKind>] = [
        .sql: [.database, .search, .vector], .search: [.search, .database, .vector], .cache: [.cache],
        .publish: [.queue, .topic], .storage: [.store], .llm: [.llm],
    ]

    private static func article(_ kind: OpKind) -> String {
        [.rpc, .http, .llm].contains(kind) ? "an" : "a"
    }

    func ops(of node: Node, at field: Field) {
        for (op, location) in zip(node.ops, field["ops"].items(named: true)) {
            operation(op, on: node, at: location)
        }
    }

    private func operation(_ op: Operation, on node: Node, at field: Field) {
        let kind = op.kind.rawValue
        let fits = OpFields.byKind[op.kind] ?? []
        for key in field.node?.fields?.map(\.key) ?? [] where OpFields.all.contains(key) {
            guard !OpFields.common.contains(key), !fits.contains(key) else { continue }
            field[key].diagnose("'\(key)' does not apply to \(Self.article(op.kind)) \(kind) op; use it on \(OpFields.kinds(using: key)) ops", .warning)
        }

        let explicitDirection = field["direction"].present
        if let target = op.target {
            if target == node.id {
                field["target"].diagnose("an op cannot target its own node; name the node it talks to", .warning)
            } else if let other = nodes[target] {
                targetFit(op, other, at: field["target"])
                opTables(op, in: other, at: field["tables"])
                if !edges.contains("\(node.id)->\(target)"), !edges.contains("\(target)->\(node.id)") {
                    field["target"].diagnose("no edge connects '\(node.id)' and '\(target)'; declare it in edges", .warning)
                }
            } else {
                field["target"].diagnose("unknown node '\(target)'\(suggestion(target, among: nodes.keys))")
            }
            if op.direction == .inbound, op.kind != .consume {
                field["direction"].diagnose("an inbound op has no target; remove target or set direction: out", .warning)
            }
        } else if !explicitDirection, let served = Self.servedBy[op.kind], !served.contains(node.kind) {
            field.diagnose("\(Self.article(op.kind)) \(kind) op without a target reads as served by '\(node.id)'; set target to the node it talks to, or direction: out when that node is not on this level", .warning)
        }
        if op.kind == .consume, op.target == nil, op.topic == nil {
            field.diagnose("a consume op names its buffer in target or topic", .warning)
        }
        if let reference = op.calls { calls(reference, from: op, at: field["calls"]) }
        query(of: op, at: field)
    }

    private func targetFit(_ op: Operation, _ target: Node, at field: Field) {
        let kind = target.kind
        guard kind != .port else { return }
        let good: Bool
        let expected: String
        switch op.kind {
        case .sql:
            good = [.database, .search].contains(kind); expected = "a database or search node"
        case .search:
            good = [.search, .database, .vector].contains(kind); expected = "a search, database or vector node"
        case .cache:
            good = kind == .cache; expected = "a cache"
        case .publish, .consume:
            good = kind.role == .buffer; expected = "a queue or topic"
        case .rpc, .http, .call:
            good = kind.role == .server && ![.database, .cache].contains(kind); expected = "a server such as a service, gateway or external API"
        case .storage:
            good = kind == .store; expected = "a store"
        case .llm:
            good = [.llm, .external, .gateway, .service, .function].contains(kind); expected = "an llm, external or service node"
        }
        guard !good else { return }
        let opKind = "\(Self.article(op.kind)) \(op.kind.rawValue) op"
        if kind.role != .server || [.publish, .consume].contains(op.kind) {
            field.diagnose("\(opKind) cannot target '\(target.id)', a \(kind.rawValue); target \(expected)")
        } else {
            field.diagnose("\(opKind) usually targets \(expected); '\(target.id)' is a \(kind.rawValue)", .warning)
        }
    }

    private func calls(_ reference: String, from op: Operation, at field: Field) {
        let parts = reference.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return }
        let owner = parts[0], id = parts[1]
        guard let reached = lookup(id, on: owner, at: field) else { return }
        if op.direction == .inbound {
            field.diagnose("calls links an outbound op to the op it reaches; '\(op.id)' is inbound", .warning)
        } else if reached.direction == .outbound {
            field.diagnose("'\(reference)' is an outbound op; calls should name the inbound op it reaches", .warning)
        }
        if op.kind == .publish {
            if reached.kind != .consume {
                field.diagnose("a publish reaches a consume op; '\(reference)' is \(Self.article(reached.kind)) \(reached.kind.rawValue) op", .warning)
            }
        } else if let target = op.target, target != owner, nodes[target]?.kind != .port {
            field.diagnose("calls names an op on '\(owner)' but the target is '\(target)'", .warning)
        }
    }

    /// The op `id` on node `owner`, diagnosing an unknown node or op at `field`.
    private func lookup(_ id: String, on owner: String, at field: Field) -> Operation? {
        guard let node = nodes[owner] else {
            field.diagnose("unknown node '\(owner)'\(suggestion(owner, among: nodes.keys))")
            return nil
        }
        if let op = node.ops.first(where: { $0.id == id }) { return op }
        let ids = node.ops.map(\.id)
        let fix = closestKey(to: id, in: ids).map { "; did you mean '\($0)'?" } ?? (ids.isEmpty ? "; '\(owner)' has no ops" : "")
        field.diagnose("unknown op '\(id)' on '\(owner)'\(fix)")
        return nil
    }

    /// Whether the node part of `node/op` names the ops of the node this level is inside: `..`, or the
    /// owner's id when no node of this level has it (`Level.resolveOp(_:caller:target:owner:)`).
    private func namesOwner(_ node: String) -> Bool {
        guard let owner else { return false }
        return node == InheritedOps.ownerKey || (node == owner.id && nodes[node] == nil)
    }

    /// The op `id` of the node this level is inside, diagnosing an unknown one at `field`.
    private func ownerLookup(_ id: String, at field: Field) -> Operation? {
        guard let owner else { return nil }
        if let op = owner.ops.first(where: { $0.id == id }) { return op }
        let fix = closestKey(to: id, in: owner.ops.map(\.id)).map { "; did you mean '\($0)'?" } ?? ""
        field.diagnose("unknown op '\(id)' on '\(owner.id)', the node this level is inside\(fix)")
        return nil
    }

    /// A flow's own `op:`: resolved on the node each run happens at (`by`, or `from`), or `node/op`.
    /// In a deep dive, an id that node doesn't have may name an op of the node the level is inside.
    func flowOp(_ flow: Flow, runsAt origin: String?, at field: Field) {
        guard let reference = flow.op else { return }
        let holder: String
        let op: Operation
        if reference.contains("/") {
            let parts = reference.split(separator: "/").map(String.init)
            if namesOwner(parts[0]) {
                guard let found = ownerLookup(parts[1], at: field) else { return }
                (holder, op) = (InheritedOps.ownerKey, found)
            } else {
                guard let found = lookup(parts[1], on: parts[0], at: field) else { return }
                (holder, op) = (parts[0], found)
            }
        } else if let owner, origin.flatMap({ nodes[$0] })?.ops.contains(where: { $0.id == reference }) != true,
                  let found = owner.ops.first(where: { $0.id == reference }) {
            (holder, op) = (InheritedOps.ownerKey, found)
        } else {
            guard let origin, let found = lookup(reference, on: origin, at: field) else { return }
            (holder, op) = (origin, found)
        }
        let named = "'\(reference)' is \(Self.article(op.kind)) \(op.kind.rawValue) op"
        if let buffer = flow.on {
            if op.kind != .consume {
                field.diagnose("\(named); a consumer flow performs a consume op", .warning)
            } else if holder != InheritedOps.ownerKey, let consumed = op.target, consumed != buffer, nodes[consumed]?.kind != .port {
                field.diagnose("'\(op.id)' consumes from '\(consumed)' but this flow is on '\(buffer)'", .warning)
            }
            if let by = flow.by, holder != by, holder != InheritedOps.ownerKey {
                field.diagnose("'\(reference)' belongs to '\(holder)'; a consumer flow's op belongs to its consumer '\(by)'", .warning)
            }
        } else if op.kind == .consume {
            field.diagnose("\(named); name it on a consumer flow (on + by)", .warning)
        }
    }

    func stepOp(_ step: Step, caller: String?, at field: Field) {
        guard let reference = step.op else { return }
        let location = field["op"]
        let target: String?
        switch step.action {
        case .call(let id, _, _), .publish(let id): target = id
        case .work, .parallel: target = nil
        }
        // The node that holds the op: the caller, the target, another node, or ".." for the node this
        // deep-dive level is inside.
        let owner: String
        let op: Operation
        if reference.contains("/") {
            let parts = reference.split(separator: "/").map(String.init)
            if namesOwner(parts[0]) {
                guard let found = ownerLookup(parts[1], at: location) else { return }
                owner = InheritedOps.ownerKey
                op = found
            } else {
                guard let found = lookup(parts[1], on: parts[0], at: location) else { return }
                owner = parts[0]
                op = found
            }
        } else {
            var candidates: [String] = []
            for id in [caller, target].compactMap({ $0 }) where nodes[id] != nil && !candidates.contains(id) {
                candidates.append(id)
            }
            guard !candidates.isEmpty || self.owner != nil else { return }
            guard let resolved = level.resolveOp(reference, caller: caller, target: target, owner: self.owner) else {
                let ids = candidates.flatMap { nodes[$0]?.ops.map(\.id) ?? [] } + (self.owner?.ops.map(\.id) ?? [])
                let fix = closestKey(to: reference, in: ids).map { "; did you mean '\($0)'?" } ?? ""
                let places = candidates.map { "'\($0)'" } + (self.owner.map { ["'\($0.id)', the node this level is inside"] } ?? [])
                location.diagnose("unknown op '\(reference)' on \(places.joined(separator: " or "))\(fix)")
                return
            }
            (owner, op) = resolved
        }

        let named = "'\(reference)' is \(Self.article(op.kind)) \(op.kind.rawValue) op"
        switch step.action {
        case .publish where op.kind != .publish:
            location.diagnose("\(named); a publish step performs a publish op", .warning)
        case .call where [.publish, .consume].contains(op.kind):
            location.diagnose("\(named), which a call step does not perform", .warning)
        default: break
        }
        guard case .call = step.action, let target else {
            if case .publish(let target) = step.action, owner == caller, let opTarget = op.target, opTarget != target {
                location.diagnose("'\(op.id)' targets '\(opTarget)' but this step publishes to '\(target)'", .warning)
            }
            return
        }
        if owner == caller, owner != target {
            if op.direction == .inbound {
                location.diagnose("'\(op.id)' is an inbound op of '\(owner)'; name it on the step that calls '\(owner)'", .warning)
            } else if let opTarget = op.target, opTarget != target {
                location.diagnose("'\(op.id)' targets '\(opTarget)' but this step calls '\(target)'", .warning)
            }
        } else if owner == target, op.direction == .outbound {
            location.diagnose("'\(op.id)' is an outbound op of '\(target)'; name it on a step that '\(target)' performs", .warning)
        }
    }
}
