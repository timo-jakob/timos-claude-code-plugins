#!/usr/bin/env zsh
# collect-approver-telemetry.zsh — collect one `telemetry/v1` record per posted,
# instrumented Approver review of a repo, from GitHub, through the shared
# emitter (epic #741, child (f) — issue #1231).
#
# Why a collector: the approver agents live in the language plugins and in
# development-claude-plugin, the emitter in the development plugin, and an
# installed plugin cannot reach another plugin's tree by path. Every approver
# agent already posts its verdict, confidence, detected type and
# dimension-tagged risk findings in the hidden `claude-approver:findings` block
# of the review it posts, so this script reads those posted reviews with `gh`
# and emits from the machine that has the emitter — one emitter, no
# cross-plugin path, any repo the operator's machine can read (ARCHITECTURE.md,
# *Approver telemetry (#1231)*).
#
# Usage:
#   collect-approver-telemetry.zsh --repo OWNER/NAME
#     [--telemetry-file PATH] [--telemetry-dir DIR]
#
# What it walks: the repo's pull requests (any state) updated in the last 30
# days — listed newest-updated first, 100 a page, and paging stops at the first
# page that is short or reaches past the window — in ascending PR number, and
# every review of each, in ascending review id. There is no range flag.
#
# Which reviews count: one whose author login starts with `claude-approver` AND
# whose author type is `Bot`. Any other author's review is ignored, uncounted,
# even when its body carries a block. A counted review becomes one
# `kind: "run"` record, `pipeline: "approve"`, when its body carries a
# parseable `<!-- claude-approver:findings … -->` block (the last one in the
# body) with an integer `started_at` and `submitted_at − started_at` is
# positive, and build-approver-telemetry-record.zsh (beside this script)
# accepts it. Otherwise — no block, a block that is not one JSON object, no or
# a non-integer `started_at`, no `submitted_at`, a non-positive wall time, or a
# block the builder refuses (a verdict that disagrees with the review's state,
# a key missing or ill-typed) — it yields NO record and is counted as not
# instrumented: wall_s is required and never guessed. Envelope: `pr` = the
# reviewed PR, `ts` = started_at, `wall_s` = submitted_at − started_at,
# `outcome` = the builder's --print-outcome (always `success`), `issue` and
# `tokens` null.
#
# Sink and idempotency: the sink is the ONE file the emitter's precedence
# resolves to — --telemetry-file, else DIR/<repo-slug>.jsonl, else the
# user-level default $HOME/.claude/telemetry/<repo-slug>.jsonl — computed by
# tlm_sink_path (telemetry-sink-lib.zsh), the function the emitter itself
# writes through, and passed to the emitter as --telemetry-file so the file
# checked and the file appended to are one. A review whose id already appears
# as `payload.review_id` on a `pipeline: "approve"` record in THAT file is
# skipped as already recorded; a record in any other file does not count. Safe
# to re-run and /loop-able.
#
# Secrets: nothing `gh` prints on stderr — where a token could appear — is ever
# echoed; only the HTTP status is read from it. The payload carries only the
# builder's enumerated, identifier-shaped fields, never a review body.
#
# Output: on completion, one stdout line —
#   collect-approver-telemetry: OWNER/NAME: recorded N, skipped as already recorded N, skipped as not instrumented N
#
# Exit codes (the collector has no host run to protect, so the telemetry
# never-fatal rule does not apply):
#   0  the collection completed — including nothing to collect and reviews
#      counted as not instrumented
#   2  usage: no --repo, a --repo that is not OWNER/NAME, an unknown or dangling
#      flag, a positional, a --telemetry-dir that exists and is not a directory.
#      Judged before any `gh` call.
#   3  a `gh` call failed (the pulls listing — a --repo that does not exist or
#      the token cannot see answers 404 there and is a failure too — or a
#      reviews listing), the emitter failed, or a tool (jq, gh), the builder
#      (any exit but its refusal, 1) or the sink is unusable. It stops at the
#      first failure with ONE stderr line naming the repo, the failing endpoint
#      or script, and the PR number and review id it was processing. Records
#      already appended stand; the emitter appends nothing on failure, so no
#      sink gains a partial line. After a transient failure (gh, the emitter) a
#      re-run resumes via idempotency; an unusable tool, builder or sink fails
#      again on every re-run until it is fixed.
#
# Seam (tests only): APPROVER_TELEMETRY_EMITTER_BIN replaces the emitter path.

emulate -L zsh
setopt nounset pipefail extendedglob

local P=collect-approver-telemetry
local self_dir="${0:A:h}"
local BUILDER="$self_dir/build-approver-telemetry-record.zsh"
local EMITTER="${APPROVER_TELEMETRY_EMITTER_BIN:-$self_dir/emit-telemetry.zsh}"

