import Foundation

/// Drift results per map in `~/.strata/drift/<id>.json`, with the repo HEAD and the manifest digest they
/// were computed for, so the app knows when to check again without walking the repo.
public enum DriftCache {
    public static var directory: URL { StrataPaths.home.appendingPathComponent("drift") }

    public static func url(for id: String) -> URL { directory.appendingPathComponent(id).appendingPathExtension("json") }

    public static func load(_ id: String) -> DriftReport? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        guard let report = try? decoder.decode(DriftReport.self, from: data), report.version == DriftReport.formatVersion else { return nil }
        return report
    }

    public static func save(_ report: DriftReport) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(report).write(to: url(for: report.manifest), options: .atomic)
    }

    /// The cached report still describes this map and repo: same manifest file, same HEAD, same repo path.
    public static func isCurrent(_ report: DriftReport, manifest: Manifest, digest: String?) -> Bool {
        guard report.status == .checked, report.kinds == DriftKind.allCases,
              report.repo == Drift.repoRoot(of: manifest), report.manifestDigest == digest else { return false }
        guard let root = report.repo else { return false }
        return DriftGit.head(URL(fileURLWithPath: root)) == report.head
    }

    /// A fingerprint of a manifest file (FNV-1a over its bytes).
    public static func digest(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// The manifest's file, when it has one (an inline map in a note has none).
    public static func file(of manifest: Manifest) -> URL? {
        switch manifest.source {
        case .file(let url), .bundled(let url): url
        case .inline: nil
        }
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
