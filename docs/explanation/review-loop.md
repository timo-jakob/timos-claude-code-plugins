# The local review loop

Before `/development:resolve-issue` opens a pull request, it runs a **local,
pre-push review loop** on the change. The point is simple: a PR is only opened on
code a reviewer panel has already converged on, so no CI minutes are ever spent
on work that still has open review blockers.

The procedure the skill follows is split for context economy: `SKILL.md` is a
conductor holding each step's invocation contract and a pointer, while the
branches described on this page — the round protocol, escalation and the
interactive extension — live in
`development/skills/resolve-issue/reference/*.md` and are read only when the run
actually reaches them.

One more split runs alongside that one. Rules that are true of a *single* repo
type — which test command is blessed, what a version bump means there, which
panel reviews it — live in that type's own plugin as a `resolve-profile` skill,
which the conductor detects and loads by name at its §1b step, before it
implements anything. A repo type with no profile keeps the conductor's generic
behaviour after a one-line notice, so the seam adds no refusal; see the
*Resolve profile contract* in ARCHITECTURE.md for the six headings a profile
carries.

## What one round does

1. **Review — and re-test, alongside it.** A language-appropriate reviewer panel
   inspects the change and emits findings (bugs, security, performance, code
   quality, tests — plus resilience on the service languages, and Swift-6
   compliance on Swift), while the full test suite runs against the same tree at
   the same time. The panel runs as visible in-session agents, never as a hidden
   background process; the *suite* is the one thing that does run in the
   background, because it is a deterministic test run rather than a model-driven
   step.
