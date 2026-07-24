#!/usr/bin/env bats
#
# Behavioral tests for toggle-fable.zsh — the on/off switch that flips every
# agent with a frontmatter `model: fable` to `model: opus` and back (issue #990).
#
# The script derives its repo root from its own location (${0:A:h:h}), so each
# test runs a COPY of it placed inside a synthetic plugin tree built in the
# test tmpdir, where its root resolves to that fixture.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK/scripts"
  cp "$REPO_ROOT/scripts/toggle-fable.zsh" "$WORK/scripts/toggle-fable.zsh"
  TOGGLE="$WORK/scripts/toggle-fable.zsh"
  MANIFEST="$WORK/scripts/.fable-agents"

  mkdir -p "$WORK/plugin-a/agents" "$WORK/plugin-b/agents"

  # plugin-a/one   — fable in frontmatter, AND a "model: fable" line in the body
  #                  PLUS a "model: fable" mention in the frontmatter description
  #                  (the frontmatter-scoping / prose false-positive guard).
  cat > "$WORK/plugin-a/agents/one.md" <<'EOF'
---
name: one
description: an agent that talks about model: fable in its description
model: fable
tools: Read
---

Body prose that literally says model: fable and must survive untouched.
EOF

  # plugin-a/two   — opus, must never be touched in either direction.
  cat > "$WORK/plugin-a/agents/two.md" <<'EOF'
---
name: two
description: already opus
model: opus
tools: Read
---

Body.
EOF

  # plugin-b/three — a second fable agent, in a different plugin.
  cat > "$WORK/plugin-b/agents/three.md" <<'EOF'
---
name: three
description: fable
model: fable
tools: Read
---

Body.
EOF

  # plugin-b/four  — haiku, must never be touched.
  cat > "$WORK/plugin-b/agents/four.md" <<'EOF'
---
name: four
description: haiku
model: haiku
tools: Read
---

Body.
EOF

  # plugin-b/five  — sonnet, must never be touched (AC names sonnet explicitly).
  cat > "$WORK/plugin-b/agents/five.md" <<'EOF'
---
name: five
description: sonnet
model: sonnet
tools: Read
---

Body.
EOF
}

# tree_hash — a stable digest of every agent .md file, for round-trip checks.
tree_hash() {
  find "$WORK" -path '*/agents/*.md' | sort | xargs shasum | shasum | awk '{print $1}'
}

fm_model() {  # frontmatter model value of a file
  sed -n '1,/^---$/p' "$1" | sed -n 's/^model: //p'
}

@test "off: exits 0, flips both fable agents to opus" {
  run zsh "$TOGGLE" off
  [ "$status" -eq 0 ]
  [ "$(fm_model "$WORK/plugin-a/agents/one.md")" = "opus" ]
  [ "$(fm_model "$WORK/plugin-b/agents/three.md")" = "opus" ]
}

@test "off: leaves opus, haiku and sonnet agents untouched" {
  zsh "$TOGGLE" off
  [ "$(fm_model "$WORK/plugin-a/agents/two.md")" = "opus" ]
  [ "$(fm_model "$WORK/plugin-b/agents/four.md")" = "haiku" ]
  [ "$(fm_model "$WORK/plugin-b/agents/five.md")" = "sonnet" ]
}

@test "off: writes a manifest listing exactly the fable agents" {
  zsh "$TOGGLE" off
  [ -f "$MANIFEST" ]
  run wc -l < "$MANIFEST"
  [ "$(tr -d ' ' <<< "$output")" -eq 2 ]
  grep -q "plugin-a/agents/one.md" "$MANIFEST"
  grep -q "plugin-b/agents/three.md" "$MANIFEST"
  run ! grep -q "two.md" "$MANIFEST"
  run ! grep -q "four.md" "$MANIFEST"
  run ! grep -q "five.md" "$MANIFEST"
}

@test "off: only the frontmatter model line changes; body and description survive" {
  zsh "$TOGGLE" off
  # body prose mentioning model: fable is untouched
  grep -q "^Body prose that literally says model: fable" "$WORK/plugin-a/agents/one.md"
  # the in-frontmatter description line (inside the sed range) is untouched too
  grep -q "talks about model: fable in its description" "$WORK/plugin-a/agents/one.md"
}

@test "off then on: byte-identical round trip" {
  before="$(tree_hash)"
  zsh "$TOGGLE" off
  [ "$(tree_hash)" != "$before" ]   # off actually changed something
  zsh "$TOGGLE" on
  [ "$(tree_hash)" = "$before" ]
}

@test "on: restores exactly the manifest agents to fable" {
  zsh "$TOGGLE" off
  run zsh "$TOGGLE" on
  [ "$status" -eq 0 ]
  [ "$(fm_model "$WORK/plugin-a/agents/one.md")" = "fable" ]
  [ "$(fm_model "$WORK/plugin-b/agents/three.md")" = "fable" ]
}

