import Foundation

// Ask keeps its questions and answers on this Mac only: one JSON Lines file per map in
// ~/.strata/ask/<id>.jsonl, and the on/off switch and the maps whose privacy notice was seen in
// ~/.strata/ask/settings.json. The directory is private to the user (0700).

public struct AskRecord: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case done, stopped, failed }

    public var id: String
    public var date: Date
    public var question: String
    public var answer: String
    /// The level the user was on, and the node selected there.
    public var path: [String]
    public var node: String?
    public var status: Status
    public var error: String?
    public var model: String?

    public init(id: String = UUID().uuidString, date: Date = Date(), question: String, answer: String, path: [String] = [],
                node: String? = nil, status: Status = .done, error: String? = nil, model: String? = nil) {
        self.id = id; self.date = date; self.question = question; self.answer = answer; self.path = path; self.node = node
        self.status = status; self.error = error; self.model = model
    }
}

public struct AskHistory: Sendable {
    public let url: URL

    public init(manifestID: String, root: URL = StrataPaths.ask) {
        url = root.appendingPathComponent("\(manifestID).jsonl")
    }

    /// The most recent `limit` records, oldest first. Lines that don't decode are skipped.
    public func load(limit: Int = 100) -> [AskRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = Self.decoder
        let records = text.split(separator: "\n").compactMap { line in
            try? decoder.decode(AskRecord.self, from: Data(line.utf8))
        }
        return Array(records.suffix(limit))
    }

    public func append(_ record: AskRecord) throws {
        try AskStorage.prepare(url.deletingLastPathComponent())
        var line = try Self.encoder.encode(record)
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The app's Ask switch and the maps whose privacy notice was acknowledged.
public struct AskSettings: Codable, Sendable, Equatable {
    public var enabled = true
    public var acknowledged: [String] = []

    public init(enabled: Bool = true, acknowledged: [String] = []) { self.enabled = enabled; self.acknowledged = acknowledged }

    public static func load(root: URL = StrataPaths.ask) -> AskSettings {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("settings.json")),
              let settings = try? JSONDecoder().decode(AskSettings.self, from: data) else { return AskSettings() }
        return settings
    }

    public func save(root: URL = StrataPaths.ask) throws {
        try AskStorage.prepare(root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(self).write(to: root.appendingPathComponent("settings.json"), options: .atomic)
    }
}

enum AskStorage {
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
