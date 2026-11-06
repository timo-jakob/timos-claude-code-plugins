#!/usr/bin/env zsh
# add-blocked-by-edges.zsh — declare an issue's prerequisites as GitHub-native
# `blockedBy` edges (#2947).
#
# Native `blockedBy` is the only source of truth for a dependency
# (ARCHITECTURE.md, *Issue-dependency model*). A prerequisite refinement finds
# in a story's prose, or a split states between its children, is therefore
# written here as an edge rather than left in prose, where the readiness gate's
# check 3 would keep rejecting it. refine-issue runs this after Step 3's
# write-back with the approved `proposed_blocked_by`, and file-split-children.zsh
# runs it for every child it files.
#
# Per ref, in order:
#   1. a self-reference is refused;
#   2. an edge that already exists is skipped (`present`), so a re-run adds only
#      what is missing;
#   3. unless --no-cycle-check, an edge that would close a cycle is refused: the
#      new edge "N blockedBy M" closes one exactly when N is already among M's
#      transitive blockers, which read-dependencies.zsh walks. A walk that fails,
#      or stops at its depth cap without finding N, cannot prove the edge safe
#      and refuses it too (fail-closed). The reader does not recurse into a
#      CLOSED blocker, so a cycle running through a closed issue is not seen;
#   4. the target's database id is resolved and the edge is POSTed. Either
#      failing — a permissions error on a cross-repo target, say — is reported
#      as `failed`, never dropped silently.
#
# --refs names a file holding one JSON array of issue references, each `#M` or
# `owner/repo#M`. A ref into --repo itself is normalised to `#M`; duplicates are
# dropped. An empty array is valid and adds nothing.
#
# Output — one JSON object on stdout for exits 0, 4 and 5:
#   { "issue": N,
#     "edges": [ { "ref": "#M" | "owner/repo#M",
#                  "status": "added" | "present" | "refused" | "failed",
#                  "detail": null | "why" }, … ] }
#
# gh is reached through $GH_BIN (default `gh`) and the reader through
# $READ_DEPS_BIN (default resolve-issue's read-dependencies.zsh), the test seams.
#
# Exit codes:
#   0 — every edge added or already present.
#   2 — usage error (unknown/dangling flag, a missing or unreadable --refs, an
#       --issue that is not a positive integer). Nothing on stdout.
#   3 — runtime error before any write: jq missing, --refs not one JSON array of
#       well-formed references, the issue's existing edges unreadable. Nothing
#       on stdout.
#   4 — at least one edge refused (self, cycle, unprovable), none failed.
#   5 — at least one edge failed to resolve or write; the report names it.
#
# Usage:
#   add-blocked-by-edges.zsh --repo OWNER/NAME --issue N --refs <refs.json>
#                            [--no-cycle-check]

emulate -L zsh
set -uo pipefail

local gh_bin="${GH_BIN:-gh}"
local reader="${READ_DEPS_BIN:-${0:A:h}/../../resolve-issue/scripts/read-dependencies.zsh}"

local repo="" issue="" refs="" cycle_check=1
while (( $# > 0 )); do
  case "$1" in
    --repo|--issue|--refs)
      (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] \
        || { print -u2 "add-blocked-by-edges.zsh: $1 needs a value"; exit 2; }
      case "$1" in
        --repo) repo="$2" ;; --issue) issue="$2" ;; --refs) refs="$2" ;;
      esac
      shift 2 ;;
    --no-cycle-check) cycle_check=0; shift ;;
    -h|--help)
      print -u2 -r -- "usage: add-blocked-by-edges.zsh --repo OWNER/NAME --issue N --refs <refs.json> [--no-cycle-check]"
      print -u2 -r -- "exit 0 all landed, 2 usage, 3 runtime, 4 an edge refused, 5 an edge failed."
      exit 0 ;;
    *) print -u2 "add-blocked-by-edges.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

