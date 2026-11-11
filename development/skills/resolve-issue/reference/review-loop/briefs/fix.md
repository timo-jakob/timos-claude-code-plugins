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

**Check the acceptance criteria before you park (#3074).** When the handoff's
`acceptance_criteria_file` is not `null`, read it before parking any finding:
it holds the story's acceptance criteria and its `story-spec/v1` block. A
blocker whose surface an acceptance criterion names is applied, never parked —
that is rule 1's first override. List every finding you park in the verdict's
`parked` array as `{issue, ac_check}`: `issue` is its follow-up's number, and
`ac_check` is `checked` when you read the file, or `no-ac-file` when the field
is `null`.

**Parked follow-ups carry their origin (#2581).** When you park a finding and
file its follow-up, also post one origin comment on that issue. Write the parked
finding's identity — its changelist entry's `file`, `line`, `dimension` and
`title`, verbatim, plus this round's number as `round` — to a JSON file outside
the worktree, and render the comment:

```bash
"<skill-base-dir>/scripts/follow-up-origin.zsh" render --kind parked-finding \
  --repo <owner/name> --source <story> --finding <file>
```

Take `--repo` from `gh repo view --json nameWithOwner -q .nameWithOwner`, run in
`worktree_root`. Take `--source` from the branch name, which
`/development:git-branch-naming` fixes as `<type>/<N>-<slug>`: run
`git -C <worktree_root> rev-parse --abbrev-ref HEAD` and use the digits after
the first `/`. When the branch does not have that shape, post no origin comment
and write the parked note as
`- parked: <title> (no origin: branch <name>) -> #<issue>`; never guess a
number. Otherwise post the render output as a comment on the issue you just
filed, with no `--pr`:
the PR does not exist yet, and SKILL.md §6 adds it once it opens. Post it once,
when the issue is filed — a later round that reuses the number posts nothing.
An exit 2 is your own malformed identity: fix the file and re-run. The comment
is how #2588 reads, by machine, which story and which finding the follow-up
came from.

On either trigger, apply `grant.severity_bar` when a grant is set, the human's
`guidance`, rule 2's collapse as **mandatory** when `rule2_mandatory` is `true`
(advisory otherwise, *The third histogram state* in
`<skill-base-dir>/reference/review-loop/carry.md`), and the profile's *Fix-pass
rules* when the prompt carries them. Then write a `fix` verdict with
`round-handoff.zsh write-verdict --work-dir <work_dir>`: `ok` with
`fix_applied`, `files_changed` (the number of distinct files you edited) and
`parked`, or
`failed` / `cannot-fix` with `fix_applied: false` and `files_changed: 0` when
you could not fix it, and `parked: []`. Return to the conductor only that the verdict was written.
