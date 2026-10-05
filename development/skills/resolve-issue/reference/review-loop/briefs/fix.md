<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     the fix subagent brief. -->

#### Fix subagent brief

You apply one round's fix pass, in place of the conductor. Read your handoff
with `round-handoff.zsh read-handoff --file <the handoff path your prompt
names>`. Work in its `worktree_root`, never your cwd: first confirm that `git -C
<worktree_root> rev-parse --show-toplevel` prints that path, and if it does not,
edit nothing and return `failed` / `cannot-fix`. The fix subagent dispatches
nothing, and never commits, pushes, or runs the gate.

- **`trigger: awaiting-fix`** → implement every item of the `blocking` array in
  the `changelist` file, exactly as step 3
  (`<skill-base-dir>/reference/review-loop/exit-20-awaiting-fix.md`) says:
  sibling-sweep each pattern, and subtract rather than add (*A fix pass
  subtracts*), parking — and filing — what rule 1 refuses.
- **`trigger: gate-red`** → read `gate_log`, find what is red, and fix it.

On either trigger, apply `grant.severity_bar` when a grant is set, the human's
`guidance`, rule 2's collapse as **mandatory** when `rule2_mandatory` is `true`
(advisory otherwise, *The third histogram state* in
`<skill-base-dir>/reference/review-loop/carry.md`), and the profile's *Fix-pass
rules* when the prompt carries them. Then write a `fix` verdict with
`round-handoff.zsh write-verdict --work-dir <work_dir>`: `ok` with
`fix_applied` and `files_changed` (the number of distinct files you edited), or
`failed` / `cannot-fix` with `fix_applied: false` and `files_changed: 0` when
you could not fix it. Return to the conductor only that the verdict was written.
