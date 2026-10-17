#!/usr/bin/env bats
#
# #2602: read-split-park.zsh — refine-issue reads resolve-issue's size pre-flight
# park (the needs-split label and the newest SPLIT/OVERRIDDEN comment) as a size
# objection, with the plan inventory from the SPLIT comment's v1 marker. The
# label is the switch; the newest size pre-flight comment is the evidence; a
# bad or absent marker falls back to the comment's triggers and counts.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  export HOME="$BATS_TEST_TMPDIR/home"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  R="$REPO_ROOT/development/skills/refine-issue/scripts/read-split-park.zsh"
  D="$BATS_TEST_TMPDIR"
  SPLIT1='size pre-flight: SPLIT — files 23 > 20; see /development:refine-issue'
  MARK='<!-- size-preflight-inventory/v1: {"files":["a.md","b.md"]} -->'
  OVER='size pre-flight: OVERRIDDEN by the human — files 23 > 20'
}

# write the issue JSON: $1 = labels json array, then each comment body
issue() {
  local labels="$1"; shift
  local c bodies="[]"
  for c in "$@"; do
    bodies="$(jq -c --arg b "$c" '. + [{body: $b, author: {login: "u"}}]' <<< "$bodies")"
  done
  jq -n --argjson l "$labels" --argjson c "$bodies" '{labels: $l, comments: $c}' > "$D/issue.json"
}

@test "with needs-split and a SPLIT comment carrying a v1 marker: an objection with the summary and the inventory" {
  issue '[{"name":"needs-split"},{"name":"enhancement"}]' "$(printf '%s\n\n%s' "$SPLIT1" "$MARK")"
  run -0 --separate-stderr zsh "$R" --file "$D/issue.json"
  [ -z "$stderr" ]
  [ "$output" = '{"objection":true,"reason":"split","summary":"files 23 > 20; see /development:refine-issue","inventory":{"files":["a.md","b.md"]}}' ]
}

@test "without the needs-split label there is no objection, even when a SPLIT comment is present (no-label)" {
  issue '[{"name":"needs-refinement"}]' "$(printf '%s\n\n%s' "$SPLIT1" "$MARK")"
  run -0 zsh "$R" --file "$D/issue.json"
  [ "$output" = '{"objection":false,"reason":"no-label","summary":null,"inventory":null}' ]
}

@test "with needs-split and a newest OVERRIDDEN comment, the label is stale (stale-overridden)" {
  issue '[{"name":"needs-split"}]' "$(printf '%s\n\n%s' "$SPLIT1" "$MARK")" "$OVER"
  run -0 zsh "$R" --file "$D/issue.json"
  [ "$output" = '{"objection":false,"reason":"stale-overridden","summary":null,"inventory":null}' ]
}

@test "with needs-split and no size pre-flight comment, the label is stale (stale-no-comment)" {
  issue '[{"name":"needs-split"}]' "A human comment." "size pre-flight is mentioned here but this is not one"
  run -0 zsh "$R" --file "$D/issue.json"
  [ "$output" = '{"objection":false,"reason":"stale-no-comment","summary":null,"inventory":null}' ]
}

@test "the newest of several SPLIT comments supplies the summary and the inventory" {
  issue '[{"name":"needs-split"}]' \
    "$(printf '%s\n\n%s' "$SPLIT1" "$MARK")" \
    "$(printf '%s\n\n%s' 'size pre-flight: SPLIT — files 30 > 20, plugin; see /development:refine-issue' '<!-- size-preflight-inventory/v1: {"files":["z.md"]} -->')"
  run -0 zsh "$R" --file "$D/issue.json"
  printf '%s' "$output" | jq -e '.summary == "files 30 > 20, plugin; see /development:refine-issue" and .inventory == {files: ["z.md"]}' >/dev/null
}

@test "an OVERRIDDEN followed by a SPLIT is an objection; a SPLIT followed by an OVERRIDDEN is not" {
  issue '[{"name":"needs-split"}]' "$OVER" "$(printf '%s\n\n%s' "$SPLIT1" "$MARK")"
  run -0 zsh "$R" --file "$D/issue.json"
  printf '%s' "$output" | jq -e '.objection == true and .reason == "split"' >/dev/null
  issue '[{"name":"needs-split"}]' "$(printf '%s\n\n%s' "$SPLIT1" "$MARK")" "$OVER"
  run -0 zsh "$R" --file "$D/issue.json"
  printf '%s' "$output" | jq -e '.objection == false and .reason == "stale-overridden"' >/dev/null
}

