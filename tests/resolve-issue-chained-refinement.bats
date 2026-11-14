#!/usr/bin/env bats
#
# The chained refinement in a human-started resolve-issue run (#2940).
#
# A human-started run no longer stops at §0b, E1b or §2: the root dispatches a
# chained refinement step (refine-issue --chained-from, #2939) and continues on
# its verdict. Every unit of work in such a run is a step, a fresh subagent that
# exchanges work with the root only through a step handoff (#2939's
# step-handoff/v1, adopted unchanged) and a step verdict (ARCHITECTURE.md's
# *Step verdict contract*). A pipeline-started run stops exactly as before.
#
# The prose pins are anchored by content, never by line number (#1189). The
# contract's executable parts — the conductor's jq verdict check and the
# refinement step's chain-result → verdict conversion — are extracted from
# reference/chain-steps.md and RUN, so a drift between the two files reds here
# rather than in a live chain.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"  # the user-level telemetry default stays out of the real ~/.claude (#1972)
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_DIR="$REPO_ROOT/development/skills/resolve-issue"
  SKILL="$SKILL_DIR/SKILL.md"
  STEPS="$SKILL_DIR/reference/chain-steps.md"
  RSTEP="$REPO_ROOT/development/agents/resolve-step.md"   # the issue step's agent (#3014)
  FSTEP="$REPO_ROOT/development/agents/refine-step.md"    # the refinement step's agent (#3014)
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  CR="$REPO_ROOT/development/skills/refine-issue/scripts/chain-result.zsh"
  D="$BATS_TEST_TMPDIR"
}

# A file's text on one line, whitespace squeezed, so a wrapped phrase matches.
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

# One `## ` section of a markdown file, heading line included.
section() {
  awk -v h="$2" 'index($0, "## " h) == 1 { f = 1; print; next } f && /^## / { exit } f' "$1"
}

# The ARCHITECTURE.md section from a `### ` heading to the next `##`/`###`.
arch_section() {
  awk -v h="$1" 'index($0, "### " h) == 1 { f = 1; print; next } f && /^##/ { exit } f' "$ARCH"
}

# The conductor's verdict check, as chain-steps.md states it: the jq filter
# between `jq -e -s --argjson n <N> --arg kind <issue|refinement> '` and
# `' <scratch_dir>/step-<N>-verdict.json`.
verdict_filter() {
  perl -0ne "print \$1 if /jq -e -s --argjson n <N> --arg kind <issue\\|refinement> '(length == 1 and .*?)' <scratch_dir>\\/step-<N>-verdict\\.json/s" "$STEPS"
}

# The refinement step's conversion of a chain-result/v1 document to a verdict,
# carried by the refine-step agent's definition since #3014.
convert_filter() {
  perl -0ne "print \$1 if /jq '(\\{schema: \"step-verdict\\/v1\".*?)' <scratch_dir>\\/chain-result-<N>\\.json > <scratch_dir>\\/step-<N>-verdict\\.json/s" "$FSTEP"
}

check() {  # <verdict json> [issue|refinement] -> exit status of the documented check
  local f; f="$(verdict_filter)"
  [ -n "$f" ] || { echo "could not extract the verdict check from $STEPS" >&2; return 99; }
  printf '%s' "$1" | jq -e -s --argjson n 2940 --arg kind "${2:-issue}" "$f" >/dev/null
}

v() {  # <verdict> <jq object of extra fields> -> a verdict document
  jq -cn --arg v "$1" --argjson x "$2" \
    '{schema: "step-verdict/v1", issue: 2940, verdict: $v, follow_ups: []} + $x'
}

esc() {  # [jq update] -> a clean stop's escalation payload (#3077)
  jq -cn '{status: "BUDGET_EXHAUSTED", trigger: ["stuck"], trend: "flat", series: [3, 3],
    carried_blockers: [{title: "t", file: "a.zsh", line: 4, dimension: "tests", severity: "WARNING", suggested_fix: "f"}],
    proposal: {recommend: "guidance", add: 3, guidance: "- t (`a.zsh:4`): f"},
    work_dir: "/h/.claude/resolve-issue/r/2940/work-dir", status_file: "/h/.claude/resolve-issue/r/2940/status.json"}
    | '"${1:-.}"
}

# --- AC1: origin ------------------------------------------------------------

@test "#2940 §0a defines the run's origin: human on the attended inference whatever resolve_session says, pipeline otherwise, inherited" {
  local t; t="$(flat "$SKILL")"
  contains "$t" '**Then note the run'"'"'s origin (#2940)** — `human` when a human invoked the skill (the attended inference above, whatever `resolve_session` says), `pipeline` for a maintenance-pipeline run — and pass it to `story-telemetry.zsh start --origin`.'
  contains "$t" 'Every run the chain starts inherits it.'
}

@test "#2940 ARCHITECTURE.md's resolve-issue telemetry requires origin human | pipeline" {
  local t; t="$(flat "$ARCH")"
  contains "$t" '| `origin` | `human` \| `pipeline` (#2940)'
  contains "$t" 'Required: the builder refuses a state whose `origin` is missing, `null` or any other value |'
}

@test "#2940 telemetry.md passes --origin to start and the epic children inherit it" {
  local t; t="$(flat "$SKILL_DIR/reference/telemetry.md")"
  contains "$t" '--run-file <scratch>/story-run-<N>.json --origin <human|pipeline>'
  contains "$t" '`child_start_args` carries it to every child'
  t="$(flat "$SKILL_DIR/reference/epic-telemetry.md")"
  contains "$t" '--run-file <scratch>/epic-run-<N>.json --origin <human|pipeline>'
  contains "$t" 'and its `--origin` (#2940), which every child inherits'
}

# --- AC2-AC5, AC8: where a human-started run chains ----------------------------

@test "#2940 §0b: a human-started step ends needs-refinement; ready restarts at §1 with no second gate, split takes the Epic flow" {
  local t; t="$(flat "$SKILL")"
  contains "$t" 'In a human-started run (#2940) the step ends with verdict `needs-refinement`, and the root dispatches a chained refinement step: on `ready` a fresh step starts at §1 with the re-gate'"'"'s risk and no second gate, and on `split` the root resolves the parent with the Epic flow:'
  # the pipeline stop is still there, unchanged
  contains "$t" 'emit the run'"'"'s record (§7), and **stop** — report that the story went back for refinement.'
  t="$(flat "$STEPS")"
  contains "$t" 'That step skips §0a and §0b, carries `risk` from the `ready` verdict, and records `dependency_precheck: PROCEED` and `gate_verdict: READY`. It never runs a second gate.'
}

@test "#2940 E1b: the root refines every unready leaf, re-gates all open leaves after a split, and an E3 child never refines" {
  local t; t="$(flat "$SKILL")"
  contains "$t" 'That halt is a pipeline-started run'"'"'s (#2940). In a human-started run (origin `human`, decided as §0a decides it), after labelling and commenting, the root dispatches one chained refinement step for every unready leaf.'
  contains "$t" 'After any split it re-reads the tree and re-gates every open leaf, and it proceeds to E2 only when all are READY.'
  contains "$t" 'An E3 child never prompts or refines.'
}

@test "#2940 §2: a human-started run parks without asking and chains; a pipeline run or an E3 child parks and stops" {
  local t; t="$(flat "$SKILL")"
  contains "$t" '**(b) A human-started run parks and chains.** Origin `human` (§0a), whatever the session mode, and not an E3 child'
  contains "$t" 'The root dispatches a chained refinement step, which files the split from that comment'"'"'s inventory, and resolves the parent with the Epic flow:'
  contains "$t" '**(c) A pipeline-started run or an E3 child parks and stops.** Never prompt:'
}

@test "#2940 E3: a size-stopped child of a human-started walk is chained after its step returns and becomes an inner node on split" {
  local t; t="$(flat "$SKILL")"
  contains "$t" 'A pipeline-started walk never chains into a split. In a human-started walk, when that child'"'"'s step returns, the root dispatches a chained refinement step on it (#2940).'
  contains "$t" 'On `split` the child becomes an inner node, whose new leaves the root gates by E1b'"'"'s rule and builds in the same walk, before any child that is `blockedBy` it. On `stopped` it stays parked.'
  lacks "$t" 'Never auto-chain into a split.'
}

@test "#2940 a pipeline-started run never reads chain-steps.md and stops as it always did" {
  local t; t="$(flat "$STEPS")"
  contains "$t" 'A pipeline-started run never reads it. It stops at §0b, E1b and §2 exactly as it always did, and runs every step in-session.'
}

# --- AC7: a stopped refinement ----------------------------------------------

