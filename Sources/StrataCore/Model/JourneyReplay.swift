import Foundation

// Replaying a journey (docs/manifest.md, Journeys): where each step happens, its op resolved and its
// placeholders filled, and every row the journey knows as it is after each step, with what the step
// changed and the status codes it moved. Additive helpers next to the contract types: the validator,
// `strata journey` and the player all replay a journey the same way.

/// A table somewhere in the manifest: the level, the node that holds it, its schema.
public struct JourneyTableSite: Sendable {
    public var path: [String]
    public var node: String
    public var schema: TableSchema
    public var ref: TableRef { TableRef(node: node, table: schema.name) }
}

/// A row the journey follows or touches: a table on a node, and the value of its first key column.
public struct JourneyRowID: Sendable, Hashable, CustomStringConvertible {
    public var path: [String]
    public var node: String
    public var table: String
    public var key: String
    public init(path: [String], node: String, table: String, key: String) {
        self.path = path; self.node = node; self.table = table; self.key = key
    }
    /// `task 5000101`: the first part of a composite key is enough to name a row in a message.
    public var description: String { "\(table) \(key.split(separator: ",", maxSplits: 1).first.map(String.init) ?? key)" }
}

/// A row's values at one moment. `exists` is false before its insert and after its delete.
public struct JourneyRow: Sendable, Equatable {
    public var id: JourneyRowID
    public var columns: [String]
    public var values: [String?]
    public var exists: Bool
    /// The sample row it started as, by index into the table's `rows`.
    public var sample: Int?

    public func value(_ column: String) -> String? {
        columns.firstIndex(of: column).flatMap { values.indices.contains($0) ? values[$0] : nil }
    }
}

public struct JourneyCellChange: Sendable, Hashable {
    public var column: String
    public var before: String?
    public var after: String?
    public init(column: String, before: String?, after: String?) { self.column = column; self.before = before; self.after = after }
}

/// What one step did to one row: the cells that changed (an insert's non-NULL values, a delete's
/// every value).
public struct JourneyRowDiff: Sendable {
    public var row: JourneyRowID
    public var kind: JourneyRowKind
    public var cells: [JourneyCellChange]
    /// The change's index in the step's `rows`; nil when a `status:` caused it.
    public var change: Int?
}

/// A status code moving: an enum column changing, or a `status:` that no row holds.
public struct JourneyMove: Sendable, Hashable {
    public var enumID: String
    public var from: String?
    public var to: String
    public var row: JourneyRowID?
    public var column: String?
    /// The step it happens at, from 0.
    public var step: Int
    /// The declared transition it follows (nil when the enum has none for it, or the value is entered).
    public var transition: EnumTransition?
}

/// The op a step runs, where it lives.
public struct JourneyOpSite: Sendable {
    public var path: [String]
    public var node: String
    public var op: Operation
    public var reference: String { "\(node)/\(op.id)" }
}

/// What the step sends, filled in: a query, a Valkey command, a message, a request.
public struct JourneyCommand: Sendable {
    public enum Kind: String, Sendable { case sql, redis, message, request }
    public var kind: Kind
    public var title: String
    public var text: String
    /// The op's text before filling.
    public var template: String
    public var fill: JourneyFill.Result?
}

/// One step as replayed.
public struct JourneyFrame: Sendable {
    public var index: Int
    public var step: JourneyStep
    /// The level the step happens on, and the node there (nil when neither `node` nor `op` resolves).
    public var path: [String]
    public var node: String?
    public var op: JourneyOpSite?
    /// The node the op talks to on that level (a database, a cache, a callee).
    public var target: String?
    /// The queue or topic the step's message goes to, on that level.
    public var buffer: String?
    public var command: JourneyCommand?
    public var instant: JourneyInstant?
    /// Every row the journey knows after this step, in the playback's row order.
    public var rows: [JourneyRow]
    public var diffs: [JourneyRowDiff]
    public var moves: [JourneyMove]

    public func row(_ id: JourneyRowID) -> JourneyRow? { rows.first { $0.id == id } }
    public func diff(_ id: JourneyRowID) -> JourneyRowDiff? { diffs.first { $0.row == id } }
}

/// A problem found while replaying, with where it is, for the validator.
public struct JourneyIssue: Sendable {
    public enum Place: Sendable, Hashable {
        case entity(String)
        case related(Int, String)
        case step(Int, String)
        case change(step: Int, index: Int, key: String)
        case status(step: Int, index: Int, key: String)
    }
    public var place: Place
    public var severity: Diagnostic.Severity
    public var message: String
}

public struct JourneyPlayback: Sendable {
    public var journey: Journey
    public var entity: JourneyRowID?
    public var related: [JourneyRowID]
    /// Rows before the first step, in row order: the entity, the related rows, then rows steps touch.
    public var initial: [JourneyRow]
    public var frames: [JourneyFrame]
    public var issues: [JourneyIssue]

