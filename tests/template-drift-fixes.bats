#!/usr/bin/env bats
# template-drift-fixes.bats — #400: a `drifted` finding names the fixes a
# re-bootstrap would deliver and flags blocking required-check changes.
# Drives detect-template-drift.zsh against a fixture target repo, with a
# fixture changelog injected via the TEMPLATE_CHANGELOG seam.

load assertions

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
  contains "$(printf '%s' "$f" | jq -r '.message')" "#999"
  contains "$(printf '%s' "$f" | jq -r '.message')" "BLOCKING"
}

@test "no fixes named when the marker is at/after the fix version" {
  render_marker "1.0.0"
  run env TEMPLATE_CHANGELOG="$CL" zsh "$DRIFT" "$REPO"
  [ "$status" -eq 0 ]
  f="$(printf '%s' "$output" | jq -c '.[] | select(.severity=="drifted")')"
  [ "$(printf '%s' "$f" | jq '.fixes | length')" -eq 0 ]
  [ "$(printf '%s' "$f" | jq '.blocking')" = "false" ]
  contains "$(printf '%s' "$f" | jq -r '.message')" "pick up upstream fixes"
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
  lacks "$(printf '%s' "$f" | jq -r '.message')" "BLOCKING"
}

@test "the shipped changelog is valid JSON" {
  run jq empty "$REPO_ROOT/development/skills/maintenance/reference/template-changelog.json"
  [ "$status" -eq 0 ]
}

@test "the §3l IaC workflow is TRACKED, so its drift is reported (#1154)" {
  # detect-template-drift.zsh's `tracked` array is the detector's whole input —
  # the loop iterates it exclusively. Bootstrap's Step 3.6 stamps
  # kubernetes-ci.yml with a provenance marker, so if the entry is dropped or
  # misspelled here the marker is written and never consumed, and a consumer
  # repo whose workflow has fallen behind the template is reported drift-free
  # FOREVER — silently. Nothing exercised the entry until now.
  local iac_tpl="iac/.github/workflows/kubernetes-ci.yml.tmpl"
  printf '# claude-bootstrap: rendered from %s @ v0.1.0 sha256:deadbeefdeadbeef\nname: kubernetes-ci\n' \
    "$iac_tpl" > "$REPO/.github/workflows/kubernetes-ci.yml"
  run env TEMPLATE_CHANGELOG="$CL" zsh "$DRIFT" "$REPO"
  [ "$status" -eq 0 ]
  # the file must appear in the findings AT ALL — that is what the tracked entry buys
  local f
  f="$(printf '%s' "$output" | jq -c '.[] | select(.file == ".github/workflows/kubernetes-ci.yml")')"
  [ -n "$f" ]
  [ "$(printf '%s' "$f" | jq -r '.severity')" = "drifted" ]
}

@test "the #1206 direct-to-cluster gate workflow is TRACKED (#1206)" {
  # same coupling, the other required check: `no-cluster-deploy` is a REQUIRED
  # context in every bootstrapped application repo, so a consumer running a
  # stale copy of the checker workflow keeps reporting green against an older
  # command set — and without this entry the Step 3.6 marker is written and
  # never consumed, so that staleness is invisible forever.
  local tpl
  tpl="common/.github/workflows/no-cluster-deploy.yml.tmpl"
  printf '# claude-bootstrap: rendered from %s @ v0.1.0 sha256:deadbeefdeadbeef\nname: no-cluster-deploy\n' \
    "$tpl" > "$REPO/.github/workflows/no-cluster-deploy.yml"
  run env TEMPLATE_CHANGELOG="$CL" zsh "$DRIFT" "$REPO"
  [ "$status" -eq 0 ]
  local f
  f="$(printf '%s' "$output" | jq -c '.[] | select(.file == ".github/workflows/no-cluster-deploy.yml")')"
  [ -n "$f" ]
  [ "$(printf '%s' "$f" | jq -r '.severity')" = "drifted" ]
}

@test "the #1206 CHECKER SCRIPT is TRACKED too — the half that goes stale (#1206)" {
  # detect-template-drift.zsh's own comment says the checker "holds the matched
  # command set, so it is the half that actually goes stale", and that tracking
  # only the workflow would leave exactly this drift invisible. It also exercises
  # a marker layout no other tracked path has: line 2, after a shebang, which is
  # where stamp-marker.zsh writes it (#783) and where the detector's
  # `head -10 | grep` must still find it.
  local tpl
  tpl="common/scripts/check-no-cluster-deploy.zsh"
  mkdir -p "$REPO/scripts"
  printf '#!/usr/bin/env zsh\n# claude-bootstrap: rendered from %s @ v0.1.0 sha256:deadbeefdeadbeef\nemulate -L zsh\n' \
    "$tpl" > "$REPO/scripts/check-no-cluster-deploy.zsh"
  run env TEMPLATE_CHANGELOG="$CL" zsh "$DRIFT" "$REPO"
  [ "$status" -eq 0 ]
  local f
  f="$(printf '%s' "$output" | jq -c '.[] | select(.file == "scripts/check-no-cluster-deploy.zsh")')"
  [ -n "$f" ]
  [ "$(printf '%s' "$f" | jq -r '.severity')" = "drifted" ]
}

# --- #689/#1358: the stamp table and the drift array must name the same files -
#
# Two lists, one invariant, in different files: SKILL.md Step 3.6's table drives
# STAMPING (bootstrap writes the marker) and detect-template-drift's `tracked`
# array drives DETECTION (maintenance reads it). They were in exact 1:1
# correspondence — an UNWRITTEN invariant, which this branch broke silently by
# adding §3i rows to the table and not the array: bootstrap then wrote markers no
# consumer read, and a stale contracts-lint.yml was reported drift-free forever.
# The detector's own kubernetes-ci comment states the rule; nothing enforced it.

@test "#689 the Step 3.6 stamp table and detect-template-drift's tracked array agree" {
  local skill="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  local detector="$REPO_ROOT/development/skills/maintenance/scripts/detect-template-drift.zsh"
  local table arr

  # Table targets: the first backticked cell of each row of the pairs table.
  table="$(sed -n '/^| Target | Template |/,/^$/p' "$skill" \
    | sed -n 's/^| `\([^`]*\)`.*/\1/p' | sort -u)"
  # Array entries: the quoted paths inside `typeset -a tracked=( … )`.
  arr="$(sed -n '/^typeset -a tracked=(/,/^)/p' "$detector" \
    | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p' | sort -u)"

  # Canaries: a slice that captured nothing would compare "" to "" and pass.
  [ "$(printf '%s\n' "$table" | grep -c .)" -ge 15 ]
  [ "$(printf '%s\n' "$arr" | grep -c .)" -ge 15 ]

  if [ "$table" != "$arr" ]; then
    printf 'stamped-but-never-read (table, not tracked):\n' >&2
    comm -23 <(printf '%s\n' "$table") <(printf '%s\n' "$arr") >&2
    printf 'tracked-but-never-stamped (tracked, not table):\n' >&2
    comm -13 <(printf '%s\n' "$table") <(printf '%s\n' "$arr") >&2
    return 1
  fi
}
