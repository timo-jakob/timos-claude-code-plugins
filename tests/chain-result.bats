#!/usr/bin/env bats
#
# refine-issue's chained refinement mode (#2939): chain-result.zsh reads the
# step-handoff/v1 file a chained run is dispatched with, and emits the run's one
# outcome document — ready, split, questions-pending or stopped, each a step
# verdict value by the same name. Every other outcome, and every malformed
# input, is exit 2 with nothing on stdout.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/refine-issue/scripts/chain-result.zsh"
  D="$BATS_TEST_TMPDIR"
  # A valid handoff (the use case's data sketch: #2939 chained from #2940).
  handoff() { jq -cn --argjson over "${1:-{\}}" \
    '{schema: "step-handoff/v1", issue: 2939, chained_from: 2940, origin: "human",
      scratch_dir: "/var/tmp/resolve-2940", answers: []} + $over' > "$D/h.json"; }
  # One round's split with one below-threshold gap question and one intent
  # question, and the refiner turn that raised them.
  cat > "$D/split.json" <<'EOF'
{"threshold":"0.900","auto":[],"ask":[
 {"question":"Where is the step-handoff contract recorded?","kind":"gap","recommended_answer":"ARCHITECTURE.md","confidence":"0.60","weakest":["evidence"],"rationale":"the contract index lives there","reason":"below-threshold"},
 {"question":"Should a split be filed without asking?","kind":"intent","recommended_answer":"yes","confidence":"0.70","weakest":["uniqueness"],"rationale":"the size check names the children","reason":"below-threshold"}]}
EOF
  cat > "$D/turn.json" <<'EOF'
{"questions":[
 {"question":"Where is the step-handoff contract recorded?","kind":"gap","recommended_answer":"ARCHITECTURE.md","proposed_doc_change":{"target":"ARCHITECTURE.md","section":"Step handoff contract (`step-handoff/v1`)","wording":"A step handoff is one JSON object."}},
 {"question":"Should a split be filed without asking?","kind":"intent","recommended_answer":"yes","proposed_doc_change":{"target":"x.md","section":"s","wording":"w"}}],
 "proposed_split":null}
EOF
}

# --- read-handoff ------------------------------------------------------------

@test "read-handoff prints a valid step-handoff/v1 object, keeping keys it does not read" {
  handoff '{"answers":[{"issue":2939,"question":"Where?","answer":"ARCHITECTURE.md"}],"step_kind":"refine"}'
  run -0 zsh "$S" read-handoff --file "$D/h.json"
  [ "$(jq -r '.schema, .issue, .chained_from, .origin, .scratch_dir' <<< "$output" | tr '\n' ' ')" = \
    "step-handoff/v1 2939 2940 human /var/tmp/resolve-2940 " ]
  [ "$(jq -c '.answers' <<< "$output")" = '[{"issue":2939,"question":"Where?","answer":"ARCHITECTURE.md"}]' ]
  [ "$(jq -r '.step_kind' <<< "$output")" = refine ]
}

@test "read-handoff accepts origin pipeline and an empty answers list" {
  handoff '{"origin":"pipeline"}'
  run -0 zsh "$S" read-handoff --file "$D/h.json"
  [ "$(jq -c '[.origin, .answers]' <<< "$output")" = '["pipeline",[]]' ]
}

@test "read-handoff refuses a missing file with exit 2 and nothing on stdout" {
  run --separate-stderr -2 zsh "$S" read-handoff --file "$D/absent.json"
  [ -z "$output" ]
  contains "$stderr" "--file file missing or unreadable"
}

@test "read-handoff refuses a file that is not exactly one JSON document" {
  printf 'not json' > "$D/h.json"
  run --separate-stderr -2 zsh "$S" read-handoff --file "$D/h.json"
  [ -z "$output" ]
  contains "$stderr" "is not exactly one JSON document"
  printf '{}\n{}\n' > "$D/h.json"
  run --separate-stderr -2 zsh "$S" read-handoff --file "$D/h.json"
  contains "$stderr" "is not exactly one JSON document"
}

