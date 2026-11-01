#!/usr/bin/env zsh
# readiness-stamp.zsh — the readiness-verdict cache (#2954, epic #2953): compute
# a story's readiness key, find which stories carry a still-valid stamp, and
# write a stamp.
#
# Why: the `story-readiness` gate is one subagent per story and nothing
# remembered its verdict, so an epic re-run gated every leaf again even when
# nothing changed. The verdict is a function of a small, known input set; when
# none of those inputs changed, a recorded verdict answers instead. This script
# is the deterministic half: it decides hit or miss, and the skills spawn the
# gate for misses only. The contract is ARCHITECTURE.md's "Readiness stamp
# contract (`readiness-stamp/v1`)"; this header states only the mechanics.
#
# Usage (run from the repository root: `check` re-runs size-check.zsh, which
# reads the plugin roster from `.claude-plugin/marketplace.json` there):
#   readiness-stamp.zsh key   --repo OWNER/NAME --issue N
#   readiness-stamp.zsh check --repo OWNER/NAME (--epic N | --issue N)
#   readiness-stamp.zsh write --repo OWNER/NAME --issue N --verdict-file F
#
# key   prints the key: sha256 over the compact, key-sorted JSON document
#         {gate_version, title, body, blocked_by, labels}
#       where title and body are normalized (CRLF -> LF, trailing whitespace
#       stripped per line, trailing blank lines dropped), blocked_by is the
#       sorted list of the issue's own native blockedBy edges (a bare number for
#       a same-repo blocker, "owner/name#N" for a foreign one), and labels is the
#       sorted label names minus `needs-refinement` and `blocked`.
#
# check reads every target with one batched GraphQL query (100 targets per
#       query; an issue's comments are paged past 100) and prints
#         {"gate_version": G,
#          "hits":   [{"issue": N, "verdict": {…}}],
#          "misses": [{"issue": N, "reason": R}]}
#       --issue N targets N; --epic N targets the open same-repo leaves below N
#       in read-sub-issues.zsh --tree. A target is a hit only when all hold, and
#       each failure is one reason, judged in this order:
#         no_stamp          no comment's first line is a readiness-stamp/v1 marker
#         untrusted_author  stamps exist, but none by a trusted author
#         malformed         the newest trusted stamp's verdict does not parse, or
#                           carries no size.inventory
#         gate_changed      the stamp's gate differs from the current gate_version
#         key_changed       the stamp's key differs from the recomputed key
#         inventory_drift   size-check.zsh re-run on verdict.size.inventory gives
#                           a different verdict or triggers than the cached
#                           size.verdict and size.triggers, or exits 2 or 3
#       Path existence is never tested. A trusted author has authorAssociation
#       OWNER, MEMBER or COLLABORATOR, or is the repository owner's Maintenance
#       App (a Bot whose login is claude-maintenance-<owner>). The newest trusted
#       stamp by creation time is the stamp; every other comment is ignored.
#
# write validates the verdict file (one JSON object with `verdict` READY or
#       NEEDS_REFINEMENT and a `size` object carrying `verdict`, `triggers` and
#       `inventory`), computes the key at write time, then edits the newest
#       trusted stamp comment in place, or creates one when none exists, and
#       deletes any older trusted stamp so one write never leaves two. Prints
#         {"issue": N, "key": K, "gate_version": G,
#          "action": "edited"|"created", "comment_id": ID}
#
# gate_version is sha256 of the contents of this plugin's
# agents/story-readiness.md followed by skills/refine-issue/scripts/size-check.zsh,
# both resolved from this script's own path — never another installed copy. It
# is not the plugin version, which bumps on almost every PR.
#
# Seams (for tests / non-PATH installs):
#   GH_BIN  overrides the `gh` binary.
#
# Exit codes:
#   0  ok — a stamp problem, a failed size re-check included, is a miss, never
#      an exit: the caller fails toward gating
#   2  usage error, or an unreadable / invalid --verdict-file
#   3  runtime error: gh, GraphQL or jq failed, an issue does not exist, or the
#      sub-issue tree could not be read. Nothing on stdout.

