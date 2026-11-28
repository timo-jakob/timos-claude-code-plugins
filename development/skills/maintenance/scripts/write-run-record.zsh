#!/usr/bin/env zsh
# Write one repo's maintenance-run/v1 record for a scheduled wave (#3215): the
# machine-readable account of one run, which the Maintenance log comment and
# the nightly report are rendered from. ARCHITECTURE.md, *Maintenance run
# record (`maintenance-run/v1`)*, is the contract.
#
# Usage:
#   write-run-record.zsh --repo <owner/name> --outcome <outcome> [--reason <text>]
#                        [--from <summary.json>]
#
#   --outcome  completed | cut-off | could-not-start | outside-window | skipped-running
#   --reason   one line saying why; stored as given, `null` when left out
#   --from     the run's summary: one JSON object that may carry `started_at`,
#              `ended_at` (UTC, YYYY-MM-DDTHH:MM:SSZ), `concerns` and `bugs` in
#              the record's own shape. Every list it leaves out is written
#              empty, and an absent timestamp is the time of writing. Without
#              --from every list is empty — the wave's record for a repo whose
#              session never started.
#
# The record goes to $MAINTENANCE_RUN_DIR/<owner>__<name>.json, written to a
# temporary file in that directory and renamed over the target, so a reader
# never sees a partial record and a writer killed midway leaves any earlier
# record as it was. `log_comment_url` is always written `null`;
# post-maintenance-log.zsh fills it in.
#
# stdout: the record's path.
#
# Exit codes:
#   0  the record written
#   1  internal failure: jq missing, the --from file unreadable or not a valid
#      summary, or the directory not writable; nothing is written
#   2  usage: an unknown or repeated argument, a missing value, an outcome not
#      in the list, a repo not shaped owner/name, or MAINTENANCE_RUN_DIR unset

set -uo pipefail

usage() {
  print -u2 "usage: write-run-record.zsh --repo <owner/name> --outcome <outcome> [--reason <text>]" \
    "[--from <summary.json>]"
  exit 2
}
bad() { print -u2 "write-run-record.zsh: $1"; usage; }
die() { print -u2 "write-run-record.zsh: $1"; exit 1; }

repo="" outcome="" from="" reason="" have_reason=0
while (( $# > 0 )); do
  case "$1" in
    --repo|--outcome|--reason|--from)
      (( $# >= 2 )) || bad "$1 needs a value"
      case "$1" in
        --repo) [[ -z "$repo" ]] || bad "--repo given twice"; repo="$2" ;;
        --outcome) [[ -z "$outcome" ]] || bad "--outcome given twice"; outcome="$2" ;;
        --reason) (( ! have_reason )) || bad "--reason given twice"; reason="$2"; have_reason=1 ;;
        --from) [[ -z "$from" ]] || bad "--from given twice"; from="$2" ;;
      esac
      shift 2 ;;
    *) bad "unknown argument '$1'" ;;
  esac
done

[[ "$repo" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]] || bad "--repo must be owner/name"
case "$outcome" in
  completed|cut-off|could-not-start|outside-window|skipped-running) ;;
  *) bad "--outcome must be one of completed, cut-off, could-not-start, outside-window, skipped-running" ;;
esac
[[ -n "${MAINTENANCE_RUN_DIR:-}" ]] || bad "MAINTENANCE_RUN_DIR is not set"

command -v jq >/dev/null 2>&1 || die "jq not found"

summary='{}'
if [[ -n "$from" ]]; then
  summary="$(cat -- "$from" 2>/dev/null)" || die "cannot read $from"
fi

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# A summary is one object; every list it carries is an array of objects, and a
# timestamp it carries is a UTC second. Anything else is refused, never guessed.
record="$(jq -s -e --arg repo "$repo" --arg outcome "$outcome" --arg reason "$reason" \
    --argjson has_reason "$have_reason" --arg now "$now" '
  def ts: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
  def item: {number: (.number // null), title: (.title // ""), url: (.url // null), note: (.note // null)};
  def lists($names; $src):
    reduce $names[] as $n ({}; . + {($n): [($src[$n] // [])[] | item]});
  def list_ok($src; $names):
    ($src | type == "object") and ($src | keys - $names | length == 0)
    and all($names[]; ($src[.] // []) | type == "array" and all(type == "object"));
  ["merged", "opened", "waiting", "parked", "deferred"] as $cl
  | ["security", "dependencies", "bugs", "codequality", "topic"] as $cs
  | ["analysed", "awaiting_confirmation", "fixed", "not_a_bug", "not_eligible", "not_reproducing"]
    as $bl
  | if length != 1 or (.[0] | type) != "object" then error("the summary is not one JSON object") else .[0] end
  | if has("started_at") and (.started_at | ts | not) then error("started_at is not YYYY-MM-DDTHH:MM:SSZ")
    elif has("ended_at") and (.ended_at | ts | not) then error("ended_at is not YYYY-MM-DDTHH:MM:SSZ")
    elif ((.concerns // {}) | type != "object" or (keys - $cs | length > 0) or any(.[]; type != "object"))
      then error("concerns is not an object of the five concerns")
    elif any(((.concerns // {}) | to_entries[] | .value); list_ok(.; $cl) | not)
      then error("a concern is not an object of merged, opened, waiting, parked, deferred lists")
    elif ((.bugs // {}) | list_ok(.; $bl) | not) then error("bugs is not an object of the six bug lists")
    else . end
  | {schema: "maintenance-run/v1", repo: $repo,
     started_at: (.started_at // $now), ended_at: (.ended_at // $now),
     outcome: $outcome, reason: (if $has_reason == 1 then $reason else null end),
     concerns: ((.concerns // {}) as $c | reduce $cs[] as $k ({}; . + {($k): lists($cl; $c[$k] // {})})),
     bugs: lists($bl; .bugs // {}),
     log_comment_url: null}
' <<<"$summary" 2>&1)" || die "not a valid summary: $record"

target="$MAINTENANCE_RUN_DIR/${repo%%/*}__${repo#*/}.json"
mkdir -p -- "$MAINTENANCE_RUN_DIR" 2>/dev/null || die "cannot create $MAINTENANCE_RUN_DIR"
tmp="$(mktemp "$MAINTENANCE_RUN_DIR/.${target:t}.XXXXXX" 2>/dev/null)" || die "cannot write in $MAINTENANCE_RUN_DIR"
trap 'rm -f -- "$tmp"' EXIT
print -r -- "$record" > "$tmp" && mv -f -- "$tmp" "$target" || die "cannot write $target"
trap - EXIT
print -r -- "$target"