[[ "$repo" == ?*/?* && "$repo" != */*/* ]] \
  || { print -u2 "add-blocked-by-edges.zsh: --repo OWNER/NAME is required"; exit 2; }
[[ "$issue" == <1-> ]] \
  || { print -u2 "add-blocked-by-edges.zsh: --issue must be a positive integer"; exit 2; }
[[ -n "$refs" && -f "$refs" && -r "$refs" ]] \
  || { print -u2 "add-blocked-by-edges.zsh: --refs not found or unreadable: ${refs:-<none>}"; exit 2; }
command -v jq >/dev/null 2>&1 || { print -u2 "add-blocked-by-edges.zsh: jq not found on PATH"; exit 3; }

# One JSON array of well-formed refs, normalised (own repo -> #M) and deduped.
local norm
norm="$(jq -cs --arg repo "${repo:l}" '
  if length != 1 or (.[0] | type) != "array" then error("not one JSON array")
  elif any(.[0][]; type != "string" or (test("^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[1-9][0-9]*$") | not))
    then error("every ref must be #N or owner/repo#N")
  else [.[0][] | if (ascii_downcase | startswith($repo + "#")) then "#" + (split("#")[1]) else . end]
       | reduce .[] as $r ([]; if index([$r]) then . else . + [$r] end)
  end' "$refs" 2>/dev/null)" \
  || { print -u2 "add-blocked-by-edges.zsh: --refs must hold one JSON array of #N or owner/repo#N refs"; exit 3; }

# The issue's existing blockers, as lowercase `owner/repo#M` keys.
local existing
existing="$("$gh_bin" api --paginate "repos/$repo/issues/$issue/dependencies/blocked_by" \
              --jq '.[] | ((.repository_url | sub("^.*/repos/"; "")) + "#" + (.number | tostring))' 2>/dev/null)" \
  || { print -u2 "add-blocked-by-edges.zsh: reading the existing blockers of #$issue failed"; exit 3; }
local -a have=( ${(f)${existing:l}} )

local -a edges=()
local -i refused=0 failed=0
_edge() {  # $1 ref, $2 status, $3 detail ("" for none)
  edges+=("$(jq -nc --arg r "$1" --arg s "$2" --arg d "$3" \
    '{ref: $r, status: $s, detail: (if $d == "" then null else $d end)}')")
}

local ref slug num key deps hit out
local -a ids
for ref in ${(f)"$(jq -r '.[]' <<< "$norm")"}; do
  if [[ "$ref" == \#* ]]; then slug="$repo"; num="${ref#\#}"
  else slug="${ref%%\#*}"; num="${ref##*\#}"; fi
  key="${slug:l}#$num"

  if [[ "${slug:l}" == "${repo:l}" && "$num" == "$issue" ]]; then
    _edge "$ref" refused "an issue cannot block itself"; (( refused++ )); continue
  fi
  if (( ${have[(Ie)$key]} )); then
    _edge "$ref" present ""; continue
  fi

  if (( cycle_check )); then
    if ! deps="$(zsh "$reader" --repo "$slug" --issue "$num" 2>/dev/null)"; then
      _edge "$ref" refused "the cycle check could not read the blockers of $ref"; (( refused++ )); continue
    fi
    if [[ "${slug:l}" == "${repo:l}" ]]; then
      hit="$(jq -r --argjson n "$issue" 'any(.blockers[]?; .number == $n)' <<< "$deps" 2>/dev/null)"
    else
      hit="$(jq -r --arg k "${repo:l}#$issue" 'any(.foreign_blockers[]?; (.ref | ascii_downcase) == $k)' <<< "$deps" 2>/dev/null)"
    fi
    if [[ "$hit" == true ]]; then
      _edge "$ref" refused "would close a cycle: #$issue already blocks $ref"; (( refused++ )); continue
    fi
    if [[ "$hit" != false ]] || [[ "$(jq -r '.truncated' <<< "$deps" 2>/dev/null)" != false ]]; then
      _edge "$ref" refused "the cycle check could not prove $ref acyclic"; (( refused++ )); continue
    fi
  fi

  if ! out="$("$gh_bin" api "repos/$slug/issues/$num" --jq .id 2>&1)"; then
    _edge "$ref" failed "resolving $ref failed: ${out//[^[:print:]]/?}"; (( failed++ )); continue
  fi
  ids=( ${(M)${(f)out}:#<->} )
  if (( ${#ids} != 1 )); then
    _edge "$ref" failed "resolving $ref returned no issue id"; (( failed++ )); continue
  fi
  if ! out="$("$gh_bin" api -X POST "repos/$repo/issues/$issue/dependencies/blocked_by" \
                -F issue_id="$ids[1]" 2>&1 >/dev/null)"; then
    _edge "$ref" failed "adding #$issue blockedBy $ref failed: ${out//[^[:print:]]/?}"; (( failed++ )); continue
  fi
  _edge "$ref" added ""
done

jq -nc --argjson issue "$issue" --argjson edges "[${(j:,:)edges}]" '{issue: $issue, edges: $edges}'
(( failed == 0 )) || exit 5
(( refused == 0 )) || exit 4
exit 0
