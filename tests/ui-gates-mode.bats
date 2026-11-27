#!/usr/bin/env bats
#
# Behavioural tests for ui-gates-mode.zsh (#3018) — the React overlay's per-repo
# gate switch, ui-gates.json. `mode` decides the a11y mode bootstrap writes from
# the repo as the user left it (bootstrap SKILL.md §3k.5, Step 2), `write` writes
# the switch without ever changing an a11y value already there, and `predecessor`
# recognises the #1946 axe files a re-run upgrades without a prompt.
# jq-driven, so hermetic.
#
# ANCHOR FORM: headings and quoted tokens only, never `path:line` (#1189).

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  UGM="$REPO_ROOT/development/skills/bootstrap/scripts/ui-gates-mode.zsh"
  RX="$REPO_ROOT/development/skills/bootstrap/templates/languages/javascript/react"
  FIX="$REPO_ROOT/tests/fixtures/react-1946"
  WORK="$BATS_TEST_TMPDIR/app"
  mkdir -p "$WORK/src"
  # a stock create-vite react-ts app: package.json, src/main.tsx and src/App.tsx
  printf '{"dependencies": {"react": "^19.0.0"}, "devDependencies": {"vite": "^8.0.0"}}\n' > "$WORK/package.json"
  : > "$WORK/src/main.tsx"
  : > "$WORK/src/App.tsx"
}

file() { mkdir -p "$WORK/$(dirname "$1")"; printf '%s' "${2:-}" > "$WORK/$1"; }

ugm() { run --separate-stderr zsh "$UGM" "$@"; }

# expect_mode <mode> <rule>
expect_mode() {
  ugm mode --repo "$WORK"
  [ "$status" -eq 0 ] || { echo "status $status: $output $stderr"; return 1; }
  [ "$output" = "$(jq -nc --arg m "$1" --arg r "$2" '{mode: $m, rule: $r}')" ] || { echo "got $output"; return 1; }
}

@test "mode: a fresh create-vite app, holding only src/main.tsx and src/App.tsx, is block" {
  expect_mode block fresh
}

@test "mode: a .tsx or .jsx file outside tests is UI code, and warn" {
  file src/pages/Orders.tsx
  expect_mode warn ui-code
  rm "$WORK/src/pages/Orders.tsx"
  file src/Legacy.jsx
  expect_mode warn ui-code
}

@test "mode: test files, test directories, node_modules, build output and dot-directories are not UI code" {
  file src/Orders.test.tsx
  file src/Orders.spec.jsx
  file src/test/query-wrapper.tsx
  file tests/e2e/fixture.tsx
  file src/__tests__/Orders.tsx
  file node_modules/some-lib/Button.tsx
  file dist/assets/App.jsx
  file build/App.jsx
  file coverage/lcov-report/App.tsx
  file .storybook/preview.tsx
  expect_mode block fresh
}

@test "mode: only the ROOT src/main.tsx and src/App.tsx are create-vite's" {
  file packages/web/src/App.tsx
  expect_mode warn ui-code
}

@test "mode: an app bootstrapped before #3018 (the family matcher in src/test/setup.ts) is block, even with UI code" {
  mkdir -p "$WORK/src/test"
  cp "$FIX/setup.ts" "$WORK/src/test/setup.ts"
  file src/pages/Orders.tsx
  printf '{"devDependencies": {"axe-core": "^4.10.0"}}\n' > "$WORK/package.json"
  expect_mode block family-matcher
}

@test "mode: a setup.ts that only names toHaveNoViolations, without expect.extend, is not the family matcher" {
  file src/test/setup.ts 'import "vitest-axe/extend-expect"; // toHaveNoViolations'
  expect_mode block fresh
}

@test "mode: an app with its own axe package is warn, whichever axe package it is" {
  local pkg
  for pkg in axe-core vitest-axe jest-axe @axe-core/playwright @axe-core/react; do
    jq -n --arg p "$pkg" '{devDependencies: {($p): "1.0.0"}}' > "$WORK/package.json"
    expect_mode warn own-axe || { echo "package: $pkg"; return 1; }
  done
}

@test "mode: an axe package outside devDependencies, or a near-miss name, is not an own axe setup" {
  printf '{"dependencies": {"axe-core": "^4.10.0"}, "devDependencies": {"axe-corey": "1", "my-axe-core": "1"}}\n' > "$WORK/package.json"
  expect_mode block fresh
}

