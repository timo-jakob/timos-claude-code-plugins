#!/usr/bin/env bats
#
# readiness-cache-plan.zsh (#2955, epic #2953): which stories the readiness gate
# runs on, which take a cached verdict, and when a dependency cycle halts the
# pre-flight. Pure — the --check document stands in for readiness-stamp.zsh
# check and the --deps records for read-dependencies.zsh — so every arm is
# driven without GitHub. The last cases pin the skill's calls to the script.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  P="$REPO_ROOT/development/skills/resolve-issue/scripts/readiness-cache-plan.zsh"
  SKILL="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  TREE_REF="$REPO_ROOT/development/skills/resolve-issue/reference/epic-tree.md"
  CACHE_REF="$REPO_ROOT/development/skills/resolve-issue/reference/readiness-cache.md"
  CHECK="$BATS_TEST_TMPDIR/check.json"
  DEPS="$BATS_TEST_TMPDIR/deps.jsonl"
}

# a cached verdict for issue $1 with verdict $2 and risk $3
verdict() {
  printf '{"issue":%s,"verdict":"%s","risk":"%s","size":{"verdict":"pass","triggers":[],"inventory":["a.zsh"]}}' "$1" "$2" "$3"
}

# a check document: hits as "N:VERDICT:RISK" words, then `--`, then misses as "N:reason"
check_doc() {
  local hits="" misses="" w in_misses=0
  for w in "$@"; do
    if [ "$w" = "--" ]; then in_misses=1; continue; fi
    if [ "$in_misses" = 1 ]; then
      misses+="${misses:+,}{\"issue\":${w%%:*},\"reason\":\"${w#*:}\"}"
    else
      IFS=: read -r n v r <<<"$w"
      hits+="${hits:+,}{\"issue\":$n,\"verdict\":$(verdict "$n" "$v" "$r")}"
    fi
  done
  printf '{"gate_version":"%s","hits":[%s],"misses":[%s]}\n' "$(printf 'g%.0s' {1..64})" "$hits" "$misses" > "$CHECK"
}

# a read-dependencies.zsh record: $1 = issue, $2 = blockers as "N" words (OPEN,
# depth 1); CYCLES and TRUNC override the cycles array and truncated flag
rec() {
  local issue="$1"; shift
  local b="" items=""
  for b in "$@"; do
    items+="${items:+,}{\"number\":$b,\"state\":\"OPEN\",\"open\":true,\"kind\":\"issue\",\"depth\":1}"
  done
  printf '{"issue":%s,"blocked":false,"open_blockers":[],"blockers":[%s],"foreign_blockers":[],"cycles":%s,"truncated":%s}\n' \
    "$issue" "$items" "${CYCLES:-[]}" "${TRUNC:-false}"
}

plan() { run --separate-stderr zsh "$P" "$@"; }

@test "#2955 AC8 an epic whose children are all hits dispatches no gate" {
  check_doc 11:READY:normal 12:READY:elevated 13:READY:low
  { rec 11; rec 12 11; rec 13 12; } > "$DEPS"
  plan --targets 11,12,13 --check "$CHECK" --deps "$DEPS"
  [ "$status" -eq 0 ]
  [ "$(jq -c .dispatch <<<"$output")" = "[]" ]
  [ "$(jq -c '[.hits[].issue]' <<<"$output")" = "[11,12,13]" ]
  [ "$(jq -c .readiness_cache <<<"$output")" = '{"hits":3,"misses":0,"miss_reasons":{}}' ]
  [ "$(jq -r .fallback <<<"$output")" = false ]
  [ "$(jq -c .cycle_members <<<"$output")" = "[]" ]
}

@test "#2955 AC1 a hit hands back the cached verdict whole, risk included" {
  check_doc 11:READY:elevated 12:NEEDS_REFINEMENT:normal
  plan --targets 11,12 --check "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hits[0].verdict.risk' <<<"$output")" = elevated ]
  [ "$(jq -r '.hits[1].verdict.verdict' <<<"$output")" = NEEDS_REFINEMENT ]
  [ "$(jq -c '.hits[0].verdict.size.inventory' <<<"$output")" = '["a.zsh"]' ]
}

