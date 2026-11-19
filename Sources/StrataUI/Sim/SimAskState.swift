import Foundation
import Observation
import StrataCore

/// Ask the map, one per map (manifest id) and app model: the question being typed, the exchange on
/// screen while it streams, the history on disk, and the switch and privacy notice. It outlives the
/// level on screen, so an answer keeps streaming while a link dives into a deep dive.
@MainActor
@Observable
final class SimAskState {
    enum Phase: Equatable {
        case starting, streaming, done, stopped
        case failed(AskFailure)
    }

    struct Exchange: Identifiable, Equatable {
        let id: String
        var question: String
        var answer = ""
        /// What Claude is doing between bursts of text ("Reading internal/pacing.go").
        var activity: String?
        var phase: Phase = .starting
        let started: Date
        var seconds: Double?
        var model: String?
        let path: [String]
        let node: String?

        var running: Bool { phase == .starting || phase == .streaming }
    }

    let manifestID: String
    var question = ""
    /// Bumped to put the cursor in the question field.
    var focusRequest = 0
    /// The last focus request the field took, so reopening the tab doesn't take focus again.
    @ObservationIgnored var focusHandled = 0
    /// Bumped by ⌘K's "Ask the map…" to open the tab.
    var openRequest = 0
    /// The Ask tab was the open dock tab, so a level of this map opened next shows it too.
    var tabOpen = false
    private(set) var current: Exchange?
    /// Earlier exchanges from ~/.strata/ask/<id>.jsonl, oldest first.
    private(set) var history: [AskRecord] = []
    private(set) var settings: AskSettings
    var expanded: Set<String> = []

    @ObservationIgnored private var runner: AskRunner?
    @ObservationIgnored private var pending = ""
    @ObservationIgnored private var flushScheduled = false
    /// Snapshots render from memory: nothing is read from or written to ~/.strata/ask.
    @ObservationIgnored var stillLife = false
    @ObservationIgnored private let store: AskHistory
    @ObservationIgnored private var historyLoaded = false
    /// Bumped by Clear history, so a load still in flight doesn't bring the old records back.
    @ObservationIgnored private var historyGeneration = 0

    private init(manifestID: String) {
        self.manifestID = manifestID
        store = AskHistory(manifestID: manifestID)
        settings = AskSettings.load()
    }

