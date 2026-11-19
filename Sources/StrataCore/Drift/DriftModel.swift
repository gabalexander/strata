import Foundation

// Drift: what a map says about its repo that the repo no longer says (docs/manifest.md, Drift).
// `Drift.check` compares a manifest with the code at its `repo:` and returns a `DriftReport`; the CLI
// prints it (`strata drift`), the app caches it per map in ~/.strata/drift/<id>.json and badges the
// nodes it concerns. Everything here is plain values, Codable, so the cache and `--json` share a shape.

/// The families of facts drift compares.
public enum DriftKind: String, Codable, Sendable, CaseIterable, Comparable {
    case code, sql, binaries, messaging, enums

    public var title: String {
        switch self {
        case .code: "Code references"
        case .sql: "SQL"
        case .binaries: "Binaries"
        case .messaging: "Messaging and keys"
        case .enums: "Enums"
        }
    }

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// `error`: the map points at something that is gone. `warn`: it changed, or the repo has something
/// the map should show. `info`: a heuristic worth a look; it never lowers freshness.
public enum DriftSeverity: String, Codable, Sendable, CaseIterable, Comparable {
    case error, warn, info

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Where a finding sits in the map: the level (node ids, `node#op` for an op's `inside:`), then the
/// node, op, mechanism and step, or a top-level enum; `field` names the key that drifted.
public struct DriftMapLocation: Codable, Hashable, Sendable, CustomStringConvertible {
    public var level: [String] = []
    public var node: String?
    public var op: String?
    public var mechanism: String?
    public var step: String?
    public var enumID: String?
    public var field: String?
    /// The manifest line of the innermost element (step, mechanism, op, node or enum), for editing.
    public var line: Int?

    enum CodingKeys: String, CodingKey { case level, node, op, mechanism, step, enumID = "enum", field, line }

    public init(level: [String] = [], node: String? = nil, op: String? = nil, mechanism: String? = nil,
                step: String? = nil, enumID: String? = nil, field: String? = nil, line: Int? = nil) {
        self.level = level; self.node = node; self.op = op; self.mechanism = mechanism; self.step = step
        self.enumID = enumID; self.field = field; self.line = line
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try c.decodeIfPresent([String].self, forKey: .level) ?? []
        node = try c.decodeIfPresent(String.self, forKey: .node)
        op = try c.decodeIfPresent(String.self, forKey: .op)
        mechanism = try c.decodeIfPresent(String.self, forKey: .mechanism)
        step = try c.decodeIfPresent(String.self, forKey: .step)
        enumID = try c.decodeIfPresent(String.self, forKey: .enumID)
        field = try c.decodeIfPresent(String.self, forKey: .field)
        line = try c.decodeIfPresent(Int.self, forKey: .line)
    }

    /// `orders › handler · op insert-order · how lock · step s3 (code)`.
    public var description: String {
        var parts: [String] = []
        if let enumID { parts.append("enum \(enumID)") }
        if let node { parts.append((level + [node]).joined(separator: " › ")) }
        else if !level.isEmpty { parts.append(level.joined(separator: " › ")) }
        if let op { parts.append("op \(op)") }
        if let mechanism { parts.append("how \(mechanism)") }
        if let step { parts.append("step \(step)") }
        let text = parts.isEmpty ? "map" : parts.joined(separator: " · ")
        return field.map { "\(text) (\($0))" } ?? text
    }

}

/// A file (relative to the repo) and line.
public struct DriftRepoLocation: Codable, Hashable, Sendable, CustomStringConvertible {
    public var file: String
    public var line: Int?
    public init(file: String, line: Int? = nil) { self.file = file; self.line = line }
    public var description: String { line.map { "\(file):\($0)" } ?? file }
}

public struct DriftFinding: Codable, Hashable, Sendable, Identifiable {
    public var severity: DriftSeverity
    public var kind: DriftKind
    /// A stable name for the check that fired: `missing-file`, `query-changed`, `unmapped-binary`, ...
    public var rule: String
    /// One line: what no longer matches.
    public var message: String
    /// One line: what to change in the map.
    public var fix: String
    public var map: DriftMapLocation?
    public var repo: DriftRepoLocation?
    /// The map's value that drifted: a code reference, a query name, a binary, a topic or key, an enum value.
    public var ref: String?
    /// What the repo has instead, when drift found it: a moved path, a new query name or line.
    public var found: String?
    /// For a changed query: a compact line diff, `- map` and `+ repo` lines with a little context.
    public var diff: [String]?

    public init(_ severity: DriftSeverity, _ kind: DriftKind, _ rule: String, message: String, fix: String,
                map: DriftMapLocation? = nil, repo: DriftRepoLocation? = nil, ref: String? = nil,
                found: String? = nil, diff: [String]? = nil) {
        self.severity = severity; self.kind = kind; self.rule = rule; self.message = message; self.fix = fix
        self.map = map; self.repo = repo; self.ref = ref; self.found = found; self.diff = diff
    }

    public var id: String {
        [kind.rawValue, rule, map?.description ?? "", repo?.description ?? "", ref ?? "", message].joined(separator: "|")
    }

    /// True for a finding about something in the repo that no map fact covers.
    public var isUnmapped: Bool { rule.hasPrefix("unmapped") }
}

/// Per kind: how many map facts were compared, how many of them drifted, and the findings by severity.
public struct DriftKindSummary: Codable, Hashable, Sendable {
    public var kind: DriftKind
    public var checked = 0
    public var stale = 0
    public var errors = 0
    public var warnings = 0
    public var infos = 0
    /// Repo items (queries, binaries, names, values) that no map fact covers.
    public var unmapped = 0
    public init(kind: DriftKind) { self.kind = kind }
}

public struct DriftSummary: Codable, Hashable, Sendable {
    public var kinds: [DriftKindSummary] = []
    public var checked = 0
    public var stale = 0
    public var errors = 0
    public var warnings = 0
    public var infos = 0
    public var unmapped = 0
    /// 0–100: the share of checked map facts with no error or warning. Unmapped repo items and notes
    /// don't lower it: they are about coverage, not about what the map says.
    public var freshness = 100
    public init() {}

    public func kind(_ kind: DriftKind) -> DriftKindSummary? { kinds.first { $0.kind == kind } }
}

public enum DriftStatus: String, Codable, Sendable {
    /// Compared with the repo.
    case checked
    /// The manifest has no `repo:` and none was given.
    case noRepo = "no-repo"
    /// The repo isn't on this machine.
    case repoMissing = "repo-missing"
}

public struct DriftReport: Codable, Sendable {
    public static let formatVersion = 1

    public var version = DriftReport.formatVersion
    public var manifest: String
    public var title: String?
    /// The repo root compared, tilde-expanded.
    public var repo: String?
    public var status: DriftStatus
    /// The repo's HEAD commit when it was checked, if it is a git checkout.
    public var head: String?
    public var checkedAt: Date
    public var durationMs = 0
    /// Files indexed in the repo (after skipping vendor/, node_modules/, .git/ and generated dirs).
    public var files = 0
    /// The file cap was reached, so part of the repo wasn't indexed.
    public var truncated = false
    public var kinds: [DriftKind] = DriftKind.allCases
    /// A fingerprint of the manifest file the check ran on (the app reruns when the map changes).
    public var manifestDigest: String?
    public var summary = DriftSummary()
    public var findings: [DriftFinding] = []

    public init(manifest: String, title: String?, repo: String?, status: DriftStatus, checkedAt: Date = Date()) {
        self.manifest = manifest; self.title = title; self.repo = repo; self.status = status; self.checkedAt = checkedAt
    }

    public var isClean: Bool { summary.errors == 0 && summary.warnings == 0 }

    /// Findings located on `node` at `level`, or anywhere inside its deep dives and op levels.
    public func findings(level: [String], node: String, inside: Bool = true) -> [DriftFinding] {
        findings.filter { finding in
            guard let map = finding.map else { return false }
            if map.level == level { return map.node == node }
            guard inside, map.level.count > level.count, Array(map.level.prefix(level.count)) == level else { return false }
            let next = map.level[level.count]
            return next == node || next.hasPrefix(node + "#")
        }
    }

    /// Per node of the level at `level`: how many errors and warnings are on it or inside it.
    public func staleNodes(level: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        for finding in findings where finding.severity != .info {
            guard let map = finding.map else { continue }
            if map.level == level, let node = map.node {
                out[node, default: 0] += 1
            } else if map.level.count > level.count, Array(map.level.prefix(level.count)) == level {
                let next = map.level[level.count]
                let node = next.split(separator: "#", maxSplits: 1).first.map(String.init) ?? next
                out[node, default: 0] += 1
            }
        }
        return out
    }
}

extension Array where Element == DriftFinding {
    /// Worst first, then by kind, map location and repo location: the order the CLI and inspector show.
    func ordered() -> [DriftFinding] {
        sorted { a, b in
            if a.severity != b.severity { return a.severity < b.severity }
            if a.kind != b.kind { return a.kind < b.kind }
            let am = a.map?.description ?? "~", bm = b.map?.description ?? "~"
            if am != bm { return am < bm }
            let ar = a.repo?.description ?? "", br = b.repo?.description ?? ""
            if ar != br { return ar < br }
            return a.message < b.message
        }
    }
}
