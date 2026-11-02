#!/usr/bin/env bats
#
# build-epic-telemetry-record.zsh (#1227): the resolve-issue EPIC-mode payload
# builder. It is pure — a state in, a payload (or the outcome) out — so every
# E1 classification, every outcome row and its first-match precedence, and every
# inconsistent state it refuses is driven here without a run. The emission
# around it (`story-telemetry.zsh emit --epic`) is tests/story-telemetry.bats.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"  # the user-level telemetry default stays out of the real ~/.claude (#1972)
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  B="$REPO_ROOT/development/skills/resolve-issue/scripts/build-epic-telemetry-record.zsh"
  ST="$BATS_TEST_TMPDIR/state.json"
}

# build from a state given inline; $1 = state JSON, rest = extra flags
build() {
  printf '%s' "$1" > "$ST"
  shift
  run --separate-stderr zsh "$B" --state "$ST" "$@"
}

# $1 = a jq expression applied to $2 (a state); prints the edited state
with() { jq -c "$1" <<<"$2"; }

# The epic #741 data sketch: a later run that resolved two children
# sequentially, verified the whole green and closed the epic.
CLOSED='{"outcome":"success","e1_classification":"native_children",
  "children":{"total":11,"completed_before":9,"resolved_this_run":2,"escalated":0,"parked":0,"queued":0},
  "split":{"parallel":0,"sequential":2},
  "child_run_ids":["resolve-issue-1791300000-1a2b","resolve-issue-1791303600-3c4d"],
  "e4":{"ran":true,"result":"green"},"e5_closed":true,
  "readiness_preflight":{"gated":2,"needs_refinement":0}}'

# The 2026-10-04 run on epic #741: E1b sent 6 of 10 open children back.
E1B_HALT='{"outcome":"parked","e1_classification":"native_children",
  "children":{"total":11,"completed_before":1,"resolved_this_run":0,"escalated":0,"parked":0,"queued":10},
  "readiness_preflight":{"gated":10,"needs_refinement":6}}'

# An epic with nothing filed at all: case 3.
UNDECOMPOSED='{"outcome":"parked","e1_classification":"halt_undecomposed",
  "children":{"total":0,"completed_before":0,"resolved_this_run":0,"escalated":0,"parked":0,"queued":0}}'

# refused: $1 = state, $2 = a needle the diagnostic must contain
refused() {
  build "$1"
  [ "$status" -eq 1 ] || { echo "want 1, got $status: $output"; return 1; }
  [ -z "$output" ]
  contains "$stderr" "$2"
}

# --- the payload --------------------------------------------------------------

@test "a closed epic: the documented payload, exactly its keys, outcome success" {
  build "$CLOSED"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mode' <<<"$output")" = "epic" ]
  [ "$(jq -r '.e1_classification' <<<"$output")" = "native_children" ]
  [ "$(jq -c '.children' <<<"$output")" = '{"total":11,"completed_before":9,"resolved_this_run":2,"escalated":0,"parked":0,"queued":0,"clean_stopped":0,"parked_behind_clean_stop":0}' ]
  [ "$(jq -c '.split' <<<"$output")" = '{"parallel":0,"sequential":2}' ]
  [ "$(jq -c '.child_run_ids' <<<"$output")" = '["resolve-issue-1791300000-1a2b","resolve-issue-1791303600-3c4d"]' ]
  [ "$(jq -c '.e4' <<<"$output")" = '{"ran":true,"result":"green"}' ]
  [ "$(jq -r '.e5_closed' <<<"$output")" = "true" ]
  [ "$(jq -c '.readiness_preflight' <<<"$output")" = '{"gated":2,"needs_refinement":0}' ]
  [ "$(jq -r '.failure_cause' <<<"$output")" = "null" ]
  # an envelope key (issue, pr, ts, wall_s, outcome) here would give a consumer
  # two places to read one fact
  [ "$(jq -c 'keys' <<<"$output")" = '["child_run_ids","children","e1_classification","e4","e5_closed","failure_cause","mode","readiness_preflight","split"]' ]
  build "$CLOSED" --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = "success" ]
}

