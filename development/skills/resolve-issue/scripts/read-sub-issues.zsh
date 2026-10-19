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
#   read-sub-issues.zsh --repo OWNER/NAME --tree N    # the whole sub-issue tree (#2857)
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
# --tree walks native sub-issues depth-first from issue N (the target, depth 0)
# and emits one JSON object:
#   { "root": N, "limit": L,
#     "nodes": [                                   # pre-order, sub-issue order
#       { "number": M, "state": "OPEN"|"CLOSED", "open": bool,
#         "repo": "owner/name",
#         "labels": [names] | null,                # null: the node was not read
#         "depth": D,                              # 0 for the root
#         "path": [N, …, M],                       # root → node, inclusive
#         "parent": P | null,                      # null for the root
#         "total": T | null, "completed": C | null,# subIssuesSummary; null: unread
#         "kind": "inner"|"leaf"|"undecomposed"|"read_failed"|"foreign" } ],
#     "over_limit": { "path": [...], "limit": L } # exit 5 only
#   }
#   Each node's labels, body and subIssuesSummary come from ONE GraphQL query
#   per node. kind is decided in this order, so every node gets exactly one:
#     1. foreign       its repo differs from --repo (case-insensitive, as
#                      --epic compares), whatever its state or total. Never
#                      read or descended into; noted on stderr as owner/name#M.
#                      Not a leaf: a consumer never gates, builds or counts it.
#     2. read_failed   a same-repo node below the root whose read failed. The
#                      walk continues, so every failure is listed.
#     3. inner         total > 0, open or closed.
#     4. leaf          closed with total == 0 (a closed node is never
#                      undecomposed).
#     5. undecomposed  open, total == 0, below the target, and carrying the
#                      `epic` label or a child declaration in its body by the
#                      #1260 rule read-dependencies.zsh codifies. Every other
#                      open total == 0 node is a leaf.
#   Closed nodes are read (for their total) but never descended into, so a
#   re-run skips closed subtrees. A native sub-issue has exactly one parent, so
#   the tree has no cycle and the depth limit is the walk's only guard.
#
#   The depth limit is RESOLVE_ISSUE_MAX_EPIC_DEPTH, the most levels allowed
#   below the target: unset → 4; an integer 1..8 (GitHub caps nesting at 8) →
#   that value; anything else → exit 4 before any gh call, never the default.
#   An open inner node AT the limit has children below it, so the tree is
#   deeper than the limit: the walk does not descend there, and the document
#   carries `over_limit` naming the first such path (that node plus its first
#   child, the deepest path a walk bounded by the limit can see), exit 5.
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
#   4  --tree only: RESOLVE_ISSUE_MAX_EPIC_DEPTH is set to an invalid value
#      (nothing on stdout, no gh call made)
#   5  --tree only: the tree is deeper than the limit (JSON, with over_limit,
#      still emitted on stdout)
#   1  internal error (gh / GraphQL / jq failed, or the issue doesn't exist;
#      for --tree, a failed read of the ROOT, since a node below it is
#      read_failed instead)

emulate -L zsh
setopt nounset pipefail

local gh_bin="${GH_BIN:-gh}"

die_usage() { print -u2 -- "$1"; exit 2 }

