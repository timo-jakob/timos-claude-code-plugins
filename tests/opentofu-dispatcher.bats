#!/usr/bin/env bats
#
# The development-opentofu maintenance dispatcher (epic #1158, child #1160).
#
# Why this file exists: the dispatcher ships NO executable behaviour — it is a
# skill, so its PROSE is the contract. Without it the only assertions touching
# the dispatcher are that the directory entry exists and that the generated
# commands page names it — both of which stay green if the routing table lost
# `policy_tests`, if the `.language` guard became a `.topic` guard, if the three
# advisory rows started routing to an auto-fixer, if the interim
# escalate-until-#1161 override silently survived into #1161, or if the
# empty-array/no-group rule were dropped so every clean dispatch escalated as
# Halted.
#
# Conventions copied from tests/kubernetes-dispatcher.bats:
#   * every haystack is SCOPED to the section that must carry the clause, so a
#     coincidental occurrence elsewhere cannot satisfy a needle and a MOVED
#     clause is distinguishable from a present one;
#   * each scoped extraction is asserted non-empty FIRST — a failed `sed` yields
#     an empty haystack, which trivially `lacks` everything and would make the
#     negative assertions vacuous;
#   * needles are chosen so a NEGATED clause cannot satisfy them.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO_ROOT/development-opentofu/skills/maintenance/SKILL.md"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-opentofu-findings.zsh"
  [ -f "$SKILL" ]
  [ -f "$GATHER" ]
  BODY="$(cat "$SKILL")"
  # the frontmatter only — everything above the second `---`, whitespace-
  # normalized because it is a folded YAML scalar, so clause boundaries and line
  # boundaries do not coincide
  FRONTMATTER="$(awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside' "$SKILL" \
    | tr -s '[:space:]' ' ')"
  [ -n "$FRONTMATTER" ]
}

section() {
  sed -n "/^## $1\$/,/^## /p" "$SKILL" | tr -s '[:space:]' ' '
}

# --- frontmatter --------------------------------------------------------------

@test "the frontmatter declares the skill and its no-approver charter (#1160)" {
  contains "$FRONTMATTER" 'name: maintenance'
  contains "$FRONTMATTER" 'disable-model-invocation: false'
  contains "$FRONTMATTER" 'Ships NO approver'
  contains "$FRONTMATTER" 'runs no detection of its own'
}

@test "the frontmatter carries the #1161 interim caveat, not a bare routing claim (#1160)" {
  # this string is reproduced verbatim into the generated
  # docs/reference/commands.md and is the summary a model may see WITHOUT the
  # body, so an uncaveated "it ROUTES to <agent>" advertises subagent_types that
  # would fail to spawn. #1161 retires the caveat in the same PR that creates
  # the agents.
  contains "$FRONTMATTER" 'Until #1161 lands those agents it routes NOTHING'
  contains "$FRONTMATTER" 'human_action_required'
}

@test "the frontmatter names the advisory route as review, never auto-fix (#1160)" {
  contains "$FRONTMATTER" 'opentofu-security-reviewer'
  contains "$FRONTMATTER" 'never to an auto-fixer'
}

# --- validation ---------------------------------------------------------------

@test "Validation terminates on each malformed-payload shape (#1160)" {
  local s
  s="$(section Validation)"
  [ -n "$s" ]
  contains "$s" '`.schema_version != "2"`'
  contains "$s" '`.language != "opentofu"`'
  # the reason the guard is on `.language` and not `.topic` — without it a
  # maintainer "fixes" the guard to read a key the v2 payload does not have,
  # and every valid dispatch stops
  contains "$s" 'there is no `topic` key in the v2 payload'
  contains "$s" '`$ARGUMENTS` empty'
  # the fifth bullet, both halves — without it a truncated or absent payload file
  # has no documented stop and falls toward the empty-plan envelope the next test
  # says must never happen
  contains "$s" 'the file is missing'
  contains "$s" 'does not parse as JSON'
}

