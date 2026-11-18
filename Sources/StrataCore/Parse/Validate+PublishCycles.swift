import Foundation

struct ZeroTimePublishValidation {
    private struct Hop {
        let target: String
        let field: Field
    }

    private let params: [String: NodeParams]
    private let zeroEdges: Set<String>

    private init(_ level: Level) {
        params = Dictionary(level.nodes.map { ($0.id, NodeConfiguration.effective($0)) },
                            uniquingKeysWith: { first, _ in first })
        zeroEdges = Set(level.edges.filter { $0.latency?.mean == 0 }.map(\.id))
    }

    static func warn(in level: Level, at field: Field) {
        let timing = Self(level)
        var graph: [String: [Hop]] = [:]
        for (flow, location) in zip(level.flows, field.items(named: true)) {
            guard let buffer = flow.on, let worker = flow.by, timing.isImmediate(from: buffer, to: worker) else { continue }
            _ = timing.canFinishImmediately(flow.steps, at: worker) { target in
                graph[buffer, default: []].append(Hop(target: target, field: location["on"]))
            }
        }

        var visited: Set<String> = []
        for node in level.nodes where graph[node.id] != nil && visited.insert(node.id).inserted {
            var stack = [(node.id, graph[node.id, default: []].makeIterator())]
            var path = [node.id: 0]
            while let current = stack.last {
                guard let hop = stack[stack.count - 1].1.next() else {
                    path.removeValue(forKey: current.0)
                    stack.removeLast()
                    continue
                }
                if let start = path[hop.target] {
                    let cycle = stack[start...].map(\.0) + [hop.target]
                    hop.field.diagnose("possible zero-time publish cycle: \(cycle.joined(separator: " → "))", .warning)
                } else if visited.insert(hop.target).inserted {
                    path[hop.target] = stack.count
                    stack.append((hop.target, graph[hop.target, default: []].makeIterator()))
                }
            }
        }
    }

    private func isImmediate(from: String, to: String) -> Bool {
        zeroEdges.contains("\(from)->\(to)") && params[to]?.latency?.mean == 0
    }

    private func canFinishImmediately(_ steps: [Step], at origin: String, publish: (String) -> Void) -> Bool {
        for step in steps where (step.p ?? 1) > 0 {
            let immediate: Bool
            switch step.action {
            case .work(let duration):
                immediate = duration.mean == 0
            case .publish(let target):
                immediate = isImmediate(from: origin, to: target)
                if immediate { publish(target) }
            case .call(let target, let inner, let miss):
                let callFinishes = isImmediate(from: origin, to: target) &&
                    canFinishImmediately(inner, at: target, publish: publish)
                let hitRate = params[target]?.hitRate ?? 1
                let missFinishes = callFinishes && hitRate < 1 && canFinishImmediately(miss, at: origin, publish: publish)
                immediate = callFinishes && (hitRate > 0 || missFinishes)
            case .parallel(let children):
                // Inspect every branch even when one takes time.
                immediate = children.map { canFinishImmediately([$0], at: origin, publish: publish) }.allSatisfy { $0 }
            }
            if !immediate, (step.p ?? 1) >= 1 { return false }
        }
        return true
    }
}