emulate -L zsh
setopt nounset pipefail

local -r gh_bin="${GH_BIN:-gh}"
local -r self_dir="${0:A:h}"
local -r plugin_root="${self_dir:h:h:h}"
local -r agent_file="$plugin_root/agents/story-readiness.md"
local -r size_check="$plugin_root/skills/refine-issue/scripts/size-check.zsh"
local -r tree_reader="$self_dir/read-sub-issues.zsh"
local -r marker_re='^<!-- readiness-stamp/v1 key=([0-9a-f]{64}) gate=([0-9a-f]{64}) at=([^ ]+) -->$'

_usage() { print -u2 -r -- "readiness-stamp.zsh: $*"; exit 2; }
_fail()  { print -u2 -r -- "readiness-stamp.zsh: $*"; exit 3; }

_sha256() {   # stdin -> hex digest
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# ---- arguments --------------------------------------------------------------

(( $# > 0 )) || _usage "a mode is required: key | check | write"
local mode="$1"; shift
case "$mode" in
  key|check|write) ;;
  -h|--help)
    print -u2 -r -- "usage: readiness-stamp.zsh key --repo R --issue N | check --repo R (--epic N | --issue N) | write --repo R --issue N --verdict-file F"
    exit 0 ;;
  *) _usage "unknown mode: $mode (expected key, check or write)" ;;
esac

local repo="" issue="" epic="" verdict_file=""
while (( $# > 0 )); do
  case "$1" in
    --repo|--issue|--epic|--verdict-file)
      (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || _usage "$1 needs a value"
      case "$1" in
        --repo) repo="$2" ;;
        --issue) issue="$2" ;;
        --epic) epic="$2" ;;
        --verdict-file) verdict_file="$2" ;;
      esac
      shift 2 ;;
    *) _usage "unknown arg: $1" ;;
  esac
done

[[ -n "$repo" ]] || _usage "--repo OWNER/NAME is required"
[[ "$repo" == ?*/?* && "$repo" != */*/* ]] || _usage "--repo must be OWNER/NAME: $repo"
local -r owner="${repo%%/*}" name="${repo#*/}"

case "$mode" in
  key|write)
    [[ -z "$epic" ]] || _usage "--epic is only valid with check"
    [[ -n "$issue" ]] || _usage "--issue N is required" ;;
  check)
    [[ -n "$issue" || -n "$epic" ]] || _usage "one of --epic N or --issue N is required"
    [[ -z "$issue" || -z "$epic" ]] || _usage "--epic and --issue are mutually exclusive" ;;
esac
[[ -z "$issue" || "$issue" == <-> ]] || _usage "--issue must be numeric: $issue"
[[ -z "$epic" || "$epic" == <-> ]] || _usage "--epic must be numeric: $epic"
if [[ "$mode" == write ]]; then
  [[ -n "$verdict_file" ]] || _usage "--verdict-file F is required"
elif [[ -n "$verdict_file" ]]; then
  _usage "--verdict-file is only valid with write"
fi

command -v jq >/dev/null 2>&1 || _fail "jq not found on PATH"
[[ -r "$agent_file" && -r "$size_check" ]] \
  || _fail "gate files not found under $plugin_root (agents/story-readiness.md, skills/refine-issue/scripts/size-check.zsh)"

local -r gate_version="$(cat -- "$agent_file" "$size_check" | _sha256)"
[[ "$gate_version" =~ '^[0-9a-f]{64}$' ]] || _fail "could not hash the gate files"

# ---- reading issues ---------------------------------------------------------

# The fields every mode reads, per issue. Labels and blockedBy take the first
# 100, the reader convention (read-dependencies.zsh); comments are paged.
local -r issue_fields='number title body
  labels(first:100){nodes{name}}
  blockedBy(first:100){nodes{number repository{nameWithOwner}}}
  comments(first:100){pageInfo{hasNextPage endCursor}
    nodes{databaseId body createdAt authorAssociation author{__typename login}}}'

