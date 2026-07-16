#!/usr/bin/env bats
#
# Behavioral tests for read-sub-issues.zsh (#802): the shared reader for
# GitHub-native epic→child parenthood. Every parenthood consumer —
# resolve-issue's E1, refine-issue's epic walk — reads through this helper, so
# what these tests pin down is the contract: children + subIssuesSummary in the
# --epic direction, the single-query parent lookup in the --child direction,
# and the typed no-parent exit (3) that distinguishes "parentless" from an
# error.
#
# gh is stubbed via the GH_BIN seam: the stub extracts the `-F number=N`
# argument and serves a canned raw GraphQL response per issue number, so the
# shapes under test are fully deterministic and need no network.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/read-sub-issues.zsh"

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

# mk_epic <num> <total> <completed> <children-json: [[num,state],...]>
# writes the raw GraphQL --epic response fixture for one issue. A child entry
# may carry a third element naming its repo (cross-repo children); it defaults
# to the epic's own repo, matching the live API which always sends
# repository.nameWithOwner.
mk_epic() {
  jq -n --argjson num "$1" --argjson total "$2" --argjson completed "$3" \
        --argjson kids "$4" \
    '{data:{repository:{issue:{
        number:$num,
        subIssuesSummary:{total:$total, completed:$completed},
        subIssues:{nodes:($kids|map({number:.[0], state:.[1],
                                     repository:{nameWithOwner:(.[2] // "owner/repo")}}))}}}}}' \
    > "$FIXTURE_DIR/issue-$1.json"
}

# mk_child <num> <parent-json: {number,state[,repo]} or null>
mk_child() {
  jq -n --argjson num "$1" --argjson parent "$2" \
    '{data:{repository:{issue:{number:$num,
        parent:(if $parent == null then null
                else {number:$parent.number, state:$parent.state,
                      repository:{nameWithOwner:($parent.repo // "owner/repo")}} end)}}}}' \
    > "$FIXTURE_DIR/issue-$1.json"
}

reader() { run env GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" zsh "$S" "$@"; }

# ---- usage errors ----------------------------------------------------------

@test "usage: missing --repo exits 2" {
  reader --epic 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"--repo OWNER/NAME is required"* ]]
}

@test "usage: --repo without a slash exits 2" {
  reader --repo just-a-name --epic 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be OWNER/NAME"* ]]
}

@test "usage: neither --epic nor --child exits 2" {
  reader --repo owner/repo
  [ "$status" -eq 2 ]
  [[ "$output" == *"one of --epic N or --child N is required"* ]]
}

@test "usage: both --epic and --child exits 2" {
  reader --repo owner/repo --epic 5 --child 6
  [ "$status" -eq 2 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "usage: non-numeric issue number exits 2" {
  reader --repo owner/repo --epic abc
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be numeric"* ]]
}

@test "usage: a dangling value flag exits 2, not a nounset abort" {
  reader --repo owner/repo --child
  [ "$status" -eq 2 ]
  [[ "$output" == *"--child needs a value"* ]]
}

# ---- --epic: children + summary --------------------------------------------

@test "--epic returns children in sub-issue order with the summary" {
  mk_epic 746 3 1 '[[790,"OPEN"],[791,"CLOSED"],[792,"OPEN"]]'
  reader --repo owner/repo --epic 746
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.epic, .summary.total, .summary.completed]')" = '[746,3,1]' ]
  [ "$(echo "$output" | jq -c '[.children[].number]')" = '[790,791,792]' ]
  [ "$(echo "$output" | jq -c '.open_children')" = '[790,792]' ]
  [ "$(echo "$output" | jq -r '.children[1].open')" = "false" ]
}

@test "--epic on an epic with NO native children reports total 0 and empty lists (exit 0)" {
  # the never-decomposed / un-backfilled shape: the caller must halt on it,
  # so the reader itself reports it plainly rather than erroring
  mk_epic 900 0 0 '[]'
  reader --repo owner/repo --epic 900
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.summary.total, .children, .open_children]')" = '[0,[],[]]' ]
}

@test "--epic where all children are closed reports total == completed (the E4/E5 licence)" {
  mk_epic 901 2 2 '[[10,"CLOSED"],[11,"CLOSED"]]'
  reader --repo owner/repo --epic 901
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.summary.total == .summary.completed')" = "true" ]
  [ "$(echo "$output" | jq -c '.open_children')" = '[]' ]
}

@test "--epic on a nonexistent issue is an internal error (exit 1)" {
  reader --repo owner/repo --epic 999
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "--epic when gh itself fails is an internal error (exit 1) with the gh message" {
  run env GH_BIN=/bin/false zsh "$S" --repo owner/repo --epic 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh api graphql failed"* ]]
}

@test "a cross-repo child carries its repo and is excluded from open_children" {
  mk_epic 746 2 0 '[[790,"OPEN"],[55,"OPEN","other/repo"]]'
  reader --repo owner/repo --epic 746
  [ "$status" -eq 0 ]
  # both children visible, each with its repo…
  [ "$(echo "$output" | jq -r '.children[1].repo')" = "other/repo" ]
  # …but the work-list holds only the same-repo one, and stderr notes the exclusion
  [ "$(echo "$output" | jq -c '.open_children')" = '[790]' ]
  [[ "$output" == *"cross-repo sub-issues excluded"* ]]
}

@test "the same-repo comparison is case-insensitive (GitHub slugs are)" {
  mk_epic 746 1 0 '[[790,"OPEN","Owner/Repo"]]'
  reader --repo owner/repo --epic 746
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.open_children')" = '[790]' ]
}

# ---- --child: the single-query parent lookup --------------------------------

@test "--child returns the parent epic (with its repo)" {
  mk_child 791 '{"number":746,"state":"OPEN"}'
  reader --repo owner/repo --child 791
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.child, .parent.number, .parent.open, .parent.repo]')" \
    = '[791,746,true,"owner/repo"]' ]
}

@test "--child when gh itself fails is an internal error (exit 1), not no-parent" {
  run env GH_BIN=/bin/false zsh "$S" --repo owner/repo --child 791
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh api graphql failed"* ]]
}

@test "--child on a parentless issue takes the typed no-parent exit 3 (JSON still emitted)" {
  mk_child 42 'null'
  reader --repo owner/repo --child 42
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -c '[.child, .parent]')" = '[42,null]' ]
}

@test "--child of a CLOSED parent reports open:false" {
  mk_child 50 '{"number":60,"state":"CLOSED"}'
  reader --repo owner/repo --child 50
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.parent.open')" = "false" ]
}

@test "--child on a nonexistent issue is an internal error (exit 1), not no-parent" {
  reader --repo owner/repo --child 999
  [ "$status" -eq 1 ]
}
