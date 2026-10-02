#!/usr/bin/env bats
#
# review-dispatch.zsh plan's `skippable_dimensions` (#2009): always present;
# a claude-plugin DELTA round builds the contract selector's two inputs from
# --prior-tree and emits ["contract"] when it says skip, [] otherwise; every
# full round and every other repo type emits [] without calling it. The
# SELECT_CONTRACT_BIN seam swaps in a stub that records each call and keeps the
# inputs it was handed, so "not called" and "built with whole-file context" are
# observed rather than inferred.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/review-dispatch.zsh"
  REAL_SEL="$REPO_ROOT/development/skills/resolve-issue/scripts/select-contract-dimension.zsh"

  DETECT="$BATS_TEST_TMPDIR/detect-stub.sh"
  printf '#!/usr/bin/env bash\necho "$DETECT_LANGS_JSON"\n' > "$DETECT"
  chmod +x "$DETECT"

  # The recording stub: counts calls, keeps the inputs, answers $STUB_ANSWER.
  CAP="$BATS_TEST_TMPDIR/cap"
  mkdir -p "$CAP"
  STUB_SEL="$BATS_TEST_TMPDIR/sel-stub.zsh"
  printf '%s\n' '#!/usr/bin/env zsh' \
    'print x >> "$CAP_DIR/calls"' \
    'cp -- "$2" "$CAP_DIR/files.json"; cp -- "$4" "$CAP_DIR/patch.diff"' \
    'if [[ -n "${STUB_ANSWER:-}" ]]; then print -r -- "$STUB_ANSWER"; else print -r -- "{\"contract\":\"skip\",\"triggers\":[]}"; fi' \
    'exit "${STUB_EXIT:-0}"' > "$STUB_SEL"
  chmod +x "$STUB_SEL"

  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/tests" "$R/dev/skills/x" "$R/dev/scripts"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  printf '#!/usr/bin/env bats\n' > "$R/tests/a.bats"
  { printf -- '---\nname: x\ndescription: does x\n---\n\n'
    for i in $(seq 1 60); do printf 'body line %s\n' "$i"; done; } > "$R/dev/skills/x/SKILL.md"
  { printf '#!/usr/bin/env zsh\n'
    for i in $(seq 1 30); do printf 'print step %s\n' "$i"; done; } > "$R/dev/scripts/tool.zsh"
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" branch -M main
}

tree_id() { zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/git-tree-id.zsh" "$R"; }

PLUGIN='{"languages":[],"is_claude_plugin":true}'

plan() {  # $1 = languages json ; $2 = selector bin ; rest = flags
  local langs="$1" sel="$2"; shift 2
  run --separate-stderr env DETECT_STACK_BIN="$DETECT" DETECT_LANGS_JSON="$langs" \
    SELECT_CONTRACT_BIN="$sel" CAP_DIR="$CAP" \
    zsh "$S" plan --repo "$R" --base main "$@"
}

calls() { [ -f "$CAP/calls" ] && wc -l < "$CAP/calls" | tr -d ' ' || echo 0; }

@test "round 1 on a claude-plugin repo: skippable_dimensions is [] and the selector is not called" {
  printf 'print new\n' >> "$R/dev/scripts/tool.zsh"
  plan "$PLUGIN" "$STUB_SEL" --round 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c .skippable_dimensions)" = '[]' ]
  [ "$(echo "$output" | jq -r .scope_mode)" = "full" ]
  [ "$(calls)" = 0 ]
}

@test "a --final sweep: skippable_dimensions is [] and the selector is not called" {
  printf 'print new\n' >> "$R/dev/scripts/tool.zsh"
  local t1; t1="$(tree_id)"
  printf 'load x\n' >> "$R/tests/a.bats"
  plan "$PLUGIN" "$STUB_SEL" --round 4 --final --prior-tree "$t1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c .skippable_dimensions)" = '[]' ]
  [ "$(calls)" = 0 ]
}

@test "a skipping delta (bats-only fix pass) emits [\"contract\"]" {
  printf 'print new\n' >> "$R/dev/scripts/tool.zsh"
  local t1; t1="$(tree_id)"
  printf 'load x\n' >> "$R/tests/a.bats"
  plan "$PLUGIN" "$REAL_SEL" --round 3 --prior-tree "$t1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .scope_mode)" = "delta" ]
  [ "$(echo "$output" | jq -c .skippable_dimensions)" = '["contract"]' ]
}

