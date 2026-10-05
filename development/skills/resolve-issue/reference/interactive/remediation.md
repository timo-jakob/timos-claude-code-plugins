<!-- Shard of reference/interactive.md (#2058), read in its index's order:
     the §0a interactive remediation and its #1226 telemetry note. -->

## Interactive remediation — offer to clear the blockage (#586, #587)

> **Read the #1226 amendment at the end of this section BEFORE running a rung.**
> A rung that runs the Single-issue flow is its own telemetry run: it calls
> `start` before its step 0a, which the frozen text below does not say. An
> epic-kind rung is an epic run of its own (#1227).

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

**Each single-issue rung is its own telemetry run (#1226).** The span above has
each blocker's run start "at its own step 0a". It predates story-mode telemetry
and is byte-frozen, so the amendment is recorded here. It applies only to a rung
that runs the **Single-issue flow**. An **epic-kind** rung runs the Epic flow
and, like any epic, stamps an **epic** run with the same sink flags, starts a
story run for each child it drives, and emits its own epic record
(`reference/epic-telemetry.md`).
Before a single-issue rung's step 0a, it calls `story-telemetry.zsh start`
with its **own** run file,
`<scratch>/story-run-<blocker>.json`, and the **same** sink flags the named
issue's run was given. Its loops take **its** `loop_args`, never the named
issue's, and it emits its own record at its own ending. The named issue's run
file is never touched by a rung, so the named issue's own record is unaffected
(`reference/telemetry.md`, step 2).
