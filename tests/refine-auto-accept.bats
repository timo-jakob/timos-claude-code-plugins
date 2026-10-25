#!/usr/bin/env bats
#
# refine-issue's auto-accept threshold: with `--auto-accept <t>` or the
# `refine_auto_accept_threshold` setting, the conductor answers an issue-refiner
# question with the refiner's recommended answer when its confidence is AT OR
# ABOVE t, instead of asking the human. What these pin down:
#
#   * RESOLUTION — scripts/auto-accept-threshold.zsh: flag beats env beats the
#     default 1; a bad flag is exit 2, a bad env value fails safe to 1 and says
#     so on stderr.
#   * THE SPLIT — scripts/split-refiner-questions.zsh: confidence is the MINIMUM
#     of the five criteria (never a refiner-stated overall), compared in
#     thousandths with `>=`; a plain-string, unrecommended, unscored or
#     malformed question is always asked.
#   * WIRING — the conductor resolves the threshold, splits every turn with the
#     script, still requires the human's approval of the exact rewrite, and
#     lists the auto-taken answers there and in the Step 6 trail; the agent
#     emits the scored shape; the how-to and the settings table name the
#     variable.
#
# Anchored by content, never by line number (#1189).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/refine-issue/scripts"
  T="$SCRIPTS/auto-accept-threshold.zsh"
  SPLIT="$SCRIPTS/split-refiner-questions.zsh"
  SKILL="$REPO_ROOT/development/skills/refine-issue/SKILL.md"
  AGENT="$REPO_ROOT/development/agents/issue-refiner.md"
  HOWTO="$REPO_ROOT/docs/how-to/let-refine-issue-answer-confident-questions.md"
  TURN="$BATS_TEST_TMPDIR/turn.json"
}

assert_eq() {  # $1 = actual, $2 = expected, $3 = label
  [ "$1" = "$2" ] || { printf 'expected %s = %s, got %s\n' "$3" "$2" "$1" >&2; return 1; }
}

# run_t <env-value-or-UNSET> [args…]
run_t() {
  local e="$1"; shift
  if [ "$e" = "UNSET" ]; then
    run env -u refine_auto_accept_threshold zsh "$T" "$@"
  else
    run env refine_auto_accept_threshold="$e" zsh "$T" "$@"
  fi
}

# q <answer-or-null> <score> [<uniqueness-score>] — one scored question object
q() {
  local ans="$1" s="$2" u="${3:-$2}"
  jq -nc --argjson a "$ans" --argjson s "$s" --argjson u "$u" \
    '{question: "Q?", recommended_answer: $a, rationale: "because ARCHITECTURE.md says so",
      criteria: {repo_consistency: $s, best_practice: $s, evidence: $s,
                 uniqueness: $u, reversibility: $s}}'
}

# split <threshold-milli> <questions-json-array>
split() {
  jq -nc --argjson qs "$2" '{issue: 1, questions: $qs}' > "$TURN"
  run zsh "$SPLIT" --threshold-milli "$1" --turn "$TURN"
}

# --- resolution ---------------------------------------------------------------

@test "unset everywhere resolves to the default 1" {
  run_t UNSET
  [ "$status" -eq 0 ]
  [ "$output" = "1000 default" ]
}

@test "empty env value is the default, not ignored" {
  run_t ""
  [ "$status" -eq 0 ]
  [ "$output" = "1000 default" ]
}

@test "the env value is used when no flag is given" {
  run_t 0.9
  [ "$status" -eq 0 ]
  [ "$output" = "900 env" ]
}

@test "the flag beats the env value" {
  run_t 0.9 --flag .75
  [ "$status" -eq 0 ]
  [ "$output" = "750 flag" ]
}

@test "every admitted spelling parses to its thousandths" {
  local pair v want
  for pair in 0:0 0.0:0 .5:500 0.95:950 0.001:1 1:1000 1.0:1000 1.000:1000; do
    v="${pair%%:*}" want="${pair#*:}"
    run_t UNSET --flag "$v"
    [ "$status" -eq 0 ] || { echo "flag [$v] exited $status" >&2; return 1; }
    [ "$output" = "$want flag" ] || { echo "flag [$v] printed [$output]" >&2; return 1; }
  done
}

@test "a malformed flag value is exit 2 with the value named" {
  local v
  for v in 1.5 30 -0.1 0.0005 abc . "" 2; do
    run_t UNSET --flag "$v"
    [ "$status" -eq 2 ] || { echo "flag [$v] exited $status" >&2; return 1; }
  done
  run_t UNSET --flag 1.5
  contains "$output" "'1.5'"
}

@test "a malformed env value fails safe to 1 and says so on stderr" {
  run --separate-stderr env refine_auto_accept_threshold=90 zsh "$T"
  [ "$status" -eq 0 ]
  [ "$output" = "1000 env-ignored" ]
  contains "$stderr" "refine_auto_accept_threshold='90'"
}

