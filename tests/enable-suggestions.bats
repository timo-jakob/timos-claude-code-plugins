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
#   * WIRING — the promotion reference tells the conductor to run the script at
#     the gate and states what `off` does, OUTSIDE the byte-frozen moved block
#     (verify-reference-move.zsh reds any edit inside it); the conductor's
#     CONVERGED arm names the setting; the how-to is reachable from the nav.
#
# Anchored by content, never by line number (#1189).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/suggestions-enabled.zsh"
  # #2057 split promotion.md: the gate and its enable_suggestions amendment are
  # in reference/promotion/gate.md.
  PROMO="$REPO_ROOT/development/skills/resolve-issue/reference/promotion/gate.md"
  CONDUCTOR="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
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

@test "promotion.md tells the conductor to run the script at the gate, outside the moved block" {
  # The amendment must sit BEFORE the frozen block opens, so it is read before
  # the frozen gate text and never edits bytes verify-reference-move.zsh pins.
  local before
  before="$(awk '/^<!-- moved: suggestion-promotion -->$/{exit} {print}' "$PROMO")"
  contains "$before" 'A third gate condition — the `enable_suggestions` setting.'
  contains "$before" 'scripts/suggestions-enabled.zsh'
  contains "$before" '**skip the phase entirely**, exactly as an autonomous run does'
  contains "$before" 'emit **no** step 3 enrichment record'
}

@test "the conductor's CONVERGED arm names the setting" {
  grep -qF 'gate also reads the `enable_suggestions` setting, and skips the phase when off' "$CONDUCTOR"
}

@test "the how-to exists, shows the settings key, and is in the nav" {
  [ -f "$HOWTO" ]
  grep -qF '"enable_suggestions": "0"' "$HOWTO"
  grep -qF 'how-to/turn-off-suggestion-prompts.md' "$REPO_ROOT/mkdocs.yml"
  grep -qF '(turn-off-suggestion-prompts.md)' "$REPO_ROOT/docs/how-to/index.md"
}
