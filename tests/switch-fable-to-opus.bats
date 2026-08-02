#!/usr/bin/env bats
#
# Behavioural tests for development/hooks/switch-fable-to-opus.zsh (#1017): the
# PreToolUse(Agent) hook that redirects fable-bound agents to opus while
# `switch_fable_to_opus` is truthy. What these pin down:
#
#   * TRUTHINESS — 1/true/yes (any case) are ON; unset, "", 0, false and any
#     unrecognised value are OFF. "" being OFF is load-bearing: a variable set to
#     "" still reaches subprocesses, so a naive presence test would read an
#     explicitly-emptied variable as ON, exactly backwards.
#   * EFFECTIVE MODEL — the per-call `model` wins over frontmatter (the Agent
#     tool's documented precedence), so an explicit model:"fable" IS redirected
#     and a fable-declaring agent called with model:"haiku" is NOT (promoting it
#     to opus would spend more — the counter-incentive this feature avoids).
#   * BOTH LAYOUTS — version-pinned plugin cache and flat --plugin-dir.
#   * KEY PRESERVATION — updatedInput carries every original tool_input key with
#     only `model` added/replaced. A dropped key would silently change what the
#     agent is asked to do; this is the worst plausible bug in the script.
#   * VALID ENUM — the emitted model is one the Agent tool accepts. A live spike
#     showed an out-of-enum value makes the tool call FAIL schema validation and
#     be BLOCKED, so emitting a bad model would break dispatch, not degrade it.
#   * FAIL-SAFE — every error path (no jq, unknown/ambiguous/unresolvable agent,
#     no frontmatter, malformed stdin, wrong tool) exits 0 emitting NOTHING, so
#     the agent dispatches exactly as declared. A hook exiting non-zero is
#     user-visible and exit 2 outright BLOCKS the call, so it must never happen.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  H="$REPO_ROOT/development/hooks/switch-fable-to-opus.zsh"

  # Synthetic marketplace, so the suite never depends on what happens to be
  # installed in ~/.claude/plugins/cache (whose declared models change release to
  # release). Version-pinned layout: <cache>/<plugin>/<version>/agents/<x>.md
  CACHE="$BATS_TEST_TMPDIR/cache"
  ROOT="$CACHE/development/1.140.0"          # the value of CLAUDE_PLUGIN_ROOT
  mkdir -p "$ROOT/hooks"

  mkagent() {  # mkagent <plugin>/<version> <name> <model>
    local dir="$CACHE/$1/agents"
    mkdir -p "$dir"
    printf -- '---\nname: %s\ndescription: test agent\nmodel: %s\n---\n\nBody.\n' \
      "$2" "$3" > "$dir/$2.md"
  }

  mkagent development-go/0.8.0     go-bug-hunter       fable
  mkagent development-go/0.8.0     go-format-lint-fixer haiku
  mkagent development-go/0.8.0     go-approver         opus
  mkagent development-java/1.15.0  java-planner        sonnet
  # An agent owned by the SAME plugin the hook ships in — the commonest real
  # case, and the one where the two resolution globs can name the same file.
  mkagent development/1.140.0      dev-own-agent       fable

  # Resolvable fable agents used as TARGETS of the path-traversal probes: each is
  # planted where a traversal WOULD land if a specific guard clause were removed,
  # so every clause has a probe that fails on its deletion rather than passing
  # vacuously. There are FOUR clauses to cover, not one:
  #   name != */*   → evilplugin/9.9.9/agents/evil.md
  #   plugin != */* → same target, reached via a plugin-side traversal
  #   plugin != .*  → .hidden/9.9.9/agents/evilh.md
  #   name != .*    → development-go/0.8.0/agents/.evilname.md
  mkagent evilplugin/9.9.9         evil                fable
  mkagent .hidden/9.9.9            evilh               fable
  mkagent hidden/9.9.9             evilh               fable   # positive control
  printf -- '---\nname: evilname\nmodel: fable\n---\n\nBody.\n' \
    > "$CACHE/development-go/0.8.0/agents/.evilname.md"
  mkagent development-go/0.8.0     evilname            fable   # positive control
  # One level ABOVE the marketplace, for the plugin `..` probe.
  mkdir -p "$BATS_TEST_TMPDIR/outside-plugin/agents"
  printf -- '---\nname: evil\nmodel: fable\n---\n\nBody.\n' \
    > "$BATS_TEST_TMPDIR/outside-plugin/agents/evil.md"
}

# A PATH containing every binary the script needs EXCEPT the named one, so a
# "missing binary" test isolates that binary instead of also hiding the shell,
# `cat`, and `awk` (an emptied PATH exits 127 and proves nothing).
path_without() {
  local drop="$1" bin="$BATS_TEST_TMPDIR/bin-no-$drop" t
  mkdir -p "$bin"
  # `type -P` resolves real executables only. `command -v printf` would print
  # the shell BUILTIN's name, and `ln -sf printf ...` would plant a
  # self-referential symlink that resolves to ELOOP — the very half-populated
  # PATH this guard exists to prevent.
  local p
  for t in cat awk env jq; do
    [ "$t" = "$drop" ] && continue
    p="$(type -P "$t")" || { echo "path_without: no $t binary on PATH" >&2; return 1; }
    [ -n "$p" ] || { echo "path_without: no $t binary on PATH" >&2; return 1; }
    ln -sf "$p" "$bin/$t"
  done
  printf '%s' "$bin"
}

