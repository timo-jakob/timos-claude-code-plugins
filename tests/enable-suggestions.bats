#!/usr/bin/env bats
#
# The `enable_suggestions` setting: resolve-issue's suggestion-promotion offer
# can be switched off, so a converged interactive run waives every suggestion
# and carries on to the PR without stopping. What these pin down:
#
#   * TRUTHINESS — scripts/suggestions-enabled.zsh prints `off` for 0/false/no/off
#     (any case) and `on` for unset, "" and every other value. The default is ON,
#     so an unrecognised value (a typo) must keep the prompt — the mirror of
#     switch_fable_to_opus, which fails towards ITS default of off.
#   * ONE LINE, EXIT 0 — the conductor reads the verdict at the promotion gate;
#     a non-zero exit or extra output would leave it guessing.
#   * WIRING — the how-to is reachable from the nav. Since #3128 the
#     conductor's CONVERGED arm no longer offers the phase, so it no longer
#     names the setting, and #3145 dropped the pin on the promotion reference
#     the epic #3121 retires.
#
# Anchored by content, never by line number (#1189).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/suggestions-enabled.zsh"
  HOWTO="$REPO_ROOT/docs/how-to/turn-off-suggestion-prompts.md"
}

# run_s <value-or-UNSET>
run_s() {
  if [ "$1" = "UNSET" ]; then
    run env -u enable_suggestions zsh "$S"
  else
    run env enable_suggestions="$1" zsh "$S"
  fi
}

# --- truthiness ---------------------------------------------------------------

@test "unset is on (the default)" {
  run_s UNSET
  [ "$status" -eq 0 ]
  [ "$output" = "on" ]
}

@test "empty string is on" {
  run_s ""
  [ "$status" -eq 0 ]
  [ "$output" = "on" ]
}

@test "each falsy spelling is off, in any case" {
  local v
  for v in 0 false FALSE False no NO No off OFF Off; do
    run_s "$v"
    [ "$status" -eq 0 ] || { echo "value [$v] exited $status" >&2; return 1; }
    [ "$output" = "off" ] || { echo "value [$v] printed [$output]" >&2; return 1; }
  done
}

@test "truthy and unrecognised values are on (a typo keeps the prompt)" {
  local v
  for v in 1 true yes on TRUE fals 00 " 0" nope; do
    run_s "$v"
    [ "$status" -eq 0 ] || { echo "value [$v] exited $status" >&2; return 1; }
    [ "$output" = "on" ] || { echo "value [$v] printed [$output]" >&2; return 1; }
  done
}

@test "the script is executable" {
  [ -x "$S" ]
}

# --- wiring -------------------------------------------------------------------

@test "the how-to exists, shows the settings key, and is in the nav" {
  [ -f "$HOWTO" ]
  grep -qF '"enable_suggestions": "0"' "$HOWTO"
  grep -qF 'how-to/turn-off-suggestion-prompts.md' "$REPO_ROOT/mkdocs.yml"
  grep -qF '(turn-off-suggestion-prompts.md)' "$REPO_ROOT/docs/how-to/index.md"
}