@test "read-handoff names each malformed field: schema, issue, chained_from, origin, scratch_dir, answers" {
  local over want
  while IFS='|' read -r over want; do
    handoff "$over"
    run --separate-stderr -2 zsh "$S" read-handoff --file "$D/h.json"
    [ -z "$output" ] || { echo "stdout for $over: $output"; return 1; }
    contains "$stderr" "unreadable step handoff: $want"
  done <<'EOF'
{"schema":"step-handoff/v2"}|schema is not step-handoff/v1
{"issue":0}|issue is not an integer >= 1
{"issue":"2939"}|issue is not an integer >= 1
{"issue":1.5}|issue is not an integer >= 1
{"chained_from":null}|chained_from is not an integer >= 1
{"origin":"maintainer"}|origin is not human or pipeline
{"scratch_dir":"var/tmp/x"}|scratch_dir is not an absolute path
{"scratch_dir":""}|scratch_dir is not an absolute path
{"answers":{}}|answers is not an array
{"answers":[{"question":"q","answer":"a"}]}|answers[0] needs issue, question and answer
{"answers":[{"issue":2939,"answer":"a"}]}|answers[0] needs issue, question and answer
{"answers":[{"issue":2939,"question":"q"}]}|answers[0] needs issue, question and answer
{"answers":[{"issue":2939,"question":"q","answer":"a"},{"issue":2939,"question":" ","answer":"a"}]}|answers[1] needs issue, question and answer
EOF
}

@test "read-handoff refuses a JSON value that is not an object" {
  printf '[1]' > "$D/h.json"
  run --separate-stderr -2 zsh "$S" read-handoff --file "$D/h.json"
  contains "$stderr" "unreadable step handoff: the handoff is not a JSON object"
}

# --- emit: the four outcomes -------------------------------------------------

@test "ready carries the risk and the auto-accepted answers" {
  printf '[{"question":"q","answer":"a","confidence":"0.95","weakest":["evidence"]}]' > "$D/answers.json"
  run -0 zsh "$S" emit --issue 2939 --outcome ready --risk elevated --answers "$D/answers.json"
  [ "$output" = '{"schema":"chain-result/v1","issue":2939,"outcome":"ready","risk":"elevated","auto_accepted":[{"question":"q","answer":"a","confidence":"0.95","weakest":["evidence"]}]}' ]
}

@test "ready without --answers carries an empty auto_accepted list" {
  run -0 zsh "$S" emit --issue 2939 --outcome ready --risk low
  [ "$output" = '{"schema":"chain-result/v1","issue":2939,"outcome":"ready","risk":"low","auto_accepted":[]}' ]
  run -0 zsh "$S" emit --issue 2939 --outcome ready --risk normal
  [ "$output" = '{"schema":"chain-result/v1","issue":2939,"outcome":"ready","risk":"normal","auto_accepted":[]}' ]
}

@test "split carries the children filed" {
  # file-split-children.zsh's own filed array, unchanged
  printf '[{"index":1,"issue":3101,"linked":true},{"index":2,"issue":3102,"linked":false}]' > "$D/children.json"
  run -0 zsh "$S" emit --issue 2939 --outcome split --children "$D/children.json"
  [ "$output" = '{"schema":"chain-result/v1","issue":2939,"outcome":"split","children":[{"index":1,"issue":3101,"linked":true},{"index":2,"issue":3102,"linked":false}]}' ]
}

