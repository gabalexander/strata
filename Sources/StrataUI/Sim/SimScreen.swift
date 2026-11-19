import AppKit
import SwiftUI
import StrataCore

@_spi(Snapshots) public struct SimSnapshotOptions {
    var selectedNode: String?
    var dockTab: SimDockTab
    var previewMenu: Bool

    public init(selectedNode: String? = nil, dockTab: SimDockTab = .controls,
                previewMenu: Bool = false) {
        self.selectedNode = selectedNode
        self.dockTab = dockTab
        self.previewMenu = previewMenu
    }
}

@MainActor
public struct SimScreen: View {
    let model: AppModel
    let id: String
    let path: [String]
    private var snapshot: SimSnapshotOptions?
    @State private var arrival: SimArrival?

    public init(model: AppModel, id: String, path: [String]) {
        self.model = model
        self.id = id
        self.path = path
    }

    @_spi(Snapshots) public init(model: AppModel, id: String, path: [String], snapshot: SimSnapshotOptions) {
        self.init(model: model, id: id, path: path)
        self.snapshot = snapshot
    }

    public var body: some View {
        let revision = model.library.revision
        let parentRate = model.route == .sim(id, path: path) ? model.routeParentRate : nil
        Group {
            if let manifest = SimSessions.cachedManifest(model, id: id) {
                if manifest.level(at: path) != nil {
                    SimScreenSession(model: model, id: id, path: path, manifest: manifest, revision: revision,
                                     parentRate: parentRate, snapshot: snapshot, arrival: $arrival)
                        .id(parentRate)
                } else {
                    SimLoadIssue(model: model, id: id, invalidPath: path)
                }
            } else {
                SimLoadIssue(model: model, id: id, invalidPath: nil)
            }
        }
        .id(AppModel.sessionKey(id, path))
        .onChange(of: revision, initial: true) { _, _ in
            if SimSessions.cachedManifest(model, id: id) == nil { SimSessions.forget(id, from: model) }
        }
    }
}

private struct SimArrival {
    let destination: Route
    let forward: Bool
    let node: String?
}

@MainActor
private struct SimScreenSession: View {
    let model: AppModel
    let id: String
    let path: [String]
    let manifest: Manifest
    let revision: Int
    let parentRate: Double?
    let snapshot: SimSnapshotOptions?
    @SwiftUI.Binding var arrival: SimArrival?
    @State private var sim: Simulation

    init(model: AppModel, id: String, path: [String], manifest: Manifest, revision: Int, parentRate: Double?,
         snapshot: SimSnapshotOptions?, arrival: SwiftUI.Binding<SimArrival?>) {
        self.model = model
        self.id = id
        self.path = path
        self.manifest = manifest
        self.revision = revision
        self.parentRate = parentRate
        self.snapshot = snapshot
        _arrival = arrival
        _sim = State(initialValue: SimSessions.cached(model, id: id, path: path, manifest: manifest, parentRate: parentRate))
    }

    var body: some View {
        SimWorkspace(model: model, id: id, sim: sim, snapshot: snapshot, arrival: $arrival)
            .id(ObjectIdentifier(sim))
            .onAppear { SimSessions.remember(sim, model: model, id: id) }
            .onChange(of: revision) { _, _ in
                guard !SimSessions.same(sim.manifest, manifest) else { return }
                sim = Simulation(manifest: manifest, path: path, parentRate: parentRate)
                SimSessions.remember(sim, model: model, id: id)
            }
    }
}

@MainActor
private struct SimWorkspace: View {
    let model: AppModel
    let id: String
    let sim: Simulation
    let snapshot: SimSnapshotOptions?
    @SwiftUI.Binding var arrival: SimArrival?
    @State private var renderer: StageRenderer
    @State private var selection: StageSelection?
    @State private var tab: SimDockTab
    @State private var viewport = StageViewport()
    @State private var navigation: Task<Void, Never>?
    @State private var presentationScale: CGFloat = 1
    @State private var presentationOpacity: Double = 1
    @State private var presentationNode: String?
    @State private var noteIDs: Set<String> = []
    @State private var pulse = SimPulse()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let terms: TermIndex

