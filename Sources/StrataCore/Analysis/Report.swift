import Foundation

// Turns the capacity model into a CapacityReport: the node and flow tables, what to scale,
// pressure on each server, and plain-sentence notes.

extension CapacityModel {
    func report() -> CapacityReport {
        var report = CapacityReport()
        let current = evaluate(configured)

        for (n, info) in nodes.enumerated() where info.node.kind.role != .annotation {
            var visits: [String: Double] = [:]
            var unitVisits = 0.0, unitDemand = 0.0
            for f in roles.indices {
                let cell = n * flowCount + f
                guard current.tally.visits[cell] > 0 else { continue }
                visits[level.flows[f].id, default: 0] += current.tally.visits[cell]
                unitVisits += current.tally.visits[cell]
                unitDemand += current.tally.demand[cell]
            }
            // At rate 0 the hold time still describes one request: visits weighted equally per flow.
            let hold = current.arrivals[n] > 0 ? current.demand[n] / current.arrivals[n]
                : unitVisits > 0 ? unitDemand / unitVisits : info.service
            var capacity = NodeCapacity(node: info.node.id, slots: info.unlimited ? nil : info.slots, holdTime: hold,
                                        demand: current.demand[n], utilization: utilization(n, current), visits: visits)
            capacity.arrivals = current.arrivals[n]
            capacity.queueWait = queueWait(n, demand: current.demand[n], arrivals: current.arrivals[n])
            report.nodes.append(capacity)
        }
        report.nodes = report.nodes.enumerated().sorted { a, b in
            if a.element.utilization != b.element.utilization { return a.element.utilization > b.element.utilization }
            if a.element.demand != b.element.demand { return a.element.demand > b.element.demand }
            return a.offset < b.offset
        }.map(\.element)

        // Per day: traffic.daily wins; consumer flows follow their publishers' daily volumes.
        let declaredDaily: [Double] = roles.indices.map { f in
            if case .consumer = roles[f], !fixed[f] { return 0 }
            return level.flows[f].traffic?.daily ?? configured[f] * 86_400
        }
        var offeredDaily = resolveRates(declaredDaily, fixed: fixed, tally: current.tally)
        for f in roles.indices { if let daily = level.flows[f].traffic?.daily { offeredDaily[f] = daily } }

        var notes = self.notes
        for (f, flow) in level.flows.enumerated() {
            var capacity = FlowCapacity(flow: flow.id, rate: current.rates[f], daily: offeredDaily[f])
            capacity.declared = flow.traffic
            capacity.slo = flow.slo
            if case .inert = roles[f] {
                report.flows.append(capacity)
                continue
            }
            let limit = maxRate(f, current: current)
            capacity.maxRate = limit.rate
            capacity.bottleneck = limit.bottleneck.map { nodes[$0].node.id }
            capacity.latency = current.tally.latency[f]
            if case .consumer(let buffer, let by) = roles[f] {
                let offered = current.rates[f]
                capacity.offered = offered
                let consumer = nodes[by].node.label, source = nodes[buffer].node.label
                if nodes[by].blocked {
                    let inflow = inflow(buffer, rates: current.rates, tally: current.tally, excluding: f)
                    capacity.rate = 0
                    if flow.traffic?.daily == nil { capacity.daily = 0 }
                    notes.append("\(consumer) is \(nodes[by].down ? "down" : "out of slots"), so \(flow.id) stops and \(source) grows \(Format.rate(inflow))/s.")
                } else if let rate = limit.rate, offered > rate * (1 + 1e-6) {
                    capacity.rate = rate
                    if flow.traffic?.daily == nil { capacity.daily = offeredDaily[f] * rate / offered }
                    let behind = limit.bottleneck.map { nodes[$0].node.label } ?? consumer
                    notes.append("\(consumer) can't keep up with \(source): \(Format.rate(offered))/s arrive and \(flow.id) handles at most \(Format.rate(rate))/s (\(behind) saturates), so the backlog grows \(Format.rate(offered - rate))/s.")
                }
            }
            report.flows.append(capacity)
        }
        for (n, info) in nodes.enumerated() where info.down && current.arrivals[n] > 0 {
            notes.append("\(info.node.label) is down: \(Format.rate(current.arrivals[n]))/s of calls to it fail fast.")
        }

        for (n, info) in nodes.enumerated() where info.node.kind.role == .server && !info.unlimited && current.demand[n] > 0 {
            var loads: [LoadSource] = []
            for (s, source) in sources.enumerated() where source.key.target == n {
                let rate = current.rates[source.key.flow]
                let calls = rate * current.tally.sourceVisits[s], busy = rate * current.tally.sourceDemand[s]
                guard calls > 0 || busy > 0 else { continue }
                var load = LoadSource(node: nodes[source.key.caller].node.id, op: source.key.op, flow: level.flows[source.key.flow].id,
                                      tables: source.tables, access: source.access, rate: calls, busyShare: busy / current.demand[n])
                load.daily = current.tally.sourceVisits[s] * offeredDaily[source.key.flow]
                loads.append(load)
            }
            loads.sort { $0.busyShare != $1.busyShare ? $0.busyShare > $1.busyShare : $0.rate > $1.rate }
            report.pressure[info.node.id] = loads
        }

        let plan: [Double] = roles.indices.map { f in
            if case .source = roles[f], inputs.rates[level.flows[f].id] == nil, let peak = level.flows[f].traffic?.peak,
               peak.isFinite, peak >= 0, !nodes[sourceNode(f)].down { return peak }
            return configured[f]
        }
        report.scalePlan = scalePlan(plan, atPeak: plan != configured)
        report.notes = notes
        return report
    }

