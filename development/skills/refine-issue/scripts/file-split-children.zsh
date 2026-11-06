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
#   3. Declare every child's prerequisites as native `blockedBy` edges (#2947),
#      through add-blocked-by-edges.zsh: each `blocked_by` the plan lists, and
#      each OPEN native blocker of the original copied onto every child whose
#      `blocked_by` names no sibling. The children that start the split's order
#      inherit the original's blockers; the rest reach them through their
#      sibling. Every edge is tried; any that cannot be added is a partial
#      result (exit 5) naming the edge, and the original's labels stay as they
#      were.
#   4. Only once every child is filed, attached and its edges added: replace the
#      original's `needs-refinement` with `epic` (and drop any `needs-split`,
#      best-effort), then post the trail comment listing the children and their
#      edges. Either failing is also exit 5, reported as such.
# Nothing here is undone — a partial result is reported, never guessed at.
#
# A re-run is safe once every filed child is attached: a plan child whose title
# equals one of the original's native sub-issues is that child, reused rather
# than filed again, and add-blocked-by-edges.zsh skips every edge that already
# exists, so a re-run adds only what is missing. A child filed but never
# attached (`linked: false`) is not found that way, and a re-run would file it
# a second time.
#
# A `blocked_by` whose sibling indexes form a cycle, or name an index outside
# the plan, is refused before any write: exit 1, nothing filed, the report's
# `error` naming it.
#
# Plan shape — exactly one JSON object, at least two children:
#   { "children": [
#       { "title": "feat(x): …", "body": "…", "files": ["development/…", …],
#         "blocked_by": [0, "#52", "owner/repo#7"] }, … ] }
# `files` is the child's declared inventory, judged exactly as size-check.zsh
# judges any inventory; an empty array is skipped, never a stop. `blocked_by` is
# optional (absent reads as `[]`): each item is the 0-based index of a sibling
# child in this plan, or an issue reference `#N` / `owner/repo#N`.
#
# Output — one JSON object on stdout for exits 0, 1 and 5:
#   { "parent": N,
#     "filed":   [ { "index": 1, "issue": M, "linked": true, "reused": bool }, … ],
#     "stopped": [ { "index": 2, "verdict": { …size-check verdict… } }, … ],
#     "edges":   [ { "issue": M, "ref": "#K" | "owner/repo#K",
#                    "status": "added" | "present" | "refused" | "failed",
#                    "detail": null | "why" }, … ],
#     "relabelled": bool, "commented": bool,
#     "error": null | "what failed" }
# `index` is the child's 1-based position in the plan (a `blocked_by` sibling
# index is 0-based).
#
# gh is reached through $GH_BIN (default `gh`), the test seam; the edge writer
# through $EDGES_BIN (default add-blocked-by-edges.zsh beside this script).
#
# Exit codes:
#   0 — every child filed and attached, the original relabelled, the trail posted.
#   1 — at least one child's inventory stops the size check, or `blocked_by`
#       forms a sibling cycle or names an index outside the plan; nothing was
#       written.
#   2 — usage error (unknown/dangling flag, a missing or unreadable plan, a
#       --parent that is not a positive integer). Nothing on stdout.
#   3 — runtime error before any write: a malformed plan, a size check that
#       errored, the original's sub-issues unreadable, jq missing. Nothing on
#       stdout.
#   5 — partial: writes started and one failed; the report names what landed.
#
# Usage:
#   file-split-children.zsh --repo OWNER/NAME --parent N --plan <plan.json>
#                           [--manifest <marketplace.json>]
# Run it from the repository root, as size-check.zsh expects.

emulate -L zsh
set -uo pipefail