    init(model: AppModel, id: String, sim: Simulation, snapshot: SimSnapshotOptions?, arrival: SwiftUI.Binding<SimArrival?>) {
        self.model = model
        self.id = id
        self.sim = sim
        self.snapshot = snapshot
        terms = SimSessions.terms(for: sim)
        _arrival = arrival
        _renderer = State(initialValue: SimSessions.renderer(for: sim))
        _selection = State(initialValue: snapshot?.selectedNode.map(StageSelection.node))
        _tab = State(initialValue: snapshot?.dockTab ?? .controls)
    }

    private var actions: SimActions {
        var actions = SimActions(model: model, sim: sim, fit: viewport.fit, dive: dive)
        actions.tidy = tidyAction
        return actions
    }

    /// "Tidy layout" is offered for `layout: manual` levels; an auto layout is already tidy.
    private var tidyAction: (() -> Void)? {
        guard sim.manifest.layout == .manual else { return nil }
        return { tidy() }
    }

    /// "Tidy layout": auto layout for this level, cards gliding to their new places, then fit the view.
    /// An auto-laid-out level is already tidy.
    private func tidy() {
        model.overlays.dismissMenu()
        if sim.manifest.layout == .manual, renderer.tidy(animated: !reduceMotion) {
            viewport.fit()
        } else {
            model.overlays.toast(sim.manifest.layout == .auto ? "Auto layout is already tidy" : "Already tidy")
        }
    }

    var body: some View {
        let actions = actions
        GeometryReader { proxy in
            // Every pane gets an exact frame, so a change inside one (a new selection in the inspector)
            // lays out that pane alone instead of re-measuring its neighbours' content.
            let size = proxy.size
            let inspectorWidth = model.inspectorVisible ? min(Theme.inspectorWidth, max(175, size.width * 0.34)) : 0
            let columnWidth = max(0, size.width - (model.inspectorVisible ? inspectorWidth + 1 : 0))
            let dockHeight = model.dockVisible ? min(222, max(133, size.height * 0.33)) : 0
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    SimToolbar(model: model, sim: sim, pulse: pulse, up: up, parent: detailParent.map { ($0.title, out) },
                               tidy: tidyAction, still: snapshot != nil)
                        .equatable()
                        .frame(width: columnWidth, height: 44)
                    Rectangle().fill(Theme.border).frame(height: 1)
                    stage(actions)
                        .frame(width: columnWidth, height: max(0, size.height - 45 - (model.dockVisible ? dockHeight + 1 : 0)))
                    if model.dockVisible {
                        Rectangle().fill(Theme.border).frame(height: 1)
                        SimDock(sim: sim, model: model, terms: terms, actions: actions, selection: selection, pulse: pulse,
                                still: snapshot != nil, select: select, tab: $tab)
                            .equatable()
                            .frame(width: columnWidth, height: dockHeight)
                    }
                }
                .frame(width: columnWidth, height: size.height)
                .overlay {
                    SimHowHost(model: model, sim: sim, terms: terms, actions: actions, select: select, still: snapshot != nil)
                        .padding(.top, 45)
                }
                if model.inspectorVisible {
                    Rectangle().fill(Theme.border).frame(width: 1, height: size.height)
                    SimInspector(model: model, sim: sim, terms: terms, actions: actions, selection: selection, select: select,
                                 pulse: pulse, still: snapshot != nil)
                        .frame(width: inspectorWidth, height: size.height)
                }
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
        .background { SimPaletteCommands(actions: actions, selection: selection) }
        .onAppear {
            updateNotes()
            appear()
            takeFocus()
        }
        .onChange(of: model.vault.revision) { _, _ in updateNotes() }
        .onChange(of: SimFocus.of(model).request) { _, _ in takeFocus() }
        .onChange(of: SimPressureState.of(sim).tabRequest) { _, _ in
            tab = .pressure
            model.dockVisible = true
        }
        .onDisappear { navigation?.cancel() }
    }

