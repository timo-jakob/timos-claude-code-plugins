#!/usr/bin/env zsh
# The code owners of a checkout, as GitHub logins (#3212). The bugs concern of
# /development:maintenance (reference/bugs.md) reads it twice: only a bug whose
# author is a code owner is eligible (list-bugs.zsh), and only a code owner's
# `confirmed` label makes a bug spec fixable (check-bug-confirmation.zsh).
#
# Usage:
#   codeowners-logins.zsh [--repo-dir <dir>]
#
# It reads the first CODEOWNERS file GitHub itself would read, in GitHub's order:
# `.github/CODEOWNERS`, `CODEOWNERS`, `docs/CODEOWNERS` under <dir> (default:
# the current directory). Every owner token after a line's path pattern counts:
#   - `@login`        -> that login;
#   - `@org/team`     -> the team's members, read with
#                        `gh api --paginate orgs/<org>/teams/<team>/members`;
#   - an e-mail entry -> skipped: it names no login a label event can carry.
# Comments (a line starting `#`, or a ` #` tail) and blank lines are skipped.
#
# Output: one login per line, lowercased (GitHub logins are case-insensitive),
# sorted and unique.
#
# Exit codes:
#   0  printed at least one login
#   1  internal failure: jq missing, or a team's members could not be read —
#      never a partial list, since a missing team member would wrongly read as
#      "not a code owner"
#   2  usage
#   3  no CODEOWNERS file, or a file that names no resolvable owner; stderr
#      says which

emulate -L zsh
set -uo pipefail

me="codeowners-logins"
repo_dir="."

usage() {
  print -u2 "usage: codeowners-logins.zsh [--repo-dir <dir>]"
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --repo-dir)
      (( $# >= 2 )) && [[ -n "$2" ]] || usage
      repo_dir="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -d "$repo_dir" ]] || { print -u2 "$me: not a directory: $repo_dir"; exit 2; }
command -v jq >/dev/null 2>&1 || { print -u2 "$me: jq not found on PATH"; exit 1; }

file=""
for candidate in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
  if [[ -f "$repo_dir/$candidate" ]]; then
    file="$candidate"
    break
  fi
done
if [[ -z "$file" ]]; then
  print -u2 "$me: no CODEOWNERS file (.github/CODEOWNERS, CODEOWNERS, docs/CODEOWNERS)"
  exit 3
fi

typeset -aU users teams
typeset -a words
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%$'\r'}"
  # a ` #` tail is a comment; a line whose first non-blank is `#` is one whole
  line="${line%%[[:space:]]\#*}"
  [[ "$line" =~ '^[[:space:]]*(#|$)' ]] && continue
  words=(${=line})
  (( ${#words} >= 2 )) || continue
  for word in "${words[@]:1}"; do
    if [[ "$word" == @*/* ]]; then
      teams+=("${word#@}")
    elif [[ "$word" == @* ]]; then
      users+=("${(L)${word#@}}")
    fi
    # anything else is an e-mail entry (or not an owner at all): skipped
  done
done < "$repo_dir/$file"

for team in "${teams[@]}"; do
  org="${team%%/*}"
  slug="${team#*/}"
  if ! raw="$(gh api --paginate "orgs/$org/teams/$slug/members" 2>/dev/null)" \
      || ! members="$(print -r -- "$raw" | jq -r '.[].login' 2>/dev/null)"; then
    print -u2 "$me: could not read the members of team @$team"
    exit 1
  fi
  for login in ${(f)members}; do
    [[ -n "$login" ]] && users+=("${(L)login}")
  done
done

if (( ${#users} == 0 )); then
  print -u2 "$me: $file names no resolvable owner"
  exit 3
fi

print -rl -- ${(o)users}