    /// Reads the map's history off the main thread the first time the tab shows.
    func loadHistory() {
        guard !historyLoaded, !stillLife else { return }
        historyLoaded = true
        let store = store, generation = historyGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let records = store.load()
            Task { @MainActor [weak self] in
                guard let self, !records.isEmpty, self.historyGeneration == generation else { return }
                let ids = Set(self.history.map(\.id))
                self.history = records.filter { !ids.contains($0.id) } + self.history
            }
        }
    }

    private final class Store { var states: [String: SimAskState] = [:] }
    private static let stores = NSMapTable<AppModel, Store>.weakToStrongObjects()

    static func of(_ model: AppModel, manifest id: String) -> SimAskState {
        let store = stores.object(forKey: model) ?? Store()
        stores.setObject(store, forKey: model)
        if let state = store.states[id] { return state }
        let state = SimAskState(manifestID: id)
        store.states[id] = state
        return state
    }

    /// The Claude binary, found once per launch (finding it may run a login shell).
    private static var located: ClaudeLocator.Found?

    // MARK: Switches

    /// `ask: { enabled: false }` in config.yaml hides Ask altogether.
    static func offInConfig(_ model: AppModel) -> Bool { !model.config.ask.enabled }

    var enabled: Bool { settings.enabled }
    var needsNotice: Bool { !settings.acknowledged.contains(manifestID) }

    func acknowledge() {
        guard needsNotice else { return }
        settings.acknowledged.append(manifestID)
        save()
    }

    func setEnabled(_ on: Bool) {
        settings.enabled = on
        if !on { stop() }
        save()
    }

    private func save() {
        guard !stillLife else { return }
        let settings = settings
        DispatchQueue.global(qos: .utility).async { try? settings.save() }
    }

    // MARK: Asking

    var running: Bool { current?.running == true }

    /// Earlier exchanges, newest first, without the one on screen.
    var earlier: [AskRecord] { history.reversed().filter { $0.id != current?.id } }

    func ask(_ text: String, manifest: Manifest, focus: AskFocus, config: AskConfig) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !running else { return }
        guard enabled, config.enabled else {
            current = Exchange(id: UUID().uuidString, question: question, phase: .failed(.disabled), started: Date(),
                               path: focus.path, node: focus.node)
            return
        }
        acknowledge()
        self.question = ""
        let exchange = Exchange(id: UUID().uuidString, question: question, started: Date(), path: focus.path, node: focus.node)
        current = exchange
        let previous = followUpContext()
        let configured = config.claude, model = config.model
        let known = Self.located
        Task.detached(priority: .userInitiated) { [weak self] in
            let claude = known ?? ClaudeLocator.standard(configured: configured).locate()
            guard let claude else {
                await self?.finish(exchange.id, AskOutcome(answer: "", failure: .notInstalled))
                return
            }
            let (invocation, _) = AskSession.invocation(question: question, manifest: manifest, file: AskSession.file(of: manifest),
                                                        focus: focus, claude: claude, model: model, previous: previous)
            await self?.launch(exchange.id, invocation: invocation, claude: claude, repo: AskInvocation.repoOnDisk(manifest))
        }
    }

    private func launch(_ id: String, invocation: ClaudeInvocation, claude: ClaudeLocator.Found, repo: String?) {
        guard current?.id == id, current?.running == true else { return }
        Self.located = claude
        let runner = AskRunner(invocation, repo: repo)
        self.runner = runner
        do {
            // The main queue keeps the runner's order, so deltas never land out of sequence.
            try runner.start(onEvent: { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(id, event) } }
            }, onFinish: { [weak self] outcome in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(id, outcome) } }
            })
        } catch {
            Self.located = nil
            finish(id, AskOutcome(answer: "", failure: .notInstalled))
        }
    }

    func stop() {
        if let runner { runner.cancel() }
        else if var exchange = current, exchange.running {
            // Still finding Claude or building the digest: drop it.
            exchange.phase = .stopped
            current = exchange
        }
    }

    /// The last answer, if it is recent, so "and if it's 5 minutes?" makes sense.
    private func followUpContext() -> AskExchangeContext? {
        let last = history.last { $0.status == .done }
        guard let last, Date().timeIntervalSince(last.date) < 30 * 60 else { return nil }
        return AskExchangeContext(question: last.question, answer: last.answer)
    }

    func receive(_ id: String, _ event: AskEvent) {
        guard var exchange = current, exchange.id == id, exchange.running else { return }
        switch event {
        case .started(let model):
            exchange.model = model
            current = exchange
        case .tool(let description):
            flush()
            exchange = current ?? exchange
            exchange.activity = description
            current = exchange
        case .newTurn:
            pending = ""
            exchange.answer = ""
            current = exchange
        case .text(let text):
            // Deltas arrive dozens of times a second; the panel redraws at most every 50 ms.
            pending += text
            guard !flushScheduled else { return }
            flushScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                self?.flush()
            }
        }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty, var exchange = current, exchange.running else { pending = ""; return }
        exchange.answer += pending
        exchange.activity = nil
        exchange.phase = .streaming
        pending = ""
        current = exchange
    }

    func finish(_ id: String, _ outcome: AskOutcome) {
        guard var exchange = current, exchange.id == id else { return }
        flush()
        exchange = current ?? exchange
        runner = nil
        if !outcome.answer.isEmpty { exchange.answer = outcome.answer }
        exchange.activity = nil
        exchange.seconds = outcome.seconds
        exchange.model = outcome.model ?? exchange.model
        if outcome.cancelled || exchange.phase == .stopped { exchange.phase = .stopped }
        else if let failure = outcome.failure { exchange.phase = .failed(failure) }
        else { exchange.phase = .done }
        if case .failed(.notInstalled) = exchange.phase { Self.located = nil }
        current = exchange
        record(exchange)
    }

    private func record(_ exchange: Exchange) {
        let status: AskRecord.Status
        var error: String?
        switch exchange.phase {
        case .done: status = .done
        case .stopped: status = .stopped
        case .failed(let failure):
            status = .failed
            error = failure.title
        case .starting, .streaming: return
        }
        let record = AskRecord(id: exchange.id, date: exchange.started, question: exchange.question, answer: exchange.answer,
                               path: exchange.path, node: exchange.node, status: status, error: error, model: exchange.model)
        history.append(record)
        guard !stillLife else { return }
        let store = store
        DispatchQueue.global(qos: .utility).async { try? store.append(record) }
    }

    func clearHistory() {
        historyGeneration += 1
        history = []
        expanded = []
        if let exchange = current, !exchange.running { current = nil }
        guard !stillLife else { return }
        let store = store
        DispatchQueue.global(qos: .utility).async { try? store.clear() }
    }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: Snapshots

    fileprivate func reset(acknowledged: Bool) {
        stillLife = true
        historyLoaded = true
        runner?.cancel()
        runner = nil
        current = nil
        history = []
        question = ""
        settings = AskSettings(enabled: true, acknowledged: acknowledged ? [manifestID] : [])
    }

    /// Replays canned stream-json lines through the same parser a live run uses.
    fileprivate func replay(_ lines: [String], question: String, focus: AskFocus, finished: Bool, seconds: Double) {
        var stream = AskStream()
        var exchange = Exchange(id: "snapshot", question: question, started: Date(), path: focus.path, node: focus.node)
        for line in lines {
            for event in stream.feed(line) {
                switch event {
                case .started(let model): exchange.model = model
                case .tool(let description): exchange.activity = description
                case .newTurn: exchange.answer = ""
                case .text(let text):
                    exchange.answer += text
                    exchange.activity = nil
                    exchange.phase = .streaming
                }
            }
        }
        if finished {
            exchange.answer = stream.finalAnswer
            exchange.phase = .done
            exchange.seconds = seconds
        }
        current = exchange
    }

    fileprivate func show(_ exchange: Exchange) { current = exchange }
    fileprivate func setHistory(_ records: [AskRecord]) { history = records }
}

