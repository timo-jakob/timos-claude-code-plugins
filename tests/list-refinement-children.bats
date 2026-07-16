#!/usr/bin/env bats
#
# Behavioral tests for list-refinement-children.zsh (#580, epic #573; source
# swapped to native sub-issues by #802) — the enumerator epic-aware
# refine-issue uses to find an epic's children that still need refinement. The
# contract: read the epic's children from the shared sub-issues reader (the
# markdown task list is never parsed here — fence/first-ref semantics are the
# reader's and backfill's business), and keep the OPEN ones carrying
# `needs-refinement`, in sub-issue order.
#
# The shared reader is stubbed via the SUBISSUES_BIN seam (canned reader JSON);
# `gh` is shadowed via PATH with a fake keyed on issue number for the per-child
# label lookups.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/refine-issue/scripts/list-refinement-children.zsh"
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"

  # Epic #500's native children: #601 open+needs-refinement, #602 open
  # no-label, #603 closed+needs-refinement, #604 open+needs-refinement.
  cat > "$STUB/reader-output.json" <<'EOF'
{"epic":500,"summary":{"total":4,"completed":1},
 "children":[{"number":601,"state":"OPEN","open":true},
             {"number":602,"state":"OPEN","open":true},
             {"number":603,"state":"CLOSED","open":false},
             {"number":604,"state":"OPEN","open":true}],
 "open_children":[601,602,604]}
EOF

  # Fake shared reader: serves the canned JSON (or fails when told to).
  cat > "$STUB/read-sub-issues.zsh" <<EOF
#!/usr/bin/env zsh
[[ -f "$STUB/reader-fails" ]] && { print -u2 "reader: boom"; exit 1 }
cat "$STUB/reader-output.json"
EOF
  chmod +x "$STUB/read-sub-issues.zsh"

  # Fake gh: `issue view <n> --json labels` returns per-child labels.
  cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
num="$3"
case "$num" in
  601) echo '{"labels":[{"name":"needs-refinement"},{"name":"feat"}]}' ;;
  602) echo '{"labels":[{"name":"feat"}]}' ;;
  604) echo '{"labels":[{"name":"needs-refinement"}]}' ;;
  *)   echo '{"labels":[]}' ;;
esac
exit 0
EOF
  chmod +x "$STUB/gh"
}
run_list() {
  run env PATH="$STUB:$PATH" SUBISSUES_BIN="$STUB/read-sub-issues.zsh" zsh "$S" "$@"
}

@test "lists only OPEN children carrying needs-refinement, in sub-issue order" {
  run_list --repo o/r --epic 500
  [ "$status" -eq 0 ]
  # 601 (open+label) and 604 (open+label) qualify; 602 (no label) and 603
  # (closed — never even label-checked, the reader already filtered it) do not.
  [ "$output" = "$(printf '601\n604')" ]
}

@test "closed children are excluded even when they carry needs-refinement" {
  cat > "$STUB/reader-output.json" <<'EOF'
{"epic":500,"summary":{"total":1,"completed":1},
 "children":[{"number":603,"state":"CLOSED","open":false}],
 "open_children":[]}
EOF
  run_list --repo o/r --epic 500
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an epic with no refinable children prints nothing (clean exit 0 — terminal case)" {
  cat > "$STUB/reader-output.json" <<'EOF'
{"epic":500,"summary":{"total":1,"completed":0},
 "children":[{"number":602,"state":"OPEN","open":true}],
 "open_children":[602]}
EOF
  run_list --repo o/r --epic 500
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an epic with ZERO native children (un-backfilled / never decomposed) is a clean empty exit 0" {
  cat > "$STUB/reader-output.json" <<'EOF'
{"epic":500,"summary":{"total":0,"completed":0},"children":[],"open_children":[]}
EOF
  run_list --repo o/r --epic 500
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a child whose label fetch fails is skipped (with a stderr notice), not fatal" {
  # gh fails for #601; #604 must still be listed
  cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
num="$3"
case "$num" in
  601) echo "gh: 500" >&2; exit 1 ;;
  604) echo '{"labels":[{"name":"needs-refinement"}]}' ;;
  *)   echo '{"labels":[]}' ;;