@test "questions-pending carries each ask entry unchanged, the resume path and the round" {
  run -0 zsh "$S" emit --issue 2939 --outcome questions-pending --split "$D/split.json" \
    --turn "$D/turn.json" --resume /var/tmp/resolve-2940/refine-2939-resume.json --round 2
  [ "$(jq -r '.outcome, .resume, .round' <<< "$output" | tr '\n' ' ')" = \
    "questions-pending /var/tmp/resolve-2940/refine-2939-resume.json 2 " ]
  # every ask-entry field, unchanged, in the split's order
  [ "$(jq -c '[.questions[] | del(.proposed_doc_change)]' <<< "$output")" = "$(jq -c '.ask' "$D/split.json")" ]
  [ "$(jq -r '.questions[0] | keys_unsorted | join(",")' <<< "$output")" = \
    "question,kind,recommended_answer,confidence,weakest,rationale,reason,proposed_doc_change" ]
}

@test "questions-pending adds proposed_doc_change on a gap only, taken from the turn's matching question" {
  run -0 zsh "$S" emit --issue 2939 --outcome questions-pending --split "$D/split.json" \
    --turn "$D/turn.json" --resume /r.json --round 1
  [ "$(jq -c '.questions[0].proposed_doc_change' <<< "$output")" = \
    '{"target":"ARCHITECTURE.md","section":"Step handoff contract (`step-handoff/v1`)","wording":"A step handoff is one JSON object."}' ]
  # the intent question's turn entry carries one too, and it is not copied
  [ "$(jq -c '.questions[1] | has("proposed_doc_change")' <<< "$output")" = false ]
}

@test "questions-pending: a gap whose turn question has no proposed_doc_change gets none" {
  jq -c '.questions[0] |= del(.proposed_doc_change)' "$D/turn.json" > "$D/turn2.json"
  run -0 zsh "$S" emit --issue 2939 --outcome questions-pending --split "$D/split.json" \
    --turn "$D/turn2.json" --resume /r.json --round 1
  [ "$(jq -c '[.questions[] | has("proposed_doc_change")]' <<< "$output")" = '[false,false]' ]
}

@test "questions-pending accepts the re-dispatch's ask-only split of the unanswered entries" {
  jq -c '{ask: [.ask[1]]}' "$D/split.json" > "$D/pending.json"
  run -0 zsh "$S" emit --issue 2939 --outcome questions-pending --split "$D/pending.json" \
    --turn "$D/turn.json" --resume /r.json --round 2
  [ "$(jq -c '[.questions[] | del(.proposed_doc_change)]' <<< "$output")" = "$(jq -c '.ask' "$D/pending.json")" ]
}

@test "stopped carries the reason" {
  run -0 zsh "$S" emit --issue 2939 --outcome stopped --reason "no convergence within the round cap"
  [ "$output" = '{"schema":"chain-result/v1","issue":2939,"outcome":"stopped","reason":"no convergence within the round cap"}' ]
}

# --- emit: refusals ------------------------------------------------------------

@test "an outcome outside the four is exit 2, the other step verdicts included" {
  local o
  for o in done needs-refinement blocked READY parked ""; do
    run --separate-stderr -2 zsh "$S" emit --issue 2939 --outcome "$o"
    [ -z "$output" ] || { echo "stdout for '$o': $output"; return 1; }
  done
  run --separate-stderr -2 zsh "$S" emit --issue 2939 --outcome done
  contains "$stderr" "--outcome must be ready, split, questions-pending or stopped, got 'done'"
}

@test "a flag that belongs to another outcome is exit 2" {
  run --separate-stderr -2 zsh "$S" emit --issue 2939 --outcome stopped --reason x --risk low
  [ -z "$output" ]
  contains "$stderr" "--risk does not belong to outcome stopped"
  printf '[{"index":1,"issue":1,"linked":true}]' > "$D/children.json"
  run --separate-stderr -2 zsh "$S" emit --issue 2939 --outcome ready --risk low --children "$D/children.json"
  contains "$stderr" "--children does not belong to outcome ready"
}

