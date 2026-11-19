import Foundation

/// A read-only index of a repo for drift: every file path (vendor/, node_modules/, .git/, build output and
/// generated dirs skipped), file names for moved-file hints, and file text read on demand with a size cap.
final class DriftRepo {
    let root: URL
    let rootPath: String
    private(set) var files: [String] = []
    private(set) var directories: Set<String> = []
    private(set) var byName: [String: [String]] = [:]
    private(set) var directoriesByName: [String: [String]] = [:]
    private(set) var truncated = false
    let maxFileBytes: Int
    private(set) var filesByDirectory: [String: [String]] = [:]
    private(set) var filesByExtension: [String: [String]] = [:]
    private var texts: [String: String?] = [:]
    /// File text stays cached up to this many bytes; past it, files are read again when asked for.
    private var textBudget = 96 << 20
    private var lineCache: [String: [Substring]] = [:]
    private var goCache: [String: GoFacts] = [:]

    /// Directory names never indexed: dependencies, VCS, build output, caches and generated code.
    static let skippedDirectories: Set<String> = [
        "vendor", "node_modules", "bower_components", "third_party", "dist", "out", "target", "coverage",
        "generated", "gen", "__generated__", "__pycache__", "venv", "testdata", "Pods", "DerivedData",
    ]

    init(root: URL, maxFiles: Int = 60_000, maxFileBytes: Int = 1_000_000) {
        self.root = root.standardizedFileURL
        rootPath = self.root.path
        self.maxFileBytes = maxFileBytes
        walk(maxFiles: maxFiles)
    }

