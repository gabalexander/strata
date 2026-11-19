import Foundation
import StrataCore

// `strata journey <file|id> [--journey id] [--full]`: a journey (docs/manifest.md, Journeys) as a readable
// timeline: each step's time, where it happens, the op and the first line of its query with the binds
// filled in, the rows it changes and the status codes it moves.
// `strata journey draft <file|id> --entity <table> [--id N] [--as id]`: a skeleton journey from what the
// map already knows, printed as YAML to paste under journeys: and finish by hand.

@MainActor
func journeyCommand(_ arguments: [String]) throws -> Int32 {
    if arguments.first == "draft" {
        let args = try Arguments(Array(arguments.dropFirst()), options: ["--entity", "--id", "--as"])
        try args.require(1, usage: "strata journey draft <file|id> --entity <table> [--id <row id>] [--as <journey id>]")
        guard let table = args.options["--entity"] else {
            throw CLIError("usage: strata journey draft <file|id> --entity <table> [--id <row id>] [--as <journey id>]")
        }
        let entry = try loadEntry(args.positional[0], command: "journey draft")
        guard let manifest = entry.manifest else { return 1 }
        do {
            let draft = try manifest.draftJourney(table: table, id: args.options["--id"], journeyID: args.options["--as"])
            print(draft.yaml, terminator: "")
        } catch let error as JourneyDraftError {
            throw CLIError(error.message)
        }
        return 0
    }
    let args = try Arguments(arguments, flags: ["--full"], options: ["--journey"])
    try args.require(1, usage: "strata journey <file|id> [--journey <id>] [--full]\n       strata journey draft <file|id> --entity <table> [--id <row id>]")
    let entry = try loadEntry(args.positional[0], command: "journey")
    guard let manifest = entry.manifest else { return 1 }
    var journeys = manifest.journeys
    if let id = args.options["--journey"] {
        journeys = journeys.filter { $0.id == id }
        guard !journeys.isEmpty else {
            let known = manifest.journeys.map(\.id)
            throw CLIError("unknown journey '\(id)'" + (known.isEmpty ? "; \(manifest.id) has none" : "; choose \(known.joined(separator: ", "))"))
        }
    }
    guard !journeys.isEmpty else {
        print("No journeys in \(manifest.id). Draft one with: strata journey draft \(manifest.id) --entity <table>")
        return 0
    }
    let sections = journeys.map { JourneyTimeline(manifest: manifest, playback: manifest.replay($0), full: args.flags.contains("--full")).render() }
    print(sections.joined(separator: "\n\n"))
    return 0
}

struct JourneyTimeline {
    let manifest: Manifest
    let playback: JourneyPlayback
    var full = false

