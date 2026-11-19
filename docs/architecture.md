# Strata architecture

Strata is a hidden, native macOS app for learning systems visually:

- an Obsidian-like notes vault;
- live simulators defined by YAML manifests (docs/manifest.md);
- architecture maps of real projects that you can drill into.

It is Swift 6.3 with SwiftUI and AppKit, built with SwiftPM and the Command Line Tools only (no Xcode).

## Modules

| Target | What | Depends on |
|---|---|---|
| `StrataCore` | model, YAML parser, validation, layout, engine, library, vault, glossary. No UI imports | Foundation |
| `StrataUI` | every view, the theme, overlays, the app model | StrataCore |
| `StrataApp` | the executable: AppKit delegate, hidden windows, hotkey, menu bar, URL scheme | Core, UI |
| `strata` | CLI for agents and scripts: `validate`, `list`, `new`, `open`, `simulate`, `ops`, `data`, `enums`, `analyze`, `how`, `ask`, `drift`, `journey`, `schema`, `paths` | Core |
| `StrataSnapshot` | renders scenes with fixture data to PNG, no screen permission needed | Core, UI |
| `StrataChecks` | assertions, since XCTest is unavailable without Xcode | Core |

```
Sources/StrataCore/
  Model/Manifest.swift        CONTRACT: decoded manifest types
  Model/Operations.swift      op lookups shared by the parser, CLI and UI
  Model/InheritedOps.swift    a deep dive's view of its owner's ops: each mapped to the inner node it talks to
  Model/Data.swift            table, join and entity lookups shared by the parser, CLI and UI
  Model/Enums.swift           enum lookups, lifecycle order, usage, search; EnumOccurrences finds values in text
  Model/Mechanisms.swift      replays a how-it-works mechanism (state after each step) for the validator, CLI and player
  Model/Journeys.swift        journeys as written; JourneyReplay.swift replays one (rows and statuses after each step),
                              JourneyDraft.swift drafts one from flows and transitions, JourneyTime.swift parses `at`
  Model/Components.swift      the processes a node's deep dive runs, listed as chips on its card
  Model/Brief.swift           brief first: the long-text threshold and the automatic short form (validator, CLI, UI)
  Drift/                      compares a map with its repo (docs/manifest.md, Drift): DriftRepo indexes the
                              repo (one lexer pass per Go file), DriftMap collects the map's facts, then
                              DriftCode, DriftSQL, DriftBinaries, DriftMessaging, DriftEnums; DriftCache
                              keeps each map's last result in ~/.strata/drift
  Engine/EngineTypes.swift    CONTRACT: what the engine hands the UI (SimFrame, NodeState, ...)
  Engine/Simulation.swift     engine (public API is the contract)
  Parse/                      YAML subset, manifest decoding + validation, commands, auto-layout, config
  Library/Library.swift       manifest library + live reload
  Terms/TermIndex.swift       glossary packs + auto-linking
  Vault/Vault.swift           notes on disk, links, backlinks, search
  Support/                    Paths, Config, Fixtures, SQLFormat (the op query formatter), JourneyFill (binds into queries),
                              Shortcuts (every shortcut, for the menu, handlers, ⌘K, hints and the sheet),
                              HintPlacement (where a hover hint goes and when it shows)
  Ask/                        Ask the map: digest, prompt, links, claude discovery, runner, stream parser, history
Sources/StrataUI/
  Theme/Theme.swift           CONTRACT: colours, type, radii, motion
  Overlay/Overlays.swift      CONTRACT: in-window menus, term cards, toasts, .onRightClick
  Overlay/Hints.swift         hover hints (.strataHint), selectable text with an in-window Copy
  App/AppModel.swift          CONTRACT: routes, history, sessions, openCode
  Shell/                      RootView, sidebar, home, OverlayHost, command palette, switcher
  Sim/                        SimScreen, stage canvas, inspector, dock, SimEmbedView
  Notes/                      NoteScreen, editor, reading view, NotesTree, SearchScreen
  Graph/                      GraphScreen (force-directed notes + sims)
  Components/                 shared small views (buttons, chips, sparkline, segmented control)
Resources/                    copied into Strata.app/Contents/Resources
  Examples/*.yaml             built-in manifests
  Glossaries/*.json           23 glossary packs (873 terms) exported from StaffForge
  Vault/                      seed notes for a fresh vault
```

