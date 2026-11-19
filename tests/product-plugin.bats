#!/usr/bin/env bats
#
# The `product` plugin shell (issue #3222, child 1 of #3202).
#
# `product` is the one plugin in the marketplace outside the language/topic
# model: it owns the charter, the persona registry and rendering, ships no
# gather script, dispatcher, resolve profile or review panel, and must work with
# `development` not installed. This suite pins the shell this story ships — the
# manifest, the marketplace entry, the byte-identical prose-hash copy and its
# independence from other plugins' directories — plus the ARCHITECTURE.md
# section that states the boundary, scoped to that section so a clause stated
# elsewhere in the document cannot satisfy it.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/product"
  PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
  MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"
  ENTRY='.plugins[] | select(.name == "product")'
  HASH_COPY="$PLUGIN_DIR/scripts/prose-hash.zsh"
  HASH_CANON="$REPO_ROOT/development/skills/refine-issue/scripts/story-spec-prose-hash.zsh"
  # terminated by a generic `^##` so the scope stops at the next heading of any
  # level, never widening into a sibling section
  SECTION="$(sed -n '/^### The `product` plugin — outside the language\/topic model/,/^##/p' \
               "$REPO_ROOT/ARCHITECTURE.md" | tr -s '[:space:]' ' ')"
  # the retired development names (#3225), each built from two halves so that
  # no line of this file holds either whole name and the sweep below cannot
  # match its own source
  OLD_CMD="/development"":define-personas"
  OLD_AGENT="development"":persona-definer"
}

@test "product plugin.json names the plugin and a version" {
  run jq -r .name "$PLUGIN_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "product" ]
  run jq -r .version "$PLUGIN_JSON"
  [ "$status" -eq 0 ]
  matches "$output" '^[0-9]+\.[0-9]+\.[0-9]+$'
}

@test "marketplace lists product from ./product with category product and plugin.json's version" {
  run jq -r "[$ENTRY] | length" "$MARKETPLACE"
  [ "$output" = "1" ]
  run jq -r "$ENTRY | .source" "$MARKETPLACE"
  [ "$output" = "./product" ]
  run jq -r "$ENTRY | .category" "$MARKETPLACE"
  [ "$output" = "product" ]
  local pv mv
  pv="$(jq -r .version "$PLUGIN_JSON")"
  mv="$(jq -r "$ENTRY | .version" "$MARKETPLACE")"
  [ -n "$pv" ]
  [ "$pv" = "$mv" ]
}

@test "product ships no gather script, maintenance dispatcher, resolve profile or review panel" {
  [ -d "$PLUGIN_DIR" ]
  run bash -c "ls -d '$PLUGIN_DIR'/scripts/gather-* 2>/dev/null"
  [ -z "$output" ]
  [ ! -e "$PLUGIN_DIR/skills/maintenance" ]
  [ ! -e "$PLUGIN_DIR/skills/resolve-profile" ]
  [ ! -e "$PLUGIN_DIR/skills/review" ]
  # maintenance discovers a plugin by a gather script in its own scripts dir,
  # not the plugin's: none may exist for product there
  local mscripts="$REPO_ROOT/development/skills/maintenance/scripts"
  [ -d "$mscripts" ]
  [ ! -e "$mscripts/gather-product-findings.zsh" ]
  [ ! -e "$mscripts/gather-product-findings.sh" ]
}

@test "the two prose-hash copies are byte-identical" {
  [ -s "$HASH_CANON" ]
  [ -x "$HASH_COPY" ]
  cmp "$HASH_COPY" "$HASH_CANON"
}

