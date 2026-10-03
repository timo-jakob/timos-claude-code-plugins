#!/usr/bin/env bats
#
# The claude-plugin panel's dispatch schedule (#2008). The review skill's Step 1
# table IS the round's plan: `planned` below derives a round's dimension set
# from the table's own **Runs** cells, so editing a cell changes what these
# cases see, and a cell in a shape this suite does not know fails loudly rather
# than being read as "every round". Alongside: the pins on the agent narrowed to
# `manifest_bump`, review-loop.md's carry-driven dispatch rule and its
# panel-verdict row, and ARCHITECTURE.md's six-dimension passage.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO_ROOT/development-claude-plugin/skills/review/SKILL.md"
  AGENT="$REPO_ROOT/development-claude-plugin/agents/claude-plugin-manifest-check.md"
  LOOP_REF="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  BUMP_CELL='`scope_mode` is `"full"`, or no plan; on a `"delta"` round only when the split-carry map holds `manifest_bump`'
  CONTRACT_CELL='`scope_mode` is `"full"`, or no plan, or `contract` is not in `skippable_dimensions`, or the split-carry map holds `contract`'
}

# Step 1's table rows as "reviewer<TAB>kind<TAB>dimension<TAB>runs".
step1_rows() {
  awk -F'|' '
    /^## Step 1:/ { on = 1; next }
    /^## / && on { exit }
    on && /^\| (claude-plugin-|check-manifests)/ {
      for (i = 2; i <= 6; i++) { gsub(/^ +| +$/, "", $i) }
      printf "%s\t%s\t%s\t%s\n", $2, $3, $5, $6
    }' "$SKILL"
}

# planned <scope_mode|none> <comma-separated split-carry keys> [<comma-separated
# skippable_dimensions>] → the round's dimensions, sorted, space-joined.
planned() {
  local mode="$1" keys=",$2," skippable=",${3:-}," reviewer kind dim runs out=()
  while IFS=$'\t' read -r reviewer kind dim runs; do
    case "$runs" in
    "every round") out+=("$dim") ;;
    "$BUMP_CELL")
      if [ "$mode" = full ] || [ "$mode" = none ] \
        || { [ "$mode" = delta ] && [[ "$keys" == *",manifest_bump,"* ]]; }; then
        out+=("$dim")
      fi ;;
    "$CONTRACT_CELL")
      if [ "$mode" = full ] || [ "$mode" = none ] || [[ "$skippable" != *",contract,"* ]] \
        || [[ "$keys" == *",contract,"* ]]; then
        out+=("$dim")
      fi ;;
    *) echo "unknown Runs cell for $reviewer: $runs" >&2; return 1 ;;
    esac
  done < <(step1_rows)
  printf '%s\n' "${out[@]}" | LC_ALL=C sort | paste -sd' ' -
}

ALL6="contract manifest manifest_bump prose_logic script_quality tests"
NO_BUMP="contract manifest prose_logic script_quality tests"

@test "the Step 1 table lists six reviewers: five agents and the manifest script" {
  [ "$(step1_rows | wc -l | tr -d ' ')" -eq 6 ]
  [ "$(step1_rows | awk -F'\t' '$1 == "check-manifests.zsh" { print $2 "/" $3 "/" $4 }')" = "script/manifest/every round" ]
  [ "$(step1_rows | awk -F'\t' '$1 == "claude-plugin-manifest-check" { print $2 "/" $3 }')" = "agent/manifest_bump" ]
  [ "$(step1_rows | awk -F'\t' '$2 == "agent"' | wc -l | tr -d ' ')" -eq 5 ]
}

@test "round 1 (full, no carry) plans all six dimensions" {
  [ "$(planned full "")" = "$ALL6" ]
}

@test "the closing sweep (full) plans all six dimensions, whatever the carry holds" {
  [ "$(planned full "tests,contract")" = "$ALL6" ]
  [ "$(planned full "manifest_bump")" = "$ALL6" ]
}

@test "a delta round with no manifest_bump carry runs the script but not the agent" {
  [ "$(planned delta "")" = "$NO_BUMP" ]
  [ "$(planned delta "manifest,tests")" = "$NO_BUMP" ]
}

