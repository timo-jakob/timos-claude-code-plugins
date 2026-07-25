# `switch_fable_to_opus` — env-gated fable→opus agent dispatch

**Date:** 2026-07-25
**Status:** Implemented (#1017). Risk 1 was spiked and resolved before implementation —
see *Risks*. One deliberate refinement was made during implementation: the switch keys on
the **effective** model rather than the frontmatter alone — see *Control flow*.
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

This design adds a **runtime** switch: one environment variable that redirects any dispatch
whose effective model would be fable to opus at dispatch time, without touching a single file.

## Scope

A `PreToolUse` hook on the `Agent` tool, shipped in the **`development`** plugin (which
already owns a `hooks.json`). When `switch_fable_to_opus` is truthy, any dispatch whose
**effective** model would be fable is sent to **opus** instead — the effective model being
the call's `model` when it passes one and the agent definition's frontmatter otherwise —
resolved from this marketplace's installed plugins, see *Resolving an agent's declared
model* (and *Control flow*, which is authoritative on the rule itself).

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
counter-incentive. The hook touches only the dispatches that would actually have run on
fable (see *Control flow* — that is not the same set as the 32 fable-declaring agents once a
per-call `model` is in play).

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
  ├─ determine the EFFECTIVE model:
  │     call passed a model  ──► that model
  │     otherwise            ──► the agent definition's frontmatter
  │
  ├─ effective model is not fable  ──────► exit 0, emit nothing
  │
  └─ otherwise ──► emit updatedInput with model:"opus"
```

**Refinement made during implementation.** The switch keys on the **effective** model, not
on the frontmatter alone. The Agent tool documents that a per-call `model` "takes precedence
over the agent definition's model frontmatter", so the effective model is the call's when it
passes one and the frontmatter's otherwise. Keying on it makes both directions correct:

- an explicit `model: "fable"` on an opus-declaring agent **is** redirected (the original
  design already required this);
- a fable-declaring agent invoked with an explicit `model: "haiku"` is **not** — it was never
  going to run on fable, so promoting it to opus would spend *more*, which is precisely the
  counter-incentive this feature exists to avoid.

A frontmatter-only rule would have got that second case wrong. It costs nothing: when the
call passes no model — the overwhelmingly common case — the two rules coincide.

The environment check happens **before** stdin is read and before `jq` is invoked, so a
user who never enables the feature pays one process spawn and nothing else.

### Output contract

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "updatedInput": { "...tool_input": "verbatim", "model": "opus" },
    "additionalContext": "switch_fable_to_opus is set — development-go:go-bug-hunter dispatched on opus instead of fable"
  }
}
```

`updatedInput` must carry **every** original key of `tool_input` unchanged, with only
`model` set or replaced. The `additionalContext` message interpolates
`tool_input.subagent_type` **verbatim**, so it carries the plugin-qualified name exactly as
the call passed it (the bats suite pins the whole string). `permissionDecision` is
deliberately **omitted** — see Risks.

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
- When several version directories match, selection is **two-tier**:
  1. plain `X.Y` / `X.Y.Z` directories are considered first, and the **numerically-greatest**
     of those wins — zsh's `(n)` glob qualifier, not a lexical sort. That distinction is
     load-bearing and easy to get backwards: `0.10.0` is lexically *smaller* than `0.7.0`, so
     a lexical sort would read the stale cache directory.
  2. consulted only when tier 1 matched nothing — the fallback glob is a bare `*`,
     deliberately unrestricted, so it
     catches the suffixed versions (`1.6.0-rc.1`, `1.2.3+build`), the four-component
     `1.2.3.4`, *and* a directory whose name is not version-shaped at all (`unknown/`).
     Narrowing it to a version pattern would silently stop resolving that last group.

  Tier 1 exists because `(n)` sorts by **name, not semver**: a *higher* prerelease outranks
  the greatest stable release, so a single `(n)`-sorted glob would read a cached `1.8.0-rc.1`
  in preference to `1.7.0`. That is **not** the fail-safe direction — an rc declaring fable
  would cause a false-positive rewrite of a stable release declaring opus.

  The narrower hazard of an rc shadowing the release it *suffixes* does **not** arise, and an
  earlier draft of this spec claimed it did. The glob sorts whole paths, so
  `1.6.0-rc.1/agents/…` sorts *before* `1.6.0/agents/…` (`-` precedes `/`) and the stable
  release already wins. Verified by collapsing the tiers and re-running the suite: exactly one
  case fails, "the greatest PLAIN version wins even when a higher prerelease exists". That is
  the case that pins this rule; the rc-vs-same-version pair documents the intent but passes
  under either implementation.
- An unqualified `subagent_type` falls back to a wildcard across sibling plugins; if that
  matches more than one **plugin** it is treated as unresolvable (see Failure posture). Bare
  names do collide across plugins — `development-swift:bug-hunter` versus
  `development-go:go-bug-hunter` — so guessing is not acceptable. Ambiguity is counted in
  plugins rather than files on purpose: two cached *versions* of one plugin are the ordinary
  version-pinned cache, not an ambiguity, and counting files there would silently disable
  the feature for every unqualified name.
- Resolution anchors on `$CLAUDE_PLUGIN_ROOT`, falling back to the script's own location
  (`${0:A:h:h}`) when that variable is unset — which is also how the bats suite drives it.

**Confinement depends on computing the marketplace root per layout.** The two layouts put
the plugin root at different depths — the version directory in the installed case, the
plugin directory in the flat case — so the marketplace is one level further up in the
former. Getting that wrong is not cosmetic: treating a *flat* root as versioned lands two
levels above the repo, where the sibling-plugin wildcard would match other checkouts, or in
a worktree every sibling worktree, and resolve a model from a tree unrelated to this
marketplace. The layouts are told apart by whether the root's basename is version-shaped
(`<->.<->*`, so `1.5`, `1.140.0`, `1.2.3-rc.1` and `1.2.3+build` all qualify), with the path
normalised first so a symlinked version directory cannot read as flat.

This is a name heuristic, not structural detection — the plugin cache carries no marketplace
manifest to key on. A plugin cached under a non-version-shaped directory (Claude Code writes
`unknown/` when a marketplace declares no version, as other marketplaces in the same cache
show today) reads as flat and its lookups quietly find nothing. This applies only to **the
hook's own plugin** — the heuristic is only ever run against `$CLAUDE_PLUGIN_ROOT`. A
*target* plugin cached that way is unaffected: tier 2's unrestricted glob still finds it. That is the fail-safe
direction — no switching, never a wrong model or a lookup outside the marketplace — and this
marketplace pins a semver version for every plugin, so it does not arise here; it is simply
the first thing to check if the switch ever silently stops working.

Within that correctly-computed root, the anchor confines the **frontmatter-resolution path**
to this marketplace: an agent belonging to an unrelated plugin is left alone. Note the
effective-model refinement scopes this claim — a call passing `model: "fable"` explicitly
needs no lookup and is redirected whoever owns the agent, which is intended.

Frontmatter parsing adapts the `frontmatter_model` awk from `scripts/toggle-fable.zsh`. It
already handles the two cases that matter — a file with no proper frontmatter (no `---` on
line 1, or no closing fence) yields nothing, and a prose `model:` in the body is invisible
because parsing stops at the closing fence. **Three deliberate differences**, the first two
because `toggle-fable.zsh` *rewrites* the line (and must round-trip it byte-exactly) while
this hook only *reads* it to compare against `fable`:

1. the value is trimmed and unquoted, so `model: "fable"` or a stray trailing space cannot
   silently mean "not fable";
2. the match is tab-tolerant (`^model:[ \t]`, slicing from 7) where `toggle-fable.zsh`
   matches `^model:` plus a literal space exactly (slicing from 8), so a tab-separated
   `model:<TAB>fable` is
   visible here and invisible there — the two can therefore disagree about which agents count
   as fable-declaring for such a file, and erring toward *seeing* the declaration is the
   intended direction, since missing it would silently disable the switch;
3. awk is invoked with `2>/dev/null`. This one follows from the fail-safe posture rather than
   from rewrite-vs-read: an unreadable definition must produce silence, not a diagnostic on
   stderr (pinned by the unreadable-definition bats case).

An **equivalent** normalisation is applied to a per-call `model` — trim spaces, tabs and
quotes, then case-fold — so both halves of the decision agree about what the word "fable" is
for every value the Agent tool accepts. The two are not byte-identical: the call path strips
those characters anywhere in the value, while the awk trims only the ends. Note also that the
case-fold itself is a **fourth** divergence from `toggle-fable.zsh` beyond the three parser
differences above — it lives at the comparison site rather than in the parser, and
`toggle-fable.zsh` compares case-sensitively, so `model: FABLE` is fable-declaring here and
invisible there.

### Failure posture

Every error path exits 0 and emits nothing, so the agent runs exactly as declared:

- `jq` not on `PATH`
- a `tool_name` that is present but not `Agent` (guards a mis-registered matcher; an
  *absent* `tool_name` is tolerated, since matching is the matcher's job)
- an empty `subagent_type`
- agent definition file not found or unreadable, or the marketplace root cannot be determined
- file present but no frontmatter `model:` line
- an unqualified `subagent_type` matching more than one **plugin** (two cached versions of
  the *same* plugin are not an ambiguity — the two-tier rule above picks one)
- a `subagent_type` whose plugin or name contains a path separator, a leading `.`, or a
  glob metacharacter
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
| on + ambiguous unqualified name (two plugins)         | no output, exit 0                       |
| on + fable agent, versioned layout                    | resolves                                |
| on + fable agent, flat `--plugin-dir` layout          | resolves                                |
| on + fable agent with extra `tool_input` keys         | all keys preserved byte-identically     |
| on + fable agent called with explicit `model: haiku` / `sonnet` / `opus` | no output, exit 0 |
| on + fable agent                                      | emitted model is enum-valid (`sonnet`\|`opus`\|`haiku`\|`fable`) |
| on + fable agent                                      | **no** `permissionDecision` key emitted |
| on + two cached versions of one plugin, unqualified   | resolves (greatest plain version wins)  |
| on + a prerelease cached alongside the stable release it suffixes | the stable release decides |
| on + a prerelease as the ONLY cached version          | resolves                                |
| on + a four-component version as the only one         | resolves (via the fallback tier)         |
| on + a plain version and a HIGHER prerelease           | the greatest plain version decides       |
| on + a root that is two-component / suffixed / symlinked | classified as the versioned layout     |
| on + a root that does not exist                       | no output, exit 0                       |
| on + unqualified name under the FLAT layout           | resolves                                |
| on + `subagent_type` with a path separator, aimed at a real outside agent | no output, exit 0 |
| on + a glob metacharacter in the plugin or name        | no output, exit 0 (literal name still resolves) |
| on + unqualified name resolvable only OUTSIDE the marketplace root | no output, exit 0 |
| on + well-formed frontmatter with no `model:` line    | no output, exit 0                       |
| on + quoted / space-padded / mixed-case `model: fable` | `updatedInput.model == "opus"`         |
| on + agent owned by the hook's own plugin             | resolves, qualified and bare            |
| off + a `jq` stub that records invocation             | stub never invoked (gate short-circuits) |
| on + `jq` absent from an otherwise-complete `PATH`     | no output, exit 0                       |

The "all keys preserved" case is the one that protects against the worst plausible bug:
`updatedInput` replaces the tool arguments wholesale, so a dropped key silently changes what
the agent is asked to do.

The script must pass `zsh -n`, per the repo's script-quality gate. It is **not** run through
shellcheck: `.pre-commit-config.yaml` scopes shellcheck and shfmt to `files: \.sh$` because
shellcheck cannot parse zsh (it emits SC1071), so `zsh -n` is the applicable check for a
`.zsh` script. An earlier draft of this spec claimed a shellcheck gate that repo policy does
not apply here.

## Risks and open questions

1. ~~**`updatedInput` without `permissionDecision` is unverified.**~~ **RESOLVED — the
   design's choice is confirmed correct.** A throwaway hook was run against the live
   install (2.1.220) before implementation, as this risk demanded:

   | probe | result |
   | --- | --- |
   | `updatedInput`, **no** `permissionDecision`, on `Bash` | rewrite **honoured** (the substituted command ran) |
   | `updatedInput`, **no** `permissionDecision`, on `Agent` | rewrite **honoured** (the substituted `prompt` reached the subagent; `subagent_type` survived) |
   | same, rewriting `model` to a bogus value | call **blocked** with `Invalid option: expected one of "sonnet"\|"opus"\|"haiku"\|"fable"`, path `["model"]` |
   | `permissionDecision: "defer"` | produced **no result at all** — it is the `-p`/SDK resume path, not a pass-through |
   | `permissionDecision: "ask"` | **forced a permission prompt**, blocking the call |

   The third row is the decisive one for the *mechanism*: the Agent tool schema-validated
   the value the hook injected, so the substituted `model` demonstrably reaches the tool's
   input — it is not discarded the way it would be if a `permissionDecision` were required.
   So omitting `permissionDecision` is not merely acceptable, it is the best available
   option: `"defer"` silently drops the call and `"ask"` adds a prompt to every fable
   dispatch, while `"allow"` — excluded on the documented contract rather than by probe —
   would suppress the user's normal Agent permission prompts.

   **What the probes do not establish.** No probe observed a subagent actually *running* on
   a substituted valid model; the rewrite was confirmed end-to-end for `prompt` (the
   substituted text reached the subagent) and confirmed to reach input validation for
   `model`. Redirection therefore rests on one documented step — that the Agent tool's
   `model` parameter selects the model — rather than on direct observation. If the fable
   bucket keeps draining with the switch on, that step is the thing to check first.

   Two consequences carried into the implementation: the emitted model must always be one of
   the four enum values (an out-of-enum value **blocks** the call rather than degrading to
   no-switch — the one way this hook could break dispatch), and a bats case now pins that.

   Note for future readers: reading the minified binary alone is **not** sufficient here. The
   permission-aggregation path contains `q.updatedInput && (q.permissionBehavior === "allow"
   || q.permissionBehavior === "ask")`, which reads as "a decision is required" and is
   contradicted by every empirical probe above — it governs a different branch. The live
   probe is the authority.
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
effect for subsequently spawned hook processes. Note this rests on the documented
`settings.env` contract only — unlike Risk 1, mid-session propagation was **not** probed, so
"no session restart needed" is an expectation rather than a verified result, and the how-to
page tells users to restart if the switch appears not to take effect.

## Deliverables

- `development/hooks/switch-fable-to-opus.zsh`
- `PreToolUse` / `Agent` entry in `development/hooks/hooks.json`
- `tests/switch-fable-to-opus.bats`
- `docs/reference/plugins.md`: four stale `development` agent Model cells corrected against
  frontmatter (drive-by — that page is hand-written and is **not** covered by the
  reference-drift gate, which regenerates only `commands.md` / `agents.md`), plus a note of
  the plugin-level hooks the manifests now advertise
- a `development/hooks/**` entry in `.github/workflows/script-tests.yml`'s
  `on.pull_request.paths` — not incidental: without it a hook-only PR never runs this suite at
  PR time, and the suite asserts on the entry, so it is a pinned contract
- `ARCHITECTURE.md`: the `development/hooks/` bullet under "`development` owns", the
  "Runtime override: `switch_fable_to_opus`" subsection under "Agent model selection", and the
  hook-script `err_exit` exemption under "Scripting conventions" (which this script's header
  cites by name as the convention it deviates from)
- `docs/how-to/switch-fable-agents-to-opus.md`, wired into **three** places: `mkdocs.yml`'s
  `nav:` (a new page is invisible without it, and the strict build fails) *and* both MOC
  listings, `docs/index.md` and `docs/how-to/index.md` (without those it is unfindable)
- `development/.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` version bump in
  lockstep, without which no installer ever receives the hook — plus the installer-visible
  `description` rewrite in both, advertising the hook