    private func walk(maxFiles: Int) {
        guard let walker = FileManager.default.enumerator(atPath: rootPath) else { return }
        while let next = walker.nextObject() as? String {
            let name = (next as NSString).lastPathComponent
            let type = walker.fileAttributes?[.type] as? FileAttributeType
            if type == .typeDirectory {
                if name.hasPrefix(".") || Self.skippedDirectories.contains(name) { walker.skipDescendants(); continue }
                directories.insert(next)
                directoriesByName[name, default: []].append(next)
                continue
            }
            guard type == .typeRegular else { continue }
            if files.count >= maxFiles { truncated = true; break }
            files.append(next)
            byName[name, default: []].append(next)
        }
        files.sort()
        for file in files {
            filesByDirectory[(file as NSString).deletingLastPathComponent, default: []].append(file)
            filesByExtension[(file as NSString).pathExtension.lowercased(), default: []].append(file)
        }
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    /// Whether a path exists, looking at the disk itself so references into skipped dirs still resolve.
    func exists(_ relative: String) -> (exists: Bool, directory: Bool) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url(relative).path, isDirectory: &isDirectory)
        return (exists, isDirectory.boolValue)
    }

    /// The file's text, or nil when it is missing, binary or bigger than the cap.
    func text(_ relative: String) -> String? {
        if let cached = texts[relative] { return cached }
        var result: String?
        if let handle = FileHandle(forReadingAtPath: url(relative).path) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: maxFileBytes + 1), data.count <= maxFileBytes,
               !data.prefix(8192).contains(0) {
                result = String(decoding: data, as: UTF8.self)
            }
        }
        if let result {
            guard textBudget > 0 else { return result }
            textBudget -= result.utf8.count
        }
        texts[relative] = result
        return result
    }

    /// Where each name is defined: Go funcs, methods and types, and sqlc queries (`-- name:`), built once.
    lazy var definitions: [String: [(file: String, line: Int)]] = {
        var index: [String: [(String, Int)]] = [:]
        for file in goSources {
            for (name, line) in goFacts(file).definitions { index[name, default: []].append((file, line)) }
        }
        for file in sqlFiles {
            for (i, line) in (lines(file) ?? []).enumerated() {
                if let named = DriftSQL.sqlcName(String(line)) { index[named.name, default: []].append((file, i + 1)) }
            }
        }
        return index
    }()

    /// Substring search over UTF-8 bytes (memmem), much faster than String.contains on large texts.
    static func contains(_ text: String, _ needle: String) -> Bool {
        var text = text
        var needle = needle
        return text.withUTF8 { hay in
            needle.withUTF8 { pattern in
                guard pattern.count > 0, pattern.count <= hay.count else { return false }
                return memmem(hay.baseAddress, hay.count, pattern.baseAddress, pattern.count) != nil
            }
        }
    }

    /// The file's lines (without terminators); a trailing newline doesn't add an empty last line.
    func lines(_ relative: String) -> [Substring]? {
        if let cached = lineCache[relative] { return cached }
        guard let text = text(relative) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        lines = lines.map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        lineCache[relative] = lines
        return lines
    }

    func files(withExtension ext: String) -> [String] { files.filter { $0.hasSuffix("." + ext) } }

    /// Go source files that aren't tests or generated code.
    lazy var goSources: [String] = files.filter { $0.hasSuffix(".go") && !$0.hasSuffix("_test.go") && !isGenerated($0) }
    lazy var sqlFiles: [String] = files(withExtension: "sql")

    /// Marked `Code generated … DO NOT EDIT` near the top (Go's convention, which sqlc and protoc follow).
    func isGenerated(_ relative: String) -> Bool {
        guard let text = text(relative) else { return false }
        let head = text.prefix(2048)
        return head.contains("DO NOT EDIT") && (head.contains("Code generated") || head.contains("@generated"))
    }

    /// What the checks need from a Go file, from one pass of the lexer; the tokens aren't kept.
    struct GoFacts {
        var package: String?
        var mainLine: Int?
        var imports: [String] = []
        var literals: [(text: String, line: Int)] = []
        var subcommands: [String] = []
        var names: [DriftMessaging.RepoName] = []
        var constBlocks: [DriftEnums.Candidate] = []
        var typedConsts: [DriftEnums.TypedConst] = []
        /// Top-level funcs, methods and types: name → line.
        var definitions: [String: Int] = [:]
    }

    func goFacts(_ relative: String) -> GoFacts {
        if let cached = goCache[relative] { return cached }
        var facts = GoFacts()
        if let text = text(relative) {
            let tokens = GoLexer.tokens(Array(text.utf8))
            facts.package = GoLexer.packageName(tokens)
            facts.imports = GoLexer.imports(tokens)
            facts.literals = GoLexer.literals(tokens)
            if facts.package == "main" { facts.mainLine = DriftBinaries.mainLine(tokens) }
            facts.subcommands = DriftBinaries.subcommands(tokens, imports: facts.imports)
            facts.names = DriftMessaging.names(in: tokens, imports: facts.imports, literals: facts.literals, file: relative)
            (facts.constBlocks, facts.typedConsts) = DriftEnums.consts(in: tokens, file: relative)
            facts.definitions = GoLexer.definitions(tokens)
        }
        goCache[relative] = facts
        return facts
    }

    /// String literals of a source file in another C-like language (Java, Kotlin, TypeScript…), not kept.
    func literals(_ relative: String) -> [(text: String, line: Int)] {
        if relative.hasSuffix(".go") { return goFacts(relative).literals }
        return text(relative).map { GoLexer.literals(GoLexer.tokens(Array($0.utf8))) } ?? []
    }

    /// Text files whose whole content counts as "mentions" for names (configs, manifests, scripts).
    static let configExtensions: Set<String> = ["yaml", "yml", "json", "toml", "env", "properties", "ini", "conf", "cfg", "hcl", "tf", "sh"]
    /// Code in other languages: searched as whole text (string literals are only parsed for Go).
    static let otherCodeExtensions: Set<String> = ["java", "kt", "kts", "scala", "ts", "tsx", "js", "jsx", "mjs", "py", "rb", "rs", "cs", "php", "ex", "exs", "lua"]

    static func isConfigName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("procfile") || lower.hasPrefix("dockerfile") || lower.hasSuffix(".dockerfile")
            || lower == "makefile" || lower.hasPrefix(".env") || lower.hasPrefix("docker-compose")
    }
}

// MARK: - Git

