#!/usr/bin/env bats
#
# file-split-children.zsh (#2589): filing an accepted refinement-time split as
# native sub-issues of the original story. Three outcomes are pinned, each by
# what reached GitHub rather than by what the script says about itself:
#
#   - all children filed with `needs-refinement`, attached to the original, the
#     original relabelled `epic` and the trail comment posted;
#   - one child whose inventory still stops the size check: ZERO writes;
#   - a failure partway: the children already filed are reported, and the
#     original's labels are never touched.
#
# gh is stubbed through the script's GH_BIN seam. Every call the stub serves is
# appended to $GH_LOG, so "no write happened" is an assertion on that file, and
# the trail comment's body is copied out so its content can be read.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/refine-issue/scripts/file-split-children.zsh"
  MANIFEST="$REPO_ROOT/.claude-plugin/marketplace.json"
  PLAN="$BATS_TEST_TMPDIR/plan.json"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log" STUB_DIR="$BATS_TEST_TMPDIR/stub"
  : > "$GH_LOG"
  mkdir -p "$STUB_DIR"
  echo 0 > "$STUB_DIR/created"

  # Fake gh. `issue create` mints #901, #902, … in call order; FAIL_CREATE_AT=k
  # fails the k-th create, FAIL_LINK=k the k-th sub-issue POST, FAIL_EDIT and
  # FAIL_COMMENT the relabel and the trail, FAIL_EDGE=M every blockedBy POST
  # onto #M. Reads are served from JSON state the writes keep up to date, with
  # the caller's own --jq applied, so a second run sees what the first wrote:
  #   $STUB_DIR/subs.json         the original's sub-issues  [{number,title}]
  #   $STUB_DIR/blocked-<M>.json  #M's blockers  [{number,state,repository_url}]
  echo '[]' > "$STUB_DIR/subs.json"
  export GH_BIN="$BATS_TEST_TMPDIR/gh-stub.sh"
  cat > "$GH_BIN" <<'EOF'
#!/usr/bin/env bash
log() { printf '%s\n' "$*" >> "$GH_LOG"; }
case "$1 $2" in
  "label create") log "label $3"; exit 0 ;;
  "issue create")
    n=$(( $(cat "$STUB_DIR/created") + 1 )); echo "$n" > "$STUB_DIR/created"
    if [ "${FAIL_CREATE_AT:-0}" = "$n" ]; then echo "gh: HTTP 502" >&2; exit 1; fi
    title=""; labels=""; prev=""
    for a in "$@"; do
      [ "$prev" = "--title" ] && title="$a"
      [ "$prev" = "--label" ] && labels="$a"
      [ "$prev" = "--body-file" ] && cp "$a" "$STUB_DIR/child-body-$n.md"
      prev="$a"
    done
    printf '%s' "$title" > "$STUB_DIR/title-$((900 + n))"
    log "create #$((900 + n)) label=$labels title=$title"
    echo "https://github.com/o/r/issues/$((900 + n))"; exit 0 ;;
  "issue edit") log "edit $*"; [ -z "${FAIL_EDIT:-}" ] || exit 1; exit 0 ;;
  "issue comment")
    prev=""
    for a in "$@"; do [ "$prev" = "--body-file" ] && cp "$a" "$STUB_DIR/trail.md"; prev="$a"; done
    log "comment $3"; [ -z "${FAIL_COMMENT:-}" ] || exit 1; exit 0 ;;
esac
if [ "$1" = api ] && [ "$2" = --paginate ]; then
  path="$3"; q="."; [ "$4" = --jq ] && q="$5"
  case "$path" in
    */sub_issues) f="$STUB_DIR/subs.json" ;;
    */dependencies/blocked_by) m="${path%/dependencies/blocked_by}"; f="$STUB_DIR/blocked-${m##*/}.json" ;;
    *) echo "unexpected gh read: $*" >&2; exit 99 ;;
  esac
  [ -f "$f" ] || echo '[]' > "$f"
  jq -r "$q" "$f"; exit 0
