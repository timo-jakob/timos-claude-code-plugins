#!/usr/bin/env bats
# update-claude-plugins.bats — the bootstrapped "refresh the dev plugins" helper.
# Drives it against a FAKE `claude` (via the CLAUDE_BIN seam) that records every
# invocation, so we can assert it refreshes + updates the family WITHOUT ever
# touching enabled/disabled state.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/bootstrap/templates/common/scripts/update-claude-plugins.zsh"
  LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$LOG"
  cat > "$BATS_TEST_TMPDIR/list.json" <<'JSON'
[
 {"id":"development-java@timos-claude-code-plugins","scope":"user","enabled":true},
 {"id":"development@timos-claude-code-plugins","scope":"user","enabled":false},
 {"id":"agent-sdk-dev@claude-plugins-official","scope":"project","enabled":false}
]
JSON
  # Fake claude: log every call; emit the fixture for `plugin list --json`.
  FAKE="$BATS_TEST_TMPDIR/claude"
  cat > "$FAKE" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG"
if [ "\$1" = "plugin" ] && [ "\$2" = "list" ]; then cat "$BATS_TEST_TMPDIR/list.json"; fi
exit 0
EOF
  chmod +x "$FAKE"
}

run_it() { run env CLAUDE_BIN="$FAKE" zsh "$S" "$@"; }

@test "refreshes the family marketplace and updates BOTH family plugins" {
  run_it
  [ "$status" -eq 0 ]
  grep -qx "plugin marketplace update timos-claude-code-plugins" "$LOG"
  grep -qx "plugin update development-java@timos-claude-code-plugins --scope user" "$LOG"
  grep -qx "plugin update development@timos-claude-code-plugins --scope user" "$LOG"
}

@test "never changes activeness (no enable/disable calls)" {
  run_it
  [ "$status" -eq 0 ]
  run ! grep -qE '(^| )(enable|disable)( |$)' "$LOG"
}

@test "only touches the family marketplace, not others" {
  run_it
  [ "$status" -eq 0 ]
  run ! grep -q "claude-plugins-official" "$LOG"
}

@test "updates disabled family plugins too (without enabling them)" {
  run_it
  # the disabled family plugin IS updated...
  grep -qx "plugin update development@timos-claude-code-plugins --scope user" "$LOG"
  # ...but never enabled.
  run ! grep -q "enable" "$LOG"
}

@test "--dry-run mutates nothing (no marketplace update, no plugin update)" {
  run_it --dry-run
  [ "$status" -eq 0 ]
  contains "$output" "[dry-run]"
  run ! grep -q "marketplace update" "$LOG"
  run ! grep -q "plugin update" "$LOG"
}

@test "no installed family plugins -> still refreshes marketplace, exits 0 with a note" {
  printf '[]' > "$BATS_TEST_TMPDIR/list.json"
  run_it
  [ "$status" -eq 0 ]
  grep -qx "plugin marketplace update timos-claude-code-plugins" "$LOG"
  contains "$output" "No installed plugins"
}

@test "--marketplace overrides the default name (refresh happens first)" {
  run_it --marketplace other-mp
  [ "$status" -eq 0 ]
  grep -qx "plugin marketplace update other-mp" "$LOG"
}

@test "unknown arg -> usage error (exit 2)" {
  run_it --bogus
  [ "$status" -eq 2 ]
}
