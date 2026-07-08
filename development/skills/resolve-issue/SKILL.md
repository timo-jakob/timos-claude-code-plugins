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
sequence of them — with the story **gated for readiness up front** and the
implementation **tested before it ever reaches review**. You **compose**
existing skills rather than reinvent them: `story-readiness` for the readiness
gate, `git-branch-naming` for the branch, the `commit` conventions for the
message, and **`/development:open-pr`** for the bot-authored PR. The novel part
is the gate → branch → implement → validate flow, plus the epic orchestration.

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

### 0. Readiness gate — is the story ready to build? (do NOT skip)

Before branching, spawn the **`story-readiness`** agent (Task tool,
`subagent_type: story-readiness`), passing it the repo (`owner/name`) and the
issue number. It returns a verdict JSON — a pure judgment, **no** GitHub writes;
**this skill** does any posting.

```json
{ "issue": 123, "verdict": "NEEDS_REFINEMENT", "risk": "normal",
  "refinement_questions": ["…", "…"], "summary": "…" }
```

- **`READY`** → carry the `risk` field forward (it rides along to the PR body
  and the Approver) and proceed to step 1.
- **`NEEDS_REFINEMENT`** → do **not** branch or implement. Ensure the
  `needs-refinement` label exists (idempotent), post the refinement questions as
  an issue comment, and **stop** — report that the story went back for
  refinement.

  ```bash
  gh label create needs-refinement --color d4c5f9 \
    --description "Sent back by the readiness gate — needs clarification before implementation" \
    2>/dev/null || true   # idempotent: ignore "already exists"
  gh issue comment <N> --body "<the refinement questions, plus a one-line why>"
  gh issue edit <N> --add-label needs-refinement
  ```

