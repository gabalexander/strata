import SwiftUI
import StrataCore

@MainActor
public struct SimEmbedView: View {
    let model: AppModel
    let embed: Embed
    let note: String
    private var snapshotSession: Simulation?
    @State private var visible = true
    @State private var fallbackID = UUID()

    public init(model: AppModel, embed: Embed, note: String) {
        self.model = model
        self.embed = embed
        self.note = note
    }

    @_spi(Snapshots) public init(model: AppModel, embed: Embed, note: String, snapshotSession: Simulation) {
        self.init(model: model, embed: embed, note: note)
        self.snapshotSession = snapshotSession
    }

    public var body: some View {
        let _ = model.library.revision
        let input = input
        Group {
            if let manifest = input.manifest, manifest.level(at: embed.view) != nil {
                SimEmbedSession(model: model, embed: embed, id: input.id, manifest: manifest,
                                handoff: handoffKey(input.id), visible: visible, snapshotSession: snapshotSession)
                    .id(AppModel.sessionKey(input.id, embed.view))
            } else {
                unavailable(input.manifest)
            }
        }
        .frame(height: embed.height)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .onAppear { visible = true }
    }

    /// Identifies this embed in its note, so a session handed to the full screen comes back here.
    private func handoffKey(_ id: String) -> String {
        [note, AppModel.sessionKey(id, embed.view), embed.scenario ?? ""].joined(separator: "\n")
    }

