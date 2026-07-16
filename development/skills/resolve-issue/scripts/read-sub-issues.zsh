#!/usr/bin/env zsh
# read-sub-issues.zsh — the shared reader for GitHub-native epic→child
# parenthood (#802), mirroring read-dependencies.zsh (#584) in shape and
# conventions.
#
# Why: native **sub-issues** are the single source of truth for which issues
# are an epic's children — the same contract #583 established for dependencies
# via `blockedBy`. The markdown task list in an epic's body stays as the
# human-readable view but is never authoritative: markdown parsing cannot
# distinguish "no children were ever filed" from "all children are closed"
# (both yield zero — #798's failure mode), while `subIssuesSummary` answers it
# deterministically. Every parenthood consumer — resolve-issue's E1,
# refine-issue's epic walk — reads through this one helper so enumeration
# semantics can never drift between them.
#
# Usage (exactly one direction):
#   read-sub-issues.zsh --repo OWNER/NAME --epic N    # epic → children
#   read-sub-issues.zsh --repo OWNER/NAME --child N   # child → parent epic
#
# --epic emits one JSON object on stdout:
#   {
#     "epic": N,
#     "summary": { "total": T, "completed": C },   # subIssuesSummary
#     "children": [                                # native sub-issues, in
#       { "number": M, "state": "OPEN"|"CLOSED",   # sub-issue list order
#         "open": bool, "repo": "owner/name" } ],
#     "open_children": [numbers]                   # open AND same-repo, same order
#   }
#   summary.total == 0 means the epic has NO native children — never
#   decomposed, or not yet backfilled (backfill-sub-issues.zsh). The caller
#   must halt, not conclude "done" (#798).
#
#   Sub-issues may live in another repository. Each child carries its `repo`
#   so a consumer never resolves a foreign number against --repo;
#   `open_children` (the work-list consumers iterate) contains only SAME-repo
#   open children, and any cross-repo child is noted on stderr.
#
# --child emits:
#   { "child": N, "parent": { "number": P, "state": "OPEN"|"CLOSED",
#                             "open": bool, "repo": "owner/name" } }  # exit 0
#   { "child": N, "parent": null }                  # typed no-parent, exit 3
#   The parent lookup is GraphQL-only (`Issue.parent`); the REST issue payload
#   has no parent field. A cross-repo parent is visible via its `repo` field.
#
# Children are read via `subIssues(first:100)` — the same page-size convention
# as read-dependencies.zsh; an epic with more than 100 children is beyond any
# sane decomposition and out of contract.
#
# Seams (for tests / non-PATH installs):
#   GH_BIN  overrides the `gh` binary (must accept `api graphql` and print the
#           raw GraphQL response JSON).
#
# Exit codes:
#   0  success — result JSON on stdout
#   2  usage error
#   3  --child only: the issue has no parent (JSON still emitted on stdout)
#   1  internal error (gh / GraphQL / jq failed, or the issue doesn't exist)

emulate -L zsh
setopt nounset pipefail

local gh_bin="${GH_BIN:-gh}"

die_usage() { print -u2 -- "$1"; exit 2 }

local repo="" epic="" child=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) (( $# >= 2 )) || die_usage "--repo needs a value"; repo="$2"; shift 2 ;;
  --epic) (( $# >= 2 )) || die_usage "--epic needs a value"; epic="$2"; shift 2 ;;
  --child) (( $# >= 2 )) || die_usage "--child needs a value"; child="$2"; shift 2 ;;
  -h|--help)
    print -r -- "usage: read-sub-issues.zsh --repo OWNER/NAME (--epic N | --child N)"; exit 0 ;;
  *) die_usage "unknown argument: $1" ;;
  esac
done
[[ -n "$repo" ]] || die_usage "--repo OWNER/NAME is required"
[[ "$repo" == */* ]] || die_usage "--repo must be OWNER/NAME, got: $repo"
if [[ -n "$epic" && -n "$child" ]]; then
  die_usage "--epic and --child are mutually exclusive"
fi
[[ -n "$epic" || -n "$child" ]] || die_usage "one of --epic N or --child N is required"
local number="${epic:-$child}"
[[ "$number" == <-> ]] || die_usage "the issue number must be numeric, got: $number"
local owner="${repo%%/*}" name="${repo#*/}"

if [[ -n "$epic" ]]; then
  # epic → children: subIssuesSummary + the native sub-issue list, in order.
  local raw
  raw=$("$gh_bin" api graphql \
    -f query='query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){
        issue(number:$number){
          number
          subIssuesSummary{total completed}
          subIssues(first:100){nodes{number state repository{nameWithOwner}}}
        }
      }
    }' \
    -f owner="$owner" -f name="$name" -F number="$number" 2>/dev/null) || {
    print -u2 -- "read-sub-issues: gh api graphql failed for issue #$number"; exit 1
  }
  local result
  result=$(print -r -- "$raw" | jq -ce --arg repo "$repo" '
    .data.repository.issue
    | if . == null then error("issue not found") else . end
    | { epic: .number,
        summary: { total: .subIssuesSummary.total,
                   completed: .subIssuesSummary.completed },
        children: [.subIssues.nodes[] | select(. != null)
                   | {number, state, open: (.state == "OPEN"),
                      repo: (.repository.nameWithOwner // "")}],
        open_children: [.subIssues.nodes[] | select(. != null)
                        | select(.state == "OPEN"
                                 and (.repository.nameWithOwner // ""
                                      | ascii_downcase) == ($repo | ascii_downcase))
                        | .number] }' 2>/dev/null) || {
    print -u2 -- "read-sub-issues: issue #$number not found in $repo (or unparseable response)"
    exit 1
  }
  print -r -- "$result"
  # cross-repo children never enter open_children — surface them, don't hide them
  local foreign
  foreign=$(print -r -- "$result" | jq -r --arg repo "$repo" \
    '[.children[] | select((.repo // "" | ascii_downcase) != ($repo | ascii_downcase))
      | "\(.repo)#\(.number)"] | join(", ")')
  [[ -n "$foreign" ]] && print -u2 -- "read-sub-issues: note — cross-repo sub-issues excluded from open_children: $foreign"
  exit 0
fi

# child → parent: GraphQL Issue.parent (the only direction the API offers a
# single-query lookup for — REST has no parent field).
local raw
raw=$("$gh_bin" api graphql \
  -f query='query($owner:String!,$name:String!,$number:Int!){
    repository(owner:$owner,name:$name){
      issue(number:$number){
        number
        parent{number state repository{nameWithOwner}}
      }
    }
  }' \
  -f owner="$owner" -f name="$name" -F number="$number" 2>/dev/null) || {
  print -u2 -- "read-sub-issues: gh api graphql failed for issue #$number"; exit 1
}
local result
result=$(print -r -- "$raw" | jq -ce '
  .data.repository.issue
  | if . == null then error("issue not found") else . end
  | { child: .number,
      parent: (if .parent == null then null
               else {number: .parent.number, state: .parent.state,
                     open: (.parent.state == "OPEN"),
                     repo: .parent.repository.nameWithOwner} end) }' 2>/dev/null) || {
  print -u2 -- "read-sub-issues: issue #$number not found in $repo (or unparseable response)"
  exit 1
}
print -r -- "$result"
# The typed no-parent exit: callers branch on 3 without parsing anything.
[[ "$(print -r -- "$result" | jq -r '.parent == null')" == "true" ]] && exit 3
exit 0
