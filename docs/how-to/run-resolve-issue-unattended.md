# Run resolve-issue unattended

`/development:resolve-issue` asks you before it takes some decisions: whether to
clear a blocker first, whether to build an oversized story as one change,
whether to grant the review loop more rounds, which waived suggestions to
promote. It decides whether you are there to ask by inference. When you invoke
the skill yourself, it assumes you are present.

If you start a long run and leave, overnight for example, that inference is
wrong, and the run stops at the first question and waits until morning. Set one
environment variable to tell it that nobody is there.

## Turn it on

Add the variable to your settings:

```json title="~/.claude/settings.json"
{
  "env": {
    "resolve_session": "unattended"
  }
}
```

The skill reads the variable at the start of every run you launch on a single
issue (not an epic) and says which mode it is in and where that came from, for
example "session mode: unattended (from `resolve_session`)". If it does not
appear to take effect, restart the session: the tools a session runs inherit
their environment from the running Claude Code process.

## Turn it off

Remove the key, or set it to `""`, to go back to the inference. Set it to
`"attended"` to say a human is present.

| Value | Mode |
| ----- | ---- |
| unset, `""` | inferred, as before this setting existed |
| `attended` (any case) | **attended** |
| `unattended` (any case) | **unattended** |
| anything else | inferred, and the run warns that the value was ignored |

A mistyped value does not switch the mode silently. The run names the value it
ignored, so check that line if you set the variable and the run still stops to
ask you something.

## What changes when it is unattended

Every branch of a single-issue run that would ask you follows the setting:
`attended` asks, and `unattended` takes the arm the skill already takes when
nobody is present. For example, when the story is blocked by an open
dependency, `attended` offers to resolve the blocker first, and `unattended`
comments on the story and adds the `blocked` label instead. The same holds for
the size pre-flight's override, the extra review rounds after an escalation,
the options for a review that did not apply, and suggestion promotion. The
run's telemetry
record carries the mode and its source (`session_mode`, `session_mode_source`).

## When an unattended run cannot finish

An unattended run that spends its review rounds without converging first takes
extra rounds automatically, but only when the rounds so far show it is getting
there. When they do not — the blockers are not falling, one is stuck, a
Critical is still open, or the extra rounds are used up — the run **stops
cleanly**:

- it opens no PR, so `main` stays untouched;
- it pushes its branch and comments on the issue, naming why it stopped and the
  blockers that remain, and adds the `needs-human-decision` label;
- it keeps the review's state in `~/.claude/resolve-issue/<repo>/<issue>/`,
  outside every checkout, so the next session can find it.

To continue it, run this in a session where you are present:

```text
/development:resolve-issue <issue> --resume
```

The run checks out the pushed branch and picks up from the last round. It then
asks you what to do next: grant more rounds, give guidance, or stop. `--resume`
is refused in an unattended session, and when no stopped run is kept for that
issue. A plain re-run without `--resume` starts over.
