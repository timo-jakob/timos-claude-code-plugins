#!/usr/bin/env zsh
# install-precommit-hooks.zsh — install every git hook type referenced
# by `.pre-commit-config.yaml`'s `stages:` entries. `pre-commit install`
# alone installs only the default `pre-commit` type, so a config that
# defines `stages: [pre-push]` (like the coverage-floor hook added in
# #93) silently doesn't fire on push until the user runs
# `pre-commit install --hook-type pre-push` manually. This script does
# that for them — idempotent, safe to re-run on every bootstrap or
# refresh.
#
# Usage: run from the repo root.
#   install-precommit-hooks.zsh

setopt err_exit nounset pipefail

config=".pre-commit-config.yaml"

if [[ ! -f "$config" ]]; then
  print -u 2 "No $config in current directory — nothing to install."
  exit 0
fi

if ! command -v pre-commit >/dev/null 2>&1; then
  print -u 2 "pre-commit not installed. Install with:"
  print -u 2 "  brew install pre-commit   (recommended)"
  print -u 2 "  pip install pre-commit"
  exit 1
fi

# Always install the default `pre-commit` hook type. Idempotent — the
# command overwrites any existing `.git/hooks/pre-commit`.
pre-commit install

# Collect every distinct `stages:` value referenced anywhere in the
# config. Supports two YAML forms used in the bootstrap templates:
#
#   stages: [pre-push, manual]            (inline flow style)
#   stages:                               (block style)
#     - pre-push
#     - manual
#
# Conservative grep + sed instead of a real YAML parser to keep the
# script dependency-free.

inline=$(grep -E '^[[:space:]]+stages:[[:space:]]*\[' "$config" 2>/dev/null \
  | sed -E 's/.*\[(.*)\].*/\1/' \
  | tr ',' '\n' \
  | tr -d '[:space:]"'"'" \
  | sort -u || true)

# Block-form parser: lines after a `stages:` line, indented more, that
# start with `-`. Stops at the first less-indented line. awk handles
# the state machine cleanly.
block=$(awk '
  /^[[:space:]]+stages:[[:space:]]*$/ {
    match($0, /^[[:space:]]+/)
    base = RLENGTH
    in_block = 1
    next
  }
  in_block {
    if (match($0, /^[[:space:]]*-[[:space:]]*/)) {
      line_indent = RLENGTH - 1
      if (line_indent > base) {
        item = $0
        sub(/^[[:space:]]*-[[:space:]]*/, "", item)
        gsub(/[[:space:]"'"'"']/, "", item)
        print item
        next
      }
    }
    in_block = 0
  }
' "$config" | sort -u)

# Union and dedupe
all_stages=$(print -- "$inline\n$block" | grep -v '^$' | sort -u || true)

if [[ -z "$all_stages" ]]; then
  print "Only default pre-commit stage configured — done."
  exit 0
fi

# `pre-commit install` already covered `pre-commit`; install everything else.
print "$all_stages" | while IFS= read -r stage; do
  [[ -z "$stage" ]] && continue
  [[ "$stage" == "pre-commit" ]] && continue
  print "Installing hook type: $stage"
  pre-commit install --hook-type "$stage"
done

print "Done."
