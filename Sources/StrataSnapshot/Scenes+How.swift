import AppKit
import SwiftUI
import StrataCore
@_spi(Snapshots) import StrataUI

// How it works and Formulas: the inspector card, the mechanism player at key moments, the state
// panel, the formula hover card and section, and the roster lesson's stage, on the bundled examples.

@MainActor func howScenes() -> [Scene] {
    let size = CGSize(width: 1400, height: 880)
    return [
        howScene("how-inspector-card", size: CGSize(width: 1400, height: 1040), selected: "scheduler"),
        howScene("how-player-step1", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", step: 1)
        },
        howScene("how-player-heartbeat2", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", step: 7)
        },
        howScene("how-player-flight", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", step: 5, progress: 0.86)
        },
        howScene("how-player-crash-expired", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", branch: "crash", step: 9)
        },
        howScene("how-player-partition-fenced", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", branch: "partition", step: 13)
        },
        howScene("how-player-leave", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", branch: "leave", step: 9)
        },
        howStateScene(),
        howKeysScene(size: size),
        howHoverScene(size: size),
        howScene("how-formula-section", size: CGSize(width: 1400, height: 1500), selected: "scheduler"),
        howScene("how-overview", size: size, manifest: "checkout", path: ["orders"], selected: nil),
        howScene("how-formula-op", size: size, selected: "scheduler") { sim in
            SimOpsSnapshot.open(sim, node: "scheduler", op: "heartbeat", from: "scheduler")
        },
        Scene(name: "how-formula-typeset", size: CGSize(width: 320, height: 1000)) {
            AnyView(SimHowSnapshot.formulas(formulaSamples()))
        },
        howScene("how-roster-stage", size: size, selected: nil, seconds: 6),
        howScene("how-op-mechanism", size: size, selected: "scheduler") { sim in
            SimOpsSnapshot.open(sim, node: "scheduler", op: "fenced-write", from: "scheduler")
        },
        howScene("how-player-untimed", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", op: "fenced-write", mechanism: "fence", branch: "stale", step: 4)
        },
        howScene("how-checkout-relay", size: size, manifest: "checkout", path: ["orders"], selected: "relay") { sim in
            SimHowSnapshot.open(sim, node: "relay", mechanism: "relay-cycle", branch: "crash", step: 5, progress: 0.8)
        },
        // The step detail: a click on a step shows all of it beside the diagram.
        howScene("how-step-detail", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", step: 1)
            SimHowSnapshot.inspect(sim)
        },
        howScene("how-step-detail-start", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", step: 0)
            SimHowSnapshot.inspect(sim)
        },
        howScene("how-step-detail-fcall", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", op: "fenced-write", mechanism: "fence", step: 1)
            SimHowSnapshot.inspect(sim)
        },
        howScene("how-step-detail-sql", size: size, manifest: "checkout", path: ["orders"], selected: "relay") { sim in
            SimHowSnapshot.open(sim, node: "relay", mechanism: "relay-cycle", step: 1)
            SimHowSnapshot.inspect(sim)
        },
        // Long keys, multi-line SQL, six participants and long labels (a synthetic sweep), wide and narrow.
        howScene("how-long-detail", size: size, manifest: longStepsID, selected: "sweeper") { sim in
            SimHowSnapshot.open(sim, node: "sweeper", mechanism: "sweep", step: "lock")
            SimHowSnapshot.inspect(sim)
        },
        howScene("how-long-detail-sql-narrow", size: CGSize(width: 1100, height: 800), manifest: longStepsID, selected: "sweeper") { sim in
            SimHowSnapshot.open(sim, node: "sweeper", mechanism: "sweep", step: "list")
            SimHowSnapshot.inspect(sim)
        },
        howScene("how-long-state-narrow", size: CGSize(width: 1000, height: 760), manifest: longStepsID, selected: "sweeper") { sim in
            SimHowSnapshot.open(sim, node: "sweeper", mechanism: "sweep", step: "lock")
        },
        howScene("how-long-hover", size: size, manifest: longStepsID, selected: "sweeper") { sim in
            SimHowSnapshot.open(sim, node: "sweeper", mechanism: "sweep", step: "lose")
            SimHowSnapshot.hover(sim, step: 4)
        },
        howScene("how-long-branch", size: size, manifest: longStepsID, selected: "sweeper") { sim in
            SimHowSnapshot.open(sim, node: "sweeper", mechanism: "sweep", branch: "valkey-down", step: 2, progress: 0.5)
        },
        howDetailKeysScene(size: size),
    ]
}

