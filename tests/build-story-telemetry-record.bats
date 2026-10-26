#!/usr/bin/env bats
#
# build-story-telemetry-record.zsh (#1226): the resolve-issue STORY-mode payload
# builder. It is pure — a state in, a payload (or a narrowed outcome) out — so
# every outcome branch, every contradiction it refuses, and every malformed
# input is driven here without a run. The emission around it is
# tests/story-telemetry.bats.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  B="$REPO_ROOT/development/skills/resolve-issue/scripts/build-story-telemetry-record.zsh"
  ST="$BATS_TEST_TMPDIR/state.json"
}

# build from a state given inline; $1 = state JSON, rest = extra flags
build() {
  printf '%s' "$1" > "$ST"
  shift
  run --separate-stderr zsh "$B" --state "$ST" "$@"
}

SUCCESS='{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY","risk":"elevated","pr":413,"story_spec_present":true,"review_loop_run_ids":["review-loop-1752403000-8f3a"],"fallbacks_fired":["user_docs"]}'
GATE_PARKED='{"outcome":"gate-parked","dependency_precheck":"PROCEED","gate_verdict":"NEEDS_REFINEMENT","risk":"normal"}'
PRECHECK_PARKED='{"outcome":"precheck-parked","dependency_precheck":"REJECT_BLOCKED"}'
ESCALATED='{"outcome":"escalated","dependency_precheck":"PROCEED","gate_verdict":"READY","risk":"normal","escalation_status":"ESCALATE_NO_CONVERGENCE","review_loop_run_ids":["review-loop-1752403000-8f3a"]}'
FAILED='{"outcome":"failed","dependency_precheck":"PROCEED","gate_verdict":"READY","risk":"low"}'

# --- the five outcome branches ----------------------------------------------

@test "pr-opened: the documented story payload, narrowed to success" {
  build "$SUCCESS"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mode' <<<"$output")" = "story" ]
  [ "$(jq -r '.dependency_precheck' <<<"$output")" = "PROCEED" ]
  [ "$(jq -r '.gate_verdict' <<<"$output")" = "READY" ]
  [ "$(jq -r '.risk' <<<"$output")" = "elevated" ]
  [ "$(jq -r '.story_spec_present' <<<"$output")" = "true" ]
  [ "$(jq -c '.review_loop_run_ids' <<<"$output")" = '["review-loop-1752403000-8f3a"]' ]
  [ "$(jq -r '.escalation_status' <<<"$output")" = "null" ]
  [ "$(jq -c '.fallbacks_fired' <<<"$output")" = '["user_docs"]' ]
  # exactly the documented keys — an envelope key (pr, issue, ts, wall_s) here
  # would give a consumer two places to read one fact
  [ "$(jq -c 'keys' <<<"$output")" = '["clean_stop","convergence_failures","dependency_precheck","escalation_status","fallbacks_fired","gate_verdict","mode","resumed_from","review_loop_run_ids","risk","session_mode","session_mode_source","story_spec_present"]' ]
  build "$SUCCESS" --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = "success" ]
}

@test "gate-parked: gate_verdict NEEDS_REFINEMENT, risk dropped, narrowed to parked" {
  build "$GATE_PARKED"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.gate_verdict' <<<"$output")" = "NEEDS_REFINEMENT" ]
  # the gate carries a risk only on READY
  [ "$(jq -r '.risk' <<<"$output")" = "null" ]
  build "$GATE_PARKED" --print-outcome
  [ "$output" = "parked" ]
}

@test "precheck-parked: the rejection type kept, gate never reached, narrowed to parked" {
  build "$PRECHECK_PARKED"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.dependency_precheck' <<<"$output")" = "REJECT_BLOCKED" ]
  [ "$(jq -r '.gate_verdict' <<<"$output")" = "null" ]
  [ "$(jq -c '.review_loop_run_ids' <<<"$output")" = "[]" ]
  build '{"outcome":"precheck-parked","dependency_precheck":"REJECT_CYCLE"}' --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = "parked" ]
}

