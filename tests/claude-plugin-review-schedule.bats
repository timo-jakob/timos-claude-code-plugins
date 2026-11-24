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
  # #2055 split review-loop.md into shards: the carry-driven dispatch and
  # skippable-dimensions sections live in carry.md, the panel-verdict table in
  # the panel subagent brief. LOOP_DIR is the whole of what the file was.
  LOOP_DIR="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop"
  LOOP_REF="$LOOP_DIR/carry.md"
  LOOP_BRIEF="$LOOP_DIR/briefs/panel.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  CONTRACT_CELL="$(skip_cell contract)"
}

# skip_cell <dimension> -> the Runs cell every agent row carries since #2925
# part 3b: the #2009 contract cell's shape, naming the row's own dimension.
skip_cell() {
  printf '`scope_mode` is `"full"`, or no plan, or `%s` is not in `skippable_dimensions`, or the split-carry map holds `%s`' "$1" "$1"
}

# Step 1's table rows as "reviewer<TAB>kind<TAB>dimension<TAB>runs".
step1_rows() {
  awk -F'|' '
    /^## Step 1:/ { on = 1; next }
    /^## / && on { exit }
    on && /^\| (claude-plugin-|check-manifests)/ {
      for (i = 2; i <= 7; i++) { gsub(/^ +| +$/, "", $i) }
      printf "%s\t%s\t%s\t%s\n", $2, $3, $6, $7
    }' "$SKILL"
}

