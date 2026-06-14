# Phase 8 (per-stage PR cycle) — rationale & edge-case detail

This file holds the *why*, the incident history, and the exhaustive lookup
tables behind **Phase 8** of the maintenance orchestrator
(`development/skills/maintenance/SKILL.md`). The imperative procedure — the
steps, commands, Agent call shapes, and decision branches — lives in SKILL.md;
Phase 8 cites the section here at each relevant point.

Nothing here is required reading to *execute* the happy path. It's the
reasoning you reach for when a step's intent is unclear or an edge case fires.
Section titles match the `§` pointers in SKILL.md's Phase 8.

## Why the identity switch matters for the Approver loop

Maintenance PRs are created under the `claude-maintenance[bot]` identity (via
the minted installation token) rather than the user's `gh` auth, because:

- The Approver's default author allowlist
  (`CLAUDE_APPROVER_AUTHOR_ALLOWLIST` per-repo variable) is **machine-only**
  by default and includes the maintenance bot's real owner-suffixed login
  (e.g. `claude-maintenance-<owner>[bot]`, #229). Without the identity switch,
  maintenance PRs would be authored by the user, the allowlist would reject
  them, and the Approver would not evaluate the PR at all — the entire
  Approver→maintenance loop would never start.
- The Approver's anti-rubber-stamp gate (PR author has no `claude-approver`
  prefix) fires correctly: the maintenance and approver Apps are distinct
  identities by design.

This is also why, when `mint-maintenance-token.zsh` fails, the right move is to
**abort PR creation for that stage** rather than fall back to the user's PAT: a
PAT-authored PR is one the Approver can't evaluate, which is worse than
skipping the stage.

## Why isolation is load-bearing (the per-group-PR invariant)

`isolation="worktree"` is the single most load-bearing parameter in a
file-editing group's spawn call. **Omitting it silently breaks the entire
per-group-PR invariant**: the agent then edits the main workspace instead of a
fresh worktree branch, its changes land on `main`'s working tree, and the
orchestrator ends up creating a branch + commit ad-hoc after the fact — exactly
the failure mode Phase 8 exists to prevent.

This pairs with the "agents commit before returning" contract: the agent only
ever commits to its own worktree branch, and the orchestrator only ever pushes
a branch the runtime created. Together those two invariants keep `main`'s
working tree clean throughout the entire run.

## Worktree-branch contract violations

If the agent comes back without a worktree branch and the main workspace has
uncommitted changes, that's a contract violation, not a graceful path. Surface
it in the summary as a quality bug. Do NOT silently create a `maint/...` branch
from the dirty main workspace — that masks the underlying failure and breaks
reproducibility for subsequent stages.

## Why close superseded vendor PRs before the CI cycle

Close superseded vendor PRs **before** the CI cycle starts, not after merge:
the vendor's PR list stays clean while the replacement waits in review, and
Dependabot stops rebasing the superseded PR. If the replacement is later
rejected, reopen the vendor PR with `gh pr reopen <n>` — no data is lost.

## New vs pre-existing failures: why classify

A failure that's already failing on `<base_branch>` is not caused by this PR —
it belongs on the project's main, not on a maintenance PR that didn't touch its
cause. Spawning the fixer on it wastes tokens and can produce confusing "fixes"
that don't apply.

On the classification shell: `gh` returns JSON arrays; `comm` needs sorted
line-delimited input. `jq -r '.[]'` between the two converts JSON arrays to
lines if the piping is awkward — adapt as needed for the shell. The intent is
the set diff, not the exact incantation.

## Per-tool override: reasoning + tool→check examples

A same-tool failure on the PR is never trusted as "pre-existing" because the
work agent was responsible for resolving the tool's findings completely — under
the planner's one-group-per-agent rule, there are no "other groups" of the same
tool to absorb the blame. The failure means either:

- the agent's fix didn't actually land (incomplete commit, bad patch), or
- a finding the agent intentionally left in `actions_requiring_review` is now
  blocking CI.

In both cases the right move is to investigate, not silently merge. The CI-fix
agent will dig into the log and either fix the remaining failures or escalate
with an actionable recommendation.

Tool → check-name correspondence is judgment-based; use substring match on the
tool key (case-insensitive). Examples:

- PR is a sonar group → `plan[i].tool == "sonarcloud"`. A failing `sonarcloud`
  (or `sonar-quality-gate`, etc.) check is this PR's own tool — keep in the
  new-failures bucket. A failing `image` (Snyk container) check is a different
  tool — eligible for pre-existing-skip.
- PR is a `snyk_prs` or `dependabot` group → `plan[i].tool` is `"snyk_prs"` or
  `"dependabot"`. A failing CI check that matches the same vendor's other PR
  signals (e.g. another Snyk App check) is this PR's own tool. A failing
  `code-scanning`/`codeql` check is a different tool — eligible for
  pre-existing-skip.
- Stage 0 (coverage improver) → treat the project's coverage gate check
  (typically Sonar's QG "new code coverage") as the PR's own tool; everything
  else is eligible for skip.

## Why `-f -f` (double force) on worktree removal

Use `-f -f` (double force), not `--force` / single `-f`. Claude Code's Agent
runtime locks every worktree it creates (lock reason: "claude agent
agent-<id>"). The lock survives even after the originating claude process
exits, so single `-f` errors out with "cannot remove a locked working tree".
`-f -f` overrides the lock AND any uncommitted state. Without this, the remove
silently fails, the local branch stays attached to the worktree,
`gh pr merge --delete-branch` fails to delete the local ref, and the worktree
accumulates across runs.

## Why re-run the state pre-flight after each merge

A merge — especially of a runtime-version-bumping PR — can change the project's
declared configuration, leaving local state (venv, toolchain cache, etc.)
inconsistent. Without this re-check, subsequent stages' agents run their
verification against state that no longer matches what's on `main`, producing
false-positive errors and missed regressions (the live test on
ai-doc-organizer's Stage 7 surfaced exactly this for the Python venv case after
a 3.13 → 3.14 merge).
