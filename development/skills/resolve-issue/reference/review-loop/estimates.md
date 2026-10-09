<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     narrating long waits with a sourced estimate. -->

### Narrating long waits — a sourced estimate or none (#2198)

A round's waits are long and vary widely: the whole-suite gate takes minutes to
most of an hour depending on how many gates share the CPUs (#1798), and a panel
can take as long. Before each one, tell the human how long it is likely to take
— so they can decide whether to step away, free CPU or stop the run — but only
with a figure that has a source. A reported number is reliable or withheld.

**Which waits.** The gate, panel, decide, risk and fix steps, every time the
round protocol dispatches them, closing-sweep and promotion-sub-loop rounds
included. No other wait is covered, and there is no time threshold: a short
wait is narrated like a long one.

**What to print.** Run `<skill-base-dir>/scripts/narrate-estimate.zsh` and print
its one stdout line verbatim — no paraphrase, no rounding, nothing added. The
line is sourced because its only sources are gate-eta.zsh and
estimate-step.zsh, and the conductor never states an unsourced figure: not "~10 min", not an estimate carried over from an
earlier round, not one worked out from the progress block. When the line says
`no estimate (no data)`, say exactly that.

```bash
"<skill-base-dir>/scripts/narrate-estimate.zsh" --step panel|decide|risk|fix \
  [--repo-type <repo_type>] [--sink <the run's sink>]
"<skill-base-dir>/scripts/narrate-estimate.zsh" --step gate \
  --gate-log <work-dir>/gate-<R>.stderr [--repo-type <repo_type>] [--sink <the run's sink>]
```

**Its inputs.**

- `--gate-log` is the round gate's captured stderr. When you launch the gate
  out of band — at step 2 (*The round boundary is concurrent*), or before the
  serial boundary's mint — also write `run-gate.zsh`'s
  stderr to `<work-dir>/gate-<R>.stderr` — separately from its stdout, which
  carries the JSON summary step 5 reads, and outside the repo like everything
  else the launch writes; that file is `--gate-log`. When `<full gate>` is not
  `run-gate.zsh`, there is no such log: the gate's line is the literal
  `estimate for gate: no estimate (no data)`, printed without running the
  script.
- A gate run as one foreground Bash call has no such log either. That is every
  round boundary in strictly sequential mode (`reference/sequential.md`), and a
  serial boundary (`reference/review-loop/core.md`) whose gate is run in the
  foreground. Immediately before the call, print the literal
  `estimate for gate: no estimate (no data)` without running the script. The
  number is withheld on purpose: before the call there is no scope or job share
  to scale a prior to.
- `--repo-type` is §1b's `repo_type`. Omit it when §1b did not run or exited 3.
- `--sink` is the file the run's loop records land in: the run's
  `telemetry_file`, else `<telemetry_dir>/<repo-slug>.jsonl`, else
  `<repo-dir>/.claude/telemetry/telemetry.jsonl`.

**When to print it.** Panel, decide, risk and fix are narrated once,
immediately before their dispatch. A gate launched out of band is narrated
once immediately after its launch, before the panel is planned; once more
before step 4's wait when the panel returned in the same turn; and once more in
each later turn the conductor is woken in anyway while the gate's completion
signal is absent. A gate run as a foreground call is narrated once, immediately
before the call, and never again: not when it returns, and not when a gate that
outlived its call notifies its exit.
Never schedule a wake-up or poll in order to re-narrate: the round protocol's
end-the-turn wait (#1513) still governs, and a narration is never a reason to
hold a turn open.

A non-zero exit from the script is its own usage error, a call you built
wrong: fix the call and run it again. It never stops the round, and it never
licenses a figure of your own in place of the line.
