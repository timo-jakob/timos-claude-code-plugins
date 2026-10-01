#!/usr/bin/env bats
#
# Behavioural tests for select-tests.zsh (#1973): which bats files a change can
# affect, for the gate before an intermediate (delta) review round. Pinned here:
#   * a plugin-only change selects that plugin's tests plus the always-run set,
#     and nothing that only references another plugin or the core;
#   * a core change selects the core's tests;
#   * every fail-safe — a shared path (helpers, *.bash, development/scripts/,
#     ARCHITECTURE.md, the marketplace manifest), an unmapped path, an empty or
#     uncomputable diff — returns the FULL suite, with the reason;
#   * references are extracted statically, `$REPO_ROOT/`-prefixed ones
#     included, plus the `# covers:` header;
#   * the map-completeness guard, and a mutation showing it bites;
#   * on THIS repo, a development-go-only change does not select
#     tests/resolve-story-loop-step.bats (the parallel floor the 50% target
#     depends on), and every tests/*.bats file is mapped or always-run.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/select-tests.zsh"

  # a fixture repo: two plugins, a core script, shared machinery, and one bats
  # file of each kind the selector distinguishes
  FX="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FX/tests/helpers" "$FX/development/skills/x/scripts" "$FX/development/scripts" \
           "$FX/development-go/agents" "$FX/development-java/agents" "$FX/.claude-plugin" \
           "$FX/styleguide" "$FX/docs"
  touch "$FX/development/skills/x/scripts/loop.zsh" "$FX/development-go/agents/go-a.md" \
        "$FX/development-java/agents/java-a.md" "$FX/.claude-plugin/marketplace.json" \
        "$FX/ARCHITECTURE.md" "$FX/styleguide/rules.yaml" "$FX/docs/unrelated.md" \
        "$FX/tests/helpers/h.py" "$FX/tests/assertions.bash"
  cat > "$FX/tests/go.bats" <<'EOF'
setup() { A="$REPO_ROOT/development-go/agents/go-a.md"; }
EOF
  cat > "$FX/tests/go-braced.bats" <<'EOF'
setup() { B="${REPO_ROOT}/development-go/agents/go-a.md"; C="${REPO_ROOT}/development-go/agents"; }
EOF
  cat > "$FX/tests/java.bats" <<'EOF'
setup() { A="$BATS_TEST_DIRNAME/../development-java/agents/java-a.md"; }
EOF
  cat > "$FX/tests/core.bats" <<'EOF'
setup() { S="$REPO_ROOT/development/skills/x/scripts/loop.zsh"; }
EOF
  printf '%s\n' '@test "a position guard" { true; }' > "$FX/tests/guard-position.bats"
  printf '%s\n' '@test "a repo-wide sweep" { git ls-files; }' > "$FX/tests/sweep.bats"
  printf '%s\n' '@test "a version check" { jq . "$REPO_ROOT/.claude-plugin/marketplace.json"; }' \
    > "$FX/tests/manifest.bats"
  printf '%s\n' '# covers: styleguide/' \
    '@test "a runtime-built path" { cat "$(printf '\''%s'\'' style)guide/rules.yaml"; }' \
    > "$FX/tests/covered.bats"
  printf '%s\n' '# covers: *' '@test "always" { true; }' > "$FX/tests/star.bats"
  ALWAYS='["tests/guard-position.bats","tests/manifest.bats","tests/star.bats","tests/sweep.bats"]'
  CHANGED="$BATS_TEST_TMPDIR/changed.txt"
}

# select with the fixture repo and a changed-path list given as arguments
sel() {
  printf '%s\n' "$@" > "$CHANGED"
  run --separate-stderr zsh "$S" --repo "$FX" --tests-dir tests --changed "$CHANGED"
}

# ---- selection ----------------------------------------------------------------

@test "plugin-only change: that plugin's tests plus the always-run set, nothing else" {
  sel development-go/agents/go-a.md
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --argjson a "$ALWAYS" \
    '.selection == "selected" and .reason == null
     and .files == (($a + ["tests/go-braced.bats","tests/go.bats"]) | sort)
     and .changed == ["development-go/agents/go-a.md"]'
}

@test "core change: the core's tests plus the always-run set" {
  sel development/skills/x/scripts/loop.zsh
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --argjson a "$ALWAYS" \
    '.selection == "selected" and .files == (($a + ["tests/core.bats"]) | sort)'
}