# Read issues $@ into one JSON array of issue objects (comments fully paged),
# in argument order. Fails the run (exit 3) on any gh / GraphQL error or a
# missing issue.
_read_issues() {
  local -a nums=("$@") chunk
  local all='[]' raw q n node
  while (( ${#nums} > 0 )); do
    chunk=("${(@)nums[1,100]}")
    nums=("${(@)nums[101,-1]}")
    q='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){'
    for n in "${chunk[@]}"; do
      q+=" i$n: issue(number:$n){ $issue_fields }"
    done
    q+='}}'
    raw=$("$gh_bin" api graphql -f query="$q" -f owner="$owner" -f name="$name" 2>/dev/null) \
      || _fail "gh api graphql failed reading issues ${chunk[*]}"
    for n in "${chunk[@]}"; do
      node=$(print -r -- "$raw" | jq -ce --arg a "i$n" \
        'if (.errors // null) != null then error("graphql") else .data.repository[$a] end
         | if type == "object" then . else error("missing") end' 2>/dev/null) \
        || _fail "issue #$n could not be read (missing, or a GraphQL error)"
      node=$(_page_comments "$n" "$node") || exit 3
      all=$(jq -c --argjson x "$node" '. + [$x]' <<<"$all") || _fail "jq failed"
    done
  done
  print -r -- "$all"
}

# Follow issue $1's comment pages past the first 100; prints the node with every
# comment in .comments.nodes.
_page_comments() {   # $1 = number, $2 = node JSON
  local node="$2" more cursor raw page
  more=$(jq -r '.comments.pageInfo.hasNextPage' <<<"$node") || _fail "jq failed"
  cursor=$(jq -r '.comments.pageInfo.endCursor // ""' <<<"$node") || _fail "jq failed"
  while [[ "$more" == true ]]; do
    raw=$("$gh_bin" api graphql -f query='query($owner:String!,$name:String!,$num:Int!,$after:String!){
        repository(owner:$owner,name:$name){issue(number:$num){
          comments(first:100,after:$after){pageInfo{hasNextPage endCursor}
            nodes{databaseId body createdAt authorAssociation author{__typename login}}}}}}' \
      -f owner="$owner" -f name="$name" -F num="$1" -f after="$cursor" 2>/dev/null) \
      || _fail "gh api graphql failed paging comments of #$1"
    page=$(jq -ce '.data.repository.issue.comments | select(type == "object")' <<<"$raw" 2>/dev/null) \
      || _fail "comment page of #$1 could not be read"
    node=$(jq -c --argjson p "$page" '.comments.nodes += $p.nodes' <<<"$node") || _fail "jq failed"
    more=$(jq -r '.pageInfo.hasNextPage' <<<"$page")
    cursor=$(jq -r '.pageInfo.endCursor // ""' <<<"$page")
  done
  print -r -- "$node"
}

# The key of one issue node (stdin).
_key_of() {
  jq -cS --arg g "$gate_version" --arg repo "$repo" '
    def norm: gsub("\r\n"; "\n") | split("\n") | map(sub("\\s+$"; ""))
              | until(length == 0 or .[-1] != ""; .[:-1]) | join("\n");
    { gate_version: $g,
      title: ((.title // "") | norm),
      body:  ((.body // "")  | norm),
      blocked_by: ([.blockedBy.nodes[]
                    | if (.repository.nameWithOwner | ascii_downcase) == ($repo | ascii_downcase)
                      then .number
                      else "\(.repository.nameWithOwner)#\(.number)" end] | sort),
      labels: ([.labels.nodes[].name | select(. != "needs-refinement" and . != "blocked")] | sort) }' \
    | _sha256
}

# The stamp comments of one issue node (stdin) as a JSON array, oldest first:
# {id, created, trusted, body}. A stamp is a comment whose first line is a full
# marker, so a comment that merely quotes one is never edited or deleted.
_stamps_of() {
  jq -c --arg owner "$owner" --arg re "$marker_re" '
    [.comments.nodes[]
     | select((.body // "") | split("\n")[0] | sub("\r$"; "") | test($re))
     | { id: .databaseId, created: .createdAt, body: .body,
         trusted: ((.authorAssociation // "" | IN("OWNER", "MEMBER", "COLLABORATOR"))
                   or ((.author.__typename // "") == "Bot"
                       and ((.author.login // "") | ascii_downcase | sub("\\[bot\\]$"; ""))
                           == "claude-maintenance-" + ($owner | ascii_downcase))) }]
    | sort_by(.created)'
}

# Parse a stamp body (stdin): {key, gate, verdict} or a jq error when malformed.
_parse_stamp() {
  jq -Rsce --arg re "$marker_re" '
    (split("\n") | map(sub("\r$"; ""))) as $lines
    | ($lines[0] | [match($re).captures[].string]) as $c
    | ([$lines | to_entries[] | select(.key > 0 and .value == "```json")] | first
       // error("no json fence")).key as $open
    | ([$lines | to_entries[] | select(.key > $open and .value == "```")] | first
       // error("unclosed fence")).key as $close
    | ($lines[($open + 1):$close] | join("\n") | fromjson) as $v
    | if ($v | type) == "object"
         and ($v.verdict | IN("READY", "NEEDS_REFINEMENT"))
         and ($v.size | type) == "object"
         and ($v.size.verdict | type) == "string"
         and ($v.size.triggers | type) == "array"
         and ($v.size.inventory | type) == "array"
      then {key: $c[0], gate: $c[1], verdict: $v}
      else error("verdict shape") end'
}

# Judge one issue node (arg $1): prints a hit or a miss object.
_judge() {
  local node="$1" n stamps stamp parsed fresh_key cached size_out size_rc inv
  n=$(jq -r '.number' <<<"$node")
  stamps=$(_stamps_of <<<"$node") || _fail "jq failed on #$n"
  _miss() { jq -cn --argjson n "$n" --arg r "$1" '{issue: $n, reason: $r}'; }
  if [[ "$(jq 'length' <<<"$stamps")" == 0 ]]; then _miss no_stamp; return; fi
  stamp=$(jq -c '[.[] | select(.trusted)] | last' <<<"$stamps")
  if [[ "$stamp" == null ]]; then _miss untrusted_author; return; fi
  parsed=$(jq -r '.body' <<<"$stamp" | _parse_stamp 2>/dev/null) || { _miss malformed; return; }
  if [[ "$(jq -r '.gate' <<<"$parsed")" != "$gate_version" ]]; then _miss gate_changed; return; fi
  fresh_key=$(_key_of <<<"$node") || _fail "could not compute the key of #$n"
  if [[ "$(jq -r '.key' <<<"$parsed")" != "$fresh_key" ]]; then _miss key_changed; return; fi
  inv=$(jq -c '{files: .verdict.size.inventory}' <<<"$parsed")
  size_out=$(print -r -- "$inv" | zsh "$size_check" 2>/dev/null)
  size_rc=$?
  if (( size_rc != 0 && size_rc != 1 )); then _miss inventory_drift; return; fi
  if ! jq -en --argjson c "$parsed" --argjson f "$size_out" '
        ($f.verdict == $c.verdict.size.verdict)
        and (($f.triggers // []) | sort) == ($c.verdict.size.triggers | sort)' >/dev/null 2>&1; then
    _miss inventory_drift; return
  fi
  jq -c --argjson n "$n" '{issue: $n, verdict: .verdict}' <<<"$parsed"
}

# ---- modes ------------------------------------------------------------------

case "$mode" in
  key)
    local one
    one=$(_read_issues "$issue") || exit 3
    jq -c '.[0]' <<<"$one" | _key_of || _fail "could not compute the key of #$issue"
    exit 0 ;;

  check)
    local -a targets
    if [[ -n "$epic" ]]; then
      local tree
      tree=$(GH_BIN="$gh_bin" zsh "$tree_reader" --repo "$repo" --tree "$epic" 2>/dev/null) \
        || _fail "read-sub-issues.zsh --tree $epic failed"
      jq -e '[.nodes[] | select(.kind == "read_failed")] | length == 0' <<<"$tree" >/dev/null 2>&1 \
        || _fail "the sub-issue tree of #$epic has unreadable nodes"
      targets=(${(f)"$(jq -r --arg repo "$repo" '.nodes[]
        | select(.depth > 0 and .kind == "leaf" and .open
                 and (.repo | ascii_downcase) == ($repo | ascii_downcase)) | .number' <<<"$tree")"})
    else
      targets=("$issue")
    fi
    local hits='[]' misses='[]' nodes res
    if (( ${#targets} > 0 )); then
      nodes=$(_read_issues "${targets[@]}") || exit 3
      local i count
      count=$(jq 'length' <<<"$nodes")
      for (( i = 0; i < count; i++ )); do
        res=$(_judge "$(jq -c ".[$i]" <<<"$nodes")") || exit 3
        if jq -e 'has("reason")' <<<"$res" >/dev/null; then
          misses=$(jq -c --argjson r "$res" '. + [$r]' <<<"$misses")
        else
          hits=$(jq -c --argjson r "$res" '. + [$r]' <<<"$hits")
        fi
      done
    fi
    jq -cn --arg g "$gate_version" --argjson h "$hits" --argjson m "$misses" \
      '{gate_version: $g, hits: $h, misses: $m}'
    exit 0 ;;

  write)
    [[ -f "$verdict_file" && -r "$verdict_file" ]] || _usage "cannot read --verdict-file $verdict_file"
    local verdict
    verdict=$(jq -cse 'if length != 1 then error("not one document") else .[0] end
      | if type == "object"
           and (.verdict | IN("READY", "NEEDS_REFINEMENT"))
           and (.size | type) == "object"
           and (.size.verdict | type) == "string"
           and (.size.triggers | type) == "array"
           and (.size.inventory | type) == "array"
        then . else error("shape") end' -- "$verdict_file" 2>/dev/null) \
      || _usage "--verdict-file is not a story-readiness verdict with size.verdict, size.triggers and size.inventory: $verdict_file"
    local node key stamps body at keep id
    node=$(_read_issues "$issue") || exit 3
    node=$(jq -c '.[0]' <<<"$node") || _fail "jq failed"
    key=$(_key_of <<<"$node") || _fail "could not compute the key of #$issue"
    stamps=$(_stamps_of <<<"$node") || _fail "jq failed on #$issue"
    at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    body=$(jq -rn --arg k "$key" --arg g "$gate_version" --arg at "$at" --argjson v "$verdict" '
      "<!-- readiness-stamp/v1 key=\($k) gate=\($g) at=\($at) -->\n"
      + "<details>\n<summary>readiness verdict: \($v.verdict) (readiness-stamp/v1)</summary>\n\n"
      + "```json\n\($v | tojson)\n```\n\n</details>"')
    keep=$(jq -r '[.[] | select(.trusted)] | last | .id // empty' <<<"$stamps")
    local action
    if [[ -n "$keep" ]]; then
      jq -n --arg b "$body" '{body: $b}' \
        | "$gh_bin" api -X PATCH "repos/$repo/issues/comments/$keep" --input - >/dev/null 2>&1 \
        || _fail "editing stamp comment $keep on #$issue failed"
      id="$keep" action=edited
    else
      id=$(jq -n --arg b "$body" '{body: $b}' \
        | "$gh_bin" api -X POST "repos/$repo/issues/$issue/comments" --input - 2>/dev/null \
        | jq -er '.id') || _fail "creating a stamp comment on #$issue failed"
      action=created
    fi
    local old
    for old in ${(f)"$(jq -r --arg k "$keep" '.[] | select(.trusted and (.id | tostring) != $k) | .id' <<<"$stamps")"}; do
      "$gh_bin" api -X DELETE "repos/$repo/issues/comments/$old" >/dev/null 2>&1 \
        || _fail "deleting the older stamp comment $old on #$issue failed"
    done
    jq -cn --argjson n "$issue" --arg k "$key" --arg g "$gate_version" --arg a "$action" --arg id "$id" \
      '{issue: $n, key: $k, gate_version: $g, action: $a, comment_id: ($id | tonumber)}'
    exit 0 ;;
esac
