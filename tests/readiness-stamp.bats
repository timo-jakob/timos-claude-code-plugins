#!/usr/bin/env bats
#
# Behavioral tests for readiness-stamp.zsh (#2954, epic #2953): the readiness
# key, the hit/miss decision of `check`, and the in-place `write`.
#
# The script resolves gate_version from its OWN plugin, so each test copies it
# with the files it hashes and calls (story-readiness.md, size-check.zsh,
# size-preflight.zsh, read-sub-issues.zsh) into a scratch plugin tree; changing
# the copied agent file is how a test moves gate_version. gh is stubbed via the
# GH_BIN seam: a GraphQL call with `-F number=N` is read-sub-issues.zsh's tree
# read and serves tree-N.json, one with `-F num=N` is a comment page and serves
# page-N.json, and any other GraphQL call is the batched issue read and serves
# batch.json, which mk_batch assembles from the issue fixtures. REST writes are
# logged to calls.log and answered with a fixed comment id.

load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  PLUG="$BATS_TEST_TMPDIR/plug/development"
  mkdir -p "$PLUG/agents" "$PLUG/skills/resolve-issue/scripts" "$PLUG/skills/refine-issue/scripts"
  cp "$REPO_ROOT/development/agents/story-readiness.md" "$PLUG/agents/"
  cp "$REPO_ROOT/development/skills/refine-issue/scripts/size-check.zsh" "$PLUG/skills/refine-issue/scripts/"
  for f in readiness-stamp.zsh size-preflight.zsh read-sub-issues.zsh; do
    cp "$REPO_ROOT/development/skills/resolve-issue/scripts/$f" "$PLUG/skills/resolve-issue/scripts/"
  done
  S="$PLUG/skills/resolve-issue/scripts/readiness-stamp.zsh"

  # The repo the script runs in: one local plugin, so size-check judges paths.
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/.claude-plugin"
  printf '%s\n' '{"plugins":[{"name":"development","source":"./development"}]}' \
    > "$WORK/.claude-plugin/marketplace.json"

  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX/issues"

  STUB="$BATS_TEST_TMPDIR/gh-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
[ -n "${GH_FAIL:-}" ] && exit 1
if [ "$1" = api ] && [ "$2" = graphql ]; then
  prev="" num="" page=""
  for a in "$@"; do
    if [ "$prev" = "-F" ]; then
      case "$a" in number=*) num="${a#number=}" ;; num=*) page="${a#num=}" ;; esac
    fi
    prev="$a"
  done
  if [ -n "$num" ]; then cat "$FIX/tree-$num.json"
  elif [ -n "$page" ]; then cat "$FIX/page-$page.json"
  else echo batch >> "$FIX/calls.log"; cat "$FIX/batch.json"; fi
  exit 0
fi
echo "$*" >> "$FIX/calls.log"
cat > "$FIX/last-body.json"
case "$*" in *"-X POST"*) echo '{"id":999}' ;; esac
exit 0
EOF
  chmod +x "$STUB"
}

run_s() { run env GH_BIN="$STUB" FIX="$FIX" bash -c 'cd "$1" && shift && zsh "$@"' _ "$WORK" "$S" "$@"; }

gate_now() { cat "$PLUG/agents/story-readiness.md" "$PLUG/skills/refine-issue/scripts/size-check.zsh" | shasum -a 256 | awk '{print $1}'; }

