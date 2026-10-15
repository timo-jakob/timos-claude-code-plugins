#!/usr/bin/env zsh
# file-split-children.zsh — file an accepted split of an oversized story as
# native sub-issues of the original (#2589, epic #2582).
#
# `/development:refine-issue` never writes back a draft whose declared inventory
# stops the size check. It proposes a split into child stories instead, each
# with its own declared inventory, and when the human accepts it this script
# files them. The human is present: this is the refinement-time split, not the
# unattended one.
#
# Order of work, and why:
#   1. Validate the plan and check EVERY child's inventory with size-check.zsh
#      before any write. One child that still stops means the split is not
#      buildable either: exit 1 and write NOTHING.
#   2. File each child (`needs-refinement` label, a closing "Split from #<parent>"
#      line), resolve its database id and attach it as a native sub-issue of the
#      original. A failure here stops at once (exit 5) and reports the children
#      already filed; the original's labels are left exactly as they were, so the
#      story still reads `needs-refinement` and a human can finish or undo it.
#   3. Only once every child is filed and attached: replace the original's
#      `needs-refinement` with `epic` (and drop any `needs-split`, best-effort),
#      then post the trail comment listing the
#      children. Either failing is also exit 5, reported as such.
# Nothing here is retried and nothing is undone — a partial result is reported,
# never guessed at.
#
# Plan shape — exactly one JSON object, at least two children:
#   { "children": [
#       { "title": "feat(x): …", "body": "…", "files": ["development/…", …] }, … ] }
# `files` is the child's declared inventory, judged exactly as size-check.zsh
# judges any inventory; an empty array is skipped, never a stop.
#
# Output — one JSON object on stdout for exits 0, 1 and 5:
#   { "parent": N,
#     "filed":   [ { "index": 1, "issue": M, "linked": true }, … ],
#     "stopped": [ { "index": 2, "verdict": { …size-check verdict… } }, … ],
#     "relabelled": bool, "commented": bool,
#     "error": null | "what failed" }
# `index` is the child's 1-based position in the plan.
#
# gh is reached through $GH_BIN (default `gh`), the test seam.
#
# Exit codes:
#   0 — every child filed and attached, the original relabelled, the trail posted.
#   1 — at least one child's inventory stops the size check; nothing was written.
#   2 — usage error (unknown/dangling flag, a missing or unreadable plan, a
#       --parent that is not a positive integer). Nothing on stdout.
#   3 — runtime error before any write: a malformed plan, a size check that
#       errored, jq missing. Nothing on stdout.
#   5 — partial: writes started and one failed; the report names what landed.
#
# Usage:
#   file-split-children.zsh --repo OWNER/NAME --parent N --plan <plan.json>
#                           [--manifest <marketplace.json>]
# Run it from the repository root, as size-check.zsh expects.

emulate -L zsh
set -uo pipefail

local -r size_check="${0:A:h}/size-check.zsh"
local gh_bin="${GH_BIN:-gh}"

