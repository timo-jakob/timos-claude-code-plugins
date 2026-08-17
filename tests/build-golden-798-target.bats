#!/usr/bin/env bats
#
# Behavioral tests for build-golden-798-target.zsh (#808, epic #810) — the
# script that materializes the #798 golden fixture as a throwaway target repo
# for /development-claude-plugin:test. The contract that matters:
#   - the last stdout line is a path to a git repo holding the pre-#798
#     SKILL.md snapshot at its original repo-relative path;
#   - the snapshot really is the defective version (the terminal case with no
#     failure branch), proven by the marker phrase absent from the fixed file;
#   - argument abuse and running outside a git worktree fail with typed codes
#     (2 usage, 3 runtime), never a half-built target on stdout.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development-claude-plugin/skills/review/scripts/build-golden-798-target.zsh"
}

teardown() {
  # Each passing run creates one mktemp dir; remove the one the test captured.
  if [ -n "${TARGET:-}" ] && [ -d "$(dirname "$TARGET")" ]; then
    rm -rf "$(dirname "$TARGET")"
  fi
}

@test "builds a git repo whose last stdout line is the target path" {
  run "$S"
  [ "$status" -eq 0 ]
  TARGET="$(echo "$output" | tail -1)"
  [ -d "$TARGET/.git" ]
}

@test "target holds the snapshot at its original repo-relative path" {
  run "$S"
  [ "$status" -eq 0 ]
  TARGET="$(echo "$output" | tail -1)"
  [ -f "$TARGET/development/skills/resolve-issue/SKILL.md" ]
}

@test "snapshot is the defective pre-#798 version, not today's fixed one" {
  run "$S"
  [ "$status" -eq 0 ]
  TARGET="$(echo "$output" | tail -1)"
  # The pre-fix terminal case licenses E4+E5 straight from "zero open
  # children"; the fixed version replaced this phrasing entirely.
  grep -q 'skip straight to \*\*E4\*\*' "$TARGET/development/skills/resolve-issue/SKILL.md"
  # And the fix's positive-evidence rule must NOT be present.
  run ! grep -q 'Positive-evidence rule' "$TARGET/development/skills/resolve-issue/SKILL.md"
}

@test "target repo has exactly one commit containing the fixture" {
  run "$S"
  [ "$status" -eq 0 ]
  TARGET="$(echo "$output" | tail -1)"
  [ "$(git -C "$TARGET" rev-list --count HEAD)" -eq 1 ]
  [ -z "$(git -C "$TARGET" status --porcelain)" ]
}

@test "rejects arguments with usage error (exit 2)" {
  run "$S" --unexpected
  [ "$status" -eq 2 ]
}

@test "fails typed (exit 3) outside a git worktree" {
  cd "$BATS_TEST_TMPDIR"
  run env GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" "$S"
  [ "$status" -eq 3 ]
}

# --- #1404: the marker guard must not stream through a pipe ------------------
# `print -r -- "$snapshot" | grep -q "$MARKER"` under `pipefail` reports a
# SUCCESSFUL match as a failed pipeline whenever the writer is still writing
# when `grep -q` exits at the match: the writer takes SIGPIPE and pipefail
# adopts its status. That reddened `bats (ubuntu-latest)` on main while macOS
# and every sequential run stayed green, because the ~39 KB snapshot fits
# Linux's default 64 KB pipe until `fs/pipe-user-pages-soft` is exceeded and
# new pipes get one 4 KiB page — which the full suite under `--jobs $(nproc)`
# reaches. The behavioural tests above cannot catch a regression here: they pass
# whenever the payload happens to fit, which is almost always. So pin the
# construct itself.
@test "the marker guard reads the snapshot without a pipe (#1404)" {
  local guard
  # the guard line: whatever feeds the DEFECT_MARKER grep
  guard="$(grep -n 'DEFECT_MARKER"' "$S" | grep -v '^[0-9]*:readonly' || true)"
  [ -n "$guard" ]
  # NEGATIVE: no writer piped into the match. Anchored on the pipe-into-grep
  # shape rather than the word `grep`, so a rewrite that keeps a pipe is caught
  # however it spells the writer.
  if printf '%s\n' "$guard" | grep -qE '\|[[:space:]]*grep'; then
    printf 'marker guard pipes into grep — see #1404:\n%s\n' "$guard" >&2
    return 1
  fi
  # POSITIVE: and it really does still check the marker, so the negative above
  # cannot be satisfied by deleting the guard outright.
  printf '%s\n' "$guard" | grep -qE 'grep -q .*DEFECT_MARKER'
}