@test "escalated: the typed loop status kept, narrowed to escalated" {
  build "$ESCALATED"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.escalation_status' <<<"$output")" = "ESCALATE_NO_CONVERGENCE" ]
  build "$ESCALATED" --print-outcome
  [ "$output" = "escalated" ]
  # every typed escalation is accepted, BUDGET_EXHAUSTED included
  local es
  for es in ESCALATE_CONFLICT ESCALATE_AMBIGUOUS BUDGET_EXHAUSTED; do
    build "$(jq -c --arg es "$es" '.escalation_status = $es' <<<"$ESCALATED")"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.escalation_status' <<<"$output")" = "$es" ]
  done
}

@test "failed: after a READY gate, or on a precheck that errored (null), narrowed to failed" {
  build "$FAILED"
  [ "$status" -eq 0 ]
  build "$FAILED" --print-outcome
  [ "$output" = "failed" ]
  # a precheck that exited 1 made no decision: null, and only `failed` fits it
  build '{"outcome":"failed","dependency_precheck":null}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.dependency_precheck' <<<"$output")" = "null" ]
}

@test "absent optional keys read as null / false / []" {
  build '{"outcome":"precheck-parked","dependency_precheck":"REJECT_CYCLE"}'
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.gate_verdict, .risk, .story_spec_present, .review_loop_run_ids, .escalation_status, .fallbacks_fired, .session_mode, .session_mode_source]' <<<"$output")" \
    = '[null,null,false,[],null,[],null,null]' ]
}

# --- the session mode (#2575) -------------------------------------------------

@test "#2575 each session mode and source is carried into the payload unchanged" {
  local m src
  for m in attended unattended; do
    for src in env inferred; do
      build "$(jq -c --arg m "$m" --arg s "$src" '.session_mode = $m | .session_mode_source = $s' <<<"$SUCCESS")"
      [ "$status" -eq 0 ] || { echo "$m/$src: $stderr"; return 1; }
      [ "$(jq -c '[.session_mode, .session_mode_source]' <<<"$output")" = "[\"$m\",\"$src\"]" ]
    done
  done
}

@test "#2575 the explicit null pair is accepted and emitted as null" {
  build "$(jq -c '.session_mode = null | .session_mode_source = null' <<<"$SUCCESS")"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.session_mode, .session_mode_source]' <<<"$output")" = '[null,null]' ]
}

@test "review_loop_run_ids are de-duplicated in first-seen order; fallbacks are a set" {
  build '{"outcome":"failed","dependency_precheck":"PROCEED","review_loop_run_ids":["review-loop-2-bbbb","review-loop-1-aaaa","review-loop-2-bbbb"],"fallbacks_fired":["user_docs","c4_currency","user_docs"]}'
  [ "$status" -eq 0 ]
  [ "$(jq -c '.review_loop_run_ids' <<<"$output")" = '["review-loop-2-bbbb","review-loop-1-aaaa"]' ]
  [ "$(jq -c '.fallbacks_fired' <<<"$output")" = '["c4_currency","user_docs"]' ]
}

@test "the state can arrive on stdin (--state - or no --state)" {
  run --separate-stderr zsh -c 'printf "%s" "$1" | zsh "$2" --state - --print-outcome' _ "$SUCCESS" "$B"
  [ "$status" -eq 0 ]
  [ "$output" = "success" ]
  run --separate-stderr zsh -c 'printf "%s" "$1" | zsh "$2" --print-outcome' _ "$GATE_PARKED" "$B"
  [ "$status" -eq 0 ]
  [ "$output" = "parked" ]
}

# --- contradictions: a record filed under the wrong outcome is refused -------

