#!/usr/bin/env zsh
# batch-approval.zsh — the one approval of an interactive epic walk's batch
# (#2904). refine-issue's Epic walk drafts every needs-refinement child first
# (phase A) and then asks ONE approval for the batch of children whose draft
# converged and passed the size check (phase B), instead of one approval per
# child. This script renders that batch for the human and splits the human's
# answer; the conductor (SKILL.md, Epic walk) owns every question and write.
#
# The walk keeps one state file per child, <dir>/<N>.json, which the conductor
# rewrites with jq after every round. A child is in the batch when its `phase`
# is "pending". The fields this script reads from a pending child:
#   proposed_story_spec  object — the draft block (acceptance_criteria,
#                        scope_boundaries.in/out, test_cases[].id)
#   old_block            object or null — the issue's current story-spec block
#   auto_accepted        array of {question, answer, confidence, weakest}
#   expected_docs_pages  array of strings
#   rewrite_path         string — where the child's full rewrite is kept
# Every other field of the state file (the Step 7 run variables, the
# conversation, draft_ready_at, …) belongs to the conductor and is not read.
#
# Usage:
#   batch-approval.zsh summary   --dir <D>
#   batch-approval.zsh partition --dir <D> [--revisit "<n …>"] [--skip "<n …>"]
#
# summary   prints one Markdown entry per pending child, in issue-number order:
#           its intent changes (acceptance_criteria and scope_boundaries.in/out
#           added and removed against old_block, or "new block"), its test
#           cases (the count and the ids Step 2.5 will create, edit or close),
#           its side effects, its Answers taken automatically, its expected
#           docs pages and the path of its full rewrite. It names no blockedBy
#           edge: refine-issue creates none.
# partition prints {"approve": [..], "revisit": [..], "skip": [..]}: every
#           pending child is in exactly one list; the ones not named go to
#           approve.
#
# Exit: 0 rendered / partitioned (a summary with no pending child prints
#       nothing); 1 a state file in <D> that is not one JSON object with a
#       string `phase`, or a pending one missing a field read above;
#       2 usage error — an unknown mode or flag, a missing or unreadable <D>,
#       a --revisit / --skip entry that is not a number, a number that is not a
#       pending child, or a number named in both lists.

emulate -L zsh
setopt no_unset pipe_fail

usage() {
  print -r -u2 -- "usage: batch-approval.zsh summary --dir <D>"
  print -r -u2 -- "       batch-approval.zsh partition --dir <D> [--revisit \"<n …>\"] [--skip \"<n …>\"]"
}

(( $# >= 1 )) || { usage; exit 2 }
local mode="$1"; shift
case "$mode" in
  summary|partition) ;;
  *) usage; exit 2 ;;
esac

