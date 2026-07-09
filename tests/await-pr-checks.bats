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

@test "await: #641 no checks past the register grace -> exit 0 (checkless verdict)" {
  # A repo that genuinely runs no CI: the set stays empty past the grace, so
  # the legitimately-checkless verdict is reported (unchanged #412 behaviour).
  # --register-grace 0 makes the grace elapse immediately, deterministically.
  : > "$CHECKS"
  run env GH_BIN="$FAKE_GH" GH_NOCHECKS=1 zsh "$S" --timeout 5 --interval 0 --register-grace 0 86
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no checks"
}

@test "await: #641 empty check set is pending — waits through the grace until a check registers, then settles" {
  # Right after `gh pr update-branch` the head SHA has zero registered check
  # runs; "no checks reported" must be treated as pending, not a false green
  # (#641). Here gh reports empty twice, then a real (passing) check registers.
  local counter="$BATS_TEST_TMPDIR/n"; echo 0 > "$counter"
  local gh2="$BATS_TEST_TMPDIR/gh2"
  cat > "$gh2" <<EOF
#!/usr/bin/env bash
n=\$(cat "$counter"); n=\$((n + 1)); echo \$n > "$counter"
if [ "\$n" -le 2 ]; then echo "no checks reported on the 'main' branch" >&2; exit 8; fi
cat "$CHECKS"
EOF
  chmod +x "$gh2"
  printf '[{"name":"a","state":"SUCCESS","bucket":"pass"}]' > "$CHECKS"
  run env GH_BIN="$gh2" zsh "$S" --timeout 5 --interval 0 --register-grace 5 86
  [ "$status" -eq 0 ]
  # It must have observed the empty set (waited) before the check registered…
  echo "$output" | grep -q "0 checks registered yet"
  # …and then settled on the real outcome.
  echo "$output" | grep -q "GREEN"
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
