# The local review loop

Before `/development:resolve-issue` opens a pull request, it runs a **local,
pre-push review loop** on the change. The point is simple: a PR is only opened on
code a reviewer panel has already converged on, so no CI minutes are ever spent
on work that still has open review blockers.

## What one round does

1. **Review** — a language-appropriate reviewer panel inspects the change and
   emits findings (bugs, security, performance, code quality, tests — plus
resilience on the service languages, and Swift-6 compliance on Swift). The
   panel runs as visible in-session agents, never as a hidden background
   process.
2. **Consolidate** — findings are de-duplicated and split into **blockers**
   (Critical + Warning) and **Suggestions**. Only blockers drive the loop;
   suggestions are logged and not looped on — unless a human explicitly
   promotes one afterwards (see [Promoting a suggestion](#promoting-a-suggestion)).
3. **Fix** — if there are blockers, an implementor pass fixes them.
4. **Re-test** — the full test suite runs again; a fix that breaks anything
   aborts the loop rather than shipping.

## What each round is scoped to

Rounds after the first are an **iteration** on the previous one, not an
independent repeat of it. Three kinds of round:

- **Round 1 — the full sweep.** Scoped to the whole story diff against the base
  branch. Nothing has happened yet to iterate on.
- **Intermediate rounds — the delta.** Scoped to what the *previous round's fix
  pass actually changed*. Two things ride along: the previous round's blockers,
  so the panel verifies the fixes it asked for actually landed; and the list of
  suggestions earlier rounds already surfaced and you already let go, which a
  reviewer must not re-raise. An already-waived suggestion re-raised at
  Suggestion level is dropped and counted, never silently — but the same finding
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
  review" choices below — both explicit human decisions. **Converged with
  residue** (below) is *not* one of them: it takes over an ending that would
  otherwise have been an escalation, but only a full sweep may declare it, so a
  run whose residue conditions hold on a delta round promotes that sweep first.
  Both PR-opening endings are reached from a full-diff review, and residue also
  files every remaining blocker as a labelled follow-up issue.)

Without this, a long run is N independent full reviews rather than N iterations:
round 9 re-reads all 49 changed files with no memory of what eight earlier rounds
weighed and let go, so re-litigation is free and a nitpick in the implementer's
own review response is indistinguishable from a defect in shipped behaviour.

The loop repeats until it **converges** — a **full-sweep** round with **zero
blockers**. Suggestions remaining is still converged; on an interactive run you
are then offered the chance to promote some of them (below).

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
  explicitly, so you never have to dig into JSON to spot it.
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
  this run, not a bigger budget.
- **Converged with residue** (`CONVERGED_WITH_RESIDUE`, exit 14) — the run was
  *about* to exhaust its budget or
  declare itself stuck, and neither was the honest verdict. Three things were
  true at once: the last two rounds found **no Critical at all**; every blocker
  still open sat in a file the loop's **own previous fix pass** had just
  written; and the round saying so had read the **whole** change, not just the
  slice it was scoped to. The first two say this is not shipped behaviour going
  wrong — it is the implementer reviewing its own last edits. The third is what
  earns the right to say it: a round scoped to a slice can only speak for that
  slice, so a run whose first two conditions hold on a *delta* round does not
  end there. It promotes the closing full sweep first — one more round — and
  only that sweep may declare residue. So the run **opens the PR** and files the
  remainder as follow-up issues instead of asking you for another round. This
  and plain **Converged** are the only two endings that open a PR, and both are
  reached only from a full sweep.
- **Budget exhausted** — the rounds ran out with blockers still open, and the
  residue conditions above did **not** hold: a Critical in the window, or a
  blocker in a file nobody had just touched.
- **Not converging** — the *same* blocker survived two rounds unchanged; more
  automated fixing clearly is not moving it. Same rule: this is the ending only
  when the residue conditions do not hold.
- **Conflict / ambiguous** — two reviewers gave opposing recommendations, or the
  repository type could not be resolved to a review panel. Neither is ever
  replaced by residue: no automated ending can pick between two opposed
  recommendations, and an unresolvable repo type is about dispatch rather than
  findings.

### What "residue" costs you, and what it buys

The residue ending is the one place the loop opens a PR without a human ever
seeing an escalation, so it is deliberately narrow. **All three** conditions are
required: two consecutive zero-Critical rounds; *every* remaining blocker inside
the previous round's own edits; and the round declaring it having run as a full
sweep. A first round can never qualify — there is no previous fix pass to
attribute anything to.

The three do not fail the same way. Either of the first two failing sends the run
back to the ordinary escalation. The third failing does **not** — a delta round
meeting the other two promotes the closing full sweep and carries on, so residue
costs one more review round than the conditions alone suggest. That round is the
one that reads every file the delta rounds structurally could not, which is what
the extra round buys.

What you get is a PR that says so. Its Summary names the residue ending and the
follow-up issues it filed, and its review dossier records the terminal state, so
a residue PR is never mistakable for a clean one. Each follow-up issue carries
the finding's file, line, dimension, severity and *class* — whether it is a
fresh defect, an incomplete propagation of the last fix, or a test assertion
that has not caught up.

Those issues are attached as **native sub-issues** of the story's epic (or of
the story itself when there is no epic), and every one is labelled
`needs-refinement`. What happens next depends on which of those two it was.

