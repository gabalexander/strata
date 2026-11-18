# Working on Strata

Read docs/architecture.md (modules, ownership, rules), docs/manifest.md (the manifest format,
which is also the simulation semantics) and docs/design.md (visual language) before changing anything.

- Build: `swift build --disable-sandbox` (the flag is required inside agent sandboxes).
- Checks: `swift run --disable-sandbox StrataChecks [filter]`.
- Snapshots: `swift run --disable-sandbox StrataSnapshot build/snapshots [scene-substring]`, then look at the PNGs.
- Never launch StrataApp or Strata.app: it is a hidden accessory app. Leave no processes running.
- Contract files (marked CONTRACT FILE) change only additively; list any change in your report.
- No third-party packages, no network.
- Never use `.contextMenu`, `.popover`, `.help`, `.sheet`, `.alert` or `NSMenu` in views. Use `Overlays` (in-window) so screen sharing never sees a separate window.
