import Foundation

struct Message {
    let sequence: Int
    let traffic: Traffic
    let expires: Double?
    let deadLetterHops: Int
    var attempts = 0
}

struct DeadLetter {
    let source: Int
    let target: Int
    let message: Message
}

enum PublishOrigin {
    case request(Attempt, epoch: Int)
    case deadLetter(DeadLetter)
}

@MainActor
final class MessageBuffer {
    var messages: [Int: Message] = [:]
    var expiringDeliveries: [Int: RecordID] = [:]
    var order = FIFO<Int>()
    var next = 0
    var consumers: [Int] = []
    var cursor = 0
    var unacked = 0
    var reserved = 0
    var lost = 0
    var ingressEpoch = 0
    var pumpPending = false

    func remove(_ sequence: Int) -> Message? {
        guard let message = messages.removeValue(forKey: sequence) else { return nil }
        while let head = order.first, messages[head] == nil { _ = order.pop() }
        if order.count > messages.count * 2 + 64 {
            var compacted = FIFO<Int>()
            for sequence in order.elements where messages[sequence] != nil { compacted.append(sequence) }
            order = compacted
        }
        return message
    }

    func push(_ message: Message) {
        messages[message.sequence] = message
        order.append(message.sequence)
    }
}

@MainActor
final class TopicGroup {
    var next = 0
    var lag = 0
    var outstanding: [Int: RecordID] = [:]
    var blocked: Set<Int> = []
}

struct Delivery {
    enum Stage {
        case transit
        case inbox
        case handling
        case retryWaiting
        case retryReady
    }

    let flow: Int
    let buffer: Int
    var message: Message
    var replica: Int
    let ack: AckMode
    let traffic: Traffic
    var stage: Stage = .transit
    var retryCount = 0
    var receivedAt = 0.0
}

@MainActor
extension Simulation {
    func beginPublish(to index: Int, from origin: PublishOrigin) {
        let node = nodes[index]
        guard let buffer = node.buffer else {
            completePublish(origin, failure: .invalidTarget)
            return
        }
        node.arrivals.add(at: now)
        guard node.up else {
            recordFailure(at: index)
            completePublish(origin, failure: .refused)
            return
        }
        let duration = random.sample(node.params.latency!) * node.slow
        if duration > 0 {
            schedule(.finishPublish(index, origin, ingressEpoch: buffer.ingressEpoch, arrived: now), at: now + duration)
        } else {
            finishPublish(to: index, from: origin, ingressEpoch: buffer.ingressEpoch, arrived: now)
        }
    }

    func finishPublish(to index: Int, from origin: PublishOrigin, ingressEpoch: Int, arrived: Double) {
        let node = nodes[index]
        let buffer = node.buffer!
        guard buffer.ingressEpoch == ingressEpoch else {
            recordFailure(at: index)
            completePublish(origin, failure: .reset)
            return
        }
        node.latency.add(now - arrived, at: now)
        guard !random.occurs(node.params.errors!) else {
            recordFailure(at: index)
            completePublish(origin, failure: .handler)
            return
        }
        let traffic: Traffic
        let deadLetterHops: Int
        switch origin {
        case .request(let attempt, _):
            traffic = attempt.traffic
            deadLetterHops = 0
        case .deadLetter(let letter):
            traffic = letter.message.traffic
            deadLetterHops = letter.message.deadLetterHops + 1
        }
        completePublish(origin, failure: storeMessage(in: index, traffic: traffic, deadLetterHops: deadLetterHops))
    }

    private func completePublish(_ origin: PublishOrigin, failure: Failure?) {
        switch origin {
        case .request(let attempt, let epoch):
            receiveResponse(attempt, epoch: epoch, failure: failure)
        case .deadLetter(let letter):
            switch failure {
            case nil, .bufferFull: break // Overflow has its own dead-letter and loss accounting.
            default: nodes[letter.source].buffer?.lost += 1
            }
        }
    }

