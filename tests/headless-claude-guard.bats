#!/usr/bin/env bats
#
# Repo-wide guard (#2191): no autonomous flow launches a headless `claude`.
# Every tracked file is swept for the needles below, and a hit passes only
# when it is covered by one of two allow-list tiers:
#
#   tier 1 — whole files that are ABOUT the human-invoked test harness, its
#            fixtures and tests, or are historical records;
#   tier 2 — exact (path, full line) pairs: a sentence that BANS headless use,
#            or cites the harness without running it, inside a file that must
#            otherwise stay clean (the conductor, its reference files,
#            ARCHITECTURE.md, …).
#
# The sweep is `git ls-files`, never a closed list of swept files, so a new file
# is covered the day it is tracked. A tier-2 entry that no longer matches its
# file reds too, so the table cannot rot into a list of dead exemptions.
#
# Every resolve-profile skill, the rest of the resolve-issue conductor with its
# reference/ files, and every maintenance skill must be clean; the allow-list
# test below refuses an entry that would widen into any of them.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export LC_ALL=C
}

# BSD-safe: no \b (macOS grep reads it differently), no -Z/-z.
_needle_re() {
  printf '%s' 'development-claude-plugin:test|run-headless|claude -p([^[:alnum:]_-]|$)|claude --print|--output-format stream-json'
}

# Tier 1: whole files. A trailing `/` allows the tree beneath it.
_tier1() {
  printf '%s\n' \
    'development-claude-plugin/skills/test/' \
    'development-claude-plugin/docs/test-harness.md' \
    'tests/run-headless.bats' \
    'development-claude-plugin/.claude-plugin/plugin.json' \
    '.claude-plugin/marketplace.json' \
    'docs/reference/commands.md' \
    'docs/reference/plugins.md' \
    'docs/adding-a-language-plugin.md' \
    'development-claude-plugin/skills/review/scripts/build-golden-798-target.zsh' \
    'tests/build-golden-798-target.bats' \
    'tests/run-script-tests.zsh' \
    'tests/switch-fable-to-opus.bats' \
    'tests/round-boundary-concurrency.bats' \
    'docs/superpowers/' \
    'development/skills/resolve-issue/docs/' \
    'tests/headless-claude-guard.bats' \
    'tests/e4-in-session-needles.bats'
}

# Tier 2: `path<TAB>exact full line`. The core.md lines sit in the byte-frozen
# `round-protocol-head` span, which this guard pins rather than edits.
_tier2() {
  printf '%s\t%s\n' \
    'development/skills/resolve-issue/SKILL.md' \
    'rules: **never** shell out to a headless `claude` (`claude -p` / `--print`)' \
    'development/skills/resolve-issue/reference/review-loop/core.md' \
    "   \`development-claude-plugin:test\`'s \`run-headless.zsh\` — **a shape reference," \
    'development/skills/resolve-issue/reference/review-loop/core.md' \
    '   `claude -p`, which the gate must never be: passing `<full gate>` as its' \
    'development/skills/resolve-issue/reference/review-loop/core.md' \
    '     `development-claude-plugin:test` records the opposite for Claude Code'"'"'s' \
    'development/skills/resolve-issue/scripts/resolve-story-loop.zsh' \
    '# headless `claude -p` behind it is NOT a supported pattern — it hides the' \
    'ARCHITECTURE.md' \
    'exit-state — a pure, testable function; wiring a headless `claude -p` behind' \
    'ARCHITECTURE.md' \
    '— and run `claude -p --plugin-dir <tmp> --output-format stream-json --verbose`,' \
    'docs/explanation/review-loop.md' \
    'model-driven steps to run inside headless `claude -p` hooks, which put a whole' \
    'development-claude-plugin/skills/review/SKILL.md' \
    '/development-claude-plugin:test --target <printed path> \'
}

_in_tier1() {
  local path="$1" entry
  while IFS= read -r entry; do
    case "$entry" in
      */) case "$path" in "$entry"*) return 0 ;; esac ;;
      *) [ "$path" = "$entry" ] && return 0 ;;
    esac
  done < <(_tier1)
  return 1
}

_in_tier2() {
  local path="$1" line="$2" p l
  while IFS=$'\t' read -r p l; do
    [ "$p" = "$path" ] && [ "$l" = "$line" ] && return 0
  done < <(_tier2)
  return 1
}