# mk_issue <num> <title> <body> <labels-json> <blockedBy-json: [[n,repo]...]> [comments-json]
mk_issue() {
  jq -n --argjson n "$1" --arg t "$2" --arg b "$3" --argjson l "$4" --argjson bb "$5" \
        --argjson c "${6:-[]}" --argjson more "${MORE:-false}" \
    '{number:$n, title:$t, body:$b,
      labels:{nodes:($l|map({name:.}))},
      blockedBy:{nodes:($bb|map({number:.[0], repository:{nameWithOwner:(.[1] // "owner/repo")}}))},
      comments:{pageInfo:{hasNextPage:$more, endCursor:(if $more then "c1" else null end)}, nodes:$c}}' \
    > "$FIX/issues/$1.json"
  mk_batch
}

mk_batch() {
  jq -s '{data:{repository:(map({key:"i\(.number)", value:.}) | from_entries)}}' "$FIX"/issues/*.json \
    > "$FIX/batch.json"
}

# comment <id> <created> <assoc> <typename> <login> <body>
comment() {
  jq -n --argjson id "$1" --arg c "$2" --arg a "$3" --arg ty "$4" --arg lo "$5" --arg b "$6" \
    '{databaseId:$id, createdAt:$c, authorAssociation:$a, author:{__typename:$ty, login:$lo}, body:$b}'
}

# stamp_body <key> <gate> <verdict-json>
stamp_body() {
  printf '<!-- readiness-stamp/v1 key=%s gate=%s at=2026-10-31T00:00:00Z -->\n<details>\n<summary>readiness verdict</summary>\n\n```json\n%s\n```\n\n</details>' "$1" "$2" "$3"
}

PASS_VERDICT='{"issue":7,"verdict":"READY","risk":"elevated","size":{"verdict":"pass","triggers":[],"files":1,"plugins":1,"inventory":["development/skills/does-not-exist/new.zsh"]}}'

key_of() { run_s key --repo owner/repo --issue "$1"; [ "$status" -eq 0 ]; KEY="$output"; }

# Gives issue 7 one stamp comment: <assoc> <typename> <login> <verdict> [key] [gate]
stamped() {
  mk_issue 7 "Add the stamp" "Body line" '["enhancement"]' '[[3]]'
  key_of 7
  local body
  body="$(stamp_body "${5:-$KEY}" "${6:-$(gate_now)}" "$4")"
  mk_issue 7 "Add the stamp" "Body line" '["enhancement"]' '[[3]]' \
    "[$(comment 501 2026-10-30T00:00:00Z "$1" "$2" "$3" "$body")]"
}

check7() { run_s check --repo owner/repo --issue 7; [ "$status" -eq 0 ]; }
miss_reason() { echo "$output" | jq -r '.misses[0].reason // "HIT"'; }

# ---- the key ----------------------------------------------------------------

@test "key: stable under CRLF, trailing whitespace and trailing blank lines" {
  mk_issue 7 "Title" $'line one\nline two' '["enhancement"]' '[]'
  key_of 7; base="$KEY"
  mk_issue 7 "Title  " $'line one  \r\nline two\t\n\n\n' '["enhancement"]' '[]'
  key_of 7
  [ "$KEY" = "$base" ]
  [ "${#KEY}" -eq 64 ]
}

@test "key: changes on a title, body, blockedBy edge or relevant label change" {
  mk_issue 7 "Title" "Body" '["enhancement"]' '[[3]]'; key_of 7; base="$KEY"
  mk_issue 7 "Title 2" "Body" '["enhancement"]' '[[3]]'; key_of 7; [ "$KEY" != "$base" ]
  mk_issue 7 "Title" "Body 2" '["enhancement"]' '[[3]]'; key_of 7; [ "$KEY" != "$base" ]
  mk_issue 7 "Title" "Body" '["enhancement"]' '[[3],[4]]'; key_of 7; [ "$KEY" != "$base" ]
  mk_issue 7 "Title" "Body" '["enhancement","epic"]' '[[3]]'; key_of 7; [ "$KEY" != "$base" ]
}

@test "key: blockedBy and label order do not matter, a foreign blocker is repo-qualified" {
  mk_issue 7 "T" "B" '["a","b"]' '[[3],[4]]'; key_of 7; base="$KEY"
  mk_issue 7 "T" "B" '["b","a"]' '[[4],[3]]'; key_of 7; [ "$KEY" = "$base" ]
  mk_issue 7 "T" "B" '["a","b"]' '[[3],[4,"other/repo"]]'; key_of 7; [ "$KEY" != "$base" ]
}

@test "key: needs-refinement and blocked labels are not inputs" {
  mk_issue 7 "T" "B" '["enhancement"]' '[]'; key_of 7; base="$KEY"
  mk_issue 7 "T" "B" '["enhancement","needs-refinement","blocked"]' '[]'; key_of 7
  [ "$KEY" = "$base" ]
}

@test "key: equals sha256 of the documented key-sorted document" {
  mk_issue 7 "T" "B" '["enhancement","blocked"]' '[[3],[4,"other/repo"]]'
  key_of 7
  [ "$KEY" = "$(jq -cnS --arg g "$(gate_now)" '{gate_version:$g,title:"T",body:"B",blocked_by:[3,"other/repo#4"],labels:["enhancement"]}' | shasum -a 256 | awk '{print $1}')" ]
}

@test "key: a gate_version change (the agent file) changes the key" {
  mk_issue 7 "T" "B" '[]' '[]'; key_of 7; base="$KEY"
  echo "one more rule" >> "$PLUG/agents/story-readiness.md"
  key_of 7
  [ "$KEY" != "$base" ]
}

@test "key: a size-check.zsh change changes the gate_version check reports" {
  mk_issue 7 "T" "B" '[]' '[]'
  run_s check --repo owner/repo --issue 7; g1="$(echo "$output" | jq -r .gate_version)"
  [ "$g1" = "$(gate_now)" ]
  echo "# comment" >> "$PLUG/skills/refine-issue/scripts/size-check.zsh"
  run_s check --repo owner/repo --issue 7; g2="$(echo "$output" | jq -r .gate_version)"
  [ "$g2" != "$g1" ]
}

# ---- check: hits ------------------------------------------------------------

@test "check: a matching trusted stamp is a hit carrying the cached verdict" {
  stamped OWNER User timo "$PASS_VERDICT"
  check7
  [ "$(echo "$output" | jq -c '[.hits[].issue, (.misses|length)]')" = '[7,0]' ]
  [ "$(echo "$output" | jq -r '.hits[0].verdict.risk')" = elevated ]
}

@test "check: a hit never tests whether the inventory's paths exist" {
  stamped MEMBER User timo "$PASS_VERDICT"
  [ ! -e "$WORK/development/skills/does-not-exist/new.zsh" ]
  check7
  [ "$(miss_reason)" = HIT ]
}

@test "check: a cached stop that still stops is a hit" {
  inv="$(jq -nc '[range(21) | "development/f\(.).md"]')"
  v="$(jq -nc --argjson i "$inv" '{verdict:"NEEDS_REFINEMENT",risk:"normal",size:{verdict:"stop",triggers:["files"],files:21,plugins:1,inventory:$i}}')"
  stamped COLLABORATOR User timo "$v"
  check7
  [ "$(miss_reason)" = HIT ]
  [ "$(echo "$output" | jq -r '.hits[0].verdict.verdict')" = NEEDS_REFINEMENT ]
}

@test "check: the owner's Maintenance App is trusted with no association" {
  stamped NONE Bot claude-maintenance-owner "$PASS_VERDICT"
  check7
  [ "$(miss_reason)" = HIT ]
}

@test "check: a stamp on the second comment page is found" {
  mk_issue 7 "Add the stamp" "Body line" '["enhancement"]' '[[3]]'
  key_of 7
  body="$(stamp_body "$KEY" "$(gate_now)" "$PASS_VERDICT")"
  MORE=true mk_issue 7 "Add the stamp" "Body line" '["enhancement"]' '[[3]]' \
    "[$(comment 1 2026-10-01T00:00:00Z NONE User someone "hello")]"
  jq -n --argjson c "$(comment 2 2026-10-02T00:00:00Z OWNER User timo "$body")" \
    '{data:{repository:{issue:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[$c]}}}}}' \
    > "$FIX/page-7.json"
  check7
  [ "$(miss_reason)" = HIT ]
}

# ---- check: one miss per reason ---------------------------------------------

@test "check: no stamp comment is no_stamp" {
  mk_issue 7 "T" "B" '[]' '[]' "[$(comment 1 2026-10-01T00:00:00Z OWNER User timo "just a comment")]"
  check7
  [ "$(miss_reason)" = no_stamp ]
}

@test "check: a stamp by an untrusted author is untrusted_author" {
  stamped NONE User drive-by "$PASS_VERDICT"
  check7
  [ "$(miss_reason)" = untrusted_author ]
}

@test "check: another owner's Maintenance App and a look-alike user are untrusted" {
  stamped NONE Bot claude-maintenance-someone-else "$PASS_VERDICT"
  check7
  [ "$(miss_reason)" = untrusted_author ]
  stamped NONE User claude-maintenance-owner "$PASS_VERDICT"
  check7
  [ "$(miss_reason)" = untrusted_author ]
}

@test "check: a verdict without size.inventory is malformed" {
  v="$(echo "$PASS_VERDICT" | jq -c 'del(.size.inventory)')"
  stamped OWNER User timo "$v"
  check7
  [ "$(miss_reason)" = malformed ]
}

@test "check: an unparseable verdict is malformed, a broken marker is no stamp" {
  stamped OWNER User timo '{"verdict": READY'
  check7
  [ "$(miss_reason)" = malformed ]
  stamped OWNER User timo "$PASS_VERDICT" "not-a-key"
  check7
  [ "$(miss_reason)" = no_stamp ]
}

@test "check: a stamp from another gate version is gate_changed" {
  stamped OWNER User timo "$PASS_VERDICT" "" "$(printf '0%.0s' $(seq 64))"
  check7
  [ "$(miss_reason)" = gate_changed ]
}

@test "check: a stamp whose key no longer matches is key_changed" {
  stamped OWNER User timo "$PASS_VERDICT" "$(printf 'a%.0s' $(seq 64))"
  check7
  [ "$(miss_reason)" = key_changed ]
}

@test "check: an edited body after stamping is key_changed" {
  stamped OWNER User timo "$PASS_VERDICT"
  jq '.body = "Body line, edited"' "$FIX/issues/7.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/7.json"
  mk_batch
  check7
  [ "$(miss_reason)" = key_changed ]
}

@test "check: a size re-check that differs from the cached one is inventory_drift" {
  inv="$(jq -nc '[range(21) | "development/f\(.).md"]')"
  v="$(echo "$PASS_VERDICT" | jq -c --argjson i "$inv" '.size.inventory = $i')"
  stamped OWNER User timo "$v"
  check7
  [ "$(miss_reason)" = inventory_drift ]
}

@test "check: the same size verdict with different triggers is inventory_drift" {
  # a second plugin makes the fresh stop carry `plugin` beside `files`
  printf '%s\n' '{"plugins":[{"name":"development","source":"./development"},{"name":"other","source":"./other"}]}' \
    > "$WORK/.claude-plugin/marketplace.json"
  inv="$(jq -nc '[range(20) | "development/f\(.).md"] + ["other/g.md"]')"
  v="$(jq -nc --argjson i "$inv" '{verdict:"NEEDS_REFINEMENT",risk:"normal",size:{verdict:"stop",triggers:["files"],files:21,plugins:2,inventory:$i}}')"
  stamped OWNER User timo "$v"
  check7
  [ "$(miss_reason)" = inventory_drift ]
}

@test "check: a size re-check that exits 3 is inventory_drift, not an error" {
  v="$(echo "$PASS_VERDICT" | jq -c '.size.inventory = [{"not":"a path"}]')"
  stamped OWNER User timo "$v"
  check7
  [ "$(miss_reason)" = inventory_drift ]
}

@test "check: the newest trusted stamp wins over an older one" {
  mk_issue 7 "Add the stamp" "Body line" '["enhancement"]' '[[3]]'
  key_of 7
  good="$(stamp_body "$KEY" "$(gate_now)" "$PASS_VERDICT")"
  bad="$(stamp_body "$KEY" "$(gate_now)" '{"verdict":"READY"}')"
  mk_issue 7 "Add the stamp" "Body line" '["enhancement"]' '[[3]]' \
    "[$(comment 1 2026-10-01T00:00:00Z OWNER User timo "$bad"),$(comment 2 2026-10-02T00:00:00Z OWNER User timo "$good"),$(comment 3 2026-10-03T00:00:00Z NONE User x "$bad")]"
  check7
  [ "$(miss_reason)" = HIT ]
  mk_issue 7 "Add the stamp" "Body line" '["enhancement"]' '[[3]]' \
    "[$(comment 1 2026-10-01T00:00:00Z OWNER User timo "$good"),$(comment 2 2026-10-02T00:00:00Z OWNER User timo "$bad")]"
  check7
  [ "$(miss_reason)" = malformed ]
}

@test "check --epic: targets the open same-repo leaves, in one batched read" {
  tree() {  # tree <num> <state> <total> <children-json>
    jq -n --argjson n "$1" --arg s "$2" --argjson t "$3" --argjson k "$4" \
      '{data:{repository:{issue:{number:$n,state:$s,body:"",labels:{nodes:[]},
        subIssuesSummary:{total:$t,completed:0},
        subIssues:{nodes:($k|map({number:.[0],state:.[1],repository:{nameWithOwner:(.[2] // "owner/repo")}}))}}}}}' \
      > "$FIX/tree-$1.json"
  }
  tree 10 OPEN 4 '[[11,"OPEN"],[12,"CLOSED"],[13,"OPEN","other/repo"],[14,"OPEN"]]'
  tree 11 OPEN 0 '[]'
  tree 12 CLOSED 0 '[]'
  tree 14 OPEN 1 '[[15,"OPEN"]]'
  tree 15 OPEN 0 '[]'
  mk_issue 11 "T" "B" '[]' '[]'
  mk_issue 15 "T" "B" '[]' '[]'
  run_s check --repo owner/repo --epic 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.misses[] | [.issue, .reason]] | sort')" = '[[11,"no_stamp"],[15,"no_stamp"]]' ]
  [ "$(grep -c '^batch$' "$FIX/calls.log")" -eq 1 ]
}

@test "check --epic: an issue with no sub-issues has no targets and reads nothing" {
  jq -n '{data:{repository:{issue:{number:10,state:"OPEN",body:"",labels:{nodes:[]},
    subIssuesSummary:{total:0,completed:0},subIssues:{nodes:[]}}}}}' > "$FIX/tree-10.json"
  run_s check --repo owner/repo --epic 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.hits, .misses]')" = '[[],[]]' ]
  [ ! -e "$FIX/calls.log" ]
}

# ---- write ------------------------------------------------------------------

@test "write: creates a stamp when none exists, keyed at write time" {
  mk_issue 7 "T" "B" '[]' '[]'
  key_of 7
  echo "$PASS_VERDICT" > "$FIX/v.json"
  run_s write --repo owner/repo --issue 7 --verdict-file "$FIX/v.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.action, .comment_id, .key]')" = "[\"created\",999,\"$KEY\"]" ]
  contains "$(cat "$FIX/calls.log")" "-X POST repos/owner/repo/issues/7/comments"
  body="$(jq -r .body "$FIX/last-body.json")"
  contains "$body" "<!-- readiness-stamp/v1 key=$KEY gate=$(gate_now) at="
  contains "$body" '"inventory":["development/skills/does-not-exist/new.zsh"]'
}

@test "write: a written stamp is a hit on the next check" {
  mk_issue 7 "T" "B" '[]' '[]'
  echo "$PASS_VERDICT" > "$FIX/v.json"
  run_s write --repo owner/repo --issue 7 --verdict-file "$FIX/v.json"
  [ "$status" -eq 0 ]
  mk_issue 7 "T" "B" '[]' '[]' "[$(comment 999 2026-10-31T00:00:00Z OWNER User timo "$(jq -r .body "$FIX/last-body.json")")]"
  check7
  [ "$(miss_reason)" = HIT ]
}

@test "write: edits the existing trusted stamp in place and creates nothing" {
  stamped OWNER User timo "$PASS_VERDICT" "$(printf 'a%.0s' $(seq 64))"
  echo "$PASS_VERDICT" > "$FIX/v.json"
  run_s write --repo owner/repo --issue 7 --verdict-file "$FIX/v.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.action, .comment_id]')" = '["edited",501]' ]
  contains "$(cat "$FIX/calls.log")" "-X PATCH repos/owner/repo/issues/comments/501"
  lacks "$(cat "$FIX/calls.log")" "POST"
}

@test "write: leaves one stamp — older trusted stamps are deleted, untrusted ones ignored" {
  mk_issue 7 "T" "B" '[]' '[]'
  b="$(stamp_body "$(printf 'a%.0s' $(seq 64))" "$(gate_now)" "$PASS_VERDICT")"
  mk_issue 7 "T" "B" '[]' '[]' \
    "[$(comment 1 2026-10-01T00:00:00Z OWNER User timo "$b"),$(comment 2 2026-10-02T00:00:00Z MEMBER User m "$b"),$(comment 3 2026-10-03T00:00:00Z NONE User x "$b"),$(comment 4 2026-10-04T00:00:00Z OWNER User timo "quoting:
$b")]"
  echo "$PASS_VERDICT" > "$FIX/v.json"
  run_s write --repo owner/repo --issue 7 --verdict-file "$FIX/v.json"
  [ "$status" -eq 0 ]
  log="$(cat "$FIX/calls.log")"
  contains "$log" "-X PATCH repos/owner/repo/issues/comments/2"
  contains "$log" "-X DELETE repos/owner/repo/issues/comments/1"
  lacks "$log" "comments/3"
  lacks "$log" "comments/4"
  lacks "$log" "POST"
}

@test "write: an untrusted stamp is never edited — a trusted one is created" {
  stamped NONE User drive-by "$PASS_VERDICT"
  echo "$PASS_VERDICT" > "$FIX/v.json"
  run_s write --repo owner/repo --issue 7 --verdict-file "$FIX/v.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .action)" = created ]
  lacks "$(cat "$FIX/calls.log")" "501"
}

@test "write --expect-key: a matching key stamps as usual" {
  mk_issue 7 "T" "B" '[]' '[]'
  key_of 7
  echo "$PASS_VERDICT" > "$FIX/v.json"
  run_s write --repo owner/repo --issue 7 --verdict-file "$FIX/v.json" --expect-key "$KEY"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.action, .comment_id, .key]')" = "[\"created\",999,\"$KEY\"]" ]
  contains "$(cat "$FIX/calls.log")" "-X POST repos/owner/repo/issues/7/comments"
}

@test "write --expect-key: a changed key writes, edits and deletes nothing" {
  stamped OWNER User timo "$PASS_VERDICT" "$(printf 'a%.0s' $(seq 64))"
  key_of 7; fresh="$KEY"
  stale="$(printf 'b%.0s' $(seq 64))"
  rm -f "$FIX/calls.log"
  echo "$PASS_VERDICT" > "$FIX/v.json"
  run_s write --repo owner/repo --issue 7 --verdict-file "$FIX/v.json" --expect-key "$stale"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.action, .key, .expected_key]')" = "[\"skipped_stale\",\"$fresh\",\"$stale\"]" ]
  # the issue read is the only gh call: no POST, PATCH or DELETE
  [ "$(grep -cv '^batch$' "$FIX/calls.log")" -eq 0 ]
}

# ---- exit codes -------------------------------------------------------------

@test "exit 2: usage errors" {
  run_s; [ "$status" -eq 2 ]; contains "$output" "a mode is required"
  run_s frob --repo owner/repo; [ "$status" -eq 2 ]; contains "$output" "unknown mode"
  run_s key --issue 7; [ "$status" -eq 2 ]; contains "$output" "--repo OWNER/NAME is required"
  run_s key --repo owner --issue 7; [ "$status" -eq 2 ]; contains "$output" "must be OWNER/NAME"
  run_s key --repo owner/repo --issue x; [ "$status" -eq 2 ]; contains "$output" "must be numeric"
  run_s key --repo owner/repo --epic 7; [ "$status" -eq 2 ]; contains "$output" "only valid with check"
  run_s check --repo owner/repo; [ "$status" -eq 2 ]; contains "$output" "one of --epic N or --issue N"
  run_s check --repo owner/repo --epic 1 --issue 2; [ "$status" -eq 2 ]; contains "$output" "mutually exclusive"
  run_s check --repo owner/repo --issue; [ "$status" -eq 2 ]; contains "$output" "--issue needs a value"
  run_s write --repo owner/repo --issue 7; [ "$status" -eq 2 ]; contains "$output" "--verdict-file F is required"
  run_s key --repo owner/repo --issue 7 --verdict-file x; [ "$status" -eq 2 ]; contains "$output" "only valid with write"
  run_s check --repo owner/repo --issue 7 --expect-key "$(printf 'a%.0s' $(seq 64))"; [ "$status" -eq 2 ]
  contains "$output" "--expect-key is only valid with write"
  run_s write --repo owner/repo --issue 7 --verdict-file x --expect-key abc; [ "$status" -eq 2 ]
  contains "$output" "--expect-key must be a 64-character lowercase hex key"
}

@test "exit 0: --help prints the usage and reads nothing" {
  run_s --help
  [ "$status" -eq 0 ]
  contains "$output" "usage: readiness-stamp.zsh key --repo R --issue N"
  [ ! -e "$FIX/calls.log" ]
}

@test "exit 2: a verdict file that is not a sized verdict" {
  mk_issue 7 "T" "B" '[]' '[]'
  echo "$PASS_VERDICT" | jq -c 'del(.size.inventory)' > "$FIX/v.json"
  run_s write --repo owner/repo --issue 7 --verdict-file "$FIX/v.json"
  [ "$status" -eq 2 ]
  contains "$output" "size.inventory"
  run_s write --repo owner/repo --issue 7 --verdict-file "$FIX/missing.json"
  [ "$status" -eq 2 ]
  [ ! -e "$FIX/calls.log" ]
}

@test "exit 3: a gh failure, with nothing on stdout" {
  mk_issue 7 "T" "B" '[]' '[]'
  run env GH_BIN="$STUB" FIX="$FIX" GH_FAIL=1 bash -c 'cd "$1" && zsh "$2" check --repo owner/repo --issue 7 2>/dev/null' _ "$WORK" "$S"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "exit 3: missing gate files" {
  mk_issue 7 "T" "B" '[]' '[]'
  rm "$PLUG/agents/story-readiness.md"
  run_s key --repo owner/repo --issue 7
  [ "$status" -eq 3 ]
  contains "$output" "gate files not found"
}

@test "exit 3: an issue the batch does not return" {
  mk_issue 7 "T" "B" '[]' '[]'
  run_s check --repo owner/repo --issue 8
  [ "$status" -eq 3 ]
  contains "$output" "issue #8 could not be read"
}

# ---- the contract prose ----------------------------------------------------

@test "prose: story-readiness reports size.inventory, copied from the sized file" {
  local gate="$REPO_ROOT/development/agents/story-readiness.md"
  grep -qF '`size` also holds `inventory`: the exact `files` array you passed to' "$gate"
  grep -qF 'a single concrete path. Copy it from the inventory file you sized; never' "$gate"
  grep -qF 're-derive it. `readiness-stamp.zsh` re-runs the size check on this list to' "$gate"
}

@test "prose: ARCHITECTURE.md states the stamp contract's size and existence rules" {
  local arch="$REPO_ROOT/ARCHITECTURE.md"
  grep -qF '## Readiness stamp contract (`readiness-stamp/v1`)' "$arch"
  grep -qF '<!-- readiness-stamp/v1 key=<sha256> gate=<gate_version> at=<ISO date> -->' "$arch"
  grep -qF 're-check compares results rather than requiring a pass. `check` re-runs' "$arch"
  grep -qF '`inventory_drift` miss. So an unchanged size-stopped story keeps its cached' "$arch"
  grep -qF -- '- **No existence test.** A stamp hit never depends on whether the inventory'"'"'s' "$arch"
  grep -qF 'So the only repo-drift re-check is the size comparison, which makes no' "$arch"
  grep -qF 'or when its author is the repository owner'"'"'s Maintenance App: a GraphQL `Bot`' "$arch"
}

@test "prose: ARCHITECTURE.md names the key's input set and the inputs a hit never re-checks" {
  local arch="$REPO_ROOT/ARCHITECTURE.md"
  grep -qF -- '- **A hit is only as fresh as its key.** A hit returns exactly the verdict a' "$arch"
  grep -qF 'gate produced for the same key and the same `gate_version`. Anything else is a' "$arch"
  grep -qF 'miss. The key covers only its declared input set: the title, the body, the' "$arch"
  grep -qF '`gate_version`. The gate also reads two inputs that are deliberately **not** key' "$arch"
  grep -qF 'inputs: the repo code a story references, and the state of its linked issues,' "$arch"
  grep -qF '`test-case`. A change to either moves no key, and a hit never re-checks them.' "$arch"
  grep -qF 'linked test-case issue, delete the stamp comment, or the old stop keeps' "$arch"
  lacks "$(cat "$arch")" 'Never a weaker gate'
  lacks "$(cat "$arch")" 'function of the inventory alone'
}

@test "prose: --expect-key is documented in ARCHITECTURE.md and the script header" {
  local arch="$REPO_ROOT/ARCHITECTURE.md"
  local hdr="$REPO_ROOT/development/skills/resolve-issue/scripts/readiness-stamp.zsh"
  grep -qF '**`--expect-key K` guards against an edit during the gate run.** It is opt-in. The' "$arch"
  grep -qF '`write` still computes the key at write time. When that key differs from `K`,' "$arch"
  grep -qF '`{"issue", "key", "expected_key", "gate_version", "action": "skipped_stale"}`.' "$arch"
  grep -qF '#       --expect-key K is the opt-in race guard: K is the key the caller read' "$hdr"
  grep -qF '#       differs from K, the issue changed while the gate ran, so write creates,' "$hdr"
  grep -qF '#       edits and deletes nothing, exits 0 and prints' "$hdr"
}

@test "exit 0: every stamp problem is a miss, never a nonzero exit" {
  stamped OWNER User timo '{"verdict": READY'
  check7
  [ "$(miss_reason)" = malformed ]
}
