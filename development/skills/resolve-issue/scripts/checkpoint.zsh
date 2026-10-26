#!/usr/bin/env zsh
# checkpoint.zsh — the recoverable checkpoint of a resolve-issue run (#2920,
# epic #2582): a wip commit pushed to the feature branch at the first green gate
# and after every round the review loop consolidates on a green gate, plus the
# marker that lets a later session `--resume` from it after a hard kill.
#
# Why: a run killed from outside — the usage limit, a closed terminal, a crash —
# never reaches the clean stop (#2579), so before this it lost everything it had
# not committed and pushed, which was usually the whole run. A checkpoint caps
# that loss at the round in progress. It opens NO PR: the review-loop contract
# is "no PR until the loop exits CONVERGED; the only earlier pushes are wip
# checkpoint commits to the feature branch". A wip commit carries no
# `[skip ci]`, so a repo whose CI runs on every push runs it on these too.
#
# It lives in the same durable directory as the clean stop (clean-stop.zsh):
#
#   $HOME/.claude/resolve-issue/<repo-slug>/<N>/
#     checkpoint.json         the marker (checkpoint/v1)
#     checkpoint-r<K>-<sha>/  the loop state at round K: work-dir/, status.json
#     lease.json              {branch, sha} — the head an earlier run left on
#                             the remote, which the next checkpoint push may
#                             replace (--force-with-lease), and nothing else
#
# Every checkpoint takes the same order: commit the worktree on the feature
# branch, push it, copy the loop state beside the marker, then rename the new
# marker into place. A kill at any point therefore leaves either the old marker
# (whose SHA and state are still there) or a new marker whose SHA is on the
# remote — which is what keeps `read`'s remote-head refusal sound. A written
# marker supersedes an older clean stop: write deletes clean-stop.json, as
# clean-stop.zsh write deletes checkpoint.json, so the marker written last wins.
#
# The wip commit runs the repo's commit hooks over everything it stages, new
# files included: the final commit sees only what changed since the last wip
# commit, so a file a checkpoint pushed unhooked would never be hooked. A hook
# that fails or rewrites the tree fails the commit, and that round goes without
# a checkpoint. The push skips pre-push hooks (`--no-verify`).
#
# Usage:
#   checkpoint.zsh write --repo-dir DIR --issue N --round K --mode attended|unattended
#                        [--ceiling C] [--run-id ID] [--work-dir DIR]
#                        [--status-file FILE] [--remote NAME|URL]
#       Commit the worktree as `wip(resolve-issue #N): implementation` (K = 0)
#       or `wip(resolve-issue #N): round K`, push it, keep the loop state and
#       write the marker; print the marker. --work-dir / --status-file default
#       to the durable ones clean-stop.zsh names. Without --remote the push goes
#       to the Maintenance App's token URL, falling back to `origin` (as the
#       user) when no token can be minted.
#   checkpoint.zsh read  --repo-dir DIR --issue N --mode attended|unattended [--remote NAME|URL]
#       The `--resume` check. Refuses in mode unattended (exit 4), with no
#       marker (exit 3), and when the remote branch head is not the marker's SHA
#       (exit 5). Otherwise restores the round's loop state over the work-dir
#       and status file — dropping any half-finished later round — and prints
#       the marker plus `loop_resume` (last_round >= 1) and `next_round`.
#   checkpoint.zsh clear --repo-dir DIR --issue N
#       Remove the marker, the kept states and any lease. Absent is not an error.
#   checkpoint.zsh supersede --repo-dir DIR --issue N --branch NAME [--remote NAME|URL]
#       A fresh run's step, once §1 has cut BRANCH. When the durable directory
#       keeps a clean-stop or checkpoint marker, move the whole directory to
#       <N>.superseded-<UTC stamp>/ (nothing deleted) and recreate it empty
#       with a lease.json naming the head the run's first checkpoint push may
#       replace: the kept checkpoint's SHA for BRANCH, else BRANCH's remote
#       head read now, before any work. With nothing kept, lease BRANCH's
#       remote head only when it is a `wip(resolve-issue #N): …` commit and no
#       open PR has BRANCH (CHECKPOINT_GH_BIN overrides gh), moving nothing;
#       any other head is exit 1. Print {superseded_to (null when nothing
#       moved), kept, lease}. Exit 3, writing nothing, when nothing is kept and
#       BRANCH is not on the remote.
#
# The marker (checkpoint/v1):
#   {schema, issue, branch, sha, last_round, ceiling, grants, work_dir,
#    status_file, state_dir, run_id, session_mode}
#   `ceiling` is the caller's --max-rounds at that round (null at round 0) — a
#   grant raises it through the kept work-dir's sidecar, not the marker;
#   `grants` counts the work-dir's grants.jsonl by source.
#
# Seams (tests): CHECKPOINT_MINT_BIN overrides the token minter and
# CHECKPOINT_GH_BIN the gh that lists open PRs (each a PATH).
#
# Exit codes: 0 ok · 2 usage · 3 no marker (read) / nothing to supersede ·
# 4 resume refused in mode unattended · 5 remote head is not the marker's SHA ·
# 1 internal (no HOME, a failed commit or push, an unreadable marker or state)

