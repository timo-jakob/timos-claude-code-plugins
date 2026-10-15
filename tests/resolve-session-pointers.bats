#!/usr/bin/env bats
#
# Every resolve-issue prose file that decides "is a human present?" points at
# the session-mode helper (#2583). #2575 made §0a's determination read
# scripts/resolve-session.zsh; a shard that restates the determination in its
# own words and never names the helper would keep inferring presence after the
# mode says `unattended`. What these pin down:
#
#   * THE SWEEP — a repo-wide invariant over `git ls-files`, never a closed file
#     list: every development/skills/resolve-issue/*.md file matching the
#     detection ERE contains the literal `resolve-session.zsh`. The check is per
#     file, because a byte-frozen `<!-- moved: -->` span can never carry the name.
#   * IT BITES — a matching shard copied into a scratch git repo with the name
#     removed fails the sweep; the unmutated copy passes.
#   * THE BRANCHES — each asking branch's file names the helper and routes
#     `unattended` to its existing autonomous arm (prose routing only).
#
# Anchored by content, never by line number (#1189).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RI="$REPO_ROOT/development/skills/resolve-issue"
  REF="$RI/reference"
  POINTER='Whether a human is present is §0a'"'"'s determination, read from `scripts/resolve-session.zsh`: `attended` takes the interactive arm, `unattended` takes the autonomous arm and never prompts.'
}

# The detection ERE, verbatim from #2583's story spec.
DETECT='human-present|human is present|no human present|no human to prompt|autonomous run|autonomous /|autonomous[,;]|interactive run|interactive only|^[[:space:]]*- \*\*(autonomous|interactive)|AskUserQuestion'

# sweep <repo-root> — print every tracked resolve-issue *.md file that matches
# the detection ERE but does not name resolve-session.zsh; status 1 when any
# does, 2 when nothing matched at all (a vacuous walk is never a pass).
sweep() {
  local root="$1" f matched=0 bad=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if grep -qiE "$DETECT" "$root/$f"; then
      matched=$((matched + 1))
      if ! grep -qF 'resolve-session.zsh' "$root/$f"; then
        printf '%s\n' "$f"
        bad=1
      fi
    fi
  done < <(git -C "$root" ls-files -- 'development/skills/resolve-issue/*.md')
  [ "$matched" -gt 0 ] || return 2
  return "$bad"
}

# flat <file> — the file's text on one line, whitespace runs collapsed, so a
# needle that wraps across lines still matches
flat() {
  tr '\n' ' ' < "$1" | tr -s '[:space:]' ' '
}

# --- the sweep ----------------------------------------------------------------

@test "#2583 every resolve-issue prose file that decides presence names resolve-session.zsh" {
  run sweep "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "these files decide presence but never name the helper:"; echo "$output"; return 1; }
}

@test "#2583 the sweep is not vacuous: it walks at least the twelve deciding files" {
  local n=0 f
  while IFS= read -r f; do
    grep -qiE "$DETECT" "$REPO_ROOT/$f" && n=$((n + 1))
  done < <(git -C "$REPO_ROOT" ls-files -- 'development/skills/resolve-issue/*.md')
  [ "$n" -ge 12 ] || { echo "only $n files match the detection ERE"; return 1; }
}

@test "#2583 MUTATION: a deciding shard without the helper's name fails the sweep; the unmutated copy passes" {
  local scratch="$BATS_TEST_TMPDIR/repo" rel="development/skills/resolve-issue/reference/promotion/gate.md"
  mkdir -p "$scratch/$(dirname "$rel")"
  git -C "$scratch" init -q
  cp "$REPO_ROOT/$rel" "$scratch/$rel"
  git -C "$scratch" add "$rel"
  run sweep "$scratch"
  [ "$status" -eq 0 ]
  # remove every mention of the helper, keeping the deciding prose
  sed -i.bak 's/resolve-session\.zsh/resolve-mode.zsh/g' "$scratch/$rel"
  rm -f "$scratch/$rel.bak"
  run sweep "$scratch"
  [ "$status" -eq 1 ]
  [ "$output" = "$rel" ]
}