@test "nothing under product/ reaches into another plugin" {
  [ -d "$PLUGIN_DIR" ]
  run grep -rnF -e '../development' -e '/development/' "$PLUGIN_DIR"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "ARCHITECTURE.md states what product owns and that it is outside the language/topic model" {
  [ -n "$SECTION" ]
  contains "$SECTION" 'The **product charter**, the **persona registry**'
  contains "$SECTION" 'the **rendering** of product documents to PDF and ePub'
  contains "$SECTION" '**It is neither a language plugin nor a topic plugin.**'
  contains "$SECTION" 'maintenance discovery never sees it'
  contains "$SECTION" '**`development` refers to it by command name only**'
  contains "$SECTION" 'Nothing in `development` may fail when `product` is absent: a persona check that points at `product` stays advisory.'
  contains "$SECTION" "\`provenance.generated_by\` names \`$OLD_CMD\` stays valid"
  contains "$SECTION" 'no validator may reject the old value'
}

@test "the bats suite's PR path filter lists product/** (#3222)" {
  # in LIST-ENTRY form: the cmp test above is the only guard on the byte-identical
  # copy, and a product-only PR must run it at PR time, not after merge
  local paths
  paths="$(sed -n '/^  pull_request:/,/^  push:/p' "$REPO_ROOT/.github/workflows/script-tests.yml")"
  [ -n "$paths" ]
  contains "$paths" "      - 'product/**'"
}

@test "reference-drift triggers on product's skill and agent frontmatter, PR and push (#3222)" {
  # generate-docs-reference.py renders product's skills and agents; the
  # development* globs never match product/, so both lists name it explicitly
  local wf="$REPO_ROOT/.github/workflows/reference-drift.yml" pr push p
  pr="$(sed -n '/^  pull_request:/,/^  push:/p' "$wf")"
  push="$(sed -n '/^  push:/,/^permissions:/p' "$wf")"
  [ -n "$pr" ]
  [ -n "$push" ]
  for p in 'product/skills/**/SKILL.md' 'product/agents/*.md'; do
    contains "$pr" "      - \"$p\""
    contains "$push" "      - \"$p\""
  done
}

@test "define-personas and persona-definer ship in product with every self-reference renamed (#3223)" {
  local skill="$PLUGIN_DIR/skills/define-personas/SKILL.md" agent="$PLUGIN_DIR/agents/persona-definer.md"
  [ -s "$skill" ]
  [ -s "$agent" ]
  run sed -n '2p' "$skill"
  [ "$output" = "name: define-personas" ]
  run sed -n '2p' "$agent"
  [ "$output" = "name: persona-definer" ]
  local s a
  s="$(tr -s '[:space:]' ' ' < "$skill")"
  a="$(tr -s '[:space:]' ' ' < "$agent")"
  contains "$s" 'You are the **conductor** of `/product:define-personas`'
  contains "$s" '`subagent_type: product:persona-definer`'
  contains "$s" '"generated_by": "persona-definer via /product:define-personas"'
  contains "$a" 'Per-turn elicitation engine for /product:define-personas'
  contains "$a" '`/product:define-personas` skill (#667) drives the loop'
  contains "$s" 'or the human explicitly confirms a deliberate exception to a convention; record that exception in the prose and proceed to final approval.'
  contains "$a" 'or the human explicitly confirms a deliberate exception to a convention; record that exception in the prose and proceed to final approval.'
  contains "$s" 'A missing sentinel pair or an unparseable block counts as a mismatch: pass the whole file as `registry_prose` with registry-so-far empty, and Step 2 rewrites the whole file as in create.'
  contains "$s" 'unless Step 0 found no sentinel pair or an unparseable block: then compose the whole file as in create, heading and intro included.'
  run grep -nF -e "$OLD_CMD" -e "$OLD_AGENT" "$skill" "$agent"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "product's define-personas hashes the prose with product's own prose-hash.zsh (#3223)" {
  local skill="$PLUGIN_DIR/skills/define-personas/SKILL.md"
  [ -s "$skill" ]
  run grep -cF '"<skill-base-dir>/../../scripts/prose-hash.zsh" --file <prose.txt>' "$skill"
  [ "$output" = "1" ]
  run grep -nF 'story-spec-prose-hash.zsh' "$skill"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # the relative path resolves from the skill's base dir to the shipped script
  [ -x "$PLUGIN_DIR/skills/define-personas/../../scripts/prose-hash.zsh" ]
}

# The old-name sweep (#3225). Every tracked line naming a retired development
# name, outside the two exempt trees — docs/superpowers/ holds dated records and
# tests/fixtures/ holds test inputs — and outside recorded `generated_by`
# provenance lines, whose old value stays valid (ARCHITECTURE.md). Prints the
# offending lines; exits non-zero only when git itself fails.
old_name_hits() {
  local out rc
  out="$(git -C "$1" grep -nF -e "$OLD_CMD" -e "$OLD_AGENT" -- . \
           ':!docs/superpowers/' ':!tests/fixtures/')"
  rc=$?
  [ "$rc" -le 1 ] || return "$rc"
  printf '%s\n' "$out" | grep -vF 'generated_by' || true
}

@test "development no longer ships define-personas or persona-definer (#3225)" {
  run git -C "$REPO_ROOT" ls-files -- development/skills/define-personas development/agents/persona-definer.md
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$REPO_ROOT/development/skills/define-personas" ]
  [ ! -e "$REPO_ROOT/development/agents/persona-definer.md" ]
}

@test "no tracked file names the retired development command or agent type (#3225)" {
  run old_name_hits "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the sweep's own file holds neither retired name whole (#3225)" {
  [ -n "$OLD_CMD" ]
  [ -n "$OLD_AGENT" ]
  run grep -cF -e "$OLD_CMD" -e "$OLD_AGENT" "$BATS_TEST_FILENAME"
  [ "$output" = "0" ]
}

@test "the sweep finds a planted old name and spares the exempt trees and provenance lines (#3225)" {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  local d="$BATS_TEST_TMPDIR/sweep"
  mkdir -p "$d/docs/superpowers" "$d/tests/fixtures" "$d/development/agents"
  printf 'run %s\n' "$OLD_CMD" > "$d/docs/superpowers/plan.md"
  printf 'agent %s\n' "$OLD_AGENT" > "$d/tests/fixtures/f.md"
  printf '"generated_by": "persona-definer via %s"\n' "$OLD_CMD" > "$d/registry.md"
  git -C "$d" init -q
  git -C "$d" add -A
  run old_name_hits "$d"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'route to %s\n' "$OLD_CMD" > "$d/development/agents/a.md"
  printf 'dispatch %s\n' "$OLD_AGENT" > "$d/b.md"
  git -C "$d" add -A
  run old_name_hits "$d"
  [ "$status" -eq 0 ]
  contains "$output" "development/agents/a.md:1:route to $OLD_CMD"
  contains "$output" "b.md:1:dispatch $OLD_AGENT"
  # an untracked file is not in the tracked-file listing
  printf 'stray %s\n' "$OLD_CMD" > "$d/untracked.md"
  run old_name_hits "$d"
  [ "$status" -eq 0 ]
  lacks "$output" 'untracked.md'
}

@test "development routes a missing persona to /product:define-personas in the product plugin (#3225)" {
  local refiner readiness skill
  refiner="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/development/agents/issue-refiner.md")"
  readiness="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/development/agents/story-readiness.md")"
  # the routing note is a blockquote: drop each line's `> ` before joining
  skill="$(sed 's/^> *//' "$REPO_ROOT/development/skills/refine-issue/SKILL.md" | tr -s '[:space:]' ' ')"
  contains "$refiner" 'tell the human to run **`/product:define-personas`** to add or fix it — it ships in the `product` plugin'
  contains "$refiner" 'its absence never blocks the turn'
  contains "$readiness" '`/product:define-personas` to add or fix it — it ships in the `product` plugin, and the advisory stands whether or not that plugin is installed.'
  contains "$readiness" '`/product:define-personas` (it ships in the `product` plugin); an `implementation-pinned` advisory'
  contains "$skill" '`/product:define-personas`** to add or adjust the persona — it ships in the `product` plugin, and you never invoke that skill automatically.'
  contains "$skill" '**advisory**, whether or not `product` is installed'
  contains "$skill" 'route the human to **`/product:define-personas`** (in the `product` plugin, as in Step 2)'
}