/// Reads a checkout's HEAD commit from `.git` without running git: HEAD, the branch ref, packed-refs,
/// and the `gitdir:` file of a worktree or submodule. A repo inside a larger checkout uses its HEAD.
public enum DriftGit {
    public static func head(_ repo: URL) -> String? {
        var dir = repo.standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<12 {
            let dotGit = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                var gitDir = dotGit
                if !isDirectory.boolValue {
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
                }
                return resolve(gitDir: gitDir.standardizedFileURL)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private static func resolve(gitDir: URL) -> String? {
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard head.hasPrefix("ref:") else { return head.isEmpty ? nil : head }
        let ref = head.dropFirst(4).trimmingCharacters(in: .whitespaces)
        // A linked worktree keeps its HEAD; refs and packed-refs live in the common dir.
        var dirs = [gitDir]
        if let common = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty {
            dirs.append((common.hasPrefix("/") ? URL(fileURLWithPath: common) : gitDir.appendingPathComponent(common)).standardizedFileURL)
        }
        for dir in dirs {
            if let sha = try? String(contentsOf: dir.appendingPathComponent(ref), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty { return sha }
        }
        for dir in dirs {
            guard let packed = try? String(contentsOf: dir.appendingPathComponent("packed-refs"), encoding: .utf8) else { continue }
            for line in packed.split(separator: "\n") where line.hasSuffix(" " + ref) {
                return String(line.split(separator: " ")[0])
            }
        }
        return nil
    }
}

// MARK: - Go lexer

/// A Go token: enough to find string literals (and `+` concatenations), const blocks, declarations and
/// call arguments. Comments are dropped; newlines are kept because const specs end at them.
struct GoToken: Sendable {
    enum Kind: Sendable { case ident, string, number, punct, newline }
    var kind: Kind
    /// The identifier, the decoded string value, the number as written, or the punctuation.
    var text: String
    var line: Int
}

enum GoLexer {
    static func tokens(_ b: [UInt8]) -> [GoToken] {
        var out: [GoToken] = []
        out.reserveCapacity(b.count / 4)
        var i = 0, line = 1
        let n = b.count
        func isIdentStart(_ c: UInt8) -> Bool { c == 95 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c >= 0x80 }
        func isIdent(_ c: UInt8) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
        while i < n {
            let c = b[i]
            switch c {
            case 10:
                out.append(GoToken(kind: .newline, text: "\n", line: line)); line += 1; i += 1
            case 32, 9, 13:
                i += 1
            case 47 where i + 1 < n && b[i + 1] == 47:   // // comment
                while i < n && b[i] != 10 { i += 1 }
            case 47 where i + 1 < n && b[i + 1] == 42:   // /* comment */
                i += 2
                while i + 1 < n && !(b[i] == 42 && b[i + 1] == 47) { if b[i] == 10 { line += 1 }; i += 1 }
                i = min(n, i + 2)
            case 96:                                      // `raw string`
                let start = line
                var j = i + 1
                while j < n && b[j] != 96 { if b[j] == 10 { line += 1 }; j += 1 }
                let text = String(decoding: b[(i + 1)..<min(j, n)].filter { $0 != 13 }, as: UTF8.self)
                out.append(GoToken(kind: .string, text: text, line: start))
                i = min(n, j + 1)
            case 34 where i + 2 < n && b[i + 1] == 34 && b[i + 2] == 34:   // """text block""" (Java, Kotlin, Python)
                let start = line
                var j = i + 3
                while j + 2 < n && !(b[j] == 34 && b[j + 1] == 34 && b[j + 2] == 34) { if b[j] == 10 { line += 1 }; j += 1 }
                let text = String(decoding: b[(i + 3)..<min(j, n)].filter { $0 != 13 }, as: UTF8.self)
                out.append(GoToken(kind: .string, text: text, line: start))
                i = min(n, j + 3)
            case 34:                                      // "interpreted string"
                var bytes: [UInt8] = []
                var j = i + 1
                while j < n && b[j] != 34 && b[j] != 10 {
                    if b[j] == 92 && j + 1 < n {
                        switch b[j + 1] {
                        case 110: bytes.append(10)
                        case 116: bytes.append(9)
                        case 114: bytes.append(13)
                        case 34: bytes.append(34)
                        case 92: bytes.append(92)
                        case 39: bytes.append(39)
                        default: bytes.append(92); bytes.append(b[j + 1])
                        }
                        j += 2
                    } else {
                        bytes.append(b[j]); j += 1
                    }
                }
                out.append(GoToken(kind: .string, text: String(decoding: bytes, as: UTF8.self), line: line))
                i = min(n, j + 1)
            case 39:                                      // 'rune'
                var j = i + 1
                while j < n && b[j] != 39 && b[j] != 10 { j += b[j] == 92 ? 2 : 1 }
                out.append(GoToken(kind: .number, text: "rune", line: line))
                i = min(n, j + 1)
            case 48...57:
                var j = i
                while j < n && (isIdent(b[j]) || b[j] == 46) { j += 1 }
                out.append(GoToken(kind: .number, text: String(decoding: b[i..<j], as: UTF8.self), line: line))
                i = j
            default:
                if isIdentStart(c) {
                    var j = i
                    while j < n && isIdent(b[j]) { j += 1 }
                    out.append(GoToken(kind: .ident, text: String(decoding: b[i..<j], as: UTF8.self), line: line))
                    i = j
                } else {
                    // Two-character operators that matter to const expressions; everything else is one byte.
                    if i + 1 < n, (c == 60 && b[i + 1] == 60) || (c == 62 && b[i + 1] == 62) || (c == 58 && b[i + 1] == 61) {
                        out.append(GoToken(kind: .punct, text: String(decoding: b[i...(i + 1)], as: UTF8.self), line: line))
                        i += 2
                    } else {
                        out.append(GoToken(kind: .punct, text: String(UnicodeScalar(c)), line: line))
                        i += 1
                    }
                }
            }
        }
        return out
    }

    /// String literals with `"a" + "b"` concatenations (across lines) joined, at the first part's line.
    static func literals(_ tokens: [GoToken]) -> [(text: String, line: Int)] {
        var out: [(String, Int)] = []
        var i = 0
        while i < tokens.count {
            guard tokens[i].kind == .string else { i += 1; continue }
            var text = tokens[i].text
            let line = tokens[i].line
            var j = i + 1
            while true {
                var k = j
                while k < tokens.count, tokens[k].kind == .newline { k += 1 }
                guard k < tokens.count, tokens[k].kind == .punct, tokens[k].text == "+" else { break }
                k += 1
                while k < tokens.count, tokens[k].kind == .newline { k += 1 }
                guard k < tokens.count, tokens[k].kind == .string else { break }
                text += tokens[k].text
                j = k + 1
            }
            out.append((text, line))
            i = j
        }
        return out
    }

    /// Top-level `func Name`, `func (r *T) Name` and `type Name`: name → line.
    static func definitions(_ tokens: [GoToken]) -> [String: Int] {
        var out: [String: Int] = [:]
        var depth = 0
        var i = 0
        while i + 1 < tokens.count {
            let token = tokens[i]
            if token.kind == .punct {
                if token.text == "{" { depth += 1 } else if token.text == "}" { depth = max(0, depth - 1) }
            } else if depth == 0, token.kind == .ident, token.text == "func" || token.text == "type" {
                var j = i + 1
                if token.text == "func", tokens[j].text == "(" {
                    var parens = 0
                    while j < tokens.count {
                        if tokens[j].text == "(" { parens += 1 }
                        if tokens[j].text == ")" { parens -= 1; if parens == 0 { break } }
                        j += 1
                    }
                    j += 1
                }
                if j < tokens.count, tokens[j].kind == .ident, out[tokens[j].text] == nil { out[tokens[j].text] = token.line }
            }
            i += 1
        }
        return out
    }

    /// The import paths of a Go file.
    static func imports(_ tokens: [GoToken]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            if tokens[i].kind == .ident, tokens[i].text == "import" {
                var j = i + 1
                while j < tokens.count, tokens[j].kind == .newline { j += 1 }
                if j < tokens.count, tokens[j].kind == .punct, tokens[j].text == "(" {
                    j += 1
                    while j < tokens.count, !(tokens[j].kind == .punct && tokens[j].text == ")") {
                        if tokens[j].kind == .string { out.append(tokens[j].text) }
                        j += 1
                    }
                } else {
                    while j < tokens.count, tokens[j].kind != .newline {
                        if tokens[j].kind == .string { out.append(tokens[j].text); break }
                        j += 1
                    }
                }
                i = j
            } else if tokens[i].kind == .ident, ["func", "type", "var", "const"].contains(tokens[i].text) {
                break   // imports come first
            }
            i += 1
        }
        return out
    }

    static func packageName(_ tokens: [GoToken]) -> String? {
        for (i, token) in tokens.enumerated() where token.kind == .ident && token.text == "package" {
            return i + 1 < tokens.count && tokens[i + 1].kind == .ident ? tokens[i + 1].text : nil
        }
        return nil
    }
}
