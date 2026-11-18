import Foundation

enum SimulationEvent {
    case source(Int, Int)
    case continueJob(RecordID)
    case deadline(RecordID)
    case request(Attempt, epoch: Int)
    case finishPublish(Int, PublishOrigin, ingressEpoch: Int, arrived: Double)
    case response(Attempt, epoch: Int, Failure?)
    case timeout(RecordID, Int)
    case retry(RecordID)
    case pumpNode(Int)
    case pumpBuffer(Int)
    case delivery(RecordID, edge: Int, epoch: Int?)
    case deadLetter(DeadLetter, edge: Int, epoch: Int)
    case retryDelivery(RecordID)
    case expire(Int, Int)
    case scenario(ScenarioStep, Int)
    case endScenario(Int)
    case sample(Int)
    case flushLog(Int)
}

struct Traffic {
    let flow: Int
    let visible: Bool
}

struct Attempt {
    let call: RecordID
    let number: Int
    let edge: Int
    let step: Int
    let traffic: Traffic
}

enum Failure {
    case refused, reset, overloaded, handler, timeout(Double, Int), deadline(Double)
    case breakerOpen, bufferFull, invalidTarget

    func describe(_ level: Level, edges: [LinkRuntime]) -> String {
        switch self {
        case .refused: "connection refused"
        case .reset: "connection reset"
        case .overloaded: "503 waiting room full"
        case .handler: "500 handler error"
        case .timeout(let seconds, let edge):
            "timeout after \(Value.number(seconds))s at \(level.nodes[edges[edge].from].id) → \(level.nodes[edges[edge].to].id)"
        case .deadline(let seconds): "deadline after \(Value.number(seconds))s"
        case .breakerOpen: "breaker open"
        case .bufferFull: "buffer full"
        case .invalidTarget: "invalid target"
        }
    }
}

struct CallRecord {
    let caller: RecordID
    let step: Int
    var number = 0
    var waiting = false
    var timeout: Double = 0
    var edge: Int?
    var breakerEpoch: Int?
}

struct Job {
    enum End {
        case source
        case call(Attempt)
        case branch(RecordID)
        case delivery(RecordID)
    }

    let end: End
    let node: Int
    let traffic: Traffic
    let arrived: Double
    let program: Int
    var index = 0
    var limit: Int?
    var slot: Int?
    var owner: RecordID?
    var activeLocally = true
    var localCount = 1
    var needsSlot = false
    var ready: [RecordID] = []
    var children: [RecordID] = []
    var failure: Failure?
    var ignoreBranchFailure = false
    var call: RecordID?
    var started = false
    var queuedForAdmission = false

    var tracksNode: Bool {
        switch end {
        case .call, .delivery: true
        case .source, .branch: false
        }
    }
}

struct CircuitKey: Hashable {
    let step: Int
    let edge: Int
}

struct Circuit {
    var consecutive = 0
    var openUntil: Double?
    var trial = false
    var epoch = 0
}

@MainActor
final class LinkRuntime {
    let id: String
    let from: Int
    let to: Int
    var latency: Dist
    var loss: Double
    var cut = false
    var epoch = 0
    var extra = 0.0
    var openCircuits = 0
    var traversals = RecentRate()

    init(_ edge: Edge, from: Int, to: Int) {
        id = edge.id
        self.from = from
        self.to = to
        latency = edge.latency ?? .fixed(0.001)
        loss = edge.loss ?? 0
    }
}

struct Replica {
    var busy = 0
    var prefetch = 0
    var pulling = 0
    var inbox = FIFO<RecordID>()

    var occupied: Int { busy + pulling }
}

@MainActor
final class NodeRuntime {
    let node: Node
    let base: NodeParams
    var params: NodeParams
    var up = true
    var slow = 1.0
    var redirect: Int?

    var replicas: [Replica]
    var busy = 0
    var waiting = FIFO<RecordID>()
    var queuedCalls = 0
    var onErrorOverride: OnError?
    var live: Set<RecordID> = []
    var deliveries: Set<RecordID> = []
    var consumerFlows: [Int] = []
    var topicCursor = 0
    var deliveryQueued = 0
    var pumpPending = false
    var buffer: MessageBuffer?

    var arrivals = RecentRate()
    var completed = RecentRate()
    var errors = RecentRate()
    var lastFailure: Double?
    var latency = RecentLatency()

    init(_ node: Node, topicConsumer: Bool) {
        self.node = node
        base = NodeConfiguration.effective(node, topicConsumer: topicConsumer)
        params = base
        replicas = Array(repeating: Replica(), count: base.replicas!)
        if node.kind.role == .buffer { buffer = MessageBuffer() }
    }