@test "#2940 a stopped refinement keeps the label, posts 'chained refinement stopped:' and ends gate-parked, failed or the E1b halt" {
  local t; t="$(section "$STEPS" 'The chained refinement step (#2940)' | tr '\n' ' ' | tr -s ' ')"
  contains "$t" 'the run keeps the label it posted and posts one comment that begins `chained refinement stopped:` with the reason, read from the verdict file so no shell expands it:'
  contains "$t" 'jq -r '"'"'"chained refinement stopped: " + .reason'"'"' <scratch_dir>/step-<N>-verdict.json'
  contains "$t" '| gh issue comment <N> --body-file -'
  lacks "$t" '--body "chained refinement stopped:'
  contains "$t" 'A single-issue root emits nothing more, because the step already emitted its record.'
  contains "$t" '**at §0b:** with `needs-refinement`, and the step'"'"'s record already says outcome `gate-parked`;'
  contains "$t" '**at §2:** with `needs-split`, the branch un-pushed, no PR, and the step'"'"'s record already says outcome `failed`;'
  contains "$t" '**at E1b:** with `needs-refinement` on each stopped child. The epic halt summary names each stopped child and its reason, and nothing is built;'
  contains "$t" '**on an E3 child:** the child stays parked, as E3 parks a size-stopped child, and the walk continues with the children that don'"'"'t depend on it.'
}

# --- AC9: records ------------------------------------------------------------

@test "#2940 each step emits its own story record parented to the root run" {
  local t; t="$(flat "$STEPS")"
  contains "$t" '**Each step emits its own story record**, parented to the root run.'
  contains "$t" 'It runs `story-telemetry.zsh start --run-file <scratch_dir>/chain-run-<N>.json --origin human` once, with the sink flags it was given, and passes its `run_id` as every handoff'"'"'s `parent_run_id`.'
  contains "$t" 'It runs `start --parent-run-id <parent_run_id> --origin <origin>` and emits its record at its ending.'
  contains "$t" '**What the root emits.** For an epic entry, the root emits the epic record. For a single-issue entry, it emits no story record of its own: its `run_id` is a correlation key that groups the chain'"'"'s step records, with no record of its own.'
  t="$(flat "$ARCH")"
  contains "$t" 'a single-issue root'"'"'s `run_id` is a correlation key that groups them and has no record of its own'
}

# --- AC10: the step model --------------------------------------------------------

@test "#2940 every unit of work in a human-started run is a fresh-subagent step; the root reads only the verdict file" {
  local t; t="$(flat "$STEPS")"
  contains "$t" 'Every unit of work is a **step**: the named issue'"'"'s own run, each chained refinement and each E3 child'"'"'s run. The root dispatches each step as a fresh subagent'
  contains "$t" 'and reads the result only from `<scratch_dir>/step-<N>-verdict.json`, never from the step'"'"'s transcript.'
  contains "$t" 'The root keeps Step 0'"'"'s classification and, for an epic, E1 to E5'"'"'s control flow. Each child'"'"'s run is still a step.'
}

@test "#2940 a retry is a new dispatch, a step dispatches no step, and the depth budget is root 0 → step 1 → panel or refiner 2 → reviewers 3" {
  local t; t="$(flat "$STEPS")"
  contains "$t" '**A retry or a recovery is a new dispatch, never a resumed agent.** A step dispatches no further step, so the depth stays root (0) → step (1) → panel or refiner (2) → reviewers (3).'
  t="$(flat "$ARCH")"
  contains "$t" 'A step dispatches no further step, so the depth stays root (0) → step (1) → panel or refiner (2) → reviewers (3).'
}

@test "#2940 a step with no verdict file is messaged to carry on, not counted as failed" {
  local t; t="$(flat "$STEPS")"
  contains "$t" '**A step that ends its turn with no verdict file is messaged to carry on, not counted as failed.**'
  contains "$t" 'Send it one SendMessage asking it to finish and write the verdict file.'
  contains "$t" 'A verdict the check above rejects gets the same message, naming the field that fails.'
  contains "$t" 'Only a step that still writes no valid verdict is a failure: report it and emit nothing on the step'"'"'s behalf. A single-issue root then stops the chain.'
  contains "$t" 'In an epic, the root treats it as a tooling failure of that child: it parks the child, quotes the failure in the epic summary, and continues E3.'
  t="$(flat "$ARCH")"
  contains "$t" 'a step that ends its turn with no verdict file is messaged to carry on, not counted as failed'
}

@test "#2940 ARCHITECTURE.md defines the step verdict next to step-handoff/v1, with exactly the seven values" {
  local h v
  # adjacent: the verdict contract is the section right after the handoff contract
  h="$(grep -n '^### Step handoff contract (`step-handoff/v1`)' "$ARCH" | cut -d: -f1)"
  v="$(grep -n '^### Step verdict contract (#2940)' "$ARCH" | cut -d: -f1)"
  [ -n "$h" ]
  [ -n "$v" ]
  [ "$(awk -v a="$h" -v b="$v" 'NR > a && NR < b && /^##/' "$ARCH" | wc -l | tr -d ' ')" = 0 ]
  local values
  values="$(arch_section 'Step verdict contract (#2940)' \
    | sed -n 's/^| `\([a-z-]*\)` | .*/\1/p' | grep -vx verdict | tr '\n' ' ')"
  [ "$values" = "done needs-refinement ready split blocked questions-pending stopped " ]
  local t; t="$(arch_section 'Step verdict contract (#2940)' | tr '\n' ' ' | tr -s ' ')"
  contains "$t" 'Its fields are schema ("step-verdict/v1"), issue (int ≥ 1, the issue the step worked on), verdict, follow_ups'
  contains "$t" 'A refinement step ends with the verdict its chain-result outcome names (ready, split, questions-pending or stopped)'
  contains "$t" 'an issue-run step never ends ready or questions-pending.'
  contains "$t" 'A verdict file that is missing, not one JSON object, or carries a value outside the table is not a result'
  contains "$t" 'optionally run_id (an issue-run step'"'"'s own story run, or `null` when it never reached `start`), and the fields its verdict value carries:'
}

@test "#2940 the step handoff is #2939's step-handoff/v1, adopted unchanged: chain-result read-handoff accepts the issue step's handoff" {
  local t; t="$(flat "$ARCH")"
  contains "$t" '#2940 adopts this contract, unchanged, for resolve-issue'"'"'s step dispatch'
  # the issue-run step's handoff example, extra fields and all, reads cleanly
  perl -0ne 'print $1 if /```json\n(\{ "schema": "step-handoff\/v1".*?\})\n```/s' "$STEPS" \
    | sed 's|"/abs/scratch"|"/var/tmp/resolve-2907"|; s|"<the root'"'"'s run_id>"|"resolve-issue-1-abcd"|' > "$D/h.json"
  [ -s "$D/h.json" ]
  run --separate-stderr zsh "$CR" read-handoff --file "$D/h.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '"\(.kind) \(.start_at) \(.origin)"' <<< "$output")" = "issue 0a human" ]
}

@test "#2940 the documented verdict check accepts each of the seven verdict values" {
  check "$(v done '{"pr": 3010}')"
  check "$(v needs-refinement '{"reason": "gate"}')"
  check "$(v needs-refinement '{"reason": "size"}')"
  check "$(v ready '{"risk": "elevated", "auto_accepted": []}')" refinement
  check "$(v split '{"children": [{"index": 1, "issue": 3011, "linked": true}]}')" refinement
  check "$(v blocked '{"blockers": [2941]}')"
  check "$(v questions-pending '{"questions": [{"question": "q?"}], "resume": "/s/refine-2940-resume.json", "round": 1}')" refinement
  check "$(v stopped '{"reason": "no convergence within the round cap"}')" refinement
  # an issue-run step's run_id, a string or null, and filed follow-ups
  check "$(v done '{"pr": 3010, "run_id": "resolve-issue-1-abcd", "follow_ups": [3020]}')"
  check "$(v stopped '{"reason": "unreadable step handoff", "cause": "tooling", "run_id": null}')"
  # an issue-run step's stopped carries each of the four causes E3 triages; a
  # clean stop also carries its escalation payload (#3077)
  local c
  for c in escalation tooling failed; do
    check "$(v stopped "$(jq -cn --arg c "$c" '{reason: "r", cause: $c}')")"
  done
  check "$(v stopped "$(jq -cn --argjson e "$(esc)" '{reason: "r", cause: "clean-stop", escalation: $e}')")"
}