@test "unknown arguments and a dangling --flag are exit 2" {
  run_t UNSET --bogus
  [ "$status" -eq 2 ]
  run_t UNSET --flag
  [ "$status" -eq 2 ]
}

# --- the split ----------------------------------------------------------------

@test "at the default 1, only an all-1.0 answer is auto" {
  split 1000 "[$(q '"yes"' 1), $(q '"no"' 1 0.99)]"
  [ "$status" -eq 0 ]
  assert_eq "$(jq -r '.auto | length' <<<"$output")" 1 "auto count"
  assert_eq "$(jq -r '.auto[0].answer' <<<"$output")" yes "auto answer"
  assert_eq "$(jq -r '.ask[0].reason' <<<"$output")" below-threshold "ask reason"
  assert_eq "$(jq -r '.threshold' <<<"$output")" 1.000 "threshold"
}

@test "confidence is the minimum criterion, and names the weakest" {
  split 0 "[$(q '"a"' 0.95 0.4)]"
  [ "$status" -eq 0 ]
  assert_eq "$(jq -r '.auto[0].confidence' <<<"$output")" 0.40 "confidence"
  assert_eq "$(jq -c '.auto[0].weakest' <<<"$output")" '["uniqueness"]' "weakest"
}

@test "the comparison is >= : equal to the threshold is auto, one hundredth below is asked" {
  split 900 "[$(q '"eq"' 0.9), $(q '"below"' 0.89)]"
  [ "$status" -eq 0 ]
  assert_eq "$(jq -r '.auto[0].answer' <<<"$output")" eq "equal is auto"
  assert_eq "$(jq -r '.ask[0].recommended_answer' <<<"$output")" below "below is asked"
}

@test "a refiner-stated overall confidence is ignored" {
  local obj
  obj="$(q '"a"' 0.5 | jq -c '. + {confidence: 1}')"
  split 900 "[$obj]"
  [ "$status" -eq 0 ]
  assert_eq "$(jq -r '.auto | length' <<<"$output")" 0 "auto count"
  assert_eq "$(jq -r '.ask[0].confidence' <<<"$output")" 0.50 "computed confidence"
}

@test "threshold 0 still asks a question with no recommendation" {
  split 0 "[\"plain string?\", $(q null 1)]"
  [ "$status" -eq 0 ]
  assert_eq "$(jq -r '.auto | length' <<<"$output")" 0 "auto count"
  assert_eq "$(jq -r '[.ask[].reason] | unique | join(",")' <<<"$output")" no-recommendation "reasons"
}

@test "a missing, out-of-range or three-decimal score is malformed and asked" {
  local missing range dec
  missing="$(q '"a"' 1 | jq -c 'del(.criteria.evidence)')"
  range="$(q '"a"' 1 | jq -c '.criteria.best_practice = 1.2')"
  dec="$(q '"a"' 1 | jq -c '.criteria.reversibility = 0.955')"
  split 0 "[$missing, $range, $dec]"
  [ "$status" -eq 0 ]
  assert_eq "$(jq -r '.auto | length' <<<"$output")" 0 "auto count"
  assert_eq "$(jq -r '[.ask[].reason] | unique | join(",")' <<<"$output")" malformed "reasons"
}

@test "a blank rationale is malformed and asked" {
  split 0 "[$(q '"a"' 1 | jq -c '.rationale = "  "')]"
  [ "$status" -eq 0 ]
  assert_eq "$(jq -r '.ask[0].reason' <<<"$output")" malformed "reason"
}

@test "an empty questions array splits to two empty lists" {
  split 1000 "[]"
  [ "$status" -eq 0 ]
  assert_eq "$(jq -c '[.auto, .ask]' <<<"$output")" '[[],[]]' "lists"
}

@test "a bad threshold or a turn without a questions array is exit 2" {
  split 1001 "[]"
  [ "$status" -eq 2 ]
  split abc "[]"
  [ "$status" -eq 2 ]
  echo '{"issue": 1}' > "$TURN"
  run zsh "$SPLIT" --threshold-milli 1000 --turn "$TURN"
  [ "$status" -eq 2 ]
  run zsh "$SPLIT" --threshold-milli 1000 --turn "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 2 ]
}

# --- the question kind (#2900) --------------------------------------------------

# kq <kind> <answer-or-null> <score> [<uniqueness-score>] — q with a `kind`
kq() {
  q "$2" "$3" "${4:-$3}" | jq -c --arg k "$1" '. + {kind: $k}'
}

