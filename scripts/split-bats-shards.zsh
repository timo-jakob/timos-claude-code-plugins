#!/usr/bin/env zsh
# split-bats-shards.zsh — split the bats suite into the legs of CI's
# script-tests matrix, and prove the legs cover it (#3084).
#
# The required check used to run all of tests/*.bats in one job. Each leg of the
# matrix now runs a disjoint share, and the legs together run every file
# exactly once. Every leg computes the same plan from the same checkout, so the
# legs agree on the split without talking to each other.
#
# Usage:
#   split-bats-shards.zsh plan  --legs N [--tests-dir DIR] [--timings FILE]
#   split-bats-shards.zsh check --plan FILE [--tests-dir DIR]
#   split-bats-shards.zsh files --plan FILE --leg K
#
#   plan   prints the split as one JSON object:
#            {"schema":"bats-shards/v1","legs":N,"basis":"timings"|"count",
#             "shards":[{"leg":1,"est_s":123.4,"files":["tests/a.bats",…]},…]}
#          The files are DIR/*.bats (default DIR: tests). With timing data the
#          split is balanced by recorded wall time: files are taken slowest
#          first, each to the leg with the least time so far, the lower leg on
#          a tie. A file the timings do not name is given their mean, so a new
#          file still lands somewhere sensible. With no timing data — no
#          --timings, a file that is missing or not valid JSON, or one naming
#          none of today's files — every file weighs the same, which is an even
#          split by file count (legs differ by at most one file), and the basis
#          is "count". est_s is the leg's summed weight.
#   check  exits 0 when the plan's legs are disjoint and their union is exactly
#          DIR/*.bats. Otherwise it exits 1 and prints, one per line on
#          stderr, every file that is missing, listed twice, or not in DIR.
#   files  prints leg K's files, one per line.
#
# The timings file is a run-gate.zsh summary, or any JSON object with the same
# `files` array: [{"file":"tests/a.bats","wall_s":3.1},…]. A file is matched by
# its basename, so the directory it was timed from does not matter. To refresh
# tests/bats-timings.json from a green CI run, merge every leg's summary line:
#   gh run view <run-id> --log | grep -o '{"mode":.*' \
#     | jq -s '{files: [.[].files[]] | sort_by(.file)}'
#
# Exit codes: 0 success; 1 check found a coverage problem; 2 usage error (bad
# subcommand or flag, --legs not a positive integer or above the file count,
# --leg outside 1..legs, an empty or missing tests dir); 3 a plan that cannot
# be read, or jq missing.

emulate -L zsh
setopt nounset pipefail

die_usage() { print -u2 -- "split-bats-shards: $1"; exit 2 }
die_runtime() { print -u2 -- "split-bats-shards: $1"; exit 3 }

command -v jq >/dev/null 2>&1 || die_runtime "jq not found"

(( $# )) || die_usage "missing subcommand (plan, check or files)"
local cmd="$1"; shift
case "$cmd" in
  plan|check|files) ;;
  -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
  *) die_usage "unknown subcommand: $cmd" ;;
esac

local tests_dir="tests" timings="" legs="" plan="" leg=""
while (( $# )); do
  case "$1" in
    --tests-dir|--timings|--legs|--plan|--leg)
      { (( $# >= 2 )) && [[ -n "$2" && "$2" != -* ]]; } || die_usage "$1 needs a value"
      case "$1" in
        --tests-dir) tests_dir="$2" ;;
        --timings) timings="$2" ;;
        --legs) legs="$2" ;;
        --plan) plan="$2" ;;
        --leg) leg="$2" ;;
      esac
      shift 2 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

