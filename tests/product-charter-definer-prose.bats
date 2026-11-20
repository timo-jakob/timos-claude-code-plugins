#!/usr/bin/env bats
#
# The `charter-definer` agent (#3206, task 5 of #3195): the per-turn engine
# behind /product:define-charter. It is prose, so this suite pins the sentences
# that carry its behaviour — the read-only frontmatter, the one-JSON-object
# output and its key list, what it asks and what it never asks, the date rule,
# the non-goal-versus-epic challenge, the direction-change rule, the `ref` rule
# for a repo that already states its principles, and the stable-id rule. The
# output example is parsed, so its keys are checked as data, not as text.
#
# Anchored by content, never by line number (#1189).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AGENT="$REPO_ROOT/product/agents/charter-definer.md"
  # the whole file with every whitespace run collapsed to one space, so a pin
  # survives re-wrapping
  FLAT="$(tr -s '[:space:]' ' ' < "$AGENT")"
  # the frontmatter alone: the lines between the first two `---`
  FRONT="$(awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside { print }' "$AGENT")"
  # the first fenced json block under `## Output`, the agent's output example
  OUT_JSON="$BATS_TEST_TMPDIR/output-example.json"
  awk '/^## Output/ { sec = 1; next } sec && /^## / { exit } sec && /^```json$/ { inb = 1; next } inb && /^```$/ { exit } inb { print }' "$AGENT" > "$OUT_JSON"
  # the first fenced json block under `## Input`, the skill's input example
  IN_JSON="$BATS_TEST_TMPDIR/input-example.json"
  awk '/^## Input/ { sec = 1; next } sec && /^## / { exit } sec && /^```json$/ { inb = 1; next } inb && /^```$/ { exit } inb { print }' "$AGENT" > "$IN_JSON"
}

# --- frontmatter ------------------------------------------------------------

@test "frontmatter names the agent charter-definer" {
  run grep -c '^name: charter-definer$' <<<"$FRONT"
  [ "$output" = "1" ]
}

@test "frontmatter grants Read, Grep, Glob and Bash, and no write tool" {
  run grep -c '^tools: Read, Grep, Glob, Bash$' <<<"$FRONT"
  [ "$output" = "1" ]
  run grep -cE '^tools:.*(Edit|Write)' <<<"$FRONT"
  [ "$output" = "0" ]
}

@test "frontmatter declares a model and a description naming /product:define-charter" {
  run grep -cE '^model: [a-z]+$' <<<"$FRONT"
  [ "$output" = "1" ]
  run grep -E '^description: ' <<<"$FRONT"
  [ "$status" -eq 0 ]
  contains "$output" "/product:define-charter"
  contains "$output" "Returns a JSON object only"
}

# --- the authority model ----------------------------------------------------

@test "the agent returns a JSON object only and writes nothing" {
  contains "$FLAT" "returns a JSON object only"
  contains "$FLAT" "You never write a file, edit the charter or touch GitHub."
}

# --- input ------------------------------------------------------------------

@test "the input example parses and carries the five input keys" {
  run jq -c 'keys' "$IN_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = '["charter_so_far","conversation","evidence","latest_reply","mode"]' ]
}

# --- output -----------------------------------------------------------------

@test "the output example parses and carries exactly the seven output keys" {
  run jq -c 'keys' "$OUT_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = '["candidates","charter_block","direction_change","draft_prose","explanation","questions","ready_for_approval"]' ]
}

@test "the output key list is stated in prose, in the order the contract names them" {
  contains "$FLAT" 'the keys `explanation`, `candidates`, `direction_change`, `questions`, `draft_prose`, `charter_block`, `ready_for_approval`, and no others'
}

@test "a candidate carries kind, proposed_id, text and evidence" {
  run jq -c '.candidates[0] | keys' "$OUT_JSON"
  [ "$output" = '["evidence","kind","proposed_id","text"]' ]
}

@test "a direction change carries from, to, rationale, date, retires, rewrites and adds" {
  run jq -c '.direction_change | keys' "$OUT_JSON"
  [ "$output" = '["adds","date","from","rationale","retires","rewrites","to"]' ]
}

@test "a question carries id, text and why" {
  run jq -c '.questions[0] | keys' "$OUT_JSON"
  [ "$output" = '["id","text","why"]' ]
}

@test "ready_for_approval is a boolean and charter_block is a charter/v1 object" {
  run jq -r '.ready_for_approval | type' "$OUT_JSON"
  [ "$output" = "boolean" ]
  run jq -r '.charter_block.schema' "$OUT_JSON"
  [ "$output" = "charter/v1" ]
}

