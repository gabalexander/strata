import Foundation

final class Findings {
    var diagnostics: [Diagnostic] = []
    var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
}

struct Field {
    let node: YAMLNode?
    let path: String
    let fallbackLine: Int
    let findings: Findings

    var line: Int { node?.line ?? fallbackLine }
    var present: Bool { node != nil }

    init(_ node: YAMLNode?, path: String = "", fallbackLine: Int = 1, findings: Findings) {
        self.node = node
        self.path = path
        self.fallbackLine = fallbackLine
        self.findings = findings
    }

    subscript(_ key: String) -> Field {
        let pair = node?.fields?.first { $0.key == key }
        let next = path.isEmpty ? key : "\(path).\(key)"
        return Field(pair?.value, path: next, fallbackLine: pair?.line ?? line, findings: findings)
    }

    func diagnose(_ message: String, _ severity: Diagnostic.Severity = .error, line: Int? = nil) {
        findings.diagnostics.append(Diagnostic(severity, message, line: line ?? self.line, path: path.isEmpty ? nil : path))
    }

    @discardableResult
    func mapping(_ keys: Set<String>) -> Bool {
        guard let fields = node?.fields else {
            diagnose("expected a mapping")
            return false
        }
        for pair in fields where !keys.contains(pair.key) {
            let suggestion = closestKey(to: pair.key, in: Array(keys)).map { "; did you mean '\($0)'?" } ?? ""
            self[pair.key].diagnose("unknown key '\(pair.key)'\(suggestion)", .warning, line: pair.line)
        }
        return true
    }

    func items(required: Bool = false, named: Bool = false) -> [Field] {
        guard present || required else { return [] }
        guard let elements = node?.elements else {
            diagnose(present ? "expected a list" : "required list is missing")
            return []
        }
        return elements.enumerated().map { index, element in
            let id = named ? element["id"]?.scalar : nil
            let suffix = id.flatMap { Syntax.isID($0) ? ".\($0)" : nil } ?? "[\(index)]"
            return Field(element, path: path + suffix, fallbackLine: line, findings: findings)
        }
    }

    func read<T>(required: Bool = false, _ parse: (YAMLNode) throws -> T) -> T? {
        guard let node else {
            if required { diagnose("required value is missing") }
            return nil
        }
        do { return try parse(node) }
        catch let error as InvalidValue { diagnose(error.message) }
        catch { diagnose(error.localizedDescription) }
        return nil
    }

    func text(required: Bool = false, nonempty: Bool = false) -> String? {
        read(required: required) { node in
            let text = try Self.string(node)
            if nonempty, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw InvalidValue("expected nonempty text") }
            return text
        }
    }

    func scalar<T>(required: Bool = false, _ parse: (String) throws -> T) -> T? {
        read(required: required) { node in
            guard let text = node.scalar else { throw InvalidValue("expected a scalar value") }
            return try parse(text)
        }
    }

    func id(required: Bool = false) -> String? {
        scalar(required: required, Syntax.id)
    }

    func termID() -> String? { scalar(Syntax.termID) }
    func duration(required: Bool = false) -> Double? { scalar(required: required, Syntax.duration) }
    func distribution(required: Bool = false) -> Dist? { scalar(required: required, Syntax.distribution) }
    func probability() -> Double? {
        read { node in
            if case .scalar(let text, let quoted) = node.content, !quoted || text.hasSuffix("%") {
                return try Syntax.probability(text)
            }
            throw InvalidValue("expected a probability between 0 and 1 or between 0% and 100%")
        }
    }

    func number(required: Bool = false, min: Double? = nil) -> Double? {
        read(required: required) { node in
            guard case .scalar(let text, quoted: false) = node.content, let value = Syntax.number(text) else {
                throw InvalidValue("expected a finite number")
            }
            if let min, value < min { throw InvalidValue("expected a number of at least \(min)") }
            return value
        }
    }

    func integer(required: Bool = false, in range: ClosedRange<Int>) -> Int? {
        read(required: required) { node in
            guard case .scalar(let text, quoted: false) = node.content, let value = Int(text), range.contains(value) else {
                if range == Int.min...Int.max { throw InvalidValue("expected an integer") }
                if range.upperBound == Int.max { throw InvalidValue("expected an integer of at least \(range.lowerBound)") }
                throw InvalidValue("expected an integer between \(range.lowerBound) and \(range.upperBound)")
            }
            return value
        }
    }

    func bool() -> Bool? {
        read { node in
            guard case .scalar(let text, quoted: false) = node.content, let value = Syntax.bool(text) else {
                throw InvalidValue("expected true or false")
            }
            return value
        }
    }

    func choice<T: RawRepresentable & CaseIterable>(_ type: T.Type) -> T? where T.RawValue == String {
        scalar { text in
            guard let value = T(rawValue: text) else {
                let choices = T.allCases.map(\.rawValue)
                let suggestion = closestKey(to: text, in: choices).map { "; did you mean '\($0)'?" } ?? ""
                throw InvalidValue("expected one of \(choices.joined(separator: ", "))\(suggestion)")
            }
            return value
        }
    }

    func value() -> Value? {
        read { node in
            guard case .scalar(let text, let quoted) = node.content else { throw InvalidValue("expected a number, text, or boolean") }
            return quoted ? .string(text) : Syntax.value(text)
        }
    }

    func textList(orOne: Bool = false) -> [String] {
        if orOne, node?.scalar != nil { return text().map { [$0] } ?? [] }
        return items().compactMap { $0.text() }
    }

    private static func string(_ node: YAMLNode) throws -> String {
        if case .scalar(let text, let quoted) = node.content,
           quoted || (Syntax.bool(text) == nil && Syntax.number(text) == nil) {
            return text
        }
        throw InvalidValue("expected text; quote it if it is written as a number or boolean")
    }
}

func closestKey(to input: String, in candidates: [String]) -> String? {
    let allowedDistance = input.count <= 3 ? 1 : (input.count <= 7 ? 2 : 3)
    return candidates
        .filter { abs($0.count - input.count) <= allowedDistance }
        .map { (name: $0, distance: editDistance(input.lowercased(), $0.lowercased())) }
        .filter { $0.distance <= allowedDistance }
        .min { ($0.distance, $0.name) < ($1.distance, $1.name) }?.name
}

private func editDistance(_ a: String, _ b: String) -> Int {
    let rhs = Array(b)
    var previous = Array(0...rhs.count)
    for (row, char) in a.enumerated() {
        var next = [row + 1]
        for (column, other) in rhs.enumerated() {
            next.append(min(previous[column + 1] + 1, next[column] + 1, previous[column] + (char == other ? 0 : 1)))
        }
        previous = next
    }
    return previous[rhs.count]
}
