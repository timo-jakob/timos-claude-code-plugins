#!/usr/bin/env zsh
# read-story-spec.zsh — extract the machine-readable story-spec/v1 block from a
# GitHub issue body (#577, epic #573).
#
# A refined issue (via /development:refine-issue) carries a `story-spec/v1` JSON
# block in a collapsed <details> below the human prose. `resolve-issue` consumes
# it as its authoritative structured interface — but pulling one fenced ```json
# object out of markdown by hand (nested fences, multiple code blocks, a
# <details> wrapper) is error-prone, so this is the one robust primitive both do.
#
# It reads the issue body from `--file <path>` or stdin, finds every *top-level*
# fenced ```json block (CommonMark-aware — a ```json line nested inside another
# fenced block, e.g. an illustrative ```bash example, is literal content and is
# ignored), and prints the LAST one whose parsed `.schema` is exactly
# `story-spec/v1` to stdout, as a single compact JSON object. Selection is by
# content (the schema) and position (the generated block is appended at the end
# of the body, below the prose), so an unrelated or illustrative json block can't
# be mistaken for the real spec. An opening fence may carry a leading indent and
# a trailing info string (```json title=...); the closing fence is bare backticks.
#
# Exit codes:
#   0 — a story-spec/v1 block was found and printed (valid JSON on stdout)
#   1 — NO block present (older/unrefined issue) — caller falls back to prose.
#       This is the normal, expected "no block" signal, NOT an error.
#   2 — usage error (bad args)
#   3 — runtime error (unreadable file, jq missing)
#
# Usage:
#   read-story-spec.zsh --file <issue-body.md>      # from a file
#   gh issue view <N> --json body -q .body | read-story-spec.zsh   # from stdin

emulate -L zsh
set -euo pipefail

local file=""
while (( $# > 0 )); do
  case "$1" in
    --file)
      (( $# >= 2 )) || { print -u2 "read-story-spec.zsh: --file needs a value"; exit 2; }
      file="$2"; shift 2 ;;
    -h|--help)
      print -r -- "usage: read-story-spec.zsh [--file <issue-body.md>]  (else reads stdin)"
      print -r -- "prints the story-spec/v1 JSON block; exit 1 when absent (fall back to prose)."
      exit 0 ;;
    *) print -u2 "read-story-spec.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

[[ -z "$file" || -f "$file" ]] || { print -u2 "read-story-spec.zsh: file not found: $file"; exit 3; }
command -v jq >/dev/null 2>&1 || { print -u2 "read-story-spec.zsh: jq not found on PATH"; exit 3; }

# Read the whole body (file or stdin).
local body
if [[ -n "$file" ]]; then
  body="$(<"$file")"
else
  body="$(cat)"
fi

# Extract every fenced ```json block into its own temp file, in order —
# CommonMark-aware, so a ```json line *inside* another fenced block (e.g. an
# illustrative ```bash example that shows a spec) is literal content, not a real
# fence, and is never mistaken for the spec. Code blocks do not nest: only the
# outermost fence toggles state, an opening fence's info string names the
# language (`json`, optionally with a trailing info string), and a closing fence
# is bare backticks (>= the opener's length, no info string).
local tmpdir; tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
print -r -- "$body" | awk -v dir="$tmpdir" '
  {
    stripped = $0; sub(/^[[:space:]]*/, "", stripped)
    nb = 0; while (substr(stripped, nb + 1, 1) == "`") nb++
    isfence = (nb >= 3)
    rest = substr(stripped, nb + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", rest)
    if (!incode) {
      if (isfence) {
        lang = rest; sub(/[[:space:]].*$/, "", lang); lang = tolower(lang)
        incode = 1; fencelen = nb; capjson = (lang == "json")
        if (capjson) { n++; fn = sprintf("%s/block-%03d.json", dir, n) }
      }
      next
    }
    # inside a code block: a bare fence of >= opener length closes it
    if (isfence && nb >= fencelen && rest == "") { incode = 0; capjson = 0; next }
    if (capjson) print $0 > fn
  }
'

# The authoritative block is the LAST story-spec/v1 block (refine-issue appends
# the generated block at the end of the body, below the prose). Emit its first
# top-level object as compact JSON, so a block that somehow holds trailing junk
# still yields a single JSON document.
local f match=""
for f in "$tmpdir"/block-*.json(N); do
  if jq -e -s '(.[0].schema // "") == "story-spec/v1"' "$f" >/dev/null 2>&1; then
    match="$f"
  fi
done

if [[ -n "$match" ]]; then
  jq -c -s '.[0]' "$match"
  exit 0
fi

# No story-spec/v1 block — the expected "unrefined issue" case.
exit 1
