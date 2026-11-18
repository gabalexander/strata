import Foundation

@MainActor
extension Simulation {
    func startAttempt(_ id: RecordID) {
        guard let call = calls[id], let job = jobs[call.caller] else { return }
        let step = topology.steps[call.step]
        guard let original = step.target else {
            note(.failed, "Invalid call or publish target", node: job.node, visible: job.traffic.visible)
            completeCall(id, failure: .invalidTarget)
            return
        }
        let target = destination(original)
        let edge = link(from: job.node, to: target)
        calls[id]!.edge = edge
        let source = nodes[job.node]
        let timeout = step.spec.timeout ?? source.params.timeout!
        calls[id]!.timeout = timeout
        if step.spec.breaker != nil {
            let key = CircuitKey(step: call.step, edge: edge)
            guard let epoch = admitCircuit(key) else {
                note(.failed, "\(source.node.id) → \(nodes[target].node.id): breaker open",
                     node: target, visible: job.traffic.visible)
                completeCall(id, failure: .breakerOpen)
                return
            }
            calls[id]!.breakerEpoch = epoch
        }
        if call.number > 0 { flows[job.traffic.flow].retries.add(at: now) }
        calls[id]!.waiting = true
        let attempt = Attempt(call: id, number: call.number, edge: edge, step: call.step, traffic: job.traffic)
        let wire = edges[edge]
        if let delay = travel(on: edge) {
            addToken(job.traffic, edge: edge, duration: delay, kind: step.isPublish ? .message : .request,
                     label: step.spec.label)
            schedule(.request(attempt, epoch: wire.epoch), at: now + delay)
        }
        if timeout > 0 { schedule(.timeout(id, call.number), at: now + timeout) }
    }

    func travel(on index: Int) -> Double? {
        let wire = edges[index]
        guard !wire.cut else { return nil }
        wire.traversals.add(at: now)
        guard !random.occurs(wire.loss) else { return nil }
        return max(0, random.sample(wire.latency) + wire.extra)
    }

    private func reached(_ edge: Int, epoch: Int) -> Bool {
        let wire = edges[edge]
        return !wire.cut && wire.epoch == epoch
    }

    func receiveRequest(_ attempt: Attempt, epoch: Int) {
        guard reached(attempt.edge, epoch: epoch) else { return }
        let target = edges[attempt.edge].to
        let step = topology.steps[attempt.step]
        switch step.action {
        case .call(_, let program, _):
            if nodes[target].node.kind.role == .server { accept(attempt, at: target, program: program) }
            else { sendResponse(attempt, failure: .invalidTarget) }
        case .publish:
            beginPublish(to: target, from: .request(attempt, epoch: epoch))
        case .parallel, .work: preconditionFailure("Only wire steps send requests")
        }
    }

    func sendResponse(_ attempt: Attempt, failure: Failure?) {
        guard let delay = travel(on: attempt.edge) else { return }
        let step = topology.steps[attempt.step].spec
        addToken(attempt.traffic, edge: attempt.edge, duration: delay, kind: failure == nil ? .response : .failure,
                 label: failure.map { $0.describe(level, edges: edges) } ?? step.label, reverse: true, reply: attempt)
        schedule(.response(attempt, epoch: edges[attempt.edge].epoch, failure), at: now + delay)
    }

    func isWaiting(for attempt: Attempt) -> Bool {
        guard let call = calls[attempt.call] else { return false }
        return call.waiting && call.number == attempt.number
    }

    func receiveResponse(_ attempt: Attempt, epoch: Int, failure: Failure?) {
        guard isWaiting(for: attempt), reached(attempt.edge, epoch: epoch) else { return }
        if let failure { attemptFailed(attempt.call, failure: failure) }
        else {
            observeCircuit(attempt.call, success: true)
            completeCall(attempt.call, failure: nil)
        }
    }

    func timeoutCall(_ id: RecordID, number: Int) {
        guard let call = calls[id], let job = jobs[call.caller], let edge = call.edge,
              call.waiting, call.number == number else { return }
        let failure = Failure.timeout(call.timeout, edge)
        flows[job.traffic.flow].timeouts.add(at: now)
        note(.timeout, failure.describe(level, edges: edges), node: job.node, visible: job.traffic.visible)
        attemptFailed(id, failure: failure)
    }

