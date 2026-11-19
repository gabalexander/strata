---
name: strata
description: Create or edit Strata simulators and architecture maps, which are YAML manifests in ~/.strata/sims that the hidden Strata app animates live. Use when the user asks to map, visualize, diagram or simulate a project's architecture (including a work repo), to build an interactive simulator for a technology or system-design pattern, to add a deep dive into a component, or mentions Strata. Also covers writing Strata notes with live sim embeds.
---

# Strata manifests

Strata is the user's private macOS app for learning systems visually. Each simulator or architecture
map is one YAML manifest, and the app simulates it live: requests travel as tokens, queues fill,
threads block, retries amplify and breakers trip. The user clicks into any node to see inside it,
right-clicks to break it, and turns knobs that explain what changes.

The format is an API. Read the full spec before writing anything, every time:

```sh
strata schema          # the complete format and simulation semantics
strata paths           # where things live (~/.strata/sims, ~/.strata/vault, config)
```

## Privacy

Maps of work projects are private:

- Write manifests only to `~/.strata/sims/` and notes only to `~/.strata/vault/`.
- Never commit them, never add them to the project's repo, and never send them to an outside service.
- Never copy production data into a map: no real rows, customer names, emails, keys or tokens.
- The app hides itself from screen sharing. Don't undo that by pasting a map somewhere else.

## Workflow

1. **Start a file**: `strata new <id> --kind architecture|sim --title "…"` writes a commented starter
   to `~/.strata/sims/<id>.yaml`. Or edit an existing file there; the app reloads on save.
