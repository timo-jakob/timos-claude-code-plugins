# CLAUDE.md

Repo-wide rules for Claude Code sessions in this repository. Architecture and
schema contracts live in ARCHITECTURE.md; template maintenance in MAINTAINING.md.

## Read `docs/architecture/` before structural changes

Before a **structural** change — adding, removing, or renaming a service,
container, datastore, message broker, or external integration — read
[`docs/architecture/`](docs/architecture/) first: this repo's C4 diagrams
(System Context and Containers, as Mermaid blocks) are the authoritative picture
of the deployable units and how they connect. **Keep it true in the same PR** —
a change that adds, removes, or renames any of the above, or changes what talks
to what, updates `docs/architecture/` alongside the code, not as a follow-up;
the maintenance pipeline flags drift between the declared containers and reality.

## Definition of "green CI" on a PR

A PR is **GREEN** when, after all checks have settled (none pending), **zero
checks are in the `fail` bucket** of `gh pr checks --json name,state,bucket`.

- **CANCELLED checks are neutral, never failures.** The Approver gate's
  `approve`/`approver-gate` jobs are cancelled by design on every run (the
  `pull_request`-triggered run is superseded by the `check_suite` run, #190).
  Counting the `cancel` bucket as failure flips every green Approver PR to
  NOT-GREEN.
- A genuinely-cancelled *required* check is enforced by branch protection
  (auto-merge simply won't fire) — not by this verdict.
- The authoritative implementation is
  `development/skills/maintenance/scripts/merge-pr-cycle.zsh` (`_await_settle`).
  Use it instead of hand-rolling `gh pr checks` parsing; if you must judge
  greenness ad hoc, apply the same rules.
