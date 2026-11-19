import Foundation

// Reads Claude Code's `--output-format stream-json --verbose --include-partial-messages` output, one
// JSON object per line, into what the Ask panel shows: the answer as it streams, what Claude is reading,
// and how the run ended. Pure, so canned streams check it without a network.

public enum AskEvent: Sendable, Equatable {
    /// The session started (the `init` line), with the model Claude Code picked.
    case started(model: String?)
    /// Text appended to the answer.
    case text(String)
    /// A new assistant turn began after the answer already had text: what follows replaces it (the
    /// answer is the last turn, after any tool use).
    case newTurn
    /// A tool use, described for the status line ("Reading internal/pacing.go").
    case tool(String)
}

/// The final `result` line.
public struct AskResult: Sendable, Equatable {
    public var isError: Bool
    public var subtype: String
    public var text: String
    public var apiErrorStatus: Int?
    public var costUSD: Double?
    public var durationMS: Int?
    public var turns: Int?
}

/// Why a run produced no answer, with a calm message that says what to do.
public enum AskFailure: Sendable, Equatable {
    case disabled
    case notInstalled
    case notLoggedIn
    case rateLimited(resets: Date?)
    case overloaded
    case timedOut(seconds: Int)
    case failed(String)

    public var title: String {
        switch self {
        case .disabled: "Ask is off"
        case .notInstalled: "Claude Code not found"
        case .notLoggedIn: "Claude Code isn't logged in"
        case .rateLimited: "Usage limit reached"
        case .overloaded: "Claude is busy"
        case .timedOut: "No answer in time"
        case .failed: "Claude Code stopped"
        }
    }

    public var message: String {
        switch self {
        case .disabled:
            return "Ask is turned off. Turn it on in the Ask tab, or remove `ask: { enabled: false }` from ~/.strata/config.yaml."
        case .notInstalled:
            return "Strata couldn't find the `claude` command. Install Claude Code (claude.com/claude-code), or set "
                + "`ask: { claude: /path/to/claude }` in ~/.strata/config.yaml."
        case .notLoggedIn:
            return "Run `claude` once in a terminal to log in, then ask again."
        case .rateLimited(let resets):
            guard let resets else { return "Your Claude usage limit is reached. Ask again once it resets." }
            let formatter = DateFormatter()
            formatter.dateStyle = Calendar.current.isDate(resets, inSameDayAs: Date()) ? .none : .medium
            formatter.timeStyle = .short
            return "Your Claude usage limit is reached until \(formatter.string(from: resets)). Ask again then."
        case .overloaded:
            return "Claude is overloaded right now. Try again in a minute."
        case .timedOut(let seconds):
            return "Nothing came back for \(seconds) s, so Strata stopped waiting. Try a narrower question, or ask again."
        case .failed(let detail):
            return detail.isEmpty ? "Claude Code exited without an answer. Try again, or run `claude` in a terminal to check it works."
                : "Claude Code exited with: \(detail)"
        }
    }

    /// Reads a failure out of how the run ended: the result line, the exit status, stderr and any
    /// rate-limit event. nil when it succeeded.
    public static func classify(result: AskResult?, exitStatus: Int32, stderr: String, rateLimit: AskRateLimit?) -> AskFailure? {
        let failed = result?.isError == true || (result == nil && exitStatus != 0)
        guard failed else { return nil }
        let text = [result?.text ?? "", stderr].joined(separator: "\n")
        let lower = text.lowercased()
        let status = result?.apiErrorStatus
        if status == 401 || status == 403 || ["not logged in", "/login", "invalid api key", "authentication_error", "oauth token",
                                              "please log in", "login required", "credentials"].contains(where: lower.contains) {
            return .notLoggedIn
        }
        if status == 429 || rateLimit?.status == "rejected"
            || ["usage limit", "rate limit", "rate_limit", "limit reached", "hit your limit", "too many requests"].contains(where: lower.contains) {
            return .rateLimited(resets: rateLimit?.resetsAt)
        }
        if status == 529 || lower.contains("overloaded") { return .overloaded }
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return .failed(String(line.prefix(240)))
    }
}

public struct AskRateLimit: Sendable, Equatable {
    public var status: String
    public var resetsAt: Date?
}

