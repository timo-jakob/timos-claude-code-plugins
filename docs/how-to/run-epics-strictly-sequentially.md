# Run epics strictly sequentially

When `/development:resolve-issue` works on an epic, it normally resolves
children that touch completely separate files in parallel, each in its own
worktree. It also runs each review round's test gate as a separate process
beside the reviewer panel. Both save time. But they also mean work is running
outside the session you are watching, and parallel children can still end up
needing re-work.

If you would rather hand an epic over and leave it, overnight for example,
turn on strictly sequential mode with one environment variable. The run is
slower, but every child is resolved one at a time and nothing runs outside
the session.

## Turn it on

Add the variable to your settings:

```json title="~/.claude/settings.json"
{
  "env": {
    "epic_strictly_sequential": "1"
  }
}
```

That is the whole procedure. The skill reads the variable once, when an epic
run starts, and says which mode it is in, for example "epic mode: strictly
sequential". If it does not appear to take effect, restart the session: the
tools a session runs inherit their environment from the running Claude Code
process.

## Turn it off

Set it to `"0"`, set it to `""`, or remove the key.

| Value | State |
| ----- | ----- |
| unset, `""` | off (the default) |
| `1`, `true`, `yes`, `on` (any case) | **on** |
| anything else | off |

Unrecognised values are off, the same as
[`switch_fable_to_opus`](switch-fable-agents-to-opus.md). The run tells you
which mode it read, so check that line if you set the variable and still see
parallel work.

## What changes when it is on

- **One child at a time.** Every child, including the ones that could have run
  in parallel, is resolved in the session itself. Each child after the first
  waits until the previous child's PR has merged, pulls the latest `main`, and
  refuses to branch until that `main` contains the merge. So every PR starts
  from the work before it and needs no rebase later.
- **The test gate runs in the foreground.** Each review round runs the full
  test gate first and waits for it before the reviewers start. Nothing is left
  running in a process you cannot see. If the gate runs longer than one tool
  call allows, Claude Code keeps it as a tracked task in the session and the run
  waits for it; a second gate is never started beside it.
- **Waiting for CI is in the foreground too.** The run waits on each PR's
  checks with ordinary, visible calls.

What does **not** change: an epic is still only started when every child passes
the readiness gate. The reviewers and other agents still run as normal
sub-agents, which you can watch in the session. On a repo where a human
approves PRs, the run still stops after opening each child's PR and continues
when you run it again after the merge.
