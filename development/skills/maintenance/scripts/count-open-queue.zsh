#!/usr/bin/env zsh
# Count the maintenance PRs waiting for a human: the open-queue figure a
# scheduled run checks against its cap before opening a PR (#3214).
#
# Usage:
#   count-open-queue.zsh [--repo <owner/name>]
#
# stdout: one integer — the open PRs authored by the repo owner's Maintenance
#         App (its slug from the App registry, ~/.config/claude-plugins/apps.json,
#         else `claude-maintenance-<owner>`; as `app/<slug>` or `<slug>[bot]`,
#         matched case-insensitively) that
#         carry no approving review, i.e. no entry of `latestReviews` in state
#         APPROVED. A PR anyone else opened —
#         Dependabot, Renovate, Snyk or a human — is never counted.
#         Without --repo, gh reads the repo of the current directory.
#
# Exit codes:
#   0  the count printed
#   1  internal failure: gh or jq missing, the repo unreadable, `gh pr list`
#      failing, or its output not one JSON array; nothing is printed, which is
#      never a count of zero
#   2  usage: an unknown argument, a repeated --repo, or --repo without a value

set -uo pipefail

usage() {
  print -u2 "usage: count-open-queue.zsh [--repo <owner/name>]"
  exit 2
}

repo=""
while (( $# > 0 )); do
  case "$1" in
    --repo)
      (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || { print -u2 "count-open-queue.zsh: --repo needs a value"; usage; }
      [[ -z "$repo" ]] || { print -u2 "count-open-queue.zsh: --repo given twice"; usage; }
      repo="$2"
      shift 2 ;;
    *) print -u2 "count-open-queue.zsh: unknown argument '$1'"; usage ;;
  esac
done

for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 || { print -u2 "count-open-queue.zsh: $tool not found"; exit 1; }
done

[[ -n "$repo" ]] || repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
[[ "$repo" == */* ]] || { print -u2 "count-open-queue.zsh: could not read the repo's owner"; exit 1; }
owner="${${repo%%/*}:l}"
slug="$(jq -r --arg o "$owner" '.owners[$o].claude_maintenance.slug // empty' "$HOME/.config/claude-plugins/apps.json" 2>/dev/null)"
[[ -n "$slug" ]] || slug="claude-maintenance-$owner"
slug="${slug:l}"

prs="$(gh pr list --repo "$repo" --state open --limit 1000 --json number,author,latestReviews)" || { print -u2 "count-open-queue.zsh: gh pr list failed"; exit 1; }

jq -e -s 'length == 1 and (.[0] | type == "array")' >/dev/null 2>&1 <<<"$prs" || {
  print -u2 "count-open-queue.zsh: gh pr list did not return one JSON array"
  exit 1
}

jq --arg slug "$slug" '[ .[]
      | select(((.author.login // "") | ascii_downcase) as $l | $l == "app/\($slug)" or $l == "\($slug)[bot]")
      | select([(.latestReviews // [])[] | select(.state == "APPROVED")] | length == 0)
    ] | length' <<<"$prs" || {
  print -u2 "count-open-queue.zsh: jq failed counting the queue"
  exit 1
}
