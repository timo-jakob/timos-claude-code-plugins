---
name: refine-issue
description: >
  Take a GitHub issue the readiness gate sent back (`needs-refinement`) and drive
  it interactively to READY — the guided path from "no" back to "ready". A human
  is present throughout: you diagnose the story with `story-readiness`, then loop
  the `issue-refiner` agent (per-turn: explanation, questions, recommendations, a
  draft rewrite, a proposed `story-spec/v1` block) relaying between it and the
  human until they approve a rewrite, or with no approval prompt when every
  question was answered automatically and no size check or split intervened
  (all-auto, #2938). Then you write back the approved prose
  plus a provenance-stamped `story-spec` block (a human-authored issue edit, NOT a
  bot PR), re-gate, remove the `needs-refinement` label only if READY, and post a
  before/after comment trail. When a session can't converge, take a typed parked
  exit (needs-decision / split-recommended / deferred) that a later run resumes
  from (#578). Pointed at an epic, it drafts each needs-refinement child through
  that single-issue flow, asks one approval for the batch of drafts (#2904), and
  posts an epic-level summary (#580). With --follow-up
  it refines a pipeline-filed follow-up unattended, from its source story (#2588).
  With --chained-from it runs as a step of a resolve-issue run: it asks no one,
  returns one outcome document, and its caller relays its questions (#2939). A
  size-check split that names its children is filed without asking.
  The intelligence lives in the agent, this skill is the conductor. Composes story-readiness (#559) and
  issue-refiner (#575); consumes the story-spec/v1 contract (#574).
disable-model-invocation: false
---

You are the **conductor** of an interactive refinement session. A story failed
the `story-readiness` gate and carries `needs-refinement`; a human wants to fix
it. The **intelligence is in the `issue-refiner` agent** (#575) — a per-turn pure
function; **you** relay between it and the human, and **you** own every GitHub
write. The payoff of doing this well: the story reaches the implementer precisely
specified, and a durable machine-readable `story-spec/v1` block rides along.

**User input:** an issue number or URL, optionally with `--auto-accept <t>`,
`--follow-up` (*Unattended follow-up mode*, below) or `--chained-from <root>
--handoff <file>` (*Chained refinement mode*, below). Operate on the session's repo
(`gh repo view --json nameWithOwner`); the issue must belong to it. If empty, print
`/development:refine-issue <issue-number|url> [--auto-accept <0..1>] [--follow-up | --chained-from <root> --handoff <file>]`
and stop.

**Resolve the auto-accept threshold once, before anything else.** The run
applies it in Step 2. Resolve it once per invocation, not once per epic child:

```bash
"<skill-base-dir>/scripts/auto-accept-threshold.zsh" [--flag <t>]   # --flag only when --auto-accept was given
```

It prints `<milli> <source>`. The value comes from the flag, else
`refine_auto_accept_threshold` in the settings `env` block, else `1`. **Exit 2**
means the `--auto-accept` value is malformed: tell the human the accepted form
(a decimal from 0 to 1, at most three decimals) and stop. On `env-ignored`,
relay the script's stderr line. Tell the human the threshold and its source in
one line, e.g. "auto-accept: 0.9 (from settings)". Carry `<milli>` in your notes
for Step 2, and `<source>` for Step 6's trail of an all-auto refinement.

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

2. **Walk the children in two phases (#2904)** — draft every child first, then
   ask **one** approval for the batch. The walk reuses the **single-issue flow**
   (Steps 0–7) as written, Step 1's stamp reuse and Step 4's stamp included
   (#2956), except that the approval of the exact rewrite moves
   out of each child's Step 2 into the batch. A parked child does not halt the
   walk — record it and continue to the next. An all-auto child (*Step 2 — the
   all-auto check*, #2938) needs no approval, so it never enters a batch: it is
   written back in phase A, and only the others are batched.

   **Per-child state.** At walk start, remove `/tmp/refine-issue-epic-<E>/` (as
   Step 0 clears `/tmp/parked-state.json`) and recreate it empty. Each child
   keeps one state file there, `/tmp/refine-issue-epic-<E>/<N>.json`, which you
   rewrite with `jq` after every round. It holds the child's Step 7 run
   variables (`t0`, `repo_root`, `rounds`, `raised`, `resolved`, `risk`,
   `size_preflight`, `state_outcome`, `park_type`, `paused_s`), its
   `conversation`, its `auto_accepted` answers (each `{question, answer,
   confidence, weakest}`), its `proposed_prose` and `proposed_story_spec`, the
   issue's current block as `old_block` (`null` when it has none), its
   `expected_docs_pages`, `rewrite_path` (a file holding its full rewrite),
   `waiting_since` and its `phase`: `pending` while its draft awaits a batch,
   and set to its outcome (`approved`, `skipped` or `drafting`) as soon as
   `partition` places it, so no child is in two batches. Its `phase` is always
   a string, from the moment its state file is created: `drafting` while it
   drafts or must redraft (a child created in phase A, a revisit, and an
   approved child whose re-gate loops it back), `pending` as above, `skipped`
   once skipped, and `ended` at every other ending, in phase A or phase B
   alike: the READY shortcut, a write-back, a typed park, a filed split, or a
   stop such as a failed label removal. So a walk is finished exactly when no
   child is `drafting`, `pending` or `approved`. Its `paused_s`
   (Step 0's `0`) holds its waits on others, which are not refinement work and
   never count toward its `wall_s`: whenever its work stops to wait — it becomes
   pending, or it loops back (it redrafts only in the next phase A) — set
   `waiting_since` to `$(date +%s)`; whenever its own work resumes (its Steps
   2.5 to 7, or its redraft), first write the wait into its state file `f`
   (`/tmp/refine-issue-epic-<E>/<N>.json`) with:

   ```bash
   jq --argjson now "$(date +%s)" '.paused_s += ($now - .waiting_since) | .waiting_since = null' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
   ```

   Every step that assigns one of those run variables — Step 0's `t0`,
   `repo_root` and `paused_s`, Step 1's verdict and its already-`READY`
   shortcut, Step 2's typed park or filed split, Step 4's re-gate and Step 5's
   ending, in phase A or phase B alike — also writes it into that state file in
   the same invocation, so Step 7 finds every ending's values there. Step 7
   re-states the child's literals from that file in the same invocation as the
   fence.

   **Phase A — draft each child, in sub-issue order.** Run Steps 0, 1 and 2 as
   written: the refiner's questions, the size check and its split, filed
   without asking (#2939), and the typed parked exit. A child that ends in phase A finishes
   there, Step 7 included, and never enters a batch: the READY shortcut (cleared
   through Step 5's `READY` branch), a typed park, a filed split, and an
   all-auto write-back. A child whose draft converges and passes the size check
   is **not** presented for approval. Run the all-auto check on its own rounds
   and sizings first. When it reports `all-auto`, add its Decisions taken
   section and run its Steps 2.5, 3, 4, 5, 6 and 7 at once, in this phase A, as
   Step 2 says for an all-auto refinement: its `phase` becomes `ended`, or
   `drafting` when its re-gate loops it back, and then it redrafts at once,
   still in this phase A, with no wait recorded. Once the all-auto loop's bound
   (Step 2) is reached, its next draft is pending like any other. Any other
   reason: add its Decisions taken section to the draft as Step 2 says, re-read
   the issue's current block into `old_block`, write its rewrite to
   `rewrite_path`, set `phase` to `pending`, and go on to the next child.

   **Phase B — one approval for the batch.** Once every child of this pass has
   ended or is pending, render the batch. When no child is pending — every one
   ended in phase A — skip phase B, ask nothing, and go to step 3's epic-level
   summary. An all-auto write-back is one such ending. Otherwise render it:

   ```bash
   "<skill-base-dir>/scripts/batch-approval.zsh" summary --dir /tmp/refine-issue-epic-<E>
   ```

   It prints one entry per pending child: the intent changes (the draft's
   `acceptance_criteria` and `scope_boundaries.in`/`out` diffed against the
   current block), the test cases and the ids Step 2.5 will create, edit or
   close, the side effects, the **Answers taken automatically**, the expected
   docs pages and the path of the full rewrite. It names no `blockedBy` edge,
   because refine-issue creates none. Exit 1 is a malformed state file: fix it
   with `jq` and re-run. Exit 2 is your own malformed call: fix it and re-run.
   Show it, then ask once (`AskUserQuestion`): **Approve all**, or name the
   children to **revisit** (with their reply), to **skip**, or whose
   auto-accepted answer they **overturn**. An overturned answer makes its child
   a revisit, with the overturn as its `human_reply`. Split the answer with:

   ```bash
   "<skill-base-dir>/scripts/batch-approval.zsh" partition --dir /tmp/refine-issue-epic-<E> \
     [--revisit "<n …>"] [--skip "<n …>"]
   ```

   It prints `{approve, revisit, skip}`. Exit 2 means a number that is not a
   pending child, or one named in both lists: ask again with the pending
   numbers. An exit 2 your own call caused (a missing `--dir`, an unknown flag)
   is fixed and re-run without asking. Exit 1 is a malformed state file: fix it
   with `jq` and re-run.

   - **approve** — one child at a time, in sub-issue order, run Steps 2.5, 3,
     4, 5, 6 and 7 for it. Its batch approval is the approval of its exact
     rewrite. Steps 4 and 5 write what they decide into its state file `f`
     with `jq … "$f" > "$f.tmp" && mv "$f.tmp" "$f"` before Step 7 reads it:
     Step 4 the re-gate's `size_preflight`, Step 5 `state_outcome` and
     `park_type`. `risk` stays Step 1's, already there from phase A.
   - **skip** — the child ends as *skipped (human declined)*: nothing is
     written, its label stays, and Step 7 emits no record, since it reached no
     decided outcome. A looped-back child already written back takes Step 5's
     stop instead.
   - **revisit** — the child re-enters Step 2 with the human's reply as
     `human_reply`, and its `phase` goes back to drafting.

   **The batch loop-back rule.** A child whose re-gate is still
   `NEEDS_REFINEMENT` loops back to Step 2 (Step 5) like a revisit child, and
   its `phase` goes back to `drafting`. The
   loop-back children and the revisit children redraft, and once each has a new
   sized draft, pending as in phase A (or has parked), they form the **next
   batch**, which gets one approval again. Batches repeat until every child has
   ended — written back, skipped or parked — so none is pending or waiting to
   redraft: a revisit child (`drafting`) or a looped-back child keeps the walk
   going, and the next phase A redrafts it. A redraft re-enters at Step 2 and
   keeps its state file: it never re-runs Step 0 or Step 1, so its `t0`,
   `rounds`, `raised` and `resolved` carry on across batches.

3. **Post an epic-level summary** on the epic issue: for each child, whether it is
   now **ready** (label cleared) or **still parked** (with the park type), plus
   any that had no work to do, plus any the human skipped in a batch
   (*skipped (human declined)*), plus any `skipped_self_ref` line a backfill
   reported (named as a self-reference that was not migrated — necessarily a
   **tracker** line, since a mistyped child ref halts the walk at step 1)
   — and, separately, any that ended in a **failure**
   state: *label-removal failed*, *parked (comment
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

## Unattended follow-up mode (`--follow-up`, #2588)

`--follow-up` refines a **pipeline-filed follow-up**, one carrying a
`follow-up-origin/v1` record (#2581), with no human in the loop.
`/development:resolve-issue` invokes it before its §7 record, and #2578 for each
split child it files. Every decision is `scripts/follow-up-auto-refine.zsh`'s;
you relay, and you own every write. Resolve the threshold as above.

**Only a trusted author's comment counts (#2645).** An origin record or a
refine-auto marker counts only in a comment whose `authorAssociation` is
`OWNER`, `MEMBER` or `COLLABORATOR`, or that the repository owner's Maintenance
App wrote as `claude-maintenance-<owner>[bot]`, on the follow-up and on the
source alike; the script ignores every other comment. The bare login `gh issue
view` prints for an App is not trusted, since a user account can hold it; the
pipeline posts these comments with a collaborator's `gh` login. So always pass
`gh issue view --json` output, whose comments carry `authorAssociation`: a
comment without it is exit 2. When
`eligible` reports a non-zero `ignored_untrusted`, name that count in your
report.

**Steps 0 and 1 run as written, with no prompt:** Step 0 first, Step 1 after the
seed (2. below). On Step 1's already-`READY` shortcut, post the note with
`--decision ready` after zero rounds, with no answers; otherwise its
`refinement_questions` are the objections for the rounds. **Every human prompt
has a fixed unattended answer:**

- Step 0's precondition — a follow-up without `needs-refinement` is not
  refined: stop, writing nothing;
- Step 1's shortcut confirmation — clear the label;
- Step 2's relay and its answers — `decide`;
- Step 2's approval — `accept`;
- Step 2's size check stopping, or a non-null `proposed_split` — park
  `deferred`, never split;
- Step 5's failed label removal — report it.

Step 2.5 has no prompt: on `accept` it runs as written, before Step 3. **An exit
2** from `follow-up-auto-refine.zsh` or `follow-up-origin.zsh` is your own
malformed input: fix it and re-run once. A second exit 2 stops the mode for
that follow-up: report it and write nothing, so the label stays. An exit 2 from
`split-refiner-questions.zsh` is the refiner's malformed turn, a broken
`kind: gap` `proposed_doc_change` (#2901) included: re-spawn the refiner for
that round once; a second one stops the mode the same way.

1. **Eligibility.** Write `gh issue view <N> --json comments` to a file and read
   the source with `follow-up-auto-refine.zsh origin --comments <file>`; exit 1
   means no record, refused as `no-origin-record` below. Write `gh issue view
   <source> --json number,title,body,comments` to a second file and run
   `eligible --comments <file> --source <file>`. Exit 1 prints the refusal: `no-origin-record`,
   `already-attempted` or `second-generation`. Report it and stop, writing
   nothing; the follow-up stays `needs-refinement` for a human.
   **Auto-refinement never splits**, and it never walks an epic.
2. **Seed.** `seed --comments <file> --source <file>` prints the seed. Pass it
   as the `seed` field of every `issue-refiner` call (Step 2), with
   `human_reply` empty on the first round.
3. **Rounds.** Split each turn with `split-refiner-questions.zsh` (Step 2), then
   run `decide --split <split.json> --turn <turn.json> --round <R>`. It accepts
   only a converged turn with a non-empty `resolved_objections`, a non-blank
   `proposed_prose` and a `proposed_story_spec` object; a converged turn without
   a draft is `continue` below the cap and `park deferred` at it:
   - `continue` — call the refiner again with the `auto` answers as
     `human_reply`, as Step 2 does when every question is `auto`;
   - `accept` — size the draft (*Step 2 — size the draft before approval*); a
     draft that stops is parked `deferred`, never split. Otherwise add the
     **Decisions taken** section (Step 2) and write it back as Steps 2.5 and 3 do, with `provenance.generated_by` set to
     `issue-refiner via /development:refine-issue --follow-up (unattended)`. Then Step 4 and
     Step 5: `READY` removes `needs-refinement`; anything else keeps it and
     posts the gate's questions, Step 5's deferred route;
   - `park` — take Step 2's typed parked exit with that `park_type`: the resume
     comment carries the seeded conversation, the label stays and no block is
     written, so a human's `/development:refine-issue <N>` resumes from it. For
     `needs-decision` its state's `open_questions` is the `ask` questions'
     text, `decision` the first of them and `owner` "the maintainer — the
     unattended mode asked no one". For
     `deferred`, `open_questions` is the unresolved objections' `objection`
     text plus any remaining questions, never empty: else "no convergence
     within the round cap". A size-check park names its own reason instead:
     "the draft's declared inventory stops the size check", with the triggers.

   Keep every `auto` answer of every round in one list for the note.
4. **Note.** Post `note --seed <seed> --answers <answers> --threshold-milli
   <milli> --decision <accept|ready|park-needs-decision|park-deferred>` as one
   comment on the follow-up, whatever the outcome: `accept` on accept, `ready`
   on Step 1's shortcut, else `park-needs-decision` or `park-deferred` by the
   park's type. Its marker is
   what makes a second run refuse `already-attempted`.
5. **Telemetry.** Step 7 emits one ordinary record, with `auto_refinement` — the
   same call with `--format json` — added to its state.

**This mode's `accept` stands in for the human's approval, here and nowhere
else.** **A park never stops the caller**: report it and return, so the calling
run, its epic walk and the next follow-up go on.

## Chained refinement mode (`--chained-from`, #2939)

`--chained-from <root> --handoff <file>` runs this skill as a **step** of a
`/development:resolve-issue` run on `<root>`: a fresh subagent that refines one
unready issue for its caller (#2907, *Context isolation*). **It never asks the
human itself.** Its caller relays the questions and dispatches it again, so a
chained run returns one outcome document instead of prompting.
`--chained-from` is never combined with `--follow-up`: print the usage line and
stop. Everything this section does not change runs as Steps 0–7 say, the
auto-accept threshold included.

1. **Read the handoff first**, before the epic classification and Step 0:
   `"<skill-base-dir>/scripts/chain-result.zsh" read-handoff --file <file>`. It
   validates the `step-handoff/v1` object (ARCHITECTURE.md, *Step handoff
   contract (`step-handoff/v1`)*) and prints it. On exit 2 or 1, return
   `stopped` with the reason "unreadable step handoff" and write nothing. A
   target the classification does not find a single issue returns `stopped`
   with the classification's finding as the reason: the Epic walk never runs
   in a chained refinement. Its
   `scratch_dir` holds this issue's chained state: the rounds directory is
   `<scratch_dir>/refine-<N>.rounds/` and the conductor's defaults file
   `<scratch_dir>/refine-<N>.defaults.json`, in place of the `/tmp` paths
   Step 0 names.
2. **A first dispatch** is one with no `<scratch_dir>/refine-<N>-resume.json`.
   It runs Steps 0 and 1 as written. **A re-dispatch** finds that file: it
   skips Steps 0 and 1, restores the state the file holds, and continues
   Step 2 with no new Step 1 diagnosis (step 5 below).
3. **A follow-up keeps its seed (#2588).** When the issue carries a
   `follow-up-origin/v1` record (`follow-up-auto-refine.zsh origin` exits 0),
   run `seed` as the unattended follow-up mode does and pass it as the `seed`
   field of every `issue-refiner` call. The `already-attempted` and
   `second-generation` refusals do not apply to it: `eligible` is not run.
   Everything else follows this section, not the follow-up mode's.
4. **A below-threshold question is relayed, not asked.** In a chained
   refinement, a below-threshold intent or gap question is
   never asked in place or through a side channel. When a round's split leaves
   any `ask` entry, the run writes nothing back, and the needs-decision park is
   never taken. It writes
   `<scratch_dir>/refine-<N>-resume.json`, holding the issue's `title` and
   `body`, the `conversation`, the open objections, the round turn- and
   split-file paths, the decisions taken, the auto-accepted answers so far, the
   `ROUNDS`/`RAISED`/`RESOLVED` counters, Step 0's `t0` and `repo_root`, Step
   1's `RISK` and `SIZE_PREFLIGHT`, `paused_s` and `waiting_since` (now), and the
   pending `ask` entries. Then it returns `questions-pending` with
   `chain-result.zsh emit --issue <N> --outcome questions-pending --split <the
   round's split> --turn <the round's turn> --resume <the resume file> --round
   <ROUNDS>`. Nothing
   is posted to GitHub between dispatches.
5. **A re-dispatch adds the answers as plain human lines.** It adds
   `now - waiting_since` to `paused_s`, then takes each handoff `answers` entry
   for this issue whose `question` is a pending entry's question text,
   verbatim, and adds it to the round's human reply as the plain human line
   `<question> → <answer>`. When every pending question is answered, it
   calls the refiner with that reply. A pending question still unanswered
   returns `questions-pending` again with only the unanswered entries, and
   makes no refiner call: it rewrites the resume file with the lines it did
   add, `waiting_since` reset to now and only the unanswered entries pending,
   and passes `--split` a file holding `{"ask": [<the unanswered entries>]}`.
6. **The round cap.** `ROUNDS` counts across dispatches, through the resume
   file. Once `ROUNDS` is at or past 3, whatever would start another round
   returns `stopped` instead, with the reason
   "no convergence within the round cap" — the follow-up mode's bound and
   wording.
7. **No approval prompt.** On convergence the size check runs as Step 2 says.
   A draft it does not stop is written back at once: the human's relayed answers,
   the auto-accepted answers and the Decisions taken stand in for the
   approval. Add the Decisions taken section, then run Steps 2.5 and 3, with
   `provenance.generated_by` set to `issue-refiner via
   /development:resolve-issue`. Then Steps 4 to 6; a still-rejected re-gate
   loops back to Step 2 within the same cap. The all-auto check does not run:
   no chained run has an approval to skip.
8. **A split is filed and handed back.** A size-check stop whose
   `proposed_split` names its children is filed without asking (Step 2), and the
   run returns `split` with the `filed` children: the caller walks them, each
   as its own chained refinement, in the same resolve-issue run. A `null`
   `proposed_split`, or a child with an empty `files`, stops the chain as a
   permanent failure: return `stopped` with the reason "the size check stops
   the draft and the split names no children". A `file-split-children.zsh`
   exit 1 runs another round within the cap; an exit 3 returns `stopped` with
   its stderr as the reason, and an exit 5 with its report's `error`.
9. **One outcome document.** The run prints exactly one document from
   `chain-result.zsh emit`: `ready` (Step 5's `READY` branch, with the re-gate
   verdict's risk and the auto-accepted answers), `split`, `questions-pending` or
   `stopped`. Each is a step verdict value by the same name, and a refinement
   step never ends `done`, `needs-refinement` or `blocked`.
10. **Telemetry.** Only the dispatch that ends `ready`, `split` or `stopped`
    emits Step 7's record, with `T0`, `PAUSED_S`, `ROUNDS`, `RAISED` and
    `RESOLVED` carried across dispatches through the resume file. A
    `questions-pending` dispatch emits none. `ready` records `refined-ready`,
    `split` and step 8's exit 5 record `parked` with `split-recommended`, and
    any other `stopped` records `parked` with `deferred`. An
    unreadable handoff stops before Step 0, so it is not a run and records
    nothing.

## Defaults taken instead of asking (#2903)

Three of this skill's flow questions have one safe, reversible answer. Under
ARCHITECTURE.md's *Decision rights — question taxonomy and the Decisions-taken
record* (#2899) they are `implementation`, so you take the answer instead of
asking: Step 0's missing-label precondition, Step 1's `READY` shortcut and Step
5's still-rejected re-gate. `reference/ask-branches.md` inventories every ask
branch this skill has, with its kind; every `intent` or `gap` branch stays with
the human. The unattended follow-up mode keeps its own fixed answers. Step
2.5's test-case spin-out (#2939) is not one of these three: it is a standing
rule the human approved, so it prints no notice and records no entry, and the
approval of the rewrite, or the write-back that replaces it, covers it. A
chained refinement takes these defaults as written, and relays every intent or
gap question to its caller (*Chained refinement mode*).

Each default does two things:

1. **Prints one line** in your terminal output: `Decision taken (not asked):
   <choice>`.
2. **Records one Decisions-taken entry**, with the question, the choice and the
   evidence from the table below. Append it as `{"kind": "implementation",
   "question": …, "answer": <choice>, "rationale": <evidence>, "overrule": <how
   to overrule>}` to the `auto` array of `/tmp/conductor-defaults.json` (in an
   epic walk, the child's `/tmp/refine-issue-epic-<E>/<N>.defaults.json`), created
   as `{"auto": []}`; Step 0 deletes it with the parked state. When Step 2
   renders the Decisions taken section before the approval, that file counts as
   one of this issue's round split files, but it is never part of a parked state's
   `decisions`. When the run ends with no write-back after the default — Step
   1's shortcut, a parked exit or a stop — post each pending entry as a
   one-line issue comment instead: `Decisions taken: <question> → <choice>
   (evidence: <evidence>; to overrule: <how to overrule>)`. The body is never
   edited only to record a default. Once an entry is in the body or a comment,
   drop it from the file, so nothing records it twice.

| Default | Question | Choice | Evidence | How to overrule |
|---|---|---|---|---|
| Step 0 | Refine an issue that is not marked `needs-refinement`? | Refined it without the label. | Nothing is written without Step 2's approval of the exact rewrite, a run that asked the human nothing (the all-auto check, #2938), or a chained refinement's relayed answers (#2939). | Restore the body from the issue's edit history. |
| Step 1 | Clear `needs-refinement` on a story the gate now passes? | Cleared it through Step 5's `READY` branch. | Step 5 removes the label only on a `READY` verdict. | Re-add the label. |
| Step 5 | Loop again after a re-gate that still rejects? | Looped back to Step 2 with the gate's remaining reasons as objections. | The label stays, and the human can stop from inside the loop; after a second rejected all-auto write-back, the next draft goes to the human (#2938). | Stop the loop; the label stays as the resume signal. |

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
  SIZE_PREFLIGHT=""   # optional, never guarded — Step 7's size_preflight (#2589)
  AUTO_REFINEMENT=""  # optional, never guarded — --follow-up only (#2588)
  # The time this run spent waiting on an epic walk's batch approval (#2904),
  # which Step 7 subtracts from wall_s.
  PAUSED_S=0
  # Print the two stamps: Step 7 needs their LITERAL values many tool calls
  # later, and a shell variable does not survive that gap.
  echo "carry into Step 7: T0=$T0 REPO_ROOT=$REPO_ROOT"
  # A stale parked-state from a PREVIOUS epic-walk child would otherwise be read
  # as this child's, giving its record the wrong park_type.
  rm -f /tmp/parked-state.json /tmp/parked-comment.md /tmp/parked.json /tmp/conductor-defaults.json
  # The all-auto check's inputs (#2938) are this run's alone: a single-issue
  # run keeps them in a directory named for its issue, so a concurrent session
  # on another issue never shares it; an epic walk child uses its own (Step 2).
  rm -rf /tmp/refine-issue-<N>.rounds && mkdir -p /tmp/refine-issue-<N>.rounds
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
- **Read resolve-issue's size park first (#2602).** resolve-issue §2(b) sends a
  story here with the `needs-split` label and a `size pre-flight: SPLIT` comment
  when its plan stopped the size pre-flight. Pipe the `labels` and `comments` you
  just fetched to the reader:

  ```bash
  gh issue view <N> --json labels,comments \
    | "<skill-base-dir>/scripts/read-split-park.zsh" > /tmp/split-park.json
  ```

  It prints `{objection, reason, summary, inventory}`. `objection: true`
  (reason `split`) is a **live size objection**, which Step 1 acts on. A
  `stale-overridden` or `stale-no-comment` reason means the `needs-split` label
  looks stale: tell the human so, and change no label. An exit 2 or 3 prints
  nothing: report its stderr and continue without a size objection, since
  resolve-issue's pre-flight remains the backstop.
- **Precondition — the `needs-refinement` label.** This skill is for stories the
  gate sent back. A live size objection satisfies it: resolve-issue sent the
  story here, so do not ask. Otherwise, if the label is **absent**, **proceed
  without asking**, and take the default with its notice (*Defaults taken instead
  of asking*, above): you can refine a story that was never formally gated, and
  nothing is written without Step 2's approval of the exact rewrite, unless no
  question reaches the human at all (*Step 2 — the all-auto check*) or the run
  is a chained refinement (*Chained refinement mode*).
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
  the human is resuming from. Write its `decisions`, when present, to a file as
  `{"auto": <decisions>}`: that file counts as one of this issue's round split files for the Decisions taken section.
  Tell the human what the prior run parked on before continuing the loop. A
  resumed session is **never all-auto** (#2938): its parked questions already
  reached the human, and Step 0 emptied the rounds directory that would have
  shown it, so its rewrite is always presented for approval.

  ```bash
  # only when a parked state was read; an epic walk child uses its own
  # /tmp/refine-issue-epic-<E>/<N>.rounds/ instead, created here if missing
  mkdir -p /tmp/refine-issue-<N>.rounds && touch /tmp/refine-issue-<N>.rounds/resumed
  ```

## Step 1 — diagnose (fresh objections)

**First, reuse a still-valid readiness stamp (#2956).** From the repository root:

```bash
"<skill-base-dir>/scripts/readiness-stamp-step.zsh" diagnose --repo "$REPO" --issue <N>
```

- **`"hit": true`** → its `verdict` is the diagnosis, exactly as if
  `story-readiness` had just returned it: spawn no gate. Everything below
  applies to it unchanged, `RISK` and `SIZE_PREFLIGHT` included, and so does
  the `READY` shortcut.
- **`"hit": false`**, or any nonzero exit → spawn the gate as below. A miss,
  a failed check included, never stops the session.

Otherwise spawn **`story-readiness`** (Task tool, `subagent_type: story-readiness`) on the
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

**Record the verdict's `size` object too** (#2589), into Step 7's
`SIZE_PREFLIGHT` as `{"verdict", "triggers", "children_filed": 0}` — for example
`SIZE_PREFLIGHT='{"verdict":"stop","triggers":["files"],"children_filed":0}'`.
Unlike `RISK`, the **last** readiness verdict's `size` wins: Step 4's re-gate
replaces it. A verdict with no `size` object leaves it empty. Step 2's own size
check never writes its `verdict` or `triggers`, so a draft split after a
readiness `pass` records `pass` beside its `children_filed`. A `size` stop
reaches you as a `scope_bounded` objection naming its trigger; the first refiner
turn that returns a non-null `proposed_split` goes straight to the plan file and
split choice of Step 2's size-check exit 1, converged or not.

**A live size objection (#2602)** comes from Step 0's reader. Make it concrete
before anything else:

- **With an `inventory`**, write it to a file and run `size-check.zsh --file
  <it>` from the repository root. Exit 1: the objection carries the re-sized
  triggers and counts. Exit 0: the plan now passes, so there is **no**
  objection; tell the human the `needs-split` label looks stale. Exit 2 or 3,
  after one re-run of a malformed call: the fallback below. Keep this sizing's
  verdict file in the rounds directory for the all-auto check: its stdout on
  exit 0 or 1, else the one-line file `{"verdict":"unjudged"}`.
- **Without one** (the fallback), the objection carries the reader's `summary`,
  and Step 2's size check sizes only the draft's declared inventory, as before.

Append the size objection to the verdict's `refinement_questions` for this
session. **While it is open, the `READY` shortcut below is not offered**, even
on a `READY` verdict: go to Step 2, and ask the first refiner turn for a split,
each child a bounded story with its own declared inventory. Its first non-null
`proposed_split` goes to the plan file and split choice of Step 2's size-check
exit 1, which with an inventory is the re-sized stop.

**`needs-split` is never yours to set or clear.** A split filed by
`file-split-children.zsh` (exit 0) removes it, as that script already does; its
exit 5 leaves the original's labels as they were. A rewrite that narrows the
story instead, or any typed parked exit, leaves it on: resolve-issue's next
pre-flight decides, and only its clear block removes it.

If it already returns `READY`, the story now passes: **clear the label through
Step 5 without asking** — no loop needed — and take the default with its notice
(*Defaults taken instead of asking*, above). That
shortcut is still a run: set `PARK_TYPE=""; ROUNDS=0; RAISED=0; RESOLVED=0` —
measured zeros, assigned deliberately, so a no-op never reads as a hard-won
convergence — then run **Step 5's `READY` branch**, which assigns
`STATE_OUTCOME` only if the label removal actually succeeded, and emit Step 7's
record. Never set `STATE_OUTCOME="refined-ready"` here: it would claim `success`
for a story whose label the removal may have failed to clear. Then **skip Step
6** — nothing changed, so there is no before/after trail to post — and stop
after Step 7, which emits **at most** one record (none if Step 5's label
removal failed and the label is still set).

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
- **`questions`** — split them first (below), then surface the **ask** ones and
  **collect the human's answers**;
- **`recommendations`** — the concrete rewrites it suggests;
- **`proposed_prose`** / **`proposed_story_spec`** — the draft, when it has one.

**Split the questions against the threshold, every round.** Write the agent's
returned JSON to a file and run it through the script. Keep this run's turn and
split files of every round, and every sizing's verdict file, Step 1's and Step
2's, in its rounds directory for the all-auto check: `/tmp/refine-issue-<N>.rounds/`,
or a child's `/tmp/refine-issue-epic-<E>/<N>.rounds/` in an epic walk, which a
redraft keeps.

```bash
"<skill-base-dir>/scripts/split-refiner-questions.zsh" \
  --threshold-milli <milli> --turn <turn.json>
```

It prints `{threshold, auto, ask}`, each entry with its `kind` — `intent`, `gap`
or `implementation`, ARCHITECTURE.md's *Decision rights — question taxonomy and
the Decisions-taken record* (#2899). The script decides and you do not
second-guess it. For an `intent` or `gap` question its confidence is the lowest
of the refiner's five criterion scores, and the answer is `auto` only when that
is at or above the threshold. An `implementation` question is `auto` at any
threshold (#2900). An exit 2 means the turn is not a JSON object with a
`questions` array, or the refiner broke its contract in one of the two
exceptions to "malformed is asked, never an error", each named on stderr: an
`implementation` entry has no `recommended_answer` or `rationale`; or — the
second exception (#2901) — an entry whose own `kind` is `gap` has no
`proposed_doc_change`, a null or blank `target`, `section` or `wording`, or a
`target` that is absolute or contains `..`. An entry routed as `gap` only
because its `kind` is missing or unknown is exempt. Either way, re-spawn the
refiner for this round once, and if it fails again, relay the questions to the
human as they are. The re-spawned turn supersedes the failed one: delete the
failed turn's file, so the round keeps one turn file. When the questions are
relayed as they are, write the round's split file yourself, as
`{"auto":[],"ask":[<the relayed questions>]}`, so the all-auto check sees that
the round reached the human (#2938). The unattended follow-up mode applies its
own exit-2 rule instead.

**An answered gap's acceptance criterion is the refiner's.** From the turn after
a `gap` question is answered, the refiner's drafts carry one
`Record in <target> under "<section>": <wording>` criterion per answered gap,
in both the prose and the block. The conductor neither adds nor edits it: the
human approves it as part of the rewrite, and Step 3 writes it back unchanged.

- **`auto`** — answer each one with its `answer`. For an `intent` or `gap`
  answer, add it to the round's human reply as
  `[auto-accepted @<confidence>] <question> → <answer>` — a `gap` one followed
  by `(Record in <target> under "<section>")` from the turn's
  `proposed_doc_change`, so the refiner's next turn reads it — and tell the human in
  one line per answer what you took and its weakest criterion. Keep a running
  list of these answers for the approval step below. For an `implementation`
  answer, add it as `[decided] <question> → <answer>` instead. It is absent from
  **Answers taken automatically**: it is recorded in the **Decisions taken**
  section below. Keep this issue's split file of every round for that section.
- **`ask`** — relay these as before. Show the `recommended_answer`,
  `confidence` and, on a `gap`, the turn's `proposed_doc_change` next to each one
  when present, so the human can simply agree. A chained refinement shows them
  to no one: it returns `questions-pending` for its caller to relay
  (*Chained refinement mode*, step 4).

When every question is `auto`, do not wait for the human: call the agent again
straight away with the auto-accepted answers as `human_reply`.

Append this round (your relayed summary + the human's reply, auto-accepted lines
included) to `conversation` and call the agent again with that reply as
`human_reply`. **Converge when the agent reports every objection
`resolved: true` AND `questions == []`** — its `resolved_objections` drives this
decision (that is its whole purpose). Then **size the draft** (*Step 2 — size
the draft before approval*, below), then run **the all-auto check** (*Step 2 —
the all-auto check*, below), and only a draft that does not stop and is not
all-auto is presented: the **final `proposed_prose` + `proposed_story_spec`**,
for the human's **explicit approval of the exact rewrite**.

**Add the Decisions taken section before the approval.** Run
`"<skill-base-dir>/scripts/render-decisions-taken.zsh" --split <split.json>` on
each of this issue's round split files and add what it prints to `proposed_prose`, leaving out a decision from this
run's split files that the human overturned before approving (an overturned answer is a human reply, not a decision
Claude took), so the section sits inside the prose sentinels Step 3 writes, is part of the rewrite the human approves,
and is covered by `prose_sha256`. The section is append-only: when the current issue body or `proposed_prose` already
holds a `## Decisions taken` section, put the new entries at its end, under the one heading, and never remove an entry
an earlier run wrote to the issue body. An entry the section already holds, such as a first pass's after a Step 5
loop-back, is not added again. The follow-up mode's `accept` does the same before Step 3. An exit
2 is your own malformed call: fix it and re-run once. Nothing is written until they approve. If they
want changes, feed their reply back for another round.

**In an epic walk the approval is the batch's (#2904).** A child's sized draft
is not presented here: it becomes **pending approval**, and the Epic walk's
phase B asks one approval for every pending child at once. The batch summary
carries the same **Answers taken automatically** this step would show. An
all-auto child is never pending: phase A writes it back, until *The all-auto
loop is bounded* (below) sends its next draft to the batch.

**Auto-accept approves the rewrite only when it answered everything.** The
threshold only answers the refiner's questions. The approval of the exact
rewrite is the human's, whatever the threshold, unless the refinement is
all-auto (*Step 2 — the all-auto check*, below): no question reached the human,
so there is no choice left to approve. The other exception is the unattended
follow-up mode below, where its `accept` decision stands in for that approval. A
chained refinement is another (*Chained refinement mode*, #2939): the human's
relayed answers, the auto-accepted answers and the Decisions taken stand in
for it.
Present it with a heading **Answers taken
automatically**, listing each auto-accepted `intent` or `gap` question, the
answer, its confidence and its weakest criterion. The human can overturn any of them
before approving. An overturned answer is a normal human reply: feed it back for
another round.

**Record Step 7's counters as you go — on every path through this loop, not just
a park.** They have no other source, and Step 7 refuses to guess, so leaving them
unset makes it skip the record entirely rather than report a fabricated zero:

A shell variable does **not** survive between Bash tool calls, and this loop
spans many of them across human turns. Step 7's fence reads Step 0's `T0` and
`REPO_ROOT` plus the run variables `STATE_OUTCOME`, `PARK_TYPE`, `RISK`,
`ROUNDS`, `RAISED`, `RESOLVED`, `SIZE_PREFLIGHT` and `PAUSED_S`, and its guard reads them
*before* the `jq` does, so substituting literals into the `--arg` lines
alone still leaves the guard seeing unset values and skipping the record. So:
carry every one of them in your own notes as you go (Step 0 prints its two), and
**re-assign every one of them on the lines immediately above the guard, in the
same invocation as the fence**. The guard reads all but `RISK` and
`SIZE_PREFLIGHT`, which only the `jq` reads — so an omitted one is not skipped:
`RISK` is silently recorded as `null`, and `size_preflight` silently left out.
Never assume an assignment from an earlier turn is still live:

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

### Step 2 — size the draft before approval (#2589)

A story too big to build as one change is found here, while you and the human
are both present, rather than at resolve-issue §2 after the human has left.
**Never write back a draft whose declared inventory stops the size check.**

On convergence, build the draft's **declared inventory** — a judgement, the same
rule `story-readiness` follows: every repo-relative path the drafted story will
touch, from `proposed_prose` and `proposed_story_spec.scope_boundaries.in`, with
concrete paths for named areas. Write it as `{"files": [ … ]}` to a temporary
file outside the repository (an empty `files` array when no concrete path can be
named), and run, from the repository root:

```bash
"<skill-base-dir>/scripts/size-check.zsh" --file <inventory.json>
```

It applies the size pre-flight's own thresholds; this skill restates none.

- **Exit 0** — `pass` or `skipped`: keep its stdout as this sizing's verdict
  file, run the all-auto check (below), and present the draft for approval as
  above only if it is not all-auto.
- **Exit 2** — your own malformed call: fix it and re-run once.
- **Exit 3, or a second 2** — the inventory could not be judged. Write the
  one-line file `{"verdict":"unjudged"}` as this sizing's verdict file, run the
  all-auto check (below), tell the human in one line and present the draft:
  resolve-issue §2's pre-flight remains the backstop.
- **Exit 1** — `stop`. Do **not** present the draft for approval. Keep its
  stdout as this sizing's verdict file. Relay the
  triggers and counts, and run another refiner turn with the stop as an
  objection: *the draft's declared inventory stops the size check
  (`<triggers>`, `<counts>`); propose a split into child stories, each a bounded
  story with a title, a body and its own declared inventory*. Write the
  refiner's `proposed_split` into a plan file as `children`, adding nothing of
  your own:

  ```json
  { "children": [ { "title": "…", "body": "…", "files": ["…"] }, … ] }
  ```

  A `null` `proposed_split`, or a child with an empty `files`, is never filled
  in by you: show no children and ask once — **Revise the draft** or **Park as
  `deferred`** (the typed parked exit below), never the `split-recommended`
  park, which is offered only when the split names its children. That question
  is a direct run's: in a chained run it stops the chain as a permanent failure
  (*Chained refinement mode*, step 8).

  **Otherwise the split is filed without asking, in every refine-issue run,
  chained or direct (#2939):** show the human every child, then file them
  (below). The split names each child with its own declared inventory, and
  `file-split-children.zsh` sizes every child before any write, so no choice is
  left that the size check has not already made. The unattended follow-up mode
  is the one exception: it never splits, and parks `deferred` (unchanged).

**Filing the split.** Run from the repository root:

```bash
"<skill-base-dir>/scripts/file-split-children.zsh" --repo "$REPO" --parent <N> --plan <plan.json>
```

It size-checks every child before any write, files each one as a native
sub-issue of `<N>` labelled `needs-refinement`, replaces `<N>`'s
`needs-refinement` with `epic`, and posts a trail comment listing the children.
Branch on its exit:

- **0** — filed. The original is now an epic, so **skip Steps 2.5–6**: nothing is
  written back to it. Set `STATE_OUTCOME="parked"`, `PARK_TYPE="split-recommended"`
  and `SIZE_PREFLIGHT`'s `children_filed` to the length of its `filed` list (an
  empty `SIZE_PREFLIGHT` stays empty: the children go uncounted), run
  Step 7, and then **walk the filed children as an epic in the same run**: the
  Epic walk below, on `<N>`. A chained run instead returns `split` with the
  filed children, and its caller walks them (*Chained refinement mode*, step 8).
  (In an epic walk that ends **this child**, not the walk: note it in the epic
  summary as split into its filed children, and walk them after the rest of
  this pass, as children of their new epic `<N>`.)
- **1** — a child's inventory still stops; **nothing was written**. Relay which
  child and its triggers, and run another round to revise the split; the
  revised split is filed the same way.
- **2** — your own malformed call: fix it and re-run once.
- **3** — nothing was written. Relay its stderr and offer the parked exit.
- **5** — partial. Relay its report verbatim: the children it filed, and what
  failed. The original's labels were left untouched. Never re-run it — a re-run
  files the children a second time. Record the run as for exit 0, with
  `children_filed` the length of the report's `filed` list, and tell the human
  what is left to finish by hand.

### Step 2 — the all-auto check (#2938)

A refinement is **all-auto** when, across the whole run, every round's split
file had an empty `ask` set (intent and gap questions only), every size check
passed or was skipped, and no round's refiner turn carried a non-null
`proposed_split`. A resumed parked session (its rounds directory holds
`resumed`, Step 0) is never all-auto: skip the check and take *Any other
reason* below. On every other converged draft that the size check did not stop,
judge the whole run so far, from the repository root:

```bash
"<skill-base-dir>/scripts/all-auto-check.zsh" \
  --split <round-1-split.json> --turn <round-1-turn.json> … \
  --size-check <sizing-1-verdict.json> …
```

Pass one `--split` and one `--turn` per round of this run, and one
`--size-check` per `size-check.zsh` run of this run, Step 1's included: its
stdout on exit 0 or 1. For a sizing that ended in exit 3, or in a second exit
2, write the one-line file `{"verdict":"unjudged"}` and pass that. Pass no
other file: the conductor's defaults file and a resumed park's decisions file
are not split files here. A run that loops back from Step 5 keeps every earlier
round's files.

It prints `{all_auto, reason}`, the reason the first that fails of
`no-rounds`, `ask-question`, `size-check-stop`, `size-check-unjudged` and
`proposed-split`, else `all-auto`. An exit 2 is your own malformed call or a
malformed file, named on stderr: fix it and re-run once. A `--split` and
`--turn` count mismatch is fixed only by deleting a re-spawned round's
superseded turn file or by writing a relayed round's split file (Step 2), never
by dropping the turn file of a round whose questions went to the human. A
second exit 2 counts as not all-auto.

- **`all-auto`** — no approval prompt. Add the Decisions taken section as for an
  approved rewrite and run Step 2.5 and Step 3 at once, with
  `provenance.generated_by` set to `issue-refiner via /development:refine-issue
  (all answers auto-accepted)`. Then Steps 4 to 7 as written; Step 6's trail
  names every answer the run took for the human.
- **Any other reason** — present the exact rewrite for the human's approval, as
  above. A refinement in which any intent or gap question reached the human is
  never all-auto.

**The all-auto loop is bounded.** On a Step 5 `NEEDS_REFINEMENT` re-gate after
an all-auto write-back, append one line to `all-auto-rejections` in the run's
rounds directory. Once that file holds two lines, the re-gate has rejected two
all-auto write-backs: the next draft and every later one of this run go to the
human for approval as for any other reason, whatever the check reports, so the
human can stop the loop. In an epic walk such a child's draft is pending and
joins the next batch.

The unattended follow-up mode never runs this check: its `accept` stands in for
the approval, with its own provenance string.

### Step 2 — the typed parked exit (#578)

Not every session reaches `READY` in one sitting. When the human decides it
**can't converge now**, take a **typed parked exit** — an early exit from this
loop (not the Step 5 post-re-gate path) that captures the state so a later run
resumes (Step 0) instead of losing the conversation. Mirrors resolve-issue's
typed escalation (#564), for the human-present refinement loop. Three types:

- **`needs-decision`** — an absent stakeholder / upstream decision blocks a
  testable spec. The state names the `decision` and its `owner`
  ([unclear requirements are refined with AI guidance](https://timo-jakob.github.io/timos-claude-code-plugins/explanation/philosophy/#pillar-4)).
- **`split-recommended`** — the story is really an epic; it can't be one bounded
  spec. The state lists the `candidate_children`
  ([epics and issues are split when too big](https://timo-jakob.github.io/timos-claude-code-plugins/explanation/philosophy/#pillar-5)).
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
object carries the type, the still-**`open_questions`**, the `conversation`, the
type-specific fields, and `decisions`: every `implementation` entry of the
`auto` arrays of this issue's round split files, the file Step 0 wrote from a
prior park's `decisions` included, leaving out a decision that the human
overturned (an overturned answer is a human reply, not a decision Claude took),
so a resumed run can still record them. `open_questions` holds **strings**:
take each refiner question's `question` text, never the scored object. Set
Step 7's run variables as you go —
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

Once the human approves the rewrite, or the all-auto check reports `all-auto`
(#2938), and **before** you write the block back
(Step 3), reconcile the approved `proposed_story_spec`'s `test_cases[]` into
linked **`test-case` issues** — the hybrid model (#671): the cases live *both*
structured in the block (the gate-validatable source of truth) *and* as separate
backlog-visible issues, while staying implemented in the **same PR** as the story
(#577/#696), so tests and feature never drift.

**In every refine-issue run, chained or direct, Step 2.5 files, edits and
closes the story's test-case issues through `test-case-spinout.zsh` without
asking (#2939).** Approving the rewrite, or the all-auto or chained write-back
that replaces the approval, also covers the test-case issues, and no branch
puts their filing to the human. This is a standing rule the human approved on
2026-10-30.

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

This edit is **human-authored**, and human-approved unless the refinement was
all-auto (Step 2, #2938) or chained (#2939) — you run it with the
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
   `"issue-refiner via /development:refine-issue"`, or `"issue-refiner via
   /development:refine-issue (all answers auto-accepted)"` for an all-auto
   refinement), `generated_at` (an ISO-8601
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

**First, after Step 3's edit, save the issue's key to a file (#2956).** It is
the race guard for the stamp below, and a file, not a shell variable, because
the stamp runs in a later shell. From the repository root:

```bash
"<skill-base-dir>/../resolve-issue/scripts/readiness-stamp.zsh" key --repo "$REPO" --issue <N> \
  > <key.txt> || : > <key.txt>
```

Then spawn **`story-readiness`** again on the freshly-edited issue, and re-record
`SIZE_PREFLIGHT` from its `size` object (Step 1). In an epic walk (#2904), also
write it as `size_preflight` into the child's state file
`/tmp/refine-issue-epic-<E>/<N>.json`. Its verdict is now
authoritative — and, because a `story-spec` block now exists, its validation also
checks the block against the prose (it will pass: you just stamped the hash over
this exact prose).

**Stamp the re-gate verdict**, `READY` and `NEEDS_REFINEMENT` alike, so the next
resolve-issue run reuses it: write the verdict JSON exactly as returned to
`<verdict.json>`, then, right after the verdict returns and before Step 5:

```bash
"<skill-base-dir>/scripts/readiness-stamp-step.zsh" stamp --repo "$REPO" --issue <N> \
  --verdict-file <verdict.json> --expect-key "$(cat <key.txt>)"
```

The stamp's key is the edited body's, the body the next run reads. A loop-back
to Step 2 stamps again at its next Step 4, in place, so a deferred park in
Step 5 leaves the newest re-gate's stamp. When the stamp was not written for a
failure, the script prints one line on stderr: relay it to the human as is and
go on to Step 5. A stamp never changes the verdict, the label handling or
Step 7's outcome.

**Relay the verdict's `advisories` to the human (#668).** The re-gate may return
non-blocking `advisories` — e.g. a `story-spec` `personas` reference to a persona
id that isn't in the target repo's `personas/v1` registry, or a stale registry.
These **never** block (the story can still be `READY`), but the human should see
them: surface each advisory's `message`, and when it names a missing/ill-fitting
persona, route the human to **`/development:define-personas`** (as in Step 2) so
they can add or fix it and, optionally, re-run refine-issue to reference it.

## Step 5 — resolve the label, honestly

**In an epic walk (#2904)**, whichever branch below sets `STATE_OUTCOME` and
`PARK_TYPE` also writes both into the child's state file
`/tmp/refine-issue-epic-<E>/<N>.json`, in the same invocation, since its Step 7
re-states the child's literals from that file.

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
  the honest signal. **Loop back to Step 2 without asking**, with the gate's
  remaining reasons as the objections, and take the default with its notice
  (*Defaults taken instead of asking*, above). The unattended follow-up mode
  never loops back: it takes the stop below, its deferred route. In an epic
  walk the looped-back child redrafts and joins the **next batch** (the Epic
  walk's batch loop-back rule), rather than being presented on its own; a child
  written back all-auto in phase A redrafts at once instead (#2938). A second
  rejected all-auto write-back sends the next draft to the human (*The all-auto
  loop is bounded*, Step 2).

  **A stop the human takes in that loop before its next Step 3 write-back is a
  recorded ending, but NOT Step 2's parked exit.**
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
verdict, and the resulting label state. When Step 2 auto-accepted any answers,
the comment also lists its `intent` and `gap` answers under **Answers taken
automatically**, each with its confidence and the threshold; its
`implementation` answers are in the body's **Decisions taken** section. A later reader can then tell which parts of the
story the human stated and which parts the refiner stated for them. This is the
audit trail a later reader — or `resolve-issue` — relies on.

**An all-auto refinement's trail (#2938)** says that the rewrite was written
back without an approval prompt because every answer was auto-accepted. It lists
every auto-taken answer of the run, `implementation` ones included, each with
its question, answer, confidence and weakest criterion, and states the threshold
with its source, as resolved before Step 0 (e.g. "auto-accept: 0.9 (from
settings)").

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
derives `repo`, mints the `run_id`, and appends to the shared user-level sink
`~/.claude/telemetry/<repo-slug>.jsonl`, outside every checkout (#1972):

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

**Re-assign them all before running this block.** `T0`, `REPO_ROOT`,
`STATE_OUTCOME`, `PARK_TYPE`, `RISK`, `ROUNDS`, `RAISED`, `RESOLVED`,
`SIZE_PREFLIGHT` and `PAUSED_S` must all be
re-stated as literals **in the same Bash invocation as the fence**, on the lines
above the guard (Step 2's rule). In an epic walk they come from the child's
state file (the Epic walk's *Per-child state*), and `PAUSED_S` is its
`paused_s`: its waits on others, which `WALL_S` excludes. In a chained
refinement they come from the resume file (*Chained refinement mode*, step 10).
Everywhere else it is Step 0's measured `0`, and the guard requires it to be
digits. In the unattended follow-up mode
`AUTO_REFINEMENT` is one more, re-stated the same way. Values assigned in an earlier tool call are
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
# shortcut.) RISK and SIZE_PREFLIGHT are nullable by contract and are NEVER
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
   || ! "${PAUSED_S:-}" =~ ^[0-9]+$ \
   || ( "${STATE_OUTCOME:-}" == "parked" && ! "${PARK_TYPE:-}" =~ $PARK_RE ) ]]; then
  echo "telemetry not recorded for this run (a Step 0 stamp, the run outcome, a run count, the paused time, or a park's type is missing) — the run itself is unaffected"
else
  # 10# so a leading-zero stamp can't be read as a bad octal literal, matching
  # the emitter's own normalization. PAUSED_S is the run's waits on others
  # (#2904), never refinement work.
  WALL_S=$(( $(date +%s) - 10#$T0 - 10#$PAUSED_S ))
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
            --arg size "${SIZE_PREFLIGHT:-}" --arg auto "${AUTO_REFINEMENT:-}" \
        '{rounds: ($rounds|tonumber),
          objections_raised: ($raised|tonumber),
          objections_resolved: ($resolved|tonumber),
          outcome: $outcome,
          park_type: (if $park_type == "" then null else $park_type end),
          risk_classification: (if $risk == "" then null else $risk end)}
         + (if $size == "" then {} else {size_preflight: ($size | fromjson)} end)
         + (($ARGS.named.auto // "") as $a | if $a == "" then {} else {auto_refinement: ($a | fromjson)} end)' > "$STATE" \
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
  run** — a non-`OPEN` issue, or a follow-up the unattended mode stops at Step 0
  for want of `needs-refinement`; (b) it was a run that reached **no decided
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
- `size_preflight` (#2589) is the one **optional** payload key, from
  `SIZE_PREFLIGHT`: a JSON object, `{"verdict", "triggers", "children_filed"}`.
  Set it from the **last** `story-readiness` verdict's `size` object — Step 1's,
  then Step 4's re-gate when one ran — with `children_filed: 0`, and set
  `children_filed` to the number of children a split filed (Step 2's split, from
  `file-split-children.zsh`'s `filed` list). Re-state it as a single-quoted
  literal above the guard like the other run variables. It is never guarded: an
  empty `SIZE_PREFLIGHT` leaves the key out (a verdict with no `size` object,
  such as one from before #2589), and a malformed one makes the builder refuse
  the state, which the `||` advisory reports.
- `auto_refinement` (#2588) is the other **optional** key, from
  `AUTO_REFINEMENT`, set only by the unattended follow-up mode: the output of
  `follow-up-auto-refine.zsh note … --format json`, re-stated as a single-quoted
  literal like `SIZE_PREFLIGHT`. A human run leaves it empty, so its payload is
  unchanged.
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
  are **not** migrated; child (e)'s rollup reads both, the old file through an
  explicit operand.

## Guardrails

- **The intelligence is the agent; you are the conductor.** Never invent the
  refinement judgment yourself — spawn `issue-refiner`. Never let the agent
  write to GitHub — every side effect (edit, label, comment) is yours.
- **Human-approved, human-authored write-back.** No bot token, no PR: you edit
  the issue with the human's auth, and only after they approve the exact rewrite
  — the exceptions are an all-auto refinement (#2938), in which no
  question reached the human, the unattended follow-up mode's `accept`, and a
  chained refinement (#2939), whose caller's relayed answers stand in for the
  approval.
- **Auto-accept answers questions, nothing else.** The threshold
  (`--auto-accept`, else `refine_auto_accept_threshold`, else 1) decides only
  which refiner questions you answer with the refiner's recommendation, and
  `scripts/split-refiner-questions.zsh` makes that decision. It approves the
  rewrite only when it answered everything, as `scripts/all-auto-check.zsh`
  decides, and it never answers the Step 0, Step 1 or Step 5 prompts; the
  unattended follow-up mode, the only exception, answers them as it lists.
  An attended run asks none of the three either: they are the conductor's
  defaults (*Defaults taken instead of asking*), which the threshold never
  decides. Every auto-taken answer is shown at approval and recorded in Step 6's trail,
  or, for an `implementation` answer, in the body's **Decisions taken** section.
  An all-auto refinement shows no approval, and its trail lists every one.
- **The label tells the truth.** Remove `needs-refinement` **only** on a `READY`
  re-gate; otherwise it stays.
- **One canonical hash.** Compute `prose_sha256` with
  `scripts/story-spec-prose-hash.zsh` — never hand-roll it, or the gate's
  staleness check will disagree with what you wrote.
- **No `dependencies` in the block** — dependencies are GitHub-native `blockedBy`
  (#583), never in `story-spec`.
- **Size every draft; never write back one that stops (#2589).** Step 2 runs
  `scripts/size-check.zsh` on the draft's declared inventory before approval. A
  stop becomes a proposed split. A split that names its children is filed
  without asking, in every run, chained or direct (#2939), and only by
  `scripts/file-split-children.zsh` — never with raw `gh issue create` calls,
  and never re-run after a partial result. A split that names no children is
  never filed: a direct run asks to revise or park, and a chained run stops.
- **A chained refinement asks no one (#2939).** It returns one
  `scripts/chain-result.zsh` outcome document — `ready`, `split`,
  `questions-pending` or `stopped` — and writes nothing back while a question is
  pending; its caller relays the questions.
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
