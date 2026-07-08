#!/usr/bin/env bats
#
# Behavioral tests for read-dependencies.zsh (#584): the shared reader for
# GitHub-native issue dependencies (epic #583). Every dependency consumer —
# the readiness gate, the single-issue precheck (#585), the epic recursion
# (#587) — reads through this helper, so what these tests pin down is the
# contract: transitive traversal over `blockedBy`, open/closed + epic/issue
# classification, explicit cycle reporting, and no recursion into CLOSED
# blockers (a met prerequisite's history can't block anything).
#
# gh is stubbed via the GH_BIN seam: the stub extracts the `-F number=N`
# argument and serves a canned raw GraphQL response per issue number, so the
# graph shape under test is fully deterministic and needs no network.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/read-dependencies.zsh"

  FIXTURE_DIR="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$FIXTURE_DIR"

  # Fake gh: serves $FIXTURE_DIR/issue-<N>.json for `-F number=<N>`; an issue
  # with no fixture resolves to null (exactly what the API returns for a
  # nonexistent issue).
  STUB="$BATS_TEST_TMPDIR/gh-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
prev="" num=""
for a in "$@"; do
  if [ "$prev" = "-F" ]; then case "$a" in number=*) num="${a#number=}" ;; esac; fi
  prev="$a"
done
f="$FIXTURE_DIR/issue-$num.json"
if [ -f "$f" ]; then cat "$f"; else echo '{"data":{"repository":{"issue":null}}}'; fi
EOF
  chmod +x "$STUB"
}

# mk <num> <state> <labels-json> <trackedIssuesCount> <body> <blockers-json>
# writes the raw GraphQL response fixture for one issue.
mk() {
  jq -n --argjson num "$1" --arg state "$2" --argjson labels "$3" \
        --argjson tracked "$4" --arg body "$5" --argjson blockers "$6" \
    '{data:{repository:{issue:{
        number:$num, state:$state, body:$body, trackedIssuesCount:$tracked,
        labels:{nodes:($labels|map({name:.}))},
        blockedBy:{nodes:($blockers|map({number:.}))}}}}}' \
    > "$FIXTURE_DIR/issue-$1.json"
}

deps() {  # $1 = issue number ; rest = extra flags
  local n="$1"; shift
  run env GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" \
    zsh "$S" --repo owner/repo --issue "$n" "$@"
}

# ---- usage errors ----------------------------------------------------------

@test "usage: missing --repo exits 2" {
  run zsh "$S" --issue 5
  [ "$status" -eq 2 ]
}

@test "usage: missing --issue exits 2" {
  run zsh "$S" --repo owner/repo
  [ "$status" -eq 2 ]
}

@test "usage: --repo without a slash exits 2" {
  run zsh "$S" --repo just-a-name --issue 5
  [ "$status" -eq 2 ]
}

@test "usage: non-numeric --issue exits 2" {
  run zsh "$S" --repo owner/repo --issue abc
  [ "$status" -eq 2 ]
}

# ---- the trivial and error base cases --------------------------------------

@test "an issue with no blockers is not blocked" {
  mk 10 OPEN '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.blocked, .open_blockers, .blockers, .cycles, .truncated]')" \
    = '[false,[],[],[],false]' ]
}

@test "a nonexistent issue is an internal error (exit 1)" {
  deps 999
  [ "$status" -eq 1 ]
}

# ---- classification: open/closed, epic/issue -------------------------------

@test "direct blockers are classified open/closed; only open ones block" {
  mk 10 OPEN '[]' 0 "" '[11,12]'
  mk 11 OPEN '[]' 0 "" '[]'
  mk 12 CLOSED '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .blocked)" = "true" ]
  [ "$(echo "$output" | jq -c .open_blockers)" = '[11]' ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==11) | .open')" = "true" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==12) | .open')" = "false" ]
}

@test "closed blockers only means not blocked (but still recorded)" {
  mk 10 OPEN '[]' 0 "" '[12]'
  mk 12 CLOSED '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .blocked)" = "false" ]
  [ "$(echo "$output" | jq -c '[.blockers[].number]')" = '[12]' ]
}

@test "a blocker with the epic label is kind=epic" {
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '["epic"]' 0 "" '[]'
  deps 10
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a blocker with tracked issues is kind=epic" {
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 3 "" '[]'
  deps 10
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a blocker with a task-list body referencing issues is kind=epic" {
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'## Children\n\n- [ ] #21\n- [x] #22\n' '[]'
  deps 10
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a task list without issue refs does NOT make a blocker an epic" {
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'- [ ] add tests\n- [ ] write docs\n' '[]'
  deps 10
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

# ---- transitive traversal ---------------------------------------------------

@test "blockers resolve transitively with depth per hop" {
  mk 10 OPEN '[]' 0 "" '[11]'
  mk 11 OPEN '[]' 0 "" '[12]'
  mk 12 OPEN '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c .open_blockers)" = '[11,12]' ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==11) | .depth')" = "1" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==12) | .depth')" = "2" ]
}

@test "a CLOSED blocker is not recursed into" {
  mk 10 OPEN '[]' 0 "" '[30]'
  mk 30 CLOSED '[]' 0 "" '[31]'
  mk 31 OPEN '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .blocked)" = "false" ]
  [ "$(echo "$output" | jq -c '[.blockers[].number]')" = '[30]' ]
}

@test "a diamond records the shared blocker once" {
  mk 10 OPEN '[]' 0 "" '[2,3]'
  mk 2 OPEN '[]' 0 "" '[4]'
  mk 3 OPEN '[]' 0 "" '[4]'
  mk 4 OPEN '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.blockers[] | select(.number==4)] | length')" = "1" ]
  [ "$(echo "$output" | jq -c '.open_blockers | sort')" = '[2,3,4]' ]
}

# ---- cycles ------------------------------------------------------------------

@test "a two-issue cycle is reported explicitly" {
  mk 20 OPEN '[]' 0 "" '[21]'
  mk 21 OPEN '[]' 0 "" '[20]'
  deps 20
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.cycles')" = '[[20,21,20]]' ]
  [ "$(echo "$output" | jq -c '.open_blockers')" = '[21]' ]
}

@test "a self-blocking issue is a one-node cycle" {
  mk 40 OPEN '[]' 0 "" '[40]'
  deps 40
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.cycles')" = '[[40,40]]' ]
}

# ---- depth cap ---------------------------------------------------------------

@test "--max-depth stops traversal and sets truncated" {
  mk 10 OPEN '[]' 0 "" '[11]'
  mk 11 OPEN '[]' 0 "" '[12]'
  mk 12 OPEN '[]' 0 "" '[13]'
  mk 13 OPEN '[]' 0 "" '[]'
  deps 10 --max-depth 2
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .truncated)" = "true" ]
  [ "$(echo "$output" | jq '.blockers | length < 3')" = "true" ]
}