@test "#2940 the documented verdict check refuses an unknown value, a missing field and a wrong schema" {
  # jq -e exits 1 on a false result; 99 (no filter extracted) or 3 (a syntax
  # error) would be the check breaking, never a refusal
  refuse() {  # <issue|refinement> <doc>
    run check "$2" "$1"
    [ "$status" -eq 1 ] || { echo "accepted or broke on ($1): $2 (status $status)"; return 1; }
  }
  local doc
  for doc in \
    "$(v merged '{"pr": 1}')" \
    "$(v done '{}')" \
    "$(v done '{"pr": "3010"}')" \
    "$(v done '{"pr": 1.5}')" \
    "$(v needs-refinement '{"reason": "x"}')" \
    "$(v blocked '{}')" \
    "$(v blocked '{"blockers": 2941}')" \
    "$(v stopped '{"reason": ""}')" \
    "$(v stopped '{"reason": "   "}')" \
    "$(v stopped '{"reason": "an issue step with no cause"}')" \
    "$(v stopped '{"reason": "r", "cause": "parked"}')" \
    "$(v done '{"pr": 1, "follow_ups": ["x"]}')" \
    "$(v done '{"pr": 1, "follow_ups": [0]}')" \
    "$(v done '{"pr": 1, "run_id": 7}')" \
    "$(v done '{"pr": 1, "follow_ups": [1.5]}')" \
    "$(v done '{"pr": 1, "follow_ups": "3020"}')" \
    "$(jq -c '.issue = "2940"' <<< "$(v done '{"pr": 1}')")" \
    "$(jq -c '.issue = 2941' <<< "$(v done '{"pr": 1}')")" \
    "$(jq -c 'del(.follow_ups)' <<< "$(v done '{"pr": 1}')")" \
    "$(jq -c '.schema = "step-verdict/v2"' <<< "$(v done '{"pr": 1}')")" \
    "$(v done '{"pr": 1}')$(v done '{"pr": 2}')" \
    "$(v ready '{"risk": "normal", "auto_accepted": []}')" \
    "$(v split '{"children": [{"index": 1, "issue": 3011, "linked": true}]}')" \
    "$(v questions-pending '{"questions": [{"question": "q?"}], "resume": "/s/r.json", "round": 1}')"
  do
    refuse issue "$doc"
  done
  for doc in \
    "$(v ready '{"risk": "high", "auto_accepted": []}')" \
    "$(v ready '{"risk": "normal", "auto_accepted": null}')" \
    "$(v ready '{"risk": "normal", "auto_accepted": "x"}')" \
    "$(v split '{"children": []}')" \
    "$(v split '{"children": "3011"}')" \
    "$(v split '{"children": [3011]}')" \
    "$(v questions-pending '{"questions": [], "resume": "/s/r.json", "round": 1}')" \
    "$(v questions-pending '{"questions": [{"question": "q?"}], "round": 1}')" \
    "$(v questions-pending '{"questions": [{"question": "q?"}], "resume": "/s/r.json"}')" \
    "$(v questions-pending '{"questions": "q?", "resume": "/s/r.json", "round": 1}')" \
    "$(v questions-pending '{"questions": ["q?"], "resume": "/s/r.json", "round": 1}')" \
    "$(v questions-pending '{"questions": [{"question": "q?"}], "resume": "/s/r.json", "round": 0}')" \
    "$(v questions-pending '{"questions": [{"question": "q?"}], "resume": "/s/r.json", "round": 1.5}')" \
    "$(v questions-pending '{"questions": [{"question": "q?"}], "resume": "/s/r.json", "round": "1"}')" \
    "$(v questions-pending '{"questions": [{"question": "q?"}], "resume": 7, "round": 1}')" \
    "$(v stopped '{"reason": ""}')" \
    "$(v stopped '{"reason": "r", "cause": "tooling"}')" \
    "$(v done '{"pr": 3010}')" \
    "$(v needs-refinement '{"reason": "gate"}')" \
    "$(v blocked '{"blockers": [2941]}')"
  do
    refuse refinement "$doc"
  done
  # a kind outside the two refuses even a verdict valid for either
  refuse issues "$(v done '{"pr": 3010}')"
  refuse step "$(v stopped '{"reason": "r"}')"
}

@test "#2940 a refinement step's verdict is its chain-result outcome, converted as documented and accepted by the check" {
  local conv; conv="$(convert_filter)"
  [ -n "$conv" ]
  # ready
  zsh "$CR" emit --issue 2940 --outcome ready --risk normal > "$D/ready.json"
  jq -c "$conv" "$D/ready.json" > "$D/v.json"
  [ "$(jq -r '"\(.verdict) \(.risk) \(.auto_accepted | length)"' "$D/v.json")" = "ready normal 0" ]
  check "$(cat "$D/v.json")" refinement
  # split
  printf '[{"index":1,"issue":3011,"linked":true}]' > "$D/children.json"
  zsh "$CR" emit --issue 2940 --outcome split --children "$D/children.json" > "$D/split.json"
  jq -c "$conv" "$D/split.json" > "$D/v.json"
  [ "$(jq -r '"\(.verdict) \(.children[0].issue)"' "$D/v.json")" = "split 3011" ]
  check "$(cat "$D/v.json")" refinement
  # stopped
  zsh "$CR" emit --issue 2940 --outcome stopped --reason "unreadable step handoff" > "$D/stopped.json"
  jq -c "$conv" "$D/stopped.json" > "$D/v.json"
  [ "$(jq -r '"\(.verdict)|\(.reason)|\(.schema)"' "$D/v.json")" = "stopped|unreadable step handoff|step-verdict/v1" ]
  check "$(cat "$D/v.json")" refinement
  # questions-pending
  jq -n '{ask: [{question: "Which?", kind: "intent", recommended_answer: "A", confidence: 0.4,
                 weakest: [], rationale: "r", reason: "below"}]}' > "$D/split-q.json"
  jq -n '{questions: [{question: "Which?"}]}' > "$D/turn.json"
  zsh "$CR" emit --issue 2940 --outcome questions-pending --split "$D/split-q.json" \
    --turn "$D/turn.json" --resume /var/tmp/r/refine-2940-resume.json --round 2 > "$D/qp.json"
  jq -c "$conv" "$D/qp.json" > "$D/v.json"
  [ "$(jq -r '"\(.verdict) \(.questions[0].question) \(.resume)"' "$D/v.json")" = "questions-pending Which? /var/tmp/r/refine-2940-resume.json" ]
  check "$(cat "$D/v.json")" refinement
}

# --- AC11: only the root asks ------------------------------------------------

@test "#2940 the questions-pending relay: the root asks, records answers verbatim, and re-dispatches with the same scratch_dir and chained_from" {
  local t; t="$(section "$STEPS" 'The questions-pending relay (#2940)' | tr '\n' ' ' | tr -s ' ')"
  contains "$t" '**Only the root asks the human.**'
  contains "$t" 'A step never asks, neither with AskUserQuestion nor through a side channel such as an OS dialog.'
  contains "$t" 'The root asks the verdict'"'"'s `questions` with AskUserQuestion'
  contains "$t" 'one `{issue, question, answer}` entry. `question` is the pending ask entry'"'"'s `question` text, verbatim.'
  contains "$t" 'with the **same** `scratch_dir` and `chained_from` as the dispatch that returned `questions-pending`, so the refinement finds its `<scratch_dir>/refine-<N>-resume.json` (#2939).'
  contains "$t" 'It dispatches a fresh refinement step: a new dispatch, never a resumed agent.'
}

@test "#2940 the step model replaces §2's in-session rule in a human-started run, and the headless-claude ban still holds" {
  local t; t="$(flat "$STEPS")"
  contains "$t" 'In a human-started run, §2'"'"'s rule that model-driven work stays in-session gives way to this model. The rule against a headless `claude` still holds'
  contains "$t" 'The human follows each step through its `progress.md` and the root'"'"'s status lines.'
}

@test "#2940 both step agents forbid asking, dispatching a step and a headless claude" {
  local issue refine
  # since #3014 the step's procedure is its agent's definition, not the brief
  issue="$(flat "$RSTEP")"
  refine="$(flat "$FSTEP")"
  contains "$issue" 'Never ask the human anything, never dispatch a step, and never launch a headless claude.'
  contains "$(section "$STEPS" 'The issue step (#2940)' | tr '\n' ' ' | tr -s ' ')" 'STEP_HANDOFF=<scratch_dir>/step-<N>-handoff.json'
  contains "$issue" '"<skill-base-dir>/../refine-issue/scripts/chain-result.zsh" read-handoff --file "$STEP_HANDOFF"'
  contains "$issue" 'On its exit 1 or 2, write verdict stopped with the reason "unreadable step handoff" and cause "tooling".'
  contains "$issue" 'When the handoff'"'"'s after is not null, branch with step 1'"'"'s script plus --after <after>.'
  contains "$issue" 'A stopped verdict carries its cause: escalation, clean-stop, tooling or failed.'
  contains "$issue" 'plus the root'"'"'s telemetry flags and its --no-review when given'
  contains "$issue" 'In place of Step 0'"'"'s start, run story-telemetry.zsh start --run-file <scratch_dir>/story-run-<N>.json --parent-run-id <parent_run_id> --origin <origin>'
  contains "$issue" 'move any kept state aside without --resume, deleting nothing, as an attended run does.'
  contains "$issue" 'listing every follow-up issue you filed in follow_ups and your run'"'"'s run_id in run_id.'
  lacks "$issue" 'development/skills/refine-issue/scripts/chain-result.zsh'
  contains "$refine" 'Never ask the human anything.'
  contains "$refine" '/development:refine-issue <N> --chained-from <root> --handoff <scratch_dir>/step-<N>-handoff.json'
  contains "$refine" 'Never dispatch a step, and never launch a headless claude.'
}