    public var moves: [JourneyMove] { frames.flatMap(\.moves) }
    /// The rows as they are after step `index` (-1: before the first).
    public func rows(after index: Int) -> [JourneyRow] { index < 0 ? initial : frames[min(index, frames.count - 1)].rows }
    /// A row's key for people: a composite key's first column (`5000101`) unless another row of the
    /// table in this journey shares it, then every part (`o_9k8 · C-3`).
    public func keyLabel(_ id: JourneyRowID) -> String {
        let parts = id.key.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return id.key }
        let shared = initial.contains { other in
            other.id != id && other.id.table == id.table && other.id.node == id.node
                && other.id.key.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) == parts[0]
        }
        return shared ? parts.joined(separator: " · ") : parts[0]
    }

    /// `task 5000101`.
    public func title(_ id: JourneyRowID) -> String { "\(id.table) \(keyLabel(id))" }

    /// The label the journey gives a row (`lead`), for the entity and related rows.
    public func role(_ id: JourneyRowID) -> String? {
        if id == entity { return journey.entity.label }
        guard let index = related.firstIndex(of: id), journey.related.indices.contains(index) else { return nil }
        return journey.related[index].label
    }

    /// The step that first inserts a row, if one does.
    public func insertion(of id: JourneyRowID) -> Int? {
        frames.firstIndex { $0.diffs.contains { $0.row == id && $0.kind == .insert } }
    }
}

public extension Manifest {
    /// Tables named `table` (or `node.table`) on any level: the shallowest first.
    func journeyTables(_ name: String) -> [JourneyTableSite] {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        let (nodeID, table) = parts.count == 2 ? (Optional(parts[0]), parts[1]) : (nil, parts[0])
        var sites: [JourneyTableSite] = []
        for (path, level) in everyLevel() {
            for node in level.nodes where nodeID == nil || node.id == nodeID {
                if let schema = node.schema.first(where: { $0.name == table }) {
                    sites.append(JourneyTableSite(path: path, node: node.id, schema: schema))
                }
            }
        }
        return sites.sorted { $0.path.count < $1.path.count }
    }

    /// Every table name on any level, for suggestions.
    func journeyTableNames() -> [String] {
        var names: [String] = []
        for (_, level) in everyLevel() {
            for node in level.nodes { for table in node.schema where !names.contains(table.name) { names.append(table.name) } }
        }
        return names
    }

    /// A step's op: `node/op` on the step's level (`../op` names the op of the node a deep dive is
    /// inside), else on the shallowest level that has that node and op; a plain id on the step's node,
    /// then on the node the level is inside.
    func resolveJourneyOp(_ reference: String, node: String?, path: [String]) -> JourneyOpSite? {
        let level = self.level(at: path)
        var owner: (path: [String], node: Node)?
        if let last = path.last, !last.contains("#"), let parent = self.level(at: Array(path.dropLast())), let node = parent.node(last) {
            owner = (Array(path.dropLast()), node)
        }
        func ownerOp(_ id: String) -> JourneyOpSite? {
            guard let owner, let op = owner.node.ops.first(where: { $0.id == id }) else { return nil }
            return JourneyOpSite(path: owner.path, node: owner.node.id, op: op)
        }
        if let slash = reference.firstIndex(of: "/") {
            let nodeID = String(reference[..<slash]), opID = String(reference[reference.index(after: slash)...])
            if nodeID == InheritedOps.ownerKey { return ownerOp(opID) }
            if let op = level?.node(nodeID)?.ops.first(where: { $0.id == opID }) { return JourneyOpSite(path: path, node: nodeID, op: op) }
            if owner?.node.id == nodeID, let site = ownerOp(opID) { return site }
            for (levelPath, other) in everyLevel().sorted(by: { $0.path.count < $1.path.count }) {
                if let op = other.node(nodeID)?.ops.first(where: { $0.id == opID }) { return JourneyOpSite(path: levelPath, node: nodeID, op: op) }
            }
            return nil
        }
        if let node, let op = level?.node(node)?.ops.first(where: { $0.id == reference }) {
            return JourneyOpSite(path: path, node: node, op: op)
        }
        return ownerOp(reference)
    }

    /// A step's `how: node/mechanism`: the node's own mechanisms, then its ops', on the shallowest level.
    func resolveJourneyHow(_ reference: String) -> (path: [String], node: String, op: String?, mechanism: Mechanism)? {
        let parts = reference.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        for (path, level) in everyLevel().sorted(by: { $0.path.count < $1.path.count }) {
            guard let node = level.node(parts[0]) else { continue }
            if let mechanism = node.how.first(where: { $0.id == parts[1] }) { return (path, node.id, nil, mechanism) }
            for op in node.ops {
                if let mechanism = op.how.first(where: { $0.id == parts[1] }) { return (path, node.id, op.id, mechanism) }
            }
        }
        return nil
    }

    /// Replays a journey: the rows it knows before and after each step.
    func replay(_ journey: Journey) -> JourneyPlayback {
        var replayer = JourneyReplayer(manifest: self, journey: journey)
        return replayer.run()
    }
}