# run_hook <var-value-or-UNSET> <stdin-json> [extra env assignments...]
run_hook() {
  local val="$1" payload="$2"; shift 2
  if [ "$val" = "UNSET" ]; then
    run env -u switch_fable_to_opus CLAUDE_PLUGIN_ROOT="$ROOT" "$@" \
      zsh "$H" <<<"$payload"
  else
    run env switch_fable_to_opus="$val" CLAUDE_PLUGIN_ROOT="$ROOT" "$@" \
      zsh "$H" <<<"$payload"
  fi
}

payload_for() {  # payload_for <subagent_type> [model]
  if [ -n "${2:-}" ]; then
    jq -nc --arg s "$1" --arg m "$2" \
      '{tool_name:"Agent",tool_input:{subagent_type:$s,model:$m,prompt:"do the thing"}}'
  else
    jq -nc --arg s "$1" \
      '{tool_name:"Agent",tool_input:{subagent_type:$s,prompt:"do the thing"}}'
  fi
}

# Several tests iterate a table of inputs. Set CASE="$v" in the loop so a failure
# names the offending value instead of only the helper's line number.
_case() { [ -z "${CASE:-}" ] || echo "failing case: [$CASE]" >&2; }

assert_silent() {  # exit 0, nothing on stdout — the fail-safe contract
  [ "$status" -eq 0 ] || { _case; echo "expected exit 0, got $status" >&2; return 1; }
  [ -z "$output" ]    || { _case; echo "expected no output, got: $output" >&2; return 1; }
}

assert_rewritten() {
  [ "$status" -eq 0 ] || { _case; echo "expected exit 0, got $status" >&2; return 1; }
  [ -n "$output" ]    || { _case; echo "expected a rewrite, got no output" >&2; return 1; }
  [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")" = "PreToolUse" ] \
    || { _case; echo "bad hookEventName in: $output" >&2; return 1; }
  [ "$(jq -r '.hookSpecificOutput.updatedInput.model' <<<"$output")" = "opus" ] \
    || { _case; echo "model not opus in: $output" >&2; return 1; }
}

# --- truthiness table ---------------------------------------------------------

@test "OFF: variable unset -> no output, exit 0" {
  run_hook UNSET "$(payload_for development-go:go-bug-hunter)"
  assert_silent
}

@test "OFF: empty string is OFF (a set-but-empty var still reaches subprocesses)" {
  run_hook "" "$(payload_for development-go:go-bug-hunter)"
  assert_silent
}

@test "OFF: 0, false, and unrecognised values all fail safe" {
  local v
  for v in 0 false FALSE no off maybe 2 '1 ' 'yes please'; do
    CASE="$v"
    run_hook "$v" "$(payload_for development-go:go-bug-hunter)"
    assert_silent
  done
}

@test "ON: 1, true, yes are truthy in any case" {
  local v
  for v in 1 true TRUE True yes YES Yes; do
    CASE="$v"
    run_hook "$v" "$(payload_for development-go:go-bug-hunter)"
    assert_rewritten
  done
}

# --- the switching decision ---------------------------------------------------

@test "ON + fable-declaring agent -> updatedInput.model == opus" {
  run_hook 1 "$(payload_for development-go:go-bug-hunter)"
  assert_rewritten
}

@test "ON + opus/haiku/sonnet agents are never touched" {
  local a
  for a in development-go:go-approver development-go:go-format-lint-fixer \
           development-java:java-planner; do
    CASE="$a"
    run_hook 1 "$(payload_for "$a")"
    assert_silent
  done
}

@test "CONTROL: those same three agent FILES are the ones actually being read" {
  # Silence in the test above is only meaningful if the hook really resolved each
  # file. Flip each fixture to fable and assert a rewrite, then RESTORE it and
  # re-assert silence before moving on — restoring matters: leaving them flipped
  # would mean later iterations only prove that *some* fable file resolved, not
  # that the named one did.
  local dir name plugin declared
  for spec in "development-go/0.8.0 go-approver development-go opus" \
              "development-go/0.8.0 go-format-lint-fixer development-go haiku" \
              "development-java/1.15.0 java-planner development-java sonnet"; do
    set -- $spec
    dir="$1"; name="$2"; plugin="$3"; declared="$4"
    CASE="$name"
    printf -- '---\nname: %s\nmodel: fable\n---\n\nBody.\n' "$name" \
      > "$CACHE/$dir/agents/$name.md"
    run_hook 1 "$(payload_for "$plugin:$name")"
    assert_rewritten
    printf -- '---\nname: %s\nmodel: %s\n---\n\nBody.\n' "$name" "$declared" \
      > "$CACHE/$dir/agents/$name.md"
    run_hook 1 "$(payload_for "$plugin:$name")"
    assert_silent
  done
}

@test "GUARD: a glob metacharacter in plugin or name resolves nothing" {
  # A `*` arriving in subagent_type must never expand into a real path and let
  # the hook rewrite a call on some ARBITRARY agent's model — the same wrong-file
  # class the separator and leading-dot guards cover.
  #
  # What actually protects this is zsh NOT globbing the result of a parameter
  # expansion by default: measured, `$mk/$plugin/...` matches nothing even
  # unquoted, and it takes an explicit `${~plugin}` (or GLOB_SUBST) to turn the
  # metacharacter live. The quoting in pick_in_plugin is belt-and-braces on top
  # of that, not the load-bearing part — so this test pins the OUTCOME rather
  # than any one mechanism, and would catch either being undone.
  # zz-fable sorts last under (n), so a live name glob would pick it.
  mkagent development-go/0.8.0 zz-fable fable
  local t
  for t in '*:go-bug-hunter' 'development-go:*' '*:*' 'development-?o:go-bug-hunter'; do
    CASE="$t"
    run_hook 1 "$(payload_for "$t")"
    assert_silent
  done
  # POSITIVE CONTROL: the planted target IS reachable by its literal name.
  run_hook 1 "$(payload_for development-go:zz-fable)"
  assert_rewritten
}

