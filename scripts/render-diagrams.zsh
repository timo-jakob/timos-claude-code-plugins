#!/usr/bin/env zsh
# render-diagrams.zsh — render every Mermaid source under docs/ to the SVG the
# docs pages embed.
#
# Each `docs/**/diagrams/<name>.mmd` is rendered to `<name>.svg` beside it, and
# BOTH are committed: the site, manual.pdf/.epub and the workflows booklet all
# embed the SVG, so none of them needs Mermaid at build time.
#
# THE FAILURE MODE THIS EXISTS FOR: Mermaid's default output puts label text in
# <foreignObject> HTML, which a browser draws and rsvg-convert — the converter
# pandoc's xelatex path uses — silently drops. A diagram rendered that way shows
# on the site and prints as empty boxes in the PDF. scripts/mermaid/config.json
# turns htmlLabels off so labels are SVG <text>, and this script refuses to
# leave behind an SVG that still carries a <foreignObject>. It also marks every
# <text> xml:space="preserve" (see the loop) so word spacing survives rsvg.
# tests/workflow-diagrams.bats pins the same invariant on what is committed.
# Each SVG also carries a `<!-- rendered-from: sha256=<hex> -->` stamp of its
# source (#3040), so a .mmd edited without a re-render fails that suite.
#
# Usage:
#   render-diagrams.zsh [file.mmd ...]   (default: every docs/**/diagrams/*.mmd)
#
# Exits 0 when every SVG rendered clean, 1 when a render failed, produced a
# <foreignObject> or could not be stamped, 2 on usage/tooling errors (no docker, no sources).
set -euo pipefail

REPO_ROOT="${0:A:h:h}"
CONFIG="scripts/mermaid/config.json"

# Pinned exactly so a Mermaid release cannot restyle every committed SVG
# without a commit here; Renovate's docker manager keeps the tag current.
IMAGE="minlag/mermaid-cli:11.4.2"

command -v docker >/dev/null || { print -u2 -- "render-diagrams: docker is required"; exit 2 }
cd "$REPO_ROOT"

local -a sources
if (( $# > 0 )); then
  sources=( "$@" )
else
  sources=( docs/**/diagrams/*.mmd(N) )
fi
(( ${#sources} > 0 )) || { print -u2 -- "render-diagrams: no .mmd sources found"; exit 2 }

local src svg hex rc=0
for src in "${sources[@]}"; do
  [[ "$src" == *.mmd && -f "$src" ]] || { print -u2 -- "render-diagrams: not a .mmd file: $src"; exit 2 }
  svg="${src%.mmd}.svg"
  print -- "render: $src -> $svg"
  # -u keeps the SVG owned by the caller rather than by the container's root.
  if ! docker run --rm -u "$(id -u):$(id -g)" -v "$REPO_ROOT:/data" "$IMAGE" \
      -q -i "/data/$src" -o "/data/$svg" -c "/data/$CONFIG" -b white; then
    print -u2 -- "render-diagrams: mermaid-cli failed on $src"
    rc=1
    continue
  fi
  # With htmlLabels off, Mermaid writes each word after the first as its own
  # <tspan> with a LEADING space, and rsvg-convert collapses that space under
  # SVG's default whitespace handling — "Branch off main" prints as
  # "Branchoffmain". Preserving whitespace on every <text> keeps it; the SVG is
  # one line, so there is no indentation for it to preserve by mistake.
  sed -i.bak -e 's/<text /<text xml:space="preserve" /g' "$svg" && rm -f "$svg.bak"
  # mermaid-cli ends the file without a newline; the end-of-file pre-commit
  # hook would otherwise rewrite every freshly rendered SVG.
  [[ -z "$(tail -c 1 "$svg")" ]] || print >> "$svg"
  # Stamp the SVG with the sha256 of the exact .mmd bytes it was rendered from,
  # as one comment right after the root <svg …> tag (#3040). CI cannot
  # re-render (no docker), so tests/workflow-diagrams.bats compares this hash
  # with the committed .mmd instead: a source edited without a re-render fails.
  # Mermaid starts the file with the root tag on one line, so the first `>` on
  # line 1 closes it.
  hex="$(shasum -a 256 < "$src" | cut -d' ' -f1)"
  sed -i.bak -e "1s/>/><!-- rendered-from: sha256=$hex -->/" "$svg" && rm -f "$svg.bak"
  if [[ "$(head -c 4 "$svg")" != '<svg' ]] \
      || (( $(grep -o 'rendered-from:' "$svg" | grep -c .) != 1 )); then
    print -u2 -- "render-diagrams: could not stamp $svg with its source hash"
    rc=1
  fi
  if grep -q '<foreignObject' "$svg"; then
    print -u2 -- "render-diagrams: $svg carries <foreignObject> — its labels will not print in the PDF"
    rc=1
  fi
done
exit $rc