esac
EOF
  chmod +x "$STUB/gh"
  run_list --repo o/r --epic 500
  [ "$status" -eq 0 ]
  # stdout carries only the qualifying child; the skip is noted on stderr
  # (bats merges the streams into $output, so assert on lines)
  [[ "$output" == *"skipping #601"* ]]
  [ "$(echo "$output" | grep -v 'skipping')" = "604" ]
}

@test "EVERY label fetch failing is a systemic gh failure (exit 3), never a false 'nothing to refine'" {
  cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: auth required" >&2; exit 1
EOF
  chmod +x "$STUB/gh"
  run_list --repo o/r --epic 500
  [ "$status" -eq 3 ]
  [[ "$output" == *"every child's label fetch failed"* ]]
}

@test "a gh response missing the labels key skips that child without aborting the walk" {
  cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
num="$3"
case "$num" in
  601) echo '{}' ;;
  604) echo '{"labels":[{"name":"needs-refinement"}]}' ;;
  *)   echo '{"labels":[]}' ;;
esac
exit 0
EOF
  chmod +x "$STUB/gh"
  run_list --repo o/r --epic 500
  [ "$status" -eq 0 ]
  [ "$output" = "604" ]
}

@test "the default SUBISSUES_BIN resolves to the real shared reader (the #802 cross-skill wiring)" {
  # No SUBISSUES_BIN override: the script must find
  # ../../resolve-issue/scripts/read-sub-issues.zsh relative to itself, and that
  # real reader calls `gh api graphql` — served by the PATH stub below.
  cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  cat <<'JSON'
{"data":{"repository":{"issue":{"number":500,
  "subIssuesSummary":{"total":1,"completed":0},
  "subIssues":{"nodes":[{"number":604,"state":"OPEN",
    "repository":{"nameWithOwner":"o/r"}}]}}}}}
JSON
  exit 0
fi
echo '{"labels":[{"name":"needs-refinement"}]}'
EOF
  chmod +x "$STUB/gh"
  run env PATH="$STUB:$PATH" zsh "$S" --repo o/r --epic 500
  [ "$status" -eq 0 ]
  [ "$output" = "604" ]
}

@test "regression: a failed reader run is the documented runtime error (exit 3)" {
  touch "$STUB/reader-fails"
  run_list --repo o/r --epic 500
  [ "$status" -eq 3 ]
  [[ "$output" == *"failed to read sub-issues"* ]]
}

@test "a missing shared reader is the documented runtime error (exit 3)" {
  run env PATH="$STUB:$PATH" SUBISSUES_BIN="$STUB/does-not-exist.zsh" zsh "$S" --repo o/r --epic 500
  [ "$status" -eq 3 ]
  [[ "$output" == *"shared reader not found"* ]]
}

@test "missing --repo is a usage error (exit 2)" {
  run_list --epic 500
  [ "$status" -eq 2 ]
  [[ "$output" == *"--repo is required"* ]]
}

@test "missing --epic is a usage error (exit 2)" {
  run_list --repo o/r
  [ "$status" -eq 2 ]
  [[ "$output" == *"--epic is required"* ]]
}

@test "non-numeric --epic is a usage error (exit 2)" {
  run_list --repo o/r --epic abc
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be a number"* ]]
}

@test "a dangling --repo (no value) is a usage error (exit 2)" {
  run_list --epic 500 --repo
  [ "$status" -eq 2 ]
  [[ "$output" == *"--repo needs a value"* ]]
}

@test "a dangling --epic (no value) is a usage error (exit 2)" {
  run_list --repo o/r --epic
  [ "$status" -eq 2 ]
  [[ "$output" == *"--epic needs a value"* ]]
}

@test "unknown arg is a usage error (exit 2)" {
  run_list --repo o/r --epic 500 --bogus x
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown arg"* ]]
}