@test "ON + call explicitly passing model fable -> redirected even on an opus agent" {
  run_hook 1 "$(payload_for development-go:go-approver fable)"
  assert_rewritten
}

@test "ON + explicit non-fable model on a FABLE agent -> NOT touched (no promotion)" {
  # The call's model overrides frontmatter, so this dispatch was never going to
  # be fable; rewriting it to opus would spend MORE, inverting the whole point.
  local m
  for m in haiku sonnet opus; do
    CASE="$m"
    run_hook 1 "$(payload_for development-go:go-bug-hunter "$m")"
    assert_silent
  done
}

@test "ON + explicit model FABLE in mixed case is still redirected" {
  run_hook 1 "$(payload_for development-go:go-approver FABLE)"
  assert_rewritten
}

@test "ON + an explicit model fable is redirected WITHOUT resolving the agent" {
  # Pins the decided contract: when the call passes a model, the effective model
  # is already known, so resolution is skipped entirely — and the redirect
  # therefore applies even to a subagent_type this marketplace does not own, or
  # one that resolves to nothing at all. Marketplace confinement scopes the
  # FRONTMATTER path only; this is deliberate, because the point is to keep the
  # call off a drained fable bucket regardless of who owns the agent.
  run_hook 1 "$(payload_for some-foreign-plugin:whatever fable)"
  assert_rewritten
  run_hook 1 "$(payload_for no-such-agent-anywhere fable)"
  assert_rewritten
}

# --- resolution ---------------------------------------------------------------

@test "ON + unknown subagent_type -> no output, exit 0" {
  run_hook 1 "$(payload_for development-go:no-such-agent)"
  assert_silent
}

@test "ON + unknown PLUGIN -> no output, exit 0" {
  run_hook 1 "$(payload_for development-nope:go-bug-hunter)"
  assert_silent
}

@test "ON + agent file with no frontmatter -> no output, exit 0" {
  printf 'Just a body, no frontmatter at all.\nmodel: fable\n' \
    > "$CACHE/development-go/0.8.0/agents/go-bug-hunter.md"
  run_hook 1 "$(payload_for development-go:go-bug-hunter)"
  assert_silent
}

@test "ON + frontmatter opened but never closed -> no output (prose model: invisible)" {
  printf -- '---\nname: x\nmodel: fable\n\nNo closing fence.\n' \
    > "$CACHE/development-go/0.8.0/agents/go-bug-hunter.md"
  run_hook 1 "$(payload_for development-go:go-bug-hunter)"
  assert_silent
}

@test "ON + a prose 'model: fable' AFTER the fence does not count" {
  printf -- '---\nname: x\nmodel: opus\n---\n\nmodel: fable\n' \
    > "$CACHE/development-go/0.8.0/agents/go-bug-hunter.md"
  run_hook 1 "$(payload_for development-go:go-bug-hunter)"
  assert_silent
}

@test "ON + well-formed frontmatter with NO model line -> no output, exit 0" {
  # The design's own failure-posture branch: fence opened AND closed, no model
  # key. Guards against an empty parsed value ever matching.
  printf -- '---\nname: x\ndescription: d\n---\n\nBody.\n' \
    > "$CACHE/development-go/0.8.0/agents/go-bug-hunter.md"
  run_hook 1 "$(payload_for development-go:go-bug-hunter)"
  assert_silent
}

@test "ON + frontmatter model in mixed case still resolves as fable" {
  # The (L) fold is applied to the FRONTMATTER value too, not just the call's.
  local v
  for v in FABLE Fable fAbLe; do
    CASE="$v"
    printf -- '---\nname: x\nmodel: %s\n---\n\nBody.\n' "$v" \
      > "$CACHE/development-go/0.8.0/agents/go-bug-hunter.md"
    run_hook 1 "$(payload_for development-go:go-bug-hunter)"
    assert_rewritten
  done
}

@test "ON + a TAB-separated frontmatter model still resolves as fable" {
  # The script deliberately matches `^model:[ \t]`, not `^model: ` exactly.
  # Narrowing it to a literal space would silently stop switching such agents.
  printf -- '---\nname: x\nmodel:\tfable\n---\n\nBody.\n' \
    > "$CACHE/development-go/0.8.0/agents/go-bug-hunter.md"
  run_hook 1 "$(payload_for development-go:go-bug-hunter)"
  assert_rewritten
}

@test "ON + a space-padded or quoted CALL model resolves as fable too" {
  # The call path and the frontmatter path must agree on what counts as "fable";
  # normalising only one of them would dispatch a padded call onto the drained
  # bucket while the identical frontmatter value switched.
  local m
  for m in ' fable' 'fable ' '"fable"' "'fable'" '  FABLE  '; do
    CASE="$m"
    run_hook 1 "$(payload_for development-go:go-approver "$m")"
    assert_rewritten
  done
}

@test "ON + a quoted or space-padded frontmatter model still resolves as fable" {
  # Real YAML permits these; treating them as "not fable" would silently disable
  # the switch for an agent that genuinely declares it.
  local v
  for v in '"fable"' "'fable'" 'fable ' '  fable'; do
    CASE="$v"
    printf -- '---\nname: x\nmodel: %s\n---\n\nBody.\n' "$v" \
      > "$CACHE/development-go/0.8.0/agents/go-bug-hunter.md"
    run_hook 1 "$(payload_for development-go:go-bug-hunter)"
    assert_rewritten
  done
}

@test "ON + unqualified name resolving to exactly one agent -> resolves" {
  run_hook 1 "$(payload_for go-bug-hunter)"
  assert_rewritten
}

