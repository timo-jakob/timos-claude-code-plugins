#!/usr/bin/env bats
#
# The instrumented-pipeline inventory (#1232, epic #741 child (g)): the
# user-facing view of which pipelines emit telemetry, what each one's payload
# holds, how nested runs join, and what is not measured.
#
# WHY THE KEY TABLES ARE CHECKED AGAINST THE BUILDERS: the how-to's payload
# tables are the only user-facing statement of each pipeline's keys, and the
# story's criterion is that they match what MERGED, not what was proposed. So
# for every pipeline the documented key set is compared with the key set the
# real payload builder emits for a valid fixture state (states copied from each
# builder's own suite). A key a builder gains or loses reds here until the table
# follows, and a row dropped from or added to a table reds here too.
#
# WHY THE JOIN EXAMPLES ARE EXECUTED: the page promises a runnable query. Each
# bash block in the join section is run against a small all-pipeline fixture
# sink, and its output must equal the json block the page prints after it, so
# the query, its documented output and the fixture can never disagree.
#
# Every comparison is a function taking the page path, so the non-vacuity tests
# at the end run the SAME function over a mutated copy and require it to fail.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"  # the user-level telemetry default stays out of the real ~/.claude (#1972)
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HOWTO="$REPO_ROOT/docs/how-to/read-pipeline-telemetry.md"
  HANDOFF="$REPO_ROOT/docs/reference/telemetry-grafana-handoff.md"
  SINK="$REPO_ROOT/tests/fixtures/telemetry-inventory/all-pipelines.jsonl"
  RI="$REPO_ROOT/development/skills/resolve-issue"
  TLM="$REPO_ROOT/development/scripts/telemetry"
  W="$BATS_TEST_TMPDIR/w"
  mkdir -p "$W"
}