# Print every uncovered hit as `path:lineno:line`. Reads repo-relative paths
# from stdin and resolves them under $1. One grep over the whole list (no repo
# path contains a `:`, so the first two fields split cleanly).
_violations() {
  local root="$1" hit rel rest lineno line
  while IFS= read -r hit; do
    rel="${hit%%:*}"
    rest="${hit#*:}"
    lineno="${rest%%:*}"
    line="${rest#*:}"
    _in_tier1 "$rel" && continue
    _in_tier2 "$rel" "$line" && continue
    printf '%s:%s:%s\n' "$rel" "$lineno" "$line"
  done < <(
    cd "$root" || exit 1
    while IFS= read -r rel; do
      [ -f "$rel" ] && printf '%s\0' "$rel"
    done | xargs -0 grep -n -H -I -E -- "$(_needle_re)" /dev/null || true
  )
}

# Print every tier-2 entry whose exact line is missing from its file under $1.
_stale_tier2() {
  local root="$1" p l
  while IFS=$'\t' read -r p l; do
    grep -qxF -- "$l" "$root/$p" 2>/dev/null || printf '%s\t%s\n' "$p" "$l"
  done < <(_tier2)
}

@test "#2191 no tracked file names a headless claude outside the allow-list" {
  local out
  out="$(git -C "$REPO_ROOT" ls-files | _violations "$REPO_ROOT")"
  [ -z "$out" ] || {
    printf 'headless-claude reference(s) outside the allow-list (#2191):\n%s\n' "$out" >&2
    printf 'An autonomous flow must not launch a headless claude. If this is the\n' >&2
    printf 'human-invoked harness or a ban sentence, add a tier-1 or tier-2 entry.\n' >&2
    return 1
  }
}

@test "#2191 the sweep is not vacuous: it sees the harness itself" {
  local n
  n="$(git -C "$REPO_ROOT" grep -c -I -E -- "$(_needle_re)" -- \
    development-claude-plugin/skills/test/SKILL.md | cut -d: -f2)"
  [ "${n:-0}" -gt 0 ]
}

@test "#2191 every tier-2 entry still matches its file" {
  local out
  out="$(_stale_tier2 "$REPO_ROOT")"
  [ -z "$out" ] || {
    printf 'stale tier-2 entries (the pinned line is gone from its file):\n%s\n' "$out" >&2
    return 1
  }
}

@test "#2191 the allow-list never widens into a profile, the conductor or a maintenance skill" {
  local e bad="" p l
  while IFS= read -r e; do
    case "$e" in
      */skills/resolve-profile/*|*/skills/maintenance/*) bad+="tier 1: $e"$'\n' ;;
      development/skills/resolve-issue/docs/) : ;;
      development/skills/resolve-issue/*) bad+="tier 1: $e"$'\n' ;;
    esac
  done < <(_tier1)
  while IFS=$'\t' read -r p l; do
    case "$p" in
      */skills/resolve-profile/*|*/skills/maintenance/*) bad+="tier 2: $p"$'\n' ;;
    esac
  done < <(_tier2)
  [ -z "$bad" ] || { printf 'allow-list entries that must stay clean:\n%s\n' "$bad" >&2; return 1; }
}

@test "#2191 mutation: re-adding the old E4 sentence to the claude-plugin profile reds the guard" {
  local rel='development-claude-plugin/skills/resolve-profile/SKILL.md' root out
  root="$BATS_TEST_TMPDIR/mut-e4"
  mkdir -p "$(dirname "$root/$rel")"
  cp "$REPO_ROOT/$rel" "$root/$rel"
  # the clean copy passes first, so the red below is the mutation's doing
  out="$(printf '%s\n' "$rel" | _violations "$root")"
  [ -z "$out" ]
  printf '%s\n' '  `/development-claude-plugin:test` driving the affected skills/agents' >> "$root/$rel"
  out="$(printf '%s\n' "$rel" | _violations "$root")"
  [ -n "$out" ]
  case "$out" in "$rel":*) : ;; *) printf 'unexpected violation: %s\n' "$out" >&2; return 1 ;; esac
}

@test "#2191 mutation: deleting a pinned tier-2 line reds the guard" {
  local p l root out
  root="$BATS_TEST_TMPDIR/mut-t2"
  while IFS=$'\t' read -r p l; do
    mkdir -p "$(dirname "$root/$p")"
    [ -f "$root/$p" ] || cp "$REPO_ROOT/$p" "$root/$p"
  done < <(_tier2)
  out="$(_stale_tier2 "$root")"
  [ -z "$out" ]
  # delete the conductor's §3.5 hard-rule line from the copy
  p='development/skills/resolve-issue/SKILL.md'
  l="$(_tier2 | awk -F '\t' -v p="$p" '$1 == p { print $2; exit }')"
  [ -n "$l" ]
  grep -vxF -- "$l" "$REPO_ROOT/$p" > "$root/$p" || true
  out="$(_stale_tier2 "$root")"
  [ "$out" = "$p"$'\t'"$l" ]
}