@test "ON + AMBIGUOUS unqualified name (same name in two plugins) -> no output" {
  # Bare names DO collide across plugins in this family, so guessing is not
  # acceptable — more than one match must mean "leave it alone".
  mkagent development-java/1.15.0 go-bug-hunter fable
  run_hook 1 "$(payload_for go-bug-hunter)"
  assert_silent
}

@test "ON + several version dirs -> the NUMERICALLY-greatest version wins" {
  # The cache is version-pinned; a stale older dir must not shadow the current
  # one. Old declares opus, new declares fable -> the NEW one decides. Note
  # 0.10.0 is lexically SMALLER than 0.7.0, so this only holds under zsh's
  # numeric-aware `(n)` glob sort — a plain lexical sort reads the stale 0.7.0.
  mkagent development-go/0.7.0  versioned-probe opus
  mkagent development-go/0.10.0 versioned-probe fable
  run_hook 1 "$(payload_for development-go:versioned-probe)"
  assert_rewritten
}

@test "ON + a cached PRERELEASE does not shadow the stable release it suffixes" {
  # DOCUMENTS INTENT; does not pin the two-tier rule. The glob sorts whole paths,
  # and `1.6.0-rc.1/agents/…` sorts BEFORE `1.6.0/agents/…` because `-` (0x2D)
  # precedes `/` (0x2F) — so the stable release already wins even under a single
  # glob, and this pair passes either way. (An earlier version of this comment
  # claimed the opposite; measured, it is false.) The rule itself is pinned by
  # the three-way case below, where a HIGHER prerelease really would outrank the
  # greatest plain release.
  mkagent development-go/1.6.0      relprobe opus
  mkagent development-go/1.6.0-rc.1 relprobe fable
  run_hook 1 "$(payload_for development-go:relprobe)"
  assert_silent
  # Mirrored pair, so this pins "the STABLE release decided" rather than merely
  # "the rc did not" — silence alone would also be produced by the name failing
  # to resolve at all.
  mkagent development-go/1.7.0      relprobe2 fable
  mkagent development-go/1.7.0-rc.1 relprobe2 opus
  run_hook 1 "$(payload_for development-go:relprobe2)"
  assert_rewritten
}

@test "ON + the greatest PLAIN version wins even when a higher prerelease exists" {
  mkagent development-go/1.6.0     threeway opus
  mkagent development-go/1.7.0     threeway fable
  mkagent development-go/1.8.0-rc.1 threeway opus
  run_hook 1 "$(payload_for development-go:threeway)"
  assert_rewritten   # 1.7.0 decided, not 1.8.0-rc.1 and not 1.6.0
}

@test "ON + a four-component version resolves when it is the only one" {
  # marketplace_root's shape test (<->.<->*) counts 1.2.3.4 as a version, but
  # pick_in_plugin's suffix-free glob (<->.<->(.<->|)) deliberately does not, so
  # it is consulted via the fallback. Pinned so the two patterns' divergence is a
  # decision rather than an accident.
  mkagent development-go/1.2.3.4 fourpart fable
  run_hook 1 "$(payload_for development-go:fourpart)"
  assert_rewritten
}

@test "ON + a prerelease is still used when it is the ONLY cached version" {
  mkagent development-go/2.1.0-rc.2 onlyrc fable
  run_hook 1 "$(payload_for development-go:onlyrc)"
  assert_rewritten
}

@test "ON + two cached versions of ONE plugin is not an ambiguity for an unqualified name" {
  # Counting distinct FILES here would make every unqualified name silently stop
  # switching the moment a stale version dir lingered — the exact stale-cache
  # case the qualified path is built to survive. Ambiguity is per PLUGIN.
  mkagent development-go/0.7.0  multiver opus
  mkagent development-go/0.10.0 multiver fable
  run_hook 1 "$(payload_for multiver)"
  assert_rewritten
}

@test "ON + an agent owned by the hook's OWN plugin resolves, qualified and bare" {
  # The commonest real case: an agent of the plugin the hook ships in. Only the
  # versioned glob matches this fixture, so the `-U` dedup is NOT exercised here
  # — that is covered by the two-cached-versions test above, where both version
  # dirs collapse to one plugin.
  run_hook 1 "$(payload_for development:dev-own-agent)"
  assert_rewritten
  run_hook 1 "$(payload_for dev-own-agent)"
  assert_rewritten
}

@test "ON + CLAUDE_PLUGIN_ROOT wins over the script-location fallback" {
  # Asserted POSITIVELY: $other declares fable and the script-location root is
  # overwritten to opus, so a rewrite can only happen if $other was actually
  # read. A silence-only assertion would keep passing if $other simply stopped
  # resolving for an unrelated reason — the vacuity trap this suite keeps hitting.
  local other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other/development/1.0.0" "$other/development-go/0.1.0/agents"
  printf -- '---\nname: go-bug-hunter\nmodel: fable\n---\n\nBody.\n' \
    > "$other/development-go/0.1.0/agents/go-bug-hunter.md"
  printf -- '---\nname: go-bug-hunter\nmodel: opus\n---\n\nBody.\n' \
    > "$CACHE/development-go/0.8.0/agents/go-bug-hunter.md"
  cp "$H" "$ROOT/hooks/switch-fable-to-opus.zsh"
  run env switch_fable_to_opus=1 CLAUDE_PLUGIN_ROOT="$other/development/1.0.0" \
    zsh "$ROOT/hooks/switch-fable-to-opus.zsh" <<<"$(payload_for development-go:go-bug-hunter)"
  assert_rewritten   # read $other (fable), not $ROOT (now opus)
  # ...and with CLAUDE_PLUGIN_ROOT unset the fallback root decides: silence.
  run env -u CLAUDE_PLUGIN_ROOT switch_fable_to_opus=1 \
    zsh "$ROOT/hooks/switch-fable-to-opus.zsh" <<<"$(payload_for development-go:go-bug-hunter)"
  assert_silent
}

