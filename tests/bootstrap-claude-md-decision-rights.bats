#!/usr/bin/env bats
#
# The decision-rights rule in the bootstrapped CLAUDE.md (#2905, epic #2898).
# Ad-hoc sessions in a bootstrapped repo only meet the question taxonomy through
# that repo's CLAUDE.md, so the common template carries a "## Who decides what"
# section linking pillar 2 on the published site. A repo bootstrapped before the
# section existed receives it as a State D adoption gap, through
# claude-md-decision-rights.zsh, which only ever appends.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMPL="$REPO_ROOT/development/skills/bootstrap/templates/common/CLAUDE.md.tmpl"
  REAL_TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  GAP="$REPO_ROOT/development/skills/bootstrap/scripts/claude-md-decision-rights.zsh"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  PILLAR_URL='https://timo-jakob.github.io/timos-claude-code-plugins/explanation/philosophy/#pillar-2'
  OUT="$BATS_TEST_TMPDIR/out"
  F="$BATS_TEST_TMPDIR/CLAUDE.md"
  mkdir -p "$OUT"
}

# The template's section, heading to the next H2 or EOF.
section_of() {
  awk '$0 == "## Who decides what" { on = 1; print; next } on && /^## / { exit } on { print }' "$1"
}

# SKILL.md with hard wraps and blockquote markers joined, so a sentence is
# pinned whole wherever it wraps.
flat_skill() {
  sed 's/^[[:space:]]*>[[:space:]]*//' "$SKILL" | tr '\n' ' ' | tr -s ' '
}

# --- AC1: the template carries the rule -------------------------------------