Never guess past a `NEEDS_REFINEMENT` — escalating the ambiguity here is the
whole point, and it is far cheaper than after three review rounds converge on
the wrong thing.

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
idioms. **Also read the issue's comments** (`gh issue view <N> --comments`): on a
resume after a review-loop escalation (#564), the human's decision lives in the
comment thread — treat it as authoritative implementation context. Make the
change. This step is identical across languages because you
read the repo, not a fixed recipe. If, on reading, the issue is genuinely
**under-specified** or far larger than its description implies, **stop and say
so** rather than guessing.

### 3. Validate — the per-issue gate (do NOT skip)

Run the repo's own test + lint gate and **only proceed when green**. Detect what
applies and run it:

- pre-commit hooks (`pre-commit run --all-files`, or the staged subset),
- tests for the stack — the **whole suite**, never a subset: `bats tests/`
  (plugin repos), `pytest` (Python — the whole suite, **not** `pytest
  tests/unit`), `./gradlew test` / `build` (Java/Gradle), etc.,
- any repo-specific check named in `CLAUDE.md`.

**Run the full suite — unit *and* integration — not a unit-only subset.** A green
local gate must mean the **whole** suite is green: a subset run (e.g. `pytest
tests/unit`) can pass while the change silently breaks integration tests whose
fixtures exercise it, so the break stays invisible until CI / the Approver —
after the bot PR is opened and CI minutes are already spent, exactly the outcome
the local gate exists to prevent (#604). Run the whole suite, or at minimum the
changed behaviour's **full blast radius** across unit and integration; when in
doubt, run everything.

If it's red, fix it; if you can't, **abandon the PR** and report — a child issue
is never merged or checked off on a red gate. Keep the test evidence for the PR
body.

### 3.5 Review loop — local, pre-push (do NOT skip unless `--no-review`)

Once the gate is green, run the **local review loop** before committing or
pushing anything, so a PR is only opened on code a reviewer panel has already
converged on (no CI minutes spent on unconverged work). Drive
`development/skills/resolve-issue/scripts/resolve-story-loop.zsh` — the state
machine (constants `MAX_REVIEW_ROUNDS=3`, `BLOCKING_SEVERITIES=(CRITICAL
WARNING)`). It ties the pieces together and you provide three hooks for the
model-driven steps:

- **`--review-cmd`** — run the diff-scoped review panel for this round: use the
  dispatch plan from `review-dispatch.zsh` (§#560) to pick `development-<lang>:review`,
  invoke it scoped to `$REVIEW_SCOPE_FILE`, and write the aggregate findings JSON
  (the #558 schema) to `$REVIEW_FINDINGS`.
- **`--fix-cmd`** — read `$REVIEW_BLOCKERS` (the consolidated Critical+High
  items) and implement the fixes, exactly as step 2 implements — Low
  suggestions never loop.
- **`--test-cmd`** — re-run the step-3 gate — the **full** suite (unit **and**
  integration), never a subset — so a fix that breaks tests anywhere aborts the
  loop instead of shipping. The per-round re-run is the whole suite too; a
  loop-round fix that passes a unit subset but breaks an integration test must
  fail here, not at CI (#604).

Pass `--issue <N>` too: the loop appends one JSONL telemetry record per run to
`.claude/telemetry/review-loop.jsonl` (git-ignored, #566) — evidence for
convergence rate, rounds-to-converge, and escalation breakdown.

The loop consolidates each round (`consolidate-findings.zsh`, §#561) and exits
with a status JSON + code:

- **`CONVERGED`** (exit 0) → proceed to step 4. **Keep the loop's status JSON**
  (`--status-file`) — step 6 feeds it to `build-dossier.zsh` so the **Review
  dossier** (per-round blockers found/fixed, dimensions reviewed, waived Low
  suggestions, reviewers) lands in the PR body, with a hidden JSON block the
  Approver re-ingests (#563).
- **`ESCALATE_CONFLICT` / `ESCALATE_NO_CONVERGENCE` / `ESCALATE_AMBIGUOUS`
  (10–12) / `BUDGET_EXHAUSTED` (13)** → do **not** commit or open a PR — go to
  *Escalation* below. Opening a PR here would spend CI on unconverged work.

`--no-review` skips the loop entirely (status `SKIPPED`) — today's fast path,
for when you deliberately want no local review round.

#### Escalation (any non-`CONVERGED` loop exit) — typed, no PR (#564)

A bad escalation costs a human an afternoon; a good one costs two minutes. On
any `ESCALATE_*` / `BUDGET_EXHAUSTED` status, produce **one** decision-ready
issue comment and nothing else — **no PR, no auto-merge exposure**:

1. **Push the branch as the bot** (so the diff-so-far is linkable) but **create
   no PR object** — a draft would trigger CI and defeat the local loop. Use the
   `open-pr` token mint + `git push`, then stop before `gh pr create`.
2. **Build the comment** from the loop's status JSON:

   ```bash
   "<skill-base-dir>/scripts/build-escalation.zsh" --status <status.json> \
     --issue <N> --branch <branch> --compare-url "https://github.com/$REPO/tree/<branch>"
   ```

   It emits the typed header, a summary, the round history, and 2–3 concrete
   options tailored to the escalation type.
3. **Post it and label**, idempotently (the repo's ensure-label idiom):

   ```bash
   gh label create needs-human-decision --color b60205 \
     --description "A review-loop escalation is waiting on a human decision" \
     2>/dev/null || true
   gh issue comment <N> --body-file <comment.md>
   gh issue edit <N> --add-label needs-human-decision
   ```

4. **Stop.** The human answers in the thread and re-runs
   `/development:resolve-issue <N>`; because step 2 (and the readiness gate) read
   the issue's **comments**, their decision becomes implementation context and
   the next run can converge. No PR exists until it does.

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
Test plan — include the Step 3 evidence) and carries `Closes #N`. When the review
loop ran and converged (§3.5), append the **Review dossier** via
`build-dossier.zsh` on the kept status JSON (#563). Outcomes:

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

### E1b. Readiness pre-flight — gate ALL children before building anything

Before any ordering or implementation, run the readiness gate over **every open
child**: spawn `story-readiness` (Task tool, `subagent_type: story-readiness`)
once per child — they're independent, so launch them in parallel in a single
message — and collect the verdicts.

- **All `READY`** → proceed to E2. Keep each child's `risk`; it rides along to
  that child's PR when you resolve it.
- **Any `NEEDS_REFINEMENT`** → the **epic is not ready; build nothing.** For
  each unready child, ensure the `needs-refinement` label and post its
  refinement questions as a comment (exactly as Single-issue step 0 does). Then
  post a **halt summary** on the epic — the checklist of which children are
  unready and why — and **stop**. One unready child means the epic is not ready.

Re-running after the stories are refined (criteria added, the `needs-refinement`
label cleared) continues the pre-flight from the still-open children — the gate
is as resumable as the rest of the flow.

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

### E3. Resolve — drive ALL children in one invocation

One epic invocation drives **every** open child to completion — decompose,
order, resolve each — not "next child, then stop". The only thing that ever
halts a child is a **typed escalation** (§#564); the readiness pre-flight (E1b)
already proved every child was `READY` before the first one starts, so nothing
else needs a human mid-run.

- **Disjoint children** → **parallel sub-agents**, each in its own **worktree**
  (so edits can't collide), each running the Single-issue flow to its own
  bot-authored PR. They don't depend on each other, so their PRs open and merge
  independently.
- **Everything else** → **sequential + stable**: resolve one child fully
  (Single-issue flow → PR), **wait for it to merge**, `git fetch origin`, branch
  the next off the fresh tip, continue — through the whole chain.

> **Bias hard to sequential.** Worktrees make parallelism *possible*, not
> *preferred*; parallelise only the provably-disjoint set. **Minimising merge
> conflicts beats throughput.** When in doubt, sequential — and off the *merged*
> tip, never stacked (the version manifest alone would conflict).

**Waiting for each merge.** In an **Approver** repo each bot PR auto-merges on
green CI, so the loop advances the whole chain by itself: wait on the PR with the
blessed poller
(`development/skills/maintenance/scripts/await-pr-checks.zsh <pr>` — exit 0 on
settle, nonzero only on a real timeout/error; never hand-roll a `while [ … ]`
poll that leaks its trailing test's status as a false failure, #412), then
fetch + branch the next. **All children, one invocation, no re-trigger.** In a
**human-only** (claude-plugin) repo a human approves + merges each PR — a genuine
judgement gate, not a needless re-trigger — so a *sequential* chain there still
advances per merge: open the current child's PR and stop, resuming on re-run once
it merges. (Disjoint children can still all be opened at once even there.)

**When a child escalates (typed exit from §#564), don't abort the epic.** Triage
the rest against the escalated child:

- children that **don't depend** on it → **keep going**;
- children that **do depend** on it → **park** them: leave a note on the epic
  that they're blocked on child #X (do not branch them off an unmerged/blocked
  dependency);
- never fail silently — the escalation already posted its own typed comment on
  the child (§#564).

**End every run with an epic summary comment** — one comment on the epic listing
**merged / escalated / parked** children (and any still queued), so the epic's
state is legible at a glance. Then:

- **All children merged** → proceed to **E4** (holistic verification) and **E5**
  (close the epic). A re-run that finds **zero open children** does no child work
  — it goes straight to E4 + E5.
- **Some escalated/parked** → the epic stays **open**; re-running after the human
  resolves an escalation (the decision lands in the child's comment thread, which
  the implement step re-reads) resumes the parked dependents and any remaining
  children. The flow is fully **resumable**.

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
- **Gate before you build** — the `story-readiness` gate runs first (single-issue
  step 0; epic pre-flight over all children). A `NEEDS_REFINEMENT` verdict posts
  refinement questions + the `needs-refinement` label and **stops** — never
  branch or implement past it, and for an epic never build *any* child while one
  is unready.
- **Don't decide the user's issues for them** — if a single issue is ambiguous,
  the gate sends it back for refinement rather than guessing a large or
  contentious change into a PR.
