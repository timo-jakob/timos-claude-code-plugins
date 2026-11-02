#!/usr/bin/env bats
#
# The claude-plugin review panel's fallback mode (#2908): with the dispatch
# descriptor's review_mode "fallback" (in hook mode, $REVIEW_MODE=fallback) the
# panel plans only script_quality, tests and prose_logic, so resolve-issue can
# review a shell, bats or Markdown diff in a repo whose own panel reports NOT
# APPLICABLE. Routing to it is #2909's.
#
# Anchored by content, never by line number (#1189).

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO_ROOT/development-claude-plugin/skills/review/SKILL.md"
  # the fallback section alone, from its heading to Step 2's
  SECTION="$(sed -n '/^## Fallback mode /,/^## Step 2:/p' "$SKILL")"
  FLAT="$(tr '\n' ' ' <<<"$SECTION" | tr -s ' ')"
}

@test "the review skill has a fallback-mode section" {
  [ -n "$SECTION" ]
  contains "$SECTION" '## Fallback mode — shell, bats and Markdown in any repo (#2908)'
}

@test "the fallback table plans exactly script_quality, tests and prose_logic, with their file types" {
  local rows
  rows="$(grep -E '^\| claude-plugin-[a-z-]+ +\| [a-z_]+ +\|' <<<"$SECTION" \
          | sed -E 's/^\| ([a-z-]+) +\| ([a-z_]+) +\| (.*) \|$/\1=\2=\3/')"
  [ "$(wc -l <<<"$rows" | tr -d ' ')" = 3 ]
  contains "$rows" 'claude-plugin-script-reviewer=script_quality=`*.sh`, `*.zsh`, `*.bash`, and extensionless files with a sh, bash or zsh shebang'
  contains "$rows" 'claude-plugin-test-reviewer=tests=`*.bats`'
  contains "$rows" 'claude-plugin-prose-logic=prose_logic=`*.md`'
}

@test "Step 1 opens by deferring to the fallback table, before its own table and script" {
  local step1
  step1="$(sed -n '/^## Step 1:/,/^| Reviewer /p' "$SKILL" | tr '\n' ' ' | tr -s ' ')"
  contains "$step1" 'In fallback mode (see *Fallback mode* below), the round plans that section'"'"'s table instead of this one and runs no `check-manifests.zsh`.'
}

@test "each fallback reviewer's review scope is its own filtered list, and its prompt drops \"plugin\"" {
  contains "$FLAT" 'Each reviewer'"'"'s `{the review scope}` is its own filtered list: only its in-scope files from the round'"'"'s scope, which need not be plugin content. Its prompt'"'"'s `Analyze all plugin content in scope` line reads `Analyze all content in scope`, since the fallback reviews any repo.'
}

@test "a fallback reviewer with none in scope still runs when the split-carry map holds its dimension" {
  contains "$FLAT" 'A reviewer with none in scope is not dispatched unless the split-carry map holds its dimension, in which case it runs to account for its carried entries (*Carry-driven dispatch*).'
}

@test "the plugin-only dimensions are never planned in fallback mode" {
  contains "$FLAT" 'The plugin-only dimensions are never planned in fallback mode: no `contract` agent, no `manifest_bump` agent, and no `check-manifests.zsh` run.'
  contains "$FLAT" 'Steps 2–4 then cover only the dimensions that ran: no script stdout or `--carry-out` file is read or concatenated, and the Metrics line names no Manifests.'
  # and the fallback table itself names none of them
  run grep -E '^\|.*(contract|manifest_bump|check-manifests)' <<<"$SECTION"
  [ "$status" -eq 1 ]
}

@test "the trigger is review_mode \"fallback\", and \$REVIEW_MODE=fallback is its hook-mode counterpart" {
  contains "$FLAT" 'when the dispatch descriptor'"'"'s `review_mode` is `"fallback"`, or, in hook mode, when `$REVIEW_MODE` is `fallback`.'
  contains "$FLAT" '`$REVIEW_MODE` is the hook-mode counterpart of `review_mode`, as `$REVIEW_SCOPE_MODE` is of `scope_mode`.'
}

@test "any other value leaves the panel in its normal mode and the normal table unchanged" {
  contains "$FLAT" 'An unset or empty `$REVIEW_MODE`, any other value, or a descriptor without `review_mode: "fallback"` leaves the panel in its normal mode, with Step 1'"'"'s table unchanged.'
  # the normal table still plans all six dimensions
  local d
  for d in prose_logic contract script_quality tests manifest_bump manifest; do
    grep -qE "^\| [a-z.-]+ +\| (agent|script) +\| [a-z—]+ +\| ${d} +\|" "$SKILL"
  done
}

@test "a full fallback round with no in-scope file is NOT APPLICABLE, naming the files, with no findings file" {
  contains "$FLAT" '**A full round whose non-empty scope holds no in-scope file is NOT APPLICABLE**: report it to the caller, naming the out-of-scope files, and write no findings file'
}

@test "delta and carried fallback rounds keep the panel's delta and carry rules" {
  contains "$FLAT" 'A delta round and every carried round follow the rules above and in Step 1 unchanged: the delta-round `[]`, the carry triple, split-carry ownership and the carry accounting file.'
}
