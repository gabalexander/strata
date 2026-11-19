import AppKit
import SwiftUI
import StrataCore
@_spi(Snapshots) import StrataUI

// Readable SQL and binaries: formatted multi-statement and one-line queries in the op detail (with the
// raw toggle), component chips on a service card, the components hover, and a binary in the inspector.
// The manifest is written the way an agent first wrote one: every query compressed onto one line.

@MainActor func sqlScenes() -> [Scene] {
    let stage = CGSize(width: 1400, height: 880)
    let detail = CGSize(width: 1400, height: 1320)
    return [
        sqlScene("sql-multi-statement", size: detail, selected: "campaigns") { sim in
            SimOpsSnapshot.open(sim, node: "campaigns", op: "start-due", from: "campaigns")
        },
        sqlScene("sql-multi-statement-raw", size: stage, selected: "campaigns") { sim in
            SimOpsSnapshot.open(sim, node: "campaigns", op: "start-due", from: "campaigns")
            SimOpsQuerySnapshot.showRaw(sim, node: "campaigns", op: "start-due")
        },
        sqlScene("sql-long-select", size: CGSize(width: 1400, height: 1000), selected: "campaigns") { sim in
            SimOpsSnapshot.open(sim, node: "campaigns", op: "list-campaigns", from: "campaigns")
        },
        sqlScene("sql-binary-chips", size: stage),
        sqlScene("sql-components-hover", size: stage) { sim in
            SimComponentsSnapshot.hover(sim, node: "campaigns", component: "worker")
        },
        sqlScene("sql-binary-inspector", size: stage, path: ["campaigns"], selected: "worker"),
    ]
}

@MainActor private func sqlScene(_ name: String, size: CGSize, path: [String] = [], selected: String? = nil,
                                 prepare: @escaping (Simulation) -> Void = { _ in }) -> Scene {
    Scene(name: name, size: size) {
        let manifest = sqlManifest()
        let model = AppModel(library: Library(manifests: [manifest]),
                             vault: Vault(root: FileManager.default.temporaryDirectory.appendingPathComponent("strata-snap-vault")))
        let sim = Simulation(manifest: manifest, path: path)
        if !path.isEmpty { model.open(.sim(manifest.id, path: path)) }
        sim.playing = true
        for _ in 0..<180 { sim.tick(1.0 / 60) }
        model.sessions[AppModel.sessionKey(manifest.id, path)] = sim
        prepare(sim)
        return AnyView(SimScreen(model: model, id: manifest.id, path: path,
                                 snapshot: SimSnapshotOptions(selectedNode: selected)))
    }
}

private func sqlManifest() -> Manifest {
    let (manifest, diagnostics) = ManifestParser.parse(sqlManifestText, source: .inline(note: "snapshots/sql.md", index: 0))
    guard let manifest else { fatalError("sql snapshot manifest: \(diagnostics)") }
    if !diagnostics.isEmpty { FileHandle.standardError.write(Data("sql snapshot manifest: \(diagnostics)\n".utf8)) }
    return manifest
}

