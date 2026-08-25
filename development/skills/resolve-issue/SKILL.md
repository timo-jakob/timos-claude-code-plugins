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
  issue (nothing auto-closes it). Repo-type-agnostic (Swift / Python / Java /
  Go / Claude-plugin / Kubernetes). Composes git-branch-naming, commit, and open-pr; never pushes
  to the default branch. When a human is driving, a `BUDGET_EXHAUSTED` /
  non-converging review-loop exit becomes an interactive extension (offer more
  rounds, give guidance, ask questions). A run whose only remaining blockers are
  non-critical and confined to its own last fix pass ends
  `CONVERGED_WITH_RESIDUE` (exit 14) instead — declarable only from the closing
  full sweep, so a delta round that qualifies promotes that sweep first: it opens
  the PR and files the remainder as labelled follow-up issues — see [The local
  review
  loop](https://timo-jakob.github.io/timos-claude-code-plugins/explanation/review-loop/).
disable-model-invocation: false
---

You turn a filed **issue** into a merge-ready **PR** — or an **epic** into a
sequence of them — with the story **gated for readiness up front** and the
implementation **tested before it is ever committed or pushed**. You
**compose** existing skills rather than reinvent them: `story-readiness` for
the readiness gate, `git-branch-naming` for the branch, the `commit`
conventions for the message, and **`/development:open-pr`** for the
bot-authored PR. The novel part is the gate → branch → implement → validate
flow, plus the epic orchestration.

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
  epic, see E1) → go to **Epic flow**. A **child line is a checkbox whose
  content STARTS with the issue reference** (#1260) — a checkbox that merely
  *mentions* an issue somewhere in its text is an **acceptance criterion**,
  not a child, and lines inside fenced code blocks don't count at all. Judge
  it by that rule and nothing looser: a well-specified story routinely cites
  sibling issues in checkbox-shaped criteria, and counting those routes it
  into the Epic flow with no children to decompose. `read-dependencies.zsh`
  codifies the rule (see ARCHITECTURE.md, *Issue-dependency model*) — read it
  there rather than re-deriving it. Several **near-miss** shapes are
  deliberately **not** child lines — a bare **issue URL**, an **ordered-list**
  checkbox (`1. [ ] #687`), a **decorated** ref (`- [ ] **#687**`,
  `- [ ] [#687](url)`), and a ref glued to the **checkbox** or to a following
  **word** (`- [ ]#687`, `- [ ] #687x`). *Why* each is excluded — whether the
  backfill could not migrate it, or the classifier is deliberately stricter
  than a backfill that would — is recorded once, per shape, in ARCHITECTURE.md
  (*Issue-dependency model*); **read it there, and never restate the split
  here**, because your action is the same for every one of them.

  **Native sub-issues and the `epic` label always win.** When either is
  present, go to the **Epic flow** regardless of the body's shape — the
  markdown list is only the human-readable view. With the `epic` label and no
  native sub-issues, E1's `total: 0` classification handles a near-miss body as
  case 4; with native sub-issues present the body is not consulted at all,
  because native parenthood is authoritative (#802).

  **A genuine child *declaration* wins over any near-miss line beside it.** If
  the body holds **at least one** `- [ ] #N` line that matches the rule **and
  declares that issue as this epic's work**, it is an epic — go to the **Epic
  flow**, where E1 judges case 1 first. The near-miss branch below is only for
  a body with **no** such line. The rule is a *shape* test and the classifier
  script cannot see intent, so matching it is necessary but **not sufficient**:
  `- [ ] #937's seam is implemented` matches the rule (the ref is at the head
  of the item, and `'` closes the `\b`) yet is plainly an acceptance criterion.
  Read the intent test below before concluding "epic" from any single line.

  **Shape alone never triggers the near-miss branch — intent does.** It
  applies only when *all four* hold: **(0)** **no** child-shaped line in the
  list is a rule-matching child *declaration* (a rule-matching line that states
  a condition about an issue is a criterion, not a declaration, and so does not
  block this branch; the shapes above are the common examples, not a
  closed set — a child-shaped line in none of them, such as `- [ ] TBD: file
  the auth child`, halts here too rather than falling through to the
  Single-issue flow); **(1)** such a list is the **sole** epic signal (`summary.total == 0`,
  no `epic` label); **(2)** it is plainly the epic's **children declaration**
  (a Children/Sub-issues/Tasks section whose items are separate **issues** — a
  *Slices* section, whose items are work descriptions rather than issues, is
  never a children declaration: that is E1 case 2, and this branch does not
  apply to it); and **(3)** it is not acceptance criteria. **A checkbox that
  states a condition about an issue is a criterion however it is written** —
  decorated or bare, matching the #1260 shape rule or not. Both
  `- [ ] **#937**'s seam is implemented` and `- [ ] #937's seam is
  implemented` are criteria, not children, so they route to the Single-issue
  flow like any other — the second matches the shape rule, which is exactly
  why intent, not shape, decides. Getting this backwards would
  refuse an ordinary refined story outright, which is #1260's own defect
  wearing a new coat. When all four do hold: **stop** — run neither flow on
  it. Interactive: ask the human to attach native sub-issues, or to rewrite
  the list as `- [ ] #N`. Autonomous: post the finding as an issue comment and
  stop; never widen it into a single-issue implementation of an epic body.
  **A checkbox that states a condition *about* an issue is a criterion, not a
  child declaration** — a body whose checkboxes are all criteria is not an epic
  signal at all (condition (3) above), so it takes the Single-issue flow **even
  when some of those lines match the #1260 shape rule**. That
  is the *intent* test, not a citing test: a body whose checkboxes are a
  children **declaration** in a near-miss shape halts as above, even though
  those lines cite issues too. An epic that declares its
  work as inline slices (E1 case 2) likewise reaches the Epic flow only via the
  `epic` label or native sub-issues. On a **failed** `read-sub-issues.zsh` call,
  **exit 2 is your own bad invocation** — fix the command and re-run, the same
  rule E1, E3 and §0a apply to their scripts. **Any other nonzero exit is a
  classification failure** — report it and stop; never fall back to
  the label/task-list signals as if the native signal were checked and
  absent (a native-only epic would misclassify as a single issue).
- Otherwise → **Single-issue flow**.

Operate on the **session's repo** (`gh repo view --json nameWithOwner`); the
issue must belong to it. If `$ARGUMENTS` is empty, print the invocation help
(`/development:resolve-issue <issue-number|url>`) and stop.

## Single-issue flow

### 0a. Dependency precheck — reject unless the graph is clean (do NOT skip)

Dependencies are enforced from **GitHub-native `blockedBy` relationships** —
the single source of truth (#583); prose declares nothing. Before anything
else — before the readiness gate, before any branch exists — run the precheck:

```bash
"<skill-base-dir>/scripts/dependency-precheck.zsh" --repo "$REPO" --issue <N>
```

It wraps the shared reader (`read-dependencies.zsh`, #584) into one typed
decision (JSON on stdout; like the readiness gate it performs **no** GitHub
writes — this skill does the posting):

- **`PROCEED` (exit 0)** — the graph was **fully walked** and no open blocker
  was found. Clear a stale `blocked` label if
  one is present (`gh issue edit <N> --remove-label blocked 2>/dev/null ||
  true`) and continue to step 0b exactly as today.
- **`REJECT_BLOCKED` (exit 10)** — has **two shapes**. Do **not** branch or
  implement in either.

  **(i) An OPEN blocker was enumerated** — at least one entry with
  `open: true` in `blockers` or `foreign_blockers`. The decision JSON's
  `comment_md` is the ready-to-post argumentation naming each open blocker.
  Handle it as the rest of this step describes.

  **(ii) No OPEN blocker** — no `open: true` entry in either array (however
  many **closed** ones are listed), and `cycles` empty. The gate rejected on
  something it **cannot name**, for one of two
  reasons, and `comment_md` says which:

  Key the split on **open**, not on the arrays being non-empty: `comment_md`
  builds its list with the same `open` test, so a document listing only
  **closed** blockers renders the shape (ii) wording — *No blocker could be
  enumerated* — while matching a non-emptiness test as shape (i). Reading it as
  (i) sends you into a remediation whose question must "name the open blockers"
  with none to name and whose chain has no rungs, and "just the dependency"
  then reports a chain cleared that was never resolvable.

  - **`truncated: true`** — the walk was cut short by the depth cap, so the
    empty arrays are evidence of **not having looked**, not of no blockers.
  - **`truncated: false`, `reader_blocked: true`** — the reader itself reported
    `blocked` for a reason none of the gate's own counts covers. The gate
    consumes that verdict rather than only re-deriving it, so a new reader
    reason rejects by default.

  Read `truncated` / `reader_blocked` to tell them apart — never guess, and
  never treat an unexplained empty set as a malfunction.

  Both are the same fail-closed rule as an open cross-repo blocker, and both
  are handled identically: there is nothing to remediate and **no rung to
  run**. Do **not** offer remediation, and never read the empty arrays as a
  malfunction and continue to 0b. Report the cause `comment_md` names and stop
  — interactive, in the conversation; autonomous, post `comment_md` (which
  says *No blocker could be enumerated*) and the `blocked` label. Do not
  promise the re-run will pass: on a truncated walk it needs a larger
  `--max-depth` or a shorter chain, and on a reader verdict it needs whatever
  the reader is seeing, which this gate cannot enumerate.

  **A blocker may live in another repository.** The reader is bound to one, so
  a cross-repo blocker is reported in `foreign_blockers` (`owner/name#M`) and
  is **never** in `open_blockers` — a bare number means nothing outside its own
  repo. An **open** one rejects all the same: the gate cannot verify it, and a
  gate that cannot verify must never report ready. It also cannot be
  remediated from here — its own blockers were never enumerated, and this
  skill's flows operate on the session's repo. Report it and let the human
  resolve it in its own repository; **never** re-run `resolve-issue` on the
  bare number against this repo, which would target whichever local issue
  happens to share it.
- **`REJECT_CYCLE` (exit 11)** — the blocked-by graph contains a cycle, which
  no order of work can satisfy. Same handling as `REJECT_BLOCKED` shape (i);
  the `comment_md` names the cycle. Refuse — never try to loop through it.
- **Any other exit is NOT a pass**, and the two codes end differently. Every
  one of these paths prints **nothing** on stdout, so a caller checking only
  for the three decision strings sees an empty document and no rejection —
  **never continue to step 0b on an empty decision document**, and never post
  the `blocked` label from either code.
  - **`2` is *your own* malformed invocation** — an empty `--repo`, a dangling
    flag, a bad `--max-depth`; the reader's own usage error is re-raised as 2
    rather than laundered into 1 precisely so it reads as *fix the call*, not
    *retry*. **Fix the command and re-run the precheck for this issue.** Stop
    and report stderr plus the invocation only if it exits 2 again, or you
    cannot see what is malformed. This is the same rule E1 applies to the
    backfill's exit 2 and E3 to a child's.
  - **`1` is an internal failure** (jq missing, the reader failed, a document
    that could not be read or emitted). Stop the flow and report the script's
    stderr; do not re-run.

On either rejection **of shape (i)** — a shape (ii) rejection already stopped
above, and has no remediation — what happens next depends on who is driving:

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

**Interactive remediation.** Read it when this step rejects with shape (i) and
a human is present:
see `reference/interactive.md` § Interactive remediation — offer to clear the blockage (#586, #587)

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
whole point, and it is far cheaper than after five review rounds converge on
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

### 1b. Detect the repo type and load the profile

The conductor is repo-type-agnostic; the rules true of **one** repo type live in
that type's own plugin, as a `resolve-profile` skill. Load this repo's before you
implement, so §3's gate command and §4's version bump are the ones this type
actually uses:

```bash
"<skill-base-dir>/scripts/review-dispatch.zsh" detect --repo .
# {"repo_type":"claude-plugin"}   ← the whole document; no diff, no --base
#   0 → use .repo_type below
#   2 → your OWN malformed invocation: fix the command and re-run
#   1 → internal failure: report the script's stderr and stop. The same
#       detector runs again at §3.5, so there is nothing here to salvage by
#       continuing — this arm is fail-closed on purpose.
#   3 → a repo whose TYPE could not be determined: the typed unsupported/
#       ambiguous object is on stdout — the same condition §3.5's `plan` raises,
#       from the same detector. Relay that object verbatim, load NO profile,
#       then add exactly ONE narration line — `repo type could not be determined
#       (<the object's error>); continuing with the conductor's generic rules` —
#       and CONTINUE. That line is NOT the missing-profile notice below: that
#       notice names a type, and this arm has none to name. The two conditions
#       are never narrated as each other, in EITHER direction — which is the
#       same rule the `unsupported_repo_type` guardrail below states from the
#       other side.
#       Stopping here would be the new typed refusal this step deliberately does
#       not introduce; if the run reaches §3.5, `plan` raises the same object
#       again and the loop escalates it as `ESCALATE_AMBIGUOUS` — which is where
#       that decision belongs.
```

Then invoke **`development-<repo_type>:resolve-profile`** by name (the Skill
tool), exactly as the maintenance orchestrator loads
`development-<lang>:maintenance`. Its `##` heading roster **is** the contract,
and it is stated in ARCHITECTURE.md's *Resolve profile contract* and in each
profile — **and nowhere else**. Read the roster there; naming it here too would
be one more copy to drift.

**Only the first two headings in that declared order have a dereference site
today** — §3 and E4 point at the first, §4 at the second. The **third** merely
*records* the panel `review-dispatch.zsh plan` already computes, and is never
dereferenced (ARCHITECTURE.md states that). The remaining three have no
dereference site at all; **#1506 decides which of them acquire one** (the
claude-plugin profile already records that at least one of them has nothing to
extract). Until then, a profile that populates one of them carries a rule no
step is told to consult — so:

- **A heading in one of those last three positions is `none` when its body
  BEGINS with `none`.** Qualifying prose after that word — a pointer, a reason,
  a `none beyond X` — does **not** make it non-`none`. The shipped claude-plugin
  profile writes exactly that shape.
- **A heading in one of those three positions that is non-`none` by that test:**
  do not apply its rule (no step is contracted to consult it), **file an issue
  against #1506** naming the profile and the heading, and continue. *File* means
  open an issue — never add the dereference to this conductor yourself, which is
  both out of scope and a charge against its line budget.
- **The first three positions are never filed against #1506** and their rules
  are always applied: two are dereferenced by §3, §4 and E4, and the third is
  deliberately a record. Nothing above licenses skipping them.

The headings are referred to here by POSITION rather than by name on purpose —
naming them would be the extra copy this section just said not to make.

**A missing profile is a fallback, never a refusal.** Most repo types have no
profile yet (#1505). When the skill does not exist, emit **one line** naming it
— `no resolve-profile for repo type <repo_type>
(development-<repo_type>:resolve-profile); continuing with the conductor's
generic rules` — and **continue**. Nothing is blocked, nothing is escalated, and
no PR is withheld over a missing profile.

**`unsupported_repo_type` is not reused here.** That name remains exclusively
`review-dispatch.zsh`'s exit-3 condition — a repo whose *type* could not be
determined — and a missing profile is a different fact about a type that **was**
determined. Keeping the two apart is what stops a later reader collapsing the
fallback above into a typed refusal.

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

**Sibling-sweep when you fix (#982).** When a change — or a review finding you're
resolving — targets one instance of a repeating *pattern*, sweep the diff for
**every sibling instance of the same pattern and fix them all in the same
round**. Never fix one exemplar and leave its siblings for a later round: that
one-instance-per-round dribble is exactly what dragged the #976 loop across
extra rounds (the same defect pattern reported and fixed one variant at a time).
The test- and script-reviewer prompts now enumerate all instances of a pattern
per round; your fix pass must clear all of them per round to match.

### 3. Validate — the per-issue gate (do NOT skip)

Run the repo's own test + lint gate and **only proceed when green**. Green
gates **consolidating and committing**, not dispatching the panel: from §3.5's
round boundary on, this gate runs while that round's reviewer panel is already
working — *The round boundary is concurrent* (§3.5), which states the ordering.
Round 1's boundary therefore **begins here**, and what it starts is the
**whole-suite `<full gate>` alone**, not this whole list: run the checks below
that **write** into the tree first — `pre-commit` with fixing hooks, any C4
revisit, the docs build — then mint `T` (the round boundary's step 1) and start the
suite. Where the *suite itself* writes, §3.5's *The `<full gate>` SUITE writes
into the tree* bullet governs instead and the mint follows the gate. Detect what
applies and run it — the boundary's own procedure, including the mint command,
the launch properties and the four `--gate-attest` rules, is on-demand reading:
see `reference/review-loop.md` § The round protocol

- pre-commit hooks (`pre-commit run --all-files`, or the staged subset),
- tests for the stack — the **whole suite**, never a subset. The blessed gate
  command for this repo's type — what to capture from it, and any degraded mode
  it must relay to the user — is the profile's:
  profile: `development-<repo_type>:resolve-profile` § Gate
  **If you reached this step without having run §1b at all, run its `detect` +
  load NOW** and use whatever that yields — the floor below applies only if that
  leaves you with no profile, and a LOADED profile's command is never
  substituted for.
  **With no profile loaded** — §1b's missing-profile fallback, **or its exit-3
  arm** (a type that could not be determined has no profile to name either) —
  use the stack's usual whole-suite command:
  `pytest` (Python — the whole suite, **not** `pytest tests/unit`),
  `./gradlew test` / `build` (Java/Gradle), etc.; for a repo type whose blessed
  command is stated in the round protocol rather than in a profile, take it from
  there rather than inventing one,
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
  # Branch on NON-ZERO, never on a specific code (#1177), and FORWARD
  # detect-stack's stderr: its non-zero exit carries its whole meaning there
  # (which search could not complete), and a generic "detection failed" drops
  # the one diagnostic that names the cause.
  if "<skill-base-dir>/../bootstrap/scripts/detect-stack.sh" > /tmp/detect.json; then
    "<skill-base-dir>/scripts/check-c4-currency.zsh" --repo . --detect-json /tmp/detect.json
  else
    echo "detection failed — C4 check skipped; do NOT touch the diagram"
    echo "  (relay detect-stack's stderr above verbatim — it names the cause)"
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

Once §3's gate is **under way**, run the **local review loop** before
committing or pushing anything, so a PR is only opened on code a reviewer panel
has already converged on (no CI minutes spent on unconverged work). *Under way*,
not *green*: the round boundary starts the gate and the panel together (below),
and it is **consolidation** — never the panel — that waits for green. Drive
`development/skills/resolve-issue/scripts/resolve-story-loop.zsh` — the
state machine (constants `MAX_REVIEW_ROUNDS=5`, `BLOCKING_SEVERITIES=(CRITICAL
WARNING)`) — in **step mode** (#971): one invocation per round, with every
model-driven step done **in-session, where the user can watch it**. Two hard
rules: **never** shell out to a headless `claude` (`claude -p` / `--print`)
for any model-driven step, and **never** run the loop as a long-lived
background task spanning rounds. The user must be able to see rounds happen:
visible review agents, visible fix edits, a narrated summary per round.

Both rules are about **model-driven** steps. The **gate** is not one — it is a
deterministic test run that only reads the tree — which is why the round
boundary below runs it in the background on purpose. The loop invocation, the
panel and every fix pass stay in-session where the user can watch them.

**At loop start, tell the user where to watch:** the loop appends one block per
round to `<work-dir>/progress.md` — say so once, e.g. "follow along with
`tail -f <work-dir>/progress.md`".

**The round protocol.** The round boundary, each round's panel, the loop
invocation template, the `AWAITING_FIX` turn and the hand-off to a terminal are
on-demand reading, taken when you reach this step:
see `reference/review-loop.md` § The round protocol

(Hook mode — `--review-cmd`/`--fix-cmd` — still exists as the bats test seam
only. Never wire it to a headless `claude`.)

Pass `--issue <N>` too: the loop appends one `telemetry/v1` record per
**terminal exit** (none on `AWAITING_FIX` / `STALE_FINDINGS`; an extended
loop emits one per escalation, plus a final one only if it later reaches a
different terminal status — a run whose human declines the grant ends ON its
last escalation, so that record is its final one, not an extra) to the shared sink
`.claude/telemetry/telemetry.jsonl` (git-ignored, #566/#1004) — via the family's
shared emitter, with the loop's own detail under `payload` and its status
narrowed onto the cross-pipeline `outcome` enum. Evidence for
convergence rate, rounds-to-converge, and escalation breakdown. **A promotion
sub-loop (#994) is a second, terminal invocation with the same `--issue`, so a
story that promotes anything appends its own record too** — read the pair
together rather than as two independent stories — with one caveat: a phase
whose keys **all** fall out unmatched/unverified never invokes the sub-loop
(step 4's *If NONE matched* terminal), so it legitimately leaves the enrichment
with no second run record to pair with. That second record carries
`payload.promotion_phase: true` (#995), which is how the two documented
convergence-**rate** recipes exclude it. The mean-rounds and escalation-breakdown
cuts deliberately **keep** it — a promotion pass genuinely did those rounds
(ARCHITECTURE.md, *Review-loop telemetry*). Every terminal exit that emits a
record also drops that record's `run_id` in `<work-dir>/.telemetry-run-id` — the
join key the promotion enrichment below needs. **Always pass an
explicit `--work-dir` and `--status-file` (paths you remember)**: the work-dir
is the loop's resumable state and the status file its verdict — the interactive
extension below re-invokes the loop with `--resume` on the *same* work-dir, and
a defaulted `mktemp` dir is unrecoverable after the run exits.

The loop consolidates each round (`consolidate-findings.zsh`, §#561) and exits
with a status JSON + code:

- **`CONVERGED`** (exit 0) → on an **interactive** run with at least one waived
  suggestion, first offer the **suggestion promotion** phase below (#994) —
  unless this loop *is* the promotion sub-loop, which never re-offers it (the
  phase runs once per story); then proceed to **§4 (Version bump)**. **Keep the
  loop's status JSON**
  (`--status-file`) — step 6 feeds it to `build-dossier.zsh` so the **Review
  dossier** (per-round blockers found/fixed, dimensions reviewed, waived Low
  suggestions, reviewers) lands in the PR body, with a hidden JSON block the
  Approver re-ingests (#563).
- **`CONVERGED_WITH_RESIDUE`** (exit 14, #1435) → **also a convergence: it opens
  the PR.** The loop reached an ending that would otherwise have been
  `ESCALATE_NO_CONVERGENCE` or `BUDGET_EXHAUSTED`, and found all THREE residue
  conditions met: its last two rounds were both zero-CRITICAL, every remaining
  blocker sits in a file the previous round's own fix pass wrote, **and the
  declaring round ran as a full sweep** (§9 — a delta round meeting the first two
  promotes that sweep instead of ending here, so this exit always speaks for the
  whole story diff). Rather than spend a human grant on
  material the reviewers themselves called non-critical, the run ships and files
  the remainder. Do **not** build an escalation comment, do **not** enter the
  interactive extension, and do **not** re-run the loop: this is a terminal
  success, and `build-escalation.zsh` has no arm for it by design. Continue
  exactly as `CONVERGED` does — the suggestion-promotion offer (its gate is
  unchanged) and the kept status JSON for the dossier — and then, **after that
  phase has resolved and immediately before §4**, take the **residue branch**
  below. Last, not first: it is the only step here that writes to GitHub before
  the PR exists, and a promotion sub-loop can still escalate into a run that
  opens none.
- **`AWAITING_FIX` (20)** → not a verdict — the step-mode "narrate, fix
  in-session, `--resume`" turn of the round protocol above. Never build an
  escalation comment from it.
- **`STALE_FINDINGS` (exit 2)** → neither a verdict nor an escalation — the
  round was never really reviewed (missing/empty on `--resume`, byte-identical
  to the last round, `--findings-file` aliased the dispatch `findings_path`,
  — #1434 — an empty delta with nothing carried to verify, or a **full** round
  whose panel produced no findings file at all, or — #1435 — the
  `--findings-tree` you attested disagrees with the working tree, so the panel
  read one tree and you are consolidating against another). Recover **by cause**
  per §3.5's *Each round* step 2 before re-invoking: several causes are **not** cleared by
  re-running the panel — an empty delta with nothing carried, an aliased
  `--findings-file`, and a panel that reported NOT APPLICABLE on a full round —
  while the cadence cause is cleared *only* by re-running it (against the current
  tree) or by discarding the fix that moved the tree. **Never** build an escalation comment or a
  dossier from it.
- **`ESCALATE_CONFLICT` / `ESCALATE_NO_CONVERGENCE` / `ESCALATE_AMBIGUOUS`
  (10–12) / `BUDGET_EXHAUSTED` (13)** → do **not** commit or open a PR — go to
  *Escalation* below. Opening a PR here would spend CI on unconverged work.
  On an interactive run, `BUDGET_EXHAUSTED` and `ESCALATE_NO_CONVERGENCE` first
  enter the **interactive extension** (offer more rounds / guidance) before any
  comment; the others, and all autonomous runs, go straight to the typed comment.

`--no-review` skips the loop entirely (status `SKIPPED`) — and is **refused
together with `--promote`** (exit 2), since nothing is consolidated for an
overlay to reach. Today's fast path,
for when you deliberately want no local review round.

**The procedure behind each terminal is on-demand reading** — take it when
that terminal is reached, not before. On an interactive run that exited
`BUDGET_EXHAUSTED` or `ESCALATE_NO_CONVERGENCE` the extension is taken FIRST,
before the escalation terminal, so it is listed here rather than reachable only
through the file that comes after it:

- see `reference/residue.md` § Residue branch — file the remainder, then ship (#1435)
- see `reference/promotion.md` § Suggestion promotion on convergence — human-curated, opt-in (#994)
- see `reference/interactive.md` § Interactive extension (#562-resume)
- see `reference/escalation.md` § Escalation (any `ESCALATE_*` / `BUDGET_EXHAUSTED` status) — typed, no PR (#564)

### 4. Version bump (plugin content only)

The rule is the repo type's; the heading stays here as the anchor the reference
files' `§4 (Version bump)` cross-references resolve to:
profile: `development-<repo_type>:resolve-profile` § Version bump

**With no profile loaded**, however you got here — §1b's missing-profile
fallback and **its exit-3 arm** are the two ordinary ways, and a resumed session
re-entering here is a third — this step is still not skipped: a change to
installable plugin content (`<plugin>/…`) bumps that plugin's
`plugin.json` **and** its matching `.claude-plugin/marketplace.json` entry in the
same PR, per the version-bump convention. This is a **floor, not a second
owner**: when a profile IS loaded its Version bump heading supersedes this
paragraph entirely — including the sizing tiers and any type-specific exception,
which this floor deliberately does not state. MAINTAINING.md remains the
authoritative statement of the tiers themselves.

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
loop ran and reached a **PR-opening** terminal (§3.5) — `CONVERGED` **or**
`CONVERGED_WITH_RESIDUE` (#1435); those two, and no escalation — append the
**Review dossier** via
`build-dossier.zsh` on the kept status JSON (#563) — appending its output
**once**, whether or not the suggestion-promotion phase also ran. Two hidden
blocks in one body would leave the Approver reading only the first. (Once-only
governs the *appended output*: an un-appended wrong-form run is discarded and
re-run correctly — open-pr's recovery.) When the
run **kept a promotion-phase status JSON** — one it wrote and did not discard,
step 8's condition — that single invocation merges both phases (#1064) by
also taking the pair `--promotion-status <promotion-status.json> --promoted
<promoted.json>`. Otherwise — including the *If NONE matched* terminal, where
the sub-loop was never invoked even though the phase was offered and its prompt
answered — it is the plain `--status` invocation. State it as the artifact, never
as "the phase ran": that phrase is true on *If NONE matched* and would send you
hunting for a status file to pass, which is exactly how a reused-scratch leftover
gets folded into the audit record. Passing one promotion flag without the other is a usage
error, not a fallback.

**Residue in the PR body (#1435).** When the **blocking phase** ended
`CONVERGED_WITH_RESIDUE` — the only phase that can, since the loop never declares
residue in a promotion sub-loop — the Summary **names the residue ending**, how many
follow-up issues were filed **and their numbers**, and the parent they were
attached to. A residue PR that reads like an ordinary converged one is the single
outcome this path must not produce — it is the first ending that opens a PR
without a human seeing an escalation, and the body is where that is disclosed.
Report the honest shape when the filing did not fully succeed, too: an empty plan
(everything was already filed — name those pre-existing numbers), a **partly
filtered** plan (some candidates were filed by an earlier run: name both sets and
account for `open`, per the residue branch step 5), a builder failure (name the remaining
blockers from the status JSON's `final_changelist.blocking` so they are not
lost), a fail-open warning (a re-run may duplicate), or issues created but not
parented — an unparented issue is never *filed*, so it counts as untracked when
you apply the remainder rule, which is keyed on `final_changelist.blocking` and
not on the plan's entries.
The dossier rendered in the same body carries the terminal and the per-dimension
`open` counts, so the Summary must not contradict those **counts** by implying
the remainder was fixed.

**Agreeing counts are not the whole duty.** The dossier's *wording* — "each was
filed as a labelled follow-up issue", and per dimension "N still open (filed as
follow-up issue(s))" — is gated on the **status alone**, so it renders
identically whether the filing succeeded or never happened; `build-dossier.zsh`
has no way to learn which. What the Summary owes on top of the counts is decided
by **`reference/residue.md`'s remainder rule** — count how much of
`final_changelist.blocking` is
filed (created AND parented, from this run or an earlier one) and take that row:
none → the verbatim override sentence above the dossier; some → the
reconciliation; all → the issue numbers.

Read the rule there rather than a copy here, and never re-derive it from which
arm the run took. A narrative mention of a filing failure does not discharge the
verbatim sentence either: the machine-readable `open > 0` beside it is what
`approver-policy-core` reads as scoped, disclosed, **tracked** risk, so only a
sentence that contradicts the claim in words can override it.

When the promotion **prompt was presented**, **name in the Summary** both
counts — **how many suggestions the human picked, and how many the sub-loop
actually cleared**; whenever the selection was **non-empty**, add step 4's
unmatched / unverified split — the *If NONE matched* terminal **included**,
where every key is one or the other and the split carries all the information
there is (step 4 requires it there explicitly, and the dossier carries no
promotion record on that terminal to back it up). Gate the split on step 4
having classified, never on the sub-loop having run. (Only a select-none answer
— prompt presented, nothing picked, step 4 never reached — is `0` and `0` with
no split to report.)

**The cleared count is the ENGINE's raised count** — `promotion.promoted`, the
number of items it stamped — and `0` on the *If NONE matched* and
not-reproducible terminals. It is **never** the sub-loop's total `fixed`, which
also counts regressions cleared along the way; and it is **not** the raw size of
step 4's matched set. That distinction is the one to get right: step 4's
*matched* class is your approximation of the engine's #983 verdict, so the engine
can raise **fewer** keys than you classed matched, and the sub-loop then
converges at round ≥2 having cleared only those. Since the dossier rendered in
the same PR body carries the engine's figure, reporting the larger matched set
would make the PR contradict itself. So report the engine's count, and name every
matched-but-never-raised key as promoted-but-not-reproducible — step 7's
vocabulary.

The two Summary counts are **not** the same number: the *If NONE matched*
terminal converges with a non-zero pick count and a sub-loop that never ran, so
reporting the picks alone would claim work that never happened. A select-none
answer is `0` and `0`.

The dossier now carries the promotion phase itself, so **no "blocking phase
only" caveat is owed** — but the Summary counts still are, because the dossier
never carries step 4's **matched / unmatched / unverified** split or the
promoted-but-not-reproducible naming, and on the *If NONE matched* terminal it
carries no promotion record at all.

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
> | `N` | `N` | Genuinely done | Do no child work → **E4**, then **E5** — unless the body also holds inline slices, which each need a confirmed merged PR first |
>
> The `total: N, completed: N` row is the genuine terminal case — and the step
> that's easy to miss: such an epic still sits OPEN until E5 closes it, because
> nothing carries `Closes #<epic>`. Native children closed against the epic
> **are** the positive evidence of merged work for the **children** half; when
> the body also holds inline slices, each slice's merged PR is required too —
> see the positive-evidence rule below.
>
> **`total: 0` never proceeds as-is — classify which zero it is first.
> Case 1 backfills — and halts whenever the dry-run plan is not exactly the
> genuine children; cases 2-unrealized, 3 and 4 halt outright:**
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
>    issue (one parent only). This vet is **load-bearing precisely because the
>    backfill's parser is looser on ref position than the classification
>    rule** (#1260): it takes the first ref *anywhere* on a checkbox line,
>    where step 0 counts only a checkbox whose content *starts with* the ref.
>    That is deliberate — it puts every context ref in front of the operator
>    (model or human; this vet is required on autonomous runs too) instead of
>    dropping it silently. **When the dry-run's `would_add` contains any
>    ref that is not a genuine child declaration** — judged by the full #1260
>    rule **plus intent**: the line **declares the referenced issue as this
>    epic's work** (not a *condition about* it — `- [ ] #937's seam is
>    implemented` passes the shape rule and still fails this vet), the
>    checkbox content *starts with* the ref, **and** the line is
>    outside any fence — **do NOT run the live
>    backfill** — halt and report (interactively: ask the human to fix the
>    body's task list so only child declarations remain), then re-dry-run
>    before migrating.
>
>    **The halt is absolute, and it is not rare.** An epic whose acceptance
>    criteria cite sibling issues in checkbox lines puts every one of those
>    refs into `would_add`, so this branch fires on ordinary, well-written
>    epics. Never read the "deliberately looser" rationale above as licence to
>    wave the extra refs through as known-harmless: the looseness exists to
>    *surface* them for this decision, not to pre-approve them. There is no
>    partial or selective migration — the sanctioned remedies are for the human
>    to attach the genuine children as native sub-issues directly, or to edit
>    the body so no non-child checkbox line carries a `#N` — and then re-run
>    the dry-run.
>
>    **First, branch on the dry-run's EXIT CODE, not just its JSON.** A
>    nonzero exit (1: missing jq/awk, epic fetch, body-parse or sub-issue-list
>    failure; 2: usage) prints **no document at all** — which, read as a plan, looks
>    exactly like the empty-plan halt below and would tell the human their task
>    list is not migratable when in fact nothing ever parsed it. **Exit 2 is
>    your own bad invocation** — fix the command and re-run the dry-run, do not
>    escalate it. **Exit 1 is a tooling failure**: report it the way the halts
>    below do — interactive, in the conversation; autonomous, as a comment on
>    the epic naming the exit code and stderr — and stop. Never read a missing
>    document as an empty plan.
>
>    **The vet runs BOTH ways.** The rule above catches refs in `would_add`
>    that are not children; this catches the reverse — a line you read as a
>    child that produced **no** ref. Compare the body's checkbox lines against
>    the dry-run's arrays as a whole (not `markdown_children` alone — it
>    excludes both skipped kinds by construction): every line you read as a
>    child declaration, in **any**
>    shape, must appear in `would_add` / `already_present` /
>    `skipped_cross_repo` / `skipped_self_ref` — a line landing in
>    `skipped_cross_repo` is the cross-repo halt, not a case-4 shape, and one
>    landing in `skipped_self_ref` is **either** the epic's own tracker line
>    (expected, halts nothing) **or** a mistyped child ref — resolve which by
>    the rule below; when you *do* halt, the comment must say
>    which it was — the cross-repo halt, a case-4 near-miss shape, or a
>    `skipped_self_ref` line judged a mistyped child.
>
>    A `skipped_self_ref` line still gets **recorded**, in whatever comment this
>    run posts on the epic — E1's own halt comment, E3's summary, E1b's halt
>    summary, or E5's closing
>    summary when the flow goes straight to E4/E5 — never omitted because E3
>    did not run. If a run posts **no** epic comment at all (E4 files a
>    regression and stops, say), post the note as its own one-line comment
>    before stopping. **Quote the body LINES, not the array entry**: the array holds
>    the epic's own number at most once and cannot tell you how many lines
>    produced it, so a genuine tracker line and a *mistyped* child ref
>    (`- [ ] #<epic> — build the thing`) yield the identical array. Naming the
>    lines is what makes the mistyped one visible.
>
>    **Then judge each quoted line, because the two demand opposite actions.**
>    A line that reads as a **tracker** (`- [ ] #<epic> stays open until …`) is
>    expected and halts nothing. A line that reads as a **child declaration
>    carrying the epic's own number** (`- [ ] #<epic> — build the thing`) is a
>    **mistyped child**: it declares work no sub-issue will ever carry, so
>    **halt exactly as case 4 does**, naming the line. If you cannot tell which
>    it is, halt and ask rather than proceeding — an autonomous run has no one
>    reading the comment before E5 fires. A
>    child-shaped line
>    that yields nothing is a **case-4 shape sitting inside a case-1 body** —
>    and nothing else would catch it, because `would_add` stays clean,
>    `markdown_children` is non-empty and `skipped_cross_repo` is empty.
>    (Which near-miss shapes yield nothing and which land in `would_add`
>    instead is ARCHITECTURE.md's per-shape record — you need not predict it:
>    run both halves and whichever applies fires.) **Halt exactly as case 4
>    does.** Without this, the epic migrates only its well-formed children,
>    reaches the `total == completed` row, and is CLOSED at E5 with the
>    dropped child never filed or built.
>
>    **Two more dry-run halts, both BEFORE the live run** (making **four** in
>    all with the forward and reverse vets above — the same four refine-issue's
>    Epic walk lists) — a run you must halt
>    on is a run whose GitHub writes must never happen:
>    - **`markdown_children` is empty.** The lines you read as children are not
>      migratable child declarations — either a near-miss shape the backfill
>      resolves nothing from, or a ref it resolves but never attaches (a
>      cross-repo ref, a self-reference to the epic). A near-miss shape the
>      backfill *does* resolve is **not** a cause here: it trips the
>      `would_add`-holds-a-non-child halt above instead. ARCHITECTURE.md
>      records which shapes fall on which side. **Either** the classification
>      was wrong, **or** the body declares children this migration cannot
>      attach (cross-repo, a self-reference) — name the lines and let the human
>      decide which; do not assert one. Halt with a comment naming the lines you read as
>      children and report that native sub-issues (or decomposition) are
>      needed, exactly as case 3 does. **Never re-run the backfill hoping for a
>      different result** — it is idempotent, so re-running loops forever.
>    - **`skipped_cross_repo` is non-empty.** It is reported on the dry-run
>      too, and cross-repo children are unmigratable here, so the epic halts
>      either way — halting now avoids attaching the same-repo half first and
>      leaving the epic half-migrated.
>
>    After a live run, **gate on its outcome**: continue
>    only on exit 0 with every markdown child accounted for in
>    `added`/`already_present` **and `skipped_cross_repo` empty** — then
>    re-read through the shared reader and take the table's row for the new
>    `summary` (that continuation is what keeps E3's "all children, one
>    invocation" true). Otherwise **halt** with a summary comment naming the
>    unattached children: on exit 5 (partial) or 1 — but **exit 2 is your own
>    bad invocation**, so fix the command and re-run the live backfill (it is
>    idempotent) rather than posting a halt comment naming children no document
>    ever reported — and equally whenever
>    `skipped_cross_repo` is non-empty — cross-repo children are
>    unmigratable here, and even when same-repo children attached fine
>    (`total > 0`), an epic with unattached cross-repo children must never
>    reach the `N == N` row's E4/E5 licence (the human attaches them
>    natively cross-repo, or descopes them from the task list). A partial
>    child set must never license closure. **Known gap, out of scope for
>    #1260:** that refusal is enforced only within the run that met the
>    cross-repo leftovers. The flow is resumable, so a later run sees a
>    non-zero `summary`, takes the in-progress row and eventually the
>    `N == N` row, and no step re-inspects the body — the dry-run halt above
>    at least stops the live write, but closing the loop across runs needs a
>    pre-E4 gate that judges the plan by the #1260 rule rather than by the
>    backfill's looser `markdown_children`, which is an epic-flow design
>    change, not a classifier fix. This is the migration hazard the
>    contract documents: treating an un-backfilled epic as "done" would
>    close never-started work en masse.
> 2. **The task list holds inline slices** (`- [ ]` describing work rather
>    than listing a child issue — no `#N`, or a `#N` that is only a context
>    ref, not the slice's own issue) — a supported pattern, realized by
>    separate PRs; slices are not issues, so nothing native can represent
>    them. **Confirm a merged PR for each slice.** All slices confirmed →
>    E4 + E5 as the `N == N` row. **Any slice unrealized → halt**: do not run
>    E4, do not close.
>
>    **Acceptance criteria are never slices.** A checkbox stating a *condition
>    about* an issue is a criterion, decorated or bare, and a body whose
>    checkboxes are **all** criteria matches none of cases 1-4 — it takes the
>    **otherwise** halt below, not this case. Case 2's terminal is the only
>    non-native door to E4/E5, so absorbing criteria here would let an
>    `epic`-labelled issue with `total: 0` reach E5 on merge evidence for work
>    that was never *its* work — closing a never-decomposed epic, which is
>    exactly what the `total: 0` branch exists to prevent (#798). Criteria
>    typically assert work that landed elsewhere, so the merged-PR hunt will
>    often *succeed* — that is the trap, not a confirmation.
> 3. **No children were ever filed / no task list at all** — the epic has not
>    been decomposed. → **halt** and report that decomposition comes first.
>    Never invent children ("don't decide the user's issues for them").
> 4. **The task list declares children in a near-miss shape** — bare issue
>    URLs, ordered-list checkboxes, decorated refs, or a ref glued to the
>    checkbox or to a word (step 0's shapes, all of them). These
>    are children in intent but not by the rule. **When they stand alone**,
>    case 1 never fires for them. **When they sit beside genuine child
>    declarations** (shape plus intent — a shape-matching criterion is not one),
>    case 1 fires and halts before the live run — by whichever vet applies:
>    a shape the backfill **does** resolve lands in `would_add` and the
>    **forward** vet catches it; a shape it resolves nothing from is caught by
>    the **reverse** vet. You do not need to know which is which in advance —
>    run both, and one of them fires. Either way case 2
>    must not absorb them as "slices". The reason differs by shape — for some
>    the backfill genuinely cannot migrate the line, for others it *would*
>    resolve and attach it unvetted, which is just as much a reason not to
>    enter case 1. ARCHITECTURE.md records which is which, per shape; **do not
>    restate that split here**, since the action below is the same either way.
>    → **halt** and ask for
>    native sub-issues (or for the list to be rewritten as `- [ ] #N`).
>
> **The cases are exclusive and closed.** Judge case 1 **first**: any genuine
> child **declaration** — the #1260 shape rule **plus** the intent half (the
> line declares that issue as this epic's work, not a condition *about* it) —
> makes it case 1 even when slice lines are also
> present — the slices are then out of this classification, and E5 still needs
> a confirmed merged PR for each of them. **A shape-matching *criterion* never
> makes it case 1**: a criteria-only body takes the otherwise halt (per case 2),
> and a body of slices beside a citing criterion is still case 2 — filing it as
> case 1 would strand the epic on a forward vet whose extra ref can only be
> cleared by editing criteria that were never children. **Otherwise** — any
> shape matching
> none of cases 1-4 → **halt** and report; never fall through to E4/E5.
>
> **Positive-evidence rule — never close an epic without evidence its work
> merged.** That evidence is native children all closed (`total == completed`,
> `total > 0`), or a confirmed merged PR per inline slice (case 2) — **and
> both when the body carries both**. Zero
> children is an *absence* of evidence and by itself licenses **nothing**. Do
> not look to E4 for this: E4 verifies that existing behaviour didn't regress,
> and a never-started epic passes it trivially — the suite is green because
> nothing changed, and there is no behaviour to exercise end-to-end because the
> feature doesn't exist. A verification gate cannot tell "the feature works"
> from "the feature was never built"; only positive merge evidence can.
>
> **The halt — every halting branch here** (case 1's **four** dry-run halts —
> the forward `would_add` vet, the reverse vet, the empty plan, and a non-empty
> `skipped_cross_repo` — plus its **dry-run tooling failure** (an **exit 1**,
> which is not a plan at all; exit 2 is your own bad invocation, fixed and
> re-run rather than reported), a `skipped_self_ref` line judged a **mistyped
> child** (halted as case 4 does), its post-live-run halt, cases 2, 3 and 4,
> and the otherwise fall-through). Mirror
> E1b's halt: post a summary comment on the epic **naming the exact cause** —
> which slices are unrealized (case 2); that no children are filed and
> decomposition is needed (case 3); the near-miss lines you read as children
> (case 4, and the reverse vet); the refs in `would_add` that are not child
> declarations; the cross-repo refs; an empty plan; that the backfill's **dry
> run failed with exit 1**, quoting stderr; the body line citing the epic's own
> number that reads as a child declaration, quoted verbatim; the children a live run
> left unattached (exit 5 or 1); or, for the fall-through, the shape you
> actually read — build nothing, leave
> the epic **OPEN**, and stop. **The comment is not optional on an autonomous
> run** — epic-driven resolve has no human to ask, so "ask the human to …"
> means: interactive, ask them; autonomous, post the comment and stop. A silent
> stop leaves no record of why the epic was not worked. Re-running after a
> human files the children (as native sub-issues —
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
  unready and why, plus any `skipped_self_ref` line an E1 backfill reported
  (quoting the body **lines**, not the array entry, named as a self-reference
  that was not migrated) — and **stop**. This halt runs *before* E3, so its
  summary is the only comment the run posts: omitting the item loses it.
  One unready child means the epic is not ready.

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
order, resolve each — not "next child, then stop". A child is halted only by a
**typed escalation** (§#564), a §0a **dependency rejection**, or a precheck
**tooling failure** — all three park just that child (see the triage below);
the readiness pre-flight (E1b)
already proved every child **open at pre-flight** was `READY` before the first
one starts, so nothing else needs a human mid-run.

> **One thing DOES arrive mid-run, and it is not epic work (#1435).** A child
> that ends `CONVERGED_WITH_RESIDUE` attaches its remainder to **this epic** as
> native sub-issues labelled `review-residue` + `needs-refinement`. They are open
> children from the moment they are filed, and they were never gated — so
> **never walk them in this invocation**: they are findings, not stories, and
> building code from a finding title is exactly what E1b exists to prevent. Do
> not re-enumerate the epic's children mid-run and pick one up. Record them in
> the end-of-run summary comment instead (below), and let E5's own note decide
> what they mean for closure.

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

**A precheck exit 1 or 2 on a child is NOT a rejection.** Nothing was decided
and stdout is empty, so there is no `comment_md` — **never** post the `blocked`
label or a rejection comment from either (that label asserts open blockers in
the child's graph, a verdict the gate never reached). They differ in what you
do next:

- **Exit 1** is a **tooling failure** of that child. Park the child, quote the
  script's stderr in the epic summary comment, and continue with the children
  that don't depend on it. Never re-run hoping for a different result.
- **Exit 2** is **your own malformed invocation** — the same rule E1 applies to
  the backfill's exit 2. **Fix the command and re-run the precheck for that
  child.** Park it (quoting stderr *and* the invocation) only if it exits 2
  again or you cannot see what is malformed. Parking on the first exit 2 would
  park every child, since the invocation is built the same way for each.

Neither ever continues that child to step 0b, and neither aborts the epic.

**End every run with an epic summary comment** — one comment on the epic listing
**merged / escalated / parked** children (and any still queued), plus any
`skipped_self_ref` line an E1 backfill reported, named as a self-reference that
was not migrated — by E1's judgement necessarily a **tracker** line, since a
mistyped child ref halts at E1 and never reaches here — so the epic's state is
legible at a glance. Then:

- **All children merged** → proceed to **E4** (holistic verification) and **E5**
  (close the epic) — and, when the body also holds inline slices, only once
  each slice's PR is confirmed merged. A re-run that finds **zero open children** does no child work
  — but it goes to E4 + E5 **only** once E1 confirms the children were filed and
  merged (the table's `total == completed > 0` row — native children all
  closed), or every inline slice's PR is confirmed merged (case 2). **A body
  carrying both kinds needs BOTH**: genuine child *declarations* (shape plus
  intent) make it case 1, and
  case 1's vets only ever judge the *child* lines — whether a slice was
  realized is never something they check (a slice carrying a context ref does
  trip the forward vet, which halts; a ref-less slice trips nothing) — so
  satisfying the children half alone would close an epic with its slices
  unrealized. **If any slice is unrealized, halt exactly as case 2 does**: post
  the halt comment naming them, do not run E4, do not close. Zero
  children on its own is never the licence; cases 2-unrealized, 3 and 4 halt
  there instead.
- **Some escalated/parked** → the epic stays **open**; re-running after the human
  resolves an escalation (the decision lands in the child's comment thread, which
  the implement step re-reads) resumes the parked dependents and any remaining
  children. The flow is fully **resumable**.
- **Residue children were filed this run (#1435)** → the epic stays **open with
  residue**, and this bucket applies **even when every walked child merged** — so
  read it before the first bucket, which would otherwise send you to E4 + E5 on a
  `total != completed` epic that E5 must then refuse to close. List the residue
  children in the summary comment, naming the child whose run filed each, and go
  to **E5's residue note** rather than closing. The next run halting at E1b on
  them is the intended prompt to refine them, not a defect in this one.

### E4. Comprehensive epic verification (after ALL children merge)

The per-child gates tested each change in isolation, but can't see the
children's **combined** effect. Once the whole epic is on `main`, run a
**holistic end-to-end test of the epic's domain** and report.

**First, before choosing a bullet below: the Epic flow never ran §1b**, so
nothing has bound `<repo_type>` or loaded a profile — E3 delegates the
Single-issue flow to the *children*, in their own sub-agents or worktrees, and a
re-run that finds zero open children arrives here having run none of them. Run
§1b's `detect` and load the profile **now**. It sits here rather than inside one
bullet because the bullets are chosen *by* repo type, which is the very thing
`detect` reports.

**Read `detect`'s two non-zero arms the Epic flow's way, not §1b's.** Both of
§1b's are argued from §3.5 — "the same detector runs again there" — and the Epic
flow never reaches §3.5, so neither promise can be kept here. At E4: **exit 1**
→ report the stderr and **halt E4 without closing the epic**; **exit 3** → relay
the typed object, **halt E4**, and report it as the epic's own
`ESCALATE_AMBIGUOUS`: post the typed object as a comment **on the epic** with
the `needs-human-decision` label, and stop. Do **not** run the escalation
terminal's own steps here — they push a story branch and build from a loop
status JSON, and at E4 there is
neither. Continuing past either would close an epic on verification that never
ran. **Exits 0 and 2, and a merely missing profile, are unchanged** — those
still follow §1b, so a usage error is still yours to fix and re-run.

**Never substitute your own command for a LOADED profile's.** With no profile,
run the repo's whole suite as §3's fallback directs, and say in the E4 report
that no profile-blessed gate was available — so the guarantees such a gate
carries (a single run, a forced-red zero-test exit, a degraded-mode relay) are
visibly absent rather than silently assumed. An improvised command whose green
nobody can account for is not E4 evidence.

- **Java / Python app** (most critical) — the full build + test suite, plus a
  real end-to-end exercise of the affected behaviour (run the relevant pipeline
  / the app itself), so integration regressions surface here.
- **Claude-plugin** — the repo type's own holistic command and end-to-end
  driver:
  profile: `development-<repo_type>:resolve-profile` § Gate

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
→ its merged PR), the **E4 verification result** (what holistic test ran and
that it passed), and any `skipped_self_ref` line an E1 backfill reported —
quoting the body **lines**, not the array entry — so the closed epic is a
self-contained record. Only after this
is the epic truly done — report it closed, with the PR/verification table.

> **A child that ended in residue leaves the epic OPEN, and that is the correct
> outcome (#1435).** A child resolving under this epic can end
> `CONVERGED_WITH_RESIDUE`, and its residue branch attaches the remainder to
> **this epic** as native sub-issues labelled `review-residue` +
> `needs-refinement` (the same pair E3's note names). They are open
> children the moment they are filed, so:
>
> - **E5 must not close the epic.** The positive-evidence rule wants
>   `total == completed`, and it does not hold. Do **not** special-case them out
>   to reach a closure — an auto-generated finding is real work nobody has
>   specified yet, and closing over it is exactly the "close never-started work"
>   hazard the rule exists for. Report the epic as **open with residue**, listing
>   the residue children and the child whose run filed them.
> - **The next run halts at E1b**, because `story-readiness` sends every one of
>   them back. That halt is the *intended* prompt, not a deadlock to engineer
>   around: it says the residue must be **refined** (`/development:refine-issue`)
>   before the epic can proceed. E1b's own halt comment names them, and the
>   `needs-refinement` label they carry is the reason.
>
> So do not read "some children are unready" here as a defect in the epic run
> that filed them. It is the design: residue is deferred work, made visible as
> work, and the epic waits for a human to specify it.

## Guardrails

- **Never push to `main`** — always a feature branch off fresh `origin/main`.
- **Never open a PR on a red gate** — a red per-issue gate blocks consolidation
  and the commit, so nothing reaches a PR.
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
  classification), **and both when the body carries both**. **Zero children
  never licenses E5 by itself**: a
  never-decomposed epic and an all-merged one enumerate identically, and E4
  cannot tell them apart (it passes trivially when nothing was built). Cases
  2-unrealized, 3 and 4 **halt** with a summary on the epic instead.
- **Dependencies gate first** — the 0a precheck rejects on open GitHub-native
  blockers (and refuses cycles) before anything is branched; in autonomous mode
  the rejection is a typed comment + `blocked` label, and an unattended run
  **never auto-chains** into resolving the blocker itself. Interactive runs get
  the guided offer (§0a remediation) — resolve blocker + named issue, or just
  the blocker — but remediation only ever starts from an explicit human choice,
  and neither a cycle, an empty-open-set (shape (ii)) rejection, nor one whose
  every open blocker is **foreign** is ever
  remediated — none names a rung, so §0a reports the cause and stops. A blocker
  whose `kind: "epic"` is
  **confirmed** by the intent half (§0a — native sub-issues or the `epic`
  label; a body or tracked-issues signal only when a checkbox line is a child
  *declaration*) remediates as a
  **whole epic** — the full Epic flow to a closed epic (E4/E5 included) before
  the dependent proceeds; never one child, never a reimplementation of the
  epic's ordering. A blocker reported `kind: "epic"` that **fails** that
  confirmation is **not** automatically a single-issue rung — §0a splits it:
  criteria-only → ordinary single-issue rung (never the Epic flow, which would
  halt at E1's `total: 0` and leave the blocker unresolved); children in a
  near-miss shape → a real undecomposed epic, **halt the rung** and ask for
  native sub-issues; anything else → ask the human.
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
