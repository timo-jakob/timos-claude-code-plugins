#!/usr/bin/env bats
#
# The development-react maintenance dispatcher (#1948, a child of #960 in epic
# #686). Its decision is a script — skills/maintenance/scripts/plan-dispatch.zsh —
# that SKILL.md runs and returns verbatim, following development-composition
# (#1747). So the routing is tested by EXECUTING it here, with fixtures carrying
# the real finding ids gather-react-findings.zsh emits (#1947), and the prose is
# pinned only for what the model must do around it.
#
# The agent the two groups route to, react-webui-quality-advisor, is prose: its
# per-type outcome table, its never-npm rule and its budget-fix flag are pinned
# row by row below.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO_ROOT/development-react/skills/maintenance/SKILL.md"
  PLAN="$REPO_ROOT/development-react/skills/maintenance/scripts/plan-dispatch.zsh"
  AGENT="$REPO_ROOT/development-react/agents/react-webui-quality-advisor.md"
  [ -f "$SKILL" ]
  [ -x "$PLAN" ]
  [ -f "$AGENT" ]
  P="$BATS_TEST_TMPDIR/payload.json"
}

# a payload: $1 = findings_by_tool, $2 = extra top-level keys
payload() {
  local extra='{}'
  [ -z "${2:-}" ] || extra="$2"
  jq -n --argjson fbt "$1" --argjson extra "$extra" '
    {schema_version: "2", language: "react", dispatch_mode: "auxiliary",
     repo: {path: "/tmp/storefront-web", default_branch: "main", visibility: "private"},
     language_meta: {version: null, manifests: ["package.json"]},
     tooling_configured: {a11y: true, lighthouse_budget: true},
     findings_by_tool: $fbt, notes: [], coverage: null} + $extra' >"$P"
}

# real #1947 finding shapes
A11Y_MATCHER='{"id":"a11y:matcher_not_registered","tool":"a11y","type":"matcher_not_registered","severity":"MAJOR",
  "message":"vitest-axe is installed but no setupFiles entry registers toHaveNoViolations","fix":"f",
  "files":["vitest.config.ts"]}'
A11Y_NOPKG='{"id":"a11y:no_axe_package","tool":"a11y","type":"no_axe_package","severity":"MAJOR",
  "message":"no axe package in devDependencies","fix":"f","files":["package.json"]}'
LH_LOOSE='{"id":"lighthouse_budget:budget_too_loose:resource-summary:script:size","tool":"lighthouse_budget",
  "type":"budget_too_loose","severity":"MINOR","message":"409600 > 307200","fix":"f","files":["lighthouserc.json"]}'
LH_TIMING='{"id":"lighthouse_budget:timing_assertion_blocking:categories:performance","tool":"lighthouse_budget",
  "type":"timing_assertion_blocking","severity":"MINOR","message":"categories:performance at error","fix":"f",
  "files":["lighthouserc.json"]}'
LH_PRESET='{"id":"lighthouse_budget:preset_present","tool":"lighthouse_budget","type":"preset_present",
  "severity":"MINOR","message":"preset lighthouse:recommended","fix":"f","files":["lighthouserc.json"]}'

A11Y_GROUP='{"group_id":1,"tool":"a11y","description":"Triage 2 accessibility-gate finding(s)",
  "findings":["a11y:matcher_not_registered","a11y:no_axe_package"],"files":["vitest.config.ts","package.json"],
  "rationale":"the axe package and toHaveNoViolations matcher findings triaged together by react-webui-quality-advisor",
  "agent":"react-webui-quality-advisor","isolation":true,
  "suggested_pr_title":"test(a11y): register the axe toHaveNoViolations matcher","priority_score":0.5}'

lh_group() {  # $1 = group_id
  jq -n --argjson gid "$1" '{group_id: $gid, tool: "lighthouse_budget",
    description: "Triage 3 Lighthouse budget finding(s)",
    findings: ["lighthouse_budget:budget_too_loose:resource-summary:script:size",
               "lighthouse_budget:timing_assertion_blocking:categories:performance",
               "lighthouse_budget:preset_present"],
    files: ["lighthouserc.json"],
    rationale: "the lighthouserc.json budget findings triaged together by react-webui-quality-advisor",
    agent: "react-webui-quality-advisor", isolation: true,
    suggested_pr_title: "ci(lighthouse): align lighthouserc.json with the family byte budgets",
    priority_score: 0.4}'
}