@test "#2955 AC8 a single edited child is the only gate dispatched" {
  check_doc 11:READY:normal 13:READY:normal -- 12:key_changed
  { rec 11; rec 12 11; rec 13 12; } > "$DEPS"
  plan --targets 11,12,13 --check "$CHECK" --deps "$DEPS"
  [ "$status" -eq 0 ]
  [ "$(jq -c .dispatch <<<"$output")" = "[12]" ]
  [ "$(jq -c '[.hits[].issue]' <<<"$output")" = "[11,13]" ]
  [ "$(jq -c .readiness_cache <<<"$output")" = '{"hits":2,"misses":1,"miss_reasons":{"key_changed":1}}' ]
}

@test "#2955 AC6 miss_reasons counts each of check's reasons" {
  check_doc 15:READY:normal -- 11:no_stamp 12:no_stamp 13:gate_changed 14:inventory_drift
  plan --targets 11,12,13,14,15 --check "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(jq -c .dispatch <<<"$output")" = "[11,12,13,14]" ]
  [ "$(jq -c .readiness_cache.miss_reasons <<<"$output")" = '{"no_stamp":2,"gate_changed":1,"inventory_drift":1}' ]
  [ "$(jq -r .readiness_cache.misses <<<"$output")" = 4 ]
}

@test "#2955 AC4 a cycle through cached children halts: its members are neither hits nor gated" {
  check_doc 11:READY:normal 12:READY:normal 13:READY:normal
  { CYCLES='[[11,12,11]]' rec 11 12; CYCLES='[[12,11,12]]' rec 12 11; rec 13; } > "$DEPS"
  plan --targets 11,12,13 --check "$CHECK" --deps "$DEPS"
  [ "$status" -eq 0 ]
  [ "$(jq -c .cycle_members <<<"$output")" = "[11,12]" ]
  [ "$(jq -c .dispatch <<<"$output")" = "[]" ]
  [ "$(jq -c '[.hits[].issue]' <<<"$output")" = "[13]" ]
  [ "$(jq -c .cycles <<<"$output")" = "[[11,12,11],[12,11,12]]" ]
}

@test "#2955 AC4 a target whose walk reaches a cycle elsewhere is a cycle member too" {
  check_doc 11:READY:normal 12:READY:normal
  { CYCLES='[[40,41,40]]' rec 11 40; rec 12; } > "$DEPS"
  plan --targets 11,12 --check "$CHECK" --deps "$DEPS"
  [ "$status" -eq 0 ]
  [ "$(jq -c .cycle_members <<<"$output")" = "[11]" ]
  [ "$(jq -c '[.hits[].issue]' <<<"$output")" = "[12]" ]
}

@test "#2955 AC4 the cycle test runs on a fallback too" {
  { CYCLES='[[11,12,11]]' rec 11 12; CYCLES='[[12,11,12]]' rec 12 11; rec 13; } > "$DEPS"
  plan --targets 11,12,13 --check-exit 3 --deps "$DEPS"
  [ "$status" -eq 0 ]
  [ "$(jq -c .cycle_members <<<"$output")" = "[11,12]" ]
  [ "$(jq -c .dispatch <<<"$output")" = "[13]" ]
}

@test "#2955 AC4 a target with no dependency record, or a truncated one, is gated fresh" {
  check_doc 11:READY:normal 12:READY:normal 13:READY:normal
  { rec 11; TRUNC=true rec 12; } > "$DEPS"
  plan --targets 11,12,13 --check "$CHECK" --deps "$DEPS"
  [ "$status" -eq 0 ]
  [ "$(jq -c .dispatch <<<"$output")" = "[12,13]" ]
  [ "$(jq -c .readiness_cache.miss_reasons <<<"$output")" = '{"acyclicity_unverified":2}' ]
}

