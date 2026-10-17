#!/usr/bin/env zsh
# check-docs.zsh — build this repository's docs the way docs.yml does, the docs stage every
# language gate shares (#2640, epic #1608). Owned and re-rendered by /development:bootstrap,
# copied verbatim: a gate calls it rather than carrying its own copy of the build.
#
# It installs requirements-docs.txt into .tools/docs-venv, runs mkdocs build --strict, derives the
# chapter order with scripts/docs-nav-to-chapters.zsh, and builds manual.pdf and manual.epub with
# the pinned pandoc image, failing on a character xelatex has no glyph for and on an unresolved
# reference. A probe first proves the image still reports an unresolved reference, so the
# reference check cannot go blind. It needs python3 and docker.
#
# Usage: zsh scripts/check-docs.zsh --out <dir> [--caller <name>] [-h|--help], from the
# repository root. --out is an existing directory that receives site/, manual.pdf, manual.epub
# and the pandoc log; the script neither creates nor removes it. --caller names the calling gate,
# and prefixes every line this script prints: `<caller>: FAIL docs — <reason>` on stderr,
# informational lines on stdout. Without it the prefix is check-docs.
#
# Exit codes: 0 built; 1 failed, the reason on stderr; 2 an unknown or malformed argument,
# including a missing or empty --out, or one that is not an existing directory.

emulate -L zsh
setopt pipefail no_unset

caller="${${0:t}%.zsh}"
out=""
while (( $# )); do
	case "$1" in
	-h | --help)
		awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
		exit 0
		;;
	--caller | --out)
		[[ $# -ge 2 && -n "$2" ]] || { print -u2 -r -- "$caller: $1 needs a value"; exit 2; }
		if [[ "$1" == --caller ]]; then caller="$2"; else out="$2"; fi
		shift 2
		;;
	*)
		print -u2 -r -- "$caller: unknown argument: $1"
		exit 2
		;;
	esac
done
[[ -n "$out" ]] || { print -u2 -r -- "$caller: --out is required"; exit 2; }
[[ -d "$out" ]] || { print -u2 -r -- "$caller: --out $out is not an existing directory"; exit 2; }
out="${out:A}"

# the pandoc image the manuals build runs without pulling a moving tag
pandoc_image="pandoc/extra:3.5"

fail() { print -u2 -r -- "$caller: FAIL docs — $1"; exit 1 }
require() { command -v "$1" >/dev/null 2>&1 || fail "$1 is not installed" }

# a top-level scalar of mkdocs.yml, without a trailing comment or surrounding quotes
mkdocs_key() {
	awk -v k="$1:" '$1 == k { v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); sub(/[[:space:]]+#.*$/, "", v)
		gsub(/^["\047]|["\047]?[[:space:]]*$/, "", v); print v; exit }' mkdocs.yml
}

require python3
require docker
python3 -m venv .tools/docs-venv &&
	.tools/docs-venv/bin/pip install --quiet -r requirements-docs.txt ||
	fail "installing requirements-docs.txt"
.tools/docs-venv/bin/mkdocs build --strict --site-dir "$out/site" ||
	fail "mkdocs build --strict"
chapter_list="$(zsh scripts/docs-nav-to-chapters.zsh)" || fail "deriving the chapter order"
chapters=(${(f)chapter_list})
# the manuals' title and author: the site's name and repository, which bootstrap renders into
# mkdocs.yml from the same values it renders into docs.yml
title="$(mkdocs_key site_name)"
author="$(mkdocs_key repo_name)"
# the manuals' page setup and layout fixes are docs.yml's, carried over unchanged
docker run --rm -v "$PWD:/data" -v "$out:/out" -w /data "$pandoc_image" \
	--pdf-engine=xelatex --toc -V fontsize=11pt \
	--metadata title="$title" --metadata author="$author" \
	--lua-filter=scripts/pandoc/break-long-tokens.lua \
	--include-in-header=scripts/pandoc/manual-header.tex \
	-o /out/manual.pdf "${chapters[@]}" > "$out/pandoc-pdf.log" 2>&1 || {
	cat "$out/pandoc-pdf.log" >&2
	fail "pandoc manual.pdf"
}
docker run --rm -v "$PWD:/data" -v "$out:/out" -w /data "$pandoc_image" \
	--toc --metadata title="$title" --metadata author="$author" \
	-o /out/manual.epub "${chapters[@]}" || fail "pandoc manual.epub"
[[ -s "$out/manual.pdf" && -s "$out/manual.epub" ]] || fail "a manual was not produced"
# xelatex drops a character it has no glyph for silently
if grep "Missing character" "$out/pandoc-pdf.log" >&2; then
	fail "xelatex dropped the characters above from manual.pdf; add a \\DeclareUnicodeFallback for each to scripts/pandoc/manual-header.tex"
fi
# The unresolved-reference check is a negative test, so a probe whose only link dangles must
# show the warning first: a pandoc image that stops reporting it would leave the check blind.
probe_log="$(docker run --rm --entrypoint sh "$pandoc_image" -c \
	'printf "# Probe\n\nA [dangling](#no-such-anchor) link.\n" > /tmp/probe.md
	pandoc --pdf-engine=xelatex -o /tmp/probe.pdf /tmp/probe.md' 2>&1)" || {
	print -u2 -r -- "$probe_log"
	fail "the pandoc probe container failed; that is infrastructure, not a pandoc change"
}
if [[ "$probe_log" != *"There were undefined references"* ]]; then
	print -u2 -r -- "$probe_log"
	fail "pandoc no longer reports undefined references, so the reference check cannot fail"
fi
if grep -q "There were undefined references" "$out/pandoc-pdf.log"; then
	grep -B2 -A2 "undefined" "$out/pandoc-pdf.log" >&2
	fail "manual.pdf has unresolved references; they work on the site only. Give the target heading the {#id} it already publishes, or fix the link"
fi
