import Foundation
import StrataCore

// `strata enums <file|id> [--find <text>] [--json]`: each enum's values and its transitions, the
// columns linked to it and the ops that use it, so an agent can check the state machine it extracted.

struct EnumListing: Encodable {
    struct Value: Encodable { let value: String; let name: String; let doc: String?; let terminal: Bool }
    struct Transition: Encodable { let from: String; let to: String; let label: String?; let by: String? }
    struct OpUse: Encodable { let level: String; let node: String; let op: String; let values: [String] }

    let id: String
    let label: String
    let doc: String?
    let code: [String]
    let values: [Value]
    let transitions: [Transition]
    /// `node.table.column`, with `level: ` in front for a deep dive.
    let columns: [String]
    let ops: [OpUse]
    let line: Int?
}

@MainActor
func listEnums(_ args: Arguments) throws -> Int32 {
    let entry = try loadEntry(args.positional[0], command: "enums")
    guard let manifest = entry.manifest else { return 1 }
    var defs = manifest.enums
    var only: [String: Set<String>] = [:]   // enum id → values to show; absent means all
    if let query = args.options["--find"] {
        let hits = manifest.searchEnums(query)
        guard !hits.isEmpty else {
            print("No enum value matches '\(query)' in \(manifest.id).")
            return 1
        }
        defs = defs.filter { def in hits.contains { $0.enumID == def.id } }
        // A query that names the enum itself shows all of it; otherwise only the values it found.
        let whole = Set(hits.filter { $0.value == nil }.map(\.enumID))
        for hit in hits where !whole.contains(hit.enumID) {
            if let value = hit.value { only[hit.enumID, default: []].insert(value) }
        }
    }
    let listings = defs.map { def in listing(def, in: manifest) }
    if args.flags.contains("--json") {
        try printJSON(listings)
        return 0
    }
    print(renderEnums(listings, manifest: manifest, only: only))
    return 0
}

private func levelName(_ path: [String]) -> String { path.joined(separator: "/") }

private func listing(_ def: EnumDef, in manifest: Manifest) -> EnumListing {
    let usage = manifest.enumUsage(def.id)
    return EnumListing(
        id: def.id, label: def.label, doc: def.doc, code: def.code,
        values: def.values.map { .init(value: $0.value, name: $0.name, doc: $0.doc, terminal: $0.terminal) },
        transitions: def.transitions.map { .init(from: $0.from, to: $0.to, label: $0.label, by: $0.by) },
        columns: usage.columns.map { ($0.path.isEmpty ? "" : levelName($0.path) + ": ") + $0.column.description },
        ops: usage.ops.map { .init(level: levelName($0.path), node: $0.node, op: $0.op, values: $0.values) },
        line: def.line)
}

func renderEnums(_ listings: [EnumListing], manifest: Manifest, only: [String: Set<String>] = [:]) -> String {
    guard !listings.isEmpty else { return "No enums in \(manifest.id)." }
    var lines: [String] = ["\(manifest.id) · \(listings.count) \(listings.count == 1 ? "enum" : "enums")"]
    for listing in listings {
        guard let def = manifest.enumDef(listing.id) else { continue }
        let shown = only[listing.id]
        lines.append("")
        lines.append("\(listing.id) · \(listing.label)" + (listing.columns.isEmpty ? "" : " · " + listing.columns.joined(separator: ", ")))
        if let doc = listing.doc { lines.append("  " + flat(doc)) }
        let values = listing.values.filter { shown?.contains($0.value) ?? true }
        // String enums often use the name as the value: print it once.
        let coded = listing.values.contains { $0.value != $0.name }
        let codeWidth = coded ? values.map(\.value.count).max() ?? 0 : 0
        let nameWidth = values.map(\.name.count).max() ?? 0
        for value in values {
            var line = "  " + (coded ? pad(value.value, codeWidth) + "  " : "") + pad(value.name, nameWidth)
            let notes = [value.terminal ? "terminal" : nil, value.doc.map(flat)].compactMap { $0 }
            if !notes.isEmpty { line += "  " + notes.joined(separator: " · ") }
            lines.append(line.trimmingTrailing())
        }
        let transitions = def.transitions.filter { shown == nil || shown!.contains($0.from) || shown!.contains($0.to) }
        if !transitions.isEmpty {
            lines.append("  transitions")
            for transition in transitions {
                let detail = [transition.label, transition.by.map { "by \($0)" }].compactMap { $0 }.joined(separator: ", ")
                lines.append("    \(def.title(of: transition.from)) → \(def.title(of: transition.to))" + (detail.isEmpty ? "" : " (\(detail))"))
            }
        }
        if !listing.ops.isEmpty {
            let ops = listing.ops.map { use in
                (use.level.isEmpty ? "" : use.level + ": ") + "\(use.node)/\(use.op)" + (use.values.isEmpty ? "" : " [\(use.values.joined(separator: ", "))]")
            }
            lines.append("  used by")
            lines += ops.map { "    " + $0 }
        }
        if !listing.code.isEmpty { lines.append("  code " + listing.code.joined(separator: ", ")) }
    }
    return lines.joined(separator: "\n")
}

private func flat(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
}

private func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

private extension String {
    func trimmingTrailing() -> String {
        var text = self
        while text.last == " " { text.removeLast() }
        return text
    }
}
