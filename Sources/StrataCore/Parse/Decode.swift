import Foundation

enum Decode {
    static let levelKeys: Set<String> = ["nodes", "edges", "groups", "flows", "controls", "scenarios", "narration", "direction"]
    static let embedKeys: Set<String> = ["view", "scenario", "height", "autoplay"]

    static func manifest(_ root: Field, source: ManifestSource, inline: Bool = false) -> Manifest? {
        let keys: Set<String> = ["strata", "id", "title", "kind", "category", "summary", "tags", "repo",
                                 "glossaries", "terms", "notes", "links", "layout"]
        guard root.mapping(keys.union(levelKeys).union(manifestEnumKeys).union(manifestJourneyKeys).union(inline ? embedKeys : [])) else { return nil }
        let version = root["strata"]
        if let number = version.integer(required: !inline, in: Int.min...Int.max), number != 1 {
            version.diagnose("unsupported manifest version \(number); use strata: 1")
        }
        let id = root["id"].id(required: !inline)
        let title = root["title"].text(required: !inline, nonempty: true)
        let level = decodeLevel(root, root: true)
        var fallback = "", fallbackTitle = ""
        if case .inline(let note, let index) = source {
            fallback = "\(note)#\(index)"
            // Shown on the embed and in breadcrumbs: name the note, not the internal id.
            fallbackTitle = "Diagram in " + ((note as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        var manifest = Manifest(id: id ?? fallback, title: title ?? fallbackTitle, root: level, source: source)
        manifest.kind = root["kind"].choice(ManifestKind.self) ?? .sim
        manifest.category = root["category"].text()
        manifest.summary = root["summary"].text()
        manifest.tags = root["tags"].textList()
        manifest.repo = root["repo"].scalar { path in
            let expanded = StrataPaths.expand(path)
            guard expanded.hasPrefix("/") else { throw InvalidValue("expected an absolute path or a path beginning with ~/") }
            return expanded
        }
        manifest.glossaries = root["glossaries"].items().compactMap { $0.id() }
        manifest.terms = root["terms"].items(named: true).compactMap(term)
        manifest.enums = root["enums"].items(named: true).compactMap(enumDef)
        manifest.journeys = journeys(root["journeys"])
        manifest.notes = root["notes"].text()
        manifest.links = root["links"].items().compactMap(link)
        manifest.layout = root["layout"].choice(LayoutMode.self) ?? .auto
        return manifest
    }

    static func decodeLevel(_ field: Field, root: Bool = false) -> Level {
        var level = Level()
        guard root || field.mapping(levelKeys) else { return level }
        level.nodes = field["nodes"].items(required: true, named: true).compactMap(node)
        level.edges = field["edges"].items().compactMap(edge)
        level.groups = field["groups"].items(named: true).compactMap(group)
        level.flows = field["flows"].items(named: true).compactMap(flow)
        level.controls = field["controls"].items(named: true).compactMap(control)
        level.scenarios = field["scenarios"].items(named: true).compactMap(scenario)
        level.narration = field["narration"].text()
        level.direction = direction(field["direction"])
        return level
    }

    /// `direction: right | down`. Other words for the two (vertical, top-down, LR, ...) get a suggestion.
    static func direction(_ field: Field) -> FlowDirection? {
        field.scalar { text in
            if let value = FlowDirection(rawValue: text) { return value }
            let word = text.lowercased().filter { $0.isLetter }
            let synonyms: [String: FlowDirection] = [
                "vertical": .down, "topdown": .down, "toptobottom": .down, "tb": .down, "td": .down, "top": .down,
                "bottom": .down, "rows": .down, "downward": .down, "downwards": .down,
                "horizontal": .right, "lefttoright": .right, "leftright": .right, "lr": .right, "ltr": .right,
                "left": .right, "columns": .right, "across": .right,
            ]
            let guess = FlowDirection(rawValue: word) ?? synonyms[word]
                ?? closestKey(to: text, in: FlowDirection.allCases.map(\.rawValue)).flatMap(FlowDirection.init(rawValue:))
            let suggestion = guess.map { "; did you mean '\($0.rawValue)'?" } ?? ""
            throw InvalidValue("expected right (flow left to right) or down (top to bottom)\(suggestion)")
        }
    }

    static func node(_ field: Field) -> Node? {
        let keys: Set<String> = ["id", "kind", "label", "tech", "at", "group", "doc", "term", "code", "icon", "links", "inside", "detail", "actions", "ops",
                                  "schema", "entities", "how", "formula"]
        let behaviour = Set(ParameterType.node.keys).subtracting(["up", "slow"])
        guard field.mapping(keys.union(behaviour).union(["binary"])) else { return nil }
        let id = field["id"].id(required: true)
        let kind = field["kind"].scalar(required: true) { raw in
            let name = raw.lowercased()
            if let kind = NodeKind(rawValue: name) { return (kind, nil as String?) }
            if let kind = NodeKind.aliases[name] { return (kind, raw as String?) }
            let choices = NodeKind.allCases.map(\.rawValue) + NodeKind.aliases.keys
            let suggestion = closestKey(to: name, in: choices).map { "; did you mean '\($0)'?" } ?? "; use a node kind such as service, database, or queue"
            throw InvalidValue("unknown node kind '\(raw)'\(suggestion)")
        }
        var node = Node(id: id ?? "", kind: kind?.0 ?? .note, label: field["label"].text())
        node.line = field.line
        node.tech = field["tech"].text() ?? kind?.1
        node.icon = field["icon"].text()
        node.at = point(field["at"])
        node.group = field["group"].id()
        node.doc = field["doc"].text()
        node.term = field["term"].termID()
        node.code = field["code"].textList(orOne: true)
        node.binary = field["binary"].text(nonempty: true)
        node.links = field["links"].items().compactMap(link)
        node.params = params(field)
        if field["inside"].present { node.inside = decodeLevel(field["inside"]) }
        node.detail = field["detail"].id()
        if field["inside"].present, field["detail"].present { field["detail"].diagnose("use either inside or detail for a deep dive") }
        node.actions = field["actions"].items(named: true).enumerated().compactMap { action($0.element, index: $0.offset) }
        node.ops = field["ops"].items(named: true).compactMap(operation)
        node.schema = field["schema"].items(named: true, nameKey: "table").compactMap(table)
        node.entities = field["entities"].items(named: true, nameKey: "name").compactMap(entity)
        node.how = mechanisms(field["how"])
        node.formula = formula(field["formula"])
        return node
    }

    static func point(_ field: Field) -> GridPoint? {
        guard field.present else { return nil }
        let items = field.items()
        guard field.node?.elements != nil else { return nil }
        guard items.count == 2 else { field.diagnose("expected [column, row]"); return nil }
        let x = items[0].number()
        let y = items[1].number()
        guard let x, let y else { return nil }
        return GridPoint(x, y)
    }

    static func params(_ field: Field) -> NodeParams {
        var params = NodeParams()
        params.latency = field["latency"].distribution()
        params.concurrency = field["concurrency"].integer(in: 1...SimulationLimits.concurrency)
        params.replicas = field["replicas"].integer(in: 1...SimulationLimits.replicas)
        params.queue = field["queue"].integer(in: 0...SimulationLimits.queue)
        params.errors = field["errors"].probability()
        params.timeout = field["timeout"].duration()
        params.retries = field["retries"].integer(in: 0...Int.max)
        params.backoff = field["backoff"].duration()
        params.async = field["async"].bool()
        params.capacity = field["capacity"].integer(in: 1...SimulationLimits.capacity)
        params.overflow = field["overflow"].choice(Overflow.self)
        params.ttl = field["ttl"].duration()
        params.dlq = field["dlq"].id()
        params.prefetch = field["prefetch"].integer(in: 0...SimulationLimits.prefetch)
        params.ack = field["ack"].choice(AckMode.self)
        params.onError = field["onError"].choice(OnError.self)
        params.maxDeliveries = field["maxDeliveries"].integer(in: 1...Int.max)
        params.hitRate = field["hitRate"].probability()
        return params
    }

    static func edge(_ field: Field) -> Edge? {
        guard field.mapping(["from", "to", "label", "protocol", "latency", "loss"]) else { return nil }
        var edge = Edge(from: field["from"].id(required: true) ?? "", to: field["to"].id(required: true) ?? "")
        edge.line = field.line
        edge.label = field["label"].text()
        edge.protocol = field["protocol"].text()
        edge.latency = field["latency"].distribution()
        edge.loss = field["loss"].probability()
        return edge
    }

    static func group(_ field: Field) -> Group? {
        guard field.mapping(["id", "label", "kind", "parent"]) else { return nil }
        var group = Group(id: field["id"].id(required: true) ?? "", label: field["label"].text())
        group.kind = field["kind"].choice(GroupKind.self) ?? .boundary
        group.parent = field["parent"].id()
        return group
    }

    static func flow(_ field: Field) -> Flow? {
        guard field.mapping(["id", "label", "from", "on", "by", "rate", "color", "deadline", "steps", "op", "traffic", "slo"]) else { return nil }
        var flow = Flow(id: field["id"].id(required: true) ?? "", label: field["label"].text())
        flow.line = field.line
        flow.color = field["color"].integer(in: 1...6)
        flow.from = field["from"].id()
        flow.on = field["on"].id()
        flow.by = field["by"].id()
        flow.rate = field["rate"].scalar(Syntax.rate) ?? .manual
        flow.deadline = field["deadline"].duration()
        flow.steps = field["steps"].items().compactMap(step)
        flow.op = field["op"].scalar { try Syntax.opReference($0, qualified: false, owner: true) }
        flow.traffic = traffic(field["traffic"])
        flow.slo = slo(field["slo"])
        return flow
    }

    static func step(_ field: Field) -> Step? {
        let verbs = ["call", "publish", "work", "parallel"]
        let callOnly = ["steps", "miss", "timeout", "retries", "backoff", "breaker"]
        guard field.mapping(Set(verbs + callOnly + ["label", "say", "optional", "p", "op"])) else { return nil }
        let found = verbs.filter { field[$0].present }
        guard found.count == 1, let verb = found.first else {
            field.diagnose("expected exactly one step action: call, publish, work, or parallel")
            return nil
        }
        if verb != "call" {
            for key in callOnly where field[key].present { field[key].diagnose("'\(key)' is only valid on call steps") }
        }
        let action: StepAction?
        switch verb {
        case "call":
            let steps = field["steps"].items().compactMap(step)
            let miss = field["miss"].items().compactMap(step)
            action = field["call"].id().map { .call(target: $0, steps: steps, miss: miss) }
        case "publish": action = field["publish"].id().map { .publish(target: $0) }
        case "work": action = field["work"].distribution().map(StepAction.work)
        default: action = .parallel(field["parallel"].items().compactMap(step))
        }
        guard let action else { return nil }
        var step = Step(action)
        step.line = field.line
        step.label = field["label"].text()
        step.say = field["say"].text()
        step.p = field["p"].probability()
        step.optional = field["optional"].bool() ?? false
        step.op = field["op"].scalar { try Syntax.opReference($0, qualified: false, owner: true) }
        if verb == "call" {
            step.timeout = field["timeout"].duration()
            step.retries = field["retries"].integer(in: 0...Int.max)
            step.backoff = field["backoff"].duration()
            step.breaker = breaker(field["breaker"])
        }
        return step
    }

    static func breaker(_ field: Field) -> Breaker? {
        guard field.present, field.mapping(["failures", "cooldown"]) else { return nil }
        let failures = field["failures"].integer(required: true, in: 1...Int.max)
        let cooldown = field["cooldown"].duration(required: true)
        guard let failures, let cooldown else { return nil }
        return Breaker(failures: failures, cooldown: cooldown)
    }

    static func control(_ field: Field) -> Control? {
        guard field.mapping(["id", "label", "bind", "min", "max", "step", "options", "unit", "hint", "term", "insights"]) else { return nil }
        let id = field["id"].id()
        let label = field["label"].text(required: true, nonempty: true)
        let binding = field["bind"].scalar(required: true) { try Syntax.binding($0) }
        let range = ["min", "max", "step"].contains { field[$0].present }
        var input: ControlInput = .toggle
        if field["options"].present {
            if range { field["options"].diagnose("choose options or a range for this control") }
            let options = field["options"].items().compactMap { $0.value() }
            if field["options"].node?.elements?.isEmpty == true { field["options"].diagnose("expected at least one option") }
            input = .options(options)
        } else if range {
            let min = field["min"].number(required: true)
            let max = field["max"].number(required: true)
            let step = field["step"].number(required: true)
            if let min, let max, let step {
                if min >= max { field["max"].diagnose("max must be greater than min") }
                if step <= 0 { field["step"].diagnose("step must be greater than zero") }
                input = .range(min: min, max: max, step: step)
            }
        }
        guard let binding else { return nil }
        var control = Control(id: id ?? binding.description, label: label ?? binding.description, bind: binding, input: input)
        control.line = field.line
        control.unit = field["unit"].text()
        control.hint = field["hint"].text()
        control.term = field["term"].termID()
        control.insights = field["insights"].items().compactMap(insight)
        return control
    }

    static func insight(_ field: Field) -> InsightRule? {
        guard field.mapping(["when", "text", "effects"]) else { return nil }
        var rule = InsightRule(text: field["text"].text(required: true) ?? "")
        rule.when = field["when"].scalar(Syntax.condition) ?? .always
        rule.effects = field["effects"].items().compactMap { effect in
            guard effect.mapping(["metric", "dir", "good"]) else { return nil }
            let metric = effect["metric"].text(required: true, nonempty: true)
            let dir = effect["dir"].scalar(required: true) { raw in
                guard let dir = EffectSpec.Dir(rawValue: raw) else { throw InvalidValue("expected up, down, or flat") }
                return dir
            }
            let good = effect["good"].bool()
            guard let metric, let dir else { return nil }
            return EffectSpec(metric: metric, dir: dir, good: good)
        }
        return rule
    }

    static func commands(_ field: Field, required: Bool = false) -> [Command] {
        guard required || field.present else { return [] }
        let fields = field.node?.scalar == nil && field.present ? field.items() : [field]
        if required, field.node?.elements?.isEmpty == true { field.diagnose("expected at least one command") }
        return fields.compactMap { item in
            guard let text = item.text(required: true) else { return nil }
            switch ManifestParser.parseCommand(text) {
            case .success(let command): return command
            case .failure(let error): item.diagnose(error.message); return nil
            }
        }
    }

    static func action(_ field: Field, index: Int) -> Action? {
        guard field.mapping(["id", "label", "icon", "do"]) else { return nil }
        let label = field["label"].text(required: true, nonempty: true)
        let parsed = commands(field["do"], required: true)
        var action = Action(id: field["id"].id() ?? "action-\(index + 1)", label: label ?? "", commands: parsed)
        action.icon = field["icon"].text()
        return action
    }

    static func scenario(_ field: Field) -> Scenario? {
        guard field.mapping(["id", "label", "goal", "setup", "steps", "watch"]) else { return nil }
        let id = field["id"].id(required: true) ?? ""
        var scenario = Scenario(id: id, label: field["label"].text() ?? id)
        scenario.goal = field["goal"].text()
        scenario.setup = commands(field["setup"])
        scenario.steps = field["steps"].items().compactMap { field in
            guard field.mapping(["at", "do", "say"]) else { return nil }
            let time = field["at"].duration(required: true)
            var step = ScenarioStep(at: time ?? 0)
            step.say = field["say"].text()
            step.commands = commands(field["do"], required: !field["say"].present)
            return step
        }
        scenario.watch = field["watch"].textList()
        return scenario
    }

    static func term(_ field: Field) -> Term? {
        guard field.mapping(["id", "term", "short", "detail", "design", "match", "related"]) else { return nil }
        var term = Term(id: field["id"].id(required: true) ?? "", term: field["term"].text(required: true, nonempty: true) ?? "",
                        short: field["short"].text(required: true) ?? "")
        term.detail = field["detail"].text()
        term.design = field["design"].text()
        if field["match"].present { term.match = field["match"].items().compactMap { $0.text(nonempty: true) } }
        if field["related"].present { term.related = field["related"].items().compactMap { $0.termID() } }
        return term
    }

    static func link(_ field: Field) -> Link? {
        guard field.mapping(["label", "url", "note", "sim"]) else { return nil }
        let label = field["label"].text(required: true, nonempty: true)
        let destinations = ["url", "note", "sim"].filter { field[$0].present }
        guard destinations.count == 1, let destination = destinations.first else {
            field.diagnose("expected exactly one link destination: url, note, or sim")
            return nil
        }
        let target: Link.Target?
        switch destination {
        case "sim": target = field["sim"].id().map(Link.Target.sim)
        case "note": target = field["note"].text(nonempty: true).map(Link.Target.note)
        default:
            target = field["url"].scalar { raw in
                guard URLComponents(string: raw)?.scheme != nil else { throw InvalidValue("expected a URL with a scheme such as https://") }
                return .url(raw)
            }
        }
        guard let label, let target else { return nil }
        return Link(label: label, target: target)
    }
}