    private func attemptFailed(_ id: RecordID, failure: Failure) {
        guard let call = calls[id], let job = jobs[call.caller], let edge = call.edge else { return }
        let step = topology.steps[call.step].spec
        let target = edges[edge].to
        if call.waiting { observeCircuit(id, success: false) }
        if nodes[target].node.kind == .cache, !topology.steps[call.step].isPublish {
            switch failure {
            case .refused, .reset:
                completeCall(id, failure: nil, forceMiss: true)
                return
            default: break
            }
        }
        switch failure {
        case .timeout: break
        default:
            note(.failed, "\(level.nodes[job.node].id) → \(level.nodes[target].id): \(failure.describe(level, edges: edges))",
                 node: target, visible: job.traffic.visible)
        }

        let params = nodes[job.node].params
        let retries = step.retries ?? params.retries!
        if call.number < retries {
            calls[id]!.waiting = false
            calls[id]!.number += 1
            calls[id]!.breakerEpoch = nil
            let backoff = step.backoff ?? params.backoff!
            schedule(.retry(id), at: now + retryDelay(backoff, attempt: call.number))
        } else {
            completeCall(id, failure: failure)
        }
    }

    func retryDelay(_ backoff: Double, attempt: Int) -> Double {
        guard backoff > 0 else { return 0 }
        return backoff * exp2(Double(min(1023, attempt))) * (0.5 + random.unit())
    }

    private func completeCall(_ id: RecordID, failure: Failure?, forceMiss: Bool = false) {
        guard let call = calls[id], jobs[call.caller] != nil else { return }
        calls.remove(id)
        jobs[call.caller]!.call = nil
        let step = topology.steps[call.step]
        // A cache that refused the call still lets the step continue as a miss, but the command failed.
        if let op = step.op { recordOp(op, latency: now - call.started, failed: failure != nil || forceMiss) }
        if let failure, !step.spec.optional {
            finishJob(call.caller, failure: failure)
            return
        }
        if failure == nil, case .call(_, _, let miss) = step.action, miss != 0, let edge = call.edge {
            let target = nodes[edges[edge].to]
            if target.node.kind == .cache, forceMiss || !random.occurs(target.params.hitRate!) {
                beginBranches(call.caller, program: miss, parallel: false, optional: step.spec.optional)
                return
            }
        }
        resumeLocal(call.caller)
    }

    func cancelCall(_ id: RecordID) {
        guard let call = calls[id] else { return }
        if let edge = call.edge, let epoch = call.breakerEpoch {
            let key = CircuitKey(step: call.step, edge: edge)
            if let circuit = circuits[key], circuit.epoch == epoch, circuit.trial {
                // The trial can no longer report its result to this caller.
                observeCircuit(id, success: false)
            }
        }
        calls.remove(id)
    }

    private func admitCircuit(_ key: CircuitKey) -> Int? {
        var circuit = circuits[key] ?? Circuit()
        guard let until = circuit.openUntil else { return circuit.epoch }
        guard now >= until, !circuit.trial else { return nil }
        circuit.trial = true
        circuits[key] = circuit
        return circuit.epoch
    }

    private func observeCircuit(_ id: RecordID, success: Bool) {
        guard let call = calls[id], let epoch = call.breakerEpoch, let edge = call.edge,
              let settings = topology.steps[call.step].spec.breaker else { return }
        let key = CircuitKey(step: call.step, edge: edge)
        var circuit = circuits[key] ?? Circuit()
        guard circuit.epoch == epoch else { return }
        if success {
            circuit.consecutive = 0
            if circuit.trial {
                circuit.openUntil = nil
                circuit.trial = false
                circuit.epoch += 1
                edges[edge].openCircuits -= 1
                append("Breaker closed on \(edges[edge].id)", .good)
            }
        } else {
            circuit.consecutive += 1
            if circuit.trial || circuit.consecutive >= max(1, settings.failures) {
                if circuit.openUntil == nil { edges[edge].openCircuits += 1 }
                circuit.openUntil = now + settings.cooldown
                circuit.trial = false
                circuit.epoch += 1
                append("Breaker opened on \(edges[edge].id)", .warn)
            }
        }
        circuits[key] = circuit
    }
}
