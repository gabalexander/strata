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
| `repo` | | absolute path (or `~/…`) of the code this describes; node `code:` paths are relative to it |
| `glossaries` | | built-in glossary packs to import: `rabbitmq`, `kafka`, `http`, `grpc`, `postgres`, `postgres-internals`, `clickhouse`, `redis`, `elasticsearch`, `go`, `linux`, `tcp-udp`, `connections`, `cdn-dns`, `kubernetes`, `raft`, `replication`, `consistency`, `resilience`, `scaling`, `queueing`, `cpu-memory`, `llm` |
| `terms` | | local glossary, see [Terms](#terms) |
| `notes` | | long markdown shown in the sim's About tab |
| `links` | | `[{label, url}]`, `[{label, note: "path/in/vault.md"}]`, or `[{label, sim: other-id}]` |
| everything a level has | | `nodes`, `edges`, `groups`, `flows`, `controls`, `scenarios`, `narration`. The top level is the root diagram |

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

## Nodes

```yaml
- id: orders            # required
  kind: service         # required, see the table below
  label: orders-svc     # default: the id
  tech: Go 1.27         # small badge
  at: [2, 1]            # grid column and row; fractions allowed. Omit everywhere for automatic layout
  group: backend        # a group id
  doc: |                # markdown in the inspector
    Owns the order lifecycle...
  term: grpc            # glossary term shown when hovering the node
  code: services/orders # or a list; relative to `repo`, `path:line` allowed
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
- `calls` and step or flow `op` references resolve. It's a warning when they don't line up: `calls`
  should name an inbound op on the target, and a step should name the op it performs (the caller's
  outbound op to that target, or the target's inbound op);
- an op that no flow or step names is fine. It still documents the code.

`strata ops <file|id>` lists every op per level and node, with the flows that name it.

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
