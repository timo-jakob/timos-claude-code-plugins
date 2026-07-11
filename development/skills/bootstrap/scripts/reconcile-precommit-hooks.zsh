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
# One tightly-scoped exception (#602): stale `coverage-floor*` pre-push hooks.
# Pre-#379 those hooks shipped with `always_run: true` and no `files:` guard, so
# a zero-covered-language push (a docs/workflow-only change) was blocked
# demanding a vacuous coverage report. #379 replaced always_run with a
# covered-source `files:` filter that lets pre-commit skip the hook. An older
# repo still carries the stale shape, so this reconciler ALSO migrates it in
# place to the guarded form — the one deliberate non-additive edit here, and a
# safe one: it only rewrites a coverage-floor* hook that BOTH still has
# `always_run: true` AND lacks a `files:` line, and it pulls the canonical
# `files:` value for each id from the rendered template rather than hardcoding.
#
# With --scan (#410): after wiring, run each newly-wired hook repo-wide
# (`pre-commit run <id> --all-files`) BEFORE the caller commits. Introducing a
# repo-wide enforcing hook (yamllint, gitleaks, …) on a non-greenfield repo
# almost always hits pre-existing violations; discovering them at push time —
# or in CI — is late and disruptive (it blocked a bot push mid-flow on
# ai-doc-organizer PR #86). The proactive scan auto-fixes what the hooks can
# (trailing-whitespace, ruff, …) and surfaces what they can't (yamllint), so
# the caller resolves it before committing. Only the NEWLY-wired hooks are
# scanned — hooks that were already present were already passing.
#
# Usage:
#   reconcile-precommit-hooks.zsh [--scan] <on-disk-config> <rendered-template>
#
# <rendered-template> must be the fully-rendered config the bootstrap would
# write for THIS repo (placeholders substituted, non-matching language blocks
# already stripped) — the reconciler does not language-gate; it trusts its
# input. Prints one line per appended hook provider to stdout so the caller can
# surface what it wired.
#
# Exit codes:
#   0  reconcile (and any --scan) completed clean — nothing left to handle
#   2  usage error
#   1  a path argument doesn't exist
#   3  --scan: a newly-wired hook surfaced violations or modified files on
#      pre-existing content — the caller must fix/stage them BEFORE committing
#
# Seam: PRE_COMMIT_BIN overrides the `pre-commit` binary (for tests / non-PATH
# installs). If pre-commit isn't found, --scan warns and skips (exit stays 0).

emulate -L zsh
setopt err_exit nounset pipefail

local scan=0
local -a positional
while [[ $# -gt 0 ]]; do
  case "$1" in
  --scan) scan=1; shift ;;
  --) shift; positional+=("$@"); break ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) positional+=("$1"); shift ;;
  esac
done