# The lines of the section headed exactly $1 in page $2, up to the next heading
# of the same or a higher level. Lines inside a fenced block are never read as
# headings — a bash comment there starts with `# ` too.
section() {
  awk -v h="$1" '
    /^```/ { fence = !fence }
    !fence && $0 == h { f = 1; match(h, /^#+/); lvl = RLENGTH; next }
    f && !fence && /^#+ / { match($0, /^#+/); if (RLENGTH <= lvl) exit }
    f' "$2"
}

# The keys a payload table documents: the first cell of each `| `key` |` row
# under the `### $1` heading of page $2, sorted.
doc_keys() {
  section "### $1" "$2" | sed -n 's/^| `\([^`]*\)` |.*/\1/p' | LC_ALL=C sort
}

# The payload the real builder emits for a valid fixture state.
builder_payload() {
  local out
  case "$1" in
    review-loop)
      printf '%s' '{"status":"CONVERGED","rounds":2,"max_rounds":3,"repo_type":"python","escalation_reasons":[],"round_changelists":[{"round":1,"blocking":[],"suggestions":[]}],"final_changelist":{"blocking":[]}}' > "$W/rl.json"
      out="$(zsh "$RI/scripts/build-telemetry-record.zsh" --status "$W/rl.json")" ;;
    "review-loop suggestion-promotion enrichment")
      # the payload is built inline by the promotion step, not by a builder
      # script: run that step's own jq expression, read out of the file
      local expr
      expr="$(sed -n "s/.*'\({event:\"suggestion_promotion\"[^']*\)'.*/\1/p" "$RI/reference/promotion/step-3-select.md")"
      [ -n "$expr" ] || { echo "the promotion step's payload expression was not found" >&2; return 1; }
      out="$(jq -nc --argjson offered 2 --argjson promoted 1 "$expr")" ;;
    refine-issue)
      printf '%s' '{"rounds":3,"objections_raised":4,"objections_resolved":4,"outcome":"refined-ready","risk_classification":"low","size_preflight":{"verdict":"pass","triggers":[],"children_filed":0}}' > "$W/rf.json"
      out="$(zsh "$REPO_ROOT/development/skills/refine-issue/scripts/build-refine-telemetry-record.zsh" --state "$W/rf.json")" ;;
    "resolve-issue, story mode")
      printf '%s' '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY","risk":"elevated","pr":413,"story_spec_present":true,"review_loop_run_ids":["review-loop-1752403000-8f3a"],"fallbacks_fired":["user_docs"]}' > "$W/st.json"
      out="$(zsh "$RI/scripts/build-story-telemetry-record.zsh" --state "$W/st.json")" ;;
    "resolve-issue, epic mode")
      printf '%s' '{"outcome":"parked","e1_classification":"halt_undecomposed","children":{"total":0,"completed_before":0,"resolved_this_run":0,"escalated":0,"parked":0,"queued":0}}' > "$W/ep.json"
      out="$(zsh "$RI/scripts/build-epic-telemetry-record.zsh" --state "$W/ep.json")" ;;
    story-preflight)
      printf '%s' '{"verdict":"pass","triggers":[],"files":3,"plugins":1}' > "$W/pf.json"
      out="$(zsh "$RI/scripts/build-story-preflight-telemetry-record.zsh" --state "$W/pf.json")" ;;
    maintenance)
      printf '%s' '{"run_modifiers":{"dry_run":false,"no_merge":false,"batch":3,"tool":null,"concern":null,"no_issues":false,"resumed":false},"resumed_from_run_id":null,"languages":{"detected":["python"],"actionable":["python"]},"topics":["claude-plugin"],"payloads":[{"findings_by_tool":{"ruff":[{"code":"F401"}]}}],"groups_planned":1,"human_action_required":0,"errors":[],"coverage_preflight":{"spawned":false,"languages":[]}}' > "$W/mt.json"
      printf '%s' '{"stage1":{"group":"ruff","pr":214,"ci_fix_count":1,"status":"merged"}}' > "$W/sg.json"
      out="$(zsh "$REPO_ROOT/development/skills/maintenance/scripts/build-maintenance-telemetry-record.zsh" --state "$W/mt.json" --stages "$W/sg.json")" ;;
    bootstrap)
      printf '%s' '{"mode":"fresh","target_repo":"acme/billing","visibility":"private","languages":{"primary":"python","auxiliary":["typescript"]},"topics":["kubernetes"],"interfaces":["rest"],"host":{"os":"macos","homebrew":true},"steps":{"common_artifacts":"written","git_hooks":"written"},"files":[{"path":"README.md","step":"common_artifacts","disposition":"written"},{"path":".git/hooks/pre-commit","step":"git_hooks","disposition":"written"}],"github_state":{"branch_protection":"applied","secrets":"applied","sonar_project":"applied","apps_installed":"already_present"},"stack":"resolved","early_stop":null,"approve_merge":"merged","pr":412}' > "$W/bs.json"
      out="$(zsh "$REPO_ROOT/development/skills/bootstrap/scripts/build-bootstrap-telemetry-record.zsh" --state "$W/bs.json")" ;;
    acceptance)
      printf '%s' '{"id":31877410925,"run_id":9001,"run_attempt":1,"name":"acceptance (cli)","status":"completed","conclusion":"success","head_sha":"4f2c9e1","started_at":"2026-10-04T10:00:00Z","completed_at":"2026-10-04T10:01:14Z"}' > "$W/job.json"
      out="$(zsh "$TLM/build-acceptance-telemetry-record.zsh" --job "$W/job.json" --junit "$REPO_ROOT/tests/fixtures/acceptance-telemetry/junit/pytest-real.xml" --artifact-name acceptance-report-cli --artifact-url "https://api.github.com/repos/o/n/actions/artifacts/7001")" ;;
    approve)
      printf '%s' '{"id":2930481177,"user":{"login":"claude-approver-x[bot]","type":"Bot"},"state":"CHANGES_REQUESTED","submitted_at":"2026-10-04T10:03:34Z","commit_id":"4f2c9e1a0b","body":"ignored"}' > "$W/rv.json"
      printf '%s' '{"approver_version":"v1","language":"python","dimensions":["bugs","security"],"started_at":1791108000,"verdict":"REQUEST_CHANGES","confidence":"LOW","type_detected":"feat","findings":[{"category":"risk","dimension":"security"}]}' > "$W/bl.json"
      out="$(zsh "$TLM/build-approver-telemetry-record.zsh" --review "$W/rv.json" --block "$W/bl.json")" ;;
    *) echo "no builder fixture for: $1" >&2; return 2 ;;
  esac
  [ -n "$out" ] || { echo "the $1 builder emitted nothing" >&2; return 1; }
  printf '%s\n' "$out"
}