@test "absent optional keys take their defaults: zero split, no runs, E4 not run, not closed" {
  build "$UNDECOMPOSED"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.split' <<<"$output")" = '{"parallel":0,"sequential":0}' ]
  [ "$(jq -c '.child_run_ids' <<<"$output")" = '[]' ]
  [ "$(jq -c '.e4' <<<"$output")" = '{"ran":false,"result":null}' ]
  [ "$(jq -r '.e5_closed' <<<"$output")" = "false" ]
  [ "$(jq -r '.readiness_preflight' <<<"$output")" = "null" ]
}

@test "child_run_ids are de-duplicated in start order" {
  build "$(with '.child_run_ids = ["resolve-issue-2-bbbb","resolve-issue-1-aaaa","resolve-issue-2-bbbb"]' "$CLOSED")"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.child_run_ids' <<<"$output")" = '["resolve-issue-2-bbbb","resolve-issue-1-aaaa"]' ]
}

# --- each of the twelve e1_classification values ------------------------------

# $1 = classification, $2 = state, $3 = the documented outcome
classifies() {
  build "$2"
  [ "$status" -eq 0 ] || { echo "status $status: $stderr"; return 1; }
  [ "$(jq -r '.e1_classification' <<<"$output")" = "$1" ]
  build "$2" --print-outcome
  [ "$output" = "$3" ]
}

# an E1 halt: nothing past E1 ran (acceptance criterion 4)
halt_state() {
  with ".e1_classification = \"$1\"" "$UNDECOMPOSED"
}

@test "native_children: the N == N row goes straight to E4/E5 with resolved_this_run 0" {
  classifies native_children "$(with '.children = {total:4,completed_before:4,resolved_this_run:0,escalated:0,parked:0,queued:0}
    | .split = {parallel:0,sequential:0} | .child_run_ids = [] | .readiness_preflight = null' "$CLOSED")" success
  [ "$(jq -r '.children.resolved_this_run' <<<"$(zsh "$B" --state "$ST")")" = "0" ]
}

@test "backfilled: a migrated epic that went on to resolve its children" {
  classifies backfilled "$(with '.e1_classification = "backfilled"' "$CLOSED")" success
}

@test "inline_slices: every slice confirmed merged, then E4/E5" {
  classifies inline_slices "$(with '.e1_classification = "inline_slices"
    | .children = {total:0,completed_before:0,resolved_this_run:0,escalated:0,parked:0,queued:0}
    | .split = {parallel:0,sequential:0} | .child_run_ids = [] | .readiness_preflight = null' "$CLOSED")" success
}

@test "halt_undecomposed: an epic with no children filed is parked" {
  classifies halt_undecomposed "$UNDECOMPOSED" parked
}

@test "halt_unrealized_slices is parked — the N == N row of a mixed body included" {
  classifies halt_unrealized_slices "$(halt_state halt_unrealized_slices)" parked
  classifies halt_unrealized_slices "$(with '.children = {total:3,completed_before:3,resolved_this_run:0,escalated:0,parked:0,queued:0}' \
    "$(halt_state halt_unrealized_slices)")" parked
}

@test "halt_near_miss is parked" {
  classifies halt_near_miss "$(halt_state halt_near_miss)" parked
}

@test "halt_backfill_vet is parked" {
  classifies halt_backfill_vet "$(halt_state halt_backfill_vet)" parked
}

@test "halt_backfill_error is parked, never failed" {
  classifies halt_backfill_error "$(halt_state halt_backfill_error)" parked
}

@test "halt_backfill_partial is parked, never failed" {
  classifies halt_backfill_partial "$(halt_state halt_backfill_partial)" parked
}

@test "halt_unclassified is parked" {
  classifies halt_unclassified "$(halt_state halt_unclassified)" parked
}

@test "every E1 halt carries the documented zeros (acceptance criterion 4)" {
  local v
  for v in halt_undecomposed halt_unrealized_slices halt_near_miss halt_backfill_vet \
           halt_backfill_error halt_backfill_partial halt_unclassified; do
    build "$(halt_state "$v")"
    [ "$status" -eq 0 ] || { echo "$v: $stderr"; return 1; }
    [ "$(jq -c '[.readiness_preflight, .e4, .e5_closed, .split, .child_run_ids]' <<<"$output")" = \
      '[null,{"ran":false,"result":null},false,{"parallel":0,"sequential":0},[]]' ]
  done
}

@test "an unknown e1_classification is refused, and so is a missing one" {
  refused "$(with '.e1_classification = "halt_backfill"' "$UNDECOMPOSED")" 'unknown e1_classification: "halt_backfill"'
  refused "$(with 'del(.e1_classification)' "$UNDECOMPOSED")" "state.e1_classification is required"
}

