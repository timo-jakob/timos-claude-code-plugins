#!/usr/bin/env zsh
# plan-story-split.zsh — validate a proposed split of an oversized story into
# child stories (issue #2584, epic #2582).
#
# Why: an unattended size pre-flight stop splits the story before it is built
# (#2578). Grouping its criteria into children is a judgement, so a subagent
# proposes it; this script takes that proposal as input and enforces what must
# hold of ANY split, so a bad grouping is refused instead of filed:
#   1. every acceptance criterion of the original lands in exactly one child,
#      verbatim — none dropped, none duplicated, none invented — and every
#      child carries at least one: a child that owns no criterion is no story;
#   2. every child's declared inventory passes size-preflight.zsh;
#   3. every file of the original's declared inventory lands in at least one
#      child (a file may sit in several: a version bump is everyone's);
#   4. the order between children is acyclic: a child is blocked only by
#      children before it in the proposal.
# It never invents a grouping, and it files nothing: that is #2578's job. A pure
# function of its input, besides running size-preflight.zsh: no GitHub, no git.
#
# Inputs:
#   --story FILE      the original story: `gh issue view <N> --json
#                     number,title,body`. Its criteria are its story-spec/v1
#                     block's `acceptance_criteria` (read-story-spec.zsh), else
#                     the `- [ ]` / `- [x]` lines under its `## Acceptance
#                     criteria` heading, with the checkbox stripped.
#   --proposal FILE   { "children": [
#                         { "title": "...", "body": "...",
#                           "criteria": ["<an original criterion, verbatim>", ...],
#                           "files": ["<repo-relative path>", ...],
#                           "blocked_by": [<1-based index of an earlier child>, ...] },
#                         ... ] }                       at least two children
#   --inventory FILE  OPTIONAL: the original's pre-flight inventory, the same
#                     {"files": [...]} object size-preflight.zsh judged.
#                     Without it, check 3 is skipped.
#   --manifest FILE   OPTIONAL: passed through to size-preflight.zsh.
#
# Output — one JSON object on stdout for exits 0 and 1:
#   { "parent": N, "valid": true|false,
#     "criteria_total": N,
#     "children": [ { "index": i, "title", "body", "criteria", "files",
#                     "blocked_by", "size": <size-preflight verdict> }, ... ],
#     "errors": [ "...", ... ] }          [] when valid
# Each error names its gap: the criterion, the child (by index and title) or
# the file. Every error is also printed on stderr.
#
# Exit codes:
#   0 — a valid plan.
#   1 — the plan breaks an invariant; `errors` names each gap. Not an error of
#       the caller's input shape.
#   2 — usage error (unknown/dangling flag, a missing or unreadable file).
#       Nothing on stdout.
#   3 — runtime error: a malformed story, proposal or inventory, a story with no
#       criteria to assign, a size-preflight.zsh that errored, jq missing.
#       Nothing on stdout.

emulate -L zsh
setopt nounset pipefail

readonly SELF_DIR="${0:A:h}"
readonly PREFLIGHT="$SELF_DIR/size-preflight.zsh"
readonly SPEC_TOOL="$SELF_DIR/read-story-spec.zsh"

_die() { print -u2 -- "plan-story-split: $1"; exit "${2:-3}" }

# A dangling value flag must not reach `shift 2` (zsh refuses the shift and the
# loop spins); record-grant.zsh guards its parser the same way.
_need_val() {   # $1 = flag, $2 = remaining argc, $3 = the candidate value
  (( $2 >= 2 )) || _die "$1 requires a value" 2
  [[ -n "$3" && "$3" != --* ]] || _die "$1 requires a value" 2
}

_readable() {   # $1 = flag, $2 = path
  [[ -n "$2" ]] || _die "$1 is required" 2
  [[ -f "$2" && -r "$2" ]] || _die "cannot read $1 $2" 2
}