@test "ON + a CLAUDE_PLUGIN_ROOT that does not exist -> no output, exit 0" {
  # The missing dir is deliberately INSIDE $CACHE, not an arbitrary path: with
  # the `[[ -d "$root" ]]` check deleted, "nope" is not version-shaped so the
  # flat branch yields $CACHE — the real marketplace — and go-bug-hunter would
  # resolve to the fable fixture and rewrite. An arbitrary missing path would
  # yield a directory containing no fixtures and the test would pass either way.
  run env switch_fable_to_opus=1 CLAUDE_PLUGIN_ROOT="$CACHE/nope" \
    zsh "$H" <<<"$(payload_for development-go:go-bug-hunter)"
  assert_silent
}

@test "ON + a TWO-component version directory is still read as the versioned layout" {
  # Pins the `<->.<->*` shape test against a root like <plugin>/1.5 — with a
  # three-component-only pattern this reads as the FLAT layout, the marketplace
  # lands one level too shallow, and the feature silently stops switching.
  mkagent development/1.5 twopart-probe fable
  mkagent development-go/2.0 twopart-target fable
  run env switch_fable_to_opus=1 CLAUDE_PLUGIN_ROOT="$CACHE/development/1.5" \
    zsh "$H" <<<"$(payload_for development-go:twopart-target)"
  assert_rewritten
  run env switch_fable_to_opus=1 CLAUDE_PLUGIN_ROOT="$CACHE/development/1.5" \
    zsh "$H" <<<"$(payload_for twopart-target)"
  assert_rewritten
}

@test "ON + a version directory with a prerelease/build suffix is read as versioned" {
  mkagent development/1.6.0-rc.1 pre-probe fable
  run env switch_fable_to_opus=1 CLAUDE_PLUGIN_ROOT="$CACHE/development/1.6.0-rc.1" \
    zsh "$H" <<<"$(payload_for development-go:go-bug-hunter)"
  assert_rewritten
}

@test "ON + a symlinked version directory still resolves as versioned" {
  # The shape test runs on the :A-normalised path, so `current -> 1.140.0`
  # cannot read as flat while the depth-stripping resolves the real version dir.
  ln -s "1.140.0" "$CACHE/development/current"
  run env switch_fable_to_opus=1 CLAUDE_PLUGIN_ROOT="$CACHE/development/current" \
    zsh "$H" <<<"$(payload_for development-go:go-bug-hunter)"
  assert_rewritten
}

@test "ON + versioned layout is preferred when a plugin has BOTH shapes" {
  mkagent development-go/0.9.0 bothshapes fable
  mkdir -p "$CACHE/development-go/agents"
  printf -- '---\nname: bothshapes\nmodel: opus\n---\n\nBody.\n' \
    > "$CACHE/development-go/agents/bothshapes.md"
  run_hook 1 "$(payload_for development-go:bothshapes)"
  assert_rewritten   # the versioned (fable) definition decided
}

@test "flat --plugin-dir layout also resolves" {
  # <repo>/<plugin>/agents/<x>.md with CLAUDE_PLUGIN_ROOT=<repo>/development —
  # the layout /development-claude-plugin:test uses, so the hook is testable there.
  local flat="$BATS_TEST_TMPDIR/flat"
  mkdir -p "$flat/development/hooks" "$flat/development-go/agents"
  printf -- '---\nname: go-bug-hunter\nmodel: fable\n---\n\nBody.\n' \
    > "$flat/development-go/agents/go-bug-hunter.md"
  run env switch_fable_to_opus=1 CLAUDE_PLUGIN_ROOT="$flat/development" \
    zsh "$H" <<<"$(payload_for development-go:go-bug-hunter)"
  assert_rewritten
}

@test "resolution falls back to the script's own location when CLAUDE_PLUGIN_ROOT is unset" {
  # Copy the hook into a synthetic <root>/hooks/ so ${0:A:h:h} is the plugin root.
  cp "$H" "$ROOT/hooks/switch-fable-to-opus.zsh"
  run env -u CLAUDE_PLUGIN_ROOT switch_fable_to_opus=1 \
    zsh "$ROOT/hooks/switch-fable-to-opus.zsh" <<<"$(payload_for development-go:go-bug-hunter)"
  assert_rewritten
}

@test "POSITIVE CONTROL: every traversal target IS resolvable by a legitimate name" {
  # Without these, a traversal probe could pass simply because its planted
  # fixture is unreachable rather than because a guard blocked it — which is
  # exactly how the first version of these tests was vacuous.
  run_hook 1 "$(payload_for evilplugin:evil)"
  assert_rewritten
  run_hook 1 "$(payload_for hidden:evilh)"          # same shape as .hidden
  assert_rewritten
  run_hook 1 "$(payload_for development-go:evilname)"   # same shape as .evilname
  assert_rewritten
  # Drive the hook at the outside target too, rather than just asserting the
  # file exists: a -f check can never fail on a script change, so it would not
  # notice the '..' probe going vacuous if the glob shape ever changed.
  run env switch_fable_to_opus=1 CLAUDE_PLUGIN_ROOT="$BATS_TEST_TMPDIR/outside-plugin" \
    zsh "$H" <<<"$(payload_for outside-plugin:evil)"
  assert_rewritten
}

