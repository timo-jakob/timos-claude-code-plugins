<!-- Shard of reference/promotion.md (#2057), read in its index's order:
     step 7 of the promotion phase, the terminal and the sub-loop's exits. -->
<!-- The frozen chunk below continues the phase's numbered list at item 7, so
     its numbering cannot restart at 1 here. -->
<!-- markdownlint-disable MD029 -->

<!-- moved: suggestion-promotion-step-7 -->
7. **Terminal.** The sub-loop clearing the promoted set is the run's final
   `CONVERGED` → continue to **§4 (Version bump)**, taking the **residue branch**
   first when the blocking phase ended `CONVERGED_WITH_RESIDUE` (it is ordered
   immediately before §4). If the sub-loop **cannot**
   clear the promoted set — blockers still open when the budget runs out — it
   escalates through the existing taxonomy and the existing interactive
   extension: the human opted into making those items blocking, so they are
   treated as blocking, not quietly re-waived.

   **`CONVERGED_WITH_RESIDUE` (exit 14) is UNREACHABLE here, by construction.**
   The loop never declares residue while a promoted set is in effect (#1435):
   these blockers are the human's own picks, raised from Low because they said
   "actually, do that one", and #994 contracts them as *treated as blocking, not
   quietly re-waived* — which is exactly what residue would do, filing the
   human's explicit request back to them as a follow-up issue. So this phase ends
   only in the arms above. If you somehow see exit 14 from the sub-loop, that is
   a defect in the loop, not a verdict: report it and stop.

   **Every exit the sub-loop can produce is covered**: 0 and 10-13 by the arms
   above, 14 by the paragraph above, 20 by the §3.5 round protocol, and 1/2 by
   the taxonomy below. **Any OTHER exit** is unhandled — report it in the
   conversation and stop, rather than mapping it onto the nearest arm.

   **A round-1 `CONVERGED` with
   a non-empty matched set is not a verdict yet** — first check that round 1's
   `--findings-file` was the file built by **step 4's ordered procedure, item 3**
   (the pre-seed aggregate plus any still-present-but-unraised keys — identical
   to the pre-seed aggregate when nothing needed seeding) and that `--promote`
   was passed. The two answers lead opposite ways:

   - **Either was wrong** → this `CONVERGED` is an artifact of the slip, not a
     result. **Discard it**, fix the invocation, and re-invoke as a **fresh
     round 1** (a new `--work-dir` and `--status-file`, never `--resume`, which
     would run the seeded findings as round 2 against the phantom round's
     changelist). **Report nothing as not-reproducible** — nothing has been
     tested yet. Never re-invoke unchanged more than once.
   - **Both were correct** → the engine legitimately raised nothing, most likely
     because dedup kept a representative whose title is fully disjoint from the
     promoted keys. **Note what this proves: ZERO keys were raised**, since any
     raise would have produced a blocker and an `AWAITING_FIX`. So treat the
     **entire** matched set as not-reproducible — never just the one key you
     suspect — report every one of them in the Summary as
     promoted-but-not-reproducible, converge with **nothing** promoted, and
     continue to **§4 (Version bump)** — via the **residue branch** first when
     the blocking phase ended `CONVERGED_WITH_RESIDUE`, exactly as the other two
     terminals of this phase do. Every path out of this phase passes that branch
     or the story ships with its remainder unfiled and §6 with no numbers to
     name.

   **Neither exit 1 nor exit 2 is an escalation or a convergence here.** Both
   have several causes, so read the status file and stderr before acting —
   and **delete the status file immediately before each sub-loop invocation**,
   so "a status JSON exists afterwards" is an unambiguous signal rather than a
   guess about whether the file is this round's or the last one's.

   - **exit 2, `status: "STALE_FINDINGS"`** → the §3.5 *Each round* step-2
     refusal: recover
     by cause and re-invoke (re-passing `--promote`). Not a bad command line.
   - **exit 2, no status JSON written** → a genuine usage error in the
     invocation. **Stderr names the offending argument**: a missing, empty,
     non-file or wrong-shaped `--promote` path, a persisted promote path that
     has since vanished or been rewritten badly, a `--max-rounds` at or below
     the resumed round, or `--promote` passed together with `--no-review`. Fix the command and re-invoke.
   - **On an exit 1 or 2 whose pre-invocation delete was NOT verified**, any
     status JSON found is a **LEFTOVER** — the previous invocation's, because
     the delete above failed or was skipped. **The content test only works when the
     pre-invocation delete provably succeeded** — verify the path is absent
     (`[[ ! -e <promotion-status.json> ]]`) before invoking, and then any status
     found afterwards is provably this invocation's. If absence was **not**
     verified, the taxonomy is unreliable for *every* status, `STALE_FINDINGS`
     and `ERROR` included: a skipped delete can leave the previous
     invocation's refusal or red gate behind, and the cross-matched
     combinations (exit 2 over a leftover `ERROR`, exit 1 over a leftover
     `STALE_FINDINGS`) match no branch at all. Treat them all as leftovers.
     (Under a **verified-absent** delete the reverse holds, and it is keyed on
     the **write contract**, not on the status shape: exit 2 writes only
     `STALE_FINDINGS` or nothing, exit 1 only `ERROR` or nothing. So **any**
     freshly-written pairing those rules forbid — a neither-status, but equally
     exit 1 over a `STALE_FINDINGS` or exit 2 over an `ERROR` — is an **engine
     anomaly**, never a previous invocation's verdict, and never the
     same-status branch keyed to the other exit code. The action is the same,
     report and stop — the repoint-and-re-invoke option below applies only to a
     **LEFTOVER** (a stale path); re-invoking cannot fix an engine that just
     violated its write contract. Exit 0 and exits 20 / 10-13
     always write their own status, so they are never in question.)
     A **LEFTOVER** is never this invocation's verdict, and
     the delete discipline that makes the taxonomy readable has broken:
     **report the leftover in the conversation and stop** — or repoint
     `--status-file` at a fresh, deletable path (step 4) before any re-invoke.
     Do **not** take the "no status JSON written" branches' fix-and-re-invoke
     handling: re-invoking without clearing the stale file leaves the next
     exit's taxonomy just as unreadable, which is the hazard this rule exists
     to prevent. Reading a leftover round-1 `CONVERGED` as this exit's result
     would converge the promotion phase on a run that actually failed.
     **Exits 20 and 10-13 are not covered by this rule**: each always writes its
     own status, so that status *is* this invocation's verdict — take the round
     protocol (`AWAITING_FIX`) or the escalation branch, never this one.
   - **exit 1** → an operational failure, and **not necessarily the promote
     file**. A freshly written `status: "ERROR"` is a **red gate after the
     previous round's fix** — follow §3's rule (fix the gate, or abandon and
     report), never rewrite the promote file and never build an escalation
     comment from it. With **no** status JSON, stderr names the cause:
     `consolidate failed at round N` may be the promote file's contents *or* an
     invalid round-findings aggregate; a dispatch failure is neither. Fix what
     stderr names and re-invoke; if stderr names nothing you can act on, report
     in the conversation and stop.
<!-- /moved: suggestion-promotion-step-7 -->
