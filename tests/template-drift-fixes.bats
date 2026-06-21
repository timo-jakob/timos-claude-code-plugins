#!/usr/bin/env bats
# template-drift-fixes.bats — #400: a `drifted` finding names the fixes a
# re-bootstrap would deliver and flags blocking required-check changes.
# Drives detect-template-drift.zsh against a fixture target repo, with a
# fixture changelog injected via the TEMPLATE_CHANGELOG seam.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DRIFT="$REPO_ROOT/development/skills/maintenance/scripts/detect-template-drift.zsh"
  # A real template path so the detector finds the template (drift comes from the
  # bogus marker hash, not a missing template).
  TPL="public/.github/workflows/quality-public.yml.tmpl"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.github/workflows"
  # Fixture changelog: one blocking fix at v1.0.0.
  CL="$BATS_TEST_TMPDIR/changelog.json"
  cat > "$CL" <<JSON
{ "$TPL": [
  { "version": "1.0.0", "issue": 999, "blocking": true,
    "summary": "the test fix" } ] }
JSON
}

# write a rendered file whose marker references $TPL at version $1, bogus hash.
render_marker() {
  printf '# claude-bootstrap: rendered from %s @ v%s sha256:deadbeefdeadbeef\nname: x\n' \
    "$TPL" "$1" > "$REPO/.github/workflows/quality-public.yml"
}

@test "drifted finding names the fix when the marker predates it" {
  render_marker "0.1.0"
  run env TEMPLATE_CHANGELOG="$CL" zsh "$DRIFT" "$REPO"
  [ "$status" -eq 0 ]
  f="$(printf '%s' "$output" | jq -c '.[] | select(.severity=="drifted")')"
  [ "$(printf '%s' "$f" | jq '.fixes | length')" -eq 1 ]
  [ "$(printf '%s' "$f" | jq '.fixes[0].issue')" -eq 999 ]
  [ "$(printf '%s' "$f" | jq '.blocking')" = "true" ]
  [[ "$(printf '%s' "$f" | jq -r '.message')" == *"#999"* ]]
  [[ "$(printf '%s' "$f" | jq -r '.message')" == *"BLOCKING"* ]]
}

@test "no fixes named when the marker is at/after the fix version" {
  render_marker "1.0.0"
  run env TEMPLATE_CHANGELOG="$CL" zsh "$DRIFT" "$REPO"
  [ "$status" -eq 0 ]
  f="$(printf '%s' "$output" | jq -c '.[] | select(.severity=="drifted")')"
  [ "$(printf '%s' "$f" | jq '.fixes | length')" -eq 0 ]
  [ "$(printf '%s' "$f" | jq '.blocking')" = "false" ]
  [[ "$(printf '%s' "$f" | jq -r '.message')" == *"pick up upstream fixes"* ]]
}

@test "degrades gracefully when the changelog has no entry for the template" {
  render_marker "0.1.0"
  empty="$BATS_TEST_TMPDIR/empty.json"; printf '{}' > "$empty"
  run env TEMPLATE_CHANGELOG="$empty" zsh "$DRIFT" "$REPO"
  [ "$status" -eq 0 ]
  f="$(printf '%s' "$output" | jq -c '.[] | select(.severity=="drifted")')"
  [ "$(printf '%s' "$f" | jq '.fixes | length')" -eq 0 ]
  [ "$(printf '%s' "$f" | jq '.blocking')" = "false" ]
}

@test "non-blocking fix names the fix but does not flag blocking" {
  cat > "$CL" <<JSON
{ "$TPL": [
  { "version": "1.0.0", "issue": 888, "blocking": false,
    "summary": "a non-gating tweak" } ] }
JSON
  render_marker "0.1.0"
  run env TEMPLATE_CHANGELOG="$CL" zsh "$DRIFT" "$REPO"
  f="$(printf '%s' "$output" | jq -c '.[] | select(.severity=="drifted")')"
  [ "$(printf '%s' "$f" | jq '.fixes | length')" -eq 1 ]
  [ "$(printf '%s' "$f" | jq '.blocking')" = "false" ]
  [[ "$(printf '%s' "$f" | jq -r '.message')" != *"BLOCKING"* ]]
}

@test "the shipped changelog is valid JSON" {
  run jq empty "$REPO_ROOT/development/skills/maintenance/reference/template-changelog.json"
  [ "$status" -eq 0 ]
}
