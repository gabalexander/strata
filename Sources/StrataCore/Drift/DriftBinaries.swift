import Foundation

/// Binaries: Go `main` packages (`cmd/*` above all), Procfile entries and the commands Dockerfiles run,
/// against the nodes' `binary:`. A node may run one binary with subcommands (`binary: "tool start
/// worker"`): the tool must still exist and each subcommand must still be declared (cobra `Use:`,
/// kingpin `Command(…)`, urfave `Name:`, or an `os.Args` switch) when the repo declares any.
enum DriftBinaries {
    struct GoMain { var dir: String; var name: String; var file: String; var line: Int; var primary: Bool }
    struct ProcEntry { var name: String; var command: String; var file: String; var line: Int }

    struct Index {
        var mains: [GoMain] = []
        var procfile: [ProcEntry] = []
        /// Docker build outputs: `go build -o /bin/api ./cmd/api` → api: cmd/api.
        var built: [String: String] = [:]
        /// Words Dockerfiles run (ENTRYPOINT and CMD), for subcommands.
        var dockerWords: Set<String> = []
        /// Subcommand name → the files that declare it.
        var subcommands: [String: [String]] = [:]
    }

    private static let auxiliary: Set<String> = ["tools", "tool", "hack", "scripts", "script", "examples", "example", "_examples", "test",
                                                 "tests", "e2e", "integration", "bench", "benchmarks", "mock", "mocks", "docs", "fixtures"]

