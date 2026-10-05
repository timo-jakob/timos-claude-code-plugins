<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     selected gates for delta rounds and the delta-round test bar. -->

### Selected gates for delta rounds (#1973)

The byte-frozen span says the loop's `--resume` gate is "the **full** suite
(unit **and** integration), never a subset (#604)", and the boundary's step 2
starts "the same `<full gate>` command §3 runs". **The first stays true**: the
loop's own `--test-cmd` is always the full `run-gate.zsh`, in every round, and
hook mode never selects. What #1973 amends, for **intermediate (delta) review
rounds only**, is the gate *the session* starts at a delta round's boundary —
the #979 and #604 guardrails, both. **This section governs wherever the text
above names the gate a boundary starts or the attestation it holds and
disagrees with it**: the round protocol's opening paragraph (its whole-suite
sentence), the boundary's steps 2, 5 and 7, the *No fix pass ran since the last
boundary* bullet, the invariant paragraph's cadence recovery, and step 3's
`AWAITING_FIX` hand-off, which names the full gate.

**Only one gate shape can select: a plugin repo whose `<full gate>` is
`run-gate.zsh` alone** — step 5's first arm. `--select-base` is a `run-gate.zsh`
flag and nothing else's. Every other stack, a **compound** `<full gate>`
(`run-gate.zsh` plus anything else as one command) and a gate whose suite
writes into the tree start their `<full gate>` unchanged before every round, as
the text above says; nothing in this section applies to them.

**One rule: a gate's scope is the `scope_mode` of the round it precedes.** Only
a delta round's gate is `selected`:

1. **Round 1** — §3's gate, the full `run-gate.zsh`. Never selected.
2. **A boundary into a delta round** — any round ≥ 2 that is **not** the closing
   sweep, including rounds a human grant bought and possible-false-trip
   continuations — **starts `<full gate>` with `--select-base <base>` appended**
   (`<base>` is the loop's `--base`). This is the default, not an option: it
   runs only the bats files `select-tests.zsh` maps the story diff to, plus the
   always-run set, and falls back to the whole suite by itself whenever the
   selection cannot be trusted.
3. **A boundary into the closing sweep** — the round `<work-dir>/.closing-sweep`
   names, the grant beyond the ceiling included — starts the **full** gate. That
   includes the sweep a zero-blocker delta round promotes **whenever the
   attestation held from that round is `selected:`**: there the *No fix pass
   ran since the last boundary* exemption does **not** apply, because no full
   gate has proved this tree. Mint `T` and start the full gate beside the
   sweep's panel exactly as steps 1–4 say; a red is step 6's (fix, restart the
   boundary), and a green consolidates with its own bare `tree` **and its
   summary as `--gate-summary`** — the tree has not moved, so that bare id
   equals the selected one, and the summary (green, `"scope":"full"`, that
   tree) is how the loop tells a full run from a rebuilt copy. Only when the
   held attestation is already a full run's bare id does that sweep skip the
   gate, as before.
4. **The loop's own `--test-cmd`** stays `<full gate>` — the full `run-gate.zsh`
   — in the invocation template, every round. Never pass `--select-base` there.

**The held attestation is the gate's reported `tree`, exactly as printed.** For
a selected run that is `selected:` followed by the hex — keep the prefix and
never rebuild the value from `T`, which would claim a full run. That holds at
step 5 and wherever the text above re-passes a *held* attestation: the
findings-file recovery re-invokes and the cadence recovery (the zero-blocker
promotion after a selected gate starts a full gate instead, item 3). (The loop
also remembers every selected identity it accepted and runs
its own full gate when a bare copy of it reaches the closing sweep — unless a
`--gate-summary` proves a green full run on that tree, as item 3's does — but
that is the backstop, not the procedure.) `--findings-tree` stays the bare `T`.

**Steps 5 and 7, for a selected run.** Its summary reports `"scope":"selected"`.
Compare the hex after the `selected:` prefix with `T`: equal and green is step
5's plugin-repo arm, consolidating with the whole reported value as
`--gate-attest`; a different hex is step 7's drift. A `--select-base` run whose
summary says `"scope":"full"` means the selector fell back — it ran the whole
suite, and its bare `tree` is an ordinary full attestation. The loop accepts a
`selected:` attestation **only on a `--resume` into a delta round**; into a
full-scope round it runs `--test-cmd`, so a selected gate can never stand in for
the full one before a round that may open a PR.

**`--gate-summary` — the gate's timings, and item 3's proof of a full run.** It is one more flag
on step 2's invocation template (which sits in the byte-frozen span): save the
gate's JSON summary outside the repo, beside the findings files, and pass it as
`--gate-summary <file>` on the invocation that consolidates the round **that
gate** preceded — round 1's included. **Pass it only when this boundary started
a gate.** A boundary that skipped the gate (a zero-blocker promotion held on a
full run's attestation, the findings-file recovery re-invokes) omits it, so no
round is credited with another round's gate; a re-invoke of the same round
re-passes that round's own file. The loop records the summary's `scope`,
`wall_s` and 10 slowest files as that round's `history[].gate` (`attested:
true`); when the loop ran its own gate instead, that run's summary is recorded
(`attested: false`). It never decides a skip on its own; its one effect on the
gate is item 3's — proving a full run lifts the loop's selected-run backstop.

**Why this is safe.** A selector that misses a dependency lets a regression
surface one round late — at the closing sweep's full gate, as an ordinary red
that step 6 fixes — never in a PR: every round that can end the run
(`CONVERGED`, `CONVERGED_WITH_RESIDUE`) is a full-scope round, and the gate
before it is full. (The loop's own refusal of a selected attestation into the
sweep is the backstop for a session that skipped item 3's gate; its red there
exits `ERROR`, which is why item 3 starts the gate rather than relying on it.)

### The delta-round test bar — fix-pass hunks (#2011)

On a **delta** round the claude-plugin test reviewer reviews at a lower bar for
what the previous fix pass just wrote. An untested branch or an unpinned
sentence inside a range that fix pass **added** is a `SUGGESTION`, not a
`WARNING`; one inside a range that rewrote or removed prior-tree lines keeps
full severity. The rule itself — its hunk-shape exception, the fix-introduced
sentence test and its two fail-closed clauses — lives in that agent's mutation
bar and is not restated here.

**Where the ranges come from.** `review-dispatch.zsh plan` emits `delta_hunks`
whenever it is given `--prior-tree` — the same condition as `delta_files`, and
`null` without it: one `{file, kind, start, end}` entry per new-side range of
the fix pass's diff, `kind` `"added"` or `"changed"`, pure deletions omitted.
The claude-plugin review skill's Step 1 adds a `Fix-pass hunks (delta round):`
line to every reviewer prompt **only when the plan's `scope_mode` is
`"delta"`**. Both are contracts every caller of the panel already reads, so the
rule behaves the same whether the conductor or the panel subagent dispatches it,
and nothing in this file's round protocol changes. Hook mode hands the panel no
descriptor, so no hunk list reaches it and the rule never applies there.

**Round 1 and every full round keep today's bar.** A closing sweep plans with
`--prior-tree`, so its descriptor carries a hunk list, but its `scope_mode` is
`"full"`, so no reviewer is handed one — and that includes the sweep a residue
promotion earned.

**No acceptance-criteria exception exists, by design.** The panel is never
handed the issue text, so no reviewer could apply one. A fix-introduced gap on
behaviour the acceptance criteria name is still caught at the full bar by the
closing full sweep, before any PR opens, at the cost of at most one more round.
A demoted finding stays reported, so the promotion phase can still raise it.
