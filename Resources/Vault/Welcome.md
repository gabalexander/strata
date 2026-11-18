# Welcome to Strata

Keep your system design notes alongside the architecture maps and live simulations you use to test them. Every note is a Markdown file in `~/.strata/vault`.

## Try a checkout failure

Open the [[checkout|checkout simulator]] and slow its database. Watch how long the order service holds connections while its requests wait. Use the [[System design/Checklist|system design checklist]] to record what you observe.

In reading view, a `strata` code fence opens a live simulator inside your note. Set `sim` to the simulator's library ID.

```strata
sim: checkout
height: 360
```

## Shortcuts

| Shortcut | Action |
| --- | --- |
| ⌃⌥S | Show or hide Strata |
| ⌘K | Find commands, notes, and simulators |
| ⌘O | Jump to a note or simulator |
| ⌘⇧E | Switch between editing and reading |
| ⌘⌥I | Toggle the inspector |

Type `[[` to link a note or simulator. To map your own system, follow [[How to map a project]].