# --- the step rules, pinned sentence by sentence ---------------------------------

@test "#2940 chain-steps.md states the step rules: handoff, start_at, verdict handling and the split arms" {
  local t; t="$(flat "$STEPS")"
  local needle
  for needle in \
    'In a human-started run, attended and unattended behave alike, whatever `resolve_session` says (#2907), except for a step'"'"'s clean stop and `deferred` (#3077).' \
    '`scratch_dir` is the root'"'"'s own scratch directory, outside the repository, and every step of the run shares it.' \
    'Before each dispatch the root deletes the issue'"'"'s old verdict file, so it never reads a previous step'"'"'s result as the new one.' \
    '`start_at` is `"0a"` for a first run, a leaf refined `ready` at E1b included. It is `"1"` only for the issue step re-dispatched after a refinement'"'"'s `ready` on an issue whose own step already passed §0a: the single-issue entry, the E3 child and a blocker (#2941).' \
    'The rule against a headless `claude` still holds: a step is an Agent-tool subagent, never a separate `claude` process.' \
    '`done` with the PR.' \
    '`blocked`, with the blockers §0a found.' \
    '`stopped`, with the reason, for any other ending: an escalation, a clean stop, a red gate or a failure. Its `cause` names which, for E3'"'"'s triage:' \
    '`kind` is the step'"'"'s handoff `kind`, `issue` or `refinement`. An issue-run step ends only `done`, `needs-refinement`, `blocked` or `stopped`, a refinement step only `ready`, `split`, `questions-pending` or `stopped`, so the root never holds a verdict it has no arm for. An issue-run step'"'"'s `stopped` must carry its `cause`, a refinement step'"'"'s never does.' \
    '**`done`** → report the PR.' \
    '**`blocked`** → on the named issue'"'"'s step, or a blocker'"'"'s, the root runs the blockers-first procedure' \
    'An E3 child'"'"'s brief never names that line, so the child posted the comment and the label: the root parks the child as E3 parks a dependency rejection' \
    '**`stopped`** → report the reason and stop.' \
    '**`ready`** → the issue is ready to build.' \
    '**A single-issue entry:** dispatch a fresh issue step with `start_at: "1"` and the verdict'"'"'s `risk`.' \
    '**A leaf at E1b:** the leaf is READY for E1b, with the verdict'"'"'s `risk`. Nothing is dispatched for it until E3 builds it.' \
    '**One refinement per issue and reason.** A second `needs-refinement` for the same issue and reason in one run, or a leaf already refined in this run that re-gates `NEEDS_REFINEMENT` at E1b, is never chained again.' \
    '**`--resume` is the exception.** A human-started run given `--resume` does not chain' \
    'A step whose handoff `issue` differs from its `chained_from` is an E3 child'"'"'s run, which §2 parks by terminal (c).' \
    'A refinement step'"'"'s `follow_ups` is always `[]`' \
    '**`split`** → the issue is now a parent.' \
    '**A leaf at E1b:** re-read the tree with E1'"'"'s `read-sub-issues.zsh --tree`, then re-gate every open leaf.' \
    'The root gates its new leaves by E1b'"'"'s rule and builds them as E3 leaves in the same walk, before any child that is `blockedBy` the split child.' \
    '**`questions-pending`** → *The questions-pending relay (#2940)*.' \
    'It appends each answer to the handoff'"'"'s `answers` list as one `{issue, question, answer}` entry.'
  do
    contains "$t" "$needle"
  done
}

@test "#2940 a step's mode is unattended for every mode-keyed branch, even when its resolve_session line says attended" {
  local t issue
  t="$(section "$STEPS" 'The step model (#2940)' | tr '\n' ' ' | tr -s ' ')"
  contains "$t" 'A step resolves its session mode as an E3 child does: §0a'"'"'s `scripts/resolve-session.zsh` with the inferred mode `unattended`, and it stays autonomous whatever the line says, so no step ever asks.'
  contains "$t" '**A step'"'"'s mode is `unattended` for every branch keyed on the mode**, even when the line says `attended`: §0a'"'"'s arms, §3.5'"'"'s extension and suggestion promotion, and the escalation'"'"'s automatic grant and clean stop. **The one exception is §0a'"'"'s kept-state arm without `--resume`:** a step with a null `resume` moves kept state aside as an attended run does, deleting nothing, and never runs `clean-stop.zsh clear`, so it never deletes state a human could still resume.'
  contains "$t" 'It records `session_mode: unattended`, with the line'"'"'s source, or `inferred` when the line says `attended`, and quotes the line it set aside.'
  issue="$(flat "$RSTEP")"
  contains "$issue" 'Your mode is unattended whatever the line says, for every branch keyed on it, the escalation grant and the clean stop included: record session_mode unattended, with the line'"'"'s source, or inferred when the line says attended.'
  contains "$issue" 'Resolve the session mode as an E3 child does (inferred unattended).'
  contains "$issue" 'Unless its resume is "clean_stop", move any kept state aside without --resume, deleting nothing, as an attended run does.'
  lacks "$issue" 'autonomous whatever the line says), but'
  # the record a step's clean stop writes is one the story-record builder accepts
  grep -q 'clean_stop needs an escalated, unattended run' "$REPO_ROOT/development/skills/resolve-issue/scripts/build-story-telemetry-record.zsh"
}

@test "#2940 a leaf refined ready at E1b is built by E3 as a first run: start_at 0a, so §0a's dependency precheck runs" {
  local t; t="$(section "$STEPS" 'The chained refinement step (#2940)' | tr '\n' ' ' | tr -s ' ')"
  contains "$t" '**A leaf at E1b:** the leaf is READY for E1b, with the verdict'"'"'s `risk`. Nothing is dispatched for it until E3 builds it. Its E3 step is a first run, `start_at: "0a"`, so §0a'"'"'s dependency precheck runs; §0b then takes the READY stamp the refinement'"'"'s re-gate left as a cache hit.'
  # "1" is narrowed to the two cases whose own step already passed §0a
  t="$(flat "$STEPS")"
  contains "$t" 'It is `"1"` only for the issue step re-dispatched after a refinement'"'"'s `ready` on an issue whose own step already passed §0a: the single-issue entry, the E3 child and a blocker (#2941).'
  lacks "$t" 'or `"1"` for the fresh step that follows a refinement'"'"'s `ready`'
}

@test "#2940 SKILL.md names the step entry and the stopped arms at E1b and E3" {
  local t; t="$(flat "$SKILL")"
  contains "$t" 'A run whose dispatch brief names a `STEP_HANDOFF` is such a step: see `reference/chain-steps.md` § The step model (#2940)'
  contains "$t" 'A `stopped` refinement takes the halt above, naming each stopped child and its reason.'
  contains "$t" 'An E3 child never prompts or refines. The step, its brief and its verdicts: see `reference/chain-steps.md` § The chained refinement step (#2940)'
  contains "$t" 'In a human-started run each child'"'"'s run is a step the root dispatches (#2940). That covers the sequential chain below as well as the parallel set. Its brief, handoff and verdict: see `reference/chain-steps.md` § The issue step (#2940)'
  t="$(flat "$SKILL_DIR/reference/telemetry.md")"
  contains "$t" '**`--origin` is the run'"'"'s origin (§0a, #2940)**: `human` when a human invoked the skill, `pipeline` for a maintenance-pipeline run, and a step'"'"'s or an E3 child'"'"'s the origin it inherits.'
}

# --- review round 1: the step model's seams ------------------------------------

@test "#2940 an epic's walk mode does not reach a step, and the root triages clean stops in every human-started walk" {
  local t; t="$(flat "$SKILL")"
  contains "$t" 'In a human-started run (#2940) the walk mode does not reach the steps: each child'"'"'s step resolves its own mode (as in `reference/chain-steps.md`), may clean-stop, and the root runs E3'"'"'s triage below.'
  t="$(flat "$STEPS")"
  contains "$t" 'An epic'"'"'s walk mode does not reach a step.'
  t="$(flat "$SKILL_DIR/reference/epic-telemetry.md")"
  contains "$t" 'A human-started walk (#2940) runs the triage whatever its mode, so an attended one counts them too.'
}

@test "#2940 a parallel child's step runs in its own worktree, and a sequential child's step branches off the previous merge" {
  local t; t="$(flat "$STEPS")"
  contains "$t" '**A parallel child'"'"'s step runs in its own worktree.** The root dispatches the step of each child in E3'"'"'s parallel set with the Agent tool'"'"'s `isolation: "worktree"` beside `subagent_type: development:resolve-step`, so each runs in a worktree of its own and their edits can'"'"'t collide. Every other step runs in the root'"'"'s checkout, one at a time.'
  contains "$t" '`after` is `null`, or, for a child of E3'"'"'s sequential chain, the merge commit of the child before it (the PR'"'"'s `mergeCommit.oid`), which the step passes to step 1'"'"'s branch script as `--after`.'
  # the handoff example carries after, and chain-result still reads it
  perl -0ne 'print $1 if /```json\n(\{ "schema": "step-handoff\/v1".*?\})\n```/s' "$STEPS" > "$D/h.json"
  [ "$(jq -c 'has("after") and .after == null' "$D/h.json")" = true ]
}

