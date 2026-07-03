#!/usr/bin/env bats
#
# Behavioral tests for await-pr-checks.zsh (#412): a poll loop that observes
# "settled" must exit 0 — hand-rolled `while [ ... ]; do …; done` loops leak the
# final test's nonzero status, so a successful poll looked like a FAILURE and
# emitted misleading `failed` notifications. Nonzero is reserved for REAL
# failures: timeout, gh/auth/network error, usage. Drives the script against a
# FAKE gh (via the GH_BIN seam) so every exit path is deterministic.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/maintenance/scripts/await-pr-checks.zsh"
  CHECKS="$BATS_TEST_TMPDIR/checks.json"
  FAKE_GH="$BATS_TEST_TMPDIR/gh"
  # Fake gh: emits $CHECKS for `pr checks --json`, or simulates the no-checks /
  # auth-error conditions via env toggles.
  cat > "$FAKE_GH" <<EOF
#!/usr/bin/env bash
if [ "\${GH_NOCHECKS:-}" = "1" ]; then echo "no checks reported on the 'main' branch" >&2; exit 8; fi
if [ "\${GH_ERROR:-}" = "1" ]; then echo "HTTP 401: Bad credentials" >&2; exit 1; fi
cat "$CHECKS"
EOF
  chmod +x "$FAKE_GH"
}

# run with a fast, non-sleeping poll
await() { run env GH_BIN="$FAKE_GH" "$@" zsh "$S" --timeout 5 --interval 0 86; }

@test "await: #412 settled + all green -> exit 0" {
  printf '[{"name":"a","state":"SUCCESS","bucket":"pass"},{"name":"b","state":"SUCCESS","bucket":"pass"}]' > "$CHECKS"
  await
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "GREEN"
}

@test "await: #412 settled but RED -> still exit 0 (red is the verdict, not a poll failure)" {
  printf '[{"name":"a","state":"FAILURE","bucket":"fail"},{"name":"b","state":"SUCCESS","bucket":"pass"}]' > "$CHECKS"
  await
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "NOT-GREEN"
}

@test "await: #522 a cancelled check is neutral, not failed — verdict stays GREEN" {
  # The Approver gate's approve/approver-gate jobs are cancelled by design on
  # every run (#190), so the cancel bucket must not flip the verdict (#520).
  printf '[{"name":"ci","state":"SUCCESS","bucket":"pass"},{"name":"approve","state":"CANCELLED","bucket":"cancel"}]' > "$CHECKS"
  await
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "1 passed, 0 failed, 1 other"
  echo "$output" | grep -q "— GREEN"
}

@test "await: #412 skipped/neutral checks don't block settle and stay green" {
  printf '[{"name":"a","state":"SUCCESS","bucket":"pass"},{"name":"b","state":"SKIPPED","bucket":"skipping"}]' > "$CHECKS"
  await
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "GREEN"
}

@test "await: #412 still pending + timeout -> exit 3 (real failure)" {
  printf '[{"name":"a","state":"IN_PROGRESS","bucket":"pending"}]' > "$CHECKS"
  run env GH_BIN="$FAKE_GH" zsh "$S" --timeout 0 --interval 0 86
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "timed out"
}

@test "await: #412 PR with no checks -> exit 0 (nothing to await)" {
  : > "$CHECKS"
  await GH_NOCHECKS=1
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no checks"
}

@test "await: #412 gh auth/network error -> exit 1 (real failure)" {
  : > "$CHECKS"
  await GH_ERROR=1
  [ "$status" -eq 1 ]
}

@test "await: missing pr argument -> usage error (exit 2)" {
  run env GH_BIN="$FAKE_GH" zsh "$S"
  [ "$status" -eq 2 ]
}

@test "await: non-numeric pr -> usage error (exit 2)" {
  run env GH_BIN="$FAKE_GH" zsh "$S" not-a-number
  [ "$status" -eq 2 ]
}

@test "await: unknown flag -> usage error (exit 2)" {
  run env GH_BIN="$FAKE_GH" zsh "$S" --bogus 86
  [ "$status" -eq 2 ]
}

@test "await: gh not installed -> exit 1" {
  run env GH_BIN="$BATS_TEST_TMPDIR/nonexistent-gh" zsh "$S" 86
  [ "$status" -eq 1 ]
}