@test "#2900 at threshold 1, an implementation answer is auto, its confidence ignoring uniqueness" {
  split 1000 "[$(kq implementation '"use jq"' 0.8 0.1)]"
  [ "$status" -eq 0 ]
  assert_eq "$(jq -c '.auto[0] | [.kind, .answer, .confidence, .weakest, .rationale]' <<<"$output")" \
    '["implementation","use jq","0.80",["repo_consistency","best_practice","evidence","reversibility"],"because ARCHITECTURE.md says so"]' "auto entry"
  assert_eq "$(jq -r '.ask | length' <<<"$output")" 0 "ask count"
}

@test "#2900 at threshold 1, intent and gap answers below it are asked, kind kept" {
  split 1000 "[$(kq intent '"a"' 0.9), $(kq gap '"b"' 0.9)]"
  [ "$status" -eq 0 ]
  assert_eq "$(jq -c '[.ask[] | [.kind, .reason]]' <<<"$output")" \
    '[["intent","below-threshold"],["gap","below-threshold"]]' "ask entries"
  assert_eq "$(jq -r '.auto | length' <<<"$output")" 0 "auto count"
}

@test "#2900 an intent answer at the threshold is auto, kind kept" {
  split 900 "[$(kq intent '"a"' 0.9)]"
  [ "$status" -eq 0 ]
  assert_eq "$(jq -c '[.auto[0].kind, .auto[0].confidence, (.ask | length)]' <<<"$output")" '["intent","0.90",0]' "auto entry"
}

@test "#2900 a missing or unknown kind is routed as gap, and a plain string stays asked" {
  split 1000 "[$(q '"a"' 0.9), $(kq bogus '"b"' 0.9), \"plain?\"]"
  [ "$status" -eq 0 ]
  assert_eq "$(jq -c '[.ask[] | [.kind, .reason]]' <<<"$output")" \
    '[["gap","below-threshold"],["gap","below-threshold"],["gap","no-recommendation"]]' "ask entries"
}

@test "#2900 malformed criteria never change an implementation answer's route" {
  split 1000 "[$(kq implementation '"use jq"' 0.8 | jq -c '.criteria = null')]"
  [ "$status" -eq 0 ]
  assert_eq "$(jq -c '.auto[0] | [.kind, .confidence, .weakest]' <<<"$output")" '["implementation",null,[]]' "auto entry"
}

@test "#2900 an implementation entry with no recommendation, or a blank rationale, is exit 2 naming it" {
  jq -nc --argjson qs "[$(kq implementation null 1)]" '{issue: 1, questions: $qs}' > "$TURN"
  run -2 --separate-stderr zsh "$SPLIT" --threshold-milli 0 --turn "$TURN"
  [ -z "$output" ]
  contains "$stderr" 'questions[0] (Q?): implementation entry has no recommended_answer'
  jq -nc --argjson qs "[$(kq gap '"ok"' 1), $(kq implementation '"use jq"' 1 | jq -c '.rationale = "  "')]" '{issue: 1, questions: $qs}' > "$TURN"
  run -2 --separate-stderr zsh "$SPLIT" --threshold-milli 0 --turn "$TURN"
  [ -z "$output" ]
  contains "$stderr" 'questions[1] (Q?): implementation entry has no rationale'
}

@test "#2900 the agent documents kind by the contract's section, and [decided] as an answer" {
  local a
  a="$(tr -s '[:space:]' ' ' < "$AGENT")"
  contains "$a" '"kind": "intent"'
  contains "$a" '`kind` — `intent`, `gap` or `implementation`, as ARCHITECTURE.md'"'"'s *Decision rights — question taxonomy and the Decisions-taken record* defines them'
  contains "$a" 'A human turn line that begins `[decided]`'
  contains "$a" 'plus every `implementation` choice your draft makes, emitted once, on the turn the draft first makes it, with a `recommended_answer` and a `rationale` so it is decided and recorded. Never re-emit a choice a `[decided]` line already answers,'
  contains "$a" 'It, too, is an answer, never a waiver.'
  contains "$a" 'An `implementation` question is never put to the human: the conductor takes your `recommended_answer` at any threshold and records it under **Decisions taken**'
  contains "$a" 'An `implementation` entry without them breaks this contract and the conductor re-asks you for the turn.'
  contains "$a" 'A missing or unknown `kind` is read as `gap`;'
  contains "$a" 'For an `implementation` question the scores are reported, never compared, and `uniqueness` is left out'
  contains "$a" 'Keep an existing `## Decisions taken` section verbatim; the skill adds new entries.'
}

