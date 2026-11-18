import Foundation

// Decoding of node `schema:` and `entities:`, and of flow `traffic:` and `slo:` (docs/manifest.md,
// Data, and Traffic, SLOs and pressure).

extension Syntax {
    /// A table, column or entity name used as a path element: no whitespace, dots or brackets.
    static func isName(_ text: String) -> Bool {
        !text.isEmpty && !text.contains { $0.isWhitespace || $0 == "." || $0 == "[" || $0 == "]" }
    }

    /// A table or column name. Dots are reserved for refs (`table.column`).
    static func dataName(_ text: String) throws -> String {
        guard isName(text) else {
            throw InvalidValue("invalid name '\(text)'; table and column names cannot be empty or contain spaces, dots or brackets")
        }
        return text
    }

    /// `table.column`, or `node.table.column` for a table on another node.
    static func columnRef(_ text: String) throws -> String {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(parts.count), parts.allSatisfy(isName) else {
            throw InvalidValue("invalid ref '\(text)'; use table.column, or node.table.column for a table on another node")
        }
        return text
    }

    private static let countSuffixes: [Character: Double] = ["k": 1e3, "K": 1e3, "M": 1e6, "B": 1e9]

    /// A count: `500`, `40k`, `12M`, `1.2B`.
    static func count(_ text: String) throws -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var digits = trimmed
        var factor = 1.0
        if let last = trimmed.last, let suffix = countSuffixes[last] {
            factor = suffix
            digits = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if let value = number(digits), value >= 0, (value * factor).isFinite { return value * factor }
        if trimmed.hasSuffix("m"), number(String(trimmed.dropLast())) != nil {
            throw InvalidValue("write millions as M, such as 12M")
        }
        throw InvalidValue("expected a count such as 500, 40k, 12M or 1.2B")
    }

    /// Seconds in each period a rate or a growth can be written per.
    private static let periods: [String: Double] = [
        "s": 1, "sec": 1, "min": 60, "h": 3600, "hr": 3600, "hour": 3600, "d": 86400, "day": 86400,
        "w": 604_800, "wk": 604_800, "week": 604_800, "mo": 2_592_000, "month": 2_592_000,
        "y": 31_536_000, "yr": 31_536_000, "year": 31_536_000,
    ]

    /// A count per period: (the count, seconds in the period).
    private static func perPeriod(_ text: String) throws -> (count: Double, seconds: Double) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { throw InvalidValue("expected a count per period, such as 40k/day or 120/s") }
        let period = parts[1].trimmingCharacters(in: .whitespaces)
        guard let seconds = periods[period] else {
            if period == "m" { throw InvalidValue("'/m' is ambiguous; write /min for minutes or /month for months") }
            let names = ["s", "min", "h", "hour", "day", "week", "month", "year"]
            let suggestion = closestKey(to: period, in: names).map { "; did you mean '/\($0)'?" } ?? ""
            throw InvalidValue("unknown period '/\(period)'; use /s, /min, /h, /day, /week, /month or /year\(suggestion)")
        }
        return (try count(parts[0]), seconds)
    }

    /// Growth, normalised to per day: `40k/day`, `1.2M/day`, `500/h`.
    static func growthPerDay(_ text: String) throws -> Double {
        guard text.contains("/") else { throw InvalidValue("growth needs a period, such as \(text)/day") }
        let (count, seconds) = try perPeriod(text)
        return count * 86400 / seconds
    }

    /// A real-world rate per second, with no simulation limit: `120/s`, `7200/min`, `12k/s`.
    static func throughput(_ text: String) throws -> Double {
        guard text.contains("/") else {
            if (try? count(text)) != nil { throw InvalidValue("a rate needs a period; write \(text)/s, not \(text)") }
            throw InvalidValue("expected a rate such as 120/s or 7200/min")
        }
        let (count, seconds) = try perPeriod(text)
        return count / seconds
    }

    /// Requests per day: `4M`, or `4M/day`.
    static func dailyCount(_ text: String) throws -> Double {
        guard text.contains("/") else { return try count(text) }
        let (count, seconds) = try perPeriod(text)
        guard seconds == 86400 else { throw InvalidValue("daily is a count per day, such as 4M; write the busiest rate as peak") }
        return count
    }
}

extension Decode {
    static let tableKeys: Set<String> = ["table", "doc", "columns", "indexes", "rows", "volume", "owner"]
    static let columnKeys: Set<String> = ["name", "type", "pk", "ref", "nullable", "unique", "note"]
    static let entityKeys: Set<String> = ["name", "source", "root", "includes", "doc", "code"]

