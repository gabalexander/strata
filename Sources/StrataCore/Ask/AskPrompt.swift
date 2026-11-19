import Foundation

// What Ask sends to Claude Code: an appended system prompt that sets the tone and teaches the link
// syntax, and a user message with the map digest, where the user is in the app, and the question.

public struct AskExchangeContext: Sendable, Hashable {
    public var question: String
    public var answer: String
    public init(question: String, answer: String) { self.question = question; self.answer = answer }
}

public enum AskPrompt {
    /// Appended to Claude Code's own system prompt (`--append-system-prompt`).
    public static let system = """
        You answer questions about one architecture map in Strata, a macOS app for exploring systems. The map \
        is a YAML manifest a coding agent wrote from a real repository; the user is looking at it in the app.

        How to answer:
        - Be brief: a few lines or 3-5 short bullets, about 60-150 words. The user dislikes walls of text. No preamble, \
        no restating the question, no closing summary, no tables. Use a heading only when the answer has clearly \
        separate parts.
        - Answer from the map digest in the message. When the repo is on this machine you may Read, Grep and \
        Glob it to confirm or fill in details; cite files as `path:line` in backticks. You can also Grep the \
        manifest file for an id to see its full YAML when the digest cut something.
        - Say plainly when the map doesn't say, and when you are inferring or guessing ("the map doesn't say; \
        likely …").
        - Don't narrate tool use or say what you are about to do. Write only the answer.

        Cite what you mention as markdown links, so the user can click them in the app:
        - a node: [pacing](strata:node/pacing); a node inside a deep dive takes the level path first: \
        [handler](strata:node/orders/handler)
        - an operation: [list running](strata:op/pacing/list-running) (level path first in a deep dive)
        - a mechanism (how:): [reaper tick](strata:how/reaper-tick/reaper-tick); on an operation: \
        [lock](strata:how/orders/insert-order/lock)
        - an enum value: [3200 · undecided](strata:enum/campaign-status/3200); a whole enum: \
        [campaign status](strata:enum/campaign-status)
        - a table: [call](strata:table/call), or [call](strata:table/db/call) naming its database node
        - a deep-dive level: [inside orders-svc](strata:level/orders)
        - a flow: [place order](strata:flow/place-order); a scenario the user can run: [db outage](strata:scenario/db-outage)
        Use ids exactly as the digest writes them, and link each thing once or twice, not every mention. \
        Never invent an id: anything that isn't in the map is plain text.
        """

    /// The message on stdin: the digest, where the user is, an earlier exchange for follow-ups, and the question.
    public static func message(question: String, manifest: Manifest, digest: AskDigest, file: String?,
                               focus: AskFocus, repoOnDisk: Bool, previous: AskExchangeContext? = nil) -> String {
        var parts: [String] = []
        parts.append("<map-digest>\n" + digest.text + "</map-digest>")
        if !digest.cut.isEmpty {
            parts.append("The digest leaves out, to fit: \(digest.cut.joined(separator: "; ")). Grep the manifest file for anything it cut.")
        }
        var context: [String] = []
        if let file { context.append("Manifest file: \(file)") }
        if let repo = manifest.repo {
            context.append(repoOnDisk ? "Repo on this machine (the working directory): \(repo)"
                                      : "Repo \(repo) is not on this machine: answer from the map only.")
        } else {
            context.append("The map names no repo: answer from the map only.")
        }
        context.append("The user is looking at: " + where_(focus, in: manifest))
        parts.append(context.joined(separator: "\n"))
        if let previous {
            parts.append("Their previous question, for follow-ups: \(AskDigestWriter.clip(previous.question, 400))\n"
                         + "Your previous answer: \(AskDigestWriter.clip(previous.answer, 1500))")
        }
        parts.append("Question: \(question.trimmingCharacters(in: .whitespacesAndNewlines))")
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// "level orders (inside orders-svc), with node handler selected".
    static func where_(_ focus: AskFocus, in manifest: Manifest) -> String {
        var text = focus.path.isEmpty ? "the overview (root level)"
            : "level \(focus.path.joined(separator: "/")) (inside \(AskDigestWriter.ownerLabel(focus.path, in: manifest)))"
        let level = manifest.level(at: focus.path)
        if let id = focus.node {
            let label = level?.node(id).map { " \"\($0.label)\" [\($0.kind.rawValue)]" } ?? ""
            text += ", with node \(id)\(label) selected"
        } else if let id = focus.flow {
            text += ", with flow \(id) selected"
        } else {
            text += ", nothing selected"
        }
        return text
    }
}
