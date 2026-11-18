import Foundation

// How trouble at one node spreads (docs/manifest.md, Backpressure and blast radius). Pure graph
// rules over the flows' steps:
// - Slowness travels up synchronous call chains: a caller holds its slot while it waits, so it fills
//   up next, and its own callers after it. An `async` caller frees its slot while it waits, so its
//   other work isn't starved, but its responses slow down and its callers still fill up.
// - A publisher waits for the buffer to take the message, so a buffer that is full or down sends
//   the trouble up to its publishers.
// - Buffers stop it. A consumer that slows down turns into depth (queue) or lag (topic) in the
//   buffer it reads, and the publishers upstream of that buffer don't notice.

struct BlastRadiusGraph {
    private struct Caller: Hashable {
        let node: String
        let flow: String
    }

    let level: Level
    private var callers: [String: [Caller]] = [:]          // callee or buffer → who calls or publishes to it
    private var consumers: [String: [(flow: String, by: String)]] = [:]   // buffer → consumer flows
    private var consumes: [String: [(flow: String, buffer: String)]] = [:] // consumer node → its buffers
    private var touches: [String: Set<String>] = [:]       // flow → nodes it calls, publishes to, starts at or consumes with

    init(_ level: Level) {
        self.level = level
        for flow in level.flows {
            var touched: Set<String> = []
            if let on = flow.on, let by = flow.by {
                consumers[on, default: []].append((flow.id, by))
                consumes[by, default: []].append((flow.id, on))
                touched.formUnion([on, by])
                walk(flow.steps, at: by, flow: flow.id, touched: &touched)
            } else if let from = flow.from {
                touched.insert(from)
                walk(flow.steps, at: from, flow: flow.id, touched: &touched)
            }
            touches[flow.id] = touched
        }
    }

    private mutating func walk(_ steps: [Step], at node: String, flow: String, touched: inout Set<String>) {
        for step in steps {
            switch step.action {
            case .call(let target, let nested, let miss):
                add(Caller(node: node, flow: flow), to: target)
                touched.insert(target)
                walk(nested, at: target, flow: flow, touched: &touched)
                walk(miss, at: node, flow: flow, touched: &touched)
            case .publish(let buffer):
                add(Caller(node: node, flow: flow), to: buffer)
                touched.insert(buffer)
            case .parallel(let branches):
                walk(branches, at: node, flow: flow, touched: &touched)
            case .work:
                break
            }
        }
    }

    private mutating func add(_ caller: Caller, to target: String) {
        if callers[target]?.contains(caller) != true { callers[target, default: []].append(caller) }
    }

    func radius(of id: String) -> BlastRadius {
        var result = BlastRadius(node: id)
        guard let start = level.node(id) else { return result }
        var edges = OrderedSet(), absorbers = OrderedSet(), lagging = OrderedSet()

        func isAsync(_ node: String) -> Bool { level.node(node)?.params.async == true }
        func absorb(at consumer: String) {
            for (_, buffer) in consumes[consumer] ?? [] {
                absorbers.insert(buffer)
                lagging.insert(consumer)
                edges.insert("\(buffer)->\(consumer)")
            }
        }

        if start.kind.role == .buffer {
            // Its consumers starve while it's down, and fall behind while it's slow.
            for (_, by) in consumers[id] ?? [] {
                lagging.insert(by)
                edges.insert("\(id)->\(by)")
            }
        }
        absorb(at: id)

        var seen: Set<String> = [id]
        var frontier = [id]
        var upstream: [String] = []
        while !frontier.isEmpty {
            var next: [String] = []
            for current in frontier {
                for caller in callers[current] ?? [] {
                    edges.insert("\(caller.node)->\(current)")
                    guard seen.insert(caller.node).inserted else { continue }
                    upstream.append(caller.node)
                    if !isAsync(caller.node) { absorb(at: caller.node) }
                    next.append(caller.node)
                }
            }
            frontier = next
        }

        // Flows that pass through the node, or through an upstream server whose slots fill up: a
        // shared pool slows every flow it serves, including a lagging consumer's own flow.
        let pools = Set([id] + upstream.filter { node in
            guard let info = level.node(node), info.kind.role == .server else { return false }
            return info.params.async != true
        })
        for flow in level.flows where !(touches[flow.id] ?? []).isDisjoint(with: pools) {
            result.flows.append(flow.id)
        }
        result.upstream = upstream
        result.edges = edges.items
        result.absorbers = absorbers.items
        result.lagging = lagging.items
        return result
    }
}

private struct OrderedSet {
    private(set) var items: [String] = []
    private var members: Set<String> = []
    mutating func insert(_ item: String) { if members.insert(item).inserted { items.append(item) } }
}
