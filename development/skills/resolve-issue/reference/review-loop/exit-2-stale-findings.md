<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     round step 2's STALE_FINDINGS recovery arms (exit 2). -->
<!-- The frozen chunk below is the tail of round step 2's list item, cut off
     from the item's own line, so its indentation is the item's. -->
<!-- markdownlint-disable MD007 MD032 -->

<!-- moved: round-protocol-recover -->
   **Recover by cause, then re-invoke** — the round is not lost. One arm below
   (the missing-confirmation-count one) is a **pre-invocation** check rather than a
   recovery: the loop cannot refuse that shape for you, so it is on you to spot
   it before you pass the file:

   - if round R's panel **did** run and its aggregate exists at its own path,
     **and the refusal named the findings FILE rather than the tree**, just
     re-invoke with the correct `--findings-file` (don't re-run the panel). The
     qualifier is load-bearing: that antecedent is true on a **cadence** refusal
     too — the panel ran, the aggregate is right where it should be — and taking
     this arm there re-passes a file the loop has just told you describes the
     wrong tree;
   - on the **CADENCE** refusal (`--findings-tree` disagreed with the working
     tree) → re-run round R's panel against the **current** tree, minting a fresh
     `--findings-tree` **before** that panel runs, and pass its aggregate. Or
     discard the fix that moved the tree and re-consolidate what the panel
     actually read. **Never clear it by dropping `--findings-tree`** — the guard
     is fail-quiet, so that consolidates the very round it just refused, which is
     the fix-then-resume outcome the guard exists to prevent;
   - if round R's panel reported the round **FAILED** — a dimension that did
     not run, a render step that failed, or (on a round ≥ 2) a
     `fix_verification_path` that was **null or unreadable** — it deliberately
     wrote no findings file and named the cause. That last shape splits: a **null**
     carry is *your own* omitted `--fix-verification` — re-plan the round with
     the carry path (step 1's precondition) and re-run the panel; an
     **unreadable** one means the path was passed but the panel could not read
     it (a relative path resolved against a different cwd, a file outside the
     agent's reach), which step 1's read-before-plan precondition should already
     have caught — fix the path so the agent can read it, then re-run. Either
     way, re-running the panel *unchanged* reproduces the same report. Do **not** write `[]` and do **not** re-invoke:
     fix what it named and re-run the panel, or, if it cannot be fixed, report
     it in the conversation and stop. Writing `[]` here records a clean round
     over a dimension nobody reviewed, and on a delta round that also promotes
     the closing sweep — so the run can reach CONVERGED and open a PR on an
     unreviewed dimension, the exact outcome the panels' write-nothing rule
     exists to prevent.

     **The panel's report to you is the primary signal**, not a file on disk.
     Only the `kubernetes` panel additionally leaves durable detail in
     `<findings-path>.failed.json`; the other five report a failed round to
     their caller and nothing else. So a missing sidecar is **not** evidence
     the panel ran cleanly. (On a loop-driven **delta** round that carries
     nothing, the `kubernetes` panel reports **not applicable** by writing `[]`
     itself plus that sidecar — the opposite case, with nothing to recover.
     With a non-empty carry it either dispatches with the carry or re-raises what
     it could not confirm. A **full** round's not-applicable verdict has its own
     arm below.);
   - **any** panel, on a round carrying a non-empty `verify-<R>.json`, that
     does not account for **every** carried entry took the wrong branch —
     whatever it wrote to the findings file. Two shapes: it states **no count
     at all**, or it states `N of M` with `N < M` and does **not** re-raise, at
     its original severity, each of the `M − N` it could not confirm. A `[]` is
     the starkest case, but two *new* findings with nothing said about the carry
     retire the carried blockers just as unconfirmed — and so does a partial
     count with no re-raises to reconcile it. The count and the findings file
     must add up: every carried entry is either confirmed in the report or
     re-raised in the file. All six carry the same rule ("say in your report
     that you confirmed N carried entries"), so this is not a kubernetes-only
     shape — a confirmed-clean `[]` is legitimate and says so. Treat an
     unconfirmed one exactly like a FAILED round: do **not** pass it to
     `--findings-file`. Re-run the round's panel, telling it explicitly to
     confirm each carried entry and to report how many it confirmed; if the
     re-run again reports no confirmation count, report it in the conversation
     and stop. Consuming it retires carried blockers no reviewer
     confirmed: the entries this round did not re-raise never reach
     `verify-<R+1>.json`, so the carry chain is gone for good — and when the
     report was a `[]`, the round additionally promotes the closing sweep, so
     the run can reach CONVERGED with the previous round's blockers unfixed;
   - if round R's panel reported the round **NOT APPLICABLE on a full round** —
     the `kubernetes` panel's verdict when a story's diff touches nothing it can
     review (a workflow, a docs page, an excluded chart's `values.yaml`), and
     the other five panels' *the story diff itself is empty* — it is neither a
     failure nor something you can fix, and **re-running it is deterministic**:
     it will report the same thing. Do **not** write `[]` (zero blockers on a
     full round is the CONVERGED condition, so that would open a PR on a story
     nothing reviewed), and do **not** loop on the panel. Report to the user
     what the panel said. Then:

     - **autonomous** — stop, and say so. An unattended run does not get to
       waive its own review. Do **not** commit and do **not** open a PR;
     - **interactive** — put it to the human as three options, and take none of
       them without an explicit choice: (1) the deliberate `--no-review` fast
       path (below), which records status `SKIPPED` and does open a PR; (2) a
       **non-panel review** — you read the story diff yourself and report what
       you find in the conversation; it produces **no** findings file and does
       not resume the loop, so the run ends with the review recorded as waived
       in the PR body; (3) stop, with no commit and no PR.

     An **empty story diff** is the one shape not to offer any of these for:
     nothing was implemented, so there is nothing to review or to ship — see
     step 1's `"full"` plan branch and go back to **§2 (Implement)**;
   - if it **never** ran, and you can establish that positively (no panel was
     dispatched this round, or it was interrupted before any dimension
     completed), run round R's panel (step 1) and write **its** aggregate —
     which is `[]` only when that panel really found nothing — then re-invoke.

   **You never author a review round's findings file yourself.** In every arm
   above the `[]` that reaches `--findings-file` is a panel's own output; there
   is no state in which the right move is to write `[]` on a panel's behalf. If
   you cannot positively establish that this round's panel ran to completion
   over **every** dimension, the absent aggregate is ambiguous — re-run the
   panel, or stop. Filling it in yourself converges the round on a review nobody
   performed. The loop enforces the same rule from its side: on a **full** round
   a missing or empty `--findings-file` is refused as `STALE_FINDINGS` rather
   than read as `[]`, because zero blockers there is the CONVERGED condition.

   **The one carve-out is the promotion sub-loop's seeded round 1** (below),
   and it is not an exception to the rule above: that file is never a `[]`
   substituted for a panel, and it adds nothing a panel did not already report
   — it is the blocking phase's own panel aggregate plus items projected from
   that phase's own changelist, so a human's promoted pick is reproducible. It
   is a *seed* for a round that then runs its panel normally, not a stand-in
   for one.
   - on the **alias** refusal, re-invoke with `--findings-file` pointing at this
     round's own path (`findings-round-R.json`). Do **not** re-run the panel —
     its output is intact, and re-running it into the same sink repeats the
     mistake;
   - on the **empty-delta** refusal, no re-run of the **panel** can clear it,
     and there is nothing to fix either: this arm fires only when the carry is
     `[]`, and the refusal message says so itself. Restore `<work-dir>/.closing-sweep` holding this round's number, or
     re-invoke under the `--max-rounds` the marker was written under (step 1
     sets out why the marker is the reachable state). **Never invent a code
     change just to move the tree.** Stop only when you cannot establish that
     the previous round was a zero-blocker delta round.

   **Re-pass the same `--gate-attest` on the recovery re-invoke** (plugin repos).
   The refusal happens *after* the resume-start gate has already run (or validly
   attest-skipped) on this exact tree, and neither the refusal nor the read-only
   panel touches the tree — so the held attestation still matches. Omit it and
   the recovery needlessly re-runs the full suite, the very duplicate #981
   removes; drop it only if you edited the tree since the green gate.

   Never re-pass the previous round's file, and **never hand-edit findings to
   make the bytes differ** — that fakes a round. The **byte-identical** refusal
   can only fire *again* if you feed it byte-identical findings *again*; two
   genuinely independent panel runs **that each found something** never
   serialise to identical bytes (evidence text, ordering, and reviewer set all
   vary), so a repeat means the file still wasn't this round's real panel
   output — recover it (above), don't work around it. Two rounds that both
   found **nothing** do serialise identically, of course, and that case is
   governed by the waiver above rather than by this rule. A blocker the reviewers keep re-finding is a real problem to
   **fix in-session**, not a reason to defeat the guard. That reasoning is
   specific to that arm. The **empty-delta** refusal depends on the tree, the
   **cadence** refusal on the tree the panel READ, and the **alias** refusal on
   the invocation, so re-passing different bytes does nothing for any of the
   three — take their own recoveries above. (The cadence one is the only refusal
   whose inputs are all well-formed: the panel ran, the file is right, and it is
   the ORDERING that was wrong.)

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
<!-- /moved: round-protocol-recover -->

**An empty story diff is refused on a written `[]` too (#1485).** Step 1's
`"full"` plan branch says that the loop refuses a full round with an empty
scope. Step 2's `STALE_FINDINGS` list states only the no-findings-file half of
that refusal. Both sit inside the byte-frozen span, so the other half is
recorded here. It is the **EMPTY-STORY-DIFF** arm. A **full** round whose
scope is **empty** is refused as `STALE_FINDINGS` whether its findings file is
absent or an actual `[]` that consolidated to zero blockers, because that `[]`
means the panel saw nothing. The arm fires in both wirings. It covers an
implementation that produced no diff, and a story whose only changes sit in the
loop's own state (a repo-internal `--work-dir`, the status, findings, telemetry
or carry-accounting files), which the filter strips. Recover exactly as step
1's `"full"` branch says: go back to **§2 (Implement)**; or, if the story
genuinely needs no code change, say so and stop, and never invent a change to
fill the diff. Like several of step 2's own arms, this cause may therefore end
the run without a re-invocation.

**This note governs wherever step 2's recovery arms would otherwise match.**
Whether the panel wrote an aggregate or, as its contract says, none at all,
step 2's arms that re-invoke with the `--findings-file` or re-run the panel look
like they apply. Take neither. Both plan the same empty scope and are refused
again.