@test "the template carries the Who decides what section exactly once (#2905)" {
  run grep -cxF '## Who decides what' "$TMPL"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "the template's section is pinned verbatim (#2905)" {
  # every clause is what a bootstrapped repo is told; a reworded one reds here
  local expected
  expected="$(cat <<'EOF'
## Who decides what

Before you put a question to the human, sort it:

- **Ask** about **intent** — what to build, its scope and priority, its
  non-functional targets, and any risk acceptance (security, cost, data loss)
  or step that is irreversible or outward-facing.
- **Ask** about **gaps** — something the work needs on which this repo's
  architecture and requirements are silent, or where they contradict each
  other — and propose the document change that would close it.
- **Decide** implementation choices yourself, within this repo's architecture
  and requirements, and let the toolchain (linters, tests, review, CI) verify
  them. Do not ask about them; list each decision you took in the PR body
  under a **Decisions taken** heading, so a reviewer can overrule it there.

When in doubt whether a question is an implementation choice, ask it. The
principle behind this rule is
[Never asks "how"](https://timo-jakob.github.io/timos-claude-code-plugins/explanation/philosophy/#pillar-2)
EOF
)"
  [ "$(section_of "$TMPL")" = "$expected" ]
}

@test "the rule links the published pillar-2 anchor with the URL ending its line (#2905)" {
  # the pillar's H2 title as link text, the published URL closing the line
  section_of "$TMPL" > "$BATS_TEST_TMPDIR/section"
  grep -qxF "[Never asks \"how\"]($PILLAR_URL)" "$BATS_TEST_TMPDIR/section"
}

@test "the rule does not restate pillar 2's own wording (#2905)" {
  local s
  s="$(section_of "$TMPL")"
  # needles from the pillar's italic line, Statement and Why on the philosophy page
  lacks "$s" 'architecture positions decide, stated in its own'
  lacks "$s" 'what* to build, never *how*'
  lacks "$s" 'turns every run into a'
  lacks "$s" 'Deciding once'
}

# --- AC2: a fresh bootstrap's CLAUDE.md contains it --------------------------

@test "a bootstrap render of CLAUDE.md.tmpl carries the rule (#2905)" {
  run zsh "$RENDER" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --project-name demo --project-slug o/demo --languages "python" \
    common/CLAUDE.md.tmpl
  [ "$status" -eq 0 ]
  local rendered="$OUT/common/CLAUDE.md"
  [ -f "$rendered" ]
  [ "$(section_of "$rendered")" = "$(section_of "$TMPL")" ]
  grep -qF "$PILLAR_URL" "$rendered"
}

# --- AC3: State D reports the gap and appends only the rule -----------------

@test "check: a CLAUDE.md without the rule is the adoption gap, exit 1 (#2905)" {
  printf '# Ours\n\nCustom guidance.\n' > "$F"
  run zsh "$GAP" check --claude-md "$F"
  [ "$status" -eq 1 ]
  [ "$output" = "gap" ]
}

@test "check: a CLAUDE.md carrying the rule is present, exit 0 (#2905)" {
  { printf '# Ours\n\n'; section_of "$TMPL"; } > "$F"
  run zsh "$GAP" check --claude-md "$F"
  [ "$status" -eq 0 ]
  [ "$output" = "present" ]
}

@test "check: the heading counts with CRLF, trailing blanks or another case (#2905)" {
  local h
  for h in $'## Who decides what\r' '## Who decides what   ' '## WHO decides What'; do
    printf '# Ours\n\n%s\n\nbody\n' "$h" > "$F"
    run zsh "$GAP" check --claude-md "$F"
    [ "$status" -eq 0 ]
  done
}

@test "check: a heading mentioned mid-line is still a gap (#2905)" {
  printf '# Ours\n\nSee ## Who decides what elsewhere.\n' > "$F"
  run zsh "$GAP" check --claude-md "$F"
  [ "$status" -eq 1 ]
}

@test "check: a heading inside a fenced block is still a gap (#2905)" {
  printf '# Ours\n\n```markdown\n## Who decides what\n```\n' > "$F"
  run zsh "$GAP" check --claude-md "$F"
  [ "$status" -eq 1 ]
  printf '# Ours\n\n~~~\n## Who decides what\n~~~\n' > "$F"
  run zsh "$GAP" check --claude-md "$F"
  [ "$status" -eq 1 ]
}

@test "check: no CLAUDE.md is not this gap, exit 3 (#2905)" {
  run zsh "$GAP" check --claude-md "$BATS_TEST_TMPDIR/absent.md"
  [ "$status" -eq 3 ]
  contains "$output" 'no such file'
}

@test "apply: no CLAUDE.md is exit 3 and creates nothing (#2905)" {
  run zsh "$GAP" apply --claude-md "$BATS_TEST_TMPDIR/absent.md" --template "$TMPL"
  [ "$status" -eq 3 ]
  [ ! -e "$BATS_TEST_TMPDIR/absent.md" ]
}

@test "apply: appends the template's section and keeps every existing byte (#2905)" {
  local orig="$BATS_TEST_TMPDIR/orig.md"
  printf '# Ours\n\nCustom guidance, customised.\n' > "$F"
  cp "$F" "$orig"
  run zsh "$GAP" apply --claude-md "$F" --template "$TMPL"
  [ "$status" -eq 0 ]
  [ "$output" = "applied" ]
  # byte-exact: the original, one blank line, the section, its final newline
  { cat "$orig"; printf '\n'; section_of "$TMPL"; } > "$BATS_TEST_TMPDIR/expected"
  cmp "$F" "$BATS_TEST_TMPDIR/expected"
  run zsh "$GAP" check --claude-md "$F"
  [ "$status" -eq 0 ]
}

@test "apply: a last line without its newline gets one before the blank line (#2905)" {
  printf '# Ours\n\nno trailing newline' > "$F"
  run zsh "$GAP" apply --claude-md "$F" --template "$TMPL"
  [ "$status" -eq 0 ]
  { printf '# Ours\n\nno trailing newline\n\n'; section_of "$TMPL"; } > "$BATS_TEST_TMPDIR/expected"
  cmp "$F" "$BATS_TEST_TMPDIR/expected"
}

@test "apply: an empty CLAUDE.md gets the section with no separator (#2905)" {
  : > "$F"
  run zsh "$GAP" apply --claude-md "$F" --template "$TMPL"
  [ "$status" -eq 0 ]
  section_of "$TMPL" > "$BATS_TEST_TMPDIR/expected"
  cmp "$F" "$BATS_TEST_TMPDIR/expected"
}

@test "apply: a CRLF CLAUDE.md gets the section in CRLF (#2905)" {
  printf '# Ours\r\n\r\nCustom.\r\n' > "$F"
  run zsh "$GAP" apply --claude-md "$F" --template "$TMPL"
  [ "$status" -eq 0 ]
  { printf '# Ours\r\n\r\nCustom.\r\n\r\n'; section_of "$TMPL" | awk '{ printf "%s\r\n", $0 }'; } > "$BATS_TEST_TMPDIR/expected"
  cmp "$F" "$BATS_TEST_TMPDIR/expected"
  # …and a second apply sees the rule
  run zsh "$GAP" apply --claude-md "$F" --template "$TMPL"
  [ "$output" = "present" ]
}

@test "apply: is idempotent — a second run changes nothing (#2905)" {
  printf '# Ours\n' > "$F"
  zsh "$GAP" apply --claude-md "$F" --template "$TMPL"
  cp "$F" "$BATS_TEST_TMPDIR/once.md"
  run zsh "$GAP" apply --claude-md "$F" --template "$TMPL"
  [ "$status" -eq 0 ]
  [ "$output" = "present" ]
  cmp "$F" "$BATS_TEST_TMPDIR/once.md"
}

@test "apply: a file carrying the rule is present even with a bad template path (#2905)" {
  { printf '# Ours\n\n'; section_of "$TMPL"; } > "$F"
  run zsh "$GAP" apply --claude-md "$F" --template "$BATS_TEST_TMPDIR/missing.tmpl"
  [ "$status" -eq 0 ]
  [ "$output" = "present" ]
}

@test "apply: a template without the section is exit 4 and writes nothing (#2905)" {
  printf '# Ours\n' > "$F"
  cp "$F" "$BATS_TEST_TMPDIR/orig.md"
  printf '# A template\n\n## Something else\n' > "$BATS_TEST_TMPDIR/t.tmpl"
  run zsh "$GAP" apply --claude-md "$F" --template "$BATS_TEST_TMPDIR/t.tmpl"
  [ "$status" -eq 4 ]
  contains "$output" 'carries no'
  cmp "$F" "$BATS_TEST_TMPDIR/orig.md"
}

@test "apply: a section holding an unrendered placeholder is exit 4 and writes nothing (#2905)" {
  printf '# Ours\n' > "$F"
  cp "$F" "$BATS_TEST_TMPDIR/orig.md"
  printf '## Who decides what\n\nAsk {{OWNER}}.\n' > "$BATS_TEST_TMPDIR/t.tmpl"
  run zsh "$GAP" apply --claude-md "$F" --template "$BATS_TEST_TMPDIR/t.tmpl"
  [ "$status" -eq 4 ]
  contains "$output" 'unrendered placeholder'
  cmp "$F" "$BATS_TEST_TMPDIR/orig.md"
}

@test "apply: a template path that does not exist is a usage error, exit 2 (#2905)" {
  printf '# Ours\n' > "$F"
  cp "$F" "$BATS_TEST_TMPDIR/orig.md"
  run zsh "$GAP" apply --claude-md "$F" --template "$BATS_TEST_TMPDIR/missing.tmpl"
  [ "$status" -eq 2 ]
  contains "$output" 'no such template'
  cmp "$F" "$BATS_TEST_TMPDIR/orig.md"
}

@test "apply: an unwritable CLAUDE.md is exit 5 and unchanged (#2905)" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores file modes"
  printf '# Ours\n' > "$F"
  cp "$F" "$BATS_TEST_TMPDIR/orig.md"
  chmod 444 "$F"
  run zsh "$GAP" apply --claude-md "$F" --template "$TMPL"
  chmod 644 "$F"
  [ "$status" -eq 5 ]
  contains "$output" 'cannot write'
  cmp "$F" "$BATS_TEST_TMPDIR/orig.md"
}

