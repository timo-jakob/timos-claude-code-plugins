#!/usr/bin/env zsh
# story-spec-prose-hash.zsh — the canonical provenance hash for a story-spec/v1
# (or personas/v1) prose region.
#
# Reads the *prose region* — the bytes between the sentinels, NOT including the
# `<!-- …:prose:start -->` / `:end -->` lines themselves — from `--file <path>`
# or stdin, applies the contract's normalisation, and prints the lowercase-hex
# SHA-256. This is the **canonical implementation** of that hash: `refine-issue`
# calls it when it writes a block. The `story-readiness` gate recomputes the same
# recipe when it checks a block for staleness — keeping the recipe byte-identical
# on both sides is what makes staleness detection reliable. (Wiring the gate to
# call this exact script, rather than re-describing the recipe, is a worthwhile
# follow-up — the script is a plugin asset, not present in a target repo, so it
# needs a plugin-relative path there.)
#
# Normalisation (ARCHITECTURE.md → "Provenance and staleness detection"), in this
# exact order:
#   1. line endings -> LF
#   2. strip trailing whitespace from each line
#   3. drop leading and trailing blank lines (blank == empty after step 2)
#   4. append exactly one trailing LF
# then SHA-256 of the resulting UTF-8 bytes, lowercase hex.
#
# Exit codes: 0 ok · 1 unreadable file / no hasher · 2 usage error.

emulate -L zsh
set -euo pipefail

local file=""
while (( $# > 0 )); do
  case "$1" in
    --file)
      (( $# >= 2 )) || { print -r -- "story-spec-prose-hash: --file needs a value" >&2; exit 2; }
      file="$2"; shift 2 ;;
    -h|--help)
      print -r -- "usage: story-spec-prose-hash.zsh [--file <prose-file>]  (else reads stdin)"
      exit 0 ;;
    *) print -r -- "story-spec-prose-hash: unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Pick a SHA-256 tool (macOS ships shasum; Linux/CI ships sha256sum).
local -a hasher
if command -v shasum >/dev/null 2>&1; then
  hasher=(shasum -a 256)
elif command -v sha256sum >/dev/null 2>&1; then
  hasher=(sha256sum)
else
  print -r -- "story-spec-prose-hash: no shasum/sha256sum on PATH" >&2
  exit 1
fi

# Raw bytes of the prose region.
local raw
if [[ -n "$file" ]]; then
  [[ -r "$file" ]] || { print -r -- "story-spec-prose-hash: cannot read: $file" >&2; exit 1; }
  raw="$(cat -- "$file")"
else
  raw="$(cat)"
fi

# Steps 1-3: LF endings, strip per-line trailing whitespace, drop leading/
# trailing blank lines (internal blank lines are preserved). `awk` prints each
# kept line with a trailing LF; the `$(…)` capture then strips trailing newlines.
local body
body="$(print -r -- "$raw" \
  | tr -d '\r' \
  | sed 's/[[:space:]]*$//' \
  | awk '
      { lines[NR] = $0 }
      END {
        s = 1;  while (s <= NR && lines[s] == "") s++
        e = NR; while (e >= 1  && lines[e] == "") e--
        for (i = s; i <= e; i++) print lines[i]
      }')"

# Step 4: exactly one trailing LF (printf re-adds the single newline the capture
# stripped), then hash. `awk` isolates the hex digest from the tool's output.
printf '%s\n' "$body" | "${hasher[@]}" | awk '{ print $1 }'