    private func storeMessage(in index: Int, traffic: Traffic, deadLetterHops: Int) -> Failure? {
        let node = nodes[index]
        let buffer = node.buffer!
        let topic = node.node.kind == .topic
        let ttl = node.params.ttl!
        let message = Message(sequence: buffer.next, traffic: traffic,
                              expires: ttl > 0 ? now + ttl : nil, deadLetterHops: deadLetterHops)
        let capacity = max(0, node.params.capacity!)
        let full = buffer.messages.count + buffer.reserved >= capacity
        if capacity == 0 || (full && (!topic || node.params.overflow == .reject)) {
            note(.overflow, "\(node.node.id) overflowed", node: index)
            if capacity > 0, node.params.overflow == .dropOldest,
               buffer.reserved < capacity, let oldest = buffer.order.first {
                removeReady(index, message: oldest, deadLetter: true)
                while buffer.messages.count + buffer.reserved >= capacity, let next = buffer.order.first {
                    removeReady(index, message: next, deadLetter: true)
                }
            } else {
                recordFailure(at: index)
                if !routeDeadLetter(message, from: index) { buffer.lost += 1 }
                return .bufferFull
            }
        }

        buffer.next += 1
        buffer.push(message)
        if topic {
            for consumer in buffer.consumers { flows[consumer].group?.lag += 1 }
            trimTopic(index)
        }
        if let expires = message.expires { schedule(.expire(index, message.sequence), at: expires) }
        node.completed.add(at: now)
        requestBufferPump(index)
        return nil
    }

    func expire(_ index: Int, message sequence: Int) {
        guard let buffer = nodes[index].buffer else { return }
        if buffer.messages[sequence] != nil {
            note(.expired, "Message expired in \(nodes[index].node.id)", node: index)
            removeReady(index, message: sequence, deadLetter: true)
            requestBufferPump(index)
        } else if let id = buffer.expiringDeliveries[sequence], let delivery = deliveries[id] {
            let worker = nodes[flows[delivery.flow].consumer!]
            if delivery.stage == .inbox {
                worker.deliveryQueued -= 1
                finishFlow(delivery.flow, arrived: delivery.receivedAt, success: false)
            }
            detachDelivery(id, delivery)
            let replica = delivery.replica
            if worker.replicas[replica].inbox.count > worker.deliveryQueued * 2 + 64 {
                var inbox = FIFO<RecordID>()
                for id in worker.replicas[replica].inbox.elements where deliveries[id] != nil { inbox.append(id) }
                worker.replicas[replica].inbox = inbox
            }
            expireQueueMessage(delivery.message, in: index)
        }
    }

    func trimTopic(_ index: Int) {
        let node = nodes[index]
        guard let buffer = node.buffer else { return }
        let capacity = max(0, node.params.capacity!)
        while buffer.messages.count > capacity, let oldest = buffer.order.first {
            removeReady(index, message: oldest, deadLetter: false)
        }
    }

    func purge(_ index: Int) {
        guard let buffer = nodes[index].buffer else { return }
        while let first = buffer.order.first { removeReady(index, message: first, deadLetter: false) }
        requestBufferPump(index)
    }

    private func removeReady(_ index: Int, message sequence: Int, deadLetter: Bool) {
        guard let buffer = nodes[index].buffer, let message = buffer.remove(sequence) else { return }
        if nodes[index].node.kind == .topic {
            for flow in buffer.consumers {
                guard let group = flows[flow].group else { continue }
                if sequence >= group.next {
                    group.lag -= 1
                    noteRetentionLoss(index, flow: flow)
                } else if let id = group.outstanding[sequence], let delivery = deliveries[id] {
                    switch delivery.stage {
                    case .retryWaiting, .retryReady:
                        detachDelivery(id, delivery)
                        noteRetentionLoss(index, flow: flow)
                    default: break
                    }
                }
            }
        } else if !deadLetter { buffer.lost += 1 }
        if deadLetter, !routeDeadLetter(message, from: index), nodes[index].node.kind == .queue {
            buffer.lost += 1
        }
    }

    private func noteRetentionLoss(_ index: Int, flow: Int) {
        nodes[index].buffer?.lost += 1
        note(.retention, "\(flows[flow].flow.id) lost a message behind \(nodes[index].node.id) retention", node: index)
    }