@test "check: an unreadable CLAUDE.md is exit 5, never a gap (#2905)" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores file modes"
  printf '# Ours\n' > "$F"
  chmod 000 "$F"
  run zsh "$GAP" check --claude-md "$F"
  chmod 644 "$F"
  [ "$status" -eq 5 ]
  contains "$output" 'cannot read'
}

@test "apply: the section ends at the next H2 of the template (#2905)" {
  printf '# Ours\n' > "$F"
  printf '## Who decides what\n\nrule line\n\n## Next\n\nnot copied\n' > "$BATS_TEST_TMPDIR/t.tmpl"
  run zsh "$GAP" apply --claude-md "$F" --template "$BATS_TEST_TMPDIR/t.tmpl"
  [ "$status" -eq 0 ]
  printf '# Ours\n\n## Who decides what\n\nrule line\n' > "$BATS_TEST_TMPDIR/expected"
  cmp "$F" "$BATS_TEST_TMPDIR/expected"
}

@test "usage: no mode or an unknown mode is exit 2 (#2905)" {
  run zsh "$GAP"
  [ "$status" -eq 2 ]
  contains "$output" 'usage:'
  run zsh "$GAP" frob --claude-md x
  [ "$status" -eq 2 ]
}

@test "usage: a missing or valueless flag is exit 2 (#2905)" {
  run zsh "$GAP" check
  [ "$status" -eq 2 ]
  run zsh "$GAP" check --claude-md
  [ "$status" -eq 2 ]
  run zsh "$GAP" apply --claude-md x
  [ "$status" -eq 2 ]
  run zsh "$GAP" apply --claude-md x --template
  [ "$status" -eq 2 ]
}

