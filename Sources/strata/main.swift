import Foundation
import StrataCore

private let help = """
Usage: strata <command>

  validate [<file|dir|id> ...] [--json]    Validate manifests (default: ~/.strata/sims)
  list [--json]                           List built-in and user manifests
  new <id> [--kind sim|architecture] [--title "…"]
                                          Create a starter manifest
  open <id> [--path orders/handler]       Open a simulation or deep dive
  open --note <vault-path>                Open a vault note
  simulate <file|id> [--seconds 30] [--scenario id]
                                          Run a simulation and print metrics
  schema                                  Print the manifest reference
  paths                                   Print local data paths
  --help                                  Show this help
"""

MainActor.assumeIsolated {
    do { exit(try run(Array(CommandLine.arguments.dropFirst()))) }
    catch let error as CLIError { stderr("error: \(error.message)"); exit(1) }
    catch { stderr("error: \(error.localizedDescription)"); exit(1) }
}

@MainActor
private func run(_ arguments: [String]) throws -> Int32 {
    guard let command = arguments.first, command != "--help", command != "-h", command != "help" else {
        print(help)
        return 0
    }
    let remaining = Array(arguments.dropFirst())

    switch command {
    case "validate":
        let args = try Arguments(remaining, flags: ["--json"])
        return try validate(args)
    case "list":
        let args = try Arguments(remaining, flags: ["--json"])
        try args.require(0, usage: "strata list [--json]")
        try list(json: args.flags.contains("--json"))
    case "new":
        let args = try Arguments(remaining, options: ["--kind", "--title"])
        try args.require(1, usage: "strata new <id> [--kind sim|architecture] [--title <title>]")
        try create(args)
    case "open":
        let args = try Arguments(remaining, options: ["--path", "--note"])
        return try openRoute(args)
    case "simulate":
        let args = try Arguments(remaining, options: ["--seconds", "--scenario"])
        try args.require(1, usage: "strata simulate <file|id> [--seconds <number>] [--scenario <id>]")
        return try simulate(args)
    case "schema":
        try Arguments(remaining).require(0, usage: "strata schema")
        guard let url = StrataResources.url("Docs/manifest.md") else { throw CLIError("manifest reference is missing") }
        FileHandle.standardOutput.write(try Data(contentsOf: url))
    case "paths":
        try Arguments(remaining).require(0, usage: "strata paths")
        let config = ConfigLoader.load().0
        print("home\t\(StrataPaths.home.path)")
        print("sims\t\(StrataPaths.sims.path)")
        print("vault\t\(config.vaultURL.path)")
        print("config\t\(StrataPaths.config.path)")
    default:
        throw CLIError("unknown command '\(command)'; run strata --help")
    }
    return 0
}

@MainActor
private func loadLibrary() -> Library {
    let config = ConfigLoader.load().0
    return Library(dirs: config.simURLs)
}

@MainActor
private func validate(_ args: Arguments) throws -> Int32 {
    let library = loadLibrary()
    var urls: [URL] = []
    var lookupEntries: [Library.Entry] = []
    var diagnostics: [Finding] = []
    if args.positional.isEmpty { urls = [StrataPaths.sims] }
    for target in args.positional {
        if let url = fileTarget(target) {
            urls.append(url)
        } else if let entry = library.entry(target) {
            lookupEntries.append(entry)
        } else {
            diagnostics.append(Finding(path: target, diagnostic: Diagnostic(.error, "unknown manifest id '\(target)'")))
        }
    }
    var seen: Set<URL> = []
    for entry in library.validate(urls) + lookupEntries where seen.insert(entry.url.standardizedFileURL).inserted {
        diagnostics += entry.diagnostics.map { Finding(path: entry.url.path, diagnostic: $0) }
    }
    if args.flags.contains("--json") {
        try printJSON(diagnostics)
    } else {
        for diagnostic in diagnostics { print(diagnostic.description) }
    }
    return diagnostics.contains(where: { $0.severity == "error" }) ? 1 : 0
}