    static func table(_ field: Field) -> TableSchema? {
        guard field.mapping(tableKeys) else { return nil }
        guard let name = field["table"].scalar(required: true, Syntax.dataName) else { return nil }
        var table = TableSchema(name: name)
        table.line = field.line
        table.doc = field["doc"].text()
        table.columns = field["columns"].items(named: true, nameKey: "name").compactMap(column)
        table.indexes = field["indexes"].textList(orOne: true)
        table.rows = rows(field["rows"], of: table)
        table.volume = volume(field["volume"])
        table.owner = field["owner"].id()
        return table
    }

    static func column(_ field: Field) -> Column? {
        guard field.mapping(columnKeys) else { return nil }
        guard let name = field["name"].scalar(required: true, Syntax.dataName) else { return nil }
        var column = Column(name: name)
        column.type = field["type"].anyText()
        column.pk = field["pk"].bool() ?? false
        column.ref = field["ref"].scalar(Syntax.columnRef)
        column.nullable = field["nullable"].bool()
        column.unique = field["unique"].bool() ?? false
        column.note = field["note"].anyText()
        return column
    }

    /// Sample rows in column order. A row is a list in column order or a map from column name to
    /// value; columns a map leaves out are NULL.
    static func rows(_ field: Field, of table: TableSchema) -> [[String?]] {
        let width = table.columns.count
        let names = table.columns.map(\.name)
        func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
        return field.items().compactMap { row in
            guard let node = row.node else { return nil }
            var cells: [String?]
            switch node.content {
            case .list(let values):
                cells = values.map(cell)
                if values.count != width {
                    row.diagnose("row has \(plural(values.count, "value")) but '\(table.name)' has \(plural(width, "column"))")
                }
            case .map(let pairs):
                cells = Array(repeating: nil, count: width)
                for pair in pairs {
                    if let index = names.firstIndex(of: pair.key) {
                        cells[index] = cell(pair.value)
                    } else {
                        let suggestion = closestKey(to: pair.key, in: names).map { "; did you mean '\($0)'?" } ?? ""
                        row[pair.key].diagnose("unknown column '\(pair.key)' in '\(table.name)'\(suggestion)", .warning, line: pair.line)
                    }
                }
            case .scalar, .null:
                guard width == 1 else {
                    row.diagnose("expected a row: a list of values in column order, or a map from column name to value")
                    return nil
                }
                cells = [cell(node)]
            }
            if cells.count < width { cells += Array(repeating: nil, count: width - cells.count) }
            return Array(cells.prefix(width))
        }
    }

    /// One sample value as written. `null` is SQL NULL; a nested mapping or list is shown as JSON.
    static func cell(_ node: YAMLNode) -> String? {
        switch node.content {
        case .null: nil
        case .scalar(let text, _): text
        case .map, .list: Field.json(node)
        }
    }

    static func volume(_ field: Field) -> TableVolume? {
        guard field.present else { return nil }
        var volume = TableVolume()
        if field.node?.scalar != nil {
            volume.rows = field.scalar(Syntax.count)
            return volume
        }
        guard field.mapping(["rows", "growth"]) else { return nil }
        volume.rows = field["rows"].scalar(Syntax.count)
        volume.growthPerDay = field["growth"].scalar(Syntax.growthPerDay)
        return volume
    }

    static func entity(_ field: Field) -> Entity? {
        guard field.mapping(entityKeys) else { return nil }
        let name = field["name"].text(required: true, nonempty: true)
        let root = field["root"].scalar(required: true, Syntax.dataName)
        guard let name, let root else { return nil }
        var entity = Entity(name: name, root: root)
        entity.line = field.line
        entity.source = field["source"].id()
        let includes = field["includes"]
        entity.includes = (includes.node?.scalar != nil ? [includes] : includes.items()).compactMap { $0.scalar(Syntax.dataName) }
        entity.doc = field["doc"].text()
        entity.code = field["code"].textList(orOne: true)
        return entity
    }

    static func traffic(_ field: Field) -> FlowTraffic? {
        guard field.present, field.mapping(["peak", "daily"]) else { return nil }
        var traffic = FlowTraffic()
        traffic.peak = field["peak"].scalar(Syntax.throughput)
        traffic.daily = field["daily"].scalar(Syntax.dailyCount)
        return traffic
    }

    static func slo(_ field: Field) -> SLO? {
        guard field.present, field.mapping(["p50", "p99", "errors"]) else { return nil }
        var slo = SLO()
        slo.p50 = field["p50"].duration()
        slo.p99 = field["p99"].duration()
        slo.errors = field["errors"].probability()
        return slo
    }
}