    private func routeDeadLetter(_ message: Message, from source: Int, consumer: Int? = nil) -> Bool {
        let override = consumer.map { nodes[$0].params.dlq! } ?? ""
        let name = override.isEmpty ? nodes[source].params.dlq! : override
        guard !name.isEmpty, let destination = topology.nodeIndex[name],
              message.deadLetterHops < nodes.count else { return false }
        let target = self.destination(destination)
        guard target != source, nodes[target].buffer != nil else { return false }
        let edge = link(from: source, to: target)
        guard let duration = travel(on: edge) else { return false }
        addToken(message.traffic, edge: edge, duration: duration, kind: .message, label: "Dead letter")
        let letter = DeadLetter(source: source, target: target, message: message)
        schedule(.deadLetter(letter, edge: edge, epoch: edges[edge].epoch), at: now + duration)
        return true
    }

    func receiveDeadLetter(_ letter: DeadLetter, edge: Int, epoch: Int) {
        if edges[edge].cut || edges[edge].epoch != epoch {
            nodes[letter.source].buffer?.lost += 1
            return
        }
        beginPublish(to: letter.target, from: .deadLetter(letter))
    }

    func requestBufferPump(_ index: Int) {
        let node = nodes[index]
        guard node.up, let buffer = node.buffer, !buffer.pumpPending, !buffer.consumers.isEmpty else { return }
        buffer.pumpPending = true
        schedule(.pumpBuffer(index), at: now)
    }

    func pumpBuffer(_ index: Int) {
        let node = nodes[index]
        guard let buffer = node.buffer else { return }
        buffer.pumpPending = false
        guard node.up else { return }
        if node.node.kind == .topic {
            for flow in buffer.consumers {
                if let consumer = flows[flow].consumer { requestNodePump(consumer) }
            }
            return
        }
        guard buffer.order.first != nil else { return }

        var replicas: [(flow: Int, replica: Int)] = []
        for flow in buffer.consumers {
            guard let index = flows[flow].consumer else { continue }
            for replica in 0..<nodes[index].params.replicas! { replicas.append((flow, replica)) }
        }
        guard !replicas.isEmpty else { return }
        var unavailable = 0
        while let first = buffer.order.first, unavailable < replicas.count {
            let candidate = replicas[buffer.cursor % replicas.count]
            buffer.cursor = (buffer.cursor + 1) % replicas.count
            let consumer = flows[candidate.flow].consumer!
            let worker = nodes[consumer]
            let ack = worker.params.ack!
            let edge = link(from: index, to: consumer)
            guard worker.up, !edges[edge].cut,
                  ack == .auto || worker.replicas[candidate.replica].prefetch < worker.params.prefetch! else {
                unavailable += 1
                continue
            }
            unavailable = 0
            guard let message = buffer.remove(first) else { continue }
            let flow = flows[candidate.flow]
            let traffic = Traffic(flow: candidate.flow, visible: flow.sample(at: now))
            let delivery = Delivery(flow: candidate.flow, buffer: index, message: message,
                                    replica: candidate.replica, ack: ack, traffic: traffic)
            let id = deliveries.insert(delivery)
            if message.expires != nil { buffer.expiringDeliveries[message.sequence] = id }
            worker.deliveries.insert(id)
            buffer.reserved += 1
            if ack == .manual {
                buffer.unacked += 1
                worker.replicas[candidate.replica].prefetch += 1
            }
            sendDelivery(id, on: edge)
        }
    }

    func pumpConsumers(_ index: Int) {
        let node = nodes[index]
        for replica in node.replicas.indices {
            while node.replicas[replica].occupied < node.params.concurrency!,
                  let id = node.replicas[replica].inbox.pop() {
                if deliveries[id]?.stage == .inbox {
                    node.deliveryQueued -= 1
                    startDelivery(id)
                }
            }
        }
        let count = node.consumerFlows.count
        var unavailable = 0
        while unavailable < count, node.freeReplica() != nil {
            let flow = node.consumerFlows[node.topicCursor]
            node.topicCursor = (node.topicCursor + 1) % count
            unavailable = pullTopic(flow) ? 0 : unavailable + 1
        }
    }

