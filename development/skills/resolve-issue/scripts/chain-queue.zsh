#!/usr/bin/env zsh
# chain-queue.zsh — the queue of pending issues in a human-started resolve-issue
# chain (#2942, epic #2907).
#
# Why: a human-started run resolves the named issue's open blockers, the named
# issue, and every follow-up filed while building, through every generation. A
# later re-run on the named issue must resume where the run stopped, so the
# queue lives in ONE file outside every checkout, in the named issue's durable
# directory — the base `clean-stop.zsh dir` prints:
#
#   $HOME/.claude/resolve-issue/<repo-slug>/<named N>/chain-queue.json
#
# `clean-stop.zsh clear` keeps that file and `checkpoint.zsh supersede` leaves
# it in place, so an entry's own run never deletes or moves the queue;
# `chain-queue.zsh clear` deletes it.
#
# Usage:
#   chain-queue.zsh add    --repo-dir DIR --issue N --entry I
#                          --kind blocker|named|follow-up
#                          [--depth D] [--before M] [--after M] [--finding JSON]
#                          [--pr P] [--child-pr P]...
#       Queue issue I and print the queue. Order: blockers deepest-first (by
#       --depth, default 1), then the named issue, then follow-ups first-filed
#       first. A blocker with --before M goes directly before entry M (a
#       follow-up's own blocker). A follow-up needs --after M, the entry that
#       filed it, and --finding, its follow-up-origin/v1 finding identity
#       {file, line, dimension, title}; it goes after M and after every entry
#       already queued from M. An issue already queued is not added twice;
#       with --pr its recorded PR is set, and --kind may then be left out. A follow-up whose finding identity
#       equals a follow-up already done in this queue is refused as a cycle
#       (exit 3) and nothing is written. --child-pr P (repeatable, #3081)
#       records P, an E3 child's PR that has merged, on entry I, an epic-kind
#       entry already queued: P is appended to its child_prs, in recorded
#       order, and a PR already there is not added twice. On an entry not yet
#       queued it exits 5 and nothing is written.
#   chain-queue.zsh next   --repo-dir DIR --issue N
#       Print the first entry not yet done. Exit 4 when there is none: every
#       queued issue is done, which is the run's done condition.
#   chain-queue.zsh done   --repo-dir DIR --issue N --entry I [--pr P]
#       Mark entry I done (with its merged PR, when given) and print the queue.
#   chain-queue.zsh report --repo-dir DIR --issue N --stopped I --reason TEXT
#                          [--pause]
#       Print the stop comment's body: the line `chain stopped: #I — TEXT`
#       (`chain stopped: #I (paused, not failed) — TEXT` with --pause), every
#       PR merged in the run (or none) and every issue still queued (or none).
#       The merged line takes the entries in queue order: each entry's own PR
#       when the entry is done, then its child_prs, done or not, each PR once.
#       A PR recorded with add --pr on an entry not yet done is not listed. It
#       reads only the queue file and makes no GitHub call.
#   chain-queue.zsh close-out --repo-dir DIR --issue N --entry I --pr P
#       Entry I's PR P has merged (#3078): mark I done with P, then print
#       {"cleared": B, "next": E}. When no entry is left queued the queue file
#       is deleted, as clear deletes it, B is true and E is null; otherwise B
#       is false and E is the entry next would print. It asks nothing, so a
#       paused last entry whose PR merged since closes the run out by itself.
#   chain-queue.zsh clear  --repo-dir DIR --issue N
#       Delete the queue file. Absent is not an error.
#
# A queue file that does not exist is an empty queue for next and report; add
# creates it. The file (chain-queue/v1):
#   {schema, named, entries: [{issue, kind, state, pr, depth, filed_by, before,
#    finding, child_prs?}]}
#   state is "queued" or "done"; pr is a number or null; filed_by is the entry
#   a follow-up came from and before the entry a --before blocker serves.
#   child_prs, optional, is the merged PRs of an epic-kind entry's E3 children
#   (the leaves, in an epic tree), in recorded order; it is written only by
#   add --child-pr, and a missing child_prs reads as [], so a queue file from
#   before #3081 reads and reports as it did. The schema stays chain-queue/v1.
#
# Exit codes: 0 ok · 1 internal (jq missing, the base not derivable, an
# unreadable queue file) · 2 usage · 3 follow-up cycle refused · 4 queue empty
# (next) · 5 unknown entry (done or close-out, add --before/--after naming
# no entry, or add --child-pr on an entry not yet queued)
emulate -L zsh
setopt err_return no_unset pipe_fail

