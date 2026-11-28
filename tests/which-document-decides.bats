#!/usr/bin/env bats
#
# Which document decides an `implementation` question (#3354, a child of
# #3198). ARCHITECTURE.md's *Decision rights* section gains the subsection
# *Which document decides*: a repo's target architecture decides ahead of the
# family's positions, wherever the lookup finds it, and only the lookup's
# exit 3 means there is none. The Decisions-taken record cites a clause by id
# and by where it was read.
#
# Three consumers apply it — the issue refiner, the readiness gate and the
# resolve-issue conductor's ask-branch inventory. They are model-read prose,
# so most pins here are prose pins: each holds one rule, one command or one
# stop behaviour in place. The fixture tests run the two commands the
# consumers name against invented throwaway repos built in setup().
#
# ANCHOR FORM: headings and quoted text only, never `path:line`.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  # a git hook or `rebase --exec` exports these, and `git -C` does not override
  # them: the fixture repo's init/add would land in the REAL index
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  # scripts that annotate under Actions would change stderr on CI only
  unset GITHUB_ACTIONS
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  REFINER="$REPO_ROOT/development/agents/issue-refiner.md"
  GATE="$REPO_ROOT/development/agents/story-readiness.md"
  ASK="$REPO_ROOT/development/skills/resolve-issue/reference/ask-branches.md"
  LOOKUP="$REPO_ROOT/development/scripts/reference-docs/resolve-reference-doc.zsh"
  VALIDATOR="$REPO_ROOT/development/scripts/reference-docs/validate-target-architecture.zsh"
  LINK='[*Which document decides*](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md#which-document-decides)'
  RULE2='the target-architecture clause decides'
}

collapse() {
  tr -s '[:space:]' ' ' | sed 's/[[:space:]]*$//'
}

# subsection <title> — the lines of one ### subsection of *Decision rights*,
# from its heading to the next ### or ## heading. awk reads the file itself, so
# an early stop never races a producer (tests/early-exit-reader-guard.bats).
subsection() {
  awk -v h="### $1" '
    /^## / { in_sec = ($0 ~ /^## Decision rights/) }
    /^##/ { on = (in_sec && $0 == h); next }
    on { print }' "$ARCH"
}

# decides — the new subsection, joined onto one line
decides() {
  subsection 'Which document decides' | collapse
}

# below_table — the paragraph that directly follows the Decisions-taken
# record's field table: the first non-blank lines after its last row, up to
# the next blank line
below_table() {
  awk '
    /^## / { in_sec = ($0 ~ /^## Decision rights/) }
    /^##/ { on = (in_sec && $0 == "### The Decisions-taken record"); next }
    !on { next }
    /^\|/ { rows = 1; next }
    rows && /^$/ && !started { next }
    rows && /^$/ { exit }
    rows { started = 1; print }' "$ARCH"
}

flat() {
  tr -s '[:space:]' ' ' < "$1"
}

