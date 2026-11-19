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
   - **Brief first, detail on demand.** A node, op, flow, mechanism or level shows its one-line `brief`
     in the text colour; without one, a long doc, narration, summary or step note shows its first
     sentence, two lines at most, ending in an ellipsis (docs/manifest.md, Briefs). The rest waits
     behind a quiet **More ⌄** (11 pt, faint, accent on hover) on its own line, which opens the text in
     place (a brief stays above it, a first sentence gives way to the whole text) and turns into
     **Less ⌃**. What is open is remembered per item for the session. A text that is already short
     shows as it is, with no disclosure. Glossary terms and links work in both forms.
   - Narration appears in a strip at the bottom of the stage: a scenario's narration, else the level's
     brief or its narration's first sentence.
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
│ Maps      │ dock: Controls · Try this · Log · Glossary·Ask│ your note    │
└───────────┴───────────────────────────────────────────────┴──────────────┘
```

- **Sidebar:** sections for Notes (the vault tree), Simulators (grouped by category) and Architecture maps.
- **Inspector and dock:** both collapse (⌥⌘I, ⌘J). The dock's tabs show their icons alone when the labels
  don't fit, each still named by its hint.
- **Toolbar:** breadcrumbs, the clock and transport, then the layout group (Tidy layout, the vertical switch,
  Links), a hairline, and the panel toggles (Show dock, the inspector). Every icon has a hint with its shortcut.
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
    processes card, each process with its brief (two lines at most); the rest of any other card shows its
    term (300 ms), else its formula, else a term-style card with its label and brief.
  - **Processes:** a node whose deep dive runs several processes lists them as chips under the tech
    badge, and its card is 80 pt tall, centred on its row so edges stay level. Clicking a chip dives in.
  - **Down:** desaturated at 40% opacity with a red "down" pill. **Slow:** a snail glyph in amber. **Failing:** red border pulse.
  - **Failure flash:** on `lastFailure` the border flashes red and fades over 0.5 s of sim time.
  - **Selected:** a 1.5 pt amber border plus a soft amber glow. **Hovered:** the border brightens.
  - **Personal note:** a small note glyph when the node has one.
  - **Glyph hints:** the small glyphs (the ops badge, the deep-dive layers, the note, drift, slow and down marks,
    the replica dots) each explain themselves with a hint above them (Hints, below), and while the pointer is on
    one the card's own hover card stays away. The ƒ badge's formula card and the process chips' processes card
    are their explanations.
  - **Drift:** a node the last drift check found stale (an error or warning on it, its ops, or inside its deep
    dive) gets a small sync glyph (`arrow.triangle.2.circlepath`, 10 pt, warn at 85%) beside the status
    glyphs top-right. There is no count and the card itself doesn't change colour: the details are in the inspector.
- **Layout:** auto layout (Layout*.swift in StrataCore) places levels in columns by flow: about 260 pt
  per column (wider where labels need room) and 150 pt per row. **Tidy layout** (toolbar wand, ⌘K,
  ⌥⌘L) lays out a `manual` level for the session: cards glide to their places over 0.55 s (none with
  reduced motion) and the view fits. A level opens fitted, but never below 62% zoom: a large map
  opens on its sources at a readable size (on the left, or at the top of a vertical map); ⌘0 fits everything.
- **Top to bottom:** `direction: down` (Layout+Down.swift) runs the same layered layout in a transposed
  frame. Layers become rows; cards stay landscape, so the spacing differs by axis: 56 pt between
  cards in a row (wider where a side edge's label sits) and at least 64 pt between rows, more for the
  pills that stack there, for group bands, and for long sideways S-bends. A store or API with one
  caller sits beside it in its row; stores shared across rows line the bottom row.
- **Spine:** top to bottom, the main path (Layout+Spine.swift) is one straight column: the longest
  chain through the flow's sources, services and queues, ties broken by flow rate. It is one
  Brandes–Köpf block in every alignment, nothing aligns across it, it moves as one in the group solver,
  and ordering keeps every group on one side of it. A queue between two members of a group on the
  spine joins that group for layout, so the group's region runs straight through it.
- **Vertical/horizontal switch:** the toolbar's arrow-down button (lit while the map runs top to
  bottom), ⌘K and ⌥⌘V run every level of the current map the other way, overriding the manifest's
  `direction`. Cards glide like Tidy layout and the view fits; the choice is saved per map in
  `~/.strata/state.json`. A manual level keeps its positions until Tidy layout, which then runs the
  chosen way.
- **Edges** (EdgeRouter):
  - Smooth curves at 1.5 pt, `Theme.borderStrong`. An edge leaves the side facing its target,
    crosses each gap between columns with one S-bend (control points mid-gap), and passes other
    columns between their cards, never through one. Edges to a later column leave right and enter
    left; back edges leave left and come back around; edges within a column go straight down, or
    around the side when a card is in the way.
  - Top to bottom, the router works on the transposed stage: edges leave a card's bottom and enter
    the next row's top with one S-bend mid-gap, pass other rows between their cards, back edges leave
    the top and come back around, and edges within a row (a side node's) run straight sideways. Pills
    stay horizontal text, placed after transposing back. A group's label slides along its top band
    to a spot no edge crosses.
  - Each edge ending on a side gets its own port, level with where it heads when that is on the
    side, so aligned cards connect with a straight line. Edges through the same gap get their own
    tracks, so parallel and opposite edges run side by side.
  - Arrowheads sit on the target's border. The protocol pill sits on the longest straight run (or
    the middle bend) in 10 pt mono on `Theme.overlay`, slid along the edge to clear cards, other
    pills and other lines.
  - **Cut:** a red dashed line with a scissors glyph mid-edge. **Breaker open:** an amber "open" pill.
  - Edge brightness follows `EdgeState.rate`.
- **Shared links** (EdgeBundling, Layout+BundleRoutes.swift): edges into one store or external API
  (database, cache, store, search, vector, external) over one protocol family (`sql` takes postgres and
  mysql, `redis` takes valkey, `http` takes https) draw as one link when three or more callers share it.
  Display only: the manifest and the simulation keep every edge, and tokens on a folded edge travel the
  link. Edges without a protocol, and edges into anything else, keep their own line, so the request path
  stays drawn edge by edge.
  - **From the group's box:** callers inside one top-level group that doesn't hold the target collapse into
    one line from the box of the deepest group they share, leaving the side that faces the target (the
    bottom top to bottom), across from it where the border reaches. A 5 pt dot marks where it leaves.
  - **Trunk:** callers left over (ungrouped, or fewer than three in their group) join one trunk at a
    junction just past the last of them; only when the target is further than the next row (column).
  - One arrowhead and one count pill, `sql · 8`; the line is half a point heavier than a single edge.
  - **Back out:** a member edge leaves its link while its source is hovered or selected, or an op path,
    pressure overlay or selected flow lights it; the count drops (`sql · 7`). Hovering or selecting the
    target, or a link left with one member, draws every member on its own. A member runs from its source
    into the link's start and on along it, like a harness, its pill on its own stretch (none when that
    stretch has no clear room), so nothing else moves.
  - Hovering a link brightens it (no unbundling, so the pointer never loses it); a click selects its target.
  - Auto layout gives a link one lane where its members would take one each (a bundle's deepest member
    lays out for all of them), so the diagram tightens; the room a member's pill needs stays.
- **Quiet data links:** links into datastores (database, cache, store, search, vector) draw at 1.1 pt
  and 60% strength, without their pill unless relevant (in focus, hovered, selected or lit). Count pills
  always show.
- **Focus:** hovering or selecting a node keeps its edges (and so its neighbours) at full strength and
  fades every other line and pill to 20%; a selected edge or flow does the same for its edges. Strengths
  ease on `Theme.snappy`'s spring (none with reduced motion), and the fade clears on hover end or
  deselect. An op path or pressure blast radius dims the stage itself, so focus doesn't fade on top of it
  (its edges still leave their links); heat mode dims nothing, so focus works under it. Tokens off the
  focus draw dimmed with their lines.
- **Links control** (toolbar, next to the layout buttons; also ⌘K), an in-window menu:
  - **Bundle shared links** (on by default): off routes every edge on its own line and lays the level
    out again (cards glide); a manual level keeps its places and is routed again.
  - **Quiet data links** (on by default).
  - **Show all links** (⌥⌘A): for now, everything at full: every link opened up, every pill, no quiet
    lines, no fading. Cards stay where they are.
  - The button lights while anything differs from the defaults. The first two are saved per map in
    `~/.strata/state.json` with the direction; Show all lasts for the session.
- **Tokens:** 7 pt circles in the flow colour with a soft glow (blur 6, 40%).
  - Responses are the same colour, hollow (ring).
  - Messages are small rounded squares. Failures are red with an ×. Orphans are faded rings.
  - With many tokens on one edge, keep 60 fps: draw simple shapes and skip labels while moving fast.
- **Narration:** a strip at the bottom of the stage on `Theme.overlay` at 92%, 13 pt text with
  glossary links, fading in on change.
- **Paused:** a small "Paused" pill top-right.

## Inspector

- **Nothing selected:** the level's brief and narration under "This level", brief first. In a deep dive, "Operations of
  orders-svc" comes next: the ops of the node the level is inside, grouped by kind as on that node's
  own level, with a faint line saying how many map to a node here. How it works, Flows and the
  diagram legend follow. The legend lists the tokens and the card glyphs this level actually shows
  (operations, ƒ, processes, drift), each sample in a 26 pt slot so the labels line up.
- **A node:** its header, brief (doc behind More), How it works, formula, actions, enums, data,
  Operations, live metrics, code, links, your note and parameters. The op detail leads with the op's
  brief the same way, a How it works card with its mechanism's brief, and a flow's card shows its brief
  under the label.
- **Operations:**
  - A service lists its own ops by kind: Endpoints, Consumes, Queries, Cache, Publishes and Calls.
  - A database, cache or buffer lists every op that talks to it, by table, key pattern, or producer
    and consumer.
  - In a deep dive, the inherited ops mapped to a database, cache, buffer or port join its list,
    with the owner's name on each row.
  - A process gets a second header, "Operations of orders-svc", for the inherited ops mapped to it
    or to a node it calls. They are grouped by that node (`orders db 6`) and introduced by one faint line.
- **Drift** (docs/manifest.md, Drift): quiet by design.
  - A map without `repo:` shows nothing. A repo that isn't on this Mac gets one faint line in the overview
    ("Drift isn't checked: ~/x isn't on this Mac.") and nothing else. A clean map is one muted line, "Matches the repo".
  - Nothing selected: a Drift section before the diagram legend. It has the freshness and counts, then
    `checked 4 min ago · a1b2c3d · 1,284 files`, a chip per kind with findings (a click filters), and this
    level's findings (five, then Show all). At the root, "Not on the map: 3 queries, 1 binary" folds open.
    Check again (the sync glyph) and "Copy prompt for your agent" finish it.
  - A node: a Drift section before Operations, with its findings and those inside its deep dive. An op
    detail: a Drift section before Code.
  - A row has a 6 pt severity dot (bad, warn, faint) and the message, then:
    - where it is in the map (a click selects that node, opening its level);
    - the repo location, which opens the code (struck through when the file is gone);
    - where it went, when drift found it;
    - a changed query's diff (mono, `+` good, `−` bad);
    - the fix, in muted text.
- **Op rows:** a kind glyph, the label, an R/W badge, the live rate and p99, a risk dot, and a mono
  second line.
  - Hovering a row lights the op's path on the stage and dims the rest. For an inherited op that is
    the steps that name it, else its performer or every edge into its peer.
  - Clicking a row opens the op detail over the inspector; Back or Esc returns.

## How it works

A mechanism (docs/manifest.md, How it works) plays in a panel over the stage column and the dock,
inset 14 pt, on `Theme.surface` with radius 12. From the top:

- **Header:** the title (up to two lines), the owner, the stats (dropped first when narrow), code
  buttons, `Esc` and Close.
- **Path:** the main sequence and one chip per branch, with where each leaves on one line when they
  fit, else without that on up to two lines; the branches past those wait behind a "+N more" chip
  whose in-window menu lists them (the chosen path always shows).
- **Sequence diagram** on the left, the **state panel** or the **step detail** on the right.
- **Transport:** restart, step back, play or pause, step forward, the scrubber (never under 96 pt), speed, and
  the `Space ← →` keycaps when the panel is 900 pt or wider (each button's hint has its key anyway). The
  journey player's transport uses the same glyphs.
- **Step strip:** the current step's label, who talks to whom and its note (a long note's first
  sentence, three lines at most), with a Step details button. It steps aside while the step detail is open.

Nothing in the player draws over anything else. Layout math makes room instead of shrinking type below
the 11–13 pt sizes:

- **Participants:** header boxes spread evenly. When neighbours don't fit side by side, boxes alternate
  between two tiers with a short lifeline down from the upper one. When even that is tight, boxes go
  compact: a tinted edge for the kind icon, and the name on up to two lines in place of the subtitle.
  Past that, names end in an ellipsis.
- **Rows:** text is measured once per path and width, never per frame. A label wraps onto a second line
  and its row grows to fit; past two lines it ends in an ellipsis. `command → reply` shares one line
  when both fit, else the reply gets its own line, so a long command never hides it. A command is
  shortened to one line: SQL loses its line breaks and ends in an ellipsis, a Valkey command keeps its
  verb and arguments and cuts its keys in the middle between segments (`app:…:nightly-sweep`).
- **Expandable:** a label or chip that lost text shows the expand glyph at its end (accent on the
  current or hovered row). Hovering a row lights it, shows the link pointer and a small "Details ›" where that end
  of the row is empty.
- **Deadlines:** a TTL's dashed line labels itself at the right edge only where no step's text is,
  dropping the key's name first (it is cut in the middle anyway).
- **State panel:** each key on its own line, cut in the middle between segments to the panel's width,
  its value below (one line, cut at the end) with the TTL beside it and the bar under both. A row that
  lost text shows a chevron; a click shows the whole key and value.

**Step detail.** A click on a step's row (or Return, or the step strip, or Step in the state panel's
header) pauses there and opens the step detail in place of the state panel, 40% of the panel's width
(320–460 pt). The row keeps an accent outline. The detail never cuts a command, reply or key short, scrolls
when long, and its text is selectable; a long note leads with its first sentence and opens with More:

- a bar with ‹ State, `step 6 of 16`, previous and next, and `Esc`;
- `STEP 6 · at 10 ms · +4 ms`, the label, and the participants as chips that select their node;
- the command: SQL formatted one clause per line with the Formatted | Raw toggle, copy and enum hovers
  (the op detail's query block); a Valkey command taken apart into verb, keys (each on its own line,
  wrapping between segments), script and arguments, with copy; anything else verbatim, with copy;
- the reply, coloured by what it means; each key the step changed with its value, TTL and what
  happened to it (set, renewed, deleted, expired), and All keys back to the state panel;
- the note, the branches that leave after this step (a click switches to them), and the step's `code:`.

Before the first step it shows the brief (the summary behind More), the participants, the state at the
start and the code.
← and → (and the bar's arrows) move it along, and so does playback; Esc or a click on empty diagram
space closes it, and a second Esc closes the player. It opens on the frame of the click, with no
animation.

## Ask

The dock's Ask tab (⌘L, or "Ask the map…" in ⌘K) answers questions about the map in place: what breaks
if a store is down, who writes a column, why a status sticks. It runs the user's own Claude Code
(docs/architecture.md, Ask the map).

- **Field:** the app's own text field on `Theme.raised` in a radius 8 box, an accent sparkle on the
  left, `⌘L` faint on the right until focused, then Ask (Return) or, while an answer streams, an
  amber Stop. The tab is taller than the others (up to 440 pt) and stays the open tab across the
  levels of a map, so a link that dives keeps the answer in view.
- **Before the first question** on a map: a one-line notice in a faint warn box says the question and
  the map go to Claude under the user's Claude Code account, with Got it and Turn Ask off. Asking
  counts as seen. "Try asking" chips below are questions made from the map, about the selected node
  when there is one.
- **The answer** streams into a card: the question in 13 pt semibold, the model and seconds faint on
  the right, a copy button when done, then the answer as markdown (paragraphs, bullets, numbered
  lists, headings, code). Every `strata:` link that resolves is an accent link; one that doesn't is
  plain text. While it runs, a pulsing accent dot and one muted line say what Claude is reading
  ("Reading internal/pacing.go") or "Writing…".
- **Links** select a node, open an op's detail over the inspector, open the How it works player at
  the mechanism, open the enum detail on its value, open a table in its database's Data section,
  dive into a level, select a flow or run a scenario. A target on another level opens that level with
  its node selected.
- **Beside the answer** when there is room (else under it): "Ask next" chips and "Earlier", the map's
  previous questions, each a row that expands to its answer, with Clear history.
- **Failures** are calm: a faint warn box with a title, what to do ("Run `claude` once in a terminal
  to log in") and Try again. Stopped answers keep what streamed, marked "Stopped."
- **Off** (Turn Ask off): the tab says what Ask would send and offers Turn Ask on. `ask: { enabled:
  false }` in config.yaml hides the tab and the ⌘K entry.

## Journeys

A journey (docs/manifest.md, Journeys) follows one entity through the map. Playing one keeps the stage in
view: its panel takes the dock's place, about half the stage column (300–470 pt), and the level's narration
steps aside. From the top:

- **Header:** the route icon, `Journey · order · orders o-77ab`, the title, then restart, previous, play or pause,
  next, `step 4 of 21`, `Esc` (from 760 pt wide) and Close. The entity line drops first when narrow.
- **Status timeline:** every status move so far as a chip (`payment 20 captured`), oldest first, the
  current step's in the accent; the earliest give way to `+N earlier` when they don't fit. A click jumps to
  the step that made the move.
- **Steps** (236 pt, 196 pt below 1060, hidden below 840): numbered rows, the current one lit and kept in view;
  a dot marks a step that moves a status. A click jumps there.
- **Step pane:** `STEP 4 OF 21 · 14:32:04.820 · +3 ms`, the label, where it happens and what it talks to as
  chips that select their node, Dive into (or Go to) when the step is on another level, the op with Op details,
  then the query formatted with its binds filled in (the op detail's query block, with enum hovers), the Valkey
  command taken apart, the message or request, the binds, the rows it changed, the status moves with the
  transition and its `by`, the note, the How it works mechanism and the code. Before the first step it shows
  the title, the brief, the rows it follows and the keys.
- **Rows** (30% of the width, 272–400 pt; below 660 pt a Step | Rows switch in the header shows one pane):
  the entity's row and the related rows as they are after the step, then the other rows touched so far. A
  card lists the key, the status columns and the columns the journey updates, the rest behind `N more columns`.
  A cell the step changed sits on an accent tint with its old value struck through above; status codes show
  their names. While a step changes other rows, an unchanged card folds to its status line. A row not inserted
  yet is a dashed card that says which step inserts it.

On the stage the route is a highlight like an op's path: the rest dims, the current step's node, the edge it
came along, the node it talks to and the queue it publishes to light in the accent, and the route so far stays
in a faint accent. Each node it visited carries a numbered disc on its top-left corner with its latest step,
the current one filled. A step deeper in the map lights the node that holds it. When the current node is off
screen the camera glides to it, keeping the zoom.

Space plays (one step every 2.6 s) or pauses, ← and → step, Home and End jump, Esc closes (after an op detail
the step opened). Every change lands on the frame of the key or click; nothing in the panel lays out per frame.

## Overlays

All overlays are drawn inside the window (see docs/architecture.md, Hidden mode). Detail that
belongs to a panel opens as a pane inside it (the op detail over the inspector, the step detail
beside the sequence diagram), never as a card over what it explains.

- **Hints** (Overlay/Hints.swift): every icon-only or non-obvious control says what it does on hover, in one
  line, never `.help` (a system tooltip is a separate window that a screen share would show).
  - 11 pt text on `Theme.overlay`, radius 6, a `Theme.borderStrong` hairline and a soft shadow; the shortcut,
    when there is one, in a small mono keycap after the text (`Tidy layout  ⌥⌘L`). A few words: what it does,
    not what it is.
  - After a 450 ms rest; then instant while moving along a toolbar (a hint is showing, or one hid in the last
    half second). A quick 0.1 s fade in and out, nothing else moves.
  - Below the control and centred on it, above it when there is no room below (stage glyphs prefer above, so
    the card stays readable), beside it when neither fits; clamped 8 pt inside the window and never over the
    control (HintPlacement, with checks).
  - A click, scroll, pinch or key dismisses it and the control keeps quiet until the pointer leaves it. A hint
    never takes an event: Esc still closes what it would have closed.
  - Only the overlay host's hint layer observes the hint, and a control's position is kept outside SwiftUI's
    state, so a hint showing or moving re-renders nothing else.
  - Use `.strataHint("What it does", shortcut)`; `SimButton` gives an icon-only button its title as a hint,
    and takes `shortcut:` from `Shortcuts` (or `keys:` for one part of a shortcut, `←`).
- **Shortcut sheet** (⌘/, or `?` outside a text field; also the sidebar's foot and ⌘K): every shortcut by area,
  centred over a 42% black backdrop on `Theme.overlay`, radius 12. Each area is a column (three when the window
  is 1080 pt or wider, else two) with an accent 11 pt heading; a row is the action in 12 pt and its keys as
  keycaps, pointer gestures after the keys in muted text. It reads `Shortcuts.all` (StrataCore), the same list
  the app menu, the stage's key handler, ⌘K and the hints use, and the checks keep it free of clashes and in
  step with the README's table. Esc, ?, ⌘/, the close button or a click outside closes it.
- **Selectable text** (a step's label, a reply, a drift message) copies through the app's own right-click menu
  (`.strataSelectable`), never the system's text menu.

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

## Keys and Escape

- **One list.** `Shortcuts.all` (StrataCore/Support/Shortcuts.swift) holds every shortcut with its area. Chords
  (⌘, ⌥, ⌃) are unique across the app; plain keys are unique within an area, and the players' Space, arrows and
  Esc take over the stage's while they are open. Shortcuts show in Apple's order, ⌃⌥⇧⌘ then the key.
- **Escape closes the innermost thing first**, one thing per press: the palette or the shortcut sheet, an
  in-window menu or pinned card, the enum detail over the stage, the How it works step detail and then its player, the op
  detail a journey opened and then the journey, the stage's overlays (a pinned blast radius, the op detail, a
  table), then the selection, then the level (up out of a deep dive). Esc twice quickly with nothing left to close
  hides the window. In a text field Esc first leaves the field (a rename cancels), so the next press reaches the
  screen.
- **What covers the dock makes way.** Ask (⌘L) and the Pressure tab live in the dock, so asking for them closes a
  journey playing in the dock's place and the How it works player over it. ⌘J with a journey open says so in a
  toast instead of toggling a dock that can't show.

## First open

The first time any map or simulator opens, one calm line sits at the top centre of the stage: **Click** a card to
inspect it · **double-click** to dive in · **right-click** for actions · **⌘K** for everything · **?** for shortcuts.
A capsule on `Theme.overlay` at 94% with a hand glyph in the accent; it drops its later parts when the stage is
narrow (ViewThatFits) and stays clear of the Paused pill. Its close button hides it for good (`state.json`,
`hints`). Offscreen snapshots show it only with `STRATA_SNAP_INTRO=1`.

## Notes

- **Width:** the editor column is up to 760 pt wide and centred, in 15 pt text at 1.55 line height.
- **Markdown styling as you type** (Obsidian's live preview, lite):
  - Headings get size and weight, with their `#` marks faint.
  - Inline `code` is mono on raised. Bold and italic are styled.
  - `[[links]]` are accent-coloured and ⌘-clickable.
  - Fenced code blocks are mono on raised. A ```strata block shows a small "live sim ▶" chip.
- **Reading view (⇧⌘E):** rendered markdown, with ```strata blocks as live embedded sims, terms linked, and checkboxes clickable.
- **Inspector:** outline, backlinks, outgoing links, and "Linked sims".
