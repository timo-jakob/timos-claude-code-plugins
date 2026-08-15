---
name: refine-issue
description: >
  Take a GitHub issue the readiness gate sent back (`needs-refinement`) and drive
  it interactively to READY — the guided path from "no" back to "ready". A human
  is present throughout: you diagnose the story with `story-readiness`, then loop
  the `issue-refiner` agent (per-turn: explanation, questions, recommendations, a
  draft rewrite, a proposed `story-spec/v1` block) relaying between it and the
  human until they approve a rewrite. Then you write back the human-approved prose
  plus a provenance-stamped `story-spec` block (a human-authored issue edit, NOT a
  bot PR), re-gate, remove the `needs-refinement` label only if READY, and post a
  before/after comment trail. When a session can't converge, take a typed parked
  exit (needs-decision / split-recommended / deferred) that a later run resumes
  from (#578). Pointed at an epic, it walks each needs-refinement child through
  that single-issue flow and posts an epic-level summary (#580). The intelligence lives in the
  agent, this skill is the conductor. Composes story-readiness (#559) and
  issue-refiner (#575); consumes the story-spec/v1 contract (#574).
disable-model-invocation: false
---

You are the **conductor** of an interactive refinement session. A story failed
the `story-readiness` gate and carries `needs-refinement`; a human wants to fix
it. The **intelligence is in the `issue-refiner` agent** (#575) — a per-turn pure
function; **you** relay between it and the human, and **you** own every GitHub
write. The payoff of doing this well: the story reaches the implementer precisely
specified, and a durable machine-readable `story-spec/v1` block rides along.

**User input:** an issue number or URL. Operate on the session's repo
(`gh repo view --json nameWithOwner`); the issue must belong to it. If empty,
print `/development:refine-issue <issue-number|url>` and stop.

**Epic or single issue? (#580)** First classify the target
(`gh issue view <N> --json labels,body`): it is an **epic** when it has
**native sub-issues** (the resolve-issue shared reader,
`read-sub-issues.zsh --repo "$REPO" --epic <N>`, reports `summary.total > 0` —
the authoritative signal, #802), when it carries the `epic` label, or when its
body holds a task list of child issues (`- [ ] #N` — the un-backfilled shape).
A **child line is a checkbox whose content STARTS with the issue reference**
(#1260) — a checkbox that merely *mentions* an issue is an **acceptance
criterion**, not a child, and lines inside fenced code blocks don't count;
counting a refined story's cross-referencing criteria would walk it as an epic
and it would never get refined at all. `read-dependencies.zsh` codifies the
rule (see ARCHITECTURE.md, *Issue-dependency model*). Several near-miss shapes
are deliberately **not** child lines — a bare **issue URL**, an
**ordered-list** checkbox (`1. [ ] #687`), a **decorated** ref
(`- [ ] **#687**`, `- [ ] [#687](url)`), and a ref glued to the **checkbox**
or to a following **word** (`- [ ]#687`, `- [ ] #687x`). *Why* each is
excluded is recorded once, per shape, in ARCHITECTURE.md (*Issue-dependency
model*); read it there rather than restating the split here — your action is
the same for every one of them.
**Native sub-issues and the `epic` label always win** — with either present,
go to the Epic walk regardless of the body's shape. **A genuine child *declaration* also
wins over any near-miss line beside it**: one line that matches the #1260 rule
**and declares that issue as this epic's work** makes the body an epic, which
goes to the Epic walk and its backfill path. The rule is a *shape* test and
the classifier script cannot see intent, so matching it is necessary but
**not sufficient**. **Shape alone never triggers the near-miss stop — intent
does**: it applies only when **none** of the child-shaped lines is a
rule-matching child *declaration*, **and** such a list
is the *sole* epic signal (`summary.total == 0`, no `epic` label), **and** it
is plainly the epic's children declaration — a section whose items are
separate issues, never a *Slices* section (work descriptions, not issues) and
never acceptance criteria. **A checkbox stating a condition *about* an issue
is a criterion however it is written** — decorated or bare, matching
the #1260 shape rule or not. Both `- [ ] **#1189**'s note is updated` and
`- [ ] #1189's note is updated` are criteria: refine the issue as a single
story. The second matches the shape rule, which is exactly why intent, not
shape, decides — walking it as an epic would backfill #1189 as a sub-issue of
the story (a misparent; one parent only) and the story would never get
refined, the very harm this narrowing exists to prevent.

**When all three conditions above hold** — no rule-matching child declaration,
the list is the sole epic signal, and it is plainly a children declaration
rather than slices or criteria — report it and
stop: ask for native sub-issues, or for the list to be rewritten as
`- [ ] #N`, rather than refining the body as a single story. **A criteria-only
body satisfies none of them**: refine it as a single story, and never
report-and-stop on it.
On a **failed** `read-sub-issues.zsh` call, **exit 2 is your own bad
invocation** — fix the command and re-run, the same rule step 1 applies to the
backfill's dry run. **Any other nonzero exit is a classification
failure** — report
it and stop; never fall back to the label/task-list signals as if the native
signal were checked and absent (a native-only epic would misclassify as a
single issue, and you'd refine the epic body itself — which the guardrails
forbid). An epic → the **Epic walk** below; anything else → the single-issue
flow (Steps 0–7).

## Epic walk — refine every needs-refinement child (#580)

When pointed at an epic, you don't refine the epic itself — you **walk its
`needs-refinement` children** through the single-issue flow, then report. The
story-readiness epic pre-flight (#559) can park several children at once, and
this is the guided pass that clears them.

1. **Enumerate the refinable children** with the enumerator (it reads the
   epic's **native sub-issues** through the shared reader — the #802 contract;
   the body's markdown task list is only the human-readable view — and keeps
   the **open** ones carrying `needs-refinement`, in sub-issue order):

   ```bash
   "<skill-base-dir>/scripts/list-refinement-children.zsh" --repo "$REPO" --epic <N>
   ```

   **Branch on the exit code, not just the output**, and split the two nonzero
   codes as this skill already splits the backfill dry-run's below. **Exit 2 is
   your own bad invocation** (an empty `--repo`, a dangling flag) — fix the
   command and re-run the enumerator for this epic; stop and report stderr only
   if it exits 2 again or you cannot see what is malformed. Abandoning the walk
   there would refine **no** child because of your own typo. **Exit 3** is an
   enumeration **failure** — report it and stop
   *without* claiming the epic has no refinable children; an empty result is
   only meaningful on exit 0.

   **Exit 0 with no children returned** → classify the zero before concluding
   (#798's lesson — an un-backfilled epic and a nothing-to-refine epic
   enumerate identically). Read
   `read-sub-issues.zsh --repo "$REPO" --epic <N>`: when `summary.total == 0`
   **and** the body still holds `- [ ] #N` task-list lines — **child
   declarations** by the #1260 rule above **plus intent** (the checkbox STARTS
   with the ref, the line is outside any fence, **and** it declares that issue
   as this epic's work), never criteria that merely state a condition about an
   issue, which fail the intent half even when they pass the shape half — the epic is
   **un-backfilled** — its `needs-refinement` children are invisible to the
   native enumerator. Run resolve-issue's
   `backfill-sub-issues.zsh --repo "$REPO" --epic <N>` (`--dry-run` first and
   vet the plan, per resolve-issue E1's hazard note — context refs are not
   children). **Branch on the dry-run's EXIT CODE first**: a nonzero exit
   (missing jq/awk, epic fetch, body-parse or sub-issue-list failure, or a
   usage error) prints
   no document, which read as a plan looks exactly like the empty-plan halt
   below. **Exit 2 is your own bad invocation** — fix the command and re-run
   the dry-run; **exit 1** you report verbatim as a backfill failure and stop,
   never as a non-migratable task list. Then, **four dry-run halts, all BEFORE the live
   run** — exactly E1's,
   because a run you must halt on is a run whose GitHub writes must never
   happen: `would_add` holding any ref that is not a child line by the rule
   above (the backfill's parser deliberately reports refs from anywhere on a
   checkbox line, and the rule's shape half cannot see intent — a ref sourced
   from `- [ ] #1189's note is updated` is not a child line); a non-empty `skipped_cross_repo`; an empty
   `markdown_children`; and — the **reverse** of the first — every checkbox
   line you read as a child declaration, in **any** shape, must appear in
   `would_add`/`already_present` (or be reported in `skipped_cross_repo`, or
   in `skipped_self_ref`). A
   child-shaped line that yields nothing is E1's reverse-vet halt: it is the
   case where the other three all pass, so nothing else would catch it.
   In each of those four cases do **NOT** run the live backfill — report
   it, naming the line, and stop.

   **`skipped_self_ref` is not one of the four halts.** It holds the epic's own
   number, which is expected: an issue cannot parent itself. Note it in the
   epic-level summary (or, when the walk ends before step 3, in the report you
   give the human) as a self-reference that was not migrated, and **quote the
   body LINES, not the array entry** — it holds that number at most once, so a
   genuine tracker line and a *mistyped* child ref yield the identical array.
   **Then judge each line**: a tracker line halts nothing; a line that reads as
   a child declaration carrying the epic's own number is a *mistyped child* —
   do **NOT** run the live backfill: report it, naming the line, and stop
   (exactly as the four halts above), since no sub-issue will ever carry that
   work. **If you cannot tell which it is, halt and ask rather than
   proceeding** — a walk that guesses "tracker" migrates the rest and leaves
   the mistyped child unfiled.

   **Only when no line halts**, run the live backfill and **gate its outcome
   exactly as E1 does**:
   re-enumerate only after the backfill exits 0 with every markdown child
   accounted for in `added`/`already_present` and `skipped_cross_repo` still
   empty. On exit 5 (partial) or 1, report the **backfill
   failure** to the human, naming the unattached children — never the
   "no children to refine" terminal, which a failed backfill would satisfy
   vacuously — and stop.

   **An EMPTY plan is not a clean backfill.** A run with `markdown_children:
   []` exits 0 and satisfies every clause above trivially, so it would reach
   the benign terminal through the success door instead of the failure one.
   It means the `- [ ] #N` lines you read are not migratable child
   declarations by the rule above — either a near-miss shape the backfill
   resolves nothing from, or a ref it resolves but never attaches (a
   cross-repo ref, a self-reference to the epic). A near-miss shape the
   backfill *does* resolve is **not** a cause: it trips the
   `would_add`-holds-a-non-child halt instead. ARCHITECTURE.md records which
   shapes fall on which side. Report that to the human,
   naming the lines, and stop; never re-run the backfill hoping for a
   different result, since it is idempotent.

   **Which terminal applies — the enumeration is closed, so take the branch
   that matches:**
   - **On the backfill path** (this was an un-backfilled epic): only a
     backfill that actually attached — or found already present — at least one
     child may re-enumerate, and only THAT re-enumeration coming back empty is
     the benign terminal.
   - **`summary.total > 0` with an empty enumeration** — the ordinary healthy
     case, no backfill involved: that **is** the benign terminal. Tell the
     human the epic has no `needs-refinement` children to refine, and stop.
   - **`summary.total == 0` with a task list in a near-miss shape** (step 0's
     shapes) — children in intent but not by the rule, so the backfill path is
     never entered for them (for some of these shapes the backfill *would*
     migrate the line unvetted, which is just as much a reason not to enter
     it — ARCHITECTURE.md records which). Report it,
     ask for native sub-issues or for the list to be
     rewritten as `- [ ] #N`, and stop. (This is resolve-issue E1 case 4.)
   - **`summary.total == 0` with a task list of inline slices** (resolve-issue
     E1 case 2) — slices are not issues, so there is nothing here to refine:
     say so and stop.
   - **`summary.total == 0` with a task list of citing acceptance criteria** —
     criteria are neither issues nor slices, so this is **not** case 2: it is
     resolve-issue E1's **otherwise** halt. Report the shape and stop. Never
     file it as case 2 — case 2's terminal is the only non-native door to
     E4/E5, and a labelled epic admitted through it can be closed on merge
     evidence for work that was never its own.
   - **`summary.total == 0` with no task list at all** — the epic was never
     decomposed. Report that decomposition comes first, and stop.
   - **Anything else** — report the shape you actually read and stop; never
     force-fit it into a branch above, and never conclude "no children to
     refine".

2. **Walk each child in turn** through the **single-issue flow** (Steps 0–7) —
   reuse it as written, one child fully before the next. A child either reaches
   `READY` (its label cleared, Step 5) or takes a **typed parked exit** (Step 2's,
   or Step 5's `deferred` stop);
   a parked child does not halt the walk — record it and continue to the next.

3. **Post an epic-level summary** on the epic issue: for each child, whether it is
   now **ready** (label cleared) or **still parked** (with the park type), plus
   any that had no work to do, plus any `skipped_self_ref` line a backfill
   reported (named as a self-reference that was not migrated — necessarily a
   **tracker** line, since a mistyped child ref halts the walk at step 1)
   — and, separately, any that ended in a **failure**
   state: *skipped (human declined)*, *label-removal failed*, *parked (comment
   build failed)*, or *parked (resume state not saved)* when the comment built
   but did not post. Never fold a failure into "no work to do": a failed child
   reading as a benign zero is how it gets forgotten. **A ready child's line also notes its expected
   docs pages (#768)** — the refiner's `expected_docs_pages` from that child's
   final turn (e.g. `· docs: docs/how-to/use-the-rest-api.md`), omitted when the
   field is `[]` (a no-surface child has no docs duty) — so the epic's docs
   impact is legible at refinement time, before resolve-issue's same-PR
   user-docs step (#767) enforces it at build time. Then re-run the enumerator
   (or note the still-open
   `needs-refinement` set) so the summary reflects the true post-walk state. This
   is the roll-up a human reads to see the epic's refinement progress at a glance.

The walk is **resumable**: re-running on the epic re-enumerates and continues
from whichever children are still `needs-refinement`.

## Step 0 — fetch, and check the precondition

```bash
gh issue view <N> --json number,title,body,state,labels,url,comments
```

- If `state` is not `OPEN`, stop — nothing to refine.
- **Stamp the run's start and the repo path, for Step 7:**

  ```bash
  T0=$(date +%s)                              # this run's start, for wall_s + ts
  REPO_ROOT="$(git rev-parse --show-toplevel)" \
    || { echo "not in a git work tree — Step 7 will skip the record"; REPO_ROOT=""; }
  # Step 7's run variables. Initialize them HERE so a later child in an epic
  # walk can never inherit the previous child's values, and assign the real
  # ones as you go: STATE_OUTCOME at Step 2's park, Step 5's guarded label write,
  # or Step 5's `deferred` stop — never at Step 1, whose shortcut delegates it to
  # Step 5; PARK_TYPE at Step 2's park or Step 5's `deferred` stop, cleared at
  # Step 1's shortcut and Step 5's READY branch; RISK from Step 1's verdict; the
  # three counts from the Step 2 loop, or explicitly on a run that made no
  # refiner call.
  STATE_OUTCOME=""; PARK_TYPE=""; RISK=""; ROUNDS=""; RAISED=""; RESOLVED=""
  # Print the two stamps: Step 7 needs their LITERAL values many tool calls
  # later, and a shell variable does not survive that gap.
  echo "carry into Step 7: T0=$T0 REPO_ROOT=$REPO_ROOT"
  # A stale parked-state from a PREVIOUS epic-walk child would otherwise be read
  # as this child's, giving its record the wrong park_type.
  rm -f /tmp/parked-state.json /tmp/parked-comment.md /tmp/parked.json
  ```

  `T0` is **per-run, not per-session**: `wall_s` and `ts` are measures of *one*
  single-issue flow, so the **epic walk re-stamps both for every child** (it
  re-enters Step 0 per child). Carrying a prior child's `T0` forward would make
  each subsequent child's `wall_s` include all the preceding ones. The contract
  requires a **measured** number and you have no other clock — without the
  stamp, Step 7 can only guess, and a guessed figure in the evidence stream is
  worse than none, so Step 7 skips the record rather than fabricate one.
  `REPO_ROOT` must be the repo **directory** — `$REPO` is an `owner/name`
  identity, not a path, and the emitter keeps the two on separate flags.
- **Precondition — the `needs-refinement` label.** This skill is for stories the
  gate sent back. If the label is **absent**, **warn and confirm** before
  proceeding ("this issue isn't marked `needs-refinement`; refine it anyway?") —
  you can refine a story that was never formally gated, but the human should
  choose that deliberately. If they decline, stop.
- Read the issue's **prior gate comment(s)** in the thread — the refinement
  questions the gate already posted are the objections you start from.
- **Resume a parked session if one exists (#578).** A prior run may have taken a
  **typed parked exit** (Step 2 below) rather than converging. Check the comments
  for its machine-findable resume state and, if present, carry it into this
  session so you continue instead of restarting:

  ```bash
  gh issue view <N> --json comments -q '.comments[].body' \
    | "<skill-base-dir>/scripts/read-parked-state.zsh" > /tmp/parked.json
  case $? in
    0) : ;;  # parked previously — /tmp/parked.json has {type, open_questions, conversation, …}
    1) : ;;  # never parked — a fresh session, nothing to resume
    *) echo "parked-state read errored"; exit 1 ;;
  esac
  ```

  When a state is present, seed the Step 2 loop with it: its `conversation`
  becomes the refiner's initial `conversation`, and its `open_questions` (plus
  the park `type` and any `decision`/`owner`/`candidate_children`) are context
  the human is resuming from. Tell the human what the prior run parked on before
  continuing the loop.

## Step 1 — diagnose (fresh objections)

Spawn **`story-readiness`** (Task tool, `subagent_type: story-readiness`) on the
repo + issue to get a **current** verdict — the thread's comment may be stale
against the latest body. Take its `refinement_questions` as the authoritative
**objections** for this session, and **record the verdict's `risk`** into Step 7's
`RISK` **verbatim** — one of `low`, `normal`, `elevated` (e.g. `RISK=elevated`),
never a placeholder and never a default, since it rides into
`risk_classification` unvalidated and a plausible-but-wrong level is worse than
none. If the spawn fails or the verdict carries no `risk`, leave `RISK=""`: the
contract makes `risk_classification` nullable for exactly this case, and an
empty value null-ifies rather than fabricating. A verdict carrying some *other*
level is still recorded verbatim — unlike `park_type`, this field is pipeline
detail that neither the guard nor the builder polices; only a **missing** risk
becomes `RISK=""`. This
**diagnosis** verdict is its only source: it is the risk of the story *as the
gate sent it back*, which is what the metric measures, so Step 4's re-gate
`risk` is never substituted for it.

If it already returns `READY`, tell the human the story now passes and offer to
just clear the label (Step 5) — no loop needed. **If they accept**, that
shortcut is still a run: set `PARK_TYPE=""; ROUNDS=0; RAISED=0; RESOLVED=0` —
measured zeros, assigned deliberately, so a no-op never reads as a hard-won
convergence — then run **Step 5's `READY` branch**, which assigns
`STATE_OUTCOME` only if the label removal actually succeeded, and emit Step 7's
record. Never set `STATE_OUTCOME="refined-ready"` here: it would claim `success`
for a story whose label the removal may have failed to clear. Then **skip Step
6** — nothing changed, so there is no before/after trail to post — and stop
after Step 7, which emits **at most** one record (none if Step 5's label
removal failed and the label is still set). **If
they decline**, ask whether they want to refine anyway: if **yes**, continue to
Step 2 and this **is** a run (Step 5 decides its outcome); if they decline **and
stop**, nothing happened — no label change, no refinement — so emit **no**
record; it was not a run. (In an epic walk that ends **this child**, not the
walk: note it in the epic summary as *skipped — human declined* and continue to
the next child.)

## Step 2 — the refinement loop (human present)

Each round is one call to the **`issue-refiner`** agent (Task tool,
`subagent_type: issue-refiner`). Pass it **one JSON object**:

```json
{
  "repo": "owner/name",
  "issue": { "number": <N>, "title": "…", "body": "… current body …" },
  "objections": ["… from Step 1 (or the still-open ones next round) …"],
  "conversation": [ { "role": "refiner"|"human", "text": "…" } ],
  "human_reply": "… the human's latest reply (empty on the first round) …"
}
```

Then relay its returned JSON to the human in readable form:

- **`explanation`** — *why* each objection blocks the story (so the human
  understands the gap);
- **`questions`** — surface them and **collect the human's answers**;
- **`recommendations`** — the concrete rewrites it suggests;
- **`proposed_prose`** / **`proposed_story_spec`** — the draft, when it has one.

Append this round (your relayed summary + the human's reply) to `conversation`
and call the agent again with the human's `human_reply`. **Converge when the
agent reports every objection `resolved: true` AND `questions == []`** — its
`resolved_objections` drives this decision (that is its whole purpose). Then
present the **final `proposed_prose` + `proposed_story_spec`** and get the
human's **explicit approval of the exact rewrite**. Nothing is written until they
approve. If they want changes, feed their reply back for another round.

**Record Step 7's counters as you go — on every path through this loop, not just
a park.** They have no other source, and Step 7 refuses to guess, so leaving them
unset makes it skip the record entirely rather than report a fabricated zero:

A shell variable does **not** survive between Bash tool calls, and this loop
spans many of them across human turns. Step 7's fence reads **eight** variables
— Step 0's `T0` and `REPO_ROOT` plus the six run variables — and its guard reads
them *before* the `jq` does, so substituting literals into the `--arg` lines
alone still leaves the guard seeing unset values and skipping the record. So:
carry all eight in your own notes as you go (Step 0 prints its two), and
**re-assign every one of them on the lines immediately above the guard, in the
same invocation as the fence**. The guard reads **seven** of the eight — all but
`RISK`, which only the `jq` reads — so an omitted `RISK` is not skipped, it is
silently recorded as `null`. Never assume an assignment from an earlier turn is
still live:

- `ROUNDS` — after each round, re-assign it to the cumulative count of
  `issue-refiner` calls made in this flow, as a bare integer (e.g. `ROUNDS=4`).
  Never spell it `ROUNDS=$((ROUNDS+1))`: the previous value is gone by the next
  tool call, so every round would record `1`.
- `RAISED` — after each round, re-assign it to the count of **distinct
  objections seen so far in this flow**, as a bare integer (e.g. `RAISED=4`);
  never paste a placeholder, which is a shell syntax error and leaves the count
  empty. In an epic walk this is *this child's* objections only, never a running
  total across children. On a run that never entered the loop it is Step 1's
  `refinement_questions` count (`0` only when the verdict raised none).
- `RESOLVED` — after each round, re-assign it to the **cumulative** count of
  objections ever reported `resolved: true`, as a bare integer (e.g.
  `RESOLVED=4`). Cumulative matters: an objection stays counted after it drops
  out of a later round's `objections` input (which carries only the still-open
  ones), so on convergence `RESOLVED == RAISED` by definition — a per-turn
  reading would record a 4-objection convergence as `objections_resolved: 1`.

**A run that made no `issue-refiner` call at all** — Step 1's already-`READY`
shortcut, or a park taken straight off a resumed session — still assigns all
three **explicitly**, per the definitions above: `ROUNDS=0`, `RESOLVED=0`, and
`RAISED` = the objections Step 1 actually raised (`0` on the shortcut, where the
verdict was `READY`; N on a resumed session that re-parked, where N objections
were seen and none resolved — that is the stall signal the stream exists to
capture, and zeroing it would hide it). Those are measured zeros. Never
*default* an unrecorded count to 0: an unset count must reach Step 7 unset so it
skips the record rather than fabricating a no-op.

### Step 2 — the typed parked exit (#578)

Not every session reaches `READY` in one sitting. When the human decides it
**can't converge now**, take a **typed parked exit** — an early exit from this
loop (not the Step 5 post-re-gate path) that captures the state so a later run
resumes (Step 0) instead of losing the conversation. Mirrors resolve-issue's
typed escalation (#564), for the human-present refinement loop. Three types:

- **`needs-decision`** — an absent stakeholder / upstream decision blocks a
  testable spec. The state names the `decision` and its `owner`.
- **`split-recommended`** — the story is really an epic; it can't be one bounded
  spec. The state lists the `candidate_children`.
- **`deferred`** — the human pauses without converging: either from this loop
  (the `conversation` so far is preserved) or from Step 5, after a re-gate the
  story still fails (the block is written, so there is no resume state to keep).

**Check first: did Step 3 already run for THIS issue's flow (Steps 0–7)?** In an
epic walk each child is its own flow, so a *previous child's* Step 3 does not
count. `build-parked-comment.zsh`
states in its comment that "no `story-spec` block was written (the prose isn't
finalized)". That is true of a park taken from **this loop before Step 3** — the
normal case — and **false** after a write-back (you looped back here from Step
5). If Step 3 has already run, do **not** build the comment: take **Step 5's
route** instead (keep the label, post Step 6's trail, emit `parked` /
`deferred`). Otherwise continue here.

Build the parked comment with the script (never hand-roll the marker) and post
it as the human, exactly like every other refine-issue side effect. The state
object carries the type, the still-**`open_questions`**, the `conversation`, and
the type-specific fields. Set Step 7's run variables as you go —
`STATE_OUTCOME="parked"` and `PARK_TYPE` to the type you chose:

```bash
# /tmp/parked-state.json — the structured state (type + open_questions +
# conversation + type-specific decision/owner or candidate_children)
STATE_OUTCOME="parked"
# Write /tmp/parked-state.json FIRST; this only reads it. Deriving the park type
# from the file that already holds it keeps the payload and the posted comment's
# marker from disagreeing — and guard the read, because an unguarded one yields
# a bogus or empty type, which Step 7's enum guard then rejects: the record is
# skipped and a real park goes uncounted.
PARK_TYPE="$(jq -re '.type' /tmp/parked-state.json)" || PARK_TYPE=""
case "$PARK_TYPE" in
  needs-decision|split-recommended|deferred) ;;
  # Re-assign it YOURSELF to the type you chose and told the human — as one of
  # the three literals, e.g. PARK_TYPE=needs-decision. Never paste a
  # placeholder: it is outside the enum, so Step 7's guard skips the record and
  # the run goes uncounted (the builder would pass it through verbatim; the
  # guard is the only thing standing between it and the shared sink).
  # If you genuinely have no type, leave it EMPTY: Step 7 then SKIPS the record,
  # which is the right answer — a `parked` with `park_type: null` is the shape
  # the contract reserves for `refined-ready`, and no consumer could tell them
  # apart. Lossy beats wrong.
  *) echo "park type missing/unknown in /tmp/parked-state.json — set PARK_TYPE to the type you chose (needs-decision|split-recommended|deferred), or leave it empty and the record is skipped"
     PARK_TYPE="" ;;
esac
# Guard the post on the build succeeding — a non-zero build (validation failure)
# must NOT post a blank/markerless comment, which would silently lose the resume.
if "<skill-base-dir>/scripts/build-parked-comment.zsh" \
     --issue <N> --state /tmp/parked-state.json > /tmp/parked-comment.md; then
  # Guard the POST too, not just the build. The run is still RECORDED either
  # way — a failed post and a failed build leave the issue in the same state
  # (no resume comment, label kept), and `outcome: "parked"` makes no
  # resumability promise, so suppressing one and not the other would split the
  # stream on an accident. What matters is that the human is told.
  gh issue comment <N> --body-file /tmp/parked-comment.md \
    || echo "the parked comment did not post — the resume state was NOT saved; retry before ending the session (the run is still recorded as parked)"
else
  echo "parked-comment build failed (see stderr) — not posting; fix the state and retry"
fi
```

**On a build failure, follow this order exactly:**

1. **Set `PARK_TYPE` first, then run Step 7.** The commonest cause of a build
   failure is the very state file the type is read from, so `PARK_TYPE` is
   likely empty — and Step 7 skips a parked record without it. Assign the type
   you chose and told the human (one of the three literals), then emit. A failed
   park still ends a run that spent rounds and objections, and it is the ending
   an author most wants counted. Emit the record **once**. Do not `exit` out of
   the shell first: that
   would discard Step 0's `T0`/`REPO_ROOT` stamps, and Step 7's guard would then
   correctly refuse to fabricate a `wall_s` — losing the very record this rule
   exists to keep.
2. **You may fix the state and re-run the build in-session.** If it then
   succeeds, post the comment. If step 1 actually **emitted** a record, emit no
   second one — "exactly one record per run" still holds. If step 1 **skipped**
   it (its advisory names which value was missing), re-state **every** required
   value and run Step 7 once more; if it skips again the run is genuinely
   unmeasured — say so and move on. Either way the run ends with at most one
   record.
3. **Then end this issue's flow**, whether or not the retry succeeded. In an
   epic walk that ends the **child**, not the walk: record it as
   `parked (comment build failed)` and continue to the next child.

A parked exit is deliberately **distinct from the Step 3 write-back and the
Step 5/6 path**:

- it **skips Step 3 entirely** — **no `story-spec` block is stamped** (the prose
  isn't finalized, so provenance never records an unfinished spec);
- it **keeps the `needs-refinement` label** (the story still isn't ready) — do
  **not** remove it;
- the comment it posts carries the machine-findable `<!-- refine-parked: <TYPE>
  -->` marker + hidden resume state, which Step 0 of the next run reads back.

Then **emit telemetry** (Step 7, `outcome: "parked"` with the `park_type`) and
**stop** — tell the human the session is parked and how to resume
(`/development:refine-issue <N>`). Do not run Steps 3–6 on a parked exit.

> **Missing-persona routing (#668).** When the refiner flags that the story needs
> a persona the target repo's `personas/v1` registry lacks or fits poorly
> (typically in its `recommendations`), relay it and **route the human to
> `/development:define-personas`** to add or adjust the persona — you never invoke
> that skill automatically. Personas are **advisory**: the human may run it and
> come back with a real persona id, or proceed without one. Never block on it,
> and never let the refiner invent a persona id the registry doesn't contain.
>
> The agent is a **pure function** — it never touches GitHub. Do not ask it to
> post or edit; that is Step 3, and it is yours.

## Step 2.5 — spin out the test cases (hybrid model, #671)

Once the human approves the rewrite, and **before** you write the block back
(Step 3), reconcile the approved `proposed_story_spec`'s `test_cases[]` into
linked **`test-case` issues** — the hybrid model (#671): the cases live *both*
structured in the block (the gate-validatable source of truth) *and* as separate
backlog-visible issues, while staying implemented in the **same PR** as the story
(#577/#696), so tests and feature never drift.

A **surface-touching** story has outside-in `test_cases[]`; a **no-surface**
story has `test_cases: []` and this step creates nothing (proportionality). Drive
the reconcile primitive — never hand-roll the `gh issue create`/`close` calls:

```bash
# The NEW approved spec (from proposed_story_spec) and, if the issue already
# carried a story-spec block, the OLD one (for reuse + orphan detection):
"<skill-base-dir>/scripts/test-case-spinout.zsh" \
  --repo "$REPO" --story <N> \
  --spec <approved-spec.json> [--old-spec <current-block.json>]
```

It is **idempotent, keyed on `test_cases[].id`**: a new case is created, a case
whose id already links to an issue is edited in place, and a case dropped since
the last round has its orphaned `test-case` issue **closed with a comment**. It
prints the **reconciled `test_cases` array** (each entry's `issue` now populated)
to stdout — splice that back into `proposed_story_spec.test_cases` so the block
you write in Step 3 carries the issue links. (The `id` is the stable key across
rounds; keep it stable so reconciliation reuses rather than re-creates.)

There is deliberately **no `blockedBy`** between the story and its test-case
issues — same-PR closure (`resolve-issue`, #577/#696) makes ordering moot.

## Step 3 — write back the approved rewrite (human-authored)

This edit is **human-approved and human-authored** — you run it with the
session's own `gh` auth (the human's identity), **not** a bot token and **not** a
PR. You are editing the issue in place.

Assemble the new body from the approved prose and `proposed_story_spec` — with
its `test_cases[]` replaced by the **reconciled array from Step 2.5** (issue links
now filled in), so the block you write records which `test-case` issue each case
spun out to:

1. **Wrap the approved prose in the provenance sentinels** and drop any prior
   story-spec block (replace, never duplicate):

   ```text
   <!-- story-spec:prose:start -->
   … the human-approved prose …
   <!-- story-spec:prose:end -->
   ```

2. **Stamp provenance.** Write the prose region (the bytes *between* the
   sentinels, sentinel lines excluded) to a temp file and compute the canonical
   hash — the same primitive the gate recomputes with, so staleness stays
   detectable:

   ```bash
   PROSE_HASH=$("<skill-base-dir>/scripts/story-spec-prose-hash.zsh" --file <prose.txt>)
   ```

   Set the block's `provenance`: `generated_by` (e.g.
   `"issue-refiner via /development:refine-issue"`), `generated_at` (an ISO-8601
   UTC timestamp), and `prose_sha256` = `$PROSE_HASH`. The agent left these
   `null` on purpose — **you** finalize the hash over the *approved* prose,
   because the approved prose (not the agent's draft) is authoritative.

3. **Render the block** below the sentinel-wrapped prose, per the ARCHITECTURE.md
   *Story-spec contract*:

   ```text
   <details>
   <summary>🤖 machine-readable story spec (story-spec/v1) — generated, do not hand-edit</summary>

   <!-- a fenced ```json block holding proposed_story_spec, provenance now filled in -->

   </details>
   ```

4. **Write it** — the full body is sentinel-wrapped prose, a blank line, then the
   `<details>` block:

   ```bash
   gh issue edit <N> --body-file <new-body.md>
   ```

Confirm the block is valid JSON (`jq -e` the fenced object) before writing.

## Step 4 — re-gate

Spawn **`story-readiness`** again on the freshly-edited issue. Its verdict is now
authoritative — and, because a `story-spec` block now exists, its validation also
checks the block against the prose (it will pass: you just stamped the hash over
this exact prose).

**Relay the verdict's `advisories` to the human (#668).** The re-gate may return
non-blocking `advisories` — e.g. a `story-spec` `personas` reference to a persona
id that isn't in the target repo's `personas/v1` registry, or a stale registry.
These **never** block (the story can still be `READY`), but the human should see
them: surface each advisory's `message`, and when it names a missing/ill-fitting
persona, route the human to **`/development:define-personas`** (as in Step 2) so
they can add or fix it and, optionally, re-run refine-issue to reference it.

## Step 5 — resolve the label, honestly

- **`READY`** → remove the label; the story is buildable. Step 7 defines
  `refined-ready` as "the run ends with `needs-refinement` **removed**", so set
  the outcome **only if the removal actually succeeded** — otherwise the record
  would claim `success` for a story still carrying the label. Clearing
  `PARK_TYPE` matters too, when an earlier loop began a park that was then
  abandoned, or the record would claim `success` with a park type attached:

  ```bash
  # The retry is INSIDE the condition: a second attempt that succeeds is an
  # ordinary READY ending and must still set the outcome, or Step 7 would skip
  # the record for a run that genuinely reached refined-ready.
  #
  # The final arm checks STATE rather than the command's status, which settles
  # two cases the status alone cannot: a story that never carried the label
  # (Step 0 allows refining an ungated one), and a first attempt that succeeded
  # server-side but lost its response. In both the label is already absent, so
  # the run really did reach refined-ready.
  if gh issue edit <N> --remove-label needs-refinement \
     || { sleep 2; gh issue edit <N> --remove-label needs-refinement; }; then
    STATE_OUTCOME="refined-ready"; PARK_TYPE=""
  elif LABELS_NOW="$(gh issue view <N> --json labels -q '.labels[].name')" \
       && ! printf '%s\n' "$LABELS_NOW" | grep -qx needs-refinement; then
    # Both edits failed, but the label is VERIFIABLY absent — the story was
    # never gated, or the first edit landed and only its response was lost.
    # The assignment is separate from the grep on purpose: `! gh … | grep`
    # would negate grep's status alone, so a FAILED read (the same outage that
    # just failed both edits) would print nothing, grep would exit 1, and the
    # run would record `success` for a story that still carries the label.
    # An unreadable label state is never evidence of absence.
    STATE_OUTCOME="refined-ready"; PARK_TYPE=""
  else
    # Never carry a value from an abandoned earlier loop into this ending.
    STATE_OUTCOME=""; PARK_TYPE=""
    echo "label removal failed, and its state is still set or unverifiable — see below"
  fi
  ```

  **If both attempts fail and the label is still there:** tell the human it could
  not be removed, do
  **not** post Step 6's trail as though it had been, and end this issue's flow.
  `STATE_OUTCOME` stays empty, so Step 7 skips the record — the run reached no
  decided ending, and a `success` here would be a lie. (In an epic walk that
  ends **this child**: note it in the epic summary as *label-removal failed* and
  continue to the next child.)

- **`NEEDS_REFINEMENT`** → **keep the label** and report the remaining reasons to
  the human. Do not remove it on a story the gate still rejects — the label is
  the honest signal. Offer another loop (back to Step 2) or to stop here.

  **If they stop here, it is a recorded ending, but NOT Step 2's parked exit.**
  Do **not** run `build-parked-comment.zsh` here: its comment states outright
  that "no `story-spec` block was written (the prose isn't finalized)", which is
  **false** on this path — Step 3 already wrote the approved prose and stamped
  the block. Posting it would contradict the issue's own edit history and seed
  the next run with a wrong resume state. Instead:

  - keep the `needs-refinement` label (that *is* the resume signal — the next
    run's Step 0 reads it, and Step 1 re-diagnoses from the current body);
  - **still post Step 6's before/after trail** — Steps 3–4 really ran, so the
    issue must record what changed, what the re-gate said, and that the label
    stays. (Step 2's "do not run Steps 3–6" applies to a parked exit taken
    **from the Step 2 loop**, where Step 3 never ran at all.)
  - then set `STATE_OUTCOME="parked"; PARK_TYPE="deferred"`, emit Step 7, and
    stop.

  Never emit `refined-ready` for a story the gate still rejects.

## Step 6 — the before/after comment trail

Post one durable comment recording **what changed and why**, so the issue is a
self-contained record: the objections you started from, a short before/after of
the prose (or a note that the full diff is in the edit history), the re-gate
verdict, and the resulting label state. This is the audit trail a later reader —
or `resolve-issue` — relies on.

## Step 7 — emit telemetry (every decided ending, #579)

Every refine-issue run — whether it reached `refined-ready` (Steps 3–6, or Step
1's already-`READY` shortcut) **or** took a typed parked exit (Step 2's, or Step
5's `deferred` park) — appends **one** `telemetry/v1` record so the
plugin self-improvement handoff can learn where refinement helps and where it
stalls. The **envelope and the sink belong to the shared emitter**
(`development/scripts/telemetry/emit-telemetry.zsh`, #740 child (a)) — never
hand-roll one here; this stream supplies only its own `payload` plus the
envelope's linkage fields, exactly as the review loop does since #1004. What
carries over unchanged from the pre-contract shape is the rule that a
**telemetry failure must never break the run** — here spelled
`{ … } || echo <advisory>`, so the loss is said once in-session and the run is
unaffected.

Build the payload from the run's summary and hand it to the emitter, which
derives `repo`, mints the `run_id`, and appends to the shared git-ignored sink
`.claude/telemetry/telemetry.jsonl`:

**Build the state with `jq`, never a hand-quoted heredoc**, and pass every field
as a **plain string** (`--arg`) so `jq` owns the encoding. A hand-quoted state is
not a small error: one unquoted value makes it invalid JSON, the builder exits 1,
and the `||` branch reduces the whole lost record to a single advisory line.

**The six run variables come from the steps that decided them** — Step 0
initializes them all to empty, and Step 1/2/5 assign the real values as they go
(each names its own). Never let Step 7 invent one: an unset count would record a
4-round convergence as `rounds: 0`, indistinguishable from Step 1's shortcut,
which is the same fabrication the `T0` guard exists to refuse.

So the guard below covers the four run variables that **must be present** —
`STATE_OUTCOME` and the three counts — on top of Step 0's `T0`/`REPO_ROOT`
stamps, which it checks first, and skips the record rather than emit a guess. It
deliberately does **not** cover `RISK`, and covers `PARK_TYPE` only
**conditionally**: both are nullable by contract (`park_type` is `null` on every
`refined-ready` run, and `risk_classification` is `null` when Step 1 produced no
verdict), and the `jq` below null-ifies an empty one — so guarding them
unconditionally would suppress the record on every successful refinement. The
one exception is a `parked` run whose `PARK_TYPE` is **empty or outside the
three-value enum**, which the guard *does* reject: an empty one is the
`refined-ready` shape wearing a `parked` label, which no consumer could tell
from a well-formed park whose type was lost, and an out-of-enum one is a
fabricated value the payload builder deliberately does not police.

**Re-assign all eight before running this block.** `T0`, `REPO_ROOT`,
`STATE_OUTCOME`, `PARK_TYPE`, `RISK`, `ROUNDS`, `RAISED`, `RESOLVED` must all be
re-stated as literals **in the same Bash invocation as the fence**, on the lines
above the guard (Step 2's rule). Values assigned in an earlier tool call are
gone, and the guard would then skip the record for a run that was measured
perfectly well. This holds on **every** path here — including Step 1's
already-`READY` shortcut, which never enters Step 2 and so never reads that rule.

```bash
# Step 0 stamped T0/REPO_ROOT and Steps 1/2/5 DECIDED the run variables —
# re-state every one of their literals above this guard (see the note above).
# T0, REPO_ROOT, STATE_OUTCOME and the three counts are REQUIRED — wall_s and the
# counts must be MEASURED, so a missing one means skip the record. (An unset T0
# would read as 0 in arithmetic and turn into a ~56-year run; a count DEFAULTED
# to 0 because it was never measured would validate and read as Step 1's no-op
# shortcut.) RISK is nullable by contract and is NEVER
# guarded; PARK_TYPE is guarded ONLY in the `parked` pairing below — see the
# paragraph above.
# Hoist both patterns: an UNQUOTED `(a|b)` / `{n,m}` on a `=~` right-hand side is
# a bash-only spelling — zsh treats those characters as shell-special on a
# different path — and this fence runs under whichever shell the session uses. A
# pattern that silently never matches would negate to true and skip EVERY parked
# run's record. A variable is the one form both shells agree on.
T0_RE='^[0-9]{1,18}$'
PARK_RE='^(needs-decision|split-recommended|deferred)$'
if [[ ! "${T0:-}" =~ $T0_RE || -z "${REPO_ROOT:-}" || ! -d "${REPO_ROOT:-/nonexistent}" \
   || -z "${STATE_OUTCOME:-}" || ! "${ROUNDS:-}" =~ ^[0-9]+$ \
   || ! "${RAISED:-}" =~ ^[0-9]+$ || ! "${RESOLVED:-}" =~ ^[0-9]+$ \
   || ( "${STATE_OUTCOME:-}" == "parked" && ! "${PARK_TYPE:-}" =~ $PARK_RE ) ]]; then
  echo "telemetry not recorded for this run (a Step 0 stamp, the run outcome, a run count, or a park's type is missing) — the run itself is unaffected"
else
  # 10# so a leading-zero stamp can't be read as a bad octal literal, matching
  # the emitter's own normalization.
  WALL_S=$(( $(date +%s) - 10#$T0 ))
  (( WALL_S >= 0 )) || WALL_S=0     # a backwards clock (NTP) would be rejected

  # Allocate independently, so a partial success is still cleaned up.
  STATE=$(mktemp) || STATE=""
  PAYLOAD=$(mktemp) || PAYLOAD=""
  if [[ -z "$STATE" || -z "$PAYLOAD" ]]; then
    rm -f "$STATE" "$PAYLOAD" 2>/dev/null
    echo "telemetry not recorded for this run (no temp file) — the run itself is unaffected"
  else
    BUILDER="<skill-base-dir>/scripts/build-refine-telemetry-record.zsh"
    {
      # PARK_TYPE / RISK are PLAIN strings ("deferred", "normal") — empty means
      # absent. jq encodes and null-ifies them, so there is no JSON literal for
      # a caller to mis-quote.
      jq -n --arg rounds "$ROUNDS" --arg raised "$RAISED" --arg resolved "$RESOLVED" \
            --arg outcome "$STATE_OUTCOME" \
            --arg park_type "${PARK_TYPE:-}" --arg risk "${RISK:-}" \
        '{rounds: ($rounds|tonumber),
          objections_raised: ($raised|tonumber),
          objections_resolved: ($resolved|tonumber),
          outcome: $outcome,
          park_type: (if $park_type == "" then null else $park_type end),
          risk_classification: (if $risk == "" then null else $risk end)}' > "$STATE" \
        && OUTCOME="$("$BUILDER" --state "$STATE" --print-outcome)" \
        && "$BUILDER" --state "$STATE" > "$PAYLOAD" \
        && "<skill-base-dir>/../../scripts/telemetry/emit-telemetry.zsh" \
             --pipeline refine-issue --kind run --outcome "$OUTCOME" \
             --repo-dir "$REPO_ROOT" --ts "$T0" --issue <N> --wall-s "$WALL_S" \
             --payload "$PAYLOAD" >/dev/null
    } || echo "telemetry not recorded for this run (see stderr) — the run itself is unaffected"
    rm -f "$STATE" "$PAYLOAD"
  fi
fi
```

- `REPO_ROOT` and `T0` are **Step 0's** stamps. `--repo-dir` needs the repo
  **directory** — never pass `$REPO`, which is the `owner/name` identity the
  emitter takes on its separate `--repo` flag; the emitter rejects a
  non-directory, and the `|| echo` advisory would reduce that to one line.
- **The state's `outcome` has exactly two values, and every ending maps to one:**
  - `refined-ready` — the run ends with `needs-refinement` **removed**, whether
    via Step 4's re-gate + Step 5's clear or Step 1's already-`READY` shortcut;
  - `parked` — a typed parked exit was taken: Step 2's, or Step 5's `deferred`
    stop on a still-rejected story.

  **Anything else emits no record at all.** Two shapes: (a) it was **not a
  run** — a non-`OPEN` issue, a declined `needs-refinement` precondition, or a
  declined shortcut clear **that ends the session at Step 1** (a decline that
  continues into Step 2 *is* a run); (b) it was a run that reached **no decided
  outcome** — Step 5's twice-failed label removal, or a run whose stamps, counts
  or park type were never measured. Both are a **skipped** record, not a third
  `outcome` value: never coerce them to `parked`.

  The two have different reasons, and conflating them is how the guard gets
  weakened: **(a)** ends before any refinement happens, so there is nothing to
  measure and recording it would inflate the denominator; **(b)** may have
  refined a great deal, and the record is skipped anyway — a fabricated outcome,
  count or park type is worse than a missing one. Lossy beats wrong. The builder
  hard-rejects any third value rather than guessing, so never invent one.

  `--print-outcome` narrows the state value onto the contract's 4-value envelope
  enum (`refined-ready` → `success`, `parked` → `parked`) — never map it by
  hand. Nothing is lost: `park_type` rides in the `payload`.
- `objections_resolved` comes from the Step 2 loop's `resolved_objections`
  tally; `objections_raised` from the distinct objections seen across the flow
  (Step 2's rule — not the size of any one round's array); `rounds` is the loop's round count (`0` on the
  Step 1 already-`READY` shortcut); `risk_classification` is the **Step 1
  diagnosis verdict's `risk`** — `low` | `normal` | `elevated`, or `null` only
  when Step 1 produced no verdict. Step 4's re-gate `risk` is never substituted:
  the metric asks how risky the story was *when the gate sent it back*. All five
  bespoke fields live in the `payload`.
- `repo_type` is deliberately **`null`** on this stream: refine-issue never
  detects a stack, and a guessed one would be worse than an absent one.
- Emit **exactly one record per run**, where a "run" is **one single-issue
  flow** (Steps 0–7). In the **epic walk** that means one record per child,
  each with its own `--issue <child>` and its own Step 0 stamps — not one per
  invocation. The walk emits **no** parent record and children carry
  `parent_run_id: null`; the epic's own summary comment is what groups them.
- **If the emission fails, say so once in-session** and move on. It must never
  fail the run, and never retry it.
- Records written **before** this retrofit stay in
  `.claude/telemetry/refine-issue.jsonl` in the pre-contract (v0) shape — they
  are **not** migrated; child (e)'s rollup reads both.

## Guardrails

- **The intelligence is the agent; you are the conductor.** Never invent the
  refinement judgment yourself — spawn `issue-refiner`. Never let the agent
  write to GitHub — every side effect (edit, label, comment) is yours.
- **Human-approved, human-authored write-back.** No bot token, no PR: you edit
  the issue with the human's auth, and only after they approve the exact rewrite.
- **The label tells the truth.** Remove `needs-refinement` **only** on a `READY`
  re-gate; otherwise it stays.
- **One canonical hash.** Compute `prose_sha256` with
  `scripts/story-spec-prose-hash.zsh` — never hand-roll it, or the gate's
  staleness check will disagree with what you wrote.
- **No `dependencies` in the block** — dependencies are GitHub-native `blockedBy`
  (#583), never in `story-spec`.
- **Spin out test cases with the script, not by hand (#671).** Step 2.5 runs
  `scripts/test-case-spinout.zsh` to create/reconcile/close the linked
  `test-case` issues; splice its reconciled `test_cases[]` (with issue links)
  into the block before write-back. Never open or close a `test-case` issue with
  a raw `gh` call — the script keeps the reconcile idempotent and orphan-closing
  consistent. Keep each case's `id` stable so re-runs reuse rather than duplicate.
- **A parked exit taken BEFORE Step 3 skips write-back and keeps the label
  (#578).** When a session can't converge in the loop, take the typed parked exit
  (Step 2): build the comment with `scripts/build-parked-comment.zsh` (never
  hand-roll the `refine-parked` marker), post it, **keep** `needs-refinement`,
  stamp **no** `story-spec` block, and stop. A later run's Step 0 resumes from it
  via `scripts/read-parked-state.zsh`. A park taken **after** Step 3 — Step 5's
  `deferred` stop, or a loop-back that re-parks — is different: the block **is**
  written, so it never runs `build-parked-comment.zsh` (whose comment would claim
  otherwise); it keeps the label, posts Step 6's trail, and emits Step 7.
- **Epic → walk the children (#580)** — pointed at an epic, enumerate its
  `needs-refinement` children with `scripts/list-refinement-children.zsh` and run
  each through the single-issue flow, then post an epic-level summary. Never
  refine the epic issue itself; a parked child doesn't halt the walk.