# outcome <file> <bullet head> — the one outcome bullet of a consumer's
# target-architecture section whose line starts with "- **<head>", up to the
# next bullet, blank line or heading, joined onto one line
outcome() {
  awk -v head="- **$2" '
    index($0, head) == 1 { on = 1; print; next }
    on && (/^- / || /^$/ || /^#/) { exit }
    on { print }' "$1" | collapse
}

g() {
  git -c user.name="Fixture Author" -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null -c init.defaultBranch=main "$@"
}

# --- the subsection's place --------------------------------------------------

@test "the subsection sits inside Decision rights, after The tie-break and before The Decisions-taken record" {
  local order
  order="$(awk '
    /^## / { in_sec = ($0 ~ /^## Decision rights/) }
    in_sec && /^### / { print }' "$ARCH")"
  [ "$order" = "$(printf '%s\n' '### The three question kinds' '### The tie-break' '### Which document decides' '### The Decisions-taken record')" ]
  [ "$(grep -cx '### Which document decides' "$ARCH")" -eq 1 ]
}

@test "the subsection links pillar 2 in the repo-root form" {
  contains "$(decides)" '[Never asks "how"](docs/explanation/philosophy.md#pillar-2)'
}

# --- the three rules ---------------------------------------------------------

@test "rule 1: active clauses at the pinned version, then the family's positions, then established practice" {
  contains "$(decides)" "1. **The order.** An \`implementation\` question is decided from the target architecture's active clauses, read at the pinned version when the file is linked, then from the family's positions, then from established practice."
}

@test "rule 2: the target-architecture clause decides, and a difference is never a gap" {
  contains "$(decides)" "2. **A difference is not a gap.** Where a target-architecture clause and a family position differ, $RULE2, and that difference is never a \`gap\`."
}

@test "rule 3: a gap is silence across both, or a contradiction inside the target architecture" {
  contains "$(decides)" '3. **What a gap is then.** A `gap` is silence across the target architecture and the positions, or a contradiction inside the target architecture.'
}

@test "a retired clause decides nothing and is never cited" {
  contains "$(decides)" 'A retired clause decides nothing and is never cited.'
}

@test "the subsection records that a target architecture decides wherever the lookup finds it" {
  contains "$(decides)" "A target architecture decides wherever the lookup finds it: its clauses come ahead of the family's positions whether the file is the repo's own or one in a linked docs repository. Only a repo with no target architecture, the lookup's exit 3, decides exactly as before."
}

@test "the subsection records exit 3 as the only no-target-architecture outcome and every other one as a clean stop" {
  contains "$(decides)" "Only the lookup's exit 3 means the repo has no target architecture. Every other outcome that is not a found, valid file is a clean stop that repeats the script's stderr and is never read as \"no target architecture\": the lookup's exits 1, 2, 4, 5 and 6, and the validator's exits 1 and 2."
}

@test "the subsection names the two commands, its three consumers and this suite" {
  local d
  d="$(decides)"
  contains "$d" '`resolve-reference-doc.zsh docs/architecture/target-architecture.md`'
  contains "$d" '`validate-target-architecture.zsh` on the `path` the lookup printed'
  contains "$d" '(`development/agents/issue-refiner.md`)'
  contains "$d" '(`development/agents/story-readiness.md`)'
  contains "$d" '(`development/skills/resolve-issue/reference/ask-branches.md`)'
  contains "$d" '`tests/which-document-decides.bats` pins both.'
  [ -f "$BATS_TEST_FILENAME" ]
}

# --- the evidence form -------------------------------------------------------

@test "the paragraph directly below the record's table gives both evidence forms" {
  local p
  p="$(below_table | collapse)"
  [ -n "$p" ]
  starts_with "$p" 'A decision that rests on a target-architecture clause'
  contains "$p" "A decision that rests on a target-architecture clause names the clause id and where the clause was read, and never quotes the clause's text:"
  contains "$p" '`<clause id> (<submodule path> @ <short sha>)` for a file in a linked docs repository'
  contains "$p" '`<clause id> (docs/architecture/target-architecture.md)` for the repo'"'"'s own file, which has no pinned commit.'
}

@test "the record's evidence row is unchanged" {
  contains "$(subsection 'The Decisions-taken record')" '| evidence | The position, requirement or established practice the choice rests on, cited by its section or file. |'
}

# --- the three consumers -----------------------------------------------------

@test "each consumer links the subsection and names both commands" {
  local f t
  for f in "$REFINER" "$GATE" "$ASK"; do
    t="$(flat "$f")"
    contains "$t" "$LINK"
    contains "$t" '`resolve-reference-doc.zsh docs/architecture/target-architecture.md`'
    contains "$t" '`validate-target-architecture.zsh` on the `path`'
  done
}

@test "the two agents spell the lookup call and resolve the validator from the plugin cache" {
  local f t
  for f in "$REFINER" "$GATE"; do
    t="$(flat "$f")"
    contains "$t" 'zsh <resolved path> --repo-dir <target repo root> docs/architecture/target-architecture.md'
    contains "$t" 'plugins/cache/*/development/*/scripts/reference-docs/validate-target-architecture.zsh(N.nOn[1])'
    contains "$t" 'its working-tree copy at `development/scripts/reference-docs/validate-target-architecture.zsh` serves instead.'
  done
  [ -x "$VALIDATOR" ]
}

@test "the conductor names where both scripts ship" {
  contains "$(flat "$ASK")" 'Both ship in this plugin, at `<skill-base-dir>/../../scripts/reference-docs/`.'
  [ -x "$LOOKUP" ]
  [ -x "$VALIDATOR" ]
}

@test "each consumer names exit 3 as the only no-target-architecture outcome" {
  contains "$(outcome "$REFINER" "The lookup's exit 3**")" 'Only exit 3 means there is no target architecture.'
  contains "$(outcome "$GATE" "The lookup's exit 3**")" 'Only exit 3 means there is no target architecture.'
  contains "$(flat "$ASK")" "On the lookup's exit 3, the only outcome that means the repo has no target architecture, the run decides exactly as before."
}

@test "each consumer's other outcomes cover the lookup's exits 1, 2, 4, 5 and 6 and the validator's 1 and 2" {
  local b
  for f in "$REFINER" "$GATE"; do
    b="$(outcome "$f" 'Any other outcome**')"
    contains "$b" "the lookup's exit 1, 2, 4, 5 or 6, the validator's exit 1 or 2, or no copy of either script"
    contains "$b" 'Never read the outcome as "no target architecture".'
  done
  contains "$(flat "$ASK")" "On any other outcome, the lookup's exit 1, 2, 4, 5 or 6 or the validator's exit 1 or 2, the run ends as a clean stop"
}

@test "the issue refiner's stop: an unresolved objection repeating stderr, and no implementation question that turn" {
  local b
  b="$(outcome "$REFINER" 'Any other outcome**')"
  contains "$b" "report an unresolved objection, a \`resolved_objections\` entry with \`resolved: false\` whose \`note\` repeats the script's stderr"
  contains "$b" 'decide no `implementation` question this turn.'
}

@test "the readiness gate's stop: no READY verdict, its reason repeating stderr" {
  local b
  b="$(outcome "$GATE" 'Any other outcome**')"
  contains "$b" 'return no `READY` verdict.'
  contains "$b" 'The verdict is `NEEDS_REFINEMENT` with `acceptance_testable` `false`'
  contains "$b" "its reason repeats the script's stderr"
}

@test "the conductor's stop: a clean stop that relays stderr and opens no PR" {
  local t
  t="$(flat "$ASK")"
  contains "$t" "the run ends as a clean stop that relays the script's stderr: it takes no \`implementation\` default, opens no PR"
  contains "$t" 'a step of a human-started chain writes verdict `stopped`, cause `tooling`.'
  contains "$t" 'and the paragraph that follows, this file states no rule of its own.'
}

@test "a found, valid file decides in both agents" {
  contains "$(outcome "$REFINER" "The lookup's exit 0 and the validator's exit 0**")" 'decide with the target architecture as that section says'
  contains "$(outcome "$GATE" "The lookup's exit 0 and the validator's exit 0**")" 'sort and judge with the target architecture as that section says.'
}

@test "no consumer restates the subsection's rules" {
  local f t
  for f in "$REFINER" "$GATE" "$ASK"; do
    t="$(flat "$f")"
    lacks "$t" 'then from the family'"'"'s positions, then from established practice'
    lacks "$t" 'that difference is never a `gap`'
    lacks "$t" 'or a contradiction inside the target architecture'
    lacks "$t" 'A retired clause decides nothing'
    contains "$t" 'not restate'
  done
}

# --- the sweep ---------------------------------------------------------------

@test "no file under development/ states rule 2 in its own words" {
  local rc
  # positive control: the needle occurs exactly once, in the subsection
  [ "$(grep -cF -- "$RULE2" "$ARCH")" -eq 1 ]
  contains "$(decides)" "$RULE2"
  run git -C "$REPO_ROOT" grep -n -i -F -e "$RULE2" -- development
  rc="$status"
  [ "$rc" -eq 1 ] || { printf 'rule 2 restated under development/ (git grep exit %s):\n%s\n' "$rc" "$output" >&2; return 1; }
  # the sweep sees the tree: development/ holds tracked files
  [ "$(git -C "$REPO_ROOT" ls-files -- development | grep -c .)" -gt 0 ]
}

# --- the commands, run as the consumers spell them --------------------------

@test "the lookup answers own with no pinned commit, and the validator checks the path it printed" {
  local repo out path
  repo="$BATS_TEST_TMPDIR/own"
  mkdir -p "$repo/docs/architecture"
  g init -q "$repo"
  printf 'not a target architecture\n' > "$repo/docs/architecture/target-architecture.md"
  g -C "$repo" add -A
  g -C "$repo" commit -q -m fixture
  run -0 zsh "$LOOKUP" --repo-dir "$repo" docs/architecture/target-architecture.md
  out="$output"
  [ "$(jq -r '.origin' <<< "$out")" = "own" ]
  [ "$(jq -r '.pinned_commit' <<< "$out")" = "null" ]
  path="$(jq -r '.path' <<< "$out")"
  [ -f "$path" ]
  run -1 zsh "$VALIDATOR" "$path"
  contains "$output" 'target-architecture:'
}

@test "a repo with no target architecture is the lookup's exit 3, with nothing on stdout" {
  local repo
  repo="$BATS_TEST_TMPDIR/none"
  mkdir -p "$repo"
  g init -q "$repo"
  printf "x\n" > "$repo/README.md"
  g -C "$repo" add -A
  g -C "$repo" commit -q -m fixture
  run --separate-stderr -3 zsh "$LOOKUP" --repo-dir "$repo" docs/architecture/target-architecture.md
  [ -z "$output" ]
}