@test "malformed emit input is exit 2 with nothing on stdout" {
  printf '[]' > "$D/empty.json"
  printf '[{"index":1,"issue":0,"linked":true}]' > "$D/badchild.json"
  printf '[{"number":3101,"title":"child a"}]' > "$D/oldchild.json"
  printf '[{"question":"q"}]' > "$D/badanswers.json"
  printf '[{"question":"q","answer":"a","confidence":"0.95"}]' > "$D/noweakest.json"
  printf '[{"answer":"a","confidence":"0.95","weakest":[]}]' > "$D/noquestion.json"
  printf '{}' > "$D/obj.json"
  jq -c '.ask = []' "$D/split.json" > "$D/noask.json"
  jq -c '.ask[0].kind = "bogus"' "$D/split.json" > "$D/badkind.json"
  jq -c '.ask[0] |= del(.reason)' "$D/split.json" > "$D/noreason.json"
  jq -c '.ask[0].question = " "' "$D/split.json" > "$D/blankq.json"
  local -a calls=(
    "--issue 0 --outcome stopped --reason x|--issue must be an integer >= 1"
    "--issue abc --outcome stopped --reason x|--issue must be an integer >= 1"
    "--outcome stopped --reason x|--issue must be an integer >= 1"
    "--issue 2939 --outcome ready|--risk must be low, normal or elevated"
    "--issue 2939 --outcome ready --risk high|--risk must be low, normal or elevated"
    "--issue 2939 --outcome ready --risk low --answers $D/badanswers.json|--answers must be an array"
    "--issue 2939 --outcome ready --risk low --answers $D/noweakest.json|--answers must be an array"
    "--issue 2939 --outcome ready --risk low --answers $D/noquestion.json|--answers must be an array"
    "--issue 2939 --outcome ready --risk low --answers $D/obj.json|--answers must be an array"
    "--issue 2939 --outcome split|--children is required"
    "--issue 2939 --outcome split --children $D/empty.json|--children must be file-split-children.zsh's non-empty filed array"
    "--issue 2939 --outcome split --children $D/badchild.json|--children must be file-split-children.zsh's non-empty filed array"
    "--issue 2939 --outcome split --children $D/oldchild.json|--children must be file-split-children.zsh's non-empty filed array"
    "--issue 2939 --outcome questions-pending --split $D/noask.json --turn $D/turn.json --resume /r --round 1|non-empty ask set"
    "--issue 2939 --outcome questions-pending --split $D/badkind.json --turn $D/turn.json --resume /r --round 1|non-empty ask set"
    "--issue 2939 --outcome questions-pending --split $D/noreason.json --turn $D/turn.json --resume /r --round 1|non-empty ask set"
    "--issue 2939 --outcome questions-pending --split $D/blankq.json --turn $D/turn.json --resume /r --round 1|non-empty ask set"
    "--issue 2939 --outcome questions-pending --split $D/split.json --turn $D/turn.json --resume r.json --round 1|--resume must be an absolute path"
    "--issue 2939 --outcome questions-pending --split $D/split.json --turn $D/turn.json --resume /r --round 0|--round must be an integer >= 1"
    "--issue 2939 --outcome questions-pending --split $D/split.json --resume /r --round 1|--turn is required"
    "--issue 2939 --outcome questions-pending --split $D/split.json --turn $D/empty.json --resume /r --round 1|--turn must be one issue-refiner turn"
    "--issue 2939 --outcome questions-pending --split $D/split.json --turn $D/obj.json --resume /r --round 1|--turn must be one issue-refiner turn"
    "--issue 2939 --outcome stopped|--reason must be a non-blank string"
    "--issue 2939 --outcome stopped --reason x --reason y|--reason given twice"
  )
  local c args want
  for c in "${calls[@]}"; do
    args="${c%%|*}"; want="${c#*|}"
    # shellcheck disable=SC2086  # the call's words are split on purpose
    run --separate-stderr -2 zsh "$S" emit $args
    [ -z "$output" ] || { echo "stdout for $args: $output"; return 1; }
    contains "$stderr" "$want"
  done
}