/// The parser: feed it lines, read the events and the state.
public struct AskStream: Sendable {
    /// The current turn's text: the answer so far.
    public private(set) var answer = ""
    /// The last turn that wrote text, kept in case the final turn writes none.
    public private(set) var lastText = ""
    public private(set) var model: String?
    public private(set) var result: AskResult?
    public private(set) var rateLimit: AskRateLimit?
    /// Tool uses so far, described.
    public private(set) var tools: [String] = []
    /// Lines that weren't JSON (a CLI that printed an error as text), kept for the failure message.
    public private(set) var noise: [String] = []
    private var partials = false
    private var turnStarted = false
    private var describedTools: Set<String> = []
    /// Shortens paths under the repo in tool descriptions.
    public var repo: String?

    public init(repo: String? = nil) { self.repo = repo }

    /// The answer to keep: the result's text, else the last turn that wrote any.
    public var finalAnswer: String {
        if let result, !result.isError, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return result.text }
        return answer.isEmpty ? lastText : answer
    }

    public mutating func feed(_ line: String) -> [AskEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if noise.count < 20 { noise.append(String(trimmed.prefix(400))) }
            return []
        }
        switch object["type"] as? String {
        case "system":
            guard object["subtype"] as? String == "init" else { return [] }
            model = object["model"] as? String
            return [.started(model: model)]
        case "stream_event":
            partials = true
            return streamEvent(object["event"] as? [String: Any] ?? [:])
        case "assistant":
            return assistant(object["message"] as? [String: Any] ?? [:])
        case "rate_limit_event":
            let info = object["rate_limit_info"] as? [String: Any] ?? [:]
            rateLimit = AskRateLimit(status: info["status"] as? String ?? "",
                                     resetsAt: (info["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
            return []
        case "result":
            result = AskResult(isError: object["is_error"] as? Bool ?? (object["subtype"] as? String != "success"),
                               subtype: object["subtype"] as? String ?? "",
                               text: object["result"] as? String ?? "",
                               apiErrorStatus: object["api_error_status"] as? Int,
                               costUSD: object["total_cost_usd"] as? Double,
                               durationMS: object["duration_ms"] as? Int,
                               turns: object["num_turns"] as? Int)
            return []
        default:
            return []
        }
    }

    private mutating func streamEvent(_ event: [String: Any]) -> [AskEvent] {
        switch event["type"] as? String {
        case "message_start":
            return startTurn()
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any] ?? [:]
            guard delta["type"] as? String == "text_delta", let text = delta["text"] as? String, !text.isEmpty else { return [] }
            answer += text
            lastText = answer
            return [.text(text)]
        default:
            return []
        }
    }

    private mutating func startTurn() -> [AskEvent] {
        defer { turnStarted = true }
        guard turnStarted, !answer.isEmpty else { return [] }
        answer = ""
        return [.newTurn]
    }

    /// A whole assistant message: names the tools it used with their inputs (a tool's input streams in
    /// pieces, so it is described from here, just before the tool runs); without partial messages it
    /// also carries the text.
    private mutating func assistant(_ message: [String: Any]) -> [AskEvent] {
        var events: [AskEvent] = []
        let content = message["content"] as? [[String: Any]] ?? []
        for block in content where block["type"] as? String == "tool_use" {
            let name = block["name"] as? String ?? "tool"
            let id = block["id"] as? String ?? UUID().uuidString
            guard describedTools.insert(id).inserted else { continue }
            let described = Self.describe(tool: name, input: block["input"] as? [String: Any] ?? [:], repo: repo)
            tools.append(described)
            events.append(.tool(described))
        }
        guard !partials else { return events }
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { return events }
        events = startTurn() + events
        answer = text
        lastText = text
        return events + [.text(text)]
    }

    /// "Reading internal/pacing.go", "Searching for “SKIP LOCKED”", "Listing **/*.sql".
    public static func describe(tool: String, input: [String: Any], repo: String?) -> String {
        func short(_ path: String) -> String {
            if let repo, path.hasPrefix(repo + "/") { return String(path.dropFirst(repo.count + 1)) }
            let parts = path.split(separator: "/")
            return parts.count > 2 ? parts.suffix(2).joined(separator: "/") : path
        }
        switch tool {
        case "Read":
            return (input["file_path"] as? String).map { "Reading \(short($0))" } ?? "Reading a file"
        case "Grep":
            return (input["pattern"] as? String).map { "Searching for “\($0.prefix(60))”" } ?? "Searching"
        case "Glob":
            return (input["pattern"] as? String).map { "Listing \($0.prefix(60))" } ?? "Listing files"
        default:
            return "Using \(tool)"
        }
    }
}
