#!/usr/bin/env bats
#
# The `composition` topic marker (#1747, child 4 of epic #687): a
# `.claude-workspace.yaml` FILE at the repo root.
#
# Like tests/opentofu-topic-marker.bats, these tests do not re-implement the
# recipe: they extract the authoritative one from development/skills/maintenance/
# SKILL.md (between the `# composition-marker:begin` / `:end` sentinels) and
# eval it, so the suite proves things about the artifact the orchestrator
# follows rather than about a copy.
#
# The second job is 3-WAY PARITY. The rule is stated three times — SKILL.md's
# recipe, gather-composition-findings.zsh's `gather-composition-marker` block
# and detect-stack.sh's `is-composition-marker` block — and the test operator
# and the path are DERIVED from each below rather than trusted: a marker that
# fires where the gather does not would dispatch an empty topic, and one that
# the gather honours but the orchestrator never fires would never run at all.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO_ROOT/development/skills/maintenance/SKILL.md"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-composition-findings.zsh"
  DETECT="$REPO_ROOT/development/skills/bootstrap/scripts/detect-stack.sh"
  W="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$W"

  # one sentinel pair per copy, and a bounded extraction: an unterminated sed
  # range would otherwise eval the rest of SKILL.md
  [ "$(grep -c '^# composition-marker:begin$' "$SKILL")" -eq 1 ]
  [ "$(grep -c '^# composition-marker:end$' "$SKILL")" -eq 1 ]
  RECIPE="$(sed -n '/^# composition-marker:begin$/,/^# composition-marker:end$/p' "$SKILL" | grep -v '^#')"
  [ -n "$RECIPE" ]
  [ "$(printf '%s\n' "$RECIPE" | wc -l)" -le 3 ]

  [ "$(grep -c '^# gather-composition-marker:begin$' "$GATHER")" -eq 1 ]
  [ "$(grep -c '^# gather-composition-marker:end$' "$GATHER")" -eq 1 ]
  GATHER_BLOCK="$(sed -n '/^# gather-composition-marker:begin$/,/^# gather-composition-marker:end$/p' "$GATHER" | grep -v '^#')"
  [ -n "$GATHER_BLOCK" ]
  [ "$(printf '%s\n' "$GATHER_BLOCK" | wc -l)" -le 3 ]

  [ "$(grep -c '^# is-composition-marker:begin$' "$DETECT")" -eq 1 ]
  [ "$(grep -c '^# is-composition-marker:end$' "$DETECT")" -eq 1 ]
  DETECT_BLOCK="$(sed -n '/^# is-composition-marker:begin$/,/^# is-composition-marker:end$/p' "$DETECT" | grep -v '^#')"
  [ -n "$DETECT_BLOCK" ]
  [ "$(printf '%s\n' "$DETECT_BLOCK" | wc -l)" -le 3 ]
}

# evaluate the SKILL.md recipe inside $1 and return its status
marker() {
  ( cd "$1" && eval "$RECIPE" )
}

# the `test <op> <path>` of a block, with the copy's own root variable
# (`$repo/`, `$cwd/`) stripped, so the three copies compare as one rule
rule_of() {
  printf '%s\n' "$1" | grep -oE 'test -[a-z] "?(\$[a-z]+/)?\.claude-workspace\.yaml' \
    | sed -E 's/"?\$[a-z]+\///; s/"//g'
}

# --- the recipe ---------------------------------------------------------------

@test "the recipe fires on a root .claude-workspace.yaml" {
  printf 'members: []\n' > "$W/.claude-workspace.yaml"
  run -0 marker "$W"
}

@test "the recipe answers exactly 1 on a repo without one" {
  run -1 marker "$W"
}

@test "a NESTED manifest is not a composition repo — root only" {
  # the placement rule: the manifest lives at a composition repo's root, and a
  # nested copy (a fixture, an example) must not classify the repo
  mkdir -p "$W/examples/demo"
  printf 'members: []\n' > "$W/examples/demo/.claude-workspace.yaml"
  run -1 marker "$W"
}

@test "a DIRECTORY named .claude-workspace.yaml is not a manifest" {
  mkdir -p "$W/.claude-workspace.yaml"
  run -1 marker "$W"
}

@test "a symlinked manifest still counts" {
  printf 'members: []\n' > "$W/real.yaml"
  ln -s real.yaml "$W/.claude-workspace.yaml"
  run -0 marker "$W"
}

# --- 3-way parity ---------------------------------------------------------------

@test "the operator and path are identical across all three copies" {
  local a b c
  a="$(rule_of "$RECIPE")"
  b="$(rule_of "$GATHER_BLOCK")"
  c="$(rule_of "$DETECT_BLOCK")"
  [ "$a" = "test -f .claude-workspace.yaml" ]
  [ "$a" = "$b" ]
  [ "$a" = "$c" ]
}

@test "SKILL.md registers the topic, its gather and its (absent) language gate" {
  local row gate
  row="$(grep -E '^\| `composition` \|' "$SKILL" | head -n1)"
  [ -n "$row" ]
  contains "$row" '`gather-composition-findings.zsh`'
  contains "$row" '`.claude-workspace.yaml`'
  gate="$(grep -cE '^\| `composition` \| none \|$' "$SKILL")"
  [ "$gate" -eq 1 ]
  [ -x "$GATHER" ]
}

