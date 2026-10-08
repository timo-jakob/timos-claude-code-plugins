<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     round step 2, the loop invocation, up to its recovery arms. -->
<!-- The frozen chunk below continues the round protocol's numbered list at
     item 2, so its numbering cannot restart at 1 here. -->
<!-- markdownlint-disable MD029 -->

<!-- moved: round-protocol-step-2 -->
2. **One loop invocation.**

   ```bash
   "<skill-base-dir>/scripts/resolve-story-loop.zsh" --repo <repo> --base <base> \
     --work-dir <work-dir> --status-file <status.json> --issue <N> \
     --findings-file <findings-round-R.json> \
     --test-cmd '<full gate>' [--resume] [--gate-attest <T>] \
     [--findings-tree <T>]
   ```

   **`--findings-tree` on EVERY step-mode invocation — round 1 included.** It is
   the identity your panel READ, and it is what arms the cadence guard (step 3
   states the invariant and the failure it prevents). Omitting it is not an
   error — the guard is fail-quiet — which is exactly why it has to be in the
   template: a run that leaves it out has the rail silently off while looking
   identical to one that does not.

   **Round 1 is the round that needs it most, not least.** A fresh round is a
   FULL round, where zero blockers *is* the `CONVERGED` condition — so a session
   that runs the panel, edits, then invokes would exit 0 and open the PR on a
   review of a tree that no longer exists. There is no `--resume` there to hang
   the habit on, which is precisely why it is stated here:

   ```bash
   T=<the round boundary's single guarded mint, §3.5 step 1>
   # …start the gate, run round 1's panel, write findings-round-1.json…
   resolve-story-loop.zsh … --findings-file <…> --findings-tree "$T" \
     --gate-attest "$T"   # plugin repos only — omit on any other stack
   ```

   `T` is the round boundary's single mint (above), not a second one, and it
   is minted through that step's fail-closed guard rather than bare. Re-pass
   the SAME value unchanged when recovering from a
   **findings-file** refusal (missing/empty, byte-identical, alias): nothing
   moved the tree there, so the held identity still matches. **On the CADENCE
   refusal it depends which recovery you take**, because the tree is what moved:
   if you **re-run the panel**, the held value can never clear it — mint a FRESH
   identity before that panel runs. If instead you **discard the fix** that moved
   the tree, the tree is back to what the panel read, so re-pass the SAME held
   value and mint nothing (minting there would be the self-attestation banned
   below). See that arm in the list below.

   **Never mint it just before the `--resume`.** An identity computed after the
   panel — or after a fix pass — matches the working tree trivially and turns the
   guard into a self-attestation that certifies nothing, defeating it on the one
   ordering it exists to catch. Mint it *before* the gate and the panel start,
   and hold it. This is the same trap `--gate-attest` names for the gate, and the
   reason both flags carry one `T`.

   `<full gate>` is the same whole-suite command as Step 3. On a **plugin repo**
   that is the blessed single-run parallel gate — `--test-cmd 'zsh
   <skill-base-dir>/scripts/run-gate.zsh --tests-dir tests'` (#980) — never a
   bare `bats` invocation that a later step would re-run to count.

   `--resume` from round 2 on. On a `--resume` invocation the loop runs
   `--test-cmd` — the **full** suite (unit **and** integration), never a
   subset (#604) — FIRST, deterministically gating the previous round's
   in-session fix: red exits `ERROR` (1), the same "red after a fix aborts"
   rule as ever — **unless** a matching `--gate-attest` (below) proves that run
   redundant, in which case the loop skips it (and only it).

   **`--gate-attest` — one full-gate run per round, not two (#981).** On a
   `--resume` the session has *just* run the full gate green in Step 3 (right
   after applying the previous round's fix). Passing the `tree` identity from
   that green `run-gate.zsh` (Step 3, above) as `--gate-attest <T>` lets the
   loop **skip** its own `--test-cmd` run **when — and only when — that identity
   still exactly matches the working tree**, killing the byte-identical
   duplicate that dominated the #976 session (~24 min). It is strictly
   **fail-closed**: a mismatch (the tree changed since the attestation), an
   empty/absent value, or an uncomputable current identity all run `--test-cmd`
   exactly as before — the gate itself never weakens, this removes only a
   provably-redundant re-run.

   Four rules keep it honest — break any and the loop either re-runs the gate
   (safe) or, worse, skips a gate it should not (a false green):

   - **Only when `--test-cmd` *is* the attested `run-gate.zsh`.** The `tree`
     field exists only on **plugin repos** (it is `run-gate.zsh` stdout). On a
     `pytest` / `gradle` / other stack there is **no** attestation to pass —
     **omit `--gate-attest` entirely** and let the loop run the gate. Never
     synthesize an identity yourself (e.g. calling `git-tree-id.zsh` right
     before `--resume`): a resume-time identity trivially matches the loop's
     resume-time computation, turning the check into a vacuous self-attestation
     that skips a gate that never ran. The attestation must come from the actual
     green gate, or not at all. The round boundary's `T` is not synthesis: it is
     minted *before* the gate starts and is passed only once that gate has
     reported **green on that same `T`**, so it carries the gate's own verdict
     rather than a resume-time recomputation. Likewise pass it only when `--test-cmd` runs the
     **same** `run-gate.zsh` you gated with — a broader/compound `--test-cmd`
     would be skipped whole on a tree match, including parts the attested run
     never executed.
   - **Capture the attestation from the *green* gate, and don't edit after.**
     The panel is read-only, so a tree that only the review agents have touched
     (i.e. read) is unchanged and still matches — but **you** must not touch the
     tree between the green Step-3 gate and the `--resume`. If you did edit anything (or you
     can't be sure), re-run the gate to get a fresh `tree` **or** omit
     `--gate-attest` — never pass the stale one. (Passing it is not *unsafe* —
     the loop just re-runs on the mismatch — but it wastes the round's point.)
   - **Keep `--work-dir` and every `findings-round-R.json` OUTSIDE the repo**
     (or on a git-ignored path). The identity hashes tracked **and** untracked,
     non-ignored files, so a findings file or work-dir written *inside* the repo
     changes the tree every round and defeats every match. Put them under a
     scratch dir outside the worktree, exactly as the C4 step (§3) writes
     `detect.json` outside the repo.
   - **The one blind spot: git-ignored files.** The identity honors
     `.gitignore`, so a change confined to an *ignored* test-relevant file is
     the single edit class a match cannot catch. In these repos ignored paths
     are build artifacts the suite never reads, so this is theoretical — but if
     you knowingly change an ignored file the tests read, re-run the gate.

   **Write each round's findings to its own path** (`findings-round-R.json` —
   hence the `R`), and pass that round's path. On a `--resume` round the loop
   refuses several shapes of "this round was never really reviewed" as
   **`STALE_FINDINGS` (exit 2, #974, #1434, #1435)** — a *recoverable* usage
   error, not a verdict. Named rather than counted, because this list has grown
   twice and both times a tally elsewhere went stale: some are about the findings
   **file** you passed, one about the tree the round is **scoped against**, one
   about the tree your **panel read**, and one about a **full** round whose panel
   produced no findings file. The empty-delta, full-round and cadence shapes are
   not `--resume`-only — they fire in hook mode too:

   - the file is **missing or empty** — a panel that found nothing still writes
     `[]`, so silence is never read as a clean round (that would converge the
     loop on an unreviewed round and green-light the PR);
   - its content is **byte-identical to the round just consumed** — a stale
     path re-passed, or the new round's file never written. Consumed, it would
     read as a blocker surviving two rounds and trip a phantom
     `ESCALATE_NO_CONVERGENCE`. **One exception (#1434):** the promoted closing
     full sweep is exempt when the round before it **looked at something and
     found nothing** — all three facts (a recorded sweep, that round's findings
     being `[]`, and its scope having been non-empty), because `[]` twice
     running is the expected shape there and refusing it would make convergence
     unreachable. You never have to work around this arm: a round whose panel
     saw *nothing* records no digest at all, so it cannot refuse its successor
     either. **Never hand-edit findings to make the bytes differ** — see the
     recovery rules below;
   - `--findings-file` **IS** the round's own dispatch `findings_path` — you
     aimed at the internal sink the loop truncates. It is refused up front, so
     your panel output was never destroyed; it is simply at the wrong path;
   - the round's **delta is empty and nothing is carried** to verify (#1434) —
     nothing has changed since a round that **left no blockers to verify** (its
     `verify-<R>.json` is `[]`; that round may still have logged Suggestions). This one is
     **not** a re-run-the-panel case: a re-invocation recomputes the same empty
     delta and refuses again. **Recover per the empty-delta arm below** —
     restore the closing-sweep marker the previous round earned, or re-invoke
     under the `--max-rounds` it was written under (step 1 sets out why the
     marker is the reachable state). Stop only when you cannot establish that
     the previous round was a zero-blocker delta round, and never invent a code
     change just to move the tree.
     (An empty delta *with* a carry is **not** refused — it is a
     verification-only round; see step 1 for how to scope it.)
   - the **`--findings-tree` you attested disagrees with the working tree** on a
     reviewable file (#1435) — the panel read one tree and you are consolidating
     against another, so these findings describe a tree that no longer exists.
     This is the cadence invariant of step 3 being enforced rather than trusted,
     and it is **not** a re-pass case: what moved is the tree, not the file.
     **Recover by re-running this round's panel against the current tree** and
     passing its aggregate with a freshly minted `--findings-tree`, or by
     discarding the fix that moved the tree and re-consolidating what the panel
     actually read. The stderr names both identities and the files that moved.

<!-- /moved: round-protocol-step-2 -->

**Every loop invocation carries the run's `loop_args` (#1226).** The invocation
template in step 2 above predates story-mode telemetry and sits in a byte-frozen
span, so this is recorded here: append the run's `loop_args` (Step 0,
`reference/telemetry.md`) to it — round 1 and every `--resume` alike. They are
`--parent-run-id <the run's run_id>` plus exactly the sink flags the run was
given, so every loop record is parented to the run and lands in its sink.
When `start` failed there is no run file: pass only the sink flags from the
`args` output, with no `--parent-run-id`. An epic child that E3 drives passes its
own child run's `loop_args` (`reference/epic-telemetry.md` step 2).

**Time every round subagent, and pass the times (#2197).** For each round, read
`date +%s` when you dispatch the panel, decide, risk and fix subagents and again
when you observe each one's verdict. A step the round dispatched more than once
— the stall retry, a recovery arm's second panel or decide — is the sum of its
dispatches, each measured from dispatch to verdict. The fix that counts is the
fix pass that preceded this round, so round 1 has none; an awaiting-fix pass
and a gate-red pass that both preceded it sum the same way. Write the
differences as one JSON object, `{"panel": s, "decide": s, "risk": s, "fix": s}`,
in whole seconds, with `null` for a step that did not run or was not timed. Keep
the file outside the repo, beside the round's findings file, and pass it on the
invocation that consolidates the round as `--step-timings <file>`. Rewrite it
before any re-invoke that followed a re-dispatch; re-pass it unchanged only when
nothing was re-dispatched. The loop records it as that round's
`history[].step_wall_s`, which `estimate-step.zsh` reads to build priors. It is
telemetry only: a file the loop cannot use costs a stderr note and nulls, never
the round.
