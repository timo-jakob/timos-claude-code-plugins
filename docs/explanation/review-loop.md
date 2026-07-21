# The local review loop

Before `/development:resolve-issue` opens a pull request, it runs a **local,
pre-push review loop** on the change. The point is simple: a PR is only opened on
code a reviewer panel has already converged on, so no CI minutes are ever spent
on work that still has open review blockers.

## What one round does

Each round, scoped to the story's diff:

1. **Review** — a language-appropriate reviewer panel inspects the change and
   emits findings (bugs, security, performance, code quality, tests).
2. **Consolidate** — findings are de-duplicated and split into **blockers**
   (Critical + High) and **Low suggestions**. Only blockers drive the loop; Low
   suggestions are logged, never looped on.
3. **Fix** — if there are blockers, an implementor pass fixes them.
4. **Re-test** — the full test suite runs again; a fix that breaks anything
   aborts the loop rather than shipping.

The loop repeats until it **converges** — a round with **zero blockers**. Low
suggestions remaining is still converged.

## The round budget and how it can end

The loop has a hard budget (three rounds by default). A round can end the loop in
one of a few ways:

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

1. It **summarizes** what is left: the remaining blockers and a per-round
   history.
2. It **offers you a choice**:
   - **Grant two more rounds** (budget exhausted only) — the remaining blockers
     get one fix pass first, then the loop continues.
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
4. You can extend repeatedly, two rounds at a time. After about five grants, or
   any round that removes no blockers, the run will warn you that it does not
   look like it is converging and suggest stopping or splitting the work — but
   the decision stays yours.

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
