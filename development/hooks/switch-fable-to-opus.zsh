#!/usr/bin/env zsh
# switch-fable-to-opus.zsh — PreToolUse(Agent) hook that redirects agents which
# would dispatch on **fable** to **opus** while the environment variable
# `switch_fable_to_opus` is truthy (#1017).
#
# Why this exists: fable is metered as its own scoped weekly bucket. When it runs
# dry, every agent declaring `model: fable` fails. Rewriting frontmatter in the
# REPO worktree is not a remedy — a session dispatches from the installed cache
# (`~/.claude/plugins/cache/`), not from a checkout, and the rewrite leaves a
# dirty tree to revert. This is the runtime fix: one variable, no files touched.
#
# Why not CLAUDE_CODE_SUBAGENT_MODEL: it overrides EVERY subagent. The fleet is
# 55 opus / 32 fable / 8 haiku / 2 sonnet, so a blanket `=opus` would promote 10
# cheap agents to opus while trying to conserve budget. This touches only the
# agents that would actually have run on fable.
#
# FAIL-SAFE POSTURE. Every unexpected condition — no jq, unresolvable or
# ambiguous `subagent_type`, no frontmatter, malformed stdin — exits 0 and emits
# NOTHING, so the agent dispatches exactly as declared. A broken hook degrades to
# "no switching", never to "wrong model everywhere". Deliberately NO `err_exit`
# (the repo default, ARCHITECTURE.md "Scripting conventions"): a PreToolUse hook
# exiting non-zero is user-visible — exit 2 outright BLOCKS the tool call — so
# the one thing this script must never do is die on the way to a decision.
#
# `permissionDecision` is deliberately NOT emitted: returning "allow" would
# suppress the user's normal Agent permission prompts as a side effect.
setopt nounset pipefail

# Capture the plugin root HERE, at top level: inside a function zsh rebinds $0 to
# the FUNCTION name, so `${0:A:h:h}` computed in resolve_agent_file would resolve
# against the function name instead of this file. This script lives at
# <plugin-root>/hooks/<file>.zsh.
readonly SCRIPT_PLUGIN_ROOT="${0:A:h:h}"

# frontmatter_model <file> — print the value of the frontmatter `model:` line, or
# nothing when the file has no *proper* frontmatter (a `---` on line 1 AND a
# closing `---`) or no model line. It is awk (no pipe) so it can't hit a SIGPIPE
# under pipefail, and it never reads past the closing fence — a prose
# "model: ..." in the body is invisible here.
#
# Three properties matter, the first two because this only READS the line to
# compare it against "fable", the third because of the fail-safe posture above:
#   * the value is trimmed and unquoted, so `model: "fable"` or a stray trailing
#     space cannot silently mean "not fable";
#   * the match is tab-tolerant (`^model:[ \t]`, slicing from 7), so a
#     tab-separated `model:<TAB>fable` is still seen as a declaration — erring
#     toward *seeing* it is the right direction, since missing it would
#     silently disable the switch;
#   * awk is invoked with `2>/dev/null`, so an unreadable definition yields
#     silence rather than a diagnostic on stderr (pinned by a bats case).
# The caller additionally case-folds the parsed value, so `model: FABLE` is
# fable-declaring too.
frontmatter_model() {
  awk '
    NR == 1     { if ($0 != "---") exit; next }
    /^---$/     { print val; exit }          # closing fence (only reached >1)
    /^model:[ \t]/ {
      val = substr($0, 7)
      gsub(/^[ \t"'"'"']+|[ \t"'"'"']+$/, "", val)
    }
  ' "$1" 2>/dev/null
}

