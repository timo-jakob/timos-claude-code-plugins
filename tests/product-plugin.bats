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
  contains "$SECTION" '`provenance.generated_by` names `/development:define-personas` stays valid'
  contains "$SECTION" 'no validator may reject the old value'
}