emulate -L zsh
setopt nounset pipefail
# an inherited GIT_DIR / GIT_WORK_TREE (a hook, a CI wrapper) would override
# `git -C` and commit into a different repository
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

local self_dir="${0:A:h}"
local usage="usage: checkpoint.zsh write --repo-dir DIR --issue N --round K --mode attended|unattended
                           [--ceiling C] [--run-id ID] [--work-dir DIR] [--status-file FILE] [--remote NAME|URL]
       checkpoint.zsh read  --repo-dir DIR --issue N --mode attended|unattended [--remote NAME|URL]
       checkpoint.zsh clear --repo-dir DIR --issue N
       checkpoint.zsh supersede --repo-dir DIR --issue N --branch NAME [--remote NAME|URL]"

_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || { print -u2 -- "checkpoint: $1 requires a value"; exit 2 }
  [[ -n "$3" && "$3" != --* ]] || {
    print -u2 -- "checkpoint: $1 requires a non-empty value"; exit 2 }
}
_only() {  # $1 = flag, $2.. = the subcommands that take it
  local f="$1"; shift
  (( ${@[(Ie)$cmd]} )) || { print -u2 -- "checkpoint: $f is not a flag of $cmd"; exit 2 }
}

(( $# > 0 )) || { print -u2 -- "$usage"; exit 2 }
local cmd="$1"; shift
case "$cmd" in
  write|read|clear|supersede) ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  *) print -u2 -- "checkpoint: unknown subcommand: $cmd"; print -u2 -- "$usage"; exit 2 ;;
esac

local repo_dir="" issue="" round="" mode="" ceiling="" run_id="" wd_arg="" sf_arg="" remote="" sbranch=""
while (( $# > 0 )); do
  case "$1" in
  --repo-dir) _need_val "$1" $# "${2:-}"; repo_dir="$2"; shift 2 ;;
  --issue) _need_val "$1" $# "${2:-}"; issue="$2"; shift 2 ;;
  --round) _only "$1" write; _need_val "$1" $# "${2:-}"; round="$2"; shift 2 ;;
  --mode) _only "$1" write read; _need_val "$1" $# "${2:-}"; mode="$2"; shift 2 ;;
  --ceiling) _only "$1" write; _need_val "$1" $# "${2:-}"; ceiling="$2"; shift 2 ;;
  --run-id) _only "$1" write; _need_val "$1" $# "${2:-}"; run_id="$2"; shift 2 ;;
  --work-dir) _only "$1" write; _need_val "$1" $# "${2:-}"; wd_arg="$2"; shift 2 ;;
  --status-file) _only "$1" write; _need_val "$1" $# "${2:-}"; sf_arg="$2"; shift 2 ;;
  --remote) _only "$1" write read supersede; _need_val "$1" $# "${2:-}"; remote="$2"; shift 2 ;;
  --branch) _only "$1" supersede; _need_val "$1" $# "${2:-}"; sbranch="$2"; shift 2 ;;
  -*) print -u2 -- "checkpoint: unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "checkpoint: unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$repo_dir" && -n "$issue" ]] || { print -u2 -- "$usage"; exit 2 }