    private func sourceNode(_ f: Int) -> Int {
        if case .source(let origin) = roles[f] { return origin }
        return 0
    }

    /// What to scale, in order: the node that saturates first as every flow grows from `plan`,
    /// the replicas that keep it under 70% (at the planned rates and when the next node saturates),
    /// and where the limit moves. Stops when nothing saturates within 100× the planned rates.
    func scalePlan(_ plan: [Double], atPeak: Bool) -> [ScaleStep] {
        var model = self
        var steps: [ScaleStep] = []
        let reference = atPeak ? "peak" : "the analysed rates"
        for _ in 0..<4 {
            guard let first = model.saturation(plan) else { break }
            let node = first.node
            let info = model.nodes[node]
            let replicas = info.params.replicas ?? 1
            let concurrency = max(1, info.params.concurrency ?? 1)
            let before = model.evaluate(plan)
            let busyBefore = model.utilization(node, before)
            let flow = model.primaryFlow(of: node, before)
            let planRate = flow.map { plan[$0] } ?? 0
            var step = ScaleStep(node: info.node.id, replicas: replicas, reason: "")
            step.flow = flow.map { level.flows[$0].id }
            step.utilization = busyBefore
            let saturatesAt = planRate > 0 ? ", at \(Format.rate(first.scale * planRate))/s of \(level.flows[flow!].id)" : ""
            guard replicas < SimulationLimits.replicas else {
                step.reason = "\(info.node.label) saturates first\(saturatesAt), and it already runs \(SimulationLimits.replicas) replicas, the most a node can have: raise its concurrency or split its work."
                step.newUtilization = busyBefore
                steps.append(step)
                break
            }

            var unbounded = model
            unbounded.nodes[node].unlimited = true
            let next = unbounded.saturation(plan)
            let horizon = min(next?.scale ?? 100, 100)
            // Service-time demand: right at the next node's saturation its queue would inflate this one's hold.
            let demandThen = unbounded.evaluate(plan.map { $0 * horizon }, queueing: false).demand[node]
            func needed(_ demand: Double) -> Int {
                guard demand.isFinite else { return SimulationLimits.replicas }
                return Int(min(1e6, (demand / (0.7 * Double(concurrency))).rounded(.up)))
            }
            let wanted = max(replicas + 1, needed(before.demand[node]), needed(demandThen))
            var target = min(SimulationLimits.replicas, wanted)
            model.nodes[node].params.replicas = target
            var after = model.saturation(plan)
            var nudges = 0
            // Queueing near a tie can still name the same node; a little more capacity settles it.
            while next != nil, after?.node == node, target < SimulationLimits.replicas, nudges < 8 {
                target += 1
                nudges += 1
                model.nodes[node].params.replicas = target
                after = model.saturation(plan)
            }
            let busyAfter = model.utilization(node, model.evaluate(plan))
            step.replicas = target
            step.newUtilization = busyAfter
            step.newMaxRate = planRate > 0 ? after.map { $0.scale * planRate } : nil
            step.nextBottleneck = after.map { model.nodes[$0.node].node.id }

            var reason = first.scale < 1
                ? "\(info.node.label) is over capacity at \(reference)"
                : "\(info.node.label) saturates first\(saturatesAt)" + (planRate > 0 ? " (\(Format.multiple(first.scale)) \(reference))" : "")
            reason += ". \(target) replicas take it from \(Format.percent(busyBefore)) to \(Format.percent(busyAfter)) busy at \(reference)"
            if wanted > SimulationLimits.replicas { reason += " (\(SimulationLimits.replicas) replicas is the limit)" }
            if let after {
                let limit = planRate > 0 ? " at \(Format.rate(after.scale * planRate))/s" : ""
                reason += after.node == node ? "; it saturates again\(limit)" : "; \(model.nodes[after.node].node.label) saturates next\(limit)"
            } else {
                reason += "; nothing else saturates within 100× \(reference)"
            }
            step.reason = reason + "."
            steps.append(step)
            guard after != nil else { break }
        }
        return steps
    }
}

/// Plain number formatting for analysis sentences.
enum Format {
    static func rate(_ value: Double) -> String {
        guard value.isFinite else { return "∞" }
        let magnitude = abs(value)
        if magnitude >= 1000 {
            // Three significant digits: a solved maximum like 199,999.6/s reads as 200,000.
            let unit = pow(10, floor(log10(magnitude)) - 2)
            return grouped((value / unit).rounded() * unit)
        }
        if magnitude >= 100 { return String(format: "%.0f", value) }
        var text = String(format: magnitude >= 0.1 || magnitude == 0 ? "%.1f" : "%.2f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func grouped(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value))
    }

    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "∞%" }
        return fraction < 0.01 && fraction > 0 ? "<1%" : String(format: "%.0f%%", fraction * 100)
    }

    static func multiple(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f×", value) : String(format: "%.1f×", value)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "∞" }
        if seconds >= 1 { return String(format: "%.1f s", seconds) }
        let ms = seconds * 1000
        return ms >= 10 ? String(format: "%.0f ms", ms) : String(format: "%.1f ms", ms)
    }
}