private struct JourneyReplayer {
    let manifest: Manifest
    let journey: Journey
    var issues: [JourneyIssue] = []
    var rows: [JourneyRowID: JourneyRow] = [:]
    var order: [JourneyRowID] = []
    /// The last payload a step sent to each queue or topic, which a later consume step receives.
    var sent: [String: String] = [:]

    init(manifest: Manifest, journey: Journey) {
        self.manifest = manifest
        self.journey = journey
    }

    mutating func issue(_ place: JourneyIssue.Place, _ message: String, _ severity: Diagnostic.Severity = .error) {
        issues.append(JourneyIssue(place: place, severity: severity, message: message))
    }

    /// The one table a name means, or an issue.
    mutating func table(_ name: String, at place: JourneyIssue.Place) -> JourneyTableSite? {
        let sites = manifest.journeyTables(name)
        guard let first = sites.first else {
            let bare = name.split(separator: ".").last.map(String.init) ?? name
            let fix = closestKey(to: bare, in: manifest.journeyTableNames()).map { "; did you mean '\($0)'?" } ?? ""
            let owner = name.contains(".") ? " on that node" : ""
            issue(place, "unknown table '\(name)'\(owner)\(fix)")
            return nil
        }
        let tied = sites.filter { $0.path.count == first.path.count }
        if tied.count > 1 {
            issue(place, "'\(name)' is a table on \(tied.map(\.node).joined(separator: " and ")); write \(tied[0].node).\(first.schema.name)")
        }
        return first
    }

    /// The columns that key a row: the table's primary key, else its first column.
    static func keyColumns(_ schema: TableSchema) -> [String] {
        let primary = schema.primaryKey.map(\.name)
        return primary.isEmpty ? schema.columns.prefix(1).map(\.name) : primary
    }

    /// A row's key from its values: the key columns that are set, joined by ","; nil without the first.
    static func compositeKey(_ schema: TableSchema, _ value: (String) -> String?) -> String? {
        let columns = keyColumns(schema)
        guard let first = columns.first, value(first) != nil else { return nil }
        return columns.compactMap(value).joined(separator: ",")
    }

    /// Rows a key may name: those known so far, the ones steps insert, and the sample rows.
    func candidates(in site: JourneyTableSite) -> [(key: String, cells: (String) -> String?)] {
        var found: [(key: String, cells: (String) -> String?)] = []
        for id in order where id.table == site.schema.name && id.node == site.node {
            if let row = rows[id] { found.append((id.key, { row.value($0) })) }
        }
        for step in journey.steps {
            for change in step.rows where change.kind == .insert {
                guard let other = manifest.journeyTables(change.table).first, other.node == site.node, other.schema.name == site.schema.name else { continue }
                let values = change.values
                let lookup: (String) -> String? = { column in values.first { $0.column == column }?.value }
                if let key = Self.compositeKey(site.schema, lookup) { found.append((key, lookup)) }
            }
        }
        for values in site.schema.rows {
            let lookup: (String) -> String? = { column in
                site.schema.columnIndex(column).flatMap { values.indices.contains($0) ? values[$0] : nil }
            }
            if let key = Self.compositeKey(site.schema, lookup) { found.append((key, lookup)) }
        }
        return found
    }

    /// The row key a JourneyKey names in a table. A scalar id is the whole key, or the first key column
    /// of a composite key; a map names the key columns, or any columns that pick out one row.
    func keyValue(_ key: JourneyKey, in site: JourneyTableSite) -> String? {
        let columns = Self.keyColumns(site.schema)
        guard let first = columns.first else { return nil }
        var scalar = key.id
        if scalar == nil {
            if columns.allSatisfy({ column in key.cells.contains { $0.column == column } }) {
                return Self.compositeKey(site.schema) { column in key.cells.first { $0.column == column }?.value }
            }
            scalar = key.cells.first { $0.column == first }?.value
        }
        let known = candidates(in: site)
        if let scalar {
            guard columns.count > 1 else { return scalar }
            if known.contains(where: { $0.key == scalar }) { return scalar }
            return known.first { $0.cells(first) == scalar }?.key ?? scalar
        }
        return known.first { candidate in key.cells.allSatisfy { candidate.cells($0.column) == $0.value } }?.key
    }

    func sampleRow(_ key: String, in site: JourneyTableSite) -> Int? {
        site.schema.rows.indices.first { row in
            Self.compositeKey(site.schema) { column in site.schema.columnIndex(column).flatMap { site.schema.value(row: row, column: $0) } } == key
        }
    }

    /// The row's state so far: known already, else its sample row, else absent.
    mutating func load(_ id: JourneyRowID, site: JourneyTableSite) -> JourneyRow {
        if let row = rows[id] { return row }
        let columns = site.schema.columns.map(\.name)
        var row = JourneyRow(id: id, columns: columns, values: Array(repeating: nil, count: columns.count), exists: false)
        if let sample = sampleRow(id.key, in: site) {
            let values = site.schema.rows[sample]
            row.values = (0..<columns.count).map { values.indices.contains($0) ? values[$0] : nil }
            row.exists = true
            row.sample = sample
        }
        rows[id] = row
        if !order.contains(id) { order.append(id) }
        return row
    }