@MainActor private func howScene(_ name: String, size: CGSize, manifest id: String = "valkey-roster", path: [String] = [],
                                 selected: String?, seconds: Double = 4, prepare: @escaping (Simulation) -> Void = { _ in }) -> Scene {
    Scene(name: name, size: size) {
        let manifest = howManifest(id)
        let model = howModel(manifest)
        let sim = Simulation(manifest: manifest, path: path)
        if !path.isEmpty { model.open(.sim(manifest.id, path: path)) }
        sim.playing = true
        var t = 0.0
        while t < seconds { sim.tick(1.0 / 60); t += 1.0 / 60 }
        sim.playing = false
        model.sessions[AppModel.sessionKey(manifest.id, path)] = sim
        prepare(sim)
        return AnyView(SimScreen(model: model, id: manifest.id, path: path, snapshot: SimSnapshotOptions(selectedNode: selected)))
    }
}

/// The state panel alone, in the crash branch while A's key drains toward its deadline.
@MainActor private func howStateScene() -> Scene {
    Scene(name: "how-state-ttl", size: CGSize(width: 330, height: 420)) {
        let manifest = howManifest("valkey-roster")
        let sim = Simulation(manifest: manifest)
        SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", branch: "crash", step: 8, progress: 0.7)
        return SimHowSnapshot.statePanel(sim)
    }
}

/// The real window: the player opened from the start, then → three times through the stage's key
/// handling, which lands on step 3 (the shard ranking).
@MainActor private func howKeysScene(size: CGSize) -> Scene {
    Scene(name: "how-player-keys", size: size, hosted: true) {
        let manifest = howManifest("valkey-roster")
        let model = howModel(manifest)
        model.open(.sim(manifest.id, path: []))
        model.sidebarVisible = false
        let sim = Simulation(manifest: manifest)
        sim.playing = false
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", step: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { howPress([124, 124, 124]) }
        return AnyView(RootView(model: model, fixtureEntries: model.library.entries, fixtureNotes: [:]))
    }
}

/// The real window: → twice, Return opens the detail on step 2, then → moves it along to step 3.
@MainActor private func howDetailKeysScene(size: CGSize) -> Scene {
    Scene(name: "how-player-detail-keys", size: size, hosted: true) {
        let manifest = howManifest("valkey-roster")
        let model = howModel(manifest)
        model.open(.sim(manifest.id, path: []))
        model.sidebarVisible = false
        let sim = Simulation(manifest: manifest)
        sim.playing = false
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", step: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { howPress([124, 124, 36, 124]) }
        return AnyView(RootView(model: model, fixtureEntries: model.library.entries, fixtureNotes: [:]))
    }
}

/// Arrow keys (123, 124) and Return (36), sent through the window like typed keys.
@MainActor private func howPress(_ keys: [UInt16]) {
    guard let window = NSApp.windows.last else { return }
    for key in keys {
        let arrow = key == 36 ? "\r" : String(UnicodeScalar(key == 124 ? NSRightArrowFunctionKey : NSLeftArrowFunctionKey)!)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key == 36 ? [] : [.numericPad, .function],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
                                           isARepeat: false, keyCode: key) else { continue }
        NSApp.sendEvent(event)
    }
}

/// Hovering the ƒ badge on scheduler shows the compact formula card, drawn by the real overlay host.
@MainActor private func howHoverScene(size: CGSize) -> Scene {
    Scene(name: "how-formula-hover", size: size, hosted: true) {
        let manifest = howManifest("valkey-roster")
        let model = howModel(manifest)
        model.open(.sim(manifest.id, path: []))
        model.sidebarVisible = false
        let sim = Simulation(manifest: manifest)
        sim.playing = true
        for _ in 0..<240 { sim.tick(1.0 / 60) }
        sim.playing = false
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        SimHowSnapshot.hoverFormula(sim, node: "scheduler")
        return AnyView(RootView(model: model, fixtureEntries: model.library.entries, fixtureNotes: [:]))
    }
}