local usage="usage: collect-approver-telemetry.zsh --repo OWNER/NAME [--telemetry-file PATH] [--telemetry-dir DIR]

Emits one telemetry/v1 record (pipeline \"approve\") per instrumented review
posted by a claude-approver Bot on OWNER/NAME's pull requests updated in the
last 30 days, skipping reviews already recorded in the resolved sink.
Sink precedence: --telemetry-file > --telemetry-dir (DIR/<repo-slug>.jsonl)
  > \$HOME/.claude/telemetry/<repo-slug>.jsonl"

_usage_err() { print -ru2 -- "$P: $1"; print -ru2 -- "$usage"; exit 2 }
_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || _usage_err "$1 requires a value"
  [[ -n "$3" && "$3" != --* ]] || _usage_err "$1 requires a non-empty value"
}

local repo="" telemetry_file="" telemetry_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) _need_val "$1" $# "${2:-}"; repo="$2"; shift 2 ;;
  --telemetry-file) _need_val "$1" $# "${2:-}"; telemetry_file="$2"; shift 2 ;;
  --telemetry-dir) _need_val "$1" $# "${2:-}"; telemetry_dir="$2"; shift 2 ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  -*) _usage_err "unknown flag: $1" ;;
  *) _usage_err "unexpected argument: $1" ;;
  esac
done

[[ -n "$repo" ]] || _usage_err "--repo OWNER/NAME is required"
[[ "$repo" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]] || _usage_err "--repo must be OWNER/NAME (got: $repo)"
[[ -z "$telemetry_dir" || ! -e "$telemetry_dir" || -d "$telemetry_dir" ]] || \
  _usage_err "--telemetry-dir is not a directory: $telemetry_dir"

# --- the one stderr line every exit 3 prints ---------------------------------

local cur_pr="" cur_review=""
_fail() {  # $1 = the failing endpoint or script, $2 = what happened
  print -ru2 -- "$P: $repo: $1 failed ($2) — PR ${cur_pr:-none}, review ${cur_review:-none}"
  exit 3
}

local tool=""
for tool in jq gh; do
  command -v "$tool" >/dev/null 2>&1 || _fail "$tool" "not found on PATH"
done
[[ -x "$EMITTER" ]] || _fail "${EMITTER:t}" "missing or not executable"

source "$self_dir/telemetry-sink-lib.zsh" || _fail "telemetry-sink-lib.zsh" "cannot be loaded"

local sink=""
sink=$(tlm_sink_path "$telemetry_file" "$telemetry_dir" "$repo") || \
  _fail "sink resolution" "HOME is not set; pass --telemetry-file or --telemetry-dir"

local tmp=""
tmp=$(mktemp -d) || _fail "mktemp" "cannot create a scratch directory"
trap 'rm -rf -- "$tmp"' EXIT

# --- reviews already recorded in THE resolved sink ----------------------------

typeset -A recorded=()
local id=""
if [[ -e "$sink" ]]; then
  [[ -r "$sink" && ! -d "$sink" ]] || _fail "sink $sink" "not a readable file"
  jq -R -r 'fromjson? | objects | select(.pipeline == "approve")
            | (.payload | objects | .review_id) // empty | tostring' < "$sink" > "$tmp/ids" \
    || _fail "sink $sink" "cannot be read"
  while IFS= read -r id; do recorded[$id]=1; done < "$tmp/ids"
fi

# --- gh -----------------------------------------------------------------------
# stdout to a file; stderr to a file that is NEVER printed (a token may be in
# it) — only its HTTP status is read back, into gh_code.

local gh_code=""
_gh() {  # $1 = output file, rest = the gh arguments
  local out="$1"; shift
  gh_code=""
  gh "$@" > "$out" 2> "$tmp/gh.err" && return 0
  [[ "$(<"$tmp/gh.err")" =~ 'HTTP ([0-9][0-9][0-9])' ]] && gh_code="${match[1]}"
  return 1
}
_gh_detail() { if [[ -n "$gh_code" ]]; then print -r -- "HTTP $gh_code"; else print -r -- "gh exited non-zero"; fi }

local cutoff=""
cutoff=$(jq -n -r 'now - 30 * 86400 | floor') || _fail "jq" "cannot read the clock"

local -i recorded_n=0 already=0 uninstrumented=0
_summary() {
  print -r -- "$P: $repo: recorded $recorded_n, skipped as already recorded $already, skipped as not instrumented $uninstrumented"
}

# --- the pull requests updated in the window ----------------------------------
# Newest-updated first, so the first page that is short or reaches past the
# window is the last one worth reading.

