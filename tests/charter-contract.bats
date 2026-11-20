#!/usr/bin/env bats
#
# The product charter contract (#3205, task 4 of #3195): pins the load-bearing
# sentences of ARCHITECTURE.md's *Product charter contract (`charter/v1`)*,
# scoped to that section so a clause stated elsewhere in the document cannot
# satisfy a needle, and checks that the section and the validator name the same
# rules and the same prose sections.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  S="$REPO_ROOT/product/scripts/validate-charter.zsh"
  # from the section's own heading to the next `## ` heading; `### ` stays inside
  RAW="$(awk '/^## Product charter contract \(`charter\/v1`\)$/ { f = 1; print; next }
              f && /^## / { exit } f' "$ARCH")"
  SECTION="$(printf '%s' "$RAW" | tr -s '[:space:]' ' ')"
}

@test "the section exists and comes right after the persona registry contract" {
  [ -n "$SECTION" ]
  local next
  # a fenced example inside the persona contract holds `## ` lines: skip fences
  next="$(awk '/^```/ { fence = !fence; next } fence { next }
               /^## Persona registry contract/ { f = 1; next } f && /^## / { print; exit }' "$ARCH")"
  [ "$next" = '## Product charter contract (`charter/v1`)' ]
}

@test "the contract fixes the prose section order and the layout" {
  contains "$SECTION" "The prose sections come in this order: Summary, Purpose and background, Who it serves, Values, What we build, What we deliberately don't build, Direction changes."
  contains "$SECTION" 'sits between `<!-- charter:prose:start -->` and `<!-- charter:prose:end -->`. It is followed by a collapsed `<details>` block holding one fenced `json` object'
}

@test "the validator checks the same sections in the same order" {
  local order
  order="$(printf '%s' "$SECTION" | sed -n 's/.*The prose sections come in this order: \([^.]*\)\..*/\1/p')"
  [ -n "$order" ]
  run zsh -c "source <(sed -n '/^local -a expected_sections=(/,/^)/p' '$S'); print -r -- \"\${(j:, :)expected_sections}\""
  [ "$status" -eq 0 ]
  [ "$output" = "$order" ]
}

@test "an entry is never deleted, and an id is never reused or renumbered" {
  contains "$SECTION" '**An entry is never deleted.** A value, scope item or non-goal that no longer holds becomes `retired`, and some direction change names it in `affects`.'
  contains "$SECTION" '**An id is unique in the charter, and never reused or renumbered.**'
}

@test "the contract states the validator's single-file limit" {
  contains "$SECTION" '**The validator checks a single file, so it cannot see an active entry reworded in place, an entry deleted, or an id renumbered or reused.**'
}

@test "provenance is the persona contract's mechanism, given as a link and not restated" {
  contains "$SECTION" "Provenance is the persona contract's mechanism, unchanged"
  contains "$SECTION" '[Provenance and staleness detection](#provenance-and-staleness-detection)'
  # the link's target is the persona contract's own heading
  run grep -c '^### Provenance and staleness detection$' "$ARCH"
  [ "$output" = "1" ]
  # the normalisation recipe stays stated once, in the persona contract
  lacks "$SECTION" 'strip trailing whitespace'
  lacks "$SECTION" 'line endings to'
}

@test "the contract's rule table names exactly the validator's rules" {
  local doc script
  doc="$(printf '%s\n' "$RAW" | sed -n '/^| Rule | A violation |$/,/^$/p' | sed -n 's/^| `\([a-z-]*\)` | .*/\1/p' | sort)"
  script="$(sed -n '/^# where <rule> is one of/,/^#$/p' "$S" | tr -d '#,.' | tr -s '[:space:]' '\n' \
    | grep -E '^[a-z]+(-[a-z]+)*$' | grep -vx -e where -e rule -e is -e one -e of | sort)"
  [ "$(printf '%s\n' "$doc" | wc -l | tr -d ' ')" -eq 12 ]
  [ "$doc" = "$script" ]
}

@test "the example is a note-taking product with three values, two non-goals and one change retiring a non-goal" {
  local block="$BATS_TEST_TMPDIR/example.json"
  printf '%s\n' "$RAW" | awk '/^```json$/ { f = 1; next } f && /^```$/ { exit } f' > "$block"
  run jq -r '[.schema, (.values | length), (.non_goals | length), (.direction_changes | length)] | @tsv' "$block"
  [ "$output" = $'charter/v1\t3\t2\t1' ]
  run jq -r '[.non_goals[] | select(.status == "retired") | .id] - .direction_changes[0].affects | length' "$block"
  [ "$output" = "0" ]
  run jq -r '[.non_goals[] | select(.status == "retired")] | length' "$block"
  [ "$output" = "1" ]
}
