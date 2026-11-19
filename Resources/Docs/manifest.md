# Strata manifest format (v1)

A manifest is one YAML file describing a system you can watch and poke: nodes (services,
databases, queues…), the links between them, the traffic that flows through them, the knobs
you can turn, scripted experiments, and explanations. Strata simulates it live: requests
travel as tokens, queues fill, threads block, retries amplify, breakers trip.

The same format serves two purposes:

- **Lessons** (`kind: sim`): a focused mechanism, such as RabbitMQ prefetch or a cache stampede.
- **Architecture maps** (`kind: architecture`): a real system, such as a project at work. You can
  click into any component to see what's inside, link it to code, and break things to see what happens.

Manifests live in `~/.strata/sims/` (one file per manifest, `<id>.yaml`) and are reloaded live
when they change. Built-in examples ship inside the app. Check a file with
`strata validate <file>` before handing it over, and open it with `strata open <id>`.

```yaml
strata: 1
id: checkout
title: Checkout platform
kind: architecture
summary: How an order travels from the web app to the warehouse.
nodes:
  - { id: web, kind: client, label: Web app, at: [0, 1] }
  - { id: api, kind: gateway, label: API gateway, at: [1, 1] }
  - { id: orders, kind: service, label: orders-svc, tech: Go, at: [2, 1], latency: 30ms, concurrency: 8 }
  - { id: db, kind: database, label: Postgres, at: [3, 0] }
  - { id: events, kind: topic, label: order-events, tech: Kafka, at: [3, 2] }
  - { id: mailer, kind: worker, label: mailer, at: [4, 2] }
edges:
  - { from: web, to: api, protocol: https, latency: 20ms }
  - { from: api, to: orders, protocol: grpc }
  - { from: orders, to: db, protocol: sql }
  - { from: orders, to: events, protocol: kafka }
  - { from: events, to: mailer }
flows:
  - id: place-order
    label: Place order
    from: web
    rate: 5/s
    steps:
      - call: api
        steps:
          - call: orders
            label: POST /orders
            steps:
              - call: db
                label: INSERT order
              - publish: events
                label: OrderPlaced
  - id: email
    label: Confirmation email
    on: events
    by: mailer
    steps:
      - work: 200ms
```

## Syntax

The YAML subset: block mappings and sequences, flow collections `[a, b]` and `{k: v}`, plain,
single- and double-quoted scalars, `|` and `>` block scalars, and `#` comments. No anchors,
aliases, tags, or multi-document streams. A `.json` file with the same structure works too.

| Value | Written as | Notes |
|---|---|---|
| id | `orders-svc`, `db_1` | `[a-z0-9][a-z0-9_-]*`, unique within its list |
| duration | `20ms`, `1.5s`, `2m`, `500us` | the unit is required; a bare number is an error |
| distribution | `20ms` · `fixed 20ms` · `10ms..40ms` · `exp 20ms` · `p50 20ms p99 400ms` | plain = mean with ±25% jitter; `..` = uniform; `exp` = exponential; `p50/p99` = lognormal (heavy tail) |
| rate | `10/s` · `600/min` · `every 2s` · `manual` · `parent` | `/s`: Poisson arrivals. `every`: evenly spaced. `manual`: only when sent. `parent`: see deep dives |
| probability | `0.2` or `20%` | |
| markdown | any string | shown rendered; `` `code` ``, `**bold**`, `[[note or sim id]]` links, glossary terms are auto-linked |

Each flow can generate up to 10,000 requests per second. Each `send` command can start up to
10,000 requests. Validation warns about zero-time publish cycles. At runtime, the simulator pauses
and logs a diagnostic when events keep generating work at the same timestamp or hit the event budget.

## Top level