if [[ ${#positional[@]} -ne 2 ]]; then
  print -u2 -- "usage: reconcile-precommit-hooks.zsh [--scan] <on-disk-config> <rendered-template>"
  exit 2
fi

local config="${positional[1]}" rendered="${positional[2]}"
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
local -a ids wired_ids
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
  wired_ids+=($ids)
  added=$((added + 1))
done

[[ $added -eq 0 ]] && print -- "all template hook providers already present — nothing to wire."

# --- #713: migrate stale coverage-floor hooks to the diff-guarded entry -------
# The canonical coverage-floor* hooks decide run/skip INSIDE `entry`, on the
# origin/<default>...HEAD diff (marker: `git diff --name-only`), with
# `always_run: true` and no `files:`. This supersedes both earlier shapes — the
# pre-#379 unguarded `always_run` (over-fired on every push, #602) and the #379
# `files:` filter (over-fires on a brand-new branch push, whose empty-tree
# comparison counts every source file as "added", #713). Migrate any on-disk
# coverage-floor* hook whose entry LACKS the diff guard by replacing its block
# with the template's canonical one — surgical, so sibling user hooks in the
# file are untouched (unlike a whole-file re-render).
local -a cf_ids
cf_ids=("${(@f)$(grep -E '^[[:space:]]*-[[:space:]]*id:[[:space:]]*coverage-floor' "$rendered" 2>/dev/null \
  | sed -E 's/^[[:space:]]*-[[:space:]]*id:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' || true)}")

local cfid tmpl_block cf_block
for cfid in $cf_ids; do
  [[ -n "$cfid" ]] || continue

  # The template's canonical block for this id (id line + body, up to the next
  # sibling `- id:`/`- repo:`).
  tmpl_block="$(awk -v id="$cfid" '
    $0 ~ "^[[:space:]]*-[[:space:]]*id:[[:space:]]*" id "([[:space:]]|$)" { inb=1; print; next }
    inb && /^[[:space:]]*-[[:space:]]*id:/ { inb=0 }
    inb && /^[[:space:]]*-[[:space:]]*repo:/ { inb=0 }
    inb { print }
  ' "$rendered")"
  [[ -n "$tmpl_block" ]] || continue

  # The on-disk hook block for this id (empty if the hook isn't present).
  cf_block="$(awk -v id="$cfid" '
    $0 ~ "^[[:space:]]*-[[:space:]]*id:[[:space:]]*" id "([[:space:]]|$)" { inb=1; print; next }
    inb && /^[[:space:]]*-[[:space:]]*id:/ { inb=0 }
    inb && /^[[:space:]]*-[[:space:]]*repo:/ { inb=0 }
    inb { print }
  ' "$config")"
  [[ -n "$cf_block" ]] || continue

  # Already diff-guarded -> idempotent skip. `if` guard keeps a non-matching
  # grep from tripping err_exit.
  if print -r -- "$cf_block" | grep -qF 'git diff --name-only'; then continue; fi

  # Replace the on-disk block with the template's canonical block. TMPL_BLOCK
  # rides in via the environment so awk emits it as literal bytes.
  TMPL_BLOCK="$tmpl_block" awk -v id="$cfid" '
    $0 ~ "^[[:space:]]*-[[:space:]]*id:[[:space:]]*" id "([[:space:]]|$)" && !done {
      printf "%s\n", ENVIRON["TMPL_BLOCK"]; inb=1; done=1; next
    }
    inb && /^[[:space:]]*-[[:space:]]*id:/ { inb=0 }
    inb && /^[[:space:]]*-[[:space:]]*repo:/ { inb=0 }
    inb { next }
    { print }
  ' "$config" > "$config.migrated"
  mv "$config.migrated" "$config"
  print -r -- "migrated stale coverage-floor hook: ${cfid} → diff-guarded entry (#713)"
done

# --- #410: proactively scan repo-wide with the newly-wired hooks -------------
if (( scan )) && (( ${#wired_ids[@]} > 0 )); then
  local pc="${PRE_COMMIT_BIN:-pre-commit}"
  if ! command -v "$pc" >/dev/null 2>&1; then
    print -u2 -- "pre-commit not found ($pc) — skipping the proactive repo-wide" \
      "scan of newly-wired hooks (#410); run \`pre-commit run <id> --all-files\`" \
      "for ${(j:, :)wired_ids} manually before committing."
  else
    print -- "proactively scanning repo-wide with newly-wired hook(s) before commit" \
      "(#410): ${(j:, :)wired_ids}"
    local scan_dirty=0
    # `pre-commit run <id> --all-files` exits non-zero both when a hook FAILS
    # (yamllint surfaces a violation) and when it MODIFIES files (ruff,
    # trailing-whitespace auto-fix). Either way the caller must handle it before
    # committing, so treat both as "dirty" and let the printed hook output tell
    # the story — `if !` keeps err_exit from aborting on the expected non-zero.
    for id in $wired_ids; do
      print -- "--- pre-commit run $id --all-files ---"
      if ! "$pc" run "$id" --all-files; then
        scan_dirty=1
      fi
    done
    if (( scan_dirty )); then
      print -u2 -- "a newly-wired hook auto-fixed files or surfaced pre-existing" \
        "violations (#410) — review/fix/stage them BEFORE committing, not at push."
      exit 3
    fi
    print -- "newly-wired hooks pass repo-wide — safe to commit."
  fi
fi

exit 0
