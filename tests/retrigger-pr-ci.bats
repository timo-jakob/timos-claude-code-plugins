#!/usr/bin/env bats
#
# Behavioral tests for retrigger-pr-ci.zsh (#605): a bot re-push to an open PR
# via a GitHub App installation token fires a `synchronize` that creates no
# workflow runs, so the new head sits with no checks and auto-merge never fires.
# This helper rescues that: it watches for a check to register (the user-push
# case where synchronize DID run CI) and, only if none does, performs a
# close+reopen nudge that reliably re-triggers CI on the current head —
# re-arming native auto-merge that closing disarmed. Drives the script against a
# FAKE gh (the GH_BIN seam) so every path is deterministic and offline.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/maintenance/scripts/retrigger-pr-ci.zsh"
  ROLLUP="$BATS_TEST_TMPDIR/rollup.json"       # response for --json …statusCheckRollup
  AUTOMERGE="$BATS_TEST_TMPDIR/automerge.json" # response for --json autoMergeRequest…
  LOG="$BATS_TEST_TMPDIR/gh.log"               # every fake-gh invocation, one per line
  FAKE_GH="$BATS_TEST_TMPDIR/gh"
  : > "$LOG"
  # Sensible defaults; individual tests overwrite.
  printf '{"headRefOid":"abc123def456","statusCheckRollup":[]}' > "$ROLLUP"
  printf '{"headRefOid":"abc123def456","autoMergeRequest":null}' > "$AUTOMERGE"

  cat > "$FAKE_GH" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG"
if [ "\${GH_ERROR:-}" = "1" ]; then echo "HTTP 401: Bad credentials" >&2; exit 1; fi
action="\$2"   # gh pr <action> …
case "\$action" in
  view)
    json=""
    while [ \$# -gt 0 ]; do [ "\$1" = "--json" ] && { json="\$2"; }; shift; done
    case "\$json" in
      *statusCheckRollup*) cat "$ROLLUP" ;;
      *autoMergeRequest*)  cat "$AUTOMERGE" ;;
      *) echo "{}" ;;
    esac
    ;;
  close)  [ "\${GH_CLOSE_FAIL:-}"  = "1" ] && { echo "close boom"  >&2; exit 1; }; exit 0 ;;
  reopen) [ "\${GH_REOPEN_FAIL:-}" = "1" ] && { echo "reopen boom" >&2; exit 1; }; exit 0 ;;
  merge)  [ "\${GH_MERGE_FAIL:-}"  = "1" ] && { echo "merge boom"  >&2; exit 1; }; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$FAKE_GH"
}

# run the script against the fake gh with a non-sleeping poll
retrig() {
  run env GH_BIN="$FAKE_GH" GH_LOG="$LOG" "$@" zsh "$S" --interval 0 --grace 5 86
}

@test "checks already registered on head -> CI-RUNNING, exit 0, no nudge" {
  printf '{"headRefOid":"abc123def456","statusCheckRollup":[{"name":"ci"}]}' > "$ROLLUP"
  retrig
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CI-RUNNING"
  # the close+reopen dance must NOT have run
  ! grep -q "pr close" "$LOG"
  ! grep -q "pr reopen" "$LOG"
}

@test "no checks + --grace 0 -> NUDGED immediately (close, reopen)" {
  run env GH_BIN="$FAKE_GH" zsh "$S" --grace 0 86
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "NUDGED"
  grep -q "pr close 86" "$LOG"
  grep -q "pr reopen 86" "$LOG"
}

@test "no auto-merge armed -> nudge does NOT re-arm merge" {
  printf '{"headRefOid":"abc123def456","autoMergeRequest":null}' > "$AUTOMERGE"
  run env GH_BIN="$FAKE_GH" zsh "$S" --grace 0 86
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "NUDGED"
  ! grep -q "pr merge" "$LOG"
}

@test "auto-merge armed (SQUASH) -> nudge re-arms with --squash --delete-branch" {
  printf '{"headRefOid":"abc123def456","autoMergeRequest":{"mergeMethod":"SQUASH"}}' > "$AUTOMERGE"
  run env GH_BIN="$FAKE_GH" zsh "$S" --grace 0 86
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "NUDGED"
  grep -q "pr merge 86 --auto --squash --delete-branch" "$LOG"
}

@test "auto-merge armed (REBASE) -> re-arm preserves the merge method" {
  printf '{"headRefOid":"abc123def456","autoMergeRequest":{"mergeMethod":"REBASE"}}' > "$AUTOMERGE"
  run env GH_BIN="$FAKE_GH" zsh "$S" --grace 0 86
  [ "$status" -eq 0 ]
  grep -q "pr merge 86 --auto --rebase --delete-branch" "$LOG"
}

@test "grace window expires with no checks -> NUDGED" {
  printf '{"headRefOid":"abc123def456","statusCheckRollup":[]}' > "$ROLLUP"
  # --grace 1 --interval 0 spins to the 1s deadline, then nudges
  run env GH_BIN="$FAKE_GH" zsh "$S" --grace 1 --interval 0 86
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "NUDGED"
}

@test "reopen fails -> NUDGE-FAILED, exit 3 (PR may be left closed)" {
  run env GH_BIN="$FAKE_GH" GH_REOPEN_FAIL=1 zsh "$S" --grace 0 86
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "NUDGE-FAILED"
}

@test "re-arm failure -> NUDGED-REARM-FAILED on stdout (CI re-triggered; re-arm is best-effort)" {
  printf '{"headRefOid":"abc123def456","autoMergeRequest":{"mergeMethod":"SQUASH"}}' > "$AUTOMERGE"
  run env GH_BIN="$FAKE_GH" GH_MERGE_FAIL=1 zsh "$S" --grace 0 86
  [ "$status" -eq 0 ]
  # the close+reopen (CI re-trigger) succeeded, so the PR was still nudged
  grep -q "pr reopen 86" "$LOG"
  # but stdout must flag the re-arm gap distinctly, not just say NUDGED
  echo "$output" | grep -q "NUDGED-REARM-FAILED"
}

@test "gh view auth/network error while watching -> exit 1" {
  run env GH_BIN="$FAKE_GH" GH_ERROR=1 zsh "$S" --grace 5 --interval 0 86
  [ "$status" -eq 1 ]
}

@test "missing pr argument -> usage error (exit 2)" {
  run env GH_BIN="$FAKE_GH" zsh "$S"
  [ "$status" -eq 2 ]
}

@test "non-numeric pr -> usage error (exit 2)" {
  run env GH_BIN="$FAKE_GH" zsh "$S" not-a-number
  [ "$status" -eq 2 ]
}

@test "bad --grace value -> usage error (exit 2)" {
  run env GH_BIN="$FAKE_GH" zsh "$S" --grace nope 86
  [ "$status" -eq 2 ]
}

@test "unknown flag -> usage error (exit 2)" {
  run env GH_BIN="$FAKE_GH" zsh "$S" --bogus 86
  [ "$status" -eq 2 ]
}

@test "gh not installed -> exit 1" {
  run env GH_BIN="$BATS_TEST_TMPDIR/nonexistent-gh" zsh "$S" 86
  [ "$status" -eq 1 ]
}