@test "#2940 an epic root triages a stopped child by its cause and counts it in the matching bucket" {
  local t; t="$(section "$STEPS" 'The issue step (#2940)' | tr '\n' ' ' | tr -s ' ')"
  local needle
  for needle in \
    '`escalation`: a typed escalation other than the clean stop;' \
    '`clean-stop`: #2579'"'"'s clean stop;' \
    '`tooling`: a precheck exit 1, or an exit 2 that recurs after the fixed re-run; a size pre-flight error; an unreadable step handoff;' \
    '`failed`: any other ending `reference/telemetry.md` step 4 records `failed`' \
    'In an epic, triage the child by its `cause`, as E3 triages that ending, and count it in the bucket `reference/epic-telemetry.md` step 3 names:' \
    '`escalation` → as E3 triages an escalation, counted `escalated`;' \
    '`clean-stop` → the same, and the child joins `epic-clean-stop-triage.zsh`'"'"'s `--clean-stopped` list;' \
    '`tooling` → as E3 parks a tooling failure: no label, the reason quoted in the epic summary, counted `parked`;' \
    '`failed` → as E3 treats a child whose run ended `failed` for a cause its triage does not park, counted `queued`.'
  do
    contains "$t" "$needle"
  done
  lacks "$t" 'triage the child as E3 triages an escalation.'
  t="$(arch_section 'Step verdict contract (#2940)' | tr '\n' ' ' | tr -s ' ')"
  contains "$t" 'an issue-run step'"'"'s also carries `cause`: `escalation`, `clean-stop`, `tooling` or `failed`'
}

@test "#2940 a recurrent park posts a fixed 'chained refinement stopped:' body, never the verdict file's reason" {
  local t; t="$(section "$STEPS" 'The chained refinement step (#2940)' | tr '\n' ' ' | tr -s ' ')"
  contains "$t" 'The root takes the `stopped` arm below, but the verdict file holds no refinement'"'"'s `stopped`, so it posts the comment with a fixed body that names the park'"'"'s reason:'
  contains "$t" 'printf '"'"'chained refinement stopped: the %s park recurred after a ready refinement\n'"'"' <gate|size>'
}

@test "#2940 messaging a step to carry on is not a retry; a retry is a new dispatch" {
  local t; t="$(flat "$STEPS")"
  contains "$t" 'That message is not a retry or a recovery: the same agent finishes its own unfinished work, and nothing is run again. Any retry after it is a new dispatch.'
  t="$(flat "$ARCH")"
  contains "$t" 'that message lets the same agent finish its own unfinished work and is not a retry or a recovery, and a retry or a recovery is a new dispatch, never a resumed agent.'
}

@test "#2940 a human-started root stamps only the chain run, and a split makes the chain run the epic run" {
  local t; t="$(flat "$SKILL_DIR/reference/telemetry.md")"
  contains "$t" '**A human-started root stamps no story run (#2940).** When the origin is `human`, the run was not given `--resume`, and its dispatch brief names no `STEP_HANDOFF`, this session is the chain'"'"'s root. It skips this step and step 4, and stamps `chain-run-<N>.json` in their place'
  contains "$t" 'A human-started root emits nothing here (step 2).'
  t="$(flat "$STEPS")"
  contains "$t" 'The root never stamps or emits `story-run-<N>.json`: that file is the issue step'"'"'s'
  contains "$t" '**A single-issue entry that splits.** When a refinement `split`s the named issue, the chain run becomes the epic run. The root stamps no `epic-run-<N>.json`, and uses `chain-run-<N>.json` wherever `reference/epic-telemetry.md` names the epic run file'
  contains "$t" '`child_run_ids` lists only the children'"'"'s runs, in start order, as the epic record'"'"'s contract defines it: the named issue'"'"'s own step runs are not children, and their records reach the run through their `parent_run_id`.'
  lacks "$t" 'lists the named issue'"'"'s own step runs first'
  t="$(flat "$SKILL_DIR/reference/epic-telemetry.md")"
  contains "$t" 'In a human-started run whose single-issue entry a refinement split (#2940), skip this stamp: the root'"'"'s `chain-run-<N>.json` is the epic run file'
  t="$(flat "$ARCH")"
  contains "$t" 'and so is a single-issue root'"'"'s once a refinement splits its issue: the chain run then becomes the epic run.'
}

# --- review round 2 ------------------------------------------------------------

@test "#2940 a refinement other than the relay's re-dispatch starts with no stale resume file" {
  local t; t="$(section "$STEPS" 'The chained refinement step (#2940)' | tr '\n' ' ' | tr -s ' ')"
  contains "$t" '**A first dispatch starts with no resume state.** Before every refinement dispatch other than the questions-pending relay'"'"'s re-dispatch, the root deletes the issue'"'"'s old resume file, so a refinement of an issue refined earlier in the run starts as a first dispatch rather than restoring that refinement'"'"'s state:'
  contains "$t" 'rm -f -- <scratch_dir>/refine-<N>-resume.json'
}

@test "#2940 the issue step's handoff names as many extra fields as its example carries" {
  local t; t="$(flat "$STEPS")"
  contains "$t" 'An issue-run step'"'"'s handoff carries the step-handoff/v1 fields and six more, which a reader that does not read them ignores:'
  perl -0ne 'print $1 if /```json\n(\{ "schema": "step-handoff\/v1".*?\})\n```/s' "$STEPS" > "$D/h.json"
  local n word
  n="$(jq '[keys[] | select(IN("schema","issue","chained_from","origin","scratch_dir","answers") | not)] | length' "$D/h.json")"
  word="$(printf '%s' "$t" | sed -n 's/.*step-handoff\/v1 fields and \([a-z]*\) more,.*/\1/p')"
  local -a words=(zero one two three four five six seven eight nine)
  [ "${words[$n]}" = "$word" ]
}

# --- #3014: the steps are the plugin's own agents -----------------------------