# Status 0 when page $2's table for pipeline $1 lists exactly the builder's keys,
# each row's Type cell admits the jq type the builder emitted for it (`integer`
# is jq's number, `array of …` an array, `X or null` either), and a Meaning cell
# that opens with a backticked name names exactly the sub-keys of an emitted
# object: its leading names, read with parentheses dropped and up to the first
# ` — `, `:` or `;`, equal the object's keys.
table_matches_builder() {
  local doc built payload k t m bt named emitted
  doc="$(doc_keys "$1" "$2")"
  payload="$(builder_payload "$1")" || return 2
  built="$(jq -r 'keys[]' <<<"$payload" | LC_ALL=C sort)"
  [ -n "$doc" ] || { echo "no key table under ### $1" >&2; return 1; }
  [ "$doc" = "$built" ] || {
    printf 'payload keys of %s drifted\n--- documented\n%s\n--- emitted\n%s\n' "$1" "$doc" "$built" >&2
    return 1
  }
  while IFS='|' read -r _ k t m _; do
    k="${k//[\` ]/}"; t="$(sed 's/^ *//; s/ *$//; s/`//g; s/integer/number/g; s/array of [a-z]*/array/g; s/ or /|/g' <<<"$t")"
    bt="$(jq -r --arg k "$k" '.[$k] | type' <<<"$payload")"
    [[ "|$t|" == *"|$bt|"* ]] || { echo "$1: \`$k\` is documented as $t, emitted as $bt" >&2; return 1; }
    [ "$bt" = object ] && [[ "${m# }" == '`'* ]] || continue
    named="$(sed 's/ ([^)]*)//g; s/ — .*//; s/[:;].*//' <<<"$m" | grep -o '`[a-z_]*`' | tr -d '`' | LC_ALL=C sort -u)"
    emitted="$(jq -r --arg k "$k" '.[$k] | keys[]' <<<"$payload" | LC_ALL=C sort)"
    [ "$named" = "$emitted" ] || {
      printf '%s: `%s` sub-keys drifted\n--- documented\n%s\n--- emitted\n%s\n' "$1" "$k" "$named" "$emitted" >&2
      return 1
    }
  done < <(section "### $1" "$2" | grep '^| `')
}

# Every payload table the page carries — the heading list itself is pinned, so
# a new table without a builder mapping reds rather than going unchecked.
PAYLOAD_TABLES=(
  "review-loop"
  "review-loop suggestion-promotion enrichment"
  "refine-issue"
  "resolve-issue, story mode"
  "resolve-issue, epic mode"
  "story-preflight"
  "maintenance"
  "bootstrap"
  "acceptance"
  "approve"
)

