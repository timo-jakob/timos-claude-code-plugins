#!/usr/bin/env zsh
# build-workflows-booklet.zsh — build the standalone workflows booklet,
# workflows.pdf + workflows.epub: the "How the plugins work" pages of the docs,
# with their diagrams, as a document you can hand to someone on its own.
#
# The chapters are NOT listed here. They are the mkdocs nav entries
# docs-nav-to-chapters.zsh emits for docs/explanation/how-the-plugins-work.md,
# how-the-family-learns.md and workflow-*.md, in nav order — so adding a
# workflow page to the nav adds it to the booklet, and the booklet can never
# disagree with the site about which pages it holds or their order.
#
# The pandoc invocation matches the manual's in .github/workflows/docs.yml and
# docs-publish.yml — same image, filter, headers, font size and fontconfig —
# so the booklet's pages look like the manual's. tests/workflow-diagrams.bats
# pins that the image tag stays in step with the workflows.
#
# Usage:
#   build-workflows-booklet.zsh [out-dir]   (default: the repo root)
#
# Exits 0 when both files were produced, 1 when a build failed or produced an
# empty file, 2 on usage/tooling errors (no docker, no chapters found).
set -euo pipefail

REPO_ROOT="${0:A:h:h}"
IMAGE="pandoc/extra:3.5"
TITLE="How the Claude Code Plugins Work"

(( $# <= 1 )) || { print -u2 -- "usage: build-workflows-booklet.zsh [out-dir]"; exit 2 }
command -v docker >/dev/null || { print -u2 -- "build-workflows-booklet: docker is required"; exit 2 }
cd "$REPO_ROOT"

local out_dir="${1:-.}"
mkdir -p "$out_dir"
out_dir="${out_dir:A}"
[[ "$out_dir" == "$REPO_ROOT" || "$out_dir" == "$REPO_ROOT"/* ]] || {
  print -u2 -- "build-workflows-booklet: out-dir must be inside the repository (the container mounts only it)"
  exit 2
}
local rel_out="${out_dir#$REPO_ROOT}"
rel_out="${rel_out#/}"
rel_out="${rel_out:-.}"

local -a chapters
chapters=( ${(f)"$(./scripts/docs-nav-to-chapters.zsh \
  | grep -E '^docs/explanation/(how-the-plugins-work|how-the-family-learns|workflow-[a-z0-9-]+)\.md$' || true)"} )
(( ${#chapters} > 0 )) || { print -u2 -- "build-workflows-booklet: no workflow pages in the mkdocs nav"; exit 2 }

# rebase_relative_paths resolves each page's `diagrams/x.svg` against that
# page's own directory; FONTCONFIG_FILE gives rsvg-convert the font the
# diagrams' labels are set in (scripts/pandoc/fonts.conf says why).
local -a common
common=( -f markdown+rebase_relative_paths --toc
  --metadata title="$TITLE" --metadata author="timos-claude-code-plugins" )

docker run --rm -e FONTCONFIG_FILE=/data/scripts/pandoc/fonts.conf -v "$REPO_ROOT:/data" -w /data "$IMAGE" \
  "${common[@]}" --pdf-engine=xelatex -V fontsize=11pt \
  --lua-filter=scripts/pandoc/break-long-tokens.lua \
  --include-in-header=scripts/pandoc/manual-header.tex \
  --include-in-header=scripts/pandoc/figures.tex \
  -o "$rel_out/workflows.pdf" "${chapters[@]}"
docker run --rm -v "$REPO_ROOT:/data" -w /data "$IMAGE" \
  "${common[@]}" -o "$rel_out/workflows.epub" "${chapters[@]}"

local f
for f in workflows.pdf workflows.epub; do
  [[ -s "$out_dir/$f" ]] || { print -u2 -- "build-workflows-booklet: $f was not produced"; exit 1 }
done
print -- "built: $rel_out/workflows.pdf $rel_out/workflows.epub (${#chapters} chapters)"