**If the story had an epic**, the epic is still open, so it now carries open
`needs-refinement` children. The run that filed them will not close the epic —
that is correct, not a stall — and the next `/development:resolve-issue` on it
walks it as an epic and **stops** at the readiness pre-flight, because a finding
title is not a story. That halt is the prompt to refine the residue before
building it, and the label is why you meet a child already carrying the reason
it stopped, rather than a surprise.

**If there was no epic**, the residue hangs off the story itself — and the story
closes when this PR merges, so nothing walks it again and no pre-flight ever
meets you. There the residue reaches you through its two labels and through the
PR body, which names every issue it filed. Search `review-residue` when you want
the backlog.

The same class split now rides in the **grant prompt** too. When a run *does*
escalate, the summary shows the last two rounds broken down by class, so
"would another round help?" is answerable from what the rounds were finding
rather than from a blocker count that may have been flat for reasons that had
nothing to do with progress.

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
run. An empty story diff means going back and implementing; a diff that simply
touches no manifests is a decision for you: skip the review deliberately and
ship, review the diff yourself and record the review as waived, or stop without
opening a PR.

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
   - **Grant three more rounds** (on budget exhausted — or on a not-converging
     exit where every carried blocker is flagged as a suspected false alarm,
     meaning the blockers may be fresh rather than stuck) — the remaining
     blockers get one fix pass first, then the loop continues.
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
   round past the ceiling — it is two. The run tells you what it actually
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
raised has been **waived** — logged, and never acted on. That default is
deliberate: a Low finding should not hold up a PR. But it left no way to say
*"actually, do that one"* at the one moment you have the whole picture and the
change is otherwise ready.

So when an **interactive** run converges with at least one waived suggestion,
you are shown them — title, `file:line`, dimension — and can **multi-select any
subset** (including none). What you pick is promoted to blocking and resolved
through a second pass of the very same loop: review → fix → re-test, the full
suite every round. Nothing about the bar changes; a regression introduced while
polishing a suggestion is caught exactly like any other blocker.

A few properties worth knowing:

- **Nothing is ever auto-promoted.** The list is a menu, not a plan. Selecting
  none converges immediately — the traces are a telemetry line recording that
  you were asked and chose nothing (when the run's own telemetry line exists;
  see *What gets recorded about it*), and a `0` picked / `0` cleared note in the
  PR summary.
- **Unattended runs are untouched.** An autonomous or headless run is never
  prompted, passes no promoted set, and converges with its suggestions waived —
  behaviour identical to before this existed.
- **The list is every suggestion the run logged**, not just the last round's.
  A suggestion raised in round 1 and never repeated is still un-actioned work,
  so it is still offered.