# The rows of the closed e1_classification table that follows the bold anchor
# paragraph in $1, one first-column value per line, sorted. Two flags, because a
# blank line separates the anchor paragraph from its table.
e1_table_values() {
  awk '/^\*\*`e1_classification`\*\*/ { a = 1 } a && /^[|] `/ { r = 1; print; next } r && /^$/ { exit }' "$1" | sed -E 's/^[|] `([^`]*)`.*/\1/' | LC_ALL=C sort
}

@test "#2140 both e1_classification tables list exactly the builder's enum, and the builder accepts every row" {
  # The reference is the enum the builder enforces. Its header comment also
  # lists the values, but a comment enforces nothing, so it is not compared.
  local ref ref_doc arch v
  ref="$(sed -n '/e1_classification | enum(\[/,/\]) | not)/p' "$B" | grep -oE '"[a-z_]+"' | tr -d '"' | LC_ALL=C sort)"
  ref_doc="$(e1_table_values "$REPO_ROOT/development/skills/resolve-issue/reference/epic-telemetry.md")"
  arch="$(e1_table_values "$REPO_ROOT/ARCHITECTURE.md")"
  [ -n "$ref_doc" ] && [ "$(grep -c '' <<<"$ref_doc")" -eq 12 ]
  [ -n "$arch" ] && [ "$(grep -c '' <<<"$arch")" -eq 12 ]
  [ "$ref_doc" = "$ref" ]
  [ "$arch" = "$ref" ]
  [ "$(tr '\n' ' ' <<<"$ref")" = "backfilled halt_backfill_error halt_backfill_partial halt_backfill_vet halt_depth_exceeded halt_near_miss halt_tree_read_error halt_unclassified halt_undecomposed halt_unrealized_slices inline_slices native_children " ]
  for v in $ref_doc; do
    build "$(halt_state "$v")"
    [ "$status" -eq 0 ] || { printf 'the builder refused %s: %s\n' "$v" "$stderr" >&2; return 1; }
  done
}

# --- each outcome row ---------------------------------------------------------

@test "row 1 failed: an E4 regression, E5 not closed" {
  local s
  s="$(with '.outcome = "failed" | .e4 = {ran:true,result:"regression"} | .e5_closed = false
    | .failure_cause = "e4_regression" | .children.completed_before = 9' "$CLOSED")"
  build "$s"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.e4.result, .e5_closed, .failure_cause]' <<<"$output")" = '["regression",false,"e4_regression"]' ]
  build "$s" --print-outcome
  [ "$output" = "failed" ]
}

@test "row 1 failed: a run that broke after E1b (E4 reached no verdict, E5 close failed, other error)" {
  local c s
  s="$(with '.outcome = "failed" | .e4 = {ran:false,result:null} | .e5_closed = false' "$CLOSED")"
  for c in e4_error e5_error error; do
    build "$(jq -c --arg c "$c" '.failure_cause = $c' <<<"$s")" --print-outcome
    [ "$status" -eq 0 ] || { echo "$c: $stderr"; return 1; }
    [ "$output" = "failed" ]
  done
}

@test "row 2 escalated: an escalated child" {
  build "$(with '.outcome = "escalated" | .children.resolved_this_run = 1 | .children.escalated = 1
    | .e4 = {ran:false,result:null} | .e5_closed = false' "$CLOSED")" --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = "escalated" ]
}

@test "row 3 parked: an E1b halt (acceptance criterion 5)" {
  build "$E1B_HALT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.readiness_preflight.needs_refinement' <<<"$output")" = "6" ]
  [ "$(jq -r '.children.resolved_this_run' <<<"$output")" = "0" ]
  [ "$(jq -r '.children.queued' <<<"$output")" = "10" ]
  [ "$(jq -r '.e4.ran' <<<"$output")" = "false" ]
  build "$E1B_HALT" --print-outcome
  [ "$output" = "parked" ]
}

@test "row 3 parked: a child PR open awaiting a human merge is queued" {
  build "$(with '.outcome = "parked" | .children.resolved_this_run = 1 | .children.queued = 1
    | .split = {parallel:0,sequential:2} | .e4 = {ran:false,result:null} | .e5_closed = false' "$CLOSED")" --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = "parked" ]
}

