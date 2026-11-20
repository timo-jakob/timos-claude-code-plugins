#!/usr/bin/env zsh
# Render one product document to a PDF and an ePub in the one house style
# (#3204).
#
#   render-document.zsh [--title <text>] [--appendix <path>]... <document.md>
#
# The PDF is pandoc + Typst with product/templates/house.typ, the ePub is pandoc
# with product/templates/house.css; product/templates/product-doc.lua serves
# both. Output is always both files or neither, in <repo-root>/dist/product/,
# named after the document: <basename>.pdf and <basename>.epub. The repo root is
# the git work tree holding the document; for a document outside any git
# repository it is the current directory.
#
# Title and appendices come from the document's machine block (a `<details>`
# element holding a fenced JSON object with a `schema` key) when it has `title`
# / `appendices` (repo-relative paths). The flags are for a document with none —
# the persona registry — and giving one the block already supplies is a usage
# error. A flag's appendix path is read relative to the current directory.
# Without either, the title is the document's first `#` heading, else its file
# name.
#
# The cover carries the title, the repo name, today's date and a version line
# (the newest `direction_changes[0].id` when the block has one, then the source
# commit's short SHA), and DRAFT when the document or an appendix has
# uncommitted changes. Every PDF page's footer carries the repo name, the short
# SHA and that commit's date, or `uncommitted` outside git or before the first
# commit.
#
# stdout on success, two lines: the absolute path of the PDF, then of the ePub.
#
# Exit codes:
#   0 rendered
#   1 internal failure: jq missing, or a temporary directory could not be made
#   2 usage error, an input file that does not exist, or a flag the machine
#     block already supplies
#   3 pandoc or Typst missing or older than MIN_PANDOC / MIN_TYPST; stderr ends
#     with the line `brew install pandoc typst`; nothing written
#   4 unsupported content: a `mermaid` fenced block (stderr names file and
#     line); nothing written
#   5 the toolchain failed (its stderr passed through); an earlier output in
#     dist/product/ is left untouched and nothing is added

emulate -L zsh
setopt extended_glob
set -uo pipefail

# The lowest versions the suite has passed with. CI pins at or above them.
MIN_PANDOC=3.14
MIN_TYPST=0.15.1

local me="${0:t}"
local here="${0:A:h}"
local templates="${here:h}/templates"

usage() {
  print -r -- "usage: $me [--title <text>] [--appendix <path>]... <document.md>" >&2
  exit 2
}