fi
if [ "$1" = api ] && [ "$2" = -X ]; then
  path="$4"; id="${6#*=}"
  case "$path" in
    */sub_issues)
      k=$(( $(cat "$STUB_DIR/links" 2>/dev/null || echo 0) + 1 )); echo "$k" > "$STUB_DIR/links"
      if [ "${FAIL_LINK:-0}" = "$k" ]; then exit 1; fi
      num=$(( id - 100000 ))
      jq --argjson n "$num" --arg t "$(cat "$STUB_DIR/title-$num")" '. + [{number: $n, title: $t}]' \
        "$STUB_DIR/subs.json" > "$STUB_DIR/subs.tmp" && mv "$STUB_DIR/subs.tmp" "$STUB_DIR/subs.json"
      log "link $4 $6"; exit 0 ;;
    */dependencies/blocked_by)
      m="${path%/dependencies/blocked_by}"; m="${m##*/}"
      if [ "${FAIL_EDGE:-0}" = "$m" ]; then echo "gh: HTTP 403" >&2; exit 1; fi
      f="$STUB_DIR/blocked-$m.json"; [ -f "$f" ] || echo '[]' > "$f"
      jq --argjson n "$(( id - 100000 ))" \
        '. + [{number: $n, state: "open", repository_url: "https://api.github.com/repos/o/r"}]' \
        "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      log "edge #$m blockedBy $(( id - 100000 ))"; exit 0 ;;
  esac
fi
if [ "$1" = api ]; then
  n="${2##*/}"; echo $(( 100000 + n )); exit 0
fi
echo "unexpected gh call: $*" >&2; exit 99
EOF
  chmod +x "$GH_BIN"
}

# A plan of children whose inventories are N files each in the development plugin.
plan_of_sizes() {
  local sizes=("$@") c i k=0 json='{"children":['
  for c in "${sizes[@]}"; do
    k=$((k + 1))
    local files="["
    for (( i = 1; i <= c; i++ )); do
      files+="\"development/skills/refine-issue/scripts/c${k}f${i}.zsh\""
      (( i < c )) && files+=","
    done
    files+="]"
    (( k > 1 )) && json+=","
    json+="{\"title\":\"feat(x): child $k\",\"body\":\"Child $k body.\",\"files\":$files}"
  done
  json+=']}'
  printf '%s' "$json" > "$PLAN"
}

split() {
  run --separate-stderr zsh "$S" --repo o/r --parent 700 --plan "$PLAN" --manifest "$MANIFEST"
}

@test "an accepted split files every child, attaches it, relabels the original and posts the trail" {
  plan_of_sizes 9 8 10
  split
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .parent == 700 and .relabelled and .commented and .error == null and .stopped == []
    and ([.filed[] | [.index, .issue, .linked]] == [[1,901,true],[2,902,true],[3,903,true]])' >/dev/null
  # each child filed with needs-refinement, in plan order
  run grep -c '^create #90[123] label=needs-refinement title=feat(x): child [123]$' "$GH_LOG"
  [ "$output" = 3 ]
  # each attached to the original by the database id the api returned
  grep -qx 'link repos/o/r/issues/700/sub_issues sub_issue_id=100901' "$GH_LOG"
  grep -qx 'link repos/o/r/issues/700/sub_issues sub_issue_id=100902' "$GH_LOG"
  grep -qx 'link repos/o/r/issues/700/sub_issues sub_issue_id=100903' "$GH_LOG"
  # needs-refinement replaced by epic on the original
  grep -qx 'edit issue edit 700 --repo o/r --remove-label needs-refinement --add-label epic' "$GH_LOG"
  grep -qx 'edit issue edit 700 --repo o/r --remove-label needs-split' "$GH_LOG"
  # every write to the original came after every child was attached
  [ "$(grep -n '^link ' "$GH_LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n '^edit ' "$GH_LOG" | head -1 | cut -d: -f1)" ]
  # the trail lists the children
  grep -q '^comment 700$' "$GH_LOG"
  grep -qx -- '- #901 — feat(x): child 1' "$STUB_DIR/trail.md"
  grep -qx -- '- #903 — feat(x): child 3' "$STUB_DIR/trail.md"
  # each child body is the plan's body, then a line pointing back at the original
  [ "$(cat "$STUB_DIR/child-body-2.md")" = "$(printf 'Child 2 body.\n\nSplit from #700.')" ]
}

@test "one child whose inventory stops writes NOTHING and names that child" {
  plan_of_sizes 9 40 10
  split
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.filed == [] and .relabelled == false and .commented == false
    and ([.stopped[] | .index] == [2]) and .stopped[0].verdict.verdict == "stop"
    and .stopped[0].verdict.triggers == ["files"]' >/dev/null
  [ ! -s "$GH_LOG" ]
}

@test "a child spanning two plugins stops on the plugin trigger, with no write" {
  printf '%s' '{"children":[
    {"title":"a","body":"a","files":["development/agents/story-readiness.md"]},
    {"title":"b","body":"b","files":["development/a.md","development-go/b.md"]}]}' > "$PLAN"
  split
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.stopped[0].index == 2 and .stopped[0].verdict.triggers == ["plugin"]' >/dev/null
  [ ! -s "$GH_LOG" ]
}

