import Foundation

@MainActor
extension Simulation {
    func advanceJob(_ id: RecordID) {
        guard let initial = jobs[id] else { return }
        let sequence = topology.programs[initial.program]
        let limit = initial.limit ?? sequence.count
        while let job = jobs[id], job.index < limit {
            let stepIndex = sequence[job.index]
            let step = topology.steps[stepIndex]
            jobs[id]!.index += 1
            if let probability = step.spec.p, !random.occurs(probability) { continue }
            if job.traffic.visible, let say = step.spec.say, narratedSteps.insert(stepIndex).inserted {
                narrate(say)
            }
            switch step.action {
            case .work(let duration):
                let seconds = random.sample(duration)
                if let op = step.op { recordOp(op, latency: seconds, failed: false) }
                if seconds > 0 {
                    schedule(.continueJob(id), at: now + seconds)
                    return
                }
            case .call, .publish:
                let request = calls.insert(CallRecord(caller: id, step: stepIndex, started: now))
                jobs[id]!.call = request
                suspendLocal(id)
                startAttempt(request)
                return
            case .parallel(let program):
                guard !topology.programs[program].isEmpty else { continue }
                if let op = step.op { jobs[id]!.parallelOp = (op, now) }
                beginBranches(id, program: program, parallel: true, optional: step.spec.optional)
                return
            }
        }
        if let job = jobs[id], job.tracksNode, random.occurs(nodes[job.node].params.errors!) {
            if case .delivery = job.end {
                note(.failed, "\(nodes[job.node].node.id): 500 handler error", node: job.node, visible: job.traffic.visible)
            }
            finishJob(id, failure: .handler)
        } else {
            finishJob(id, failure: nil)
        }
    }

    func beginBranches(_ parent: RecordID, program: Int, parallel: Bool, optional: Bool = false) {
        guard let job = jobs[parent] else { return }
        // A branch works at the same node and borrows its parent's slot.
        let owner = job.owner ?? (job.tracksNode ? parent : nil)
        let count = parallel ? topology.programs[program].count : 1
        var children: [RecordID] = []
        children.reserveCapacity(count)
        for index in 0..<count {
            let child = Job(end: .branch(parent), node: job.node, traffic: job.traffic, arrived: now,
                            program: program, index: index, limit: parallel ? index + 1 : nil, owner: owner)
            children.append(jobs.insert(child))
        }
        jobs[parent]!.children = children
        jobs[parent]!.ignoreBranchFailure = optional
        if let owner { jobs[owner]!.localCount += count }
        suspendLocal(parent)
        for child in children { resumeLocal(child) }
    }

    private func branchFinished(_ id: RecordID, parent: RecordID, failure: Failure?) {
        guard jobs[parent] != nil else { return }
        jobs[parent]!.children.removeAll { $0 == id }
        if let failure, jobs[parent]!.failure == nil, !jobs[parent]!.ignoreBranchFailure {
            jobs[parent]!.failure = failure
        }
        guard jobs[parent]!.children.isEmpty else { return }
        if let pending = jobs[parent]!.parallelOp {
            jobs[parent]!.parallelOp = nil
            recordOp(pending.slot, latency: now - pending.started, failed: jobs[parent]!.failure != nil)
        }
        if let failure = jobs[parent]!.failure { finishJob(parent, failure: failure) }
        else { resumeLocal(parent) }
    }

    private func discardJob(_ id: RecordID) {
        guard let job = jobs[id] else { return }
        if let call = job.call { cancelCall(call) }
        jobs.remove(id)
        for child in job.children { discardJob(child) }
    }

    func finishJob(_ id: RecordID, failure: Failure?) {
        guard let job = jobs[id] else { return }
        let localCount = job.owner == nil ? 0 : activeBranchCount(id)
        discardJob(id)
        if let owner = job.owner, jobs[owner] != nil {
            jobs[owner]!.localCount -= localCount
            releaseWhenWaiting(owner)
        }
        let node = nodes[job.node]
        if job.tracksNode {
            if job.queuedForAdmission { node.queuedCalls -= 1 }
            node.live.remove(id)
            if let slot = job.slot { releaseSlot(job.node, slot) }
            if job.started {
                node.completed.add(at: now)
                node.latency.add(now - job.arrived, at: now)
            }
            if failure != nil { recordFailure(at: job.node) }
        }
        switch job.end {
        case .source:
            node.live.remove(id)
            node.completed.add(at: now)
            node.latency.add(now - job.arrived, at: now)
            if failure != nil { recordFailure(at: job.node) }
            finishFlow(job.traffic.flow, arrived: job.arrived, success: failure == nil)
        case .call(let attempt): sendResponse(attempt, failure: failure)
        case .branch(let parent): branchFinished(id, parent: parent, failure: failure)
        case .delivery(let delivery):
            finishFlow(job.traffic.flow, arrived: job.arrived, success: failure == nil)
            finishDelivery(delivery, failure: failure)
        }
    }

    private func activeBranchCount(_ id: RecordID) -> Int {
        guard let job = jobs[id] else { return 0 }
        return (job.activeLocally ? 1 : 0) + job.children.reduce(0) { $0 + activeBranchCount($1) }
    }

    func finishFlow(_ index: Int, arrived: Double, success: Bool) {
        let flow = flows[index]
        flow.inFlight -= 1
        flow.latency.add(now - arrived, at: now)
        if let op = flow.op { recordOp(op, latency: now - arrived, failed: !success) }
        if success {
            flow.totalOK += 1
            flow.ok.add(at: now)
        } else {
            flow.totalFailed += 1
            flow.failed.add(at: now)
        }
    }