@test "the guard block is syntactically valid shell (#1160)" {
  # the block is pasted into a shell by the orchestrator, so a syntax error in
  # it is a runtime failure of the dispatch rather than a docs defect
  local block
  block="$(sed -n '/^```bash$/,/^```$/p' "$SKILL" | sed '/^```/d')"
  [ -n "$block" ]
  run -0 bash -n <(printf '%s\n' "$block")
}

@test "the guard block still CONTAINS each guard, not merely valid syntax (#1160)" {
  # `bash -n` passes over any subset, so a block with the JSON-parse or
  # `.language` guard deleted is still "valid" — and the prose "Stop on any
  # failure in the block above" would then dangle at nothing. Each guard is
  # pinned on its own line. Note these are the block's POSITIVE spellings
  # (`.language == "opentofu"`), which are different strings from the Validation
  # bullets' negative ones, so the bullet needles do not cover them.
  local block
  block="$(sed -n '/^```bash$/,/^```$/p' "$SKILL" | sed '/^```/d')"
  [ -n "$block" ]
  [ "$(printf '%s\n' "$block" | wc -l)" -le 14 ]
  contains "$block" 'command -v jq'
  contains "$block" '[ -n "$ARGUMENTS" ]'
  contains "$block" 'test -f "$ARGUMENTS"'
  contains "$block" 'jq -e . "$ARGUMENTS"'
  contains "$block" '.schema_version == "2"'
  contains "$block" '.language == "opentofu"'
  contains "$block" 'no payload file at:'
}

@test "the unknown-key bullet RETURNS the halt envelope rather than erroring (#1160)" {
  local s
  s="$(section Validation)"
  [ -n "$s" ]
  contains "$s" 'it does not error out: it **returns** the halt envelope'
  # rule AND consequence: erroring instead makes the orchestrator record
  # `dispatch failed` and swallow the escalation
  contains "$s" 'swallow it'
}

@test "Validation forbids falling through to the empty-plan envelope (#1160)" {
  local s
  s="$(section Validation)"
  [ -n "$s" ]
  contains "$s" 'Never fall through to *Response* and return the empty-plan envelope'
  contains "$s" 'the empty plan is for a *valid* v2 payload'
}

# --- routing ------------------------------------------------------------------

@test "the routing table covers EXACTLY the gather's seven keys (#1160)" {
  # derived from BOTH artifacts and compared, so the dispatcher and the gather
  # cannot drift into different vocabularies — a routed key the gather never
  # emits is dead, and an emitted key the table lacks halts every dispatch as
  # routing drift.
  local from_table from_gather
  # the KEY column explicitly, not every backticked token in the table range:
  # a future disposition worded `advisory` would otherwise enter the derived key
  # set and red this assertion for a reason unrelated to routing drift
  from_table="$(sed -n 's/^| `\([a-z_]*\)` | .* | `[a-z-]*` |$/\1/p' "$SKILL" \
    | sort -u | tr '\n' ' ')"
  [ -n "$from_table" ]
  # the gather's tooling_configured object is the authoritative key list
  # `sed 1d` drops the range's own opening line, which would otherwise
  # contribute the literal key `tooling_configured` to the derived set
  from_gather="$(sed -n '/^  tooling_configured: {/,/^  },$/p' "$GATHER" | sed 1d \
    | grep -oE '^[[:space:]]+[a-z_]+:' | tr -d ' :' | sort -u | tr '\n' ' ')"
  [ -n "$from_gather" ]
  [ "$from_table" = "$from_gather" ]
  # and pinned literally too, so three copies edited together cannot agree on a
  # silently shrunken set
  [ "$from_table" = "format lint misconfiguration policy policy_tests state_encryption validate " ]
}

@test "the three routed agent names are the #1161 filename contract (#1160)" {
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  contains "$s" '`opentofu-format-fixer`'
  contains "$s" '`opentofu-policy-triage`'
  contains "$s" '`opentofu-security-reviewer`'
}