    static func index(_ repo: DriftRepo) -> Index {
        var index = Index()
        var seenDirs = Set<String>()
        for file in repo.goSources {
            let facts = repo.goFacts(file)
            for name in facts.subcommands { index.subcommands[name, default: []].append(file) }
            guard facts.package == "main", let at = facts.mainLine else { continue }
            let dir = (file as NSString).deletingLastPathComponent
            guard seenDirs.insert(dir).inserted else { continue }
            let parts = dir.split(separator: "/").map(String.init)
            let name = dir.isEmpty ? repo.root.lastPathComponent : (dir as NSString).lastPathComponent
            // A deployable: the root package, or cmd/<name> at the top or in a service dir (services/x/cmd/api).
            // Deeper or internal mains (test plugins, codegen tools) are notes.
            let containers = parts.dropLast()
            let underCmd = parts.count >= 2 && parts[parts.count - 2] == "cmd"
            let aux = containers.contains(where: auxiliary.contains) || !underCmd && parts.last.map(auxiliary.contains) == true
            let primary = dir.isEmpty || underCmd && parts.count <= 4 && !aux
                && containers.allSatisfy { $0 != "internal" && !$0.contains("test") }
            if aux && !primary { continue }
            index.mains.append(GoMain(dir: dir, name: name, file: file, line: at, primary: primary))
        }
        for file in repo.files {
            let name = (file as NSString).lastPathComponent.lowercased()
            if name.hasPrefix("procfile"), let lines = repo.lines(file) {
                for (i, line) in lines.enumerated() {
                    let text = line.trimmingCharacters(in: .whitespaces)
                    guard !text.hasPrefix("#"), let colon = text.firstIndex(of: ":") else { continue }
                    let entry = String(text[..<colon])
                    guard !entry.isEmpty, entry.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { continue }
                    index.procfile.append(ProcEntry(name: entry, command: text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces),
                                                    file: file, line: i + 1))
                }
            } else if name.hasPrefix("dockerfile") || name.hasSuffix(".dockerfile"), let lines = repo.lines(file) {
                for line in lines {
                    let text = line.trimmingCharacters(in: .whitespaces)
                    let upper = text.uppercased()
                    if upper.hasPrefix("ENTRYPOINT") || upper.hasPrefix("CMD") {
                        for word in dockerWords(String(text.drop { !$0.isWhitespace })) {
                            index.dockerWords.insert(word)
                            index.dockerWords.insert((word as NSString).lastPathComponent)
                        }
                    }
                    if upper.hasPrefix("RUN"), text.contains("go build") {
                        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
                        if let o = words.firstIndex(of: "-o"), o + 1 < words.count,
                           let package = words[(o + 2)...].first(where: { $0.hasPrefix("./") || $0.contains("/cmd/") || $0.hasPrefix("cmd/") }) {
                            let out = (words[o + 1] as NSString).lastPathComponent
                            var dir = package
                            while dir.hasPrefix("./") { dir.removeFirst(2) }
                            if dir.hasSuffix("/...") { dir.removeLast(4) }
                            index.built[out] = dir
                        }
                    }
                }
            }
        }
        return index
    }

    static func mainLine(_ tokens: [GoToken]) -> Int? {
        for i in 0..<max(0, tokens.count - 2) where tokens[i].kind == .ident && tokens[i].text == "func"
            && tokens[i + 1].kind == .ident && tokens[i + 1].text == "main" && tokens[i + 2].text == "(" {
            return tokens[i].line
        }
        return nil
    }

    /// Subcommand names a Go file declares.
    static func subcommands(_ tokens: [GoToken], imports: [String]) -> [String] {
        var out: [String] = []
        let urfave = imports.contains { $0.contains("urfave/cli") }
        let args = tokens.contains { $0.kind == .ident && $0.text == "Args" }
        var i = 0
        while i + 2 < tokens.count {
            let token = tokens[i]
            if token.kind == .ident {
                // cobra: Use: "worker [flags]"; urfave: Name: "worker"
                if token.text == "Use" || urfave && token.text == "Name" && inCommandLiteral(tokens, before: i),
                   tokens[i + 1].text == ":", tokens[i + 2].kind == .string,
                   let word = tokens[i + 2].text.split(separator: " ").first {
                    out.append(String(word))
                }
                // kingpin, kong: app.Command("worker", …)
                if token.text == "Command", tokens[i + 1].text == "(", tokens[i + 2].kind == .string, !tokens[i + 2].text.isEmpty {
                    out.append(tokens[i + 2].text)
                }
                // switch os.Args[1] { case "worker": … }
                if args, token.text == "case" {
                    var j = i + 1
                    while j < tokens.count, tokens[j].kind == .string || tokens[j].text == "," {
                        if tokens[j].kind == .string, !tokens[j].text.isEmpty, !tokens[j].text.contains(" ") {
                            out.append(tokens[j].text)
                        }
                        j += 1
                    }
                }
            }
            i += 1
        }
        return out
    }

    /// urfave/cli: `Name:` inside a `cli.Command{…}` literal, not a flag's.
    private static func inCommandLiteral(_ tokens: [GoToken], before index: Int) -> Bool {
        var depth = 0
        var j = index - 1
        while j >= 0, index - j < 400 {
            let text = tokens[j].text
            if text == "}" { depth += 1 }
            if text == "{" {
                if depth == 0 {
                    guard j > 0 else { return false }
                    let type = tokens[j - 1].text
                    // An element of `[]*cli.Command{ {…}, {…} }` has its type elided: look one level out.
                    if type != "{" && type != "," && tokens[j - 1].kind != .newline { return type == "Command" || type == "App" }
                }
                depth -= 1
            }
            j -= 1
        }
        return false
    }

    /// The words of an ENTRYPOINT or CMD: the exec form's JSON array, or the shell form split on spaces.
    static func dockerWords(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
           let words = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return words
        }
        return trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The binary a `binary:` names and its subcommand words: `./cmd/api` → (cmd/api, []),
    /// `tool start worker --fast` → (tool, [start, worker]), `go run ./cmd/api` → (cmd/api, []).
    static func split(_ binary: String) -> (tool: String, subcommands: [String]) {
        var words = binary.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count >= 3, words[0] == "go", words[1] == "run" { words.removeFirst(2) }
        guard var tool = words.first else { return ("", []) }
        while tool.hasPrefix("./") { tool.removeFirst(2) }
        if tool.hasSuffix("/main.go") { tool.removeLast("/main.go".count) }
        while tool.count > 1, tool.hasSuffix("/") { tool.removeLast() }
        let subcommands = words.dropFirst().prefix { word in
            !word.hasPrefix("-") && !word.contains("=") && !word.contains("/") && word.first?.isLetter == true
                && word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
        return (tool, Array(subcommands))
    }

    static func run(_ context: DriftContext) {
        let repo = context.repo
        let index = index(repo)
        let facts = context.facts
        var matchedMains = Set<String>(), matchedProcs = Set<String>()
        var mappedTools: Set<String> = []
        var mappedChains: [(tool: String, words: [String])] = []

        for fact in facts.binaries {
            let (tool, words) = split(fact.binary)
            guard !tool.isEmpty else { continue }
            context.checked(.binaries)
            let key = "binaries|\(fact.location)"
            let base = (tool as NSString).lastPathComponent
            mappedTools.insert(base)
            mappedChains.append((tool, words))
            // A source path (cmd/api) names its package and nothing else; a bare name or a built artifact
            // (api, bin/api) can be a main package, a Procfile entry or a Docker build output.
            let sourcePath = tool.contains("/") && (tool.hasPrefix("cmd/") || tool.contains("/cmd/") || repo.exists(tool).directory)
            let mains = index.mains.filter { main in
                main.dir == tool || main.dir.hasSuffix("/" + tool) || !sourcePath && (main.name == base || index.built[base] == main.dir)
            }
            let procs = sourcePath ? [] : index.procfile.filter { entry in
                entry.name == tool || entry.command.split(whereSeparator: \.isWhitespace).contains { ($0 as NSString).lastPathComponent == base }
            }
            mains.forEach { matchedMains.insert($0.dir) }
            procs.forEach { matchedProcs.insert($0.name) }
            let onDisk = tool.contains("/") && repo.exists(tool).exists
            if mains.isEmpty && procs.isEmpty && !onDisk && (sourcePath || !index.dockerWords.contains(base)) {
                let path = tool.contains("/")
                let near = path ? DriftCode.rank(repo.directoriesByName[base] ?? [], like: tool).first : nil
                let candidates = index.mains.filter(\.primary).map(\.dir)
                context.add(DriftFinding(path ? .error : .warn, .binaries, "binary-gone",
                                         message: path ? "\(tool) is no longer a main package in the repo" : "no main package, Procfile entry or Docker command is called \(tool)",
                                         fix: near.map { "Point binary at \($0)." }
                                            ?? (candidates.isEmpty ? "Remove binary: or point it at what runs now." : "Point binary at one of \(candidates.prefix(4).joined(separator: ", ")), or remove it."),
                                         map: fact.location, repo: path ? DriftRepoLocation(file: tool) : nil, ref: fact.binary, found: near), fact: key)
                continue
            }
            guard !index.subcommands.isEmpty else { continue }
            for word in words where index.subcommands[word] == nil && !index.dockerWords.contains(word) {
                context.add(DriftFinding(.warn, .binaries, "subcommand-gone",
                                         message: "\(tool) has no subcommand \(word) any more",
                                         fix: "Update binary: to the command this node runs now.",
                                         map: fact.location, ref: fact.binary), fact: key)
                break
            }
        }

        // Main packages and Procfile entries no node runs. A code reference into the package counts as mapped.
        let codePaths = facts.codeRefs.compactMap { DriftCode.parse($0.ref, root: repo.rootPath)?.path }
        for main in index.mains where !matchedMains.contains(main.dir) {
            let mentioned = main.dir.isEmpty
                ? mappedTools.contains(main.name) || codePaths.contains("main.go")
                : codePaths.contains { $0 == main.dir || $0.hasPrefix(main.dir + "/") } || DriftRepo.contains(facts.text, main.dir)
            guard !mentioned else { continue }
            let label = main.dir.isEmpty ? "the root main package (\(main.name))" : main.dir
            context.add(DriftFinding(main.primary ? .warn : .info, .binaries, "unmapped-binary",
                                     message: "\(label) builds a binary no node runs",
                                     fix: "Add a node for it (kind service, worker or cron) with binary: \(main.dir.isEmpty ? main.name : main.dir) and code: \(main.file).",
                                     repo: DriftRepoLocation(file: main.file, line: main.line), ref: main.dir.isEmpty ? main.name : main.dir))
        }
        for entry in index.procfile where !matchedProcs.contains(entry.name) {
            let mapped = facts.binaries.contains { $0.binary.trimmingCharacters(in: .whitespaces) == entry.command }
                || entry.command.split(whereSeparator: \.isWhitespace).contains { mappedTools.contains(($0 as NSString).lastPathComponent) }
            guard !mapped else { continue }
            context.add(DriftFinding(.warn, .binaries, "unmapped-binary",
                                     message: "Procfile entry \(entry.name) (\(entry.command)) runs on no node",
                                     fix: "Add a node with binary: \(entry.name) for it.",
                                     repo: DriftRepoLocation(file: entry.file, line: entry.line), ref: entry.name))
        }

        // Subcommands declared next to the mapped ones (the same package) that no node runs.
        var mappedLeaves = Set<String>()
        for chain in mappedChains { if let leaf = chain.words.last { mappedLeaves.insert(leaf) } }
        var reported = Set<String>()
        var byDirectory: [String: [(name: String, file: String)]] = [:]
        for (name, declared) in index.subcommands {
            for file in declared { byDirectory[(file as NSString).deletingLastPathComponent, default: []].append((name, file)) }
        }
        var chains = Set<String>()
        for chain in mappedChains where chain.words.count >= 1 && chains.insert(([chain.tool] + chain.words).joined(separator: " ")).inserted {
            guard let leaf = chain.words.last, let files = index.subcommands[leaf] else { continue }
            let dirs = Set(files.map { ($0 as NSString).deletingLastPathComponent })
            let parentWords = Set(chain.words.dropLast())
            let siblings = dirs.flatMap { byDirectory[$0] ?? [] }.sorted { ($0.name, $0.file) < ($1.name, $1.file) }
            for (name, file) in siblings where !mappedLeaves.contains(name) && !parentWords.contains(name) && name != chain.tool {
                let command = ([chain.tool] + chain.words.dropLast() + [name]).joined(separator: " ")
                guard reported.insert(command).inserted, !DriftRepo.contains(facts.text, command) else { continue }
                context.add(DriftFinding(.info, .binaries, "unmapped-subcommand",
                                         message: "\(command) is declared next to the mapped subcommands but runs on no node",
                                         fix: "Add a node with binary: \(command) if it runs in production.",
                                         repo: DriftRepoLocation(file: file), ref: command))
            }
        }
    }
}
