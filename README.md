# Strata

A hidden macOS lab bench for learning systems visually: notes like Obsidian, live simulators,
and maps of real architectures you can drill into and break. Simulators are YAML manifests
(docs/manifest.md), so an agent can write one for any system.

```sh
make app        # build/Strata.app
make install    # ~/Applications/Strata.app, the `strata` CLI in ~/.local/bin, the agent skill
make checks     # assertions
make snapshots  # PNGs of the main screens in build/snapshots
```

Data lives in `~/.strata/` (sims/, vault/, config.yaml). The window is excluded from screen
sharing and the app stays out of the Dock; ctrl+option+s shows it.

See docs/architecture.md.