private let sqlManifestText = """
    strata: 1
    id: campaigns
    title: Campaign platform
    kind: architecture
    narration: "campaigns-svc ships three binaries from one Go module. Hover its card, or click a chip to open that binary."
    nodes:
      - { id: web, kind: client, label: Admin UI, at: [0, 1] }
      - id: campaigns
        kind: service
        label: campaigns-svc
        tech: Go
        at: [1, 1]
        concurrency: 16
        code: cmd
        doc: One Go module, three binaries (cmd/api, cmd/worker, cmd/scheduler) sharing internal/campaign and internal/store.
        ops:
          - id: start-due
            kind: sql
            target: db
            label: Start due campaigns
            access: read-write
            tables: [campaigns, campaign_events]
            tx: true
            locks: row, SKIP LOCKED
            code: internal/store/queries/campaigns.sql:88
            query: "BEGIN; WITH due AS (SELECT id FROM campaigns WHERE status = 3200 AND start_at <= now() ORDER BY start_at LIMIT 50 FOR UPDATE SKIP LOCKED) UPDATE campaigns c SET status = 3300, started_at = now() FROM due WHERE c.id = due.id RETURNING c.id; INSERT INTO campaign_events (campaign_id, kind, at) SELECT id, 'started', now() FROM campaigns WHERE id = ANY($1::bigint[]); UPDATE scheduler_runs SET finished_at = now(), started = cardinality($1::bigint[]) WHERE id = $2; COMMIT;"
          - id: list-campaigns
            kind: sql
            target: db
            label: List campaigns for an account
            access: read
            tables: [campaigns, campaign_events]
            code: internal/store/queries/campaigns.sql:12
            query: "-- name: ListCampaigns :many\\nselect c.id, c.name, c.status, c.budget_cents, c.spent_cents, c.start_at, c.end_at, count(e.id) as events from campaigns c left join campaign_events e on e.campaign_id = c.id where c.account_id = sqlc.arg(account_id) and c.status <> 3900 and (c.name ilike @query or @query = '') group by c.id order by c.start_at desc limit sqlc.arg(page_size) offset sqlc.arg(page_offset);"
        inside:
          narration: Three binaries built from cmd/, sharing internal/campaign and internal/store.
          nodes:
            - { id: in, kind: port, label: Admin UI, at: [0, 0] }
            - { id: api, kind: service, label: api, tech: Go, binary: cmd/api, code: cmd/api/main.go, at: [1, 0], doc: The HTTP API the admin UI calls. }
            - { id: worker, kind: worker, label: worker, tech: Go, binary: cmd/worker, code: [cmd/worker/main.go, internal/campaign/pacing.go], at: [1, 1], doc: Paces spend for running campaigns. }
            - { id: scheduler, kind: cron, label: scheduler, tech: Go, binary: cmd/scheduler, code: cmd/scheduler/main.go, at: [1, 2], doc: Starts due campaigns every 10 seconds. }
            - { id: pg, kind: database, label: campaigns-db, tech: Postgres, at: [2, 1] }
          edges:
            - { from: in, to: api, protocol: https }
            - { from: api, to: pg, protocol: sql }
            - { from: worker, to: pg, protocol: sql }
            - { from: scheduler, to: pg, protocol: sql }
          flows:
            - { id: requests, from: in, rate: parent, steps: [ { call: api, steps: [ { call: pg } ] } ] }
            - { id: ticks, from: scheduler, rate: every 1s, steps: [ { call: pg } ] }
      - id: ingest
        kind: service
        label: events-ingest
        tech: Go
        at: [1, 2.3]
        doc: Five processes behind one deployment; the card shows what fits and +N for the rest.
        inside:
          nodes:
            - { id: gateway-api, kind: service, label: http-gateway, binary: cmd/gateway, at: [0, 0] }
            - { id: consumer, kind: worker, label: kafka-consumer, binary: cmd/consumer, at: [0, 1] }
            - { id: dedupe, kind: worker, label: dedupe, binary: cmd/dedupe, at: [1, 0] }
            - { id: compactor, kind: cron, label: compactor, binary: cmd/compactor, at: [1, 1] }
            - { id: exporter, kind: function, label: metrics-exporter, at: [2, 0] }
      - { id: db, kind: postgres, label: campaigns-db, at: [2.2, 1] }
      - { id: valkey, kind: cache, label: roster, tech: Valkey, at: [2.2, 0] }
      - { id: events, kind: topic, label: ad-events, tech: Kafka, at: [2.2, 2.3] }
    edges:
      - { from: web, to: campaigns, protocol: https }
      - { from: campaigns, to: db, protocol: sql }
      - { from: campaigns, to: valkey, protocol: redis }
      - { from: ingest, to: events, protocol: kafka }
    flows:
      - id: admin
        label: Admin requests
        from: web
        rate: 8/s
        steps:
          - call: campaigns
            steps:
              - { call: valkey }
              - { call: db, op: list-campaigns }
    """