## Data on disk

Everything lives under `~/.strata/` (`STRATA_HOME` overrides it):

- `sims/`: user and agent manifests, live-reloaded;
- `vault/`: markdown notes;
- `config.yaml`;
- `state.json`: window and UI state (the open route, each map's vertical/horizontal switch and Links options, and
  the once-only hints already seen).
- `ask/`: Ask history, one JSON Lines file per map (`<id>.jsonl`), and `settings.json` (the in-app
  switch and the maps whose privacy notice was seen). The directory is 0700.
- `drift/<id>.json`: the last drift check of each map, with the repo HEAD it saw and a fingerprint of the
  map file. `strata drift` writes it after a full check of a library map, and so does the app.

Nothing about a work project goes into this repo.

## Ask the map

The dock's Ask tab and `strata ask <id> "question"` answer questions about a map with the user's own
Claude Code CLI, never an API key of Strata's.

- **Finding `claude`.** A GUI app's PATH is minimal, so `ClaudeLocator` tries `ask.claude` from
  config.yaml, then `zsh -lc 'command -v claude'` (then `-lic`, for a PATH set in .zshrc), then the
  installers' locations (`~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin`, `/usr/local/bin`,
  npm, volta, bun, pnpm, nvm). The child gets the login shell's PATH, so a Node-based install finds `node`.
- **The run.** `claude -p --output-format stream-json --verbose --include-partial-messages
  --append-system-prompt <prompt> --tools Read,Grep,Glob --allowedTools Read Grep Glob
  --disallowedTools Bash Edit Write NotebookEdit WebFetch WebSearch Agent Task --strict-mcp-config
  --no-session-persistence --disable-slash-commands [--add-dir <repo>] [--model <ask.model>]`, with the
  message on stdin. The working directory is the map's `repo:` when it is on this machine, else an
  empty temporary directory. No model flag unless `ask: { model: … }` sets one: the user's Claude Code
  default applies. Stop kills the process (SIGTERM, then SIGKILL); 90 s without output or 5 minutes in
  all stops it as timed out.
- **The message.** `AskDigest` renders the whole manifest as compact text with the ids the answer's
  links use: every level, node, op (kind, target, tables, the full query), mechanism (steps with
  commands), enum (values, transitions), table (columns, sample rows), flow, control and scenario. It
  fits a 150 KB budget (about 37k tokens) by tiers that cut the least important detail first (sample
  rows, then long docs and payloads, mechanism steps, queries, and finally op details outside the level
  on screen) and says what it cut; the selected node keeps everything and the level on screen keeps
  one tier more. Then the manifest's path (Claude can Grep it for what was cut), whether the repo is
  on this machine, where the user is, a recent exchange for follow-ups, and the question.
  `strata ask <id> --digest` prints it and sends nothing.
- **Links.** The system prompt teaches `strata:node/…`, `op/…`, `how/…`, `enum/<id>/<value>`,
  `table/…`, `level/…`, `flow/…` and `scenario/…` (AskLinks.swift). Links resolve against the manifest
  (exact path first, then the shallowest level with the id); the UI maps each target to its action
  (SimAskNav.swift), and a link that doesn't resolve renders as plain text.
- **Streaming.** `AskStream` reads stream-json: text deltas append to the answer, a new assistant
  turn after tool use replaces it (the answer is the last turn), tool uses become the status line,
  and the `result` line, exit status, stderr and rate-limit events become a calm failure (not
  installed, not logged in, usage limit, overloaded, timed out) that says what to do.
- **Privacy.** Maps are private work maps. Ask sends the digest and the question to Claude under the
  user's own Claude Code account, and the app says so the first time on each map. "Turn Ask off" in
  the tab, or `ask: { enabled: false }` in config.yaml (which also hides the tab), stops it, and
  `strata ask` honours both. History stays in `~/.strata/ask`. Claude gets read-only tools only, no
  MCP servers, and no saved session.

## Hidden mode

Hidden mode:

