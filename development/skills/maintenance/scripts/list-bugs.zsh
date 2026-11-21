#!/usr/bin/env zsh
# Every open bug issue, classified for the bugs concern of
# /development:maintenance (#3212; reference/bugs.md walks the result).
#
# Usage:
#   list-bugs.zsh [--repo <owner/name>] [--repo-dir <dir>]
#
# --repo defaults to the session's repo (`gh repo view`); --repo-dir is the
# checkout whose CODEOWNERS decides who is a code owner (default: the current
# directory). It reads the open `bug`-labelled issues, the open PRs' closing
# references, the code owners (codeowners-logins.zsh) and, for each eligible
# bug that is not held, check-bug-confirmation.zsh's answer.
#
# Output: one JSON array, one object per open bug — number, title, author,
# priority_high (it carries `priority: high`), created_at, state, reason. The
# state is the first that applies:
#   not-eligible           the author is not a code owner, or the repo has no
#                          code owners at all — the reason says which
#   held                   it carries needs-refinement, blocked or
#                          needs-human-decision, or an open PR closes it
#   needs-analysis         no bug spec yet, or its prose was edited since it was
#                          rendered (spec-prose-edited)
#   not-a-bug              the spec's verdict is not-a-bug
#   awaiting-confirmation  a bug spec no code owner's `confirmed` label covers;
#                          the reason is check-bug-confirmation.zsh's
#   confirmed              check-bug-confirmation.zsh exits 0
# Sorted confirmed, needs-analysis, awaiting-confirmation, not-a-bug, held,
# not-eligible; within a state priority_high first, then oldest, then lowest
# number.
#
# Exit codes:
#   0  printed (`[]` when there is no open bug)
#   1  internal failure: jq missing, a gh read failed, the code-owner lookup or
#      the confirmation check could not decide
#   2  usage

emulate -L zsh
set -uo pipefail

me="list-bugs"
here="${0:A:h}"

usage() {
  print -u2 "usage: list-bugs.zsh [--repo <owner/name>] [--repo-dir <dir>]"
  exit 2
}

repo="" repo_dir="."
while (( $# > 0 )); do
  case "$1" in
    --repo) (( $# >= 2 )) && [[ "$2" == ?*/?* ]] || usage; repo="$2"; shift 2 ;;
    --repo-dir) (( $# >= 2 )) && [[ -d "$2" ]] || usage; repo_dir="$2"; shift 2 ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || { print -u2 "$me: jq not found on PATH"; exit 1; }

if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" && [[ "$repo" == ?*/?* ]] || {
    print -u2 "$me: could not determine the repo; pass --repo"
    exit 1
  }
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/list-bugs.XXXXXX")" || exit 1
trap 'rm -rf -- "$tmp"' EXIT

no_owners=""
zsh "$here/codeowners-logins.zsh" --repo-dir "$repo_dir" > "$tmp/owners" 2> "$tmp/owners.err"
case $? in
  0) ;;
  3) no_owners="$(sed -n 1p "$tmp/owners.err")"; no_owners="${no_owners#codeowners-logins: }" ;;
  *) print -u2 "$me: codeowners-logins.zsh failed: $(sed -n 1p "$tmp/owners.err")"; exit 1 ;;
esac
typeset -a owners=(${(f)"$(<"$tmp/owners")"})

if ! gh issue list --repo "$repo" --label bug --state open --limit 1000 \
    --json number,title,author,labels,createdAt > "$tmp/issues" 2>/dev/null \
    || ! jq -e 'type == "array"' "$tmp/issues" >/dev/null 2>&1; then
  print -u2 "$me: could not list the open bug issues of $repo"
  exit 1
fi
if ! gh pr list --repo "$repo" --state open --limit 1000 \
    --json number,closingIssuesReferences > "$tmp/prs" 2>/dev/null \
    || ! jq -e 'type == "array"' "$tmp/prs" >/dev/null 2>&1; then
  print -u2 "$me: could not list the open PRs of $repo"
  exit 1
fi

# One line per issue: number, author (lowercased; a deleted account reads as
# GitHub's own `ghost`), then the hold reason or nothing — the only field that
# may be empty is the last, so tab-splitting never shifts a field.
rows="$(jq -r --slurpfile prs "$tmp/prs" '
  ($prs[0] | map(.number as $pr | (.closingIssuesReferences // [])[] | {key: (.number | tostring), value: $pr})
    | from_entries) as $open_pr
  | .[]
  | ([.labels[].name] | map(select(IN("needs-refinement", "blocked", "needs-human-decision")))) as $holds
  | [ (.number | tostring),
      ((.author.login // "ghost") | ascii_downcase),
      (if ($holds | length) > 0 then "carries \($holds | join(", "))"
       elif $open_pr[.number | tostring] then "open PR #\($open_pr[.number | tostring])"
       else "" end)
    ] | @tsv' "$tmp/issues")" || { print -u2 "$me: could not read the issue list"; exit 1; }

: > "$tmp/classified"
for row in ${(f)rows}; do
  IFS=$'\t' read -r number author hold <<< "$row"
  if [[ -n "$no_owners" ]]; then
    state=not-eligible reason="no code owners: $no_owners"
  elif (( ! ${owners[(Ie)$author]} )); then
    state=not-eligible reason="author @$author is not a code owner"
  elif [[ -n "$hold" ]]; then
    state=held reason="$hold"
  else
    zsh "$here/check-bug-confirmation.zsh" "$number" --repo "$repo" --owners-file "$tmp/owners" \
      > /dev/null 2> "$tmp/check.err"
    rc=$?
    why="$(sed -n 's/^bug-confirmation: //p' "$tmp/check.err" | sed -n 1p)"
    case "$rc:${why%% *}" in
      0:*) state=confirmed reason="confirmed by a code owner" ;;
      1:no-spec) state=needs-analysis reason="no bug spec yet" ;;
      1:spec-prose-edited) state=needs-analysis reason="$why" ;;
      1:not-a-bug) state=not-a-bug reason="the bug spec's verdict is not-a-bug" ;;
      1:?*) state=awaiting-confirmation reason="$why" ;;
      *)
        print -u2 "$me: check-bug-confirmation.zsh could not decide #$number: $(sed -n 1p "$tmp/check.err")"
        exit 1 ;;
    esac
  fi
  jq -cn --argjson n "$number" --arg s "$state" --arg r "$reason" \
    '{number: $n, state: $s, reason: $r}' >> "$tmp/classified"
done

jq -c --slurpfile cls "$tmp/classified" '
  ($cls | map({key: (.number | tostring), value: .}) | from_entries) as $by
  | {"confirmed": 0, "needs-analysis": 1, "awaiting-confirmation": 2, "not-a-bug": 3, "held": 4,
     "not-eligible": 5} as $rank
  | map({number, title, author: (.author.login // null),
        priority_high: ([.labels[].name] | index("priority: high") != null),
        created_at: .createdAt,
        state: $by[.number | tostring].state, reason: $by[.number | tostring].reason})
  | sort_by($rank[.state], (if .priority_high then 0 else 1 end), .created_at, .number)' "$tmp/issues"
