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
