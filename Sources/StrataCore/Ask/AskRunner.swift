import Foundation

/// How a run ended.
public struct AskOutcome: Sendable, Equatable {
    public var answer: String
    public var failure: AskFailure?
    public var cancelled = false
    public var model: String?
    public var costUSD: Double?
    public var seconds: Double

    public init(answer: String, failure: AskFailure? = nil, cancelled: Bool = false, model: String? = nil,
                costUSD: Double? = nil, seconds: Double = 0) {
        self.answer = answer; self.failure = failure; self.cancelled = cancelled; self.model = model
        self.costUSD = costUSD; self.seconds = seconds
    }
}

/// One `claude -p` process: writes the prompt to stdin, parses stdout line by line as it streams, and
/// reports events and the outcome on a background queue. `cancel()` kills it. A run with no output
/// for `idleTimeout` seconds, or longer than `totalTimeout`, is stopped and reported as timed out.
public final class AskRunner: @unchecked Sendable {
    public let invocation: ClaudeInvocation
    public var idleTimeout: TimeInterval = 90
    public var totalTimeout: TimeInterval = 300

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "strata.ask.runner")
    private let process = Process()
    private var stream: AskStream
    private var buffer = Data()
    private var stderrText = ""
    private var lastOutput = Date()
    private let started = Date()
    private var timer: DispatchSourceTimer?
    private var stopReason: AskFailure?
    private var cancelled = false
    private var finished = false
    private var openPipes = 2
    private var exited = false
    private var onEvent: (@Sendable (AskEvent) -> Void)?
    private var onFinish: (@Sendable (AskOutcome) -> Void)?

    public init(_ invocation: ClaudeInvocation, repo: String? = nil) {
        self.invocation = invocation
        stream = AskStream(repo: repo)
    }

    /// Starts the process. Events and the outcome arrive on a background queue; hop to the main actor
    /// to show them.
    public func start(onEvent: @escaping @Sendable (AskEvent) -> Void, onFinish: @escaping @Sendable (AskOutcome) -> Void) throws {
        self.onEvent = onEvent
        self.onFinish = onFinish
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: invocation.directory, isDirectory: true)
        process.environment = invocation.environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; self.closed() } else { self.received(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; self.closed() } else { self.receivedError(data) }
        }
        process.terminationHandler = { [weak self] _ in self?.terminated() }

        try process.run()
        let prompt = Data(invocation.input.utf8)
        queue.async {
            // A closed pipe (the CLI exited early) raises SIGPIPE on write; ignore it for this write.
            signal(SIGPIPE, SIG_IGN)
            try? input.fileHandleForWriting.write(contentsOf: prompt)
            try? input.fileHandleForWriting.close()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Stops the run; the outcome reports `cancelled` with whatever answer had streamed.
    public func cancel() {
        lock.lock()
        let running = !finished && !cancelled
        if running { cancelled = true }
        lock.unlock()
        if running { stop() }
    }

    private func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.process.isRunning == true { kill(pid, SIGKILL) }
        }
    }

    private func tick() {
        lock.lock()
        let now = Date()
        var reason: AskFailure?
        if !finished, !cancelled, stopReason == nil {
            if now.timeIntervalSince(lastOutput) > idleTimeout { reason = .timedOut(seconds: Int(idleTimeout)) }
            else if now.timeIntervalSince(started) > totalTimeout { reason = .timedOut(seconds: Int(totalTimeout)) }
        }
        if let reason { stopReason = reason }
        lock.unlock()
        if reason != nil { stop() }
    }

    private func received(_ data: Data) {
        var events: [AskEvent] = []
        lock.lock()
        lastOutput = Date()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            events += stream.feed(line)
        }
        let handler = onEvent
        lock.unlock()
        for event in events { handler?(event) }
    }

    private func receivedError(_ data: Data) {
        lock.lock()
        if stderrText.utf8.count < 64_000 { stderrText += String(decoding: data, as: UTF8.self) }
        lock.unlock()
    }

    private func closed() {
        lock.lock()
        openPipes -= 1
        let ready = openPipes <= 0 && exited
        lock.unlock()
        if ready { finish() }
    }

    private func terminated() {
        lock.lock()
        exited = true
        let ready = openPipes <= 0
        lock.unlock()
        if ready { finish() }
        else {
            // A grandchild (a hook, ripgrep) may still hold the pipes open; don't wait on it for long.
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.finish() }
        }
    }

    private func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        timer?.cancel()
        var events: [AskEvent] = []
        if !buffer.isEmpty {
            events = stream.feed(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        let status = process.isRunning ? -1 : process.terminationStatus
        var failure = stopReason
        if failure == nil, !cancelled {
            let noise = stream.noise.joined(separator: "\n")
            failure = AskFailure.classify(result: stream.result, exitStatus: status,
                                          stderr: [stderrText, noise].filter { !$0.isEmpty }.joined(separator: "\n"),
                                          rateLimit: stream.rateLimit)
        }
        let outcome = AskOutcome(answer: stream.finalAnswer, failure: failure, cancelled: cancelled, model: stream.model,
                                 costUSD: stream.result?.costUSD, seconds: Date().timeIntervalSince(started))
        let eventHandler = onEvent, finishHandler = onFinish
        onEvent = nil
        onFinish = nil
        lock.unlock()
        for event in events { eventHandler?(event) }
        finishHandler?(outcome)
    }
}

/// Starting a run end to end: find Claude, build the digest and prompt, and start the process.
public enum AskSession {
    /// Builds the prompt and the invocation for a question. Pure apart from checking the repo exists.
    public static func invocation(question: String, manifest: Manifest, file: String?, focus: AskFocus,
                                  claude: ClaudeLocator.Found, model: String?, previous: AskExchangeContext? = nil,
                                  budget: Int = AskDigest.defaultBudget) -> (ClaudeInvocation, AskDigest) {
        let digest = AskDigest.build(manifest, file: file, focus: focus, budget: budget)
        let prompt = AskPrompt.message(question: question, manifest: manifest, digest: digest, file: file, focus: focus,
                                       repoOnDisk: AskInvocation.repoOnDisk(manifest) != nil, previous: previous)
        return (AskInvocation.make(claude: claude, prompt: prompt, manifest: manifest, model: model), digest)
    }

    /// The manifest's file on disk, when it has one Claude can Read.
    public static func file(of manifest: Manifest) -> String? {
        switch manifest.source {
        case .bundled(let url), .file(let url): url.path
        case .inline: nil
        }
    }
}
