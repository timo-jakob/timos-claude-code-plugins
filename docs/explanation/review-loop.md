# The local review loop

Before `/development:resolve-issue` opens a pull request, it runs a **local,
pre-push review loop** on the change. The point is simple: a PR is only opened on
code a reviewer panel has already converged on, so no CI minutes are ever spent
on work that still has open review blockers.

## What one round does

Each round, scoped to the story's diff:

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

The loop repeats until it **converges** — a round with **zero blockers**.
Suggestions remaining is still converged; on an interactive run you are then
offered the chance to promote some of them (below).

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

- **Converged** — zero blockers. The run proceeds to open the PR.
- **Budget exhausted** — the rounds ran out with blockers still open.
- **Not converging** — the *same* blocker survived two rounds unchanged; more
  automated fixing clearly is not moving it.
- **Conflict / ambiguous** — two reviewers gave opposing recommendations, or the
  repository type could not be resolved to a review panel.

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
   A grant raises the run's *ceiling* by three. When the budget ran out that is
   exactly three more rounds; when the run stopped early for not converging, it
   can be more — the run tells you what it actually bought.
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
  none converges immediately — the only trace is a telemetry line recording that
  you were asked and chose nothing (when the run's own telemetry line exists;
  see *What gets recorded about it*).
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
- **The PR's review dossier covers the first pass only, for now.** A suggestion
  you promoted and the second pass fixed still appears under *Waived
  suggestions* there; the PR Summary states how many were promoted meanwhile.
  Merging both passes into one dossier is tracked as
  [#1064](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1064).
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
