#!/usr/bin/env bats
#
# Behavioral tests for untested-surface.zsh (#2014): the claude-plugin
# pre-review self-check. It lists the exits, flags, case arms and rule sentences
# a story diff adds that no bats case tests and no bats needle pins. Each kind
# has a positive case (listed) and a negative control (covered or pinned, so not
# listed) — a script that listed everything, or nothing, fails one of the pair.
#
# Every fixture is a real temp git repo: a committed base on `main`, then the
# story's edits in the working tree, exactly as the writer runs it before
# committing.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development-claude-plugin/skills/resolve-profile/scripts/untested-surface.zsh"

  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/plug/skills/x/scripts" "$R/tests"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  cat > "$R/plug/skills/x/scripts/tool.zsh" <<'EOF'
#!/usr/bin/env zsh
mode=""
while (( $# > 0 )); do
  case "$1" in
  --repo) repo="$2"; shift 2 ;;
  *) print -u2 "unknown: $1"; exit 2 ;;
  esac
done
case "$mode" in
plan) print plan ;;
esac
exit 0
EOF
  printf 'Intro paragraph.\n' > "$R/plug/skills/x/SKILL.md"
  printf 'base\n' > "$R/README.md"
  # a covering file for tool.zsh: names the script, tests the existing surface
  printf '%s\n' 'run zsh plug/skills/x/scripts/tool.zsh --repo .' \
    '[ "$status" -eq 2 ]' > "$R/tests/tool.bats"
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" branch -M main
}

surface() { run --separate-stderr zsh "$S" --repo "$R" --base main "$@"; }

# Inserts line $2 after line $1 of tool.zsh (1-based, post-change numbering is
# then $1 + 1).
insert_after() {
  local f="$R/plug/skills/x/scripts/tool.zsh"
  awk -v n="$1" -v t="$2" '{ print } NR == n { print t }' "$f" > "$f.new"
  mv "$f.new" "$f"
}

cover() { printf '%s\n' "$@" >> "$R/tests/tool.bats"; }

# --- exit -------------------------------------------------------------------

@test "an untested new exit code is listed with its post-change line and text" {
  insert_after 4 '  --dry) exit 3 ;;'
  cover '--dry'
  surface
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.[] | select(.kind == "exit")]')" = \
    '[{"file":"plug/skills/x/scripts/tool.zsh","kind":"exit","line":5,"text":"--dry) exit 3 ;;"}]' ]
}