    mutating func reference(_ ref: JourneyRowRef, at place: (String) -> JourneyIssue.Place, inserted: Set<String>) -> JourneyRowID? {
        guard let site = table(ref.table, at: place("table")) else { return nil }
        var key = ref.key.flatMap { keyValue($0, in: site) }
        if key == nil, ref.key == nil {
            // No id: the row a step inserts into this table first, else its first sample row.
            key = firstInsert(into: site) ?? (site.schema.rows.isEmpty ? nil : Self.compositeKey(site.schema) { column in
                site.schema.columnIndex(column).flatMap { site.schema.value(row: 0, column: $0) }
            })
        }
        guard let key else {
            issue(place(ref.key == nil ? "table" : "id"), ref.key == nil ? "'\(site.schema.name)' has no sample rows and no step inserts one; name the row with id"
                                                                         : "no row of '\(site.schema.name)' matches \(ref.key?.description ?? "")")
            return nil
        }
        let id = JourneyRowID(path: site.path, node: site.node, table: site.schema.name, key: key)
        let row = load(id, site: site)
        if !row.exists, !inserted.contains("\(site.node).\(site.schema.name).\(key)") {
            let samples = site.schema.rows.indices.compactMap { row in
                Self.compositeKey(site.schema) { column in site.schema.columnIndex(column).flatMap { site.schema.value(row: row, column: $0) } }
            }
            let fix = closestKey(to: key, in: samples).map { "; did you mean \($0)?" } ?? (samples.isEmpty ? "" : "; sample ids: \(samples.prefix(6).joined(separator: ", "))")
            issue(place(ref.key == nil ? "table" : "id"), "\(site.schema.name) \(key) is not a sample row and no step inserts it\(fix)")
        }
        return id
    }

    /// The key of the first row a step inserts into a table.
    func firstInsert(into site: JourneyTableSite) -> String? {
        for step in journey.steps {
            for change in step.rows where change.kind == .insert {
                let sites = manifest.journeyTables(change.table)
                guard let other = sites.first, other.node == site.node, other.schema.name == site.schema.name else { continue }
                if let key = Self.insertKey(change, site.schema) { return key }
            }
        }
        return nil
    }

    static func insertKey(_ change: JourneyRowChange, _ schema: TableSchema) -> String? {
        compositeKey(schema) { column in change.values.first { $0.column == column }?.value }
    }

    /// Every row the steps insert, as `node.table.key`.
    func insertedKeys() -> Set<String> {
        var keys: Set<String> = []
        for step in journey.steps {
            for change in step.rows where change.kind == .insert {
                guard let site = manifest.journeyTables(change.table).first, let key = Self.insertKey(change, site.schema) else { continue }
                keys.insert("\(site.node).\(site.schema.name).\(key)")
            }
        }
        return keys
    }

    mutating func run() -> JourneyPlayback {
        let inserted = insertedKeys()
        let entity = reference(journey.entity, at: { .entity($0) }, inserted: inserted)
        var related: [JourneyRowID] = []
        for (index, ref) in journey.related.enumerated() {
            if let id = reference(ref, at: { .related(index, $0) }, inserted: inserted) { related.append(id) }
        }
        // Rows the steps name come after the entity and related rows, in the order they first appear.
        for (stepIndex, step) in journey.steps.enumerated() {
            for (index, change) in step.rows.enumerated() {
                guard let site = manifest.journeyTables(change.table).first else { continue }
                let key = change.kind == .insert ? Self.insertKey(change, site.schema) : change.key.flatMap { keyValue($0, in: site) }
                guard let key else { continue }
                let id = JourneyRowID(path: site.path, node: site.node, table: site.schema.name, key: key)
                if rows[id] == nil {
                    let row = load(id, site: site)
                    if change.kind == .insert, row.exists {
                        issue(.change(step: stepIndex, index: index, key: "insert"),
                              "\(site.schema.name) \(key) is already a sample row; insert a new id, or update the sample row instead")
                        rows[id]?.exists = false
                    }
                }
            }
        }
        let initial = order.compactMap { rows[$0] }
        let (instants, timing) = JourneyClock.timeline(journey.steps)
        for (index, message) in timing { issue(.step(index, "at"), message, .warning) }
        var frames: [JourneyFrame] = []
        for (index, step) in journey.steps.enumerated() {
            frames.append(frame(index, step, instant: instants[index]))
        }
        return JourneyPlayback(journey: journey, entity: entity, related: related, initial: initial, frames: frames, issues: issues)
    }

    // MARK: A step

