#!/usr/bin/env zsh
# Is this bug's spec confirmed by a code owner? (#3212). The gate between the
# two steps of the bugs concern (reference/bugs.md): analysis writes a bug spec,
# a code owner confirms it with the `confirmed` label, and only a bug this
# script passes may be fixed unattended.
#
# Usage:
#   check-bug-confirmation.zsh <issue-number> [--repo <owner/name>]
#       [--repo-dir <dir>] [--owners-file <file>]
#
# --repo defaults to the session's repo (`gh repo view`). The code owners come
# from --owners-file (one login per line, as codeowners-logins.zsh prints them)
# or else from codeowners-logins.zsh over --repo-dir (default: the current
# directory). One GraphQL read fetches the body, its last edit time, the labels
# and the issue's label events.
#
# The checks, in this order; the first that fails is the reason:
#   no-spec                  no bug-spec/v1 on the body, or one bug-spec.zsh
#                            cannot read
#   not-a-bug                the spec's verdict is `not-a-bug`
#   spec-prose-edited        the block's prose_sha256 no longer matches the
#                            prose; only a new analysis re-renders it
#   no-label                 the issue does not carry `confirmed`
#   label-not-by-code-owner  the latest event that applied `confirmed` was not a
#                            code owner's — an issue form or a bot applying it,
#                            or a repo with no code owners at all
#   spec-edited-after-label  the body was edited after that event
#
# Exit codes:
#   0  confirmed; stdout is {"issue", "confirmed_by", "labelled_at"}
#   1  not confirmed; stderr is one line `bug-confirmation: <reason>`
#   2  usage
#   3  could not decide: jq missing, the issue could not be read, the spec
#      reader or the code-owner lookup failed — never read as either answer

emulate -L zsh
set -uo pipefail

me="check-bug-confirmation"
here="${0:A:h}"

usage() {
  print -u2 "usage: check-bug-confirmation.zsh <issue-number> [--repo <owner/name>] [--repo-dir <dir>] [--owners-file <file>]"
  exit 2
}

issue="" repo="" repo_dir="." owners_file=""
while (( $# > 0 )); do
  case "$1" in
    --repo) (( $# >= 2 )) && [[ -n "$2" ]] || usage; repo="$2"; shift 2 ;;
    --repo-dir) (( $# >= 2 )) && [[ -n "$2" ]] || usage; repo_dir="$2"; shift 2 ;;
    --owners-file) (( $# >= 2 )) && [[ -n "$2" ]] || usage; owners_file="$2"; shift 2 ;;
    -*) usage ;;
    *) [[ -z "$issue" ]] || usage; issue="$1"; shift ;;
  esac
done
[[ "$issue" == <1-> ]] || usage
[[ -z "$repo" || "$repo" == ?*/?* ]] || usage

command -v jq >/dev/null 2>&1 || { print -u2 "$me: jq not found on PATH"; exit 3; }

not_confirmed() {
  print -u2 -r -- "bug-confirmation: $1"
  exit 1
}

if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" && [[ "$repo" == ?*/?* ]] || {
    print -u2 "$me: could not determine the repo; pass --repo"
    exit 3
  }
fi

query='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      body
      lastEditedAt
      labels(first: 100) { nodes { name } }
      timelineItems(itemTypes: [LABELED_EVENT], last: 100) {
        nodes { ... on LabeledEvent { createdAt label { name } actor { login } } }
      }
    }
  }
}'
if ! raw="$(gh api graphql -f query="$query" -f owner="${repo%%/*}" -f name="${repo#*/}" -F number="$issue" 2>/dev/null)" \
    || ! doc="$(print -r -- "$raw" | jq -ce '.data.repository.issue | select(type == "object")' 2>/dev/null)"; then
  print -u2 "$me: could not read issue #$issue of $repo"
  exit 3
fi

tmp="$(mktemp "${TMPDIR:-/tmp}/bug-confirmation.XXXXXX")" || exit 3
trap 'rm -f -- "$tmp"' EXIT
print -r -- "$doc" | jq -r '.body // ""' > "$tmp"
spec="$(zsh "$here/bug-spec.zsh" read --body-file "$tmp" 2>/dev/null)"
case $? in
  0) ;;
  1) not_confirmed no-spec ;;
  *) print -u2 "$me: bug-spec.zsh could not read the body"; exit 3 ;;
esac

[[ "$(print -r -- "$spec" | jq -r '.block.verdict')" == bug ]] || not_confirmed not-a-bug
[[ "$(print -r -- "$spec" | jq -r '(.block.provenance.prose_sha256 // "") == .prose_sha256')" == true ]] \
  || not_confirmed "spec-prose-edited (the prose no longer matches its hash)"

print -r -- "$doc" | jq -e '[.labels.nodes[].name] | index("confirmed") != null' >/dev/null || not_confirmed no-label

event="$(print -r -- "$doc" | jq -c '[.timelineItems.nodes[] | select(.label.name? == "confirmed")] | last // empty')"
[[ -n "$event" ]] || not_confirmed "label-not-by-code-owner (no event applying it was found)"
actor="$(print -r -- "$event" | jq -r '.actor.login // "" | ascii_downcase')"
labelled_at="$(print -r -- "$event" | jq -r '.createdAt')"

if [[ -n "$owners_file" ]]; then
  [[ -r "$owners_file" ]] || { print -u2 "$me: cannot read: $owners_file"; exit 3; }
  owners="$(cat -- "$owners_file")"
else
  owners="$(zsh "$here/codeowners-logins.zsh" --repo-dir "$repo_dir" 2>/dev/null)"
  case $? in
    0) ;;
    3) not_confirmed "label-not-by-code-owner (the repo has no code owners)" ;;
    *) print -u2 "$me: codeowners-logins.zsh failed"; exit 3 ;;
  esac
fi
typeset -a owner_list=(${(fL)owners})
[[ -n "$actor" ]] && (( ${owner_list[(Ie)$actor]} )) || not_confirmed label-not-by-code-owner

edited="$(print -r -- "$doc" | jq -r '.lastEditedAt // ""')"
[[ -z "$edited" || ! "$edited" > "$labelled_at" ]] \
  || not_confirmed "spec-edited-after-label (the body was edited after the label)"

jq -cn --argjson n "$issue" --arg by "$actor" --arg at "$labelled_at" \
  '{issue: $n, confirmed_by: $by, labelled_at: $at}'