    private func stage(_ actions: SimActions) -> some View {
        SimStage(sim: sim, model: model, terms: terms, renderer: renderer, viewport: viewport,
                 selection: selection, noteIDs: noteIDs, still: snapshot != nil,
                 onSelect: select, onDive: { if let node = sim.level.node($0) { dive(node) } },
                 menu: actions.menu, onKey: key, pulse: pulse, pressureOpen: pressureOpen)
            .scaleEffect(presentationScale, anchor: viewport.origin(for: presentationNode, in: renderer.layout, compact: false))
            .opacity(presentationOpacity)
            .clipped()
            .overlay(alignment: .center) {
                if snapshot?.previewMenu == true { SimMenuPreview(items: actions.menu(for: selection)) }
            }
            .overlay(alignment: .top) { SimEnumDetailHost(model: model, sim: sim, still: snapshot != nil) }
    }

    /// The zoom out of a level runs `Theme.gentle`; the next level opens just before it finishes.
    private static let routeSwitchDelay = Duration.milliseconds(200)

    /// The Pressure tab is on screen: a selected node shows its blast radius.
    private var pressureOpen: Bool { tab == .pressure && model.dockVisible }

    private func select(_ target: StageSelection?) {
        selection = target
        SimOpsState.of(sim).selectionChanged(to: target)
        SimPressureState.of(sim).selectionChanged(to: target)
        model.overlays.dismissMenu()
    }

    /// Selects the node a note or the palette asked for.
    private func takeFocus() {
        guard let node = SimFocus.of(model).take(for: AppModel.sessionKey(id, sim.path)),
              sim.level.node(node) != nil else { return }
        select(.node(node))
    }

    /// The level this manifest was entered from through a node's `detail:` link.
    private var detailParent: (title: String, node: String)? {
        guard sim.path.isEmpty, case .sim(let parentID, let parentPath)? = model.backStack.last, parentID != id,
              let parent = SimSessions.cachedManifest(model, id: parentID),
              let node = parent.level(at: parentPath)?.nodes.first(where: { $0.detail == id }) else { return nil }
        let level = parentPath.last.flatMap { parent.level(at: Array(parentPath.dropLast()))?.node($0)?.label }
        return (level ?? parent.title, node.id)
    }

    /// Back out of a `detail:` deep dive to the level it was entered from.
    private func out() {
        guard navigation == nil, let parent = detailParent, let destination = model.backStack.last else { return }
        model.overlays.dismissMenu()
        model.overlays.closeTerm()
        guard !reduceMotion else { model.goBack(); return }
        presentationNode = nil
        withAnimation(Theme.gentle) {
            presentationScale = 0.8
            presentationOpacity = 0
        }
        navigation = Task { @MainActor in
            try? await Task.sleep(for: SimWorkspace.routeSwitchDelay)
            guard !Task.isCancelled else { return }
            arrival = SimArrival(destination: destination, forward: false, node: parent.node)
            model.goBack()
            navigation = nil
        }
    }

    private func updateNotes() {
        noteIDs = Set(sim.level.nodes.filter { model.vault.hasNote(actions.notePath($0)) }.map(\.id))
    }

    private func dive(_ node: Node) {
        guard let route = SimSessions.drillDestination(node, id: id, path: sim.path) else { return }
        navigate(route, forward: true, node: node.id,
                 parentRate: sim.nodeState(node.id)?.arrivals ?? SimOpsPath.measuredRate(node.id, in: sim))
    }

    private func up(_ depth: Int) {
        guard depth < sim.path.count else { return }
        let path = Array(sim.path.prefix(depth))
        let ancestor = model.sessions[AppModel.sessionKey(id, path)]
        navigate(.sim(id, path: path), forward: false, node: sim.path[depth], parentRate: ancestor?.parentRate)
    }