@test "row 3 parked: every child resolved but E5 not reached is still parked" {
  build "$(with '.outcome = "parked" | .e5_closed = false' "$CLOSED")" --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = "parked" ]
}

# --- first-match precedence: the three overlap cases (acceptance criterion 9) --

@test "overlap: an escalation plus an E4 regression is failed" {
  local s
  s="$(with '.children.resolved_this_run = 1 | .children.escalated = 1
    | .e4 = {ran:true,result:"regression"} | .e5_closed = false' "$CLOSED")"
  build "$(with '.outcome = "failed"' "$s")" --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = "failed" ]
  # the lower row is refused, not silently re-ranked
  refused "$(with '.outcome = "escalated"' "$s")" "outcome escalated is not the first matching row (failed)"
}

@test "overlap: escalated plus parked children is escalated" {
  local s
  s="$(with '.children.resolved_this_run = 0 | .children.escalated = 1 | .children.parked = 1
    | .e4 = {ran:false,result:null} | .e5_closed = false' "$CLOSED")"
  build "$(with '.outcome = "escalated"' "$s")" --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = "escalated" ]
  refused "$(with '.outcome = "parked"' "$s")" "outcome parked is not the first matching row (escalated)"
}

@test "overlap: parked children with e5_closed false is parked" {
  local s
  s="$(with '.children.resolved_this_run = 1 | .children.parked = 1
    | .e4 = {ran:false,result:null} | .e5_closed = false' "$CLOSED")"
  build "$(with '.outcome = "parked"' "$s")" --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = "parked" ]
  refused "$(with '.outcome = "success"' "$s")" "outcome success is not the first matching row (parked)"
}

# --- builder consistency refusal: one case each (acceptance criterion 10) ------

@test "refused: success without e5_closed true" {
  refused "$(with '.e5_closed = false' "$CLOSED")" "success needs e5_closed: true"
}

@test "refused: e5_closed with an E4 result other than green" {
  refused "$(with '.e4 = {ran:false,result:null}' "$CLOSED")" "e5_closed needs a green E4"
}

@test "refused: e5_closed with escalated, parked or queued children" {
  refused "$(with '.children.resolved_this_run = 1 | .children.queued = 1' "$CLOSED")" \
    "e5_closed with escalated, parked or queued children"
}

@test "refused: a halt with a resolved child" {
  refused "$(with '.children = {total:1,completed_before:0,resolved_this_run:1,escalated:0,parked:0,queued:0}' "$UNDECOMPOSED")" \
    "a halt_undecomposed halt resolves no child"
}

@test "refused: a halt that ran E4" {
  refused "$(with '.e4 = {ran:true,result:"green"}' "$UNDECOMPOSED")" "a halt_undecomposed halt never runs E4"
}

@test "refused: a halt with a non-zero split" {
  refused "$(with '.split = {parallel:1,sequential:0} | .child_run_ids = ["resolve-issue-1-aaaa"]' "$UNDECOMPOSED")" \
    "halt opens no child PR, so split must be zeros"
}

@test "refused: a halt with a child run" {
  refused "$(with '.child_run_ids = ["resolve-issue-1-aaaa"]' "$UNDECOMPOSED")" "a halt_undecomposed halt starts no child run"
}

@test "refused: a halt with a readiness_preflight" {
  refused "$(with '.readiness_preflight = {gated:0,needs_refinement:0}' "$UNDECOMPOSED")" \
    "halt never reaches E1b, so readiness_preflight must be null"
}

@test "refused: an E1b halt with a resolved child" {
  refused "$(with '.children.resolved_this_run = 1 | .children.queued = 9' "$E1B_HALT")" \
    "an E1b halt (needs_refinement > 0) builds nothing"
}

@test "refused: an E1b halt that ran E4" {
  refused "$(with '.e4 = {ran:true,result:"green"}' "$E1B_HALT")" "an E1b halt (needs_refinement > 0) builds nothing"
}

@test "refused: e4.ran false with a non-null result" {
  refused "$(with '.e4 = {ran:false,result:"green"}' "$E1B_HALT")" "e4.ran is false, so e4.result must be null"
}

@test "refused: a failure attributed to an E4 regression without e4.result regression" {
  refused "$(with '.outcome = "failed" | .e5_closed = false | .failure_cause = "e4_regression"' "$CLOSED")" \
    "a failure attributed to an E4 regression needs e4.result: regression"
}