@test "a delta round whose split-carry map holds manifest_bump runs the script and the agent" {
  [ "$(planned delta "manifest_bump")" = "$ALL6" ]
}

@test "a standalone run (no plan) plans all six dimensions" {
  [ "$(planned none "")" = "$ALL6" ]
}

# --- #2009: the contract row

NO_CONTRACT="manifest prose_logic script_quality tests"

@test "the contract row carries the #2009 dispatch condition" {
  [ "$(step1_rows | awk -F'\t' '$1 == "claude-plugin-contract-integrity" { print $2 "/" $3 "/" $4 }')" = "agent/contract/$CONTRACT_CELL" ]
}

@test "a skipping delta round (skippable_dimensions holds contract, no contract carry) does not plan contract" {
  [ "$(planned delta "" "contract")" = "$NO_CONTRACT" ]
  [ "$(planned delta "tests,manifest" "contract")" = "$NO_CONTRACT" ]
}

@test "a delta round whose split-carry map holds contract plans contract even when the plan says skippable" {
  [ "$(planned delta "contract" "contract")" = "$NO_BUMP" ]
}

@test "a triggering delta round (skippable_dimensions []) plans contract" {
  [ "$(planned delta "" "")" = "$NO_BUMP" ]
}

@test "a full round and a standalone run plan contract whatever skippable_dimensions holds" {
  [ "$(planned full "" "contract")" = "$ALL6" ]
  [ "$(planned none "" "contract")" = "$ALL6" ]
}

@test "Step 1 states where skippable_dimensions is read, hook mode included (#2009)" {
  contains "$(cat "$SKILL")" 'The `contract` row (#2009): it runs on every full round, and on a'
  contains "$(cat "$SKILL")" 'dispatch descriptor (in hook mode, `$REVIEW_SKIPPABLE_DIMENSIONS`, a JSON array string); a standalone run has'
  contains "$(cat "$SKILL")" 'neither, which is the *no plan* case. A carried `contract` entry still brings it back, by the same'
}

@test "review-loop.md documents skippable_dimensions and cites Carry-driven dispatch (#2008) (#2009)" {
  local sec
  sec="$(sed -n '/^### Skippable dimensions (#2009)$/,/^### /p' "$LOOP_REF")"
  contains "$sec" '`review-dispatch.zsh plan` always emits `skippable_dimensions`'
  contains "$sec" 'Hook mode exports it as `$REVIEW_SKIPPABLE_DIMENSIONS`.'
  contains "$sec" 'by *Carry-driven dispatch'
  # AC3: an omitted contract is accepted; a planned-but-not-run one is still the verdict row
  contains "$sec" 'A delta round whose plan omitted `contract` returns no contract'
  contains "$sec" 'verdict and is consumed like any other round — the loop adds no check of its'
  contains "$sec" '`failed` / `dimension-not-run` row of the *Panel subagent brief*.'
  contains "$(cat "$LOOP_REF")" '| a planned dimension did not run | `failed` / `dimension-not-run` |'
  # cited, never restated: the carry rule's bold sentence lives only in its own section
  lacks "$sec" 'is dispatched on a delta round exactly'
  contains "$sec" '`<work-dir>/skippable-<R>.json`'
  contains "$sec" '`skipped_dimensions_by_round`'
}

@test "ARCHITECTURE.md's claude-plugin panel passage states the contract schedule (#2009)" {
  contains "$(cat "$ARCH")" '`contract` (#2009) has a schedule of'
  contains "$(cat "$ARCH")" '`select-contract-dimension.zsh` finds that the fix pass touched no contract'
  contains "$(cat "$ARCH")" '`skippable_dimensions` (#2009) is always present: the dimensions this round'"'"'s'
}

