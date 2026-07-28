# Reference

Lookup-oriented material: what exists and exactly what it does. Reach for these
when you already know what you're looking for.

- [Plugin overview](plugins.md) — the narrative tour of each plugin and its
  purpose, policies, and composition.
- [Commands](commands.md) — every slash command, **generated from skill
  frontmatter** (kept in sync with the code by CI).
- [Agents](agents.md) — every agent with its model and tools, **generated from
  agent frontmatter**.
- [`c4_drift` findings](c4-drift-findings.md) — the finding shape the docs topic
  plugin emits when the Container diagram and detection disagree.
- [Grafana hand-off contract](telemetry-grafana-handoff.md) — what the separate
  cross-repo reporting repo ingests: the shared directory, the glob, the closed
  `telemetry/v1` envelope, the join keys, and the reference dashboard.
- [Repo scripts](repo-scripts.md) — the helper scripts under `scripts/`.
- [Requirements](requirements.md) — platform and runtime dependencies.

For the authoritative architecture & schema contract, see
[`ARCHITECTURE.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md) at the repo root.