@test "#2900 SKILL.md states the exit-2 exception, the [decided] relay and the append-only Decisions taken section" {
  local s
  s="$(tr -s '[:space:]' ' ' < "$SKILL")"
  contains "$s" 'the one exception to "malformed is asked, never an error" — an `implementation` entry has no `recommended_answer` or `rationale`'
  contains "$s" 'An exit 2 from `split-refiner-questions.zsh` is the refiner'"'"'s malformed turn: re-spawn the refiner for that round once; a second one stops the mode the same way.'
  contains "$s" 'For an `implementation` answer, add it as `[decided] <question> → <answer>` instead. It is absent from **Answers taken automatically**'
  contains "$s" 'scripts/render-decisions-taken.zsh" --split <split.json>'
  contains "$s" 'so the section sits inside the prose sentinels Step 3 writes, is part of the rewrite the human approves, and is covered by `prose_sha256`.'
  contains "$s" 'The section is append-only'
  contains "$s" 'For an `intent` or `gap` question its confidence is the lowest of the refiner'"'"'s five criterion scores, and the answer is `auto` only when that is at or above the threshold.'
  contains "$s" 'An `implementation` question is `auto` at any threshold (#2900).'
  contains "$s" 'or, for an `implementation` answer, in the body'"'"'s **Decisions taken** section.'
  contains "$s" 'never remove an entry an earlier run wrote to the issue body. The follow-up mode'"'"'s `accept` does the same before Step 3.'
  contains "$s" 'Otherwise add the **Decisions taken** section (Step 2) and write it back as Steps 2.5 and 3 do'
  contains "$s" 'Keep this issue'"'"'s split file of every round for that section.'
  contains "$s" 'Write its `decisions`, when present, to a file as `{"auto": <decisions>}`: that file counts as one of this issue'"'"'s round split files for the Decisions taken section.'
  contains "$s" 'on each of this issue'"'"'s round split files and add what it prints to `proposed_prose`, leaving out a decision from this run'"'"'s split files that the human overturned before approving (an overturned answer is a human reply, not a decision Claude took), so the section'
  contains "$s" 'when the current issue body or `proposed_prose` already holds a `## Decisions taken` section, put the new entries at its end'
  contains "$s" 'put the new entries at its end, under the one heading, and never remove an entry an earlier run wrote to the issue body.'
  contains "$s" 'The follow-up mode'"'"'s `accept` does the same before Step 3. An exit 2 is your own malformed call: fix it and re-run once.'
  contains "$s" 'the comment also lists its `intent` and `gap` answers under **Answers taken automatically**, each with its confidence and the threshold; its `implementation` answers are in the body'"'"'s **Decisions taken** section.'
  contains "$s" 'Either way, re-spawn the refiner for this round once, and if it fails again, relay the questions to the human as they are.'
  contains "$s" 'listing each auto-accepted `intent` or `gap` question, the answer, its confidence and its weakest criterion.'
}

@test "#2900 ARCHITECTURE.md's auto-accept setting routes kind" {
  contains "$(tr -s '[:space:]' ' ' < "$REPO_ROOT/ARCHITECTURE.md")" 'an `implementation` question is `auto` at any threshold, with a confidence reported but never compared and computed without `uniqueness`, and is recorded under **Decisions taken** rather than asked (#2900). A missing or unknown `kind` is `gap`.'
}

@test "#2900 the how-to says implementation questions are never put to the human" {
  contains "$(tr -s '[:space:]' ' ' < "$HOWTO")" 'The threshold applies to intent and gap questions. An implementation question is never put to you, whatever the threshold:'
  contains "$(cat "$HOWTO")" '## Implementation questions are decided, not asked'
  contains "$(tr -s '[:space:]' ' ' < "$HOWTO")" "Implementation answers are in the body's **Decisions taken** section instead."
}

# --- wiring -------------------------------------------------------------------

@test "the conductor resolves the threshold with the script and splits with the other" {
  contains "$(cat "$SKILL")" 'scripts/auto-accept-threshold.zsh'
  contains "$(cat "$SKILL")" 'scripts/split-refiner-questions.zsh'
  contains "$(cat "$SKILL")" '--auto-accept'
}

@test "auto-accept never skips the approval of the exact rewrite" {
  contains "$(cat "$SKILL")" 'Auto-accept never approves the rewrite'
  contains "$(cat "$SKILL")" 'Answers taken automatically'
}

@test "the agent emits the scored question shape and all five criteria" {
  local c
  for c in repo_consistency best_practice evidence uniqueness reversibility recommended_answer; do
    contains "$(cat "$AGENT")" "\"$c\"" || return 1
  done
}

@test "the how-to exists, names the variable, and is reachable" {
  [ -f "$HOWTO" ]
  contains "$(cat "$HOWTO")" 'refine_auto_accept_threshold'
  contains "$(cat "$REPO_ROOT/docs/how-to/index.md")" 'let-refine-issue-answer-confident-questions.md'
  contains "$(cat "$REPO_ROOT/docs/reference/plugins.md")" '`refine_auto_accept_threshold`'
}
