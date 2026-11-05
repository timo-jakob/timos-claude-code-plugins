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
# between `jq -e -s --argjson n <N> '` and `' <scratch_dir>/step-<N>-verdict.json`.
verdict_filter() {
  perl -0ne "print \$1 if /jq -e -s --argjson n <N> '(length == 1 and .*?)' <scratch_dir>\\/step-<N>-verdict\\.json/s" "$STEPS"
}

# The refinement step's conversion of a chain-result/v1 document to a verdict.
convert_filter() {
  perl -0ne "print \$1 if /jq '(\\{schema: \"step-verdict\\/v1\".*?)' > <scratch_dir>/s" "$STEPS"
}

check() {  # <verdict json> -> exit status of the documented check
  local f; f="$(verdict_filter)"
  [ -n "$f" ] || { echo "could not extract the verdict check from $STEPS" >&2; return 99; }
  printf '%s' "$1" | jq -e -s --argjson n 2940 "$f" >/dev/null
}

v() {  # <verdict> <jq object of extra fields> -> a verdict document
  jq -cn --arg v "$1" --argjson x "$2" \
    '{schema: "step-verdict/v1", issue: 2940, verdict: $v, follow_ups: []} + $x'
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
  check "$(v ready '{"risk": "elevated", "auto_accepted": []}')"
  check "$(v split '{"children": [{"index": 1, "issue": 3011, "linked": true}]}')"
  check "$(v blocked '{"blockers": [2941]}')"
  check "$(v questions-pending '{"questions": [{"question": "q?"}], "resume": "/s/refine-2940-resume.json", "round": 1}')"
  check "$(v stopped '{"reason": "no convergence within the round cap"}')"
  # an issue-run step's run_id, a string or null, and filed follow-ups
  check "$(v done '{"pr": 3010, "run_id": "resolve-issue-1-abcd", "follow_ups": [3020]}')"
  check "$(v stopped '{"reason": "unreadable step handoff", "run_id": null}')"
}

@test "#2940 the documented verdict check refuses an unknown value, a missing field and a wrong schema" {
  # jq -e exits 1 on a false result; 99 (no filter extracted) or 3 (a syntax
  # error) would be the check breaking, never a refusal
  local doc
  for doc in \
    "$(v merged '{"pr": 1}')" \
    "$(v done '{}')" \
    "$(v needs-refinement '{"reason": "x"}')" \
    "$(v ready '{"risk": "high", "auto_accepted": []}')" \
    "$(v ready '{"risk": "normal", "auto_accepted": null}')" \
    "$(v split '{"children": []}')" \
    "$(v blocked '{}')" \
    "$(v questions-pending '{"questions": [], "resume": "/s/r.json", "round": 1}')" \
    "$(v questions-pending '{"questions": [{"question": "q?"}], "round": 1}')" \
    "$(v questions-pending '{"questions": [{"question": "q?"}], "resume": "/s/r.json"}')" \
    "$(v stopped '{"reason": ""}')" \
    "$(v stopped '{"reason": "   "}')" \
    "$(v done '{"pr": 1, "follow_ups": ["x"]}')" \
    "$(v done '{"pr": 1, "follow_ups": [0]}')" \
    "$(v done '{"pr": 1, "run_id": 7}')" \
    "$(jq -c '.issue = "2940"' <<< "$(v done '{"pr": 1}')")" \
    "$(jq -c '.issue = 2941' <<< "$(v done '{"pr": 1}')")" \
    "$(jq -c 'del(.follow_ups)' <<< "$(v done '{"pr": 1}')")" \
    "$(jq -c '.schema = "step-verdict/v2"' <<< "$(v done '{"pr": 1}')")" \
    "$(v done '{"pr": 1}')$(v done '{"pr": 2}')"
  do
    run check "$doc"
    [ "$status" -eq 1 ] || { echo "accepted or broke on: $doc (status $status)"; return 1; }
  done
}

@test "#2940 a refinement step's verdict is its chain-result outcome, converted as documented and accepted by the check" {
  local conv; conv="$(convert_filter)"
  [ -n "$conv" ]
  # ready
  zsh "$CR" emit --issue 2940 --outcome ready --risk normal > "$D/ready.json"
  jq -c "$conv" "$D/ready.json" > "$D/v.json"
  [ "$(jq -r '"\(.verdict) \(.risk) \(.auto_accepted | length)"' "$D/v.json")" = "ready normal 0" ]
  check "$(cat "$D/v.json")"
  # split
  printf '[{"index":1,"issue":3011,"linked":true}]' > "$D/children.json"
  zsh "$CR" emit --issue 2940 --outcome split --children "$D/children.json" > "$D/split.json"
  jq -c "$conv" "$D/split.json" > "$D/v.json"
  [ "$(jq -r '"\(.verdict) \(.children[0].issue)"' "$D/v.json")" = "split 3011" ]
  check "$(cat "$D/v.json")"
  # stopped
  zsh "$CR" emit --issue 2940 --outcome stopped --reason "unreadable step handoff" > "$D/stopped.json"
  jq -c "$conv" "$D/stopped.json" > "$D/v.json"
  [ "$(jq -r '"\(.verdict)|\(.reason)|\(.schema)"' "$D/v.json")" = "stopped|unreadable step handoff|step-verdict/v1" ]
  check "$(cat "$D/v.json")"
  # questions-pending
  jq -n '{ask: [{question: "Which?", kind: "intent", recommended_answer: "A", confidence: 0.4,
                 weakest: [], rationale: "r", reason: "below"}]}' > "$D/split-q.json"
  jq -n '{questions: [{question: "Which?"}]}' > "$D/turn.json"
  zsh "$CR" emit --issue 2940 --outcome questions-pending --split "$D/split-q.json" \
    --turn "$D/turn.json" --resume /var/tmp/r/refine-2940-resume.json --round 2 > "$D/qp.json"
  jq -c "$conv" "$D/qp.json" > "$D/v.json"
  [ "$(jq -r '"\(.verdict) \(.questions[0].question) \(.resume)"' "$D/v.json")" = "questions-pending Which? /var/tmp/r/refine-2940-resume.json" ]
  check "$(cat "$D/v.json")"
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

