# Interactive procedures — a human is present

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it when the
step that points here is reached, never up front.

Both procedures below run only when a human invoked the skill and is
present; an autonomous run takes neither.

Every `<!-- moved: … -->` block below is byte-identical to the text it was
carved out of; `scripts/verify-reference-move.zsh` proves that against the
pinned pre-move commit, and is what keeps this file honest.

## Interactive remediation — offer to clear the blockage (#586, #587)

<!-- moved: interactive-remediation -->
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
<!-- /moved: interactive-remediation -->

## Interactive extension (#562-resume)

> **Read the #1576 amendment at the end of this section BEFORE acting on step
> 5.** The grant is recorded to the work-dir by `record-grant.zsh` — a step the
> frozen text below does not mention — and step 5's "buys only two" on a granted
> closing sweep is superseded there.

<!-- moved: interactive-extension -->
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
   fixed-since-prior), the **blocker-class histogram for the last two rounds**
   (#1435 — new_defect / incomplete_propagation / under_assertion, where a `–`
   cell means that round was never class-stamped rather than that it scored
   zero), the **convergence assessment** — an explicit, honest
   read of whether another round is likely to help — and the grants consumed
   against the soft cap (#969). The histogram is the one that answers "what
   would another round buy?": a round of `new_defect`s is finding fresh
   problems, a round of the other two is re-reading the last fix pass. Show all of it *before* the `AskUserQuestion`
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
     Since #1498 an all-ambiguous carried set no longer reaches this extension
     the first time **unless the rung refused it** — a Critical among the
     matches, the round already at the ceiling, an unstamped changelist, or a
     failed marker write. So arriving here is not proof a continuation was
     spent. Read the step-1 assessment before framing the blocker as stuck: it
     reports the count only when one was spent, and flags a possibly-new
     carried match only on a stamped round.

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
   and implement the fixes exactly as step 2 implements, then take the granted
   round's boundary — *The round boundary is concurrent* (§3.5) — which mints
   `T`, starts the gate and dispatches that round's panel in-session together,
   producing its findings file. Resume only once that gate is green; a **red**
   gate takes the boundary's own step 6 — this round's panel findings are
   discarded, neither attest is passed, and the boundary restarts from its step
   1 once the red is fixed (or you abandon and report). The grant is not
   consumed twice: the restarted boundary is the same granted round. Then
   resume the loop — same
   `--work-dir`, `--resume`, ceiling raised by 3 — and increment `grants`.
   That fix pass is bound by
   *A fix pass subtracts* (§3.5's round protocol, step 3)
   like any other, and a granted round is where it is likeliest to be ignored.
   The grant buys a fix pass, not a redesign, and the human's guidance is
   direction for what to **remove** as readily as for what to correct — but
   guidance that asks for surface is one of rule 1's overrides, so it is
   applied, not parked. Read the rule there; it is not restated here.
   **The grant raises the *ceiling* by 3, not the remaining rounds**:
   after a `BUDGET_EXHAUSTED` (round == `max_rounds`) that is
   exactly three more rounds (ceiling 8 after the default budget, rounds 6-8),
   but an `ESCALATE_NO_CONVERGENCE` can fire as early as round 2, where the same
   `prev_max + 3` leaves more than three
   (ceiling 8 after a round-2 exit = 6 rounds left) — and a run whose closing
   sweep was granted its extra round is already **one past** `max_rounds`
   (#1434), where the same `prev_max + 3` buys only two. Compute the remainder
   (`new ceiling − rounds already run`) and say what the resume actually buys,
   rather than promising a flat three. The soft cap counts **grants** and the
   20-round figure is a `max_rounds` value, so the varying remainder changes
   neither.
   On a plugin repo
   pass the green gate's `tree` as `--gate-attest` here too (#981, under the four
   rules above), so the resume skips the byte-identical re-run just as a normal
   round does; omit it on any other stack. **`--findings-tree` is not optional
   here either** — §3.5's *Each round* step 2 rule is every step-mode invocation, and a
   granted resume is one: mint `T` at that round's boundary — before the gate and
   the panel, per *The round boundary is concurrent* (§3.5) — and pass it. The guard is fail-quiet, so leaving
   it off silently disarms the cadence check on exactly the rounds residue is
   declared from:

   ```bash
   "<skill-base-dir>/scripts/resolve-story-loop.zsh" --repo <repo> --base <base> \
     --work-dir <same-work-dir> --resume --max-rounds <prev_max + 3> \
     --findings-file <findings-round-R.json> --test-cmd '<full gate>' \
     [--gate-attest <T>] [--findings-tree <T>] \
     [--promote <promoted.json>] --issue <N> \
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
   normal — **via the residue branch first when the BLOCKING phase ended
   `CONVERGED_WITH_RESIDUE`** (its ordering is stated once, at the exit-14
   bullet). That combination is ordinary, not exotic: a residue blocking phase,
   a promotion sub-loop that escalates, a granted +3, and the sub-loop then
   exits 0 here — and without the pointer the run opens its PR with the
   remainder unfiled. **Every** path to `CONVERGED` passes that gate exactly
   once; an
   extended run is the one most likely to have accumulated waived suggestions,
   so it is the last one that should skip the offer. On
   `CONVERGED_WITH_RESIDUE` (exit 14, #1435) → leave this branch too, and take
   the exit-14 bullet's ordering **verbatim**: the suggestion-promotion gate
   first, then the **residue branch**, then §4. The ordering is stated once,
   there — restating it here is how the two came to disagree, and the disagreement
   is on the hot path, since residue replaces exactly the two exits this
   extension exists for. It is a convergence, not another
   escalation — do **not** re-summarize it, do **not** offer more rounds, and do
   **not** consume a grant for it. On another `BUDGET_EXHAUSTED` /
   `ESCALATE_NO_CONVERGENCE` → go back to step 1 with the new status. On
   `ESCALATE_CONFLICT` / `ESCALATE_AMBIGUOUS` → leave this branch and take the
   typed-comment terminal below (a resumed run can surface a different exit).
   On `AWAITING_FIX` (20) → continue the §3.5 round protocol (narrate, fix
   in-session, then the next round's boundary per *The round boundary is
   concurrent* (§3.5), `--resume` with the same
   raised `--max-rounds`) — no grant bookkeeping; the grant was already
   counted. On `STALE_FINDINGS` (exit 2, #974) → **not terminal**: recover **by
   cause** per §3.5's *Each round* step 2 — for the findings-file causes that means re-invoking
   with round R's real path, or running its panel first (re-passing the same
   `--gate-attest` per §3.5's recovery rule); the empty-delta, alias and
   not-applicable-on-a-full-round causes have their own recoveries there, none
   of which is a panel re-run — then resume with the same raised
   `--max-rounds`. The grant
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
<!-- /moved: interactive-extension -->

**The granted ceiling is written to the work-dir, not remembered (#1576).** Step
5 above says "ceiling raised by 3", and for a long time nothing enforced it: the
number lived only in this session's memory, across a context that compacts.
It is now mechanical.

**Run it exactly ONCE per grant** — at the moment the human grants, before the
resume that spends it. That includes a **guidance-only** answer: step 4 makes
guidance an implied grant and routes it here, so it persists a ceiling like any
other:

```bash
"<skill-base-dir>/scripts/record-grant.zsh" --work-dir <same-work-dir> \
  --status <status.json> --add 3
```

**Once per GRANT, not once per `--resume`.** Step 5 reaches a `--resume` on
three other paths after a single grant — the `AWAITING_FIX` (20) continuation,
the `STALE_FINDINGS` (2) recovery re-invoke, and a red gate that restarts the
granted round's boundary. None of them is a new grant, and the same rule the
`grants` counter already follows applies here: they neither increment nor
decrement it, and they must **not** re-run this script. They cannot, in
general, be made harmless by re-running it: the base compounds off the existing
sidecar, so a second `--add 3` on one grant silently funds three rounds the
human never gave and the step-6 soft cap never sees them. Re-run it only when
the human grants **again**, which is exactly when compounding is what you want.

It writes `<work-dir>/.max-rounds` and echoes the new ceiling, computing it from
the **status JSON** rather than from your memory — so a granted closing sweep's
extra round (#1434) is already counted, and a later grant compounds off the
first.

**The file and the flag do NOT always agree, and the file is the one that is
right.** The script adds the increment to the ceiling **actually in force**
(`effective_max_rounds`), not to the flag. On a run whose closing sweep was
granted its extra round that is one *higher* than step 5's `prev_max + 3`.
Still pass `--max-rounds <prev_max + 3>`: the higher of the two wins, so the
flag can only ever raise the ceiling further (a human going beyond the grant),
never lower it. Never "repair" a `.max-rounds` that disagrees with the number
you passed. It usually **equals** what you passed, and is **one higher** on a
run whose closing sweep was granted its extra round — both are ordinary, and
neither is the stale-sidecar hazard.

**This supersedes step 5's "buys only two" on a granted closing sweep.** That
**frozen** sentence below was written when the ceiling was whatever
`--max-rounds` you typed, so the #1434 sweep round was silently deducted from
the grant (ARCHITECTURE.md and the explanation page said the same and have since
been corrected; only the frozen text still reads the old way). It is no longer: a grant
after a granted closing sweep buys **three**, like any other exit.

Do not compute the remainder from your own arithmetic — and mind **which**
number you read, because step 5 owes the human that figure *at the grant*, before
any resume has run. **Before the resume**, the remainder is
`record-grant.zsh`'s **echoed** ceiling minus the rounds already run; the status
JSON on disk at that moment is the *escalation's*, whose `effective_max_rounds`
is the ceiling from **before** the grant, so subtracting from it reports zero (or
one) rounds bought. **After the resume**, re-read `effective_max_rounds` from the
new status JSON and correct the figure if it differs.

**Neither the write nor the adoption is guaranteed — verify, and never halt on
either.** `record-grant.zsh` exits non-zero on a bad invocation (2) or an
unusable status JSON / failed write (1), and the loop's reader does not take
every sidecar at face value either — both of its loud arms are non-fatal, and
they end **differently**:

- a sidecar that is **not a bounded integer** is refused and the flag wins
  (`ignoring an unreadable max-rounds sidecar …`);
- a sidecar **beyond `--max-rounds + MAX_ROUNDS_SIDECAR_SLACK`** (16 today) is
  **clamped to that cap and ADOPTED** (`clamping a max-rounds sidecar beyond the
  soft cap … using <cap>`). Read that line as *the ceiling is higher than the
  flag but lower than the file asked for* — **not** as a lost grant. Do not
  re-run `record-grant.zsh` over it (the once-per-grant rule above), and do not
  hand-raise `--max-rounds` to "fix" it.

Both are non-fatal by design — losing a grant
costs one re-grant, while halting wastes the human's — so **neither ever halts
the granted resume**.

`record-grant.zsh` has a third, **successful** outcome worth knowing: when the
new ceiling would exceed the loop's soft cap it clamps, says so on stderr, and
exits **0** having written the clamped value. Its cap is computed from the
status JSON's `max_rounds`, while the loop's is computed from the `--max-rounds`
you pass, so the two can differ by what you raised the flag to — which is one
more reason to report the ceiling you read back rather than the one you asked
for.

Take the code's own branch, in order:

- **Exit 2** — your own malformed call. **Fix the invocation and re-run the
  script before resuming**, exactly as everywhere else in this skill. Only if it
  fails again, fall through to the exit-1 handling. Skipping the re-run over a
  fixable typo throws the grant back into a context that compacts, which is the
  #1558 loss the script exists to prevent.
- **Exit 1** — the ceiling was not recorded and re-running will not change that.
  Report it in one line and resume with an **explicit** ceiling. That ceiling is
  the status JSON's `effective_max_rounds + 3`, **not** `prev_max + 3`: on a run
  whose closing sweep was granted its extra round the two differ by one, and the
  flag alone would under-fund the grant by exactly the round this story stopped
  deducting. Fall back to `prev_max + 3` only when `effective_max_rounds` is
  unreadable. Report the remainder from **that** explicit ceiling — there is no
  echoed value to read on this path.

**Then verify by the NUMBER, not by the source.** After the resume, the grant is
in force when `effective_max_rounds` is at least `record-grant.zsh`'s **echoed**
ceiling (on the exit-1 path, the explicit ceiling you passed instead).
`max_rounds_source` only says **where** that ceiling came from, and `flag` is the
**ordinary** answer on a successful grant: you passed `prev_max + 3` and the
sidecar holds the same value, so the flag wins the tie and the grant is in force
regardless. Reading `flag` as "refused" would have you report a failure on the
modal success — and invite a second `record-grant.zsh` run, which the once-per-
grant rule above forbids. Report the ceiling you read back, never the one you
asked for.

The loop's status JSON reports the result in `effective_max_rounds` (the ceiling
actually in force) and `max_rounds_source` (`flag` or `work-dir`). **`max_rounds`
still reports what you passed** — the same split #1434 made for
`closing_sweep_granted`, so the `+3`/`grants` bookkeeping above, the soft cap and
the escalation summary all keep reading exactly the number they read before.
