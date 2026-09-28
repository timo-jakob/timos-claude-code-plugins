# Turn off suggestion prompts after the review loop converges

When `/development:resolve-issue` runs with you present, its
[local review loop](../explanation/review-loop.md) stops once it converges and
shows you every suggestion it waived, so you can
[promote some of them](../explanation/review-loop.md#promoting-a-suggestion) to
blocking. That stop needs you to answer before the run carries on to the PR.

If you would rather the run never stop there, turn the offer off with one
environment variable. Every suggestion is then waived, as it already is on an
unattended run, and the run goes straight on to open the PR.

## Turn it off

Add the variable to your settings:

```json title="~/.claude/settings.json"
{
  "env": {
    "enable_suggestions": "0"
  }
}
```

That is the whole procedure. The skill reads the variable at the moment the
loop converges, so a new setting should apply to the next run. If it does not
appear to take effect, restart the session: the tools a session runs inherit
their environment from the running Claude Code process.

## Turn it back on

Set it to `"1"`, set it to `""`, or remove the key. Any of the three restores
the prompt.

| Value | State |
| ----- | ----- |
| unset, `""` | **on** (the default) |
| `0`, `false`, `no`, `off` (any case) | off |
| anything else | **on** |

Unrecognised values are on by design, which is the reverse of
[`switch_fable_to_opus`](switch-fable-agents-to-opus.md). Each switch fails
towards its own default, so a typo here keeps the prompt rather than silently
waiving suggestions you meant to see.

## What changes when it is off

- **No prompt.** A converged run shows no suggestion list and asks nothing. It
  says in one line that promotion was skipped and how many suggestions were
  waived, then carries on.
- **Nothing is promoted.** Suggestions stay logged and non-blocking. They still
  appear under *Waived suggestions* in the PR's review dossier.
- **No promotion telemetry.** The `suggestion_promotion` record is written only
  when you were actually asked, so a run with the setting off writes none. That
  is the same as an unattended run.

What does **not** change: the review loop itself. Blockers still block, every
round still runs the full test gate, and a run that does not converge still
stops and asks you, just as before. The setting only removes the stop that comes
after convergence.
