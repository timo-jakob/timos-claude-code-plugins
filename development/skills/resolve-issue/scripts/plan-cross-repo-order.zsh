#!/usr/bin/env zsh
# plan-cross-repo-order.zsh — the cross-repo order of an epic's children, and
# whether one child must wait for a same-epic sibling in another repo (#3082,
# epic #3073).
#
# Why: an epic whose children live in several repos is worked one session per
# repo. The dependency precheck rejects a child on an open foreign blocker, but
# it never reads that blocker's own blockers, so it cannot say which sibling
# has to be built first, or in which repo. This script reads the epic's native
# sub-issues in every repo, with their blocked-by links, and orders them. It
# only reads and reports: it drives no repo, and the precheck stays the one
# gate that decides whether a child may start.
#
# Usage (exactly one mode):
#   plan-cross-repo-order.zsh --repo OWNER/NAME --issue N   # child mode
#   plan-cross-repo-order.zsh --repo OWNER/NAME --epic N    # epic mode
#
# --repo is the session's repo. Child mode finds issue N's parent epic with
# read-sub-issues.zsh --child (the parent may live in another repo); epic mode
# takes epic N of --repo. Both then read the epic's sub-issues in ONE GraphQL
# query, each with its repo, state and blockedBy list.
#
# Only edges BETWEEN siblings of the epic count, and only open ones: a blocker
# outside the epic is the precheck's, never this script's. Siblings are named
# `owner/name#N`.
#
# Output: one JSON object on stdout:
#   { "epic": "owner/name#E", "repo": "<--repo>",
#     "order": [refs],          # the open siblings, every blocker first, in
#                               # sub-issue order where the edges allow
#     "cycle": [refs],          # open siblings no order can place (else [])
#     "ready": [refs],          # open siblings with no open sibling blocker
#     "local_order": [numbers], # `order` restricted to --repo: what a session
#                               # here resolves, in that order
#     "next_sessions": [        # one per OTHER repo holding an open sibling
#       { "repo": "owner/name", "next": ref | null, "waits_on": [refs] } ],
#     # child mode only:
#     "issue": "owner/name#N",
#     "decision": "proceed" | "wait",
#     "wait_on": [refs],        # the open sibling blockers in OTHER repos of the
#                               # issue and of the siblings here it waits on
#     "run_first": [refs],      # the ready siblings among everything the issue
#                               # transitively waits on, in order; the line of
#                               # one the issue reaches through --repo alone
#                               # says a blockers-first run clears it, else
#                               # start it here, never "in a session on"
#     "lines": [strings] }      # the report, one line each, ready to print
#   `next` is the first ready sibling of that repo in `order`; when the repo
#   has none ready, it is null and `waits_on` names the open sibling blockers
#   of that repo's earliest sibling in `order`.
#
# Seams (for tests / non-PATH installs):
#   GH_BIN        overrides the `gh` binary (must accept `api graphql`).
#   SUB_ISSUES_BIN overrides read-sub-issues.zsh (default: beside this script).
#
# Exit codes:
#   0   epic mode: the plan. Child mode: decision `proceed`.
#   10  child mode: decision `wait` (an open same-epic blocker in another repo)
#   3   child mode: the issue has no parent epic (nothing on stdout)
#   2   usage error
#   1   internal error (gh, jq or read-sub-issues.zsh failed, or the issue is
#       not among its parent's sub-issues)

emulate -L zsh
setopt nounset pipefail

local gh_bin="${GH_BIN:-gh}"
local sub_bin="${SUB_ISSUES_BIN:-${0:A:h}/read-sub-issues.zsh}"

die_usage() { print -u2 -- "plan-cross-repo-order: $1"; exit 2 }
die() { print -u2 -- "plan-cross-repo-order: $1"; exit 1 }