    var slots: Int {
        guard params.concurrency! < Int.max else { return 0 }
        let (value, overflow) = params.concurrency!.multipliedReportingOverflow(by: params.replicas!)
        return overflow ? Int.max : value
    }

    func freeReplica() -> Int? {
        guard up else { return nil }
        let limit = params.concurrency!
        if params.replicas == 1 { return replicas[0].occupied < limit ? 0 : nil }
        var least = limit
        var result: Int?
        for index in 0..<params.replicas! where replicas[index].occupied < least {
            least = replicas[index].occupied
            result = index
            if least == 0 { break }
        }
        return result
    }
}

@MainActor
final class FlowRuntime {
    let flow: Flow
    let program: Int
    let color: Int
    let source: Int?
    let buffer: Int?
    let consumer: Int?
    var rate: Rate
    var deadline: Double
    var generation = 0

    var lastCredit: Double?
    var credit = 1.0
    var inFlight = 0
    var totalOK = 0
    var totalFailed = 0
    var started = RecentRate()
    var ok = RecentRate()
    var failed = RecentRate()
    var retries = RecentRate()
    var timeouts = RecentRate()
    var latency = RecentLatency()
    var group: TopicGroup?

    init(_ flow: Flow, index: Int, program: Int, topology: ProgramTopology) {
        self.flow = flow
        self.program = program
        color = flow.color ?? index + 1
        source = flow.from.flatMap { topology.nodeIndex[$0] }
        buffer = flow.on.flatMap { topology.nodeIndex[$0] }
        consumer = flow.by.flatMap { topology.nodeIndex[$0] }
        rate = flow.rate
        deadline = flow.deadline ?? 0
        if let buffer, topology.level.nodes[buffer].kind == .topic { group = TopicGroup() }
    }

    func sample(at time: Double) -> Bool {
        if let lastCredit { credit = min(1, credit + (time - lastCredit) * 12) }
        lastCredit = time
        guard credit >= 1 - 1e-9 else { return false }
        credit = 0
        return true
    }
}

struct ProgramStep {
    enum Action {
        case call(target: Int?, program: Int, miss: Int)
        case publish(target: Int?)
        case work(Dist)
        case parallel(Int)
    }

    let spec: Step
    let action: Action

    var target: Int? {
        switch action {
        case .call(let target, _, _), .publish(let target): target
        default: nil
        }
    }

    var isPublish: Bool {
        if case .publish = action { return true }
        return false
    }
}

struct ProgramTopology {
    var level: Level
    let nodeIndex: [String: Int]
    let flowIndex: [String: Int]
    var programs: [[Int]] = [[]]
    var steps: [ProgramStep] = []
    var flowPrograms: [Int] = []

    init(_ level: Level) {
        self.level = level
        nodeIndex = Dictionary(level.nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        flowIndex = Dictionary(level.flows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var known = Set(level.edges.map(\.id))
        for flow in level.flows {
            if let on = flow.on, let by = flow.by { addEdge(on, by, known: &known) }
            flowPrograms.append(compile(flow.steps, from: flow.from ?? flow.by, known: &known))
        }
        for (index, node) in level.nodes.enumerated() where node.at == nil {
            self.level.nodes[index].at = GridPoint(Double(index % 4), Double(index / 4))
        }
    }

    private mutating func addEdge(_ from: String?, _ to: String, known: inout Set<String>) {
        guard let from, nodeIndex[from] != nil, nodeIndex[to] != nil else { return }
        var edge = Edge(from: from, to: to)
        guard known.insert(edge.id).inserted else { return }
        edge.implicit = true
        level.edges.append(edge)
    }

    private mutating func compile(_ sequence: [Step], from: String?, known: inout Set<String>) -> Int {
        guard !sequence.isEmpty else { return 0 }
        var indices: [Int] = []
        for step in sequence {
            let action: ProgramStep.Action
            switch step.action {
            case .call(let target, let nested, let miss):
                addEdge(from, target, known: &known)
                action = .call(target: nodeIndex[target], program: compile(nested, from: target, known: &known),
                               miss: compile(miss, from: from, known: &known))
            case .publish(let target):
                addEdge(from, target, known: &known)
                action = .publish(target: nodeIndex[target])
            case .work(let dist): action = .work(dist)
            case .parallel(let branches): action = .parallel(compile(branches, from: from, known: &known))
            }
            indices.append(steps.count)
            steps.append(ProgramStep(spec: step, action: action))
        }
        programs.append(indices)
        return programs.count - 1
    }
}