[[ "$issue" == <-> && "$issue" != 0* ]] || {
  print -u2 -- "checkpoint: --issue must be an issue number (got: $issue)"; exit 2 }
[[ -d "$repo_dir" ]] || { print -u2 -- "checkpoint: --repo-dir is not a directory: $repo_dir"; exit 2 }
if [[ "$cmd" == write || "$cmd" == read ]]; then
  [[ "$mode" == attended || "$mode" == unattended ]] || {
    print -u2 -- "checkpoint: $cmd needs --mode attended|unattended"; exit 2 }
fi
[[ "$cmd" != supersede || -n "$sbranch" ]] || {
  print -u2 -- "checkpoint: supersede needs --branch, the branch §1 cut"; exit 2 }
if [[ "$cmd" == write ]]; then
  [[ "$round" == <-> && ( "$round" == 0 || "$round" != 0* ) ]] || {
    print -u2 -- "checkpoint: write needs --round K, a round number (0 for the implementation)"; exit 2 }
  [[ -z "$ceiling" || ( "$ceiling" == <-> && "$ceiling" != 0* ) ]] || {
    print -u2 -- "checkpoint: --ceiling must be a positive round count (got: $ceiling)"; exit 2 }
fi

command -v jq >/dev/null 2>&1 || { print -u2 -- "checkpoint: jq not found on PATH"; exit 1 }
source "${self_dir}/../../../scripts/telemetry/telemetry-sink-lib.zsh" || {
  print -u2 -- "checkpoint: cannot load telemetry-sink-lib.zsh"; exit 1 }
[[ -n "${HOME:-}" ]] || { print -u2 -- "checkpoint: HOME is unset, so there is no durable directory"; exit 1 }

local repo_id="" slug="" base=""
repo_id=$(tlm_derive_repo "$repo_dir") || repo_id=""
slug=$(tlm_repo_slug "$repo_id") || slug=""
[[ -n "$slug" ]] || { print -u2 -- "checkpoint: could not derive the repo slug for $repo_dir"; exit 1 }
base="$HOME/.claude/resolve-issue/$slug/$issue"
local marker="$base/checkpoint.json" lease="$base/lease.json" cs_marker="$base/clean-stop.json"
local wd="${wd_arg:-$base/work-dir}" sf="${sf_arg:-$base/status.json}"

# _remote_head BRANCH -> the remote's head SHA for BRANCH on stdout (empty when
# the branch does not exist there); status 1 when the remote cannot be read
_remote_head() {
  local out=""
  out=$(git -C "$repo_dir" ls-remote "${remote:-origin}" "refs/heads/$1" 2>/dev/null) || return 1
  print -r -- "${${out%%[[:space:]]*}:-}"
}

