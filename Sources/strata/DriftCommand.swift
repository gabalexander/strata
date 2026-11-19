import Foundation
import StrataCore

// `strata drift <id|path> [--repo PATH] [--json] [--kind code,sql,…] [--quiet]`: what the map says about
// its repo that the repo no longer says. Exit 0 when nothing drifted (notes alone don't count), 1 when
// there are errors or warnings, 2 when the check can't run (no manifest, no repo, bad arguments).

private let usage = "strata drift <id|path> [--repo PATH] [--json] [--kind code|sql|binaries|messaging|enums] [--quiet]"

@MainActor
func driftCommand(_ arguments: [String]) -> Int32 {
    do {
        let args = try Arguments(arguments, flags: ["--json", "--quiet"], options: ["--repo", "--kind"])
        try args.require(1, usage: usage)
        var kinds = Set(DriftKind.allCases)
        if let list = args.options["--kind"] {
            kinds = []
            for word in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
                guard let kind = DriftKind(rawValue: word) else {
                    throw CLIError("--kind takes \(DriftKind.allCases.map(\.rawValue).joined(separator: ", ")), not '\(word)'")
                }
                kinds.insert(kind)
            }
        }
        let entry = try loadEntry(args.positional[0], command: "drift")
        guard let manifest = entry.manifest else { return 2 }
        let repo = args.options["--repo"]
        let digest = DriftCache.digest(of: entry.url)
        let report = Drift.check(manifest, options: DriftOptions(repo: repo, kinds: kinds, manifestDigest: digest))
        // The app reads the same result: cache a full check of a library map against its own repo.
        if report.status == .checked, repo == nil, kinds.count == DriftKind.allCases.count, !entry.builtIn {
            try? DriftCache.save(report)
        }
        let json = args.flags.contains("--json")
        if json {
            print(String(decoding: try DriftCache.encoder.encode(report), as: UTF8.self))
        }
        switch report.status {
        case .noRepo:
            if !json { stderr("\(manifest.id) has no repo set (the repo: key); pass --repo PATH to compare it with a checkout") }
            return 2
        case .repoMissing:
            if !json { stderr("\(manifest.id): the repo \(tilde(report.repo ?? "")) isn't on this machine; pass --repo PATH") }
            return 2
        case .checked:
            break
        }
        if !json { print(args.flags.contains("--quiet") ? summaryLine(report) : renderDrift(report)) }
        return report.isClean ? 0 : 1
    } catch let error as CLIError {
        stderr("error: \(error.message)")
        return 2
    } catch {
        stderr("error: \(error.localizedDescription)")
        return 2
    }
}

private func tilde(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

private func plural(_ count: Int, _ word: String, _ many: String? = nil) -> String {
    "\(count) " + (count == 1 ? word : many ?? word + "s")
}

func summaryLine(_ report: DriftReport) -> String {
    let s = report.summary
    var parts = ["\(report.manifest)", "freshness \(s.freshness)%"]
    let counts = [s.errors > 0 ? plural(s.errors, "error") : nil, s.warnings > 0 ? plural(s.warnings, "warning") : nil,
                  s.infos > 0 ? plural(s.infos, "note") : nil].compactMap { $0 }
    parts.append(counts.isEmpty ? "no drift" : counts.joined(separator: ", "))
    if s.unmapped > 0 { parts.append("\(s.unmapped) repo \(s.unmapped == 1 ? "item" : "items") not on the map") }
    return parts.joined(separator: " · ")
}

/// Grouped by kind; within a kind, what the map says first (worst first, the same finding on several
/// map places printed once), then the repo items no map fact covers, by file.
func renderDrift(_ report: DriftReport) -> String {
    let s = report.summary
    var lines: [String] = []
    var header = "\(report.manifest) · drift against \(tilde(report.repo ?? ""))"
    if let head = report.head { header += " @ \(head.prefix(7))" }
    header += " · \(report.files) files in \(report.durationMs) ms"
    if report.truncated { header += " (file cap reached)" }
    lines.append(header)
    lines.append("freshness \(s.freshness)% · \(s.checked - s.stale) of \(plural(s.checked, "map fact")) still match · "
                 + summaryLine(report).split(separator: "·").dropFirst(2).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · "))
    for kind in report.kinds {
        guard let row = s.kind(kind) else { continue }
        let findings = report.findings.filter { $0.kind == kind }
        var title = "\(kind.title) · \(row.checked) checked"
        if row.stale > 0 { title += " · \(row.stale) stale" }
        if row.unmapped > 0 { title += " · \(row.unmapped) not on the map" }
        lines.append("")
        lines.append(title)
        if findings.isEmpty { lines.append("  ok"); continue }
        // The same finding on several map places (one file referenced from six nodes) prints once.
        var groups: [(finding: DriftFinding, places: [String])] = []
        for finding in findings where !finding.isUnmapped {
            let place = finding.map?.description ?? ""
            if let index = groups.firstIndex(where: { same($0.finding, finding) }) {
                groups[index].places.append(place)
            } else {
                groups.append((finding, [place]))
            }
        }
        for (finding, places) in groups {
            lines.append("  " + pad(finding.severity.rawValue, 6) + finding.message)
            var where_ = places.prefix(3).joined(separator: "; ")
            if places.count > 3 { where_ += "; +\(places.count - 3) more" }
            if let repo = finding.repo { where_ += (where_.isEmpty ? "" : " · ") + repo.description }
            if !where_.isEmpty { lines.append("        " + where_) }
            for line in finding.diff ?? [] { lines.append("          " + line) }
            lines.append("        fix: " + finding.fix)
        }
        let unmapped = findings.filter(\.isUnmapped)
        if !unmapped.isEmpty {
            lines.append("  not on the map")
            let byFile = Dictionary(grouping: unmapped) { $0.repo?.file ?? "" }
            for file in byFile.keys.sorted() {
                lines.append("    " + (file.isEmpty ? "(repo)" : file))
                for finding in byFile[file]!.sorted(by: { ($0.repo?.line ?? 0, $0.message) < ($1.repo?.line ?? 0, $1.message) }) {
                    let line = finding.repo?.line.map(String.init) ?? ""
                    lines.append("      " + pad(finding.severity.rawValue, 6) + pad(line, 5) + finding.message)
                }
            }
        }
    }
    return lines.joined(separator: "\n")
}

private func same(_ a: DriftFinding, _ b: DriftFinding) -> Bool {
    a.rule == b.rule && a.message == b.message && a.repo == b.repo && a.fix == b.fix && a.severity == b.severity
}

private func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
}
