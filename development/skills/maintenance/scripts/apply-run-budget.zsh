#!/usr/bin/env zsh
# Split a maintenance run's concern-ordered groups into what runs and what the
# run's budget defers (#3214).
#
# Usage:
#   apply-run-budget.zsh --caps <json> [--queue <n>] [--queue-cap <n>]
#                        [--scheduled] [--cutoff-epoch <s>] [--now-epoch <s>]
#                        < ordered.json
#
# stdin:  order-groups.zsh's output — one JSON array of groups, each carrying
#         `concern` (security | dependencies | bugs | codequality | topic) — with
#         each group also carrying `opens_pr` (boolean): true for a stage that
#         opens a PR of its own, false for one that only triages or merges
#         existing vendor PRs.
# stdout: { "run": [ …groups… ],
#           "deferred": [ { …group, "deferred_by": "cap" | "queue" | "cutoff" } ] }
#         Both arrays keep stdin's order. Every field of a group is kept.
#
# The rules, applied to each group in stdin's order, first match wins:
#   cutoff  under --scheduled with --cutoff-epoch, when now >= the cutoff:
#           nothing new starts, so every group is deferred.
#   queue   under --scheduled, an `opens_pr: true` group while the open queue
#           (--queue) is at or above --queue-cap. A group with `opens_pr: false`
#           is never deferred by `queue`.
#   cap     when this group's concern already has its cap's worth of groups in
#           `run`. Without --scheduled only the `bugs` cap applies.
#   run     otherwise; the group counts one against its concern's cap.
#
# Caps default to security 5, dependencies 5, bugs 5, codequality 10, topic 10.
# --caps is a JSON object whose keys are any of those five concerns and whose
# values are non-negative integers; a key it names replaces that default, `{}`
# keeps them all. --queue-cap defaults to 5. --queue is required under
# --scheduled and ignored without it, as are --queue-cap and --cutoff-epoch.
# --now-epoch defaults to the current time. `--batch=N` is not applied here: the
# caller applies it to `run` afterwards.
#
# Exit codes:
#   0  the split printed
#   1  internal failure (jq missing or failing, no clock)
#   2  usage: an unknown or repeated flag, a flag without its value, a value
#      that is not a non-negative integer, --caps that is not such an object,
#      --scheduled without --queue, or stdin that is not one JSON array of
#      objects each with a known `concern` and a boolean `opens_pr`

set -uo pipefail

usage() {
  print -u2 "usage: apply-run-budget.zsh --caps <json> [--queue <n>] [--queue-cap <n>] [--scheduled] [--cutoff-epoch <s>] [--now-epoch <s>] < ordered.json"
  exit 2
}

caps="" queue="" queue_cap="" cutoff="" now="" scheduled=false
typeset -A seen
while (( $# > 0 )); do
  case "$1" in
    --caps|--queue|--queue-cap|--cutoff-epoch|--now-epoch)
      (( $# >= 2 )) || { print -u2 "apply-run-budget.zsh: $1 needs a value"; usage; }
      [[ -z "${seen[$1]:-}" ]] || { print -u2 "apply-run-budget.zsh: $1 given twice"; usage; }
      seen[$1]=1
      case "$1" in
        --caps) caps="$2" ;;
        --queue) queue="$2" ;;
        --queue-cap) queue_cap="$2" ;;
        --cutoff-epoch) cutoff="$2" ;;
        --now-epoch) now="$2" ;;
      esac
      shift 2 ;;
    --scheduled)
      [[ -z "${seen[$1]:-}" ]] || { print -u2 "apply-run-budget.zsh: $1 given twice"; usage; }
      seen[$1]=1
      scheduled=true
      shift ;;
    *) print -u2 "apply-run-budget.zsh: unknown argument '$1'"; usage ;;
  esac
done

[[ -n "${seen[--caps]:-}" ]] || { print -u2 "apply-run-budget.zsh: --caps is required"; usage; }
if [[ "$scheduled" == true && -z "${seen[--queue]:-}" ]]; then
  print -u2 "apply-run-budget.zsh: --scheduled needs --queue"
  usage
fi

is_count() { [[ "$1" =~ '^[0-9]+$' ]]; }
for pair in "--queue:$queue" "--queue-cap:$queue_cap" "--cutoff-epoch:$cutoff" "--now-epoch:$now"; do
  flag="${pair%%:*}" value="${pair#*:}"
  [[ -z "${seen[$flag]:-}" ]] && continue
  is_count "$value" || { print -u2 "apply-run-budget.zsh: $flag must be a non-negative integer, got '$value'"; usage; }
done

if ! command -v jq >/dev/null 2>&1; then
  print -u2 "apply-run-budget.zsh: jq not found"
  exit 1
fi

if ! jq -e -s 'length == 1 and (.[0] | type == "object"
      and all(keys[]; IN("security", "dependencies", "bugs", "codequality", "topic"))
      and all(.[]; type == "number" and . >= 0 and . == floor))' >/dev/null 2>&1 <<<"$caps"; then
  print -u2 "apply-run-budget.zsh: --caps must be one JSON object mapping security, dependencies, bugs, codequality or topic to a non-negative integer"
  usage
fi

if [[ -z "${seen[--now-epoch]:-}" ]]; then
  now="$(date +%s)" && is_count "$now" || { print -u2 "apply-run-budget.zsh: could not read the clock"; exit 1; }
fi
[[ -n "${seen[--queue-cap]:-}" ]] || queue_cap=5
[[ -n "${seen[--queue]:-}" ]] || queue=0

input="$(cat)"
if ! jq -e -s 'length == 1 and (.[0] | type == "array"
      and all(.[]; type == "object"
        and (.concern | IN("security", "dependencies", "bugs", "codequality", "topic"))
        and (.opens_pr | type == "boolean")))' >/dev/null 2>&1 <<<"$input"; then
  print -u2 "apply-run-budget.zsh: stdin must be one JSON array of objects, each with a known \"concern\" and a boolean \"opens_pr\""
  exit 2
fi

cutoff_json=null
[[ -n "${seen[--cutoff-epoch]:-}" ]] && cutoff_json="$cutoff"

jq -c --argjson caps "$caps" --argjson queue "$queue" --argjson qcap "$queue_cap" \
  --argjson sched "$scheduled" --argjson cutoff "$cutoff_json" --argjson now "$now" '
  ({security: 5, dependencies: 5, bugs: 5, codequality: 10, topic: 10} + $caps) as $cap
  | reduce .[] as $g ({run: [], deferred: [], n: {}};
      if $sched and $cutoff != null and $now >= $cutoff then
        .deferred += [$g + {deferred_by: "cutoff"}]
      elif $sched and $g.opens_pr and $queue >= $qcap then
        .deferred += [$g + {deferred_by: "queue"}]
      elif ($sched or $g.concern == "bugs") and ((.n[$g.concern] // 0) >= $cap[$g.concern]) then
        .deferred += [$g + {deferred_by: "cap"}]
      else
        .run += [$g] | .n[$g.concern] = ((.n[$g.concern] // 0) + 1)
      end)
  | {run, deferred}
' <<<"$input" || {
  print -u2 "apply-run-budget.zsh: jq failed applying the budget"
  exit 1
}
