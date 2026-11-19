import Foundation

// Lookups over the operations of a level (docs/manifest.md, Operations). Additive helpers next to
// the contract types; the parser, the engine, the CLI and the UI all resolve references the same way.

public extension Level {
    /// Resolves a step's `op:`: `node/op`, or an op id on the calling node, then on the step's target.
    func resolveOp(_ reference: String, caller: String?, target: String?) -> (node: String, op: Operation)? {
        if let slash = reference.firstIndex(of: "/") {
            let owner = String(reference[..<slash])
            let id = String(reference[reference.index(after: slash)...])
            return node(owner)?.ops.first { $0.id == id }.map { (owner, $0) }
        }
        for owner in [caller, target].compactMap({ $0 }) {
            if let op = node(owner)?.ops.first(where: { $0.id == reference }) { return (owner, op) }
        }
        return nil
    }

    /// `resolveOp`, then the ops of `owner`, the node this deep-dive level is inside: a plain id that
    /// neither the caller nor the target has, `owner-id/op` when no node of this level has that id, or
    /// `../op`. An owner op resolves with the node `InheritedOps.ownerKey` ("..").
    func resolveOp(_ reference: String, caller: String?, target: String?, owner: Node?) -> (node: String, op: Operation)? {
        if let found = resolveOp(reference, caller: caller, target: target) { return found }
        guard let owner else { return nil }
        var id = reference
        if let slash = reference.firstIndex(of: "/") {
            let prefix = String(reference[..<slash])
            guard prefix == InheritedOps.ownerKey || (prefix == owner.id && node(prefix) == nil) else { return nil }
            id = String(reference[reference.index(after: slash)...])
        }
        return owner.ops.first { $0.id == id }.map { (InheritedOps.ownerKey, $0) }
    }

    /// "node/op" → ids of the flows that name that op, on the flow or on any step, in flow order.
    func opReferences() -> [String: [String]] { opReferences(owner: nil) }

    /// `opReferences()` on a deep-dive level whose steps may name the ops of `owner`, the node it is
    /// inside (keyed "../op").
    func opReferences(owner: Node?) -> [String: [String]] {
        var result: [String: [String]] = [:]
        func add(_ reference: String?, caller: String?, target: String?, flow: String) {
            guard let reference, let resolved = resolveOp(reference, caller: caller, target: target, owner: owner) else { return }
            let key = "\(resolved.node)/\(resolved.op.id)"
            if result[key]?.contains(flow) != true { result[key, default: []].append(flow) }
        }
        func walk(_ steps: [Step], caller: String?, flow: String) {
            for step in steps {
                switch step.action {
                case .call(let callee, let inner, let miss):
                    add(step.op, caller: caller, target: callee, flow: flow)
                    walk(inner, caller: callee, flow: flow)
                    walk(miss, caller: caller, flow: flow)
                case .publish(let buffer): add(step.op, caller: caller, target: buffer, flow: flow)
                case .parallel(let branches):
                    add(step.op, caller: caller, target: nil, flow: flow)
                    walk(branches, caller: caller, flow: flow)
                case .work: add(step.op, caller: caller, target: nil, flow: flow)
                }
            }
        }
        for flow in flows {
            add(flow.op, caller: flow.by ?? flow.from, target: nil, flow: flow.id)
            walk(flow.steps, caller: flow.from ?? flow.by, flow: flow.id)
        }
        return result
    }

    /// The op an outbound op's `calls: node/op` reaches on this level.
    func resolveCalls(_ op: Operation) -> (node: String, op: Operation)? {
        guard let calls = op.calls, calls.contains("/") else { return nil }
        return resolveOp(calls, caller: nil, target: nil)
    }
}