private func formulaSamples() -> [(title: String, formula: Formula)] {
    func formula(_ expr: String, _ vars: [(String, String)] = [], example: String? = nil) -> Formula {
        var formula = Formula(expr: expr)
        formula.vars = vars.map { (name: $0.0, meaning: $0.1) }
        formula.example = example
        return formula
    }
    return [
        ("Spec example: ranker", formula("score = w_r · e^(−age / τ) + w_c · ctr − p · spam",
                                         [("w_r", "weight of recency (0.6)"), ("τ", "half-life of a post in hours (6)"), ("ctr", "click-through rate"), ("p", "spam penalty (0.9)")],
                                         example: "age 3 h, ctr 0.04, not spam → 0.6 · e^(−0.5) + 0.4 · 0.04 = 0.38")),
        ("Rendezvous hashing", formula("owner(s) = argmax_(m ∈ M) h(m, s)")),
        ("Stacked fraction", formula("interval = (ttl / (k + 1))", [("ttl", "key TTL"), ("k", "heartbeats per TTL")])),
        ("Sum with subscripts", formula("total = Σ_i qty_i · price_i · (1 − d) + ship")),
        ("ASCII spellings", formula("p99 <= 2 * p50 and lambda >= mu_max / (1 + rho^2)")),
        ("Unknown syntax falls back to mono", formula("x = (a + b")),
    ]
}

private let longStepsID = "how-long-steps"

private func howManifest(_ id: String) -> Manifest {
    if id == longStepsID {
        guard let manifest = ManifestParser.parse(longStepsSource, source: .file(URL(fileURLWithPath: "/snapshots/how-long-steps.yaml"))).0 else {
            fatalError("the long steps fixture does not parse")
        }
        return manifest
    }
    guard let url = StrataResources.url("Examples/\(id).yaml"), let text = try? String(contentsOf: url, encoding: .utf8),
          let manifest = ManifestParser.parse(text, source: .bundled(url)).0 else { fatalError("missing example \(id)") }
    return manifest
}

@MainActor private func howModel(_ manifest: Manifest) -> AppModel {
    AppModel(library: Library(manifests: [manifest]),
             vault: Vault(root: FileManager.default.temporaryDirectory.appendingPathComponent("strata-snap-vault")))
}