# marketplace_root — print the directory that CONTAINS the plugin directories,
# or nothing when it cannot be determined. Everything else globs strictly BELOW
# this, which is what actually confines the feature to this marketplace.
#
# CLAUDE_PLUGIN_ROOT is the contract; SCRIPT_PLUGIN_ROOT (captured from $0 at top
# level) is the fallback, so the hook still resolves when invoked directly —
# which is how the bats suite drives it.
#
# Two layouts must BOTH resolve, and they differ in how DEEP the plugin root sits:
#   installed     <marketplace>/<plugin>/<version>/   ← root is the VERSION dir
#   --plugin-dir  <marketplace>/<plugin>/             ← root is the PLUGIN dir
# so the marketplace is `root:h:h` in the first case and `root:h` in the second.
# Getting this wrong is not cosmetic: computing `root:h:h` under the FLAT layout
# lands two levels ABOVE the repo, where `*/*/agents/<name>.md` would match
# sibling repos — or, in a worktree, every sibling worktree — and resolve an
# agent's model from a tree that has nothing to do with this marketplace.
#
# The layouts are told apart by whether the root's own basename is version-shaped
# — `<->` is zsh for "one or more digits", so `<->.<->*` covers `1.5`, `1.140.0`,
# `1.2.3.4`, `1.2.3-rc.1` and `1.2.3+build`, while no plugin directory name in
# this marketplace begins `<digits>.<digits>`.
#
# The path is normalised (`:A`) BEFORE the shape test so the test and the
# depth-stripping agree: a symlinked version dir (`current -> 1.140.0`) would
# otherwise read as flat by name while `:A:h` stripped the resolved version dir.
#
# Honest limitation: this is a name heuristic, not structural detection — there
# is no marketplace manifest in the plugin cache to key on. A plugin cached under
# a NON-version-shaped directory (Claude Code writes `unknown/` when a
# marketplace declares no version — visible today under other marketplaces in
# the same cache) reads as flat, the marketplace lands one level too shallow, and
# lookups quietly find nothing. That is the fail-safe direction — no switching,
# never a wrong model or a lookup outside the marketplace — and this marketplace
# pins a semver version for every plugin, so it does not arise here. It is
# nonetheless the first thing to check if the switch ever silently stops working.
#
# The OTHER misclassification is the dangerous one and is NOT fail-safe: a flat
# --plugin-dir directory whose basename begins <digits>.<digits> would take the
# versioned branch and land one level ABOVE the marketplace, re-opening the
# sibling-repo glob described above. Nothing prevents that but the naming
# convention — every plugin directory here is alphabetic.
marketplace_root() {
  local root="${${CLAUDE_PLUGIN_ROOT:-$SCRIPT_PLUGIN_ROOT}:A}"
  [[ -d "$root" ]] || return 0
  if [[ "${root:t}" == <->.<->* ]]; then
    print -r -- "${root:h:h}"       # versioned cache: strip <version>/<plugin>
  else
    print -r -- "${root:h}"         # flat --plugin-dir: strip <plugin>
  fi
}