local repo="" parent="" plan="" manifest=""
while (( $# > 0 )); do
  case "$1" in
    --repo|--parent|--plan|--manifest)
      (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] \
        || { print -u2 "file-split-children.zsh: $1 needs a value"; exit 2; }
      case "$1" in
        --repo) repo="$2" ;; --parent) parent="$2" ;;
        --plan) plan="$2" ;; --manifest) manifest="$2" ;;
      esac
      shift 2 ;;
    -h|--help)
      print -u2 -r -- "usage: file-split-children.zsh --repo OWNER/NAME --parent N --plan <plan.json> [--manifest <marketplace.json>]"
      print -u2 -r -- "exit 0 filed, 1 a child stops (nothing written), 2 usage, 3 runtime, 5 partial."
      exit 0 ;;
    *) print -u2 "file-split-children.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$repo" && "$repo" == */* ]] \
  || { print -u2 "file-split-children.zsh: --repo OWNER/NAME is required"; exit 2; }
[[ "$parent" == <1-> ]] \
  || { print -u2 "file-split-children.zsh: --parent must be a positive integer"; exit 2; }
[[ -n "$plan" && -f "$plan" && -r "$plan" ]] \
  || { print -u2 "file-split-children.zsh: --plan not found or unreadable: ${plan:-<none>}"; exit 2; }
command -v jq >/dev/null 2>&1 || { print -u2 "file-split-children.zsh: jq not found on PATH"; exit 3; }

local problem
problem="$(jq -rs '
  if length != 1 then "the plan is not exactly one JSON document"
  else .[0] |
    if type != "object" then "the plan is not a JSON object"
    elif (.children | type) != "array" then "children must be an array"
    elif (.children | length) < 2 then "a split needs at least two children"
    elif any(.children[]; type != "object") then "every child must be an object"
    elif any(.children[]; (.title | type) != "string" or (.title | length) == 0)
      then "every child needs a non-empty title"
    elif any(.children[]; (.body | type) != "string") then "every child needs a body string"
    elif any(.children[]; (.files | type) != "array") then "every child needs a files array"
    else "" end
  end' "$plan" 2>/dev/null)" \
  || { print -u2 "file-split-children.zsh: the plan is not valid JSON"; exit 3; }
[[ -z "$problem" ]] || { print -u2 "file-split-children.zsh: malformed plan: $problem"; exit 3; }

local work
work="$(mktemp -d)" || { print -u2 "file-split-children.zsh: no temp dir"; exit 3; }
trap 'rm -rf "$work"' EXIT

local -i count i
count="$(jq '.children | length' "$plan")"

# --- 1. size-check every child before any write ----------------------------
local -a stopped=() args=()
[[ -z "$manifest" ]] || args=(--manifest "$manifest")
local verdict
local -i rc
for (( i = 1; i <= count; i++ )); do
  jq -c --argjson i "$i" '{files: .children[$i - 1].files}' "$plan" > "$work/inv-$i.json"
  verdict="$(zsh "$size_check" --file "$work/inv-$i.json" "${args[@]}")"
  rc=$?
  case $rc in
    0) ;;
    1) stopped+=("$(jq -nc --argjson i "$i" --argjson v "$verdict" '{index: $i, verdict: $v}')") ;;
    *) print -u2 "file-split-children.zsh: the size check errored on child $i (exit $rc)"; exit 3 ;;
  esac
done

local -a filed=()
_report() {  # $1 relabelled, $2 commented, $3 error ("" for none)
  jq -nc --argjson parent "$parent" \
    --argjson filed "[${(j:,:)filed}]" --argjson stopped "[${(j:,:)stopped}]" \
    --argjson relabelled "$1" --argjson commented "$2" --arg error "$3" \
    '{parent: $parent, filed: $filed, stopped: $stopped,
      relabelled: $relabelled, commented: $commented,
      error: (if $error == "" then null else $error end)}'
}

if (( ${#stopped} > 0 )); then
  _report false false ""
  exit 1
fi

# --- 2. file and attach each child ------------------------------------------
"$gh_bin" label create needs-refinement --repo "$repo" --color d4c5f9 \
  --description "Sent back by the readiness gate — needs clarification before implementation" \
  >/dev/null 2>&1 || true
"$gh_bin" label create epic --repo "$repo" --color 5319E7 \
  --description "Parent issue with a task list of children" >/dev/null 2>&1 || true

local title url num out id
local -a ids
for (( i = 1; i <= count; i++ )); do
  title="$(jq -r --argjson i "$i" '.children[$i - 1].title' "$plan")"
  jq -r --argjson i "$i" --argjson p "$parent" \
    '.children[$i - 1].body + "\n\nSplit from #\($p)."' "$plan" > "$work/body-$i.md"
  if ! url="$("$gh_bin" issue create --repo "$repo" --title "$title" \
                --body-file "$work/body-$i.md" --label needs-refinement 2>&1)"; then
    _report false false "creating child $i failed: ${url//[^[:print:]]/?}"
    exit 5
  fi
  num="${${(M)${(f)url}:#*/issues/<->}##*/}"
  if [[ "$num" != <1-> ]]; then
    _report false false "creating child $i returned no issue URL: ${url//[^[:print:]]/?}"
    exit 5
  fi
  # the issue exists now, linked or not — report it either way
  if ! out="$("$gh_bin" api "repos/$repo/issues/$num" --jq .id 2>&1)"; then
    filed+=("$(jq -nc --argjson i "$i" --argjson n "$num" '{index: $i, issue: $n, linked: false}')")
    _report false false "resolving the id of #$num failed: ${out//[^[:print:]]/?}"
    exit 5
  fi
  ids=( ${(M)${(f)out}:#<->} )
  if (( ${#ids} != 1 )) || ! "$gh_bin" api -X POST "repos/$repo/issues/$parent/sub_issues" \
        -F sub_issue_id="$ids[1]" >/dev/null 2>&1; then
    filed+=("$(jq -nc --argjson i "$i" --argjson n "$num" '{index: $i, issue: $n, linked: false}')")
    _report false false "attaching #$num as a sub-issue of #$parent failed"
    exit 5
  fi
  filed+=("$(jq -nc --argjson i "$i" --argjson n "$num" '{index: $i, issue: $n, linked: true}')")
done

# --- 3. relabel the original, then post the trail ---------------------------
if ! "$gh_bin" issue edit "$parent" --repo "$repo" \
      --remove-label needs-refinement --add-label epic >/dev/null 2>&1; then
  _report false false "relabelling #$parent failed"
  exit 5
fi
# a story resolve-issue §2 parked carries needs-split; the split resolves it
"$gh_bin" issue edit "$parent" --repo "$repo" --remove-label needs-split >/dev/null 2>&1 || true

{
  print -r -- "**Split at refinement** (\`/development:refine-issue\`): the declared inventory was too large to build"
  print -r -- "as one change, so the story was split into $count child stories, filed as native sub-issues:"
  print
  for (( i = 1; i <= count; i++ )); do
    print -r -- "- #$(jq -r --argjson i "$i" '.[] | select(.index == $i) | .issue' <<< "[${(j:,:)filed}]") — $(jq -r --argjson i "$i" '.children[$i - 1].title' "$plan")"
  done
  print
  print -r -- "Each child carries \`needs-refinement\`; this issue is now an \`epic\`."
} > "$work/trail.md"
if ! "$gh_bin" issue comment "$parent" --repo "$repo" --body-file "$work/trail.md" >/dev/null 2>&1; then
  _report true false "posting the trail comment on #$parent failed"
  exit 5
fi

_report true true ""
exit 0