# One frontmatter field of an agent file: the value after `<key>: `.
fm() { awk -v k="$2" 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { exit } f && index($0, k ": ") == 1 { print substr($0, length(k) + 3) }' "$1"; }

@test "#3014 the plugin ships resolve-step and refine-step, each pinning its name, model and tools" {
  [ "$(fm "$RSTEP" name)" = resolve-step ]
  [ "$(fm "$FSTEP" name)" = refine-step ]
  [ "$(fm "$RSTEP" model)" = opus ]
  [ "$(fm "$FSTEP" model)" = opus ]
  # both run a skill that dispatches subagents and runs scripts
  local a tool
  for a in "$RSTEP" "$FSTEP"; do
    [ -n "$(fm "$a" description)" ]
    for tool in Agent Skill Read Write Bash; do
      printf '%s\n' "$(fm "$a" tools)" | tr ',' '\n' | tr -d ' ' | grep -qxF "$tool"
    done
  done
  # the issue step implements the story, so it edits files
  printf '%s\n' "$(fm "$RSTEP" tools)" | tr ',' '\n' | tr -d ' ' | grep -qxF Edit
  # the issue step waits on the gate and its background round dispatches with Monitor (core.md, subagents.md)
  printf '%s\n' "$(fm "$RSTEP" tools)" | tr ',' '\n' | tr -d ' ' | grep -qxF Monitor
  # the refinement step waits on a background readiness gate or issue-refiner with Monitor
  printf '%s\n' "$(fm "$FSTEP" tools)" | tr ',' '\n' | tr -d ' ' | grep -qxF Monitor
}

@test "#3014 chain-steps.md dispatches each step as its plugin agent and never as general-purpose" {
  run grep -c 'general-purpose' "$STEPS"
  [ "$output" = 0 ]
  local t
  t="$(section "$STEPS" 'The step model (#2940)' | tr '\n' ' ' | tr -s ' ')"
  contains "$t" '`subagent_type: development:resolve-step` for an issue-run step, `subagent_type: development:refine-step` for a chained refinement.'
  contains "$t" 'Each agent'"'"'s definition carries the step'"'"'s whole contract and pins its model and tools, so the brief names only what differs between steps.'
  contains "$t" '`isolation: "worktree"` beside `subagent_type: development:resolve-step`'
  t="$(section "$STEPS" 'The issue step (#2940)' | tr '\n' ' ' | tr -s ' ')"
  contains "$t" 'with `subagent_type: development:resolve-step`. The agent'"'"'s definition (`development/agents/resolve-step.md`) carries the step'"'"'s procedure'
  t="$(section "$STEPS" 'The chained refinement step (#2940)' | tr '\n' ' ' | tr -s ' ')"
  contains "$t" 'with `subagent_type: development:refine-step`. The agent'"'"'s definition (`development/agents/refine-step.md`) carries the step'"'"'s procedure'
  # every path the sections name is a shipped agent file
  [ -f "$RSTEP" ]
  [ -f "$FSTEP" ]
  t="$(flat "$ARCH")"
  contains "$t" 'Each step is dispatched as its own plugin agent (#3014): `development:resolve-step` for an issue-run step and `development:refine-step` for a chained refinement.'
}

@test "#3014 the briefs are reduced to the handoff and the root's flags" {
  local brief
  # the issue step's brief: the text block of its section, line by line
  brief="$(section "$STEPS" 'The issue step (#2940)' | awk '/^```text$/ { f = 1; next } f && /^```$/ { exit } f')"
  [ "$brief" = "$(printf '%s\n' 'STEP_HANDOFF=<scratch_dir>/step-<N>-handoff.json' 'FLAGS=<the root'"'"'s telemetry flags and its --no-review, when given>' 'BLOCKERS_FIRST=1')" ]
  brief="$(section "$STEPS" 'The chained refinement step (#2940)' | awk '/^```text$/ { f = 1; next } f && /^```$/ { exit } f')"
  [ "$brief" = 'STEP_HANDOFF=<scratch_dir>/step-<N>-handoff.json' ]
  # the procedure the briefs no longer carry is the agents'
  lacks "$(flat "$STEPS")" 'You are a step of a human-started'
  lacks "$(flat "$STEPS")" 'You are a chained refinement step'
  contains "$(flat "$RSTEP")" 'Invoke the development:resolve-issue skill with "<N>" plus the root'"'"'s telemetry flags and its --no-review when given'
  contains "$(flat "$RSTEP")" 'Before you end your turn, write <scratch_dir>/step-<N>-verdict.json (step-verdict/v1, ARCHITECTURE.md *Step verdict contract*)'
}

@test "#3014 the refine-step agent's unreadable-handoff verdict passes the root's verdict check" {
  local doc
  doc="$(perl -0ne 'print $1 if /`(\{"schema": "step-verdict\/v1", "issue": <N>, "verdict": "stopped".*?\})`/s' "$FSTEP")"
  [ -n "$doc" ]
  doc="${doc//<N>/2940}"
  check "$doc" refinement
  # an issue step's stopped would need a cause; a refinement's must not carry one
  lacks "$doc" '"cause"'
}

@test "#3014 the refine-step agent feeds its conversion a saved document and writes a verdict when none is printed" {
  local t; t="$(flat "$FSTEP")"
  contains "$t" 'save that document verbatim to `<scratch_dir>/chain-result-<N>.json` with the Write tool, never through a shell string'
  contains "$t" 'never end it without a verdict file.'
  local doc
  doc="$(perl -0ne 'print $1 if /`(\{"schema": "step-verdict\/v1", "issue": <N>, "verdict": "stopped", "follow_ups": \[\], "reason": "no chain-result document"\})`/s' "$FSTEP")"
  [ -n "$doc" ]
  doc="${doc//<N>/2940}"
  check "$doc" refinement
  lacks "$doc" '"cause"'
}

@test "#3014 the refine-step agent dispatches its skill's subagents in the foreground and waits on a background one" {
  local t; t="$(flat "$FSTEP")"
  contains "$t" 'Dispatch each in the foreground (`run_in_background: false`).'
  contains "$t" 'When one runs in the background anyway, wait for its result in your turn; never end your turn while it runs, and never write the "no chain-result document" verdict before it has ended.'
  contains "$t" 'Wait with one bounded Monitor call, never a Bash poll.'
  contains "$t" 'When the bound expires, the resolve-issue skill'"'"'s `reference/review-loop/subagents.md` rule *A background round dispatch is waited on in-turn* governs the retry; follow it as written.'
  contains "$t" 'Write the "no chain-result document" verdict above only when that rule stops the skill.'
  # the retry sequence is the rule's own: the agent points at it and never restates it
  lacks "$t" 're-dispatch it once'
}

@test "#3014 the resolve-step agent names its brief's lines, waits on its own subagents and points at the verdict arms" {
  local t; t="$(flat "$RSTEP")"
  contains "$t" '`<N>` in its name is the issue you work on.'
  contains "$t" '`FLAGS=<flags>`, only when the root was given any: its telemetry flags and its `--no-review`.'
  contains "$t" 'Dispatch each in the foreground (`run_in_background: false`). When one runs in the background, wait for its result in your turn; never end your turn while it runs.'
  contains "$t" 'Wait with one bounded Monitor call, never a Bash poll.'
  contains "$t" 'When the bound expires, the resolve-issue skill'"'"'s `reference/review-loop/subagents.md` rule *A background round dispatch is waited on in-turn* governs the retry; follow it as written.'
  contains "$t" 'Write a stopped verdict, cause tooling, only when that rule stops the run.'
  # the retry sequence is the rule's own: the agent points at it and never restates it
  lacks "$t" 're-dispatch it once'
  contains "$t" 'Which verdict each ending writes is `reference/chain-steps.md` § The issue step (#2940).'
  # the section it points at exists
  grep -qxF '## The issue step (#2940)' "$STEPS"
  t="$(flat "$STEPS")"
  contains "$t" 'The root dispatches a chained refinement step with `subagent_type: development:refine-step`.'
}

# --- #3077: what a step hands back to its root ----------------------------------

# The step's escalation builder, as escalation.md states it: the jq filter
# between `--slurpfile c <scratch_dir>/step-<N>-convergence.json '` and
# `' > <scratch_dir>/step-<N>-escalation.json`.
ESC_REL=development/skills/resolve-issue/reference/escalation.md
escalation_filter() {
  local ESC="$REPO_ROOT/$ESC_REL"
  perl -0ne "print \$1 if /--slurpfile c <scratch_dir>\\/step-<N>-convergence\\.json '(.*?)' > <scratch_dir>\\/step-<N>-escalation\\.json/s" "$ESC"
}

@test "#3077 the verdict check accepts a clean stop's escalation and a deferred set on an issue step" {
  local d='{"suggested_follow_ups": [{"title": "split the helper", "body": "named in round 2"}]}'
  check "$(v stopped "$(jq -cn --argjson e "$(esc)" --argjson d "$d" '{reason: "r", cause: "clean-stop", escalation: $e, deferred: $d}')")"
  check "$(v done "$(jq -cn --argjson d "$d" '{pr: 3010, deferred: $d}')")"
  check "$(v done '{"pr": 3010, "deferred": {"suggested_follow_ups": []}}')"
  check "$(v stopped "$(jq -cn --argjson e "$(esc '.trend = null | .proposal.guidance = null | .proposal.recommend = "grant" | .status = "ESCALATE_NO_CONVERGENCE"')" '{reason: "r", cause: "clean-stop", escalation: $e}')")"
}

@test "#3077 the verdict check refuses a clean stop without its payload, a misplaced or malformed payload, and a malformed deferred set" {
  refuse() {  # <issue|refinement> <doc>
    run check "$2" "$1"
    [ "$status" -eq 1 ] || { echo "accepted or broke on ($1): $2 (status $status)"; return 1; }
  }
  clean() { v stopped "$(jq -cn --argjson e "$(esc "$1")" '{reason: "r", cause: "clean-stop", escalation: $e}')"; }
  local doc
  for doc in \
    "$(v stopped '{"reason": "r", "cause": "clean-stop"}')" \
    "$(v stopped '{"reason": "r", "cause": "clean-stop", "escalation": null}')" \
    "$(v stopped "$(jq -cn --argjson e "$(esc)" '{reason: "r", cause: "escalation", escalation: $e}')")" \
    "$(v done "$(jq -cn --argjson e "$(esc)" '{pr: 1, escalation: $e}')")" \
    "$(clean '.status = "ESCALATE_CONFLICT"')" \
    "$(clean '.trigger = []')" \
    "$(clean '.trigger = "stuck"')" \
    "$(clean '.trend = "falling"')" \
    "$(clean '.carried_blockers = [3]')" \
    "$(clean '.proposal.recommend = "stop"')" \
    "$(clean '.proposal.add = 0')" \
    "$(clean '.proposal.guidance = 7')" \
    "$(clean 'del(.proposal)')" \
    "$(clean '.work_dir = "work-dir"')" \
    "$(clean 'del(.status_file)')" \
    "$(v done '{"pr": 1, "deferred": []}')" \
    "$(v done '{"pr": 1, "deferred": {}}')" \
    "$(v done '{"pr": 1, "deferred": {"suggestions": []}}')" \
    "$(v done '{"pr": 1, "deferred": {"suggestions": [], "suggested_follow_ups": []}}')" \
    "$(v done '{"pr": 1, "deferred": {"suggestions": [{"file": "a", "line": 1, "dimension": "d", "title": "t"}], "suggested_follow_ups": []}}')" \
    "$(v done '{"pr": 1, "deferred": {"suggested_follow_ups": [], "other": 1}}')" \
    "$(v done '{"pr": 1, "deferred": {"suggested_follow_ups": [{"title": "t"}]}}')" \
    "$(v done '{"pr": 1, "deferred": {"suggested_follow_ups": [{"title": " ", "body": "b"}]}}')" \
    "$(v done '{"pr": 1, "deferred": {"suggested_follow_ups": ["t"]}}')"
  do
    refuse issue "$doc"
  done
  # a refinement step's verdict carries neither field
  refuse refinement "$(v ready '{"risk": "normal", "auto_accepted": [], "deferred": {"suggested_follow_ups": []}}')"
  refuse refinement "$(v stopped "$(jq -cn --argjson e "$(esc)" '{reason: "r", escalation: $e}')")"
}

@test "#3077 the documented escalation builder turns a marker, a status file and a verdict into a payload the check accepts" {
  local f; f="$(escalation_filter)"
  [ -n "$f" ]
  jq -n '{schema: "clean-stop/v1", issue: 2940, branch: "feat/2940-x", status: "ESCALATE_NO_CONVERGENCE",
    work_dir: "/h/r/2940/work-dir", status_file: "/h/r/2940/status.json", last_round: 5, ceiling: 5,
    convergence_failures: ["trend", "stuck"], run_id: "resolve-issue-1-abcd"}' > "$D/marker.json"
  jq -n '{round_changelists: [
      {blocking: [{title: "old", file: "a", line: 1, dimension: "d", severity: "WARNING"}]},
      {blocking: [
        {title: "carried", file: "b.zsh", line: 9, dimension: "tests", priority: "WARNING", non_converging: true, suggested_fix: "assert the exit"},
        {title: "false trip", file: "c", line: 2, dimension: "d", severity: "WARNING", non_converging: true, possible_false_trip: true, suggested_fix: "x"},
        {title: "fresh", file: "e", line: 3, dimension: "d", priority: "CRITICAL", non_converging: false}]}]}' > "$D/status.json"
  jq -n '{converging: false, failures: ["trend", "stuck"], series: [1, 3], trend: "regressing"}' > "$D/conv.json"
  run --separate-stderr jq -n --slurpfile m "$D/marker.json" --slurpfile s "$D/status.json" --slurpfile c "$D/conv.json" "$f"
  [ "$status" -eq 0 ]
  local e="$output"
  [ "$(jq -c '.trigger' <<< "$e")" = '["trend","stuck"]' ]
  [ "$(jq -r '.status, .trend, .work_dir, .status_file' <<< "$e" | tr '\n' ' ')" = "ESCALATE_NO_CONVERGENCE regressing /h/r/2940/work-dir /h/r/2940/status.json " ]
  # only the last round's carried blockers that are not flagged false trips
  [ "$(jq -r '[.carried_blockers[].title] | join(",")' <<< "$e")" = "carried" ]
  [ "$(jq -r '.carried_blockers[0] | [.severity, .file, .line, .suggested_fix] | join(" ")' <<< "$e")" = "WARNING b.zsh 9 assert the exit" ]
  [ "$(jq -r '.proposal.recommend' <<< "$e")" = "guidance" ]
  [ "$(jq -r '.proposal.add' <<< "$e")" = "3" ]
  [ "$(jq -r '.proposal.guidance' <<< "$e")" = '- carried (`b.zsh:9`): assert the exit' ]
  check "$(v stopped "$(jq -cn --argjson e "$e" '{reason: "r", cause: "clean-stop", escalation: $e}')")"
  # a passing verdict (the automatic grant hit its cap) recommends the grant
  # on BUDGET_EXHAUSTED only; no suggested fix leaves no draft guidance
  jq '.converging = true' "$D/conv.json" > "$D/conv2.json"
  run --separate-stderr jq -n --slurpfile m "$D/marker.json" --slurpfile s "$D/status.json" --slurpfile c "$D/conv2.json" "$f"
  [ "$(jq -r '.proposal.recommend' <<< "$output")" = "guidance" ]
  jq '.status = "BUDGET_EXHAUSTED"' "$D/marker.json" > "$D/marker2.json"
  jq '(.round_changelists[-1].blocking[] | select(.title == "carried")) |= del(.suggested_fix)' "$D/status.json" > "$D/status2.json"
  run --separate-stderr jq -n --slurpfile m "$D/marker2.json" --slurpfile s "$D/status2.json" --slurpfile c "$D/conv2.json" "$f"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.proposal.recommend' <<< "$output")" = "grant" ]
  [ "$(jq -r '.proposal.guidance' <<< "$output")" = "null" ]
  run --separate-stderr jq -n --slurpfile m "$D/marker2.json" --slurpfile s "$D/status.json" --slurpfile c "$D/conv.json" "$f"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.proposal.recommend' <<< "$output")" = "guidance" ]
  # a status with no rounds carries no blockers rather than failing
  echo '{}' > "$D/status3.json"
  run --separate-stderr jq -n --slurpfile m "$D/marker.json" --slurpfile s "$D/status3.json" --slurpfile c "$D/conv.json" "$f"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.carried_blockers' <<< "$output")" = "[]" ]
}