@test "#2940 both step briefs forbid asking, dispatching a step and a headless claude" {
  local issue refine
  issue="$(section "$STEPS" 'The issue step (#2940)' | tr '\n' ' ' | tr -s ' ')"
  refine="$(section "$STEPS" 'The chained refinement step (#2940)' | tr '\n' ' ' | tr -s ' ')"
  contains "$issue" 'Never ask the human anything, never dispatch a step, and never launch a headless claude.'
  contains "$issue" 'STEP_HANDOFF=<scratch_dir>/step-<N>-handoff.json'
  contains "$issue" '"<skill-base-dir>/../refine-issue/scripts/chain-result.zsh" read-handoff --file "$STEP_HANDOFF"'
  contains "$issue" 'On its exit 1 or 2, write verdict stopped with the reason "unreadable step handoff".'
  contains "$issue" 'plus the root'"'"'s telemetry flags and its --no-review when given'
  contains "$issue" 'In place of Step 0'"'"'s start, run story-telemetry.zsh start --run-file <scratch_dir>/story-run-<N>.json --parent-run-id <parent_run_id> --origin <origin>'
  contains "$issue" 'move any kept state aside without --resume, deleting nothing, as an attended run does.'
  contains "$issue" 'listing every follow-up issue you filed in follow_ups and your run'"'"'s run_id in run_id.'
  lacks "$issue" 'development/skills/refine-issue/scripts/chain-result.zsh'
  contains "$refine" 'Never ask the human anything.'
  contains "$refine" '/development:refine-issue <N> --chained-from <root> --handoff <scratch_dir>/step-<N>-handoff.json'
}

# --- the step rules, pinned sentence by sentence ---------------------------------

@test "#2940 chain-steps.md states the step rules: handoff, start_at, verdict handling and the split arms" {
  local t; t="$(flat "$STEPS")"
  local needle
  for needle in \
    'In a human-started run, attended and unattended behave alike, whatever `resolve_session` says (#2907).' \
    '`scratch_dir` is the root'"'"'s own scratch directory, outside the repository, and every step of the run shares it.' \
    'Before each dispatch the root deletes the issue'"'"'s old verdict file, so it never reads a previous step'"'"'s result as the new one.' \
    '`start_at` is `"0a"` for a first run, or `"1"` for the fresh step that follows a refinement'"'"'s `ready`.' \
    'The rule against a headless `claude` still holds: a step is an Agent-tool subagent, never a separate `claude` process.' \
    '`done` with the PR.' \
    '`blocked`, with the blockers §0a found.' \
    '`stopped`, with the reason, for any other ending: an escalation, a clean stop, a red gate or a failure.' \
    '**`done`** → report the PR.' \
    '**`blocked`** → until #2941 lands, the root handles it as §0a'"'"'s autonomous arm handles a rejection: the step already posted the comment and the label, so the root reports the blockers and stops, offering no remediation.' \
    'In an epic, the root parks the child as E3 parks a dependency rejection and continues with the children that don'"'"'t depend on it.' \
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

@test "#2940 SKILL.md names the step entry and the stopped arms at E1b and E3" {
  local t; t="$(flat "$SKILL")"
  contains "$t" 'A run whose dispatch brief names a `STEP_HANDOFF` is such a step: see `reference/chain-steps.md` § The step model (#2940)'
  contains "$t" 'A `stopped` refinement takes the halt above, naming each stopped child and its reason.'
  contains "$t" 'An E3 child never prompts or refines. The step, its brief and its verdicts: see `reference/chain-steps.md` § The chained refinement step (#2940)'
  contains "$t" 'In a human-started run each child'"'"'s run is a step the root dispatches (#2940). That covers the sequential chain below as well as the parallel set. Its brief, handoff and verdict: see `reference/chain-steps.md` § The issue step (#2940)'
  t="$(flat "$SKILL_DIR/reference/telemetry.md")"
  contains "$t" '**`--origin` is the run'"'"'s origin (§0a, #2940)**: `human` when a human invoked the skill, `pipeline` for a maintenance-pipeline run, and a step'"'"'s or an E3 child'"'"'s the origin it inherits.'
}
