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
                                visible: visible, snapshotSession: snapshotSession)
                    .id(AppModel.sessionKey(input.id, embed.view))
            } else {
                Label("Simulator or level unavailable", systemImage: "exclamationmark.triangle")
                    .font(Theme.ui()).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: embed.height)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .onAppear { visible = true }
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

    init(model: AppModel, embed: Embed, id: String, manifest: Manifest,
         visible: Bool, snapshotSession: Simulation?) {
        self.model = model
        self.embed = embed
        self.id = id
        self.manifest = manifest
        self.visible = visible
        still = snapshotSession != nil
        _session = StateObject(wrappedValue: EmbedSessionState(snapshotSession ?? Self.make(model: model, id: id, manifest: manifest, embed: embed)))
    }

    var body: some View {
        SimEmbedWorkspace(model: model, id: id, sim: sim, scenario: embed.scenario, visible: visible, still: still)
            .id(ObjectIdentifier(sim))
            .onChange(of: Definition(manifest: manifest, scenario: embed.scenario)) { _, _ in
                session.sim = Self.make(model: model, id: id, manifest: manifest, embed: embed)
            }
            .onChange(of: embed.autoplay) { _, autoplay in sim.playing = autoplay }
    }

    private static func make(model: AppModel, id: String, manifest: Manifest, embed: Embed) -> Simulation {
        let sim = SimSessions.make(model, id: id, path: embed.view, manifest: manifest)
        if let scenario = embed.scenario, sim.level.scenarios.contains(where: { $0.id == scenario }) {
            sim.start(scenario: scenario)
        }
        sim.playing = embed.autoplay
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
    let visible: Bool
    let still: Bool
    @State private var renderer: StageRenderer
    @State private var viewport = StageViewport()
    @State private var selection: StageSelection?
    private let terms: TermIndex

    init(model: AppModel, id: String, sim: Simulation, scenario: String?, visible: Bool, still: Bool) {
        self.model = model
        self.id = id
        self.sim = sim
        self.scenario = scenario
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
                        else { sim.start(scenario: scenario); sim.playing = true }
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
                     selection: selection, compact: true, visible: visible, still: still, onSelect: { selection = $0 })
        }
    }

    private var title: String {
        guard let node = sim.path.last,
              let level = sim.manifest.level(at: Array(sim.path.dropLast())) else { return sim.manifest.title }
        return sim.manifest.title + " › " + (level.node(node)?.label ?? node)
    }

    private func expand() {
        if case .inline = sim.manifest.source {
            if !sim.path.isEmpty, SimSessions.cachedManifest(model, id: id).map({ !SimSessions.same($0, sim.manifest) }) ?? true {
                SimSessions.remember(SimSessions.make(model, id: id, path: [], manifest: sim.manifest), model: model, id: id)
            }
            SimSessions.remember(sim, model: model, id: id)
        } else if model.sessions[AppModel.sessionKey(id, sim.path)] == nil {
            SimSessions.remember(sim, model: model, id: id)
        }
        model.open(.sim(id, path: sim.path))
    }
}