@test "#3077 an attended root runs the extension on a step's clean stop and re-dispatches it to resume on a grant; only Stop takes the stopped arm" {
  local t; t="$(flat "$REPO_ROOT/$ESC_REL")"
  local needle
  for needle in \
    '**A chain step'"'"'s clean stop goes up to its root (#3077).**' \
    'The step itself never asks: its root does, when the root is attended.' \
    'That is its root mode, as `reference/chain-steps.md` § The step model (#2940) defines it, never an epic'"'"'s walk mode.' \
    'An attended root runs the interactive extension (`reference/interactive/extension.md`) on the step'"'"'s kept state, with the same options and recommendation as a direct attended run:' \
    'Ask the extension'"'"'s step 2 question with AskUserQuestion, marking `proposal.recommend`'"'"'s option recommended.' \
    'A non-null `proposal.guidance` is offered as the draft guidance.' \
    '`record-grant.zsh --work-dir <escalation.work_dir> --status <escalation.status_file> --add 3`.' \
    '`start_at: "0a"`, `after: null` and `resume: "clean_stop"`, and dispatch a fresh issue step.' \
    'so a second clean stop comes back here.' \
    'Only **Stop** ends the step: the root then takes the `stopped` arm, as an unattended root does.' \
    '"<skill-base-dir>/scripts/build-escalation.zsh" --status <the marker'"'"'s status_file> \ --format verdict --work-dir <the marker'"'"'s work_dir> > <scratch_dir>/step-<N>-convergence.json' \
    'On a grant, post any guidance as step 4 says, then record it:' \
    '**The step builds the payload** after the marker is written, from the marker (the `marker` path `clean-stop.zsh dir` prints),' \
    '`trigger` is the marker'"'"'s `convergence_failures`.' \
    '`proposal.recommend` is the option a direct attended run recommends: `grant` only on `BUDGET_EXHAUSTED` when the convergence verdict passes' \
    'It runs `clean-stop.zsh read --repo-dir <worktree> --issue <N> --mode attended`, since the root'"'"'s human made the grant, and its exit 3 or 4 ends the step `stopped` with cause `tooling`. It moves no kept state aside.' \
    'and `--max-rounds` set to the ceiling in `<work_dir>/.max-rounds`.' \
    'Its mode stays `unattended` for everything after, so a second failure takes the automatic grant or the clean stop again.' \
    '**The re-dispatched step resumes the kept clean stop** in place of a fresh run, as §0a'"'"'s `--resume` arm does.' \
    '`proposal.guidance` drafts guidance from the carried blockers'"'"' suggested fixes, `null` when none has one.' \
    'Show `build-escalation.zsh --status <escalation.status_file> --format summary --grants <grants>`, where `grants` counts this issue'"'"'s grants in this run, starting at 0.' \
    'A question the human asks is answered and the question re-asked, as step 3 says.' \
    'Remove the `needs-human-decision` label the clean stop added, delete the step'"'"'s old verdict file, write a fresh handoff for the same issue with the same `scratch_dir`, `chained_from` and `parent_run_id`,' \
    'It notes `resumed_from: clean_stop`, runs §0a'"'"'s precheck, checks out the marker'"'"'s `branch` from `origin`, runs §1b, skips §0b, §1, §2 and §3, and records `gate_verdict: READY`.' \
    'Then it continues at the extension'"'"'s step 5 (`reference/interactive/extension-grant.md`), with the grant already recorded and any guidance already posted:'
  do
    contains "$t" "$needle"
  done
  # chain-steps.md routes the clean stop and the resume handoff there
  t="$(section "$STEPS" 'The issue step (#2940)' | tr '\n' ' ' | tr -s ' ')"
  contains "$t" '**`stopped` with cause `clean-stop`, in an attended root (#3077)** → the extension on the step'"'"'s kept state (`reference/escalation.md`); only **Stop** takes the `stopped` arm below, as an unattended root does.'
  t="$(section "$STEPS" 'The step model (#2940)' | tr '\n' ' ' | tr -s ' ')"
  contains "$t" '`resume` is `null`, or `"clean_stop"` on a step an attended root re-dispatches to resume a granted clean stop (`reference/escalation.md`, #3077).'
  contains "$t" 'attended and unattended behave alike, whatever `resolve_session` says (#2907), except for a step'"'"'s clean stop and `deferred` (#3077).'
  contains "$t" 'Those two read only the **root mode**, which the root resolves before its first dispatch with `scripts/resolve-session.zsh --inferred attended`, never an epic'"'"'s walk mode.'
}

