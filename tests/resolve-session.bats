#!/usr/bin/env bats
#
# The `resolve_session` setting (#2575): a maintainer can tell
# /development:resolve-issue whether a human is present, instead of leaving it
# to the conductor's inference. What these pin down:
#
#   * THE CONTRACT — scripts/resolve-session.zsh --inferred attended|unattended
#     prints exactly one line `<mode> <source>`. A recognised value (any case,
#     trimmed) wins with source `env`; unset or empty keeps the caller's
#     inference with source `inferred`.
#   * A TYPO IS VISIBLE — an unrecognised value keeps the inference too, but
#     says so in one stderr line naming the value, so an overnight run with a
#     mistyped setting does not silently stop at the first prompt.
#   * USAGE — a missing or invalid --inferred, an unknown flag or a stray
#     argument exits 2 with nothing on stdout; there is no other exit code.
#   * WIRING — §0a runs the helper and routes `attended` to the interactive arm
#     and `unattended` to the autonomous arm; the setting is documented and its
#     how-to is reachable from the nav.
#
# Anchored by content, never by line number (#1189).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/resolve-session.zsh"
  CONDUCTOR="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  HOWTO="$REPO_ROOT/docs/how-to/run-resolve-issue-unattended.md"
}

# run_s <value-or-UNSET> <inferred> — stdout and stderr kept apart
run_s() {
  if [ "$1" = "UNSET" ]; then
    run --separate-stderr env -u resolve_session zsh "$S" --inferred "$2"
  else
    run --separate-stderr env resolve_session="$1" zsh "$S" --inferred "$2"
  fi
}

# --- the setting wins when recognised ------------------------------------------

@test "a recognised value wins over either inference, with source env" {
  local v inf
  for inf in attended unattended; do
    for v in attended unattended; do
      run_s "$v" "$inf"
      [ "$status" -eq 0 ]
      [ "$output" = "$v env" ] || { echo "resolve_session=$v --inferred $inf: '$output'"; return 1; }
      [ -z "$stderr" ]
    done
  done
}

@test "a recognised value is read in any case and with surrounding whitespace" {
  local v
  for v in ATTENDED Attended '  attended' 'attended  ' "$(printf '\tattended\n')"; do
    run_s "$v" unattended
    [ "$status" -eq 0 ]
    [ "$output" = "attended env" ] || { echo "resolve_session='$v': '$output'"; return 1; }
    [ -z "$stderr" ]
  done
  run_s UNATTENDED attended
  [ "$output" = "unattended env" ]
}

# --- unset or empty keeps the inference ------------------------------------------

@test "unset keeps the caller's inference, with source inferred and no warning" {
  local inf
  for inf in attended unattended; do
    run_s UNSET "$inf"
    [ "$status" -eq 0 ]
    [ "$output" = "$inf inferred" ]
    [ -z "$stderr" ]
  done
}

@test "empty and whitespace-only keep the caller's inference, with no warning" {
  local v inf
  for inf in attended unattended; do
    for v in "" "   "; do
      run_s "$v" "$inf"
      [ "$status" -eq 0 ]
      [ "$output" = "$inf inferred" ] || { echo "resolve_session='$v': '$output'"; return 1; }
      [ -z "$stderr" ]
    done
  done
}

# --- an unrecognised value is visible --------------------------------------------

@test "an unrecognised value keeps the inference and warns once, naming the value" {
  local inf
  for inf in attended unattended; do
    run_s unatended "$inf"
    [ "$status" -eq 0 ]
    [ "$output" = "$inf inferred" ]
    [ "$(grep -c '' <<<"$stderr")" -eq 1 ]
    contains "$stderr" "ignoring unrecognised resolve_session value 'unatended'"
  done
}

@test "the source stays two-valued: only env or inferred is ever printed" {
  local v line
  for v in UNSET "" attended unattended yes 1 nobody; do
    run_s "$v" attended
    [ "$status" -eq 0 ]
    line="$output"
    [ "$(grep -c '' <<<"$line")" -eq 1 ]
    grep -qxE '(attended|unattended) (env|inferred)' <<<"$line" || { echo "value '$v' printed: '$line'"; return 1; }
  done
}