@test "a SPLIT comment without a marker, or with another version, falls back to inventory null with no stderr note" {
  issue '[{"name":"needs-split"}]' "$SPLIT1"
  run -0 --separate-stderr zsh "$R" --file "$D/issue.json"
  [ -z "$stderr" ]
  printf '%s' "$output" | jq -e '.objection == true and .inventory == null and .summary == "files 23 > 20; see /development:refine-issue"' >/dev/null
  issue '[{"name":"needs-split"}]' "$(printf '%s\n\n%s' "$SPLIT1" '<!-- size-preflight-inventory/v2: {"files":["a.md"]} -->')"
  run -0 --separate-stderr zsh "$R" --file "$D/issue.json"
  [ -z "$stderr" ]
  printf '%s' "$output" | jq -e '.objection == true and .inventory == null' >/dev/null
}

@test "a v1 marker whose payload is not one JSON object with a files array falls back with a stderr note, never exit 3" {
  local bad
  for bad in '{"files":' '["a.md"]' '{"paths":["a.md"]}' '{"files":"a.md"}'; do
    issue '[{"name":"needs-split"}]' "$(printf '%s\n\n<!-- size-preflight-inventory/v1: %s -->' "$SPLIT1" "$bad")"
    run -0 --separate-stderr zsh "$R" --file "$D/issue.json"
    printf '%s' "$output" | jq -e '.objection == true and .inventory == null' >/dev/null || { echo "payload $bad"; return 1; }
    contains "$stderr" "is not one JSON object with a files array; falling back to its triggers and counts"
  done
}

@test "a v1 marker whose JSON payload spans two lines still yields the inventory" {
  issue '[{"name":"needs-split"}]' "$(printf '%s\n\n<!-- size-preflight-inventory/v1: {"files":\n["a.md","b.md"]} -->' "$SPLIT1")"
  run -0 --separate-stderr zsh "$R" --file "$D/issue.json"
  [ -z "$stderr" ]
  printf '%s' "$output" | jq -e '.objection == true and .inventory == {files: ["a.md", "b.md"]}' >/dev/null
}

@test "a v1 marker payload holding two JSON documents falls back to inventory null with the stderr note" {
  issue '[{"name":"needs-split"}]' "$(printf '%s\n\n<!-- size-preflight-inventory/v1: {"files":["a.md"]} {"files":["b.md"]} -->' "$SPLIT1")"
  run -0 --separate-stderr zsh "$R" --file "$D/issue.json"
  printf '%s' "$output" | jq -e '.objection == true and .inventory == null' >/dev/null
  contains "$stderr" "is not one JSON object with a files array; falling back to its triggers and counts"
}

@test "the input can come on stdin, and labels or comments given as plain strings are read too" {
  jq -n --arg b "$(printf '%s\n\n%s' "$SPLIT1" "$MARK")" '{labels: ["needs-split"], comments: [$b]}' > "$D/plain.json"
  run -0 zsh -c 'zsh "$1" < "$2"' _ "$R" "$D/plain.json"
  printf '%s' "$output" | jq -e '.objection == true and .inventory == {files: ["a.md", "b.md"]}' >/dev/null
}

@test "input that is not valid JSON, or lacks labels or comments, is exit 3 with nothing on stdout" {
  printf 'not json\n' > "$D/bad.json"
  run -3 --separate-stderr zsh "$R" --file "$D/bad.json"
  [ -z "$output" ]
  contains "$stderr" "input is not one JSON object with labels and comments arrays"
  printf '{"labels":[]}\n' > "$D/bad.json"
  run -3 --separate-stderr zsh "$R" --file "$D/bad.json"
  [ -z "$output" ]
}

@test "usage errors are exit 2 with nothing on stdout" {
  run -2 --separate-stderr zsh "$R" --file "$D/missing.json"
  [ -z "$output" ]
  contains "$stderr" "cannot read --file"
  run -2 --separate-stderr zsh "$R" --file
  contains "$stderr" "--file requires a value"
  run -2 --separate-stderr zsh "$R" --bogus
  contains "$stderr" "unknown argument: --bogus"
}

@test "-h prints the usage on stderr only and exits 0" {
  run -0 --separate-stderr zsh "$R" -h
  [ -z "$output" ]
  contains "$stderr" "usage: read-split-park.zsh [--file <gh-issue-view.json>]"
}