@test "#2583 every file that offers an AskUserQuestion names resolve-session.zsh" {
  local f bad=""
  while IFS= read -r f; do
    if grep -qF 'AskUserQuestion' "$REPO_ROOT/$f" && ! grep -qF 'resolve-session.zsh' "$REPO_ROOT/$f"; then
      bad="$bad $f"
    fi
  done < <(git -C "$REPO_ROOT" ls-files -- 'development/skills/resolve-issue/*.md')
  [ -z "$bad" ] || { echo "AskUserQuestion without the helper:$bad"; return 1; }
}

# --- the asking branches route unattended to the autonomous arm ----------------

@test "#2583 dependency remediation points at the helper and routes unattended to the autonomous arm" {
  contains "$(flat "$REF/interactive/remediation.md")" "$POINTER"
}

@test "#2583 the size pre-flight override is attended-only, and unattended takes terminal (c)" {
  local skill
  skill="$(flat "$RI/SKILL.md")"
  contains "$skill" '**(a) The human overrides.** Interactive only (mode `attended`, §0a'"'"'s `resolve-session.zsh`)'
  contains "$skill" '**(c) No human present** (autonomous: mode `unattended`, §0a'"'"'s `resolve-session.zsh` — an E3 child included). Never prompt: take (b) without the question.'
  contains "$skill" 'Never prompt: take (b) without the question.'
}

@test "#2583 the interactive extension points at the helper, before its frozen span and in the index" {
  contains "$(flat "$REF/interactive/extension.md")" "$POINTER"
  contains "$(flat "$REF/interactive/extension-grant.md")" "$POINTER"
  contains "$(flat "$REF/interactive.md")" "$POINTER"
  contains "$(flat "$RI/SKILL.md")" 'On an interactive run (mode `attended`, §0a'"'"'s `resolve-session.zsh`), `BUDGET_EXHAUSTED` and `ESCALATE_NO_CONVERGENCE` first'
}

@test "#2583 the NOT APPLICABLE options point at the helper" {
  contains "$(flat "$REF/review-loop/exit-2-stale-findings.md")" "$POINTER"
  contains "$(flat "$REF/review-loop/subagents.md")" "$POINTER"
}

@test "#2583 suggestion promotion points at the helper, and the CONVERGED offer is attended-only" {
  contains "$(flat "$REF/promotion/gate.md")" "$POINTER"
  contains "$(flat "$REF/promotion/step-3-select.md")" "$POINTER"
  contains "$(flat "$REF/promotion.md")" "$POINTER"
  contains "$(flat "$RI/SKILL.md")" '**`CONVERGED`** (exit 0) → on an **interactive** run (mode `attended`, §0a'"'"'s `resolve-session.zsh`) with at least one waived'
}

@test "#2583 the escalation terminal points at the helper" {
  contains "$(flat "$REF/escalation.md")" "$POINTER"
}

@test "#2583 every pointer sits outside the byte-frozen spans" {
  local f inside
  for f in "$REF"/escalation.md "$REF"/interactive/*.md "$REF"/promotion/*.md "$REF"/review-loop/exit-2-stale-findings.md; do
    inside="$(awk '/^<!-- moved: /{m=1} /^<!-- \/moved: /{m=0} m && /resolve-session\.zsh/' "$f")"
    [ -z "$inside" ] || { echo "$f names the helper inside a moved span: $inside"; return 1; }
  done
}

@test "#2583 the docs say every asking branch follows the setting, no longer deferring to #2583" {
  contains "$(flat "$REPO_ROOT/docs/how-to/run-resolve-issue-unattended.md")" 'Every branch of a single-issue run that would ask you follows the setting'
  contains "$(flat "$REPO_ROOT/docs/reference/plugins.md")" 'Every branch that would ask you follows it'
  run grep -cF '#2583' "$REPO_ROOT/docs/how-to/run-resolve-issue-unattended.md" "$REPO_ROOT/docs/reference/plugins.md"
  [ "$status" -eq 1 ]
}