    mutating func frame(_ index: Int, _ step: JourneyStep, instant: JourneyInstant?) -> JourneyFrame {
        var path = step.path
        var level = manifest.level(at: path)
        if level == nil {
            issue(.step(index, "path"), "unknown deep-dive path '\(path.joined(separator: "/"))'\(pathHint(path))")
        }
        var node = step.node
        if let id = node, let level, level.node(id) == nil {
            let fix = closestKey(to: id, in: level.nodes.map(\.id)).map { "; did you mean '\($0)'?" } ?? ""
            let place = path.isEmpty ? "" : " in \(path.joined(separator: "/"))"
            issue(.step(index, "node"), "unknown node '\(id)'\(place)\(fix)")
            node = nil
        }
        var site: JourneyOpSite?
        if let reference = step.op {
            site = manifest.resolveJourneyOp(reference, node: node, path: path)
            if site == nil { issue(.step(index, "op"), "unknown op '\(reference)'\(opHint(reference, node: node, level: level))") }
        }
        if node == nil, let site, step.node == nil {
            node = site.node
            path = site.path
            level = manifest.level(at: path)
        }
        var target: String?
        var buffer: String?
        if let site, let level {
            if let id = site.op.target, level.node(id) != nil { target = id }
            else if site.op.kind == .publish || site.op.kind == .consume,
                    let topic = site.op.topic, let found = level.nodes.first(where: { $0.kind.role == .buffer && ($0.id == topic || $0.label == topic) }) {
                target = found.id
            } else if site.op.kind == .consume,
                      let flow = level.flows.first(where: { flow in
                          flow.by == site.node && flow.op.flatMap { level.resolveOp($0, caller: site.node, target: nil)?.op.id } == site.op.id
                      }) {
                // A consumer's queue is the one the flow that names it consumes.
                target = flow.on
            }
        }
        if let message = step.message {
            if let to = message.to {
                if let found = level?.node(to) {
                    if found.kind.role != .buffer { issue(.step(index, "message"), "'\(to)' must be a queue or topic; it is a \(found.kind.rawValue)") }
                    else { buffer = to }
                } else {
                    let fix = level.flatMap { closestKey(to: to, in: $0.nodes.filter { $0.kind.role == .buffer }.map(\.id)) }.map { "; did you mean '\($0)'?" } ?? ""
                    issue(.step(index, "message"), "unknown queue or topic '\(to)'\(fix)")
                }
                if let site, site.op.kind == .publish, let opTarget = site.op.target, opTarget != to {
                    issue(.step(index, "message"), "the message goes to '\(to)' but \(site.reference) publishes to '\(opTarget)'", .warning)
                }
            } else if let site, site.op.kind == .publish, let target {
                buffer = target
            }
        } else if let site, site.op.kind == .publish, let target {
            buffer = target
        }
        let command = self.command(step, site: site, index: index, buffer: buffer ?? (site?.op.kind == .consume ? target : nil))
        if let buffer, command?.kind == .message, let text = command?.text { sent[buffer] = text }
        if let note = step.note {
            let lines = note.split(separator: "\n", omittingEmptySubsequences: true).count
            if lines > 2 || note.count > 320 {
                issue(.step(index, "note"), "keep a step's note to two lines (it has \(lines) line\(lines == 1 ? "" : "s"), \(note.count) characters); put the rest in the op's doc", .warning)
            }
        }
        if let how = step.how, manifest.resolveJourneyHow(how) == nil {
            let parts = how.split(separator: "/").map(String.init)
            let all = manifest.everyLevel().flatMap { $0.level.nodes.flatMap { node in (node.how + node.ops.flatMap(\.how)).map { "\(node.id)/\($0.id)" } } }
            let fix = closestKey(to: how, in: all).map { "; did you mean '\($0)'?" } ?? (all.isEmpty ? "; no node has a how: mechanism" : "")
            let known = manifest.everyLevel().contains { $0.level.node(parts.first ?? "") != nil }
            issue(.step(index, "how"), known ? "'\(parts.first ?? "")' has no mechanism '\(parts.last ?? "")'\(fix)" : "unknown node '\(parts.first ?? "")' in how '\(how)'\(fix)")
        }

        var diffs: [JourneyRowDiff] = []
        var moves: [JourneyMove] = []
        for (changeIndex, change) in step.rows.enumerated() {
            apply(change, step: index, index: changeIndex, op: site, diffs: &diffs, moves: &moves)
        }
        for (statusIndex, status) in step.status.enumerated() {
            applyStatus(status, step: index, index: statusIndex, frameStep: step, site: site, node: node, diffs: &diffs, moves: &moves)
        }
        // Each move follows the declared transition made by this step's op or node, else any for it.
        for k in moves.indices {
            guard let from = moves[k].from, let def = manifest.enumDef(moves[k].enumID) else { continue }
            let candidates = def.transitions.filter { $0.from == from && $0.to == moves[k].to }
            moves[k].transition = candidates.first { Self.matches($0.by, site: site, node: node) } ?? candidates.first
        }
        return JourneyFrame(index: index, step: step, path: path, node: node, op: site, target: target, buffer: buffer, command: command,
                            instant: instant, rows: order.compactMap { rows[$0] }, diffs: diffs, moves: moves)
    }

