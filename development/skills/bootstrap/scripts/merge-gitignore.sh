#!/usr/bin/env bash
# merge-gitignore.sh — emits the contents that should be APPENDED to an
# existing .gitignore when adding a language fragment, with entries that
# already appear in the existing file deduped out.
#
# Usage:
#   merge-gitignore.sh <existing-gitignore> <fragment-file>
#
# Prints a "to-append" block to stdout. The caller decides whether and how
# to actually concatenate it (the orchestrator usually wraps it in a small
# header comment so the diff is readable).
#
# Comparison rules:
#   - Comments (lines starting with `#`) and blank lines pass through from
#     the fragment regardless of duplication — they make the diff readable.
#   - Non-comment, non-blank pattern lines are compared literally
#     (whitespace-trimmed) against the existing file. If a pattern already
#     appears in the existing file, it's omitted from the output.
#   - Negation patterns (`!foo`) and plain patterns (`foo`) are compared
#     as whole strings — we don't try to be clever about overlap.
#
# Exit status:
#   0  always — a missing existing file just means "every line from the
#      fragment goes through".

set -euo pipefail

existing="${1:-}"
fragment="${2:-}"

[[ -n "$existing" && -n "$fragment" ]] || {
  echo "usage: $0 <existing-gitignore> <fragment-file>" >&2
  exit 2
}

[[ -f "$fragment" ]] || {
  echo "fragment file not found: $fragment" >&2
  exit 2
}

# If there's no existing file (empty repo, fresh init), nothing to dedupe
# against — just emit the fragment as-is.
if [[ ! -f "$existing" ]]; then
  cat "$fragment"
  exit 0
fi

# Two-file awk pass: collect existing patterns from $1, then stream $2
# (the fragment) emitting only the patterns not already seen.
#
# We dispatch on FILENAME rather than the `NR==FNR` trick because the
# trick fails when the first file is empty (NR doesn't advance during the
# first file, so NR==FNR remains true for line 1 of the second file too).
awk -v existing="$existing" -v fragment="$fragment" '
function trim(s) {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
  return s
}
FILENAME == existing {
  # First file: existing .gitignore. Record non-blank, non-comment patterns.
  line = trim($0)
  if (line != "" && line !~ /^#/) seen[line] = 1
  next
}
FILENAME == fragment {
  # Second file: the fragment we want to append.
  line = trim($0)

  if (line == "" || line ~ /^#/) {
    # Comments + blanks pass through verbatim.
    print
    next
  }

  if (line in seen) {
    # Already in existing — drop.
    next
  }

  # New pattern: emit and remember (in case the fragment has its own dupes).
  print
  seen[line] = 1
}
' "$existing" "$fragment"
