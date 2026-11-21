#!/usr/bin/env bats
#
# /product:define-charter (#3207, task 6 of #3195): the conductor that gathers
# evidence, loops the charter-definer agent, writes the approved charter, then
# validates and renders it. It is prose, so this suite pins the sentences that
# carry its behaviour — the step order, each lookup branch, the evidence list,
# the loop's relay rules, the write and its provenance, validate-then-render,
# the .gitignore line, the nav-entry note, the closing report, the persona gap,
# and the "no charter, no guessing" rule in ARCHITECTURE.md. The input example
# is parsed and its keys checked against the agent's own input example, so the
# skill and the agent cannot drift apart.
#
# Anchored by content, never by line number (#1189).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO_ROOT/product/skills/define-charter/SKILL.md"
  AGENT="$REPO_ROOT/product/agents/charter-definer.md"
  # the whole file with every whitespace run collapsed to one space, so a pin
  # survives re-wrapping
  FLAT="$(tr -s '[:space:]' ' ' < "$SKILL")"
  ARCH_FLAT="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/ARCHITECTURE.md")"
  # the frontmatter alone: the lines between the first two `---`
  FRONT="$(awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside { print }' "$SKILL")"
  # the first fenced json block under `## Step 1`, the agent input the skill builds
  IN_JSON="$BATS_TEST_TMPDIR/skill-input.json"
  awk '/^## Step 1/ { sec = 1; next } sec && /^## / { exit } sec && /^```json$/ { inb = 1; next } inb && /^```$/ { exit } inb { print }' "$SKILL" > "$IN_JSON"
  # the agent's own input example, the contract the skill must feed
  AGENT_IN_JSON="$BATS_TEST_TMPDIR/agent-input.json"
  awk '/^## Input/ { sec = 1; next } sec && /^## / { exit } sec && /^```json$/ { inb = 1; next } inb && /^```$/ { exit } inb { print }' "$AGENT" > "$AGENT_IN_JSON"
}

# --- frontmatter ------------------------------------------------------------

@test "frontmatter names the skill define-charter and describes the charter/v1 write" {
  run grep -c '^name: define-charter$' <<<"$FRONT"
  [ "$output" = "1" ]
  FRONT_FLAT="$(tr -s '[:space:]' ' ' <<<"$FRONT")"
  contains "$FRONT_FLAT" "docs/product/charter.md"
  contains "$FRONT_FLAT" "charter-definer"
  contains "$FRONT_FLAT" "It does not commit or push."
}

# --- the step order ---------------------------------------------------------

@test "the steps come in order: lookup, evidence, loop, write, validate and render, report" {
  run grep -E '^## ' "$SKILL"
  [ "$status" -eq 0 ]
  expected="$(printf '%s\n' \
    '## Step 0 — find the charter and set the mode' \
    '## Step 0b — gather the evidence' \
    '## Step 1 — the charter loop (human present)' \
    '## Step 2 — write the approved charter (working tree)' \
    '## Step 3 — validate, then render' \
    '## Step 4 — the closing report' \
    '## Guardrails')"
  [ "$output" = "$expected" ]
}

# --- Step 0: the lookup branches --------------------------------------------

@test "the mode comes from the product-document lookup on docs/product/charter.md" {
  contains "$FLAT" '"<skill-base-dir>/../../scripts/resolve-product-doc.zsh" --repo <target repo root> docs/product/charter.md'
  contains "$FLAT" 'The **mode is inferred** through the product-document lookup (Step 0); you never ask for it.'
}

@test "lookup origin own means update mode" {
  contains "$FLAT" '**exit 0, origin `own`** → **update**.'
}

@test "lookup exit 3 means create mode" {
  contains "$FLAT" '**exit 3** (not found anywhere) → **create**. The charter so far is `null`.'
}

@test "a linked charter is named and the skill stops without writing" {
  contains "$FLAT" '**exit 0, origin `linked:<submodule path>`** → this repo has no charter of its own, and the product'"'"'s charter lives in a linked repository. **Stop without writing anything.**'
  contains "$FLAT" 'Tell the human the product'"'"'s charter lives in the linked repository at `<submodule path>`, at `<absolute path>`'
}

@test "lookup exit 4 relays the init line and stops without writing" {
  contains "$FLAT" '**exit 4** (a declared submodule is not initialised, and it could hold the charter) → **stop without writing anything**. Relay the lookup'"'"'s stderr, which names the submodule and its `git submodule update --init` line'
}

@test "lookup exit 5, 1 and 2 stop without writing" {
  contains "$FLAT" '**exit 5** (`docs/product/charter.md` lies inside a declared submodule'"'"'s mount, and no submodule holds it at that path) → **stop without writing anything**.'
  contains "$FLAT" '**exit 1 or 2** → **stop without writing anything** and report the stderr.'
}

