import Foundation

@MainActor
extension Simulation {
    func read(_ binding: Binding) -> Value? {
        switch binding.target {
        case .node(let id):
            guard let index = topology.nodeIndex[id] else { return nil }
            let node = nodes[index]
            if binding.param == "up" { return .bool(node.up) }
            if binding.param == "slow" { return .number(node.slow) }
            return NodeConfiguration.value(binding.param, in: node.params)
        case .flow(let id):
            guard let index = topology.flowIndex[id] else { return nil }
            if binding.param == "rate" { return .number(rate(for: flows[index])) }
            if binding.param == "deadline" { return .number(flows[index].deadline) }
        case .edge(let from, let to):
            guard let a = topology.nodeIndex[from], let b = topology.nodeIndex[to],
                  let index = existingLink(from: a, to: b) else { return nil }
            let edge = edges[index]
            switch binding.param {
            case "latency": return .number(edge.latency.mean)
            case "loss": return .number(edge.loss)
            case "cut": return .bool(edge.cut)
            default: return nil
            }
        }
        return nil
    }

    func write(_ value: Value, to binding: Binding) -> Bool {
        switch binding.target {
        case .node(let id):
            guard let index = topology.nodeIndex[id] else { return false }
            let node = nodes[index]
            switch (binding.param, value) {
            case ("up", .bool(let up)): setUp(index, up)
            case ("slow", .number(let factor)) where factor.isFinite && factor >= 0: node.slow = factor
            default:
                var params = node.params
                guard NodeConfiguration.apply(value, to: binding.param, in: &params) else { return false }
                if binding.param == "dlq", let dlq = params.dlq, !dlq.isEmpty,
                   topology.nodeIndex[dlq].map({ nodes[$0].buffer == nil }) ?? true { return false }
                node.params = params
                if binding.param == "onError" { node.onErrorOverride = params.onError }
                resizeReplicas(index)
                if binding.param == "capacity", node.node.kind == .topic { trimTopic(index) }
                requestNodePump(index)
                requestBufferPump(index)
                for flow in node.consumerFlows {
                    if let buffer = flows[flow].buffer { requestBufferPump(buffer) }
                }
            }
            return true
        case .flow(let id):
            guard let index = topology.flowIndex[id], let number = value.number,
                  number.isFinite, number >= 0 else { return false }
            if binding.param == "rate", flows[index].source != nil { changeRate(index, to: .perSecond(number)) }
            else if binding.param == "deadline" { flows[index].deadline = number }
            else { return false }
            return true
        case .edge(let from, let to):
            guard let a = topology.nodeIndex[from], let b = topology.nodeIndex[to],
                  let index = existingLink(from: a, to: b) else { return false }
            let edge = edges[index]
            switch (binding.param, value) {
            case ("cut", .bool(let cut)): setCut(index, cut)
            case ("latency", .number(let time)) where time.isFinite && time >= 0: edge.latency = .fixed(time)
            case ("loss", .number(let loss)) where loss.isFinite && loss >= 0: edge.loss = min(1, loss)
            default: return false
            }
            return true
        }
    }

    func apply(_ command: Command) {
        func bind(_ id: String, _ param: String, _ value: Value) -> Bool {
            write(value, to: Binding(.node(id), param))
        }
        let text: String
        var succeeded = true
        switch command {
        case .kill(let id):
            succeeded = bind(id, "up", .bool(false))
            text = "Killed \(id)"
        case .restore(let id):
            if let index = topology.nodeIndex[id] {
                let node = nodes[index]
                node.slow = 1
                node.params.errors = node.base.errors
                setUp(index, true)
            } else { succeeded = false }
            text = "Restored \(id)"
        case .slow(let id, let factor):
            succeeded = bind(id, "slow", .number(factor))
            text = "Set \(id) latency factor to \(Value.number(factor))×"
        case .fail(let id, let probability):
            succeeded = bind(id, "errors", .number(probability))
            text = "Set \(id) error probability to \(Value.number(probability * 100))%"
        case .scale(let id, let replicas, let relative):
            if let index = topology.nodeIndex[id] {
                let base = relative ? nodes[index].params.replicas! : 0
                let (total, overflow) = base.addingReportingOverflow(replicas)
                succeeded = !overflow && bind(id, "replicas", .number(Double(max(1, total))))
            } else { succeeded = false }
            let amount = relative && replicas >= 0 ? "+\(replicas)" : String(replicas)
            text = "Scaled \(id) \(amount)"
        case .set(let binding, let value):
            succeeded = write(value, to: binding)
            text = "Set \(binding) to \(value)"
        case .rate(let id, let rate):
            if let index = topology.flowIndex[id], flows[index].source != nil { changeRate(index, to: rate) }
            else { succeeded = false }
            text = "Changed \(id) rate to \(rateDescription(rate))"
        case .send(let id, let count):
            succeeded = count > 0 && topology.flowIndex[id].map { flows[$0].source != nil } == true
            if succeeded { send(id, count: count) }
            text = "Sent \(count) on \(id)"
        case .cut(let from, let to), .heal(let from, let to):
            let cut: Bool
            if case .cut = command { cut = true } else { cut = false }
            succeeded = changeLinks(from, to) { setCut($0, cut) }
            text = "\(cut ? "Cut" : "Healed") \(from) ↔ \(to)"
        case .delay(let from, let to, let time):
            succeeded = time.isFinite && time >= 0 && changeLinks(from, to) { edges[$0].extra = time }
            text = "Added \(Value.number(time))s of one-way delay between \(from) and \(to)"
        case .redirect(let id, let other):
            if let from = topology.nodeIndex[id], let to = topology.nodeIndex[other],
               canRedirect(from, to: to) {
                nodes[from].redirect = to
            } else { succeeded = false }
            text = "Redirected \(id) to \(other)"
        case .unredirect(let id):
            if let index = topology.nodeIndex[id] { nodes[index].redirect = nil }
            else { succeeded = false }
            text = "Removed redirect for \(id)"
        case .purge(let id):
            if let index = topology.nodeIndex[id], nodes[index].buffer != nil { purge(index) }
            else { succeeded = false }
            text = "Purged \(id)"
        case .say(let message): text = message
        case .pause:
            playing = false
            text = "Paused"
        }

        let feedback = succeeded ? text : "Could not apply \(command)"
        narrate(feedback)
        append(feedback, succeeded ? .info : .warn)
    }

    private func canRedirect(_ from: Int, to: Int) -> Bool {
        var next: Int? = to
        while let index = next {
            guard index != from else { return false }
            next = nodes[index].redirect
        }
        return true
    }

    private func changeLinks(_ from: String, _ to: String, _ change: (Int) -> Void) -> Bool {
        guard let a = topology.nodeIndex[from], let b = topology.nodeIndex[to] else { return false }
        let forward = existingLink(from: a, to: b)
        let reverse = a == b ? nil : existingLink(from: b, to: a)
        if let forward { change(forward) }
        if let reverse { change(reverse) }
        return forward != nil || reverse != nil
    }

    private func setCut(_ index: Int, _ cut: Bool) {
        let edge = edges[index]
        guard cut != edge.cut else { return }
        edge.cut = cut
        if cut {
            edge.epoch += 1
            tokens.removeAll { $0.edge == index }
        } else {
            requestBufferPump(edge.from)
            requestNodePump(edge.to)
        }
    }

    private func rateDescription(_ rate: Rate) -> String {
        switch rate {
        case .manual: "manual"
        case .parent: "parent"
        case .every(let time): "every \(Value.number(time))s"
        case .perSecond(let perSecond): "\(Value.number(perSecond))/s"
        }
    }
}