/// A synthetic sweep with the kind of steps that used to collide: six participants, keys of 60+
/// characters, multi-line SQL with a subquery, a gRPC call, a JSON payload, long labels and branches.
private let longStepsSource = #"""
strata: 1
id: how-long-steps
title: Nightly sweep
category: How it works
nodes:
  - id: sweeper
    kind: service
    label: sweeper
    tech: Go
    how:
      - id: sweep
        title: The nightly sweep, its lock and its claims
        summary: |
          Every minute both sweeper pods try one Valkey lock. Whoever gets it closes the jobs whose
          deadline passed and tells the broker; the other pod waits for the next minute. Nobody deletes
          the lock: its 15 s expiry frees it.
        code: internal/sweep/controller.go:120
        participants:
          - { id: a, label: sweeper pod A, node: sweeper }
          - { id: b, label: sweeper pod B, node: sweeper }
          - { id: v, label: Valkey, node: cache }
          - { id: pg, label: jobs Postgres, node: db }
          - { id: reg, label: owner-registry, node: owners }
          - { id: bus, label: event broker, node: broker }
        initial:
          - { key: "app:jobs-scheduler-eu:locks:generation", value: "1800000000000000000" }
          - { key: "app:jobs-scheduler-eu:daily:full-sweep:done:2026-11-19", value: "1", ttl: 780m }
        steps:
          - { id: epoch, from: a, to: v, label: A checks the lock store's generation, command: "GET app:jobs-scheduler-eu:locks:generation",
              reply: '"1800000000000000000"', at: 0s }
          - id: lock
            from: a
            to: v
            label: A takes the sweep lock for this minute
            command: "SET app:jobs-scheduler-eu:locks:sweep:nightly-full-sweep:2026-11-19 1801234500000 NX PX 15000"
            reply: OK
            at: 1ms
            state: [ { key: "app:jobs-scheduler-eu:locks:sweep:nightly-full-sweep:2026-11-19", value: "1801234500000", ttl: 15s } ]
            note: "The value records when A took it. `NX` lets only one pod win; `PX 15000` frees the lock by itself if A dies holding it."
            code: internal/sweep/lock.go:88
          - { id: lose, from: b, to: v, label: B tries the same minute and gets nothing,
              command: "SET app:jobs-scheduler-eu:locks:sweep:nightly-full-sweep:2026-11-19 1801234500004 NX PX 15000", reply: (nil), at: 4ms }
          - id: list
            from: a
            to: pg
            label: find the jobs still running after their deadline (last 6 hours, full pass)
            command: |
              SELECT j.id, j.created_at, l.worker_id, l.expires_at IS NULL
              FROM public.jobs j
              JOIN public.leases l ON l.job_id = j.id
              WHERE j.state = ?
                AND j.created_at >= ?
                AND EXISTS (SELECT 1 FROM job_groups g WHERE g.id = j.group_id AND g.shard < (SELECT shard_limit FROM public.sweep_config))
              ORDER BY j.updated_at
              LIMIT ?
            reply: "2 rows: job 4120 (worker w-3, lease expired), job 4121 (worker w-9, lease expired)"
            at: 10ms
            note: "Parameters: state running, the cutoff six hours back, and a page of 500."
          - { id: owners, from: a, to: reg, label: ask who holds each job, command: "OwnerRegistry/GetOwners{job_ids: [4120, 4121], include_released: false}",
              reply: "{ owners: [WORKER_A, WORKER_B] }", at: 14ms }
          - id: close
            from: a
            to: pg
            label: mark 4120 closed, drop its lease
            command: |
              BEGIN;
              UPDATE public.jobs SET state = ?, closed_at = now() WHERE id = ? AND state = ?;
              UPDATE public.leases SET released_at = now() WHERE job_id = ?;
              COMMIT;
            reply: UPDATE 1, UPDATE 1, COMMIT
            at: 20ms
          - { id: publish, from: a, to: bus, label: announce the closed job,
              command: 'basic.publish exchange=jobs routing_key=jobs.closed.v1 {"job_id": 4120, "state": "closed", "reason": "deadline"}',
              reply: basic.ack, at: 25ms }
          - { id: lapse, from: v, to: v, label: "the lock's 15 s run out", at: 15s,
              state: [ { key: "app:jobs-scheduler-eu:locks:sweep:nightly-full-sweep:2026-11-19", value: null } ] }
        branches:
          - id: valkey-down
            label: Valkey does not answer, so nobody sweeps this minute
            after: epoch
            steps:
              - { from: a, to: v, label: SET waits a second and fails, command: "SET app:jobs-scheduler-eu:locks:sweep:nightly-full-sweep:2026-11-19 1801234500000 NX PX 15000",
                  reply: "(error) i/o timeout", at: 1s }
              - { from: a, to: a, label: nothing swept this minute, at: 1s }
          - id: race
            label: A worker finishes the job during the sweep
            after: list
            steps:
              - { from: a, to: pg, label: the guarded update finds the job closed, command: "UPDATE public.jobs SET state = ? WHERE id = ? AND state = ?", reply: UPDATE 0, at: 20ms }
          - id: crash
            label: Pod A dies halfway
            after: close
            steps:
              - { from: a, to: a, label: A dies, at: 1s }
          - id: owners-down
            label: owner-registry is down
            after: list
            steps:
              - { from: a, to: reg, label: GetOwners fails, command: "OwnerRegistry/GetOwners{job_ids: [4120, 4121]}", reply: UNAVAILABLE, at: 14ms }
          - id: publish-fails
            label: The broker refuses the closed job's event
            after: close
            steps:
              - { from: a, to: bus, label: the publish is nacked, command: "basic.publish exchange=jobs routing_key=jobs.closed.v1", reply: basic.nack, at: 25ms }
          - id: slow
            label: The sweep runs past the lock's 15 s
            after: lock
            steps:
              - { from: v, to: v, label: the lock lapses mid-sweep, at: 15s,
                  state: [ { key: "app:jobs-scheduler-eu:locks:sweep:nightly-full-sweep:2026-11-19", value: null } ] }
  - { id: cache, kind: cache, label: Valkey, tech: Valkey 8 }
  - { id: db, kind: database, label: jobs db, tech: Postgres 16 }
  - { id: owners, kind: service, label: owner-registry, tech: gRPC }
  - { id: broker, kind: queue, label: event broker, tech: RabbitMQ }
edges:
  - { from: sweeper, to: cache }
  - { from: sweeper, to: db }
  - { from: sweeper, to: owners }
  - { from: sweeper, to: broker }
"""#