    private func pullTopic(_ index: Int) -> Bool {
        let flow = flows[index]
        guard let source = flow.buffer, let consumer = flow.consumer, let group = flow.group,
              let buffer = nodes[source].buffer, nodes[source].up else { return false }
        let node = nodes[consumer]
        let edge = link(from: source, to: consumer)
        guard !edges[edge].cut, let replica = node.freeReplica() else { return false }

        let id: RecordID
        if let blocked = group.blocked.min() {
            guard let retry = group.outstanding[blocked], deliveries[retry]?.stage == .retryReady else { return false }
            id = retry
            deliveries[id]!.replica = replica
            deliveries[id]!.stage = .transit
        } else {
            // Skip holes left by TTL or retention before taking another offset.
            group.next = max(group.next, buffer.order.first ?? buffer.next)
            while group.next < buffer.next, buffer.messages[group.next] == nil { group.next += 1 }
            guard let message = buffer.messages[group.next] else { return false }
            group.next += 1
            let traffic = Traffic(flow: index, visible: flow.sample(at: now))
            id = deliveries.insert(Delivery(flow: index, buffer: source, message: message,
                                            replica: replica, ack: .manual, traffic: traffic))
            group.outstanding[message.sequence] = id
            node.deliveries.insert(id)
        }
        node.replicas[replica].pulling += 1
        sendDelivery(id, on: edge)
        return true
    }

    private func sendDelivery(_ id: RecordID, on edge: Int) {
        guard let delivery = deliveries[id] else { return }
        if let delay = travel(on: edge) {
            addToken(delivery.traffic, edge: edge, duration: delay, kind: .message, label: nil)
            schedule(.delivery(id, edge: edge, epoch: edges[edge].epoch), at: now + delay)
        } else {
            let delay = max(0.01, nodes[delivery.buffer].params.backoff!)
            schedule(.delivery(id, edge: edge, epoch: nil), at: now + delay)
        }
    }

    func receiveDelivery(_ id: RecordID, edge: Int, epoch: Int?) {
        guard let delivery = deliveries[id], delivery.stage == .transit else { return }
        let flow = flows[delivery.flow]
        let index = flow.consumer!
        let node = nodes[index]
        if flow.group != nil { node.replicas[delivery.replica].pulling -= 1 }
        if !node.up || edges[edge].cut || edges[edge].epoch != epoch {
            if flow.group == nil { returnToQueue(id, delivery) }
            else { waitToRetry(id, delivery) }
            requestNodePump(index)
            return
        }

        deliveries[id]!.message.attempts += 1
        if flow.group == nil, delivery.ack == .auto {
            nodes[delivery.buffer].buffer!.reserved -= 1
            requestBufferPump(delivery.buffer)
        }
        deliveries[id]!.stage = .inbox
        deliveries[id]!.receivedAt = now
        startFlow(delivery.flow)
        node.arrivals.add(at: now)
        if node.replicas[delivery.replica].occupied < node.params.concurrency!, node.waiting.first == nil {
            startDelivery(id)
        } else {
            node.deliveryQueued += 1
            node.replicas[delivery.replica].inbox.append(id)
            requestNodePump(index)
        }
    }

    private func startDelivery(_ id: RecordID) {
        guard let delivery = deliveries[id] else { return }
        let flow = flows[delivery.flow]
        let index = flow.consumer!
        let node = nodes[index]
        if flow.group == nil, delivery.message.expires != nil {
            nodes[delivery.buffer].buffer!.expiringDeliveries.removeValue(forKey: delivery.message.sequence)
        }
        deliveries[id]!.stage = .handling
        let job = jobs.insert(Job(end: .delivery(id), node: index, traffic: delivery.traffic,
                                  arrived: delivery.receivedAt, program: flow.program))
        node.live.insert(job)
        useSlot(job, node: index, replica: delivery.replica)
    }

    func finishDelivery(_ id: RecordID, failure: Failure?) {
        guard let delivery = deliveries[id] else { return }
        let flow = flows[delivery.flow]
        let index = flow.consumer!
        let worker = nodes[index]
        if !worker.up {
            killDelivery(id)
            return
        }
        guard failure != nil else {
            detachDelivery(id, delivery)
            return
        }

        let onError = worker.onErrorOverride ?? worker.node.params.onError ?? (flow.group == nil ? .requeue : .retry)
        let requeue = flow.group == nil && delivery.ack == .manual && onError == .requeue
        if flow.group != nil, onError == .retry {
            waitToRetry(id, delivery)
        } else if requeue, delivery.message.attempts < worker.params.maxDeliveries! {
            returnToQueue(id, delivery)
        } else {
            detachDelivery(id, delivery)
            if !(onError == .dlq || requeue) || !routeDeadLetter(delivery.message, from: delivery.buffer, consumer: index) {
                nodes[delivery.buffer].buffer!.lost += 1
            }
        }
    }

