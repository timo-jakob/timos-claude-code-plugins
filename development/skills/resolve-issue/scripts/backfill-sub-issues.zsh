#!/usr/bin/env zsh
# backfill-sub-issues.zsh — one-time migration of an epic's markdown task-list
# children into GitHub-native sub-issues (#802).
#
# Why: #802 makes native sub-issues the authoritative epic→child source (the
# contract read-sub-issues.zsh reads). Existing epics declared their children
# only as markdown task-list lines — switching readers without backfilling
# would make every such epic enumerate ZERO native children and look
# never-decomposed (the migration hazard: #798's failure mode, en masse). This
# script converts the markdown declaration into the native relationship, one
# epic at a time. The markdown list itself is left untouched — it remains the
# human-readable view, it just stops being authoritative.
#
# Idempotent: children already attached natively are skipped, so an immediate
# second run is a no-op. Dry-run-able: --dry-run reports the plan and writes
# nothing.
#
# Usage:
#   backfill-sub-issues.zsh --repo OWNER/NAME --epic N [--dry-run]
#
# Parsing rule: this script is the SOLE remaining consumer of the fence-aware
# markdown task-list rule (the rule resolve-issue's E1 and
# list-refinement-children.zsh enumerated by before #802 made native
# sub-issues authoritative — both now read only the shared reader). The rule:
# checklist bullets (`- [ ]` / `- [x]`, `*`/`+` too), first issue ref per
# line, lines inside ``` fences ignored. A `this-repo#N` ref (compared
# case-insensitively — GitHub slugs are) counts as `#N`; a genuinely
# CROSS-repo ref is NOT migrated (this script attaches by same-repo issue
# number; cross-repo parenting is out of scope) — it is skipped and reported
# in "skipped_cross_repo".
#
# Emits one JSON object on stdout:
#   {
#     "epic": N, "dry_run": bool,
#     "markdown_children": [numbers],   # parsed from the body, body order
#     "already_present": [numbers],     # markdown children ALREADY attached
#                                       # natively before this run (a native
#                                       # child with no markdown line is not
#                                       # listed — read-sub-issues.zsh is the
#                                       # full-native-list reader)
#     "added": [numbers],               # attached by this run ([] on dry-run)
#     "would_add": [numbers],           # dry-run only: the plan
#     "skipped_cross_repo": ["owner/repo#N", ...],
#     "failed": [{"number": M, "error": "..."}]
#   }
#
# Seams (for tests / non-PATH installs):
#   GH_BIN  overrides the `gh` binary.
#
# Exit codes:
#   0  success — including the no-op (nothing to add) and dry-run
#   2  usage error
#   1  internal error (epic fetch / sub-issue list failed)
#   5  partial — some children could not be attached (see "failed")

emulate -L zsh
setopt nounset pipefail

local gh_bin="${GH_BIN:-gh}"

die_usage() { print -u2 -- "$1"; exit 2 }

local repo="" epic="" dry_run=false
while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) (( $# >= 2 )) || die_usage "--repo needs a value"; repo="$2"; shift 2 ;;
  --epic) (( $# >= 2 )) || die_usage "--epic needs a value"; epic="$2"; shift 2 ;;
  --dry-run) dry_run=true; shift ;;
  -h|--help)
    print -r -- "usage: backfill-sub-issues.zsh --repo OWNER/NAME --epic N [--dry-run]"; exit 0 ;;
  *) die_usage "unknown argument: $1" ;;
  esac