@test "on: never promotes a non-manifest opus/haiku/sonnet agent to fable" {
  zsh "$TOGGLE" off
  zsh "$TOGGLE" on
  [ "$(fm_model "$WORK/plugin-a/agents/two.md")" = "opus" ]
  [ "$(fm_model "$WORK/plugin-b/agents/four.md")" = "haiku" ]
  [ "$(fm_model "$WORK/plugin-b/agents/five.md")" = "sonnet" ]
}

@test "on: a manifest agent deliberately changed away from opus is left alone" {
  zsh "$TOGGLE" off
  # simulate a human committing one.md as haiku after the off snapshot
  sed '1,/^---$/ s/^model: opus$/model: haiku/' "$WORK/plugin-a/agents/one.md" > "$WORK/t"
  mv "$WORK/t" "$WORK/plugin-a/agents/one.md"
  run zsh "$TOGGLE" on
  [ "$status" -eq 0 ]
  [ "$(fm_model "$WORK/plugin-a/agents/one.md")" = "haiku" ]   # NOT promoted to fable
  [[ "$output" == *"leaving it alone"* ]]
  # the other manifest agent still restored
  [ "$(fm_model "$WORK/plugin-b/agents/three.md")" = "fable" ]
}

@test "on: a manifest agent whose file was deleted is skipped, run still succeeds" {
  zsh "$TOGGLE" off
  rm "$WORK/plugin-b/agents/three.md"
  run zsh "$TOGGLE" on
  [ "$status" -eq 0 ]
  [[ "$output" == *"no longer exists"* ]]
  [ "$(fm_model "$WORK/plugin-a/agents/one.md")" = "fable" ]   # survivor restored
  [[ "$output" == *"Restored 1 agent"* ]]
}

@test "off twice: idempotent, manifest preserved, no drift" {
  zsh "$TOGGLE" off
  after_first="$(tree_hash)"
  manifest_first="$(cat "$MANIFEST")"
  run zsh "$TOGGLE" off
  [ "$status" -eq 0 ]
  [ "$(tree_hash)" = "$after_first" ]
  [ "$(cat "$MANIFEST")" = "$manifest_first" ]
}

@test "on twice: idempotent, no drift" {
  zsh "$TOGGLE" off
  zsh "$TOGGLE" on
  after_first="$(tree_hash)"
  run zsh "$TOGGLE" on
  [ "$status" -eq 0 ]
  [ "$(tree_hash)" = "$after_first" ]
}

@test "on with no saved manifest: exits 1 and says so on stderr" {
  run zsh "$TOGGLE" on
  [ "$status" -eq 1 ]
  [[ "$output" == *"No saved manifest"* ]]
  [[ "$output" == *"off"* ]]
  [ ! -f "$MANIFEST" ]
}

@test "off with no fable agents and no manifest: exits 0, creates no manifest" {
  # rewrite the two fable agents to opus by hand, so nothing is on fable
  for a in plugin-a/agents/one.md plugin-b/agents/three.md; do
    sed '1,/^---$/ s/^model: fable$/model: opus/' "$WORK/$a" > "$WORK/t"; mv "$WORK/t" "$WORK/$a"
  done
  run zsh "$TOGGLE" off
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do"* ]]
  [ ! -f "$MANIFEST" ]
}

@test "no arguments: exits 2 with usage" {
  run zsh "$TOGGLE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "unknown argument: exits 2 with usage" {
  run zsh "$TOGGLE" sideways
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "too many arguments: exits 2 with usage" {
  run zsh "$TOGGLE" on off
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "off unions a newly-added fable agent without dropping prior entries" {
  zsh "$TOGGLE" off
  zsh "$TOGGLE" on
  # a fable agent appears after the first cycle
  cat > "$WORK/plugin-a/agents/six.md" <<'EOF'
---
name: six
description: new fable agent
model: fable
tools: Read
---

Body.
EOF
  run zsh "$TOGGLE" off
  [ "$status" -eq 0 ]
  # new one captured AND flipped
  grep -q "plugin-a/agents/six.md" "$MANIFEST"
  [ "$(fm_model "$WORK/plugin-a/agents/six.md")" = "opus" ]
  # prior entries still present (union, not replace)
  grep -q "plugin-a/agents/one.md" "$MANIFEST"
  grep -q "plugin-b/agents/three.md" "$MANIFEST"
}

@test "a malformed agent with no closing frontmatter fence is never touched" {
  # opening fence + a bare 'model: fable' line but NO closing --- : must be
  # ignored (not captured, not rewritten).
  cat > "$WORK/plugin-a/agents/broken.md" <<'EOF'
---
name: broken
model: fable
tools: Read
EOF
  before="$(shasum < "$WORK/plugin-a/agents/broken.md")"
  run zsh "$TOGGLE" off
  [ "$status" -eq 0 ]
  run ! grep -q "broken.md" "$MANIFEST"
  [ "$(shasum < "$WORK/plugin-a/agents/broken.md")" = "$before" ]
}