@test "\$REPO_ROOT/, \${REPO_ROOT}/ and ../-relative references are all extracted" {
  sel development-go/agents/go-a.md development-java/agents/java-a.md
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.files | index("tests/go.bats") and index("tests/go-braced.bats") and index("tests/java.bats")'
}

@test "an extracted DIRECTORY reference covers only itself: a new file under it is unmapped" {
  # go-braced.bats spells `development-go/agents` — a test naming a directory
  # (or a scratch path ending in one) must not make its whole tree look mapped
  sel development-go/agents/new-agent.md
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "full" and (.reason | contains("unmapped path changed: development-go/agents/new-agent.md"))'
}

@test "a directory reference SELECTS its test for a mapped change below it" {
  # the `SCRIPTS=…/scripts; "$SCRIPTS/loop.zsh"` idiom names only the directory
  printf 'setup() { SCRIPTS="$REPO_ROOT/development/skills/x/scripts"; }\n' > "$FX/tests/dir-user.bats"
  sel development/skills/x/scripts/loop.zsh      # mapped exactly by core.bats
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected"
    and (.files | index("tests/core.bats")) and (.files | index("tests/dir-user.bats"))'
}

@test "a directory reference never MAPS a change: nothing names it exactly -> full" {
  printf 'setup() { SCRIPTS="$REPO_ROOT/development/skills/x/scripts"; }\n' > "$FX/tests/dir-user.bats"
  sel development/skills/x/scripts/new.zsh
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "full" and (.reason | contains("unmapped path changed: development/skills/x/scripts/new.zsh"))'
}

@test "a top-level directory spelled after a path prefix SELECTS its test, never maps" {
  # `TESTS_DIR="$REPO_ROOT/tests"` anchors a sweep over every bats file
  printf 'setup() { TESTS_DIR="$REPO_ROOT/tests"; }\n' > "$FX/tests/sweeper.bats"
  sel tests/java.bats                                  # mapped: a changed bats file
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected" and (.files | index("tests/sweeper.bats"))'
  # the anchor is select-only: it neither maps a path nor satisfies the map guard
  run --separate-stderr zsh "$S" --repo "$FX" --tests-dir tests --check-map
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.unmapped == ["tests/sweeper.bats"]'
}

@test "a BARE top-level directory word does not select its test either" {
  # prose-dirs.bats spells `development:resolve-issue`, `--tests-dir tests` and
  # `docs/` bare: none of it may pull the file into a selection
  mk_prose_dirs
  sel development/skills/x/scripts/loop.zsh      # mapped exactly by core.bats
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --argjson a "$ALWAYS" '.files == (($a + ["tests/core.bats"]) | sort)'
}

@test "a top-level directory spelled after ../ SELECTS its test" {
  printf 'setup() { D="../docs"; }\n' > "$FX/tests/rel-docs.bats"
  printf 'setup() { U="$REPO_ROOT/docs/unrelated.md"; }\n' > "$FX/tests/docs-user.bats"
  sel docs/unrelated.md                            # mapped exactly by docs-user.bats
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected"
    and (.files | index("tests/docs-user.bats")) and (.files | index("tests/rel-docs.bats"))'
}

@test "the # covers: header maps a path extraction cannot see" {
  sel styleguide/rules.yaml
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected" and (.files | index("tests/covered.bats"))'
}

@test "a # covers: directory also covers every path under it" {
  sel styleguide/sub/new.yaml
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected" and (.files | index("tests/covered.bats"))'
}

@test "a changed bats file selects itself" {
  sel tests/java.bats
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --argjson a "$ALWAYS" '.files == (($a + ["tests/java.bats"]) | sort)'
}

# prose naming the development tree, a `--tests-dir tests`, the plugin half of
# `development:resolve-issue` — none of it may cover a whole tree
mk_prose_dirs() {
  cat > "$FX/tests/prose-dirs.bats" <<'EOF'
# the development:resolve-issue skill runs `run-gate.zsh --tests-dir tests`
# over the development tree and the docs/ tree
setup() { X="$REPO_ROOT/styleguide/rules.yaml"; }
EOF
}

@test "a bare top-level DIRECTORY word is not a reference: an unmapped development/ path is full" {
  mk_prose_dirs
  sel development/skills/x/other.zsh
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "full" and (.reason | contains("unmapped path changed: development/skills/x/other.zsh"))'
}