@test "Step 1 states the dispatch condition, the not-planned rule and the script invocation" {
  contains "$(cat "$SKILL")" '## Step 1: Plan the round, then run its script and launch its agents in parallel'
  contains "$(cat "$SKILL")" '**This table is the round'"'"'s plan**'
  contains "$(cat "$SKILL")" '**A dimension the table does not plan for this round is not run and produces nothing**'
  contains "$(cat "$SKILL")" '--base <the plan'"'"'s base, or origin/main standalone> --round {ROUND}'
  contains "$(cat "$SKILL")" 'In hook mode (no descriptor, but not the table'"'"'s *no plan*), the two values are `$REVIEW_REPO` and `$REVIEW_BASE`.'
  contains "$(cat "$SKILL")" 'On a carried round whose split-carry map holds `manifest`, add `--fix-verification <the path the map gives'
  contains "$(cat "$SKILL")" 'invocation (or a carried entry this script does not own): fix the call and re-run once. Any other non-zero'
  contains "$(cat "$SKILL")" 'exit, or a second exit 2, means the `manifest` dimension did not run.'
  contains "$(cat "$SKILL")" 'The five agents are prose and cannot be unit-tested — the `manifest` script is,'
  lacks "$(cat "$SKILL")" 'Launch All 5 Review Agents'
  lacks "$(cat "$SKILL")" 'Wait for all 5 background agents'
}

@test "claude-plugin-manifest-check declares manifest_bump and does not report the moved checks at any severity" {
  contains "$(cat "$AGENT")" 'You are the `manifest_bump` dimension.'
  contains "$(cat "$AGENT")" '**do not report them at any severity**'
  for moved in 'plugin content changed with no version bump' 'a needless bump on a plugin whose content did not' \
    'versions out of lockstep' 'a plugin listed in only one manifest' '`source` path that does not match the plugin directory' \
    'a version that is not plain `X.Y.Z`'; do
    contains "$(sed -n '/^## What You Do Not Report/,/^## What You Look For/p' "$AGENT")" "$moved"
  done
  contains "$(cat "$AGENT")" '- **WARNING:** Bump size clearly wrong for the change'
  contains "$(cat "$AGENT")" '- **SUGGESTION:** Stale descriptions'
  lacks "$(cat "$AGENT")" '- **CRITICAL:**'
  lacks "$(cat "$AGENT")" '### Lockstep'
  lacks "$(cat "$AGENT")" '### Bump presence'
}

@test "the bump-size agent is handed each bump's base version, and without it reports no bump size above SUGGESTION" {
  contains "$(cat "$SKILL")" '**The `Version increments:` line goes to `claude-plugin-manifest-check` alone.**'
  contains "$(cat "$SKILL")" '`git show <base>:<plugin>/.claude-plugin/plugin.json` in the script'"'"'s `--repo` and `--base`, and list'
  contains "$(cat "$SKILL")" 'Version increments (claude-plugin-manifest-check only): {increments} — each bumped plugin'"'"'s version at the base and in this tree, as <plugin>: <base version> -> <new version>.'
  contains "$(cat "$AGENT")" 'Size each bump against the prompt'"'"'s `Version increments:` line'
  contains "$(cat "$AGENT")" '**Without that line, report no bump-size finding above SUGGESTION**'
}

@test "review-loop.md states Carry-driven dispatch (#2008) and the planned-dimension row" {
  contains "$(cat "$LOOP_REF")" '### Carry-driven dispatch (#2008)'
  contains "$(cat "$LOOP_REF")" '**A dimension skipped on delta rounds is dispatched on a delta round exactly'
  contains "$(cat "$LOOP_REF")" 'when #2010'"'"'s split-carry map holds its key.**'
  contains "$(cat "$LOOP_REF")" '| a planned dimension did not run | `failed` / `dimension-not-run` |'
  lacks "$(cat "$LOOP_REF")" 'a reviewer dimension did not run'
  contains "$(cat "$LOOP_REF")" 'it is neither run nor missing, so it never raises `dimension-not-run`'
  contains "$(cat "$LOOP_REF")" 'which you append to `carry-lines-<R>.txt`'
}

@test "ARCHITECTURE.md's claude-plugin panel passage names six dimensions, manifest from the script" {
  contains "$(cat "$ARCH")" '(`claude-plugin-script-reviewer`), `manifest` (`check-manifests.zsh`) and'
  contains "$(cat "$ARCH")" '`manifest_bump` (`claude-plugin-manifest-check`) are its extension, while `tests`'
  contains "$(cat "$ARCH")" 'six claude-plugin dimensions in total (#2008)'
  lacks "$(tr '\n' ' ' < "$ARCH")" 'five claude-plugin dimensions in total'
}