2. **Write the manifest**: see [Mapping a real project](#mapping-a-real-project) or [Lessons](#lessons-kind-sim).
3. **Validate**: `strata validate ~/.strata/sims/<id>.yaml` until it prints nothing (zero errors, zero
   warnings). Messages carry line numbers and the fix.
4. **Review** the map as a reviewer would: [Verification](#7-verification).
5. **Simulate**: `strata simulate <id> --seconds 30`, then each scenario with `--scenario <id>`. In
   steady state no node should sit above about 70% utilisation unless you mean to show saturation,
   errors should be about 0, and each scenario should show what its `goal` promises.
6. **Show it**: `strata open <id>` (add `--path node/child` to open a deep dive).

**Refreshing a map** ("update the map", "the code changed"): run `strata drift <id> --json` first and fix
each finding where its map location (level, node, op, step, manifest `line`) says:

- point `code:` at the new path or line (`found`);
- copy each changed query verbatim from its repo location;
- rename what was renamed, and remove ops, nodes or values that are gone;
- add the repo items it lists as not on the map (queries, binaries, subcommands, topics, keys, enum values)
  as ops, nodes and values, or tell the user why you left one out.

Then `strata validate` and `strata drift <id>` again until drift exits 0. Notes (`info`) are heuristics:
check each one, but they don't block.

## Mapping a real project

Survey before you draw, and read the code, not only the file names:

- **Entry points**: every `cmd/*` main package, Dockerfiles and their `CMD`, Procfiles, Helm charts and
  k8s manifests, docker-compose, Terraform.
- **Service boundaries**: one deployable is one node. A repo that builds several binaries is one
  service node with one node per binary inside it ([Binaries](#1-binaries)).
- **Datastores** (drivers, migrations, ORMs), **messaging** (Kafka, RabbitMQ, SQS, NATS clients and
  their topic or queue names), **caches** (Redis, Valkey), search, object storage, LLM APIs, and
  **external APIs** (HTTP clients and their base URLs).
- **The 3-6 request paths that matter**, from route tables, gRPC services, handlers and consumers.
  They become `flows`.
- **Mechanisms, formulas and codes**: grep for `SET … NX`, `EXPIRE`, `EVAL`, `pg_advisory_lock`,
  `FOR UPDATE`, `SKIP LOCKED`, tickers and intervals, leases, backoff, `score`, `rate`, `budget`, status
  constants and `iota` blocks. Each one you find gets explained ([Depth checklist](#depth-checklist)).
- **Real numbers**: DB pool sizes, worker counts, goroutine pools, timeouts, retries and backoff,
  prefetch, replicas, TTLs and intervals, rate limits and SLOs. When you guess, say so in the `doc`
  (`estimate`).

Then build:

- **Overview level**: 8-15 nodes, `groups` for clusters, VPCs or teams, edges with `protocol`, and
  labels as the team says them (`orders-svc`, `ledger-db`). Set `repo:` at the top and `code:` on
  every node.
- **A `brief` on every node and op**: one line, about 15 words: what it is, what it owns, why it matters
  ([Briefs and docs](#briefs-and-docs)).
- **Deep dives** (`inside:`) for every important service: its binaries, then handler → domain logic →
  repositories, outbox, caches and clients, with `port` nodes for callers and `rate: parent` so traffic
  follows the overview. For a big service, write a separate manifest `<project>-<service>` and link it
  with `detail:`.
- **`ops:`** on every service ([Operations](#operations)), **`schema:`** on the main databases and
  **`entities:`** on the services that load them ([Data](#data)).
- **Terms** for domain jargon, and the built-in `glossaries:` for the tech (`[kafka, postgres, redis, grpc]`).
- **Controls** for the real knobs (pool sizes, timeouts, retries, replicas, traffic), with `insights`
  that explain the trade-off *in this system*.
- **Scenarios** for the incidents that matter or have happened: a dependency down, a slow DB, a retry
  storm, consumer lag, a cache flush, a bad deploy (`fail <node> 30%`). Each has a `goal` question and
  `say` narration at each step.
- **Optionally a note**: `~/.strata/vault/Maps/<project>.md` with an overview, a ```strata embed and `[[links]]`.
- **Ids and briefs feed Ask**: the app's Ask tab answers questions from the map and cites nodes, ops, mechanisms,
  enum values and tables by id, so short, stable ids and a one-line summary on every node and op make its answers better.

## Briefs and docs

The inspector shows the `brief` first and keeps the `doc` behind a quiet "More". The user scans briefs
and won't read paragraphs, so write for that:

- **`brief`** on every node (inner nodes too) and every op, and on flows, `how:` mechanisms and deep-dive
  levels: one line, about 15 words (100 characters at most): what it is, what it owns, why it matters.
  Not "handles X" or "the X service": say what X is for.
- **`doc`** is optional: at most 3 short lines or bullets of the non-obvious facts only: how it fails, a
  key number, a gotcha. No paragraphs, no restating the brief, the label or the tech badge.
- **Everything else has a better home**: mechanics in `how:` (step by step, with commands), numbers in
  ops (`facts`, `ttl`, `status`) and node parameters, code paths in `code:`, the status codes in
  `enums:`, and background or history in a vault note linked from `links:`.
- **Level `narration`**: a `brief` plus at most 3 lines on what to watch. **Mechanism `summary`**: a
  `brief` plus at most 3 lines; the steps tell the rest. **Step `note`**: the one thing to notice, in a
  line or two.
- `strata validate` warns about a doc, narration or summary over 280 characters or 3 lines without a
  brief, and about a brief over 120 characters. Fix the text; don't just add a brief on top of a wall.

Before (what an agent tends to write):

```yaml
- id: billing
  kind: service
  doc: |
    The billing service is a Go service that owns invoices and payment attempts. It exposes a REST API
    to the storefront and consumes order events from Kafka. It writes to the billing database and calls
    the payment provider with a 2 s timeout and 3 retries. If the provider is slow, its worker pool
    fills up and order events start to lag, which delays invoices for every customer.
```

After:

```yaml
- id: billing
  kind: service
  brief: Owns invoices and payment attempts; charges the provider for each order.
  doc: |
    - A slow provider fills the worker pool; order events lag behind it.
    - Charges are idempotent by order id, so a redelivered event never charges twice.
  ops:
    - { id: charge, kind: http, target: provider, label: POST /charges, brief: Charges one order.,
        facts: { timeout: 2s, retries: "3, exponential" } }
```

The REST API, the topic and the database are already on the diagram as edges and ops; the timeout and
retries are facts on the op that has them.

## Depth checklist

A map is deep enough when a new engineer can answer "what runs, what does it query, how does that
mechanism work, what does 3200 mean" from it alone. For **every important service**, do all seven.
A mechanism that is only "noted", a formula without numbers, a query with `...` or a status code
without a meaning is not done. Deep means more ops, mechanisms, formulas and enums, never longer prose:
a node's brief and its 3-line doc stay that size however deep the map goes.

### 1. Binaries

- Each binary (`cmd/api`, `cmd/worker`, `cmd/scheduler`, each Procfile entry) is its own node inside
  the service: `kind: service` for servers, `worker` for consumers and loops, `cron` for schedulers.
  Give it `binary:` and `code:` (its `main.go`). The service card then lists them as chips.
- The service's `doc` names the shared packages (`internal/*`, `pkg/*`) in a bullet each: what it owns
  and which binaries use it.

```yaml
- id: campaigns
  kind: service
  label: campaigns-svc
  code: cmd
  brief: Owns campaigns, their schedule and pacing; one Go module, three binaries.
  doc: |
    - internal/campaign (pacing, the status machine): api and worker.
    - internal/store (sqlc queries): all three.
  inside:
    nodes:
      - { id: in, kind: port, label: admin UI }
      - { id: api, kind: service, label: api, binary: cmd/api, code: cmd/api/main.go }
      - { id: worker, kind: worker, label: worker, binary: cmd/worker, code: cmd/worker/main.go }
      - { id: scheduler, kind: cron, label: scheduler, binary: cmd/scheduler, code: cmd/scheduler/main.go }
```

### 2. Full SQL

- One op per query. Copy each **verbatim**: from the sqlc `.sql` file (keep its `-- name: GetX :one`
  line), the ORM or query-builder call, or the raw string in the code.
- Never elide (`...`, `…`, `SELECT ...`, `<columns>`), never compress several clauses or statements
  onto one line, never paraphrase. Write `query: |` with one clause per line.
- A transaction lists every statement in order, `BEGIN` to `COMMIT`, with `tx: true` and `locks:`.
- `strata validate` warns about an elided query, a statement that isn't whole, and a `sql` op without
  a `query`. Fix each by copying the real query.

### 3. Mechanisms

- Any algorithm or protocol gets a `how:` sequence on the node or op that implements it: leader
  election, a roster with heartbeats, locks and leases, rate limiting, sharding and rebalancing,
  retries with fencing tokens, outbox relays, schedulers.
- A `brief` says the idea in one line; `summary` adds at most 3 lines. Each step's `note` is the one
  thing to notice there, in a line or two.
- Each step has the **exact command** (the Valkey or Redis command with its arguments, the SQL, the RPC)
  and its `reply`; `at` timings from the code's intervals; `state` changes with their `ttl`.
- `branches:` cover the failures: a crash, an expired lease, a lost race, a timeout, a split brain.
- Participants link to diagram nodes with `node:`, and `code:` points at the implementation.
- Model it on the roster example in `strata schema` (How it works); `strata how valkey-roster` prints a
  complete one.

### 4. Formulas

Scoring, pricing, budgets and pacing, rate calculations and backoff math get `formula:` with `expr`
written as math, `where:` naming every symbol with its unit and its value from config, a worked
`example` with real numbers, and `code:`.

### 5. Enums and status codes

- Every status or type code, integer (3100, 3200) or string (`pending`), gets an `enums:` entry: each
  value with `name` and `doc`, `terminal: true` on the end states, and `transitions` with `by:`
  naming the `node/op` that makes each move. Columns that hold it get `enum:`.
- HTTP and gRPC ops list every `status` they return with when it happens (`409 duplicate idempotency key`).

### 6. Layout

Don't hand-place nodes. Leave `layout: auto`, express structure with `groups`, and set `at` only as a
hint to fix one specific ordering.

Architecture maps with a request spine (a request enters, then flows step by step through services and
queues) read best top to bottom: set `direction: down` at the top level. The spine (the longest path
of sources, services and queues the flows take) runs straight down the middle, a store or API that one
step alone calls sits beside that step, and databases shared by several steps line the bottom. Model
the spine as real edges and flows so the layout can find it: an external engine or store on the main
path breaks it there. Deep dives inherit it; give a deep dive `direction: right` if it reads
better left to right. Keep `direction: right` (the default) for short pipelines and most lessons.

### 7. Verification

`strata validate` must print nothing. Then read each report as a reviewer and fix what's missing:

- every node and op has a `brief`, and no `doc` runs past 3 short lines (`strata ops <id> --json` shows
  each op's `brief` and `doc`);

- `strata ops <id>`: every binary has its endpoints, queries, keys and topics, the ops you care about are named by a flow,
  and in each deep dive every op that talks to something maps to an inner node;
- `strata data <id>`: tables, keys and sample rows join, and entities assemble;
- `strata how <id>`: every mechanism plays from start to end with exact commands and its failure branches
  (`--mechanism <id>` or `--branch <id>` prints just one);
- `strata enums <id>`: every code has a name, a meaning and its transitions (`--find 3200` looks one up);
- `strata analyze <id>`: the bottleneck and max rates match what the team knows ([Pressure](#pressure));
- `strata drift <id>`: every code reference, query, binary, topic, key and enum still matches the repo (exit 0),
  and what it lists as not on the map is either added or left out on purpose.

When you hand the map over, tell the user what you covered (binaries, mechanisms, formulas, enums)
and where you guessed.

## Operations

Ops are what each node really does, taken from the code. Add one per query, endpoint, topic or key
pattern, with `code:` pointing at it. `strata schema` lists the fields for each kind.

- **SQL** (`kind: sql`, `target:` the database): see [Full SQL](#2-full-sql). Set `access`; take
  `tables` and `indexes` from the migrations, never guess them.
- **Redis or Valkey** (`kind: cache`): `command` (`GET`, `SET EX 300`, `HINCRBY`, `EVAL`), the key
  pattern from the key builder (`price:{sku}`), and `ttl`.
- **Kafka, RabbitMQ or SQS**: producers are `publish` ops and consumers `consume` ops, with `topic`
  (or exchange or queue), `key` and `group`, and a `payload` built from the message schema.
- **Endpoints** are inbound (no `target`): gRPC methods from `.proto` services
  (`method: orders.v1.Orders/PlaceOrder`, `streaming`), HTTP routes from router tables, and every
  `status` the handler returns.
- **Outbound clients** (`kind: http` or `rpc`, `target:` the callee): `calls: <node>/<op>` names the
  endpoint reached, so a request can be followed across services. Timeouts, retries, auth and
  idempotency go in `facts`.
- **Live numbers**: put `op:` on the flow step that performs each op, and on each consumer flow.
- **Ops in a deep dive**: keep a service's ops on the service node in the overview, with `target:`
  the overview node (`orders-db`, `redis`). Inside its `inside:` level, Strata maps each one to the inner
  node it talks to (the target's id, the node whose `code:` file is the op's, a node labelled like the
  target, or the only database, cache or port that fits), and lists them on that node and under
  "Operations of <service>". To light the exact path, name the op on the inner step that performs it:
  `{ call: tx, op: insert-order }` resolves on the service when neither inner node has it (or write
  `../insert-order`). An op only one inner node performs can live on that node instead. Give inner
  stores, caches and clients the same `code:` file as their ops, and label a port drawn for an
  overview node like that node, so the mapping is exact. `strata ops <id>` prints the mapping per
  deep dive: check that every op that talks to something has a peer.

## Data

- **Schemas** come from migrations or ORM models; foreign keys become `ref`, and `enum:` links a
  status column to its enum. List the indexes the queries use, and make each op's `tables` match.
- **Entities** come from domain structs and the repository code that loads them.
- **Sample rows**, 3-6 per table, from seed files or fixtures or synthesised realistically, with ids
  that join. Made-up names and `example.com` emails, never production rows.
- **Volumes** (`rows`, `growth`) and flow `traffic:` and `slo:` come from the code, configs or the
  user; say in the `doc` that they are estimates, and leave them out rather than invent them.

## Pressure

`strata analyze <id>` prints the Pressure tab: per node slots, hold time and utilisation; per flow its
max rate and the bottleneck; a scale plan; the load on each database and cache by op and table; and
the blast radius of the top bottleneck. `--rates place-order=120/s,...` asks "what if"; `--json` is for scripts.

Check it against reality and tell the user what you found:

- **The bottleneck** should be the component the team knows hurts (the DB pool, a worker count, a
  partner's rate limit). If it isn't, fix a pool size, replica count or latency, not the conclusion.
- **Max rates** should be in the range production has survived. Far below the real peak means the map
  is too pessimistic or production is close to falling over: ask.
- **Database pressure** should name the queries the team would call the heavy ones.
- **The simulation agrees**: `strata simulate <id>` at the same rates shows similar utilisation (the
  analysis uses means, so heavy tails and timeouts only show up in the simulation).

## Lessons (`kind: sim`)

For a technology or pattern (retries vs timeouts, prefetch, cache stampede, outbox, consumer lag):
3-8 nodes on one level with a `category` and `glossaries:`; 2-4 controls whose insights name the metric
that moves and whether that's good; 2-4 scenarios that each prove one point; a `brief` and a short
`narration` that says what to watch; a `brief` on each node.

## Gotchas

- Durations need units (`20ms`, not `20`). Probabilities are `0.2` or `20%`.
- `call` targets must be servers and `publish` targets a `queue` or `topic`. A consumer flow is
  `on: <buffer>` + `by: <consumer>`, with no `rate`.
- Nested `steps` under a `call` run *at the callee*. Order them as the code does.
- A step's `op:` resolves on the calling node first, then the target; write `node/op` when both have it.
  In a deep dive it then falls back to the ops of the node the level is inside (`../op` names one outright).
- A service holds its slot while it waits on downstream calls. Set `async: true` for event-loop servers.
- Keep ids stable once the user has notes on them (`~/.strata/vault/Sims/<sim>/<node>.md`).

## Notes with live sims

Notes are markdown in `~/.strata/vault/`. `[[Note name]]` and `[[sim-id]]` link, and a fenced block
embeds a live simulator:

````markdown
```strata
sim: checkout
view: [orders]        # optional: start inside a deep dive
scenario: db-outage   # optional
```
````