BOTH="{\"a11y\":[$A11Y_MATCHER,$A11Y_NOPKG],\"lighthouse_budget\":[$LH_LOOSE,$LH_TIMING,$LH_PRESET]}"

# --- the routing, executed ------------------------------------------------------

@test "two tools with findings yield exactly one group each, both routed to react-webui-quality-advisor" {
  payload "$BOTH"
  run "$PLAN" "$P"
  [ "$status" -eq 0 ]
  run jq -r '.plan | length' <<<"$output"
  [ "$output" = "2" ]
  run "$PLAN" "$P"
  run jq -r '[.plan[].tool] | join(",")' <<<"$output"
  [ "$output" = "a11y,lighthouse_budget" ]
  run "$PLAN" "$P"
  run jq -r '[.plan[].agent] | unique | join(",")' <<<"$output"
  [ "$output" = "react-webui-quality-advisor" ]
}

@test "every finding id passes through byte-identical, including an assertion id that contains a colon" {
  payload "$BOTH"
  run "$PLAN" "$P"
  [ "$status" -eq 0 ]
  got="$(jq -c '[.plan[].findings[]]' <<<"$output")"
  want="$(jq -c '[.a11y[].id, .lighthouse_budget[].id]' <<<"$BOTH")"
  [ "$got" = "$want" ]
  contains "$got" '"lighthouse_budget:timing_assertion_blocking:categories:performance"'
}

@test "each group carries exactly the Step 3 shape (files, isolation, title, priority 0.5 / 0.4)" {
  payload "$BOTH"
  run "$PLAN" "$P"
  [ "$status" -eq 0 ]
  jq -e --argjson want "$A11Y_GROUP" '.plan[0] == $want' <<<"$output" >/dev/null
  jq -e --argjson want "$(lh_group 2)" '.plan[1] == $want' <<<"$output" >/dev/null
}

@test "the a11y group's files are the de-duplicated union of its findings' files" {
  dup='{"id":"a11y:matcher_not_registered","tool":"a11y","type":"matcher_not_registered","severity":"MAJOR",
    "message":"m","fix":"f","files":["package.json","vitest.config.ts"]}'
  payload "{\"a11y\":[$A11Y_MATCHER,$dup,$A11Y_NOPKG],\"lighthouse_budget\":[]}"
  run "$PLAN" "$P"
  [ "$status" -eq 0 ]
  run jq -c '.plan[0].files' <<<"$output"
  [ "$output" = '["vitest.config.ts","package.json"]' ]
}

@test "an empty a11y list yields only the lighthouse_budget group" {
  payload "{\"a11y\":[],\"lighthouse_budget\":[$LH_LOOSE,$LH_TIMING,$LH_PRESET]}"
  run "$PLAN" "$P"
  [ "$status" -eq 0 ]
  jq -e --argjson want "$(lh_group 1)" '.plan == [$want] and .missing_tooling == []' <<<"$output" >/dev/null
}

@test "an empty lighthouse_budget list yields only the a11y group" {
  payload "{\"a11y\":[$A11Y_MATCHER,$A11Y_NOPKG],\"lighthouse_budget\":[]}"
  run "$PLAN" "$P"
  [ "$status" -eq 0 ]
  jq -e --argjson want "$A11Y_GROUP" '.plan == [$want]' <<<"$output" >/dev/null
}

@test "a clean payload (both lists empty) is an empty plan in the documented envelope" {
  payload '{"a11y":[],"lighthouse_budget":[]}'
  run "$PLAN" "$P"
  [ "$status" -eq 0 ]
  jq -e '. == {schema_version: "2", ci_fixer_agent: "js-ci-fixer", plan: [], missing_tooling: []}' \
    <<<"$output" >/dev/null
}

@test "an unknown tool carrying findings gets a missing_tooling entry and no group" {
  payload "{\"a11y\":[],\"lighthouse_budget\":[$LH_LOOSE,$LH_TIMING,$LH_PRESET],
    \"playwright\":[{\"id\":\"playwright:no_config\",\"tool\":\"playwright\"}],\"storybook\":[]}"
  run "$PLAN" "$P"
  [ "$status" -eq 0 ]
  jq -e '[.plan[].tool] == ["lighthouse_budget"]' <<<"$output" >/dev/null
  jq -e '.missing_tooling == [{tool: "playwright",
    summary: "findings present for a tool development-react does not handle yet",
    what_it_provides: "the finding source this dispatcher has no routing-table entry for",
    how_to_add: "register the tool in Step 2'"'"'s routing table and give it a group shape in Step 3"}]' \
    <<<"$output" >/dev/null
}

