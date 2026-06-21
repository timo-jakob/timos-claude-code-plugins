#!/usr/bin/env bats
# format-drift-issue.bats — #402: the watcher's issue-body formatter renders
# named fixes, flags blocking required-check changes, and handles every severity.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FMT="$REPO_ROOT/development/skills/maintenance/scripts/format-drift-issue.zsh"
  J="$BATS_TEST_TMPDIR/drift.json"
}

@test "blocking drift: names the fix, flags BLOCKING, and shows the global ⚠ callout" {
  cat > "$J" <<'JSON'
[{"file":".github/workflows/quality-public.yml","severity":"drifted",
  "marker_version":"1.49.1","current_version":"1.50.0","blocking":true,
  "fixes":[{"version":"1.49.2","issue":386,"blocking":true,"summary":"image scan path-conditional"}],
  "message":"x"}]
JSON
  run zsh "$FMT" --from-file "$J"
  [ "$status" -eq 0 ]
  [[ "$output" == *"v1.49.1 → v1.50.0"* ]]
  [[ "$output" == *"#386 — image scan path-conditional"* ]]
  [[ "$output" == *"BLOCKING required-check change"* ]]
  [[ "$output" == *"REQUIRED CI check"* ]]
  [[ "$output" == *"/development:bootstrap"* ]]
}

@test "non-blocking drift: names the fix but no BLOCKING callout" {
  cat > "$J" <<'JSON'
[{"file":".github/workflows/claude-approver.yml","severity":"drifted",
  "marker_version":"1.49.0","current_version":"1.50.0","blocking":false,
  "fixes":[{"version":"1.49.1","issue":387,"blocking":false,"summary":"gate excludes advisory snyk"}],
  "message":"x"}]
JSON
  run zsh "$FMT" --from-file "$J"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#387 — gate excludes advisory snyk"* ]]
  [[ "$output" != *"BLOCKING"* ]]
  [[ "$output" != *"REQUIRED CI check"* ]]
}

@test "drift with no changelog entry falls back to the generic line" {
  cat > "$J" <<'JSON'
[{"file":".github/dependabot.yml","severity":"drifted",
  "marker_version":"1.40.0","current_version":"1.50.0","blocking":false,
  "fixes":[],"message":"x"}]
JSON
  run zsh "$FMT" --from-file "$J"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pick up the latest fixes"* ]]
}

@test "unknown_provenance is reported with a re-bootstrap hint" {
  cat > "$J" <<'JSON'
[{"file":".github/workflows/scorecard.yml","severity":"unknown_provenance","message":"no marker"}]
JSON
  run zsh "$FMT" --from-file "$J"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no provenance marker"* ]]
  [[ "$output" == *"add a marker"* ]]
}

@test "bad --from-file is a usage error (exit 2)" {
  run zsh "$FMT" --from-file "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 2 ]
}