@test "a failure partway reports the children filed and leaves the original's labels untouched" {
  plan_of_sizes 9 8 10
  FAIL_CREATE_AT=3 split
  [ "$status" -eq 5 ]
  printf '%s' "$output" | jq -e '
    ([.filed[] | [.index, .issue, .linked]] == [[1,901,true],[2,902,true]])
    and .relabelled == false and .commented == false
    and (.error | test("creating child 3 failed"))' >/dev/null
  run -1 grep -q '^edit ' "$GH_LOG"
  run -1 grep -q '^comment ' "$GH_LOG"
}

@test "a child filed but not attached is reported as unlinked, and the original is untouched" {
  plan_of_sizes 9 8
  FAIL_LINK=2 split
  [ "$status" -eq 5 ]
  printf '%s' "$output" | jq -e '
    ([.filed[] | [.index, .issue, .linked]] == [[1,901,true],[2,902,false]])
    and (.error | test("attaching #902"))' >/dev/null
  run -1 grep -q '^edit ' "$GH_LOG"
}

@test "a failed relabel is partial: children reported, no trail posted" {
  plan_of_sizes 9 8
  FAIL_EDIT=1 split
  [ "$status" -eq 5 ]
  printf '%s' "$output" | jq -e '(.filed | length) == 2 and .relabelled == false and .commented == false
    and (.error | test("relabelling #700"))' >/dev/null
  run -1 grep -q '^comment ' "$GH_LOG"
}

@test "a failed trail comment is partial, with the relabel reported as done" {
  plan_of_sizes 9 8
  FAIL_COMMENT=1 split
  [ "$status" -eq 5 ]
  printf '%s' "$output" | jq -e '.relabelled == true and .commented == false
    and (.error | test("trail comment"))' >/dev/null
}

# --- blockedBy edges (#2947) --------------------------------------------------