@test "a bare top-level DIRECTORY word is not a reference: an unmapped docs/ path is full" {
  mk_prose_dirs
  sel docs/unrelated.md
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "full"'
}

@test "a bare top-level FILE is a reference" {
  printf '%s\n' '@test "reads the readme" { grep -q x README.md; }' > "$FX/tests/readme.bats"
  touch "$FX/README.md"
  sel README.md
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected" and (.files | index("tests/readme.bats"))'
}

mk_fixture_user() {
  mkdir -p "$FX/tests/fixtures"
  cat > "$FX/tests/fixture-user.bats" <<'EOF'
setup() { A="$BATS_TEST_DIRNAME/fixtures/data.json"; B="${BATS_TEST_DIRNAME}/fixtures/more.json"; }
EOF
}

@test "a \$BATS_TEST_DIRNAME/ reference maps to <tests-dir>/" {
  mk_fixture_user
  sel tests/fixtures/data.json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected" and (.files | index("tests/fixture-user.bats"))'
}

@test "a \${BATS_TEST_DIRNAME}/ reference maps to <tests-dir>/" {
  mk_fixture_user
  sel tests/fixtures/more.json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected" and (.files | index("tests/fixture-user.bats"))'
}

@test "trailing sentence punctuation is dropped from a reference" {
  cat > "$FX/tests/prose.bats" <<'EOF'
# see development-java/agents/java-b.md.
EOF
  sel development-java/agents/java-b.md
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected" and (.files | index("tests/prose.bats"))'
}

@test "a changed bats file that no longer exists is covered, never selected" {
  sel tests/gone.bats
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected" and (.files | index("tests/gone.bats") | not)'
}

@test "the output is deterministic: two runs are byte-identical" {
  sel development-go/agents/go-a.md development/skills/x/scripts/loop.zsh
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local first="$output"
  sel development/skills/x/scripts/loop.zsh development-go/agents/go-a.md
  [ "$output" = "$first" ]
}

# ---- every fail-safe returns the full suite -----------------------------------

@test "fail-safe: each shared path returns the FULL suite with the reason" {
  local all; all="$(cd "$FX" && printf '%s\n' tests/*.bats | jq -R . | jq -sc 'sort')"
  local p
  for p in tests/helpers/h.py tests/assertions.bash development/scripts/emit.zsh \
           ARCHITECTURE.md .claude-plugin/marketplace.json; do
    sel development-go/agents/go-a.md "$p"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e --argjson all "$all" --arg p "$p" \
      '.selection == "full" and .files == $all and (.reason | contains("shared path changed: " + $p))'
  done
}

@test "fail-safe: an unmapped changed path returns the FULL suite" {
  sel development-go/agents/go-a.md docs/unrelated.md
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "full" and (.files | length) == 9
    and (.reason | contains("unmapped path changed: docs/unrelated.md"))'
}

@test "fail-safe: an empty diff returns the FULL suite" {
  : > "$CHANGED"
  run --separate-stderr zsh "$S" --repo "$FX" --tests-dir tests --changed "$CHANGED"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "full" and .reason == "the diff is empty" and (.files | length) == 9'
}

# ---- --base: the merge-base diff of the working tree ----------------------------

mk_git_fixture() {
  git -C "$FX" init -q
  git -C "$FX" config user.email t@example.com
  git -C "$FX" config user.name tester
  git -C "$FX" add -A && git -C "$FX" commit -qm base
  git -C "$FX" branch base
}

@test "--base: uncommitted AND untracked changes since the merge-base are the diff" {
  mk_git_fixture
  echo edit >> "$FX/development-go/agents/go-a.md"          # tracked, uncommitted
  echo new > "$FX/styleguide/new.yaml"                      # untracked, under a # covers: dir
  run --separate-stderr zsh "$S" --repo "$FX" --tests-dir tests --base base
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected"
    and .changed == ["development-go/agents/go-a.md","styleguide/new.yaml"]
    and (.files | index("tests/go.bats")) and (.files | index("tests/covered.bats"))
    and (.files | index("tests/core.bats") | not)'
}

@test "--base: committed changes on the branch count too" {
  mk_git_fixture
  echo edit >> "$FX/development/skills/x/scripts/loop.zsh"
  git -C "$FX" commit -qam change
  run --separate-stderr zsh "$S" --repo "$FX" --tests-dir tests --base base
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.changed == ["development/skills/x/scripts/loop.zsh"] and (.files | index("tests/core.bats"))'
}

