import Foundation

// Ask runs the user's own Claude Code CLI headless (`claude -p`), never an API key of Strata's. This
// file finds the binary from a GUI app, whose PATH is minimal, and builds the read-only invocation.

/// Finds the `claude` binary: the configured path, then the login shell's `command -v claude`, then
/// the usual install locations. Every input is injectable, so the order is checkable without a shell.
public struct ClaudeLocator: Sendable {
    public struct Found: Sendable, Equatable {
        public var path: String
        /// How it was found: "config", "login shell" or "known location".
        public var via: String
        /// The login shell's PATH, handed to the child so a Node-based install finds `node`.
        public var searchPath: String?
        public init(path: String, via: String, searchPath: String? = nil) { self.path = path; self.via = via; self.searchPath = searchPath }
    }

    /// What a login shell reports: the path `command -v claude` printed (if any) and its PATH.
    public struct ShellAnswer: Sendable, Equatable {
        public var claude: String?
        public var path: String?
        public init(claude: String?, path: String?) { self.claude = claude; self.path = path }
    }

    public var configured: String?
    public var shell: @Sendable () -> ShellAnswer?
    public var candidates: [String]
    public var isExecutable: @Sendable (String) -> Bool

    public init(configured: String?, shell: @escaping @Sendable () -> ShellAnswer?, candidates: [String],
                isExecutable: @escaping @Sendable (String) -> Bool) {
        self.configured = configured; self.shell = shell; self.candidates = candidates; self.isExecutable = isExecutable
    }

    public func locate() -> Found? {
        if let configured, !configured.isEmpty {
            let path = StrataPaths.expand(configured)
            return isExecutable(path) ? Found(path: path, via: "config") : nil
        }
        let answer = shell()
        if let claude = answer?.claude, claude.hasPrefix("/"), isExecutable(claude) {
            return Found(path: claude, via: "login shell", searchPath: answer?.path)
        }
        for candidate in candidates where isExecutable(candidate) {
            return Found(path: candidate, via: "known location", searchPath: answer?.path)
        }
        return nil
    }

    /// The real lookup: `ask.claude` from config, `zsh -lc` (then `-lic`, for a PATH set in .zshrc), and
    /// the places Claude Code's installers use.
    public static func standard(configured: String?) -> ClaudeLocator {
        ClaudeLocator(configured: configured, shell: { loginShell() }, candidates: knownLocations(),
                      isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    public static func knownLocations(home: String = NSHomeDirectory()) -> [String] {
        var paths = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.volta/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/Library/pnpm/claude",
        ]
        // nvm keeps one directory per Node version; newest first.
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin/claude" }
        }
        return paths
    }

    /// Asks a login shell where `claude` is, and for its PATH. Five seconds at most per try.
    static func loginShell() -> ShellAnswer? {
        let marker = "__STRATA_PATH__"
        for flags in ["-lc", "-lic"] {
            guard let output = run("/bin/zsh", [flags, "command -v claude; printf '\(marker)%s\\n' \"$PATH\""], timeout: 5) else { continue }
            var claude: String?
            var path: String?
            for line in output.split(separator: "\n").map(String.init) {
                if line.hasPrefix(marker) { path = String(line.dropFirst(marker.count)) }
                else if line.hasPrefix("/") { claude = claude ?? line }
            }
            if claude != nil { return ShellAnswer(claude: claude, path: path) }
            if flags == "-lic", path != nil { return ShellAnswer(claude: nil, path: path) }
        }
        return nil
    }

    /// Runs a short command and returns its stdout, or nil on failure or timeout.
    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // Read while it runs so a chatty shell never blocks on a full pipe.
        var data = Data()
        let reader = DispatchQueue(label: "strata.ask.shell")
        let read = DispatchSemaphore(value: 0)
        reader.async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        _ = read.wait(timeout: .now() + 1)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Everything needed to start one `claude -p` run.
public struct ClaudeInvocation: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var directory: String
    public var environment: [String: String]
    /// The prompt, written to stdin (a large digest doesn't fit comfortably in argv).
    public var input: String
}

public enum AskInvocation {
    /// The only tools Claude gets: it can read the repo and the manifest, nothing else.
    public static let tools = ["Read", "Grep", "Glob"]
    /// Denied outright as well, in case a settings file allows them.
    public static let denied = ["Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch", "Agent", "Task"]

    /// The flags, in order: headless, streaming JSON with partial messages, the appended system prompt,
    /// read-only tools, no MCP servers, no saved session, no skills; the repo as an extra directory; a
    /// model only when `ask.model` names one (else the user's Claude Code default).
    public static func arguments(model: String?, repo: String?) -> [String] {
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--append-system-prompt", AskPrompt.system,
                    "--tools", tools.joined(separator: ","),
                    "--allowedTools"] + tools
        args += ["--disallowedTools"] + denied
        args += ["--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"]
        if let repo { args += ["--add-dir", repo] }
        if let model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    /// The repo's absolute path when it is a directory on this machine.
    public static func repoOnDisk(_ manifest: Manifest) -> String? {
        guard let repo = manifest.repo else { return nil }
        let path = StrataPaths.expand(repo)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : nil
    }

    /// Where Claude runs without a repo: an empty directory, so it reads nothing by accident.
    public static func emptyDirectory() -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("strata-ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    public static func make(claude: ClaudeLocator.Found, prompt: String, manifest: Manifest, model: String?,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeInvocation {
        let repo = repoOnDisk(manifest)
        return ClaudeInvocation(executable: claude.path, arguments: arguments(model: model, repo: repo),
                                directory: repo ?? emptyDirectory(),
                                environment: environment(base: base, searchPath: claude.searchPath, claude: claude.path),
                                input: prompt)
    }

    /// The child's environment: ours, with the login shell's PATH (plus the binary's own directory and
    /// the usual ones), and without the variables that mark a nested Claude Code session.
    public static func environment(base: [String: String], searchPath: String?, claude: String) -> [String: String] {
        var env = base
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        var dirs: [String] = []
        for part in [searchPath, base["PATH"]].compactMap({ $0 }) {
            for dir in part.split(separator: ":").map(String.init) where !dirs.contains(dir) { dirs.append(dir) }
        }
        let own = (claude as NSString).deletingLastPathComponent
        for dir in [own, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !dirs.contains(dir) {
            dirs.append(dir)
        }
        env["PATH"] = dirs.joined(separator: ":")
        return env
    }
}
