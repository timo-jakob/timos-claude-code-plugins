#!/usr/bin/env zsh
# docs-nav-to-chapters.zsh — emit the docs source files in MkDocs `nav:` order,
# one per line, prefixed with the configured docs dir. This is the single
# source of chapter order for the pandoc PDF/ePub build (epic #744 slice (c),
# issue #754): the site nav defined once in mkdocs.yml drives both the HTML
# site and the manuals, so the two can never disagree.
#
# Usage:
#   docs-nav-to-chapters.zsh [mkdocs.yml]
#
# Prints e.g.
#   docs/index.md
#   docs/tutorials/index.md
#   ...
#
# Exit codes:
#   0  success — chapter list on stdout
#   1  mkdocs.yml not found, or its nav produced no files
#   2  usage error

emulate -L zsh
setopt pipefail

local mkdocs="${1:-mkdocs.yml}"

[[ $# -le 1 ]] || { print -u2 -- "usage: docs-nav-to-chapters.zsh [mkdocs.yml]"; exit 2 }
[[ -f "$mkdocs" ]] || { print -u2 -- "docs-nav-to-chapters: not found: $mkdocs"; exit 1 }

# docs_dir defaults to "docs" when the key is absent (MkDocs' own default).
local docs_dir
docs_dir=$(grep -E '^docs_dir:[[:space:]]*' "$mkdocs" | head -1 \
  | sed -E 's/^docs_dir:[[:space:]]*//; s/[[:space:]]*$//')
docs_dir="${docs_dir:-docs}"

# Walk the `nav:` block (from `nav:` to the next top-level key or EOF) and pull
# the `*.md` token out of each entry in document order. Section-header lines
# (`- Tutorials:`) carry no `.md` and are skipped; `- Title: path.md` and bare
# `- path.md` both yield their path.
local -a chapters
chapters=( ${(f)"$(awk '
  /^nav:/            { innav = 1; next }
  innav && /^[^[:space:]#]/ { innav = 0 }   # a new top-level key ends the nav
  innav             { print }
' "$mkdocs" | grep -oE '[^[:space:]]+\.md')"} )

(( ${#chapters} > 0 )) || {
  print -u2 -- "docs-nav-to-chapters: no .md entries found in the nav of $mkdocs"
  exit 1
}

local c
for c in "${chapters[@]}"; do
  print -r -- "${docs_dir}/${c}"
done
