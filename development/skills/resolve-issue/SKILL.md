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
  holistic end-to-end test over the merged epic and explicitly close the epic
  issue (nothing auto-closes it). Repo-type-agnostic (Python / Java /
  Claude-plugin). Composes git-branch-naming, commit, and open-pr; never pushes
  to the default branch.
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

Per `/development:git-branch-naming` — `<type>/<N>-<slug>`, with `type` from
the issue's type label if it has one; else from the title's Conventional-Commit
prefix (`fix(...)` → `fix`, `feat(...)` → `feat`, …); else inferred from the
change (`fix` / `feat` / `docs` / `chore` / `refactor`). Always branch from the
current origin tip — never stack:

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

Delegate to **`/development:open-pr`** — i.e. follow its procedure: mint the
writer token (`mint-maintenance-token.zsh`), **push the branch as the bot**
(`git push https://x-access-token:$TOKEN@github.com/$REPO.git HEAD:$BRANCH` — so
the bot is also the last pusher), open the PR with `GH_TOKEN=$TOKEN gh pr create`
(author = the Maintenance App), then `GH_TOKEN=$TOKEN gh pr merge <n> --auto
--squash --delete-branch`. The PR body follows the template (Type / Summary /
Test plan — include the Step 3 evidence) and carries `Closes #N`. Outcomes:

- **Approver repo (Python / Java)** → the Claude Approver auto-approves → it
  auto-merges on green CI.
- **Claude-plugin repo (human-only)** → a human approves → it auto-merges.
- **No writer App installed** → open-pr falls back to a *user*-authored PR (the
  human admin-merges, since they can't approve their own); report which path ran.

Report the PR URL, that it's bot-authored, and that auto-merge is armed.

## Epic flow

You do **not** implement the epic directly — you resolve its children
conflict-aware, then verify the whole, then **close the epic** (E4/E5).

### E1. Enumerate the children

Parse the epic body's **task-list lines** specifically (`- [ ] #N` / `- [x] #N`,
or `owner/repo#N`) — match those, **not every `#N` mention** in the body (which
also catches unrelated cross-references and would pull in non-children).
Consider only the **open** ones (skip children already closed/merged). This
makes the skill **resumable**: re-running continues from wherever a prior run
stopped.

> **Terminal case — no open children left.** When this enumeration finds **zero
> open children** (every child already closed/merged, e.g. on the re-run after
> the last child landed), do **no** child work: skip straight to **E4**
> (holistic verification) and then **E5** (close the epic). This is the step
> that's easy to miss — an epic whose children are all merged still sits OPEN
> until E5 closes it, because nothing carries `Closes #<epic>`. Some epics
> instead track **inline slices** (`- [ ]` describing work, no `#N`) realized by
> separate PRs; for those, confirm each slice's PR merged, then E4 + E5 the
> same way.

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
- **In-flight PRs** — also list the repo's **open PRs** (`gh pr list --json
  number,title,headRefName`) and the files they touch. An open PR editing a
  file (or the plugin's version manifests) a child needs is an **in-flight
  dependency**: queue that child behind it exactly as you would a merged
  overlap. Don't analyse against `main` alone.

> **The version manifest is the dominant serialiser.** Substantively
> file-disjoint same-plugin children (e.g. three different template files) still
> can't parallelise, because all three bump `plugin.json` + `marketplace.json`
> — **two same-plugin PRs open at once will conflict on the version line.** So
> serialise same-plugin work and resolve each child off the **merged** tip, where
> its bump increments cleanly. (This bites in-flight too: any open same-plugin PR
> — even the one that *added* this skill — forces the children to queue behind
> it. Treat an open same-plugin PR as a hard dependency.)

Partition into the **provably-disjoint set** (no shared files at all *and* no
in-flight PR touching them — realistically: different plugins) and **everything
else**.

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
> **Waiting for a merge — and one child per invocation in a human-only repo.**
> In an **Approver** repo each bot PR auto-merges on green CI, so the sequential
> loop proceeds on its own — wait on the PR's checks with the blessed poller
> (`development/skills/maintenance/scripts/await-pr-checks.zsh <pr>`, which exits
> 0 on settle and nonzero only on a real timeout/error — never hand-roll a
> `while [ … ]` poll that leaks its trailing test's exit status as a false
> failure, #412), then when it's merged fetch + branch the next. In a
> **human-only** (claude-plugin) repo the PR waits for the
> human, so a sequential epic resolves **exactly one child per invocation**:
> resolve it, open the bot PR, then **stop** — the next child can't branch off
> the unmerged tip (it would stack and conflict on the version line). Surface the
> PR, tell the user to approve it, and that re-running
> `/development:resolve-issue <epic#>` continues from the next open child once it
> merges (the skill is resumable). **When a re-run finds no open children left,
> it does no child work — it runs E4 (holistic verification) and E5 (close the
> epic).** **Never branch the next child off an unmerged dependency, and never
> pre-resolve multiple sequential children.**

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
(and resolve it if it fits) rather than silently marking the epic done — the
epic stays **open** until that regression is handled. Otherwise the epic's domain
is verified green: proceed to **E5**.

### E5. Close the epic (the step that gets missed)

**Closing the epic is an explicit action — nothing does it for you.** Each child
closed via its own PR's `Closes #N`, but the **epic issue has no PR of its own**,
so no `Closes` trailer ever references it. A done epic therefore lingers OPEN
unless you close it by hand. This is the single most common miss in this flow, so
do it as the final, deliberate step — **only after E4 is green** (closed-after-
final-testing, never before):

```bash
gh issue close <epic#> --comment "<closing summary>"
```

The closing summary should carry the **completed checklist** (each child / slice
→ its merged PR) and the **E4 verification result** (what holistic test ran and
that it passed), so the closed epic is a self-contained record. Only after this
is the epic truly done — report it closed, with the PR/verification table.

## Guardrails

- **Never push to `main`** — always a feature branch off fresh `origin/main`.
- **Never open a PR on a red gate** — green tests are the precondition for review
  (the per-issue gate).
- **The PR is bot-authored** via `open-pr` so it can be approved and auto-merge;
  never self-author when the writer App is available.
- **One issue per PR, one PR per issue** — squash merge, no stacking: each child
  branches off the merged tip.
- **Resumable** — re-running on an epic skips already-resolved children.
- **Close the epic explicitly after E4 (E5)** — children auto-close via their
  PRs' `Closes #N`, but the epic issue has no PR, so it never closes itself. A
  done-but-open epic is the most common miss; the final re-run (zero open
  children) exists to verify and close it.
- **Don't decide the user's issues for them** — if a single issue is ambiguous,
  ask/stop; don't guess a large or contentious change into a PR.
