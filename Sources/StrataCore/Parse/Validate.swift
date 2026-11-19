import Foundation

enum Validate {
    static func manifest(_ manifest: inout Manifest, at root: Field) {
        duplicates(manifest.terms, at: root["terms"])
        let available = Set(GlossaryPacks.available)
        for (index, pack) in manifest.glossaries.enumerated() where !available.contains(pack) {
            let suggestion = closestKey(to: pack, in: Array(available)).map { "; did you mean '\($0)'?" } ?? ""
            root["glossaries"].items()[index].diagnose("unknown glossary pack '\(pack)'\(suggestion)")
        }
        level(&manifest.root, at: root, terms: TermIndex(manifest: manifest), layout: manifest.layout)
        EnumValidation.check(manifest, at: root)
    }

    private static func duplicates<T: Identifiable>(_ items: [T], at field: Field) where T.ID == String {
        var seen: [String: Int] = [:]
        for (item, location) in zip(items, field.items(named: true)) {
            let id = location["id"].present ? location["id"] : location
            if let original = seen[item.id] {
                id.diagnose("duplicate id '\(item.id)' (first defined on line \(original))")
            } else {
                seen[item.id] = id.line
            }
        }
    }

    private static func level(_ level: inout Level, at field: Field, terms: TermIndex, layout: LayoutMode) {
        duplicates(level.nodes, at: field["nodes"])
        duplicates(level.groups, at: field["groups"])
        duplicates(level.flows, at: field["flows"])
        duplicates(level.controls, at: field["controls"])
        duplicates(level.scenarios, at: field["scenarios"])

        var validator = LevelValidation(level: level, terms: terms)
        for (edge, location) in zip(level.edges, field["edges"].items()) {
            validator.edge(edge, at: location)
        }
        validator.groups(level.groups, fields: field["groups"].items(named: true))

        for (flow, location) in zip(level.flows, field["flows"].items(named: true)) {
            validator.flow(flow, at: location)
        }
        level.edges += validator.implicitEdges
        ZeroTimePublishValidation.warn(in: level, at: field["flows"])
        for (index, location) in field["nodes"].items(named: true).enumerated() {
            let node = level.nodes[index]
            validator.node(node, at: location)
            level.nodes[index].entities = validator.data(of: node, at: location)
            duplicates(node.actions, at: location["actions"])
            duplicates(node.ops, at: location["ops"])
            if var inside = node.inside {
                Self.level(&inside, at: location["inside"], terms: terms, layout: layout)
                level.nodes[index].inside = inside
            }
            for (opIndex, opLocation) in location["ops"].items(named: true).enumerated() {
                guard var inside = node.ops[opIndex].inside else { continue }
                Self.level(&inside, at: opLocation["inside"], terms: terms, layout: layout)
                level.nodes[index].ops[opIndex].inside = inside
            }
        }
        for (control, location) in zip(level.controls, field["controls"].items(named: true)) {
            validator.control(control, at: location)
        }
        for (scenario, location) in zip(level.scenarios, field["scenarios"].items(named: true)) {
            validator.scenario(scenario, at: location)
        }
        LayoutValidation.place(&level, at: field, mode: layout)
    }
}

struct LevelValidation {
    let level: Level
    let nodes: [String: Node]
    let flows: [String: Flow]
    let groups: [String: String]
    let terms: TermIndex
    var edges: Set<String> = []
    var implicitEdges: [Edge] = []
    var positions: [GridPoint: String] = [:]

