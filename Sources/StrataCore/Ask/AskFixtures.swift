import Foundation

/// Canned Claude Code stream-json output for the checks and the snapshots: the shapes `claude -p
/// --output-format stream-json --verbose --include-partial-messages` prints, trimmed to the fields
/// Ask reads. The answer cites the bundled checkout map (Resources/Examples/checkout.yaml).
public enum AskFixtures {
    public static let manifest = "checkout"
    public static let question = "What happens if Postgres is down for 30 s?"

    /// Every link resolves in the checkout map except `ledger`, which must render as plain text.
    public static let answer = """
        Checkout fails fast while [Postgres](strata:node/db) is down; requests don't queue up.

        - [orders-svc](strata:node/orders) can't run [INSERT order + outbox](strata:op/orders/insert-order), so PlaceOrder \
        returns UNAVAILABLE and the [API gateway](strata:node/api) answers 503 on [POST /v1/orders](strata:op/api/post-orders).
        - The [outbox relay](strata:node/orders/relay) can't claim rows ([relay cycle](strata:how/orders/relay/relay-cycle)), \
        so no OrderPlaced reaches the [mailer](strata:node/mailer). Nothing is lost; it catches up after.
        - No order enters [10 · placed](strata:enum/order-status/10) in [orders](strata:table/orders) for those 30 s.
        - The map doesn't say whether the web app retries on its own; [submit order](strata:op/web/submit-order) shows a retry button after 10 s.

        Run [Postgres outage](strata:scenario/db-outage) to watch it. The [ledger](strata:node/ledger) isn't in this map.
        """

    /// A whole successful run: init, a Grep of the manifest, then the answer streamed in small deltas.
    public static func success(answer: String = answer, chunk: Int = 18) -> [String] {
        var lines = [init_]
        lines += turn(id: "msg_1", tool: ("Grep", ["pattern": "kill db", "path": "/tmp/checkout.yaml"]))
        lines.append(json(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "toolu_1", "content": "946:  - id: db-outage"]]]]))
        lines += turn(id: "msg_2", text: answer, chunk: chunk)
        lines.append(json(["type": "rate_limit_event", "rate_limit_info": ["status": "allowed", "resetsAt": 1795112400]]))
        lines.append(json(["type": "result", "subtype": "success", "is_error": false, "result": answer,
                           "duration_ms": 6400, "num_turns": 2, "total_cost_usd": 0.0123]))
        return lines
    }

    /// The first `count` lines of `success()`: a run caught mid-answer.
    public static func streaming(upTo fraction: Double = 0.55) -> [String] {
        let all = success()
        let start = all.firstIndex { $0.contains("\"msg_2\"") } ?? 0
        let end = all.lastIndex { $0.contains("text_delta") } ?? all.count - 1
        return Array(all.prefix(start + Int(Double(end - start) * fraction)))
    }

    /// Claude says what it is about to do, uses a tool, then answers: the answer is the last turn.
    public static let narrated: [String] = {
        var lines = [init_]
        lines += turn(id: "msg_1", text: "Let me check the relay.", chunk: 64)
        lines += turn(id: "msg_2", tool: ("Read", ["file_path": "/repo/services/orders/outbox/relay.go"]))
        lines += turn(id: "msg_3", text: "The [relay](strata:node/orders/relay) polls every 500 ms.", chunk: 64)
        lines.append(json(["type": "result", "subtype": "success", "is_error": false,
                           "result": "The [relay](strata:node/orders/relay) polls every 500 ms.", "num_turns": 3]))
        return lines
    }()

    /// Older output without partial messages: whole assistant messages only.
    public static let wholeMessages: [String] = [
        init_,
        json(["type": "assistant", "message": ["id": "msg_1", "role": "assistant", "content": [["type": "text", "text": "One line."]]]]),
        json(["type": "result", "subtype": "success", "is_error": false, "result": "One line.", "num_turns": 1]),
    ]

    public static let notLoggedIn: [String] = [
        init_,
        json(["type": "result", "subtype": "success", "is_error": true, "result": "Not logged in · Please run /login", "num_turns": 0]),
    ]

    public static let rateLimited: [String] = [
        init_,
        json(["type": "rate_limit_event", "rate_limit_info": ["status": "rejected", "resetsAt": 1795112400]]),
        json(["type": "result", "subtype": "success", "is_error": true, "result": "You've hit your limit · resets 3pm",
              "api_error_status": 429, "num_turns": 0]),
    ]

    private static let init_ = json(["type": "system", "subtype": "init", "cwd": "/tmp/strata-ask", "session_id": "fixture",
                                     "tools": ["Glob", "Grep", "Read"], "mcp_servers": [] as [Any], "model": "claude-fixture",
                                     "permissionMode": "default"])

    private static func turn(id: String, text: String? = nil, tool: (name: String, input: [String: Any])? = nil, chunk: Int = 18) -> [String] {
        var lines = [json(["type": "stream_event", "event": ["type": "message_start",
                                                             "message": ["id": id, "role": "assistant", "content": [] as [Any]]]])]
        var content: [[String: Any]] = []
        if let text {
            lines.append(json(["type": "stream_event", "event": ["type": "content_block_start", "index": 0,
                                                                 "content_block": ["type": "text", "text": ""]]]))
            var rest = Substring(text)
            while !rest.isEmpty {
                let piece = rest.prefix(chunk)
                rest = rest.dropFirst(piece.count)
                lines.append(json(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0,
                                                                     "delta": ["type": "text_delta", "text": String(piece)]]]))
            }
            content.append(["type": "text", "text": text])
        }
        if let tool {
            lines.append(json(["type": "stream_event", "event": ["type": "content_block_start", "index": 0,
                                                                 "content_block": ["type": "tool_use", "id": "toolu_1",
                                                                                   "name": tool.name, "input": [:] as [String: Any]]]]))
            content.append(["type": "tool_use", "id": "toolu_\(id)", "name": tool.name, "input": tool.input])
        }
        lines.append(json(["type": "assistant", "message": ["id": id, "role": "assistant", "content": content]]))
        lines.append(json(["type": "stream_event", "event": ["type": "message_stop"]]))
        return lines
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
