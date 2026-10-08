#!/usr/bin/env zsh
# never-approve-bar.zsh — the claude-plugin Approver's hard bar (#2132). A
# claude-plugin repo is the origin of every other repo, so even with
# CLAUDE_PLUGIN_APPROVER=1 these changes always go to a human: the agent posts
# COMMENT, never APPROVE.
#
# Usage: never-approve-bar.zsh --body <pr-body-file> --paths <changed-paths-file>
#   --body   the PR body; every hidden `<!-- review-dossier: {…} -->` block in it
#            is read, and a missing block or a missing `open` key counts as 0
#   --paths  one repo-relative path per line; pass a renamed file's old path
#            too, so a file moved out of the machinery still hits
#
# Stdout: one line per hit, residue first, then the paths in input order —
#   hit=residue open=<n>               sum of dimensions.*.open over every block
#   hit=workflow path=<p>              .github/workflows/*
#   hit=approval-machinery path=<p>    any path containing "approver" (any case),
#                                      anything under */skills/approve/, and
#                                      resolve-approval.zsh, claude-apps-owner.zsh,
#                                      install-claude-apps.zsh, register-claude-apps.zsh,
#                                      mint-maintenance-token.zsh
#
# Exit codes:
#   0 — clear: nothing hit, nothing printed
#   1 — a dossier block that is not valid JSON, or whose `open` is not a number;
#       or a paths file with no non-empty line (every PR changes a file).
#       Fail-closed: the bar cannot say "clear", so the skill posts nothing.
#   2 — usage error (missing, unknown or valueless argument, unreadable file)
#   3 — bar hit, one stdout line per hit

setopt err_exit nounset pipefail

usage() {
  print -u2 -- "usage: never-approve-bar.zsh --body <file> --paths <file>"
  exit 2
}

body="" paths=""
while (( $# )); do
  case "$1" in
    --body)  (( $# >= 2 )) || usage; body="$2"; shift 2 ;;
    --paths) (( $# >= 2 )) || usage; paths="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$body" && -n "$paths" && -r "$body" && -r "$paths" ]] || usage

# Every PR changes a file, so a paths file with no non-empty line means the
# upstream fetch failed: fail closed rather than read it as clear.
if ! grep -q . "$paths"; then
  print -u2 -- "never-approve-bar: no changed paths — cannot judge"
  exit 1
fi

hits=0

# Residue. Each block's payload is one JSON object on the block's own line, as
# build-dossier.zsh prints it. jq -s reads them all, so residue declared in a
# second block is not hidden behind a clean first one.
blocks=$(sed -n 's/.*<!-- review-dossier: \(.*\) -->.*/\1/p' "$body")
open=0
if [[ -n "$blocks" ]]; then
  if ! open=$(jq -se '[.[] | (.dimensions // {}) | .[] | (.open // 0)
                       | if type == "number" then . else error("open") end] | add // 0' \
                <<<"$blocks" 2>/dev/null); then
    print -u2 -- "never-approve-bar: a review-dossier block is not valid JSON with numeric open counts"
    exit 1
  fi
fi
if (( open > 0 )); then
  print -r -- "hit=residue open=$open"
  hits=1
fi

while IFS= read -r p || [[ -n "$p" ]]; do
  [[ -n "$p" ]] || continue
  case "${(L)p}" in
    .github/workflows/*)
      print -r -- "hit=workflow path=$p"; hits=1 ;;
    *approver*|*/skills/approve/*|(|*/)(resolve-approval|claude-apps-owner|install-claude-apps|register-claude-apps|mint-maintenance-token).zsh)
      print -r -- "hit=approval-machinery path=$p"; hits=1 ;;
  esac
done < "$paths"

(( hits )) && exit 3
exit 0