    init(level: Level, terms: TermIndex) {
        self.level = level
        nodes = Dictionary(level.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        flows = Dictionary(level.flows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        groups = Dictionary(level.groups.map { ($0.id, $0.parent ?? "") }, uniquingKeysWith: { first, _ in first })
        self.terms = terms
    }

    @discardableResult
    func requireNode(_ id: String, at field: Field, as expected: NodeRole? = nil, allowPort: Bool = false) -> Node? {
        guard let node = nodes[id] else {
            field.diagnose("unknown node '\(id)'\(suggestion(id, among: nodes.keys))")
            return nil
        }
        if let expected, node.kind.role != expected, !(allowPort && node.kind == .port) {
            let role = expected == .source && allowPort ? "source or port" : String(describing: expected)
            field.diagnose("'\(id)' must be a \(role); it is a \(node.kind.rawValue)")
            return nil
        }
        return node
    }

    func requireFlow(_ id: String, at field: Field) {
        guard let flow = flows[id] else {
            field.diagnose("unknown flow '\(id)'\(suggestion(id, among: flows.keys))")
            return
        }
        if flow.isConsumer { field.diagnose("'\(id)' is a consumer flow; choose a source flow") }
    }

    func requireTerm(_ id: String?, at field: Field) {
        if let id, terms.term(id) == nil {
            field.diagnose("unknown term '\(id)'; define it in terms or import its glossary pack", .warning)
        }
    }

    func suggestion(_ id: String, among choices: Dictionary<String, some Any>.Keys) -> String {
        closestKey(to: id, in: Array(choices)).map { "; did you mean '\($0)'?" } ?? ""
    }

    mutating func edge(_ edge: Edge, at field: Field) {
        requireNode(edge.from, at: field["from"])
        requireNode(edge.to, at: field["to"])
        if !edges.insert(edge.id).inserted { field.diagnose("duplicate edge '\(edge.id)'") }
    }

    func groups(_ ordered: [Group], fields: [Field]) {
        for (group, field) in zip(ordered, fields) {
            guard var parent = group.parent else { continue }
            if groups[parent] == nil {
                field["parent"].diagnose("unknown parent group '\(parent)'\(suggestion(parent, among: groups.keys))")
                continue
            }
            var visited: Set<String> = [group.id]
            while !parent.isEmpty {
                if !visited.insert(parent).inserted {
                    field["parent"].diagnose("group '\(group.id)' has a cycle in its parent chain")
                    break
                }
                parent = groups[parent] ?? ""
            }
        }
    }

    mutating func node(_ node: Node, at field: Field) {
        if let group = node.group, groups[group] == nil {
            field["group"].diagnose("unknown group '\(group)'\(suggestion(group, among: groups.keys))")
        }
        if let dlq = node.params.dlq { requireNode(dlq, at: field["dlq"], as: .buffer) }
        requireTerm(node.term, at: field["term"])
        if let at = node.at {
            if let other = positions[at] {
                field["at"].diagnose("nodes '\(other)' and '\(node.id)' share the same position", .warning)
            } else {
                positions[at] = node.id
            }
        }
        for (action, location) in zip(node.actions, field["actions"].items(named: true)) {
            commands(action.commands, at: location["do"])
        }
        ops(of: node, at: field)
        how(of: node, at: field)
    }

    mutating func flow(_ flow: Flow, at field: Field) {
        var origin: String?
        if let from = flow.from {
            origin = requireNode(from, at: field["from"], as: .source, allowPort: true)?.id
            if flow.on != nil { field["on"].diagnose("a flow cannot have both from and on") }
        }
        if let on = flow.on {
            let buffer = requireNode(on, at: field["on"], as: .buffer)
            if field["rate"].present { field["rate"].diagnose("consumer flows cannot have a rate") }
            if let by = flow.by {
                let consumer = requireNode(by, at: field["by"], as: .server)
                origin = consumer?.id
                if let buffer, let consumer {
                    addHop(from: buffer.id, to: consumer.id, at: field["by"])
                    if let mode = consumer.params.onError, !consumerModes(buffer.kind).contains(mode) {
                        field["by"].diagnose("'\(consumer.id).onError' must be one of \(consumerModes(buffer.kind).map(\.rawValue).joined(separator: ", ")) when consuming a \(buffer.kind.rawValue)")
                    }
                }
            } else {
                field["by"].diagnose("a consumer flow needs by: <server>")
            }
        } else {
            if flow.from == nil { field.diagnose("a flow needs from: <source> or on: <buffer> with by: <server>") }
            if flow.by != nil { field["by"].diagnose("by is only valid on a consumer flow with on") }
        }
        steps(flow.steps, at: field["steps"], chain: origin.map { [$0] } ?? [])
        flowOp(flow, runsAt: origin, at: field["op"])
        trafficSanity(flow, at: field)
    }

    func consumerModes(_ kind: NodeKind) -> [OnError] {
        kind == .topic ? [.retry, .skip, .dlq] : [.requeue, .drop, .dlq]
    }

    mutating func steps(_ steps: [Step], at field: Field, chain: [String]) {
        for (step, location) in zip(steps, field.items()) {
            stepOp(step, caller: chain.last, at: location)
            switch step.action {
            case .call(let id, let inner, let miss):
                let target = requireNode(id, at: location["call"], as: .server)
                if chain.contains(id) {
                    location["call"].diagnose("recursive call path: \((chain + [id]).joined(separator: " -> "))")
                }
                if let from = chain.last, target != nil { addHop(from: from, to: id, at: location["call"]) }
                if location["miss"].present, let target, target.kind != .cache {
                    location["miss"].diagnose("miss is only valid on calls to caches")
                }
                self.steps(inner, at: location["steps"], chain: chain + [id])
                self.steps(miss, at: location["miss"], chain: chain)
            case .publish(let id):
                let target = requireNode(id, at: location["publish"], as: .buffer)
                if let from = chain.last, target != nil { addHop(from: from, to: id, at: location["publish"]) }
            case .parallel(let children): self.steps(children, at: location["parallel"], chain: chain)
            case .work: break
            }
        }
    }

    mutating func addHop(from: String, to: String, at field: Field) {
        var edge = Edge(from: from, to: to)
        if edges.insert(edge.id).inserted {
            edge.implicit = true
            edge.line = field.line
            implicitEdges.append(edge)
            field.diagnose("added implicit edge '\(edge.id)'; declare it in edges to set its properties", .warning)
        }
    }

    func control(_ control: Control, at field: Field) {
        requireTerm(control.term, at: field["term"])
        let bind = field["bind"]
        switch control.bind.target {
        case .node(let id): requireNode(id, at: bind)
        case .flow(let id): requireFlow(id, at: bind)
        case .edge(let from, let to): requireEdge(from, to, at: bind, eitherDirection: false)
        }
        guard let type = ParameterType.forBinding(control.bind) else {
            let options: [String]
            switch control.bind.target {
            case .node: options = Array(ParameterType.node.keys)
            case .flow: options = ["rate"]
            case .edge: options = ["latency", "loss"]
            }
            let fix = closestKey(to: control.bind.param, in: options).map { "; did you mean '\($0)'?" } ?? ""
            bind.diagnose("unknown bindable parameter '\(control.bind.param)'\(fix)")
            return
        }
        switch control.input {
        case .toggle:
            if case .bool = type {} else { bind.diagnose("a toggle requires a boolean parameter; add options or a range") }
        case .options(let values):
            for (value, location) in zip(values, field["options"].items()) {
                parameterValue(value, type: type, at: location)
            }
        case .range(let min, let max, let step):
            guard type.allowsRange else {
                field["min"].diagnose("this parameter needs options or a toggle")
                return
            }
            parameterValue(.number(min), type: type, at: field["min"], range: true)
            parameterValue(.number(max), type: type, at: field["max"], range: true)
            if case .integer = type, Int(exactly: step) == nil { field["step"].diagnose("use a whole-number step for an integer parameter") }
        }
        for (rule, location) in zip(control.insights, field["insights"].items()) {
            switch rule.when {
            case .always: break
            case .eq(let value): parameterValue(value, type: type, at: location["when"], range: true)
            default:
                if !type.allowsRange { location["when"].diagnose("use an equality condition for this parameter") }
            }
        }
    }

    func parameterValue(_ value: Value, type: ParameterType, at field: Field, range: Bool = false) {
        do { try type.validate(value, range: range) }
        catch let error as InvalidValue { field.diagnose(error.message); return }
        catch { field.diagnose(error.localizedDescription); return }
        if case .nodeID = type, case .string(let id) = value { requireNode(id, at: field, as: .buffer) }
    }

    func requireEdge(_ from: String, _ to: String, at field: Field, eitherDirection: Bool) {
        let a = requireNode(from, at: field)
        let b = requireNode(to, at: field)
        if a != nil, b != nil, !edges.contains("\(from)->\(to)"),
           !(eitherDirection && edges.contains("\(to)->\(from)")) {
            field.diagnose("unknown edge '\(from)->\(to)'; declare it in edges")
        }
    }

    func commands(_ commands: [Command], at field: Field) {
        let locations = field.node?.elements == nil ? [field] : field.items()
        for (command, location) in zip(commands, locations) {
            switch command {
            case .kill(let id), .restore(let id), .slow(let id, _), .fail(let id, _),
                 .scale(let id, _, _), .unredirect(let id):
                requireNode(id, at: location)
            case .purge(let id): requireNode(id, at: location, as: .buffer)
            case .send(let id, _), .rate(let id, _): requireFlow(id, at: location)
            case .cut(let a, let b), .heal(let a, let b): requireEdge(a, b, at: location, eitherDirection: true)
            case .delay(let a, let b, _): requireEdge(a, b, at: location, eitherDirection: false)
            case .redirect(let a, let b):
                let source = requireNode(a, at: location)
                let target = requireNode(b, at: location)
                if let source, let target, source.kind.role != target.kind.role {
                    location.diagnose("redirect targets must have the same role")
                }
                if a == b { location.diagnose("redirect needs two different nodes") }
            case .set(let binding, let value):
                if case .node(let id) = binding.target { requireNode(id, at: location) }
                if let type = ParameterType.forBinding(binding) { parameterValue(value, type: type, at: location) }
            case .say, .pause: break
            }
        }
    }

    func scenario(_ scenario: Scenario, at field: Field) {
        commands(scenario.setup, at: field["setup"])
        for (step, location) in zip(scenario.steps, field["steps"].items()) {
            commands(step.commands, at: location["do"])
        }
        let nodeMetrics: Set<String> = ["inflight", "queued", "util", "throughput", "errors", "p50", "p99", "depth", "lag"]
        let flowMetrics: Set<String> = ["rate", "ok", "errors", "p50", "p99", "retries"]
        for (watch, location) in zip(scenario.watch, field["watch"].items()) {
            let parts = watch.components(separatedBy: ".")
            guard parts.count == 2 else { location.diagnose("expected <node>.<metric> or <flow>.<metric>"); continue }
            let id = parts[0]
            let metric = parts[1]
            if nodes[id] == nil, flows[id] == nil {
                location.diagnose("unknown node or flow '\(id)'")
            } else if !(nodes[id] != nil && nodeMetrics.contains(metric)), !(flows[id] != nil && flowMetrics.contains(metric)) {
                location.diagnose("unknown watch metric '\(metric)' for '\(id)'")
            }
        }
    }
}
