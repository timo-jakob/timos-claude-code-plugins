#!/usr/bin/env bats
#
# The `epic_strictly_sequential` setting: resolve-issue's Epic flow can be
# told to resolve every child one at a time in the session, with the gate and
# every wait in the foreground. What these pin down:
#
#   * TRUTHINESS — scripts/strictly-sequential.zsh prints `on` for
#     1/true/yes/on (any case) and `off` for unset, "" and every other value.
#     The default is OFF, so an unrecognised value (a typo) keeps today's
#     behaviour — the same direction as switch_fable_to_opus.
#   * ONE LINE, EXIT 0 — the conductor reads the verdict once at the start of
#     the Epic flow; a non-zero exit or extra output would leave it guessing.
#   * WIRING — the conductor points at reference/sequential.md before E1 (the
#     conductor is at its line ceiling, so the procedure lives there); that file
#     runs the script, names the three changes, and keeps the gate in the
#     foreground; the how-to is reachable from the nav and the settings table.
#
# Anchored by content, never by line number (#1189).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/strictly-sequential.zsh"
  SEQ="$REPO_ROOT/development/skills/resolve-issue/reference/sequential.md"
  CONDUCTOR="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  HOWTO="$REPO_ROOT/docs/how-to/run-epics-strictly-sequentially.md"
}

# run_s <value-or-UNSET>
run_s() {
  if [ "$1" = "UNSET" ]; then
    run env -u epic_strictly_sequential zsh "$S"
  else
    run env epic_strictly_sequential="$1" zsh "$S"
  fi
}

# --- truthiness ---------------------------------------------------------------

@test "unset is off (the default)" {
  run_s UNSET
  [ "$status" -eq 0 ]
  [ "$output" = "off" ]
}

@test "empty string is off" {
  run_s ""
  [ "$status" -eq 0 ]
  [ "$output" = "off" ]
}

@test "each truthy spelling is on, in any case" {
  local v
  for v in 1 true TRUE True yes YES Yes on ON On; do
    run_s "$v"
    [ "$status" -eq 0 ] || { echo "value [$v] exited $status" >&2; return 1; }
    [ "$output" = "on" ] || { echo "value [$v] printed [$output]" >&2; return 1; }
  done
}

@test "falsy and unrecognised values are off (a typo keeps today's flow)" {
  local v
  for v in 0 false no off tru 11 " 1" sequential; do
    run_s "$v"
    [ "$status" -eq 0 ] || { echo "value [$v] exited $status" >&2; return 1; }
    [ "$output" = "off" ] || { echo "value [$v] printed [$output]" >&2; return 1; }
  done
}

@test "the script is executable" {
  [ -x "$S" ]
}

# --- wiring -------------------------------------------------------------------

@test "the Epic flow points at the mode before E1" {
  local before_e1
  before_e1="$(awk '/^## Epic flow$/{on=1} /^### E1\. /{exit} on{print}' "$CONDUCTOR")"
  contains "$before_e1" '**Before E1, read the mode** — `epic_strictly_sequential`'
  contains "$before_e1" 'see `reference/sequential.md` § Strictly sequential mode'
}

@test "sequential.md runs the script, announces the mode, and names the three changes" {
  local mode
  mode="$(awk '/^## Strictly sequential mode$/{on=1} /^### /{exit} on{print}' "$SEQ")"
  contains "$mode" '**Read the mode once, before E1.**'
  contains "$mode" '"<skill-base-dir>/scripts/strictly-sequential.zsh"'
  contains "$mode" 'epic mode: strictly sequential'
  contains "$mode" '**E3 resolves every child sequentially, in this session.**'
  contains "$mode" 'provably-disjoint set is not parallelised'
  contains "$mode" '**Every review-loop round boundary is serial, with the gate in the'
  contains "$mode" '**Every PR-check wait is a foreground call.**'
  contains "$mode" 'E1b still gates **every** child'
}

@test "sequential.md keeps the gate in the foreground and never starts a second one" {
  local gate
  gate="$(awk '/^### The round boundary — gate first, in the foreground$/{on=1} on{print}' "$SEQ")"
  contains "$gate" '**Run `<full gate>` as one ordinary foreground Bash call**'
  contains "$gate" 'Never start a second gate beside it'
  contains "$gate" 're-launch it in the background yourself'
  contains "$gate" '**report and stop**'
}

@test "the how-to exists, shows the settings key, and is in the nav and settings table" {
  [ -f "$HOWTO" ]
  grep -qF '"epic_strictly_sequential": "1"' "$HOWTO"
  grep -qF 'how-to/run-epics-strictly-sequentially.md' "$REPO_ROOT/mkdocs.yml"
  grep -qF '(run-epics-strictly-sequentially.md)' "$REPO_ROOT/docs/how-to/index.md"
  grep -qF '| `epic_strictly_sequential` | off |' "$REPO_ROOT/docs/reference/plugins.md"
}