@test "GUARD: a NAME containing a path separator cannot reach an agent elsewhere" {
  # The name must contain a separator but NOT start with a dot, or the sibling
  # `"$name" != .*` clause would reject it and this test would pass with the
  # separator clause deleted — which is exactly how it was vacuous before.
  # `sub/` is a real directory, so with the clause removed the glob normalises
  # onto evilplugin/9.9.9/agents/evil.md (a fable agent) and the hook rewrites.
  mkdir -p "$CACHE/development-go/0.8.0/agents/sub"
  run_hook 1 "$(payload_for 'development-go:sub/../../../../evilplugin/9.9.9/agents/evil')"
  assert_silent
}

@test "GUARD: a NAME starting with a dot AND containing separators is rejected" {
  # Covered by the leading-dot clause; kept separate so the test above isolates
  # the separator clause on its own.
  run_hook 1 "$(payload_for 'development-go:../../../evilplugin/9.9.9/agents/evil')"
  assert_silent
}

@test "GUARD: a PLUGIN containing a path separator cannot reach another plugin" {
  # Without `"$plugin" != */*`, pick_in_plugin globs
  # $CACHE/development-go/../evilplugin/*/agents/evil.md → the fable agent.
  run_hook 1 "$(payload_for 'development-go/../evilplugin:evil')"
  assert_silent
}

@test "GUARD: a PLUGIN starting with a dot cannot be resolved" {
  # Without `"$plugin" != .*`, $CACHE/.hidden/9.9.9/agents/evilh.md resolves
  # (the component is literal, so a hidden directory matches).
  run_hook 1 "$(payload_for '.hidden:evilh')"
  assert_silent
}

@test "GUARD: a NAME starting with a dot cannot be resolved" {
  # Without `"$name" != .*`, $CACHE/development-go/0.8.0/agents/.evilname.md
  # resolves — same literal-component reasoning.
  run_hook 1 "$(payload_for 'development-go:.evilname')"
  assert_silent
}

@test "GUARD: a PLUGIN of '..' cannot climb above the marketplace" {
  # Caught by the SAME `"$plugin" != .*` clause as the .hidden probe — this test
  # pins the escape SCENARIO (climbing above the marketplace), not a distinct
  # clause. Without the plugin guard, pick_in_plugin globs $CACHE/../*/agents/evil.md,
  # which matches the planted outside-plugin/agents/evil.md. Deliberately probes
  # only ONE level up, so it stays inside this test's own BATS_TEST_TMPDIR and
  # never depends on what sibling tests created (bats runs them in parallel).
  run_hook 1 "$(payload_for '..:evil')"
  assert_silent
}

@test "an unqualified name is never resolved from OUTSIDE the marketplace root" {
  # The flat-layout regression: computing the marketplace as root:h:h under
  # --plugin-dir would reach the repo's PARENT, where a sibling checkout or
  # sibling worktree's <plugin>/agents/<name>.md would resolve. Plant exactly
  # that shape one level above the flat root and assert it is not consulted.
  # ONE sibling fixture only. A second plugin matching the same bare name would
  # make the unqualified scan ambiguous under the bug, so the ambiguity guard —
  # not the confinement fix — would produce the silence, and this assertion
  # could no longer fail. The qualified case gets its own test below, with its
  # own distinct agent name, so the two cannot interfere.
  local flat="$BATS_TEST_TMPDIR/flat2"
  mkdir -p "$flat/development" "$flat/development-go/agents" \
           "$BATS_TEST_TMPDIR/sibling-repo/development-go/agents"
  printf -- '---\nname: outsider\nmodel: fable\n---\n\nBody.\n' \
    > "$BATS_TEST_TMPDIR/sibling-repo/development-go/agents/outsider.md"
  # POSITIVE CONTROL, and the suite's only coverage of unqualified resolution
  # under the FLAT layout: without it, silence below is equally explained by the
  # flat unqualified glob not working at all, and deleting that glob from
  # resolve_agent_file leaves the whole suite green.
  printf -- '---\nname: insider\nmodel: fable\n---\n\nBody.\n' \
    > "$flat/development-go/agents/insider.md"
  run env switch_fable_to_opus=1 CLAUDE_PLUGIN_ROOT="$flat/development" \
    zsh "$H" <<<"$(payload_for insider)"
  assert_rewritten
  run env switch_fable_to_opus=1 CLAUDE_PLUGIN_ROOT="$flat/development" \
    zsh "$H" <<<"$(payload_for outsider)"
  assert_silent
}

@test "a QUALIFIED name is never resolved from OUTSIDE the marketplace root" {
  # Distinct agent name (outsider-q) so it can never enter the unqualified
  # ambiguity count of the test above. Under the bug, pick_in_plugin's flat glob
  # hits $BATS_TEST_TMPDIR/development-go/agents/outsider-q.md and rewrites.
  local flat="$BATS_TEST_TMPDIR/flat3"
  mkdir -p "$flat/development" "$BATS_TEST_TMPDIR/development-go/agents"
  printf -- '---\nname: outsider-q\nmodel: fable\n---\n\nBody.\n' \
    > "$BATS_TEST_TMPDIR/development-go/agents/outsider-q.md"
  run env switch_fable_to_opus=1 CLAUDE_PLUGIN_ROOT="$flat/development" \
    zsh "$H" <<<"$(payload_for development-go:outsider-q)"
  assert_silent
}

# --- payload handling ---------------------------------------------------------