# The set the legs must cover: DIR/*.bats, sorted, as DIR/<name>.bats.
suite_files() {
  [[ -d "$tests_dir" ]] || die_usage "tests dir not found: $tests_dir"
  local -a fs=( "${tests_dir%/}"/*.bats(N.on) )
  (( ${#fs} )) || die_usage "no .bats files in $tests_dir"
  print -rl -- "${fs[@]}"
}

read_plan() {
  [[ -n "$plan" ]] || die_usage "$cmd needs --plan"
  [[ -r "$plan" ]] || die_runtime "plan not readable: $plan"
  jq -e 'type == "object" and .schema == "bats-shards/v1"
         and (.legs | type == "number") and (.shards | type == "array")
         and (.shards | length) == .legs
         and all(.shards[]; (.files | type == "array") and all(.files[]; type == "string"))' \
    "$plan" >/dev/null 2>&1 || die_runtime "not a bats-shards/v1 plan: $plan"
}

case "$cmd" in
plan)
  [[ "$legs" == <1-> ]] || die_usage "--legs must be a positive integer"
  local listing; listing="$(suite_files)" || exit $?
  local -a files=( "${(@f)listing}" )
  legs=$(( legs ))
  (( legs <= ${#files} )) || die_usage "--legs $legs is more than the ${#files} bats files"

  # The timing data, as {basename: seconds}; {} when there is none to use.
  local tmap='{}'
  if [[ -n "$timings" ]]; then
    if [[ -r "$timings" ]] && tmap="$(jq -c '
          [ (.files // [])[] | select(type == "object")
            | select((.file | type) == "string" and (.wall_s | type) == "number" and .wall_s >= 0)
            | {key: (.file | split("/") | last), value: .wall_s} ] | from_entries' "$timings" 2>/dev/null)" \
       && [[ -n "$tmap" ]]; then
      :
    else
      print -u2 -- "split-bats-shards: timings unreadable ($timings) — splitting by file count"
      tmap='{}'
    fi
  fi

  print -rl -- "${files[@]}" | jq -R . | jq -s -c --argjson legs "$legs" --argjson t "$tmap" '
    . as $files
    | ([ $files[] | split("/") | last | $t[.] | select(. != null) ]) as $known
    | (if ($known | length) > 0 then "timings" else "count" end) as $basis
    | (if $basis == "timings" then ($known | add / length) else 1 end) as $mean
    | [ $files[] | {f: ., w: (if $basis == "timings" then ($t[split("/") | last] // $mean) else 1 end)} ]
    | sort_by([-.w, .f])
    | reduce .[] as $x ([range($legs) | {files: [], est: 0}];
        (to_entries | min_by([.value.est, .key]) | .key) as $i
        | .[$i].files += [$x.f] | .[$i].est += $x.w)
    | {schema: "bats-shards/v1", legs: $legs, basis: $basis,
       shards: [ to_entries[] | {leg: (.key + 1), est_s: ((.value.est * 1000 | round) / 1000),
                                 files: (.value.files | sort)} ]}'
  ;;
check)
  read_plan
  local listing; listing="$(suite_files)" || exit $?
  local problems
  problems="$(print -rl -- "${(@f)listing}" | jq -R . | jq -s -r --slurpfile p "$plan" '
    . as $want
    | [ $p[0].shards[].files[] ] as $got
    | ($got | group_by(.) | map(select(length > 1) | .[0])) as $dups
    | ($want - $got) as $missing
    | ($got - $want | unique) as $extra
    | ($dups[] | "listed twice: \(.)"), ($missing[] | "missing from every leg: \(.)"),
      ($extra[] | "not in the suite: \(.)")')" \
    || die_runtime "could not compare the plan with the suite"
  if [[ -n "$problems" ]]; then
    print -u2 -r -- "$problems"
    print -u2 -- "split-bats-shards: the legs do not cover the suite exactly once"
    exit 1
  fi
  ;;
files)
  read_plan
  local n; n="$(jq -r '.legs' "$plan")"
  [[ "$leg" == <1-> ]] && (( leg <= n )) || die_usage "--leg must be between 1 and $n"
  jq -r --argjson k "$leg" '.shards[$k - 1].files[]' "$plan"
  ;;
esac