/// Offscreen snapshots: put the Ask tab in a known state from canned streams, without Claude or disk.
@_spi(Snapshots) @MainActor
public enum SimAskSnapshot {
    /// A clean slate: no history, the switch on, the privacy notice seen or not.
    public static func reset(_ model: AppModel, manifest: String, noticeSeen: Bool = true) {
        SimAskState.of(model, manifest: manifest).reset(acknowledged: noticeSeen)
    }

    /// The in-app switch off, as "Turn Ask off" leaves it.
    public static func turnOff(_ model: AppModel, manifest: String) {
        SimAskState.of(model, manifest: manifest).setEnabled(false)
    }

    public static func type(_ model: AppModel, manifest: String, _ text: String) {
        SimAskState.of(model, manifest: manifest).question = text
    }

    /// Shows the exchange `lines` produce: mid-answer, or finished.
    public static func replay(_ model: AppModel, manifest: String, question: String, lines: [String], path: [String] = [],
                              node: String? = nil, finished: Bool, seconds: Double = 6.4) {
        SimAskState.of(model, manifest: manifest).replay(lines, question: question, focus: AskFocus(path: path, node: node),
                                                         finished: finished, seconds: seconds)
    }

    public static func fail(_ model: AppModel, manifest: String, question: String, failure: AskFailure) {
        var exchange = SimAskState.Exchange(id: "snapshot", question: question, started: Date(), path: [], node: nil)
        exchange.phase = .failed(failure)
        exchange.seconds = 0.8
        SimAskState.of(model, manifest: manifest).show(exchange)
    }

    public static func history(_ model: AppModel, manifest: String, _ records: [AskRecord]) {
        SimAskState.of(model, manifest: manifest).setHistory(records)
    }

    /// Asks for real through the app's path (find Claude, digest, runner, main-queue delivery), with
    /// `config.claude` pointing at a stand-in, and waits up to `timeout` for the answer.
    public static func ask(_ model: AppModel, manifest: Manifest, question: String, timeout: TimeInterval = 10) -> String? {
        let state = SimAskState.of(model, manifest: manifest.id)
        state.ask(question, manifest: manifest, focus: AskFocus(), config: model.config.ask)
        let deadline = Date().addingTimeInterval(timeout)
        while state.running, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let exchange = state.current else { return nil }
        switch exchange.phase {
        case .done: return "done, \(exchange.answer.count) characters"
        case .failed(let failure): return "failed: \(failure.title)"
        default: return "\(exchange.phase)"
        }
    }

    /// The answer as the panel renders it: broken links flattened, the rest canonical.
    public static func renderedAnswer(_ model: AppModel, manifest: Manifest) -> String? {
        SimAskState.of(model, manifest: manifest.id).current.map { AskLinks.rewrite($0.answer, in: manifest) }
    }
}

@_spi(Snapshots) extension SimAskSnapshot {
    /// What clicking `link` in an answer does, from the level of `sim`: returns the level to render and
    /// the node selected there (nil when the link didn't resolve).
    public static func follow(_ model: AppModel, from sim: Simulation, link: String) -> (path: [String], node: String?)? {
        guard let target = sim.manifest.askTarget(link) else { return nil }
        var selected: String?
        SimAskNav.open(target, sim: sim, model: model) { selection in
            if case .node(let id)? = selection { selected = id }
        }
        let path = target.path ?? sim.path
        return (path, selected)
    }
}