local title_flag="" doc=""
local -i have_title=0 have_doc=0
local -a appendix_flags=()
while (( $# > 0 )); do
  case "$1" in
    --title)
      (( $# >= 2 )) && [[ -n "$2" ]] || { print -r -- "$me: --title needs a value" >&2; usage; }
      (( have_title == 0 )) || { print -r -- "$me: --title given twice" >&2; usage; }
      title_flag="$2"; have_title=1; shift 2 ;;
    --appendix)
      (( $# >= 2 )) && [[ -n "$2" ]] || { print -r -- "$me: --appendix needs a value" >&2; usage; }
      appendix_flags+=( "$2" ); shift 2 ;;
    -h|--help)
      print -r -- "usage: $me [--title <text>] [--appendix <path>]... <document.md>"
      exit 0 ;;
    --) shift; (( $# == 1 )) || usage; doc="$1"; have_doc=1; shift ;;
    -*) print -r -- "$me: unknown flag: $1" >&2; usage ;;
    *)
      (( have_doc == 0 )) || { print -r -- "$me: more than one document given" >&2; usage; }
      doc="$1"; have_doc=1; shift ;;
  esac
done
(( have_doc == 1 )) && [[ -n "$doc" ]] || { print -r -- "$me: a document is required" >&2; usage; }
[[ -f "$doc" ]] || { print -r -- "$me: no such document: $doc" >&2; usage; }
doc="${doc:A}"
local a
for a in "${appendix_flags[@]}"; do
  [[ -f "$a" ]] || { print -r -- "$me: no such appendix: $a" >&2; usage; }
done

# --- the toolchain: present and new enough, or exit 3 before anything else --

# version_ge <have> <want> — dotted numeric comparison
version_ge() {
  local -a h w
  h=( ${(s:.:)1} ); w=( ${(s:.:)2} )
  local -i i n=$(( ${#h} > ${#w} ? ${#h} : ${#w} ))
  for (( i = 1; i <= n; i++ )); do
    local -i x=${h[i]:-0} y=${w[i]:-0}
    (( x > y )) && return 0
    (( x < y )) && return 1
  done
  return 0
}

local -a tool_problems=()
# check_tool <name> <min> — the first dotted number of `<name> --version`
check_tool() {
  local name="$1" min="$2" line ver
  if ! line="$("$name" --version 2>/dev/null)" || [[ -z "$line" ]]; then
    tool_problems+=( "$name is not installed (need $min or newer)" )
    return
  fi
  ver="$(print -r -- "${line%%$'\n'*}" | sed -nE 's/^[^0-9]*([0-9]+(\.[0-9]+)*).*/\1/p')"
  if [[ -z "$ver" ]]; then
    tool_problems+=( "$name reports no version (need $min or newer)" )
  elif ! version_ge "$ver" "$min"; then
    tool_problems+=( "$name $ver is older than $min" )
  fi
}
check_tool pandoc "$MIN_PANDOC"
check_tool typst "$MIN_TYPST"
if (( ${#tool_problems} > 0 )); then
  local p
  for p in "${tool_problems[@]}"; do print -r -- "$me: $p" >&2; done
  print -r -- "$me: install or upgrade them with:" >&2
  print -r -- "brew install pandoc typst" >&2
  exit 3
fi

command -v jq >/dev/null 2>&1 || { print -r -- "$me: jq is not on PATH" >&2; exit 1; }

# --- where the document lives -----------------------------------------------

local root="" sha="" short="" commit_date="" remote_url="" remote_base=""
local -i in_git=0
if command -v git >/dev/null 2>&1 && root="$(git -C "${doc:h}" rev-parse --show-toplevel 2>/dev/null)" \
   && [[ -n "$root" ]]; then
  in_git=1
  root="${root:A}"
  if sha="$(git -C "$root" rev-parse --verify -q HEAD 2>/dev/null)" && [[ -n "$sha" ]]; then
    short="$(git -C "$root" rev-parse --short HEAD)"
    commit_date="$(git -C "$root" log -1 --format=%cs HEAD)"
  else
    sha=""
  fi
  remote_url="$(git -C "$root" remote get-url origin 2>/dev/null)" || remote_url=""
  if [[ -z "$remote_url" ]]; then
    local first_remote
    first_remote="$(git -C "$root" remote 2>/dev/null | sed -n 1p)"
    [[ -n "$first_remote" ]] && remote_url="$(git -C "$root" remote get-url "$first_remote" 2>/dev/null)"
  fi
else
  root="${PWD:A}"
fi

# A remote counts only when it is a web host: https, ssh:// or scp-style.
local web=""
case "$remote_url" in
  https://*|http://*)
    web="${remote_url#*://}"; web="${web#*@}"; web="https://$web" ;;
  ssh://*)
    web="${remote_url#ssh://}"; web="${web#*@}"; web="${web/:[0-9]##\//\/}"; web="https://$web" ;;
  ?*@?*:*)
    web="${remote_url#*@}"; web="https://${web/://}" ;;
esac
web="${web%/}"; web="${web%.git}"
[[ -n "$web" ]] && remote_base="$web/blob/${sha:-HEAD}"

local repo_name="${root:t}"

# --- the machine block: title, appendices, newest direction change ----------

# The first fenced JSON block inside a <details> element whose object has a
# `schema` key; empty when the document has none.
machine_block() {
  awk '
    /<details[ >]/ || /<details$/ { inside = 1 }
    inside && !fence && /^[ \t]*```+[ \t]*json[ \t]*$/ { fence = 1; next }
    fence && /^[ \t]*```+[ \t]*$/ { exit }
    fence { print }
    /<\/details[ \t]*>/ { inside = 0 }
  ' "$1"
}
local block="" block_title="" newest_change=""
local -i block_has_title=0 block_has_appendices=0
local -a appendices=()
block="$(machine_block "$doc")"
if [[ -n "$block" ]] && print -r -- "$block" | jq -e 'type == "object" and has("schema")' >/dev/null 2>&1; then
  if print -r -- "$block" | jq -e '.title | type == "string"' >/dev/null 2>&1; then
    block_has_title=1
    block_title="$(print -r -- "$block" | jq -r '.title')"
  fi
  if print -r -- "$block" | jq -e '.appendices | type == "array"' >/dev/null 2>&1; then
    block_has_appendices=1
    local -a listed
    listed=( "${(@f)$(print -r -- "$block" | jq -r '.appendices[] | strings')}" )
    for a in "${listed[@]}"; do
      [[ -n "$a" ]] || continue
      [[ -f "$root/$a" ]] || { print -r -- "$me: the machine block's appendix does not exist: $a" >&2; exit 2; }
      appendices+=( "${${:-$root/$a}:A}" )
    done
  fi
  newest_change="$(print -r -- "$block" | jq -r '(.direction_changes // [])[0].id // empty | strings')"
fi
if (( have_title == 1 && block_has_title == 1 )); then
  print -r -- "$me: --title given, but the machine block already has a title" >&2
  usage
fi
if (( ${#appendix_flags} > 0 && block_has_appendices == 1 )); then
  print -r -- "$me: --appendix given, but the machine block already lists appendices" >&2
  usage
fi
for a in "${appendix_flags[@]}"; do appendices+=( "${a:A}" ); done

local title
if (( block_has_title == 1 )); then
  title="$block_title"
elif (( have_title == 1 )); then
  title="$title_flag"
else
  title="$(sed -nE 's/^#[ \t]+(.*[^ \t#])[ \t#]*$/\1/p' "$doc" | sed -n 1p)"
  [[ -n "$title" ]] || title="${${doc:t}%.*}"
fi

# --- refusals: content the house style cannot render ------------------------

# show_path <abs> — repo-relative when inside the root, else absolute
show_path() {
  [[ "$1" == "$root"/* ]] && print -r -- "${1#$root/}" || print -r -- "$1"
}
local f hit
for f in "$doc" "${appendices[@]}"; do
  hit="$(awk '
    function fence_of(s) { match(s, /^[ \t]*(`{3,}|~{3,})/); return substr(s, RSTART, RLENGTH) }
    {
      if (!open) {
        if ($0 ~ /^[ \t]*(```+|~~~+)/) {
          f = fence_of($0); sub(/^[ \t]*/, "", f)
          info = substr($0, RSTART + RLENGTH)
          sub(/^[ \t{.]*/, "", info)
          if (tolower(info) ~ /^mermaid([^a-z0-9_-]|$)/) { print NR; exit }
          open = 1; marker = f
        }
      } else {
        line = $0; sub(/^[ \t]*/, "", line)
        if (index(line, marker) == 1 && line ~ /^(`+|~+)[ \t]*$/) open = 0
      }
    }
  ' "$f")"
  if [[ -n "$hit" ]]; then
    print -r -- "$me: $(show_path "$f"):$hit: a mermaid block is not supported; diagrams are not rendered yet" >&2
    exit 4
  fi
done

# --- the facts the cover and the footer print -------------------------------

local -i draft=0
if (( in_git == 0 || ${#sha} == 0 )); then
  draft=1
else
  local changes
  changes="$(git -C "$root" status --porcelain -- "$doc" "${appendices[@]}" 2>/dev/null)"
  [[ -n "$changes" ]] && draft=1
fi
local stamp version
if [[ -n "$short" ]]; then
  stamp="$short · $commit_date"
  version="$short"
else
  stamp="uncommitted"
  version="uncommitted"
fi
[[ -n "$newest_change" ]] && version="$newest_change · $version"
local today
today="$(date +%Y-%m-%d)"

# --- build both in a scratch directory, then move both in -------------------

local work
work="$(mktemp -d "${TMPDIR:-/tmp}/render-document.XXXXXX")" || { print -r -- "$me: mktemp failed" >&2; exit 1; }
local out_dir="$root/dist/product"
local name="${${doc:t}%.*}"
local staged_pdf="" staged_epub=""
cleanup() {
  rm -rf -- "$work"
  [[ -n "$staged_pdf" ]] && rm -f -- "$staged_pdf"
  [[ -n "$staged_epub" ]] && rm -f -- "$staged_epub"
}
trap cleanup EXIT

local -a common=(
  -f gfm
  --lua-filter "$templates/product-doc.lua"
  --resource-path "${doc:h}"
  -M "pd_root=$root"
  -M "pd_doc=$doc"
  -M "pd_remote=$remote_base"
  -M "pd_reader=gfm"
  -M "title=$title"
  -M "date=$today"
)
for a in "${appendices[@]}"; do common+=( -M "pd_appendix=$a" ); done

local -a pdf_args=(
  "${common[@]}"
  -t typst
  --template "$templates/house.typ"
  --pdf-engine typst
  --pdf-engine-opt=--ignore-system-fonts
  -M "repo=$repo_name"
  -M "version=$version"
  -M "stamp=$stamp"
)
(( draft == 1 )) && pdf_args+=( -M "draft=true" )

local subtitle="$repo_name · Version $version"
(( draft == 1 )) && subtitle="$subtitle · DRAFT"
local -a epub_args=(
  "${common[@]}"
  -t epub3
  --toc --toc-depth 2
  --css "$templates/house.css"
  --split-level 1
  -M "subtitle=$subtitle"
)

if ! pandoc "${pdf_args[@]}" -o "$work/out.pdf" -- "$doc" 2> "$work/pdf.err"; then
  cat -- "$work/pdf.err" >&2
  print -r -- "$me: the PDF render failed" >&2
  exit 5
fi
cat -- "$work/pdf.err" >&2
if ! pandoc "${epub_args[@]}" -o "$work/out.epub" -- "$doc" 2> "$work/epub.err"; then
  cat -- "$work/epub.err" >&2
  print -r -- "$me: the ePub render failed" >&2
  exit 5
fi
cat -- "$work/epub.err" >&2
[[ -s "$work/out.pdf" && -s "$work/out.epub" ]] || { print -r -- "$me: the toolchain wrote no output" >&2; exit 5; }

mkdir -p -- "$out_dir" || { print -r -- "$me: cannot create $out_dir" >&2; exit 5; }
staged_pdf="$out_dir/.$name.pdf.$$"
staged_epub="$out_dir/.$name.epub.$$"
if ! cp -- "$work/out.pdf" "$staged_pdf" || ! cp -- "$work/out.epub" "$staged_epub"; then
  print -r -- "$me: cannot write into $out_dir" >&2
  exit 5
fi
mv -f -- "$staged_pdf" "$out_dir/$name.pdf" && staged_pdf=""
mv -f -- "$staged_epub" "$out_dir/$name.epub" && staged_epub=""

print -r -- "$out_dir/$name.pdf"
print -r -- "$out_dir/$name.epub"
exit 0