local self_dir="${0:A:h}"
local usage="usage: chain-queue.zsh add|next|done|close-out|report|clear --repo-dir DIR --issue N [flags]"

_need_val() { [[ $2 -ge 2 && -n "$3" ]] || { print -u2 -- "chain-queue: $1 needs a value"; exit 2 } }
_num() { [[ "$2" == <-> && "$2" != 0* ]] || { print -u2 -- "chain-queue: $1 must be an issue or PR number (got: $2)"; exit 2 } }

(( $# > 0 )) || { print -u2 -- "$usage"; exit 2 }
local cmd="$1"; shift
case "$cmd" in
  add|next|done|close-out|report|clear) ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  *) print -u2 -- "chain-queue: unknown subcommand: $cmd"; print -u2 -- "$usage"; exit 2 ;;
esac

local repo_dir="" issue="" entry="" kind="" depth="1" before="" after="" finding="" pr=""
local -a child_prs=()
local stopped="" reason="" pause=0
_only() { [[ " $2 " == *" $cmd "* ]] || { print -u2 -- "chain-queue: $1 is not a flag of $cmd"; exit 2 } }
while (( $# > 0 )); do
  case "$1" in
  --repo-dir) _need_val "$1" $# "${2:-}"; repo_dir="$2"; shift 2 ;;
  --issue) _need_val "$1" $# "${2:-}"; issue="$2"; shift 2 ;;
  --entry) _only "$1" "add done close-out"; _need_val "$1" $# "${2:-}"; entry="$2"; shift 2 ;;
  --kind) _only "$1" "add"; _need_val "$1" $# "${2:-}"; kind="$2"; shift 2 ;;
  --depth) _only "$1" "add"; _need_val "$1" $# "${2:-}"; depth="$2"; shift 2 ;;
  --before) _only "$1" "add"; _need_val "$1" $# "${2:-}"; before="$2"; shift 2 ;;
  --after) _only "$1" "add"; _need_val "$1" $# "${2:-}"; after="$2"; shift 2 ;;
  --finding) _only "$1" "add"; _need_val "$1" $# "${2:-}"; finding="$2"; shift 2 ;;
  --pr) _only "$1" "add done close-out"; _need_val "$1" $# "${2:-}"; pr="$2"; shift 2 ;;
  --child-pr) _only "$1" "add"; _need_val "$1" $# "${2:-}"; child_prs+=("$2"); shift 2 ;;
  --stopped) _only "$1" "report"; _need_val "$1" $# "${2:-}"; stopped="$2"; shift 2 ;;
  --reason) _only "$1" "report"; _need_val "$1" $# "${2:-}"; reason="$2"; shift 2 ;;
  --pause) _only "$1" "report"; pause=1; shift ;;
  -*) print -u2 -- "chain-queue: unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "chain-queue: unexpected argument: $1"; exit 2 ;;
  esac
done

[[ -n "$repo_dir" && -n "$issue" ]] || { print -u2 -- "$usage"; exit 2 }
_num --issue "$issue"
[[ -d "$repo_dir" ]] || { print -u2 -- "chain-queue: --repo-dir is not a directory: $repo_dir"; exit 2 }
case "$cmd" in
add)
  [[ -n "$entry" && ( -n "$kind" || -n "$pr" || ${#child_prs} -gt 0 ) ]] || {
    print -u2 -- "chain-queue: add needs --entry and --kind"; exit 2 }
  _num --entry "$entry"
  [[ -z "$kind" ]] || [[ "$kind" == blocker || "$kind" == named || "$kind" == follow-up ]] || {
    print -u2 -- "chain-queue: --kind must be blocker, named or follow-up (got: $kind)"; exit 2 }
  [[ "$depth" == <-> && "$depth" != 0* ]] || { print -u2 -- "chain-queue: --depth must be a positive integer (got: $depth)"; exit 2 }
  [[ -z "$before" ]] || _num --before "$before"
  [[ -z "$after" ]] || _num --after "$after"
  [[ -z "$pr" ]] || _num --pr "$pr"
  local cp=""
  for cp in "${child_prs[@]}"; do _num --child-pr "$cp"; done
  [[ -z "$before" || "$kind" == blocker ]] || { print -u2 -- "chain-queue: --before is for a blocker only"; exit 2 }
  [[ "$kind" == named && "$entry" != "$issue" ]] && { print -u2 -- "chain-queue: the named entry must be --issue itself"; exit 2 }
  if [[ "$kind" == follow-up ]]; then
    [[ -n "$after" && -n "$finding" ]] || { print -u2 -- "chain-queue: a follow-up needs --after and --finding"; exit 2 }
  else
    [[ -z "$after" && -z "$finding" ]] || { print -u2 -- "chain-queue: --after and --finding are for a follow-up only"; exit 2 }
  fi
  ;;
done) [[ -n "$entry" ]] || { print -u2 -- "chain-queue: done needs --entry"; exit 2 }
  _num --entry "$entry"; [[ -z "$pr" ]] || _num --pr "$pr" ;;
close-out) [[ -n "$entry" && -n "$pr" ]] || { print -u2 -- "chain-queue: close-out needs --entry and --pr"; exit 2 }
  _num --entry "$entry"; _num --pr "$pr" ;;
report) [[ -n "$stopped" && -n "$reason" ]] || { print -u2 -- "chain-queue: report needs --stopped and --reason"; exit 2 }
  _num --stopped "$stopped" ;;
