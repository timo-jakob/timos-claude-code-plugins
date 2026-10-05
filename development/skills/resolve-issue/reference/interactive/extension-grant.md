<!-- Shard of reference/interactive.md (#2058), read in its index's order:
     steps 5-7 of the interactive extension: the grant, the soft cap, stop. -->
<!-- The frozen chunk below continues the extension's numbered list at
     item 5, so its numbering cannot restart at 1 here. -->
<!-- markdownlint-disable MD029 -->

<!-- moved: interactive-extension-steps-5-7 -->
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
<!-- /moved: interactive-extension-steps-5-7 -->

**Read on:** `reference/interactive/extension-ceiling.md` amends step 5 above —
read it BEFORE acting on step 5.