    /// A transition's `by` names this step's op (`node/op`) or its node.
    static func matches(_ by: String?, site: JourneyOpSite?, node: String?) -> Bool {
        guard let by else { return false }
        if let site, by == site.reference { return true }
        let actor = by.split(separator: "/").first.map(String.init)
        return !by.contains("/") && (actor == node || actor == site?.node)
    }

    func pathHint(_ path: [String]) -> String {
        var level = manifest.root
        for (depth, element) in path.enumerated() {
            let id = element.split(separator: "#").first.map(String.init) ?? element
            guard let node = level.node(id) else {
                let fix = closestKey(to: id, in: level.nodes.map(\.id)).map { "; did you mean '\($0)'?" } ?? ""
                return depth == 0 ? fix : "; '\(path[depth - 1])' has no node '\(id)'\(fix)"
            }
            guard let inner = manifest.level(at: Array(path.prefix(depth + 1))) else {
                return node.detail != nil ? "; '\(id)' opens another manifest (detail:), which a journey can't enter" : "; '\(id)' has no deep dive (inside:)"
            }
            level = inner
        }
        return ""
    }

    func opHint(_ reference: String, node: String?, level: Level?) -> String {
        let parts = reference.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            let nodes = manifest.everyLevel().flatMap { $0.level.nodes }
            guard let owner = nodes.first(where: { $0.id == parts[0] }) else {
                return closestKey(to: parts[0], in: nodes.map(\.id)).map { "; no node '\(parts[0])', did you mean '\($0)'?" } ?? "; no node '\(parts[0])'"
            }
            let ops = nodes.filter { $0.id == owner.id }.flatMap(\.ops).map(\.id)
            return closestKey(to: parts[1], in: ops).map { "; did you mean '\(owner.id)/\($0)'?" } ?? (ops.isEmpty ? "; '\(owner.id)' has no ops" : "")
        }
        guard let node else { return "; write node/op, or set node" }
        let ops = level?.node(node)?.ops.map(\.id) ?? []
        return closestKey(to: reference, in: ops).map { "; did you mean '\($0)'?" } ?? "; '\(node)' has no op '\(reference)', write node/op for another node's"
    }

    // MARK: The command

    mutating func command(_ step: JourneyStep, site: JourneyOpSite?, index: Int, buffer: String?) -> JourneyCommand? {
        let binds = step.binds
        guard let op = site?.op else {
            if !binds.isEmpty { issue(.step(index, "binds"), "binds fill an op's placeholders; this step names no op", .warning) }
            if let payload = step.message?.payload {
                return JourneyCommand(kind: .message, title: step.message?.topic ?? "Message", text: payload, template: payload, fill: nil)
            }
            return nil
        }
        var result: JourneyCommand?
        switch op.kind {
        case .sql, .search:
            if let query = op.query, SQLFormat.looksLikeSQL(query) || op.kind == .sql {
                let fill = JourneyFill.sql(query, binds: binds)
                result = JourneyCommand(kind: .sql, title: "SQL", text: fill.text, template: query, fill: fill)
            } else if let query = op.query {
                let fill = JourneyFill.braces(query, binds: binds)
                result = JourneyCommand(kind: .request, title: "Query", text: fill.text, template: query, fill: fill)
            }
        case .cache, .storage:
            let verb = (op.command ?? op.method ?? (op.kind == .cache ? "GET" : "")).trimmingCharacters(in: .whitespaces)
            if let pattern = op.key {
                let fill = JourneyFill.braces(pattern, binds: binds)
                var words = verb.split(separator: " ").map(String.init)
                let head = words.isEmpty ? "" : words.removeFirst()
                let text = ([head, fill.text] + words).filter { !$0.isEmpty }.joined(separator: " ")
                result = JourneyCommand(kind: op.kind == .cache || head.uppercased() == head ? .redis : .request, title: verb.isEmpty ? "Key" : verb,
                                        text: text, template: ([head, pattern] + words).filter { !$0.isEmpty }.joined(separator: " "), fill: fill)
            } else if !verb.isEmpty {
                result = JourneyCommand(kind: .redis, title: verb, text: verb, template: verb, fill: nil)
            }
        case .publish, .consume:
            // A consumer receives what the journey last sent to its queue, unless the step says otherwise.
            let received = op.kind == .consume ? buffer.flatMap { sent[$0] } : nil
            let payload = step.message?.payload ?? received ?? op.payload
            let topic = step.message?.topic ?? op.topic
            if let payload {
                let fill = JourneyFill.braces(payload, binds: binds)
                result = JourneyCommand(kind: .message, title: topic ?? "Message", text: fill.text, template: payload, fill: fill)
            }
        case .rpc, .http, .call, .llm:
            // The request this step sends: its message's payload, else the op's example request.
            let line = [op.method, op.path].compactMap { $0 }.joined(separator: " ")
            let body = (step.message?.payload ?? op.request ?? "").replacingOccurrences(of: "\n", with: " ")
            let template = [line, body].filter { !$0.isEmpty }.joined(separator: "\n")
            if !template.isEmpty {
                let fill = JourneyFill.braces(template, binds: binds)
                let lines = fill.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let title = line.isEmpty ? "Request" : (lines.first ?? line)
                let body = line.isEmpty ? fill.text : (lines.count > 1 ? lines[1] : "")
                result = JourneyCommand(kind: .request, title: title, text: body, template: template, fill: fill)
            }
        }
        if !binds.isEmpty {
            guard let fill = result?.fill, !fill.placeholders.isEmpty else {
                issue(.step(index, "binds"), "\(site?.reference ?? "the op") has no placeholders for binds to fill", .warning)
                return result
            }
            let positional = binds.filter { $0.name == nil }.count
            let questions = fill.placeholders.filter { $0 == "?" }.count
            if positional > 0, questions > 0, positional != questions {
                issue(.step(index, "binds"), "\(site?.reference ?? "the op")'s query has \(questions) ? placeholder\(questions == 1 ? "" : "s"); binds gives \(positional) value\(positional == 1 ? "" : "s")", .warning)
            } else if !fill.unused.isEmpty {
                let names = fill.placeholders.filter { $0 != "?" }
                issue(.step(index, "binds"), "bind\(fill.unused.count == 1 ? "" : "s") \(fill.unused.joined(separator: ", ")) fill\(fill.unused.count == 1 ? "s" : "") no placeholder of \(site?.reference ?? "the op")\(names.isEmpty ? "" : "; it has \(names.joined(separator: ", "))")", .warning)
            } else if !fill.unfilled.isEmpty {
                issue(.step(index, "binds"), "no bind for \(fill.unfilled.joined(separator: ", ")) in \(site?.reference ?? "the op")", .warning)
            }
        }
        return result
    }

    // MARK: Rows

    mutating func apply(_ change: JourneyRowChange, step: Int, index: Int, op: JourneyOpSite?, diffs: inout [JourneyRowDiff], moves: inout [JourneyMove]) {
        let place: (String) -> JourneyIssue.Place = { .change(step: step, index: index, key: $0) }
        guard let site = table(change.table, at: place(change.kind.rawValue)) else { return }
        let schema = site.schema
        let names = schema.columns.map(\.name)
        for cell in change.values + (change.key?.cells ?? []) where schema.column(cell.column) == nil {
            let fix = closestKey(to: cell.column, in: names).map { "; did you mean '\($0)'?" } ?? ""
            issue(place(change.kind == .update ? "set" : "values"), "unknown column '\(cell.column)' in '\(schema.name)'\(fix)")
        }
        if let op = op?.op, op.kind == .sql || op.kind == .search, !op.tables.isEmpty, !op.tables.contains(schema.name) {
            issue(place(change.kind.rawValue), "\(op.id)'s tables are \(op.tables.joined(separator: ", ")); they don't include '\(schema.name)'", .warning)
        }
        for cell in change.values {
            guard let column = schema.column(cell.column), let enumID = column.enumRef, let value = cell.value,
                  let def = manifest.enumDef(enumID), def.value(value) == nil else { continue }
            let byName = def.value(named: value).map { "; '\(value)' is the name of \($0.value), write the value" } ?? ""
            issue(place(change.kind == .update ? "set" : "values"), "\(schema.name).\(column.name) = \(value) is not a value of '\(enumID)'\(byName)", .warning)
        }
        let key: String?
        switch change.kind {
        case .insert:
            key = Self.insertKey(change, schema)
            if key == nil { issue(place("values"), "insert into '\(schema.name)' needs its key column \(Self.keyColumns(schema).first ?? "")") }
        case .update, .delete:
            key = change.key.flatMap { keyValue($0, in: site) }
            if key == nil, let written = change.key { issue(place("key"), "no row of '\(schema.name)' matches \(written)") }
        }
        guard let key else { return }
        let id = JourneyRowID(path: site.path, node: site.node, table: schema.name, key: key)
        var row = load(id, site: site)
        var cells: [JourneyCellChange] = []
        switch change.kind {
        case .insert:
            if row.exists {
                issue(place("insert"), "\(schema.name) \(key) already exists at this step; insert a new id or update it")
            }
            row.values = Array(repeating: nil, count: row.columns.count)
            for cell in change.values {
                guard let column = row.columns.firstIndex(of: cell.column) else { continue }
                row.values[column] = cell.value
                if cell.value != nil { cells.append(JourneyCellChange(column: cell.column, before: nil, after: cell.value)) }
            }
            row.exists = true
        case .update:
            guard row.exists else {
                issue(place("key"), "\(schema.name) \(key) doesn't exist before this step: it is not a sample row\(row.sample == nil ? "" : " any more") and no earlier step inserts it")
                return
            }
            for cell in change.values {
                guard let column = row.columns.firstIndex(of: cell.column) else { continue }
                let before = row.values[column]
                if before != cell.value { cells.append(JourneyCellChange(column: cell.column, before: before, after: cell.value)) }
                row.values[column] = cell.value
            }
            if cells.isEmpty, !change.values.isEmpty {
                issue(place("set"), "this update changes nothing: \(schema.name) \(key) already holds those values", .warning)
            }
        case .delete:
            guard row.exists else {
                issue(place("key"), "\(schema.name) \(key) doesn't exist before this step, so there is nothing to delete")
                return
            }
            cells = zip(row.columns, row.values).compactMap { column, value in value.map { JourneyCellChange(column: column, before: $0, after: nil) } }
            row.exists = false
        }
        rows[id] = row
        record(JourneyRowDiff(row: id, kind: change.kind, cells: cells, change: index), into: &diffs)
        for cell in cells where change.kind != .delete {
            guard let enumID = schema.column(cell.column)?.enumRef, let to = cell.after else { continue }
            moves.append(JourneyMove(enumID: enumID, from: cell.before, to: to, row: id, column: cell.column, step: step))
        }
    }

    /// Merges a diff into the step's diffs: one per row, an insert staying an insert.
    func record(_ diff: JourneyRowDiff, into diffs: inout [JourneyRowDiff]) {
        guard let k = diffs.firstIndex(where: { $0.row == diff.row }) else { diffs.append(diff); return }
        var merged = diffs[k]
        if diff.kind == .delete { merged.kind = .delete }
        for cell in diff.cells {
            if let c = merged.cells.firstIndex(where: { $0.column == cell.column }) {
                merged.cells[c].after = cell.after
            } else {
                merged.cells.append(cell)
            }
        }
        diffs[k] = merged
    }

    // MARK: Status

    mutating func applyStatus(_ status: JourneyStatus, step: Int, index: Int, frameStep: JourneyStep, site: JourneyOpSite?, node: String?,
                              diffs: inout [JourneyRowDiff], moves: inout [JourneyMove]) {
        let place: (String) -> JourneyIssue.Place = { .status(step: step, index: index, key: $0) }
        guard let def = manifest.enumDef(status.enumID) else {
            let ids = manifest.enums.map(\.id)
            let fix = closestKey(to: status.enumID, in: ids).map { "; did you mean '\($0)'?" } ?? (ids.isEmpty ? "; define it under enums" : "")
            issue(place("enum"), "unknown enum '\(status.enumID)'\(fix)")
            return
        }
        var valid = true
        for (value, key) in [(status.from, "from"), (Optional(status.to), "to")] {
            guard let value, def.value(value) == nil else { continue }
            valid = false
            let byName = def.value(named: value).map { "; '\(value)' is the name of \($0.value), write the value" }
            let fix = byName ?? closestKey(to: value, in: def.values.map(\.value)).map { "; did you mean \($0)?" } ?? ""
            issue(place(key), "unknown value \(value) in '\(def.id)'\(fix)")
        }
        guard valid else { return }
        // A row change in this step already made this move: the same move, written twice.
        let same = moves.filter { $0.enumID == status.enumID && $0.to == status.to && $0.step == step }
        if same.contains(where: { status.from == nil || $0.from == status.from }) { return }
        // Else the row the journey knows whose column holds this enum at `from`.
        var holders: [(row: JourneyRowID, column: String, value: String?)] = []
        for id in order {
            guard let row = rows[id], row.exists, let site = manifest.journeyTables("\(id.node).\(id.table)").first else { continue }
            for column in site.schema.columns where column.enumRef == status.enumID {
                if let wanted = status.column {
                    let parts = wanted.split(separator: ".").map(String.init)
                    guard parts.last == column.name, parts.dropLast().last == id.table else { continue }
                }
                holders.append((id, column.name, row.value(column.name)))
            }
        }
        if let holder = holders.first(where: { $0.value == status.from }) {
            guard var row = rows[holder.row], let column = row.columns.firstIndex(of: holder.column) else { return }
            row.values[column] = status.to
            rows[holder.row] = row
            record(JourneyRowDiff(row: holder.row, kind: .update, cells: [JourneyCellChange(column: holder.column, before: status.from, after: status.to)], change: nil),
                   into: &diffs)
            moves.append(JourneyMove(enumID: status.enumID, from: status.from, to: status.to, row: holder.row, column: holder.column, step: step))
            return
        }
        if let other = same.first, holders.allSatisfy({ $0.value != status.from }) {
            let row = other.row.map { " on \($0)" } ?? ""
            issue(place("from"), "status says from \(status.from.map(def.title(of:)) ?? "NULL"), but \(other.column ?? "the column")\(row) was \(other.from.map(def.title(of:)) ?? "NULL") before this step")
            return
        }
        if !holders.isEmpty {
            let held = holders.map { "\($0.row).\($0.column) is \($0.value.map(def.title(of:)) ?? "NULL")" }.joined(separator: ", ")
            issue(place("from"), "no row holds \(status.from.map(def.title(of:)) ?? "NULL") in a '\(def.id)' column before this step (\(held))")
            return
        }
        if let wanted = status.column {
            issue(place("column"), "no row of this journey has a column \(wanted) holding '\(def.id)'")
            return
        }
        // No row holds it: an in-memory or external status, shown on the timeline only.
        moves.append(JourneyMove(enumID: status.enumID, from: status.from, to: status.to, row: nil, column: nil, step: step))
    }
}