local repo="" epic="" child="" tree=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) (( $# >= 2 )) || die_usage "--repo needs a value"; repo="$2"; shift 2 ;;
  --epic) (( $# >= 2 )) || die_usage "--epic needs a value"; epic="$2"; shift 2 ;;
  --child) (( $# >= 2 )) || die_usage "--child needs a value"; child="$2"; shift 2 ;;
  --tree) (( $# >= 2 )) || die_usage "--tree needs a value"; tree="$2"; shift 2 ;;
  -h|--help)
    print -r -- "usage: read-sub-issues.zsh --repo OWNER/NAME (--epic N | --child N | --tree N)"; exit 0 ;;
  *) die_usage "unknown argument: $1" ;;
  esac
done
[[ -n "$repo" ]] || die_usage "--repo OWNER/NAME is required"
[[ "$repo" == */* ]] || die_usage "--repo must be OWNER/NAME, got: $repo"
local -i directions=0
[[ -n "$epic" ]] && (( directions++ ))
[[ -n "$child" ]] && (( directions++ ))
[[ -n "$tree" ]] && (( directions++ ))
if (( directions > 1 )); then
  die_usage "--epic, --child and --tree are mutually exclusive"
fi
(( directions == 1 )) || die_usage "one of --epic N, --child N or --tree N is required"
local number="${epic:-${child:-$tree}}"
[[ "$number" == <-> ]] || die_usage "the issue number must be numeric, got: $number"
local owner="${repo%%/*}" name="${repo#*/}"

if [[ -n "$tree" ]]; then
  # The limit is validated before any gh call, and an invalid value never falls
  # back to the default: a mistyped override would otherwise walk to a depth
  # its author never chose.
  local -i limit=4
  if (( ${+RESOLVE_ISSUE_MAX_EPIC_DEPTH} )); then
    if [[ "$RESOLVE_ISSUE_MAX_EPIC_DEPTH" == [1-8] ]]; then
      limit=$RESOLVE_ISSUE_MAX_EPIC_DEPTH
    else
      print -u2 -- "read-sub-issues: RESOLVE_ISSUE_MAX_EPIC_DEPTH must be an integer from 1 to 8, got: '$RESOLVE_ISSUE_MAX_EPIC_DEPTH'"
      exit 4
    fi
  fi

  # One node's read, in ONE query: its labels, its body (only the #1260 verdict
  # leaves jq), its subIssuesSummary and its sub-issue list.
  _read_node() {
    local raw
    raw=$("$gh_bin" api graphql \
      -f query='query($owner:String!,$name:String!,$number:Int!){
        repository(owner:$owner,name:$name){
          issue(number:$number){
            number state body
            labels(first:100){nodes{name}}
            subIssuesSummary{total completed}
            subIssues(first:100){nodes{number state repository{nameWithOwner}}}
          }
        }
      }' \
      -f owner="$owner" -f name="$name" -F number="$1" 2>/dev/null) || return 1
    print -r -- "$raw" | jq -ce '
      # The #1260 child-declaration rule exactly as read-dependencies.zsh
      # states and owns it: a start-anchored ref, fence-aware with the opener
      # tracked. tests/read-sub-issues.bats pins the two copies identical.
      def is_child_decl:
        test("^[ \t]*[-*+][ \t]+\\[[ xX]\\][ \t]+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+\\b");
      def has_child_task_list:
        ((. // "") | split("\n") | map(sub("\r$"; ""))
         | reduce .[] as $line ({fence: null, found: false};
             (($line | capture("^[ \t]*(?<run>```+|~~~+)(?<rest>.*)$")) // {run: "", rest: ""}) as $f
             | if ($f.run | length) > 0 then
                 if .fence == null then .fence = {ch: $f.run[0:1], len: ($f.run | length)}
                 elif ($f.run[0:1] == .fence.ch) and (($f.run | length) >= .fence.len)
                      and ($f.rest | test("^[ \t]*$")) then .fence = null
                 else . end
               elif .fence != null then .
               elif ($line | is_child_decl) then .found = true
               else . end)
         | .found);
      .data.repository.issue
      | if . == null then error("issue not found") else . end
      | { number, state,
          labels: [.labels.nodes[].name],
          total: .subIssuesSummary.total, completed: .subIssuesSummary.completed,
          declares_children: (.body | has_child_task_list),
          children: [.subIssues.nodes[] | select(. != null)
                     | {number, state, repo: (.repository.nameWithOwner // "")}] }' 2>/dev/null
  }

  local -a tree_nodes=() foreign_refs=()
  local over_limit=""

  # _unread_node NUMBER STATE REPO DEPTH PATH PARENT KIND — a node listed from
  # its parent's sub-issue list and never read (foreign or read_failed).
  _unread_node() {
    jq -cn --argjson n "$1" --arg s "$2" --arg r "$3" --argjson d "$4" \
      --argjson p "$5" --argjson par "$6" --arg k "$7" \
      '{number:$n, state:$s, open:($s == "OPEN"), repo:$r, labels:null, depth:$d,
        path:$p, parent:$par, total:null, completed:null, kind:$k}'
  }

  # _walk NUMBER PARENT DEPTH PATH LISTED_STATE LISTED_REPO, pre-order. The
  # LISTED_* values are what the parent's sub-issue list said (empty at the
  # root). Returns 1 only for a failed read of the root.
  # (never name a local `path`: zsh ties it to $PATH, and gh would vanish)
  _walk() {
    local n=$1 parent=$2 depth=$3 node_path=$4 lstate=$5 lrepo=$6
    if [[ -n "$lrepo" && "${lrepo:l}" != "${repo:l}" ]]; then
      foreign_refs+=("$lrepo#$n")
      tree_nodes+=("$(_unread_node $n "$lstate" "$lrepo" $depth "$node_path" $parent foreign)")
      return 0
    fi
    local node
    if ! node=$(_read_node $n); then
      (( depth == 0 )) && return 1
      tree_nodes+=("$(_unread_node $n "$lstate" "$repo" $depth "$node_path" $parent read_failed)")
      return 0
    fi
    tree_nodes+=("$(print -r -- "$node" | jq -c --arg r "${lrepo:-$repo}" \
      --argjson d $depth --argjson p "$node_path" --argjson par $parent '
      (.state == "OPEN") as $open
      | {number, state, open: $open, repo: $r, labels, depth: $d, path: $p,
         parent: $par, total, completed,
         kind: (if .total > 0 then "inner"
                elif ($open | not) then "leaf"
                elif $d > 0 and ((.labels | index("epic")) != null or .declares_children)
                  then "undecomposed"
                else "leaf" end)}')")
    # descend only into an OPEN inner node: a closed subtree is finished work
    [[ "$(print -r -- "$node" | jq -r '.state == "OPEN" and .total > 0')" == "true" ]] || return 0
    local -a kids=("${(@f)$(print -r -- "$node" | jq -r '.children[] | "\(.number) \(.state) \(.repo)"')}")
    if (( depth >= limit )); then
      [[ -n "$over_limit" ]] || over_limit=$(print -r -- "$node_path" \
        | jq -c --arg k "${kids[1]%% *}" --argjson l $limit \
            '{path: (if $k == "" then . else . + [$k | tonumber] end), limit: $l}')
      return 0
    fi
    local kid
    local -a f
    for kid in "${kids[@]}"; do
      [[ -n "$kid" ]] || continue
      f=(${(s: :)kid})
      _walk ${f[1]} $n $(( depth + 1 )) \
        "$(print -r -- "$node_path" | jq -c --argjson k ${f[1]} '. + [$k]')" "${f[2]}" "${f[3]}"
    done
  }

  _walk $number null 0 "[$number]" "" "" || {
    print -u2 -- "read-sub-issues: issue #$number not found in $repo (or its read failed)"
    exit 1
  }
  print -r -- "${(F)tree_nodes}" | jq -cs --argjson root $number --argjson limit $limit \
    --argjson over "${over_limit:-null}" '
    {root: $root, limit: $limit, nodes: .}
    + (if $over == null then {} else {over_limit: $over} end)' || {
    print -u2 -- "read-sub-issues: failed to assemble the tree document"; exit 1
  }
  # a foreign node is listed, never read: surface it, don't hide it
  (( ${#foreign_refs} )) && print -u2 -- "read-sub-issues: note — cross-repo sub-issues listed as foreign, not read: ${(j:, :)foreign_refs}"
  [[ -n "$over_limit" ]] && exit 5
  exit 0
fi

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