@test "--base: the diff is taken from the MERGE-BASE, not the ref's moved tip" {
  mk_git_fixture
  git -C "$FX" switch -q -c story
  # main (here: base) moves on after the story forked
  git -C "$FX" switch -q base
  echo moved >> "$FX/development-java/agents/java-a.md"
  git -C "$FX" commit -qam "base moves on"
  git -C "$FX" switch -q story
  echo edit >> "$FX/development-go/agents/go-a.md"
  run --separate-stderr zsh "$S" --repo "$FX" --tests-dir tests --base base
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.changed == ["development-go/agents/go-a.md"]'
}

@test "--base: .gitignore is honoured for untracked files" {
  mk_git_fixture
  printf 'ignored/\n' > "$FX/.gitignore"
  git -C "$FX" add .gitignore && git -C "$FX" commit -qm ignore
  git -C "$FX" branch -f base
  mkdir -p "$FX/ignored"; echo x > "$FX/ignored/x.txt"
  echo edit >> "$FX/development-go/agents/go-a.md"
  run --separate-stderr zsh "$S" --repo "$FX" --tests-dir tests --base base
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected" and .changed == ["development-go/agents/go-a.md"]'
}

@test "--base: a rename lists the OLD path too, so a test naming it is still reached" {
  mk_git_fixture
  git -C "$FX" mv development/skills/x/scripts/loop.zsh development/skills/x/scripts/moved.zsh
  git -C "$FX" commit -qm rename
  run --separate-stderr zsh "$S" --repo "$FX" --tests-dir tests --base base
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.changed | index("development/skills/x/scripts/loop.zsh") and index("development/skills/x/scripts/moved.zsh")'
}

@test "fail-safe: a --repo below the top level of its work tree returns the FULL suite" {
  mk_git_fixture
  mkdir -p "$FX/sub/tests"
  printf 'setup() { A="$REPO_ROOT/development-go/agents"; }\n' > "$FX/sub/tests/a.bats"
  run --separate-stderr zsh "$S" --repo "$FX/sub" --tests-dir tests --base base
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "full" and (.reason | contains("not the top level"))'
}

@test "fail-safe: an uncomputable --base diff returns the FULL suite" {
  mk_git_fixture
  run --separate-stderr zsh "$S" --repo "$FX" --tests-dir tests --base no-such-ref
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "full" and (.reason | contains("could not be computed")) and (.files | length) == 9'
}

@test "fail-safe: --base outside a git repo returns the FULL suite" {
  run --separate-stderr zsh "$S" --repo "$FX" --tests-dir tests --base main
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "full"'
}

# ---- the map-completeness guard ---------------------------------------------------

@test "--check-map: a complete map passes" {
  run --separate-stderr zsh "$S" --repo "$FX" --tests-dir tests --check-map
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.unmapped == []'
}

@test "--check-map: a bats file with no reference and no always-run trait fails the guard" {
  printf '@test "x" { true; }\n' > "$FX/tests/orphan.bats"
  run --separate-stderr zsh "$S" --repo "$FX" --tests-dir tests --check-map
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.unmapped == ["tests/orphan.bats"]'
}

@test "--check-map: a file whose only path-shaped words are bare top-level DIRECTORY names is unmapped" {
  printf '%s\n' '# runs --tests-dir tests over the development tree and docs/' '@test "x" { true; }' \
    > "$FX/tests/bare-words.bats"
  run --separate-stderr zsh "$S" --repo "$FX" --tests-dir tests --check-map
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.unmapped == ["tests/bare-words.bats"]'
}

@test "--check-map mutation: deleting a file's only mapping entry makes the guard fail" {
  # covered.bats is mapped by its `# covers:` header alone; remove it
  sed -i.bak '/^# covers:/d' "$FX/tests/covered.bats"; rm -f "$FX/tests/covered.bats.bak"
  run --separate-stderr zsh "$S" --repo "$FX" --tests-dir tests --check-map
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.unmapped == ["tests/covered.bats"]'
}

# ---- usage ------------------------------------------------------------------------

usage_is() {  # $1 = expected stderr fragment, then the arguments
  local want="$1"; shift
  run --separate-stderr zsh "$S" "$@"
  [ "$status" -eq 2 ]
  contains "$stderr" "$want"
}