    private func unavailable(_ manifest: Manifest?) -> some View {
        let reason: (title: String, detail: String?)
        if let manifest {
            reason = ("No level “\(embed.view.joined(separator: " › "))” in \(manifest.title)",
                      "Check the embed’s view: path against the manifest’s nodes.")
        } else if case .library(let id) = embed.target, let entry = model.library.entry(id) {
            let error = entry.firstError
            var location = entry.url.lastPathComponent
            if let line = error?.line { location += " · line \(line)" }
            reason = ("\(entry.title) has an error", error.map { "\(location): \($0.message)" })
        } else if case .library(let id) = embed.target {
            reason = ("No simulator “\(id)” in the library", "Check the id, or run strata list to see what is installed.")
        } else {
            reason = ("Simulator unavailable", nil)
        }
        return VStack(spacing: 6) {
            Label(reason.title, systemImage: "exclamationmark.triangle")
                .font(Theme.ui(13, .semibold)).foregroundStyle(Theme.warn)
            if let detail = reason.detail {
                Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center).lineLimit(3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var input: (id: String, manifest: Manifest?) {
        switch embed.target {
        case .library(let id): return (id, model.library.manifest(id))
        case .inline(var manifest):
            let key: String
            if case .inline(let path, let index) = manifest.source {
                key = "\(path)#\(index)"
            } else {
                key = "\(note)#\(fallbackID.uuidString)"
                manifest.source = .inline(note: note, index: 0)
            }
            return ("inline:" + Data(key.utf8).base64EncodedString(), manifest)
        }
    }
}

@MainActor
private struct SimEmbedSession: View {
    let model: AppModel
    let embed: Embed
    let id: String
    let manifest: Manifest
    let handoff: String
    let visible: Bool
    let still: Bool

    private struct Definition: Equatable {
        let manifest: Manifest
        let scenario: String?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.scenario == rhs.scenario && SimSessions.same(lhs.manifest, rhs.manifest)
        }
    }

    @StateObject private var session: EmbedSessionState
    private var sim: Simulation { session.sim }

    init(model: AppModel, embed: Embed, id: String, manifest: Manifest, handoff: String,
         visible: Bool, snapshotSession: Simulation?) {
        self.model = model
        self.embed = embed
        self.id = id
        self.manifest = manifest
        self.handoff = handoff
        self.visible = visible
        still = snapshotSession != nil
        let shared = SimSessions.handedOff(handoff, model: model, id: id, path: embed.view, manifest: manifest)
        _session = StateObject(wrappedValue: EmbedSessionState(snapshotSession ?? shared ?? Self.make(manifest: manifest, embed: embed)))
    }

    var body: some View {
        SimEmbedWorkspace(model: model, id: id, sim: sim, scenario: embed.scenario, handoff: handoff,
                          visible: visible, still: still)
            .id(ObjectIdentifier(sim))
            .onChange(of: Definition(manifest: manifest, scenario: embed.scenario)) { _, _ in
                session.sim = Self.make(manifest: manifest, embed: embed)
            }
            .onChange(of: embed.autoplay) { _, autoplay in sim.playing = autoplay }
    }

    private static func make(manifest: Manifest, embed: Embed) -> Simulation {
        let sim = Simulation(manifest: manifest, path: embed.view)
        if let scenario = embed.scenario, sim.level.scenarios.contains(where: { $0.id == scenario }) {
            sim.start(scenario: scenario)
        }
        if !embed.autoplay { sim.playing = false }
        return sim
    }
}

@MainActor
private final class EmbedSessionState: ObservableObject {
    @Published var sim: Simulation

    init(_ sim: Simulation) { self.sim = sim }
}

@MainActor
private struct SimEmbedWorkspace: View {
    let model: AppModel
    let id: String
    let sim: Simulation
    let scenario: String?
    let handoff: String
    let visible: Bool
    let still: Bool
    @State private var renderer: StageRenderer
    @State private var viewport = StageViewport()
    @State private var selection: StageSelection?
    private let terms: TermIndex

    init(model: AppModel, id: String, sim: Simulation, scenario: String?, handoff: String, visible: Bool, still: Bool) {
        self.model = model
        self.id = id
        self.sim = sim
        self.scenario = scenario
        self.handoff = handoff
        self.visible = visible
        self.still = still
        _renderer = State(initialValue: StageRenderer(level: sim.level))
        terms = TermIndex(manifest: sim.manifest)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "waveform.path").foregroundStyle(Theme.accent)
                Text(title).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 4)
                if let scenario, sim.level.scenarios.contains(where: { $0.id == scenario }) {
                    SimButton(title: sim.scenario == scenario ? "Stop scenario" : "Run scenario", icon: "flag",
                              iconOnly: true, active: sim.scenario == scenario) {
                        if sim.scenario == scenario { sim.stopScenario() }
                        else { sim.start(scenario: scenario) }
                    }
                }
                SimButton(title: sim.playing ? "Pause" : "Play", icon: sim.playing ? "pause.fill" : "play.fill",
                          iconOnly: true, active: sim.playing) { sim.playing.toggle() }
                SimButton(title: "Reset", icon: "arrow.counterclockwise", iconOnly: true) { sim.reset() }
                SimButton(title: "Expand simulator", icon: "arrow.up.left.and.arrow.down.right", iconOnly: true) { expand() }
            }
            .font(Theme.ui(12))
            .padding(.horizontal, 10)
            .frame(height: 37)
            Rectangle().fill(Theme.border).frame(height: 1)
            SimStage(sim: sim, model: model, terms: terms, renderer: renderer, viewport: viewport,
                     selection: selection, compact: true, visible: visible, still: still, onSelect: { selection = $0 },
                     menu: SimActions(model: model, sim: sim, fit: viewport.fit, dive: dive).menu)
        }
    }

    private var title: String {
        guard let node = sim.path.last,
              let level = sim.manifest.level(at: Array(sim.path.dropLast())) else { return sim.manifest.title }
        return sim.manifest.title + " › " + (level.node(node)?.label ?? node)
    }

    /// A deep dive from the embed continues full screen, with this level kept for the way back out.
    private func dive(_ node: Node) {
        guard let destination = SimSessions.drillDestination(node, id: id, path: sim.path) else { return }
        share()
        model.open(destination, parentRate: sim.nodeState(node.id)?.arrivals)
    }

    /// The full screen continues this embed's simulation, and the embed picks it up again on return.
    private func expand() {
        share()
        model.open(.sim(id, path: sim.path))
    }

    private func share() {
        if case .inline = sim.manifest.source, !sim.path.isEmpty,
           SimSessions.cachedManifest(model, id: id).map({ !SimSessions.same($0, sim.manifest) }) ?? true {
            // Inline manifests live only in sessions: keep the root so breadcrumbs can lead out.
            SimSessions.remember(Simulation(manifest: sim.manifest), model: model, id: id)
        }
        SimSessions.remember(sim, model: model, id: id)
        SimSessions.handOff(handoff, model: model)
    }
}