@test "each routing row's key→AGENT pairing is pinned, not just the name set (#1160)" {
  # asserting only that the three names appear somewhere leaves the MAPPING
  # free: re-pointing `state_encryption` at `opentofu-format-fixer` — the exact
  # charter violation this file asserts in prose two tests down — would keep the
  # key set, the name set and the never-auto-fix sentence all intact
  local rows
  rows="$(sed -n 's/^| `\([a-z_]*\)` | .* | `\([a-z-]*\)` |$/\1=\2/p' "$SKILL" | sort | tr '\n' ' ')"
  [ -n "$rows" ]
  [ "$rows" = "format=opentofu-format-fixer lint=opentofu-format-fixer misconfiguration=opentofu-security-reviewer policy=opentofu-policy-triage policy_tests=opentofu-policy-triage state_encryption=opentofu-security-reviewer validate=opentofu-security-reviewer " ]
}

@test "no advisory row names an auto-fixer, derived rather than asserted in prose (#1160)" {
  # the charter rule as a DERIVATION over the table: the three advisory keys must
  # map to the reviewer, whatever the prose around them says
  local k
  for k in validate misconfiguration state_encryption; do
    run -0 bash -c "sed -n 's/^| \`$k\` | .* | \`\([a-z-]*\)\` |\$/\1/p' '$SKILL'"
    [ "$output" = "opentofu-security-reviewer" ]
  done
}

@test "the advisory rows route to a REVIEWER and never to an auto-fixer (#1160)" {
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  contains "$s" 'never route to an AUTO-FIXER'
  # ...and specifically NOT through the halt channel: that is the defect that
  # would cancel the mechanical fixes on the repos that need them most
  contains "$s" 'Do not put them in `human_action_required`'
  contains "$s" 'silently cancel'
}

@test "the #1161 interim override covers ALL THREE agent names, not just two (#1160)" {
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  contains "$s" 'This slice ships no agents at all'
  contains "$s" '**every** row is escalated instead of routed'
  contains "$s" '`opentofu-security-reviewer`, and emit one `human_action_required` entry per'
}

@test "the interim override's PREMISE holds — none of the routed agents exists yet (#1160)" {
  # THE DANGEROUS DIRECTION, and the only one nothing else guards. Every other
  # override test asserts the override is PRESENT; none asserts it is still
  # WARRANTED. So #1161 could ship the agent files, forget to flip the table, and
  # this dispatcher would escalate every finding group as human_action_required
  # forever with the whole suite green.
  #
  # Derived from the table rather than hard-coded, so it cannot fall out of step
  # with the routing rows.
  #
  # #1161 MUST INVERT THIS TEST in the same PR that ships the agents and retires
  # the override — that is the point of asserting the premise rather than the
  # conclusion.
  local agents agent
  agents="$(sed -n 's/^| `[a-z_]*` | .* | `\([a-z-]*\)` |$/\1/p' "$SKILL" | sort -u)"
  [ -n "$agents" ]
  [ "$(printf '%s\n' "$agents" | wc -l | tr -d ' ')" -eq 3 ]
  # a plain word-split loop: this file runs under bash, where zsh's ${(f)…} is a
  # bad substitution — and the agent names contain no whitespace
  for agent in $agents; do
    [ ! -f "$REPO_ROOT/development-opentofu/agents/$agent.md" ]
  done
}

@test "the interim override is declared to outrank every other routing statement (#1160)" {
  # the file restates routing in three places (the table, Dispatch mode's
  # bullets, No coverage gate); without a precedence rule a model reading only
  # the later section emits a plan entry naming a subagent that does not exist
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  contains "$s" 'This override outranks every other statement of routing in this file'
  contains "$s" 'inert today'
}

@test "an empty routed array forms no group and no escalation (#1160)" {
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  # "has a row for", not "is routed" — the interim override consumes the word
  # *routed*, so phrasing the rule that way would read as forming no groups at
  # all today
  contains "$s" 'A group exists only for a `findings_by_tool` key THAT THIS TABLE HAS A ROW FOR, and whose array is NON-EMPTY'
  contains "$s" 'the override changes only what is **emitted** for them'
  contains "$s" 'no `human_action_required` entry either'
  # the reason: four keys are empty on EVERY payload, so treating each key as a
  # group escalates the ordinary clean dispatch
  contains "$s" 'the most common payload there is'
}

@test "an UNKNOWN key halts on mere presence, empty array or not (#1160)" {
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  contains "$s" 'halts on its mere *presence*, empty array or not'
  contains "$s" 'this paragraph does not exempt it'
}