esac

command -v jq >/dev/null 2>&1 || { print -u2 -- "chain-queue: jq not found on PATH"; exit 1 }
if [[ -n "$finding" ]]; then
  print -r -- "$finding" | jq -e 'type == "object" and (.file | type == "string" and length > 0)
      and (.line == null or (.line | type == "number")) and (.dimension | type == "string" and length > 0)
      and (.title | type == "string" and length > 0)' >/dev/null 2>&1 || {
    print -u2 -- "chain-queue: --finding must be a JSON object {file, line, dimension, title}"; exit 2 }
fi

local dir_json="" base=""
dir_json=$("$self_dir/clean-stop.zsh" dir --repo-dir "$repo_dir" --issue "$issue") || {
  print -u2 -- "chain-queue: could not derive the durable directory"; exit 1 }
base=$(print -r -- "$dir_json" | jq -r '.base // empty') || base=""
[[ -n "$base" ]] || { print -u2 -- "chain-queue: clean-stop.zsh dir printed no base"; exit 1 }
local qf="$base/chain-queue.json"

local q=""
if [[ -e "$qf" ]]; then
  q=$(jq -ce 'select(.schema == "chain-queue/v1" and (.entries | type == "array"))' "$qf" 2>/dev/null) || {
    print -u2 -- "chain-queue: the queue file is not a chain-queue/v1 document: $qf"; exit 1 }
else
  q=$(jq -nc --argjson n "$issue" '{schema: "chain-queue/v1", named: $n, entries: []}')
fi

_write() {
  mkdir -p -- "$base" || { print -u2 -- "chain-queue: could not create $base"; exit 1 }
  local tmp="$qf.tmp.$$"
  print -r -- "$1" | jq . > "$tmp" && mv -f -- "$tmp" "$qf" || {
    rm -f -- "$tmp"; print -u2 -- "chain-queue: could not write $qf"; exit 1 }
  print -r -- "$1" | jq .
}

