#!/usr/bin/env zsh
# sync-prs.zsh — re-sync open Maintenance-App PRs that have become conflicting
# with main since they were opened (#1823, epic #1820).
#
# Run from inside the repository. It lists the open PRs and, for each bot PR
# whose `mergeable` is CONFLICTING and whose head lives in this repository, in
# order of PR number:
#   1. adds a scratch worktree (detached) on the PR head, under a temp dir;
#   2. runs development/scripts/merge/rebase-onto-main.zsh inside it;
#   3. on `clean` or `resolved`, force-pushes the rebased head as the
#      Maintenance App, the lease pinned to the pre-rebase sha, then re-triggers
#      CI with retrigger-pr-ci.zsh --grace 0 — a push made with an App
#      installation token to an open PR runs no workflows (#605), so without the
#      close+reopen nudge armed auto-merge would never fire;
#   4. on `conflict`, adds the `needs-manual-rebase` label (created if absent)
#      and, once the label is on, posts one PR comment naming the conflicting
#      files — label first, so a PR whose label failed is retried by the next
#      run rather than commented on again;
#   5. removes the worktree, on every path.
# A PR authored by anyone else is reported and never touched, a labelled bot PR
# is skipped until the label is removed, and a PR whose `mergeable` GitHub is
# still computing (UNKNOWN) is skipped and picked up by a later run. MERGEABLE
# PRs have nothing to do and are left out of the report.
#
# The token is minted once, at the first push, comment or label, and never
# under --dry-run. It stays in the mode-600 file the mint script writes: `git
# push` reads it through a credential helper and `gh` through GH_TOKEN, each at
# the point of use, so the value is never in argv, a URL, stdout or stderr. The
# push pins its URL against url.*.insteadOf / pushInsteadOf prefix rewrites
# (such as https://github.com/ → git@github.com:), which would otherwise send it
# over another transport under the user's identity; the pin is the full URL, so
# it outranks any shorter prefix.
#
# Usage:
#   sync-prs.zsh [--dry-run]
#
#   --dry-run  runs the rebases, but pushes, comments and labels nothing and
#              never invokes the mint script; each entry says what would happen
#
# Stdout: one JSON object, {"prs": [{number, verdict, action, resolved, reason}]}
#   verdict   the engine's verdict (clean | resolved | conflict), null when the
#             engine did not run or printed none
#   action    pushed | push-rejected | conflict | engine-failed | unchanged |
#             skipped | failed | would-push | would-mark-conflict
#   resolved  the engine's resolved records ([] when none)
#   reason    why, for anything but a plain success; the CI nudge's outcome on
#             `pushed`
#
# Exit codes:
#   0    every PR was handled — conflicts, skips and per-PR failures included
#   2    usage
#   3    runtime: gh, git or jq unavailable, not in a git work tree, the repo or
#        PR listing failed, a temp file could not be written, or the token mint
#        failed — all before any PR was changed, since the mint precedes the
#        first push, comment or label. The one exception is a report that
#        cannot be assembled at the end, after the per-PR work. Stdout is empty.
#   130  interrupted (INT, TERM or HUP); stdout is empty, the scratch worktrees
#        and the token file are removed
#
# Seams (tests): SYNC_PRS_ENGINE, SYNC_PRS_MINT, SYNC_PRS_RETRIGGER replace the
# engine, the mint script and the CI nudge; SYNC_PRS_PUSH_URL replaces the push
# target (default https://github.com/<owner/name>.git).

emulate -L zsh
setopt nounset pipefail

local here="${0:A:h}"
local dev="${here:h:h:h}"
local engine="${SYNC_PRS_ENGINE:-$dev/scripts/merge/rebase-onto-main.zsh}"
local mint="${SYNC_PRS_MINT:-$dev/skills/maintenance/scripts/mint-maintenance-token.zsh}"
local retrigger="${SYNC_PRS_RETRIGGER:-$dev/skills/maintenance/scripts/retrigger-pr-ci.zsh}"
local LABEL="needs-manual-rebase"

die() { print -u2 -- "sync-prs: $1"; exit 3 }

local dry_run=false
while (( $# )); do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    *) print -u2 -- "sync-prs: unknown argument: $1
usage: sync-prs.zsh [--dry-run]"; exit 2 ;;
  esac
done

local t
for t in gh git jq; do
  command -v "$t" >/dev/null 2>&1 || die "$t not found on PATH"
done

local top
top="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$top" ]] || die "not inside a git work tree"
cd -- "$top" || die "cannot enter $top"

local repo
repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)" && [[ "$repo" == */* ]] \
  || die "gh repo view failed"
local push_url="${SYNC_PRS_PUSH_URL:-https://github.com/$repo.git}"
# The Maintenance App of this repository's owner (the App the mint script
# mints, #1683): gh spells its login app/<slug>, the REST API <slug>[bot].
local slug="claude-maintenance-${${repo%%/*}:l}"

local listing
listing="$(gh pr list -R "$repo" --state open --limit 500 \
  --json number,headRefName,author,mergeable,labels,isCrossRepository)" \
  || die "gh pr list failed"

