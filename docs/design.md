# Strata visual language

The feel is a calm, dark lab bench: precise and quiet. Motion only shows where the system is
doing something. Think Linear's restraint, a good oscilloscope, and Obsidian's density.

Use `Theme` (Sources/StrataUI/Theme/Theme.swift) for every colour, font and radius.

## Principles

1. **Motion means work.** Tokens move only along real edges at sim time. Nothing animates for
   decoration. UI chrome animates quickly (`Theme.snappy`). Zooming into a deep dive animates
   gently (`Theme.gentle`).
2. **One accent.** Amber (`Theme.accent`) marks selection, focus and "look here". State uses
   good, bad and warn. Flows use the six token colours. Everything else is greyscale.
3. **Explain in place.**
   - Any term that has a glossary entry gets a faint dotted underline. Hovering it shows the
     card after 300 ms; clicking pins it.
   - Every control shows what changes, as effect chips plus one sentence.
   - Narration appears in a strip at the bottom of the stage.
4. **Right-click everything.** Nodes, edges, the canvas, notes, folders, library cards and tokens
   all have context menus with the useful verbs. Every action is also reachable from ⌘K.
5. **Dense but breathable.** 13 pt UI text, 11 pt labels, 12 pt mono for numbers. Use 8 pt spacing
   steps and hairline borders (`Theme.border`) instead of heavy dividers. Avoid big empty headers.

## Layout

```
┌───────────┬───────────────────────────────────────────────┬──────────────┐
│ sidebar   │ breadcrumbs · toolbar (play ⏸ step speed reset)│ inspector    │
│ (248)     │                                               │ (320)        │
│ ⌘K search │                stage (Canvas)                 │ selected     │
│ Notes     │                                               │ node / flow  │
│  tree     │                                               │ metrics,     │
│ Sims      │  narration strip ─────────────────────────────│ params,      │
│  by cat.  ├───────────────────────────────────────────────┤ actions,     │
│ Maps      │ dock: Controls · Try this · Log · Glossary    │ your note    │
└───────────┴───────────────────────────────────────────────┴──────────────┘
```

- **Sidebar:** sections for Notes (the vault tree), Simulators (grouped by category) and Architecture maps.
- **Inspector and dock:** both collapse (⌘⌥I, ⌘J).
- **Window:** full-size content, transparent titlebar, traffic lights over the sidebar.

## Stage

- **Background:** `Theme.bg` with a faint dot grid (`Theme.grid`) every 24 pt. It pans (drag on
  empty space) and zooms (pinch, ⌘ + scroll, ⌘0 to fit, ⌘+ and ⌘−).
- **Groups:** large rounded regions (radius 16) behind their nodes.
  - Fill white at 2%, a 1 pt border at 6%, and the label top-left in 11 pt muted.
  - `cluster` gets a faint fill; `vpc` and `region` use a dashed border.
- **Nodes:** rounded cards (radius 10), about 168×64, filled `Theme.raised` with a `Theme.border` hairline.
  - Kind symbol in a 28 pt rounded square tinted by role:
    - sources: grey;
    - servers: info blue at 15% fill;
    - databases: teal (token 3);
    - caches: amber (token 5);
    - buffers: violet (token 2);
    - external: grey dashed border.
  - Label in 13 pt semibold and the tech badge in 10 pt mono muted.
  - A live line in 11 pt mono: `3/16 busy · 42/s`, or `depth 120 · lag 30` for buffers.
  - A utilization bar on the bottom edge, 2 pt: green below 0.7, amber below 0.9, red above.
  - **Buffers** draw message slots, small rounded rects coloured by flow (`NodeState.held`), plus `+N` past 12.
  - **Replicas** appear as small dots top-right.
  - **Deep dive:** a small layers glyph bottom-right means double-click to zoom in.
  - **Ops:** a small `6 ops` badge after the tech badge. In a deep dive it also counts the ops of the
    node the level is inside that map to this card. **Formula:** an ƒ badge top-right; hovering it shows the typeset formula.
  - **Hover cards:** one at a time, so none covers another. The ƒ badge shows the formula after 120 ms and
    hides the processes card while the pointer is on it. The rest of a card with process chips shows the
    processes card; the rest of any other card shows its term (300 ms), else its formula.
  - **Processes:** a node whose deep dive runs several processes lists them as chips under the tech
    badge, and its card is 80 pt tall, centred on its row so edges stay level. Clicking a chip dives in.
  - **Down:** desaturated at 40% opacity with a red "down" pill. **Slow:** a snail glyph in amber. **Failing:** red border pulse.
  - **Failure flash:** on `lastFailure` the border flashes red and fades over 0.5 s of sim time.
  - **Selected:** a 1.5 pt amber border plus a soft amber glow. **Hovered:** the border brightens.
  - **Personal note:** a small note glyph when the node has one.
