---
name: strata
description: Create or edit Strata simulators and architecture maps, which are YAML manifests in ~/.strata/sims that the hidden Strata app animates live. Use when the user asks to map, visualize, diagram or simulate a project's architecture (including a work repo), to build an interactive simulator for a technology or system-design pattern, to add a deep dive into a component, or mentions Strata. Also covers writing Strata notes with live sim embeds.
---

# Strata manifests

Strata is the user's private macOS app for learning systems visually. Each simulator or architecture
map is one YAML manifest. The app simulates it live:

- requests travel as tokens;
- queues fill and threads block;
- retries amplify and breakers trip.

The user can click into any node to see what's inside, right-click to break it, and turn knobs
that explain what changes.

The format is an API. Read the full spec before writing anything:

```sh
strata schema          # the complete format and simulation semantics. Read it every time.
strata paths           # where things live (~/.strata/sims, ~/.strata/vault, config)
```

## Privacy

Maps of work projects are private:

- Write manifests only to `~/.strata/sims/` and notes only to `~/.strata/vault/`.
- Never commit them, never add them to the project's repo, and never send them to an outside service.
- The app hides itself from screen sharing. Don't undo that by pasting a map somewhere else.

## Workflow

1. **Start a file**: `strata new <id> --kind architecture|sim --title "…"`. This writes a commented
   starter to `~/.strata/sims/<id>.yaml`. Or edit an existing file there; the app reloads on save.
2. **Write the manifest.** See below for mapping a project, or for a lesson.
3. **Validate**: `strata validate ~/.strata/sims/<id>.yaml`. Fix every error *and* warning; the
   messages carry line numbers and suggestions.
4. **Sanity-check the behaviour**: `strata simulate <id> --seconds 30`, then each scenario with
   `strata simulate <id> --scenario <scenario-id>`.
   - In steady state no node should sit above about 70% utilisation unless you mean to show
     saturation, and the error rate should be about 0.
   - Each scenario should show the effect its `goal` promises.
   - Adjust params until it does.
5. **Show it**: `strata open <id>` (add `--path node/child` to open a deep dive).

## Mapping a real project

Survey before you draw:

- **Entry points:** `cmd/`, `main` packages, Dockerfiles, Helm charts and k8s manifests,
  docker-compose, Terraform, Procfiles.
- **Service boundaries:** one deployable is one node. Separate API and worker processes from the
  same repo are separate nodes.
- **Datastores:** DB drivers, migrations, ORMs. **Messaging:** Kafka, RabbitMQ, SQS or NATS clients,
  and topic or queue names. **Caches:** Redis clients. **Search, object storage, LLM APIs.**
- **External APIs:** HTTP clients with base URLs (payments, email, auth).
- **The 3-6 request paths that matter**, from route tables, gRPC services, handlers and consumers.
  These become `flows`.