@test "recording a direction change is a first-class path in update mode" {
  contains "$FLAT" '**Recording a direction change is a first-class path in update mode.**'
  contains "$FLAT" 'it is the first turn'"'"'s `latest_reply`, not a question for you to answer'
}

@test "a stale block in update mode is reported and the prose goes to the agent" {
  contains "$FLAT" 'tell the human the machine block is stale (the prose was edited after it was generated)'
  contains "$FLAT" 'A missing sentinel pair or an unparseable block **stops the skill without writing anything**: tell the human what is missing, since a draft made without the block'"'"'s ids could reuse them.'
}

# --- Step 0b: the evidence --------------------------------------------------

@test "the evidence list names every source the agent mines" {
  contains "$FLAT" '- the README;'
  contains "$FLAT" '- the explanation pages under `docs/`'
  contains "$FLAT" '- the persona registry, found through the same lookup with `docs/personas.md` — never by a path of your own;'
  contains "$FLAT" '- the ARCHITECTURE.md positions, when the repo has one;'
  contains "$FLAT" '- `.maintenance.yml`, when present;'
  contains "$FLAT" '- the titles of open and recently closed epics'
  contains "$FLAT" '- the issues closed as not planned'
}

@test "a missing persona or registry names /product:define-personas and the session continues" {
  contains "$FLAT" 'name `/product:define-personas` to the human and continue: `serves` stays as it is'
  contains "$FLAT" 'with no registry anywhere it stays empty, which the validator allows'
}

# --- Step 1: the loop -------------------------------------------------------

@test "each round calls the charter-definer agent" {
  contains "$FLAT" '`subagent_type: product:charter-definer`'
}

@test "the input the skill builds carries exactly the agent's input keys" {
  run jq -c 'keys' "$IN_JSON"
  [ "$status" -eq 0 ]
  skill_keys="$output"
  run jq -c 'keys' "$AGENT_IN_JSON"
  [ "$status" -eq 0 ]
  [ "$skill_keys" = "$output" ]
  [ "$skill_keys" = '["charter_so_far","conversation","evidence","latest_reply","mode","previous_turn"]' ]
}

@test "the skill relays the agent's questions and never adds its own" {
  contains "$FLAT" '**Relay the agent'"'"'s questions; never add questions of your own.**'
}

@test "the loop stops on approval and nothing is written before it" {
  contains "$FLAT" '**Stop looping on approval:** when `ready_for_approval` is `true`'
  contains "$FLAT" 'get the human'"'"'s **explicit approval of the exact charter**'
  contains "$FLAT" 'Nothing is written before they approve.'
}

@test "the skill cites pillar 2 by its published page and never by a relative path" {
  run grep -cE '^\[Never asks "how"\]\(https://timo-jakob\.github\.io/timos-claude-code-plugins/explanation/philosophy/#pillar-2\)$' "$SKILL"
  [ "$output" = "1" ]
  run grep -c 'philosophy\.md' "$SKILL"
  [ "$output" = "0" ]
}

# --- Step 2: the write ------------------------------------------------------

@test "the write puts the prose between the charter sentinels and the block in a details element" {
  run grep -c '^   <!-- charter:prose:start -->$' "$SKILL"
  [ "$output" = "1" ]
  run grep -c '^   <!-- charter:prose:end -->$' "$SKILL"
  [ "$output" = "1" ]
  contains "$FLAT" 'Write `docs/product/charter.md` in the **working tree**'
}

@test "provenance carries a fresh prose hash from prose-hash.zsh and the generated_by string" {
  contains "$FLAT" 'PROSE_HASH=$("<skill-base-dir>/../../scripts/prose-hash.zsh" --file <prose.txt>)'
  contains "$FLAT" '"generated_by": "charter-definer via /product:define-charter"'
  contains "$FLAT" 'The hash is always fresh, over the approved prose: never carry the old one over.'
}

# --- Step 3: validate, then render ------------------------------------------

@test "the validator runs before the renderer" {
  run awk '/validate-charter\.zsh" docs\/product\/charter\.md/ && !v { v = NR } /render-document\.zsh" docs\/product\/charter\.md/ && !r { r = NR } END { print (v > 0 && r > v) ? "ordered" : "unordered" }' "$SKILL"
  [ "$output" = "ordered" ]
}

@test "a failed validation or render is reported with its output, never as success" {
  contains "$FLAT" '**A failure of either is reported with its output and never as success.**'
  contains "$FLAT" 'report every `charter: <rule>: <detail>` line verbatim and do not render. The Markdown stays written'
  contains "$FLAT" 'report the exit code and the renderer'"'"'s stderr verbatim'
}

@test "dist/product/ is added to .gitignore when not already ignored" {
  contains "$FLAT" 'When `git check-ignore -q dist/product/` says it is not already ignored, add `dist/product/` to the target repo'"'"'s `.gitignore`'
}