@test "the two grouping rules are stated, each with its shared-file reason (#1160)" {
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  contains "$s" 'Group `policy` and `policy_tests` into **one** PR'
  contains "$s" 'Group `format` and `lint` into **one** PR'
}

# --- dispatch mode ------------------------------------------------------------

@test "Dispatch mode dispositions all seven keys, and defers to the interim override (#1160)" {
  local s
  s="$(section "Dispatch mode")"
  [ -n "$s" ]
  contains "$s" 'read "routed" as "routed once the agents exist"'
  contains "$s" '`policy_tests` → **omitted entirely** in auxiliary mode'
  # the one that must NOT be suppressed, with its reason — unencrypted state is
  # a defect whatever the repo's primary language is
  contains "$s" 'never suppressed in auxiliary mode'
}

@test "a non-primary/auxiliary dispatch_mode halts rather than defaulting (#1160)" {
  local s
  s="$(section "Dispatch mode")"
  [ -n "$s" ]
  contains "$s" 'absent is treated as `"primary"`'
  contains "$s" 'Do **not** "treat it as primary and carry on"'
}

# --- the coverage analogue ----------------------------------------------------

@test "the policy_tests ordering rule carries the interim carve-out (#1160)" {
  # THE regression this section is most likely to produce: it is the section a
  # model consulting "what do I do with policy_tests?" reads on its own, and
  # without the carve-out it orders a plan entry naming an agent that does not
  # exist in this slice
  local s
  s="$(section "No coverage gate, one analogue")"
  [ -n "$s" ]
  contains "$s" 'ordering-blocking'
  contains "$s" 'Until #1161 lands, this group escalates like every other'
  contains "$s" 'build **no** plan entry'
  contains "$s" 'inert today'
}

# --- absent policies ----------------------------------------------------------

@test "absent policies are a skip, never a finding and never missing_tooling (#1160)" {
  local s
  s="$(section "Absent policies are not a finding")"
  [ -n "$s" ]
  contains "$s" '`policies/conftest/**/*.rego` matched nothing'
  contains "$s" 'Do not synthesise a finding'
  contains "$s" 'that is the consumer'
}

@test "a declared set that could not be EVALUATED is the opposite case (#1160)" {
  # the distinction the charter turns on: 'the tool could not run' must never be
  # read as 'the repo declined to declare opinions'
  local s
  s="$(section "Absent policies are not a finding")"
  [ -n "$s" ]
  contains "$s" 'arrives as an ordinary `policy` finding'
  contains "$s" 'when conftest is not installed at all'
  contains "$s" 'green-over-'
}

# --- response -----------------------------------------------------------------

@test "the response envelope carries every field, and the halt keeps plan (#1160)" {
  local s
  s="$(section Response)"
  [ -n "$s" ]
  contains "$s" '"schema_version": "2"'
  contains "$s" '"ci_fixer_agent": null'
  contains "$s" 'adds a fifth top-level field — but **keeps `plan` and `missing_tooling`**'
  contains "$s" 'swallow the very escalation the halt exists to deliver'
}

@test "missing_tooling is declared ALWAYS EMPTY on this topic, with the derivation (#1160)" {
  local s
  s="$(section Response)"
  [ -n "$s" ]
  contains "$s" '`policy` and `policy_tests`'
  contains "$s" 'declined to declare opinions'
  contains "$s" 'ALWAYS EMPTY on this topic'
  contains "$s" 'always a mistake'
}

@test "the five presence-detected keys cannot be false, and a false one halts (#1160)" {
  local s
  s="$(section Response)"
  [ -n "$s" ]
  contains "$s" 'cannot be `false` on a payload that reached you'
  contains "$s" 'note it in `human_action_required` and route nothing'
  # rule AND reason: "no .tf found" is not "tflint is unconfigured"
  contains "$s" 'is not "tflint is unconfigured"'
}

@test "ci_fixer_agent is null and no other plugin's fixer is substituted (#1160)" {
  local s
  s="$(section Response)"
  [ -n "$s" ]
  contains "$s" '`ci_fixer_agent` is `null`'
  contains "$s" 'does **not** substitute another plugin'
}

