import Foundation

// Validation of `how:` mechanisms and `formula:` on nodes and operations (docs/manifest.md, How it
// works and Formulas).
extension LevelValidation {
    /// Checks the mechanisms and formula of a node and of each of its operations.
    func how(of node: Node, at field: Field) {
        mechanisms(node.how, at: field["how"])
        if let formula = node.formula { self.formula(formula, at: field["formula"]) }
        for (op, location) in zip(node.ops, field["ops"].items(named: true)) {
            mechanisms(op.how, at: location["how"])
            if let formula = op.formula { self.formula(formula, at: location["formula"]) }
        }
    }

    private func mechanisms(_ list: [Mechanism], at field: Field) {
        var seen: [String: Int] = [:]
        for (mechanism, location) in zip(list, field.items(named: true)) {
            if let first = seen[mechanism.id] {
                location["id"].diagnose("duplicate mechanism '\(mechanism.id)' (first defined on line \(first))")
            } else {
                seen[mechanism.id] = location.line
            }
            self.mechanism(mechanism, at: location)
        }
    }

    private func mechanism(_ mechanism: Mechanism, at field: Field) {
        var participants: [String: Int] = [:]
        for (participant, location) in zip(mechanism.participants, field["participants"].items(named: true)) {
            if let first = participants[participant.id] {
                location["id"].diagnose("duplicate participant '\(participant.id)' (first defined on line \(first))")
            } else {
                participants[participant.id] = location.line
            }
            if let node = participant.node, nodes[node] == nil {
                location["node"].diagnose("unknown node '\(node)'\(suggestion(node, among: nodes.keys))")
            }
        }

        let main = field["steps"].items(named: true)
        var mainIDs: [String: Int] = [:]
        var times: [String: Double] = [:]
        var time = 0.0
        for (step, location) in zip(mechanism.steps, main) {
            self.step(step, at: location, participants: participants, ids: &mainIDs, time: &time)
            times[step.id] = time
        }

        var branches: [String: Int] = [:]
        for (branch, location) in zip(mechanism.branches, field["branches"].items(named: true)) {
            if let first = branches[branch.id] {
                location["id"].diagnose("duplicate branch '\(branch.id)' (first defined on line \(first))")
            } else {
                branches[branch.id] = location.line
            }
            var start = 0.0
            var ids: [String: Int] = [:]
            if let after = branch.after {
                if let index = mechanism.steps.firstIndex(where: { $0.id == after }) {
                    start = times[after] ?? 0
                    for (step, location) in zip(mechanism.steps[...index], main) where ids[step.id] == nil {
                        ids[step.id] = location.line
                    }
                } else {
                    let fix = closestKey(to: after, in: mechanism.steps.map(\.id)).map { "; did you mean '\($0)'?" } ?? ""
                    location["after"].diagnose("unknown step '\(after)'; after names a step of the main sequence\(fix)")
                }
            }
            for (step, stepLocation) in zip(branch.steps, location["steps"].items(named: true)) {
                self.step(step, at: stepLocation, participants: participants, ids: &ids, time: &start)
            }
        }
    }

    /// One step: its participants exist, its id is new on this path, and its `at` doesn't go back in time.
    private func step(_ step: MechStep, at field: Field, participants: [String: Int], ids: inout [String: Int], time: inout Double) {
        if let first = ids[step.id] {
            (field["id"].present ? field["id"] : field).diagnose("duplicate step '\(step.id)' (first defined on line \(first))")
        } else {
            ids[step.id] = field.line
        }
        for (key, id) in [("from", step.from), ("to", step.to)] where participants[id] == nil {
            let fix = closestKey(to: id, in: Array(participants.keys)).map { "; did you mean '\($0)'?" } ?? ""
            field[key].diagnose("unknown participant '\(id)'\(fix)")
        }
        guard let at = step.at else { return }
        if at < time {
            field["at"].diagnose("at \(Self.seconds(at)) goes back in time; the step before it is at \(Self.seconds(time))", .warning)
        } else {
            time = at
        }
    }

    private func formula(_ formula: Formula, at field: Field) {
        for (name, _) in formula.vars where !formula.mentions(name) {
            field["where"][name].diagnose("'\(name)' does not appear in expr", .warning)
        }
    }

    private static func seconds(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        return (rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)) + "s"
    }
}