@test "the agent emits only the JSON object, with no prose around it" {
  contains "$FLAT" "Emit exactly one fenced \`json\` block and no other prose."
}

# --- what it asks -----------------------------------------------------------

@test "it asks about purpose, audience, values in conflict, what is out and why, and what has changed" {
  contains "$FLAT" "You ask about five things only: purpose, audience, values in conflict, what is out and why, and what has changed."
}

@test "it asks nothing about tooling, layout or file placement, citing pillar 2 by its published page" {
  contains "$FLAT" "You ask nothing about tooling, layout or file placement."
  run grep -cE '^ *\[Never asks "how"\]\(https://timo-jakob\.github\.io/timos-claude-code-plugins/explanation/philosophy/#pillar-2\)\.?$' "$AGENT"
  [ "$output" = "1" ]
}

@test "the agent never links the philosophy page by a relative path" {
  run grep -c 'philosophy\.md' "$AGENT"
  [ "$output" = "0" ]
}

# --- the rules --------------------------------------------------------------

@test "it never invents a date, and asks when the evidence gives none" {
  contains "$FLAT" "You never invent a date."
  contains "$FLAT" 'When the evidence does not give a change its date, the date is `null` and you ask the human for it.'
}

@test "a non-goal contradicted by an open epic is put to the human as a question" {
  contains "$FLAT" "When an open epic contradicts a stated non-goal, you say so and ask the human which one is true"
}

@test "a changed meaning always comes with a direction_change" {
  contains "$FLAT" 'Any change to what an entry means comes with a `direction_change`'
}

@test "when the repo already states its principles, values are refs and never restated" {
  contains "$FLAT" 'When the repo already states its principles on a page of its own, every value is a `ref` to that page'
  contains "$FLAT" "never a restatement of it"
}

@test "ids already in charter_so_far never change" {
  contains "$FLAT" 'An id already in `charter_so_far` never changes'
  contains "$FLAT" "never reused or renumbered"
}

@test "an entry that no longer holds is retired, never deleted" {
  contains "$FLAT" 'An entry is never deleted: one that no longer holds becomes `retired`'
}

# --- the rest of the turn contract -------------------------------------------

@test "mode is create with no charter and update with one" {
  contains "$FLAT" '`mode` is `create` (no charter yet) or `update` (the charter exists).'
  contains "$FLAT" '`charter_so_far` is the current `charter/v1` block in `update` mode, and `null` in `create` mode.'
}

@test "a direction change drafts its log entry and names what it retires, rewrites and adds, in one turn" {
  contains "$FLAT" 'In one turn you draft the log entry, name the entries it retires (`retires`) and rewrites (`rewrites`) and the ones it adds (`adds`)'
  contains "$FLAT" 'In `create` mode you also mine the history for changes that already happened and propose them as back-dated entries for the human to confirm.'
}

@test "a null date never reaches charter_block" {
  contains "$FLAT" 'A `null` date is never written into `charter_block`: the entry waits there until the human answers.'
}

@test "a new entry takes the next free number of its list" {
  contains "$FLAT" 'A new entry takes the next free number of its list'
  contains "$FLAT" 'a direction change takes `DC-<yyyy>-<mm>-<n>` from its date'
}

@test "a repo with no principles page gets statements, and personas are never defined here" {
  contains "$FLAT" 'A repo with no such page gets `statement`s.'
  contains "$FLAT" '`serves` holds persona ids from the repo'
  contains "$FLAT" 'you never define a persona here'
}

@test "ready_for_approval is true only when no question is open and both drafts are complete" {
  contains "$FLAT" '**`ready_for_approval`** — `true` only when `questions` is `[]` and both drafts are complete; otherwise `false`.'
}

@test "a candidate's kind is value, scope or non_goal, each with its evidence" {
  contains "$FLAT" 'each with `kind` (`value`, `scope` or `non_goal`), `proposed_id`, `text` and `evidence`'
}

@test "charter_block carries no provenance, and draft_prose omits the sentinels" {
  contains "$FLAT" '**No `provenance` field**: the skill stamps `generated_by` and `generated_at` and computes `prose_sha256` over the prose the human approves.'
  contains "$FLAT" 'Omit the sentinels and the `<details>` block: the skill renders those.'
  run jq -r '.charter_block | has("provenance")' "$OUT_JSON"
  [ "$output" = "false" ]
}

@test "it never fabricates evidence and never re-asks an answered question" {
  contains "$FLAT" '**Never fabricate evidence.**'
  contains "$FLAT" 'Never re-ask what the reply or the evidence already answered.'
}
