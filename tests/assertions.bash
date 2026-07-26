# shellcheck shell=bash
#
# Shared bats assertion helpers (#1011).
#
# WHY THESE EXIST: on bash 3.2 — the `/bin/bash` macOS still ships, and what
# `#!/usr/bin/env bash` resolves to on this repo's primary platform — errexit
# does NOT fire on a failing `[[ ... ]]`. So a false `[[ "$output" == *"x"* ]]`
# in the middle of a test body is SILENTLY IGNORED: the test reports `ok` while
# proving nothing, unless the assertion happens to be the block's last statement
# (where its status becomes the block's own).
#
# On bash >= 4 the same assertion fails correctly. That is WORSE, not better: it
# makes an assertion's meaning depend on which machine ran it — inert on the
# maintainer's Mac and on the `bats (macos-latest)` CI leg, enforced on
# `bats (ubuntu-latest)`. A repo-wide ban is the only way to make the suite say
# one thing everywhere.
#
# Verified empirically: bats 1.10.0/1.11.0/1.12.0/1.13.0/1.14.0 ALL report `ok`
# under bash 3.2.57 and `not ok` under bash 4.4/5.2 — the bats version is not the
# variable, the bash version is. `[ ... ]` in the same position fails correctly
# on every bash, which is why it is never flagged.
#
# Each helper below is an ordinary function, so calling it is a simple command
# that errexit catches wherever it appears AS A COMMAND OF ITS OWN — position
# stops mattering. tests/no-inert-bracket-assertions.bats bans the inert
# `[[ ]]` form these replace, and fails any tests/*.bats that calls a helper
# without `load assertions`; plain `[ ... ]` remains correct and is never
# flagged.
#
# Two ways to neutralise a helper call, both still your responsibility:
#   * `a && b` — the AND-list errexit exemption applies to a function call
#     exactly as it does to `[[ ]]`, so a failing `a` is swallowed. Put each
#     assertion on its own line. An `||`-joined pair is fine (the command after
#     the final `||` is what errexit sees).
#   * a bare `!` negation — inert for its own reason, guarded by #829 in
#     tests/no-inert-negative-assertions.bats. Use `lacks` instead of negating
#     `contains`.
#
# Load from a test file with `load assertions` (bats resolves it relative to the
# test's directory).
#
# LITERAL vs REGEX: `contains`, `lacks`, `starts_with` and `ends_with` match
# LITERALLY — `${1#*"$2"}` and `case` with a quoted pattern both treat `$2` as
# plain text. That is deliberate: a `case`-based glob would silently reinterpret
# a literal like `[worktree]` as a character class, which is exactly the kind of
# quiet semantic drift this file removes. `matches` is the sole exception and
# takes an ERE — use it only when you actually want a regex.
#
# EVERY helper requires exactly TWO arguments and a NON-EMPTY `$2`, enforced
# below. Without that guard a dropped argument would make `lacks`, `starts_with`,
# `ends_with` and `matches` return true unconditionally (bats does not run test
# bodies under `set -u`, so `$2` would quietly expand to empty) — a vacuous
# assertion, which is the very defect class this file exists to eliminate.

# Guard shared by every helper. Returns 2, distinct from a genuine mismatch (1),
# so a caller that pins `$status` can tell misuse from a real failure.
#
# NOTE: bats' `run ! …` accepts ANY non-zero status, so it canNOT tell 2 from 1
# — a negated call would swallow the misuse it was meant to expose. Write a
# negative assertion as `run <helper> …; [ "$status" -eq 1 ]`, or simply use
# `lacks`. tests/assertions.bats pins both halves of this.
_assert_args() {
  if [ "$1" -ne 2 ]; then
    printf 'assertion helper: expected 2 arguments, got %s\n' "$1" >&2
    return 2
  fi
  if [ -z "$2" ]; then
    printf 'assertion helper: the needle/pattern must be non-empty\n' >&2
    return 2
  fi
}

# `$1` contains the literal substring `$2`.
contains() { _assert_args "$#" "${2-}" || return 2; [ "${1#*"$2"}" != "$1" ]; }

# `$1` does NOT contain the literal substring `$2`.
lacks() { _assert_args "$#" "${2-}" || return 2; [ "${1#*"$2"}" = "$1" ]; }

# `$1` begins with the literal string `$2`.
starts_with() {
  _assert_args "$#" "${2-}" || return 2
  case "$1" in "$2"*) return 0 ;; *) return 1 ;; esac
}

# `$1` ends with the literal string `$2`.
ends_with() {
  _assert_args "$#" "${2-}" || return 2
  case "$1" in *"$2") return 0 ;; *) return 1 ;; esac
}

# `$1` matches the extended regular expression `$2` — the replacement for
# `[[ "$x" =~ re ]]`, with the SAME whole-string semantics: `^`/`$` anchor the
# whole value, not a line. (An earlier draft piped through `grep -qE`, which
# anchors per LINE and would have silently weakened every anchored assertion to
# "some line matches".) `$2` is deliberately unquoted — quoting it would make
# the ERE literal.
matches() {
  _assert_args "$#" "${2-}" || return 2
  [[ "$1" =~ $2 ]]
}