# --- detect-stack ---------------------------------------------------------------

@test "detect-stack agrees with the marker on a composition repo" {
  printf 'members: []\n' > "$W/.claude-workspace.yaml"
  run -0 marker "$W"
  run -0 bash -c "cd '$W' && bash '$DETECT' | jq -e '.is_composition == true' >/dev/null"
}

@test "detect-stack agrees with the marker on a repo without one — and emits a real boolean" {
  mkdir -p "$W/examples"
  printf 'members: []\n' > "$W/examples/.claude-workspace.yaml"
  run -1 marker "$W"
  # `== false`, never `| not`: `null | not` is true, so the weaker form would pass
  # if the key were dropped from the envelope
  run -0 bash -c "cd '$W' && bash '$DETECT' | jq -e '.is_composition == false' >/dev/null"
}

@test "detect-stack rejects a directory named .claude-workspace.yaml too" {
  mkdir -p "$W/.claude-workspace.yaml"
  run -0 bash -c "cd '$W' && bash '$DETECT' | jq -e '.is_composition == false' >/dev/null"
}

# --- the gather ------------------------------------------------------------------

@test "the gather agrees with the marker on a repo without one: nothing configured, and a note" {
  run -1 marker "$W"
  # a gh stub first on PATH that logs every call: nothing may be gathered, and
  # a regression that dropped the marker check must not reach the real gh
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  printf '#!/bin/sh\necho "$*" >> "%s/gh.log"\necho "[]"\n' "$BATS_TEST_TMPDIR" >"$bin/gh"
  chmod +x "$bin/gh"
  : >"$BATS_TEST_TMPDIR/gh.log"
  run -0 env PATH="$bin:$PATH" zsh "$GATHER" "$W"
  [ ! -s "$BATS_TEST_TMPDIR/gh.log" ]
  jq -e '.tooling_configured == {workspace_validation: false, tag_bump: false}' <<<"$output" >/dev/null
  jq -e '.findings_by_tool == {}' <<<"$output" >/dev/null
  jq -e '.notes | length == 1 and (.[0] | contains("not a composition repo"))' <<<"$output" >/dev/null
}

# --- bootstrap reads the key as a GUARD, never as an entry --------------------------

@test "bootstrap guards a composition re-run instead of asking for a language or rewriting the primary" {
  # a plain /development:bootstrap on a repo §3m already scaffolded must not
  # reach Q4 or §3l's conflict branch, which would offer to rewrite
  # `primary: composition` to `kubernetes`
  local skill step1 flat
  skill="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  step1="$(sed -n '/^## Step 1: Detect Repo State/,/^Run the stack detection script/p' "$skill" | tr -s '[:space:]' ' ')"
  [ -n "$step1" ]
  contains "$step1" '**It does guard on it.**'
  # the trigger, whole: ONLY a run the user did not ask to be a composition run
  # (a deliberate request must still reach §3m), on the detect-stack key OR the
  # recorded primary — not just one of them
  contains "$step1" 'When the user did **not** ask for a composition repo but `is_composition: true` or `.maintenance.yml` records `primary: composition`'
  contains "$step1" 'do **not** ask Q4'
  contains "$step1" "do **not** take §3l's conflict branch"
  contains "$step1" '**never** offer to change the recorded primary'
  # …and it ends the run rather than falling through to the generic path, split on
  # what detection ALSO reports (#1929): a marker beside a language or IaC is a mixed
  # repo §3m itself refuses, so that branch stops WITHOUT offering §3m
  contains "$step1" '**Detection also reports any language, `is_kubernetes: true` or `is_opentofu: true`**'
  contains "$step1" 'Report that a `.claude-workspace.yaml` (or a recorded `primary: composition`) sits in a repo holding application code or IaC'
  contains "$step1" "which the manifest's placement rule forbids, and stop without offering §3m"
  # the §3m re-run offer survives only in the no-language, no-IaC branch
  contains "$step1" '**Otherwise** → this is a repo §3m already scaffolded. Report that this is a composition repo, ask whether to re-run §3m, and stop'
  lacks "$step1" 'already scaffolded: do **not** ask Q4'
  # "§3m refuses the same mix" holds only while §3m really stops on it
  local s3m
  s3m="$(sed -n '/^### 3m\./,/^## Step 4/p' "$skill" | tr -s '[:space:]' ' ')"
  [ -n "$s3m" ]
  contains "$s3m" 'when it reports any language, `is_kubernetes: true` or `is_opentofu: true`, **stop the run** — do not fall back to the language or §3l path'
  # the key list describes the same contract, not "emitted only"
  local keylist
  keylist="$(sed -n '/^- `is_composition` —/,/^- `interfaces` —/p' "$skill" | tr -s '[:space:]' ' ')"
  [ -n "$keylist" ]
  contains "$keylist" 'Step 1 **guards** on it'
  lacks "$keylist" 'Emitted only'
  flat="$(tr -s '[:space:]' ' ' <"$skill")"
  contains "$flat" 'A recorded `primary: composition` never reaches this branch'
}