    private func suspendLocal(_ id: RecordID) {
        guard let job = jobs[id], job.activeLocally,
              let owner = job.owner ?? (job.tracksNode ? id : nil) else { return }
        jobs[id]!.activeLocally = false
        jobs[owner]!.localCount -= 1
        releaseWhenWaiting(owner)
    }

    private func releaseWhenWaiting(_ owner: RecordID) {
        guard let job = jobs[owner], job.localCount == 0, let slot = job.slot,
              nodes[job.node].params.async! else { return }
        jobs[owner]!.slot = nil
        releaseSlot(job.node, slot)
    }

    func resumeLocal(_ id: RecordID) {
        guard let job = jobs[id] else { return }
        if let owner = job.owner ?? (job.tracksNode ? id : nil), let host = jobs[owner] {
            if !job.activeLocally {
                jobs[id]!.activeLocally = true
                jobs[owner]!.localCount += 1
            }
            if host.slot == nil {
                jobs[owner]!.ready.append(id)
                if !host.needsSlot {
                    jobs[owner]!.needsSlot = true
                    nodes[host.node].waiting.append(owner)
                    requestNodePump(host.node)
                }
                return
            }
        }
        schedule(.continueJob(id), at: now)
    }

    func accept(_ attempt: Attempt, at index: Int, program: Int) {
        let node = nodes[index]
        node.arrivals.add(at: now)
        guard node.up else {
            recordFailure(at: index)
            sendResponse(attempt, failure: .refused)
            return
        }
        if node.waiting.first != nil { admitWaiting(index) }
        let slot = node.freeReplica()
        if slot == nil, node.queuedCalls >= node.params.queue! {
            recordFailure(at: index)
            // The caller records the failed response, including when it retries.
            sendResponse(attempt, failure: .overloaded)
            return
        }
        let id = jobs.insert(Job(end: .call(attempt), node: index, traffic: attempt.traffic,
                                 arrived: now, program: program, queuedForAdmission: slot == nil))
        node.live.insert(id)
        if let slot { useSlot(id, node: index, replica: slot) }
        else {
            node.queuedCalls += 1
            node.waiting.append(id)
        }
    }

    func useSlot(_ id: RecordID, node index: Int, replica: Int) {
        guard let job = jobs[id] else { return }
        let node = nodes[index]
        node.replicas[replica].busy += 1
        node.busy += 1
        jobs[id]!.slot = replica
        if job.started {
            jobs[id]!.needsSlot = false
            jobs[id]!.ready.removeAll(keepingCapacity: true)
            for ready in job.ready { schedule(.continueJob(ready), at: now) }
        } else {
            jobs[id]!.started = true
            if job.queuedForAdmission {
                node.queuedCalls -= 1
                jobs[id]!.queuedForAdmission = false
            }
            let duration = random.sample(node.params.latency!) * node.slow
            if duration > 0 { schedule(.continueJob(id), at: now + duration) }
            else { advanceJob(id) }
        }
    }

    private func releaseSlot(_ index: Int, _ replica: Int) {
        let node = nodes[index]
        node.replicas[replica].busy -= 1
        node.busy -= 1
        requestNodePump(index)
    }

    func requestNodePump(_ index: Int) {
        let node = nodes[index]
        guard node.up, !node.pumpPending, node.waiting.first != nil || !node.consumerFlows.isEmpty else { return }
        node.pumpPending = true
        schedule(.pumpNode(index), at: now)
    }

    func pumpNode(_ index: Int) {
        let node = nodes[index]
        node.pumpPending = false
        guard node.up else { return }
        admitWaiting(index)
        if !node.consumerFlows.isEmpty { pumpConsumers(index) }
    }

    private func admitWaiting(_ index: Int) {
        let node = nodes[index]
        while let replica = node.freeReplica(), let id = node.waiting.pop() {
            if jobs[id] != nil { useSlot(id, node: index, replica: replica) }
        }
    }

    func resizeReplicas(_ index: Int) {
        let node = nodes[index]
        let configured = node.params.replicas!
        if configured > node.replicas.count {
            node.replicas += Array(repeating: Replica(), count: configured - node.replicas.count)
        }
        // Removed replicas drain their existing work and receive no new deliveries.
        reevaluateSlots(index)
    }

    func reevaluateSlots(_ index: Int) {
        let node = nodes[index]
        if node.params.async! {
            for id in node.live.sorted() { releaseWhenWaiting(id) }
        }
    }

    func setUp(_ index: Int, _ up: Bool) {
        let node = nodes[index]
        guard node.up != up else { return }
        node.up = up
        append("\(node.node.id) is \(up ? "up" : "down")", up ? .good : .bad, node: index)
        if !up {
            node.buffer?.ingressEpoch += 1
            node.waiting = FIFO()
            for id in node.live.sorted() {
                if let job = jobs[id] {
                    switch job.end {
                    case .source, .delivery:
                        note(.failed, "\(node.node.id): connection reset", node: index, visible: job.traffic.visible)
                    default: break
                    }
                }
                finishJob(id, failure: .reset)
            }
            for id in node.deliveries.sorted() { killDelivery(id) }
            for replica in node.replicas.indices { node.replicas[replica].inbox = FIFO() }
            node.lastFailure = now
        } else {
            requestNodePump(index)
            requestBufferPump(index)
        }
        for flow in node.consumerFlows {
            if let buffer = flows[flow].buffer { requestBufferPump(buffer) }
        }
    }
}