2. **Consolidate** — and this is what waits for the suite. Findings are
   de-duplicated and split into **blockers** (Critical + Warning) and
   **Suggestions**. Only blockers drive the loop; suggestions are logged and not
   looped on (see [Promoting a suggestion](#promoting-a-suggestion)).
3. **Fix** — if there are blockers, an implementor pass fixes them, and the next
   round's boundary re-tests what it wrote. A suite that comes back red discards
   that round's findings and restarts the boundary; a fix that cannot be made
   green abandons the run rather than shipping.

**A reviewer that cannot run a tool does not get to report its verdict.** Most
reviewers are read-only by design — they read and grep, they do not execute — so
a claim like *"the linter would fail this"* or *"the validator reports a
mismatch"* is reasoning about a tool, not the tool's answer, and this repo has
had both come back wrong on real rounds. Such a finding is therefore capped at
**Suggestion**, and names the command that would settle it. Between the panel and
consolidation the driver **runs** those commands against the same tree the panel
read, and only a genuine red raises the finding to the severity its reviewer
proposed; a green leaves it a logged suggestion. That keeps the reviewers
read-only while putting execution in the one step that already runs tools on the
minted tree. The line it draws is *observation vs. execution*, not subject
matter — a defect read straight out of the files keeps its full severity.

Both halves hold on every stack. The **driver's** half is generic: on any repo
type, a finding carrying that command gets it run before consolidation. The
**reviewer's** half — the rule that caps the claim and names the command — ships
with every panel's read-only reviewers, Python, Go, Java, Swift, Kubernetes and
plugin alike. The only read-only agents without it are listed, each with its
reason, in `tests/reviewer-evidence-rule.exemptions` — today the bootstrap
skill's pre-write checks, which no review loop dispatches. One limit remains:
the driver settles a claim on the round that *raises* it, and nothing re-decides
it once the loop carries the finding into later rounds — issue #1647.
The normative statement — where the verdict is
recorded, what a command that cannot run decides, and why the severity rewrite
rather than the recorded verdict is what promotes — is
`/development:resolve-issue` §3.5's round protocol, under *The decided pass*, and
nothing here restates it.

**The gate and the panel run concurrently.** Both only *read* the working tree,
so a round boundary mints one tree identity, starts the test gate in the
background and dispatches the panel against that same tree, instead of making
the panel queue behind the suite. Nothing about the gate changes — it still
runs on every round that applied a fix, and consolidation still waits for it
to come back green — so what is saved is the shorter of the two,
per round; §3.5 carries the measured figure. The one cost is that a **red** gate
discards that round's panel findings, because they describe a tree the fix is
about to supersede; the round restarts from a fresh mint.
`/development:resolve-issue` §3.5's round protocol states the ordering and the
red-gate arm, and nothing here restates them.

**The whole suite runs once per story.** On a plugin repo, every round before
the closing full sweep runs only the tests the story's changes can affect, and
falls back to the whole suite whenever that set cannot be trusted. The closing
sweep and the required CI job run all of it, and no round converges until the
whole suite is green on its tree, so a test the selection missed costs a round,
never a merged PR.

**The wait between the two is a turn boundary, not a poll.** Having started the
gate and dispatched the panel, the driver ends its turn: every reviewer's result
comes back as a harness notification that re-invokes it. The background suite is
the one thing nothing announces, so it is collected once, in a single blocking
call, rather than watched. This is
a cost rule as much as a style one — a run that polls instead spends a third of
its turns and a third of its input tokens on answers it was going to be handed
anyway. The normative statement — what a waiting turn may not do, and the single
bounded blocking call reserved for signals the harness does not deliver — is
`/development:resolve-issue` §3.5's **How to wait**, and nothing here restates
it.

**Each wait comes with a sourced estimate, or an honest none.** Before the gate,
the panel, or any other round subagent, the driver prints one line that
`narrate-estimate.zsh` builds: a live time-left read from the running gate's own
log, a median and 80th percentile from this repo's past runs, or
`no estimate (no data)`. The driver never improvises a figure, so a human
deciding whether to step away is reading a measurement, not a guess.

**A fix pass subtracts.** Step 3 is allowed to delete, narrow or collapse; it is
not allowed to grow the change. A finding whose smallest fix would have to add
new behaviour is parked as a follow-up issue instead — unless a human, or the
story's own acceptance criteria, asked for that surface on purpose. The reason
is mechanical rather than aesthetic: a pass that adds surface is writing the
round after next's findings, and the loop then spends its budget reviewing its
own edits instead of your change. When the round classes say that is already
happening, collapsing a restatement rather than patching it stops being advisory
and becomes required. The normative statement — the closed list of moves, and
the exact condition that makes them mandatory — lives in
`/development:resolve-issue` §3.5's round protocol, step 3, and nothing here
restates it.

## What each round is scoped to

Rounds after the first are an **iteration** on the previous one, not an
independent repeat of it. Three kinds of round:

- **Round 1 — the full sweep.** Scoped to the whole story diff against the base
  branch. Nothing has happened yet to iterate on.
- **Intermediate rounds — the delta.** Scoped to what the *previous round's fix
  pass actually changed*. Two things ride along: the previous round's blockers,
  so the panel verifies the fixes it asked for actually landed — each carried
  blocker is shown only to the reviewer of its own dimension, its one owner,
  which reports it as confirmed, re-raised (it saw the defect still present,
  and says where) or unconfirmed; a reviewer that cannot find a fix
  reports it as unconfirmed rather than re-raising it, and the loop refuses a
  round in which a carried blocker's owner neither confirmed nor re-raised it
  rather than letting it drop out of the carry; and the list of
  suggestions earlier rounds already surfaced and you already let go, which a
  reviewer must not re-raise. An already-waived suggestion re-raised at
  Suggestion level is dropped and counted, never silently — and one a tool
  actually decided red is never dropped at all — but the same finding
  re-raised as a **Warning or Critical** is never suppressed, and neither is a
  suggestion in a file the last fix pass touched, because there it may be a new
  observation about new code.
- **The closing full sweep — a converging run always ends on a full sweep.**
  Delta scoping buys convergence, but on its own it could hide a defect that
  exists only in the *interaction* between rounds. So the loop can never
  *converge* on a delta round: one that reaches zero blockers **promotes the
  next round** to a closing sweep over the whole story diff instead of
  finishing. (A run that converges on round 1 needs no promotion — round 1 is
  already a full sweep — and a run that ends by exhausting its budget or
  escalating opens no PR at all. So: every run that reaches plain **Converged**
  ends on a full-diff review. Two things open a PR without one, and each is a
  deliberate, stated trade: the `--no-review` fast path and the "nothing to
  review" choices below — both explicit human decisions. Plain **Converged** is
  the only review-loop ending that opens a PR at all.)

Without this, a long run is N independent full reviews rather than N iterations:
round 9 re-reads all 49 changed files with no memory of what eight earlier rounds
weighed and let go, so re-litigation is free and a nitpick in the implementer's
own review response is indistinguishable from a defect in shipped behaviour.

The loop repeats until it **converges** — a **full-sweep** round with **zero
blockers**. Suggestions remaining is still converged, and the run waives them
(below).

## Watching it run

The loop is transparent by construction. Earlier versions allowed the
model-driven steps to run inside headless `claude -p` hooks, which put a whole
multi-round loop behind a single opaque background task — you saw nothing
until it exited. The loop now runs in **step mode**: the driving session
processes one round per loop invocation, so everything model-driven happens in
the session where you can see it.

- **Review agents are visible** — each round's panel is spawned in-session,
  one named agent per review dimension, so the terminal shows who is
  reviewing what.
- **A narrated summary per round** — after each round the session reports the
  blockers found by severity (critical / warning / suggestion), the new-vs-carried
  split, how many of the previous round's blockers the fix pass actually cleared,
  the cumulative blocking trend, and what it fixes next. When a "carried" blocker
  looks like a false alarm — the cross-round match hit a *different* finding that
  merely landed near the old one after edits shifted lines — the summary says so
  explicitly, so you never have to dig into JSON to spot it. Where it cannot
  tell — the titles differ but overlap — and *every* carried blocker of the
  round is that ambiguous, the loop does not stop to ask: it takes the round on
  its own and says so in the same summary (see
  [the round budget](#the-round-budget-and-how-it-can-end)).
- **A tail-able progress file** — the loop appends the same summary to a
  `progress.md` in its work directory (the run tells you the exact path when
  the loop starts); `tail -f` it from another terminal to follow a long run.
  The file survives the session.

## The round budget and how it can end

The loop has a hard budget (five rounds by default). The budget is an *upper*
bound, not a target — the loop stops the moment there are no blockers left, so a
story that converges in one round is unaffected by the size of the cap. It exists
only to bound the hard tail. A round can end the loop in one of a few ways:

- **Converged** (`CONVERGED`, exit 0) — zero blockers on a **full-sweep** round.
  The run proceeds to
  open the PR. A delta round with zero blockers does not end the run: it
  promotes the next one to the closing full sweep (above). If that happens on
  the very last round of the budget, the loop grants the closing full sweep
  exactly one round beyond the ceiling — once, and only for that sweep. The
  budget you set is still what gets reported; the extra round is a fact about
  this run, not a bigger budget. **`CONVERGED` is the only ending that opens a
  PR**: `main` only ever receives work the panel has no blockers left on.
- **Budget exhausted** — the rounds ran out with blockers still open.
- **Not converging** — the *same* blocker survived two rounds unchanged; more
  automated fixing clearly is not moving it. This is the ending only when the
  loop could not take the free round below.
- **Conflict / ambiguous** — two reviewers gave opposing recommendations, or the
  repository type could not be resolved to a review panel. No automated ending
  can pick between two opposed recommendations, and an unresolvable repo type is
  about dispatch rather than findings.

None of the last three opens a PR. When a human is driving, a run whose
blockers are all non-critical goes to the [interactive
extension](#when-a-human-is-driving-the-interactive-extension). An unattended
run takes the automatic extension (#2576) instead, and if blockers survive it,
the clean stop (#2579): the run records why it stopped and leaves its state for
a later run, rather than shipping the blockers.

### The free round on an all-ambiguous carry

"The same blocker survived two rounds" is a judgement the loop makes from
*titles*, because line numbers move as fixes land. Three verdicts are possible.
When the two titles are identical the blocker really is the same one, and the run
stops. When they share no significant word at all, the loop already treats the
new one as a genuinely different finding that merely landed near the old one, and
carries on without asking. In between sits the ambiguous case — the titles differ
but overlap — where the loop honestly cannot tell a reworded survivor from a new
neighbour.

Stopping the run there costs you a question you cannot answer any better than the
loop can, and in one observed session it cost forty-one minutes of waiting across
two occurrences, both of which ended with the human choosing exactly what the
loop's own assessment had already recommended. So the loop now takes that round
itself, once, under four conditions: **every** carried blocker of the round is
ambiguous (one identical-title match among them and the run stops), **none** of
them is Critical, the round is **below** the ceiling, and **none** of the
identities involved has already used its free round. It records what it
continued on, says so in the round summary and in `progress.md`, and moves on.

It costs no grant, but it does cost a round: the loop takes the round it already
had rather than an extra one, so the budget you set is neither raised nor
exceeded, and nothing is added to the grant count or the soft cap. That is also
why it cannot fire on the last round — the rung requires the round to be
strictly below the ceiling. And it is once per identity — including the title
the match was against, so re-wording a finding cannot buy a second one. If an
identity comes back ambiguous again, that repetition is itself the evidence, and
the run stops as it always did.

### Why the residue ending was retired

The loop once had a second PR-opening ending: a run whose last two rounds found
no Critical, and whose closing full sweep still left non-critical blockers, could
open its PR and file those blockers as labelled follow-up issues. It was retired
(#2580). `main` is the stable build, and that ending shipped work with known
blockers still in it. A residue-shaped run now goes to an extension, or to the
clean stop, as described above. The follow-up issues earlier runs filed are
still in the tracker under the `review-residue` label, as history.

With [`corner_case_risk_threshold`](../how-to/set-a-corner-case-risk-threshold.md)
set, the run assesses the reviewers' blocking findings in every round. A
non-critical one whose risk falls below the floor — unless a tool confirmed
it — is **demoted to a suggestion**: logged in the round's
progress and in the PR, but not fixed. That keeps the fix pass from spending
round after round on corner cases nobody would hit, which is what most often
left a run with only non-critical blockers.

When a run escalates, the **grant prompt** shows the last two rounds' blockers
broken down by class — a fresh defect, an incomplete propagation of the last
fix, or a test assertion that has not caught up — so "would another round help?"
is answerable from what the rounds were finding rather than from a blocker count
that may have been flat for reasons that had nothing to do with progress.

There are also two ways a round can be **refused rather than counted** —
neither cleared by re-running the review itself. If a round's delta is
empty *and* the previous round left no blockers to verify, there is nothing for
a panel to look at and nothing to re-check, so the loop refuses the round rather
than counting it. That is a refusal, not an outcome: no PR is opened, no
escalation comment is posted, and re-running changes nothing — the way forward
is usually to restore the closing-sweep record the previous round earned — or
to re-run under the round budget that record was written under; the message says
which. That is the reachable cause: this refusal only fires after a round that
found nothing, so there is nothing left to fix, and inventing a code change just
to move the tree is never the answer. Stopping is the last option, not the
first.

The second is a **full** round with nothing to review: the story diff itself is
empty, or — on a Kubernetes repo — it touches nothing that deploys. The panel
reports that and writes no findings, and the loop refuses the round rather than
reading "no findings" as "no problems", which on a full round would converge the
run. An empty story diff means going back and implementing. A non-empty diff the
repository type's panel cannot review — a `.bats`-only change on a Kubernetes
repo, a docs-only change on a JavaScript repo — goes to the **fallback panel**
first (#2909): `/development-claude-plugin:review` in its fallback mode reviews
the shell, bats and Markdown files in the same round, and keeps reviewing the
rest of the run. The run asks nothing, prints one line naming both panels, and
records the choice under the PR's *Decisions taken*. Only when the fallback
cannot review the diff either, or `development-claude-plugin` is not installed,
is it a decision for you: skip the review deliberately and ship, review the
diff yourself and record the review as waived, or stop without opening a PR.

## When a human is driving: the interactive extension

If **you** launched `/development:resolve-issue` and are present, the two
"still making progress but not done" endings — **budget exhausted** and **not
converging** — do not dead-end. Instead the run pauses and talks to you:

1. It **summarizes** what is left, with enough in front of you to actually
   decide: the remaining blockers (with severity and dimension, and any
   suspected false-alarm "carried" match flagged), a per-round progress table
   (critical / warning / suggestion counts, new vs carried, fixed since the
   prior round), an honest **convergence assessment** — whether another round
   is likely to help, or whether direction or a split is needed — and how many
   extension grants you have already spent.
2. It **offers you a choice**:
   - **Grant three more rounds** (on budget exhausted) — the remaining
     blockers get one fix pass first, then the loop continues. There is no such
     option on a *not-converging* exit any more: the case that used to justify
     it — every carried blocker flagged as a suspected false alarm — is now
     handled by the loop itself, one round, no question asked, so a
     not-converging exit that does reach you is one the loop could not take that
     way.
   - **Give guidance, then retry** — tell it something it is missing ("that auth
     check is intentional, don't flag it"; "try a documented fast-path helper for
     the retry logic"). Your note is posted to the issue and folded into the next
     fix pass. For a *not-converging* blocker this is the main lever — more rounds
     alone will not move a stuck blocker, but the missing constraint will.
   - **Ask a question** — "why is that blocker stuck?", "show me the diff for
     that file". You get an answer and the same choice again; asking never uses
     up a grant.
   - **Stop** — hand off asynchronously (see below).
3. If you grant rounds, the remaining blockers are **fixed first** (folding in
   any guidance you gave), then the loop **resumes where it left off** — the
   round count and the not-converging detection carry across the extension, so
   it is a true continuation, not a restart.
   A grant raises the run's *ceiling* by three, but what that **buys** depends
   on how far the run already got. When the budget ran out at the ceiling it is
   exactly three more rounds; when the run stopped early for not converging, it
   can be more; and when the run had already been granted its closing sweep — a
   round past the ceiling — it is three as well, because the recorded ceiling
   already counts that extra round. The run tells you what it actually
   bought, rather than promising a flat three.
4. You can extend repeatedly, +3 to the ceiling each time.
   After about five grants, or any round that removes no blockers, the run will
   warn you that it does not look like it is converging and suggest stopping or
   splitting the work — but the decision stays yours.
   That five-grant point is a *nudge*, not a hard stop: by then the ceiling
   already stands at 5 + 5×3 = 20 rounds, and a run that needs anywhere near
   that many should be split, which is exactly what the warning tells you.

## Promoting a suggestion

Suggestions never block, so by the time a run converges every one the panel
raised has been **waived**: logged in the round's progress and in the PR's
review dossier, and never acted on. That is where the run leaves them, attended
or not. A converged run goes straight on to the version bump and the PR, with no
prompt in between.

Earlier versions stopped an attended run at this point and offered every waived
suggestion for promotion to blocking, resolved through a second pass of the
loop. Over a month of runs nobody promoted anything, so the offer was removed:
the project prefers to move forward rather than re-open what a converged run
already let go.

## When you stop, or a run is unattended

If you choose **Stop**, or the run is **autonomous** (an epic-driven or
maintenance run, with no human to prompt), the loop takes the asynchronous path
instead: it posts **one** typed comment on the issue — the escalation type, a
summary, the round history, and two or three concrete options — applies the
`needs-human-decision` label, and pushes the branch so the diff-so-far is
linkable, **without opening a PR** (a draft would spend the CI minutes the local
loop exists to save). You (or anyone) answer in the thread and re-run
`/development:resolve-issue <N>`; the next run reads your comment as
implementation context when it builds the change again.

## Skipping the loop

`/development:resolve-issue` can run with the loop disabled (the `--no-review`
fast path) when you deliberately want no local review round — for example on a
trivial change you will review yourself.

## See also

- [Read your pipeline telemetry](../how-to/read-pipeline-telemetry.md) — the
  loop appends one record per run ending; this is how you read them back.
- [Pipeline telemetry](pipeline-telemetry.md) — why the loop records anything,
  and what it deliberately does not. The five-round default on this page is
  itself a telemetry-driven number.
