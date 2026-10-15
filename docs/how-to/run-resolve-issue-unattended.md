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

Today the setting decides the dependency precheck at the start of a run on a
single issue. When the story is blocked by an open dependency, `attended` offers
to resolve the blocker first, and `unattended` comments on the story and adds the
`blocked` label instead. The other branches that ask you follow the setting
once #2583 points them at it. The run's telemetry
record carries the mode and its source (`session_mode`, `session_mode_source`).