# pick_in_plugin <marketplace> <plugin> <name> — print the one agent definition
# for <plugin>/<name>, or nothing. Three globs in precedence order: the plain
# `X.Y`/`X.Y.Z` version shape, then a catch-all `*` for anything else cached
# there, then the flat shape. The first two take the NUMERICALLY-greatest match
# (`(N)` = null glob, `(n)` = numeric-aware sort, so 0.10.0 beats 0.7.0 — a
# plain lexical sort gets that backwards and would read a stale cache dir); the
# flat shape needs no sort, as it can match at most one path. All three are
# anchored under <marketplace>, so none can escape it.
pick_in_plugin() {
  local mk="$1" plugin="$2" name="$3"
  local -a hits
  # Plain `X.Y`/`X.Y.Z` versions FIRST, because `(n)` sorts by NAME, not by
  # semver: a HIGHER prerelease outranks the greatest stable release, so with a
  # single glob a cached `1.8.0-rc.1` would beat `1.7.0` and be read instead.
  # That is not fail-safe — an rc declaring fable would cause a false-positive
  # rewrite of a stable release declaring opus.
  #
  # The narrower hazard of an rc shadowing the release it SUFFIXES does NOT
  # arise: the glob sorts whole paths, and `1.6.0-rc.1/agents/...` sorts before
  # `1.6.0/agents/...` because `-` precedes `/`. Verified — the ordering that
  # actually needs this tier is the higher-prerelease one, pinned by the
  # three-way bats case.
  #
  # The FIRST glob is deliberately narrower than marketplace_root's `<->.<->*`
  # shape test: a four-component `1.2.3.4` is a version there but falls through
  # to the fallback here.
  #
  # The second glob is that fallback tier. It runs whenever the first found
  # nothing, and the `(n)`-greatest of whatever it matches wins. It is a bare
  # `*` on purpose - strictly BROADER than the shape test - so a plugin cached
  # under a directory that is not version-shaped at all (`unknown/`) still
  # resolves; narrowing it would silently drop those.
  hits=( "$mk"/"$plugin"/<->.<->(.<->|)/agents/"$name".md(Nn) )
  (( ${#hits} )) || hits=( "$mk"/"$plugin"/*/agents/"$name".md(Nn) )
  (( ${#hits} )) || hits=( "$mk"/"$plugin"/agents/"$name".md(N) )
  (( ${#hits} )) || return 0
  print -r -- "${hits[-1]:A}"
}

# resolve_agent_file <subagent_type> — print the path of the agent definition
# that `subagent_type` names, or nothing when it cannot be resolved UNAMBIGUOUSLY.
resolve_agent_file() {
  local st="$1" plugin name mk f
  mk="$(marketplace_root)"
  [[ -n "$mk" ]] || return 0

  if [[ "$st" == *:* ]]; then
    plugin="${st%%:*}"
    name="${st#*:}"
  else
    plugin=""
    name="$st"
  fi
  # A name or plugin with a path separator is not an identifier; refuse rather
  # than let it climb out of the marketplace.
  [[ -n "$name" && "$name" != */* && "$name" != .* ]] || return 0
  [[ "$plugin" != */* && "$plugin" != .* ]] || return 0

  if [[ -n "$plugin" ]]; then
    pick_in_plugin "$mk" "$plugin" "$name"
    return 0
  fi

  # Unqualified: search every plugin in the marketplace. Bare names DO collide
  # across plugins — development-swift:bug-hunter vs development-go:go-bug-hunter
  # — so guessing is not acceptable.
  #
  # Ambiguity is counted in distinct PLUGINS, not distinct files: two cached
  # versions of the SAME plugin are not an ambiguity, they are the ordinary
  # version-pinned cache, and counting files there would make every unqualified
  # name silently stop switching — exactly the stale-version case the qualified
  # path is built to survive.
  local -aU plugins
  for f in "$mk"/*/*/agents/"$name".md(N) "$mk"/*/agents/"$name".md(N); do
    # <marketplace>/<plugin>/... — the first component after $mk is the plugin.
    local rel="${f#$mk/}"
    plugins+=("${rel%%/*}")
  done
  (( ${#plugins} == 1 )) || return 0
  pick_in_plugin "$mk" "${plugins[1]}" "$name"
}

# --- 1. the env gate — before stdin, before jq -------------------------------
# The common path is "feature off", and it must cost one process spawn and
# nothing else.
#
# Truthiness: `1`, `true`, `yes` (any case) are ON; unset, "", `0`, `false` and
# any UNRECOGNISED value are OFF. Two deliberate choices:
#   * "" is OFF. The settings documentation states a variable set to "" *still*
#     reaches subprocesses, so a naive "is it present?" test would read an
#     explicitly-emptied variable as ON — exactly backwards.
#   * unrecognised is OFF, so a typo fails safe.
case "${(L)${switch_fable_to_opus:-}}" in
  1|true|yes) ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat)" || exit 0
[[ -n "$payload" ]] || exit 0

# --- 2. parse the hook payload ------------------------------------------------
# One jq pass emitting three tab-separated fields. Each key defaults to "" rather
# than `empty`, which would shorten the line and desync the field positions.
parsed="$(
  printf '%s' "$payload" \
    | jq -r '[(.tool_name // ""), (.tool_input.subagent_type // ""),
              (.tool_input.model // "")] | @tsv' 2>/dev/null
)" || exit 0

# Split with `(@ps:\t:)`, NOT `IFS=$'\t' read`. Tab is IFS *whitespace*, so `read`
# strips leading/trailing runs and collapses empties: a payload with no
# `tool_name` yields "\t<subagent>\t", and `read` would slide <subagent> into
# tool_name, leaving subagent_type empty — the hook would then silently no-op on
# every such call. `(@ps:...:)` preserves empty fields positionally.
#
# Known limitation, deliberately unhandled: @tsv escapes an embedded tab, newline
# or backslash as a two-character sequence, which this split leaves as-is. No
# agent name or model contains those, and a mangled value simply fails to
# resolve — i.e. it lands in the fail-safe direction, no switching.
fields=( "${(@ps:\t:)parsed}" )
tool_name="${fields[1]:-}"
subagent_type="${fields[2]:-}"
call_model="${fields[3]:-}"

# Defensive: the hooks.json matcher already scopes this to Agent, but a
# mis-registration must not rewrite some other tool's input. An ABSENT tool_name
# is tolerated (matching is the matcher's job); a WRONG one is not.
[[ -z "${tool_name:-}" || "${tool_name:-}" == "Agent" ]] || exit 0
[[ -n "${subagent_type:-}" ]] || exit 0

# --- 3. decide on the EFFECTIVE model ----------------------------------------
# The effective model is the per-call `model` when the call passes one, and the
# agent definition's frontmatter otherwise — the Agent tool's documented
# precedence ("model: … takes precedence over the agent definition's model
# frontmatter"). Keying on the EFFECTIVE model, rather than on the frontmatter
# alone, is what makes both directions correct:
#   * an explicit `model: "fable"` on an opus-declaring agent IS redirected;
#   * a fable-declaring agent invoked with an explicit `model: "haiku"` is NOT —
#     it was never going to run on fable, and promoting it to opus would spend
#     more, the exact counter-incentive this feature exists to avoid.
if [[ -n "${call_model:-}" ]]; then
  # Normalise EQUIVALENTLY to the frontmatter path: strip spaces, tabs and
  # quotes, then case-fold. (Not byte-identical, and deliberately so described:
  # frontmatter_model trims only the ENDS inside its awk and does not fold at
  # all — the fold is applied to its output below. This strips those characters
  # anywhere in the value.) They agree on every value the Agent tool accepts.
  # Normalising only one path would let ` fable` compare unequal here while the
  # identical frontmatter value switched.
  effective="${(L)${call_model//[[:space:]\"\']/}}"
else
  agent_file="$(resolve_agent_file "$subagent_type")"
  [[ -n "$agent_file" ]] || exit 0
  effective="${(L)$(frontmatter_model "$agent_file")}"
fi

[[ "$effective" == fable ]] || exit 0

# --- 4. emit the rewrite ------------------------------------------------------
# `updatedInput` REPLACES tool_input wholesale, so it must carry every original
# key. `.tool_input + {model:"opus"}` is an object merge: existing keys survive,
# in order, `model` is set or replaced, and nothing is dropped. A dropped key
# would silently change what the agent is asked to do — the worst plausible bug
# in this script, and the reason the bats suite asserts key preservation.
out="$(
  printf '%s' "$payload" | jq -c \
    --arg ctx "switch_fable_to_opus is set — ${subagent_type} dispatched on opus instead of fable" '
      if (.tool_input | type) == "object" then
        {hookSpecificOutput: {
           hookEventName: "PreToolUse",
           updatedInput: (.tool_input + {model: "opus"}),
           additionalContext: $ctx}}
      else empty end' 2>/dev/null
)" || exit 0

[[ -n "$out" ]] && print -r -- "$out"
exit 0