case "$cmd" in
write)
  local branch=""
  branch=$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null) || {
    print -u2 -- "checkpoint: HEAD is detached in $repo_dir — a checkpoint needs the feature branch"; exit 1 }
  local default_branch=""
  default_branch=$(git -C "$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || default_branch=""
  if [[ "$branch" == main || "$branch" == master || "$branch" == "${default_branch#origin/}" ]]; then
    print -u2 -- "checkpoint: refusing to checkpoint onto $branch — a checkpoint is only ever pushed to a feature branch"
    exit 1
  fi
  local msg="wip(resolve-issue #$issue): round $round"
  (( round == 0 )) && msg="wip(resolve-issue #$issue): implementation"
  git -C "$repo_dir" add -A 2>/dev/null || {
    print -u2 -- "checkpoint: could not stage the worktree in $repo_dir"; exit 1 }
  git -C "$repo_dir" commit -q --allow-empty -m "$msg" >/dev/null 2>&1 || {
    print -u2 -- "checkpoint: could not commit the checkpoint on $branch (a commit hook may have failed)"; exit 1 }
  local sha=""
  sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null) || {
    print -u2 -- "checkpoint: could not read the checkpoint commit"; exit 1 }

  # the lease a superseded run left: replace exactly that head, nothing else
  local -a lease_arg=()
  if [[ -s "$lease" ]]; then
    local l_branch="" l_sha=""
    l_branch=$(jq -r '.branch // ""' "$lease" 2>/dev/null) || l_branch=""
    l_sha=$(jq -r '.sha // ""' "$lease" 2>/dev/null) || l_sha=""
    [[ "$l_branch" == "$branch" ]] && lease_arg=("--force-with-lease=$branch:$l_sha")
  fi

  # push: the explicit --remote, else the Maintenance App, else origin
  local token_file="" push_ok=0 via=""
  if [[ -n "$remote" ]]; then
    git -C "$repo_dir" push -q --no-verify "${lease_arg[@]}" "$remote" "HEAD:refs/heads/$branch" >/dev/null 2>&1 && push_ok=1
    via="$remote"
  else
    local mint="${CHECKPOINT_MINT_BIN:-${self_dir}/../../maintenance/scripts/mint-maintenance-token.zsh}"
    if [[ "$repo_id" == */* ]]; then
      token_file=$(cd "$repo_dir" && "$mint" 2>/dev/null) || token_file=""
    fi
    if [[ -n "$token_file" && -s "$token_file" ]]; then
      # the token is read inline at the point of use and never echoed (#640)
      git -C "$repo_dir" push -q --no-verify "${lease_arg[@]}" \
        "https://x-access-token:$(<"$token_file")@github.com/$repo_id.git" "HEAD:refs/heads/$branch" \
        >/dev/null 2>&1 && push_ok=1
      rm -f -- "$token_file"
      via="the Maintenance App"
    else
      print -u2 -- "checkpoint: no Maintenance App token could be minted here — pushing the checkpoint to origin as you"
      git -C "$repo_dir" push -q --no-verify "${lease_arg[@]}" origin "HEAD:refs/heads/$branch" >/dev/null 2>&1 && push_ok=1
      via="origin"
    fi
  fi
  (( push_ok )) || {
    print -u2 -- "checkpoint: the push of $branch ($sha) to $via failed — the previous checkpoint marker stands; the commit stays local and rides the next checkpoint"
    exit 1 }
  rm -f -- "$lease"

  # keep this round's loop state beside the marker, then swap the marker in
  local state_dir="$base/checkpoint-r$round-${sha[1,12]}"
  rm -rf -- "$state_dir"
  mkdir -p -- "$state_dir" || { print -u2 -- "checkpoint: could not create $state_dir"; exit 1 }
  if [[ -d "$wd" ]]; then
    cp -Rp -- "$wd" "$state_dir/work-dir" || {
      print -u2 -- "checkpoint: could not keep the loop work-dir $wd"; exit 1 }
  fi
  if [[ -f "$sf" ]]; then
    cp -p -- "$sf" "$state_dir/status.json" || {
      print -u2 -- "checkpoint: could not keep the status file $sf"; exit 1 }
  fi
  local grants='{"human":0,"automatic":0}'
  if [[ -s "$wd/grants.jsonl" ]]; then
    grants=$(jq -sc '{human: ([.[] | select(.source == "human")] | length),
                      automatic: ([.[] | select(.source == "automatic")] | length)}' \
      "$wd/grants.jsonl" 2>/dev/null) || grants='{"human":0,"automatic":0}'
  fi
  local doc=""
  doc=$(jq -nc --argjson n "$issue" --arg b "$branch" --arg sha "$sha" --argjson k "$round" \
          --arg c "$ceiling" --argjson g "$grants" --arg w "$wd" --arg s "$sf" \
          --arg d "$state_dir" --arg r "$run_id" --arg m "$mode" '
    {schema: "checkpoint/v1", issue: $n, branch: $b, sha: $sha, last_round: $k,
     ceiling: (if $c == "" then null else ($c | tonumber) end), grants: $g,
     work_dir: $w, status_file: $s, state_dir: $d,
     run_id: (if $r == "" then null else $r end), session_mode: $m}') || {
    print -u2 -- "checkpoint: could not build the marker"; exit 1 }
  local tmp="$marker.tmp.$$"
  { print -r -- "$doc" > "$tmp" && mv -f -- "$tmp" "$marker" } 2>/dev/null || {
    rm -f -- "$tmp"; print -u2 -- "checkpoint: could not write the marker: $marker"; exit 1 }
  # the states the new marker superseded, and an older clean stop
  local old
  for old in "$base"/checkpoint-r*(N/); do
    [[ "$old" == "$state_dir" ]] || rm -rf -- "$old"
  done
  rm -f -- "$cs_marker"
  print -r -- "$doc"
  ;;

read)
  [[ "$mode" == attended ]] || {
    print -u2 -- "checkpoint: --resume is for an attended session only — an unattended run never resumes a checkpoint"
    exit 4 }
  [[ -e "$marker" ]] || {
    print -u2 -- "checkpoint: no checkpoint is kept for issue #$issue ($marker) — re-run without --resume to start fresh"
    exit 3 }
  jq -e -s 'length == 1 and (.[0] | type == "object" and .schema == "checkpoint/v1"
             and (.branch | type == "string") and (.sha | type == "string")
             and (.last_round | type == "number") and (.work_dir | type == "string")
             and (.status_file | type == "string") and (.state_dir | type == "string"))' \
    "$marker" >/dev/null 2>&1 || {
    print -u2 -- "checkpoint: the marker is malformed: $marker"; exit 1 }
  local m_branch="" m_sha="" m_wd="" m_sf="" m_state=""
  m_branch=$(jq -r '.branch' "$marker") && m_sha=$(jq -r '.sha' "$marker") \
    && m_wd=$(jq -r '.work_dir' "$marker") && m_sf=$(jq -r '.status_file' "$marker") \
    && m_state=$(jq -r '.state_dir' "$marker") || {
    print -u2 -- "checkpoint: could not read the marker: $marker"; exit 1 }
  local head=""
  head=$(_remote_head "$m_branch") || {
    print -u2 -- "checkpoint: could not read the remote head of $m_branch from ${remote:-origin}"; exit 1 }
  [[ "$head" == "$m_sha" ]] || {
    print -u2 -- "checkpoint: refusing to resume — the remote head of $m_branch is ${head:-<absent>}, not the checkpoint's $m_sha; something moved the branch after the checkpoint, so its state no longer describes it"
    exit 5 }
  [[ -d "$m_state" ]] || { print -u2 -- "checkpoint: the checkpoint's loop state is missing: $m_state"; exit 1 }
  # drop whatever a half-finished later round left, and restore this round's
  rm -rf -- "$m_wd" || { print -u2 -- "checkpoint: could not clear the work-dir $m_wd"; exit 1 }
  if [[ -d "$m_state/work-dir" ]]; then
    cp -Rp -- "$m_state/work-dir" "$m_wd" || {
      print -u2 -- "checkpoint: could not restore the work-dir $m_wd"; exit 1 }
  else
    mkdir -p -- "$m_wd" || { print -u2 -- "checkpoint: could not create the work-dir $m_wd"; exit 1 }
  fi
  if [[ -f "$m_state/status.json" ]]; then
    cp -p -- "$m_state/status.json" "$m_sf" || {
      print -u2 -- "checkpoint: could not restore the status file $m_sf"; exit 1 }
  else
    rm -f -- "$m_sf"
  fi
  jq -c '. + {loop_resume: (.last_round >= 1), next_round: (.last_round + 1)}' "$marker"
  ;;

clear)
  rm -rf -- "$marker" "$lease" "$base"/checkpoint-r*(N/) || {
    print -u2 -- "checkpoint: could not clear the checkpoint in $base"; exit 1 }
  ;;

supersede)
  local -a kept=()
  [[ -e "$cs_marker" ]] && kept+=(clean-stop)
  [[ -e "$marker" ]] && kept+=(checkpoint)
  local l_sha="" have_lease=0
  if (( ! ${#kept} )); then
    # nothing kept: lease the remote head only when it is a killed run's own
    # wip checkpoint for this issue and no open PR has the branch, so a PR or
    # anyone else's commits are never replaced
    local left="" subject="" prs=""
    left=$(_remote_head "$sbranch") || {
      print -u2 -- "checkpoint: could not read the remote head of $sbranch from ${remote:-origin}"; exit 1 }
    [[ -z "$left" ]] && exit 3
    git -C "$repo_dir" fetch -q "${remote:-origin}" "refs/heads/$sbranch" 2>/dev/null &&
      subject=$(git -C "$repo_dir" log -1 --format=%s "$left" 2>/dev/null) || subject=""
    prs=$(cd "$repo_dir" && "${CHECKPOINT_GH_BIN:-gh}" pr list --head "$sbranch" --state open \
      --json number --jq length 2>/dev/null) || prs=""
    if [[ "$subject" != "wip(resolve-issue #$issue): "* || "$prs" != 0 ]]; then
      print -u2 -- "checkpoint: $sbranch is on the remote at $left and no kept state leases it — it is not a killed run's wip checkpoint with no open PR, so a fresh run may not replace it; delete the remote branch or resume the run that left it"
      exit 1
    fi
    l_sha="$left"; have_lease=1
  fi
  # the head the first checkpoint push may replace: the kept checkpoint's own
  # SHA for this branch, else the branch's remote head as it is now, before any
  # work — never re-read at push time, which would lease nothing
  if (( ! have_lease )) && [[ -e "$marker" ]] &&
     [[ "$(jq -r '.branch // ""' "$marker" 2>/dev/null)" == "$sbranch" ]]; then
    l_sha=$(jq -r '.sha // ""' "$marker" 2>/dev/null) || l_sha=""
    [[ -n "$l_sha" ]] && have_lease=1
  fi
  if (( ! have_lease )); then
    if l_sha=$(_remote_head "$sbranch"); then
      [[ -n "$l_sha" ]] && have_lease=1
    else
      print -u2 -- "checkpoint: could not read the remote head of $sbranch — no lease is recorded, so the first checkpoint push must fast-forward"
    fi
  fi
  local dest=""
  if (( ${#kept} )); then
    dest="$base.superseded-$(date -u +%Y%m%dT%H%M%SZ)"
    [[ -e "$dest" ]] && dest="$dest-$$"
    mv -- "$base" "$dest" || { print -u2 -- "checkpoint: could not move $base aside"; exit 1 }
  fi
  mkdir -p -- "$base" || { print -u2 -- "checkpoint: could not create $base"; exit 1 }
  local lease_json='null'
  if (( have_lease )); then
    lease_json=$(jq -nc --arg b "$sbranch" --arg s "$l_sha" '{branch: $b, sha: $s}')
    print -r -- "$lease_json" > "$lease" || { print -u2 -- "checkpoint: could not write $lease"; exit 1 }
  fi
  jq -nc --arg d "$dest" --argjson l "$lease_json" --args \
    '{superseded_to: (if $d == "" then null else $d end), kept: $ARGS.positional, lease: $l}' "${kept[@]}"
  ;;
esac