@test "mode: a missing or non-object package.json decides nothing (exit 3, empty stdout)" {
  rm "$WORK/package.json"
  ugm mode --repo "$WORK"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'the own-axe rule cannot be judged'
  printf '[1]\n' > "$WORK/package.json"
  ugm mode --repo "$WORK"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "write: writes the switch when absent, as two-space JSON with a11y on its own line" {
  ugm write --repo "$WORK" --mode warn
  [ "$status" -eq 0 ]
  [ "$output" = '{"action":"written","a11y":"warn"}' ]
  [ "$(cat "$WORK/ui-gates.json")" = "$(printf '{\n  "schema": "ui-gates/v1",\n  "a11y": "warn"\n}')" ]
  # a one-line edit flips it
  grep -qxF '  "a11y": "warn"' "$WORK/ui-gates.json"
  # no temp file is left beside it
  [ "$(find "$WORK" -maxdepth 1 -name '.ui-gates.json.*' | wc -l | tr -d ' ')" = 0 ]
}

@test "write: an a11y value already in the file is never changed, and the file is not rewritten" {
  printf '{"a11y": "block", "component_gates": "warn"}\n' > "$WORK/ui-gates.json"
  cp "$WORK/ui-gates.json" "$BATS_TEST_TMPDIR/before.json"
  ugm write --repo "$WORK" --mode warn
  [ "$status" -eq 0 ]
  [ "$output" = '{"action":"kept","a11y":"block"}' ]
  cmp -s "$WORK/ui-gates.json" "$BATS_TEST_TMPDIR/before.json"
  # an invalid value is kept too: the gate reports it, bootstrap does not repair it
  printf '{"a11y": "off"}\n' > "$WORK/ui-gates.json"
  ugm write --repo "$WORK" --mode block
  [ "$output" = '{"action":"kept","a11y":"off"}' ]
  grep -qF '"off"' "$WORK/ui-gates.json"
}

@test "write: a file without the a11y key gains it and keeps every other key" {
  printf '{"schema": "ui-gates/v1", "component_gates": "warn"}\n' > "$WORK/ui-gates.json"
  ugm write --repo "$WORK" --mode block
  [ "$status" -eq 0 ]
  [ "$output" = '{"action":"written","a11y":"block"}' ]
  [ "$(jq -c . "$WORK/ui-gates.json")" = '{"schema":"ui-gates/v1","component_gates":"warn","a11y":"block"}' ]
  # a file with no schema key gets one, ahead of the rest
  printf '{"component_gates": "warn"}\n' > "$WORK/ui-gates.json"
  ugm write --repo "$WORK" --mode warn
  [ "$(jq -c . "$WORK/ui-gates.json")" = '{"schema":"ui-gates/v1","component_gates":"warn","a11y":"warn"}' ]
}

@test "write: a file that is not a JSON object is left untouched (exit 3)" {
  local body
  for body in '[1]' 'not json' '"block"'; do
    printf '%s\n' "$body" > "$WORK/ui-gates.json"
    ugm write --repo "$WORK" --mode block
    [ "$status" -eq 3 ] || { echo "$body: status $status"; return 1; }
    [ -z "$output" ]
    [ "$(cat "$WORK/ui-gates.json")" = "$body" ]
  done
}

@test "predecessor: the #1946 setup.ts and canary are known; today's templates and any edit are not" {
  ugm predecessor --file "$FIX/setup.ts"
  [ "$output" = '{"known":true,"template":"src/test/setup.ts"}' ]
  ugm predecessor --file "$FIX/a11y-canary.test.tsx"
  [ "$output" = '{"known":true,"template":"src/test/a11y-canary.test.tsx"}' ]
  ugm predecessor --file "$RX/src/test/setup.ts"
  [ "$output" = '{"known":false}' ]
  # one byte changed is a customised file, which takes the rule-3 prompt
  { cat "$FIX/setup.ts"; printf '\n'; } > "$BATS_TEST_TMPDIR/edited.ts"
  ugm predecessor --file "$BATS_TEST_TMPDIR/edited.ts"
  [ "$output" = '{"known":false}' ]
}

@test "the #1946 fixtures are the templates as #1946 shipped them, not today's" {
  # the fixtures stand in for history: each still carries #1946's matcher call,
  # which #3018 replaced
  grep -qxF '    expect(results).not.toHaveNoViolations();' "$FIX/a11y-canary.test.tsx"
  grep -qxF '  toHaveNoViolations(results: AxeResults) {' "$FIX/setup.ts"
  run cmp -s "$FIX/setup.ts" "$RX/src/test/setup.ts"
  [ "$status" -eq 1 ]
  run cmp -s "$FIX/a11y-canary.test.tsx" "$RX/src/test/a11y-canary.test.tsx"
  [ "$status" -eq 1 ]
}

@test "usage: a bad subcommand, flag, mode or path is exit 2 with nothing on stdout" {
  local args
  for args in "" "frobnicate --repo $WORK" "mode" "mode --repo" "mode --repo $WORK --bogus" \
    "mode --repo $WORK/missing" "write --repo $WORK" "write --repo $WORK --mode off" \
    "predecessor" "predecessor --file $WORK/missing" "predecessor --file $FIX/setup.ts --repo $WORK"; do
    # shellcheck disable=SC2086 # word-splitting the argument list is the point
    run --separate-stderr zsh "$UGM" $args
    [ "$status" -eq 2 ] || { echo "'$args': status $status"; return 1; }
    [ -z "$output" ] || { echo "'$args': stdout $output"; return 1; }
  done
}
