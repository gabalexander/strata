import Foundation

// Journeys (docs/manifest.md, Journeys): one real entity followed end to end through the architecture,
// step by step: where each step happens, the op it runs with its placeholders filled in, the rows it
// changes and the status codes it moves. The decoded form, as written; JourneyReplay.swift replays it.

/// One column value in a journey: a row change's value, or part of a row key. nil is SQL NULL.
public struct JourneyCell: Sendable, Hashable {
    public var column: String
    public var value: String?
    public init(column: String, value: String?) { self.column = column; self.value = value }
}

/// How a journey names a row: a scalar `id` (the value of the table's first key column), or a map of
/// columns (`{ task_sid: 40017, create_time: … }`).
public struct JourneyKey: Sendable, Hashable, CustomStringConvertible {
    public var id: String?
    public var cells: [JourneyCell] = []
    public init(id: String) { self.id = id }
    public init(cells: [JourneyCell]) { self.cells = cells }
    public var description: String {
        id ?? cells.map { "\($0.column)=\($0.value ?? "NULL")" }.joined(separator: ", ")
    }
}

/// The entity a journey follows, or a related row it shows beside it: a table (`task`, or `pg.task`
/// when several databases have one) and a row of it.
public struct JourneyRowRef: Sendable {
    public var table: String
    public var key: JourneyKey?
    /// What the row is to a reader: `lead`, `attempt`, `order`.
    public var label: String?
    public var line: Int?
    public init(table: String, key: JourneyKey? = nil) { self.table = table; self.key = key }
}

public enum JourneyRowKind: String, Sendable, CaseIterable { case insert, update, delete }

/// A row a step inserts, updates or deletes.
public struct JourneyRowChange: Sendable {
    public var kind: JourneyRowKind
    public var table: String
    /// The row an update or delete changes; an insert takes its key from `values`.
    public var key: JourneyKey?
    /// An insert's values, or the columns an update sets.
    public var values: [JourneyCell] = []
    public var line: Int?
    public init(kind: JourneyRowKind, table: String) { self.kind = kind; self.table = table }
}

/// A status code a step moves: `from` nil means the value is entered (a new row, a first status).
public struct JourneyStatus: Sendable, Hashable {
    public var enumID: String
    public var from: String?
    public var to: String
    /// `table.column` when more than one row of the journey holds this enum.
    public var column: String?
    public var line: Int?
    public init(enumID: String, from: String?, to: String) { self.enumID = enumID; self.from = from; self.to = to }
}

/// A message a step publishes: the queue or topic node, the topic name, the routing key, the payload.
public struct JourneyMessage: Sendable {
    public var to: String?
    public var topic: String?
    public var key: String?
    public var payload: String?
    public var line: Int?
    public init() {}
}

/// A value for one of the op's placeholders: positional (`?`, `$1`) when `name` is nil, else named
/// (`@task_sid`, `:id`, `sqlc.arg(id)`, `{sku}` in a key pattern, `$2`).
public struct JourneyBind: Sendable, Hashable {
    public var name: String?
    public var value: String?
    /// Written quoted in YAML, so it is a string literal even when it reads as a number.
    public var quoted = false
    public init(name: String? = nil, value: String?, quoted: Bool = false) { self.name = name; self.value = value; self.quoted = quoted }
}

public struct JourneyStep: Sendable, Identifiable {
    public var id: String
    /// As written: an offset from the start (`40ms`), from the step before (`+16ms`), a wall clock
    /// (`14:31:17.020`) or a timestamp (`2026-11-19T14:31:17Z`).
    public var at: String?
    public var label: String
    /// Where it happens: a node on the level at `path` (the root by default).
    public var node: String?
    public var path: [String] = []
    /// The op it runs, `node/op` or an op id on `node`, resolved like a flow step's op.
    public var op: String?
    public var binds: [JourneyBind] = []
    public var rows: [JourneyRowChange] = []
    public var status: [JourneyStatus] = []
    public var message: JourneyMessage?
    public var note: String?
    /// A How it works mechanism that explains this step: `node/mechanism`.
    public var how: String?
    public var line: Int?
    public init(id: String, label: String) { self.id = id; self.label = label }
}

public struct Journey: Sendable, Identifiable {
    public var id: String
    public var title: String
    /// One line: what the journey shows.
    public var brief: String?
    public var entity: JourneyRowRef
    public var related: [JourneyRowRef] = []
    public var steps: [JourneyStep] = []
    public var line: Int?
    public init(id: String, title: String, entity: JourneyRowRef) { self.id = id; self.title = title; self.entity = entity }
}

public extension Manifest {
    func journey(_ id: String) -> Journey? { journeys.first { $0.id == id } }
}
