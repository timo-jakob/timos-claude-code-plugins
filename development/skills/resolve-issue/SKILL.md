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
  rounds, give guidance, ask questions) — see [The local review
  loop](https://timo-jakob.github.io/timos-claude-code-plugins/explanation/review-loop/).
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

#### Interactive remediation — offer to clear the blockage (#586, #587)

Applies **only** with a human present, and only to a **shape (i)**
`REJECT_BLOCKED` — one that actually enumerated an **OPEN** blocker:

- **`REJECT_CYCLE` has no remediation.** No order of work satisfies a cycle;
  the fix is a relationship edit (remove whichever blocked-by points the wrong
  way), and that judgment is the human's. Report and stop.
- **A shape (ii) `REJECT_BLOCKED` has no remediation either.** No OPEN blocker
  was enumerated (however many closed ones are listed), so nothing names a
  rung, and both options below would promise to clear a chain that
  does not exist — and reading "no rungs" as "chain already clear" is exactly
  the continue-to-0b outcome shape (ii) forbids. Report the cause and stop.
- **An open blocker classified `kind: "epic"` blocks as a whole** (#587):
  resolving one child wouldn't unblock the dependent — the named issue may
  depend on the epic's **combined** effect.

  **Confirm the `kind` before acting on it.** `kind` comes from the same
  *shape* classifier as step 0 (#1260) and, like it, **cannot see intent**.
  ARCHITECTURE.md (*Issue-dependency model*) lists **every** consumer that must
  apply the intent half on top of it — widening or narrowing the classifier
  means sweeping that list, not just this skill's own sites.

  **Fetch the blocker before judging.** The precheck's decision JSON carries
  `issue`, `decision`, `open_blockers`, `blockers` (each with `depth` and
  `kind`), `foreign_blockers`, `cycles`, `truncated`, `reader_blocked` and
  `comment_md` — that is
  the named
  source for every array the sections below read. `truncated` is true when the
  walk left `blockedBy` edges **unread** at the depth cap — so the blocker
  arrays are a **floor**, not a complete answer, and when they are empty it is
  why, rather than proof there are none. Merely *reaching* the cap does not set
  it: a leaf there leaves nothing unread and reports false. What it does
  **not** carry is
  any **breakdown of the signals that produced a `kind`**: no sub-issue count,
  no label list, no body. So the confirmation evidence is not already in hand:

  ```bash
  gh issue view <blocker> --json labels,body
  "<skill-base-dir>/scripts/read-sub-issues.zsh" --repo "$REPO" --epic <blocker>
  ```

  `summary.total > 0` or an `epic` label **confirms** it — those two are proof
  on their own. `trackedIssuesCount` is **not**: GitHub derives it from the
  same body checkbox lines, so judge it exactly like a body signal. A **body**
  (or tracked-issues) signal is proof only when at least one checkbox line is a
  child **declaration** (shape *plus* intent). A blocker whose only checkbox
  refs are acceptance criteria — `- [ ] #937's seam is implemented` — is
  reported `kind: "epic"` and is an **ordinary issue**: remediate it through
  the single-issue flow, and say so rather than relaying the `comment_md`'s
  *epic* wording. Running the Epic flow on it instead ends in E1's `total: 0`
  halt posting a decomposition complaint on a well-specified story, so the
  blocker is never resolved and the named issue stays blocked — #1260's own
  harm, arriving through the dependency path. Getting it backwards is just as
  costly: treating an unconfirmed `kind` as an ordinary issue completes the
  rung on one PR and lets the dependent proceed with a genuine epic's remaining
  children unbuilt.

  **A failed fetch, or a body you cannot judge either way, is not a
  confirmation.** This path is interactive-only — ask the human which it is,
  and never guess a rung. **Exit 2 is your own bad invocation, though**: fix
  the command and re-run the fetch before asking, rather than spending the
  human's attention on your own typo.

  Remediating a **confirmed** epic blocker means
  running the **full Epic flow** on it (E1–E5: every child, the holistic E4
  verification, the explicit E5 close) — **reuse that flow as written**, never
  a re-implementation of its ordering. The named issue stays queued until the
  blocking epic is **CLOSED**, not merely until its children merge — E4 may
  still surface a regression that keeps the epic open. That is the epic flow's
  "never branch off an unmerged dependency" rule, extended across the epic
  boundary. (Autonomous runs are unchanged: an epic blocker rejects +
  escalates like any other — an unattended run never auto-runs the epic.)

**When `blockers` holds NO `open: true` entry — every open blocker is
foreign — there is no rung at all: do NOT present the offer.** The chain below
is the `blockers` array only, so it would be empty, and both options would
promise to clear a chain that does not exist; option 2 would then report a
chain merged when nothing was resolvable from this repo. Report the open
`foreign_blockers` refs as unresolvable here and stop, exactly as a shape (ii)
rejection does. The either/or below applies **only** when at least one open
entry exists in `blockers`.

**When an open `foreign_blockers` entry exists alongside local ones, the offer
cannot fully clear the
chain** — the local rungs would merge and the precheck would still reject. (A
shape (ii) rejection — truncated, or the reader's own verdict, both with NO
**open** blocker enumerated — has no rungs at
all: it already told you to stop, so never reach this offer. A `truncated`
rejection that **did** enumerate blockers is shape (i): the rungs are real, so
offer them deepest-first as usual — clearing them prunes the very walk that hit
the cap, so the re-run may well pass — but say that the list is a **floor**, so
a blocker beyond the cap could still surface.) So
either withhold the offer and stop as an autonomous run does (report + the
`blocked` label), or present it with that stake stated plainly in the question.
Never present it as if completing the local rungs would unblock the issue.

Otherwise — whatever the blocker's kind — put the choice to the human
(AskUserQuestion —
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

**Either way, the blocker chain resolves deepest-first.** The chain is the
`blockers` array only — **`foreign_blockers` are not rungs**: they are in
another repository, carry no `depth`, and this flow operates on the session's
repo, so an open one means the offer cannot fully clear the chain. Say so up
front rather than presenting a remediation that will still re-reject. The
`blockers` array carries a `depth` per blocker: work from the deepest open
blocker upward, because a shallower blocker may itself be blocked by a deeper
one — building it first would just re-reject. **`depth` is the SHORTEST
distance from the named issue, so it is a hint, not a topological order**: a
blocker that is both direct and a prerequisite of another direct blocker
reports `depth: 1` like its dependent (the field's documented meaning is "1 =
direct blocker", which needs the minimum). What actually guarantees the order
is the recursion below — each blocker's own step 0a re-rejects it if a deeper
one is still open — so use `depth` to choose a starting point, never as proof
that a rung is ready. Resolve each blocker via the
**full single-issue flow, recursively**: each blocker's run starts at its own
step 0a, so a still-deeper blocker surfaces there (and, with the human still
present, gets the same offer), and #585's cycle refusal is inherited rather
than re-implemented. One issue per PR, as always — a chain of three blockers
is three PRs, each **merged before its dependent branches** (never stacked;
the epic flow's "never branch off an unmerged dependency" rule, applied
across the remediation chain). An **epic-kind blocker occupies its rung as a
single unit** — once its `kind` is **confirmed** by the check above, never on
the reported field alone: that rung runs the Epic flow (above) instead of the
single-issue flow, and the rung is complete only when the blocking epic is
closed.

**Failing the confirmation has two *nameable* causes plus a catch-all, and
they end differently.** Only the first is the criteria case:

- Its checkbox refs are **acceptance criteria** — an ordinary well-specified
  story. Take an ordinary **single-issue rung**.
- Its children are written in a **near-miss shape** (step 0's shapes: a bare
  issue URL, an ordered-list checkbox, a decorated or glued ref). This is a
  real but **undecomposed epic** — `trackedIssuesCount` reports it as one
  because GitHub's own task-list tracking is looser than the #1260 shape rule,
  yet no line passes the shape half. **Halt the rung** exactly as step 0's
  near-miss branch does: ask for native sub-issues or a `- [ ] #N` rewrite.
  Never run either flow on it — a single-issue rung here would widen into a
  single-issue implementation of an epic body, which step 0 forbids, and the
  rung's own step-0a re-entry does not re-run step 0's near-miss branch.
- **Anything else you cannot classify**: ask the human.

**Wait for each merge before the next rung** — this applies to *every* rung,
not only the ones above. An Approver repo
auto-merges on green (`await-pr-checks.zsh`); in a human-only repo the human
is present — report the blocker PR ready and continue once they merge it.
When an epic rung pauses awaiting a child's merge (the human-only cadence),
this remediation pauses with it; re-running `/development:resolve-issue` on
the **named issue** re-enters the gate and resumes the blocking epic from its
next open child.

Then, per the chosen option:

- **Just the dependency** → stop once the blocker chain is merged. Do not
  branch, implement, or comment on the named issue — it was never touched, and
  its next `resolve-issue` run passes the precheck by itself. (Unless an open
  `foreign_blockers` entry remains — then that re-run rejects again, and the
  human must clear it in **its own** repository first. A `truncated` rejection
  that enumerated blockers needs no such caveat — clearing them prunes the walk
  that hit the cap — but the list is a floor, so re-verify rather than assume;
  only the case where NO open blocker was enumerated needs a larger
  `--max-depth` or a shorter chain.)
- **Both** → **re-verify, then proceed**: re-run the precheck on the named
  issue and require `PROCEED` — a squash-merged PR closes its issue via
  `Closes #N`, but verify rather than assume (a blocker may have gained a new
  relationship
  while the chain was in flight; a merge may not have closed what you think
  it closed). Only on `PROCEED` continue to step 0b and the rest of the
  single-issue flow, exactly as if the precheck had passed first try.

  **If the re-verification returns `REJECT_BLOCKED` or `REJECT_CYCLE`** —
  guaranteed when
  an open foreign blocker remains, and possible whenever a relationship
  changed mid-flight — do **not** branch, do **not** implement, and do **not**
  re-offer remediation (the chain cannot be cleared by repeating it; that is
  an unbounded loop). Report the still-open blockers, naming any
  `foreign_blockers` entry as **unresolvable from this repo**, and stop.

  **An exit 1 or 2 here is NOT a rejection** — nothing was decided and stdout
  is empty, so there is no fresh blocker list. **Never** relay the list you
  held from the first rejection: those rungs were just merged, so reporting
  them asserts a verdict the gate never reached and sends the human back to
  re-resolve them. Exit 2 is your own malformed invocation — fix the command
  and re-run the re-verification. Exit 1 is an internal failure — report the
  script's stderr and stop. Either way, never continue to step 0b.
  Never read an already-reported blocker as "known, therefore fine" and
  continue to 0b — building against an unverifiable prerequisite is precisely
  what the gate exists to prevent.

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

Run the repo's own test + lint gate and **only proceed when green**. Detect what
applies and run it:

- pre-commit hooks (`pre-commit run --all-files`, or the staged subset),
- tests for the stack — the **whole suite**, never a subset. For **plugin
  repos**, run the blessed single-run parallel gate rather than bare `bats`:
  `<skill-base-dir>/scripts/run-gate.zsh --tests-dir tests` (#980) — it runs the
  whole `bats tests` suite **exactly once**, parallelised via `--jobs` = CPU
  count on a multi-core host with GNU `parallel`, and run sequentially otherwise
  — loudly (a degraded warning) only on a multi-core host missing GNU `parallel`,
  quietly on a single-core host where there is nothing to parallelise — prints
  the ok/not-ok counts plus bats' **real** exit code (a JSON
  summary on stdout), and exits with that code, so it drops in as the gate
  command. A run that reports **zero** tests is forced to a non-zero (red) exit
  — never a false green. Never hand-roll a `bats … | grep -c` that runs the
  suite twice to count. For other stacks: `pytest` (Python — the whole suite,
  **not** `pytest tests/unit`), `./gradlew test` / `build` (Java/Gradle), etc.,
  - **Capture the gate attestation (#981).** On a **green** `run-gate.zsh`,
    keep its stdout `"tree"` field — the working-tree identity it just gated. On
    the **next** review round's `--resume` you pass it as `--gate-attest` (§3.5)
    so the loop skips a byte-identical re-run of the exact same tree it already
    proved green — the single biggest per-round duplicate the #976 session paid.
    It is a plain identity, not a verdict; `exit`/`ok` counts remain the pass
    signal, and the loop re-runs the gate on any mismatch (fail-closed).
- **relay a DEGRADED gate to the user, up front (#980).** `run-gate.zsh`'s
  stdout summary carries a `"mode"` field. When it is `"sequential-degraded"`
  (GNU `parallel` is not installed), the gate still ran the **whole** suite at
  full rigor — but sequentially, so every review round's gate takes multiple
  times longer. Tell the user **clearly and immediately**: that parallelization
  is unavailable, that each round's gate will be several times slower, and that
  the fix is `brew install parallel`. Never quietly absorb the slowdown.
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

Once the gate is green, run the **local review loop** before committing or
pushing anything, so a PR is only opened on code a reviewer panel has already
converged on (no CI minutes spent on unconverged work). Drive
`development/skills/resolve-issue/scripts/resolve-story-loop.zsh` — the
state machine (constants `MAX_REVIEW_ROUNDS=5`, `BLOCKING_SEVERITIES=(CRITICAL
WARNING)`) — in **step mode** (#971): one invocation per round, with every
model-driven step done **in-session, where the user can watch it**. Two hard
rules: **never** shell out to a headless `claude` (`claude -p` / `--print`)
for any model-driven step, and **never** run the loop as a long-lived
background task spanning rounds. The user must be able to see rounds happen:
visible review agents, visible fix edits, a narrated summary per round.

**At loop start, tell the user where to watch:** the loop appends one block per
round to `<work-dir>/progress.md` — say so once, e.g. "follow along with
`tail -f <work-dir>/progress.md`".

Each round:

1. **Review panel, in-session.** Get the dispatch plan (`review-dispatch.zsh
   plan`, §#560) and spawn the reviewers of the skill it names in
   `review_skill` via the **Agent tool** (one agent per dimension, visible to
   the user), scoped to the plan's `changed_files` — minus anything under the
   loop's `--work-dir`, which is loop state, never story code. Aggregate their
   findings into one #558-schema JSON array file — the round's findings file.
2. **One loop invocation.**

   ```bash
   "<skill-base-dir>/scripts/resolve-story-loop.zsh" --repo <repo> --base <base> \
     --work-dir <work-dir> --status-file <status.json> --issue <N> \
     --findings-file <findings-round-R.json> \
     --test-cmd '<full gate>' [--resume] [--gate-attest <tree>]
   ```

   `<full gate>` is the same whole-suite command as Step 3. On a **plugin repo**
   that is the blessed single-run parallel gate — `--test-cmd 'zsh
   <skill-base-dir>/scripts/run-gate.zsh --tests-dir tests'` (#980) — never a
   bare `bats` invocation that a later step would re-run to count.

   `--resume` from round 2 on. On a `--resume` invocation the loop runs
   `--test-cmd` — the **full** suite (unit **and** integration), never a
   subset (#604) — FIRST, deterministically gating the previous round's
   in-session fix: red exits `ERROR` (1), the same "red after a fix aborts"
   rule as ever — **unless** a matching `--gate-attest` (below) proves that run
   redundant, in which case the loop skips it (and only it).

   **`--gate-attest` — one full-gate run per round, not two (#981).** On a
   `--resume` the session has *just* run the full gate green in Step 3 (right
   after applying the previous round's fix). Passing the `tree` identity from
   that green `run-gate.zsh` (Step 3, above) as `--gate-attest <tree>` lets the
   loop **skip** its own `--test-cmd` run **when — and only when — that identity
   still exactly matches the working tree**, killing the byte-identical
   duplicate that dominated the #976 session (~24 min). It is strictly
   **fail-closed**: a mismatch (the tree changed since the attestation), an
   empty/absent value, or an uncomputable current identity all run `--test-cmd`
   exactly as before — the gate itself never weakens, this removes only a
   provably-redundant re-run.

   Four rules keep it honest — break any and the loop either re-runs the gate
   (safe) or, worse, skips a gate it should not (a false green):

   - **Only when `--test-cmd` *is* the attested `run-gate.zsh`.** The `tree`
     field exists only on **plugin repos** (it is `run-gate.zsh` stdout). On a
     `pytest` / `gradle` / other stack there is **no** attestation to pass —
     **omit `--gate-attest` entirely** and let the loop run the gate. Never
     synthesize an identity yourself (e.g. calling `git-tree-id.zsh` right
     before `--resume`): a resume-time identity trivially matches the loop's
     resume-time computation, turning the check into a vacuous self-attestation
     that skips a gate that never ran. The attestation must come from the actual
     green gate, or not at all. Likewise pass it only when `--test-cmd` runs the
     **same** `run-gate.zsh` you gated with — a broader/compound `--test-cmd`
     would be skipped whole on a tree match, including parts the attested run
     never executed.
   - **Capture the attestation from the *green* gate, and don't edit after.**
     The panel is read-only, so a tree that only the review agents have touched
     (i.e. read) is unchanged and still matches — but **you** must not touch the
     tree between the green Step-3 gate and the `--resume`. If you did edit anything (or you
     can't be sure), re-run the gate to get a fresh `tree` **or** omit
     `--gate-attest` — never pass the stale one. (Passing it is not *unsafe* —
     the loop just re-runs on the mismatch — but it wastes the round's point.)
   - **Keep `--work-dir` and every `findings-round-R.json` OUTSIDE the repo**
     (or on a git-ignored path). The identity hashes tracked **and** untracked,
     non-ignored files, so a findings file or work-dir written *inside* the repo
     changes the tree every round and defeats every match. Put them under a
     scratch dir outside the worktree, exactly as the C4 step (§3) writes
     `detect.json` outside the repo.
   - **The one blind spot: git-ignored files.** The identity honors
     `.gitignore`, so a change confined to an *ignored* test-relevant file is
     the single edit class a match cannot catch. In these repos ignored paths
     are build artifacts the suite never reads, so this is theoretical — but if
     you knowingly change an ignored file the tests read, re-run the gate.

   **Write each round's findings to its own path** (`findings-round-R.json` —
   hence the `R`), and pass that round's path. On a `--resume` round the loop
   refuses two shapes of "this round's panel never ran" as
   **`STALE_FINDINGS` (exit 2, #974)** — a *recoverable* usage error, not a
   verdict:

   - the file is **missing or empty** — a panel that found nothing still writes
     `[]`, so silence is never read as a clean round (that would converge the
     loop on an unreviewed round and green-light the PR);
   - its content is **byte-identical to the round just consumed** — a stale
     path re-passed, or the new round's file never written. Consumed, it would
     read as a blocker surviving two rounds and trip a phantom
     `ESCALATE_NO_CONVERGENCE`.

   **Recover by cause, then re-invoke** — the round is not lost:

   - if round R's panel **did** run and its aggregate exists at its own path,
     just re-invoke with the correct `--findings-file` (don't re-run the panel);
   - if it **never** ran (or you can't tell), run round R's panel (step 1),
     write its aggregate — `[]` when it found nothing — and re-invoke.

   **Re-pass the same `--gate-attest` on the recovery re-invoke** (plugin repos).
   The refusal happens *after* the resume-start gate has already run (or validly
   attest-skipped) on this exact tree, and neither the refusal nor the read-only
   panel touches the tree — so the held attestation still matches. Omit it and
   the recovery needlessly re-runs the full suite, the very duplicate #981
   removes; drop it only if you edited the tree since the green gate.

   Never re-pass the previous round's file, and **never hand-edit findings to
   make the bytes differ** — that fakes a round. The refusal can only fire
   *again* if you feed it byte-identical findings *again*; two genuinely
   independent panel runs never serialise to identical bytes (evidence text,
   ordering, and reviewer set all vary), so a repeat means the file still
   wasn't this round's real panel output — recover it (above), don't work
   around it. A blocker the reviewers keep re-finding is a real problem to
   **fix in-session**, not a reason to defeat the guard.

   Exit 2 **writes** its own status JSON (`status: "STALE_FINDINGS"`) to
   stdout and `--status-file`, so the previous round's verdict is never left
   there to be misread; it is not terminal, so it appends no telemetry record
   and no `**Final:**` line — but it *does* append a `**Refused (round N):**`
   line to `<work-dir>/progress.md`, so a user tailing it sees why the round
   they expected did not happen. `STALE_FINDINGS` is never an escalation: don't
   run `build-escalation.zsh` on it, don't post a comment from it, don't enter
   the interactive extension on it — only recover-and-re-invoke.

   The byte-identical half of the guard needs a sha256 tool (`shasum` /
   `sha256sum`); without one that detection degrades silently, so a re-passed
   stale file trips a **phantom** `ESCALATE_NO_CONVERGENCE` instead of this
   refusal. Guard against that at the point it would mislead: on any
   `ESCALATE_NO_CONVERGENCE`, before trusting it, confirm the `--findings-file`
   you passed was round R's own freshly-aggregated path. If it was **stale**,
   the escalation is phantom — ignore it (don't post or extend on it) and
   recover as the `STALE_FINDINGS` case (re-invoke `--resume` with round R's
   real findings, running the panel first if it never ran). The missing/empty
   half of the guard (and the alias guard — `--findings-file` must never be the
   dispatch `findings_path`) needs no digest tool and always applies.
3. **On `AWAITING_FIX` (exit 20)** — blockers remain and budget is left:
   **narrate the round in the conversation** (round number; the
   Critical/Warning/Suggestion counts — plus, on a promotion sub-loop round, the
   `promoted` count and each `- promoted suggestion:` line; blockers found, new
   vs carried;
   fixed-since-prior and the cumulative blocking trend from round 2 on; the
   dimensions they came from; what you fix next — the same block the loop
   just appended to progress.md, which carries these where applicable). Two
   false-trip shapes to narrate: an **escalating possible false trip** — a
   carried match with no shared (non-empty) prior title that is still
   ambiguous (#913/#969) — can only appear on an *escalating* round (an
   `ESCALATE_NO_CONVERGENCE`, never `AWAITING_FIX`); narrate it there, per the
   escalation branch below. A **verified false trip auto-continue** (#983),
   though, *does* appear on an `AWAITING_FIX` round: a carried match whose title
   is fully disjoint from its prior is identity-cleared as a genuinely different
   finding, so the loop kept going (no escalation, no human grant) — progress.md
   renders it as a `false trip auto-continued` line; narrate it here (the blocker
   is fresh, not stuck) and fix it as a normal new blocker. Then implement the
   blockers from the status JSON's `final_changelist.blocking` exactly as
   step 2 implements — **sibling-sweeping each blocker's pattern across the whole
   diff and fixing every instance this round** (#982), so a repeating defect is
   cleared in one round, not dribbled across several — Low suggestions never
   loop — re-run the full gate (on a
   plugin repo, keep its green `tree` for the next `--resume`'s `--gate-attest`,
   #981; other stacks have none), and go to 1 for the next round's panel.
4. **On a terminal status**, take its branch below (`CONVERGED` → step 4;
   escalations → *Escalation*).

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
- **`AWAITING_FIX` (20)** → not a verdict — the step-mode "narrate, fix
  in-session, `--resume`" turn of the round protocol above. Never build an
  escalation comment from it.
- **`STALE_FINDINGS` (exit 2)** → neither a verdict nor an escalation — the
  round's findings were never produced (missing/empty on `--resume`,
  byte-identical to the last round, or `--findings-file` aliased the dispatch
  `findings_path`). Recover by cause per §3.5 step 2 and re-invoke; **never**
  build an escalation comment or a dossier from it.
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

#### Suggestion promotion on convergence — human-curated, opt-in (#994)

Low suggestions never block, so every one the panel raises is **waived** the
moment it is surfaced — logged and never actioned. That is the right default,
but it leaves a human no way to say *"actually, do that one"* at the one moment
they have the full picture and the PR is otherwise ready. This phase is that
opt-in, and nothing else: **suggestions stay non-blocking by default and nothing
is ever auto-promoted.**

**Gate — both conditions, or skip the phase entirely.** Offer it only when the
run is **interactive** (the same human-present determination §0a's remediation
uses) **and** the waived set is non-empty. An **autonomous / headless run never
prompts and never passes `--promote`**: it converges with its suggestions
waived, byte-identically to before this feature existed. Selecting *none* skips
the sub-loop and converges unchanged — but it is still a **presented prompt**, so
step 3's enrichment record (`suggestions_promoted: 0`) is emitted *first*
(subject to step 3's no-id rule — an absent or empty sidecar means no record at
all). Only
an autonomous / headless run, which never prompts, is byte-identical to before
this feature existed.

**First, locate the run's telemetry id (#995).** The blocking phase's terminal
exit wrote the `run_id` of the record it just emitted to
`<blocking-phase-work-dir>/.telemetry-run-id`. Step 3 reads it **directly from
there**, inline, at the moment it emits:

```bash
cat <blocking-phase-work-dir>/.telemetry-run-id     # the join key, read at emit time
```

Two things not to do with it, each of which silently breaks the join:

- **Do not hold it in a shell variable.** Step 3's emit runs after one or more
  `AskUserQuestion` turns, and each `bash` invocation is its own shell — a
  `RUN_ID=…` set here is unset there, the emitter refuses the empty `--run-id`
  with exit 2, and the "never fatal" rule below swallows it, so the enrichment
  silently never lands, on every run.
- **Do not copy it to a fixed scratch path first.** A scratch dir is reused
  within a session (a human resolving several issues back to back; a re-run
  after an escalation), and a copy that fails — the source is absent whenever
  telemetry was skipped, and it fails *silently* — leaves an **earlier story's**
  id at that path to be read as this run's. The work-dir path has no such
  hazard: it is per-run, and the loop clears it on a fresh start and rewrites it
  on every terminal exit.

**Absent or empty is not an error.** Most often it means no record was emitted —
telemetry is best-effort — and there is then nothing to join to: skip the
enrichment entirely and run the phase as normal. Before concluding that, confirm
the path you are reading is the **blocking phase's** `--work-dir` (the one you
passed at §3.5), not a defaulted temp dir or the sub-loop's. Never mint or invent
a `run_id` to fill the gap; a fresh id would validate cleanly and be permanently
orphaned.

1. **Derive the waived set.** It is the **cross-round union of distinct Low
   findings**, keyed `[file, line, dimension, title]`, over the status JSON's
   `round_changelists[]` — the same set `build-telemetry-record.zsh` already
   counts as `waived`, so the prompt and the telemetry record can never
   disagree. It is **not** the final round's `suggestions[]`: that converged
   round holds only *its own* Lows, and a suggestion raised in round 1 and never
   re-raised is still un-actioned work.

   The pipeline must **dedup first, then filter** — the order
   `build-telemetry-record.zsh` uses. Filtering first would offer a key that was
   a *blocker* in an early round and Low in a later one; telemetry excludes it
   (its earliest occurrence wins), so the two surfaces would disagree and the
   human could be offered an item that was already fixed as a blocker. (The
   mirror case — Low early, blocking-and-fixed later — keeps its Low priority and
   is still offered, because the earliest occurrence wins; it falls out as
   unmatched in step 4, and telemetry counts it as waived for the same reason,
   so the two surfaces still agree.)

   ```bash
   jq -c '[ .round_changelists[]? | (.blocking[]?, .suggestions[]?)
            | {file, line, dimension, title, priority: (.priority // "Low")} ]
          | unique_by([.file, .line, .dimension, .title])
          | map(select(.priority == "Low"))
          | map({file, line, dimension, title})' <status.json>
   ```

   **If the derivation fails or yields `[]`** — a malformed status file, or a
   `--no-review`/`SKIPPED` status with no `round_changelists` — there is no
   waived set: **skip the phase and converge unchanged**. Never treat it as an
   error, and never invent a set.

2. **Render it** as a numbered list — title · `file:line` · dimension — and
   **state the stake in one line**: promoted items become blockers, so if the
   sub-loop cannot clear them the run escalates and **no PR is opened this
   run**. A human promoting one cosmetic Low from an already-PR-ready change is
   entitled to know that before they pick, not after.

3. **Multi-select** which to promote (0..N) with `AskUserQuestion`
   (`multiSelect: true`), at most **3 suggestions per question** so the fourth
   option can carry the decline — declining should be a first-class choice, not
   something the human has to express through the "Other" escape hatch.
   - **One question covers the whole set** → label the fourth option
     **"Promote nothing — converge now"**.
   - **A larger set is chunked** → selections **accumulate across chunks**, and
     the decline option is labelled **"None from this batch"** (it declines
     *that chunk*, not the phase). **Ask every chunk before acting**, and
     re-state the running selection before the last one so the human can see
     what they have picked so far.
   - **The decline option selected TOGETHER with one or more suggestions** is an
     ambiguous answer, not a resolvable one — `multiSelect` puts both in the
     same question, so the human can tick both. Re-present that chunk rather
     than deciding which half to honour; emit no enrichment until the answer is
     unambiguous.
   - **A free-text question** (the built-in **"Other"** channel used to ask
     rather than answer — "which file is #3 in?") is **not an answer**: answer
     it and **re-present the same chunk**. A question never ends the phase, the
     same rule the interactive extension applies to its own "Other".
   - **Any other free text** is the human's **final** answer: stop chunking
     (never re-prompt a chunk they have ended), then:
     - free text that **names items** ("also do #2 and #7, that's all") **adds
       exactly those** — matched by their rendered number or title, including
       items from a chunk not yet asked — to the accumulated selection, and then
       ends the phase. If any name is ambiguous, treat the answer as a
       **question** (answer it, re-present that chunk) rather than guessing
       which item was meant;
     - free text that **names no items** declines **only the remaining chunks**,
       never the earlier picks.
     Either way the phase converges unchanged only when the accumulated
     selection over **every chunk actually asked** is empty — and the prompt
     *was* presented, so step 3's enrichment is still owed.
   - **Record the answer first, then branch** (below). Converge unchanged only
     when the **accumulated** selection over **every chunk actually asked** is
     empty; otherwise proceed to step 4 of this phase with the accumulated set.

   **Record the offered-vs-promoted pair (#995) — once the answer is known,
   before either branch above.** This is the one fact the sink cannot
   reconstruct: `waived` counts what the loop *logged*, never what a human was
   *shown* or *chose*. Append **one** `telemetry/v1` enrichment joined to the
   phase-1 run, via the shared emitter (no skill hand-rolls an envelope):

   ```bash
   # the guard IS the documented "no id -> no record, silently": unguarded, an
   # absent file makes `cat` complain and the emitter exit 2 on the empty
   # --run-id, handing you a failure you are separately told never to act on
   if [[ -s <blocking-phase-work-dir>/.telemetry-run-id ]]; then
     jq -nc --argjson offered <N-offered> --argjson promoted <N-picked> \
       '{event:"suggestion_promotion", suggestions_offered:$offered, suggestions_promoted:$promoted}' \
       > <scratch>/promotion-enrichment.json   # <scratch>: the same
       # outside-the-repo dir as the work-dir and findings files (§3.5), never a
       # path inside the worktree — one more file §5 could otherwise commit
     "<skill-base-dir>/../../scripts/telemetry/emit-telemetry.zsh" \
       --pipeline review-loop --kind enrichment --outcome success \
       --run-id "$(cat <blocking-phase-work-dir>/.telemetry-run-id)" \
       --repo-dir <repo> --issue <issue-number> [--repo-type T] \
       [--telemetry-file <the same file the loop was given>] \
       --payload <scratch>/promotion-enrichment.json >/dev/null
   fi
   ```

   - **`suggestions_offered`** is the size of the set step 1 derived and step 2
     rendered (it equals the phase-1 record's `waived` by construction — same
     union, same identity — and is repeated here only so the enrichment stands
     alone without a join). **`suggestions_promoted`** is the **accumulated**
     selection across every chunk — *how many the human picked*, recorded here
     at answer time and therefore **before** step 4's matching runs. It is not a
     count of items that reached the sub-loop: a run whose keys all fall out
     unmatched/unverified legitimately carries a non-zero value with no sub-loop
     at all (step 4's "**If NONE matched**" terminal), so never divide the
     sub-loop's `fixed` by it.
   - **No `--wall-s`** — the emitter rejects it on an enrichment, and `wall_s`
     lands `null`; **`--outcome success`** describes *the enrichment event*
     (the promotion facts were settled), never the run's outcome.
   - **`--repo-dir` must be the loop's `--repo` value** (a *path* — not the
     emitter's own `--repo`, which is the `owner/name` identity), **and
     `--telemetry-file` the same `--telemetry-file`.** Since #1006 the emitter
     has three sink determinants — `--telemetry-file`, `--telemetry-dir`, and
     `--repo-dir` (via the local default) — in the precedence
     `--telemetry-file` > `--telemetry-dir` > the local default
     `<repo-dir>/.claude/telemetry/telemetry.jsonl`. A differing
     `--telemetry-file`/`--telemetry-dir` lands the record in a *different*
     sink; a differing `--repo-dir` mis-derives `repo` (and picks a different
     sink too whenever `--telemetry-file` is absent — under `--telemetry-dir`
     the derived `repo` also chooses the file inside `DIR`) — and the emitter exits 0
     either way, so nothing surfaces the loss. The loop has no
     `--telemetry-dir` of its own, so the enrichment must not pass one either:
     mirror exactly what the loop was given and the two records share a sink.
   - **Emit exactly when the prompt was presented** — that is this step. A
     headless run, or one with nothing to offer, never reaches here and gets
     **no record at all**. Promoting **none** is a *settled* fact and **does**
     get a record (`suggestions_promoted: 0`) — it is the single most
     informative datum for "do humans act on suggestions?", so emit it and
     *then* converge unchanged.
   - **No id (absent/empty `<blocking-phase-work-dir>/.telemetry-run-id`) → no
     record.** The `-s` guard above *is* that rule: skip silently and carry on.
     A failed emit is likewise never fatal — telemetry never changes what the
     run does.

4. **Write the promote file and run the sub-loop.** The selected identity keys
   go to a JSON array file **outside the repo** (the scratch dir the work-dir
   and findings files already live in, §3.5 — anything written inside the repo
   changes the tree identity and defeats every `--gate-attest` match). Then run
   the promotion sub-loop exactly like the blocking phase — a **fresh
   `--work-dir`** and a **`--status-file` path distinct from the blocking
   phase's kept status JSON** (the `rm -f` below deletes **the promotion status
   file**, and §6 still needs the blocking-phase one), the same `--test-cmd`,
   the round protocol above — adding `--promote`.

   **Do not run the command below yet.** Round 1's `--findings-file` is the
   **seeded** file built by the ordered procedure that follows, and a
   NONE-matched classification means the sub-loop is never invoked at all. Read
   the procedure first, then come back to this invocation.
   **`rm -f <promotion-status.json> && [[ ! -e <promotion-status.json> ]] ||
   { echo "could not delete the promotion status file — its existence is no
   longer a signal; do NOT invoke the sub-loop"; exit 1; }` immediately before
   every invocation** (round 1, each `--resume`, each recovery re-invoke) so
   step 7's exit taxonomy can tell a status this invocation wrote from one the
   last one left behind — and so a *failed* delete is visible rather than
   silently turning the next exit's taxonomy into a guess. **On a failed delete,
   do not invoke the sub-loop at all**: step 7 could not then tell this
   invocation's verdict from the previous one's. Report it in the conversation
   and stop, or point `--status-file` at a fresh, deletable path and continue:

   ```bash
   "<skill-base-dir>/scripts/resolve-story-loop.zsh" --repo <repo> --base <base> \
     --work-dir <promotion-work-dir> --status-file <promotion-status.json> \
     --issue <N> --findings-file <findings-promo-round-R.json> \
     --promote <promoted.json> --test-cmd '<full gate>' [--resume] [--gate-attest <tree>]
   ```

   The consolidator raises each matching Low to `WARNING`/`High` **before** the
   conflict and non-convergence classification, so a promoted item is blocking
   in every downstream sense — and a regression introduced while fixing one is
   gated exactly like any other blocker. Matching **reuses the #983 identity
   rules** (gather on file + dimension + line proximity, decide by normalized
   title), so **a promoted item survives its own fix shifting the line** rather
   than silently reverting to Low.

   **Establish what is still there, then seed only what needs it.** The overlay
   can only *raise* a Low that is present in **that round's** findings — it never
   injects one. But the waived set is the cross-round union, so a suggestion
   raised in round 1 and never re-raised (exactly the case step 1 exists to
   cover) would match nothing in the sub-loop's fresh panel: zero blockers,
   `CONVERGED` on round 1, and step 7 would read that as the promoted set having
   been cleared when it was never even seen.

   This is an **ordered procedure**, not a set of independent rules — running it
   out of order destroys the evidence the verification needs:

   1. **Run the round-1 panel and keep its aggregate at its own path**
      (`<pre-seed-round-1.json>`, in the same scratch dir outside the repo as
      the promote file and the work-dir — §3.5). This is the verification
      baseline; do not overwrite it.
   2. **Classify each promoted key against that file**, in the *engine's* terms
      and never by exact key equality: it was **raised** when the panel reported
      an item with the same `file` and `dimension`, a line within the proximity
      window (**±10 lines**; an absent or null line is a wildcard within the
      file+dimension — ARCHITECTURE.md's consolidate-findings contract), and a
      title not fully disjoint from the promoted one (the #983 rules the overlay
      applies). A literal key-appearance check would call a
      genuinely present item missing the moment dedup kept a different
      representative title or its line drifted.
      - **Raised** → **matched, and it needs no seed**: the overlay will raise
        the panel's own item, which is the one at the *current* line. Seeding a
        second copy from the blocking phase's stale `line` would survive dedup as
        a separate entry, and the same defect would be raised twice — with the
        fix pass sent to a line where it no longer is.
      - **Not raised** → **look before calling it gone.** A panel is not
        deterministic, so silence is absence of evidence, not evidence of
        absence — and this branch ends in a claim in the PR body. Open the cited
        **`file`** and look for the defect the changelist item's
        `title`/`description` names — **search the file, not just the cited
        line**: the blocking phase's own fixes shift lines, which is exactly why
        the engine matches by identity rather than by line. Three outcomes, each
        with its own class:
        **still there (anywhere in the file)** → **matched**: this is what the
        seed is for. Seed it (projected as below) using **the line you actually
        found it at**, not the stale cited one — **and re-anchor the key to
        match**: rewrite that key's `line` in `<promoted.json>` to the same found
        line (or to `null`, the documented file+dimension wildcard) before
        invoking the sub-loop. The overlay gathers candidates within ±10 of the
        **key's** line, so a seed at the found line while the key keeps the stale
        one is never gathered — the item stays Low and the promotion silently
        fails to fire;
        **confirmably gone** (the pattern is absent from the whole file, or the
        file is) → **unmatched**;
        **cannot tell** → **unverified** — a third class, not a flavour of
        unmatched: do not seed it, do not count it matched, and never fabricate
        a change to satisfy a blocker you cannot locate.
   3. **Build the round-1 findings file** as the pre-seed aggregate **plus only
      the still-present-but-unraised keys** from step 2.

   **Projecting a seed.** `round_changelists[]` holds *consolidator output*
   (`priority`, `blocking`, `reviewers[]`, `agreement`), not findings, so copying
   one verbatim lands it with no `reviewer` — it then shows as `agreement: 0`,
   attributed to nobody, in progress.md and the dossier. Project instead, taking
   the fields from the **changelist item** you find by looking the promoted key
   up in `<status.json>`'s `round_changelists[]` on
   `[file, line, dimension, title]` (the key itself carries only those four, so
   `description` and `suggested_fix` can come from nowhere else). **Project the
   seed BEFORE re-anchoring the key**, and look it up on its **original**
   (as-derived) `line`: `<status.json>` only ever holds the stale line, so a key
   already re-anchored to the found line — or to `null` — matches nothing there,
   and the fields it says can come from nowhere else would have to be
   fabricated. If you have already re-anchored, look the item up on
   `[file, dimension, title]` alone:
   `{severity: "SUGGESTION", round: 1, dimension, file, line, title, description,
   suggested_fix, reviewer}` — where `line` is **the line you FOUND it at**, the
   same one you re-anchor the key to, never the changelist item's stale one (a
   seed outside the key's ±10 gather window is never raised, and step 7 would
   then report a still-present item as promoted-but-not-reproducible) (the #558 schema declares `round`), with `reviewer`
   from that item's `reviewers[0]`, or `"promoted-by-human"` when it has none.

   **Keep the matched set** — every key classed matched in step 2, seeded or not
   — in the **same scratch dir outside the repo** as the promote file and the
   work-dir (a file written inside the repo changes the tree identity, defeats
   every `--gate-attest` match, and risks being committed at §5). It is the set
   §6 **reconciles against the engine's raised count** (`promotion.promoted`) —
   not itself the cleared figure: a matched key the engine never raised is
   reported as promoted-but-not-reproducible, never counted as cleared.

   - **Report each class in the PR body's Summary by its own name** — never
     collapse them: **unmatched** keys are *promoted but no longer present*;
     **unverified** keys are *promoted but could not be verified*. Saying "no
     longer present" about a key you could not check is the one claim this whole
     procedure exists to prevent.
   - **If some keys matched**, continue as step 7. **If NONE matched**, treat the
     run as converged **with nothing promoted**, say so plainly, note the split
     between unmatched and unverified in the Summary, and continue to **§4
     (Version bump)**. Do not escalate and do not re-prompt — but never let a
     bare `CONVERGED` imply work that never happened.

   **Re-pass `--promote` on EVERY invocation of the sub-loop** — each
   `AWAITING_FIX` `--resume`, the interactive extension's resume, and a
   `STALE_FINDINGS` recovery alike. The loop persists the promoted set in its
   work-dir and re-adopts it when the flag is absent, so a slip degrades to a
   warning rather than a silent un-promotion — but do not rely on that: pass it
   explicitly, because an explicit `--promote` is what keeps the command you run
   and the overlay that is applied the same thing.

5. **Budget — the same one as the blocking phase.** Pass **no
   `--max-rounds` override**: the sub-loop inherits the loop's own
   `MAX_REVIEW_ROUNDS` default and is extended by the identical
   +3-per-approval interactive extension. There is deliberately **no second
   budget constant** — one number governs both phases.

   **`grants` starts at 0 for the promotion phase.** It is a separate loop with
   its own work-dir and its own ceiling, so it gets its own counter rather than
   inheriting the blocking phase's total; otherwise a story that spent four
   grants clearing real blockers would hit the soft-cap nudge on the promotion
   phase's *first* grant and be told "this isn't converging" about a phase that
   has consumed nothing. When you summarize an escalation here, report **both**
   counts ("2 grants this phase; 4 earlier on the blocking phase") so the human
   sees the story's true cost.

6. **One-shot.** New suggestions surfacing *during* the sub-loop are waived, not
   re-prompted — this phase runs once per story. New blockers (regressions)
   gate normally.

7. **Terminal.** The sub-loop clearing the promoted set is the run's final
   `CONVERGED` → continue to **§4 (Version bump)**. If the sub-loop **cannot**
   clear the promoted set — blockers still open when the budget runs out — it
   escalates through the existing taxonomy and the existing interactive
   extension: the human opted into making those items blocking, so they are
   treated as blocking, not quietly re-waived.

   **A round-1 `CONVERGED` with
   a non-empty matched set is not a verdict yet** — first check that round 1's
   `--findings-file` was the file built by **step 4's ordered procedure, item 3**
   (the pre-seed aggregate plus any still-present-but-unraised keys — identical
   to the pre-seed aggregate when nothing needed seeding) and that `--promote`
   was passed. The two answers lead opposite ways:

   - **Either was wrong** → this `CONVERGED` is an artifact of the slip, not a
     result. **Discard it**, fix the invocation, and re-invoke as a **fresh
     round 1** (a new `--work-dir` and `--status-file`, never `--resume`, which
     would run the seeded findings as round 2 against the phantom round's
     changelist). **Report nothing as not-reproducible** — nothing has been
     tested yet. Never re-invoke unchanged more than once.
   - **Both were correct** → the engine legitimately raised nothing, most likely
     because dedup kept a representative whose title is fully disjoint from the
     promoted keys. **Note what this proves: ZERO keys were raised**, since any
     raise would have produced a blocker and an `AWAITING_FIX`. So treat the
     **entire** matched set as not-reproducible — never just the one key you
     suspect — report every one of them in the Summary as
     promoted-but-not-reproducible, converge with **nothing** promoted, and
     continue to §4.

   **Neither exit 1 nor exit 2 is an escalation or a convergence here.** Both
   have several causes, so read the status file and stderr before acting —
   and **delete the status file immediately before each sub-loop invocation**,
   so "a status JSON exists afterwards" is an unambiguous signal rather than a
   guess about whether the file is this round's or the last one's.

   - **exit 2, `status: "STALE_FINDINGS"`** → the §3.5 step-2 refusal: recover
     by cause and re-invoke (re-passing `--promote`). Not a bad command line.
   - **exit 2, no status JSON written** → a genuine usage error in the
     invocation. **Stderr names the offending argument**: a missing, empty,
     non-file or wrong-shaped `--promote` path, a persisted promote path that
     has since vanished or been rewritten badly, a `--max-rounds` at or below
     the resumed round, or `--promote` passed together with `--no-review`. Fix the command and re-invoke.
   - **On an exit 1 or 2 whose pre-invocation delete was NOT verified**, any
     status JSON found is a **LEFTOVER** — the previous invocation's, because
     the delete above failed or was skipped. **The content test only works when the
     pre-invocation delete provably succeeded** — verify the path is absent
     (`[[ ! -e <promotion-status.json> ]]`) before invoking, and then any status
     found afterwards is provably this invocation's. If absence was **not**
     verified, the taxonomy is unreliable for *every* status, `STALE_FINDINGS`
     and `ERROR` included: a skipped delete can leave the previous
     invocation's refusal or red gate behind, and the cross-matched
     combinations (exit 2 over a leftover `ERROR`, exit 1 over a leftover
     `STALE_FINDINGS`) match no branch at all. Treat them all as leftovers.
     (Under a **verified-absent** delete the reverse holds, and it is keyed on
     the **write contract**, not on the status shape: exit 2 writes only
     `STALE_FINDINGS` or nothing, exit 1 only `ERROR` or nothing. So **any**
     freshly-written pairing those rules forbid — a neither-status, but equally
     exit 1 over a `STALE_FINDINGS` or exit 2 over an `ERROR` — is an **engine
     anomaly**, never a previous invocation's verdict, and never the
     same-status branch keyed to the other exit code. The action is the same,
     report and stop — the repoint-and-re-invoke option below applies only to a
     **LEFTOVER** (a stale path); re-invoking cannot fix an engine that just
     violated its write contract. Exit 0 and exits 20 / 10-13
     always write their own status, so they are never in question.)
     A **LEFTOVER** is never this invocation's verdict, and
     the delete discipline that makes the taxonomy readable has broken:
     **report the leftover in the conversation and stop** — or repoint
     `--status-file` at a fresh, deletable path (step 4) before any re-invoke.
     Do **not** take the "no status JSON written" branches' fix-and-re-invoke
     handling: re-invoking without clearing the stale file leaves the next
     exit's taxonomy just as unreadable, which is the hazard this rule exists
     to prevent. Reading a leftover round-1 `CONVERGED` as this exit's result
     would converge the promotion phase on a run that actually failed.
     **Exits 20 and 10-13 are not covered by this rule**: each always writes its
     own status, so that status *is* this invocation's verdict — take the round
     protocol (`AWAITING_FIX`) or the escalation branch, never this one.
   - **exit 1** → an operational failure, and **not necessarily the promote
     file**. A freshly written `status: "ERROR"` is a **red gate after the
     previous round's fix** — follow §3's rule (fix the gate, or abandon and
     report), never rewrite the promote file and never build an escalation
     comment from it. With **no** status JSON, stderr names the cause:
     `consolidate failed at round N` may be the promote file's contents *or* an
     invalid round-findings aggregate; a dispatch failure is neither. Fix what
     stderr names and re-invoke; if stderr names nothing you can act on, report
     in the conversation and stop.

8. **Keep BOTH status files — the dossier covers both phases (#1064).** The
   phase leaves a second status JSON, and §6 merges the two into the **one**
   section and **one** hidden `<!-- review-dossier: … -->` block the Approver
   parses (#563), by passing the promotion pair alongside the blocking-phase
   `--status`:

   ```bash
   "<skill-base-dir>/scripts/build-dossier.zsh" --status <blocking-status.json> \
     --promotion-status <promotion-status.json> --promoted <promoted.json>
   ```

   So keep all three paths: the blocking-phase status, the promotion-phase
   status, and the promote file. **Append its output exactly once** — never two
   hidden blocks in one body, or the Approver reads only the first — and
   **never hand-edit its output**. The rule is about *appended output*, not
   processes: a wrong-form run whose output was never appended is discarded and
   the correct invocation re-run (open-pr owns that recovery); one already
   appended means stop and report.

   The two promotion flags are an **atomic pair**: passing one without the other
   is a usage error (exit 2), never a silent fall back to a blocking-only
   dossier. Pass them exactly when **a promotion-phase status JSON that THIS run
   wrote and did not discard exists** — and not otherwise. Stated as the artifact
   rather than as "the phase ran", but note the two qualifiers, because a bare
   "a file is at that path" would be wrong twice over: the scratch dir is reused
   within a session, so an earlier story can leave one there (step 4's `rm -f`
   before every invocation is exactly what makes its later existence a signal —
   step 7's **LEFTOVER** rule), and step 7's discard branch abandons a phantom
   status that must never be passed either. Neither hazard is a terminal and
   neither prescribes a dossier form: a **LEFTOVER** means report and stop
   (step 7) — no PR, so no invocation at all — and after a **discard** it is the
   re-invoked sub-loop's own status, never the discarded file, that this
   condition tests. With that settled, the two terminals differ:

   - the *If NONE matched* terminal (step 4) **never invokes** the sub-loop, so
     there is no promotion status to pass → the plain `--status` invocation;
   - the **not-reproducible** terminal (step 7) *did* invoke it — a full round 1
     that wrote a `CONVERGED` status — so **pass the pair**. The dossier then
     records `selected: N, promoted: 0`, which is the honest shape: the human
     picked N and the engine raised none. Dropping the pair here would discard a
     real phase's rounds and the pick count, which is exactly the record #1064
     exists to preserve.

   The merged dossier drops a promoted-and-fixed item from the waived list and
   from the per-dimension suggestion counts, and carries a
   `promotion: {rounds, status, selected, promoted}` object — so the waived list
   no longer contradicts what the run did. §6 still owns the Summary's count
   contract (both counts plus step 4's unmatched / unverified split); what it no
   longer needs is the "dossier covers the blocking phase only" caveat.

   **On a non-zero exit, do not open the PR without the dossier.** The script
   prints nothing on stdout when it fails, so an unchecked invocation is
   indistinguishable from the legitimate "no loop ran" no-op — the silent-loss
   failure its own validation exists to prevent. Check the status: **2** is a
   usage error (a broken atomic pair, a flag missing its value) and **1** an
   input error (a status that is not one JSON object, a `null`-holding or
   two-object scratch file, a wrong-shaped promote file); stderr names the
   offending flag and file in both cases. Fix what it names and re-run. Treat
   **empty output at exit 0** the same way whenever the loop is known to have run
   a round — it means `--status` points at the wrong file.

   If what stderr names **cannot be restored** — a kept status or promote file
   lost or clobbered after convergence — **report in the conversation and stop**:
   no PR. Never reconstruct a status or promote file by hand to satisfy the
   command; the dossier is an audit record, and a hand-built input fabricates
   exactly the history it exists to attest.

#### Escalation (any `ESCALATE_*` / `BUDGET_EXHAUSTED` status) — typed, no PR (#564)

A bad escalation costs a human an afternoon; a good one costs two minutes. On
any `ESCALATE_*` / `BUDGET_EXHAUSTED` status, produce **one** decision-ready
issue comment and nothing else — **no PR, no auto-merge exposure**:

**Only those statuses escalate.** Exit 1/2 are operational, never escalations:
`STALE_FINDINGS` (exit 2) follows §3.5 step 2's recover-and-re-invoke, and any
other exit 1/2 is reported in the conversation. Never build an escalation comment
from a status file the failed invocation did not write.

**Interactive extension (human present, `BUDGET_EXHAUSTED` /
`ESCALATE_NO_CONVERGENCE` only, #562-resume).** When the run is
**interactive** — the same human-present determination §0a's remediation uses —
and the loop exited `BUDGET_EXHAUSTED` or `ESCALATE_NO_CONVERGENCE`, do **not**
jump straight to the comment. The person who can grant "three more rounds" or
supply the missing constraint is right here; offer that in-session first. (Every
other exit — `ESCALATE_CONFLICT`, `ESCALATE_AMBIGUOUS` — and **every autonomous
run** skip this branch entirely and go straight to the typed comment below.)

Run this extension loop, tracking a `grants` counter **per loop** — where a
"loop" is one `--work-dir` and its chain of `--resume` invocations. It starts at
0 the **first** time the extension is entered for that loop; re-entering after an
`AWAITING_FIX` detour or a later escalation **of the same loop** resumes the
existing count — **never reset it**, or the `--grants` figure shown to the human
understates what was consumed and the step-6 soft cap can never fire across
detours. The **promotion sub-loop (#994) is a different loop** — its own
work-dir, its own ceiling — so it starts its own counter at 0; pass the **current
loop's** count to `--grants`, and mention the other phase's total as prose
alongside the summary so the human still sees the story's full cost:

1. **Summarize** the exit in the conversation — never make the human read a
   comment when they are right here:

   ```bash
   "<skill-base-dir>/scripts/build-escalation.zsh" --status <status.json> \
     --format summary --grants <grants>
   ```

   It prints the typed status, the remaining blockers (severity + dimension,
   with any **possible false trip** flagged), the round history, the
   **per-round progress table** (Critical/Warning/Suggestion, a **Promoted**
   column when any round has a promoted blocker (#995), new/carried,
   fixed-since-prior), the **convergence assessment** — an explicit, honest
   read of whether another round is likely to help — and the grants consumed
   against the soft cap (#969). Show all of it *before* the `AskUserQuestion`
   in step 2, so the human can decide **and** supply direction from the
   summary alone. It is the same data the comment would carry, so nothing
   drifts — never compose an ad-hoc summary instead.

2. **Offer the choice** with `AskUserQuestion` (one question), tailored to the
   exit type. The built-in **"Other"** option is the free-text channel — the
   human uses it to *ask you a question* ("why is that blocker stuck?", "show me
   the diff for `b.py`") **or** to *type guidance*.
   - `BUDGET_EXHAUSTED`: **Grant +3 rounds** · **Grant +3 with guidance** ·
     **Stop**.
   - `ESCALATE_NO_CONVERGENCE`: **Give guidance & retry (+3)** — the primary
     lever, since more rounds alone will not move a stuck blocker — · **Stop**.
     When the step-1 assessment reports **every** carried match as a possible
     false trip (the blockers may be fresh, not stuck), also offer a plain
     **Grant +3 rounds** option — the guidance-only framing would contradict
     the assessment shown moments earlier.

3. **If they asked a question** (Other → a question, not guidance): answer it
   from the changelist / dossier, then **re-present step 2**. A question never
   consumes a grant.

4. **If they gave guidance** (with or without an explicit grant — guidance
   always implies a grant; the +3/`grants` bookkeeping happens **once**, in
   step 5): **post it as an issue comment** so it is durable and
   survives a dead session, tagged so the audit trail separates human guidance
   from the automated escalation comment:

   ```bash
   # via a QUOTED heredoc + --body-file, never --body "$GUIDANCE": guidance
   # about code routinely contains backticks/$(...) that a double-quoted
   # --body would hand to the shell as command substitution
   cat > /tmp/review-loop-guidance.md <<'GUIDANCE_EOF'
   <!-- review-loop-guidance -->
   <the guidance text>
   GUIDANCE_EOF
   gh issue comment <N> --body-file /tmp/review-loop-guidance.md
   ```

   Then resume (step 5): re-read the issue's comments during the pre-resume
   in-session fix pass so the guidance becomes fix context (the readiness gate
   and escalation already read comments — reuse that, do not invent an env
   side-channel).

5. **If they granted rounds** (with or without guidance): **first apply one fix
   pass, then resume.** The escalated round broke *before* its own fix pass ran
   (the loop's round order is review → decide → fix), so the tree still holds
   the un-fixed blockers — resuming immediately would re-review unchanged code
   and instantly re-trip non-convergence against the carried prior round,
   burning the grant on a no-op. So: read the status JSON's
   `final_changelist.blocking` (plus the guidance comment, when one was posted)
   and implement the fixes exactly as step 2 implements, re-run the step-3 gate
   — resume only once it is green; red follows §3's rule (fix it, or abandon and
   report) — run the next round's panel in-session (round protocol step 1) to
   produce its findings file, then resume the loop — same `--work-dir`,
   `--resume`, ceiling raised by 3 — and increment `grants`.
   **The grant raises the *ceiling* by 3, not the remaining rounds**:
   after a `BUDGET_EXHAUSTED` (round == `max_rounds`) that is
   exactly three more rounds (ceiling 8 after the default budget, rounds 6-8),
   but an `ESCALATE_NO_CONVERGENCE` can fire as early as round 2, where the same
   `prev_max + 3` leaves more than three
   (ceiling 8 after a round-2 exit = 6 rounds left). Compute the remainder
   (`new ceiling − rounds already run`) and say what the resume actually buys,
   rather than promising a flat three. The soft cap counts **grants** and the
   20-round figure is a `max_rounds` value, so the varying remainder changes
   neither.
   On a plugin repo
   pass the green gate's `tree` as `--gate-attest` here too (#981, under the four
   rules above), so the resume skips the byte-identical re-run just as a normal
   round does; omit it on any other stack:

   ```bash
   "<skill-base-dir>/scripts/resolve-story-loop.zsh" --repo <repo> --base <base> \
     --work-dir <same-work-dir> --resume --max-rounds <prev_max + 3> \
     --findings-file <findings-round-R.json> --test-cmd '<full gate>' \
     [--gate-attest <tree>] [--promote <promoted.json>] --issue <N> \
     --status-file <status.json>
   ```

   **`--promote` is required here whenever the escalating loop IS the promotion
   sub-loop** (#994). The loop persists the promoted set in its work-dir and
   re-adopts it if you omit the flag, so a slip degrades to a warning rather
   than a silent un-promotion — but pass it explicitly anyway, so the command
   you run and the overlay that is applied never diverge. The same applies to
   the `STALE_FINDINGS` recovery re-invoke below.

   On `CONVERGED` (exit 0) → leave this branch, offer the **suggestion-promotion
   phase** under its own gate (unless this loop *is* the promotion sub-loop —
   the phase runs once per story), then proceed to §4 (Version bump) / PR as
   normal. **Every** path to `CONVERGED` passes that gate exactly once; an
   extended run is the one most likely to have accumulated waived suggestions,
   so it is the last one that should skip the offer. On another `BUDGET_EXHAUSTED` /
   `ESCALATE_NO_CONVERGENCE` → go back to step 1 with the new status. On
   `ESCALATE_CONFLICT` / `ESCALATE_AMBIGUOUS` → leave this branch and take the
   typed-comment terminal below (a resumed run can surface a different exit).
   On `AWAITING_FIX` (20) → continue the §3.5 round protocol (narrate, fix
   in-session, re-run the gate, run the next panel, `--resume` with the same
   raised `--max-rounds`) — no grant bookkeeping; the grant was already
   counted. On `STALE_FINDINGS` (exit 2, #974) → **not terminal**: recover by
   cause per §3.5 step 2 (re-invoke with round R's real findings path, or run
   its panel first, re-passing the same `--gate-attest` per §3.5's recovery
   rule) and resume with the same raised `--max-rounds`. The grant
   was already counted at the resume that produced this exit — the recovery
   re-invocation neither increments nor decrements `grants`, and never re-runs
   step 1's `build-escalation.zsh` summary on the `STALE_FINDINGS` status. On
   any **other operational error** (exit 1/2), the loop wrote
   either **no** new status (on the blocking phase the file still holds the
   *previous* escalation; on a promotion sub-loop it is absent, because that
   phase deletes it before every invocation) or
   a status `ERROR` (a red gate after a fix) — neither is a typed escalation, so
   never build a comment from the file: report the error in the conversation and
   stop.

6. **Soft cap.** Before re-offering, if `grants >= 5` **or** the **last round
   removed no blockers** — measured by the progress table's *Fixed since
   prior* column (prior blockers cleared: the prior round's blocking count
   minus distinct matched priors) being 0, **not** by the net
   blocking count, which a churn round (fixed 3, found 3 new) would wrongly
   trip; fall back to comparing `.round_changelists[-1].summary.blocking` to
   the round before only when the Fixed cell degrades to `–` (stamp-less
   round) — say
   so plainly — "this isn't converging; the diff may need rethinking" — and nudge
   toward **Stop** or splitting the work into a follow-up issue. Never hard-stop
   on the human; they may still choose to extend. The cap is a **nudge** by
   design, not a hard stop (#993): by the fifth grant the ceiling already stands
   at 5 + 5×3 = 20 rounds, and the human — not the counter — decides whether to
   go past it.

7. **Stop / decline** (the human picks Stop, or bails via "Other"): fall through
   to the typed-comment terminal below, exactly as an autonomous run does. The
   diff-so-far and any guidance are already on the issue; the human can resume
   later with `/development:resolve-issue <N>`.

If the interactive extension ended in `CONVERGED`, skip the terminal below,
offer the suggestion-promotion phase under its own gate (as above — once per
story), and continue to §4. A `STALE_FINDINGS` exit never ends it — recover and resume as
step 5 says. If it ended in another **operational error**, it was already
reported in-session (step 5) — stop, with **no** typed comment. Otherwise (a
Stop / decline, or a `CONFLICT` / `AMBIGUOUS` exit):

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

### E4. Comprehensive epic verification (after ALL children merge)

The per-child gates tested each change in isolation, but can't see the
children's **combined** effect. Once the whole epic is on `main`, run a
**holistic end-to-end test of the epic's domain** and report:

- **Java / Python app** (most critical) — the full build + test suite, plus a
  real end-to-end exercise of the affected behaviour (run the relevant pipeline
  / the app itself), so integration regressions surface here.
- **Claude-plugin** — the full `bats` suite via the blessed single-run gate
  `<skill-base-dir>/scripts/run-gate.zsh --tests-dir tests` (#980 — same
  parallel, single-run, real-exit command as Step 3; never a bare `bats … |
  grep -c` that runs the suite twice) **and** `/development-claude-plugin:test`
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
→ its merged PR), the **E4 verification result** (what holistic test ran and
that it passed), and any `skipped_self_ref` line an E1 backfill reported —
quoting the body **lines**, not the array entry — so the closed epic is a
self-contained record. Only after this
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
