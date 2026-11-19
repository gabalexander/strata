import Foundation

// Decoding of `how:` (mechanisms as playable sequences) and `formula:` on nodes and operations
// (docs/manifest.md, How it works and Formulas).

extension Decode {
    static let mechanismKeys: Set<String> = ["id", "title", "brief", "summary", "code", "participants", "initial", "steps", "branches"]

    static func mechanisms(_ field: Field) -> [Mechanism] {
        field.items(named: true).compactMap(mechanism)
    }

    static func mechanism(_ field: Field) -> Mechanism? {
        guard field.mapping(mechanismKeys) else { return nil }
        let id = field["id"].id(required: true)
        let title = field["title"].text(required: true, nonempty: true)
        guard let id else { return nil }
        var mechanism = Mechanism(id: id, title: title ?? id)
        mechanism.line = field.line
        mechanism.brief = field["brief"].text()
        mechanism.summary = field["summary"].text()
        mechanism.code = field["code"].textList(orOne: true)
        mechanism.participants = field["participants"].items(required: true, named: true).compactMap(participant)
        mechanism.initial = field["initial"].items().compactMap(stateEntry)
        mechanism.steps = field["steps"].items(required: true, named: true).enumerated().compactMap { index, item in
            mechStep(item, defaultID: "s\(index + 1)")
        }
        if field["steps"].node?.elements?.isEmpty == true { field["steps"].diagnose("expected at least one step") }
        mechanism.branches = field["branches"].items(named: true).compactMap(branch)
        return mechanism
    }

    static func participant(_ field: Field) -> Participant? {
        guard field.mapping(["id", "label", "node", "kind"]) else { return nil }
        guard let id = field["id"].id(required: true) else { return nil }
        var participant = Participant(id: id, label: field["label"].text(nonempty: true))
        participant.node = field["node"].id()
        participant.kind = field["kind"].scalar { raw in
            let name = raw.lowercased()
            if let kind = NodeKind(rawValue: name) ?? NodeKind.aliases[name] { return kind }
            let choices = NodeKind.allCases.map(\.rawValue) + NodeKind.aliases.keys
            let suggestion = closestKey(to: name, in: choices).map { "; did you mean '\($0)'?" } ?? ""
            throw InvalidValue("unknown node kind '\(raw)'\(suggestion)")
        }
        return participant
    }

    /// A step of the main sequence or of a branch. `defaultID` names it when `id` is left out.
    static func mechStep(_ field: Field, defaultID: String) -> MechStep? {
        guard field.mapping(["id", "from", "to", "label", "command", "reply", "note", "at", "state", "code"]) else { return nil }
        let id = field["id"].id() ?? defaultID
        let from = field["from"].id(required: true)
        let to = field["to"].id(required: true)
        let command = field["command"].anyText()
        let label = field["label"].text(nonempty: true)
        guard let from, let to else { return nil }
        var step = MechStep(id: id, from: from, to: to, label: label ?? command ?? id)
        step.line = field.line
        step.command = command
        step.reply = field["reply"].anyText()
        step.note = field["note"].text()
        step.at = field["at"].duration()
        step.state = field["state"].items().compactMap(stateEntry)
        step.code = field["code"].textList(orOne: true)
        return step
    }

    static func branch(_ field: Field) -> MechBranch? {
        guard field.mapping(["id", "label", "after", "note", "steps"]) else { return nil }
        guard let id = field["id"].id(required: true) else { return nil }
        var branch = MechBranch(id: id, label: field["label"].text(required: true, nonempty: true) ?? id)
        branch.after = field["after"].id()
        branch.note = field["note"].text()
        branch.steps = field["steps"].items(required: true, named: true).enumerated().compactMap { index, item in
            mechStep(item, defaultID: "\(id)-s\(index + 1)")
        }
        if field["steps"].node?.elements?.isEmpty == true { field["steps"].diagnose("expected at least one step") }
        return branch
    }

    /// `{ key, value, ttl }`. `value: null` deletes the key; a mapping or list is kept as JSON.
    static func stateEntry(_ field: Field) -> StateEntry? {
        guard field.mapping(["key", "value", "ttl"]) else { return nil }
        let key = field["key"].scalar(required: true) { $0 }
        let value = field["value"]
        guard value.present else {
            value.diagnose("required value is missing; write value: null to delete the key")
            return nil
        }
        let text: String? = if case .null? = value.node?.content { nil } else { value.structuredText() }
        let ttl = field["ttl"].scalar { raw in
            let seconds = try Syntax.duration(raw)
            guard seconds > 0 else { throw InvalidValue("expected a ttl greater than 0s") }
            return seconds
        }
        if ttl != nil, text == nil { field["ttl"].diagnose("a deleted key (value: null) has no ttl", .warning) }
        guard let key else { return nil }
        return StateEntry(key: key, value: text, ttl: text == nil ? nil : ttl)
    }

    static func formula(_ field: Field) -> Formula? {
        guard field.present else { return nil }
        guard field.mapping(["expr", "where", "example", "doc", "code"]) else { return nil }
        guard let expr = field["expr"].text(required: true, nonempty: true) else { return nil }
        var formula = Formula(expr: expr)
        let terms = field["where"]
        if terms.present {
            if let pairs = terms.node?.fields {
                formula.vars = pairs.compactMap { pair in terms[pair.key].anyText().map { (name: pair.key, meaning: $0) } }
            } else {
                terms.diagnose("expected a mapping of variable names to their meaning")
            }
        }
        formula.example = field["example"].anyText()
        formula.doc = field["doc"].text()
        formula.code = field["code"].textList(orOne: true)
        return formula
    }
}