local dir="" revisit_raw="" skip_raw=""
while (( $# > 0 )); do
  case "$1" in
    --dir) (( $# >= 2 )) || { usage; exit 2 }; dir="$2"; shift 2 ;;
    --revisit)
      [[ "$mode" == partition ]] || { usage; exit 2 }
      (( $# >= 2 )) || { usage; exit 2 }; revisit_raw="$2"; shift 2 ;;
    --skip)
      [[ "$mode" == partition ]] || { usage; exit 2 }
      (( $# >= 2 )) || { usage; exit 2 }; skip_raw="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$dir" && -d "$dir" && -r "$dir" ]] || {
  print -r -u2 -- "batch-approval: --dir missing or unreadable: '$dir'"; exit 2 }

# Load every <N>.json, validating as we go. Exit 1 names the first bad file.
local -a files
files=("$dir"/<->.json(N))
local -a pending
local -A file_of
local f n
for f in "${files[@]}"; do
  jq -e -s 'length == 1 and (.[0] | type == "object") and ((.[0].phase // null) | type == "string")' \
    "$f" >/dev/null 2>&1 || {
    print -r -u2 -- "batch-approval: malformed state file (not one JSON object with a string phase): $f"; exit 1 }
  [[ "$(jq -r '.phase' "$f")" == pending ]] || continue
  jq -e '
    (.proposed_story_spec | type == "object")
    and has("old_block") and ((.old_block | type) as $t | $t == "object" or $t == "null")
    and (.auto_accepted | type == "array")
    and (.expected_docs_pages | type == "array")
    and (.rewrite_path | type == "string")
  ' "$f" >/dev/null 2>&1 || {
    print -r -u2 -- "batch-approval: malformed pending state file (needs proposed_story_spec, old_block, auto_accepted, expected_docs_pages, rewrite_path): $f"; exit 1 }
  n="$(( 10#${${f:t}%.json} ))"
  file_of[$n]="$f"
  pending+=("$n")
done
pending=(${(on)pending})

if [[ "$mode" == summary ]]; then
  for n in "${pending[@]}"; do
    jq -r --arg n "$n" '
      # NB: no apostrophes in this program — it is single-quoted.
      def line: tostring | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
      def arr(p): (p // []) | map(line);
      def diff($what; $nw; $od):
        ($nw - $od) as $add | ($od - $nw) as $del
        | (if ($add | length) > 0 then ["  - \($what) added: " + ($add | map("\"" + . + "\"") | join("; "))] else [] end)
        + (if ($del | length) > 0 then ["  - \($what) removed: " + ($del | map("\"" + . + "\"") | join("; "))] else [] end);
      .proposed_story_spec as $new | .old_block as $old
      | ([$new.test_cases // [] | .[] | .id // empty | tostring]) as $nid
      | ([$old // {} | .test_cases // [] | .[] | .id // empty | tostring]) as $oid
      | ($nid - $oid) as $create | ($nid - ($nid - $oid)) as $edit | ($oid - $nid) as $close
      | def ids(xs): if (xs | length) == 0 then "none" else (xs | join(", ")) end;
      "### #\($n)",
      "",
      "- **Intent changes:**",
      ( if $old == null then "  - new block"
        else
          ( diff("acceptance criterion"; arr($new.acceptance_criteria); arr($old.acceptance_criteria))
          + diff("scope in"; arr($new.scope_boundaries.in); arr($old.scope_boundaries.in))
          + diff("scope out"; arr($new.scope_boundaries.out); arr($old.scope_boundaries.out)) ) as $d
          | if ($d | length) == 0 then "  - none" else $d[] end
        end ),
      "- **Test cases:** \($nid | length) — create: \(ids($create)); edit: \(ids($edit)); close: \(ids($close))",
      "- **Side effects:** the issue body is rewritten; the test-case issues above are reconciled; `needs-refinement` is cleared if the re-gate is READY",
      "- **Answers taken automatically:**",
      ( if (.auto_accepted | length) == 0 then "  - none"
        else .auto_accepted[] | "  - \(.question | line) → \(.answer | line) (confidence \(.confidence // "?"), weakest: \((.weakest // []) | if type == "array" then join(", ") else tostring end))"
        end ),
      "- **Expected docs pages:** \(if (.expected_docs_pages | length) == 0 then "none" else (.expected_docs_pages | join(", ")) end)",
      "- **Full rewrite:** \(.rewrite_path)",
      ""
    ' "${file_of[$n]}" || exit 1
  done
  exit 0
fi

# partition
parse_list() {
  local raw="$1" tok
  local -a out
  for tok in ${=raw//,/ }; do
    [[ "$tok" == <-> || "$tok" == \#<-> ]] || {
      print -r -u2 -- "batch-approval: not an issue number: '$tok'"; return 2 }
    out+=("$(( 10#${tok#\#} ))")
  done
  print -r -- "${(j: :)${(onu)out}}"
}
local -a revisit skip
local parsed
parsed="$(parse_list "$revisit_raw")" || exit 2
revisit=(${=parsed})
parsed="$(parse_list "$skip_raw")" || exit 2
skip=(${=parsed})

for n in "${revisit[@]}" "${skip[@]}"; do
  (( ${pending[(Ie)$n]} )) || {
    print -r -u2 -- "batch-approval: #$n is not a pending child of this batch"; exit 2 }
done
for n in "${revisit[@]}"; do
  (( ${skip[(Ie)$n]} )) && {
    print -r -u2 -- "batch-approval: #$n is named both to revisit and to skip"; exit 2 }
done

local -a approve
for n in "${pending[@]}"; do
  (( ${revisit[(Ie)$n]} || ${skip[(Ie)$n]} )) || approve+=("$n")
done

jq -n -c \
  --argjson approve "[${(j:,:)approve}]" \
  --argjson revisit "[${(j:,:)revisit}]" \
  --argjson skip "[${(j:,:)skip}]" \
  '{approve: $approve, revisit: $revisit, skip: $skip}'