done
[[ -n "$repo" ]] || die_usage "--repo OWNER/NAME is required"
[[ "$repo" == */* ]] || die_usage "--repo must be OWNER/NAME, got: $repo"
[[ -n "$epic" ]] || die_usage "--epic N is required"
[[ "$epic" == <-> ]] || die_usage "--epic must be a number, got: $epic"
command -v jq >/dev/null 2>&1 || { print -u2 -- "backfill-sub-issues: jq not found on PATH"; exit 1 }

# The epic body — the markdown declaration being migrated.
local body
body=$("$gh_bin" api "repos/$repo/issues/$epic" --jq .body 2>/dev/null) || {
  print -u2 -- "backfill-sub-issues: failed to fetch epic #$epic from $repo"; exit 1
}

# Its task-list child refs, in body order — the fence-aware awk pass (see the
# header: this script is the rule's sole remaining consumer), keeping the
# optional `owner/repo` prefix of each line's FIRST ref so cross-repo refs can
# be told apart below.
local -a refs
refs=("${(@f)$(print -r -- "$body" | awk '
  /^[[:space:]]*```/ { infence = !infence; next }
  infence { next }
  /^[[:space:]]*[-*+] \[[ xX]\]/ {
    if (match($0, /([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?#[0-9]+/))
      print substr($0, RSTART, RLENGTH)
  }')}")
refs=(${refs:#})   # drop the empty element a childless body yields

# Same-repo refs (`#N`, `this-repo#N`) become candidate children; genuinely
# cross-repo refs are unmigratable and only reported. A self-reference (a
# tracker line like "#N stays open until …") is never a child — an issue
# cannot be its own sub-issue.
local -a md_children skipped_cross
local ref n
for ref in "${refs[@]}"; do
  if [[ "$ref" == "#"<-> ]]; then
    n="${ref#\#}"
  elif [[ "${(L)ref}" == "${(L)repo}#"<-> ]]; then   # GitHub slugs are case-insensitive
    n="${ref##*\#}"
  else
    skipped_cross+=("$ref")
    continue
  fi
  n=$(( n ))   # normalize zero-padded refs (#007 → 7); JSON forbids leading zeros
  (( n == epic )) && continue   # self-ref: not a child
  md_children+=("$n")
done

# The native sub-issues already attached (numbers).
local existing_json
existing_json=$("$gh_bin" api --paginate "repos/$repo/issues/$epic/sub_issues" \
  --jq '[.[].number]' 2>/dev/null | jq -cs 'add // []') || {
  print -u2 -- "backfill-sub-issues: failed to list sub-issues of epic #$epic"; exit 1
}

typeset -A present
# NB: `n` was declared with the ref parse above — re-declaring `local` at
# script (non-function) scope in zsh echoes the parameter, polluting stdout.
for n in ${(f)"$(print -r -- "$existing_json" | jq -r '.[]')"}; do
  [[ -n "$n" ]] && present[$n]=1
done

# Partition: already attached vs to attach (dedup'd, body order).
typeset -A seen
local -a already to_add
for n in "${md_children[@]}"; do
  [[ -n "${seen[$n]:-}" ]] && continue
  seen[$n]=1
  if [[ -n "${present[$n]:-}" ]]; then already+=("$n"); else to_add+=("$n"); fi
done

_json_num_array() {
  (( $# == 0 )) && { print -rn -- '[]'; return }
  print -rn -- "[${(j:,:)@}]"
}
_json_str_array() {  # newline-join → jq split, so no hand-escaping needed
  (( $# == 0 )) && { print -rn -- '[]'; return }
  print -rn -- "${(pj:\n:)@}" | jq -Rcs 'split("\n")'
}

if [[ "$dry_run" == true ]]; then
  jq -nc \
    --argjson epic "$epic" \
    --argjson md "$(_json_num_array "${md_children[@]}")" \
    --argjson already "$(_json_num_array "${already[@]}")" \
    --argjson would "$(_json_num_array "${to_add[@]}")" \
    --argjson skipped "$(_json_str_array "${skipped_cross[@]}")" \
    '{ epic: $epic, dry_run: true, markdown_children: $md,
       already_present: $already, added: [], would_add: $would,
       skipped_cross_repo: $skipped, failed: [] }'
  exit 0
fi

# Attach each missing child: resolve its database id, then POST it as a
# sub-issue. A single child's failure (e.g. it already has a different
# parent — GitHub allows one parent only) is recorded and does not abort the
# rest of the run.
local -a added failed_recs
local child_id err
for n in "${to_add[@]}"; do
  child_id=$("$gh_bin" api "repos/$repo/issues/$n" --jq .id 2>/dev/null) || {
    failed_recs+=("$(jq -nc --argjson n "$n" '{number: $n, error: "failed to resolve issue id"}')")
    continue
  }
  if err=$("$gh_bin" api -X POST "repos/$repo/issues/$epic/sub_issues" \
             -F sub_issue_id="$child_id" 2>&1 >/dev/null); then
    added+=("$n")
  else
    failed_recs+=("$(jq -nc --argjson n "$n" --arg e "${err:-POST failed}" '{number: $n, error: $e}')")
  fi
done

_json_array() {
  (( $# == 0 )) && { print -rn -- '[]'; return }
  print -rn -- "[${(j:,:)@}]"
}

jq -nc \
  --argjson epic "$epic" \
  --argjson md "$(_json_num_array "${md_children[@]}")" \
  --argjson already "$(_json_num_array "${already[@]}")" \
  --argjson added "$(_json_num_array "${added[@]}")" \
  --argjson skipped "$(_json_str_array "${skipped_cross[@]}")" \
  --argjson failed "$(_json_array "${failed_recs[@]}")" \
  '{ epic: $epic, dry_run: false, markdown_children: $md,
     already_present: $already, added: $added, would_add: [],
     skipped_cross_repo: $skipped, failed: $failed }'

(( ${#failed_recs} > 0 )) && exit 5
exit 0