    func render() -> String {
        let journey = playback.journey
        var lines = ["\(manifest.id) › \(journey.id): \(journey.title)"]
        if let brief = journey.brief { lines.append("  " + brief) }
        if let entity = playback.entity { lines.append("  entity: " + describe(entity)) }
        if !playback.related.isEmpty { lines.append("  related: " + playback.related.map(describe).joined(separator: "; ")) }
        if let first = playback.frames.first?.instant, let date = JourneyClock.date(first) { lines.append("  date: \(date) (UTC)") }
        let width = String(playback.frames.count).count
        for frame in playback.frames {
            lines.append("")
            lines += step(frame, width: width)
        }
        let moves = timeline()
        if !moves.isEmpty {
            lines.append("")
            lines.append("status timeline")
            lines += moves.map { "  " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    private func describe(_ id: JourneyRowID) -> String {
        let role = playback.role(id).map { "\($0): " } ?? ""
        let place = id.path.isEmpty ? "" : " in \(id.path.joined(separator: "/"))"
        let inserted = playback.insertion(of: id).map { " (inserted at step \($0 + 1))" } ?? ""
        return "\(role)\(id.node).\(playback.title(id))\(place)\(inserted)"
    }

    private func step(_ frame: JourneyFrame, width: Int) -> [String] {
        let number = String(frame.index + 1).leftPad(width)
        let previous = frame.index > 0 ? playback.frames[frame.index - 1].instant : nil
        let time = [frame.instant.map(JourneyClock.format), JourneyClock.delta(frame.instant, after: previous)].compactMap { $0 }.joined(separator: " ")
        let place = ((frame.path.isEmpty ? [] : frame.path) + [frame.node ?? "?"]).joined(separator: " › ")
        let arrow = frame.op?.op.kind == .consume ? "←" : "→"
        let target = (frame.buffer ?? frame.target).map { " \(arrow) \($0)" } ?? ""
        var head = "\(number)  \(frame.step.id)"
        if !time.isEmpty { head += "  \(time)" }
        head += "  \(place)\(target)"
        if let op = frame.op { head += "  \(op.reference)" }
        var lines = [head, indent(width) + frame.step.label]
        if let command = frame.command { lines += self.command(command, width: width) }
        if let message = frame.step.message, let to = frame.buffer ?? message.to {
            let key = message.key.map { " key \($0)" } ?? ""
            lines.append(indent(width) + "message → \(to)\(key)")
        }
        for diff in frame.diffs { lines.append(indent(width) + row(diff, frame: frame)) }
        for move in frame.moves { lines.append(indent(width) + status(move)) }
        if let note = frame.step.note { lines.append(indent(width) + "note: " + StepCommand.oneLine(note)) }
        if let how = frame.step.how { lines.append(indent(width) + "how: \(how)") }
        return lines
    }

    private func indent(_ width: Int) -> String { String(repeating: " ", count: width + 2) }

    private func command(_ command: JourneyCommand, width: Int) -> [String] {
        let pad = indent(width)
        switch command.kind {
        case .sql:
            let statements = SQLFormat.statements(command.text, width: 100).filter { !$0.isTransactionControl }
            if full {
                return ["\(pad)SQL"] + statements.flatMap { $0.text.split(separator: "\n").map { pad + "  " + $0 } }
            }
            let first = statements.first.map { StepCommand.oneLine(Self.uncommented($0.text)) } ?? StepCommand.oneLine(command.text)
            let more = statements.count > 1 ? "  (+\(statements.count - 1) statement\(statements.count == 2 ? "" : "s"))" : ""
            return ["\(pad)SQL  \(cut(first, 150))\(more)"]
        case .redis:
            return ["\(pad)\(cut(StepCommand.oneLine(command.text), 160))"]
        case .message:
            return ["\(pad)\(command.title)  \(cut(StepCommand.oneLine(command.text), full ? 10_000 : 140))"]
        case .request:
            let body = command.text.isEmpty ? "" : "  " + cut(StepCommand.oneLine(command.text), full ? 10_000 : 120)
            return ["\(pad)\(command.title)\(body)"]
        }
    }

    /// SQL without its `--` comment lines (sqlc's `-- name:` header), for a one-line summary.
    static func uncommented(_ sql: String) -> String {
        sql.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }.joined(separator: "\n")
    }

    private func cut(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    private func row(_ diff: JourneyRowDiff, frame: JourneyFrame) -> String {
        let title = playback.title(diff.row)
        let enums = enumColumns(diff.row)
        func value(_ column: String, _ text: String?) -> String {
            guard let text else { return "NULL" }
            if let def = enums[column].flatMap(manifest.enumDef), def.value(text) != nil { return def.title(of: text) }
            return cut(text, 48)
        }
        switch diff.kind {
        case .insert:
            let cells = diff.cells.map { "\($0.column) \(value($0.column, $0.after))" }
            return "+ \(title): " + cells.joined(separator: ", ")
        case .update:
            let cells = diff.cells.map { "\($0.column) \(value($0.column, $0.before)) → \(value($0.column, $0.after))" }
            return "~ \(title): " + cells.joined(separator: ", ")
        case .delete:
            return "- \(title)"
        }
    }

    private func enumColumns(_ id: JourneyRowID) -> [String: String] {
        guard let schema = manifest.journeyTables("\(id.node).\(id.table)").first?.schema else { return [:] }
        return Dictionary(schema.columns.compactMap { column in column.enumRef.map { (column.name, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    private func status(_ move: JourneyMove) -> String {
        guard let def = manifest.enumDef(move.enumID) else { return "status \(move.enumID): \(move.from ?? "") → \(move.to)" }
        let from = move.from.map { def.title(of: $0) + " " } ?? ""
        let place = move.row.map { " on \(playback.title($0))\(move.column.map { ".\($0)" } ?? "")" } ?? ""
        var why: [String] = []
        if let label = move.transition?.label { why.append(label) }
        if let by = move.transition?.by { why.append("by \(by)") }
        return "status \(def.id)\(place): \(from)→ \(def.title(of: move.to))" + (why.isEmpty ? "" : " (\(why.joined(separator: ", ")))")
    }

    /// Each enum on each row, its codes in order: `task 5000101 status: 2100 → 2200 → 2300`.
    private func timeline() -> [String] {
        var order: [String] = []
        var chains: [String: [String]] = [:]
        for move in playback.moves {
            let key = "\(move.row.map { playback.title($0) + "." } ?? "")\(move.column ?? move.enumID)"
            if chains[key] == nil {
                order.append(key)
                chains[key] = move.from.map { [$0] } ?? []
            }
            chains[key]?.append(move.to)
        }
        return order.map { key in
            let enumID = playback.moves.first { "\($0.row.map { playback.title($0) + "." } ?? "")\($0.column ?? $0.enumID)" == key }?.enumID ?? ""
            let def = manifest.enumDef(enumID)
            let codes = (chains[key] ?? []).map { code in def.map { $0.title(of: code) } ?? code }
            return "\(key) (\(enumID)): " + codes.joined(separator: " → ")
        }
    }
}

private extension String {
    func leftPad(_ width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}