@test "an unknown subcommand or flag is a usage error (exit 2); --help is exit 0" {
  run --separate-stderr -2 zsh "$S" relay
  contains "$stderr" "usage: chain-result.zsh read-handoff --file <path>"
  run --separate-stderr -2 zsh "$S"
  contains "$stderr" "usage:"
  run --separate-stderr -2 zsh "$S" read-handoff --issue 1
  contains "$stderr" "unknown argument for read-handoff: --issue"
  run --separate-stderr -2 zsh "$S" emit --issue
  contains "$stderr" "--issue needs a value"
  run -0 zsh "$S" --help
}

@test "jq missing from PATH is exit 1" {
  mkdir -p "$D/bin"
  ln -s "$(command -v zsh)" "$D/bin/zsh"
  run --separate-stderr -1 env PATH="$D/bin" zsh "$S" emit --issue 1 --outcome stopped --reason x
  [ -z "$output" ]
  contains "$stderr" "jq is not on PATH"
}

# --- the contracts, recorded where the reader looks -----------------------------

@test "ARCHITECTURE.md records the step-handoff/v1 contract with AC14's wording" {
  local a; a="$(tr '\n' ' ' < "$REPO_ROOT/ARCHITECTURE.md" | tr -s ' ')"
  grep -qxF '### Step handoff contract (`step-handoff/v1`)' "$REPO_ROOT/ARCHITECTURE.md"
  contains "$a" 'A step handoff is one JSON object the root writes for a step. Its fields are schema ("step-handoff/v1"), issue (int ≥ 1, the issue the step works on), chained_from (int ≥ 1, the root issue of the run), origin (human or pipeline), scratch_dir (an absolute path) and answers, a list of {issue, question, answer} entries. An entry'"'"'s question is the question text of a pending ask entry, verbatim, so a refinement matches each answer to the question it asked. A reader requires the fields it reads and ignores keys it does not read, so other step kinds may add fields. refine-issue'"'"'s chained mode (#2939) reads it with chain-result.zsh read-handoff.'
}

@test "ARCHITECTURE.md records the chained refinement mode with AC15's wording" {
  local a; a="$(tr '\n' ' ' < "$REPO_ROOT/ARCHITECTURE.md" | tr -s ' ')"
  grep -qxF '### The chained refinement mode — `refine-issue --chained-from` (#2939)' "$REPO_ROOT/ARCHITECTURE.md"
  contains "$a" 'A chained refinement returns one outcome document from chain-result.zsh, whose outcome is ready, split, questions-pending or stopped. Each is a step verdict value by the same name: a refinement step ends with the verdict its outcome names, and never ends done, needs-refinement or blocked. ready carries the risk and the auto-accepted answers, split the children filed, questions-pending the pending ask entries and the resume-state path, and stopped the reason.'
  # the follow-up mode paragraph states the #2939 rules
  contains "$a" '**Splits and test cases outside this mode (#2939).**'
  contains "$a" 'it still receives its seed, and the already-attempted and second-generation refusals do not apply to it.'
}

# --- the SKILL.md rules that run this script (#2939) ------------------------------