@test "#2965 a cached verdict that failed the dependency check is gated fresh as dependencies_recheck" {
  printf '{"gate_version":"g","hits":[{"issue":11,"verdict":{"verdict":"NEEDS_REFINEMENT","risk":"normal","checks":{"dependencies_resolved":false}}},{"issue":12,"verdict":{"verdict":"NEEDS_REFINEMENT","risk":"normal","checks":{"dependencies_resolved":true}}},{"issue":13,"verdict":{"verdict":"READY","risk":"low","checks":"n/a"}}],"misses":[]}\n' > "$CHECK"
  { rec 11; rec 12; rec 13; } > "$DEPS"
  plan --targets 11,12,13 --check "$CHECK" --deps "$DEPS"
  [ "$status" -eq 0 ]
  [ "$(jq -c .dispatch <<<"$output")" = "[11]" ]
  [ "$(jq -c '[.hits[].issue]' <<<"$output")" = "[12,13]" ]
  [ "$(jq -c .readiness_cache <<<"$output")" = '{"hits":2,"misses":1,"miss_reasons":{"dependencies_recheck":1}}' ]
  plan --targets 11 --check "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(jq -c .dispatch <<<"$output")" = "[11]" ]
  grep -qF 'dependencies_recheck   check reported it a hit, but the cached verdict has' "$P"
  grep -qF "the planner's \`check_failed\`, \`not_checked\`, \`acyclicity_unverified\` and \`dependencies_recheck\`)" "$REPO_ROOT/ARCHITECTURE.md"
}

@test "#2955 AC5 a check that exits nonzero falls back to gating every target" {
  check_doc 11:READY:normal 12:READY:normal
  plan --targets 11,12 --check "$CHECK" --check-exit 3
  [ "$status" -eq 0 ]
  [ "$(jq -r .fallback <<<"$output")" = true ]
  [ "$(jq -r .fallback_reason <<<"$output")" = "check exited 3" ]
  [ "$(jq -c .dispatch <<<"$output")" = "[11,12]" ]
  [ "$(jq -c .hits <<<"$output")" = "[]" ]
  [ "$(jq -c .readiness_cache <<<"$output")" = '{"hits":0,"misses":2,"miss_reasons":{"check_failed":2}}' ]
}

@test "#2955 AC5 an empty or foreign check document falls back the same way" {
  : > "$CHECK"
  plan --targets 11 --check "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .fallback <<<"$output")" = true ]
  [ "$(jq -c .dispatch <<<"$output")" = "[11]" ]
  printf '{"hits":"nope"}\n' > "$CHECK"
  plan --targets 11 --check "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .fallback <<<"$output")" = true ]
  plan --targets 11
  [ "$status" -eq 0 ]
  [ "$(jq -r .fallback_reason <<<"$output")" = "no check document" ]
}

@test "#2955 a target check never reported is gated as not_checked; a stray hit is ignored" {
  check_doc 11:READY:normal 99:READY:low
  plan --targets 11,12 --check "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(jq -c .dispatch <<<"$output")" = "[12]" ]
  [ "$(jq -c '[.hits[].issue]' <<<"$output")" = "[11]" ]
  [ "$(jq -c .readiness_cache.miss_reasons <<<"$output")" = '{"not_checked":1}' ]
}

@test "#2955 every target lands in exactly one of dispatch, hits and cycle_members" {
  check_doc 11:READY:normal 13:READY:normal -- 12:no_stamp 14:malformed
  { CYCLES='[[13,14,13]]' rec 13 14; rec 11; rec 12; rec 14; } > "$DEPS"
  plan --targets 11,12,13,14 --check "$CHECK" --deps "$DEPS"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.dispatch[], .hits[].issue, .cycle_members[]] | sort' <<<"$output")" = "[11,12,13,14]" ]
  [ "$(jq -c .cycle_members <<<"$output")" = "[13,14]" ]
}

