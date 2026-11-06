#!/usr/bin/env bats
#
# add-blocked-by-edges.zsh (#2947): refinement declares a story's prerequisites
# as GitHub-native blockedBy edges, so a story whose only readiness objection is
# a prose-only dependency passes check 3 at the re-gate with no manual `gh api`
# call. Pinned by what reached GitHub (the stub's write log), never by what the
# script says about itself:
#
#   - each new edge is POSTed by the target's database id; an existing one is
#     skipped, so a re-run writes nothing;
#   - a self-reference, an edge that would close a cycle, and an edge the
#     reader cannot prove acyclic are refused with no write (exit 4);
#   - a failed write or id lookup is reported by name (exit 5), never dropped;
#   - the refiner fixture turn's proposed_blocked_by carries the prose-named
#     prerequisite and not the context-only reference.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/refine-issue/scripts/add-blocked-by-edges.zsh"
  TURN="$REPO_ROOT/tests/fixtures/refiner-turns/blocked-by-turn.json"
  REFS="$BATS_TEST_TMPDIR/refs.json"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log" STUB_DIR="$BATS_TEST_TMPDIR/stub"
  : > "$GH_LOG"
  mkdir -p "$STUB_DIR"
  # $STUB_DIR/existing: the issue's current blockers, one `owner/repo#M` a line.
  : > "$STUB_DIR/existing"

  export GH_BIN="$BATS_TEST_TMPDIR/gh-stub.sh"
  cat > "$GH_BIN" <<'EOF'
#!/usr/bin/env bash
log() { printf '%s\n' "$*" >> "$GH_LOG"; }
if [ "$1" = api ] && [ "$2" = -X ]; then
  log "post $4 $6"
  [ -n "${FAIL_POST:-}" ] && { echo "gh: HTTP 403 Resource not accessible" >&2; exit 1; }
  exit 0
fi
if [ "$1" = api ] && [ "$2" = --paginate ]; then
  [ -n "${FAIL_READ:-}" ] && exit 1
  cat "$STUB_DIR/existing"; exit 0
fi
if [ "$1" = api ]; then
  case "$2" in
    *other/repo/issues/*) [ -n "${FAIL_FOREIGN_ID:-}" ] && { echo "gh: HTTP 404" >&2; exit 1; } ;;
  esac
  n="${2##*/}"; echo $(( 100000 + n )); exit 0
fi
echo "unexpected gh call: $*" >&2; exit 99
EOF
  chmod +x "$GH_BIN"

  # Fake read-dependencies.zsh: $STUB_DIR/deps-<M>.json is M's reader document,
  # defaulting to "no blockers"; FAIL_READER makes it exit 1.
  export READ_DEPS_BIN="$BATS_TEST_TMPDIR/reader-stub.zsh"
  cat > "$READ_DEPS_BIN" <<'EOF'
[ -n "${FAIL_READER:-}" ] && exit 1
printf 'reader %s\n' "$*" >> "$GH_LOG.reader"
n=""; prev=""
for a in "$@"; do [ "$prev" = --issue ] && n="$a"; prev="$a"; done
if [ -f "$STUB_DIR/deps-$n.json" ]; then cat "$STUB_DIR/deps-$n.json"
else printf '%s\n' '{"blockers":[],"foreign_blockers":[],"cycles":[],"truncated":false}'; fi
EOF
}

edges() {
  run --separate-stderr zsh "$S" --repo o/r --issue 954 --refs "$REFS" "$@"
}

@test "each new edge is added by the target's database id, own-repo refs normalised" {
  printf '%s' '["#953", "o/r#52", "other/repo#7"]' > "$REFS"
  edges
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.issue == 954 and
    ([.edges[] | [.ref, .status, .detail]] ==
     [["#953","added",null],["#52","added",null],["other/repo#7","added",null]])' >/dev/null
  grep -qx 'post repos/o/r/issues/954/dependencies/blocked_by issue_id=100953' "$GH_LOG"
  grep -qx 'post repos/o/r/issues/954/dependencies/blocked_by issue_id=100052' "$GH_LOG"
  grep -qx 'post repos/o/r/issues/954/dependencies/blocked_by issue_id=100007' "$GH_LOG"
}

@test "a re-run skips every edge that already exists and writes nothing" {
  printf '%s\n' 'o/r#953' 'other/repo#7' > "$STUB_DIR/existing"
  printf '%s' '["#953", "other/repo#7", "#953"]' > "$REFS"
  edges
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '[.edges[] | [.ref, .status]] == [["#953","present"],["other/repo#7","present"]]' >/dev/null
  run grep -c '^post ' "$GH_LOG"
  [ "$output" = 0 ]
}

@test "an edge that would close a cycle is refused with no write, the rest still land" {
  # #953 is already blocked (transitively) by #954
  printf '%s' '{"blockers":[{"number":960},{"number":954}],"foreign_blockers":[],"cycles":[],"truncated":false}' \
    > "$STUB_DIR/deps-953.json"
  printf '%s' '["#953", "#52"]' > "$REFS"
  edges
  [ "$status" -eq 4 ]
  printf '%s' "$output" | jq -e '.edges[0].ref == "#953" and .edges[0].status == "refused"
    and (.edges[0].detail | test("cycle")) and .edges[1].status == "added"' >/dev/null
  run -1 grep -q 'issue_id=100953' "$GH_LOG"
  grep -q 'issue_id=100052' "$GH_LOG"
}