@test "refine-issue's chained mode section states its dispatch, state and outcome rules" {
  local f="$REPO_ROOT/development/skills/refine-issue/SKILL.md" t
  t="$(tr '\n' ' ' < "$f" | tr -s ' ')"
  grep -qxF '## Chained refinement mode (`--chained-from`, #2939)' "$f"
  contains "$t" '**It never asks the human itself.**'
  contains "$t" '`--chained-from` is never combined with `--follow-up`: print the usage line and stop.'
  contains "$t" 'Its `scratch_dir` holds this issue'"'"'s chained state: the rounds directory is `<scratch_dir>/refine-<N>.rounds/` and the conductor'"'"'s defaults file `<scratch_dir>/refine-<N>.defaults.json`'
  contains "$t" '**A first dispatch** is one with no `<scratch_dir>/refine-<N>-resume.json`.'
  contains "$t" 'A pending question still unanswered returns `questions-pending` again with only the unanswered entries, and makes no refiner call:'
  contains "$t" 'The run prints exactly one document from `chain-result.zsh emit`: `ready` (Step 5'"'"'s `READY` branch, with the re-gate verdict'"'"'s risk and the auto-accepted answers), `split`, `questions-pending` or `stopped`.'
  contains "$t" 'A `questions-pending` dispatch emits none.'
  contains "$t" 'A chained refinement shows them to no one: it returns `questions-pending` for its caller to relay'
  contains "$t" '`/development:refine-issue <issue-number|url> [--auto-accept <0..1>] [--follow-up | --chained-from <root> --handoff <file>]`'
  contains "$t" 'A target the classification does not find a single issue returns `stopped` with the classification'"'"'s finding as the reason: the Epic walk never runs in a chained refinement.'
  contains "$t" 'it skips Steps 0 and 1, restores the state the file holds, and continues Step 2 with no new Step 1 diagnosis (step 5 below).'
  contains "$t" '`<scratch_dir>/refine-<N>-resume.json`, holding the issue'"'"'s `title` and `body`, the `conversation`, the open objections, the round turn- and split-file paths, the decisions taken, the auto-accepted answers so far, the `ROUNDS`/`RAISED`/`RESOLVED` counters, Step 0'"'"'s `t0` and `repo_root`, Step 1'"'"'s `RISK` and `SIZE_PREFLIGHT`, `paused_s` and `waiting_since` (now), and the pending `ask` entries.'
  contains "$t" '`chain-result.zsh emit --issue <N> --outcome questions-pending --split <the round'"'"'s split> --turn <the round'"'"'s turn> --resume <the resume file> --round <ROUNDS>`.'
  contains "$t" 'It adds `now - waiting_since` to `paused_s`, then takes each handoff `answers` entry for this issue whose `question` is a pending entry'"'"'s question text, verbatim, and adds it to the round'"'"'s human reply as the plain human line `<question> → <answer>`.'
  contains "$t" 'it rewrites the resume file with the lines it did add, `waiting_since` reset to now and only the unanswered entries pending, and passes `--split` a file holding `{"ask": [<the unanswered entries>]}`.'
  contains "$t" 'The all-auto check does not run: no chained run has an approval to skip.'
  contains "$t" 'A `null` `proposed_split`, or a child with an empty `files`, stops the chain as a permanent failure: return `stopped` with the reason "the size check stops the draft and the split names no children". A `file-split-children.zsh` exit 1 runs another round within the cap; an exit 3 returns `stopped` with its stderr as the reason, and an exit 5 with its report'"'"'s `error`.'
  contains "$t" '`ready` records `refined-ready`, `split` and step 8'"'"'s exit 5 record `parked` with `split-recommended`, and any other `stopped` records `parked` with `deferred`. An unreadable handoff stops before Step 0, so it is not a run and records nothing.'
  contains "$t" 'A chained refinement is another (*Chained refinement mode*, #2939): the human'"'"'s relayed answers, the auto-accepted answers and the Decisions taken stand in for it.'
}

@test "refine-issue's split rules: an epic-walk child's filed split, and a split with no children" {
  local t; t="$(tr '\n' ' ' < "$REPO_ROOT/development/skills/refine-issue/SKILL.md" | tr -s ' ')"
  contains "$t" '(In an epic walk that ends **this child**, not the walk: note it in the epic summary as split into its filed children, and walk them after the rest of this pass, as children of their new epic `<N>`.)'
  contains "$t" 'A split that names no children is never filed: a direct run asks to revise or park, and a chained run stops.'
  contains "$t" 'It returns one `scripts/chain-result.zsh` outcome document — `ready`, `split`, `questions-pending` or `stopped` — and writes nothing back while a question is pending'
}
