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

load assertions

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
  contains "$output" "--repo OWNER/NAME is required"
}

@test "usage: --repo without a slash exits 2" {
  reader --repo just-a-name --epic 5
  [ "$status" -eq 2 ]
  contains "$output" "must be OWNER/NAME"
}

@test "usage: none of --epic, --child or --tree exits 2" {
  reader --repo owner/repo
  [ "$status" -eq 2 ]
  contains "$output" "one of --epic N, --child N or --tree N is required"
}

@test "usage: both --epic and --child exits 2" {
  reader --repo owner/repo --epic 5 --child 6
  [ "$status" -eq 2 ]
  contains "$output" "mutually exclusive"
}

@test "usage: non-numeric issue number exits 2" {
  reader --repo owner/repo --epic abc
  [ "$status" -eq 2 ]
  contains "$output" "must be numeric"
}

@test "usage: a dangling value flag exits 2, not a nounset abort" {
  reader --repo owner/repo --child
  [ "$status" -eq 2 ]
  contains "$output" "--child needs a value"
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
  contains "$output" "not found"
}

@test "--epic when gh itself fails is an internal error (exit 1) with the gh message" {
  run env GH_BIN=/bin/false zsh "$S" --repo owner/repo --epic 5
  [ "$status" -eq 1 ]
  contains "$output" "gh api graphql failed"
}