# --- the negative charter -----------------------------------------------------

@test "the dispatcher spawns nothing, edits nothing and approves nothing (#1160)" {
  local s
  s="$(section "What you never do")"
  [ -n "$s" ]
  contains "$s" "Don't edit any file or spawn any agent"
  contains "$s" "Don't approve anything"
  contains "$s" 'can destroy state that no rollback recovers'
  contains "$s" "don't treat their absence as a gap"
}

@test "no approver agent is shipped, and none is referenced (#1160)" {
  # the charter's negative half, asserted against the tree rather than the prose
  [ ! -d "$REPO_ROOT/development-opentofu/agents" ] \
    || [ -z "$(find "$REPO_ROOT/development-opentofu/agents" -name '*approver*' 2>/dev/null)" ]
  lacks "$BODY" 'opentofu-approver'
}

# --- the clauses that make the prose implementable ---------------------------

@test "Routing disambiguates the policy TOOL from the top-level policy OBJECT (#1160)" {
  # the paragraph that prevents inverting the charter's central skip. Trimmed as
  # redundant, a model resolving a bare "policy" binds it to the always-truthy
  # top-level object and every repo with no Rego files is read as having
  # policies configured — a group formed for exactly the repos the skip exists
  # to leave alone. The "Absent policies are not a finding" tests assert that
  # outcome in prose; nothing pinned the mechanism.
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  contains "$s" 'One name, two things'
  contains "$s" '`tooling_configured.policy` / `findings_by_tool.policy`'
  contains "$s" 'top-level `policy` object'
  contains "$s" '**never** read by this dispatcher'
  contains "$s" 'inverting the charter'
}

@test "the advisory guardrail carries its own inert-today qualifier (#1160)" {
  # the guardrail forbids `human_action_required` for the three advisory rows,
  # which is the exact envelope the interim override requires TODAY. Without the
  # qualifier IN THIS SECTION, a model consulting "what do I do with a
  # state_encryption finding?" builds a plan entry naming an agent that does not
  # exist and Phase 8 fails to spawn.
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  contains "$s" 'INERT TODAY'
  contains "$s" 'escalate via `human_action_required` like every other row'
  # and the override must claim the whole file, not merely what follows it
  contains "$s" '**any other** section'
}

@test "Validation halts on a configured key ABSENT from findings_by_tool (#1160)" {
  # the mirror of the unknown-key break. Without it an absent key falls into the
  # no-group path and Phase 9 renders "Clean — the topic's tools ran and found
  # nothing" for a payload-contract break.
  local s
  s="$(section Validation)"
  [ -n "$s" ]
  contains "$s" 'reports **`true`** is **ABSENT**'
  contains "$s" 'not "configured and clean"'
  contains "$s" 'jq` is not on PATH'
}

@test "auxiliary-mode suppression of policy_tests is deferral WITH a trace (#1160)" {
  # the gather evaluated policy_tests and may have emitted a high-severity
  # finding; dropping it with nothing said lets Phase 9 report a clean verdict
  # over a defect the pipeline found — the trace-less loss this file refuses one
  # bullet up for state_encryption
  local s
  s="$(section "Dispatch mode")"
  [ -n "$s" ]
  contains "$s" 'DEFERRAL, not disappearance'
  contains "$s" 'never renders a bare "Clean"'
  contains "$s" 'Do not invent a channel'
}

@test "the negative charter pins the no-trim and no-gather rules too (#1160)" {
  # "echo the finding objects through in full" is what stops a dispatcher
  # summarising findings out of the prompt Phase 8 builds
  local s
  s="$(section "What you never do")"
  [ -n "$s" ]
  contains "$s" "Don't run the gather"
  contains "$s" 'in full'
}

@test "Routing states the dispatch_filter rule and its empty-plan outcome (#1160)" {
  # the whole defensive-handling rule, including that an empty plan is the
  # CORRECT result of a filter that excludes every key — without it a dispatcher
  # reads an empty plan as a payload it failed to understand
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  contains "$s" 'dispatch_filter'
  contains "$s" 'an empty plan is the correct result'
}