    private func navigate(_ route: Route, forward: Bool, node: String, parentRate: Double? = nil) {
        guard navigation == nil else { return }
        model.overlays.dismissMenu()
        model.overlays.closeTerm()
        guard !reduceMotion else { model.open(route, parentRate: parentRate); return }
        presentationNode = forward ? node : nil
        withAnimation(Theme.gentle) {
            presentationScale = forward ? 2.15 : 0.8
            presentationOpacity = 0
        }
        navigation = Task { @MainActor in
            try? await Task.sleep(for: SimWorkspace.routeSwitchDelay)
            guard !Task.isCancelled else { return }
            arrival = SimArrival(destination: route, forward: forward, node: node)
            model.open(route, parentRate: parentRate)
            navigation = nil
        }
    }

    private func appear() {
        guard let target = arrival, target.destination == .sim(id, path: sim.path) else { return }
        arrival = nil
        guard !reduceMotion else { return }
        presentationNode = target.forward ? nil : target.node
        presentationScale = target.forward ? 1.28 : 1.55
        presentationOpacity = 0
        navigation = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.gentle) {
                presentationScale = 1
                presentationOpacity = 1
            }
            navigation = nil
        }
    }

    private func key(_ event: NSEvent) -> Bool {
        guard !model.paletteOpen, !model.switcherOpen else { return false }
        if model.overlays.menu == nil, model.overlays.card == nil, SimHowState.of(sim).key(event) { return true }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 {
            if model.overlays.menu != nil { model.overlays.dismissMenu() }
            else if model.overlays.card != nil { model.overlays.closeTerm() }
            else if SimPressureState.of(sim).escape(selection, tabOpen: pressureOpen, sim: sim) { return true }
            else if SimDataState.of(sim).escape(selection) { return true }
            else if selection != nil { select(nil) }
            else if !sim.path.isEmpty { up(sim.path.count - 1) }
            else if detailParent != nil { out() }
            else { return false }
            return true
        }
        guard model.overlays.menu == nil else { return false }
        if flags == .command && event.keyCode == 126 {
            if !sim.path.isEmpty { up(sim.path.count - 1); return true }
            if detailParent != nil { out(); return true }
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags.isEmpty {
            switch key {
            case " ": if !event.isARepeat { sim.playing.toggle() }; return true
            case ".": sim.pauseAndStep(); return true
            default: return false
            }
        }
        if flags == [.command, .option], key == "i" { model.inspectorVisible.toggle(); return true }
        if flags == [.command, .option], key == "l" || event.keyCode == 37 { tidy(); return true }
        guard flags == .command || flags == [.command, .shift] && key == "+" else { return false }
        switch key {
        case "r": sim.reset()
        case "0": viewport.fit()
        case "+", "=": viewport.zoom(1.2, layout: renderer.layout, compact: false)
        case "-", "−": viewport.zoom(1 / 1.2, layout: renderer.layout, compact: false)
        case "j": model.dockVisible.toggle()
        default: return false
        }
        return true
    }
}

@MainActor
private struct SimToolbar: View, Equatable {
    let model: AppModel
    let sim: Simulation
    let pulse: SimPulse
    let up: (Int) -> Void
    /// Set when this manifest is another manifest's `detail:` deep dive: that level's title and the way out.
    var parent: (title: String, out: () -> Void)?
    /// "Tidy layout", offered for `layout: manual` levels.
    var tidy: (() -> Void)?
    var still = false