@test "negative control: an exit whose status a covering file asserts is not listed" {
  insert_after 4 '  --dry) exit 3 ;;'
  cover '--dry' '[ "$status" -eq 3 ]'
  surface
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "the exit predicate is file-level: the assertion in a file NOT naming the script does not cover it" {
  insert_after 4 '  --dry) exit 3 ;;'
  cover '--dry'
  printf '%s\n' '[ "$status" -eq 3 ]' > "$R/tests/other.bats"
  surface
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[] | select(.kind == "exit") | .line')" = "5" ]
}

@test "a variable exit is skipped" {
  insert_after 11 'exit $rc'
  surface
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# --- flag -------------------------------------------------------------------

@test "an untested new flag is listed" {
  insert_after 4 '  --dry-run) dry=1; shift ;;'
  surface
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.')" = \
    '[{"file":"plug/skills/x/scripts/tool.zsh","kind":"flag","line":5,"text":"--dry-run) dry=1; shift ;;"}]' ]
}

@test "negative control: a flag a covering file names is not listed" {
  insert_after 4 '  --dry-run) dry=1; shift ;;'
  cover 'run zsh tool.zsh --dry-run'
  surface
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "a multi-alternative flag arm is one flag item when any flag is untested, never also a case arm" {
  insert_after 4 '  --verbose|--quiet|-v) v=1; shift ;;'
  cover '--quiet'
  surface
  [ "$(echo "$output" | jq -c '[.[] | {kind, line}]')" = '[{"kind":"flag","line":5}]' ]
}

# --- case-arm ---------------------------------------------------------------

@test "an untested new case arm is listed, and so is a partly covered one" {
  insert_after 9 'detect|probe) print detect ;;'
  surface
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.[] | {kind, line}]')" = '[{"kind":"case-arm","line":10}]' ]
  # every literal alternative is required: one of the two is not enough
  cover 'run zsh tool.zsh detect'
  surface
  [ "$(echo "$output" | jq -c '[.[] | {kind, line}]')" = '[{"kind":"case-arm","line":10}]' ]
}

@test "negative control: a case arm whose every alternative a covering file holds is not listed" {
  insert_after 9 'detect|probe) print detect ;;'
  cover 'run zsh tool.zsh detect' 'run zsh tool.zsh probe'
  surface
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "a pure-glob arm is skipped" {
  insert_after 9 '*) print other ;;'
  surface
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# --- rule-sentence ----------------------------------------------------------

@test "an unpinned new rule sentence is listed, flattened, at the line it starts on" {
  printf '%s\n' 'Intro paragraph.' '' 'Plain prose here. The writer must' \
    'never skip the gate.' >> "$R/plug/skills/x/SKILL.md"
  surface
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.')" = \
    '[{"file":"plug/skills/x/SKILL.md","kind":"rule-sentence","line":4,"text":"The writer must never skip the gate."}]' ]
}

@test "a backtick term alone makes a rule sentence; a sentence with neither is not one" {
  printf '%s\n' '' 'Run `tool.zsh` first. Nothing else here.' >> "$R/plug/skills/x/SKILL.md"
  surface
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[].text')" = 'Run `tool.zsh` first.' ]
}

@test "the keywords match as whole words, case-insensitively" {
  printf '%s\n' '' 'ALWAYS pin it. Mustard is required.' 'Nevertheless fine.' \
    >> "$R/plug/skills/x/SKILL.md"
  surface
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.[].text] | join("|")')" = 'ALWAYS pin it.|Mustard is required.' ]
}

@test "a rule sentence with no closing punctuation is still listed" {
  printf '%s\n' '' '- Never skip the gate' >> "$R/plug/skills/x/SKILL.md"
  surface
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.[] | .kind, .line, .text]')" = '["rule-sentence",3,"Never skip the gate"]' ]
}

@test "negative control: a sentence a 12+ character bats literal pins is not listed" {
  printf '%s\n' '' 'The writer must never skip the gate.' >> "$R/plug/skills/x/SKILL.md"
  printf '%s\n' "contains \"\$s\" 'never skip the gate'" > "$R/tests/pins.bats"
  surface
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "a sentence ending inside closing markup splits, so a pinned bold lead does not pin the next sentence" {
  printf '%s\n' '' '- **Run the self-check first (#2014).** The writer must never skip the gate.' \
    >> "$R/plug/skills/x/SKILL.md"
  printf '%s\n' "contains \"\$s\" 'Run the self-check first'" > "$R/tests/pins.bats"
  surface
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.[].text] | join("|")')" = 'The writer must never skip the gate.' ]
}

@test "a literal shorter than 12 characters does not pin" {
  printf '%s\n' '' 'The writer must never skip the gate.' >> "$R/plug/skills/x/SKILL.md"
  printf '%s\n' "contains \"\$s\" 'skip the g'" > "$R/tests/pins.bats"
  surface
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[].kind')" = "rule-sentence" ]
}

@test "prose outside a skills/ or agents/ directory, and fenced code, are not rule sentences" {
  printf '%s\n' 'You must never do this.' > "$R/plug/NOTES.md"
  printf '%s\n' '' '```' 'you must never run this' '```' >> "$R/plug/skills/x/SKILL.md"
  surface
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# --- whole-diff shapes ------------------------------------------------------

@test "a clean diff prints [] and exits 0" {
  surface
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "a diff with no script or prose changes prints [] and exits 0" {
  printf 'changed\n' > "$R/README.md"
  printf '%s\n' '{"a": 1}' > "$R/plug/data.json"
  surface
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "an untracked script counts, items sort by file then line, and committed changes count" {
  printf '%s\n' '#!/usr/bin/env zsh' 'exit 4' > "$R/plug/skills/x/scripts/new.zsh"
  insert_after 4 '  --dry-run) dry=1; shift ;;'
  git -C "$R" checkout -qb story
  git -C "$R" commit -qam story
  surface
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.[] | [.file, .kind, .line]]')" = \
    '[["plug/skills/x/scripts/new.zsh","exit",2],["plug/skills/x/scripts/tool.zsh","flag",5]]' ]
}

# --- exit codes -------------------------------------------------------------

@test "a usage error exits 2 and names the flag" {
  run --separate-stderr zsh "$S" --repo "$R" --bogus
  [ "$status" -eq 2 ]
  contains "$stderr" "--bogus"
  run --separate-stderr zsh "$S" --repo "$R" --base
  [ "$status" -eq 2 ]
  contains "$stderr" "--base requires a value"
  run --separate-stderr zsh "$S" --base main
  [ "$status" -eq 2 ]
  contains "$stderr" "--repo is required"
}

@test "a missing merge-base exits 1 with empty stdout and the named stderr" {
  git -C "$R" checkout -q --orphan lonely
  git -C "$R" commit -qm orphan
  run --separate-stderr zsh "$S" --repo "$R" --base main
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "untested-surface: no merge-base between main and HEAD in $R" ]
}