@test "#2955 usage errors exit 2" {
  plan
  [ "$status" -eq 2 ]
  contains "$stderr" "--targets is required"
  plan --targets 11,x
  [ "$status" -eq 2 ]
  plan --targets 11,11
  [ "$status" -eq 2 ]
  contains "$stderr" "twice"
  plan --targets 11 --check-exit -1
  [ "$status" -eq 2 ]
  plan --targets 11 --deps "$BATS_TEST_TMPDIR/absent.jsonl"
  [ "$status" -eq 2 ]
  printf 'not json\n' > "$DEPS"
  plan --targets 11 --deps "$DEPS"
  [ "$status" -eq 2 ]
  contains "$stderr" "not JSON Lines"
  plan --targets 11 --bogus 1
  [ "$status" -eq 2 ]
}

@test "#2955 0b and E1b point at the cache procedure, which calls the stamp check and the planner" {
  grep -qF 'see `reference/readiness-cache.md` § Step 0b — gate only a stamp miss' "$SKILL"
  grep -qF 'see `reference/readiness-cache.md` § E1b — gate only the stamp misses' "$TREE_REF"
  grep -qF 'Before branching, and only on a readiness-stamp miss, spawn the **`story-readiness`** agent' "$SKILL"
  grep -qF '**this skill** does any posting, stamping fresh verdicts first (#2955):' "$SKILL"
  grep -qF 'child whose readiness stamp misses** (#2955): spawn `story-readiness` (Task tool,' "$SKILL"
  grep -qF 'once per stamp-missing child' "$SKILL"
  grep -qF "and take each hit's cached verdict instead." "$SKILL"
  grep -qF 'Only the leaves whose readiness stamp misses are gated, and every fresh' "$TREE_REF"
  grep -qF 'verdict is stamped; a hit answers here exactly as a fresh verdict does (#2955):' "$TREE_REF"
  grep -qF '[--readiness-cache <scratch>/readiness-plan.json]' "$SKILL"
  grep -qF 'readiness-stamp.zsh" check --repo "$REPO" --epic <N>' "$CACHE_REF"
  grep -qF 'readiness-stamp.zsh" check --repo "$REPO" --issue <N>' "$CACHE_REF"
  grep -qF 'readiness-cache-plan.zsh" --targets <N>' "$CACHE_REF"
  grep -qF -- '--deps <scratch>/deps.jsonl' "$CACHE_REF"
  grep -qF 'readiness-stamp.zsh" write --repo "$REPO" --issue <N> --verdict-file' "$CACHE_REF"
  grep -qF -- '--expect-key <the key read before the gate>' "$CACHE_REF"
  grep -qF '**Stamp every fresh verdict, `READY` and `NEEDS_REFINEMENT` alike**' "$CACHE_REF"
}

