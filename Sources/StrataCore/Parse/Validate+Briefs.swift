import Foundation

// Validation of briefs (docs/manifest.md, Briefs): a long doc, narration or summary without a one-line
// `brief:` is a warning, and so is a brief that isn't one short line.
enum BriefValidation {
    /// A node's doc and brief, then each op's, and the mechanisms of both.
    static func node(_ node: Node, at field: Field) {
        if node.kind != .note { long(node.doc, brief: node.brief, at: field["doc"], key: "doc", owner: "node") }
        shape(node.brief, at: field["brief"])
        mechanisms(node.how, at: field["how"])
        for (op, location) in zip(node.ops, field["ops"].items(named: true)) {
            long(op.doc, brief: op.brief, at: location["doc"], key: "doc", owner: "op")
            shape(op.brief, at: location["brief"])
            mechanisms(op.how, at: location["how"])
        }
    }

    static func level(_ level: Level, at field: Field) {
        long(level.narration, brief: level.brief, at: field["narration"], key: "narration", owner: "level")
        shape(level.brief, at: field["brief"])
    }

    static func flow(_ flow: Flow, at field: Field) {
        shape(flow.brief, at: field["brief"])
    }

    private static func mechanisms(_ list: [Mechanism], at field: Field) {
        for (mechanism, location) in zip(list, field.items(named: true)) {
            long(mechanism.summary, brief: mechanism.brief, at: location["summary"], key: "summary", owner: "mechanism")
            shape(mechanism.brief, at: location["brief"])
        }
    }

    /// `key` is too long to scan and there's no brief to show instead.
    private static func long(_ text: String?, brief: String?, at field: Field, key: String, owner: String) {
        guard let text, Brief.isLong(text), (brief ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = Brief.lineCount(trimmed)
        let size = trimmed.count > Brief.longCharacters
            ? "\(trimmed.count) characters" + (lines > 1 ? " on \(lines) lines" : "")
            : "\(lines) lines"
        field.diagnose("\(key) is \(size); add a one-line brief: to the \(owner) (what it is or does, about 100 characters) "
                       + "and cut the \(key) to \(Brief.longLines) short lines or bullets of the non-obvious facts",
                       .warning)
    }

    private static func shape(_ brief: String?, at field: Field) {
        guard let brief, let problem = Brief.briefProblem(brief) else { return }
        field.diagnose(problem, .warning)
    }
}