@test "refused: children that do not sum to total" {
  refused "$(with '.children.total = 12' "$CLOSED")" "children do not sum to total"
}

@test "refused: a split larger than the child runs started" {
  refused "$(with '.split = {parallel:1,sequential:2}' "$CLOSED")" \
    "split.parallel + split.sequential (3) exceeds the child runs started (2)"
}

@test "refused: a halt filed as failed — an E1 halt is always parked" {
  refused "$(with '.outcome = "failed" | .failure_cause = "error"' "$(halt_state halt_backfill_error)")" \
    "halt is parked, never failed"
}

@test "refused: E4 ran with no verdict, or an errored E4 or E5 that claims to have finished" {
  refused "$(with '.e4 = {ran:true,result:null} | .e5_closed = false | .outcome = "parked"' "$CLOSED")" \
    "e4.ran is true, so e4.result must be green or regression"
  refused "$(with '.outcome = "failed" | .e5_closed = false | .failure_cause = "e4_error"' "$CLOSED")" \
    "an E4 that could not reach a verdict has e4.ran: false"
  refused "$(with '.outcome = "failed" | .failure_cause = "e5_error"' "$CLOSED")" \
    "a failed E5 close has e5_closed: false"
}

@test "refused: more children sent back than were gated" {
  refused "$(with '.readiness_preflight = {gated:5,needs_refinement:6}' "$E1B_HALT")" "needs_refinement exceeds gated"
}

@test "every violation is reported at once" {
  build "$(with '.e5_closed = false | .children.total = 12' "$CLOSED")"
  [ "$status" -eq 1 ]
  contains "$stderr" "success needs e5_closed: true"
  contains "$stderr" "children do not sum to total"
}

# --- shape --------------------------------------------------------------------

@test "refused: a wrong-typed field — a false where null is meant is not read as absent" {
  refused "$(with '.readiness_preflight = false' "$UNDECOMPOSED")" "readiness_preflight must be null or an object"
  refused "$(with '.children.queued = -1' "$UNDECOMPOSED")" "children must be an object of non-negative integers"
  refused "$(with '.children.queued = 1.5' "$UNDECOMPOSED")" "children must be an object of non-negative integers"
  refused "$(with '.split = {parallel:0}' "$UNDECOMPOSED")" "split must be an object of non-negative integers"
  refused "$(with '.child_run_ids = [""]' "$UNDECOMPOSED")" "child_run_ids must be an array of non-empty strings"
  refused "$(with '.e4 = {ran:"no",result:null}' "$UNDECOMPOSED")" "e4 must be {ran: bool, result: green | regression | null}"
  refused "$(with '.e4 = {ran:true,result:"red"}' "$CLOSED")" "e4 must be {ran: bool, result: green | regression | null}"
  refused "$(with '.e5_closed = "yes"' "$UNDECOMPOSED")" "e5_closed must be a boolean"
  refused "$(with '.failure_cause = "e3_error"' "$UNDECOMPOSED")" "failure_cause must be"
}

@test "refused: an unknown or missing outcome" {
  refused "$(with '.outcome = "pr-opened"' "$UNDECOMPOSED")" 'unknown outcome: "pr-opened"'
  refused "$(with 'del(.outcome)' "$UNDECOMPOSED")" "state.outcome is required"
}

@test "refused: not exactly one JSON object" {
  refused '[]' "state must be a single JSON object"
  refused "$UNDECOMPOSED $UNDECOMPOSED" "state must be a single JSON object"
  refused 'not json' "state must be a single JSON object"
}

@test "the state can come on stdin" {
  run --separate-stderr zsh -c "zsh '$B' --print-outcome <<<'$(jq -c . <<<"$UNDECOMPOSED")'"
  [ "$status" -eq 0 ]
  [ "$output" = "parked" ]
}

@test "usage errors exit 2" {
  run --separate-stderr zsh "$B" --state
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$B" --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$B" extra
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$B" --state "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$B" --state "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
}