- **Layout:** auto layout (Layout*.swift in StrataCore) places levels in columns by flow: about 260 pt
  per column (wider where labels need room) and 150 pt per row. **Tidy layout** (toolbar wand, ⌘K,
  ⌥⌘L) lays out a `manual` level for the session: cards glide to their places over 0.55 s (none with
  reduced motion) and the view fits. A level opens fitted, but never below 62% zoom: a large map
  opens on its sources at a readable size; ⌘0 fits everything.
- **Edges** (EdgeRouter):
  - Smooth curves at 1.5 pt, `Theme.borderStrong`. An edge leaves the side facing its target,
    crosses each gap between columns with one S-bend (control points mid-gap), and passes other
    columns between their cards, never through one. Edges to a later column leave right and enter
    left; back edges leave left and come back around; edges within a column go straight down, or
    around the side when a card is in the way.
  - Each edge ending on a side gets its own port, level with where it heads when that is on the
    side, so aligned cards connect with a straight line. Edges through the same gap get their own
    tracks, so parallel and opposite edges run side by side.
  - Arrowheads sit on the target's border. The protocol pill sits on the longest straight run (or
    the middle bend) in 10 pt mono on `Theme.overlay`, slid along the edge to clear cards, other
    pills and other lines.
  - **Cut:** a red dashed line with a scissors glyph mid-edge. **Breaker open:** an amber "open" pill.
  - Edge brightness follows `EdgeState.rate`.
- **Tokens:** 7 pt circles in the flow colour with a soft glow (blur 6, 40%).
  - Responses are the same colour, hollow (ring).
  - Messages are small rounded squares. Failures are red with an ×. Orphans are faded rings.
  - With many tokens on one edge, keep 60 fps: draw simple shapes and skip labels while moving fast.
- **Narration:** a strip at the bottom of the stage on `Theme.overlay` at 92%, 13 pt text with
  glossary links, fading in on change.
- **Paused:** a small "Paused" pill top-right.

## Inspector

- **Nothing selected:** the level's narration under "This level". In a deep dive, "Operations of
  orders-svc" comes next: the ops of the node the level is inside, grouped by kind as on that node's
  own level, with a faint line saying how many map to a node here. How it works, Flows and the
  diagram legend follow.
- **A node:** its header, doc, How it works, formula, actions, enums, data, Operations, live metrics,
  code, links, your note and parameters.
- **Operations:**
  - A service lists its own ops by kind: Endpoints, Consumes, Queries, Cache, Publishes and Calls.
  - A database, cache or buffer lists every op that talks to it, by table, key pattern, or producer
    and consumer.
  - In a deep dive, the inherited ops mapped to a database, cache, buffer or port join its list,
    with the owner's name on each row.
  - A process gets a second header, "Operations of orders-svc", for the inherited ops mapped to it
    or to a node it calls. They are grouped by that node (`orders db 6`) and introduced by one faint line.
- **Op rows:** a kind glyph, the label, an R/W badge, the live rate and p99, a risk dot, and a mono
  second line.
  - Hovering a row lights the op's path on the stage and dims the rest. For an inherited op that is
    the steps that name it, else its performer or every edge into its peer.
  - Clicking a row opens the op detail over the inspector; Back or Esc returns.

## Overlays

All overlays are drawn inside the window (see docs/architecture.md, Hidden mode).

- **Context menu:**
  - `Theme.overlay` with a hairline border, radius 8, and a 0 12 32 black-45% shadow.
  - Rows 26 pt, 13 pt text, an SF Symbol at 13 pt in the muted colour, and the shortcut right-aligned in faint.
  - Hover is `Theme.selected` with radius 5. Destructive rows are red. Submenus open to the right on hover.
  - Header rows are 11 pt faint. The menu dismisses on outside click, Escape or scroll.
- **Term card:**
  - 340 pt wide on `Theme.overlay`: term in 13 pt semibold, `short`, then `detail` muted.
  - "In a design" sits in a raised box.
  - When pinned it shows related chips and a close button.
  - It is placed below the anchor, or flips above it, and is clamped to the window.
- **Command palette (⌘K):** centred, 640 wide, with a search field and grouped results (Commands,
  Notes, Simulators, Nodes in the current sim, Glossary). Arrow keys and Return work.
- **Toasts:** bottom centre, a small pill that fades out.

## Notes

- **Width:** the editor column is up to 760 pt wide and centred, in 15 pt text at 1.55 line height.
- **Markdown styling as you type** (Obsidian's live preview, lite):
  - Headings get size and weight, with their `#` marks faint.
  - Inline `code` is mono on raised. Bold and italic are styled.
  - `[[links]]` are accent-coloured and ⌘-clickable.
  - Fenced code blocks are mono on raised. A ```strata block shows a small "live sim ▶" chip.
- **Reading view (⌘E):** rendered markdown, with ```strata blocks as live embedded sims, terms linked, and checkboxes clickable.
- **Inspector:** outline, backlinks, outgoing links, and "Linked sims".
