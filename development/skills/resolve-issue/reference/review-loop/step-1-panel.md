<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     round step 1, the review panel. -->

**The end-the-turn wait that step 1's pointer names never covers a round
subagent dispatch (#2113).** A `round-panel`, `round-fix`, `round-decide` or
`round-risk` dispatch that launched in the background is waited on in-turn, as
*A background round dispatch* (Round subagents) says — not by ending the turn.

<!-- moved: round-protocol-tail -->
1. **Review panel, in-session.** Get the dispatch plan (`review-dispatch.zsh
   plan`, §#560) and spawn the reviewers of the skill it names in
   `review_skill` via the **Agent tool** (one agent per dimension, visible to
   the user), scoped to the plan's `changed_files` — minus anything under the
   loop's `--work-dir`, which is loop state, never story code. Aggregate their
   findings into one #558-schema JSON array file — the round's findings file.

   **How to wait** (this section) governs the wait — it is not restated here.

   **From round 2 on, `plan` needs flags — and it refuses a round ≥ 2 that
   names neither `--prior-tree` nor `--final` (#1434).** The two carry flags are
   optional to the parser, but they are not alike. `--adjudicated` is genuinely
   optional and a `null` path is benign. Omitting `--fix-verification` on a
   round ≥ 2 is **not**: the descriptor reports a `null` path and every panel
   then refuses the round outright — writing no findings file and naming the
   flag — so the omission costs a full panel run before the round can be
   re-planned.
   Your panel must be scoped the way the loop will consolidate
   the round, so run the loop's own invocation as your baseline — then apply the
   `--final` rule below. The loop reaches the same two `--final` rounds itself
   (for a verification-only round, via its own re-plan), so your plan and its
   plan agree; the rule is what you need in order to scope your panel *before*
   the loop's invocation exists:

   ```bash
   # round 1 — no flags beyond the round; there is nothing yet to iterate on
   "<skill-base-dir>/scripts/review-dispatch.zsh" plan \
     --repo <repo> --base <base> --round 1
   # round R >= 2
   "<skill-base-dir>/scripts/review-dispatch.zsh" plan \
     --repo <repo> --base <base> --round <R> \
     --prior-tree "$(cat <work-dir>/tree-$((R-1)).txt)" \
     [--final] \
     --fix-verification <work-dir>/verify-<R>.json \
     --adjudicated <work-dir>/adjudicated.json
   ```

   The work-dir files above are written **by the loop**. Three are **normally**
   on disk
   before every round ≥ 2: `tree-<N>.txt` (the working-tree identity round N's
   reviewers saw), `verify-<N>.json` (round N-1's blockers, written at the end
   of round N-1) and `adjudicated.json`. The fourth, `.closing-sweep`, is
   absent until a zero-blocker delta round promotes a sweep — and then
   **persists for the rest of the run**, since a sweep that finds blockers does
   not end it. So read its **content**, never its mere existence: it means
   "this round is the closing sweep" only when it holds **this** round's number.
   A marker naming an earlier round means the sweep already happened and this
   round is ordinary. Neither its absence nor a stale number is a broken
   work-dir. A missing or blank
   `tree-<R-1>.txt` IS an error: it means the loop never ran round R-1, so
   report it and stop.

   **Read the carry before you plan ANY round ≥ 2**, not only when the delta
   turns out to be empty. `jq length` on `<work-dir>/verify-<R>.json`: if it is
   **absent**, **zero-byte**, or does not print a non-negative integer, it is an
   **unreadable carry** — report it and stop. Both causes are orthogonal to
   whether the delta is empty (a `--resume` into an older work-dir predating
   that write; a run killed in the write's truncate-then-fill window), so on a
   NON-empty delta round the empty-delta branch below never runs and nothing
   else would catch it. Planning the round anyway names a `--fix-verification`
   path you could not read: the panel gets a carry it cannot enumerate, re-raises
   nothing, and the loop then writes `verify-<R+1>.json` from this round's
   blockers alone — the carry chain gone for good. **Never plan a round with a
   carry path you have not successfully read.**
   **Never synthesize a prior tree** — computing one from the current tree
   yields an empty delta and a panel that reviews nothing.

   **A non-zero `plan` exit is never a scope.** The call is as fallible as the
   file read above — you hand-build it, including `$(cat <work-dir>/tree-<R-1>.txt)`
   — and it has three documented failures:

   - **exit 2** is your own malformed invocation (an empty value, a dangling
     flag, a `--round` that is not a non-negative integer of at most 18
     digits). Fix the command and re-run it, the same rule §0a applies to its
     own script;
   - **exit 1** is an internal failure (an unresolvable `--base` or
     `--prior-tree`, a failed `jq` or stack probe). Report its stderr and stop;
   - **exit 3** prints a **typed error object** on stdout (`unsupported_repo_type`,
     or an ambiguous repo type) and names no panel. It is the same condition the
     loop reports as `ESCALATE_AMBIGUOUS` — report it and stop.

   Exit 3 is the trap worth naming twice: its stdout *parses as JSON*, so a
   descriptor read that only checks "did I get JSON?" sails past it with
   `review_skill` and `changed_files` null. In none of the three cases may you
   derive `changed_files` yourself or pick a panel by inspection — a
   `git diff <base>` substitute is a **full** scope on a delta round, the
   independent repeat this whole section exists to remove.

   **Pass `--final` in exactly two cases, and never otherwise:**

   - **this round is the closing full sweep** — `<work-dir>/.closing-sweep`
     holds this round's number (the loop writes it, and the zero-blocker
     `AWAITING_FIX` in step 3 is the same signal). The loop passes `--final` on
     its own `plan` call for that round whether or not you do; if you don't,
     your panel is scoped to a delta that is **empty** (the sweep applies no
     fix), so it reviews nothing while the loop records a full-sweep round with
     zero blockers and converges — the safety net silently becoming a no-op;
   - **this round is a verification-only round** — the plan came back
     `scope_mode: "delta"` with `scope_empty: true` while blockers are carried
     (below). Re-plan it with `--final` so the carried blockers are actually
     checked against the whole story diff.

   **`changed_files` is the round's scope, and what it MEANS varies by round.**
   `scope_mode` says which — read the field rather than inferring it:

   - **`"full"`** — the whole story diff against `--base`. That is round 1, the
     closing full sweep, and a verification-only round you re-planned with
     `--final`.
   - **`"delta"`** — every intermediate round: exactly what the previous
     round's fix pass changed. Review that, and **do not** re-read the rest of
     the story diff: a round that re-reviews everything is an independent
     repeat, not an iteration, which is what let round 9 of the #687 run
     produce 49 blocking findings and zero Criticals.

   **A `"full"` plan with `scope_empty: true` is not a round to review either,
   and it is a different problem.** The scope of a full round *is* the story
   diff, so an empty one means the implementation produced nothing. Do not spawn
   a panel, and do not write `[]` — go back to **§2 (Implement)** and write the
   code, then take this round's boundary again — *The round boundary is
   concurrent* (§3.5) — which mints `T`, starts the gate and re-dispatches this
   round's panel together; do not gate to green first. Or, if the story
   genuinely needs no code change, say so and stop. The loop will refuse
   such a round rather than converge it (`STALE_FINDINGS`, naming the full
   round), so there is nothing to recover by re-running the panel: this is the
   verdict all six panels emit as *the story diff itself is empty*, and its
   recovery arm is in step 2.

   **A `"delta"` plan with `scope_empty: true` is not a round to review.**
   Nothing changed since the previous round, so there is nothing for a panel to
   look at. Judge that emptiness on the set you will actually hand the panel —
   `changed_files` **after** the `--work-dir` subtraction above — not on
   `scope_empty` alone. The two agree whenever the work-dir is outside the repo
   or git-ignored, which this section already requires, and the loop itself
   judges on the filtered set; keying on the raw flag would send you to spawn a
   panel over nothing on the one wiring that section forbids. Two cases, split by **how many blockers `<work-dir>/verify-<R>.json`
   carries** — `jq length` on it, not whether the file exists or is non-empty:
   the loop writes that file at the end of every round, storing `[]` when the
   round had no blockers, so for any work-dir this loop version created it is
   normally present and non-empty — and you have already read it, because the
   precondition above required that before this round was planned at all. An
   **absent or zero-byte** carry, or a `jq length` that is not a non-negative
   integer, is **not** "carries none": it is the unreadable carry that stopped
   you there (the loop treats absent and zero-byte identically, `! -s`), and it
   never reads as 0 — the loop's own round-start fallback only rebuilds
   it after your panel has already run.

   - **carries blockers** — a verification-only round. **Re-plan with
     `--final`** and review the whole story diff, so the carried blockers are
     actually checked. (In step mode the loop keeps this a delta round either
     way — it cannot converge, and a clean result promotes the closing sweep.
     What `--final` changes is what your panel *reads*: without it the panel
     sees an empty scope and the carried blockers go unverified for another
     round.)
   - **carries none (`[]`)** — **check `<work-dir>/.closing-sweep` first.** If
     it holds this round's number, this is the promoted closing full sweep and
     the empty delta is expected: re-plan with `--final` and run the full-diff
     panel (above). Stopping here would abandon the run one round short of
     convergence, and skip the very sweep this story exists to add.

     If the marker does **not** name this round, do not read that as "nothing
     to review" either. An empty carry means the previous round found **zero
     blockers**, and such a round is either full — which would have CONVERGED
     and ended the run — or a delta round, for which the loop *writes* the
     marker. So in a healthy run the marker naming this round is the only
     reachable state: its absence means it was lost after that round was
     recorded, or the `--resume` adoption clamp ignored it (a resume passing a
     smaller `--max-rounds` than the run that wrote it, or an unreadable
     marker — the loop says so on stderr). **Recover, don't stop**: restore
     `<work-dir>/.closing-sweep` holding this round's number, or re-invoke with
     the `--max-rounds` the marker was written under, and re-plan the round with
     `--final`. Stop only when you cannot establish that the previous round was
     a zero-blocker delta round. The loop's own refusal message names the same
     recovery — never invent a code change just to move the tree.

   Two carries ride in the plan from round 2 on, and the reviewers must be
   **told about both** — they are the point of the delta, not decoration:

   - **`fix_verification_path`** — the previous round's blockers. Each
     reviewer's first job is to confirm those fixes actually landed, before
     looking for anything new. **Say what to do when one did not:** a fix that
     did not land, or that the reviewer cannot confirm landed, must be
     **re-raised at its original severity**, citing the carried entry, *even
     when its file is outside this round's delta* — a delta round cannot
     re-derive it, so silence here converges the run with the blocker unfixed.
     **And tell each reviewer to report how many carried entries it confirmed
     landed** — on any round whose carry is non-empty, whatever it writes to the
     findings file, `[]` or otherwise. Step 2 refuses a round that does not
     account for every carried entry, so asking for the count belongs to the
     dispatch, not to the recovery.

     **You get one count per reviewer, and the round's count is their UNION.**
     A carried entry is confirmed when **at least one** reviewer says so; the
     round's count is `|union| of M`. A reviewer silent about the carry
     contributes zero confirmations — it does **not** fail the round on its own,
     since the entry may be outside its dimension. What fails the round is a
     carried entry that no reviewer confirmed **and** no reviewer re-raised.
   - **`adjudicated_path`** — suggestions earlier rounds already surfaced and
     the human already waived. **Do not re-raise them as Suggestions — except
     in a file the PREVIOUS ROUND'S FIX PASS touched**, where new code has just
     been written and a same-titled observation may be genuinely new. Key it on
     the fix pass, not on the round's scope: on a **delta** round the two are
     the same set, and on a **closing full sweep that NO fix pass
     preceded** (the zero-blocker promotion) the fix-touched set is empty — so
     there, withhold every waived suggestion. On a sweep the RESIDUE promotion
     earned, a fix pass did run, so the exemption applies as on any round.
     That exemption is an *instruction*, not a footnote: in
     step mode the panel reads `adjudicated.json` as the previous round left it,
     before the loop drops the entries whose file the fix pass touched, so a
     reviewer that withholds one there kills a finding nothing downstream can
     restore. And if one is genuinely *blocking* on this round's code, raise it
     at `CRITICAL`/`WARNING` and say what changed — a re-raise above Suggestion
     level is never suppressed, and withholding it would converge the run with a
     Critical nobody reported.
<!-- /moved: round-protocol-tail -->
