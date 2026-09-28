#!/usr/bin/env zsh
# read-prior-story-specs.zsh — read the story-spec/v1 blocks of the newest
# completed stories on one interface surface (#1363, slice 3 of #1266).
#
# issue-refiner's cross-feature-consistency slice proposes the choices a new
# story's predecessors already settled, so the story is built like the last
# five instead of re-deciding the error-body shape, the pagination convention
# and the rest. This is the bounded primitive it reads those predecessors with,
# straight from the issues themselves — there is no index artifact to drift.
#
# It makes ONE `gh issue list --state closed --limit 30 --json
# number,body,stateReason` call, keeps only the issues closed as COMPLETED — a
# story closed as not planned or as a duplicate settled nothing, however
# refined its block — sorts them by issue number descending (the number is
# monotonic and never edited, unlike a close date), extracts each candidate's
# block with resolve-issue's read-story-spec.zsh — the family's one
# CommonMark-aware fence extractor, called rather than reimplemented — keeps
# the blocks whose `interface_surfaces` contains <surface>, and stops as soon as
# five are emitted. Cost is bounded on both axes by construction: one list
# call, at most 30 bodies parsed locally, at most five blocks out, no paging. A
# repo with more than 30 closed issues has only its 30 newest considered, by
# design.
#
# Each emitted block is one compact JSON Lines record, newest first:
#   {"issue": <n>, "spec": <block>}
# — the block and its issue number (a block does not carry its own), never the
# surrounding issue prose.
#
# Per candidate: read-story-spec.zsh's exit 1 (no usable block — absent, or
# present but unparseable), or a block with no `interface_surfaces` array, skips
# that candidate with one stderr line naming it; a parseable block naming
# another surface is skipped silently, since it is not malformed; the
# extractor's exit 3 propagates as 3. The extractor also exits 1 on some of its
# own I/O failures (its header says so), which this script cannot tell apart
# from "no usable block".
#
# Exit codes:
#   0 — at least one block was emitted (JSON Lines on stdout)
#   1 — no completed story on that surface, among the 30 newest closed issues,
#       carries a usable block (not an error; the normal early state — the
#       caller says so and skips the slice). Empty stdout.
#   2 — usage error (a missing --repo/--surface, a --surface outside
#       rest|grpc|web-ui|cli, an unknown flag — `--limit` included: the cap is
#       fixed at five on purpose)
#   3 — runtime error (gh or jq missing, the gh call failing or returning
#       anything but an array of numbered issues, the extractor missing or
#       failing, a scratch-file or jq step failing)
#
# Usage:
#   read-prior-story-specs.zsh --repo OWNER/NAME --surface <rest|grpc|web-ui|cli>
#
# Test seam:
#   GH_BIN  overrides the `gh` binary.

emulate -L zsh
set -euo pipefail

local repo="" surface=""
while (( $# > 0 )); do
  case "$1" in
    --repo|--surface)
      (( $# >= 2 )) || { print -u2 "read-prior-story-specs.zsh: $1 needs a value"; exit 2; }
      if [[ "$1" == --repo ]]; then repo="$2"; else surface="$2"; fi
      shift 2 ;;
    -h|--help)
      print -r -- "usage: read-prior-story-specs.zsh --repo OWNER/NAME --surface <rest|grpc|web-ui|cli>"
      print -r -- "prints up to five {issue, spec} JSON Lines, newest first; exit 1 when none match."
      exit 0 ;;
    *) print -u2 "read-prior-story-specs.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$repo" ]] || { print -u2 "read-prior-story-specs.zsh: --repo is required"; exit 2; }
[[ -n "$surface" ]] || { print -u2 "read-prior-story-specs.zsh: --surface is required"; exit 2; }
[[ "$surface" == (rest|grpc|web-ui|cli) ]] \
  || { print -u2 "read-prior-story-specs.zsh: --surface must be one of rest|grpc|web-ui|cli (got: $surface)"; exit 2; }

# Every runtime failure is typed 3: a bare errexit exit would surface as 1 (read
# by the caller as "no precedent yet") or as jq's own 2/5.
die() { print -u2 "read-prior-story-specs.zsh: $1"; exit 3; }

local gh_bin="${GH_BIN:-gh}"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
command -v "$gh_bin" >/dev/null 2>&1 || die "gh binary not found: $gh_bin"

# Same plugin, sibling skill: an install carries both, so the relative path holds.
local extractor="${0:A:h}/../../resolve-issue/scripts/read-story-spec.zsh"
[[ -f "$extractor" ]] || die "extractor not found: $extractor"

local tmpdir
tmpdir="$(mktemp -d)" || die "mktemp failed"
trap 'rm -rf "$tmpdir"' EXIT

"$gh_bin" issue list --repo "$repo" --state closed --limit 30 --json number,body,stateReason \
  > "$tmpdir/list.json" \
  || die "gh issue list failed for $repo"
jq -e 'type == "array" and all(.[]; type == "object" and (.number | type) == "number")' \
  "$tmpdir/list.json" >/dev/null 2>&1 \
  || die "gh issue list did not return an array of numbered issues"

# Completed only, newest first, and never more than the 30 the call asked for.
jq -c 'sort_by(-.number) | .[:30] | map(select(.stateReason == "COMPLETED"))' \
  "$tmpdir/list.json" > "$tmpdir/sorted.json" \
  || die "could not sort the candidates"

local total emitted=0 i n spec rc
total="$(jq 'length' "$tmpdir/sorted.json")" || die "could not count the candidates"
for (( i = 0; i < total && emitted < 5; i++ )); do
  n="$(jq -r ".[$i].number" "$tmpdir/sorted.json")" || die "could not read candidate $i"
  jq -r ".[$i].body // \"\"" "$tmpdir/sorted.json" > "$tmpdir/body.md" \
    || die "could not write candidate #$n's body"
  rc=0
  spec="$(zsh "$extractor" --file "$tmpdir/body.md")" || rc=$?
  case $rc in
    0) ;;
    1) print -u2 "read-prior-story-specs.zsh: #$n: no usable story-spec/v1 block, skipped"; continue ;;
    3) die "#$n: read-story-spec.zsh failed (exit 3)" ;;
    *) die "#$n: read-story-spec.zsh exited $rc" ;;
  esac
  if ! print -r -- "$spec" | jq -e '.interface_surfaces | type == "array"' >/dev/null 2>&1; then
    print -u2 "read-prior-story-specs.zsh: #$n: no usable story-spec/v1 block, skipped"
    continue
  fi
  print -r -- "$spec" | jq -e --arg s "$surface" 'any(.interface_surfaces[]; . == $s)' >/dev/null 2>&1 \
    || continue
  print -r -- "$spec" | jq -c --argjson n "$n" '{issue: $n, spec: .}' || die "could not emit #$n"
  (( emitted += 1 ))
done

(( emitted > 0 )) || exit 1
exit 0
