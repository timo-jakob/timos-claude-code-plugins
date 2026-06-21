#!/usr/bin/env zsh
# reconcile-precommit-hooks.zsh — additively wire any hook the rendered
# .pre-commit-config.yaml template provides but the on-disk config lacks.
#
# Why (#409): the bootstrap's gap-fill renders whole *missing* files, but an
# existing .pre-commit-config.yaml that predates a newer hook (e.g. the
# `yamllint` hook that consumes a freshly gap-filled .yamllint) is "present"
# and so is left untouched — leaving the shipped config orphaned (yamllint
# never runs, a silent no-op). Whole-file presence is the wrong unit: a config
# and the pre-commit hook that consumes it are one gap-fill unit. This
# reconciles hook-by-hook instead: for every `- repo:` block in the rendered
# template whose hook id(s) are *entirely absent* on disk, it appends that
# block to the on-disk config's `repos:` list.
#
# Granularity is the repo block (a whole missing hook *provider* — yamllint,
# gitleaks, semgrep, …), which is the realistic gap on an older repo. It does
# NOT add a single missing id back into an otherwise-present repo block, and it
# is purely ADDITIVE — it never edits or removes existing entries, so user
# customizations and pinned revs are preserved. Idempotent: a second run finds
# every id already present and changes nothing.
#
# Usage:
#   reconcile-precommit-hooks.zsh <on-disk-config> <rendered-template>
#
# <rendered-template> must be the fully-rendered config the bootstrap would
# write for THIS repo (placeholders substituted, non-matching language blocks
# already stripped) — the reconciler does not language-gate; it trusts its
# input. Prints one line per appended hook provider to stdout so the caller can
# surface what it wired; exits 0 whether or not anything was added.

emulate -L zsh
setopt err_exit nounset pipefail

if [[ $# -ne 2 ]]; then
  print -u2 -- "usage: reconcile-precommit-hooks.zsh <on-disk-config> <rendered-template>"
  exit 2
fi

local config="$1" rendered="$2"
[[ -f "$config" ]] || { print -u2 -- "no such config: $config"; exit 1; }
[[ -f "$rendered" ]] || { print -u2 -- "no such rendered template: $rendered"; exit 1; }

local work; work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Split the rendered template into top-level `- repo:` blocks, one temp file
# each. Lines before the first `- repo:` (the `repos:` header + banner comments)
# are skipped — we only carry actual hook providers.
awk -v dir="$work" '
  /^  - repo:/ { n++; file = sprintf("%s/block.%03d", dir, n) }
  n > 0 { print > file }
' "$rendered"

local added=0 block trimmed id found
local -a ids
for block in "$work"/block.*(N); do
  # The split includes everything up to the next `- repo:`, which can trail the
  # following section's banner comment / blank lines. Trim trailing blank and
  # comment-only lines so a block carries only its own content.
  trimmed="$block.trim"
  awk '
    { lines[NR] = $0 }
    END {
      last = NR
      while (last > 0 && (lines[last] ~ /^[[:space:]]*$/ || lines[last] ~ /^[[:space:]]*#/)) last--
      for (i = 1; i <= last; i++) print lines[i]
    }
  ' "$block" > "$trimmed"

  # Hook ids declared in this block.
  ids=("${(@f)$(grep -E '^[[:space:]]*-[[:space:]]*id:' "$trimmed" \
    | sed -E 's/^[[:space:]]*-[[:space:]]*id:[[:space:]]*//; s/[[:space:]]*(#.*)?$//')}")
  [[ ${#ids[@]} -eq 0 ]] && continue

  # Already present if ANY of its ids appears on disk — don't re-add a provider
  # the user already has (possibly customized).
  found=0
  for id in $ids; do
    if grep -qE "^[[:space:]]*-[[:space:]]*id:[[:space:]]*${id}([[:space:]]|\$)" "$config"; then
      found=1
      break
    fi
  done
  (( found )) && continue

  # Missing provider → append additively. Ensure the config ends with a newline
  # first so the appended list item can't fuse onto the last existing line.
  [[ -n "$(tail -c1 "$config")" ]] && print >> "$config"
  {
    print -- "  # --- ${(j:, :)ids} — wired by gap-fill reconcile (#409) ---"
    cat "$trimmed"
  } >> "$config"
  print -- "wired hook provider: ${(j:, :)ids}"
  added=$((added + 1))
done

[[ $added -eq 0 ]] && print -- "all template hook providers already present — nothing to wire."
exit 0