@MainActor
private func list(json: Bool) throws {
    let entries = loadLibrary().entries.map { entry in
        Listing(id: entry.id, kind: entry.kind.rawValue, title: entry.title, source: entry.url.path,
                errors: entry.diagnostics.filter { $0.severity == .error }.count,
                warnings: entry.diagnostics.filter { $0.severity == .warning }.count)
    }
    if json {
        try printJSON(entries)
    } else {
        for entry in entries {
            print([entry.id, entry.kind, entry.title, entry.source, String(entry.errors), String(entry.warnings)]
                .map { $0.replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\n", with: "\\n") }
                .joined(separator: "\t"))
        }
    }
}

private func create(_ args: Arguments) throws {
    let id = args.positional[0]
    let rawKind = args.options["--kind"] ?? "sim"
    guard let kind = ManifestKind(rawValue: rawKind) else { throw CLIError("--kind must be sim or architecture") }
    let title = args.options["--title"] ?? id
    let text = """
    # Strata manifest v1. Run strata schema for the format.
    strata: 1
    id: \(try quote(id))
    title: \(try quote(title))
    kind: \(kind.rawValue)

    # Drop at from a node to let Strata place it.
    nodes:
      - { id: client, kind: client, at: [0, 0] }
      - { id: service, kind: service, at: [1, 0], latency: 20ms }
    edges:
      - { from: client, to: service, protocol: http }

    # Manual traffic runs when you send a request.
    flows:
      - id: requests
        from: client
        rate: manual
        steps:
          - call: service

    """
    let url = StrataPaths.sims.appendingPathComponent(id).appendingPathExtension("yaml")
    let (manifest, diagnostics) = ManifestParser.parse(text, source: .file(url))
    guard manifest != nil, diagnostics.isEmpty else {
        throw CLIError(diagnostics.map(\.description).joined(separator: "\n"))
    }
    try FileManager.default.createDirectory(at: StrataPaths.sims, withIntermediateDirectories: true)
    do {
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
        throw CLIError("file already exists: \(url.path)")
    }
    print(url.path)
}

private func openRoute(_ args: Arguments) throws -> Int32 {
    var components = URLComponents()
    components.scheme = "strata"
    if let note = args.options["--note"] {
        guard !note.isEmpty, args.positional.isEmpty, args.options["--path"] == nil else {
            throw CLIError("usage: strata open --note <vault-path>")
        }
        components.host = "note"
        components.path = "/" + note
    } else {
        try args.require(1, usage: "strata open <id> [--path <node>/<child>]")
        let id = args.positional[0]
        let path = args.options["--path"]
        let settings = try path.map { "view: " + (try quote($0)) } ?? ""
        let embed = "sim: " + (try quote(id)) + "\n" + settings
        let (request, diagnostics) = ManifestParser.parseEmbed(embed, note: "", index: 0)
        guard request != nil else { throw CLIError(diagnostics.map(\.description).joined(separator: "\n")) }
        components.host = "sim"
        components.path = "/" + id
        if let path { components.queryItems = [URLQueryItem(name: "path", value: path)] }
    }
    guard let url = components.url else { throw CLIError("could not create Strata URL") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

@MainActor
private func simulate(_ args: Arguments) throws -> Int32 {
    let target = args.positional[0]
    let rawSeconds = args.options["--seconds"] ?? "30"
    guard let seconds = Double(rawSeconds), seconds.isFinite, seconds >= 0 else {
        throw CLIError("--seconds must be a finite nonnegative number")
    }
    let library = loadLibrary()
    let entry: Library.Entry?
    if let file = fileTarget(target) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw CLIError("simulate needs a manifest file or id")
        }
        entry = library.validate([file]).first
    } else {
        entry = library.entry(target)
    }
    guard let entry else { throw CLIError("unknown manifest id '\(target)'") }
    for diagnostic in entry.diagnostics { stderr(Finding(path: entry.url.path, diagnostic: diagnostic).description) }
    guard let manifest = entry.manifest else { return 1 }
    let simulation = Simulation(manifest: manifest)
    if let scenario = args.options["--scenario"] {
        guard manifest.root.scenarios.contains(where: { $0.id == scenario }) else {
            throw CLIError("unknown root scenario '\(scenario)'")
        }
        simulation.start(scenario: scenario)
    }
    if !simulation.eventLimitReached { simulation.run(seconds: seconds) }
    print(simulation.report())
    return simulation.eventLimitReached ? 1 : 0
}

private func fileTarget(_ text: String) -> URL? {
    let url = URL(fileURLWithPath: StrataPaths.expand(text))
    if FileManager.default.fileExists(atPath: url.path) || text.contains("/") || text.hasPrefix(".")
        || ["yaml", "yml", "json"].contains(url.pathExtension.lowercased()) {
        return url
    }
    return nil
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

private func quote(_ text: String) throws -> String {
    String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
}

private func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private struct CLIError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private struct Finding: Encodable, CustomStringConvertible {
    let path: String
    let line: Int
    let severity: String
    let message: String
    let field: String?

    init(path: String, diagnostic: Diagnostic) {
        self.path = path
        line = diagnostic.line ?? 1
        severity = diagnostic.severity.rawValue
        message = diagnostic.message
        field = diagnostic.path
    }

    var description: String {
        let location = field.map { "\($0): " } ?? ""
        let text = (location + message).replacingOccurrences(of: "\n", with: "\\n")
        return "\(path):\(line): \(severity): \(text)"
    }
}

private struct Listing: Encodable {
    let id: String
    let kind: String
    let title: String
    let source: String
    let errors: Int
    let warnings: Int
}

private struct Arguments {
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    init(_ args: [String], flags: Set<String> = [], options: Set<String> = []) throws {
        var words = args.makeIterator()
        while let token = words.next() {
            if token == "--" {
                while let rest = words.next() { positional.append(rest) }
            } else if flags.contains(token) {
                guard self.flags.insert(token).inserted else { throw CLIError("duplicate flag \(token)") }
            } else if options.contains(token) {
                guard self.options[token] == nil else { throw CLIError("duplicate option \(token)") }
                guard let value = words.next(), !flags.contains(value), !options.contains(value), value != "--" else {
                    throw CLIError("missing value for \(token)")
                }
                self.options[token] = value
            } else if token.hasPrefix("--") {
                throw CLIError("unknown option \(token)")
            } else {
                positional.append(token)
            }
        }
    }

    func require(_ count: Int, usage: String) throws {
        guard positional.count == count else { throw CLIError("usage: \(usage)") }
    }
}