local story="" proposal="" inventory="" manifest=""
while (( $# )); do
  case "$1" in
    --story)     _need_val "$1" $# "${2:-}"; story="$2"; shift 2 ;;
    --proposal)  _need_val "$1" $# "${2:-}"; proposal="$2"; shift 2 ;;
    --inventory) _need_val "$1" $# "${2:-}"; inventory="$2"; shift 2 ;;
    --manifest)  _need_val "$1" $# "${2:-}"; manifest="$2"; shift 2 ;;
    -h|--help)   print -u2 -- "usage: plan-story-split.zsh --story FILE --proposal FILE [--inventory FILE] [--manifest FILE]"; exit 0 ;;
    *) _die "unknown argument: $1" 2 ;;
  esac
done
_readable --story "$story"
_readable --proposal "$proposal"
[[ -z "$inventory" ]] || _readable --inventory "$inventory"
[[ -z "$manifest" ]] || _readable --manifest "$manifest"
command -v jq >/dev/null 2>&1 || _die "jq is required"

# --- the original's criteria ----------------------------------------------------
jq -e 'type == "object" and (.number | type == "number") and (.body | type == "string")' -- "$story" >/dev/null 2>&1 \
  || _die "--story must be an issue object with number and body (gh issue view --json number,title,body)"
local parent body criteria spec rc=0
parent="$(jq -r '.number' -- "$story")"
body="$(jq -r '.body' -- "$story")"
spec="$(print -r -- "$body" | zsh "$SPEC_TOOL" 2>/dev/null)" || rc=$?
case $rc in
  0) criteria="$(jq -c '.acceptance_criteria // [] | map(select(type == "string"))' <<< "$spec")" ;;
  1) # no block: the checkbox lines under the "## Acceptance criteria" heading
     criteria="$(print -r -- "$body" | awk '
       { sub(/\r$/, "") }
       /^## / { on = ($0 ~ /^## Acceptance criteria[[:space:]]*$/); next }
       on && /^- \[[ xX]\] / { sub(/^- \[[ xX]\] /, ""); print }' \
       | jq -R -s -c 'split("\n") | map(select(length > 0))')" ;;
  *) _die "read-story-spec.zsh failed on the story body (exit $rc)" ;;
esac
[[ "$(jq 'length' <<< "$criteria")" -gt 0 ]] || _die "the story has no acceptance criteria to assign (no story-spec block, no ## Acceptance criteria checkboxes)"
jq -e 'length == (unique | length)' <<< "$criteria" >/dev/null \
  || _die "the story lists the same acceptance criterion twice; a split cannot assign it exactly once"