# The N-th ```<lang> block of section $2 in page $3 ($1 = lang, $4 = N).
nth_block() {
  section "$2" "$3" | awk -v lang="$1" -v n="$4" '
    /^```/ && !in_b { if ($0 == "```" lang) { k++; in_b = 1; next } }
    in_b && /^```$/ { in_b = 0; next }
    in_b && k == n'
}

# Run a page's bash block against the fixture sink: its `S=` line is pointed at
# the fixture, nothing else in it is changed.
run_block_on_fixture() {
  local block="$1"
  printf '%s\n' "$block" | sed "s#^S=.*#S='$SINK'#" > "$W/block.sh"
  bash "$W/block.sh"
}

# Status 0 when join example $2 (1 or 2) of page $1, run on the fixture, prints
# exactly the json block the page shows after it.
join_example_holds() {
  local sect='## Join nested runs through `parent_run_id`' code want got
  code="$(nth_block bash "$sect" "$1" "$2")"
  want="$(nth_block json "$sect" "$1" "$2")"
  [ -n "$code" ] && [ -n "$want" ] || { echo "join example $2 not found" >&2; return 1; }
  got="$(run_block_on_fixture "$code")" || { echo "join example $2 did not run" >&2; return 1; }
  [ "$got" = "$want" ] || { printf 'join example %s\n--- documented\n%s\n--- actual\n%s\n' "$2" "$want" "$got" >&2; return 1; }
}

# ------------------------------------------------------------- the fixture sink

@test "the fixture sink is valid telemetry/v1 and holds every instrumented pipeline" {
  run zsh "$TLM/validate-telemetry.zsh" --require-records "$SINK"
  [ "$status" -eq 0 ]
  local pipelines
  pipelines="$(jq -r '.pipeline' "$SINK" | LC_ALL=C sort -u | tr '\n' ' ')"
  [ "$pipelines" = "acceptance approve bootstrap maintenance refine-issue resolve-issue review-loop story-preflight " ]
}

# ------------------------------------------------------------- inventory (AC1)

@test "the inventory lists every pipeline of the epic, each marked instrumented" {
  local inv row
  inv="$(section '## Which pipelines are instrumented' "$HOWTO")"
  [ -n "$inv" ]
  # each row pinned whole: its trigger and its issue / pr / parent_run_id linkage
  # cells are what a reader joins on
  for row in \
    '| review loop (`review-loop`) | instrumented | each terminal exit of a review loop — never per round, and never on a resumable pause | the story | `null` | the resolve-issue run it ran under, else `null` | [review-loop](#review-loop) |' \
    '| `/development:refine-issue` (`refine-issue`) | instrumented | each single-issue refinement ends — an epic walk appends one per child | the issue | `null` | `null` | [refine-issue](#refine-issue) |' \
    '| `/development:resolve-issue`, story mode (`resolve-issue`, `payload.mode: "story"`) | instrumented | a single-issue run that reached the dependency precheck ends | the story | the opened PR, else `null` | the epic run for an epic'"'"'s child, else `null` | [story mode](#resolve-issue-story-mode) |' \
    '| `/development:resolve-issue`, epic mode (`resolve-issue`, `payload.mode: "epic"`) | instrumented | each Epic-flow invocation ends — one record per invocation, not per epic | the epic | `null` | `null` | [epic mode](#resolve-issue-epic-mode) |' \
    '| `/development:maintenance` (`maintenance`) | instrumented | an invocation that passed the proceed/halt gate reaches its summary phase | `null` | `null` — its PRs are in the payload | `null` | [maintenance](#maintenance) |' \
    '| `/development:bootstrap` (`bootstrap`) | instrumented | every invocation, at whichever ending it reaches | `null` | the PR the run opened, else `null` | `null` | [bootstrap](#bootstrap) |' \
    '| acceptance stage (`acceptance`) | instrumented | you run `collect-acceptance-telemetry.zsh`: one record per completed `acceptance (<interface>)` check run attempt of the last 30 days | `null` | the run'"'"'s PR | `null` | [acceptance](#acceptance) |' \
    '| Approver (`approve`) | instrumented | you run `collect-approver-telemetry.zsh`: one record per posted Approver review carrying its findings block, on PRs updated in the last 30 days | `null` | the reviewed PR | `null` | [approve](#approve) |'; do
    contains "$inv" "$row"
  done
  # exactly those eight rows: a ninth pipeline row, or one marked anything but
  # instrumented / not instrumented, reds
  [ "$(grep -c '^| .* | instrumented |' <<<"$inv")" -eq 8 ]
  [ "$(grep -c '^| .* | \(not \)\{0,1\}instrumented |' <<<"$inv")" -eq 8 ]
  contains "$(tr -s '[:space:]' ' ' <<<"$inv")" "Every pipeline of the instrumentation epic is **instrumented**; none was deferred."
}

@test "every inventory row's payload link names a payload table on the page" {
  local inv anchors a heading found
  inv="$(section '## Which pipelines are instrumented' "$HOWTO")"
  anchors="$(grep -o '](#[a-z0-9_-]*)' <<<"$inv" | sed 's/^](#//; s/)$//' | LC_ALL=C sort -u)"
  [ -n "$anchors" ]
  while IFS= read -r a; do
    [ "$a" = "which-pipelines-are-instrumented" ] && continue
    found=""
    for heading in "${PAYLOAD_TABLES[@]}"; do
      # mkdocs' slug: lower-case, drop punctuation but `_` and `-`, spaces to `-`
      [ "$(tr '[:upper:]' '[:lower:]' <<<"$heading" | tr -cd 'a-z0-9 _-' | tr ' ' '-')" = "$a" ] && found=1
    done
    [ -n "$found" ] || { echo "inventory links #$a, which is no payload table" >&2; return 1; }
  done <<<"$anchors"
}

# ------------------------------------------------------- payload key tables (AC2)

@test "the payload section carries exactly the pinned tables" {
  local got want
  got="$(section '## Payload keys by pipeline' "$HOWTO" | sed -n 's/^### //p')"
  want="$(printf '%s\n' "${PAYLOAD_TABLES[@]}")"
  [ "$got" = "$want" ] || { printf 'tables changed:\n%s\n' "$got" >&2; return 1; }
}

@test "every payload table lists exactly the keys its pipeline's builder emits" {
  local t
  for t in "${PAYLOAD_TABLES[@]}"; do
    table_matches_builder "$t" "$HOWTO"
  done
}

@test "the page states the tables are the user-facing key list and names the normative sections" {
  local s names n
  s="$(section '## Payload keys by pipeline' "$HOWTO" | tr -s '[:space:]' ' ')"
  contains "$s" "These tables list every top-level \`payload\` key of each pipeline, so you can write a query without reading the emitting script."
  # one pointer per table, in PAYLOAD_TABLES order, each to a real ARCHITECTURE.md heading
  names="$(section '## Payload keys by pipeline' "$HOWTO" | sed -n 's/^Normative: `ARCHITECTURE.md`, \*\(.*\)\*\.$/\1/p')"
  [ "$names" = "$(printf '%s\n' 'Review-loop telemetry' 'The suggestion-promotion enrichment' 'Refine-issue telemetry' 'Resolve-issue telemetry' 'Epic mode (#1227)' 'Story size pre-flight (#1437)' 'Maintenance telemetry (#1228)' 'Bootstrap telemetry (#1229)' 'Acceptance telemetry (#1230)' 'Approver telemetry (#1231)')" ]
  while IFS= read -r n; do
    awk -v n="$n" '/^#+ / { sub(/^#+ /, ""); if (index($0, n) == 1) f = 1 } END { exit !f }' "$REPO_ROOT/ARCHITECTURE.md" || { echo "no ARCHITECTURE.md heading starts with: $n" >&2; return 1; }
  done <<<"$names"
}

# -------------------------------------------------------- the nesting join (AC3)

@test "join example 1 returns a resolve-issue run with its nested review-loop runs, as documented" {
  join_example_holds "$HOWTO" 1
  # and what it returns is the claim: the story run plus both loop records, the
  # sibling size pre-flight and the enrichment left out
  local got
  got="$(run_block_on_fixture "$(nth_block bash '## Join nested runs through `parent_run_id`' "$HOWTO" 1)")"
  [ "$(jq -r '.run.pipeline // .run.mode' <<<"$got")" = "story" ]
  [ "$(jq -c '[.review_loops[].run_id]' <<<"$got")" = '["review-loop-1791300200-0e1a","review-loop-1791300200-7c3d"]' ]
  lacks "$got" "story-preflight"
}

@test "join example 2 returns an epic's child runs with each child's review loops, as documented" {
  join_example_holds "$HOWTO" 2
}

@test "the join section warns about the four newcomer mistakes" {
  local s
  s="$(section '## Join nested runs through `parent_run_id`' "$HOWTO" | tr -s '[:space:]' ' ')"
  contains "$s" "**A review loop names its story run, never the epic.**"
  contains "$s" "**Filter on \`pipeline\` as well as \`parent_run_id\`.**"
  contains "$s" "**Filter on \`kind == \"run\"\`.**"
  contains "$s" "**One loop can leave several records.**"
}

# ---------------------------------------------------------------- gaps (AC4)

@test "the gaps section states there is no deferral and names each unmeasured fact with a substitute" {
  local s row
  s="$(section '## What is not measured' "$HOWTO")"
  contains "$(tr -s '[:space:]' ' ' <<<"$s")" "No pipeline of the instrumentation epic was deferred, so there is no deferral to substitute for."
  for row in '| `tokens`, on every pipeline |' '| A PR'"'"'s fate: merged, reverted, CI rounds to green |' \
             '| refine-issue records in a shared directory |' '| A run that stopped before its first real step |' \
             '| A run whose session died before its ending |' '| An Approver run that posted no review' \
             '| A posted review with no usable findings block |' '| Acceptance legs older than 30 days' \
             '| An acceptance leg whose report is missing, expired or unreadable |'; do
    contains "$s" "$row"
  done
  # every row carries three cells — a substitute, or a plain `none`
  [ "$(grep -c '^| .* | .* | .* |$' <<<"$s")" -ge 11 ]
}

# ---------------------------------------------------- recipes on a mixed sink (AC5)

@test "the story-runs recipe returns story runs only, never the epic record that shares the pipeline" {
  local code got
  code="$(nth_block bash '## Follow one story from outcome to review churn' "$HOWTO" 1)"
  contains "$code" '.payload.mode == "story"'
  got="$(run_block_on_fixture "$code")"
  [ "$(grep -c '' <<<"$got")" -eq 5 ]
  [ "$(jq -s -c 'map(.issue)' <<<"$got")" = '[1226,1227,1300,null,null]' ]
  # the second query returns exactly the story's two loop runs, never its pre-flight
  [ "$(jq -s -c 'map(.run_id // empty)' <<<"$got")" = '["review-loop-1791300200-0e1a","review-loop-1791300200-7c3d"]' ]
}

@test "the mode-split recipe separates story from epic runs" {
  local code
  code="$(nth_block bash '## What each measure means' "$HOWTO" 1)"
  run run_block_on_fixture "$code"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"mode":"epic","runs":1,"outcome_mix":{"success":1}},{"mode":"story","runs":3,"outcome_mix":{"parked":1,"success":2}}]' ]
}

@test "the measure table says which rollup figures mean something different per pipeline" {
  local s
  s="$(section '## What each measure means' "$HOWTO" | tr -s '[:space:]' ' ')"
  contains "$s" "Only \`review-loop\` and \`refine-issue\` carry \`payload.rounds\`, so every other pipeline shows it withheld."
  contains "$s" "show \`0\` by construction, not as a measured result."
  contains "$s" "**The \`resolve-issue\` section mixes story and epic runs.**"
}

@test "the share bullets name every forwarding pipeline and the one that does not" {
  local s
  s="$(section '## Share it across repos (opt-in)' "$HOWTO" | tr -s '[:space:]' ' ')"
  contains "$s" "**Every pipeline but one forwards it for you.**"
  contains "$s" "\`/development:maintenance\` and \`/development:bootstrap\` take the same two flags"
  contains "$s" "the acceptance and approver collectors take them for every record they append."
  contains "$s" "\`/development:refine-issue\` does **not** forward it yet"
}

# ------------------------------------------------------------- hand-off (AC6)

@test "the hand-off page says, once, that payload keys are not dashboard fields, linking the key tables" {
  local flat
  flat="$(tr -s '[:space:]' ' ' < "$HANDOFF")"
  contains "$flat" "Per-pipeline payload keys are not dashboard fields — no payload key ever enters the field manifest — and each pipeline's keys are listed in the [per-pipeline payload key tables](../how-to/read-pipeline-telemetry.md#payload-keys-by-pipeline)."
  [ "$(grep -o 'read-pipeline-telemetry.md#payload-keys-by-pipeline' "$HANDOFF" | grep -c '')" -eq 1 ]
  # the anchor it links is a real heading of the how-to
  [ "$(grep -c '^## Payload keys by pipeline$' "$HOWTO")" -eq 1 ]
}

# ---------------------------------------------------------------- non-vacuity

@test "non-vacuity: a key table with a row dropped, or a row added, reds the builder comparison" {
  local fx="$W/howto.md"
  # drop the review-loop `rounds` row (the refine-issue table has one too, so
  # only the first match in the file is dropped)
  awk '!done && /^\| `rounds` \|/ { done = 1; next } 1' "$HOWTO" > "$fx"
  run diff -q "$HOWTO" "$fx"
  [ "$status" -ne 0 ]
  run table_matches_builder "review-loop" "$fx"
  [ "$status" -eq 1 ]
  # an extra, undocumented-by-the-builder row in the approve table
  awk '{ print } /^\| `approver_version` \|/ { print "| `approver_model` | string | invented |" }' "$HOWTO" > "$fx"
  run table_matches_builder "approve" "$fx"
  [ "$status" -eq 1 ]
  # a Meaning cell that names a sub-key the builder does not emit
  sed 's/^| `host` | object | `os` and `homebrew`/| `host` | object | `os`, `region` and `homebrew`/' "$HOWTO" > "$fx"
  run diff -q "$HOWTO" "$fx"
  [ "$status" -ne 0 ]
  run table_matches_builder "bootstrap" "$fx"
  [ "$status" -eq 1 ]
  # the same, in the maintenance table's run_modifiers row
  sed 's/^| `run_modifiers` | object | `dry_run`,/| `run_modifiers` | object | `dry_run`, `region`,/' "$HOWTO" > "$fx"
  run diff -q "$HOWTO" "$fx"
  [ "$status" -ne 0 ]
  run table_matches_builder "maintenance" "$fx"
  [ "$status" -eq 1 ]
  # and the untouched page passes the same function
  run table_matches_builder "approve" "$HOWTO"
  [ "$status" -eq 0 ]
}

@test "non-vacuity: a join example whose query or documented output drifts reds" {
  local fx="$W/howto.md"
  # the query loses its pipeline filter, so the sibling size pre-flight leaks in
  sed 's/select(.pipeline == "review-loop" and .parent_run_id == \$id)/select(.parent_run_id == $id)/' "$HOWTO" > "$fx"
  run diff -q "$HOWTO" "$fx"
  [ "$status" -ne 0 ]
  run join_example_holds "$fx" 1
  [ "$status" -eq 1 ]
  # the documented output claims a round count the fixture does not hold
  sed 's/"outcome":"success","rounds":7,"wall_s":3600/"outcome":"success","rounds":6,"wall_s":3600/' "$HOWTO" > "$fx"
  run diff -q "$HOWTO" "$fx"
  [ "$status" -ne 0 ]
  run join_example_holds "$fx" 1
  [ "$status" -eq 1 ]
  # the epic example loses its hop through the child run
  sed 's/select(.pipeline == "review-loop" and .parent_run_id == \$child)/select(.pipeline == "review-loop" and .parent_run_id == $id)/' "$HOWTO" > "$fx"
  run diff -q "$HOWTO" "$fx"
  [ "$status" -ne 0 ]
  run join_example_holds "$fx" 2
  [ "$status" -eq 1 ]
}
