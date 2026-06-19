---
name: resolve-issue
description: >
  Take a GitHub issue — or an epic of issues — and drive it to merge-ready,
  bot-authored PR(s). Single issue: branch off fresh main, implement, validate
  (tests must be green), commit, and open a Maintenance-App-authored PR with
  squash auto-merge armed — the Approver auto-approves on app repos; a human
  approves on claude-plugin repos. Epic: decompose the children, order them
  conflict-aware, resolve provably-disjoint ones in parallel worktrees and the
  rest sequentially off fresh main (each child independently tested), then run a
  holistic end-to-end test over the merged epic. Repo-type-agnostic (Python /
  Java / Claude-plugin). Composes git-branch-naming, commit, and open-pr; never
  pushes to the default branch.
disable-model-invocation: false
---

You turn a filed **issue** into a merge-ready **PR** — or an **epic** into a
sequence of them — with the implementation **tested before it ever reaches
review**. You **compose** existing skills rather than reinvent them:
`git-branch-naming` for the branch, the `commit` conventions for the message,
and **`/development:open-pr`** for the bot-authored PR. The only novel part is
the issue → branch → implement → validate flow, plus the epic orchestration.

**User input:** $ARGUMENTS — a single issue number / URL, or an epic's.

## Step 0 — classify the target

```bash
gh issue view <N> --json number,title,body,state,labels,url
```

- If `state` is not `OPEN`, stop — it's already handled.
- **Epic?** It's an epic when the body holds a **task list of child issues**
  (`- [ ] #123`, `- [ ] owner/repo#123`) or it carries an `epic` label →
  go to **Epic flow**.
- Otherwise → **Single-issue flow**.

Operate on the **session's repo** (`gh repo view --json nameWithOwner`); the
issue must belong to it. If `$ARGUMENTS` is empty, print the invocation help
(`/development:resolve-issue <issue-number|url>`) and stop.

## Single-issue flow

### 1. Branch off fresh main

Per `/development:git-branch-naming` — `<type>/<N>-<slug>`, with `type` inferred
from the issue's label/title (`fix` for a bug, `feat` for a feature, `docs`,
`chore`, `refactor`). Always branch from the current origin tip — never stack:

```bash
git fetch origin -q
git switch -c "<type>/<N>-<slug>" origin/main
```

### 2. Implement

Read the issue carefully and the files it names; read the repo's conventions
(`CLAUDE.md`, the surrounding code) and match them — comment density, naming,
idioms. Make the change. This step is identical across languages because you
read the repo, not a fixed recipe. If, on reading, the issue is genuinely
**under-specified** or far larger than its description implies, **stop and say
so** rather than guessing.

### 3. Validate — the per-issue gate (do NOT skip)

Run the repo's own test + lint gate and **only proceed when green**. Detect what
applies and run it:

- pre-commit hooks (`pre-commit run --all-files`, or the staged subset),
- tests for the stack: `bats tests/` (plugin repos), `pytest` (Python),
  `./gradlew test` / `build` (Java/Gradle), etc.,
- any repo-specific check named in `CLAUDE.md`.

If it's red, fix it; if you can't, **abandon the PR** and report — a child issue
is never merged or checked off on a red gate. Keep the test evidence for the PR
body.

### 4. Version bump (plugin content only)

If you changed any plugin's installable content (`<plugin>/…`), bump that
plugin's `plugin.json` **and** its matching `.claude-plugin/marketplace.json`
entry (per the version-bump convention) — otherwise installs never see the
change. A patch for a fix, a minor for a feature. Skip for root-only docs.

### 5. Commit

Use the `/development:commit` conventions: a Conventional Commits subject,
`Closes #N` in the body, and the family's `Co-Authored-By` trailer. One commit
unless the change is genuinely multi-part. Let pre-commit run (never
`--no-verify`).

### 6. Open the bot-authored PR

Delegate to **`/development:open-pr`** — it mints the writer token, pushes as the
Maintenance App, opens the PR **as the bot**, and arms squash auto-merge with
branch deletion. The PR body follows the template (Type / Summary / Test plan —
include the Step 3 evidence) and carries `Closes #N`. Outcomes:

