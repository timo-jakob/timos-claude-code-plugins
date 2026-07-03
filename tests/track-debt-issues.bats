#!/usr/bin/env bats
#
# Tests for track-debt-issues.zsh — the maintenance issue tracker (#58, #384).
# Argument-validation paths exit before any gh call; the main-path tests (#530)
# shadow `gh` with a fake via PATH so the abort regressions are exercised
# deterministically: a tool with exactly ONE finding must not kill the script
# (the plural command-substitution returned exit 1 under set -e), and a label
# that already exists must not either (the list|grep -q pipeline raced under
# pipefail via SIGPIPE and the fallback `gh label create` died on
# "already exists").

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TRACK="$REPO_ROOT/development/skills/maintenance/scripts/track-debt-issues.zsh"

  STUB="$BATS_TEST_TMPDIR/bin"
  TITLE_LOG="$BATS_TEST_TMPDIR/titles"
  mkdir -p "$STUB"
  : > "$TITLE_LOG"
  # Fake gh: env toggles simulate label state; issue create/edit log --title
  # so tests can assert the singular/plural rendering.
  cat > "$STUB/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "label create")
    if [ "\${GH_LABEL_EXISTS:-}" = "1" ]; then
      echo "label with name \"\$3\" already exists; use \\\`--force\\\` to update its color and description" >&2
      exit 1
    fi
    if [ "\${GH_LABEL_FAIL:-}" = "1" ]; then echo "HTTP 502: server error" >&2; exit 1; fi
    exit 0 ;;
  "label list") echo ""; exit 0 ;;
  "issue list") echo "\${GH_ISSUE_LIST:-[]}"; exit 0 ;;
  "issue create"|"issue edit")
    while [ \$# -gt 0 ]; do [ "\$1" = "--title" ] && echo "\$2" >> "$TITLE_LOG"; shift; done
    echo "https://github.com/x/y/issues/99"; exit 0 ;;
  "issue close") exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB/gh"
}

# run the main path against the fake gh (PATH shadowing — no network).
track() { run env PATH="$STUB:$PATH" "$@" zsh "$TRACK" --findings "$BATS_TEST_TMPDIR/f.json" --repo "$BATS_TEST_TMPDIR"; }

findings() { printf '%s' "$1" > "$BATS_TEST_TMPDIR/f.json"; }
ONE_HOTSPOT='{"findings_by_tool":{"sonarcloud":[{"type":"SECURITY_HOTSPOT","rule":"java:S6474","component":"build.gradle.kts","line":1,"message":"m"}]}}'

@test "track-debt-issues: --findings is required (exit 2)" {
  run zsh "$TRACK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--findings is required"* ]]
}

@test "track-debt-issues: nonexistent findings file (exit 1)" {
  run zsh "$TRACK" --findings "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"findings file not found"* ]]
}

@test "track-debt-issues: unknown arg (exit 2)" {
  run zsh "$TRACK" --bogus x
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown arg"* ]]
}

@test "track-debt-issues: --run-ref is recognized, not treated as unknown (#384)" {
  # With --run-ref parsed and --findings still absent, it must fail on the
  # missing --findings — NOT complain about an unknown arg.
  run zsh "$TRACK" --run-ref "2026-06-20 (branch test)"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--findings is required"* ]]
  [[ "$output" != *"unknown arg"* ]]
}

@test "#530 a tool with exactly ONE finding is processed (singular title) and later tools still run" {
  # The plural substitution `$([[ $count -ne 1 ]] && print -- s)` exited 1 for
  # count == 1 and set -e killed the script silently — sonarcloud's single
  # hotspot aborted the tick-client-snapper run before container_scan.
  findings "$ONE_HOTSPOT"
  track
  [ "$status" -eq 0 ]
  grep -qx "\[maintenance\] sonarcloud debt (1 finding)" "$TITLE_LOG"
  [[ "$output" == *"created:"* ]]
  [[ "$output" == *"container_scan has zero findings"* ]]   # the loop CONTINUED past count==1
}

@test "#530 plural stays plural (2 findings)" {
  findings '{"findings_by_tool":{"sonarcloud":[{"type":"BUG","rule":"r1","component":"a","line":1,"message":"m"},{"type":"BUG","rule":"r2","component":"b","line":2,"message":"m"}]}}'
  track
  [ "$status" -eq 0 ]
  grep -qx "\[maintenance\] sonarcloud debt (2 findings)" "$TITLE_LOG"
}

@test "#530 pre-existing labels are not fatal (ensure_label is idempotent)" {
  # `gh label list | grep -qx` raced under pipefail (grep -q exits at first
  # match → gh takes SIGPIPE → pipeline "fails" → create runs → "already
  # exists" → set -e death). The create must treat an existing label as
  # success instead.
  findings '{"findings_by_tool":{}}'
  track GH_LABEL_EXISTS=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}

@test "#530 a genuine label-create failure is still fatal and surfaced" {
  findings '{"findings_by_tool":{}}'
  track GH_LABEL_FAIL=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"HTTP 502"* ]]
}