# --- the proposal's shape ---------------------------------------------------------
local shape
shape="$(jq -r '
  def strs: type == "array" and all(.[]; type == "string" and length > 0);
  if type != "object" or (.children | type) != "array" then "the proposal must be an object with a children array"
  elif (.children | length) < 2 then "a split needs at least two children"
  else ([.children | to_entries[] | .key as $k | .value
         | if type != "object" then "child \($k + 1) is not an object"
           elif (.title | type) != "string" or (.title | length) == 0 then "child \($k + 1) has no title"
           elif (.body | type) != "string" then "child \($k + 1) has no body"
           elif (.criteria | strs) | not then "child \($k + 1) criteria must be an array of non-empty strings"
           elif (.files | strs) | not then "child \($k + 1) files must be an array of non-empty strings"
           elif (.blocked_by // [] | type == "array" and all(.[]; type == "number" and . == floor)) | not
             then "child \($k + 1) blocked_by must be an array of child indices"
           else empty end] | first // "ok") end' -- "$proposal" 2>/dev/null)" \
  || _die "--proposal $proposal is not JSON"
[[ "$shape" == ok ]] || _die "$shape"
if [[ -n "$inventory" ]]; then
  jq -e 'type == "object" and (.files | type == "array") and all(.files[]; type == "string")' -- "$inventory" >/dev/null 2>&1 \
    || _die "--inventory must be an object with a files array (the size-preflight inventory)"
fi

# --- the invariants -------------------------------------------------------------
local -a errors
local e
# 1. criteria: each original exactly once; nothing unknown
while IFS= read -r e; do
  [[ -n "$e" ]] && errors+=("$e")
done < <(jq -r --argjson orig "$criteria" '
  [.children | to_entries[] | .key as $k | .value.criteria[] | {c: ., i: ($k + 1)}] as $a
  | ($orig[] as $c
     | ([$a[] | select(.c == $c) | .i]) as $in
     | if ($in | length) == 0 then "criterion assigned to no child: \($c)"
       elif ($in | length) > 1 then "criterion assigned to children \($in | map(tostring) | join(" and ")): \($c)"
       else empty end),
    ($a[] | select(.c as $c | $orig | index($c) | not)
     | "child \(.i) carries a criterion the story does not have: \(.c)"),
    (.children | to_entries[] | select(.value.criteria | length == 0)
     | "child \(.key + 1) (\(.value.title)) carries no acceptance criterion")' -- "$proposal")

# 4. order: blocked_by names only earlier children
while IFS= read -r e; do
  [[ -n "$e" ]] && errors+=("$e")
done < <(jq -r '.children | to_entries[] | (.key + 1) as $i | (.value.blocked_by // [])[]
  | select(. < 1 or . >= $i)
  | "child \($i) is blocked by child \(.), which is not an earlier child"' -- "$proposal")

# 3. the original inventory: every file in at least one child
if [[ -n "$inventory" ]]; then
  while IFS= read -r e; do
    [[ -n "$e" ]] && errors+=("$e")
  done < <(jq -r --slurpfile p "$proposal" '
    ([$p[0].children[].files[]] | unique) as $have
    | .files[] | select(. as $f | $have | index($f) | not)
    | "file in the original inventory assigned to no child: \(.)"' -- "$inventory")
fi

# 2. size: every child passes the pre-flight
local n i verdict vrc child_inv child_err why sizes="[]"
n="$(jq '.children | length' -- "$proposal")"
child_inv="$(mktemp "${TMPDIR:-/tmp}/plan-story-split.XXXXXX")" || _die "cannot create a temp file"
child_err="$(mktemp "${TMPDIR:-/tmp}/plan-story-split.XXXXXX")" || { rm -f -- "$child_inv"; _die "cannot create a temp file"; }
local -a mf=()
[[ -z "$manifest" ]] || mf=(--manifest "$manifest")
for (( i = 0; i < n; i++ )); do
  jq -c --argjson i "$i" '{files: .children[$i].files}' -- "$proposal" > "$child_inv"
  vrc=0
  verdict="$(zsh "$PREFLIGHT" --file "$child_inv" "${mf[@]}" 2>"$child_err")" || vrc=$?
  case $vrc in
    0|1) ;;
    *) why="$(tr '\n' ' ' < "$child_err")"; why="${why%% }"
       rm -f -- "$child_inv" "$child_err"
       _die "size-preflight.zsh failed on child $(( i + 1 ))'s inventory (exit $vrc)${why:+: $why}" ;;
  esac
  sizes="$(jq -c --argjson v "$verdict" '. + [$v]' <<< "$sizes")"
  if (( vrc == 1 )); then
    errors+=("$(jq -r --argjson i "$i" --argjson v "$verdict" \
      '"child \($i + 1) (\(.children[$i].title)) stops the size pre-flight: \($v.triggers | join(", "))"' -- "$proposal")")
  fi
done
rm -f -- "$child_inv" "$child_err"

# --- the plan -------------------------------------------------------------------
local errs_json
errs_json="$(print -rl -- "${errors[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
(( ${#errors} == 0 )) || print -rl -u2 -- "${errors[@]/#/plan-story-split: }"
jq -c --argjson parent "$parent" --argjson orig "$criteria" --argjson sizes "$sizes" --argjson errs "$errs_json" '
  {parent: $parent, valid: ($errs | length == 0), criteria_total: ($orig | length),
   children: [.children | to_entries[] | {index: (.key + 1), title: .value.title, body: .value.body,
              criteria: .value.criteria, files: .value.files, blocked_by: (.value.blocked_by // []),
              size: $sizes[.key]}],
   errors: $errs}' -- "$proposal"
(( ${#errors} == 0 )) || exit 1
