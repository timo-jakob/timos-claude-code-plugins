<!-- Shard of reference/promotion.md (#2057), read in its index's order:
     step 8 of the promotion phase, plus the #1226 sinks and #1935 subagent
     notes. -->
<!-- The frozen chunk below continues the phase's numbered list at item 8, so
     its numbering cannot restart at 1 here. -->
<!-- markdownlint-disable MD029 -->

<!-- moved: suggestion-promotion-step-8 -->
8. **Keep BOTH status files — the dossier covers both phases (#1064).** The
   phase leaves a second status JSON, and §6 merges the two into the **one**
   section and **one** hidden `<!-- review-dossier: … -->` block the Approver
   parses (#563), by passing the promotion pair alongside the blocking-phase
   `--status`:

   ```bash
   "<skill-base-dir>/scripts/build-dossier.zsh" --status <blocking-status.json> \
     --promotion-status <promotion-status.json> --promoted <promoted.json>
   ```

   So keep all three paths: the blocking-phase status, the promotion-phase
   status, and the promote file. **Append its output exactly once** — never two
   hidden blocks in one body, or the Approver reads only the first — and
   **never hand-edit its output**. The rule is about *appended output*, not
   processes: a wrong-form run whose output was never appended is discarded and
   the correct invocation re-run (open-pr owns that recovery); one already
   appended means stop and report.

   The two promotion flags are an **atomic pair**: passing one without the other
   is a usage error (exit 2), never a silent fall back to a blocking-only
   dossier. Pass them exactly when **a promotion-phase status JSON that THIS run
   wrote and did not discard exists** — and not otherwise. Stated as the artifact
   rather than as "the phase ran", but note the two qualifiers, because a bare
   "a file is at that path" would be wrong twice over: the scratch dir is reused
   within a session, so an earlier story can leave one there (step 4's `rm -f`
   before every invocation is exactly what makes its later existence a signal —
   step 7's **LEFTOVER** rule), and step 7's discard branch abandons a phantom
   status that must never be passed either. Neither hazard is a terminal and
   neither prescribes a dossier form: a **LEFTOVER** means report and stop
   (step 7) — no PR, so no invocation at all — and after a **discard** it is the
   re-invoked sub-loop's own status, never the discarded file, that this
   condition tests. With that settled, the two terminals differ:

   - the *If NONE matched* terminal (step 4) **never invokes** the sub-loop, so
     there is no promotion status to pass → the plain `--status` invocation;
   - the **not-reproducible** terminal (step 7) *did* invoke it — a full round 1
     that wrote a `CONVERGED` status — so **pass the pair**. The dossier then
     records `selected: N, promoted: 0`, which is the honest shape: the human
     picked N and the engine raised none. Dropping the pair here would discard a
     real phase's rounds and the pick count, which is exactly the record #1064
     exists to preserve.

   The merged dossier drops a promoted-and-fixed item from the waived list and
   from the per-dimension suggestion counts, and carries a
   `promotion: {rounds, status, selected, promoted}` object — so the waived list
   no longer contradicts what the run did. §6 still owns the Summary's count
   contract (both counts plus step 4's unmatched / unverified split); what it no
   longer needs is the "dossier covers the blocking phase only" caveat.

   **On a non-zero exit, do not open the PR without the dossier.** The script
   prints nothing on stdout when it fails, so an unchecked invocation is
   indistinguishable from the legitimate "no loop ran" no-op — the silent-loss
   failure its own validation exists to prevent. Check the status: **2** is a
   usage error (a broken atomic pair, a flag missing its value) and **1** an
   input error (a status that is not one JSON object, a `null`-holding or
   two-object scratch file, a wrong-shaped promote file); stderr names the
   offending flag and file in both cases. Fix what it names and re-run. Treat
   **empty output at exit 0** the same way whenever the loop is known to have run
   a round — it means `--status` points at the wrong file.

   If what stderr names **cannot be restored** — a kept status or promote file
   lost or clobbered after convergence — **report in the conversation and stop**:
   no PR. Never reconstruct a status or promote file by hand to satisfy the
   command; the dossier is an audit record, and a hand-built input fabricates
   exactly the history it exists to attest.
<!-- /moved: suggestion-promotion-step-8 -->

**The sub-loop and the enrichment now forward the run's sinks (#1226).** Two
statements in the frozen span predate story-mode telemetry — the moved blocks of
`reference/promotion/gate.md`, `reference/promotion/step-3-select.md`,
`reference/promotion/step-4-sub-loop.md`, `reference/promotion/step-7-terminal.md`
and this file — and that span is byte-frozen, so the correction is recorded here
rather than edited into it.

- **Every sub-loop invocation also carries the run's `loop_args`** (Step 0,
  `reference/telemetry.md`): `--parent-run-id <the run's run_id>` plus exactly
  the `--telemetry-file` / `--telemetry-dir` the run was given — round 1, each
  `--resume`, and each recovery re-invoke alike. The step 4 invocation in
  `reference/promotion/step-4-sub-loop.md` shows neither. Without them the promotion record is unparented, and under a
  sink flag it lands in a different sink from the run's other records. When
  `start` failed there is no run file: pass only the sink flags from the `args`
  output, with no `--parent-run-id`.
- **The loop does have a `--telemetry-dir` now.** Step 3's
  (`reference/promotion/step-3-select.md`) "the loop has no
  `--telemetry-dir` of its own, so the enrichment must not pass one either" is
  therefore reversed, by the same mirroring rule it states: pass the
  enrichment the same `--telemetry-file` **and** the same `--telemetry-dir`
  the loop was given, and the two records share a sink. The enrichment itself
  takes **no** `--parent-run-id`: it stays joined to the loop record it enriches
  by that record's `run_id`, and through it to the resolve-issue run.

**The sub-loop's rounds dispatch the same panel and fix subagents (#1935).** The
frozen span — the five shards' moved blocks, named in the note above — has the
conductor run each sub-loop round's panel and fix pass itself. Like the blocking
phase's rounds, they are now dispatched as the
**panel**, **decide**, **risk** and **fix** subagents, through the same handoff and
verdict files:
`reference/review-loop/subagents.md` § *Round subagents — the conductor reads only
verdicts (#1935)* governs. The seed procedure and its step-7 verification stay
with the conductor — one of that section's two named exceptions. On sub-loop
round 1, `<pre-seed-round-1.json>` is the panel verdict's
`aggregate_findings_file`, `<promotion-work-dir>/findings-round-1.json` — inside
the work-dir, not at a path of its own, so the decide handoff can name it — and
the seeded file — not the verdict's path — is what that round passes as
`--findings-file`. The decide subagent runs over `<pre-seed-round-1.json>` first: build the seeded file
(step 3) only after an `ok` decide verdict, from the decided file. The decide
pass's atomic rewrite is the one overwrite step 1 permits — it changes stamps
and severities only, never a finding's `file`, `dimension` or line, so step 2
classifies against a baseline that is still valid.