@test "dispatch_filter.only_tools restricts the plan to the listed tools" {
  payload "$BOTH" '{"dispatch_filter":{"only_tools":["lighthouse_budget"]}}'
  run "$PLAN" "$P"
  [ "$status" -eq 0 ]
  jq -e --argjson want "$(lh_group 1)" '.plan == [$want]' <<<"$output" >/dev/null
}

@test "a non-v2 payload is refused with exit 1 and nothing on stdout, never an empty plan" {
  payload "$BOTH" '{"schema_version":"3"}'
  run --separate-stderr "$PLAN" "$P"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" 'want schema_version 2, found: 3'
}

@test "a payload that is not JSON is refused with exit 1 and nothing on stdout" {
  printf '{"schema_version": "2", ' >"$P"
  run --separate-stderr "$PLAN" "$P"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" 'not valid JSON'
}

@test "a missing payload file is refused with exit 1 and nothing on stdout" {
  run --separate-stderr "$PLAN" "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" 'no payload file at:'
}

@test "no argument, two arguments or one empty argument is a usage error (exit 2)" {
  payload "$BOTH"
  run --separate-stderr "$PLAN"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'usage: plan-dispatch.zsh'
  run --separate-stderr "$PLAN" "$P" "$P"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'usage: plan-dispatch.zsh'
  run --separate-stderr "$PLAN" ""
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'usage: plan-dispatch.zsh'
}

@test "a payload jq cannot build a response from is refused with exit 1 and nothing on stdout" {
  payload '{"a11y":"not-an-array","lighthouse_budget":[]}'
  run --separate-stderr "$PLAN" "$P"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" 'could not build the response'
}

@test "with no jq on PATH the planner refuses with exit 1, never an empty plan" {
  payload "$BOTH"
  stub="$BATS_TEST_TMPDIR/nojq"
  mkdir -p "$stub"
  ln -s "$(command -v zsh)" "$stub/zsh"
  run --separate-stderr env PATH="$stub" "$(command -v zsh)" "$PLAN" "$P"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" 'jq not found on PATH'
}

@test "groups follow the routing table's order (a11y first), not the payload's key order" {
  payload "{\"lighthouse_budget\":[$LH_LOOSE,$LH_TIMING,$LH_PRESET],\"a11y\":[$A11Y_MATCHER,$A11Y_NOPKG]}"
  run "$PLAN" "$P"
  [ "$status" -eq 0 ]
  jq -e '[.plan[] | [.group_id, .tool]] == [[1, "a11y"], [2, "lighthouse_budget"]]' <<<"$output" >/dev/null
}

@test "a handled tool reported unconfigured with no findings gets a missing_tooling entry, never a clean-looking response" {
  payload '{"a11y":[],"lighthouse_budget":[]}' '{"tooling_configured":{"a11y":false,"lighthouse_budget":true}}'
  run "$PLAN" "$P"
  [ "$status" -eq 0 ]
  jq -e '.plan == [] and [.missing_tooling[].tool] == ["a11y"]
    and .missing_tooling[0].summary == "the gather could not audit `a11y`, so it was not fully inspected."' \
    <<<"$output" >/dev/null
}

@test "a configured tool whose check the gather could not complete (a note, no finding) is not clean either" {
  note='a11y: the setupFiles value in vitest.config.ts has an entry with no string literal to read statically (a variable or computed expression) — the axe matcher registration was not judged.'
  payload "{\"a11y\":[],\"lighthouse_budget\":[$LH_LOOSE,$LH_TIMING,$LH_PRESET]}" \
    "$(jq -n --arg n "$note" '{notes: [$n]}')"
  run "$PLAN" "$P"
  [ "$status" -eq 0 ]
  jq -e --arg n "$note" '[.plan[].tool] == ["lighthouse_budget"]
    and [.missing_tooling[].tool] == ["a11y"]
    and (.missing_tooling[0].summary | contains($n))' <<<"$output" >/dev/null
}

# --- the prose around the script ------------------------------------------------