- **A promoted item survives its own fix.** Matching is by identity — file,
  dimension, and title — with a tolerance for line drift, not by an exact line
  number. Otherwise the first edit above it would quietly drop it back to Low
  and the pass would "converge" without doing what you asked.
- **It runs once.** New suggestions that surface during the promotion pass are
  waived, not re-offered — the phase is a triage moment, not a treadmill.
- **One pick, one item.** A selection raises exactly the finding you picked, not
  its neighbours — so promoting one suggestion never quietly enlists the two
  next to it.
- **The PR's review dossier covers both passes** — whenever the second pass ran
  to a verdict the run kept. A suggestion you promoted and that pass fixed is listed as
  found-and-fixed, not under *Waived suggestions*, and the dossier records how
  many suggestions you picked versus how many the engine actually raised; those
  differ whenever a pick was no longer there to raise. (When *none* of your picks
  could be confirmed still present — each either no longer there or
  unverifiable — the second pass never runs, so those counts appear in the PR
  summary instead.) One caveat worth knowing: an item is dropped from the
  waived list only when its title still matches exactly, so a suggestion the
  panel re-worded between passes can stay listed even though it was fixed. That
  direction is deliberate — the alternative risks hiding a genuinely un-actioned
  suggestion that merely shares a word.
- **The budget is a fresh allowance** — the promotion pass gets the same
  five-round budget the blocking phase had, governed by that same single
  constant rather than a second one, with the same extension offer if it runs
  out. It is not the blocking phase's leftovers.
- **A promoted item reads as promoted, everywhere.** Once raised it is a
  blocker like any other — but it is labelled, so nobody has to guess whether a
  reviewer flagged it or you did. The progress file counts it in the round's
  blockers line (`critical: 0, warning: 3, promoted: 2`) and gives it its own
  line naming the file, dimension and title; if the pass ends up escalating, the
  per-round table gains a **Promoted** column and the item is listed as
  `Warning (promoted)`. Both the count and the column appear **only when
  something was actually promoted**, so an ordinary run's output is unchanged.
  The count is always a *subset* of the warnings, never an extra category added
  on top.
- **A promoted item that has already vanished is reported, not silently
  skipped.** If the code moved on and a promoted suggestion no longer exists,
  you are told — a converged pass never implies work that was not done. And when
  the run cannot confirm either way, it says exactly that ("could not verify")
  rather than claiming the item is gone.

### What gets recorded about it

The point of offering the choice at all is to find out whether suggestions are
worth acting on — so the run records the two numbers that answer it: **how many
suggestions you were shown**, and **how many you promoted**. They are appended
to the repo's local telemetry file as one extra line linked to the run that
produced them, at the moment you answer.

Four details worth knowing, because they decide what the numbers mean:

- **Picking none is recorded too** (as "0 promoted"). It is a real answer to
  "are these worth doing?", not a non-event.
- **An unattended run records nothing here.** No prompt was shown, so there is
  no offered-vs-promoted pair to record, and its telemetry is exactly what it
  was before this feature existed.
- **The promotion pass does not count against the loop's convergence rate.** It
  is polish on an already-converged change, so the headline "did it converge?"
  figures deliberately exclude it — otherwise choosing to promote a suggestion
  would make the loop look worse at converging. Its rounds still show up where
  the question is *what the loop did*: the rounds-to-converge average and the
  escalation breakdown both keep them.
- **If the run's own telemetry line was never written, nothing is recorded here
  either.** The pair is linked to that line, and an unlinkable record would be
  worse than none — so it is skipped rather than invented.

The telemetry file records only counts, never the findings themselves — what
each suggestion *was* lives in the PR's review dossier. What this adds is just
the two numbers: what you were shown, and what you chose.

If the promotion pass cannot clear what you picked, it escalates through the
normal taxonomy rather than silently re-waiving it — you asked for those items,
so they are treated as blockers. That has a cost worth knowing before you pick:
an escalation ends the run **without opening a PR**, so promoting something
unclearable can turn an otherwise-ready change into one that needs another
session. The prompt says so at the point of choosing.

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