    /// A selection change re-renders the workspace; the toolbar shows none of it. Its closures act on
    /// the same session either way, and what it observes (playing, speed, scenario) it reads itself.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.sim === rhs.sim && lhs.pulse === rhs.pulse && lhs.parent?.title == rhs.parent?.title && lhs.still == rhs.still
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if still {
                    breadcrumbs
                } else {
                    ScrollView(.horizontal) { breadcrumbs }
                        .scrollIndicators(.hidden)
                        .defaultScrollAnchor(.leading, for: .alignment)
                        .defaultScrollAnchor(.trailing, for: .initialOffset)
                }
            }
            .frame(minWidth: 40, maxWidth: .infinity, alignment: .leading)
            playback
            HStack(spacing: 4) {
                if let tidy {
                    SimButton(title: "Tidy layout", icon: SimActions.tidyIcon, iconOnly: true, action: tidy)
                }
                if !model.dockVisible {
                    SimButton(title: "Show dock", icon: "rectangle.bottomthird.inset.filled", iconOnly: true) {
                        model.dockVisible = true
                    }
                }
                SimButton(title: model.inspectorVisible ? "Hide inspector" : "Show inspector",
                          icon: "sidebar.right", iconOnly: true, active: model.inspectorVisible) {
                    model.inspectorVisible.toggle()
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Theme.surface)
    }

    private var playback: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                if let scenario = sim.scenario {
                    SimPill(title: sim.level.scenarios.first { $0.id == scenario }?.label ?? scenario, icon: "flag.fill", tint: Theme.accent)
                }
                transport
            }
            transport
        }
        .layoutPriority(1)
    }

    private var transport: some View {
        HStack(spacing: 6) {
            SimLive(sim: sim, pulse: pulse) {
                Text(SimFormat.seconds(sim.now)).font(Theme.mono(11, .medium)).monospacedDigit()
                    .foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
            }
            SimButton(title: sim.playing ? "Pause" : "Play", icon: sim.playing ? "pause.fill" : "play.fill",
                      iconOnly: true, active: sim.playing) { sim.playing.toggle() }
            SimButton(title: "Step", icon: "forward.frame", iconOnly: true) { sim.pauseAndStep() }
            SimSegments(values: [0.25, 0.5, 1, 2, 4], selected: sim.speed, label: speedLabel) { sim.speed = $0 }
                .accessibilityLabel("Playback speed")
            SimButton(title: "Reset", icon: "arrow.counterclockwise", iconOnly: true) { sim.reset() }
        }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 7) {
            Image(systemName: sim.manifest.kind == .architecture ? "point.3.connected.trianglepath.dotted" : "waveform.path")
                .font(Theme.ui(13, .medium)).foregroundStyle(Theme.accent)
            if let parent {
                Button(action: parent.out) {
                    Text(parent.title).font(Theme.ui(13)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Back out of this deep dive")
                Image(systemName: "chevron.right").font(Theme.ui(8, .medium)).foregroundStyle(Theme.faint)
            }
            crumb(sim.manifest.title, depth: 0)
            ForEach(Array(sim.path.enumerated()), id: \.offset) { i, id in
                Image(systemName: "chevron.right").font(Theme.ui(8, .medium)).foregroundStyle(Theme.faint)
                let label = SimOpsPath.crumb(id, in: sim.manifest.level(at: Array(sim.path.prefix(i))))
                crumb(label, depth: i + 1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func crumb(_ title: String, depth: Int) -> some View {
        Button { up(depth) } label: {
            Text(title)
                .font(Theme.ui(13, depth == sim.path.count ? .semibold : .regular))
                .foregroundStyle(depth == sim.path.count ? Theme.text : Theme.muted)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(depth == sim.path.count ? .isSelected : [])
    }

    private func speedLabel(_ speed: Double) -> String {
        switch speed {
        case 0.25: "¼"
        case 0.5: "½"
        default: SimFormat.number(speed) + "×"
        }
    }
}

@MainActor
private struct SimMenuPreview: View {
    let items: [MenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                if item.isSeparator {
                    Rectangle().fill(Theme.borderStrong).frame(height: 1).padding(.vertical, 4)
                } else if item.isHeader {
                    Text(item.title).font(Theme.label).foregroundStyle(Theme.muted).padding(.horizontal, 8).frame(height: 23)
                } else {
                    HStack(spacing: 9) {
                        Image(systemName: item.icon ?? "circle").frame(width: 15).foregroundStyle(Theme.muted)
                        Text(item.title)
                        Spacer(minLength: 12)
                        if !item.submenu.isEmpty { Image(systemName: "chevron.right").font(Theme.ui(9)).foregroundStyle(Theme.muted) }
                    }
                    .font(Theme.ui()).foregroundStyle(item.role == .destructive ? Theme.bad : item.enabled ? Theme.text : Theme.faint)
                    .padding(.horizontal, 8).frame(height: 26)
                }
            }
        }
        .padding(5).frame(width: 224)
        .card(Theme.overlay, radius: 8)
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 12)
        .offset(x: 100, y: 15)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