# --- usage -------------------------------------------------------------------------

@test "a missing --inferred exits 2 with nothing on stdout" {
  run --separate-stderr env -u resolve_session zsh "$S"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "--inferred is required"
}

@test "--inferred with no value, or an invalid value, exits 2 with nothing on stdout" {
  run --separate-stderr env resolve_session=attended zsh "$S" --inferred
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  local v
  for v in "" human ATTENDED yes; do
    run --separate-stderr env resolve_session=attended zsh "$S" --inferred "$v"
    [ "$status" -eq 2 ] || { echo "--inferred '$v' exited $status"; return 1; }
    [ -z "$output" ]
  done
}

@test "an unknown flag or a stray argument exits 2 with nothing on stdout" {
  run --separate-stderr zsh "$S" --inferred attended --mode attended
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "unknown flag: --mode"
  run --separate-stderr zsh "$S" --inferred attended extra
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "unexpected argument: extra"
}

@test "--help prints the usage line on stdout and exits 0" {
  run --separate-stderr zsh "$S" --help
  [ "$status" -eq 0 ]
  [ "$output" = "usage: resolve-session.zsh --inferred attended|unattended" ]
  run --separate-stderr zsh "$S" -h
  [ "$status" -eq 0 ]
  [ "$output" = "usage: resolve-session.zsh --inferred attended|unattended" ]
}

@test "the header documents the contract and both exit codes" {
  grep -qF 'Usage: resolve-session.zsh --inferred attended|unattended' "$S"
  grep -qF '0  a mode was printed (every case above)' "$S"
  grep -qF '2  usage — --inferred missing' "$S"
  grep -qF 'There is no other exit code.' "$S"
}

# --- wiring ------------------------------------------------------------------------

@test "§0a runs the helper with today's inference" {
  grep -qF '"<skill-base-dir>/scripts/resolve-session.zsh" --inferred <attended|unattended>' "$CONDUCTOR"
  grep -qF '`attended` when a human invoked the skill,' "$CONDUCTOR"
  grep -qF '`unattended` for an E3 child or the maintenance pipeline' "$CONDUCTOR"
}

@test "§0a routes attended to the interactive arm and unattended to the autonomous arm" {
  grep -qF '`attended` takes the interactive arm, `unattended` the' "$CONDUCTOR"
  grep -qF 'child or the maintenance pipeline stays autonomous whatever the line says (E3' "$CONDUCTOR"
  grep -qF -- '- **Autonomous / non-interactive** (mode `unattended`:' "$CONDUCTOR"
  grep -qF -- '- **Interactive** (mode `attended`: a human invoked' "$CONDUCTOR"
}

@test "§0a states the mode once and quotes the helper's warning" {
  grep -qF 'Say the mode and its source once, quoting any stderr warning,' "$CONDUCTOR"
}

@test "the helper call sits in §0a, before the precheck it governs" {
  local sec
  sec="$(awk '/^### 0a\. /{f=1} /^### 0b\. /{f=0} f' "$CONDUCTOR")"
  [ -n "$sec" ]
  contains "$sec" "resolve-session.zsh"
  # before the precheck's own invocation
  local a b
  a="$(grep -n 'resolve-session.zsh' <<<"$sec" | head -1 | cut -d: -f1)"
  b="$(grep -n 'dependency-precheck.zsh' <<<"$sec" | head -1 | cut -d: -f1)"
  [ "$a" -lt "$b" ]
}

@test "the setting is documented, and its how-to exists and is in the nav" {
  grep -qF '| `resolve_session` |' "$REPO_ROOT/docs/reference/plugins.md"
  grep -qF '(../how-to/run-resolve-issue-unattended.md)' "$REPO_ROOT/docs/reference/plugins.md"
  [ -f "$HOWTO" ]
  grep -qF '"resolve_session": "unattended"' "$HOWTO"
  grep -qF 'how-to/run-resolve-issue-unattended.md' "$REPO_ROOT/mkdocs.yml"
  grep -qF '(run-resolve-issue-unattended.md)' "$REPO_ROOT/docs/how-to/index.md"
}
