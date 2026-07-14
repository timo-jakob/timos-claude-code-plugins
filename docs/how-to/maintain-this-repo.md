# Maintain this repo (quarterly template refresh)

The bootstrap skill pins versions inside `.tmpl` files (GitHub Actions
versions, pre-commit hook revs, Docker image tags, language runtime
versions). Standard Dependabot can't update those — see
[`MAINTAINING.md`](../../MAINTAINING.md) for the quarterly refresh checklist
that keeps the templates current. ~20 minutes per quarter.

## Feeding real runs back into the plugins

Improving these plugins from actual `/development:maintenance` runs is the core
loop of this repo — but a Claude Code session stores the main transcript and
each subagent's transcript in separate files, so handing over only the main
`.jsonl` loses the dispatcher/triage/planner/ci-fixer detail. Run
[`scripts/capture-session-log.zsh`](../../scripts/capture-session-log.zsh)
with no arguments after a run: it offers the most recent project and
session (just press Enter twice) and bundles the main transcript **plus**
the `subagents/` directory into one `.tgz` to hand back for analysis.

See [Repo scripts](../reference/repo-scripts.md) for the full script reference.
