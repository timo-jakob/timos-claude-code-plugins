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
- **Epic?** It's an epic when it has **native sub-issues**
  (`read-sub-issues.zsh --repo "$REPO" --epic <N>` reports
  `summary.total > 0` — the authoritative signal, #802), when it carries an
  `epic` label, or when the body holds a **task list of child issues**
  (`- [ ] #123`, `- [ ] owner/repo#123` — which marks an *un-backfilled*
  epic, see E1) → go to **Epic flow**. A **failed** reader call (nonzero
  exit) is a classification failure — report it and stop; never fall back to
  the label/task-list signals as if the native signal were checked and
  absent (a native-only epic would misclassify as a single issue).
- Otherwise → **Single-issue flow**.

Operate on the **session's repo** (`gh repo view --json nameWithOwner`); the
issue must belong to it. If `$ARGUMENTS` is empty, print the invocation help
(`/development:resolve-issue <issue-number|url>`) and stop.

## Single-issue flow

### 0a. Dependency precheck — reject on open blockers (do NOT skip)

Dependencies are enforced from **GitHub-native `blockedBy` relationships** —
the single source of truth (#583); prose declares nothing. Before anything
else — before the readiness gate, before any branch exists — run the precheck:

```bash
"<skill-base-dir>/scripts/dependency-precheck.zsh" --repo "$REPO" --issue <N>
```

It wraps the shared reader (`read-dependencies.zsh`, #584) into one typed
decision (JSON on stdout; like the readiness gate it performs **no** GitHub
writes — this skill does the posting):

- **`PROCEED` (exit 0)** — no open blockers. Clear a stale `blocked` label if
  one is present (`gh issue edit <N> --remove-label blocked 2>/dev/null ||
  true`) and continue to step 0b exactly as today.
- **`REJECT_BLOCKED` (exit 10)** — the issue has open blockers, directly or
  transitively. Do **not** branch or implement. The decision JSON's
  `comment_md` is the ready-to-post argumentation naming each open blocker.
- **`REJECT_CYCLE` (exit 11)** — the blocked-by graph contains a cycle, which
  no order of work can satisfy. Same handling as `REJECT_BLOCKED`; the
  `comment_md` names the cycle. Refuse — never try to loop through it.

On either rejection, what happens next depends on who is driving:

- **Autonomous / non-interactive** (maintenance pipeline, epic-driven resolve —
  no human to prompt): post `comment_md` as an issue comment, apply the
  `blocked` label idempotently, and **stop**. **Never auto-chain** into
  resolving the blocker unattended — an unattended run must not widen its own
  scope (#583's decision).

  ```bash
  gh label create blocked --color b60205 \
    --description "Rejected by the dependency precheck — open blockers in its blocked-by graph" \
    2>/dev/null || true   # idempotent: ignore "already exists"
  gh issue comment <N> --body "<comment_md>"
  gh issue edit <N> --add-label blocked
  ```

- **Interactive** (a human invoked `/development:resolve-issue` and is
  present): report the argumentation in the conversation instead — the human
  is right there, a comment would be noise. Then offer **guided remediation**
  (below) rather than dead-ending — with a human present, a rejection is a
  fork in the road, not a stop sign.

#### Interactive remediation — offer to clear the blockage (#586, #587)

Applies **only** with a human present, and only to `REJECT_BLOCKED`:

- **`REJECT_CYCLE` has no remediation.** No order of work satisfies a cycle;
  the fix is a relationship edit (remove whichever blocked-by points the wrong
  way), and that judgment is the human's. Report and stop.
- **An open blocker classified `kind: "epic"` blocks as a whole** (#587):
  resolving one child wouldn't unblock the dependent — the named issue may
  depend on the epic's **combined** effect. Remediating an epic blocker means
  running the **full Epic flow** on it (E1–E5: every child, the holistic E4
  verification, the explicit E5 close) — **reuse that flow as written**, never
  a re-implementation of its ordering. The named issue stays queued until the
  blocking epic is **CLOSED**, not merely until its children merge — E4 may
  still surface a regression that keeps the epic open. That is the epic flow's
  "never branch off an unmerged dependency" rule, extended across the epic
  boundary. (Autonomous runs are unchanged: an epic blocker rejects +
  escalates like any other — an unattended run never auto-runs the epic.)

Whatever the blocker's kind, put the choice to the human (AskUserQuestion —
one question, two options; on rejection, name the open blockers in the
question, and say when one is an epic, since choosing to resolve it means
resolving the whole epic):

1. **Resolve the dependency AND the named issue** — clear the whole blocker
   chain, then build the named issue in the same run.
2. **Resolve just the dependency** — clear the chain, then stop; the human
   re-runs `/development:resolve-issue <N>` when ready (its blockers now
   closed, the precheck passes on its own).

Declining both (the "Other" escape hatch) stops exactly as before the offer
existed — never remediate without an explicit choice.

**Either way, the blocker chain resolves deepest-first.** The precheck's
`blockers` array carries a `depth` per blocker: work from the deepest open
blocker upward, because a shallower blocker may itself be blocked by a deeper
one — building it first would just re-reject. Resolve each blocker via the
**full single-issue flow, recursively**: each blocker's run starts at its own
step 0a, so a still-deeper blocker surfaces there (and, with the human still
present, gets the same offer), and #585's cycle refusal is inherited rather
than re-implemented. One issue per PR, as always — a chain of three blockers
is three PRs, each **merged before its dependent branches** (never stacked;
the epic flow's "never branch off an unmerged dependency" rule, applied
across the remediation chain). An **epic-kind blocker occupies its rung as a
single unit**: that rung runs the Epic flow (above) instead of the
single-issue flow, and the rung is complete only when the blocking epic is
closed. Wait for each merge before the next rung: an Approver repo
auto-merges on green (`await-pr-checks.zsh`); in a human-only repo the human
is present — report the blocker PR ready and continue once they merge it.
When an epic rung pauses awaiting a child's merge (the human-only cadence),
this remediation pauses with it; re-running `/development:resolve-issue` on
the **named issue** re-enters the gate and resumes the blocking epic from its
next open child.

Then, per the chosen option:

- **Just the dependency** → stop once the blocker chain is merged. Do not
  branch, implement, or comment on the named issue — it was never touched, and
  its next `resolve-issue` run passes the precheck by itself.
- **Both** → **re-verify, then proceed**: re-run the precheck on the named
  issue and require `PROCEED` — a squash-merged PR closes its issue via
  `Closes #N`, but verify rather than assume (a blocker may have gained a new
  relationship
  while the chain was in flight; a merge may not have closed what you think
  it closed). Only on `PROCEED` continue to step 0b and the rest of the
  single-issue flow, exactly as if the precheck had passed first try.

### 0b. Readiness gate — is the story ready to build? (do NOT skip)

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

**Division of labour — the gate judges specification, 0a enforces sequencing**
(#800). One fact, one owner: step 0a (`dependency-precheck.zsh`) is the **sole**
enforcement point for whether a blocker has landed, and it has already run by the
time you reach here. The gate judges only whether dependencies are **declared**
natively and acyclic — it never fails a story because a declared blocker is still
open. So a `READY` verdict on a story with open blockers is not a contradiction:
0a rejected it already if it mattered. Never re-derive the sequencing question
from the gate's verdict, and never treat a `READY`-with-open-blockers story as a
gate malfunction.

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

**First — consume the `story-spec/v1` block if the issue carries one (#577).** A
refined issue (via `/development:refine-issue`) has a machine-readable
`story-spec/v1` block appended to its body (a collapsed `<details>` holding a
fenced `json` object, per the ARCHITECTURE.md *Story-spec contract*). When
present it is your **authoritative structured interface** — and you can trust it,
because step 0b's `story-readiness` gate already validated it against the prose
(a stale or contradictory block is a `NEEDS_REFINEMENT` reason, so it never
reaches here out of sync). Extract it with the robust primitive rather than
hand-parsing markdown:

```bash
gh issue view <N> --json body -q .body \
  | "<skill-base-dir>/scripts/read-story-spec.zsh" > /tmp/story-spec.json
case $? in
  0) : ;;  # block present in /tmp/story-spec.json — use it as below
  1) : ;;  # NO block (unrefined issue) — fall back to prose, this is normal
  *) echo "story-spec extraction errored"; exit 1 ;;
esac
```

- **`acceptance_criteria` / `testable_checks`** are the definition of done — they
  drive what your Step 3 validation must demonstrate.
- **`scope_boundaries`** (`in` / `out`) bound the change: implement what's `in`,
  and do **not** wander into what's explicitly `out`.
- **Dependencies are never read from the block** — they live only in native
  `blockedBy` (#583), already enforced by step 0a.
- The prose stays human-authoritative context; the block is the precise machine
  interface. They agree (the gate guaranteed it) — read the block for structure,
  the prose for nuance.

**Same-PR test-case lifecycle (#696).** When the block carries **linked**
`test_cases[]` (refinement defined them, #670, and spun them out as `test-case`
issues, #671), implement the feature **and** its acceptance tests in this one PR,
so tests and feature can never drift. Plan the acceptance tests from the block:

```bash
# feed the block (from read-story-spec.zsh) to the planner:
printf '%s' "$(cat /tmp/story-spec.json)" \
  | "<skill-base-dir>/scripts/plan-acceptance-tests.zsh" > /tmp/acc-plan.json
case $? in
  0) : ;;  # linked test cases — /tmp/acc-plan.json lists {issue, id, kind, tooling, dir}
  1) : ;;  # NO linked test cases — implement ONLY the story (fallback, see below)
  *) echo "acceptance-test planning errored"; exit 1 ;;
esac
```

For each plan entry, **write one acceptance test** for that `test_cases[]` case
into its `dir` (`tests/acceptance/<surface>/`, the #243 convention;
`curl`→`rest`, `grpcurl`→`grpc`, `playwright`→`web`, `cli`→`cli`). Draw
**representative test data** from the block's `use_case` and any referenced
persona `data_traits` (#668) — real-looking values, never `foo`/`bar`. The story
and its linked `test-case` issues are then **closed together** in the PR (Step 6:
one `Closes #N` for the story and for each plan entry's `issue`), so the tests
land with the feature. Standing up the `tests/acceptance/…` tree + its CI
execution is #243's concern — this step only writes into it.

**No linked test cases → story-only.** When the planner exits 1 (no block, or a
block whose `test_cases[]` carry no linked issues), implement **only the story**
and close only it — exactly as before. The lifecycle is an enhancement for
refined, surface-touching stories, not a precondition.

**Same-PR user-docs step (#767).** The same discipline applies to **end-user
docs**: a story that touches a runtime surface ships its docs update in the
same PR, so target-repo docs (seeded by bootstrap, #766) are born maintained,
not seeded-then-abandoned. Plan the docs work from the block:

```bash
printf '%s' "$(cat /tmp/story-spec.json)" \
  | "<skill-base-dir>/scripts/plan-user-docs.zsh" > /tmp/docs-plan.json
case $? in
  0) : ;;  # plan in /tmp/docs-plan.json — [] for a no-surface story
  1) : ;;  # NO block (unrefined issue) — no docs step, prose-only as before
  *) echo "user-docs planning errored"; exit 1 ;;
esac
```

The docs step applies when **all three** hold — otherwise it no-ops, and you
**report which fallback fired** (never fail the story over docs machinery):

1. the planner exited 0 with a **non-empty** plan (a `[]` plan is a
   `none`-surface story — docs, chores, refactors — with no user-docs duty);
2. the target repo **has the docs machinery** (`mkdocs.yml` at the repo root —
   the #766 bootstrap set). Absent → note "docs machinery not adopted yet
   (#766)" and continue story-only;
3. the story actually changes user-visible behaviour on that surface (the
   gate's check-5 classification already implies it).

For each plan entry, **add or update the named page**: extend the surface's
how-to page (`docs/how-to/use-the-<surface>.md`, the #766 seed) — or add a
sibling how-to page named for the story's job when the change deserves its own
"How do I …?" page. Seed the content from the block's `use_case` (and
referenced persona `data_traits`, #668) — the same representative data rule as
the acceptance tests: real-looking values, never `foo`/`bar`. **Register any
new page** in `mkdocs.yml`'s `nav:` and the `docs/index.md` MOC — the strict
docs build fails on an omitted page, which is exactly the drift-proofing the
step exists for. The docs change rides the same commit/PR as the feature
(Step 3 gates it, Step 6 reports it).

**Graceful fallback — no block (exit 1).** Most issues have never been refined
and carry **no** `story-spec/v1` block; that is **not** an error. Behave exactly
as before, deriving intent from the prose (and comments). Never stall on a
missing block, and never fabricate one — block-consumption is an enhancement over
the prose baseline, not a precondition.

Then, block or not: read the issue carefully and the files it names; read the
repo's conventions (`CLAUDE.md`, the surrounding code) and match them — comment
density, naming, idioms. **Also read the issue's comments** (`gh issue view <N>
--comments`): on a resume after a review-loop escalation (#564), the human's
decision lives in the comment thread — treat it as authoritative implementation
context. Make the change. This step is identical across languages because you
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
- any repo-specific check named in `CLAUDE.md`,
- **the same-PR C4 currency check (#746 child (c), #792)**: if the change
  altered the system's **structure**, `docs/architecture/c4-container.md` must be
  revisited in this same PR. The trigger is **working-tree detection, not the
  `elevated` risk gate** — `elevated` means security/auth/public-API/migrations/
  concurrency, which is orthogonal to structure (an auth fix is `elevated` but
  structurally neutral; a new service can score `normal`). Run detection on the
  working tree (writing to a scratch path **outside** the repo, so `detect.json`
  is never committed) and hand it to the comparator, which calls #790's parser for
  the declared set and compares it to #799's detected set:

  ```bash
  # Actually skip on a detection failure — never run the comparator on a
  # truncated/stale /tmp/detect.json.
  if "<skill-base-dir>/../bootstrap/scripts/detect-stack.sh" > /tmp/detect.json; then
    "<skill-base-dir>/scripts/check-c4-currency.zsh" --repo . --detect-json /tmp/detect.json
  else
    echo "detection failed — C4 check skipped; do NOT touch the diagram"
  fi
  #   0 + non-empty plan naming docs/architecture/c4-container.md → REVISIT it:
  #       update the Container diagram to match the new structure, in THIS PR
  #       (re-seed via bootstrap's seed-c4-diagrams.zsh, or edit by hand), then
  #       re-run the docs build (below) so the strict gate proves it coherent.
  #   0 + [] → no-op (neutral change, or detection inconclusive — the reason is
  #       on stderr). Touch nothing under docs/architecture/.
  #   1 → the repo has no docs/architecture/c4-container.md (hasn't adopted C4) —
  #       a reported no-op, not a failure.
  #   2 → usage error (fix the invocation).
  #   3 → a HARD error — read stderr: the parser named the declared block → fix
  #       docs/architecture/c4-container.md; otherwise the detection input is
  #       bad (bad/wrong-shape detect.json, jq missing) → fix that, NOT the diagram.
  ```

  When the plan demanded a revisit, updating the page is a docs change that the
  `mkdocs build --strict` bullet below must then gate (a page missing from nav, or
  a broken link, fails it) — so **run the docs build after this check whenever it
  demanded a revisit, even if the user-docs step (#767) no-oped**. Report which
  path fired in the PR body (the page touched, or the no-op reason).
- **the docs build, when the user-docs step ran (#767) OR the C4 check above
  demanded a revisit (#792)** — and, either way, only when the repo **has the
  docs machinery** (`mkdocs.yml` at the root, #766; a C4-only repo without it
  can't be built, so note it and skip): a docs page that doesn't compile is a red
  gate, same as a failing test. Run the target repo's own pinned toolchain —
  `pip install -r requirements-docs.txt` into a venv/scratch environment (never
  the system Python), then `mkdocs build --strict` at the repo root — so the
  PR-time `docs` check (#766's gate) can't fail on something the local gate
  passed. When **neither** trigger fired (no user-docs plan, and no C4 revisit),
  or the machinery is absent, there is nothing to build and the gate is unchanged.

**Run the full suite — unit *and* integration — not a unit-only subset.** A green
local gate must mean the **whole** suite is green: a subset run (e.g. `pytest
tests/unit`) can pass while the change silently breaks integration tests whose
fixtures exercise it, so the break stays invisible until CI / the Approver —
after the bot PR is opened and CI minutes are already spent, exactly the outcome
the local gate exists to prevent (#604). Run the whole suite, or at minimum the
changed behaviour's **full blast radius** across unit and integration; when in
doubt, run everything.

**When a `story-spec/v1` block was consumed (#577), its `acceptance_criteria` and
`testable_checks` are the concrete bar this gate must clear** — treat them as the
definition of done the tests have to demonstrate, not just the repo's suite
passing. If the change can't be shown to satisfy them, it isn't done. (With no
block, the prose acceptance criteria play the same role, as before.)

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
  dispatch plan from `review-dispatch.zsh` (§#560) and invoke the skill its
  descriptor names in `review_skill` (a language panel, or
  `development-claude-plugin:review` for a plugin repo — #809), scoped to
  `$REVIEW_SCOPE_FILE`, and write the aggregate findings JSON
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
writer token (`mint-maintenance-token.zsh` returns a mode-600 file **path**,
never the token value — #640), **push the branch as the bot**
(`git push https://x-access-token:$(cat "$TOKEN_FILE")@github.com/$REPO.git HEAD:$BRANCH`
— so the bot is also the last pusher, reading the token inline at the point of
use and never echoing it), open the PR with
`GH_TOKEN="$(cat "$TOKEN_FILE")" gh pr create` (author = the Maintenance App),
then `GH_TOKEN="$(cat "$TOKEN_FILE")" gh pr merge <n> --auto --squash
--delete-branch`. The PR body follows the template (Type / Summary /
Test plan — include the Step 3 evidence) and carries `Closes #N`. When the review
loop ran and converged (§3.5), append the **Review dossier** via
`build-dossier.zsh` on the kept status JSON (#563).

**Joint closure of the story + its test-case issues (#696).** When the same-PR
test-case lifecycle ran (Step 2's planner exited 0), the PR body carries **one
`Closes #N` per issue** — the story **and** every linked `test-case` issue from
the plan (`jq -r '.[].issue' /tmp/acc-plan.json`) — so the feature and its
acceptance tests close together and can never drift. With no linked test cases
(planner exited 1), it's the single `Closes #<story>` as before.

**Docs pages in the PR body (#767).** When the user-docs step ran (Step 2's
docs planner produced a non-empty plan and the machinery was present), the PR
body's Summary **names the docs page(s) the PR added or updated** (from
`jq -r '.[].page' /tmp/docs-plan.json`, plus any sibling page you added) — so
the reviewer sees feature + docs as one reviewable unit. When it no-oped,
say why in one line (`surface: none` / no story-spec block / docs machinery
not adopted yet) — an explicit no-op beats a silent one.

Outcomes:

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

**Native sub-issues are the source of truth for parenthood (#802)** — the same
contract #583 established for dependencies: declare it natively or it doesn't
exist. Read them through the shared reader, never by parsing the body (the
markdown task list stays as the human-readable view, but it is no longer
authoritative — exactly as prose dependencies stopped being after #583):

```bash
"<skill-base-dir>/scripts/read-sub-issues.zsh" --repo "$REPO" --epic <N>
```

It emits the native children (number, state) plus **`summary`**
(`subIssuesSummary { total, completed }`). Work only the **open** children
(skip closed/merged ones) — this keeps the skill **resumable**: re-running
continues from wherever a prior run stopped.

> **The terminal case branches on `summary` — deterministically, no
> inference.** Markdown parsing could never distinguish "no children were ever
> filed" from "all children are closed" (both yielded zero — #798's failure
> mode); `subIssuesSummary` answers it directly:
>
> | `total` | `completed` | State | Action |
> |---|---|---|---|
> | `0` | `0` | Not decomposed — or not backfilled | **Never proceed as-is** (classify below) |
> | `N` | `< N` | In progress | Resolve the open children |
> | `N` | `N` | Genuinely done | Do no child work → **E4**, then **E5** |
>
> The `total: N, completed: N` row is the genuine terminal case — and the step
> that's easy to miss: such an epic still sits OPEN until E5 closes it, because
> nothing carries `Closes #<epic>`. Native children closed against the epic
> **are** the positive evidence of merged work that closing requires.
>
> **`total: 0` never proceeds as-is — classify which zero it is first.
> Case 1 backfills and continues; cases 2-unrealized and 3 halt:**
>
> 1. **The body's task list holds `#N` children but none are native
>    sub-issues** — an **un-backfilled epic** (its children were declared
>    before #802's contract). Do **not** fall back to parsing the markdown:
>    run the backfill —
>    `"<skill-base-dir>/scripts/backfill-sub-issues.zsh" --repo "$REPO"
>    --epic <N>` (idempotent). **Always `--dry-run` first and sanity-check
>    the plan against the body**: a slice line whose `#N` is a parenthetical
>    *context* ref (e.g. "validation on the #717 constellation") is case 2,
>    not a child declaration — migrating it would misparent the referenced
>    issue (one parent only). **When the dry-run's `would_add` contains any
>    ref that is not a genuine child declaration, do NOT run the live
>    backfill** — halt and report (interactively: ask the human to fix the
>    body's task list so only child declarations remain), then re-dry-run
>    before migrating. After a live run, **gate on its outcome**: continue
>    only on exit 0 with every markdown child accounted for in
>    `added`/`already_present` **and `skipped_cross_repo` empty** — then
>    re-read through the shared reader and take the table's row for the new
>    `summary` (that continuation is what keeps E3's "all children, one
>    invocation" true). Otherwise **halt** with a summary comment naming the
>    unattached children: on exit 5 (partial) or 1, and equally whenever
>    `skipped_cross_repo` is non-empty — cross-repo children are
>    unmigratable here, and even when same-repo children attached fine
>    (`total > 0`), an epic with unattached cross-repo children must never
>    reach the `N == N` row's E4/E5 licence (the human attaches them
>    natively cross-repo, or descopes them from the task list). A partial
>    child set must never license closure. This is the migration hazard the
>    contract documents: treating an un-backfilled epic as "done" would
>    close never-started work en masse.
> 2. **The task list holds inline slices** (`- [ ]` describing work rather
>    than listing a child issue — no `#N`, or a `#N` that is only a context
>    ref, not the slice's own issue) — a supported pattern, realized by
>    separate PRs; slices are not issues, so nothing native can represent
>    them. **Confirm a merged PR for each slice.** All slices confirmed →
>    E4 + E5 as the `N == N` row. **Any slice unrealized → halt**: do not run
>    E4, do not close.
> 3. **No children were ever filed / no task list at all** — the epic has not
>    been decomposed. → **halt** and report that decomposition comes first.
>    Never invent children ("don't decide the user's issues for them").
>
> **Positive-evidence rule — never close an epic without evidence its work
> merged.** That evidence is native children all closed (`total == completed`,
> `total > 0`) or a confirmed merged PR per inline slice (case 2). Zero
> children is an *absence* of evidence and by itself licenses **nothing**. Do
> not look to E4 for this: E4 verifies that existing behaviour didn't regress,
> and a never-started epic passes it trivially — the suite is green because
> nothing changed, and there is no behaviour to exercise end-to-end because the
> feature doesn't exist. A verification gate cannot tell "the feature works"
> from "the feature was never built"; only positive merge evidence can.
>
> **The halt (cases 2 and 3).** Mirror E1b's halt: post a summary comment on the
> epic naming which slices are unrealized (case 2) or that no children are filed
> and decomposition is needed (case 3), build nothing, leave the epic **OPEN**,
> and stop. Re-running after a human files the children (as native sub-issues —
> new epics declare parenthood natively from the start) — or after the missing
> slices' PRs merge — resumes the flow normally.

### E1b. Readiness pre-flight — gate ALL children before building anything

Before any ordering or implementation, run the readiness gate over **every open
child**: spawn `story-readiness` (Task tool, `subagent_type: story-readiness`)
once per child — they're independent, so launch them in parallel in a single
message — and collect the verdicts.

- **All `READY`** → proceed to E2. Keep each child's `risk`; it rides along to
  that child's PR when you resolve it.
- **Any `NEEDS_REFINEMENT`** → the **epic is not ready; build nothing.** For
  each unready child, ensure the `needs-refinement` label and post its
  refinement questions as a comment (exactly as Single-issue step 0b does). Then
  post a **halt summary** on the epic — the checklist of which children are
  unready and why — and **stop**. One unready child means the epic is not ready.

Re-running after the stories are refined (criteria added, the `needs-refinement`
label cleared) continues the pre-flight from the still-open children — the gate
is as resumable as the rest of the flow.

> **A child with declared-but-open blockers is `READY`-but-queued — never a
> pre-flight veto** (#800). #583 *requires* declaring a prerequisite as a native
> `blockedBy` edge, so a **correctly sequenced** epic is one whose children carry
> open blockers — that is the epic doing its job, not a defect. If an open
> blocker halted the pre-flight, every dependency-ordered epic would deadlock
> permanently (only an epic with no internal sequencing at all could pass), and
> refinement could never clear it, because no human reply closes a blocker. The
> gate is aligned with this: check 3 judges **declaration and acyclicity, not
> closure**, so such a child gates `READY` on its own merits. **E2** then orders
> the children by the dependency graph, and **step 0a** enforces the wait when a
> child's turn comes — exactly what E3's sequential chain already does ("wait for
> it to merge … branch the next off the fresh tip"). Halt the pre-flight only for
> a genuine specification gap.

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

The same triage applies when a child's **dependency precheck rejects it**
(§0a): epic-driven resolve is autonomous, so the rejection posts the child's
`blocked` comment + label, the child is **parked** — never auto-chained past —
and the run continues with the children that don't depend on it.

**End every run with an epic summary comment** — one comment on the epic listing
**merged / escalated / parked** children (and any still queued), so the epic's
state is legible at a glance. Then:

- **All children merged** → proceed to **E4** (holistic verification) and **E5**
  (close the epic). A re-run that finds **zero open children** does no child work
  — but it goes to E4 + E5 **only** once E1 confirms the children were filed and
  merged (the table's `total == completed > 0` row — native children all
  closed), or every inline slice's PR is confirmed merged (case 2). Zero
  children on its own is never the licence; cases 2-unrealized and 3 halt
  there instead.
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
  done-but-open epic is the most common miss; the final re-run exists to verify
  and close it.
- **Never close an epic without positive evidence its work merged** — closed
  `#N` children, or a confirmed merged PR per inline slice (E1's
  classification). **Zero children never licenses E5 by itself**: a
  never-decomposed epic and an all-merged one enumerate identically, and E4
  cannot tell them apart (it passes trivially when nothing was built). Cases
  2-unrealized and 3 **halt** with a summary on the epic instead.
- **Dependencies gate first** — the 0a precheck rejects on open GitHub-native
  blockers (and refuses cycles) before anything is branched; in autonomous mode
  the rejection is a typed comment + `blocked` label, and an unattended run
  **never auto-chains** into resolving the blocker itself. Interactive runs get
  the guided offer (§0a remediation) — resolve blocker + named issue, or just
  the blocker — but remediation only ever starts from an explicit human choice,
  and cycles are never remediated. An epic-kind blocker remediates as a
  **whole epic** — the full Epic flow to a closed epic (E4/E5 included) before
  the dependent proceeds; never one child, never a reimplementation of the
  epic's ordering.
- **Gate before you build** — the `story-readiness` gate runs next (single-issue
  step 0b; epic pre-flight over all children). A `NEEDS_REFINEMENT` verdict posts
  refinement questions + the `needs-refinement` label and **stops** — never
  branch or implement past it, and for an epic never build *any* child while one
  is unready.
- **The gate judges specification; 0a enforces sequencing** (#800) — one fact,
  one owner. The gate never fails a story for a **declared-but-open** blocker
  (that is 0a's call, already made); it fails only for an **undeclared** or
  **prose-only** dependency, or a **cycle**. So a child with open blockers is
  `READY`-but-queued and **never** vetoes the E1b pre-flight — otherwise every
  dependency-ordered epic, which #583 requires you to sequence natively, would
  deadlock forever.
- **Don't decide the user's issues for them** — if a single issue is ambiguous,
  the gate sends it back for refinement rather than guessing a large or
  contentious change into a PR.