@test "a triggering delta (a usage line in a shipped script) emits []" {
  local t1; t1="$(tree_id)"
  printf 'print -u2 "usage: tool"\n' >> "$R/dev/scripts/tool.zsh"
  plan "$PLUGIN" "$REAL_SEL" --round 3 --prior-tree "$t1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c .skippable_dimensions)" = '[]' ]
}

@test "a non-claude-plugin delta emits [] and never calls the selector" {
  local t1; t1="$(tree_id)"
  printf 'load x\n' >> "$R/tests/a.bats"
  plan '{"languages":["python"]}' "$STUB_SEL" --round 3 --prior-tree "$t1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .scope_mode)" = "delta" ]
  [ "$(echo "$output" | jq -c .skippable_dimensions)" = '[]' ]
  [ "$(calls)" = 0 ]
}

@test "the patch build: a SKILL.md body edit far below the frontmatter is one whole-file hunk, a script line is -U0" {
  local t1; t1="$(tree_id)"
  sed -i.bak 's/^body line 55$/body line fifty-five/' "$R/dev/skills/x/SKILL.md" && rm "$R/dev/skills/x/SKILL.md.bak"
  sed -i.bak 's/^print step 20$/print step twenty/' "$R/dev/scripts/tool.zsh" && rm "$R/dev/scripts/tool.zsh.bak"
  mkdir -p "$R/.review" && printf '[]\n' > "$R/.review/findings-round-3.json"   # loop state: excluded
  plan "$PLUGIN" "$STUB_SEL" --round 3 --prior-tree "$t1"
  [ "$status" -eq 0 ]
  [ "$(calls)" = 1 ]
  [ "$(jq -c 'sort_by(.path)' "$CAP/files.json")" = '[{"status":"M","path":"dev/scripts/tool.zsh"},{"status":"M","path":"dev/skills/x/SKILL.md"}]' ]
  # the SKILL.md section: exactly one hunk, starting at line 1 on both sides
  skill_hunks="$(awk '/^diff --git /{on = ($0 ~ /SKILL\.md/)} on && /^@@ /' "$CAP/patch.diff")"
  [ "$(printf '%s\n' "$skill_hunks" | wc -l | tr -d ' ')" = 1 ]
  starts_with "$skill_hunks" "@@ -1,65 +1,65 @@"
  # the script section: zero context, the one changed line alone
  script_hunks="$(awk '/^diff --git /{on = ($0 ~ /tool\.zsh/)} on && /^@@ /' "$CAP/patch.diff")"
  [ "$(printf '%s\n' "$script_hunks" | wc -l | tr -d ' ')" = 1 ]
  starts_with "$script_hunks" "@@ -21 +21 @@"
  # the stub answered skip, so the plan says so
  [ "$(echo "$output" | jq -c .skippable_dimensions)" = '["contract"]' ]
}

@test "fail-closed: a selector that fails or answers anything but skip leaves skippable_dimensions []" {
  local t1; t1="$(tree_id)"
  printf 'load x\n' >> "$R/tests/a.bats"
  STUB_EXIT=1 plan "$PLUGIN" "$STUB_SEL" --round 3 --prior-tree "$t1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c .skippable_dimensions)" = '[]' ]
  contains "$stderr" 'the contract selector could not decide (fail-closed: contract runs)'
  STUB_ANSWER='not json' plan "$PLUGIN" "$STUB_SEL" --round 3 --prior-tree "$t1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c .skippable_dimensions)" = '[]' ]
  STUB_ANSWER='{"contract":"run","triggers":["heading"]}' plan "$PLUGIN" "$STUB_SEL" --round 3 --prior-tree "$t1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c .skippable_dimensions)" = '[]' ]
  lacks "$stderr" 'could not decide'
}

@test "skippable_dimensions is always present, directly after delta_hunks" {
  plan '{"languages":["python"]}' "$STUB_SEL" --round 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[keys_unsorted[]] | index("skippable_dimensions") - index("delta_hunks")')" = 1 ]
}
