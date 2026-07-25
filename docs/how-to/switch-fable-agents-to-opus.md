# Switch fable agents to opus when the fable budget runs out

Fable is metered as its own weekly bucket, separate from the shared pools. When
that bucket runs dry, every agent in this family that declares `model: fable`
fails — and that is 32 of the 97 agents, including reviewers the
[local review loop](../explanation/review-loop.md) depends on.

The `development` plugin ships a runtime switch for exactly this: set one
environment variable and those agents dispatch on **opus** instead. No files are
edited, nothing is left to revert.

## Turn it on

Add the variable to your settings:

```json title="~/.claude/settings.json"
{
  "env": {
    "switch_fable_to_opus": "1"
  }
}
```

That is the whole procedure. The variable is read by each hook process as it is
spawned, so a new setting should apply to subsequent agent dispatches. If it
does not appear to take effect, restart the session — hook processes inherit
their environment from the running Claude Code process, and how a mid-session
edit of `settings.json` propagates is not something this page has verified.

## Turn it off

Set it to `"0"`, set it to `""`, or remove the key. Any of the three restores
normal fable dispatch.

| Value | State |
| ----- | ----- |
| `1`, `true`, `yes` (any case) | **on** |
| unset, `""`, `0`, `false` | off |
| anything else | off |

Unrecognised values are off on purpose, so a typo fails safe rather than
silently changing which model your agents run on. `""` is off for a less obvious
reason: a variable set to the empty string *still* reaches subprocesses, so
treating "the variable exists" as "on" would read an explicitly-emptied variable
as enabled — exactly backwards.

## What it does and does not touch

It redirects **only** the agents that would actually have run on fable:

- an agent whose definition declares `model: fable` → dispatched on opus;
- a call that explicitly passes `model: "fable"` → dispatched on opus, even if
  the agent itself declares something else;
- a fable-declaring agent called with an explicit `model: "haiku"` → **left
  alone**. That call was never going to use fable, and promoting it to opus
  would cost more than doing nothing.

Put the other way round: a dispatch whose **effective** model is `opus`, `haiku`,
or `sonnet` is never touched. Note this is about the effective model, not the
declared one — an `opus`-declaring agent called with an explicit `model: "fable"`
*is* rewritten, because that call really would have hit the fable bucket.

This is the reason the feature is a hook rather than the built-in
`CLAUDE_CODE_SUBAGENT_MODEL`, which overrides *every* subagent: with a fleet of
55 opus / 32 fable / 8 haiku / 2 sonnet, a blanket `=opus` would promote 10 cheap
agents to opus while you were trying to conserve budget.

**Marketplace scope applies to the frontmatter path only.** When the call passes
no `model`, the hook reads the agent's declared model from *this* marketplace's
installed plugins, so a fable agent belonging to an unrelated plugin is left
alone. When the call passes `model: "fable"` explicitly, no lookup is needed or
performed, and the redirect applies whoever owns the agent — deliberately, since
the goal is to keep the call off a drained bucket regardless of its origin.

## How it works

A `PreToolUse` hook on the `Agent` tool
(`development/hooks/switch-fable-to-opus.zsh`) inspects each dispatch, takes the
call's `model` when it passes one and otherwise resolves the agent's declared
model from its installed definition, and rewrites the model to `opus` when that
effective model would have been fable.

When the variable is not truthy the hook exits before reading its input or
invoking `jq`, so the cost with the feature off is one process spawn per agent
dispatch (~15 ms on an M-series Mac).

!!! note "It reads the *installed* definitions"
    The hook resolves agents from the installed plugin cache, which is what a
    session actually dispatches from. During local plugin development an agent
    whose declared model changed in your working copy but has not been
    reinstalled will still resolve to the old value. The exception is running
    the plugins straight from a checkout (`--plugin-dir`): there the hook reads
    that checkout, so working-copy changes take effect immediately.

### If it does not seem to be doing anything

Every failure path is deliberately silent: a missing `jq`, an agent definition
that cannot be resolved unambiguously, a definition with no frontmatter, or a
malformed payload all cause the hook to do nothing and let the dispatch proceed
exactly as declared. A broken hook degrades to *no switching*, never to *the
wrong model everywhere*.

So if agents are still failing on fable, check in this order: the variable's
value is one of the truthy forms above; `jq` is on `PATH`; the plugin cache is
current (`/plugin` → update); and, if all three look right, restart the session
so the hook processes are spawned with a freshly-read environment.

If all four check out and dispatches are *still* landing on fable, please open an
issue. The redirect ultimately rests on the Agent tool's `model` parameter
selecting the model — that is the step to verify first. Note the
`toggle-fable.zsh` fallback described below only helps if you run these plugins
**from a checkout** (`--plugin-dir`, or the plugin test harness); it rewrites the
working tree, so it does nothing for plugins installed from the marketplace cache.

## Relationship to `toggle-fable.zsh`

The repo also has [`scripts/toggle-fable.zsh`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/scripts/toggle-fable.zsh),
which rewrites `model:` frontmatter across the agent files in a checkout. The two
are independent and do not conflict — the script edits files in the repo working
tree, the variable changes runtime dispatch from the installed cache. An agent
the script has already rewritten to `model: opus` simply is not fable, so the
hook ignores it.

Use the variable when you want your *sessions* to keep working; use the script
when you want the *repo* to declare something different.