@test "a cross-repo child carries its repo and is excluded from open_children" {
  mk_epic 746 2 0 '[[790,"OPEN"],[55,"OPEN","other/repo"]]'
  reader --repo owner/repo --epic 746
  [ "$status" -eq 0 ]
  # both children visible, each with its repo…
  [ "$(echo "$output" | jq -r '.children[1].repo')" = "other/repo" ]
  # …but the work-list holds only the same-repo one, and stderr notes the exclusion
  [ "$(echo "$output" | jq -c '.open_children')" = '[790]' ]
  contains "$output" "cross-repo sub-issues excluded"
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
  contains "$output" "gh api graphql failed"
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

# ---- --tree: the sub-issue tree of any depth (#2857) -----------------------

# mk_node <num> <state> <labels-json> <body> <total> <completed> <children-json>
# writes the raw GraphQL --tree response fixture for one issue. A child entry
# is [num,state] or [num,state,repo], as in mk_epic.
mk_node() {
  jq -n --argjson num "$1" --arg state "$2" --argjson labels "$3" --arg body "$4" \
        --argjson total "$5" --argjson completed "$6" --argjson kids "$7" \
    '{data:{repository:{issue:{
        number:$num, state:$state, body:$body,
        labels:{nodes:($labels|map({name:.}))},
        subIssuesSummary:{total:$total, completed:$completed},
        subIssues:{nodes:($kids|map({number:.[0], state:.[1],
                                     repository:{nameWithOwner:(.[2] // "owner/repo")}}))}}}}}' \
    > "$FIXTURE_DIR/issue-$1.json"
}

# kind_of <output> <num> — the kind the document gave issue <num>
kind_of() { echo "$1" | jq -r --argjson n "$2" '.nodes[] | select(.number == $n) | .kind'; }

# three levels below the target: 12 → 231 → 251 → 261, beside plain leaves
mk_three_level_tree() {
  mk_node 12 OPEN '["epic"]' "" 3 1 '[[231,"OPEN"],[232,"OPEN"],[239,"CLOSED"]]'
  mk_node 231 OPEN '["epic"]' "" 2 0 '[[251,"OPEN"],[252,"OPEN"]]'
  mk_node 251 OPEN '[]' "" 1 0 '[[261,"OPEN"]]'
  mk_node 261 OPEN '["enhancement"]' "the leaf" 0 0 '[]'
  mk_node 252 OPEN '[]' "a story" 0 0 '[]'
  mk_node 232 OPEN '[]' "a story" 0 0 '[]'
  mk_node 239 CLOSED '[]' "done" 0 0 '[]'
}

@test "--tree emits root, limit and every node field, pre-order with full paths" {
  mk_three_level_tree
  reader --repo owner/repo --tree 12
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.root, .limit]')" = '[12,4]' ]
  [ "$(echo "$output" | jq -c '[.nodes[].number]')" = '[12,231,251,261,252,232,239]' ]
  [ "$(echo "$output" | jq -c '.nodes[3] | keys')" \
    = '["completed","depth","kind","labels","number","open","parent","path","repo","state","total"]' ]
  [ "$(echo "$output" | jq -c '.nodes[3] | [.depth, .path, .parent, .open, .repo, .labels]')" \
    = '[3,[12,231,251,261],251,true,"owner/repo",["enhancement"]]' ]
  [ "$(echo "$output" | jq -c '.nodes[0] | [.depth, .path, .parent, .total, .completed]')" \
    = '[0,[12],null,3,1]' ]
}

@test "--tree kinds: open total > 0 is inner, open total == 0 with no epic signal is leaf" {
  mk_three_level_tree
  reader --repo owner/repo --tree 12
  [ "$status" -eq 0 ]
  [ "$(kind_of "$output" 12)" = inner ]
  [ "$(kind_of "$output" 231)" = inner ]
  [ "$(kind_of "$output" 251)" = inner ]
  [ "$(kind_of "$output" 261)" = leaf ]
  [ "$(kind_of "$output" 232)" = leaf ]
}

@test "--tree: a closed total == 0 node is a leaf, never undecomposed, even with the epic label" {
  mk_node 12 OPEN '[]' "" 1 1 '[[40,"CLOSED"]]'
  mk_node 40 CLOSED '["epic"]' "- [ ] #41 a child" 0 0 '[]'
  reader --repo owner/repo --tree 12
  [ "$status" -eq 0 ]
  [ "$(kind_of "$output" 40)" = leaf ]
}

@test "--tree: a closed total > 0 node is inner and is never descended into" {
  mk_node 12 OPEN '[]' "" 2 1 '[[40,"CLOSED"],[42,"OPEN"]]'
  mk_node 40 CLOSED '[]' "" 1 1 '[[41,"CLOSED"]]'
  mk_node 41 CLOSED '[]' "" 0 0 '[]'
  mk_node 42 OPEN '[]' "" 0 0 '[]'
  reader --repo owner/repo --tree 12
  [ "$status" -eq 0 ]
  [ "$(kind_of "$output" 40)" = inner ]
  # 41 sits under a closed subtree: not listed at all
  [ "$(echo "$output" | jq -c '[.nodes[].number]')" = '[12,40,42]' ]
}

@test "--tree: an open nested total == 0 node with the epic label is undecomposed" {
  mk_node 12 OPEN '[]' "" 1 0 '[[50,"OPEN"]]'
  mk_node 50 OPEN '["epic"]' "no list" 0 0 '[]'
  reader --repo owner/repo --tree 12
  [ "$status" -eq 0 ]
  [ "$(kind_of "$output" 50)" = undecomposed ]
}

@test "--tree: an open nested total == 0 node whose body declares a child (#1260) is undecomposed" {
  mk_node 12 OPEN '[]' "" 2 0 '[[50,"OPEN"],[51,"OPEN"]]'
  mk_node 50 OPEN '[]' $'## Children\n- [ ] #687 build the thing' 0 0 '[]'
  # a criterion that merely CITES an issue is not a declaration, and a fenced
  # list is quoted, not declared: both leave the node a leaf
  mk_node 51 OPEN '[]' $'- [ ] the seam from #937 holds\n```\n- [ ] #688 quoted\n```' 0 0 '[]'
  reader --repo owner/repo --tree 12
  [ "$status" -eq 0 ]
  [ "$(kind_of "$output" 50)" = undecomposed ]
  [ "$(kind_of "$output" 51)" = leaf ]
}

@test "--tree: the root itself is never undecomposed (E1's own total: 0 machinery owns it)" {
  mk_node 12 OPEN '["epic"]' "- [ ] #13 a child" 0 0 '[]'
  reader --repo owner/repo --tree 12
  [ "$status" -eq 0 ]
  [ "$(kind_of "$output" 12)" = leaf ]
}

@test "--tree: the #1260 rule is byte-identical to read-dependencies.zsh's copy" {
  D="$REPO_ROOT/development/skills/resolve-issue/scripts/read-dependencies.zsh"
  a="$(grep -F 'test("^[ \t]*[-*+]' "$S" | sed 's/^ *//')"
  b="$(grep -F 'test("^[ \t]*[-*+]' "$D" | sed 's/^ *//')"
  [ -n "$a" ]
  [ "$a" = "$b" ]
}

@test "--tree: a cross-repo node is foreign, never read or descended, noted on stderr, exit 0" {
  mk_node 12 OPEN '[]' "" 2 0 '[[60,"OPEN","other/repo"],[61,"OPEN"]]'
  # a SAME-numbered local issue exists: reading it would graft the wrong node
  mk_node 60 OPEN '[]' "" 1 0 '[[99,"OPEN"]]'
  mk_node 61 OPEN '[]' "" 0 0 '[]'
  # stdout and stderr kept apart: `run` would merge the note into the JSON
  status=0
  output="$(env GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" zsh "$S" --repo owner/repo --tree 12 \
    2>"$BATS_TEST_TMPDIR/err")" || status=$?
  [ "$status" -eq 0 ]
  [ "$(kind_of "$output" 60)" = foreign ]
  [ "$(echo "$output" | jq -c '.nodes[] | select(.number == 60) | [.repo, .total, .labels, .open]')" \
    = '["other/repo",null,null,true]' ]
  [ "$(echo "$output" | jq -c '[.nodes[].number]')" = '[12,60,61]' ]
  contains "$(cat "$BATS_TEST_TMPDIR/err")" "other/repo#60"
}

@test "--tree: a nested read failure is read_failed and the walk continues" {
  mk_node 12 OPEN '[]' "" 3 0 '[[70,"OPEN"],[71,"OPEN"],[72,"OPEN"]]'
  # no fixture for 70 or 72: both reads fail
  mk_node 71 OPEN '[]' "" 0 0 '[]'
  reader --repo owner/repo --tree 12
  [ "$status" -eq 0 ]
  [ "$(kind_of "$output" 70)" = read_failed ]
  [ "$(kind_of "$output" 71)" = leaf ]
  [ "$(kind_of "$output" 72)" = read_failed ]
  [ "$(echo "$output" | jq -c '.nodes[] | select(.number == 72) | [.path, .total]')" = '[[12,72],null]' ]
}

@test "--tree: a failed read of the root is an internal error (exit 1)" {
  reader --repo owner/repo --tree 999
  [ "$status" -eq 1 ]
  contains "$output" "not found"
}

@test "--tree: the depth limit defaults to 4 and a four-level tree passes" {
  mk_node 1 OPEN '[]' "" 1 0 '[[2,"OPEN"]]'
  mk_node 2 OPEN '[]' "" 1 0 '[[3,"OPEN"]]'
  mk_node 3 OPEN '[]' "" 1 0 '[[4,"OPEN"]]'
  mk_node 4 OPEN '[]' "" 1 0 '[[5,"OPEN"]]'
  mk_node 5 OPEN '[]' "" 0 0 '[]'
  run env -u RESOLVE_ISSUE_MAX_EPIC_DEPTH GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" zsh "$S" --repo owner/repo --tree 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.limit')" = 4 ]
  [ "$(echo "$output" | jq -r 'has("over_limit")')" = false ]
  [ "$(echo "$output" | jq -c '.nodes[-1].path')" = '[1,2,3,4,5]' ]
}

@test "--tree: a tree deeper than the limit exits 5 with over_limit naming the path" {
  mk_node 1 OPEN '[]' "" 1 0 '[[2,"OPEN"]]'
  mk_node 2 OPEN '[]' "" 1 0 '[[3,"OPEN"]]'
  mk_node 3 OPEN '[]' "" 0 0 '[]'
  run env RESOLVE_ISSUE_MAX_EPIC_DEPTH=1 GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" zsh "$S" --repo owner/repo --tree 1
  [ "$status" -eq 5 ]
  [ "$(echo "$output" | jq -c '.over_limit')" = '{"path":[1,2,3],"limit":1}' ]
  # the document is still emitted, and the walk never descends past the limit
  [ "$(echo "$output" | jq -c '[.nodes[].number]')" = '[1,2]' ]
}

@test "--tree: RESOLVE_ISSUE_MAX_EPIC_DEPTH=8 is accepted as the limit" {
  mk_node 1 OPEN '[]' "" 0 0 '[]'
  run env RESOLVE_ISSUE_MAX_EPIC_DEPTH=8 GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" zsh "$S" --repo owner/repo --tree 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.limit')" = 8 ]
}

@test "--tree: an invalid RESOLVE_ISSUE_MAX_EPIC_DEPTH exits 4 before any gh call, no fallback" {
  MARK="$BATS_TEST_TMPDIR/gh-called"
  CALLED="$BATS_TEST_TMPDIR/gh-mark.sh"
  printf '#!/usr/bin/env bash\ntouch "%s"\necho "{}"\n' "$MARK" > "$CALLED"
  chmod +x "$CALLED"
  for v in 0 9 abc 4x "" 04; do
    rm -f "$MARK"
    run env RESOLVE_ISSUE_MAX_EPIC_DEPTH="$v" GH_BIN="$CALLED" zsh "$S" --repo owner/repo --tree 1
    [ "$status" -eq 4 ] || { echo "value '$v' exited $status"; false; }
    contains "$output" "RESOLVE_ISSUE_MAX_EPIC_DEPTH"
    [ ! -e "$MARK" ] || { echo "value '$v' called gh"; false; }
  done
}

@test "usage: --tree with --epic or --child exits 2" {
  reader --repo owner/repo --tree 5 --epic 6
  [ "$status" -eq 2 ]
  contains "$output" "mutually exclusive"
  reader --repo owner/repo --tree 5 --child 6
  [ "$status" -eq 2 ]
  contains "$output" "mutually exclusive"
}