- **Approver repo (Python / Java)** → the Claude Approver auto-approves → it
  auto-merges on green CI.
- **Claude-plugin repo (human-only)** → a human approves → it auto-merges.
- **No writer App installed** → open-pr falls back to a *user*-authored PR (the
  human admin-merges, since they can't approve their own); report which path ran.

Report the PR URL, that it's bot-authored, and that auto-merge is armed.

## Epic flow

You do **not** implement the epic directly — you resolve its children
conflict-aware, then verify the whole.

### E1. Enumerate the children

Parse the epic body's task list / linked issues. Consider only the **open**
ones (skip children already closed/merged). This makes the skill **resumable**:
re-running continues from wherever a prior run stopped.

### E2. Analyse order + overlap

For each child, determine the files it will touch (the issue body usually names
them; confirm with a quick repo scan). Then order by:

- **Dependencies** — if B builds on A, A first (the epic may already imply an
  order; honour it).
- **File overlap** — children that edit the same file must be sequential
  relative to each other. **This includes the shared version manifests:** two
  children in the *same plugin* both bump `plugin.json` + `marketplace.json`, so
  they are **never completely disjoint** even when their substantive files
  differ.

Partition into the **provably-disjoint set** (no shared files at all —
realistically: different plugins) and **everything else**.

### E3. Resolve — sequential by default, disjoint-only in parallel

- **Disjoint children** → may run as **parallel sub-agents**, each in its own
  **worktree** (so file edits can't collide), each running the Single-issue flow
  to its own bot-authored PR. They don't depend on each other, so their PRs can
  be open and merge independently.
- **Everything else** → **sequential + stable**: resolve one child fully
  (Single-issue flow → PR), **wait for it to merge**, then `git fetch origin` and
  branch the next off the fresh tip. This mirrors `/development:maintenance`'s
  per-group cadence and is the default.

> **Bias hard to sequential.** Worktrees make parallelism *possible*, not
> *preferred* — even with them, choose sequential stability and only parallelise
> the provably-disjoint set. **Minimising merge conflicts beats throughput.**
> When in doubt, sequential.
>
> **Waiting for a merge.** In an **Approver** repo each bot PR auto-merges on
> green CI, so the sequential loop proceeds on its own — poll the PR state, and
> when it's merged, fetch + branch the next. In a **human-only** (claude-plugin)
> repo the PR waits for the human: after opening a child's PR that the next child
> depends on, surface it and **pause** — tell the user to approve it, and that
> re-running `/development:resolve-issue <epic#>` continues from the next open
> child once it has merged. **Never branch the next child off an unmerged
> dependency.**

### E4. Comprehensive epic verification (after ALL children merge)

The per-child gates tested each change in isolation, but can't see the
children's **combined** effect. Once the whole epic is on `main`, run a
**holistic end-to-end test of the epic's domain** and report:

- **Java / Python app** (most critical) — the full build + test suite, plus a
  real end-to-end exercise of the affected behaviour (run the relevant pipeline
  / the app itself), so integration regressions surface here.
- **Claude-plugin** — the full `bats` suite **and** `/development-claude-plugin:test`
  driving the affected skills/agents end-to-end (the same pattern used to verify
  slices by hand).

If the holistic test surfaces a regression the per-issue runs missed, **file it**
(and resolve it if it fits) rather than silently marking the epic done. Otherwise
note the epic complete.

## Guardrails

- **Never push to `main`** — always a feature branch off fresh `origin/main`.
- **Never open a PR on a red gate** — green tests are the precondition for review
  (the per-issue gate).
- **The PR is bot-authored** via `open-pr` so it can be approved and auto-merge;
  never self-author when the writer App is available.
- **One issue per PR, one PR per issue** — squash merge, no stacking: each child
  branches off the merged tip.
- **Resumable** — re-running on an epic skips already-resolved children.
- **Don't decide the user's issues for them** — if a single issue is ambiguous,
  ask/stop; don't guess a large or contentious change into a PR.