# Three small children; $1 $2 $3 are their blocked_by arrays.
plan_with_blocked_by() {
  printf '%s' "{\"children\":[
    {\"title\":\"feat(x): child 1\",\"body\":\"c1\",\"files\":[\"development/a1.md\"],\"blocked_by\":$1},
    {\"title\":\"feat(x): child 2\",\"body\":\"c2\",\"files\":[\"development/a2.md\"],\"blocked_by\":$2},
    {\"title\":\"feat(x): child 3\",\"body\":\"c3\",\"files\":[\"development/a3.md\"],\"blocked_by\":$3}]}" > "$PLAN"
}

# The original #700 is natively blocked by #52 and #36 (open) and #40 (closed).
parent_blocked() {
  printf '%s' '[
    {"number":52,"state":"open","repository_url":"https://api.github.com/repos/o/r"},
    {"number":36,"state":"open","repository_url":"https://api.github.com/repos/o/r"},
    {"number":40,"state":"closed","repository_url":"https://api.github.com/repos/o/r"}]' \
    > "$STUB_DIR/blocked-700.json"
}

@test "sibling blocked_by becomes native edges; open parent blockers go only to children with no sibling blocker" {
  parent_blocked
  plan_with_blocked_by '[]' '[0]' '["#88"]'
  split
  [ "$status" -eq 0 ]
  # #901 starts the order: it inherits the original's open blockers
  jq -e '[.[].number] == [52, 36]' "$STUB_DIR/blocked-901.json" >/dev/null
  # #902 is after #901 and reaches #52/#36 through it, so inherits nothing
  jq -e '[.[].number] == [901]' "$STUB_DIR/blocked-902.json" >/dev/null
  # #903 names no sibling: its own prerequisite plus the inherited ones
  jq -e '[.[].number] == [88, 52, 36]' "$STUB_DIR/blocked-903.json" >/dev/null
  # the closed blocker is never copied
  run -1 grep -q 'blockedBy 40$' "$GH_LOG"
  printf '%s' "$output" >/dev/null
  # every edge lands before the original is relabelled
  [ "$(grep -n '^edge ' "$GH_LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n '^edit ' "$GH_LOG" | head -1 | cut -d: -f1)" ]
  # the trail names each child's blockers
  grep -qx -- '- #902 — feat(x): child 2 (blocked by #901)' "$STUB_DIR/trail.md"
  grep -qx -- '- #901 — feat(x): child 1 (blocked by #52, #36)' "$STUB_DIR/trail.md"
}

@test "the report lists every edge with its child" {
  plan_with_blocked_by '[]' '[0]' '[1]'
  split
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '[.edges[] | [.issue, .ref, .status]] == [[902,"#901","added"],[903,"#902","added"]]' >/dev/null
}

@test "an edge that cannot be added is partial (exit 5) naming it, and the original is untouched" {
  plan_with_blocked_by '[]' '[0]' '[]'
  FAIL_EDGE=902 split
  [ "$status" -eq 5 ]
  printf '%s' "$output" | jq -e '(.filed | length) == 3 and .relabelled == false and .commented == false
    and (.error | test("#902 blockedBy #901"))' >/dev/null
  run -1 grep -q '^edit ' "$GH_LOG"
  run -1 grep -q '^comment ' "$GH_LOG"
}

@test "a re-run reuses the filed children and adds only the missing edges" {
  parent_blocked
  plan_with_blocked_by '[]' '[0]' '[]'
  FAIL_EDGE=902 split
  [ "$status" -eq 5 ]
  local edges_before
  edges_before="$(grep -c '^edge ' "$GH_LOG")"
  split
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '[.filed[] | [.issue, .reused]] == [[901,true],[902,true],[903,true]]' >/dev/null
  # no child filed twice
  run grep -c '^create ' "$GH_LOG"
  [ "$output" = 3 ]
  # the second run wrote exactly the edge the first could not
  [ "$(grep -c '^edge ' "$GH_LOG")" -eq $(( edges_before + 1 )) ]
  [ "$(tail -n +1 "$GH_LOG" | grep '^edge ' | tail -1)" = "edge #902 blockedBy 901" ]
}

@test "a sibling cycle is refused before any write (exit 1, nothing filed)" {
  plan_with_blocked_by '[2]' '[0]' '[1]'
  split
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.filed == [] and .edges == []
    and .error == "blocked_by forms a cycle among the children at indexes 0, 1, 2"' >/dev/null
  [ ! -s "$GH_LOG" ]
  plan_with_blocked_by '[0]' '[]' '[]'
  split
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.error | test("cycle among the children at indexes 0$")' >/dev/null
  [ ! -s "$GH_LOG" ]
}

@test "a blocked_by index outside the plan is refused before any write (exit 1)" {
  plan_with_blocked_by '[]' '[3]' '[-1]'
  split
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.filed == [] and (.error | test("index outside the plan: -1, 3"))' >/dev/null
  [ ! -s "$GH_LOG" ]
}

@test "a malformed blocked_by is a runtime error before any write" {
  plan_with_blocked_by '[]' '"#1"' '[]'
  split
  [ "$status" -eq 3 ]
  contains "$stderr" "blocked_by must be an array"
  plan_with_blocked_by '[]' '["953"]' '[]'
  split
  [ "$status" -eq 3 ]
  contains "$stderr" "sibling index or #N"
  plan_with_blocked_by '[]' '[0.5]' '[]'
  split
  [ "$status" -eq 3 ]
  [ ! -s "$GH_LOG" ]
}

@test "a malformed plan is a runtime error before any write" {
  printf '%s' '{"children":[{"title":"only one","body":"x","files":[]}]}' > "$PLAN"
  split
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "at least two children"
  [ ! -s "$GH_LOG" ]
  printf '%s' '{"children":[{"title":"","body":"x","files":[]},{"title":"b","body":"x","files":[]}]}' > "$PLAN"
  split
  [ "$status" -eq 3 ]
  contains "$stderr" "non-empty title"
  printf '%s' 'not json' > "$PLAN"
  split
  [ "$status" -eq 3 ]
  [ ! -s "$GH_LOG" ]
}

@test "a size check that errors on a child is a runtime error before any write" {
  printf '%s' '{"children":[{"title":"a","body":"a","files":[1]},{"title":"b","body":"b","files":[]}]}' > "$PLAN"
  split
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "size check errored on child"
  [ ! -s "$GH_LOG" ]
}

@test "children with empty inventories are skipped by the size check, not stopped" {
  printf '%s' '{"children":[{"title":"a","body":"a","files":[]},{"title":"b","body":"b","files":[]}]}' > "$PLAN"
  split
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '(.filed | length) == 2' >/dev/null
}

@test "usage errors exit 2 with nothing on stdout and no write" {
  plan_of_sizes 2 2
  run --separate-stderr zsh "$S" --repo o/r --plan "$PLAN"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr zsh "$S" --repo o/r --parent abc --plan "$PLAN"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$S" --repo norepo --parent 7 --plan "$PLAN"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$S" --repo o/r --parent 7 --plan "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$S" --repo o/r --parent 7 --plan "$PLAN" --bogus
  [ "$status" -eq 2 ]
  [ ! -s "$GH_LOG" ]
}

@test "-h prints usage on stderr, nothing on stdout, exits 0 and writes nothing" {
  run --separate-stderr zsh "$S" -h
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  contains "$stderr" "usage: file-split-children.zsh"
  [ ! -s "$GH_LOG" ]
}

@test "the script holds no threshold of its own" {
  run -1 grep -nE 'MAX_FILES|more than [0-9a-z-]+ files|BOOTSTRAP_TEMPLATES' "$S"
}