| Key | Required | Meaning |
|---|---|---|
| `strata` | yes | format version, `1` |
| `id` | yes | unique across the library; the file should be named `<id>.yaml` |
| `title` | yes | display name |
| `kind` | | `sim` (default) or `architecture` |
| `category` | | library section: `messaging`, `network`, `data`, `distributed`, `patterns`, `platform`, `runtime`, `ai`, or any word (company maps often use the company or team name) |
| `summary` | | one or two sentences for the library card |
| `tags` | | list of strings |
| `repo` | | absolute path (or `~/…`) of the code this describes; node `code:` paths are relative to it, and `strata drift` compares the map with it ([Drift](#drift)) |
| `glossaries` | | built-in glossary packs to import: `rabbitmq`, `kafka`, `http`, `grpc`, `postgres`, `postgres-internals`, `clickhouse`, `redis`, `elasticsearch`, `go`, `linux`, `tcp-udp`, `connections`, `cdn-dns`, `kubernetes`, `raft`, `replication`, `consistency`, `resilience`, `scaling`, `queueing`, `cpu-memory`, `llm` |
| `terms` | | local glossary, see [Terms](#terms) |
| `enums` | | value dictionaries such as status codes, see [Enums](#enums) |
| `layout` | | `auto` (default: the layout engine places every node; `at` is a hint) or `manual` (use `at` exactly) |
| `direction` | | `right` (default: flow runs left to right) or `down` (top to bottom); a level's key, so a deep dive can set its own. See [Layout](#layout) |
| `notes` | | long markdown shown in the sim's About tab |
| `links` | | `[{label, url}]`, `[{label, note: "path/in/vault.md"}]`, or `[{label, sim: other-id}]` |
| everything a level has | | `nodes`, `edges`, `groups`, `flows`, `controls`, `scenarios`, `narration`, `direction`. The top level is the root diagram |

### Layout

With `layout: auto` (the default) Strata lays out every level, deep dives and op `inside:` levels
included, as a whiteboard diagram:

- Flow runs left to right along calls, publishes and consumes. Sources and inbound ports start on
  the left; databases, caches and outbound ports end on the right. Stores called by the same
  service share a column.
- Edge crossings are kept low, main flows run straight, and rows keep an even rhythm. Columns widen
  to fit the edge labels between them.
- A group's members stay together, and its region never covers a node from outside it. `parent`
  groups nest.
- Notes go to a free corner.
- Leave out `at`. If you give it, it's a hint: nodes sharing an `at` column prefer one column, and
  the rows order each column. Validation warns about hints the layout can't follow, such as a node
  hinted left of a node that calls it.

`direction: down` turns the layout top to bottom, the way an architecture with a request spine reads:

```yaml
direction: down          # at the top level, or on any inside: level
```

- Layers become rows from top to bottom, and each row runs left to right. Sources and inbound ports
  start the top row; outbound ports end the bottom one.
- **The spine.** The level's main path runs down one straight centre line, and everything else sits
  to its sides. It is the longest chain of nodes that carry the flow (sources, ports, services,
  workers, gateways, queues and topics; not stores or external APIs), heavier flow `rate` winning a
  tie, ending on a node that does the work rather than a queue. A queue on the spine between two
  services of one group sits inside that group's region, so the region runs straight with the spine
  (it is still the group's members that the region is drawn around). Where a straight line can't keep
  clear of a group (the spine would leave a group that goes on beside it), only the part that can
  stays straight.
- A store or external API that only one node calls sits in that node's row, beside it, joined by a
  level edge: a step and what it talks to read at one height. A node keeps at most two this way (one
  each side); with more they fan out in the row below.
- A store or external API called from several rows goes to the bottom row, so shared databases line
  the bottom.
- Edges leave a card's bottom and enter the next row's top with one S-bend; edges back up go around.
  Rows are spaced for the edge labels between them.
- `at` hints read the same way the level runs: the row (`at[1]`) picks the layer and the column
  orders it. Validation warns about a node hinted above a node that calls it.
- Deep dives (`inside:` levels, op `inside:` levels included) run the way their parent runs unless
  they set `direction` themselves. A `detail:` manifest has its own.
- The stage's **vertical/horizontal switch** (toolbar, ⌘K, ⌥⌘V) runs every level of a map the
  other way, overriding `direction`, and the app remembers it per map.

With `layout: manual`, `at` is exact (nodes without one are fitted around the rest). Validation
warns about overlapping nodes, group regions that overlap or cover other nodes, edges whose straight
line runs through another node, and more than three crossing edges. **Tidy layout** (toolbar or ⌘K, ⌥⌘L) lays out a manual level automatically for
the session, using its positions as hints, in the level's `direction` (or the way the switch says). The
switch alone leaves a manual level's positions where they are.

## Levels and deep dives

A **level** is one diagram: `nodes`, `edges`, `groups`, `flows`, `controls`, `scenarios`, and
`narration` (markdown shown when the level opens). The manifest's top level is the root level.
Any node can have its own level inside it:

```yaml
  - id: orders
    kind: service
    label: orders-svc
    inside:
      narration: Inside orders-svc, one request is a handler, a validator, and an outbox write in one transaction.
      nodes:
        - { id: in, kind: port, label: from api-gateway, at: [0, 1] }
        - { id: handler, kind: service, label: HTTP handler, at: [1, 1], latency: 2ms }
        - { id: tx, kind: database, label: orders tx, at: [2, 1] }
      flows:
        - { id: requests, from: in, rate: parent, steps: [ { call: handler, steps: [ { call: tx } ] } ] }
```

- Double-click (or right-click, then **Deep dive**) on a node with `inside:` to zoom into it. Breadcrumbs lead back out.
- `detail: <manifest-id>` opens another manifest as the deep dive instead. Use it for big
  systems: one file per service, linked from the overview.
- Each level is simulated on its own; ids only need to be unique within their level.
- `kind: port` nodes stand for the outside world inside a deep dive (who calls in, what it calls out to).
- `rate: parent` makes a flow follow the measured request rate of the node you drilled into
  (5/s when opened directly).
- **Ops** stay on the node in the overview. Inside, each one maps to the inner node it talks to, and
  inner steps can name it with `op:` ([In a deep dive](#in-a-deep-dive)).
- **Processes.** The `service`, `worker`, `cron` and `function` nodes of an `inside:` level are the
  processes the node runs. Its card lists them as chips (`api · worker · scheduler`, then `+N` when
  they don't fit) and is 16 pt taller. Clicking a chip dives in with that process selected; hovering
  the card lists each with its `tech`, `binary` and `code`. A repo that builds several binaries
  (`cmd/api`, `cmd/worker`, `cmd/scheduler`) is one node with one process node per binary inside.

## Nodes

```yaml
- id: orders            # required
  kind: service         # required, see the table below
  label: orders-svc     # default: the id
  tech: Go 1.27         # small badge
  at: [2, 1]            # grid column and row, fractions allowed. A hint with layout: auto (see Layout), exact with manual
  group: backend        # a group id
  doc: |                # markdown in the inspector
    Owns the order lifecycle...
  term: grpc            # glossary term shown when hovering the node
  code: services/orders # or a list; relative to `repo`, `path:line` allowed
  binary: cmd/orders    # the executable it runs as (a `cmd/*` main package, a Procfile entry)
  icon: shippingbox     # SF Symbol override
  links: [...]
  inside: {...}         # a nested level (deep dive)
  detail: orders-deep   # or another manifest as the deep dive
  actions: [...]        # extra right-click actions, see Actions
  # behaviour, all optional (defaults depend on kind):
  latency: 30ms         # handling time per request or publish (a distribution)
  concurrency: 8        # requests processed at once, per replica (threads, connections, workers)
  replicas: 3
  queue: 100            # waiting room for requests when all slots are busy; beyond it they get 503
  errors: 1%            # probability that handling fails
  timeout: 1s           # default timeout for calls this node makes
  retries: 2            # default retries for calls this node makes
  backoff: 100ms        # first retry delay; doubles each attempt, with jitter
  async: false          # true: an event-loop server that releases its slot while waiting on downstream calls
  # buffers (queue, topic):
  capacity: 10000       # max messages held
  overflow: reject      # reject (publish fails, backpressure) or drop-oldest
  ttl: 30s              # messages older than this expire
  dlq: dead-letters     # node id that receives rejected/expired/poison messages
  # consumers (the `by:` node of a flow with `on:`):
  prefetch: 10          # queue only: unacked messages delivered per replica
  ack: manual           # manual (remove after success) or auto (remove on delivery)
  onError: requeue      # requeue, dlq, or drop (queues); retry, skip, or dlq (topics)
  maxDeliveries: 5      # a message delivered this many times goes to the dlq (or is dropped)
  # caches:
  hitRate: 90%
```

| kind | role | aliases | default latency | default concurrency | default queue |
|---|---|---|---|---|---|
| `client` | source | browser, mobile, app | | | |
| `user` | source | person | | | |
| `cron` | source | scheduler, job | | | |
| `gateway` | server | lb, proxy, ingress, loadbalancer, nginx, envoy | 1ms | 256 | 1000 |
| `service` | server | api, server, microservice | 20ms | 8 | 100 |
| `worker` | server | consumer | 50ms | 4 | 100 |
| `function` | server | lambda, serverless | 30ms | 100 | 0 |
| `database` | server | db, postgres, mysql, sql | 5ms | 20 | 200 |
| `cache` | server | redis, memcached | 0.5ms | 1000 | 1000 |
| `search` | server | elasticsearch, opensearch | 15ms | 16 | 200 |
| `store` | server | s3, blob, bucket, gcs | 30ms | 1000 | 1000 |
| `external` | server | thirdparty, saas, partner | 150ms | 1000 | 1000 |
| `cdn` | server | edge | 5ms | 10000 | 10000 |
| `dns` | server | resolver | 2ms | 1000 | 1000 |
| `llm` | server | model, inference | p50 800ms p99 4s | 4 | 100 |
| `vector` | server | vectordb, embeddings | 10ms | 32 | 200 |
| `port` | server and source | in, out, boundary | 0ms | unlimited | unlimited |
| `queue` | buffer | rabbitmq, sqs, amqp | fixed 0.2ms | | |
| `topic` | buffer | kafka, pubsub, sns, stream, kinesis | fixed 0.2ms | | |
| `note` | annotation | sticky | | | |

Aliases set the kind and, when `tech` is missing, use the alias as the tech badge
(`kind: postgres` becomes a `database` with tech `postgres`).

- **Sources** start flows and have no capacity limits.
- **Servers** accept `call`s.
- **Buffers** accept `publish` and are drained by consumer flows.
- **Notes** are sticky annotations: `doc` is the text. They have no behaviour.

Defaults: `replicas: 1`, `errors: 0`, no timeout, no retries, `backoff: 100ms`, `capacity: 10000`,
`overflow: reject` (queues) or `drop-oldest` (topics), `prefetch: 10`, `ack: manual`,
`onError: requeue` (queues) or `retry` (topics), `hitRate: 90%`.

Explicit limits are 64 replicas, 100,000 concurrency or prefetch per replica, and 1,000,000 for
`capacity` or the `queue` waiting room. Runtime updates above these limits are clamped and logged.

## Operations

Operations are what a node actually does: the queries it runs, the endpoints it serves, the messages
it publishes or consumes, the cache keys it touches. They're the bridge between the diagram and the code.

- The inspector lists a node's operations grouped by kind, and clicking one opens its detail.
- Databases, caches and buffers show the reverse view: every operation on any node of the level
  that targets them, grouped by table, key pattern or topic.
- Inside a deep dive, the ops of the node it is inside map onto the inner nodes they talk to
  ([In a deep dive](#in-a-deep-dive)).

```yaml
- id: orders
  kind: service
  ops:
    - id: create-order              # unique within the node
      kind: http                    # sql | cache | publish | consume | rpc | http | search | storage | llm | call
      label: POST /orders
      method: POST
      path: /orders
      request: '{ "sku": "A-1", "qty": 2 }'
      status: ["201 created", "409 duplicate idempotency key"]
      doc: Validates the cart, writes the order and its outbox row in one transaction.
    - id: insert-order
      kind: sql
      target: db                    # an outbound op names the node it talks to
      label: INSERT order + outbox
      access: write                 # read | write | read-write
      tables: [orders, outbox]
      tx: true
      locks: row
      query: |
        INSERT INTO orders (id, user_id, total) VALUES ($1, $2, $3);
        INSERT INTO outbox (topic, payload) VALUES ('OrderPlaced', $4);
      code: services/orders/repo.go:88
      risks: [hot rows for very large customers]
    - id: price
      kind: cache
      target: cache
      label: GET price
      command: GET
      key: "price:{sku}"
      ttl: 5m
    - id: order-placed
      kind: publish
      target: events
      label: OrderPlaced
      topic: order-events
      key: order_id                 # partition / routing key
      payload: '{ "order_id": "…", "total": 4200 }'
    - id: charge
      kind: rpc
      target: payments
      label: Charge card
      method: payments.v1.Payments/Charge
      streaming: unary
      calls: payments/charge        # the inbound op it reaches on the target ("node/op")
      facts: { deadline: 800ms, idempotent: "yes, by order id" }
```

**Direction.** An op with a `target` is outbound: something this node calls. One without a target
is inbound: an endpoint or RPC method it serves (`http`, `rpc`), or a consumer (`consume`, which
names its buffer in `topic` or `target`). Override with `direction: in|out`.

**Fields by kind.** Every field is optional except `id`, `kind` and `label`. Use the ones that fit the kind:

| Kind | Fields |
|---|---|
| `sql`, `search` | `query`, `tables`, `indexes`, `access`, `tx`, `locks` |
| `cache` (Redis, Valkey, Memcached) | `command`, `key` (pattern), `ttl`, `access` |
| `publish`, `consume` (Kafka, RabbitMQ, SQS, NATS) | `topic`, `key` (partition/routing), `group`, `payload`; `calls` on a publish |
| `rpc` (gRPC, Thrift), `http`, `llm`, `call` | `method`, `path`, `request`, `response`, `streaming` (`unary`, `server`, `client`, `bidi`), `status`, `calls` |
| `storage` (S3, GCS, blob) | `key` (object key pattern), `path`, `method`, `access`, `ttl`, `payload` |
| any kind | `doc`, `code`, `risks`, `tags`, `facts` (a map of extra facts, kept in order), `inside` / `detail` |

**Queries.** `query` is the SQL exactly as the code runs it, copied verbatim from the sqlc `.sql` file,
the ORM call or the raw SQL string: every statement of a transaction, never shortened. Write it as a `|`
block, one clause per line. The op detail formats it anyway (major clauses on their own lines, `AND`
under `WHERE`, subqueries indented, keywords in upper case) and shows each statement of a
multi-statement query as its own numbered block, with `BEGIN` and `COMMIT` as markers. A toggle shows
the query as written. `search` queries that read as SQL are shown the same way; JSON bodies are
re-indented.

`code`, `risks`, `tags`, `tables` and `indexes` take one string or a list. `status` items may be bare
numbers (`[201, 409]`). `payload`, `request` and `response` take text, or a YAML mapping or list that
is shown as JSON. A field another kind uses (`query` on a `publish`) is a warning.

**Going deeper.**

- `calls: node/op` links an outbound call to the endpoint it reaches, so you can follow a request
  through the code: gateway → orders-svc `POST /orders` → `INSERT order + outbox`. On a `publish`,
  it names the `consume` op that handles the message.
- `inside:` gives an op its own level (for example the lock and transaction sequence of a query),
  and `detail:` opens another manifest. In a level path that level is the element `node#op`:
  `view: [orders#insert-order]` in an embed, `?path=orders%23insert-order` in a `strata://sim/` link.
  Inside it, `rate: parent` follows the op's measured rate.

**Live numbers.** A step names the op it performs with `op:`. That counts its rate, errors and
latency on the op:

```yaml
- call: db
  op: insert-order          # resolved on the calling node, then the target; or "orders/insert-order"
```

A step's numbers run from the step's start to its result, retries included. A `work` step counts
its duration, a `parallel` step its slowest branch.

A flow can name an op too, which counts each run of the flow when it finishes, handler failures
included. On a consumer flow, `op:` names the consume op of its `by` node (`op: on-order-placed`),
so every message it handles counts. On a source flow, it names an op of its `from` node.

Validation checks:

- op ids are unique within a node;
- targets exist and fit the kind: `sql` → database or search, `cache` → cache, `publish`/`consume`
  → queue or topic, `rpc`/`http` → a server. An impossible target (a `sql` op on a queue) is an
  error; a questionable one (a `cache` op on a database) is a warning, and so is a target with no edge;
- `calls` and step or flow `op` references resolve (in a deep dive, also on the ops of the node the
  level is inside). It's a warning when they don't line up: `calls` should name an inbound op on the
  target, and a step should name the op it performs (the caller's outbound op to that target, or the
  target's inbound op);
- a `sql` op has a `query`, and the query is whole: a warning names one that looks elided (`...`,
  `…`, `<query>`, `TODO`), and a statement that isn't (a `SELECT` without `FROM` that computes
  nothing, an `UPDATE` without `SET`, an `INSERT` without `INTO`, a description in words);
- an op that no flow or step names is fine. It still documents the code.

`strata ops <file|id>` lists every op per level and node, with the flows that name it. Under each
deep dive it prints how the ops of the node the level is inside map to inner nodes: the peer, the rule
that matched, the process that performs each op, and the flows that name it (`deepDive` in `--json`).

### In a deep dive

Keep a service's ops on the service node in the overview, with `target:` the overview node. Inside
its `inside:` level they are the level's inherited ops. With nothing selected, the inspector lists them
under "Operations of orders-svc", grouped by kind. It also maps each op to the inner node it talks to,
its peer. The rules are tried in this order, and the first that names one node wins:

1. **target**: the op's `target` is an inner node id, or a message's `topic` names an inner queue or topic.
2. **code**: an inner node's `code:` names the op's `code:`. The op's entries are tried in order, each
   with its line and then by file. For an op with a target, a process (service, worker, cron,
   function) with that code is the one that performs it, not its peer. An op without a target (an
   endpoint, a consumer) maps to the process that serves it.
3. **label**: the inner node is labelled like the target, such as a port drawn for that database.
4. **kind**: the inner node is the only one of a kind the op talks to: a database for `sql`, a cache
   or store for `cache` and `storage`, a queue or topic for messages, narrowed by the target's tech
   and name. When the service's ops of that family name several targets, the node must be named like
   this op's target. For `rpc`, `http`, `call` and `llm`, it is the one port or external named like
   the target (`payments API` for `payments`).

An op that no rule matches, such as pure compute or a formula, stays unmapped and is still listed.
Selecting an inner node shows the inherited ops that concern it:

- a database, cache, buffer or port shows the ops mapped to it in its reverse view;
- a process shows the ops mapped to it or to a node it calls.

Each card's ops badge counts the ops mapped to it.

A flow or step `op:` inside the deep dive that resolves on neither the caller nor the target falls back
to the ops of the node the level is inside. `orders/insert-order` works when no inner node has the id
`orders`, and `../insert-order` always works. Naming the op counts its live numbers on this level. It
also lights the step's exact path when you hover the op, where otherwise every edge into its peer
lights:

```yaml
- id: orders
  kind: service
  ops:
    - { id: insert-order, kind: sql, target: db, label: INSERT order, query: "INSERT INTO orders (id) VALUES ($1)", code: repo/orders.go:88 }
  inside:
    nodes:
      - { id: in, kind: port, label: from api-gateway }
      - { id: handler, kind: service, label: HTTP handler }
      - { id: tx, kind: database, label: orders tx }
    edges:
      - { from: in, to: handler }
      - { from: handler, to: tx, protocol: sql }
    flows:
      - id: requests
        from: in
        rate: parent
        steps:
          - call: handler
            steps:
              - { call: tx, op: insert-order }    # orders-svc's op, mapped to tx
```

An op that only one inner node performs can live on that inner node instead.

## Data

Show what the data looks like.

- A database or store node can describe its tables: columns, keys, sample rows and volume.
- A service can name the entities it works with: the domain objects assembled from those tables.

The inspector draws the tables with their foreign keys. Clicking a key value highlights the rows
it joins to, and an entity is shown as the object the code sees, each field coloured by the table
it comes from.

```yaml
- id: db
  kind: postgres
  schema:
    - table: users
      columns:
        - { name: id, type: uuid, pk: true }
        - { name: email, type: text, unique: true }
      rows:
        - [u-42, ada@example.com]
    - table: orders
      doc: One row per checkout.
      columns:
        - { name: id, type: uuid, pk: true }
        - { name: user_id, type: uuid, ref: users.id }
        - { name: status, type: text, note: "pending | paid | shipped" }
        - { name: total_cents, type: bigint }
      indexes: ["orders_user_id_idx (user_id)"]
      rows:
        - [o-9f1c, u-42, paid, 4200]
        - { id: o-77ab, user_id: u-42, status: pending, total_cents: 1999 }   # a map works too
      volume: { rows: 12M, growth: 40k/day }
    - table: order_items
      columns:
        - { name: order_id, type: uuid, ref: orders.id }
        - { name: sku, type: text }
        - { name: qty, type: int }
      rows:
        - [o-9f1c, A-1, 2]
        - [o-9f1c, B-7, 1]
- id: orders
  kind: service
  entities:
    - name: Order
      source: db                 # the database node (default: the one database this node has ops on)
      root: orders
      includes: [order_items, users]
      doc: The aggregate orders-svc loads and saves as one unit.
      code: services/orders/domain/order.go:14
```

- **Columns** take `name` (required), `type`, `pk`, `ref`, `nullable`, `unique` and `note`. `pk` on
  several columns makes a composite key.
- **Rows** are lists in column order, or maps from column name to value. Columns a map leaves out
  are NULL, and so is `null`. A nested mapping or list (a `jsonb` value) is shown as JSON.
- **Sample rows are illustrative.** Make them realistic and make the ids join, but never copy
  production data.
- **`ref`** is `table.column` in the same database node. Use `node.table.column` across nodes.
- **Volumes** use counts with `k`, `M` or `B` suffixes (`12M`). Growth is a count per period
  (`40k/day`, `500/h`, `70k/week`), stored per day.
- **`owner`** names the node that writes the table. It defaults to the nodes whose ops name the table
  in `tables` with write or read-write access.
- **`source`** defaults to the one database, store or search node the entity's node has ops on. With
  several, the one whose schema has the root table.
- **Entities** follow `ref` columns from the root to each included table, in either direction:
  `order_items.order_id → orders.id` makes items children of an order, and `orders.user_id → users.id`
  makes the user its parent. An include can also join through another include (an item's product).
- **Validation**:
  - errors: duplicate tables, columns or entities; a `ref` or `owner` that doesn't resolve; a row
    whose width doesn't match the columns; an entity whose source is missing or isn't a database,
    store or search node, whose root or includes aren't in the source's schema, or whose include
    doesn't join the root through refs;
  - warnings: op `tables` missing from the target's schema when it has one, duplicate primary keys
    in sample rows, and a schema on a node that isn't a database, store or search node.

`strata data <file|id>` prints every table with its keys and sample rows, then each entity assembled
from the first row of its root table.

## How it works

Some nodes and operations implement a mechanism that a diagram can't show: leader election, a
roster with heartbeats, a distributed lock, a rate limiter, sharding, a retry protocol. Describe
it as a **sequence you can play**. Each step is a message between participants, with the exact
command, its reply, and how the state (keys, TTLs, rows) changes. Failure cases are branches.

```yaml
- id: scheduler
  kind: service
  how:
    - id: roster
      title: Roster membership with heartbeats
      summary: |
        Each instance registers itself in a Valkey key with a TTL and renews it twice per TTL.
        An instance whose key expires is dropped from the roster, and its shards are reassigned.
      code: internal/roster/roster.go:40
      participants:
        - { id: a, label: instance A, node: scheduler }
        - { id: b, label: instance B, node: scheduler }
        - { id: v, label: Valkey, node: valkey }
      initial:
        - { key: "roster:members", value: "{}" }
      steps:
        - id: join
          from: a
          to: v
          label: register
          command: "SET roster:inst:a 1 NX PX 15000"
          reply: OK
          at: 0s
          state: [ { key: "roster:inst:a", value: "1", ttl: 15s } ]
          code: internal/roster/roster.go:52
        - { id: hb1, from: a, to: v, label: heartbeat 1, command: "PEXPIRE roster:inst:a 15000", reply: "1", at: 5s,
            state: [ { key: "roster:inst:a", value: "1", ttl: 15s } ] }
        - { id: hb2, from: a, to: v, label: heartbeat 2, command: "PEXPIRE roster:inst:a 15000", reply: "1", at: 10s,
            note: "Two heartbeats per TTL: one lost heartbeat never drops a healthy member." }
      branches:
        - id: crash
          label: A crashes
          after: hb1
          steps:
            - { id: expire, from: v, to: v, label: key expires, at: 20s, state: [ { key: "roster:inst:a", value: null } ] }
            - { id: take, from: b, to: v, label: B sees A gone and takes its shards, command: "SCAN 0 MATCH roster:inst:*" }
```

- Steps play in order and branches leave the main sequence after the step named in `after`.
- `from: v, to: v` is a self-step: an expiry, a timer, internal work.
- `at` builds a timeline, `command` and `reply` are shown verbatim, and `state` changes the
  state panel. `value: null` deletes a key, and `ttl` counts down while playing.
- `code:` on a step (one path or a list) says where the code takes it; the step detail links it.
- Write commands and replies in full: the diagram shortens them to one line (a long Valkey key is cut
  in the middle), and clicking a step opens its detail with everything: the SQL formatted one clause
  per line, a Valkey command split into verb, keys and arguments, the reply, every state change and
  the note.
- Participants with `node:` link to the diagram.
- An operation can have `how:` too.
- Step `id`s default to `s1`, `s2`, … (`<branch>-s1`, … in a branch). Validation checks that participants
  are unique, `from`, `to` and `node` resolve, `after` names a main step, and (a warning) that `at` never
  goes back in time.

`strata how <file|id> [--mechanism id] [--branch id]` prints a mechanism as a numbered transcript: time,
from → to, label, command → reply, and the state after each step with TTLs aged by `at`.

## Formulas

A node or operation that computes something gets a `formula`, shown on hover and in the inspector.

```yaml
- id: ranker
  kind: service
  formula:
    expr: "score = w_r · e^(−age / τ) + w_c · ctr − p · spam"
    where:
      w_r: weight of recency (0.6)
      τ: half-life of a post in hours (6)
      ctr: click-through rate over the last 24 h
      p: spam penalty (0.9)
    example: "age 3 h, ctr 0.04, not spam → 0.6 · e^(−0.5) + 0.4 · 0.04 = 0.38"
    code: internal/rank/score.go:22
```

`expr` is typeset: variables in italics, `e`, `log`, `min`, `max`, `argmax` and friends upright, `w_r` and
`x_(i,j)` as subscripts, `e^x` and `e^(…)` as superscripts, `(a / b)` as a stacked fraction, Greek letters
written as `τ` or `tau`, and `*`, `-`, `<=`, `>=`, `!=`, `->` as `·`, `−`, `≤`, `≥`, `≠`, `→`. Anything it can't
read is shown as written, in mono. Each `where` key should appear in `expr` (a warning otherwise).

## Enums

Status codes and other value dictionaries, with their meaning and the allowed transitions.

```yaml
enums:
  - id: campaign-status
    label: Campaign status
    doc: Stored as an integer in campaigns.status.
    code: internal/campaign/status.go:8
    values:
      - { value: 3100, name: draft }
      - { value: 3200, name: scheduled, doc: Waiting for start_at. }
      - { value: 3300, name: running }
      - { value: 3400, name: paused }
      - { value: 3900, name: finished, terminal: true }
    transitions:
      - { from: 3100, to: 3200, label: schedule, by: campaigns/schedule }
      - { from: 3200, to: 3300, label: start_at reached, by: scheduler }
      - { from: 3300, to: 3400, label: pause }
      - { from: 3400, to: 3300, label: resume }
      - { from: 3300, to: 3900, label: budget spent or end_at }
```

- A column points at an enum with `enum: campaign-status`. Its sample values then show their names.
- Values are numbers or strings, kept as written: `3200` in a value, a transition, a sample row and
  a query are the same value. `name` is required; `label` defaults to the id.
- Wherever a value of a linked column appears (sample rows, queries, payloads), hovering it shows
  its meaning. Strata finds `status = 3200`, `status IN (3100, 3200)`, `SET status = 3300`,
  `INSERT INTO campaigns (…, status) VALUES (…, 3100)` and `"status": 3200`, using the tables the
  statement or the op names, and the enclosing JSON key (`"payment": { "status": … }` → `payments`).
  A payload may carry the name instead of the code (`"status": "scheduled"`).
- Clicking a value opens the enum: its values and the transitions drawn as a state machine.
- ⌘K finds an enum by value (`3200`), by name (`scheduled`) or by label (`campaign status`).
- **Validation**:
  - errors: duplicate enum ids or values, a transition `from` or `to` that isn't a value, a `by`
    that doesn't name a node or `node/op` on any level, and a column `enum` that doesn't exist;
  - warnings: sample rows in a linked column holding values the enum doesn't have, a terminal value
    with a transition out of it, and duplicate names.

`strata enums <file|id> [--find <text>]` prints each enum's values and transitions
(`3100 draft → 3200 scheduled (schedule, by campaigns/schedule)`), the columns linked to it and the
ops that use it.

## Drift

Maps rot as the code moves on. `strata drift <file|id>` compares a map with the code at its `repo:` (or
`--repo PATH`) and lists what no longer matches, so you can trust the map or have your agent refresh
exactly the stale parts. It only reads the repo. It skips `vendor/`, `node_modules/`, `.git/` and other
hidden dirs, build output, `testdata/`, generated code (`Code generated … DO NOT EDIT`) and files over 1 MB.

| Kind | Compares | Reports |
|---|---|---|
| `code` | every `code:` (nodes, ops, mechanisms, steps, formulas, entities, enums). Where the context names a symbol (a sqlc `-- name:`, a symbol written after the path, a `` `Acquire()` `` in the doc), the line must still be at it | a missing file (error, with where it went: a file of the same name, or where its symbols are defined now); a line past the end; a line that moved off its symbol |
| `sql` | each op's `query`: by sqlc `-- name:` in `.sql` files, otherwise by normalised text in the op's `code:` file, then in any `.sql` file or SQL string in Go (`"…" + "…"` joined) | a changed query (with a diff), a renamed one, a missing one; repo queries no op has, by file (sqlc ones are warnings, raw strings notes) |
| `binaries` | `binary:` against Go `main` packages, Procfile entries and Dockerfile commands. `binary: "tool start worker"` checks the tool and each subcommand (cobra `Use:`, kingpin `Command`, urfave `Name:`, an `os.Args` switch) | a binary or subcommand that is gone; `cmd/*` mains and Procfile entries no node runs; subcommands declared next to mapped ones |
| `messaging` | `topic`, `group` and `key` of publish and consume ops, and cache `key` patterns, against names in Go: broker calls (`QueueDeclare`, `ExchangeDeclare`, `QueueBind`, `Consume`, `Publish…`, NATS `Subscribe`, `Topic:` fields), constants named like queues or topics, Valkey and Redis key strings (`app:lock:%s` matches `app:lock:{name}`) | names the repo has that the map doesn't mention; names the map has that no string in the repo contains |
| `enums` | each `enums:` entry against the definition with its values: a Go const block (explicit or `iota`), typed consts, a Postgres `CREATE TYPE … AS ENUM` (and `ADD VALUE`), a `CHECK (col IN (…))`. Its `code:` picks the block | values added in the code, values gone, and values renamed (when the map's names follow the code's) |

- **SQL is normalised.** Comments, whitespace and keyword case don't count. `?`, `$1`, `:name`, `@name` and
  `sqlc.arg(x)` are the same placeholder, and `BEGIN`/`COMMIT` are dropped. An example value where the code
  has a placeholder still matches (`id IN (101, 102)` for `sqlc.slice(ids)`), but a literal that differs
  from the code's is a change.
- **Severity.** An error means the map points at something that is gone. A warning means something
  changed, or the repo has something the map should show. A note is a heuristic worth a look.
- **Freshness** is the share of checked map facts with no error or warning. Notes and repo items that
  aren't on the map don't lower it.
- **Output.** Findings are grouped by kind, and the same finding on several nodes prints once.
  - `--json` gives each finding its map location (level path, node, op, mechanism, step, manifest line),
    repo location, message, fix and diff: the input for a refresh.
  - `--kind code,sql` checks only those kinds, and `--quiet` prints one line.
  - Exit 0 when nothing drifted (notes alone don't count), 1 with errors or warnings, 2 when it can't
    check (no `repo:`, a repo that isn't on this machine, an unknown manifest).
- **In the app.** The last result per map is kept in `~/.strata/drift/<id>.json`, with the repo HEAD and a
  fingerprint of the map file. Opening a map checks again in the background when either changed;
  ⌘K "Check drift against the repo" runs a check now. Stale nodes get a small mark, and the inspector
  lists the findings.

## Edges

```yaml
- from: api
  to: orders
  label: gRPC           # pill on the line
  protocol: grpc        # badge: http, https, grpc, tcp, udp, amqp, kafka, sql, redis, ...
  latency: 2ms          # one-way network delay (default 1ms)
  loss: 0%              # probability a message on this link is dropped silently
```

Requests travel `from → to` and responses come back on the same edge. If a flow calls between
two nodes that have no edge, Strata draws one and `strata validate` warns. Consumer flows draw
`buffer → consumer` automatically.

## Groups

```yaml
groups:
  - { id: backend, label: Backend (EKS), kind: cluster }
```

`kind` is `cluster`, `vpc`, `region`, `zone`, `team`, or `boundary` (the default). A group is drawn as a
labelled region around its member nodes (`group: backend` on each node). `parent: <group>` nests groups.

## Flows

A flow is a kind of traffic. Either it starts at a source (`from:`) at some `rate`, or it consumes
messages from a buffer (`on:` + `by:`).

```yaml
flows:
  - id: place-order
    label: Place order
    from: web             # a source (or port) node
    rate: 20/s
    color: 2              # token colour 1-6 (default: by order)
    deadline: 3s          # the client gives up after this, end to end
    steps: [...]          # run at `from`
  - id: email
    on: order-events      # a queue or topic
    by: mailer            # the consumer node; its replicas x concurrency handle messages in parallel
    steps: [...]          # run at `by` for each message
```

### Steps

Steps run in order at the current node. A step fails its parent unless it is `optional: true`.

```yaml
- call: orders            # synchronous request/response to a server node
  label: POST /orders     # shown on the token and in the log
  say: Narration for the first visible token that runs this step.
  timeout: 1s             # caller gives up (overrides the caller node's timeout)
  retries: 2              # on failure or timeout (overrides the caller node's retries)
  backoff: 50ms
  breaker: { failures: 5, cooldown: 5s }   # circuit breaker on this call
  optional: true          # a failure here doesn't fail the parent
  p: 30%                  # the step runs only 30% of the time
  steps: [...]            # nested steps, run AT orders while it holds its slot
  miss: [...]             # only for calls to a cache: steps run at the caller on a miss (1 - hitRate)
- publish: order-events   # put a message into a queue/topic; doesn't wait for consumers
  label: OrderPlaced
- work: 15ms              # extra processing at the current node (a distribution)
- parallel:               # run these at the same time; continue when all finish
    - call: inventory
    - call: pricing
```

What happens on a `call`:

1. The request crosses the edge, taking its latency.
   - If the target is **down**, it fails fast ("connection refused").
   - If the link is **cut**, the request is lost silently and the caller waits for its timeout,
     or forever if there is none.
2. The target takes a slot: one of `concurrency × replicas`, using the least busy replica. If none is
   free, the request waits in the node's queue. A full queue rejects it at once (503).
3. The target works for `latency`, multiplied by its slow factor, then runs the nested `steps`.
   Unless the node is `async`, it holds its slot while it waits on downstream calls. This is why a
   slow database exhausts the thread pools of every service above it.
4. With probability `errors` the handling fails (500). Otherwise it succeeds. The slot is released
   and the response crosses back.
5. A caller that times out moves on (retry or fail). The target keeps working anyway: wasted work,
   and its late response is drawn as a faded orphan.
6. Retries wait `backoff × 2^attempt` (±50% jitter). Each attempt is real load on the target.
7. A breaker opens after `failures` consecutive failures. During `cooldown`, it rejects calls
   immediately ("breaker open") without using the caller's retry budget. After that one trial call
   is let through: success closes the breaker, failure opens it again.

Messages (`publish` and consumer flows):

- **Queues** use competing consumers. The broker pushes ready messages to consumer replicas that
  have fewer than `prefetch` unacked (round-robin). A replica handles up to `concurrency` messages
  at once.
  - With `ack: manual`, a message is removed only after its steps succeed. On failure it is
    requeued, dead-lettered, or dropped, as `onError` says. When a consumer dies, its unacked
    messages go back to the queue.
  - With `ack: auto`, a message is removed on delivery and prefetch doesn't apply, so a crash
    loses whatever was delivered.
- **Topics** keep messages, up to `capacity`. Every consumer flow (`by:` node) is a separate
  consumer group with its own offset, so each group gets every message. Its lag is the number of
  messages it hasn't processed yet. On failure it retries in place, skips, or dead-letters, per
  `onError`. A group that reaches `maxDeliveries` while retrying advances past the message and
  sends it to the configured DLQ, or drops it if no DLQ is available.
- `ttl` expires old messages and `dlq` receives expired messages. Queue messages can expire
  while traveling to a consumer or waiting in its inbox. Once a handler starts, it runs to
  completion even if the TTL elapses. A failed message that is past its TTL expires if it would
  return to the queue.
- Publishing to a down buffer or one at capacity with `overflow: reject` fails the publish step.
  With `drop-oldest`, a queue can evict ready messages. It rejects a publish if deliveries have
  reserved all of its capacity.
- A buffer spends its own `latency × slow` handling a publish after it crosses the producer's
  edge. With probability `errors`, ingress fails without storing the message. The publisher waits
  for ingress to complete. Consumers run independently.

## Traffic, SLOs and pressure

Flows can carry the real numbers you know from production. The Pressure tab compares them with the simulation.

```yaml
flows:
  - id: place-order
    from: web
    rate: 20/s                     # what the simulation runs
    traffic: { peak: 120/s, daily: 4M }
    slo: { p99: 300ms, errors: 0.1% }
```

- `traffic.peak` is the busiest rate (`120/s`, `7200/min`, `12k/s`), with no simulation limit.
  `traffic.daily` is a count per day (`4M`).
- `slo.p50` and `slo.p99` are durations. `slo.errors` is the highest acceptable error ratio (`0.1%`).
- A peak below the simulated `rate` is fine. Validation warns when `daily` is less than one minute
  of peak traffic or more than a whole day of it, when `p50` is above `p99`, and when `p99` is longer
  than the flow's `deadline`.

The **Pressure** tab answers where the architecture hurts. It combines a static capacity analysis
of the level with live culprits from the running simulation.

- **Capacity.**
  - Each node has `slots = concurrency × replicas`.
  - A request *holds* a slot for its own latency. Unless the node is `async`, it also holds it for
    every downstream call it waits on: network both ways plus the callee's hold time, retries
    included.
  - *Visits* per request come from the flow steps, with `p`, cache `miss` probability and retries
    counted.
  - Demand is `Σ rate × visits × hold time` busy slots, and utilization is `demand / slots`.
  - A flow saturates at the rate where its first node reaches 100%. That node is its **bottleneck**.
- **What to scale.** Scale the bottleneck until it stops being one. The tab shows the replicas
  needed, the new max rate, and the next bottleneck, repeated up to a few steps.
- **Backpressure and blast radius.** Slowness travels *up* synchronous call chains, because
  callers hold their slots while they wait, so they saturate next. It stops at queues and topics,
  where it becomes depth and consumer lag downstream. Selecting a node shows its blast radius on the stage.
- **Database pressure.** For every database, cache and search node: which ops from which nodes
  use its busy time (rate × hold time), split into reads and writes and grouped by table.
- **Volumes.** Calls per second and per day for flows and ops. `traffic.daily` wins when it is declared.
- **Culprits (live).** Saturated nodes, growing queues, rising lag, timeouts, error bursts, open
  breakers, down nodes and SLO breaches, worst first. Each one links to its node or flow.

## Controls

Knobs shown under the stage. Each one binds to a parameter and can explain what changes.

```yaml
controls:
  - label: Checkout traffic
    bind: place-order.rate        # <flow>.rate | <node>.<param> | <from>-><to>.latency|loss
    min: 0
    max: 200
    step: 5
    unit: /s
  - label: Mailer prefetch
    bind: mailer.prefetch
    options: [1, 10, 50]
    term: prefetch
    insights:
      - when: "== 1"
        text: Fair dispatch, but every message waits for a round trip.
        effects:
          - { metric: throughput, dir: down, good: false }
          - { metric: fairness, dir: up, good: true }
      - when: "> 1"
        text: Messages wait in the consumer's buffer, so the round trip is hidden.
        effects: [ { metric: throughput, dir: up, good: true } ]
  - label: Ack mode
    bind: mailer.ack
    options: [manual, auto]
```

- A control is `min`/`max`/`step` (a slider), `options` (a segmented picker), or a toggle if the
  parameter is boolean.
- Bindable node parameters are everything under "behaviour" above, plus `up` (true/false) and
  `slow` (a factor).
- `insights` are checked in order and the first matching `when` is shown under the control.
  - `when` is one of: `"< 5"`, `"<= 5"`, `"> 5"`, `">= 5"`, `"== manual"` (or just `manual`),
    `"1..10"`, `true`/`false`. No `when` means "otherwise".
  - Each effect has `dir: up|down|flat`, and `good: true|false`; leave `good` out when it's a trade-off.

## Commands

Actions and scenarios change a running simulation with one-line commands:

| Command | Effect |
|---|---|
| `kill <node>` / `restore <node>` | take a node down: it refuses new work and its in-flight work fails. `restore` also clears slow and fail |
| `slow <node> <factor>` | multiply its latency (`slow db 10`; `slow db 1` is normal) |
| `fail <node> <prob>` | set its error probability (`fail payments 50%`) |
| `scale <node> <n>` | set replicas (`scale orders 4`, `scale orders +1`) |
| `set <node>.<param> <value>` | any node parameter (`set mailer.prefetch 1`) |
| `rate <flow> <rate>` | change a flow's rate (`rate place-order 50/s`) |
| `send <flow> [n]` | fire n requests now (default 1) |
| `cut <a> <b>` / `heal <a> <b>` | partition the link between two nodes (both directions) |
| `delay <a> <b> <duration>` | add latency per traversal of the declared `a → b` edge (`0ms` clears) |
| `redirect <node> <other>` / `unredirect <node>` | calls and publishes to `node` go to `other` (failover, promotion) |
| `purge <buffer>` | drop every ready message |
| `say <text>` | show narration |
| `pause` | pause the simulation |

## Actions

Extra entries in a node's right-click menu, on top of the built-in ones: deep dive, kill/restore,
slow, inject errors, scale, send, open note, open code.

```yaml
actions:
  - label: Promote replica
    icon: arrow.up.circle
    do: [ "kill db", "redirect db db-replica", "say The replica is now primary; writes resume." ]
```

## Scenarios

Guided experiments ("Try this"). They are applied after a reset, and their steps run at sim times.

```yaml
scenarios:
  - id: db-outage
    label: Postgres goes down
    goal: What happens to checkout when the database disappears for five seconds?
    setup: [ "rate place-order 20/s" ]
    steps:
      - { at: 2s, do: "kill db", say: "Postgres is gone. Watch orders-svc's threads fill up." }
      - { at: 7s, do: "restore db", say: "Back. How long until the backlog drains?" }
    watch: [ orders.inflight, place-order.errors ]
```

`watch` highlights metrics: `<node>.inflight|queued|util|throughput|errors|p50|p99|depth|lag`
and `<flow>.rate|ok|errors|p50|p99|retries`.

## Terms

The glossary behind the hover cards. Words in any markdown text are linked automatically.

```yaml
terms:
  - id: outbox
    term: Transactional outbox
    short: Write the event to an outbox table in the same transaction as the data, and publish it later.
    detail: A relay process polls the table (or tails the WAL) and publishes each row, so an event is never lost or sent for data that was rolled back.
    design: Use it when a service must update its database and emit an event atomically.
    match: [outbox, outbox table]
    related: [cdc, idempotency]
```

Lookup order for `term:` and links: local `terms`, then each pack in `glossaries`, in order.
`pack/id` (for example `rabbitmq/prefetch`) names a pack explicitly.

## Embedding in notes

In a note, a fenced block opens a live sim right where it is written:

````markdown
```strata
sim: checkout          # a library id
view: [orders]         # optional: start inside these nodes
scenario: db-outage    # optional: start this scenario
height: 420
```
````

A fenced block that has `nodes:` is a whole inline manifest (`strata`, `id`, and `title` are optional
there), which suits small diagrams that belong to one note.
