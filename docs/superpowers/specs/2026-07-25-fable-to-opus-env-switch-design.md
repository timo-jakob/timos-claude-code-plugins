# `switch_fable_to_opus` — env-gated fable→opus agent dispatch

**Date:** 2026-07-25
**Status:** Design approved; awaiting implementation plan
**Provenance:** live probe of the local install — `claude` 2.1.220 binary strings,
`GET /api/oauth/usage` response, `~/.claude/plugins/cache/` layout, and the documented
`PreToolUse` / `settings.env` contracts (both verified against code.claude.com docs)

## Motivation

Fable is metered as its own scoped weekly bucket, separate from the shared pools. A live
probe of `/api/oauth/usage` on the maintainer's seat returned:

```json
{ "kind": "weekly_scoped", "percent": 97, "severity": "critical", "is_active": true,
  "scope": { "model": { "display_name": "Fable" } },
  "resets_at": "2026-07-26T17:00:00Z" }
```

When that bucket runs dry, every agent declaring `model: fable` fails. Today the only
remedy is `scripts/toggle-fable.zsh off` (#990, #996), which rewrites the frontmatter of
32 agent files in the repo worktree. That works for local development but does **not**
affect the installed plugins a session actually dispatches from
(`~/.claude/plugins/cache/`), and it produces a dirty worktree that must be reverted.

This design adds a **runtime** switch: one environment variable that redirects fable-declaring
agents to opus at dispatch time, without touching a single file.

## Scope

A `PreToolUse` hook on the `Agent` tool, shipped in the **`development`** plugin (which
already owns a `hooks.json`). When `switch_fable_to_opus` is truthy, any agent whose
definition declares `model: fable` is dispatched on **opus** instead.

### Non-goals

Explicitly **not** in this change — each was considered and cut:

- **No usage-API reading.** No `GET /api/oauth/usage`, no percentage thresholds, no
  hysteresis band, no state file, no polling, no automatic switch-back.
- **No credential access.** Nothing reads the OAuth token from Keychain. This is the single
  most important non-goal: it is what makes the feature safe to ship to every installer.
- **No configuration surface.** No thresholds, no fallback-chain table, no config file. One
  variable, one behaviour.
- **No change to `toggle-fable.zsh`.** Re-pointing #990 at this variable is a clean
  follow-up, deliberately deferred so the hook lands and is proven first.

The maintainer flips the variable by hand. That is accepted, not a limitation to be
designed around.

## Why a hook rather than `CLAUDE_CODE_SUBAGENT_MODEL`

`CLAUDE_CODE_SUBAGENT_MODEL` exists (confirmed in the 2.1.220 binary) and overrides both
the per-invocation `model` parameter and the agent's frontmatter — one variable for the
whole session. It is nonetheless the wrong mechanism here, because it overrides **every**
subagent, not just the fable ones.

The current fleet is 97 agents:

| declared model | count | effect of a blanket `=opus` override |
| -------------- | ----: | ------------------------------------ |
| `opus`         |    55 | no change                            |
| `fable`        |    32 | **intended** — the whole point       |
| `haiku`        |     8 | **promoted to opus — spends more**   |
| `sonnet`       |     2 | **promoted to opus — spends more**   |

Promoting 10 cheap agents to opus while trying to conserve budget is a direct
counter-incentive. The hook touches only the 32 agents that actually declare fable.

## Design

### Component

One script, `development/hooks/switch-fable-to-opus.zsh`, registered as a `PreToolUse`
hook with matcher `Agent` in the existing `development/hooks/hooks.json`.

### Control flow

```text
PreToolUse(Agent)
  │
  ├─ $switch_fable_to_opus not truthy  ──► exit 0, emit nothing   (the common path)
  │
  ├─ parse tool_input.subagent_type and tool_input.model
  │
  ├─ resolve the agent's declared model from its definition file
  │
  ├─ declared model is not fable, and the call did not explicitly
  │  pass model:"fable"          ──────► exit 0, emit nothing
  │
  └─ otherwise ──► emit updatedInput with model:"opus"
```

The environment check happens **before** stdin is read and before `jq` is invoked, so a
user who never enables the feature pays one process spawn and nothing else.

### Output contract

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "updatedInput": { "...tool_input": "verbatim", "model": "opus" },
    "additionalContext": "switch_fable_to_opus is set — go-bug-hunter dispatched on opus instead of fable"
  }
}
```

`updatedInput` must carry **every** original key of `tool_input` unchanged, with only
`model` set or replaced. `permissionDecision` is deliberately **omitted** — see Risks.

### Truthiness

| value                          | state |
| ------------------------------ | ----- |
| `1`, `true`, `yes` (any case)  | on    |
| unset, `""`, `0`, `false`      | off   |
| any other value                | off   |

Treating `""` as off is load-bearing, not defensive padding: the settings documentation
states that a variable set to `""` *"still"* reaches subprocesses. A naive "is the variable
present?" test would therefore read an explicitly-emptied variable as **on**, which is
exactly backwards. Unrecognised values are off so that a typo fails safe.

### Resolving an agent's declared model

`subagent_type` arrives plugin-qualified (e.g. `development-go:go-bug-hunter`), so the
owning plugin is known and resolution is a glob rather than a search. Two layouts must both
resolve, anchored on `$CLAUDE_PLUGIN_ROOT`:

```text
installed      $CLAUDE_PLUGIN_ROOT/../../development-go/0.8.0/agents/go-bug-hunter.md
--plugin-dir   $CLAUDE_PLUGIN_ROOT/../development-go/agents/go-bug-hunter.md
```

- The **versioned** form is mandatory because the plugin cache is version-pinned. A path
  hard-coded to today's version breaks silently on the next release — silently being the
  operative risk, since the failure mode is "no switching" rather than an error.
- The **flat** form is mandatory because `/development-claude-plugin:test` loads local
  plugins via `--plugin-dir`, and this hook must be testable that way.
- If several version directories match, the lexically-greatest is used.
- An unqualified `subagent_type` falls back to a wildcard across sibling plugins; if that
  matches more than one file it is treated as unresolvable (see Failure posture). Bare names
  do collide across plugins — `development-swift:bug-hunter` versus
  `development-go:go-bug-hunter` — so guessing is not acceptable.

Anchoring on `$CLAUDE_PLUGIN_ROOT` also confines the feature to this marketplace at no extra
cost: a fable agent belonging to an unrelated plugin is left alone, which matches the
intent of "the agents in this repo."

Frontmatter parsing reuses the `frontmatter_model` awk from `scripts/toggle-fable.zsh`
verbatim. It already handles the two cases that matter — a file with no proper frontmatter
(no `---` on line 1, or no closing fence) yields nothing, and a prose `model:` in the body
is invisible because parsing stops at the closing fence.

### Failure posture

Every error path exits 0 and emits nothing, so the agent runs exactly as declared:

- `jq` not on `PATH`
- agent definition file not found
- file present but no frontmatter `model:` line
- an unqualified `subagent_type` matching multiple plugins
- malformed hook stdin

A broken hook therefore degrades to *"no switching"* — never to *"wrong model everywhere."*
This mirrors the failure posture already chosen for the surrounding tooling: no signal means
status quo.

## Relationship to `toggle-fable.zsh` (#990)

The two remain independent and non-conflicting because they act on different things: the
script rewrites frontmatter in the repo worktree, the variable changes runtime dispatch. An
agent already rewritten to `model: opus` by the script is simply not fable, so the hook
ignores it — the mechanisms compose rather than fight.

Re-pointing the script at this variable (writing settings rather than rewriting 32 files) is
a deliberate follow-up, out of scope here.

## Testing

bats, following the existing `tests/*.bats` convention, driving the script with synthetic
hook stdin and asserting the emitted JSON:

| case                                                  | expected                                |
| ----------------------------------------------------- | --------------------------------------- |
| variable unset                                        | no output, exit 0                       |
| variable `""`                                         | no output, exit 0                       |
| variable `0` / `false` / unrecognised                 | no output, exit 0                       |
| on + fable-declaring agent                            | `updatedInput.model == "opus"`          |
| on + opus / haiku / sonnet agent                      | no output, exit 0                       |
| on + call explicitly passing `model: "fable"`         | `updatedInput.model == "opus"`          |
| on + unknown `subagent_type`                          | no output, exit 0                       |
| on + agent file with no frontmatter                   | no output, exit 0                       |
| on + ambiguous unqualified name                       | no output, exit 0                       |
| on + fable agent, versioned layout                    | resolves                                |
| on + fable agent, flat `--plugin-dir` layout          | resolves                                |
| on + fable agent with extra `tool_input` keys         | all keys preserved byte-identically     |

The "all keys preserved" case is the one that protects against the worst plausible bug:
`updatedInput` replaces the tool arguments wholesale, so a dropped key silently changes what
the agent is asked to do.

The script must also be shellcheck-clean and pass `zsh -n`, per the repo's script-quality
gate.

## Risks and open questions

1. **`updatedInput` without `permissionDecision` is unverified.** The documented schema lists
   both fields, but not whether input rewriting is honoured when no decision is returned.
   Returning `"allow"` would work but would suppress the user's normal Agent permission
   prompts as a side effect, which is unacceptable. **The first implementation step is a
   throwaway hook proving the model actually changes with no decision field set.** If it
   turns out a decision is required, the design needs revisiting — `"defer"` is the candidate,
   and it must be confirmed that defer preserves normal permission behaviour.
2. **Every `development` user pays a process spawn per agent dispatch**, even with the feature
   off, because hooks cannot be conditionally registered. Measured on the maintainer's machine
   (macOS, arm64): 50 spawns of an early-exit zsh script in 0.766 s, i.e. **~15 ms each**, so a
   16-agent fan-out pays roughly 245 ms. Judged acceptable, but it is a real and permanent tax
   on users who will never enable this, and it is three times the figure originally estimated
   from intuition — worth re-measuring if the hook ever grows work before its exit.
3. **The variable name is unconventional.** `switch_fable_to_opus` is lowercase where
   environment variables are conventionally upper-case, and unnamespaced where the ecosystem
   uses `CLAUDE_CODE_*`. Chosen deliberately for readability in `settings.json`; noted here so
   the choice is explicit rather than accidental.
4. **A stale plugin cache means stale model declarations.** The hook reads the *installed*
   agent definitions, so an agent whose declared model changed in the repo but has not been
   reinstalled resolves to the old value. This is correct behaviour — the installed definition
   is what actually dispatches — but it can surprise during local development.

## Enablement

```jsonc
// ~/.claude/settings.json
{
  "env": {
    "switch_fable_to_opus": "1"
  }
}
```

Setting it to `"0"`, `""`, or removing the key restores fable dispatch. The change takes
effect for subsequently spawned hook processes; no session restart is needed.

## Deliverables

- `development/hooks/switch-fable-to-opus.zsh`
- `PreToolUse` / `Agent` entry in `development/hooks/hooks.json`
- `tests/switch-fable-to-opus.bats`
- Documentation page wired into mkdocs nav (a new page is invisible without a nav entry)
- `development/.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` version bump in
  lockstep, without which no installer ever receives the hook
