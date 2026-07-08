#!/usr/bin/env zsh
# read-dependencies.zsh — the shared reader for GitHub-native issue
# dependencies (epic #583, issue #584).
#
# Why: `resolve-issue` enforces dependencies only when they are DECLARED as
# GitHub-native `blockedBy` relationships — the single, machine-readable source
# of truth (a dependency living only in prose is a readiness-gate failure, not
# an input to this reader). Every consumer of dependency data — the readiness
# gate, the single-issue precheck (#585), the epic-as-dependency recursion
# (#587) — reads through this one helper so the traversal, classification, and
# cycle semantics can never drift between them.
#
# Usage:
#   read-dependencies.zsh --repo OWNER/NAME --issue N [--max-depth D]
#
# Emits one JSON object on stdout:
#   {
#     "issue": N,
#     "blocked": true|false,        # any OPEN blocker, directly or transitively
#     "open_blockers": [numbers],   # the open ones, dedup'd, discovery order
#     "blockers": [                 # every distinct blocker reached
#       { "number": M, "state": "OPEN"|"CLOSED", "open": bool,
#         "kind": "epic"|"issue",   # epic := `epic` label, tracked issues,
#                                   #         or a task-list body (`- [ ] #N`)
#         "depth": 1.. }            # 1 = direct blocker of the named issue
#     ],
#     "cycles": [[a,b,a], ...],     # each cycle as the path that closed it
#     "truncated": bool             # true iff --max-depth stopped traversal
#   }
#
# Traversal: depth-first over `blockedBy`, transitively. A CLOSED blocker is
# recorded but NOT recursed into — a met prerequisite's own history cannot
# block anything (so a cycle running through a closed issue is inert and goes
# unreported by design). Cycles among open issues are returned explicitly, and
# each issue is fetched exactly once.
#
# Seams (for tests / non-PATH installs):
#   GH_BIN  overrides the `gh` binary (must accept `api graphql` and print the
#           raw GraphQL response JSON).
#
# Exit codes:
#   0  success — result JSON on stdout
#   2  usage error
#   1  internal error (gh / GraphQL / jq failed, or the issue doesn't exist)

emulate -L zsh
setopt nounset pipefail

local gh_bin="${GH_BIN:-gh}"

die_usage() { print -u2 -- "$1"; exit 2 }

local repo="" issue="" max_depth=20
while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) repo="$2"; shift 2 ;;
  --issue) issue="$2"; shift 2 ;;
  --max-depth) max_depth="$2"; shift 2 ;;
  -h|--help)
    print -r -- "usage: read-dependencies.zsh --repo OWNER/NAME --issue N [--max-depth D]"; exit 0 ;;
  *) die_usage "unknown argument: $1" ;;
  esac
done
[[ -n "$repo" ]] || die_usage "--repo OWNER/NAME is required"
[[ -n "$issue" ]] || die_usage "--issue N is required"
[[ "$repo" == */* ]] || die_usage "--repo must be OWNER/NAME, got: $repo"
[[ "$issue" == <-> ]] || die_usage "--issue must be a number, got: $issue"
local owner="${repo%%/*}" name="${repo#*/}"

# One GraphQL round-trip per issue, memoized. Each node is normalized to
#   {number, state, epic, blocked_by:[numbers]}
# so the traversal below never touches raw GraphQL shapes.
typeset -A node_cache   # number -> normalized node JSON

_fetch_node() {
  local n="$1" raw
  [[ -n "${node_cache[$n]:-}" ]] && return 0
  raw=$("$gh_bin" api graphql \
    -f query='query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){
        issue(number:$number){
          number state body trackedIssuesCount
          labels(first:100){nodes{name}}
          blockedBy(first:100){nodes{number}}
        }
      }
    }' \
    -f owner="$owner" -f name="$name" -F number="$n" 2>/dev/null) || {
    print -u2 -- "read-dependencies: gh api graphql failed for issue #$n"; return 1
  }
  local node
  node=$(print -r -- "$raw" | jq -ce '
    .data.repository.issue
    | { number, state,
        epic: (([.labels.nodes[].name] | index("epic") != null)
               or (.trackedIssuesCount > 0)
               or ((.body // "") | test("(?m)^[[:space:]]*[-*][[:space:]]\\[[ xX]\\][[:space:]].*#[0-9]+"))),
        blocked_by: [.blockedBy.nodes[].number] }' 2>/dev/null) || {
    print -u2 -- "read-dependencies: issue #$n not found in $repo (or unparseable response)"
    return 1
  }
  node_cache[$n]="$node"
}

typeset -A recorded     # blocker number -> 1 (dedupe: first path wins)
typeset -A on_path      # number -> 1 (the current DFS stack, for cycles)
typeset -a chain        # the current DFS chain, root first (NB: not `path` — special in zsh)
typeset -a blocker_recs # one compact JSON object per distinct blocker
typeset -a cycle_recs   # one compact JSON array per detected cycle
local truncated=false

_walk() {  # $1 = issue number whose blockers to expand; depth = ${#chain}
  local n="$1" b node state kind depth
  (( ${#chain} >= max_depth )) && { truncated=true; return 0 }
  on_path[$n]=1
  chain+=("$n")
  local -a blockers=( ${(f)"$(print -r -- "${node_cache[$n]}" | jq -r '.blocked_by[]')"} )
  for b in "${blockers[@]}"; do
    [[ -n "$b" ]] || continue
    if [[ -n "${on_path[$b]:-}" ]]; then
      # the chain closed on itself: report the loop from b's first occurrence
      local idx=${chain[(i)$b]}
      cycle_recs+=("$(print -r -- "${(j:,:)chain[$idx,-1]},$b" | jq -Rc 'split(",") | map(tonumber)')")
      continue
    fi
    _fetch_node "$b" || return 1
    node="${node_cache[$b]}"
    state=$(print -r -- "$node" | jq -r '.state')
    if [[ -z "${recorded[$b]:-}" ]]; then
      recorded[$b]=1
      depth=${#chain}
      blocker_recs+=("$(print -r -- "$node" | jq -c --argjson depth "$depth" \
        '{number, state, open: (.state == "OPEN"), kind: (if .epic then "epic" else "issue" end), depth: $depth}')")
    fi
    # a CLOSED blocker is a met prerequisite — its own blockers can't block us
    [[ "$state" == "OPEN" ]] && { _walk "$b" || return 1 }
  done
  chain[-1]=()
  unset "on_path[$n]"
}

_fetch_node "$issue" || exit 1
_walk "$issue" || exit 1

_json_array() {  # join pre-validated compact-JSON elements into one array
  (( $# == 0 )) && { print -rn -- '[]'; return }
  print -rn -- "[${(j:,:)@}]"
}

jq -nc \
  --argjson issue "$issue" \
  --argjson blockers "$(_json_array "${blocker_recs[@]}")" \
  --argjson cycles "$(_json_array "${cycle_recs[@]}")" \
  --argjson truncated "$truncated" \
  '{ issue: $issue,
     blocked: ([$blockers[] | select(.open)] | length > 0),
     open_blockers: [$blockers[] | select(.open) | .number],
     blockers: $blockers,
     cycles: $cycles,
     truncated: $truncated }'
