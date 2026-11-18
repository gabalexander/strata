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
| `strata` | CLI for agents and scripts: `validate`, `list`, `new`, `open`, `schema`, `paths` | Core |
| `StrataSnapshot` | renders scenes with fixture data to PNG, no screen permission needed | Core, UI |
| `StrataChecks` | assertions, since XCTest is unavailable without Xcode | Core |

```
Sources/StrataCore/
  Model/Manifest.swift        CONTRACT: decoded manifest types
  Engine/EngineTypes.swift    CONTRACT: what the engine hands the UI (SimFrame, NodeState, ...)
  Engine/Simulation.swift     engine (public API is the contract)
  Parse/                      YAML subset, manifest decoding + validation, commands, auto-layout, config
  Library/Library.swift       manifest library + live reload
  Terms/TermIndex.swift       glossary packs + auto-linking
  Vault/Vault.swift           notes on disk, links, backlinks, search
  Support/                    Paths, Config, Fixtures
Sources/StrataUI/
  Theme/Theme.swift           CONTRACT: colours, type, radii, motion
  Overlay/Overlays.swift      CONTRACT: in-window menus, term cards, toasts, .onRightClick
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
- `state.json`: window and UI state.

Nothing about a work project goes into this repo.

## Hidden mode

Hidden mode:

- **Out of screen shares.** When screen-share hiding is enabled, Strata sets `sharingType = .none` before AppKit orders any app-owned window on screen. Window sweeps also enforce this setting. macOS owns input method candidate windows, the character palette, and dictation UI, so their visibility is outside Strata's control.
- **Out of the Dock and ⌘-Tab:** the app is an accessory (`LSUIElement`).
- **Summoned:** a global hotkey (Carbon `RegisterEventHotKey`, no Accessibility permission; default ctrl+option+s) and a menu bar item open it.
- **No system popups:** menus, popovers, tooltips and sheets are drawn inside the window by `OverlayHost`. Never use `.contextMenu`, `.popover`, `.help`, `.sheet`, `.alert` or `NSMenu`; a separate system window would show up in a screen share. The menu bar item's own menu is the one exception.

## Time and rendering

- `Simulation` is a discrete-event engine on the main actor. The stage is a SwiftUI `Canvas` inside `TimelineView(.animation)`. Each frame calls `sim.tick(dt)` and then `sim.frame()`, and draws from that.
- Token positions come from sim time, so pausing, speed changes and stepping are exact.
- Tokens are sampled: at most about 12 visible requests per flow per second. Metrics count every request.
- Panels outside the canvas refresh from `TimelineView(.periodic(by: 0.25))`, or when `sim.revision` changes.

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