    func killDelivery(_ id: RecordID) {
        guard let delivery = deliveries[id] else { return }
        let flow = flows[delivery.flow]
        let index = flow.consumer!
        let node = nodes[index]
        if delivery.stage == .inbox {
            node.deliveryQueued -= 1
            recordFailure(at: index)
            finishFlow(delivery.flow, arrived: delivery.receivedAt, success: false)
        }
        if flow.group != nil {
            if delivery.stage == .transit { node.replicas[delivery.replica].pulling -= 1 }
            if delivery.stage != .retryWaiting, delivery.stage != .retryReady { waitToRetry(id, delivery) }
        } else if delivery.ack == .manual || delivery.stage == .transit {
            returnToQueue(id, delivery)
        } else {
            detachDelivery(id, delivery)
            nodes[delivery.buffer].buffer!.lost += 1
            note(.lost, "\(node.node.id) lost an auto-ack message on kill", node: index)
        }
    }

    private func detachDelivery(_ id: RecordID, _ delivery: Delivery) {
        let flow = flows[delivery.flow]
        let node = nodes[flow.consumer!]
        let buffer = nodes[delivery.buffer].buffer!
        node.deliveries.remove(id)
        deliveries.remove(id)
        if let group = flow.group {
            group.outstanding.removeValue(forKey: delivery.message.sequence)
            group.blocked.remove(delivery.message.sequence)
            group.lag -= 1
            requestNodePump(flow.consumer!)
        } else {
            buffer.expiringDeliveries.removeValue(forKey: delivery.message.sequence)
            if delivery.ack == .manual {
                node.replicas[delivery.replica].prefetch -= 1
                buffer.unacked -= 1
            }
            if delivery.ack == .manual || delivery.stage == .transit { buffer.reserved -= 1 }
            requestBufferPump(delivery.buffer)
        }
    }

    private func returnToQueue(_ id: RecordID, _ delivery: Delivery) {
        detachDelivery(id, delivery)
        if let expires = delivery.message.expires, expires <= now {
            expireQueueMessage(delivery.message, in: delivery.buffer)
        } else {
            nodes[delivery.buffer].buffer!.push(delivery.message)
        }
    }

    private func expireQueueMessage(_ message: Message, in index: Int) {
        note(.expired, "Message expired in \(nodes[index].node.id)", node: index)
        if !routeDeadLetter(message, from: index) { nodes[index].buffer!.lost += 1 }
    }

    private func waitToRetry(_ id: RecordID, _ delivery: Delivery) {
        let flow = flows[delivery.flow]
        let consumer = flow.consumer!
        let buffer = nodes[delivery.buffer].buffer!
        if delivery.message.attempts >= nodes[consumer].params.maxDeliveries! {
            detachDelivery(id, delivery)
            if !routeDeadLetter(delivery.message, from: delivery.buffer, consumer: consumer) { buffer.lost += 1 }
            return
        }
        guard buffer.messages[delivery.message.sequence] != nil else {
            detachDelivery(id, delivery)
            noteRetentionLoss(delivery.buffer, flow: delivery.flow)
            return
        }
        flow.group!.blocked.insert(delivery.message.sequence)
        deliveries[id]!.stage = .retryWaiting
        deliveries[id]!.retryCount += 1
        let backoff = nodes[consumer].params.backoff!
        schedule(.retryDelivery(id), at: now + max(0.001, retryDelay(backoff, attempt: delivery.retryCount)))
    }

    func retryDelivery(_ id: RecordID) {
        guard let delivery = deliveries[id], delivery.stage == .retryWaiting else { return }
        deliveries[id]!.stage = .retryReady
        requestNodePump(flows[delivery.flow].consumer!)
    }
}