@test "usage: a flag the mode does not take is exit 2 (#2905)" {
  run zsh "$GAP" check --claude-md x --template y
  [ "$status" -eq 2 ]
  run zsh "$GAP" check --claude-md x --bogus
  [ "$status" -eq 2 ]
}

# --- the skill wires the gap into State D -----------------------------------

@test "bootstrap SKILL.md names the State D adoption gap and the script's arms (#2905)" {
  local flat
  flat="$(flat_skill)"
  contains "$flat" "*State D — the decision-rights rule's adoption gap (#2905).*"
  contains "$flat" '**Run the check in every State D run, before any of steps 3, 4 and 5 ends the run** — step 5a'"'"'s no-drift stop included, since an older repo with no other gap is this gap'"'"'s usual case:'
  contains "$flat" '`"<skill-base-dir>/scripts/claude-md-decision-rights.zsh" check --claude-md "<repo-path>/CLAUDE.md"`, with the absolute path.'
  contains "$flat" 'Exit 0 means the rule is present and there is nothing to do; exit 1 is the **adoption gap** — report it in the Step 2 plan as "`CLAUDE.md` lacks the decision-rights rule" and, on confirmation, run the same script'"'"'s `apply --claude-md "<repo-path>/CLAUDE.md" --template "<skill-base-dir>/templates/common/CLAUDE.md.tmpl"`.'
  contains "$flat" 'It appends the template'"'"'s section and leaves every existing byte of the file unchanged, so a customised `CLAUDE.md` keeps its customisations.'
  contains "$flat" 'Exit 3 (no `CLAUDE.md`) is not this gap: the missing-file gap-fill renders the whole template, rule included.'
  contains "$flat" 'Exit 2 is your own malformed call, a `--template` path that does not exist included: fix it and re-run.'
  contains "$flat" 'An `apply` exit 4 means the shipped template lost its section or holds an unrendered placeholder, and an exit 5 that the file or the template could not be read or written: report either as an outstanding Step 5 item and install nothing.'
  contains "$flat" '`CLAUDE.md` is a scaffold file, never stamped, so the drift detector cannot see a repo bootstrapped before the section existed.'
}

@test "bootstrap SKILL.md lists the gap in State D's steps 3 and 5a (#2905)" {
  local flat
  flat="$(flat_skill)"
  # step 3: the gap-fill's working-tree writes
  contains "$flat" "the Go identity adoption gap's install and the decision-rights rule's adoption gap — see below),"
  contains "$flat" "and of a pending decision-rights rule (\`CLAUDE.md\`'s State D gap, #2905), each offered in the Step 2 plan"
  # step 5a: the no-drift stop does not end a run with this gap pending
  contains "$flat" "and so does a pending decision-rights rule (\`CLAUDE.md\`'s State D gap, #2905, whose check runs before this stop is decided): do not stop — continue to the Step 2 plan, and on confirmation its install is the delta.)"
}