local ep="repos/$repo/pulls" more=""
local -i page=1
: > "$tmp/prs"
while true; do
  _gh "$tmp/page.json" api "$ep?state=all&sort=updated&direction=desc&per_page=100&page=$page" \
    || _fail "gh api $ep" "$(_gh_detail)"
  more="$(jq -r --argjson c "$cutoff" '
    if type != "array" then error("not an array") else
      (.[] | select(((.updated_at // "") | try fromdateiso8601 catch -1) >= $c) | .number
             | select(type == "number") | tostring),
      "more=\(length == 100 and all(.[]; ((.updated_at // "") | try fromdateiso8601 catch -1) >= $c))"
    end' < "$tmp/page.json" 2>/dev/null)" || _fail "gh api $ep" "unreadable response"
  print -r -- "${more%more=*}" >> "$tmp/prs"
  [[ "${more##*more=}" == true ]] || break
  page+=1
done

typeset -a prs=() review_rows=()
prs=("${(@f)$(sort -n -u -- "$tmp/prs" | sed '/^$/d')}")

local pr="" rv="" line="" started="" wall="" ts="" outcome="" why=""
local -i rc=0
for pr in "${prs[@]}"; do
  [[ -n "$pr" ]] || continue
  cur_pr="$pr"; cur_review=""
  ep="repos/$repo/pulls/$pr/reviews"
  _gh "$tmp/reviews.json" api --paginate "$ep?per_page=100" || _fail "gh api $ep" "$(_gh_detail)"
  # Only a claude-approver Bot's reviews; each with its parsed hidden block
  # (the last in the body) as `block`, null when absent or not one object.
  jq -s -c '[ .[] | if type == "array" then .[] else error("not an array") end ]
    | map(select(((.user.login // "") | tostring | startswith("claude-approver"))
                 and .user.type == "Bot"))
    | sort_by(.id) | .[]
    | . + {block: ((.body // "") as $b
                   | if ($b | type) != "string" then null else
                       ([$b | match("<!-- claude-approver:findings([\\s\\S]*?)-->"; "g")] | last
                        | if . == null then null
                          else (.captures[0].string | try fromjson catch null) end)
                     end
                   | if type == "object" then . else null end)}' \
    < "$tmp/reviews.json" > "$tmp/reviews.lines" 2>/dev/null || _fail "gh api $ep" "unreadable response"
  review_rows=("${(@f)$(cat -- "$tmp/reviews.lines")}")

  for rv in "${review_rows[@]}"; do
    [[ -n "$rv" ]] || continue
    print -r -- "$rv" > "$tmp/review.json"
    id="$(jq -r '.id | tostring' < "$tmp/review.json")" || _fail "jq" "unreadable review"
    cur_review="$id"
    if (( ${+recorded[$id]} )); then (( already++ )); continue; fi

    # started_at and the wall time: absent, non-integer or non-positive → not
    # instrumented. Both are printed as one tab-separated line; an empty field
    # keeps its place under the doubled-tab IFS.
    line="$(jq -r '
      def secs: if type == "number" and . == floor then .
                elif type == "string" and test("^[0-9]+$") then tonumber else null end;
      (.block.started_at | secs) as $s
      | ((.submitted_at // null) | if type == "string" then (try fromdateiso8601 catch null) else null end) as $t
      | [($s // ""), (if $s != null and $t != null then $t - $s else "" end)] | @tsv' < "$tmp/review.json")" \
      || _fail "jq" "unreadable review"
    IFS=$'\t\t' read -r started wall <<< "$line"
    if [[ -z "$started" || -z "$wall" ]] || (( wall <= 0 )); then
      (( uninstrumented++ )); continue
    fi
    jq -c '.block' < "$tmp/review.json" > "$tmp/block.json" || _fail "jq" "unreadable block"

    rc=0
    zsh "$BUILDER" --review "$tmp/review.json" --block "$tmp/block.json" > "$tmp/payload.json" 2>/dev/null || rc=$?
    if (( rc == 1 )); then (( uninstrumented++ )); continue; fi
    (( rc == 0 )) || _fail "${BUILDER:t}" "exit $rc"
    outcome="$(zsh "$BUILDER" --review "$tmp/review.json" --block "$tmp/block.json" --print-outcome 2>/dev/null)" \
      || _fail "${BUILDER:t}" "--print-outcome failed"
    ts="$started"

    rc=0
    "$EMITTER" --pipeline approve --kind run --outcome "$outcome" --wall-s "$wall" --ts "$ts" \
      --repo "$repo" --pr "$pr" --payload "$tmp/payload.json" --telemetry-file "$sink" \
      > /dev/null 2> "$tmp/emit.err" || rc=$?
    if (( rc )); then
      why="$(sed -n 1p "$tmp/emit.err")"
      _fail "${EMITTER:t}" "exit $rc${why:+: $why}"
    fi
    recorded[$id]=1
    (( recorded_n++ ))
  done
done

cur_pr=""; cur_review=""
_summary
exit 0
