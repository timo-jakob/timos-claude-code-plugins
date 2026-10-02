#!/usr/bin/env bats
#
# Behavioral tests for `review-dispatch.zsh split-carry` (#2010): each carried
# entry gets exactly one owner. The carry is split per dimension so every
# reviewer is handed only its own dimension's entries; the input carry stays
# byte-unchanged because it is still the loop's carry. The subcommand reads no
# repository, so no git fixture is needed.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/review-dispatch.zsh"
  W="$BATS_TEST_TMPDIR/work"
  mkdir -p "$W"
  # the epic's data sketch: four entries over three dimensions
  printf '%s\n' '[{"file":"development/skills/resolve-issue/scripts/run-gate.zsh","dimension":"script_quality","title":"unquoted jobs count","line":41},{"file":"tests/run-gate.bats","dimension":"tests","title":"no case for the degraded mode","line":null},{"file":"development/skills/resolve-issue/scripts/run-gate.zsh","dimension":"script_quality","title":"exit code of the summary write ignored","line":88},{"file":"development/skills/resolve-issue/SKILL.md","dimension":"prose_logic","title":"gate step names no failure branch","line":120}]' > "$W/verify-3.json"
  cp "$W/verify-3.json" "$W/verify-3.orig"
}

split() { run zsh "$S" split-carry "$@"; }

@test "split-carry: each per-dimension file holds only its own dimension, the union is the input, the input is byte-unchanged" {
  split --fix-verification "$W/verify-3.json"
  [ "$status" -eq 0 ]
  # the map names exactly the three dimensions, each at <stem>-<dimension>.json
  [ "$(echo "$output" | jq -c 'keys')" = '["prose_logic","script_quality","tests"]' ]
  [ "$(echo "$output" | jq -r '.script_quality')" = "$W/verify-3-script_quality.json" ]
  [ "$(echo "$output" | jq -r '.tests')" = "$W/verify-3-tests.json" ]
  [ "$(echo "$output" | jq -r '.prose_logic')" = "$W/verify-3-prose_logic.json" ]
  # own dimension only, with the counts of the sketch (2 + 1 + 1)
  [ "$(jq -r '[.[].dimension] | unique | join(",")' "$W/verify-3-script_quality.json")" = "script_quality" ]
  [ "$(jq 'length' "$W/verify-3-script_quality.json")" -eq 2 ]
  [ "$(jq -r '[.[].dimension] | unique | join(",")' "$W/verify-3-tests.json")" = "tests" ]
  [ "$(jq 'length' "$W/verify-3-tests.json")" -eq 1 ]
  [ "$(jq -r '[.[].dimension] | unique | join(",")' "$W/verify-3-prose_logic.json")" = "prose_logic" ]
  [ "$(jq 'length' "$W/verify-3-prose_logic.json")" -eq 1 ]
  # the union of the per-dimension files equals the input, entry for entry
  local union input
  union="$(jq -s -c 'add | sort_by(.file, .dimension, .title)' \
    "$W/verify-3-script_quality.json" "$W/verify-3-tests.json" "$W/verify-3-prose_logic.json")"
  input="$(jq -c 'sort_by(.file, .dimension, .title)' "$W/verify-3.json")"
  [ "$union" = "$input" ]
  # and the input itself was never touched
  cmp -s "$W/verify-3.json" "$W/verify-3.orig"
}

@test "split-carry: an empty carry prints {} and writes no per-dimension file" {
  printf '[]\n' > "$W/verify-4.json"
  split --fix-verification "$W/verify-4.json"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
  run ls "$W"
  lacks "$output" 'verify-4-'
}

@test "split-carry: a carry-redispatch projection splits under its own stem" {
  jq -c '[.[0]]' "$W/verify-3.json" > "$W/verify-3-carry.json"
  # a previous redispatch's split is replaced, never kept
  printf '%s\n' '[{"file":"stale","dimension":"script_quality","title":"old"}]' > "$W/verify-3-carry-script_quality.json"
  split --fix-verification "$W/verify-3-carry.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c .)" = "{\"script_quality\":\"$W/verify-3-carry-script_quality.json\"}" ]
  [ "$(jq 'length' "$W/verify-3-carry-script_quality.json")" -eq 1 ]
  [ "$(jq -r '.[0].title' "$W/verify-3-carry-script_quality.json")" = "unquoted jobs count" ]
}

@test "split-carry: a per-dimension file it cannot write is exit 1, leaving no partial file" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores the directory's write bit"
  chmod a-w "$W"
  split --fix-verification "$W/verify-3.json"
  chmod u+w "$W"
  [ "$status" -eq 1 ]
  contains "$output" 'could not write'
  run ls "$W"
  [ "$output" = "$(printf 'verify-3.json\nverify-3.orig')" ]
}

@test "split-carry: an entry with no dimension has no owner and is refused, never dropped" {
  printf '%s\n' '[{"file":"a.zsh","dimension":"script_quality","title":"x"},{"file":"b.zsh","title":"ownerless"}]' > "$W/verify-5.json"
  split --fix-verification "$W/verify-5.json"
  [ "$status" -eq 1 ]
  contains "$output" 'each name a dimension'
  # refused before any write: no partial split a reviewer could read as the carry
  [ ! -e "$W/verify-5-script_quality.json" ]
}

@test "split-carry: a dimension that is not name-safe is refused (no path escape)" {
  printf '%s\n' '[{"file":"a.zsh","dimension":"../escape","title":"x"}]' > "$W/verify-6.json"
  split --fix-verification "$W/verify-6.json"
  [ "$status" -eq 1 ]
  [ ! -e "$W/verify-6-../escape.json" ]
  [ ! -e "$BATS_TEST_TMPDIR/escape.json" ]
  printf '%s\n' '[{"file":"a.zsh","dimension":".hidden","title":"x"}]' > "$W/verify-7.json"
  split --fix-verification "$W/verify-7.json"
  [ "$status" -eq 1 ]
}

@test "split-carry: a missing, empty or multi-value carry is exit 1" {
  split --fix-verification "$W/absent.json"
  [ "$status" -eq 1 ]
  : > "$W/empty.json"
  split --fix-verification "$W/empty.json"
  [ "$status" -eq 1 ]
  printf '[]\n[]\n' > "$W/two.json"
  split --fix-verification "$W/two.json"
  [ "$status" -eq 1 ]
  printf '{"dimension":"tests"}\n' > "$W/obj.json"
  split --fix-verification "$W/obj.json"
  [ "$status" -eq 1 ]
}

@test "split-carry: a missing flag, a stray argument or a non-.json path is a usage error (exit 2)" {
  split
  [ "$status" -eq 2 ]
  split --fix-verification
  [ "$status" -eq 2 ]
  split --fix-verification "$W/verify-3.json" extra
  [ "$status" -eq 2 ]
  cp "$W/verify-3.json" "$W/verify-3.txt"
  split --fix-verification "$W/verify-3.txt"
  [ "$status" -eq 2 ]
  [ ! -e "$W/verify-3.txt-tests.json" ]
}
