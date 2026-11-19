import Foundation

// Validation of top-level `journeys:` (docs/manifest.md, Journeys). Runs after the levels and enums are
// validated: a journey's tables, nodes, ops, enums and mechanisms can live on any level. The replay
// (JourneyReplay.swift) finds most problems; this maps them to lines and adds the transition checks.
enum JourneyValidation {
    static func check(_ manifest: Manifest, at root: Field) {
        var seen: [String: Int] = [:]
        for (journey, field) in zip(manifest.journeys, root["journeys"].items(named: true)) {
            if let first = seen[journey.id] {
                field["id"].diagnose("duplicate journey '\(journey.id)' (first defined on line \(first))")
            } else {
                seen[journey.id] = field["id"].line
            }
            check(journey, in: manifest, at: field)
        }
    }

    private static func check(_ journey: Journey, in manifest: Manifest, at field: Field) {
        let steps = field["steps"].items(named: true)
        var ids: [String: Int] = [:]
        for (step, location) in zip(journey.steps, steps) {
            if let first = ids[step.id] {
                location["id"].diagnose("duplicate step '\(step.id)' in '\(journey.id)' (first defined on line \(first))")
            } else {
                ids[step.id] = location.line
            }
        }
        let playback = manifest.replay(journey)
        for issue in playback.issues {
            locate(issue.place, journey: field, steps: steps).diagnose(issue.message, issue.severity)
        }
        guard !playback.issues.contains(where: { $0.severity == .error }) else { return }
        for frame in playback.frames {
            for move in frame.moves { transition(move, frame: frame, in: manifest, at: steps[frame.index]) }
        }
        if let entity = playback.entity,
           !playback.frames.contains(where: { $0.diffs.contains { $0.row == entity } || $0.moves.contains { $0.row == entity } }) {
            field["entity"].diagnose("no step changes \(entity); add the rows and status codes each step changes", .warning)
        }
    }

    /// A move should follow a declared transition, made by this step's op or node when the transition says who.
    private static func transition(_ move: JourneyMove, frame: JourneyFrame, in manifest: Manifest, at step: Field) {
        guard let from = move.from, let def = manifest.enumDef(move.enumID) else { return }
        let location = place(of: move, step: frame.step, at: step)
        if let value = def.value(from), value.terminal {
            location.diagnose("\(def.title(value)) is terminal in '\(def.id)', but this step moves it to \(def.title(of: move.to))", .warning)
            return
        }
        let candidates = def.transitions.filter { $0.from == from && $0.to == move.to }
        guard !candidates.isEmpty else {
            let outs = def.transitions(from: from).map { t in def.title(of: t.to) + (t.by.map { " by \($0)" } ?? "") }
            var unique: [String] = []
            for out in outs where !unique.contains(out) { unique.append(out) }
            let hint = unique.isEmpty ? "nothing moves out of \(def.title(of: from))" : "from \(def.title(of: from)) it moves to " + unique.prefix(4).joined(separator: ", ")
            location.diagnose("'\(def.id)' has no transition \(def.title(of: from)) → \(def.title(of: move.to)); \(hint)", .warning)
            return
        }
        let actors = candidates.compactMap(\.by)
        guard actors.count == candidates.count, frame.op != nil || frame.node != nil else { return }
        if move.transition.map({ matches($0.by, frame: frame) }) == true { return }
        let ran = frame.op?.reference ?? frame.node ?? ""
        var unique: [String] = []
        for actor in actors where !unique.contains(actor) { unique.append(actor) }
        location.diagnose("\(def.title(of: from)) → \(def.title(of: move.to)) in '\(def.id)' is made by \(unique.joined(separator: " or ")), not \(ran)", .warning)
    }

    private static func matches(_ by: String?, frame: JourneyFrame) -> Bool {
        guard let by else { return false }
        if let op = frame.op, by == op.reference { return true }
        return !by.contains("/") && (by == frame.node || by == frame.op?.node)
    }

    /// Where a move was written: its `status:` entry, else the row change that set the column.
    private static func place(of move: JourneyMove, step: JourneyStep, at field: Field) -> Field {
        let statuses = field["status"].node?.fields != nil ? [field["status"]] : field["status"].items()
        if let k = step.status.firstIndex(where: { $0.enumID == move.enumID && $0.to == move.to }), statuses.indices.contains(k) {
            return statuses[k]
        }
        let changes = field["rows"].items()
        if let row = move.row, let column = move.column,
           let k = step.rows.firstIndex(where: { change in
               change.table.split(separator: ".").last.map(String.init) == row.table && change.values.contains { $0.column == column }
           }), changes.indices.contains(k) {
            let change = changes[k]
            let values = change["set"].present ? change["set"] : change["values"]
            return values[column].present ? values[column] : change
        }
        return field
    }

    private static func locate(_ place: JourneyIssue.Place, journey: Field, steps: [Field]) -> Field {
        func pick(_ field: Field, _ key: String) -> Field { field[key].present ? field[key] : field }
        func list(_ field: Field) -> [Field] { field.node?.fields != nil ? [field] : field.items() }
        switch place {
        case .entity(let key):
            return pick(journey["entity"], key)
        case .related(let index, let key):
            let related = list(journey["related"])
            return related.indices.contains(index) ? pick(related[index], key) : journey["related"]
        case .step(let index, let key):
            return steps.indices.contains(index) ? pick(steps[index], key) : journey["steps"]
        case .change(let step, let index, let key):
            guard steps.indices.contains(step) else { return journey["steps"] }
            let changes = steps[step]["rows"].items()
            guard changes.indices.contains(index) else { return pick(steps[step], "rows") }
            if key == "key", !changes[index]["key"].present { return pick(changes[index], "id") }
            if key == "set" || key == "values" {
                return changes[index]["set"].present ? changes[index]["set"] : pick(changes[index], "values")
            }
            return pick(changes[index], key)
        case .status(let step, let index, let key):
            guard steps.indices.contains(step) else { return journey["steps"] }
            let statuses = list(steps[step]["status"])
            return statuses.indices.contains(index) ? pick(statuses[index], key) : pick(steps[step], "status")
        }
    }
}