# planned <scope_mode|none> <comma-separated split-carry keys> [<comma-separated
# skippable_dimensions>] → the round's dimensions, sorted, space-joined.
planned() {
  local mode="$1" keys=",$2," skippable=",${3:-}," reviewer kind dim runs out=()
  while IFS=$'\t' read -r reviewer kind dim runs; do
    # only the script row runs every round; an agent row must carry the skip
    # cell naming its OWN dimension, or the cell is unknown and the case fails
    if [ "$kind" = script ] && [ "$runs" = "every round" ]; then
      out+=("$dim")
    elif [ "$kind" = agent ] && [ "$runs" = "$(skip_cell "$dim")" ]; then
      if [ "$mode" = full ] || [ "$mode" = none ] || [[ "$skippable" != *",$dim,"* ]] \
        || [[ "$keys" == *",$dim,"* ]]; then
        out+=("$dim")
      fi
    else
      echo "unknown Runs cell for $reviewer: $runs" >&2; return 1
    fi
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

@test "a delta round offering manifest_bump, with no manifest_bump carry, runs the script but not the agent" {
  [ "$(planned delta "" "manifest_bump")" = "$NO_BUMP" ]
  [ "$(planned delta "manifest,tests" "manifest_bump")" = "$NO_BUMP" ]
}

@test "a delta round whose split-carry map holds manifest_bump runs the script and the agent" {
  [ "$(planned delta "manifest_bump")" = "$ALL6" ]
  [ "$(planned delta "manifest_bump" "manifest_bump")" = "$ALL6" ]
}

@test "a standalone run (no plan) plans all six dimensions" {
  [ "$(planned none "")" = "$ALL6" ]
}

# --- #2009: the contract row

NO_CONTRACT="manifest manifest_bump prose_logic script_quality tests"

@test "the contract row carries the #2009 dispatch condition" {
  [ "$(step1_rows | awk -F'\t' '$1 == "claude-plugin-contract-integrity" { print $2 "/" $3 "/" $4 }')" = "agent/contract/$CONTRACT_CELL" ]
}

@test "a skipping delta round (skippable_dimensions holds contract, no contract carry) does not plan contract" {
  [ "$(planned delta "" "contract")" = "$NO_CONTRACT" ]
  [ "$(planned delta "tests,manifest" "contract")" = "$NO_CONTRACT" ]
}

@test "a delta round whose split-carry map holds contract plans contract even when the plan says skippable" {
  [ "$(planned delta "contract" "contract")" = "$ALL6" ]
}

@test "a triggering delta round (skippable_dimensions []) plans every dimension" {
  [ "$(planned delta "" "")" = "$ALL6" ]
}

@test "a full round and a standalone run plan contract whatever skippable_dimensions holds" {
  [ "$(planned full "" "contract")" = "$ALL6" ]
  [ "$(planned none "" "contract")" = "$ALL6" ]
}

# --- #2925 part 3b: every agent row honours skippable_dimensions

SKIPPABLE5="prose_logic,contract,script_quality,tests,manifest_bump"

@test "#2925 part 3b: every agent row carries the skip cell naming its own dimension" {
  local dim
  for dim in prose_logic contract script_quality tests manifest_bump; do
    [ "$(step1_rows | awk -F'\t' -v d="$dim" '$2 == "agent" && $3 == d { print $4 }')" = "$(skip_cell "$dim")" ] || {
      echo "the $dim row does not carry its skip cell" >&2; return 1
    }
  done
}

@test "#2925 part 3b: the check-manifests.zsh row still runs every round, whatever the plan offers" {
  [ "$(planned delta "" "$SKIPPABLE5")" = "manifest" ]
  [ "$(planned delta "" "$SKIPPABLE5,manifest")" = "manifest" ]
}

@test "#2925 part 3b: a delta round leaves out each dimension the plan offers and its carry does not hold" {
  [ "$(planned delta "" "prose_logic")" = "contract manifest manifest_bump script_quality tests" ]
  [ "$(planned delta "" "script_quality")" = "contract manifest manifest_bump prose_logic tests" ]
  [ "$(planned delta "" "tests")" = "contract manifest manifest_bump prose_logic script_quality" ]
  [ "$(planned delta "" "prose_logic,tests,manifest_bump")" = "contract manifest script_quality" ]
}

@test "#2925 part 3b: a carried entry brings its offered dimension back on a delta round" {
  [ "$(planned delta "prose_logic" "$SKIPPABLE5")" = "manifest prose_logic" ]
  [ "$(planned delta "script_quality" "$SKIPPABLE5")" = "manifest script_quality" ]
  [ "$(planned delta "tests" "$SKIPPABLE5")" = "manifest tests" ]
  [ "$(planned delta "manifest_bump,tests" "$SKIPPABLE5")" = "manifest manifest_bump tests" ]
}

@test "#2925 part 3b: a full round and a standalone run plan all six whatever the plan offers" {
  [ "$(planned full "" "$SKIPPABLE5")" = "$ALL6" ]
  [ "$(planned none "" "$SKIPPABLE5")" = "$ALL6" ]
}

@test "#2925 part 3b: Step 1 states the shared condition and the script row's every-round run" {
  local flat; flat="$(tr '\n' ' ' < "$SKILL")"
  contains "$flat" 'The five agent rows share one condition (#2009, #2925 part 3b): each runs on every full round'
  contains "$flat" 'and on a `"delta"` round unless the plan'"'"'s `skippable_dimensions` holds its dimension.'
  contains "$flat" 'Only the `check-manifests.zsh` row runs every round.'
  lacks "$flat" 'Two cells vary.'
  lacks "$flat" 'brings it back only to account for its own carried entries'
}

@test "#2925 part 3b: the Fallback mode table is unchanged" {
  local table
  table="$(sed -n '/^## Fallback mode/,/^## /p' "$SKILL" | grep '^|')"
  [ "$(printf '%s\n' "$table" | wc -l | tr -d ' ')" -eq 5 ]
  contains "$table" '| Reviewer | Dimension | In-scope files |'
  contains "$table" '| claude-plugin-script-reviewer | script_quality | `*.sh`, `*.zsh`, `*.bash`, and extensionless files with a sh, bash or zsh shebang |'
  contains "$table" '| claude-plugin-test-reviewer | tests | `*.bats` |'
  contains "$table" '| claude-plugin-prose-logic | prose_logic | `*.md` |'
  lacks "$table" 'skippable_dimensions'
}

@test "Step 1 states where skippable_dimensions is read, hook mode included (#2009)" {
  local flat; flat="$(tr '\n' ' ' < "$SKILL")"
  contains "$flat" 'Read `skippable_dimensions` from the dispatch descriptor (in hook mode, `$REVIEW_SKIPPABLE_DIMENSIONS`, a JSON array string); a standalone run has neither, which is the *no plan* case.'
  contains "$flat" 'A carried entry still brings its dimension back, by that file'"'"'s *Carry-driven dispatch (#2008)* rule.'
  contains "$flat" 'for `contract`, a pure selector finds no contract surface touched'
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
  contains "$(cat "$LOOP_BRIEF")" '| a planned dimension did not run | `failed` / `dimension-not-run` |'
  # cited, never restated: the carry rule's bold sentence lives only in its own section
  lacks "$sec" 'is dispatched on a delta round exactly'
  contains "$sec" '`<work-dir>/skippable-<R>.json`'
  contains "$sec" '`skipped_dimensions_by_round`'
}

@test "review-loop carry.md states the widened skippable field, its reasons and skip_reasons (#3311)" {
  local sec
  sec="$(sed -n '/^### Skippable dimensions (#2009)$/,/^### /p' "$LOOP_REF")"
  contains "$sec" 'it offers each of `prose_logic`, `contract`, `script_quality`, `tests` and'
  contains "$sec" 'carry, or the fix pass touched a file in its class: a `*.sh` / `*.zsh` /'
  contains "$sec" 'dimension out of the field: it runs. Beside it the plan emits'
  contains "$sec" '`dimension_reasons`, each dimension'"'"'s `carried`, `touched`, `undecided` or'
  contains "$sec" '`none` (`full` on a full round). Until the panel'"'"'s Step 1 table reads the wider'
  contains "$sec" 'field (#2925 part 3b), the panel honours only `contract` from it, and it leaves'
  contains "$sec" '`manifest_bump` out of every delta round whose carry does not hold it, whatever'
  lacks "$sec" 'only `contract` is actually left out'
  contains "$sec" 'Each round'"'"'s line in `<work-dir>/history.jsonl` records `skipped_dimensions`:'
  contains "$sec" 'the plan'"'"'s field less every dimension the round'"'"'s carry forced back in, `[]`'
  contains "$sec" 'when none. It also records `skip_reasons` (#3311): the plan'"'"'s'
  contains "$sec" '`dimension_reasons`, with every dimension the carry forced back in named'
  contains "$sec" '`carried`, `{}` when the plan named none. The loop keeps the plan'"'"'s two fields'
  contains "$sec" '`<work-dir>/skip-reasons-<R>.json`'
  contains "$sec" 'the history as `skipped_dimensions_by_round`. Both record the plan'"'"'s offer,'
  contains "$sec" 'not what the panel ran: until #2925 part 3b the panel honours only a `contract`'
  contains "$sec" 'entry, and it leaves `manifest_bump` out of every delta round whose carry does'
  contains "$sec" 'not hold it, whatever the entry or its reason says, `touched` included.'
  lacks "$sec" 'dimension the panel actually left out'
}

@test "ARCHITECTURE.md states the widened skippable field, dimension_reasons and skip_reasons as the plan's offer (#3311)" {
  local arch; arch="$(cat "$ARCH")"
  contains "$arch" 'it, and since #3311 it offers every panel dimension'
  contains "$arch" 'deleted file is classed by its prior path, a rename by both.'
  contains "$arch" '`dimension_reasons` (#3311) is always present, directly after it: an object'
  contains "$arch" 'panel needs; the script reads the file only on a claude-plugin delta round,'
  contains "$arch" 'leaves every dimension `undecided`.'
  contains "$arch" 'round'"'"'s plan offered to leave out — the plan'"'"'s `skippable_dimensions` less any'
  contains "$arch" '(#3311) is the plan'"'"'s `dimension_reasons` for that round, with every dimension'
  contains "$arch" '`null` for a history line that predates the key. It is the plan'"'"'s offer, not'
  contains "$arch" '(#2925 part 3b), the panel honours only a `contract` entry from it, and it'
  contains "$arch" 'leaves `manifest_bump` out of every delta round whose carry does not hold it,'
  contains "$arch" 'whatever the entry or its reason says, `touched` included. It joins the'
  contains "$arch" 'honours only `contract` from the field, and it leaves `manifest_bump` out of'
  lacks "$arch" 'is a dimension the panel actually left'
  lacks "$arch" 'it honours only `contract` until the panel'
  lacks "$arch" 'this script never reads the file'
  lacks "$arch" 'claude-plugin schedule actually skipped, and why'
}

@test "the telemetry how-to states skipped_dimensions_by_round as the plan's offer (#3311)" {
  local page; page="$(cat "$REPO_ROOT/docs/how-to/read-pipeline-telemetry.md")"
  contains "$page" '(until #2925 part 3b only `contract` was honoured from this list, and `manifest_bump` was left out of every delta round that did not carry it, whatever its entry or reason)'
  contains "$page" '`skip_reasons`, each dimension'"'"'s reason (`carried`, `touched`, `undecided`, `none` or `full`)'
  lacks "$page" 'only a `contract` entry was actually left out'
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
  # #3158: a stale description never reaches the blocking bar, so the check is gone
  lacks "$(cat "$AGENT")" '- **SUGGESTION:** Stale descriptions'
  lacks "$(cat "$AGENT")" '### Stale descriptions'
  contains "$(cat "$AGENT")" 'Nothing below `WARNING` is reported, except a tool-verdict claim the evidence rule caps at `SUGGESTION`.'
  lacks "$(cat "$AGENT")" '- **CRITICAL:**'
  lacks "$(cat "$AGENT")" '### Lockstep'
  lacks "$(cat "$AGENT")" '### Bump presence'
}

@test "the bump-size agent is handed each bump's base version, and without it reports no bump-size finding" {
  contains "$(cat "$SKILL")" '**The `Version increments:` line goes to `claude-plugin-manifest-check` alone.**'
  contains "$(cat "$SKILL")" '`git show <base>:<plugin>/.claude-plugin/plugin.json` in the script'"'"'s `--repo` and `--base`, and list'
  contains "$(cat "$SKILL")" 'Version increments (claude-plugin-manifest-check only): {increments} — each bumped plugin'"'"'s version at the base and in this tree, as <plugin>: <base version> -> <new version>.'
  contains "$(cat "$AGENT")" 'Size each bump against the prompt'"'"'s `Version increments:` line'
  contains "$(cat "$AGENT")" '**Without that line, report no bump-size finding**'
  lacks "$(cat "$AGENT")" 'report no bump-size finding above SUGGESTION'
}

@test "review-loop.md states Carry-driven dispatch (#2008) and the planned-dimension row" {
  contains "$(cat "$LOOP_REF")" '### Carry-driven dispatch (#2008)'
  contains "$(cat "$LOOP_REF")" '**A dimension skipped on delta rounds is dispatched on a delta round exactly'
  contains "$(cat "$LOOP_REF")" 'when #2010'"'"'s split-carry map holds its key.**'
  contains "$(cat "$LOOP_BRIEF")" '| a planned dimension did not run | `failed` / `dimension-not-run` |'
  # the retired row wording, banned from every shard and the index — the
  # contains guards against an empty haystack passing the lacks vacuously
  local all; all="$(find "$LOOP_DIR" "$LOOP_DIR.md" -type f -name '*.md' -exec cat {} +)"
  contains "$all" '### Carry-driven dispatch (#2008)'
  lacks "$all" 'a reviewer dimension did not run'
  contains "$(cat "$LOOP_BRIEF")" 'it is neither run nor missing, so it never raises `dimension-not-run`'
  contains "$(cat "$LOOP_BRIEF")" 'which you append to `carry-lines-<R>.txt`'
}

@test "ARCHITECTURE.md's claude-plugin panel passage names six dimensions, manifest from the script" {
  contains "$(cat "$ARCH")" '(`claude-plugin-script-reviewer`), `manifest` (`check-manifests.zsh`) and'
  contains "$(cat "$ARCH")" '`manifest_bump` (`claude-plugin-manifest-check`) are its extension, while `tests`'
  contains "$(cat "$ARCH")" 'six claude-plugin dimensions in total (#2008)'
  lacks "$(tr '\n' ' ' < "$ARCH")" 'five claude-plugin dimensions in total'
}

# fm_field <agent file> <key> -> the frontmatter value of <key>, empty if absent
fm_field() {
  awk -v k="$2" '/^---$/ { d++; next } d == 1 && index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }' "$1"
}

@test "#3310 every development-claude-plugin agent declares the effort its class gets" {
  local expected="claude-plugin-version-sync:low claude-plugin-manifest-check:high
claude-plugin-structure-validator:low claude-plugin-skill-validator:low
claude-plugin-reference-checker:medium claude-plugin-script-quality:medium
claude-plugin-contract-integrity:high claude-plugin-test-reviewer:high
claude-plugin-script-reviewer:high claude-plugin-prose-logic:high claude-plugin-approver:high"
  local agents_dir="$REPO_ROOT/development-claude-plugin/agents" pair f n=0
  for pair in $expected; do
    f="$agents_dir/${pair%%:*}.md"
    [ "$(fm_field "$f" effort)" = "${pair##*:}" ] || {
      printf '%s declares effort %s, expected %s\n' "${pair%%:*}" "$(fm_field "$f" effort)" "${pair##*:}" >&2
      return 1
    }
    n=$((n + 1))
  done
  # every agent in the directory is covered, so a new agent cannot ship without one
  [ "$n" -eq "$(find "$agents_dir" -name '*.md' | wc -l | tr -d ' ')" ]
}

@test "#3310 the Step 1 table's Model and Effort cells equal each agent's frontmatter" {
  local rows reviewer model effort f n=0
  rows="$(awk -F'|' '
    /^## Step 1:/ { on = 1; next }
    /^## / && on { exit }
    on && /^\| claude-plugin-/ {
      for (i = 2; i <= 5; i++) { gsub(/^ +| +$/, "", $i) }
      printf "%s\t%s\t%s\n", $2, $4, $5
    }' "$SKILL")"
  # the header names the column, so the cells read are the Effort column's
  grep -qE '^\| Reviewer \| Kind \| Model \| Effort \| Dimension \| Runs \|$' "$SKILL"
  while IFS=$'\t' read -r reviewer model effort; do
    f="$REPO_ROOT/development-claude-plugin/agents/$reviewer.md"
    [ "$model" = "$(fm_field "$f" model)" ] || { echo "$reviewer: Model cell $model differs from frontmatter" >&2; return 1; }
    [ "$effort" = "$(fm_field "$f" effort)" ] || { echo "$reviewer: Effort cell $effort differs from frontmatter" >&2; return 1; }
    n=$((n + 1))
  done <<<"$rows"
  [ "$n" -eq 5 ]
}