@test "a cross-repo target that is blocked by this issue is refused as a cycle" {
  printf '%s' '{"blockers":[],"foreign_blockers":[{"ref":"O/R#954","open":true}],"cycles":[],"truncated":false}' \
    > "$STUB_DIR/deps-7.json"
  printf '%s' '["other/repo#7"]' > "$REFS"
  edges
  [ "$status" -eq 4 ]
  printf '%s' "$output" | jq -e '.edges[0].status == "refused" and (.edges[0].detail | test("cycle"))' >/dev/null
  run -1 grep -q '^post ' "$GH_LOG"
}

@test "a truncated or failed cycle check cannot prove the edge safe and refuses it" {
  printf '%s' '{"blockers":[],"foreign_blockers":[],"cycles":[],"truncated":true}' > "$STUB_DIR/deps-953.json"
  printf '%s' '["#953"]' > "$REFS"
  edges
  [ "$status" -eq 4 ]
  printf '%s' "$output" | jq -e '.edges[0].status == "refused" and (.edges[0].detail | test("could not prove"))' >/dev/null
  FAIL_READER=1 edges
  [ "$status" -eq 4 ]
  printf '%s' "$output" | jq -e '.edges[0].status == "refused" and (.edges[0].detail | test("could not read"))' >/dev/null
  run -1 grep -q '^post ' "$GH_LOG"
}

@test "--no-cycle-check never calls the reader" {
  printf '%s' '["#953"]' > "$REFS"
  FAIL_READER=1 edges --no-cycle-check
  [ "$status" -eq 0 ]
  [ ! -e "$GH_LOG.reader" ]
  grep -q 'issue_id=100953' "$GH_LOG"
}

@test "a self-reference is refused" {
  printf '%s' '["#954"]' > "$REFS"
  edges
  [ "$status" -eq 4 ]
  printf '%s' "$output" | jq -e '.edges[0].status == "refused" and (.edges[0].detail | test("itself"))' >/dev/null
  run -1 grep -q '^post ' "$GH_LOG"
}

@test "a failed write is reported naming the edge (exit 5), never dropped" {
  printf '%s' '["#953"]' > "$REFS"
  FAIL_POST=1 edges
  [ "$status" -eq 5 ]
  printf '%s' "$output" | jq -e '.edges[0].status == "failed"
    and (.edges[0].detail | test("adding #954 blockedBy #953 failed"))' >/dev/null
}

@test "a cross-repo target whose id cannot be resolved is reported as failed (exit 5)" {
  printf '%s' '["other/repo#7", "#953"]' > "$REFS"
  FAIL_FOREIGN_ID=1 edges
  [ "$status" -eq 5 ]
  printf '%s' "$output" | jq -e '.edges[0].status == "failed" and .edges[1].status == "added"' >/dev/null
  printf '%s' "$output" | jq -e '.edges[0].detail | test("resolving other/repo#7")' >/dev/null
}

@test "malformed refs and an unreadable edge list are runtime errors before any write" {
  printf '%s' '["953"]' > "$REFS"
  edges
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  printf '%s' '{"refs":["#953"]}' > "$REFS"
  edges
  [ "$status" -eq 3 ]
  printf '%s' '["#953"]' > "$REFS"
  FAIL_READ=1 edges
  [ "$status" -eq 3 ]
  run -1 grep -q '^post ' "$GH_LOG"
}

@test "usage errors exit 2 with nothing on stdout" {
  printf '%s' '[]' > "$REFS"
  run --separate-stderr zsh "$S" --repo o/r --issue x --refs "$REFS"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  run --separate-stderr zsh "$S" --repo o --issue 1 --refs "$REFS"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$S" --repo o/r --issue 1 --refs "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$S" --repo o/r --issue 1 --refs "$REFS" --bogus
  [ "$status" -eq 2 ]
}

@test "an empty refs array adds nothing and exits 0" {
  printf '%s' '[]' > "$REFS"
  edges
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.edges == []' >/dev/null
  run -1 grep -q '^post ' "$GH_LOG"
}

@test "the refiner fixture turn names the prose prerequisite, not the context-only ref, and the script adds it" {
  # #953 is named as a prerequisite; #937 is cited "for context only"
  jq -e '.proposed_blocked_by == ["#953"]' "$TURN" >/dev/null
  jq -e '.proposed_prose | test("#937")' "$TURN" >/dev/null
  # story-spec/v1 carries no dependencies
  jq -e '.proposed_story_spec | has("dependencies") | not' "$TURN" >/dev/null
  jq '.proposed_blocked_by' "$TURN" > "$REFS"
  edges
  [ "$status" -eq 0 ]
  grep -qx 'post repos/o/r/issues/954/dependencies/blocked_by issue_id=100953' "$GH_LOG"
  run grep -c '^post ' "$GH_LOG"
  [ "$output" = 1 ]
}

@test "-h prints usage on stderr, nothing on stdout, and exits 0" {
  run --separate-stderr zsh "$S" -h
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  contains "$stderr" "usage: add-blocked-by-edges.zsh"
  [ ! -s "$GH_LOG" ]
}