@test "SKILL.md runs plan-dispatch.zsh and returns its stdout verbatim" {
  body="$(tr -s '[:space:]' ' ' <"$SKILL")"
  contains "$body" 'zsh "<skill-base-dir>/scripts/plan-dispatch.zsh" "$ARGUMENTS"'
  contains "$body" 'its stdout **is** the response. Return it inline, unchanged'
  contains "$body" 'Never fall back to an empty plan for a payload you could not validate'
}

@test "SKILL.md's Empty plan note: clean only when both tools are configured" {
  body="$(tr -s '[:space:]' ' ' <"$SKILL")"
  contains "$body" 'an empty plan with **both** tools reported configured'
  contains "$body" 'A tool reported **unconfigured** (`false`) is **not** clean'
  contains "$body" 'an unaudited gate is never returned as an empty, clean-looking response'
  contains "$body" 'If it exits 2 again, report the stderr line and **stop**'
}

@test "no copy of the empty-universe or zero-group wording remains in the dispatcher, manifests or reference docs" {
  local f pat
  for f in "$SKILL" \
           "$REPO_ROOT/development-react/.claude-plugin/plugin.json" \
           "$REPO_ROOT/.claude-plugin/marketplace.json" \
           "$REPO_ROOT/docs/reference/plugins.md" \
           "$REPO_ROOT/docs/reference/commands.md"; do
    [ -f "$f" ]
    for pat in 'tool universe is deliberately' 'tool universe is empty' 'Empty tool universe' \
               'zero-group' 'tool-less' 'dispatcher stub' 'always an empty plan' 'always `[]`' \
               'always [] in v0.1' '(none yet' 'does not route the two tools yet'; do
      run grep -F -- "$pat" "$f"
      [ "$status" -eq 1 ] || { echo "stale wording '$pat' in $f: $output"; return 1; }
    done
  done
}

@test "the manifests and reference docs name the new routing" {
  contains "$(jq -r .description "$REPO_ROOT/development-react/.claude-plugin/plugin.json")" \
    'react-webui-quality-advisor'
  contains "$(jq -r '.plugins[] | select(.name == "development-react") | .description' \
    "$REPO_ROOT/.claude-plugin/marketplace.json")" 'react-webui-quality-advisor'
  run grep -cE '^\| react-webui-quality-advisor \| opus \|' "$REPO_ROOT/docs/reference/plugins.md"
  [ "$output" = "1" ]
}

@test "plugin.json and marketplace.json versions move in lockstep" {
  a="$(jq -er .version "$REPO_ROOT/development-react/.claude-plugin/plugin.json")"
  b="$(jq -er '.plugins[] | select(.name == "development-react") | .version' "$REPO_ROOT/.claude-plugin/marketplace.json")"
  [ -n "$a" ]
  [ "$a" = "$b" ]
}

# --- the agent ------------------------------------------------------------------

frontmatter() {
  awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside' "$AGENT"
}

@test "the agent's frontmatter: name, a non-empty description, model opus, tools Read, Edit, Bash, Grep" {
  fm="$(frontmatter)"
  [ -n "$fm" ]
  run grep -cx 'name: react-webui-quality-advisor' <<<"$fm"
  [ "$output" = "1" ]
  run grep -cx 'model: opus' <<<"$fm"
  [ "$output" = "1" ]
  run grep -cx 'tools: Read, Edit, Bash, Grep' <<<"$fm"
  [ "$output" = "1" ]
  run grep -E '^description: .{40,}' <<<"$fm"
  [ "$status" -eq 0 ]
}

# the table rows under "## What each finding means" — one per type
table_row() {  # $1 = the finding type as written in its first cell
  sed -n '/^## What each finding means$/,/^## /p' "$AGENT" | grep -F -- "| \`$1\` |"
}

