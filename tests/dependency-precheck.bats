#!/usr/bin/env bats
#
# Behavioral tests for dependency-precheck.zsh (#585): the single-issue
# dependency gate of /development:resolve-issue (epic #583). What these tests
# pin down is the typed decision contract on top of the shared reader (#584):
# PROCEED (0) only when no open blockers exist, REJECT_BLOCKED (10) naming
# every open blocker in the argumentation, REJECT_CYCLE (11) winning over
# blockers (a cycle can never be satisfied, so "resolve these first" would be
# a lie), and a machine-findable marker on every rejection comment.
#
# The reader is stubbed via the DEPS_BIN seam: the stub emits $DEPS_JSON with
# exit $DEPS_STATUS and records its argv, so the graph under test is fully
# deterministic and needs no gh/network.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/dependency-precheck.zsh"

  DEPS_ARGS_FILE="$BATS_TEST_TMPDIR/deps-args"
  STUB="$BATS_TEST_TMPDIR/deps-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$DEPS_ARGS_FILE"
echo "$DEPS_JSON"
exit "${DEPS_STATUS:-0}"
EOF
  chmod +x "$STUB"
}

precheck() {  # $1 = reader result JSON ; rest = extra flags
  local json="$1"; shift
  run env DEPS_BIN="$STUB" DEPS_JSON="$json" DEPS_ARGS_FILE="$DEPS_ARGS_FILE" \
    zsh "$S" --repo owner/repo --issue 50 "$@"
}

# ---- usage errors -----------------------------------------------------------

@test "usage: missing --repo exits 2" {
  run zsh "$S" --issue 5
  [ "$status" -eq 2 ]
}

@test "usage: missing --issue exits 2" {
  run zsh "$S" --repo owner/repo
  [ "$status" -eq 2 ]
}

# ---- PROCEED ----------------------------------------------------------------

@test "no blockers at all -> PROCEED, exit 0, no comment" {
  precheck '{"issue":50,"blocked":false,"open_blockers":[],"blockers":[],"cycles":[],"truncated":false}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .decision)" = "PROCEED" ]
  [ "$(echo "$output" | jq -r .comment_md)" = "null" ]
}

@test "closed-only blockers -> PROCEED (a met prerequisite doesn't block)" {
  precheck '{"issue":50,"blocked":false,"open_blockers":[],"blockers":[{"number":9,"state":"CLOSED","open":false,"kind":"issue","depth":1}],"cycles":[],"truncated":false}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .decision)" = "PROCEED" ]
}

# ---- REJECT_BLOCKED ---------------------------------------------------------

@test "open blockers -> REJECT_BLOCKED, exit 10" {
  precheck '{"issue":50,"blocked":true,"open_blockers":[11],"blockers":[{"number":11,"state":"OPEN","open":true,"kind":"issue","depth":1}],"cycles":[],"truncated":false}'
  [ "$status" -eq 10 ]
  [ "$(echo "$output" | jq -r .decision)" = "REJECT_BLOCKED" ]
}

@test "the blocked argumentation names every open blocker, not the closed ones" {
  precheck '{"issue":50,"blocked":true,"open_blockers":[11,13],"blockers":[
    {"number":11,"state":"OPEN","open":true,"kind":"issue","depth":1},
    {"number":12,"state":"CLOSED","open":false,"kind":"issue","depth":1},
    {"number":13,"state":"OPEN","open":true,"kind":"issue","depth":2}],"cycles":[],"truncated":false}'
  [ "$status" -eq 10 ]
  comment="$(echo "$output" | jq -r .comment_md)"
  [[ "$comment" == *"#11"* ]]
  [[ "$comment" == *"#13"* ]]
  [[ "$comment" != *"#12"* ]]
}

@test "an epic blocker is called out as an epic in the argumentation" {
  precheck '{"issue":50,"blocked":true,"open_blockers":[20],"blockers":[{"number":20,"state":"OPEN","open":true,"kind":"epic","depth":1}],"cycles":[],"truncated":false}'
  [ "$status" -eq 10 ]
  [[ "$(echo "$output" | jq -r .comment_md)" == *"**epic**"* ]]
}

@test "the blocked comment carries the machine-findable marker and a re-run hint" {
  precheck '{"issue":50,"blocked":true,"open_blockers":[11],"blockers":[{"number":11,"state":"OPEN","open":true,"kind":"issue","depth":1}],"cycles":[],"truncated":false}'
  comment="$(echo "$output" | jq -r .comment_md)"
  [[ "$comment" == *"<!-- dependency-precheck: REJECT_BLOCKED -->"* ]]
  [[ "$comment" == *"/development:resolve-issue 11"* ]]
  [[ "$comment" == *"/development:resolve-issue 50"* ]]
}

@test "a truncated traversal adds the incompleteness caution" {
  precheck '{"issue":50,"blocked":true,"open_blockers":[11],"blockers":[{"number":11,"state":"OPEN","open":true,"kind":"issue","depth":1}],"cycles":[],"truncated":true}'
  [[ "$(echo "$output" | jq -r .comment_md)" == *"may be incomplete"* ]]
}

# ---- REJECT_CYCLE -----------------------------------------------------------

@test "a cycle -> REJECT_CYCLE, exit 11, comment names the cycle path" {
  precheck '{"issue":50,"blocked":true,"open_blockers":[21],"blockers":[{"number":21,"state":"OPEN","open":true,"kind":"issue","depth":1}],"cycles":[[50,21,50]],"truncated":false}'
  [ "$status" -eq 11 ]
  [ "$(echo "$output" | jq -r .decision)" = "REJECT_CYCLE" ]
  comment="$(echo "$output" | jq -r .comment_md)"
  [[ "$comment" == *"#50 → #21 → #50"* ]]
  [[ "$comment" == *"<!-- dependency-precheck: REJECT_CYCLE -->"* ]]
}

@test "cycle wins over open blockers (both present -> REJECT_CYCLE)" {
  precheck '{"issue":50,"blocked":true,"open_blockers":[11,21],"blockers":[
    {"number":11,"state":"OPEN","open":true,"kind":"issue","depth":1},
    {"number":21,"state":"OPEN","open":true,"kind":"issue","depth":1}],"cycles":[[50,21,50]],"truncated":false}'
  [ "$status" -eq 11 ]
  [ "$(echo "$output" | jq -r .decision)" = "REJECT_CYCLE" ]
}

# ---- plumbing ---------------------------------------------------------------

@test "reader failure propagates as internal error (exit 1)" {
  DEPS_STATUS=1
  run env DEPS_BIN="$STUB" DEPS_JSON='' DEPS_STATUS=1 DEPS_ARGS_FILE="$DEPS_ARGS_FILE" \
    zsh "$S" --repo owner/repo --issue 50
  [ "$status" -eq 1 ]
}

@test "--max-depth is forwarded to the reader" {
  precheck '{"issue":50,"blocked":false,"open_blockers":[],"blockers":[],"cycles":[],"truncated":false}' --max-depth 3
  [ "$status" -eq 0 ]
  grep -q -- "--max-depth 3" "$DEPS_ARGS_FILE"
}

@test "repo and issue are forwarded to the reader" {
  precheck '{"issue":50,"blocked":false,"open_blockers":[],"blockers":[],"cycles":[],"truncated":false}'
  grep -q -- "--repo owner/repo --issue 50" "$DEPS_ARGS_FILE"
}