@test "the skill does not commit or push" {
  contains "$FLAT" 'The skill does not commit or push: the change lands through the normal PR flow'
  contains "$FLAT" 'No commit, no push, no PR.'
}

# --- Step 4: the closing report ---------------------------------------------

@test "the closing report gives both paths, the DRAFT note and the sendable-copy command" {
  contains "$FLAT" '**Both output paths**, the PDF and the ePub'
  contains "$FLAT" '**The PDF is a DRAFT until the file is committed**: the charter was just written and not committed, so the cover says DRAFT.'
  contains "$FLAT" '**The one command that renders the sendable copy**, once `docs/product/charter.md` is committed'
}

@test "a repo with a mkdocs.yml is told the page needs a nav entry" {
  contains "$FLAT" '**When the repo has a `mkdocs.yml`**, the closing line says the new page `docs/product/charter.md` needs a nav entry'
  contains "$FLAT" 'The skill never edits the site configuration.'
}

# --- the plugin boundary ----------------------------------------------------

@test "every script the skill names exists in the product plugin" {
  run grep -oE '\.\./\.\./scripts/[a-z-]+\.zsh' "$SKILL"
  [ "$status" -eq 0 ]
  while IFS= read -r ref; do
    [ -f "$REPO_ROOT/product/scripts/${ref#../../scripts/}" ]
  done <<<"$output"
}

@test "the skill names no path into another plugin" {
  run grep -cE '(^|[^a-z/])development[a-z-]*/' "$SKILL"
  [ "$output" = "0" ]
}

# --- ARCHITECTURE.md --------------------------------------------------------

@test "ARCHITECTURE.md states the no-charter-no-guessing rule for every product skill" {
  contains "$ARCH_FLAT" '**No charter, no guessing.** Every product skill that needs the charter finds it with the lookup, and when the lookup finds none it offers to run `/product:define-charter` then and there'
  contains "$ARCH_FLAT" 'names that repository as the place to run it — and does not proceed on an assumed direction.'
}

@test "ARCHITECTURE.md states how define-charter writes, validates and renders" {
  contains "$ARCH_FLAT" 'On the human'"'"'s approval it writes the charter, then runs `validate-charter.zsh`, then `render-document.zsh`; a failure of either is reported with its output and never as success. It does not commit or push.'
}

# --- the rest of the conductor's rules --------------------------------------

@test "a product has one charter, and a linked one is never shadowed" {
  contains "$FLAT" 'A product has one charter; never create a second one here.'
  contains "$FLAT" '**Never shadow a linked charter.** When the lookup finds the charter in a linked submodule, never create a second one here: Step 0 stops without writing.'
}

@test "an update replaces only the prose region and the block, never appending a second" {
  contains "$FLAT" 'keep the existing heading and intro, which sit outside the hashed region, and replace only the sentinel prose region and the `<details>` block'
  contains "$FLAT" 'In update mode replace the old region and block in place; never append a second.'
  contains "$FLAT" 'Confirm the block is valid JSON (`jq -e` the fenced object), then write the file.'
}

@test "an invalid charter offers another round, and an incomplete check is not a verdict" {
  contains "$FLAT" 'Offer the human another round of the loop with the violations as `latest_reply`, which ends in a fresh write and a fresh validation.'
  contains "$FLAT" 'A `stale-prose` line, or a `schema` line about the sentinels or the `<details>` block, is your own write'"'"'s fault: redo Step 2 and validate again, with no agent round.'
  contains "$FLAT" '**exit 2** → report the stderr; the check could not complete, which is not a verdict, and you do not render.'
}

@test "the agent is a pure function and the conductor never authors entries" {
  contains "$FLAT" 'The agent is a **pure function**: it never writes the charter or touches > GitHub.'
  contains "$FLAT" 'Never author charter entries yourself; spawn `product:charter-definer`. Never let the agent write files or GitHub.'
}

@test "ids are forever and entries are never deleted" {
  contains "$FLAT" '**Ids are forever, entries are never deleted.** In update mode an entry keeps its id, and one that no longer holds is retired by a direction change.'
}

@test "the epics and not-planned issues are read with gh" {
  contains "$FLAT" 'as a path and an excerpt, from the target repo root, so the agent'"'"'s first proposals are grounded and you can tell the human what they rest on and which source a failed command left out:'
  contains "$FLAT" '(`gh issue list --label epic --state all`)'
  contains "$FLAT" '(`gh issue list --state closed --search '"'"'reason:"not planned"'"'"'`)'
}

@test "previous_turn is passed back unchanged and charter_so_far follows the mode" {
  contains "$FLAT" '`charter_so_far` is the parsed block in update mode, `null` in create.'
  contains "$FLAT" '`previous_turn` is the object the agent returned last round, passed back unchanged, and `null` on the first.'
}
