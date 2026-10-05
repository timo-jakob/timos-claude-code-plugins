<!-- Shard of reference/interactive.md (#2058), read in its index's order:
     the #1226, #1576 and #1583 amendments to the extension's step 5. -->

**A granted resume carries the run's `loop_args` too (#1226).** The resume
invocation in step 5 (`reference/interactive/extension-grant.md`) predates
story-mode telemetry and sits in a byte-frozen span, so this is recorded here:
append the run's `loop_args` (Step 0, `reference/telemetry.md`) to it, so the
post-grant record is parented to the same resolve-issue run and lands in the
same sink as the escalation it follows.

**The granted ceiling is written to the work-dir, not remembered (#1576).** Step
5 (`reference/interactive/extension-grant.md`) says "ceiling raised by 3", and
for a long time nothing enforced it: the number lived only in this session's
memory, across a context that compacts. It is now mechanical.

**Run it exactly ONCE per grant** — at the moment the human grants, before the
resume that spends it. That includes a **guidance-only** answer: step 4
(`reference/interactive/extension.md`) makes guidance an implied grant and
routes it here, so it persists a ceiling like any other:

```bash
"<skill-base-dir>/scripts/record-grant.zsh" --work-dir <same-work-dir> \
  --status <status.json> --add 3
```

**Once per GRANT, not once per `--resume`.** Step 5
(`reference/interactive/extension-grant.md`) reaches a `--resume` on three other
paths after a single grant — the `AWAITING_FIX` (20) continuation, the
`STALE_FINDINGS` (2) recovery re-invoke, and a red gate that restarts the
granted round's boundary. None of them is a new grant, and the same rule the
`grants` counter already follows applies here: they neither increment nor
decrement it, and they must **not** re-run this script. They cannot, in general,
be made harmless by re-running it: the base compounds off the existing sidecar,
so a second `--add 3` on one grant silently funds three rounds the human never
gave and the step-6 soft cap (`reference/interactive/extension-grant.md`) never
sees them. Re-run it only when the human grants **again**, which is exactly when
compounding is what you want.

It writes `<work-dir>/.max-rounds` and echoes the new ceiling, computing it from
the **status JSON** rather than from your memory — so a granted closing sweep's
extra round (#1434) is already counted, and a later grant compounds off the
first.

**The file and the flag do NOT always agree, and the file is the one that is
right.** The script adds the increment to the ceiling **actually in force**
(`effective_max_rounds`), not to the flag. On a run whose closing sweep was
granted its extra round that is one *higher* than step 5's `prev_max + 3`
(`reference/interactive/extension-grant.md`). Still pass
`--max-rounds <prev_max + 3>`: the higher of the two wins, so the flag can only
ever raise the ceiling further (a human going beyond the grant), never lower it. Never "repair" a
`.max-rounds` that disagrees with the number you passed. It usually **equals**
what you passed, and is **one higher** on a run whose closing sweep was granted
its extra round — both are ordinary, and neither is the stale-sidecar hazard.

**This supersedes step 5's "buys only two" on a granted closing sweep**
(`reference/interactive/extension-grant.md`). That **frozen** sentence was
written when the ceiling was whatever `--max-rounds` you typed, so the #1434
sweep round was silently deducted from the grant (ARCHITECTURE.md and the
explanation page said the same and have since been corrected; only the frozen
text still reads the old way). It is no longer: a grant after a granted closing
sweep buys **three**, like any other exit.

Do not compute the remainder from your own arithmetic — and mind **which**
number you read, because step 5 (`reference/interactive/extension-grant.md`)
owes the human that figure *at the grant*, before any resume has run. **Before
the resume**, the remainder is `record-grant.zsh`'s **echoed** ceiling minus the
rounds already run; the status JSON on disk at that moment is the
*escalation's*, whose `effective_max_rounds` is the ceiling from **before** the
grant, so subtracting from it reports zero (or one) rounds bought. **After the
resume**, re-read `effective_max_rounds` from the new status JSON and correct
the figure if it differs.

**Neither the write nor the adoption is guaranteed — verify, and never halt on
either.** `record-grant.zsh` exits non-zero on a bad invocation (2) or an
unusable status JSON / failed write (1), and the loop's reader does not take
every sidecar at face value either — both of its loud arms are non-fatal, and
they end **differently**:

- a sidecar that is **not a bounded integer** is refused and the flag wins
  (`ignoring an unreadable max-rounds sidecar …`);
- a sidecar **beyond `--max-rounds + MAX_ROUNDS_SIDECAR_SLACK`** (16 today) is
  **clamped to that cap and ADOPTED** (`clamping a max-rounds sidecar beyond the
  soft cap … using <cap>`). Read that line as *the ceiling is higher than the
  flag but lower than the file asked for* — **not** as a lost grant. Do not
  re-run `record-grant.zsh` over it (the once-per-grant rule above), and do not
  hand-raise `--max-rounds` to "fix" it.

Both are non-fatal by design — losing a grant
costs one re-grant, while halting wastes the human's — so **neither ever halts
the granted resume**.

`record-grant.zsh` has a third, **successful** outcome worth knowing: when the
new ceiling would exceed the loop's soft cap it clamps, says so on stderr, and
exits **0** having written the clamped value. Its cap is computed from the
status JSON's `max_rounds`, while the loop's is computed from the `--max-rounds`
you pass, so the two can differ by what you raised the flag to — which is one
more reason to report the ceiling you read back rather than the one you asked
for.

Take the code's own branch, in order:

- **Exit 2** — your own malformed call. **Fix the invocation and re-run the
  script before resuming**, exactly as everywhere else in this skill. Only if it
  fails again, fall through to the exit-1 handling. Skipping the re-run over a
  fixable typo throws the grant back into a context that compacts, which is the
  #1558 loss the script exists to prevent.
- **Exit 1** — the ceiling was not recorded and re-running will not change that.
  Report it in one line and resume with an **explicit** ceiling. That ceiling is
  the status JSON's `effective_max_rounds + 3`, **not** `prev_max + 3`: on a run
  whose closing sweep was granted its extra round the two differ by one, and the
  flag alone would under-fund the grant by exactly the round this story stopped
  deducting. Fall back to `prev_max + 3` only when `effective_max_rounds` is
  unreadable. Report the remainder from **that** explicit ceiling — there is no
  echoed value to read on this path.

**Then verify by the NUMBER, not by the source.** After the resume, the grant is
in force when `effective_max_rounds` is at least `record-grant.zsh`'s **echoed**
ceiling (on the exit-1 path, the explicit ceiling you passed instead).
`max_rounds_source` only says **where** that ceiling came from, and `flag` is the
**ordinary** answer on a successful grant: you passed `prev_max + 3` and the
sidecar holds the same value, so the flag wins the tie and the grant is in force
regardless. Reading `flag` as "refused" would have you report a failure on the
modal success — and invite a second `record-grant.zsh` run, which the once-per-
grant rule above forbids. Report the ceiling you read back, never the one you
asked for.

The loop's status JSON reports the result in `effective_max_rounds` (the ceiling
actually in force) and `max_rounds_source` (`flag` or `work-dir`).
**`max_rounds` still reports what you passed** — the same split #1434 made for
`closing_sweep_granted`, so the `+3`/`grants` bookkeeping of step 5 and the soft
cap of step 6 (`reference/interactive/extension-grant.md`) and the escalation
summary all keep reading exactly the number they read before.

**A granted resume is a carried round — pass the carry accounting (#1583).**
Step 5's granted-resume template (`reference/interactive/extension-grant.md`)
and the `STALE_FINDINGS` recovery re-invoke it points at predate #1583. Since
then a step-mode `--resume` whose `verify-<R>.json` is non-empty is refused —
exit 2, `STALE_FINDINGS`, the CARRY-UNACCOUNTED arm — unless
`--carry-accounting <carry-round-R.json>` is passed, and a granted round
**always** carries entries:
the terminal round it extends still held blockers, which is what was escalated.
So read both invocations as carrying `--carry-accounting <carry-round-R.json>`,
assembled from the granted round's panel exactly as on any other carried round,
per `reference/review-loop/carry.md` § *Carry accounting — confirmed, re-raised,
unconfirmed (#1583)* — which also governs the refusal's recovery. Omitting it
burns the grant on a refusal round-trip: the loop consolidates the granted
round, then refuses it before `verify-<R+1>.json` is written, and the human's
grant has bought nothing until the re-invoke.