@test "ON + every other tool_input key is preserved, with only model added" {
  local p out
  p="$(jq -nc '{tool_name:"Agent",tool_input:{
        subagent_type:"development-go:go-bug-hunter",
        prompt:"multi\nline\tprompt with \"quotes\" and — unicode",
        description:"d", run_in_background:true, isolation:"worktree",
        nested:{a:[1,2,{b:null}]}, count:42, flag:false}}')"
  run_hook 1 "$p"
  [ "$status" -eq 0 ]
  out="$(jq -c '.hookSpecificOutput.updatedInput' <<<"$output")"
  # Every original key survives with an identical value...
  run jq -e --argjson orig "$(jq -c '.tool_input' <<<"$p")" \
    '. as $u | $orig | to_entries | all(.key == "model" or ($u[.key] == .value))' <<<"$out"
  [ "$status" -eq 0 ]
  # ...and the ONLY key gained is model.
  run jq -e --argjson orig "$(jq -c '.tool_input' <<<"$p")" \
    '((. | keys) - ($orig | keys)) == ["model"]' <<<"$out"
  [ "$status" -eq 0 ]
}

@test "ON + an existing non-fable model key is REPLACED, not duplicated" {
  run_hook 1 "$(payload_for development-go:go-approver fable)"
  assert_rewritten
  # Count the model KEY, not `[.path] | length` — that is always 1 (jq collapses
  # duplicate keys at parse time and `[null] | length` is 1 too), so it could
  # never fail. Also pin the total key count so a gained/dropped key shows up.
  [ "$(jq -r '.hookSpecificOutput.updatedInput
              | [keys[] | select(. == "model")] | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.hookSpecificOutput.updatedInput | keys | length' <<<"$output")" = "3" ]
}

@test "the emitted model is a value the Agent tool schema accepts" {
  # A live spike proved an out-of-enum model makes the Agent call fail schema
  # validation and get BLOCKED — so this must never drift to a bogus string.
  # Deliberately NOT calling assert_rewritten: its `model == "opus"` assertion
  # would make the membership check below tautological.
  local m
  run_hook 1 "$(payload_for development-go:go-bug-hunter)"
  [ "$status" -eq 0 ]
  m="$(jq -r '.hookSpecificOutput.updatedInput.model' <<<"$output")"
  run jq -e --arg m "$m" '["sonnet","opus","haiku","fable"] | index($m) != null' <<<'null'
  [ "$status" -eq 0 ]
}

@test "permissionDecision is NEVER emitted (it would suppress Agent permission prompts)" {
  run_hook 1 "$(payload_for development-go:go-bug-hunter)"
  assert_rewritten
  [ "$(jq -r '.hookSpecificOutput | has("permissionDecision")' <<<"$output")" = "false" ]
}

@test "additionalContext states the full message, in the right direction" {
  # Substring checks on the agent name alone would also pass on an INVERTED
  # message ("dispatched on fable instead of opus"), so pin the whole string.
  run_hook 1 "$(payload_for development-go:go-bug-hunter)"
  assert_rewritten
  [ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" \
    = "switch_fable_to_opus is set — development-go:go-bug-hunter dispatched on opus instead of fable" ]
}

@test "output is a single line of valid JSON" {
  run_hook 1 "$(payload_for development-go:go-bug-hunter)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | wc -l | tr -d ' ')" = "0" ]   # no trailing newline inside
  run jq -e . <<<"$output"
  [ "$status" -eq 0 ]
}

# --- fail-safe ----------------------------------------------------------------

@test "malformed / empty / non-object stdin -> no output, exit 0" {
  local p
  for p in 'not json at all' '' '[]' 'null' '{"tool_name":"Agent"}' \
           '{"tool_name":"Agent","tool_input":"a string"}' \
           '{"tool_name":"Agent","tool_input":null}'; do
    CASE="$p"
    run_hook 1 "$p"
    assert_silent
  done
}

@test "a non-Agent tool_name is never rewritten (guards a mis-registered matcher)" {
  run_hook 1 '{"tool_name":"Bash","tool_input":{"command":"rm -rf /","subagent_type":"development-go:go-bug-hunter"}}'
  assert_silent
}

@test "an ABSENT tool_name is tolerated (matching is the matcher's job)" {
  run_hook 1 '{"tool_input":{"subagent_type":"development-go:go-bug-hunter","prompt":"x"}}'
  assert_rewritten
}

@test "no jq on PATH -> no output, exit 0" {
  # PATH keeps cat/awk/env and drops ONLY jq, so this isolates the `command -v
  # jq` guard. An emptied PATH would also hide `cat`, and the test would pass
  # through any missing-binary path rather than the one it names.
  local bin; bin="$(path_without jq)"
  run env switch_fable_to_opus=1 CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$bin" \
    "$(command -v zsh)" "$H" <<<"$(payload_for development-go:go-bug-hunter)"
  assert_silent
  # POSITIVE CONTROL: the same synthetic PATH *with* jq must rewrite. Without
  # this, a PATH broken in some other way (a failed symlink in the helper) would
  # produce the same silence and the test would prove nothing.
  local ok; ok="$(path_without nothing)"
  run env switch_fable_to_opus=1 CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$ok" \
    "$(command -v zsh)" "$H" <<<"$(payload_for development-go:go-bug-hunter)"
  assert_rewritten
}

@test "OFF short-circuits BEFORE stdin is read and BEFORE jq is invoked" {
  # Pins the ORDERING, not just the silence — the design's "one process spawn
  # when the feature is off" property. BOTH halves are observed: a `cat` stub
  # for the stdin read and a `jq` stub for the parse. Asserting only
  # exit-0-and-empty, or only the jq half, would let the gate drift below the
  # stdin read with nothing failing.
  local bin="$BATS_TEST_TMPDIR/stuborder"; mkdir -p "$bin"
  local jqm="$BATS_TEST_TMPDIR/jq-was-called" catm="$BATS_TEST_TMPDIR/cat-was-called"
  printf '#!/usr/bin/env bash\ntouch "%s"\nexit 1\n' "$jqm" > "$bin/jq"
  printf '#!/usr/bin/env bash\ntouch "%s"\nexec %s "$@"\n' "$catm" "$(command -v cat)" > "$bin/cat"
  chmod +x "$bin/jq" "$bin/cat"
  run env -u switch_fable_to_opus CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$bin:$PATH" \
    zsh "$H" <<<"$(payload_for development-go:go-bug-hunter)"
  assert_silent
  [ ! -e "$jqm" ]
  [ ! -e "$catm" ]
  # POSITIVE CONTROL: with the feature ON both stubs are reachable, proving the
  # markers can fire at all and the absence above is the gate, not a dud stub.
  run env switch_fable_to_opus=1 CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$bin:$PATH" \
    zsh "$H" <<<"$(payload_for development-go:go-bug-hunter)"
  [ -e "$catm" ]
  [ -e "$jqm" ]   # each marker's absence above is backed by its presence here
}

@test "a jq that fails at the EMIT stage -> no output, exit 0" {
  # The second jq call's failure branch is unreachable through stdin (a bad
  # payload already fails the first pass), so it needs a stub seam: succeed on
  # the parse call, fail on the emit call.
  local bin="$BATS_TEST_TMPDIR/stubjq2"; mkdir -p "$bin"
  local count="$BATS_TEST_TMPDIR/jq-calls"
  cat > "$bin/jq" <<EOF
#!/usr/bin/env bash
n=\$(cat "$count" 2>/dev/null || echo 0); echo \$((n+1)) > "$count"
[ "\$n" -ge 1 ] && exit 1
exec "$(command -v jq)" "\$@"
EOF
  chmod +x "$bin/jq"
  run env switch_fable_to_opus=1 CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$bin:$PATH" \
    zsh "$H" <<<"$(payload_for development-go:go-bug-hunter)"
  assert_silent
  [ "$(cat "$count")" -ge 2 ]   # proves the emit call really was reached
}

@test "an unreadable agent definition -> no output, exit 0" {
  # tests/Dockerfile runs the suite as root, where chmod 000 is still readable.
  [ "$(id -u)" -ne 0 ] || skip "chmod proves nothing as root"
  chmod 000 "$CACHE/development-go/0.8.0/agents/go-bug-hunter.md"
  run_hook 1 "$(payload_for development-go:go-bug-hunter)"
  chmod 644 "$CACHE/development-go/0.8.0/agents/go-bug-hunter.md"
  assert_silent
}

@test "an empty subagent_type -> no output, exit 0" {
  run_hook 1 '{"tool_name":"Agent","tool_input":{"subagent_type":"","prompt":"x"}}'
  assert_silent
}

@test "a present-but-EMPTY or null tool_input.model falls through to the frontmatter" {
  # Empty and absent must behave identically: the call passed no usable model, so
  # the fable frontmatter decides. Swapping the `-n` test for a presence test
  # (has("model")) would silently stop switching these calls.
  local p
  for p in '{"tool_name":"Agent","tool_input":{"subagent_type":"development-go:go-bug-hunter","model":"","prompt":"x"}}' \
           '{"tool_name":"Agent","tool_input":{"subagent_type":"development-go:go-bug-hunter","model":null,"prompt":"x"}}'; do
    CASE="$p"
    run_hook 1 "$p"
    assert_rewritten
    [ "$(jq -r '.hookSpecificOutput.updatedInput.model' <<<"$output")" = "opus" ]
  done
}

# --- registration -------------------------------------------------------------

@test "hooks.json registers the hook on PreToolUse/Agent with the portable command" {
  # Assert EQUALITY, not endswith(): an absolute developer-machine path would
  # satisfy endswith() while being the one form that cannot work on an
  # installer's machine. Single quotes keep the shell off ${CLAUDE_PLUGIN_ROOT}.
  local hj="$REPO_ROOT/development/hooks/hooks.json"
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Agent") | .hooks[]
             | select(.type == "command")
             | select(.command == "${CLAUDE_PLUGIN_ROOT}/hooks/switch-fable-to-opus.zsh")' "$hj"
  [ "$status" -eq 0 ]
}

@test "hooks.json leaves the pre-existing PostToolUse/Bash cleanup hook untouched" {
  local hj="$REPO_ROOT/development/hooks/hooks.json"
  run jq -e '.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[]
             | select(.command | endswith("/skills/cleanup/scripts/cleanup-hook.sh"))' "$hj"
  [ "$status" -eq 0 ]
}

@test "the hook script is executable" {
  [ -x "$H" ]
}

@test "the script is covered by the script-tests path filter" {
  # GitHub path filters are not implicitly **-prefixed, so a hook-only PR would
  # otherwise never run this suite at PR time. Asserted STRUCTURALLY — on the
  # entries of on.pull_request.paths specifically, so it cannot be satisfied by
  # the string appearing in a comment or under paths-ignore. awk rather than a
  # YAML library because PyYAML is not guaranteed on the runners.
  local entries
  entries="$(awk '
    /^on:/                      { in_on=1; next }
    in_on && /^  pull_request:/ { in_pr=1; next }
    in_pr && /^    paths:/      { in_paths=1; next }
    in_paths && /^      - /     { v=$0; sub(/^      - /,"",v);
                                  gsub(/^['"'"'"]|['"'"'"]$/,"",v); print v; next }
    in_paths && !/^      / && !/^ *$/ && !/^ *#/ { in_paths=0; in_pr=0 }
  ' "$REPO_ROOT/.github/workflows/script-tests.yml")"
  # Sanity-check the extractor itself, so a parse that silently yields nothing
  # cannot be mistaken for a satisfied assertion.
  grep -qx 'tests/\*\*' <<<"$entries"
  grep -qx 'development/hooks/\*\*' <<<"$entries"
}