@test "#3077 an unattended root treats a step's clean stop as it always did" {
  local t; t="$(flat "$REPO_ROOT/$ESC_REL")"
  contains "$t" 'An unattended root takes the `stopped` arm as before: a single-issue root stops, an epic root triages the child by its cause and continues E3.'
  t="$(section "$STEPS" 'The issue step (#2940)' | tr '\n' ' ' | tr -s ' ')"
  # the stopped arm itself still stops and still triages a clean-stopped child
  contains "$t" '**`stopped`** → report the reason and stop.'
  contains "$t" '`clean-stop` → the same, and the child joins `epic-clean-stop-triage.zsh`'"'"'s `--clean-stopped` list;'
}

@test "#3077 a step's deferred follow-ups are offered once by an attended root, filed by an unattended one, never dropped" {
  local t; t="$(section "$SKILL_DIR/reference/chain-steps/deferred-follow-ups.md" "A step's deferred follow-ups (#3077)" | tr '\n' ' ' | tr -s ' ')"
  [ -n "$t" ]
  local needle
  for needle in \
    'A step of a human-started run never asks.' \
    'Its verdict carries `deferred` instead, on any verdict of a run whose review loop ran: `suggested_follow_ups`, each `{title, body}`, for every follow-up the run would otherwise name only in prose without filing it.' \
    'A suggestion the run waived is not handed back: it stays waived.' \
    'The root mode is the one the root resolved before its first dispatch with `scripts/resolve-session.zsh --inferred attended`, never a step'"'"'s own mode.' \
    'On a clean stop it asks after the extension'"'"'s answer, Stop included.' \
    'On a grant it asks about this verdict'"'"'s items before it deletes the verdict file and re-dispatches, and asks about the re-dispatched step'"'"'s verdict only for the items not in that answered list: the step resumes on the same status file, so its verdict names the earlier items again.' \
    '**Each filed item** is read from the step'"'"'s verdict file, never retyped, so no shell expands its title.' \
    '`<k>` is the item'"'"'s 0-based index, its list number minus one.' \
    'passed as one argument, which exits non-zero, so nothing is filed, when no item has that index; its finding is' \
    'It becomes an issue, `gh issue create --title <title> --body-file <file>`, whose body is the item'"'"'s `body`, read the same way, and names the step'"'"'s issue and its PR when there is one, and is queued like a listed follow-up:' \
    'It is `[]` when there are none, and a follow-up the run filed goes in `follow_ups`, never here.' \
    'The root handles them by its root mode (`reference/chain-steps.md` § The step model (#2940)) before the verdict'"'"'s own arm, except on an attended clean stop:' \
    '**An attended root asks once per step.**' \
    'one question with AskUserQuestion: **File all** · **File none**, with "Other" taking the numbers to file.' \
    'an `intent` question under ARCHITECTURE.md'"'"'s *Decision rights*, so it is asked and never decided for the human.' \
    '**An unattended root files every suggested follow-up.**' \
    '`chain-queue.zsh add --entry <new> --kind follow-up --after <the entry that filed it>` (for an E3 child, its epic-kind entry), as the chain queue'"'"'s step 2 adds and stops on its exits,' \
    'Nothing in `deferred` is dropped without the human'"'"'s answer.'
  do
    contains "$t" "$needle"
  done
  # the dropped option and the suggestion half are gone
  lacks "$t" 'File the suggested follow-ups only'
  lacks "$t" 'suggestions-enabled.zsh'
  # the queued finding for a suggested follow-up is one chain-queue accepts
  local q="$REPO_ROOT/development/skills/resolve-issue/scripts/chain-queue.zsh" f
  f="$(printf '%s' "$t" | sed -n 's/.*with `--finding` `\({"file": "follow-up", "line": null, "dimension": "follow-up", "title": \)<its title>}`.*/\1"split the helper"}/p')"
  [ -n "$f" ]
  jq -e . <<< "$f" >/dev/null
  mkdir -p "$D/repo"
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  git -C "$D/repo" init -q
  git -C "$D/repo" remote add origin https://github.com/o/r.git
  run --separate-stderr zsh "$q" add --repo-dir "$D/repo" --issue 2940 --entry 2940 --kind named
  [ "$status" -eq 0 ]
  run --separate-stderr zsh "$q" add --repo-dir "$D/repo" --issue 2940 --entry 3030 --kind follow-up --after 2940 --finding "$f"
  [ "$status" -eq 0 ]
  # the title and finding are read from the verdict with jq, so a title with quotes and backticks survives
  local tf ff vf="$D/verdict.json" hostile='split the `helper` "now"'
  tf="$(printf '%s' "$t" | sed -n 's/.*title is `jq -er --argjson i <k> '"'"'\([^'"'"']*\)'"'"' <verdict>`.*/\1/p')"
  ff="$(printf '%s' "$t" | sed -n 's/.*; its finding is `jq -c --argjson i <k> '"'"'\([^'"'"']*\)'"'"' <verdict>`.*/\1/p')"
  [ -n "$tf" ]
  [ -n "$ff" ]
  jq -n --arg t "$hostile" '{deferred: {suggested_follow_ups: [{title: "a", body: "b"}, {title: $t, body: "c"}]}}' > "$vf"
  [ "$(jq -r --argjson i 1 "$tf" "$vf")" = "$hostile" ]
  # an index past the end (a list number passed as written) stops before any issue is filed
  run jq -er --argjson i 2 "$tf" "$vf"
  [ "$status" -ne 0 ]
  f="$(jq -c --argjson i 1 "$ff" "$vf")"
  jq -e --arg t "$hostile" '. == {file: "follow-up", line: null, dimension: "follow-up", title: $t}' <<< "$f" >/dev/null
  run --separate-stderr zsh "$q" add --repo-dir "$D/repo" --issue 2940 --entry 3031 --kind follow-up --after 2940 --finding "$f"
  [ "$status" -eq 0 ]
  # a grant asks about the first list before escalation.md's step 3 deletes the verdict file
  local e; e="$(flat "$REPO_ROOT/$ESC_REL")"
  contains "$e" 'Ask about this verdict'"'"'s `deferred` follow-ups before the verdict file goes (`reference/chain-steps/deferred-follow-ups.md` § A step'"'"'s deferred follow-ups (#3077)). Remove the `needs-human-decision` label'
  # chain-steps.md routes the root there before every verdict arm
  t="$(flat "$STEPS")"
  contains "$t" 'and has handled its `deferred` follow-ups (#3077): see `reference/chain-steps/deferred-follow-ups.md` § A step'"'"'s deferred follow-ups (#3077)'
  # the section has one home: chain-steps.md routes there and no longer carries it
  lacks "$t" '**An attended root asks once per step.**'
}

@test "#3077 the resolve-step agent hands escalation and deferred back and never asks" {
  local t; t="$(flat "$RSTEP")"
  contains "$t" 'A clean stop'"'"'s verdict also carries escalation, its payload, and a run whose review loop ran also carries deferred'
  contains "$t" 'They are how the root, not you, puts those choices to the human (#3077).'
  contains "$t" 'carries deferred: every follow-up it would otherwise name only in prose. A suggestion it waived stays waived and is not handed back. Build them as reference/escalation.md and reference/chain-steps.md say.'
  contains "$t" 'When its resume is "clean_stop", resume the kept clean stop the root granted more rounds on'
  contains "$t" 'Never ask the human anything'
  lacks "$t" 'AskUserQuestion'
  t="$(arch_section 'Step verdict contract (#2940)' | tr '\n' ' ' | tr -s ' ')"
  contains "$t" 'escalation, on a stopped verdict with cause clean-stop and on no other, is the clean stop'"'"'s payload'
  contains "$t" 'A refinement step'"'"'s verdict carries neither.'
  contains "$t" 'deferred, on any verdict of a run whose review loop ran, holds suggested_follow_ups ({title, body} each) and no other key: a suggestion the run waived stays waived and is not handed back.'
  contains "$t" 'An unattended root files every suggested follow-up.'
  lacks "$t" 'and no suggestion'
}
