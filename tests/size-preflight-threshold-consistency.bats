#!/usr/bin/env bats
#
# The size pre-flight's file threshold (#1437) is executable in ONE place —
# `typeset -r MAX_FILES=<n>` in size-preflight.zsh — and restated in prose in
# three live places. Nothing but these tests would catch a retune that moves the
# constant without moving its transcriptions, so the constant is READ from the
# script and every site is checked against it, in the review-loop-budget-
# consistency.bats mould:
#
#   - the DIGIT form ("more than 20 files") in the conductor, which agents read;
#   - the WORD form ("more than twenty files") in ARCHITECTURE.md, which humans
#     read. Words cannot be derived from the constant without a table, so the
#     table below is the one place a retune past its range must extend;
#   - the script's own header, which states the straddle ("20 passes, 21 stops").
#
# Both spellings are swept NEGATIVELY across every site too, so a stale number
# in either form reds here. And a repo-wide tripwire (the #936/#1188 lesson: a
# closed site list rots) finds every tracked file that restates the threshold
# beside the pre-flight, so a fourth site cannot appear unguarded.
#
# Idioms: negative assertions use `run -1` (grep's exit 2 on a missing file must
# not pass as "not found"), and digit needles are anchored with -E so "20" never
# matches inside "120".

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/development/skills/resolve-issue/scripts/size-preflight.zsh"
  SKILL="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"

  MAX="$(sed -n 's/^typeset -r MAX_FILES=\([0-9][0-9]*\)$/\1/p' "$SCRIPT")"
  [ -n "$MAX" ] || {
    printf 'typeset -r MAX_FILES=<n> not found in %s — nothing to check against\n' "$SCRIPT" >&2
    return 1
  }
  local -a words=(zero one two three four five six seven eight nine ten eleven twelve
    thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twenty-one
    twenty-two twenty-three twenty-four twenty-five twenty-six twenty-seven
    twenty-eight twenty-nine thirty)
  [ "$MAX" -lt "${#words[@]}" ] || {
    printf 'MAX_FILES=%s is past the word table — extend it\n' "$MAX" >&2
    return 1
  }
  WORD="${words[$MAX]}"
  SITES=("$SKILL" "$ARCH" "$SCRIPT")
}

@test "the threshold is read out of the script" {
  [ "$MAX" -gt 0 ]
  [ -n "$WORD" ]
}

@test "the conductor restates the threshold in digit form" {
  grep -qE "(^|[^0-9])more than ${MAX} files" "$SKILL"
}

@test "ARCHITECTURE.md restates the threshold in word form" {
  grep -qF "more than ${WORD} files" "$ARCH"
}

@test "the script header states the straddle the threshold sets" {
  grep -qE "\(${MAX} passes, $(( MAX + 1 )) stops\)" "$SCRIPT"
}

@test "no site states a different number of files in digit form" {
  local f
  for f in "${SITES[@]}"; do
    [ -r "$f" ] || { printf "site %s is missing or unreadable\n" "$f" >&2; return 1; }
    # -o, so a correct restatement on the same line cannot hide a wrong one
    run -1 grep -vxF "more than ${MAX} files" <(grep -oE 'more than [0-9]+ files' "$f")
  done
}

@test "no site states a different number of files in word form" {
  local f
  for f in "${SITES[@]}"; do
    [ -r "$f" ] || { printf "site %s is missing or unreadable\n" "$f" >&2; return 1; }
    run -1 grep -vxF "more than ${WORD} files" <(grep -oE 'more than [a-z-]+ files' "$f")
  done
}

@test "every tracked file that restates the threshold beside the pre-flight is a guarded site" {
  local -a found=()
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in docs/superpowers/*|tests/*) continue ;; esac
    grep -qE 'size[- ]pre-?flight' "$REPO_ROOT/$f" || continue
    grep -qE "more than ([0-9]+|${WORD}) files|MAX_FILES=" "$REPO_ROOT/$f" || continue
    found+=("$f")
  done < <(git -C "$REPO_ROOT" ls-files)
  local got expected
  got="$(printf '%s\n' "${found[@]}" | sort | tr '\n' ' ')"
  expected="$(printf '%s\n' "${SITES[@]#"$REPO_ROOT"/}" | sort | tr '\n' ' ')"
  [ "$got" = "$expected" ] || {
    printf 'threshold restated in [%s] but SITES guards [%s] — add the new site here\n' "$got" "$expected" >&2
    return 1
  }
}