@test "#2139 both children rows state the ordered first-match rule and the qualified queued clause" {
  local f doc
  for f in development/skills/resolve-issue/reference/epic-telemetry.md ARCHITECTURE.md; do
    doc="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/$f")"
    contains "$doc" 'Every child **open** at that read goes in the **first** of these buckets whose test it meets: `resolved_this_run` (closed as completed during this run), `escalated` (ended on a typed escalation, or in the `skip` of E3'"'"'s clean-stop triage — a child skipped for a kept marker from an earlier walk counts here too), `parked` (parked by E3'"'"'s triage: a §0a dependency rejection, a precheck tooling failure — exit 1, or an exit 2 that recurs after the fixed re-run or whose malformation cannot be seen — a §2 size pre-flight stop or error, and every child that depends on an escalated or parked child, or, under `override=on`, on a child stopped short of `MERGED` at §6'"'"'s human-only stop), then `queued` (every other open child: a PR awaiting a human merge, a child whose own story run ended `failed` for a cause E3'"'"'s triage does not park — an abandoned red gate, a gate or loop error, or a round protocol that stopped before any loop invocation — and every child when E1b halts)'
    lacks "$doc" 'a child whose own story run ended `failed`,'
  done
}

# --- the clean-stop sub-counts (#2585) ----------------------------------------

# an unattended walk where one child clean-stopped and two dependants parked
# behind it, one other child escalated otherwise
CLEAN_STOP='{"outcome":"escalated","e1_classification":"native_children",
  "children":{"total":6,"completed_before":1,"resolved_this_run":1,"escalated":2,"parked":2,"queued":0,
              "clean_stopped":1,"parked_behind_clean_stop":2},
  "split":{"parallel":0,"sequential":1},
  "child_run_ids":["resolve-issue-1-aaaa","resolve-issue-2-bbbb","resolve-issue-3-cccc"],
  "readiness_preflight":{"gated":5,"needs_refinement":0}}'

@test "#2585 AC3 the sub-counts ride in children, outside the bucket sum" {
  build "$CLEAN_STOP"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.children | {clean_stopped, parked_behind_clean_stop}' <<<"$output")" = '{"clean_stopped":1,"parked_behind_clean_stop":2}' ]
  # the five buckets alone sum to total: 1 + 1 + 2 + 2 + 0 = 6
  [ "$(jq '.children | .completed_before + .resolved_this_run + .escalated + .parked + .queued' <<<"$output")" -eq 6 ]
  build "$CLEAN_STOP" --print-outcome
  [ "$output" = "escalated" ]
}

@test "#2585 AC3 absent sub-counts default to 0" {
  build "$E1B_HALT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.children | {clean_stopped, parked_behind_clean_stop}' <<<"$output")" = '{"clean_stopped":0,"parked_behind_clean_stop":0}' ]
}

@test "#2585 AC3 a sub-count larger than its bucket is refused" {
  refused "$(with '.children.clean_stopped = 3' "$CLEAN_STOP")" \
    "children.clean_stopped (3) exceeds children.escalated (2): a clean stop is an escalation"
  refused "$(with '.children.parked_behind_clean_stop = 3' "$CLEAN_STOP")" \
    "children.parked_behind_clean_stop (3) exceeds children.parked (2)"
  # equal is fine
  build "$(with '.children.clean_stopped = 2' "$CLEAN_STOP")"
  [ "$status" -eq 0 ]
}

@test "#2585 AC3 the sub-counts are non-negative integers like every count" {
  local v
  for v in -1 1.5 '"1"'; do
    refused "$(with ".children.clean_stopped = $v" "$CLEAN_STOP")" \
      "children must be an object of non-negative integers: total, completed_before, resolved_this_run, escalated, parked, queued, clean_stopped, parked_behind_clean_stop"
    refused "$(with ".children.parked_behind_clean_stop = $v" "$CLEAN_STOP")" \
      "children must be an object of non-negative integers"
  done
}

# --- #2857: the sub-issue tree -----------------------------------------------

@test "#2857 the optional tree member rides in the payload when given" {
  build "$(with '.tree = {depth:3, inner_nodes:2, inner_closed_this_run:2}' "$CLOSED")"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.tree' <<<"$output")" = '{"depth":3,"inner_nodes":2,"inner_closed_this_run":2}' ]
}

@test "#2857 an absent or null tree leaves the payload without one" {
  build "$CLOSED"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("tree")' <<<"$output")" = false ]
  build "$(with '.tree = null' "$CLOSED")"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("tree")' <<<"$output")" = false ]
}

@test "#2857 tree is type-checked: non-negative integers, all three keys" {
  local v
  for v in '{depth:-1,inner_nodes:0,inner_closed_this_run:0}' '{depth:1.5,inner_nodes:0,inner_closed_this_run:0}' \
           '{depth:1,inner_nodes:"2",inner_closed_this_run:0}' '{depth:1,inner_nodes:2}' '[1,2,3]' '"deep"'; do
    refused "$(with ".tree = $v" "$CLOSED")" \
      "tree must be null or an object of non-negative integers: depth, inner_nodes, inner_closed_this_run"
  done
}

