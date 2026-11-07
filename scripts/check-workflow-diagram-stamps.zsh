#!/usr/bin/env zsh
# check-workflow-diagram-stamps.zsh — fail when a workflow diagram's
# drawn-against stamp no longer matches the heading structure of the sources it
# draws (#3024).
#
# A covered diagram's Mermaid source starts with one stamp line:
#
#   %% drawn-against: sha256=<hex> <source> [<source> ...]
#
# Each <source> is a path relative to --root: a workflow page
# (docs/explanation/workflow-*.md) or the SKILL.md it documents. <hex> is the
# sha256 of the sources' heading lines — lines starting with two to six `#`
# and a space — taken in the listed order and joined with newlines. A wording
# or link edit leaves the hash alone; adding, removing, renaming or reordering
# a heading moves it. The stamp is a tripwire, not a proof: a behaviour change
# written only inside a paragraph is not seen here.
#
# Covered diagrams, each of which must carry a stamp:
#   - every diagrams/<name>.svg a docs/explanation/workflow-*.md page embeds,
#     through its docs/explanation/diagrams/<name>.mmd source;
#   - docs/explanation/diagrams/sdlc.mmd.
# Any other docs/**/diagrams/*.mmd that carries a stamp is checked as well.
#
# Usage: check-workflow-diagram-stamps.zsh [--root <dir>]   (default: the repo)
#
# Exit 0 when every stamp is valid. Exit 1 when a covered diagram is missing,
# has no stamp, names a missing source, or carries a stale hash; each problem
# is one line on stdout, and a stale stamp is followed by the exact replacement
# line. Exit 2 on a usage error or when no sha256 tool is on PATH.

setopt nounset pipefail extended_glob

usage() { print -u2 -- "usage: ${0:t} [--root <dir>]"; exit 2 }

root="${0:A:h:h}"
while (( $# )); do
  case "$1" in
    --root) (( $# >= 2 )) && [[ -n "$2" ]] || usage; root="$2"; shift 2 ;;
    -h|--help) print -- "usage: ${0:t} [--root <dir>]"; exit 0 ;;
    *) usage ;;
  esac
done
[[ -d "$root" ]] || { print -u2 -- "${0:t}: not a directory: $root"; exit 2 }
cd "$root" || exit 2

if command -v sha256sum >/dev/null 2>&1; then
  sha() { sha256sum | cut -d' ' -f1 }
elif command -v shasum >/dev/null 2>&1; then
  sha() { shasum -a 256 | cut -d' ' -f1 }
else
  print -u2 -- "${0:t}: no sha256sum or shasum on PATH"; exit 2
fi

readonly PREFIX='%% drawn-against: '
readonly DIAGRAMS='docs/explanation/diagrams'

# heading_hash <source...> — the sha256 of the sources' heading lines.
heading_hash() {
  local src
  for src in "$@"; do
    grep -E '^#{2,6} ' -- "$src" || true
  done | sha
}

typeset -A covered   # diagram path -> why it is covered
local page ref
for page in docs/explanation/workflow-*.md(N); do
  # each embedded `](diagrams/<name>.svg)`, reduced to <name>
  for ref in ${(f)"$(grep -oE '\]\(diagrams/[^)<>]+\.svg\)' -- "$page" \
      | sed -E 's|^\]\(diagrams/||; s|\.svg\)$||' || true)"}; do
    [[ -n "$ref" ]] || continue
    covered[$DIAGRAMS/$ref.mmd]="embedded by $page"
  done
done
covered[$DIAGRAMS/sdlc.mmd]="the lifecycle overview"

failed=0
problem() { print -- "$1"; failed=1 }

# A stamped diagram outside the covered set is checked too.
local mmd
for mmd in docs/**/diagrams/*.mmd(N); do
  [[ -n "${covered[$mmd]-}" ]] && continue
  [[ "$(head -n 1 -- "$mmd")" == "$PREFIX"* ]] && covered[$mmd]="stamped"
done

local line hex want src missing
local -a fields sources
for mmd in ${(ko)covered}; do
  if [[ ! -f "$mmd" ]]; then
    problem "missing: $mmd (${covered[$mmd]})"; continue
  fi
  line="$(head -n 1 -- "$mmd")"
  if [[ "$line" != "$PREFIX"* ]]; then
    problem "unstamped: $mmd (${covered[$mmd]}) — its first line must be '${PREFIX}sha256=<hex> <source> ...'"
    continue
  fi
  fields=( ${(z)line#"$PREFIX"} )
  hex="${fields[1]-}"
  sources=( ${fields[2,-1]} )
  if [[ "$hex" != sha256=* ]] || (( ${#sources} == 0 )); then
    problem "malformed stamp: $mmd — expected '${PREFIX}sha256=<hex> <source> ...'"
    continue
  fi
  missing=""
  for src in $sources; do [[ -f "$src" ]] || missing+=" $src"; done
  if [[ -n "$missing" ]]; then
    problem "missing source: $mmd names$missing"; continue
  fi
  want="$(heading_hash $sources)"
  if [[ "${hex#sha256=}" != "$want" ]]; then
    problem "stale: $mmd — the headings of its sources changed; update the diagram if it no longer matches, then replace line 1 with:"
    print -- "${PREFIX}sha256=$want ${(j: :)sources}"
  fi
done

exit $failed