- **Real numbers:**
  - DB pool size (concurrency of the db or of the service's connection limit), worker counts,
    goroutine and thread pools;
  - timeouts, retry and backoff configs, prefetch, replica counts;
  - SLOs and rate limits.
  - When you guess, say so in the node's `doc` ("latency assumed").

Then build:

- **Overview level:** 8-15 nodes laid out left to right by call depth (`at: [col, row]`, at most
  about 6 columns).
  - Groups for clusters, VPCs or teams.
  - Edges with `protocol`.
  - Labels as the team says them (`orders-svc`, `ledger-db`).
  - Set `repo:` at the top and `code:` on every node (folder, or `file.go:123` for a key handler).
  - `ops:` on every service: see [Operations](#operations).
  - `schema:` on the main databases and `entities:` on the services that load them: see [Data](#data).
- **Docs on every node** (`doc`), 2-5 lines:
  - what it owns;
  - key endpoints, topics or tables;
  - how it fails;
  - the non-obvious thing a new engineer should know.
- **Deep dives** for the 2-4 most important services, using `inside:`:
  - handler → domain logic → repositories, plus outbox, caches and clients, with `port` nodes for
    callers;
  - `rate: parent` so traffic follows the overview.
  - For a big service, write a separate manifest `<project>-<service>` and link it with `detail:`.
- **Terms** for domain jargon and internal names. Import the built-in `glossaries:` packs for the
  tech involved (for example `[kafka, postgres, redis, grpc]`).
- **Controls** for the real knobs (pool sizes, timeouts, retries, replicas, traffic), with
  `insights` explaining the trade-off *in this system*.
- **Scenarios** for the incidents that matter or have happened: a dependency down, a slow DB, a
  retry storm, consumer lag, a cache flush, a bad deploy (`fail <node> 30%`). Each has a `goal`
  question and `say` narration at each step.
- **Optionally, notes:** `~/.strata/vault/Maps/<project>.md` with an overview, a ```strata embed
  (`sim: <id>`) and `[[links]]`.

## Operations

Ops are what each node really does, taken from the code. Add one op per query, endpoint, topic or key
pattern that matters, with `code:` pointing at it. `strata schema` lists the fields for each kind.

- **SQL** (`kind: sql`, `target:` the database): sqlc query files (`-- name: GetPrice :one`), ORM
  and query-builder calls (GORM, Prisma, SQLAlchemy, ActiveRecord, knex, jOOQ) and raw SQL strings.
  - Set `access` and `query`. Add `tx: true` when statements share a transaction, and `locks` for
    `FOR UPDATE` or `SKIP LOCKED`.
  - Take `tables` and `indexes` from the migrations; don't guess them.
- **Redis or Valkey** (`kind: cache`): `command` (`GET`, `SET EX 300`, `HINCRBY`, `EVAL`), the key
  pattern from the key builder (`price:{sku}`), and `ttl`.
- **Kafka, RabbitMQ or SQS:** producers are `publish` ops and consumers are `consume` ops.
  - Record `topic` (or exchange or queue), `key` (partition or routing key) and `group`.
  - Add a `payload` example built from the message schema (protobuf, Avro, a JSON struct).
- **Endpoints** are inbound: no `target`. Take gRPC methods from `.proto` services
  (`method: orders.v1.Orders/PlaceOrder`, `streaming`) and HTTP routes from router tables (chi, gin,
  Express, FastAPI, Rails). Add the `status` codes the handler returns.
- **Outbound HTTP and gRPC clients** (`kind: http` or `rpc`, `target:` the callee):
  - `calls: <node>/<op>` names the endpoint the client reaches, so a request can be followed across
    services. A `publish` can also name its consumer this way.
  - Timeouts, retries, auth and idempotency go in `facts`.
- **Live numbers:** put `op:` on the flow step that performs each op: the caller's outbound op, or the
  callee's endpoint. Put `op:` on each consumer flow for its consume op.
- **Review** with `strata ops <id>`. Check that every service has its ops, that tables, keys and topics
  are right, and that the ops you care about are named by a flow. Then run `strata validate`.

## Data

Show what the data looks like: `schema:` on database, store and search nodes, `entities:` on the
services that load them, and real numbers on flows. `strata schema` lists the fields.

- **Schemas** come from migrations (`CREATE TABLE`, `ALTER TABLE`, foreign keys, `CREATE INDEX`) or
  ORM models (GORM structs, Prisma schema, SQLAlchemy, ActiveRecord). Foreign keys become `ref`.
  List the indexes the ops' queries use, and make each op's `tables` match the schema.
- **Entities** come from domain structs and the repository code that loads them: the root table, plus
  the tables the load joins in `includes`.
- **Sample rows**, 3-6 per table, come from seed files or test fixtures, or are synthesised
  realistically. Make the ids join across tables.
- **Never copy production rows or real personal data**, even when you can read a real database. Use
  made-up names and `example.com` emails.
- **Volumes** (`rows`, `growth`) come from what the user or the code says (retention jobs,
  partitioning, the user's numbers). Say in the node's `doc` that they are estimates.
- **`traffic:` and `slo:`** on flows come from configs (rate limits, autoscaling targets), dashboards
  the user mentions, or SLO docs. Leave them out rather than invent them.
- **Check** with `strata data <id>`: each table's keys and rows, `unmatched` lines for ids that join
  nothing, and each entity assembled from its first root row. Then run `strata validate`.

## Pressure

`strata analyze <id>` prints what the app's Pressure tab shows:

- per node: slots, hold time, calls/s and utilization;
- per flow: calls per second and per day, its max rate and the node that caps it (the bottleneck);
- a scale plan, the load on each database and cache by op and table, and the blast radius of the
  top bottleneck.

`--rates place-order=120/s,...` asks "what if", and `--json` is for scripts. With `traffic:` on flows
(see [Data](#data)), the scale plan uses `peak` and the per-day numbers use `daily`; the app checks
`slo:` live.

Sanity-check the result against reality before you hand the map over, and tell the user what you found:

- **The bottleneck** should be the component the team knows hurts: the DB pool, a worker count, a
  partner's rate limit. If it isn't, a pool size, replica count or latency is probably wrong. Fix the
  params, not the conclusion.
- **Max rates** should be in the range production has survived. A max far below the real peak means
  the map is too pessimistic, or production is close to falling over: ask.
- **Database pressure** should name the queries the team would call the heavy ones.
- **The simulation agrees:** `strata simulate <id>` at the same rates should show similar utilization.
  The analysis uses means, so heavy tails and timeouts only show up in the simulation.

## Lessons (`kind: sim`)

Use a lesson for a technology or pattern: retries vs timeouts, prefetch, cache stampede, outbox,
consumer lag.

- Small: 3-8 nodes, one level, a `category`, `glossaries:` for the tech.
- 2-4 controls with insights that name the metric that moves (throughput, p99, fairness,
  memory, duplicates) and whether that's good.
- 2-4 scenarios that each prove one point.
- `narration` that says what to watch.

## Gotchas

- Durations need units (`20ms`, not `20`). Probabilities are `0.2` or `20%`.
- `call` targets must be servers. `publish` targets must be `queue` or `topic`. A consumer flow is
  `on: <buffer>` + `by: <consumer>`, with no `rate`.
- Nested `steps` under a `call` run *at the callee*. Order them as the code does.
- A step's `op:` resolves on the calling node first, then on the target. Write `node/op` when both
  have an op with that id.
- A service holds its slot while it waits on downstream calls (thread-per-request). Set
  `async: true` for event-loop servers (Node, Netty, async Rust).
- Keep ids stable once the user has notes on them: node notes live at
  `~/.strata/vault/Sims/<sim>/<node>.md`.

## Notes with live sims

Notes are markdown in `~/.strata/vault/`:

- `[[Note name]]` and `[[sim-id]]` link to notes and sims.
- A fenced block embeds a live simulator:

````markdown
```strata
sim: checkout
view: [orders]        # optional: start inside a deep dive
scenario: db-outage   # optional
```
````
