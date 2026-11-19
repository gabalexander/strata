import Foundation
import StrataCore

// `strata ask <file|id> "question"`: Ask the map from a terminal or an agent, with the same digest,
// prompt and read-only Claude Code invocation as the app's Ask tab. The answer streams to stdout as
// markdown with `strata:` links; what Claude reads goes to stderr. `--digest` prints the message that
// would be sent, and sends nothing.

@MainActor
func ask(_ args: Arguments) throws -> Int32 {
    let usage = "strata ask <file|id> \"question\" [--path a/b] [--node id] [--model m] [--budget bytes] [--digest]"
    guard let target = args.positional.first else { throw CLIError("usage: \(usage)") }
    let entry = try loadEntry(target, command: "ask")
    guard let manifest = entry.manifest else { return 1 }
    let question = args.positional.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    let path = (args.options["--path"] ?? "").split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
    guard manifest.level(at: path) != nil else { throw CLIError("no level at \(path.joined(separator: "/")) in \(manifest.id)") }
    if let node = args.options["--node"], manifest.level(at: path)?.node(node) == nil {
        throw CLIError("no node '\(node)' on level \(path.isEmpty ? "root" : path.joined(separator: "/"))")
    }
    var budget = AskDigest.defaultBudget
    if let text = args.options["--budget"] {
        guard let value = Int(text), value >= 2000 else { throw CLIError("--budget takes a byte count of at least 2000") }
        budget = value
    }
    let focus = AskFocus(path: path, node: args.options["--node"])
    let file = AskSession.file(of: manifest) ?? entry.url.path

    if args.flags.contains("--digest") {
        let digest = AskDigest.build(manifest, file: file, focus: focus, budget: budget)
        let message = AskPrompt.message(question: question.isEmpty ? "(your question)" : question, manifest: manifest,
                                        digest: digest, file: file, focus: focus,
                                        repoOnDisk: AskInvocation.repoOnDisk(manifest) != nil)
        FileHandle.standardOutput.write(Data(message.utf8))
        stderr("digest: \(digest.bytes) bytes (~\(digest.estimatedTokens) tokens), tier \(digest.tier)"
               + (digest.cut.isEmpty ? ", nothing cut" : "; cut: \(digest.cut.joined(separator: "; "))"))
        stderr("message: \(message.utf8.count) bytes; system prompt: \(AskPrompt.system.utf8.count) bytes")
        return 0
    }
    guard !question.isEmpty else { throw CLIError("usage: \(usage)") }

    let config = ConfigLoader.load().0
    guard config.ask.enabled, AskSettings.load().enabled else {
        stderr("\(AskFailure.disabled.title): \(AskFailure.disabled.message)")
        return 1
    }
    guard let claude = ClaudeLocator.standard(configured: config.ask.claude).locate() else {
        stderr("\(AskFailure.notInstalled.title): \(AskFailure.notInstalled.message)")
        return 1
    }
    let model = args.options["--model"] ?? config.ask.model
    let (invocation, digest) = AskSession.invocation(question: question, manifest: manifest, file: file, focus: focus,
                                                     claude: claude, model: model, budget: budget)
    stderr("Asking Claude Code about \(manifest.id): the map digest (\(digest.bytes / 1000) KB) and your question go to Claude "
           + "under your Claude Code account.")

    let runner = AskRunner(invocation, repo: AskInvocation.repoOnDisk(manifest))
    let done = DispatchSemaphore(value: 0)
    let box = OutcomeBox()
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { runner.cancel() }
    interrupt.resume()
    defer { interrupt.cancel(); signal(SIGINT, SIG_DFL) }

    try runner.start(onEvent: { event in
        switch event {
        case .started(let model): if let model { stderr("model: \(model)") }
        case .text(let text): box.write(text)
        case .newTurn: box.write("\n\n")
        case .tool(let description): stderr("· \(description)")
        }
    }, onFinish: { outcome in
        box.outcome = outcome
        done.signal()
    })
    done.wait()
    guard let outcome = box.outcome else { return 1 }
    if box.written == 0, !outcome.answer.isEmpty { box.write(outcome.answer) }
    if box.written > 0, !box.endsWithNewline { box.write("\n") }
    if outcome.cancelled { stderr("Stopped."); return 130 }
    if let failure = outcome.failure {
        stderr("\(failure.title): \(failure.message)")
        return 1
    }
    return 0
}

/// The run's outcome and what was printed, shared with the runner's background queue.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _outcome: AskOutcome?
    private(set) var written = 0
    private(set) var endsWithNewline = true

    var outcome: AskOutcome? {
        get { lock.lock(); defer { lock.unlock() }; return _outcome }
        set { lock.lock(); _outcome = newValue; lock.unlock() }
    }

    func write(_ text: String) {
        guard !text.isEmpty else { return }
        lock.lock()
        written += text.utf8.count
        endsWithNewline = text.hasSuffix("\n")
        lock.unlock()
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