# $1 = state, $2 = a fragment of the expected diagnostic
refuses() {
  build "$1"
  [ "$status" -eq 1 ] || { echo "want exit 1, got $status: $stderr"; return 1; }
  [ -z "$output" ] || { echo "stdout must be empty on refusal, got: $output"; return 1; }
  contains "$stderr" "$2"
  # --print-outcome is refused on the same grounds: the outcome of a
  # contradictory state is exactly what cannot be trusted
  build "$1" --print-outcome
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "pr-opened with no pr is refused" {
  refuses '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY"}' "pr-opened needs a pr"
}

@test "a pr on any other outcome is refused" {
  refuses '{"outcome":"failed","dependency_precheck":"PROCEED","gate_verdict":"READY","pr":9}' "pr is set, so the outcome must be pr-opened"
}

@test "a NEEDS_REFINEMENT gate filed as anything but gate-parked is refused" {
  refuses '{"outcome":"failed","dependency_precheck":"PROCEED","gate_verdict":"NEEDS_REFINEMENT"}' "a NEEDS_REFINEMENT gate can only end gate-parked"
}

@test "gate-parked without a NEEDS_REFINEMENT verdict is refused" {
  refuses '{"outcome":"gate-parked","dependency_precheck":"PROCEED","gate_verdict":"READY"}' "gate-parked needs"
}

@test "a REJECT_* precheck filed as anything but precheck-parked is refused" {
  refuses '{"outcome":"failed","dependency_precheck":"REJECT_BLOCKED"}' "a REJECT_BLOCKED precheck can only end precheck-parked"
}

@test "precheck-parked with a PROCEED precheck is refused" {
  refuses '{"outcome":"precheck-parked","dependency_precheck":"PROCEED"}' "precheck-parked needs a REJECT_* dependency_precheck"
}

@test "precheck-parked with a gate verdict is refused — the gate is never reached" {
  refuses '{"outcome":"precheck-parked","dependency_precheck":"REJECT_CYCLE","gate_verdict":"READY"}' "gate_verdict must be null"
}

@test "escalated with no typed status is refused" {
  refuses '{"outcome":"escalated","dependency_precheck":"PROCEED","gate_verdict":"READY"}' "escalated needs a typed escalation_status"
}

@test "an escalation_status on a non-escalated outcome is refused" {
  refuses '{"outcome":"failed","dependency_precheck":"PROCEED","gate_verdict":"READY","escalation_status":"BUDGET_EXHAUSTED"}' "the outcome must be escalated"
}

@test "#2575 a session mode outside its enum is refused" {
  refuses "$(jq -c '.session_mode = "present" | .session_mode_source = "env"' <<<"$SUCCESS")" "session_mode must be attended | unattended | null"
  refuses "$(jq -c '.session_mode = false | .session_mode_source = "env"' <<<"$SUCCESS")" "session_mode must be attended | unattended | null"
}

@test "#2575 a session mode source outside its enum is refused" {
  refuses "$(jq -c '.session_mode = "attended" | .session_mode_source = "settings"' <<<"$SUCCESS")" "session_mode_source must be env | inferred | null"
}

@test "#2575 a half-null session pair is refused, either way round" {
  refuses "$(jq -c '.session_mode = "unattended"' <<<"$SUCCESS")" "session_mode and session_mode_source are a pair"
  refuses "$(jq -c '.session_mode_source = "inferred"' <<<"$SUCCESS")" "session_mode and session_mode_source are a pair"
}

@test "every contradiction is reported, not just the first" {
  build '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"NEEDS_REFINEMENT"}'
  [ "$status" -eq 1 ]
  contains "$stderr" "a NEEDS_REFINEMENT gate can only end gate-parked"
  contains "$stderr" "pr-opened needs a pr"
  # one line per problem, each prefixed
  [ "$(grep -c '^build-story-telemetry-record: ' <<<"$stderr")" -eq 2 ]
}

# --- malformed input ----------------------------------------------------------

@test "invalid JSON: exit 1, empty stdout" {
  build 'not json'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "state must be a single JSON object"
}

@test "a concatenated multi-document state is refused" {
  build "$SUCCESS$SUCCESS"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "a non-object state is refused" {
  build '[1,2]'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "an unknown outcome: exit 1, empty stdout" {
  build '{"outcome":"shipped","dependency_precheck":"PROCEED"}'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" 'unknown outcome: "shipped"'
  build '{"outcome":"shipped","dependency_precheck":"PROCEED"}' --print-outcome
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "a missing outcome, and a missing dependency_precheck key, are refused" {
  build '{"dependency_precheck":"PROCEED"}'
  [ "$status" -eq 1 ]
  contains "$stderr" "state.outcome is required"
  build '{"outcome":"failed"}'
  [ "$status" -eq 1 ]
  contains "$stderr" "state.dependency_precheck is required"
}

@test "a value outside its enum or of the wrong type is refused" {
  local bad
  for bad in \
    '{"outcome":"failed","dependency_precheck":"MAYBE"}' \
    '{"outcome":"failed","dependency_precheck":"PROCEED","gate_verdict":"SORT_OF"}' \
    '{"outcome":"failed","dependency_precheck":"PROCEED","risk":3}' \
    '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY","pr":"413"}' \
    '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY","pr":0}' \
    '{"outcome":"failed","dependency_precheck":"PROCEED","story_spec_present":"yes"}' \
    '{"outcome":"failed","dependency_precheck":"PROCEED","review_loop_run_ids":"review-loop-1-aaaa"}' \
    '{"outcome":"failed","dependency_precheck":"PROCEED","review_loop_run_ids":[""]}' \
    '{"outcome":"failed","dependency_precheck":"PROCEED","fallbacks_fired":["docs"]}' \
    '{"outcome":"escalated","dependency_precheck":"PROCEED","gate_verdict":"READY","escalation_status":"ERROR"}'; do
    build "$bad"
    [ "$status" -eq 1 ] || { echo "accepted: $bad"; return 1; }
    [ -z "$output" ] || { echo "stdout on refusal for: $bad"; return 1; }
  done
}

# --- usage ----------------------------------------------------------------------

@test "usage errors exit 2: dangling / empty / flag-shaped value, unknown flag, positional" {
  run --separate-stderr zsh "$B" --state
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$B" --state ""
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$B" --state --print-outcome
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$B" --bogus
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown flag: --bogus"
  run --separate-stderr zsh "$B" extra
  [ "$status" -eq 2 ]
}

@test "a bad --state operand is a usage error (exit 2), never a broken-state 1" {
  run --separate-stderr zsh "$B" --state "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 2 ]
  contains "$stderr" "does not exist"
  run --separate-stderr zsh "$B" --state "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  contains "$stderr" "is a directory"
}

@test "a process-substitution --state (a non-regular FIFO) is read, not refused (#1762)" {
  # The guard rejects only DIRECTORIES so the documented `--state <(jq -c …)`
  # idiom keeps working; narrowing it to a regular-file test reds this case.
  run --separate-stderr zsh "$B" --state <(printf '%s' "$SUCCESS")
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mode' <<<"$output")" = "story" ]
  [ "$(jq -r '.gate_verdict' <<<"$output")" = "READY" ]
  run --separate-stderr zsh "$B" --state <(printf '%s' "$SUCCESS") --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = "success" ]
}

@test "--help exits 0 with the usage" {
  run zsh "$B" --help
  [ "$status" -eq 0 ]
  contains "$output" "--print-outcome"
}

# --- each half of every compound rule, on its own ------------------------------

@test "escalated after a non-READY gate, or a non-PROCEED precheck, is refused" {
  refuses '{"outcome":"escalated","dependency_precheck":"PROCEED","gate_verdict":null,"escalation_status":"BUDGET_EXHAUSTED"}' "escalated needs a typed escalation_status"
  refuses '{"outcome":"escalated","dependency_precheck":null,"gate_verdict":"READY","escalation_status":"BUDGET_EXHAUSTED"}' "escalated needs a typed escalation_status"
}

@test "pr-opened after a non-READY gate, or a non-PROCEED precheck, is refused" {
  refuses '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":null,"pr":5}' "pr-opened needs a pr after"
  refuses '{"outcome":"pr-opened","dependency_precheck":null,"gate_verdict":"READY","pr":5}' "pr-opened needs a pr after"
}

@test "gate-parked with a null precheck is refused" {
  refuses '{"outcome":"gate-parked","dependency_precheck":null,"gate_verdict":"NEEDS_REFINEMENT"}' "gate-parked needs"
}

@test "a precheck-parked ending after an accepted remediation is filed, not refused" {
  # 'just the dependency', a failed rung, a rejecting re-verification: the last
  # precheck is still a rejection, and precheck-parked is the one row it fits
  build '{"outcome":"precheck-parked","dependency_precheck":"REJECT_BLOCKED"}'
  [ "$status" -eq 0 ]
  # while an errored re-verification is failed with a null precheck
  build '{"outcome":"failed","dependency_precheck":null}' --print-outcome
  [ "$output" = "failed" ]
}

@test "false is a wrong type, never read as an absent field" {
  local bad
  for bad in \
    '{"outcome":"failed","dependency_precheck":false}' \
    '{"outcome":"failed","dependency_precheck":"PROCEED","gate_verdict":false}' \
    '{"outcome":"failed","dependency_precheck":"PROCEED","escalation_status":false}' \
    '{"outcome":"failed","dependency_precheck":"PROCEED","pr":false}' \
    '{"outcome":"failed","dependency_precheck":"PROCEED","gate_verdict":"READY","risk":false}' \
    '{"outcome":"failed","dependency_precheck":"PROCEED","review_loop_run_ids":false}' \
    '{"outcome":"failed","dependency_precheck":"PROCEED","fallbacks_fired":false}'; do
    build "$bad"
    [ "$status" -eq 1 ] || { echo "accepted: $bad"; return 1; }
    [ -z "$output" ]
  done
}

@test "an unreadable --state is a usage error (exit 2)" {
  [ "$(id -u)" -ne 0 ] || skip "runs as root: mode 000 does not stop root reading the file"
  printf '%s' "$SUCCESS" > "$ST"
  chmod 000 "$ST"
  run --separate-stderr zsh "$B" --state "$ST"
  chmod 644 "$ST"
  [ "$status" -eq 2 ]
  contains "$stderr" "not readable"
}

@test "no --state with stdin on a terminal is a usage error, never a hang" {
  command -v script >/dev/null 2>&1 || skip "script(1) is not available to provide a terminal"
  # BSD and util-linux script(1) take different arguments; try both shapes. The
  # builder's own exit is printed INSIDE the pty, since script(1)'s status and
  # the `||` fallback would both hide it.
  # a wrapper FILE, so no layer of quoting can expand `$?` before the pty runs it
  local W="$BATS_TEST_TMPDIR/in-tty.zsh"
  printf 'zsh %q\nprint -r -- "rc=$?"\n' "$B" > "$W"
  run bash -c "script -q /dev/null zsh '$W' </dev/null 2>&1 || script -qec \"zsh '$W'\" /dev/null </dev/null 2>&1"
  contains "$output" "stdin is a terminal"
  contains "$output" "rc=2"
}

@test "review_loop_run_ids must hold strings, and pr must be a whole number" {
  build '{"outcome":"failed","dependency_precheck":"PROCEED","review_loop_run_ids":[7]}'
  [ "$status" -eq 1 ]
  contains "$stderr" "review_loop_run_ids must be an array of non-empty strings"
  build '{"outcome":"failed","dependency_precheck":"PROCEED","review_loop_run_ids":["review-loop-1-aaaa",{"a":1}]}'
  [ "$status" -eq 1 ]
  contains "$stderr" "review_loop_run_ids must be an array of non-empty strings"
  build '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY","pr":413.5}'
  [ "$status" -eq 1 ]
  contains "$stderr" "pr must be a positive integer or null"
}

@test "no jq on PATH is an internal error (exit 1), not a usage one" {
  local SB="$BATS_TEST_TMPDIR/nojq-bin"
  mkdir -p "$SB"
  ln -s "$(command -v zsh)" "$SB/zsh"
  printf '%s' "$SUCCESS" > "$ST"
  # the restricted PATH is the CHILD's only: bats' own `run` needs mktemp
  run --separate-stderr env PATH="$SB" "$SB/zsh" "$B" --state "$ST"
  [ "$status" -eq 1 ]
  contains "$stderr" "jq not found on PATH"
}

# --- the clean stop (#2579) -----------------------------------------------------

# an unattended clean stop: escalated, typed BUDGET_EXHAUSTED or
# ESCALATE_NO_CONVERGENCE, with its failing conditions
clean_state() {  # $1 = escalation_status, $2 = convergence_failures JSON, $3 = session mode
  jq -nc --arg es "$1" --argjson f "$2" --arg m "${3:-unattended}" \
    '{outcome:"escalated", dependency_precheck:"PROCEED", gate_verdict:"READY", risk:"normal",
      escalation_status:$es, session_mode:$m, session_mode_source:"env",
      clean_stop:true, convergence_failures:$f}'
}

@test "#2579 a clean stop records outcome escalated, clean_stop true and its convergence_failures" {
  build "$(clean_state BUDGET_EXHAUSTED '["trend","stuck"]')"
  [ "$status" -eq 0 ]
  [ "$(jq -c '{escalation_status, clean_stop, convergence_failures}' <<<"$output")" = '{"escalation_status":"BUDGET_EXHAUSTED","clean_stop":true,"convergence_failures":["trend","stuck"]}' ]
  build "$(clean_state ESCALATE_NO_CONVERGENCE '["cap"]')" --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = "escalated" ]
}

@test "#2579 today's escalation records clean_stop false and no convergence_failures" {
  build "$ESCALATED"
  [ "$status" -eq 0 ]
  [ "$(jq -c '{clean_stop, convergence_failures}' <<<"$output")" = '{"clean_stop":false,"convergence_failures":[]}' ]
  build "$SUCCESS"
  [ "$(jq -c '{clean_stop, convergence_failures}' <<<"$output")" = '{"clean_stop":false,"convergence_failures":[]}' ]
}

@test "#2579 clean_stop true is refused on any other ending, status or session mode" {
  local msg='clean_stop needs an escalated, unattended run whose escalation_status is BUDGET_EXHAUSTED or ESCALATE_NO_CONVERGENCE'
  # attended
  build "$(clean_state BUDGET_EXHAUSTED '["trend"]' attended)"
  [ "$status" -eq 1 ]; [ -z "$output" ]; contains "$stderr" "$msg"
  # another typed status
  local es
  for es in ESCALATE_CONFLICT ESCALATE_AMBIGUOUS; do
    build "$(clean_state "$es" '["trend"]')"
    [ "$es: $status" = "$es: 1" ]; contains "$stderr" "$msg"
  done
  # no session mode at all
  build "$(clean_state BUDGET_EXHAUSTED '["trend"]' | jq -c '.session_mode = null | .session_mode_source = null')"
  [ "$status" -eq 1 ]; contains "$stderr" "$msg"
  # another ending
  build "$(jq -c '. + {clean_stop:true, convergence_failures:["trend"], session_mode:"unattended", session_mode_source:"env"}' <<<"$SUCCESS")"
  [ "$status" -eq 1 ]; contains "$stderr" "$msg"
  build "$(jq -c '. + {clean_stop:true, convergence_failures:["trend"], session_mode:"unattended", session_mode_source:"env"}' <<<"$FAILED")"
  [ "$status" -eq 1 ]; contains "$stderr" "$msg"
}

@test "#2579 clean_stop and convergence_failures come together, and the failures are a closed set" {
  build "$(clean_state BUDGET_EXHAUSTED '[]')"
  [ "$status" -eq 1 ]; contains "$stderr" "clean_stop needs the failing convergence_failures"
  build "$(clean_state BUDGET_EXHAUSTED '["trend"]' | jq -c '.clean_stop = false')"
  [ "$status" -eq 1 ]; contains "$stderr" "convergence_failures is set, so clean_stop must be true"
  build "$(clean_state BUDGET_EXHAUSTED '["slow"]')"
  [ "$status" -eq 1 ]; contains "$stderr" "convergence_failures must be an array drawn from too-few-rounds | trend | stuck | critical | cap"
  build "$(clean_state BUDGET_EXHAUSTED '["trend"]' | jq -c '.clean_stop = "yes"')"
  [ "$status" -eq 1 ]; contains "$stderr" "clean_stop must be a boolean"
  local f
  for f in too-few-rounds trend stuck critical cap; do
    build "$(clean_state BUDGET_EXHAUSTED "[\"$f\"]")"
    [ "$f: $status" = "$f: 0" ]
  done
}

# --- resumed_from (#2920) -------------------------------------------------------

@test "#2920 resumed_from records checkpoint, clean_stop or null, and null when absent" {
  build "$SUCCESS"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.resumed_from' <<<"$output")" = 'null' ]
  build "$(jq -c '.resumed_from = null' <<<"$SUCCESS")"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.resumed_from' <<<"$output")" = 'null' ]
  local r
  for r in checkpoint clean_stop; do
    build "$(jq -c --arg r "$r" '.resumed_from = $r' <<<"$SUCCESS")"
    [ "$r: $status" = "$r: 0" ]
    [ "$(jq -r '.resumed_from' <<<"$output")" = "$r" ]
  done
}

@test "#2920 resumed_from outside its enum, or not a string, is refused" {
  local bad
  for bad in '"session"' 'true' '1' '"Checkpoint"'; do
    build "$(jq -c --argjson b "$bad" '.resumed_from = $b' <<<"$SUCCESS")"
    [ "$bad: $status" = "$bad: 1" ]
    [ -z "$output" ]
    contains "$stderr" "resumed_from must be checkpoint | clean_stop | null"
  done
}