@test "#2857 an unknown tree key is refused" {
  refused "$(with '.tree = {depth:2, inner_nodes:1, inner_closed_this_run:0, leaves:4}' "$CLOSED")" \
    "unknown tree key(s): leaves"
}

@test "#2857 more inner nodes closed than exist is refused; equal is fine" {
  refused "$(with '.tree = {depth:2, inner_nodes:1, inner_closed_this_run:2}' "$CLOSED")" \
    "tree.inner_closed_this_run (2) exceeds tree.inner_nodes (1)"
  build "$(with '.tree = {depth:2, inner_nodes:1, inner_closed_this_run:1}' "$CLOSED")"
  [ "$status" -eq 0 ]
}

@test "#2857 halt_depth_exceeded and halt_tree_read_error are parked E1 halts" {
  classifies halt_depth_exceeded "$(halt_state halt_depth_exceeded)" parked
  classifies halt_tree_read_error "$(halt_state halt_tree_read_error)" parked
}

@test "#2857 the new halt values take the halt_* refusals" {
  local h
  for h in halt_depth_exceeded halt_tree_read_error; do
    refused "$(with '.readiness_preflight = {gated:1,needs_refinement:0}' "$(halt_state $h)")" \
      "a $h halt never reaches E1b, so readiness_preflight must be null"
    refused "$(with '.child_run_ids = ["resolve-issue-1-aaaa"]' "$(halt_state $h)")" \
      "a $h halt starts no child run"
  done
}

# --- #2955: the readiness-verdict cache at E1b ---------------------------------

@test "#2955 AC6 the optional readiness_cache rides in the payload when given" {
  build "$(with '.readiness_cache = {hits:1, misses:1, miss_reasons:{key_changed:1}}' "$CLOSED")"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.readiness_cache' <<<"$output")" = '{"hits":1,"misses":1,"miss_reasons":{"key_changed":1}}' ]
  build "$(with '.readiness_cache = {hits:2, misses:0, miss_reasons:{}}' "$CLOSED")"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.readiness_cache' <<<"$output")" = '{"hits":2,"misses":0,"miss_reasons":{}}' ]
}

@test "#2955 an absent or null readiness_cache leaves the payload without one" {
  build "$CLOSED"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("readiness_cache")' <<<"$output")" = false ]
  build "$(with '.readiness_cache = null' "$CLOSED")"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("readiness_cache")' <<<"$output")" = false ]
}

@test "#2955 readiness_cache is type-checked" {
  local v
  for v in '{hits:-1,misses:0,miss_reasons:{}}' '{hits:1,misses:0}' '{hits:0,misses:1,miss_reasons:[1]}' \
           '{hits:0,misses:1,miss_reasons:{no_stamp:0}}' '{hits:0,misses:1,miss_reasons:{no_stamp:"1"}}' '"cached"'; do
    refused "$(with ".readiness_cache = $v" "$CLOSED")" \
      "readiness_cache must be null or {hits, misses, miss_reasons} of non-negative integers, miss_reasons a reason-to-positive-count object"
  done
}

@test "#2955 readiness_cache contradicting E1b is refused" {
  refused "$(with '.readiness_cache = {hits:1, misses:0, miss_reasons:{}}' "$(halt_state halt_undecomposed)")" \
    "readiness_cache needs readiness_preflight: both come from E1b"
  refused "$(with '.readiness_cache = {hits:2, misses:1, miss_reasons:{no_stamp:1}}' "$CLOSED")" \
    "readiness_cache.hits + misses exceeds readiness_preflight.gated"
  refused "$(with '.readiness_cache = {hits:0, misses:2, miss_reasons:{no_stamp:1}}' "$CLOSED")" \
    "readiness_cache.miss_reasons do not sum to misses"
}

@test "#2955 a cached NEEDS_REFINEMENT counts in gated: an all-cached E1b halt builds" {
  build "$(with '.readiness_cache = {hits:10, misses:0, miss_reasons:{}}' "$E1B_HALT")"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.readiness_preflight' <<<"$output")" = '{"gated":10,"needs_refinement":6}' ]
}