@test "the agent's table names all nine #1947 finding types, each with its pinned outcome" {
  local pair type outcome row n
  n="$(sed -n '/^## What each finding means$/,/^## /p' "$AGENT" | grep -cE '^\| `(a11y|lighthouse_budget):')"
  [ "$n" = "9" ]
  for pair in \
    'a11y:no_axe_package=escalate' \
    'a11y:matcher_not_registered=fix, narrowly' \
    'lighthouse_budget:missing_config=escalate' \
    'lighthouse_budget:invalid_config=escalate' \
    'lighthouse_budget:budget_missing:<assertion-id>=fix' \
    'lighthouse_budget:budget_not_blocking:<assertion-id>=fix' \
    'lighthouse_budget:budget_too_loose:<assertion-id>=fix' \
    'lighthouse_budget:timing_assertion_blocking:<assertion-id>=fix' \
    'lighthouse_budget:preset_present=escalate, always'; do
    type="${pair%%=*}"; outcome="${pair#*=}"
    row="$(table_row "$type")"
    [ -n "$row" ] || { echo "no row for $type"; return 1; }
    # the Outcome cell is the second column, exactly
    [ "$(awk -F' \\| ' '{print $2}' <<<"$row")" = "$outcome" ] \
      || { echo "$type: outcome is not '$outcome': $row"; return 1; }
  done
}

@test "the agent's matcher fix is narrow: vitest-axe/jest-axe plus an existing setupFiles entry, else escalate" {
  row="$(table_row 'a11y:matcher_not_registered')"
  contains "$row" 'Only when `vitest-axe` or `jest-axe` is in `devDependencies`'
  contains "$row" "import '<package>/extend-expect';"
  contains "$row" '`jest-axe` qualifies only when that config also sets `globals: true`'
  contains "$row" 'Escalate the rest: bare `axe-core`'
}

@test "the agent's budget_not_blocking fix also lowers an above-limit maxNumericValue" {
  contains "$(table_row 'lighthouse_budget:budget_not_blocking:<assertion-id>')" \
    'set `maxNumericValue` to the limit when it is absent, not a number, or above the limit'
}

@test "the agent verifies each jq edit's value, and may use Bash for the undo copy and the commit" {
  body="$(tr -s '[:space:]' ' ' <"$AGENT")"
  contains "$body" 'then assert the intended value on its path with `jq -e`'
  contains "$body" 'If the edit command failed, the file does not parse, or the value is not there, restore the copy from step 1'
  contains "$body" 'Bash is for `jq`, for copying and restoring `lighthouserc.json` around each edit, and for the `git add` / `git commit` of the final edits'
}

@test "the agent pins the family byte-budget limits and timing gates drop to warn" {
  body="$(tr -s '[:space:]' ' ' <"$AGENT")"
  contains "$body" '**307200** for `resource-summary:script:size`'
  contains "$body" '**512000** for `resource-summary:total:size`'
  contains "$(table_row 'lighthouse_budget:timing_assertion_blocking:<assertion-id>')" \
    'Lower the level from `error` to `warn`'
}

@test "the agent never runs npm, and no command block in it invokes npm" {
  body="$(tr -s '[:space:]' ' ' <"$AGENT")"
  contains "$body" 'You **never run `npm`**'
  # no fenced shell block may carry an npm/npx/yarn/pnpm command
  run awk '/^```(bash|sh|zsh)$/ {inside=1; next} /^```$/ {inside=0} inside' "$AGENT"
  [ "$status" -eq 0 ]
  run grep -E '(^|[^[:alnum:]_-])(npm|npx|yarn|pnpm)[[:space:]]' <<<"$output"
  [ "$status" -eq 1 ]
}

@test "the agent flags that a budget fix may turn the Lighthouse job red, with no branch-protection lookup" {
  body="$(tr -s '[:space:]' ' ' <"$AGENT")"
  contains "$body" '**Budget fixes are applied and flagged.**'
  contains "$body" "**the new or tightened budget may turn the repo's Lighthouse job red**"
  contains "$body" 'You do **no** branch-protection lookup'
}

@test "the agent re-parses lighthouserc.json after each jq edit and undoes only that edit on failure" {
  body="$(tr -s '[:space:]' ' ' <"$AGENT")"
  contains "$body" 're-parse with `jq -e . lighthouserc.json`'
  contains "$body" 'undoing that one edit'
  contains "$body" 'move the finding to **`unable_to_fix`**'
}

@test "the agent returns the docs-c4-drift-advisor result shape and drops no finding" {
  body="$(tr -s '[:space:]' ' ' <"$AGENT")"
  contains "$body" 'Every finding lands in **exactly one** of `actions_taken`, `actions_requiring_review` or `unable_to_fix`'
  json="$(awk '/^```json$/ {inside=1; next} /^```$/ {inside=0} inside' "$AGENT")"
  jq -e 'keys == ["actions_requiring_review","actions_taken","configured","tool","unable_to_fix"]' \
    <<<"$json" >/dev/null
}
