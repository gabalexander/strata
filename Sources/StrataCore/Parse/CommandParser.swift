import Foundation

public extension ManifestParser {
    /// One command line, e.g. "kill db", "rate place-order 50/s".
    static func parseCommand(_ line: String) -> Result<Command, Diagnostic> {
        do {
            return .success(try CommandSyntax.parse(line))
        } catch let error as InvalidValue {
            return .failure(Diagnostic(.error, error.message))
        } catch {
            return .failure(Diagnostic(.error, error.localizedDescription))
        }
    }
}

private enum CommandSyntax {
    static let usages = [
        "kill": "kill <node>", "restore": "restore <node>", "slow": "slow <node> <factor>",
        "fail": "fail <node> <probability>", "scale": "scale <node> <replicas|+n|-n>",
        "set": "set <node>.<param> <value>", "rate": "rate <flow> <rate>", "send": "send <flow> [count]",
        "cut": "cut <from> <to>", "heal": "heal <from> <to>", "delay": "delay <from> <to> <duration>",
        "redirect": "redirect <node> <other>", "unredirect": "unredirect <node>", "purge": "purge <buffer>",
        "say": "say <text>", "pause": "pause",
    ]

    static func parse(_ line: String) throws -> Command {
        guard !line.unicodeScalars.contains(where: CharacterSet.newlines.contains) else {
            throw InvalidValue("expected one command per line; put multiple commands in a list")
        }
        let input = line.trimmingCharacters(in: .whitespaces)
        let head = input.prefix { !$0.isWhitespace }
        let name = String(head)
        let tail = input.dropFirst(head.count).trimmingCharacters(in: .whitespaces)
        guard let usage = usages[name] else {
            if name.isEmpty { throw InvalidValue("expected a command such as 'kill db' or 'pause'") }
            let suggestion = closestKey(to: name, in: Array(usages.keys)).map { "; did you mean '\($0)'?" } ?? ""
            throw InvalidValue("unknown command '\(name)'\(suggestion)")
        }
        let args = Syntax.words(tail)

        func require(_ count: ClosedRange<Int>) throws {
            guard count.contains(args.count) else { throw InvalidValue("expected '\(usage)'") }
        }

        func id(_ index: Int) throws -> String { try Syntax.id(args[index]) }

        switch name {
        case "pause":
            try require(0...0)
            return .pause
        case "say":
            try require(1...Int.max)
            return .say(tail)
        case "kill", "restore", "unredirect", "purge":
            try require(1...1)
            let node = try id(0)
            switch name {
            case "kill": return .kill(node)
            case "restore": return .restore(node)
            case "unredirect": return .unredirect(node)
            default: return .purge(node)
            }
        case "cut", "heal", "redirect":
            try require(2...2)
            let first = try id(0)
            let second = try id(1)
            switch name {
            case "cut": return .cut(first, second)
            case "heal": return .heal(first, second)
            default: return .redirect(first, second)
            }
        case "delay":
            try require(3...3)
            return .delay(try id(0), try id(1), try Syntax.duration(args[2]))
        case "slow":
            try require(2...2)
            guard let factor = Syntax.number(args[1]), factor > 0 else { throw InvalidValue("slow needs a positive factor, such as 'slow db 10'") }
            return .slow(try id(0), factor)
        case "fail":
            try require(2...2)
            return .fail(try id(0), try Syntax.probability(args[1]))
        case "scale":
            try require(2...2)
            let relative = args[1].hasPrefix("+") || args[1].hasPrefix("-")
            guard let count = Int(args[1]), relative || count > 0 else {
                throw InvalidValue("scale needs a positive replica count or a signed change such as '+1'")
            }
            return .scale(try id(0), count, relative: relative)
        case "send":
            try require(1...2)
            let count = args.count == 2 ? Int(args[1]) : 1
            guard let count, count > 0 else { throw InvalidValue("send needs a positive request count") }
            guard count <= SimulationLimits.send else { throw InvalidValue("send is limited to \(SimulationLimits.send) requests") }
            return .send(try id(0), count)
        case "rate":
            try require(2...3)
            return .rate(try id(0), try Syntax.rate(args.dropFirst().joined(separator: " ")))
        case "set":
            try require(2...Int.max)
            let binding = try Syntax.binding(args[0], nodeOnly: true)
            guard let parameter = ParameterType.forBinding(binding) else {
                let suggestion = closestKey(to: binding.param, in: Array(ParameterType.node.keys)).map { "; did you mean '\($0)'?" } ?? ""
                throw InvalidValue("unknown node parameter '\(binding.param)'\(suggestion)")
            }
            let raw = args.dropFirst().joined(separator: " ")
            let value = Syntax.value(raw)
            try parameter.validate(value)
            return .set(binding, value)
        default:
            throw InvalidValue("expected '\(usage)'")
        }
    }
}