local -r size_check="${0:A:h}/size-check.zsh"
local edges_bin="${EDGES_BIN:-${0:A:h}/add-blocked-by-edges.zsh}"
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
    elif any(.children[]; has("blocked_by") and (.blocked_by | type) != "array")
      then "blocked_by must be an array"
    elif any(.children[].blocked_by[]?;
             if type == "number" then . != floor
             elif type == "string" then test("^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[1-9][0-9]*$") | not
             else true end)
      then "every blocked_by item must be a sibling index or #N / owner/repo#N"
    else "" end
  end' "$plan" 2>/dev/null)" \
  || { print -u2 "file-split-children.zsh: the plan is not valid JSON"; exit 3; }
[[ -z "$problem" ]] || { print -u2 "file-split-children.zsh: malformed plan: $problem"; exit 3; }

local work
work="$(mktemp -d)" || { print -u2 "file-split-children.zsh: no temp dir"; exit 3; }
trap 'rm -rf "$work"' EXIT

local -i count i
count="$(jq '.children | length' "$plan")"

local -a filed=() stopped=() edges=()
_report() {  # $1 relabelled, $2 commented, $3 error ("" for none)
  jq -nc --argjson parent "$parent" \
    --argjson filed "[${(j:,:)filed}]" --argjson stopped "[${(j:,:)stopped}]" \
    --argjson edges "[${(j:,:)edges}]" \
    --argjson relabelled "$1" --argjson commented "$2" --arg error "$3" \
    '{parent: $parent, filed: $filed, stopped: $stopped, edges: $edges,
      relabelled: $relabelled, commented: $commented,
      error: (if $error == "" then null else $error end)}'
}

# --- 0. the sibling order must be satisfiable -------------------------------
local refusal
refusal="$(jq -r '
  . as $p | ($p.children | length) as $n
  | def succ($i): [$p.children[$i].blocked_by[]? | numbers];
    def reach($s): $s | until(([.[], (.[] | succ(.)[])] | unique) == .;
                               [.[], (.[] | succ(.)[])] | unique);
    ([range(0; $n) as $i | succ($i)[] | select(. < 0 or . >= $n)] | unique) as $bad
  | if ($bad | length) > 0 then
      "blocked_by names an index outside the plan: \($bad | map(tostring) | join(", "))"
    else
      [range(0; $n) as $i | select(reach(succ($i) | unique) | index([$i])) | $i] as $cyc
      | if ($cyc | length) > 0 then
          "blocked_by forms a cycle among the children at indexes \($cyc | map(tostring) | join(", "))"
        else "" end
    end' "$plan")" \
  || { print -u2 "file-split-children.zsh: the blocked_by order could not be checked"; exit 3; }
if [[ -n "$refusal" ]]; then
  _report false false "$refusal"
  exit 1
fi

# --- 1. size-check every child before any write ----------------------------
local -a args=()
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

