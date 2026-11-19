import Foundation

public struct DriftOptions: Sendable {
    /// The repo to compare with; nil uses the manifest's `repo:`.
    public var repo: String?
    public var kinds: Set<DriftKind> = Set(DriftKind.allCases)
    public var maxFiles = 60_000
    public var maxFileBytes = 1_000_000
    /// Stored in the report so a cached result knows which version of the map it describes.
    public var manifestDigest: String?

    public init(repo: String? = nil, kinds: Set<DriftKind> = Set(DriftKind.allCases), manifestDigest: String? = nil) {
        self.repo = repo; self.kinds = kinds; self.manifestDigest = manifestDigest
    }
}

/// Compares a map with its repo (docs/manifest.md, Drift). Read-only and deterministic: the same map and
/// repo give the same findings in the same order.
public enum Drift {
    /// The repo root a check uses: the override, else the manifest's `repo:`, tilde-expanded.
    public static func repoRoot(of manifest: Manifest, override: String? = nil) -> String? {
        guard let path = override ?? manifest.repo, !path.isEmpty else { return nil }
        let expanded = StrataPaths.expand(path)
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded).standardizedFileURL.path
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).standardizedFileURL.path
    }

    /// True when the repo a check would use is a directory on this machine.
    public static func repoAvailable(_ manifest: Manifest, override: String? = nil) -> Bool {
        guard let root = repoRoot(of: manifest, override: override) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// A query's statements as drift compares them: comments, whitespace and keyword case don't count,
    /// `?`, `$1`, `:name`, `@name` and `sqlc.arg(x)` are one placeholder, `BEGIN`/`COMMIT` are dropped.
    /// `loose` also reads literals as placeholders and `IN (?, ?)` as `IN (?)`.
    public static func normalizedSQL(_ query: String, loose: Bool = false) -> [String] {
        DriftSQL.segments(query).flatMap { DriftSQL.statements($0.body) }.map { loose ? $0.looseKey : $0.exactKey }
    }

    public static func check(_ manifest: Manifest, options: DriftOptions = DriftOptions(), now: Date = Date()) -> DriftReport {
        let started = Date()
        let root = repoRoot(of: manifest, override: options.repo)
        var report = DriftReport(manifest: manifest.id, title: manifest.title, repo: root, status: .checked, checkedAt: now)
        report.kinds = DriftKind.allCases.filter(options.kinds.contains)
        report.manifestDigest = options.manifestDigest
        guard let root else {
            report.status = .noRepo
            return report
        }
        guard repoAvailable(manifest, override: options.repo) else {
            report.status = .repoMissing
            return report
        }
        let url = URL(fileURLWithPath: root)
        report.head = DriftGit.head(url)
        let indexed = Date()
        let repo = DriftRepo(root: url, maxFiles: options.maxFiles, maxFileBytes: options.maxFileBytes)
        let context = DriftContext(manifest: manifest, repo: repo, facts: DriftMapFacts(manifest))
        let timing = ProcessInfo.processInfo.environment["STRATA_DRIFT_TIMING"] != nil
        var mark = indexed
        func lap(_ name: String) {
            if timing { FileHandle.standardError.write(Data("\(name) \(Int(Date().timeIntervalSince(mark) * 1000)) ms\n".utf8)) }
            mark = Date()
        }
        lap("index")
        if options.kinds.contains(.code) { DriftCode.run(context); lap("code") }
        if options.kinds.contains(.sql) { DriftSQL.run(context); lap("sql") }
        if options.kinds.contains(.binaries) { DriftBinaries.run(context); lap("binaries") }
        if options.kinds.contains(.messaging) { DriftMessaging.run(context); lap("messaging") }
        if options.kinds.contains(.enums) { DriftEnums.run(context); lap("enums") }
        report.findings = context.findings.ordered()
        report.summary = context.summary(kinds: report.kinds)
        report.files = repo.files.count
        report.truncated = repo.truncated
        report.durationMs = Int(Date().timeIntervalSince(started) * 1000)
        return report
    }
}

/// One check's working state: the repo index, the map's facts, and what the checks found.
final class DriftContext {
    let manifest: Manifest
    let repo: DriftRepo
    let facts: DriftMapFacts
    private(set) var findings: [DriftFinding] = []
    private var seen: Set<String> = []
    private var checked: [DriftKind: Int] = [:]
    private var stale: [DriftKind: Set<String>] = [:]
    private var unmapped: [DriftKind: Int] = [:]

    init(manifest: Manifest, repo: DriftRepo, facts: DriftMapFacts) {
        self.manifest = manifest; self.repo = repo; self.facts = facts
    }

    /// Counts a map fact as compared.
    func checked(_ kind: DriftKind, _ count: Int = 1) { checked[kind, default: 0] += count }

    /// Adds a finding. `fact` names the map fact it is about, so a fact with several findings counts as
    /// stale once; unmapped findings count toward coverage instead.
    func add(_ finding: DriftFinding, fact: String? = nil) {
        guard seen.insert(finding.id).inserted else { return }
        findings.append(finding)
        if finding.isUnmapped { unmapped[finding.kind, default: 0] += 1 }
        if finding.severity != .info, let fact { stale[finding.kind, default: []].insert(fact) }
    }

    func summary(kinds: [DriftKind]) -> DriftSummary {
        var summary = DriftSummary()
        for kind in kinds {
            var row = DriftKindSummary(kind: kind)
            row.checked = checked[kind, default: 0]
            row.stale = min(row.checked, stale[kind]?.count ?? 0)
            row.unmapped = unmapped[kind, default: 0]
            for finding in findings where finding.kind == kind {
                switch finding.severity {
                case .error: row.errors += 1
                case .warn: row.warnings += 1
                case .info: row.infos += 1
                }
            }
            summary.kinds.append(row)
            summary.checked += row.checked
            summary.stale += row.stale
            summary.errors += row.errors
            summary.warnings += row.warnings
            summary.infos += row.infos
            summary.unmapped += row.unmapped
        }
        summary.freshness = summary.checked == 0 ? 100
            : Int((Double(summary.checked - summary.stale) / Double(summary.checked) * 100).rounded(.down))
        return summary
    }
}