@test "#2955 the cache procedure's hit, miss and fallback rules are pinned" {
  local n
  for n in \
    '- **The issue is in `hits`** → take its `verdict` as if the gate had just' \
    'returned it, `risk` included, and branch on it as step 0b says. Spawn no gate' \
    '- **The issue is in `dispatch`** → spawn the gate as step 0b says, after reading' \
    '- **`fallback` is `true`** → the stamp check failed, so the story is gated' \
    'fresh. Say so once in the run output, quoting `fallback_reason`. It never' \
    'the flag out only when the planner failed and the story was gated fresh.' \
    'the issue'"'"'s key, and stamp its verdict (*Stamping a fresh verdict*, below).' \
    'Before spawning anything, start `<scratch>/deps.jsonl` from an empty file, append' \
    'one `"<skill-base-dir>/scripts/read-dependencies.zsh" --repo "$REPO" --issue <child>`' \
    'record per child to it, then read the stamps and plan. Only this run'"'"'s records may be in the file: an' \
    'earlier run'"'"'s line would stand in for a read that failed or a cycle since broken.' \
    'A child whose read fails gets no line, and the planner then gates it fresh. From' \
    ': > <scratch>/deps.jsonl' \
    '    >> <scratch>/deps.jsonl || true' \
    'and write no stamp. A cached verdict that failed the dependency check is never' \
    'a hit: the planner gates it fresh as `dependencies_recheck`, since the edge that' \
    'resolves it may sit on another issue and moves no stamp key.' \
    'just returned it. A cached verdict that failed the dependency check, a cycle' \
    'included, is never a hit: the planner dispatches it as `dependencies_recheck`,' \
    'so the current graph decides it.' \
    'and stamp each fresh verdict (*Stamping a fresh verdict*, below).' \
    'Before spawning the gate on a miss, read the issue'"'"'s key:' \
    '`"<skill-base-dir>/scripts/readiness-stamp.zsh" key --repo "$REPO" --issue <N>`' \
    'right after the gate returns and before you post any label or comment. Write the' \
    'verdict JSON exactly as returned to a scratch file and record it:' \
    '- **`dispatch`** → spawn `story-readiness` for exactly these children, in' \
    'parallel, as E1b says. An empty list spawns none. Read each child'"'"'s key first' \
    '- **`hits`** → take each cached `verdict`, `risk` included, as if the gate had' \
    '- **`cycle_members`** → each counts `NEEDS_REFINEMENT`, with the cycle from' \
    'unready child. A cycle is never stamped and never read from a cached verdict:' \
    'the dependency records are tested on every run, before ordering.' \
    '- **`fallback` is `true`** → every child in `dispatch` is gated fresh; the' \
    '`cycle_members` still count as above. Say so once in the run output, quoting' \
    'fix it and re-run once. Any other nonzero exit, or a second 2, gates every' \
    '`fallback_reason`; it never halts the run. A planner exit 2 is your own call:' \
    'child fresh: no plan exists.' \
    '- **The planner exits 2** → your own malformed call: fix it and re-run once. Any' \
    'other nonzero exit, or a second 2, gates the story fresh; say so.' \
    'Keep the plan'"'"'s `readiness_cache` for the epic record' \
    'Keep `<scratch>/readiness-plan.json`: §2'"'"'s `story-preflight` record carries its' \
    'E1b'"'"'s halt and proceed rules then apply to the combined verdict set, unchanged.' \
    'An `action` of `skipped_stale` means the issue changed while the gate ran:' \
    'the same. When `key` failed, run `write` without `--expect-key`. Neither a failed' \
    '`key` nor a `write` that exits nonzero is fatal: report it and go on, since the' \
    'next run simply misses. A cached hit is never re-stamped.'; do
    grep -qF -- "$n" "$CACHE_REF" || { echo "missing from readiness-cache.md: $n" >&2; return 1; }
  done
  grep -qF 'Leave it out when E1b never ran or its planner failed.' \
    "$REPO_ROOT/development/skills/resolve-issue/reference/epic-telemetry.md"
}

@test "#2955 --help prints the usage; a missing jq is an internal failure (exit 1)" {
  plan --help
  [ "$status" -eq 0 ]
  starts_with "$output" "usage: readiness-cache-plan.zsh --targets"
  local zsh_bin; zsh_bin="$(command -v zsh)"
  mkdir -p "$BATS_TEST_TMPDIR/nojq"
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/nojq" "$zsh_bin" "$P" --targets 11
  [ "$status" -eq 1 ]
  contains "$stderr" "jq not found on PATH"
}

@test "#2955 AC7 the workflow page states the verdict reuse and how to force a fresh gate" {
  local page="$REPO_ROOT/docs/explanation/workflow-resolve-issue.md"
  grep -qF 'it is reused while the gate'"'"'s inputs are unchanged' "$page"
  grep -qF 'Deleting the stamp comment forces a fresh gate.' "$page"
  grep -qF 'checked afresh on every run, never taken from a stamp' "$page"
}