if (( ${#stopped} > 0 )); then
  _report false false ""
  exit 1
fi

# --- 2. file and attach each child ------------------------------------------
# The original's current sub-issues, `<number>\t<title>` a line: a plan child
# whose title is already one of them was filed by an earlier run and is reused.
local subs
subs="$("$gh_bin" api --paginate "repos/$repo/issues/$parent/sub_issues" \
          --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null)" \
  || { print -u2 "file-split-children.zsh: reading the sub-issues of #$parent failed"; exit 3; }
local -A sub_by_title=()
local line
for line in ${(f)subs}; do
  [[ "$line" == <1->$'\t'* ]] && sub_by_title[${line#*$'\t'}]="${line%%$'\t'*}"
done

"$gh_bin" label create needs-refinement --repo "$repo" --color d4c5f9 \
  --description "Sent back by the readiness gate — needs clarification before implementation" \
  >/dev/null 2>&1 || true
"$gh_bin" label create epic --repo "$repo" --color 5319E7 \
  --description "Parent issue with a task list of children" >/dev/null 2>&1 || true

local title url num out id
local -a ids
local -a nums=()
for (( i = 1; i <= count; i++ )); do
  title="$(jq -r --argjson i "$i" '.children[$i - 1].title' "$plan")"
  if [[ -n "${sub_by_title[$title]:-}" ]]; then
    nums[i]="${sub_by_title[$title]}"
    filed+=("$(jq -nc --argjson i "$i" --argjson n "$nums[i]" '{index: $i, issue: $n, linked: true, reused: true}')")
    continue
  fi
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
    filed+=("$(jq -nc --argjson i "$i" --argjson n "$num" '{index: $i, issue: $n, linked: false, reused: false}')")
    _report false false "resolving the id of #$num failed: ${out//[^[:print:]]/?}"
    exit 5
  fi
  ids=( ${(M)${(f)out}:#<->} )
  if (( ${#ids} != 1 )) || ! "$gh_bin" api -X POST "repos/$repo/issues/$parent/sub_issues" \
        -F sub_issue_id="$ids[1]" >/dev/null 2>&1; then
    filed+=("$(jq -nc --argjson i "$i" --argjson n "$num" '{index: $i, issue: $n, linked: false, reused: false}')")
    _report false false "attaching #$num as a sub-issue of #$parent failed"
    exit 5
  fi
  nums[i]="$num"
  filed+=("$(jq -nc --argjson i "$i" --argjson n "$num" '{index: $i, issue: $n, linked: true, reused: false}')")
done

# --- 3. declare every child's prerequisites as native blockedBy edges -------
local parent_blockers
if ! parent_blockers="$("$gh_bin" api --paginate "repos/$repo/issues/$parent/dependencies/blocked_by" \
        --jq '.[] | select(.state == "open")
              | ((.repository_url | sub("^.*/repos/"; "")) + "#" + (.number | tostring))' 2>&1)"; then
  _report false false "reading the open blockers of #$parent failed: ${parent_blockers//[^[:print:]]/?}"
  exit 5
fi
local -a inherited=( ${(f)parent_blockers} )
local siblings report
local -i erc
local -a failed_edges=()
for (( i = 1; i <= count; i++ )); do
  # sibling indexes -> "#<filed number>"; references kept as they are
  jq -c --argjson i "$i" --argjson nums "[${(j:,:)nums}]" --argjson inh "$(jq -nc '$ARGS.positional' --args "${inherited[@]}")" '
    (.children[$i - 1].blocked_by // []) as $b
    | [$b[] | if type == "number" then "#\($nums[.])" else . end]
      + (if any($b[]; type == "number") then [] else $inh end)' "$plan" > "$work/refs-$i.json"
  report="$(GH_BIN="$gh_bin" zsh "$edges_bin" --repo "$repo" --issue "$nums[i]" \
              --refs "$work/refs-$i.json" --no-cycle-check 2>"$work/edges-err-$i")"
  erc=$?
  if [[ -n "$report" ]] && jq -e '.edges | type == "array"' <<< "$report" >/dev/null 2>&1; then
    edges+=( ${(f)"$(jq -c --argjson n "$nums[i]" '.edges[] | {issue: $n} + .' <<< "$report")"} )
  fi
  if (( erc != 0 )); then
    if [[ -n "$report" ]]; then
      failed_edges+=( ${(f)"$(jq -r --argjson n "$nums[i]" \
        '.edges[] | select(.status != "added" and .status != "present")
         | "#\($n) blockedBy \(.ref) (\(.status): \(.detail // "no detail"))"' <<< "$report" 2>/dev/null)"} )
    else
      failed_edges+=("the edges of #$nums[i] (exit $erc: $(tr -cd '[:print:]' < "$work/edges-err-$i"))")
    fi
  fi
done
if (( ${#failed_edges} > 0 )); then
  _report false false "adding blockedBy edges failed: ${(j:; :)failed_edges}"
  exit 5
fi

# --- 4. relabel the original, then post the trail ---------------------------
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
    print -r -- "- #$nums[i] — $(jq -r --argjson i "$i" '.children[$i - 1].title' "$plan")$(jq -r --argjson n "$nums[i]" \
      '[.[] | select(.issue == $n) | .ref] | if length > 0 then " (blocked by \(join(", ")))" else "" end' <<< "[${(j:,:)edges}]")"
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