- **Out of screen shares.** When screen-share hiding is enabled, Strata sets `sharingType = .none` before AppKit orders any app-owned window on screen. Window sweeps also enforce this setting. macOS owns input method candidate windows, the character palette, and dictation UI, so their visibility is outside Strata's control.
- **Out of the Dock and ⌘-Tab:** the app is an accessory (`LSUIElement`).
- **Summoned:** a global hotkey (Carbon `RegisterEventHotKey`, no Accessibility permission; default ctrl+option+s) and a menu bar item open it.
- **No system popups:** menus, popovers, tooltips (hover hints, Overlay/Hints.swift), the shortcut sheet and sheets are drawn inside the window by `OverlayHost` and `RootView`. Never use `.contextMenu`, `.popover`, `.help`, `.sheet`, `.alert`, `.confirmationDialog`, a menu-style `Picker` or `NSMenu`; a separate system window would show up in a screen share. Selectable text (`.textSelection`) brings the system's text menu on right-click, so use `.strataSelectable` (or a right-click catcher) with it. The menu bar item's own menu is the one exception.

## Time and rendering

- `Simulation` is a discrete-event engine on the main actor. The stage is a SwiftUI `Canvas` inside `TimelineView(.animation)`. Each frame calls `sim.tick(dt)` and then `sim.frame()`, and draws from that.
- Token positions come from sim time, so pausing, speed changes and stepping are exact.
- Tokens are sampled: at most about 12 visible requests per flow per second. Metrics count every request.
- Panels outside the canvas never re-render on a timer, and nothing outside the stage does work on an animation frame.
  - Selection, dock tabs and control values are observed state, so they update on the frame they change.
  - Live numbers (metrics, sparklines, flow stats, scenario steps, the clock) sit in `SimLive` leaves. A leaf re-renders when `sim.revision` changes (a command, a parameter, a log entry, a step) and on each `SimPulse` beat.
  - The stage's frame clock beats the pulse four times a second while the sim plays and the stage is on screen, so nothing refreshes while paused or hidden.
  - Don't wrap panels in `TimelineView(.periodic)`: it rebuilds everything inside it on every tick.
- Stage input goes through the stage's AppKit event layer (`StageEvents`), not SwiftUI gestures:
  - a left mouse down selects at once, with no wait for the double-click interval;
  - the second click of a double-click dives into the node;
  - a drag from empty space pans, and a click on empty space clears the selection on mouse up;
  - the click that activates the window counts too.

## Drift checks

`Drift.check` is read-only, deterministic and synchronous. The app runs it with `Task.detached` at utility
priority (SimDriftState) and never on the main thread. Opening a map reads its cache and compares the HEAD
in `.git` (read from the files, no git process) and the map file's fingerprint. When either changed, the map
is checked again. A repo that isn't on this Mac is noted once in the inspector, and nothing else runs.
`STRATA_DRIFT_TIMING=1` prints the time of each pass to stderr.

## Ownership while agents build in parallel

Each agent works in its own git worktree and branch and owns a set of files. Contract files
(marked `CONTRACT FILE`) belong to the lead:

- If you need a contract change, make it additive (a new field, a new method with a default), keep it minimal, and list it in your report.
- Never rename or remove anything in a contract file.

| Area | Owns |
|---|---|
| manifest | `StrataCore/Parse/*`, `Library/*`, `Terms/*`, `Sources/strata/*`, `StrataChecks/Checks+Parser.swift` |
| engine | `StrataCore/Engine/Simulation.swift` and any new `Engine/*` file, `StrataChecks/Checks+Engine.swift` |
| stage | `StrataUI/Sim/*`, `StrataSnapshot/Scenes+Sim.swift` |
| notes | `StrataCore/Vault/*`, `StrataUI/Notes/*`, `StrataChecks/Checks+Vault.swift`, `StrataSnapshot/Scenes+Notes.swift`, `Resources/Vault/*` |
| shell | `StrataApp/*`, `StrataUI/Shell/*`, `StrataUI/Graph/*`, `StrataUI/Palette/*`, `StrataUI/Components/*`, `StrataSnapshot/Scenes+Shell.swift`, `StrataSnapshot/main.swift`, `Makefile`, `scripts/*` |

Shared rules:

- `swift build` must pass before you report.
- Verify visually with `swift run StrataSnapshot build/snapshots <scene>` and look at the PNG.
- Never launch the real app: it is hidden and runs as an accessory. Never leave processes running.
- Swift 5 language mode, `@MainActor` on UI and engine types, no third-party packages (no network).
