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

    /// The op an outbound op's `calls: node/op` reaches on this level.
    func resolveCalls(_ op: Operation) -> (node: String, op: Operation)? {
        guard let calls = op.calls, calls.contains("/") else { return nil }
        return resolveOp(calls, caller: nil, target: nil)
    }
}