@test "the script is executable (run-gate calls it by path)" {
  [ -x "$S" ]
}

@test "--help exits 0 and prints the usage header" {
  run zsh "$S" --help
  [ "$status" -eq 0 ]
  contains "$output" "--check-map"
}

@test "usage: no mode exits 2" {
  usage_is "one of --base, --changed or --check-map is required" --repo "$FX"
}

@test "usage: --base with --changed exits 2" {
  : > "$CHANGED"
  usage_is "mutually exclusive" --repo "$FX" --base main --changed "$CHANGED"
}

@test "usage: --check-map with --changed or --base exits 2" {
  : > "$CHANGED"
  usage_is "--check-map takes no --base/--changed" --repo "$FX" --check-map --changed "$CHANGED"
  usage_is "--check-map takes no --base/--changed" --repo "$FX" --check-map --base main
}

@test "usage: a missing --repo directory exits 2" {
  usage_is "repo dir not found" --repo "$BATS_TEST_TMPDIR/nope" --check-map
}

@test "usage: an absolute --tests-dir exits 2" {
  usage_is "must be relative to --repo" --repo "$FX" --tests-dir "$FX/tests" --check-map
}

@test "usage: a missing tests dir exits 2" {
  usage_is "tests dir not found" --repo "$FX" --tests-dir nope --check-map
}

@test "usage: a tests dir holding no .bats file exits 2 (never a vacuous map pass)" {
  mkdir -p "$FX/empty"
  usage_is "no .bats files" --repo "$FX" --tests-dir empty --check-map
}

@test "usage: an unreadable --changed file exits 2" {
  usage_is "not readable" --repo "$FX" --changed "$BATS_TEST_TMPDIR/absent.txt"
}

@test "usage: each value flag without a value exits 2" {
  local flag
  for flag in --repo --tests-dir --base --changed; do
    usage_is "$flag needs a value" "$flag"
  done
}

@test "usage: an unknown flag exits 2" {
  usage_is "unknown argument" --repo "$FX" --bogus
}

@test "no jq on PATH exits 1, named" {
  local zsh_bin; zsh_bin="$(command -v zsh)"
  mkdir -p "$BATS_TEST_TMPDIR/nobin"
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/nobin" "$zsh_bin" "$S" --repo "$FX" --check-map
  [ "$status" -eq 1 ]
  contains "$stderr" "jq not found"
}

# ---- this repository ------------------------------------------------------------

@test "this repo: every tests/*.bats file is mapped or in the always-run set" {
  run --separate-stderr zsh "$S" --repo "$REPO_ROOT" --tests-dir tests --check-map
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.unmapped == []'
}

@test "this repo: a change to the loop selects the suites that reach it through a \$SCRIPTS/ directory" {
  printf '%s\n' development/skills/resolve-issue/scripts/resolve-story-loop.zsh > "$CHANGED"
  run --separate-stderr zsh "$S" --repo "$REPO_ROOT" --tests-dir tests --changed "$CHANGED"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected"
    and (.files | index("tests/possible-false-trip-auto-continue.bats"))
    and (.files | index("tests/resolve-issue-conductor-budget.bats"))'
}

@test "this repo: suites anchored on a top-level directory variable are selected below it" {
  # TESTS_DIR="$REPO_ROOT/tests" (an inert-assertion sweep) and
  # PLUGIN_DIR="$REPO_ROOT/development-opentofu" (its review panel)
  printf '%s\n' tests/select-tests.bats > "$CHANGED"
  run --separate-stderr zsh "$S" --repo "$REPO_ROOT" --tests-dir tests --changed "$CHANGED"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected" and (.files | index("tests/no-inert-negative-assertions.bats"))'
  printf '%s\n' development-opentofu/skills/review/SKILL.md > "$CHANGED"
  run --separate-stderr zsh "$S" --repo "$REPO_ROOT" --tests-dir tests --changed "$CHANGED"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected" and (.files | index("tests/opentofu-review-panel.bats"))'
}

@test "this repo: a development-go-only change does not select resolve-story-loop-step.bats" {
  printf '%s\n' development-go/agents/go-bug-hunter.md > "$CHANGED"
  run --separate-stderr zsh "$S" --repo "$REPO_ROOT" --tests-dir tests --changed "$CHANGED"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.selection == "selected"
    and (.files | index("tests/resolve-story-loop-step.bats") | not)
    and (.files | length) < 100'
}
