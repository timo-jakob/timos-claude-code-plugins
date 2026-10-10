# Strictly sequential epics

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it
at the start of the Epic flow, before E1, never on a single-issue run.

## Strictly sequential mode

**Read the mode once, before E1.** Run

```bash
"<skill-base-dir>/scripts/strictly-sequential.zsh"
```

It prints `on` or `off` from the `epic_strictly_sequential` environment
variable, which the human sets in the `env` block of their Claude Code settings
exactly like `switch_fable_to_opus` (`1`, `true`, `yes`, `on` in any case are
on; unset and anything else are off). Say which mode the run is in — one line,
e.g. "epic mode: strictly sequential (`epic_strictly_sequential` is on)" — so a
mistyped value shows up as the wrong mode rather than silently.

**`off`** is the Epic flow as SKILL.md writes it; nothing below applies.
**`on`** is a run a human can leave unattended and trust: slower, with no
re-work and nothing running out of sight. It changes three things and nothing
else, and where SKILL.md or `reference/review-loop.md` disagree with them in
this mode, this file governs:

- **E3 resolves every child sequentially, in this session.** The
  provably-disjoint set is not parallelised: no parallel sub-agents, no second
  worktree. Every child joins E3's *everything else* chain, one at a time: the
  first child branches with step 1's script as any run does; every later child
  waits until the previous child's PR is **merged**, then branches with the same
  script plus `--after <merge commit>`, which pulls main and refuses (exit 4) to
  branch until main holds that commit. On exit 4, run the script again once the
  merge has reached `origin` — never branch the child any other way.
- **Every review-loop round boundary is serial, with the gate in the
  foreground** — below.
- **Every PR-check wait is a foreground call.** Waiting on a PR's checks runs
  `await-pr-checks.zsh --timeout 540 <pr>` as an ordinary Bash call with the
  tool's largest timeout; on its exit 3 (not yet settled) issue the same call
  again, up to the script's default 30-minute budget in total, and treat a
  timeout after that as a real one. Never a `run_in_background` poll, a
  `Monitor`, or a detached process. Under the `override=on` exception
  (SKILL.md §6), `merge-pr-cycle.zsh --timeout 540 <pr>` waits the same way:
  re-issued on its exit 3 within the same 30-minute total, and only a timeout
  after that is §6's human-only stop. §6's re-read until `MERGED` needs no
  splitting: it is already at most 30 foreground calls, one `gh pr view` each.

Unchanged in both modes: E1b still gates **every** child and builds nothing
unless all are `READY`; the review panel, the E1b readiness gates and the other
agents stay ordinary sub-agents, visible in the session; a human-only repo still
stops after opening each sequential child's PR, unless
`development/scripts/approval/plugin-approver-override.zsh` reports
`override=on` (the `CLAUDE_PLUGIN_APPROVER=1` exception, SKILL.md §6's
approve-and-advance path); and headless `claude` is never used.

### The round boundary — gate first, in the foreground

Every round boundary of every child takes **the serial boundary** that
`reference/review-loop/core.md` describes for a suite that writes into the tree —
whatever the suite does — and the gate is **never launched out of band**:

- **Run `<full gate>` as one ordinary foreground Bash call**, with the tool's
  largest timeout, and read its exit status (and `run-gate.zsh`'s JSON summary
  where `<full gate>` is `run-gate.zsh`) from that call. Nothing is detached by
  you: no `setpgrp` wrapper, no `nohup`, no `&`, no `run_in_background`, no
  `Monitor`. The round protocol's step 2 launch properties and step 4 wait do
  not apply, and step 3's "stop the gate" has nothing to stop, because the gate
  has returned before the panel is planned.
- **A gate that outlives the call.** Claude Code moves a foreground command
  that reaches its timeout into its own tracked background task, which stays
  visible in the session and notifies you when it exits. That is still the one
  gate you started: **end the turn**, and read its output when the completion
  notification arrives. Never start a second gate beside it, and never
  re-launch it in the background yourself. A gate that is killed or interrupted
  without a verdict is the round protocol's *signal never arrived*: neither
  green nor red — **report and stop**.
- **Then mint `T`**, once the gate has returned, and dispatch the panel against
  it. Consolidate by the round protocol's step 5 arms, exactly as the serial
  boundary does.
- **A red gate** is step 6, fixed before any panel is dispatched — so no panel
  findings are ever discarded in this mode.

The cost is the `min(gate, panel)` per round that #1497's overlap buys back.
That is the trade the human chose: a run that takes longer and has nothing
running out of sight.
