import Foundation

struct LibraryFile {
    var entry: Library.Entry
    let document: YAMLNode?
    let declaredID: String?

    init(_ url: URL, builtIn: Bool) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let result = ManifestParser.parseDocument(text, source: builtIn ? .bundled(url) : .file(url))
            self.init(url: url, builtIn: builtIn, manifest: result.manifest, document: result.document, diagnostics: result.diagnostics)
        } catch {
            self.init(failureAt: url, builtIn: builtIn, message: "could not read manifest: \(error.localizedDescription)")
        }
    }

    init(failureAt url: URL, builtIn: Bool = false, message: String) {
        self.init(url: url, builtIn: builtIn, manifest: nil, document: nil, diagnostics: [Diagnostic(.error, message, line: 1)])
    }

    private init(url: URL, builtIn: Bool, manifest: Manifest?, document: YAMLNode?, diagnostics: [Diagnostic]) {
        let filename = url.deletingPathExtension().lastPathComponent
        self.document = document
        declaredID = document?["id"]?.scalar.flatMap { Syntax.isID($0) ? $0 : nil }
        entry = Library.Entry(id: manifest?.id ?? declaredID ?? filename, title: manifest?.title ?? document?["title"]?.scalar ?? filename,
                              kind: manifest?.kind ?? document?["kind"]?.scalar.flatMap(ManifestKind.init(rawValue:)) ?? .sim,
                              category: manifest?.category, summary: manifest?.summary, tags: manifest?.tags ?? [],
                              url: url, builtIn: builtIn, diagnostics: diagnostics, manifest: manifest)
    }

    mutating func markDuplicate(first path: String) {
        entry.manifest = nil
        let error = Diagnostic(.error, "duplicate manifest id '\(entry.id)'; first defined in \(path)",
                               line: document?["id"]?.line ?? 1, path: "id")
        entry.diagnostics = ManifestParser.sorted(entry.diagnostics + [error])
    }

    mutating func checkDetails(known ids: Set<String>) {
        guard let manifest = entry.manifest else { return }
        let findings = Findings()
        func check(_ level: Level, at field: Field) {
            for (node, location) in zip(level.nodes, field["nodes"].items(named: true)) {
                if let detail = node.detail, !ids.contains(detail) {
                    location["detail"].diagnose("unknown detail manifest '\(detail)'; add it to the library or check its id", .warning)
                }
                if let inside = node.inside { check(inside, at: location["inside"]) }
                for (op, opLocation) in zip(node.ops, location["ops"].items(named: true)) {
                    if let detail = op.detail, !ids.contains(detail) {
                        opLocation["detail"].diagnose("unknown detail manifest '\(detail)'; add it to the library or check its id", .warning)
                    }
                    if let inside = op.inside { check(inside, at: opLocation["inside"]) }
                }
            }
        }
        check(manifest.root, at: Field(document, findings: findings))
        entry.diagnostics = ManifestParser.sorted(entry.diagnostics + findings.diagnostics)
    }

    static func copy(_ text: String, replacingIDWith id: String) throws -> Data {
        let document = try YAML.parse(text)
        guard let fields = document.fields else { throw InvalidValue("expected a manifest mapping") }
        let updated = fields.map { field in
            field.key == "id" ? YAMLPair(key: "id", line: field.line, value: .plain(id, line: field.value.line)) : field
        }
        return Data((render(YAMLNode(content: .map(updated), line: document.line)) + "\n").utf8)
    }

    // JSON-compatible flow syntax also works for top-level flow mappings and quoted or multiline ids.
    private static func render(_ node: YAMLNode, indent: String = "") -> String {
        switch node.content {
        case .null: return "null"
        case .scalar(let text, let quoted):
            if !quoted, let flag = Syntax.bool(text) { return String(flag) }
            if !quoted, Syntax.number(text) != nil { return text }
            return JSONQuoted.string(text)
        case .list(let items):
            return "[" + items.map { render($0, indent: indent) }.joined(separator: ", ") + "]"
        case .map(let fields):
            if fields.isEmpty { return "{}" }
            let childIndent = indent + "  "
            let pairs = fields.map { childIndent + JSONQuoted.string($0.key) + ": " + render($0.value, indent: childIndent) }
            return "{\n" + pairs.joined(separator: ",\n") + "\n" + indent + "}"
        }
    }
}

private enum JSONQuoted {
    static func string(_ text: String) -> String {
        // Encoding a String cannot fail.
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }
}