# One line per reported PR: {number, branch, kind, reason}; kind is candidate or
# skipped. Precedence: author, cross-repo head, label, then mergeable.
local plan
plan="$(jq -c --arg slug "$slug" --arg label "$LABEL" '
  sort_by(.number)[]
  | select(.mergeable == "CONFLICTING" or .mergeable == "UNKNOWN")
  | ((.author.login // "") | ascii_downcase) as $login
  | {number, branch: .headRefName}
    + if ($login != "app/\($slug)" and $login != "\($slug)[bot]") then {kind: "skipped", reason: "human-authored"}
      elif .isCrossRepository == true then {kind: "skipped", reason: "cross-repository"}
      elif ([.labels[]?.name] | index($label)) != null then {kind: "skipped", reason: "labelled"}
      elif .mergeable == "UNKNOWN" then {kind: "skipped", reason: "mergeable-unknown"}
      else {kind: "candidate", reason: null} end
' <<<"$listing")" || die "cannot read the gh pr list output"

local tmp="" token_file=""
cleanup() {
  [[ -n "$token_file" ]] && rm -f -- "$token_file"
  if [[ -n "$tmp" ]]; then
    local w
    for w in "$tmp"/pr-*(N/); do git worktree remove --force -- "$w" >/dev/null 2>&1; done
    git worktree prune >/dev/null 2>&1
    rm -rf -- "$tmp"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

tmp="$(mktemp -d "${TMPDIR:-/tmp}/sync-prs.XXXXXX")" || die "mktemp failed"

local report="$tmp/report.jsonl"
: > "$report" || die "cannot create $report"

# need_token — mint on first use. Called as a plain command, never in $(…), so
# token_file survives; every PR change comes after it, so a failed mint exits 3
# before any PR was touched.
need_token() {
  [[ -n "$token_file" ]] && return 0
  token_file="$(zsh "$mint")" && [[ -n "$token_file" && -r "$token_file" ]] \
    || { token_file=""; die "the Maintenance App token mint failed (${mint:t})"; }
}

# entry <number> <verdict|""> <action> <resolved json> <reason|"">
entry() {
  jq -nc --argjson n "$1" --arg v "$2" --arg a "$3" --argjson r "$4" --arg why "$5" \
    '{number: $n, verdict: (if $v == "" then null else $v end), action: $a,
      resolved: $r, reason: (if $why == "" then null else $why end)}' >> "$report"
}

# The last non-empty line of a file, with the token (if any) masked.
last_line() {
  local l
  l="$(grep -v '^[[:space:]]*$' -- "$1" 2>/dev/null | tail -n 1)"
  local tok=""
  [[ -n "$token_file" && -r "$token_file" ]] && tok="$(<"$token_file")"
  [[ -n "$tok" ]] && l="${l//${(b)tok}/***}"
  print -r -- "$l"
}

gh_bot() { GH_TOKEN="$(<"$token_file")" gh "$@" }

# mark_conflict <number> <files json> — the label, then one comment; sets
# MARK_WHY to what failed ("" when both landed). Called as a plain command,
# never in $(…), so label_ready and the token survive to the next conflict.
local label_ready=false MARK_WHY=""
mark_conflict() {
  local n="$1" files="$2" list body
  MARK_WHY=""
  need_token
  if [[ $label_ready == false ]]; then
    # An existing label is the ordinary case; any other failure surfaces at the
    # add below, so it is not remembered as ready.
    if gh_bot label create "$LABEL" -R "$repo" --color d93f0b \
        --description "sync-prs could not rebase this PR onto main; rebase it by hand" \
        >/dev/null 2>"$tmp/gh.err" || grep -qi 'already exists' "$tmp/gh.err"; then
      label_ready=true
    fi
  fi
  if ! gh_bot pr edit "$n" -R "$repo" --add-label "$LABEL" >/dev/null 2>"$tmp/gh.err"; then
    MARK_WHY="the label failed, so no comment was posted and the next run retries: $(last_line "$tmp/gh.err")"
    return
  fi
  list="$(jq -r '.[] | "- `\(.)`"' <<<"$files")"
  body="sync-prs could not rebase this PR onto \`main\`: the rebase stopped on a conflict the merge driver does not resolve.

Conflicting files:
$list

Rebase it by hand, then remove the \`$LABEL\` label so later sync-prs runs pick it up again."
  gh_bot pr comment "$n" -R "$repo" --body "$body" >/dev/null 2>"$tmp/gh.err" \
    || MARK_WHY="the comment failed: $(last_line "$tmp/gh.err")"
}

sync_one() {
  local n="$1" branch="$2" wt="$tmp/pr-$1" err="$tmp/pr-$1.err"
  if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    entry "$n" "" failed '[]' "head branch name is not a valid branch: $branch"; return
  fi
  if ! git fetch -q origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" 2>"$err"; then
    entry "$n" "" failed '[]' "git fetch of $branch failed: $(last_line "$err")"; return
  fi
  local pre
  pre="$(git rev-parse --verify -q "refs/remotes/origin/$branch^{commit}")" \
    || { entry "$n" "" failed '[]' "origin/$branch does not resolve after the fetch"; return; }
  if ! git worktree add -q --detach "$wt" "$pre" 2>"$err"; then
    entry "$n" "" failed '[]' "git worktree add failed: $(last_line "$err")"; return
  fi

  local out rc=0
  out="$(cd -- "$wt" && zsh "$engine" 2>"$err")" || rc=$?
  # Exit 0 must carry clean/resolved and exit 1 conflict; any other exit (2
  # usage, 3 runtime) carries no verdict, so its stdout is never parsed.
  local verdict="" resolved files
  case $rc in
    0) verdict="$(jq -er '.verdict | select(. == "clean" or . == "resolved")' <<<"$out" 2>/dev/null)" ;;
    1) verdict="$(jq -er '.verdict | select(. == "conflict")' <<<"$out" 2>/dev/null)" ;;
  esac
  if [[ -z "$verdict" ]]; then
    entry "$n" "" engine-failed '[]' "rebase engine exited ${rc}: $(last_line "$err")"
    return
  fi
  resolved="$(jq -c '.resolved // []' <<<"$out")"

  if [[ "$verdict" == conflict ]]; then
    files="$(jq -c '.files // []' <<<"$out")"
    if [[ $dry_run == true ]]; then
      entry "$n" conflict would-mark-conflict '[]' "conflicting files: $(jq -r 'join(", ")' <<<"$files")"
    else
      mark_conflict "$n" "$files"
      entry "$n" conflict conflict '[]' "conflicting files: $(jq -r 'join(", ")' <<<"$files")${MARK_WHY:+; $MARK_WHY}"
    fi
    return
  fi

  local head base
  head="$(git -C "$wt" rev-parse HEAD)"
  if [[ "$head" == "$pre" ]]; then
    entry "$n" "$verdict" unchanged "$resolved" "the head is already on main's tip; nothing to push"; return
  fi
  base="$(jq -r '.base // empty' <<<"$out")"
  if [[ -n "$base" && "$(git -C "$wt" rev-list --count "$base..HEAD")" == 0 ]]; then
    entry "$n" "$verdict" skipped "$resolved" "empty-after-rebase: every commit is already on main"; return
  fi
  if [[ $dry_run == true ]]; then
    entry "$n" "$verdict" would-push "$resolved" "would force-push $head over $pre"; return
  fi

  need_token
  # The helper reads the token file at the point of use; the value never
  # reaches argv or the URL. The empty helper first drops any configured one,
  # the identity insteadOf mappings pin the URL (the longest match wins), and a
  # rejected token fails instead of prompting.
  local helper="!f() { echo username=x-access-token; printf 'password=%s\\n' \"\$(cat ${(qq)token_file})\"; }; f"
  if ! GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= git -C "$wt" \
      -c credential.helper= -c "credential.helper=$helper" \
      -c "url.${push_url}.insteadOf=${push_url}" -c "url.${push_url}.pushInsteadOf=${push_url}" \
      push -q "$push_url" "HEAD:refs/heads/$branch" \
      --force-with-lease="refs/heads/${branch}:${pre}" 2>"$err"; then
    # git's `! [rejected]` / `! [remote rejected]` line names the cause (stale
    # info, a declined hook); its closing line only says the push failed.
    local cause
    cause="$(grep -m 1 '^ *! \[' "$err" 2>/dev/null)"
    entry "$n" "$verdict" push-rejected "$resolved" "${cause:-$(last_line "$err")}"; return
  fi

  local nudge nrc=0 why
  nudge="$(GH_TOKEN="$(<"$token_file")" zsh "$retrigger" --repo "$repo" --grace 0 "$n" 2>"$err")" || nrc=$?
  nudge="$(print -r -- "$nudge" | grep '^result:' | tail -n 1)"
  if (( nrc != 0 )); then
    why="pushed, but re-triggering CI failed (exit $nrc): ${nudge:-$(last_line "$err")}"
  elif [[ "$nudge" == "result: NUDGED-REARM-FAILED"* ]]; then
    why="pushed, but re-arming auto-merge failed; re-arm it by hand: $nudge"
  else
    why="${nudge:-result: (none)}"
  fi
  entry "$n" "$verdict" pushed "$resolved" "$why"
}

local line n branch kind reason
for line in "${(@f)plan}"; do
  [[ -n "$line" ]] || continue
  n="$(jq -r .number <<<"$line")"
  kind="$(jq -r .kind <<<"$line")"
  if [[ "$kind" == skipped ]]; then
    entry "$n" "" skipped '[]' "$(jq -r .reason <<<"$line")"
    continue
  fi
  branch="$(jq -r .branch <<<"$line")"
  sync_one "$n" "$branch"
  git worktree remove --force -- "$tmp/pr-$n" >/dev/null 2>&1
done

jq -sc '{prs: .}' "$report" || die "cannot assemble the report"
exit 0