case "$cmd" in
add)
  local present=""
  present=$(print -r -- "$q" | jq --argjson i "$entry" '[.entries[] | select(.issue == $i)] | length')
  if (( present > 0 )); then
    [[ -n "$pr" ]] && q=$(print -r -- "$q" | jq -c --argjson i "$entry" --argjson p "$pr" \
      '.entries |= map(if .issue == $i then .pr = $p else . end)')
    (( ${#child_prs} > 0 )) && q=$(print -r -- "$q" | jq -c --argjson i "$entry" \
      --argjson c "[${(j:,:)child_prs}]" \
      '.entries |= map(if .issue == $i then .child_prs = (reduce $c[] as $p ((.child_prs // []);
         if index([$p]) == null then . + [$p] else . end)) else . end)')
    _write "$q"; exit 0
  fi
  (( ${#child_prs} == 0 )) || { print -u2 -- "chain-queue: --child-pr needs an entry already queued: no queued entry #$entry"; exit 5 }
  [[ -n "$kind" ]] || { print -u2 -- "chain-queue: no queued entry #$entry"; exit 5 }
  if [[ "$kind" == follow-up ]]; then
    print -r -- "$q" | jq -e --argjson f "$finding" \
      'any(.entries[]; .kind == "follow-up" and .state == "done"
        and (.finding | {file, line, dimension, title}) == ($f | {file, line, dimension, title}))' >/dev/null && {
      print -u2 -- "chain-queue: follow-up cycle — #$entry's finding equals a follow-up already resolved in this run"
      exit 3 }
  fi
  local anchor="${before:-$after}"
  if [[ -n "$anchor" ]]; then
    print -r -- "$q" | jq -e --argjson a "$anchor" 'any(.entries[]; .issue == $a)' >/dev/null || {
      print -u2 -- "chain-queue: no queued entry #$anchor"; exit 5 }
  fi
  q=$(print -r -- "$q" | jq -c --argjson i "$entry" --arg k "$kind" --argjson d "$depth" \
      --argjson b "${before:-null}" --argjson a "${after:-null}" --argjson p "${pr:-null}" \
      --argjson f "${finding:-null}" '
    def idx($n): [.entries[].issue] | index($n);
    # every entry queued from $n: its follow-ups and their blockers, recursively
    def from($n): . as $q | [$n] | until(
        . as $s | [$q.entries[] | select((.filed_by != null and (.filed_by | IN($s[])))
          or (.before != null and (.before | IN($s[])))) | .issue] | (. - $s) | length == 0;
        . as $s | ($s + [$q.entries[] | select((.filed_by != null and (.filed_by | IN($s[])))
          or (.before != null and (.before | IN($s[])))) | .issue]) | unique);
    {issue: $i, kind: $k, state: "queued", pr: $p, depth: (if $k == "blocker" then $d else null end),
     filed_by: (if $k == "follow-up" then $a else null end),
     before: (if $k == "blocker" then $b else null end),
     finding: (if $k == "follow-up" then ($f | {file, line, dimension, title}) else null end)} as $e
    | . as $q
    | (if $k == "follow-up" then
         (from($a)) as $mine
         | ([range(0; .entries | length)] | map(select($q.entries[.].issue | IN($mine[]))) | max) + 1
       elif $k == "blocker" and $b != null then idx($b)
       elif $k == "blocker" then
         ([range(0; .entries | length)] | map(select($q.entries[.].kind == "blocker" and $q.entries[.].before == null
            and $q.entries[.].depth >= $d)) | max // -1) + 1
       else
         ([range(0; .entries | length)] | map(select($q.entries[.].kind == "blocker" and $q.entries[.].before == null))
            | max // -1) + 1
       end) as $at
    | .entries = .entries[:$at] + [$e] + .entries[$at:]')
  _write "$q"
  ;;
next)
  local n=""
  n=$(print -r -- "$q" | jq -c 'first(.entries[] | select(.state != "done")) // empty')
  [[ -n "$n" ]] || { print -u2 -- "chain-queue: the queue is empty — every queued issue is done"; exit 4 }
  print -r -- "$n"
  ;;
done)
  print -r -- "$q" | jq -e --argjson i "$entry" 'any(.entries[]; .issue == $i)' >/dev/null || {
    print -u2 -- "chain-queue: no queued entry #$entry"; exit 5 }
  q=$(print -r -- "$q" | jq -c --argjson i "$entry" --argjson p "${pr:-null}" \
    '.entries |= map(if .issue == $i then .state = "done" | (if $p != null then .pr = $p else . end) else . end)')
  _write "$q"
  ;;
close-out)
  print -r -- "$q" | jq -e --argjson i "$entry" 'any(.entries[]; .issue == $i)' >/dev/null || {
    print -u2 -- "chain-queue: no queued entry #$entry"; exit 5 }
  q=$(print -r -- "$q" | jq -c --argjson i "$entry" --argjson p "$pr" \
    '.entries |= map(if .issue == $i then .state = "done" | .pr = $p else . end)')
  local nx=""
  nx=$(print -r -- "$q" | jq -c 'first(.entries[] | select(.state != "done")) // empty')
  if [[ -n "$nx" ]]; then
    _write "$q" >/dev/null
    jq -nc --argjson e "$nx" '{cleared: false, next: $e}'
  else
    rm -f -- "$qf" || { print -u2 -- "chain-queue: could not remove $qf"; exit 1 }
    rmdir -- "$base" 2>/dev/null || true
    jq -nc '{cleared: true, next: null}'
  fi
  ;;
report)
  print -r -- "$q" | jq -r --argjson s "$stopped" --arg r "$reason" --argjson pause "$pause" '
    def refs: if length == 0 then "none" else map("#\(.)") | join(", ") end;
    "chain stopped: #\($s)" + (if $pause == 1 then " (paused, not failed)" else "" end) + " — " + $r,
    "Merged in this run: " + ([.entries[] | (if .state == "done" and .pr != null then [.pr] else [] end)
        + (.child_prs // []) | .[]]
      | reduce .[] as $p ([]; if index([$p]) == null then . + [$p] else . end) | refs),
    "Still queued: " + ([.entries[] | select(.state != "done") | .issue] | refs)'
  ;;
clear)
  rm -f -- "$qf" || { print -u2 -- "chain-queue: could not remove $qf"; exit 1 }
  rmdir -- "$base" 2>/dev/null || true
  ;;
esac