local repo="" issue="" epic=""
while (( $# > 0 )); do
  case "$1" in
  --repo) (( $# >= 2 )) || die_usage "--repo needs a value"; repo="$2"; shift 2 ;;
  --issue) (( $# >= 2 )) || die_usage "--issue needs a value"; issue="$2"; shift 2 ;;
  --epic) (( $# >= 2 )) || die_usage "--epic needs a value"; epic="$2"; shift 2 ;;
  -h|--help)
    print -r -- "usage: plan-cross-repo-order.zsh --repo OWNER/NAME (--issue N | --epic N)"; exit 0 ;;
  *) die_usage "unknown argument: $1" ;;
  esac
done
[[ "$repo" =~ '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' ]] || die_usage "--repo must be OWNER/NAME, got: '$repo'"
[[ -n "$issue" && -n "$epic" ]] && die_usage "--issue and --epic are mutually exclusive"
[[ -n "$issue" || -n "$epic" ]] || die_usage "one of --issue N or --epic N is required"
[[ "${issue:-$epic}" == <-> ]] || die_usage "the issue number must be numeric, got: ${issue:-$epic}"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

local epic_repo="$repo" epic_num="$epic"
if [[ -n "$issue" ]]; then
  local parent rc=0
  parent=$(GH_BIN="$gh_bin" zsh "$sub_bin" --repo "$repo" --child "$issue" 2>/dev/null) || rc=$?
  (( rc == 3 )) && exit 3
  (( rc == 0 )) || die "read-sub-issues.zsh --child failed for #$issue (exit $rc)"
  epic_num=$(print -r -- "$parent" | jq -er '.parent.number') || die "unreadable parent of #$issue"
  epic_repo=$(print -r -- "$parent" | jq -er '.parent.repo') || die "unreadable parent of #$issue"
fi

# The planner, one jq program. Siblings are matched case-insensitively by ref,
# as read-sub-issues.zsh compares repos.
_plan_jq() {
  cat <<'JQ'
def lc: ascii_downcase;
def ref: "\(.repository.nameWithOwner // "")#\(.number)";
def num: sub("^.*#"; "");
def rrepo: sub("#[0-9]+$"; "");
.data.repository.issue
| if . == null then error("epic not found") else . end
| ($erepo + "#" + (.number | tostring)) as $epic
| [.subIssues.nodes[] | select(. != null)
   | {ref: (ref | lc), number, repo: ((.repository.nameWithOwner // "") | lc),
      open: (.state == "OPEN"),
      blockers: [.blockedBy.nodes[] | select(. != null) | select(.state == "OPEN") | ref | lc]}] as $all
| ($all | map(select(.open))) as $open0
| ($open0 | map(.ref)) as $open_refs
# sibling edges only, and never a self-edge: a blocker outside the epic is the precheck's
| ($open0 | map(.ref as $me | .blockers |= map(select(. != $me and (. as $b | $open_refs | index($b) != null))))) as $nodes
| ($nodes | map({key: .ref, value: .}) | from_entries) as $by
# Kahn, stable: place the first remaining node whose blockers are all placed
| ({order: [], rest: $nodes}
   | until((.order as $o | [.rest[] | select((.blockers - $o) == [])] | length) == 0;
       (.order as $o | [.rest[] | select((.blockers - $o) == [])][0].ref) as $pick
       | .order += [$pick] | .rest |= map(select(.ref != $pick)))
   | {order, cycle: [.rest[].ref]}) as $k
| ($k.order + $k.cycle) as $seq
| [$seq[] | select($by[.].blockers == [])] as $ready
| ($repo | lc) as $here
| ([$nodes[].repo] | reduce .[] as $r ([]; if index($r) then . else . + [$r] end)
   | map(select(. != $here))) as $others
| [$others[] as $r | [$seq[] | select($by[.].repo == $r)] as $mine
   | ([$mine[] | select(. as $x | $ready | index($x) != null)][0]) as $next
   | {repo: $r, next: $next, waits_on: (if $next == null then $by[$mine[0]].blockers else [] end)}] as $sessions
| {epic: ($epic | lc), repo: $here, order: $k.order, cycle: $k.cycle, ready: $ready,
   local_order: [$k.order[] | select($by[.].repo == $here) | $by[.].number],
   next_sessions: $sessions}
| if $target == "" then
    .lines = (["cross-repo order of \(.epic):"]
      + [range(0; $k.order | length) as $i | $k.order[$i] as $r
         | "  \($i + 1). \($r)" + (if $by[$r].blockers == [] then " — ready"
                                   else " — after \($by[$r].blockers | join(", "))" end)]
      + (if $k.cycle == [] then [] else ["  cycle: \($k.cycle | join(", ")) — no order places these"] end)
      + ["this session (\($here)) resolves: "
         + (if .local_order == [] then "none" else (.local_order | map("#\(.)") | join(", ")) end)]
      + [$sessions[] | if .next != null
           then "next session in \(.repo): /development:resolve-issue \(.next | num) (\(.next))"
           else "next session in \(.repo): none ready — waits on \(.waits_on | join(", "))" end])
  else
    ($target | lc) as $t
    | if ($all | map(.ref) | index($t)) == null then error("issue not among the epic's sub-issues") else . end
    | (($by[$t].blockers) // []) as $direct
    | ($direct | until((. + [.[] | $by[.].blockers[]] | unique) == (. | unique); . + [.[] | $by[.].blockers[]] | unique)) as $closure
    | [$seq[] | select(. as $x | ($closure | index($x)) != null and ($ready | index($x)) != null)] as $first
    # the target's blockers reachable through this repo alone: blockers-first clears these itself
    | ([$direct[] | select(rrepo == $here)]
       | until((. + [.[] | $by[.].blockers[] | select(rrepo == $here)] | unique) == (. | unique);
           . + [.[] | $by[.].blockers[] | select(rrepo == $here)] | unique)) as $cleared_here
    # the foreign siblings the precheck sees: the target's own, and those of the siblings here it waits on
    | ([([$t] + $cleared_here)[] | $by[.].blockers[] | select(rrepo != $here)]
       | reduce .[] as $r ([]; if index($r) then . else . + [$r] end)) as $wait
    | . + {issue: $t, decision: (if $wait == [] then "proceed" else "wait" end), wait_on: $wait, run_first: $first}
    | .lines = (if $wait == [] then ["\($t): no open same-epic blocker in another repo"]
      else [$wait[] | "\($t) waits on its same-epic sibling \(.) in \(rrepo)"]
        + (if $first == [] then ["run first: none ready — the siblings it waits on form a cycle"]
           else [$first[] | . as $x | if ($cleared_here | index($x)) != null
                   then "run first: \(.) — a blocker of \($t) in this session's repo: a blockers-first run clears it before the wait; otherwise start /development:resolve-issue \(num) here"
                   else "run first: \(.) — start /development:resolve-issue \(num) in a session on \(rrepo)" end] end)
      end)
  end
JQ
}

local raw
raw=$("$gh_bin" api graphql \
  -f query='query($owner:String!,$name:String!,$number:Int!){
    repository(owner:$owner,name:$name){
      issue(number:$number){
        number
        subIssues(first:100){nodes{number state repository{nameWithOwner}
          blockedBy(first:100){nodes{number state repository{nameWithOwner}}}}}
      }
    }
  }' \
  -f owner="${epic_repo%%/*}" -f name="${epic_repo#*/}" -F number="$epic_num" 2>/dev/null) \
  || die "gh api graphql failed for epic $epic_repo#$epic_num"

local plan
plan=$(print -r -- "$raw" | jq -ce --arg repo "$repo" --arg erepo "$epic_repo" \
  --arg target "${issue:+$repo#$issue}" "$(_plan_jq)" 2>/dev/null) \
  || die "unreadable sub-issues of epic $epic_repo#$epic_num, or #$issue is not among them"
print -r -- "$plan"
[[ -n "$issue" && "$(print -r -- "$plan" | jq -r '.decision')" == "wait" ]] && exit 10
exit 0
