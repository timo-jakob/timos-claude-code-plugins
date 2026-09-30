#!/usr/bin/env bats
#
# The `react` topic marker (issue #956, epic #686). The orchestrator's topic
# detection recipe matches `react` in the **runtime** dependencies of ANY
# package.json, monorepo-aware, under detect_lang's prune set.
#
# CRITICAL DESIGN POINT: these tests do NOT re-implement the recipe. They extract
# the authoritative one from the fenced block in
# development/skills/maintenance/SKILL.md (between the `# react-marker:begin` and
# `# react-marker:end` sentinels) and `eval` it. A hand-copied helper would prove
# things about the test file rather than about the artifact the orchestrator
# actually follows, letting the SKILL.md recipe drift — e.g. widen to
# devDependencies — with a green suite. The extraction is asserted non-empty so a
# broken extraction can never silently make every test vacuous, and every negative
# test asserts the precise no-match status (1) rather than "any failure", so a
# recipe that blows up (127, a set -e abort) cannot masquerade as a clean rejection.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO_ROOT/development/skills/maintenance/SKILL.md"
  DETECT="$REPO_ROOT/development/skills/bootstrap/scripts/detect-stack.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
  cd "$WORK"

  # SHAPE guards first. `sed -n '/begin/,/end/p'` prints to END OF FILE when the
  # closing sentinel is missing/renamed, and a duplicated opening sentinel
  # concatenates blocks — either way RECIPE would become most of SKILL.md, whose
  # later fenced blocks contain git/gh commands and $(...) substitutions that
  # `eval` would then execute. Content-only guards cannot catch that, because the
  # real recipe is a PREFIX of the runaway blob. So: pin exactly one sentinel
  # pair, and bound the extraction's size and its first/last lines.
  [ "$(grep -c '^# react-marker:begin$' "$SKILL")" -eq 1 ]
  [ "$(grep -c '^# react-marker:end$' "$SKILL")" -eq 1 ]

  # the ONE source of truth: the recipe as documented, comments stripped
  RECIPE="$(sed -n '/^# react-marker:begin$/,/^# react-marker:end$/p' "$SKILL" | grep -v '^#')"
  [ -n "$RECIPE" ]
  [ "$(printf '%s\n' "$RECIPE" | wc -l)" -le 20 ]
  starts_with "$RECIPE" 'if ! command -v jq'
  ends_with "$RECIPE" 'fi'
  contains "$RECIPE" 'package.json'

  # the SECOND executable react recipe: the path lister that fills
  # language_meta.manifests. It duplicates the prune set, so it gets the same
  # sentinel treatment and the same derived parity oracle.
  [ "$(grep -c '^  # react-manifests:begin$' "$SKILL")" -eq 1 ]
  [ "$(grep -c '^  # react-manifests:end$' "$SKILL")" -eq 1 ]
  MANIFESTS="$(sed -n '/^  # react-manifests:begin$/,/^  # react-manifests:end$/p' "$SKILL" \
    | grep -v '^  #' | sed 's/^  //')"
  [ -n "$MANIFESTS" ]
  [ "$(printf '%s\n' "$MANIFESTS" | wc -l)" -le 14 ]
  starts_with "$MANIFESTS" 'find .'
  ends_with "$MANIFESTS" '|| true'
}

list_manifests() { eval "$MANIFESTS"; }

react_marker() { eval "$RECIPE"; }

# write a package.json at <path> declaring <dep> under <block>
write_pkg() {
  local path="$1" block="$2" dep="${3:-react}"
  mkdir -p "$(dirname "$path")"
  jq -n --arg b "$block" --arg d "$dep" '{name: "app", ($b): {($d): "19.0.0"}}' > "$path"
}

@test "react marker: true when react is a runtime dependency of the root package.json" {
  write_pkg ./package.json dependencies
  run react_marker
  [ "$status" -eq 0 ]
}

@test "react marker: false on a package.json without react at all" {
  write_pkg ./package.json dependencies lodash
  run react_marker
  [ "$status" -eq 1 ]
}

@test "react marker: devDependencies-only does NOT match (React tooling is not a React app)" {
  write_pkg ./package.json devDependencies
  run react_marker
  [ "$status" -eq 1 ]
}

@test "react marker: peerDependencies-only does NOT match (a React component library is not a React app)" {
  write_pkg ./package.json peerDependencies
  run react_marker
  [ "$status" -eq 1 ]
}

@test "react marker: react-dom without react does NOT match (exact key, not a prefix)" {
  write_pkg ./package.json dependencies react-dom
  run react_marker
  [ "$status" -eq 1 ]
}

@test "react marker: a monorepo sub-package matches even when the ROOT package.json lacks react" {
  jq -n '{name: "root", private: true, workspaces: ["packages/*"]}' > package.json
  write_pkg ./packages/web/package.json dependencies
  run react_marker
  [ "$status" -eq 0 ]
}

@test "react marker: a package path containing a space still matches (find -exec passes one argv element)" {
  write_pkg './packages/my app/package.json' dependencies
  run react_marker
  [ "$status" -eq 0 ]
}

@test "react marker: false when there is no package.json at all" {
  printf '# readme\n' > README.md
  run react_marker
  [ "$status" -eq 1 ]
}

@test "react marker: a match only under node_modules/ does NOT count (transitive-dep false positive)" {
  write_pkg ./package.json dependencies lodash
  write_pkg ./node_modules/some-lib/package.json dependencies
  run react_marker
  [ "$status" -eq 1 ]
}

@test "react marker: a NESTED node_modules/ is pruned too (not just the root one)" {
  jq -n '{name: "root", private: true}' > package.json
  write_pkg ./packages/web/node_modules/react-dep/package.json dependencies
  run react_marker
  [ "$status" -eq 1 ]
}

# --- prune-set parity with detect-stack.sh's detect_lang (#956 review round 1) ---
# Any divergence breaks the required-language gate: a package.json in a tree the
# marker searches but detect_lang prunes fires `react` while `javascript` is NOT
# detected. templates/ is the concrete case — #957 ships React bootstrap templates.

@test "react marker: a match only under templates/ does NOT count (detect_lang prunes it — #957's own templates)" {
  write_pkg ./templates/languages/javascript/react/package.json dependencies
  run react_marker
  [ "$status" -eq 1 ]
}

@test "react marker: a match only under dist/ does NOT count" {
  write_pkg ./dist/package.json dependencies
  run react_marker
  [ "$status" -eq 1 ]
}

@test "react marker: a match only under vendor/ does NOT count" {
  write_pkg ./vendor/package.json dependencies
  run react_marker
  [ "$status" -eq 1 ]
}

@test "react marker: a match only under .build/ does NOT count" {
  write_pkg ./.build/package.json dependencies
  run react_marker
  [ "$status" -eq 1 ]
}

@test "react marker: a match only under .git/ does NOT count" {
  write_pkg ./.git/package.json dependencies
  run react_marker
  [ "$status" -eq 1 ]
}

@test "react marker: a repo whose ROOT directory has a pruned name is still searched (start dir is '.')" {
  # find tests the start point as the literal '.', which matches no prune pattern,
  # so a checkout in a directory named `templates` is searched normally. (This is
  # why -mindepth 1 is a no-op here, unlike detect_lang's absolute-$cwd search.)
  local nested="$BATS_TEST_TMPDIR/templates"
  mkdir -p "$nested"
  cd "$nested"
  write_pkg ./package.json dependencies
  run react_marker
  [ "$status" -eq 0 ]
}

@test "react marker: a MISSING jq is status 2 (could not evaluate), never 1 (not React), and does NOT kill the caller" {
  # the three-way verdict: conflating 'cannot evaluate' with 'no React' would
  # silently skip the whole topic on a jq-less machine. The trailing AFTER= probe
  # is what pins `( exit 2 )` rather than a bare `exit 2` — the latter would
  # terminate a caller that sourced/eval'd the recipe mid-detection, and a test
  # whose recipe is the LAST command cannot tell the two apart.
  write_pkg ./package.json dependencies
  stub="$BATS_TEST_TMPDIR/nojq"
  mkdir -p "$stub"
  bash_bin="$(command -v bash)"
  run --separate-stderr env PATH="$stub" "$bash_bin" -c \
    "cd '$PWD'; $RECIPE; rc=\$?; printf 'AFTER=%s\n' \"\$rc\""
  [ "$status" -eq 0 ]
  contains "$output" 'AFTER=2'
  contains "$stderr" 'UNEVALUATED'
}

@test "react marker: an unreadable subdirectory does not abort an errexit caller (the || true on the capture)" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  write_pkg ./package.json dependencies
  mkdir -p ./locked
  chmod 000 ./locked
  run bash -c "set -e; cd '$PWD'; $RECIPE"
  chmod 755 ./locked
  [ "$status" -eq 0 ]
}

@test "react marker: a malformed manifest's jq errors are suppressed (2>/dev/null), not leaked to the transcript" {
  mkdir -p ./packages/aaa-bad
  printf 'not json at all\n' > ./packages/aaa-bad/package.json
  write_pkg ./packages/web/package.json dependencies
  run --separate-stderr react_marker
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "react marker: prune patterns match a WHOLE path segment — distribution/ and templates-src/ are still searched" {
  # guards against a widening to '*/dist*' / '*templates*', which the derived
  # oracle cannot catch if both lists are edited together
  write_pkg ./distribution/package.json dependencies
  run react_marker
  [ "$status" -eq 0 ]

  rm -rf distribution
  write_pkg ./templates-src/package.json dependencies
  run react_marker
  [ "$status" -eq 0 ]
}

@test "react marker: a symlinked DIRECTORY is not traversed (the documented -P trade; -L would loop on symlink farms)" {
  mkdir -p "$BATS_TEST_TMPDIR/outside/web"
  jq -n '{name: "app", dependencies: {react: "19.0.0"}}' > "$BATS_TEST_TMPDIR/outside/web/package.json"
  mkdir -p ./packages
  ln -s "$BATS_TEST_TMPDIR/outside/web" ./packages/web
  run react_marker
  [ "$status" -eq 1 ]
}

# --- the manifests lister (the SECOND executable recipe, feeding language_meta) ---

@test "manifests lister: prints the matching package.json paths, repo-relative" {
  jq -n '{name: "root", private: true}' > package.json
  write_pkg ./packages/web/package.json dependencies
  run list_manifests
  [ "$status" -eq 0 ]
  [ "$output" = "packages/web/package.json" ]
}

@test "manifests lister: prints NOTHING for pruned trees and non-matching manifests" {
  write_pkg ./package.json dependencies lodash
  write_pkg ./node_modules/lib/package.json dependencies
  write_pkg ./templates/app/package.json dependencies
  write_pkg ./dist/package.json dependencies
  run list_manifests
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "manifests lister: a path containing a space is ONE line, not split" {
  write_pkg './packages/my app/package.json' dependencies
  run list_manifests
  [ "$status" -eq 0 ]
  [ "$output" = "packages/my app/package.json" ]
}

@test "manifests lister: a matching ROOT package.json is listed as 'package.json' (the ./ strip at depth 1)" {
  # the majority repo shape, and the one every other lister test misses: they all
  # match at a NESTED path or assert empty. A drift in the start point or depth
  # would emit [] here while the verdict recipe still fires react — a React payload
  # naming no manifest, which is the exact failure `manifests` exists to prevent.
  write_pkg ./package.json dependencies
  run list_manifests
  [ "$status" -eq 0 ]
  [ "$output" = "package.json" ]
}

@test "manifests lister: lists EVERY match, not just the first (a batched -exec + would truncate)" {
  # the four single-match tests cannot see this: with `-exec ... +`, $1 binds only
  # the FIRST file of each batch and every other match is silently dropped — which
  # is the whole point of a field called `manifests`. The malformed sibling sorts
  # first, so this also pins the batch-abort isolation the SKILL calls load-bearing.
  mkdir -p ./packages/aaa-bad
  printf 'not json at all\n' > ./packages/aaa-bad/package.json
  write_pkg ./packages/web/package.json dependencies
  write_pkg ./apps/admin/package.json dependencies
  run list_manifests
  [ "$status" -eq 0 ]
  # sorted, so the assertion does not depend on find's traversal order
  [ "$(printf '%s\n' "$output" | sort | tr '\n' '|')" = "apps/admin/package.json|packages/web/package.json|" ]
}

@test "manifests lister: the recipe uses the per-file exec form and the same narrowing as the verdict" {
  contains "$MANIFESTS" '{} \;'
  lacks "$MANIFESTS" '{} +'
  # depth parity with the verdict recipe: a drift to -mindepth 2 (or a start dir
  # other than '.') would silently emit [] for a plain single-package React repo
  contains "$MANIFESTS" '-mindepth 1'
  contains "$MANIFESTS" '! -type d'
  contains "$MANIFESTS" '.dependencies.react'
  lacks "$MANIFESTS" 'devDependencies'
  lacks "$MANIFESTS" 'peerDependencies'
}

@test "manifests lister: a symlinked manifest is listed, matching the verdict recipe (no narrower)" {
  # if the two diverged here a repo would dispatch as React while manifests omitted
  # the very file that fired the marker
  mkdir -p ./shared ./packages/web
  jq -n '{name: "app", dependencies: {react: "19.0.0"}}' > ./shared/manifest.json
  ln -s ../../shared/manifest.json ./packages/web/package.json
  run list_manifests
  [ "$status" -eq 0 ]
  [ "$output" = "packages/web/package.json" ]
}

@test "manifests lister: an unreadable subdirectory does not abort it (same tolerance as the verdict recipe)" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  write_pkg ./packages/web/package.json dependencies
  mkdir -p ./locked
  chmod 000 ./locked
  run bash -c "set -e; cd '$PWD'; $MANIFESTS"
  chmod 755 ./locked
  [ "$status" -eq 0 ]
  [ "$output" = "packages/web/package.json" ]
}

@test "manifests lister: devDependencies-only is not listed (same narrowing as the verdict recipe)" {
  write_pkg ./package.json devDependencies
  run list_manifests
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- failure isolation: per-file -exec, never a batched + ---

@test "react marker: a MALFORMED package.json sorted before a real match does not suppress it (per-file -exec, not +)" {
  # the discriminating input: a batched `jq` aborts at the parse error and skips
  # every remaining file in that batch, so this fails under `-exec ... +` and
  # passes under the documented `-exec ... \;`
  mkdir -p ./packages/aaa-bad
  printf 'not json at all\n' > ./packages/aaa-bad/package.json
  write_pkg ./packages/web/package.json dependencies
  run react_marker
  [ "$status" -eq 0 ]
}

@test "react marker: a malformed package.json on its own is a deliberate non-match" {
  printf 'not json at all\n' > package.json
  run react_marker
  [ "$status" -eq 1 ]
}

@test "react marker: an early non-matching package.json does not mask a later match" {
  write_pkg ./package.json dependencies lodash
  write_pkg ./packages/web/package.json dependencies
  run react_marker
  [ "$status" -eq 0 ]
}

# --- the authoritative row + prose, anchored (never a whole-file grep) ---

@test "the react topics-table ROW pins the runtime-only narrowing as a NEGATION, so widening it fails here" {
  # anchor on the gather-script column so this selects the TOPICS row only — a bare
  # '^| `react` |' also matches the required-language gate row further down
  row="$(grep -E '^\| `react` \|.*gather-react-findings\.zsh' "$SKILL")"
  [ -n "$row" ]
  [ "$(printf '%s\n' "$row" | wc -l)" -eq 1 ]
  # the negation is what a devDependencies widening must destroy; asserting the
  # mere PRESENCE of the word 'devDependencies' would be satisfied by a widened
  # row reading "dependencies or devDependencies"
  contains "$row" '**not** `devDependencies`'
  contains "$row" 'monorepo-aware'
  contains "$row" 'requires language `javascript`'
  contains "$row" 'gather-react-findings.zsh'
}

@test "the recipe's prune set is DERIVED-equal to detect_lang's, not merely similar" {
  # the parity oracle: extract both prune sets from their authoritative sources and
  # compare. A hand-copied list here would repeat exactly the defect this suite
  # fixed for the recipe body — if detect_lang gains or loses a prune entry (as it
  # did when `templates` was added), the marker silently diverges, the
  # required-language gate breaks, and a literal list would stay green.
  detect_set="$(sed -n '/^detect_lang()/,/^}/p' "$DETECT" \
    | grep -oE "\-path '[^']+' -prune" | sort -u)"
  recipe_set="$(printf '%s\n' "$RECIPE" | grep -oE "\-path '[^']+' -prune" | sort -u)"
  manifests_set="$(printf '%s\n' "$MANIFESTS" | grep -oE "\-path '[^']+' -prune" | sort -u)"
  [ -n "$detect_set" ]
  [ "$recipe_set" = "$detect_set" ]
  # the manifests lister is a THIRD copy of the prune set — hold it to the same oracle
  [ "$manifests_set" = "$detect_set" ]
}

@test "the extracted recipe keeps -mindepth 1 for diff-parity with detect_lang" {
  contains "$RECIPE" '-mindepth 1'
}

@test "the extracted recipe reads runtime dependencies only, per-file, and never hands jq a directory" {
  contains "$RECIPE" ".dependencies.react // empty"
  lacks "$RECIPE" 'devDependencies'
  lacks "$RECIPE" 'peerDependencies'
  # `! -type d` rather than `-type f`: a DIRECTORY named package.json must never
  # reach jq, but a symlinked manifest (which detect_lang matches by name) must
  # still count, or the marker would be narrower than the language detector
  contains "$RECIPE" '! -type d'
  # per-file terminator, NOT a batched `+`
  contains "$RECIPE" '{} \;'
  lacks "$RECIPE" '{} +'
}

@test "the recipe CAPTURES the find output instead of piping into grep -q (pipefail-safe)" {
  # `find … | grep -q .` inverts under `set -o pipefail`: grep short-circuits on the
  # first hit, the next jq child dies on SIGPIPE, find reports non-zero, and a real
  # React repo reads as 'not React'. Capture-and-test has no pipe in the verdict.
  lacks "$RECIPE" 'grep -q'
  contains "$RECIPE" 'react_hits='
  contains "$RECIPE" '[ -n "$react_hits" ]'
}

@test "the recipe's verdict survives set -o pipefail on a MATCHING repo (with real pipe pressure)" {
  # a SINGLE match cannot discriminate: grep -q would short-circuit only after find
  # already finished, so no SIGPIPE occurs and the pipe form would pass too. Many
  # matches make a piped verdict short-circuit mid-traversal, which is exactly when
  # find dies on SIGPIPE and pipefail inverts the result.
  local i
  for i in $(seq 1 60); do write_pkg "./packages/p$i/package.json" dependencies; done
  run bash -c "set -o pipefail; cd '$PWD'; $RECIPE"
  [ "$status" -eq 0 ]
}

@test "a symlinked package.json still matches (detect_lang matches by name, so the marker must not be narrower)" {
  mkdir -p ./shared ./packages/web
  jq -n '{name: "app", dependencies: {react: "19.0.0"}}' > ./shared/manifest.json
  ln -s ../../shared/manifest.json ./packages/web/package.json
  run react_marker
  [ "$status" -eq 0 ]
}

@test "the SKILL documents jq as a prerequisite whose absence is NOT a negative verdict" {
  body="$(cat "$SKILL")"
  contains "$body" 'command -v jq'
  contains "$body" 'jq not on PATH: the React marker could not be evaluated'
}

@test "the SKILL enforces the required-language gate in the PARTITION step, not only in prose" {
  body="$(cat "$SKILL")"
  contains "$body" 'Required language'
  contains "$body" 'marker present but required language <lang> is not in the supported set'
  # the gate table must bind react to javascript and spring to java
  contains "$body" '| `react` | `javascript` |'
  contains "$body" '| `spring` | `java` |'
}

@test "the SKILL states the load-bearing reason for per-file -exec (batch abort), not the false exit-status one" {
  body="$(cat "$SKILL")"
  contains "$body" 'aborts at the first unparseable'
  lacks "$body" 'exit status reflects only the *last* value'
}

# --- the dispatcher + registries, each assertion anchored to its structure ---

@test "the development-react dispatcher SKILL.md exists" {
  [ -f "$REPO_ROOT/development-react/skills/maintenance/SKILL.md" ]
}

@test "the dispatcher validates a v2 payload and checks the no-arguments case first" {
  skill="$REPO_ROOT/development-react/skills/maintenance/SKILL.md"
  body="$(cat "$skill")"
  contains "$body" 'schema_version == "2"'
  # the empty-$ARGUMENTS guard must precede the test -f line
  argline="$(grep -n '\[ -n "\$ARGUMENTS" \]' "$skill" | head -1 | cut -d: -f1)"
  fileline="$(grep -n 'test -f "\$ARGUMENTS"' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$argline" ]
  [ -n "$fileline" ]
  [ "$argline" -lt "$fileline" ]
}

@test "the dispatcher returns js-ci-fixer as its ci_fixer_agent (the exact binding, not a mention)" {
  skill="$REPO_ROOT/development-react/skills/maintenance/SKILL.md"
  body="$(cat "$skill")"
  contains "$body" '"ci_fixer_agent": "js-ci-fixer"'
}

@test "the dispatcher records unhandled-tool findings in missing_tooling rather than dropping them" {
  skill="$REPO_ROOT/development-react/skills/maintenance/SKILL.md"
  body="$(cat "$skill")"
  contains "$body" 'add an entry to `missing_tooling`'
  contains "$body" 'does not handle yet'
}

@test "the dispatcher's ROUTING TABLE routes a11y and lighthouse_budget to react-webui-quality-advisor (#1948)" {
  skill="$REPO_ROOT/development-react/skills/maintenance/SKILL.md"
  # the table rows themselves — a whole-file grep for the agent name would be
  # satisfied by the frontmatter and prose, and would survive deleting the table
  run grep -cE '^\| `a11y` \| `react-webui-quality-advisor` \(opus\) \|' "$skill"
  [ "$output" = "1" ]
  run grep -cE '^\| `lighthouse_budget` \| `react-webui-quality-advisor` \(opus\) \|' "$skill"
  [ "$output" = "1" ]
  # and the empty-universe placeholder row is gone
  run grep -F '(none yet' "$skill"
  [ "$status" -eq 1 ]
}

@test "the development-react plugin.json exists at v0.3.0 and marketplace.json matches it in lockstep" {
  plugin="$REPO_ROOT/development-react/.claude-plugin/plugin.json"
  [ -f "$plugin" ]
  run jq -er '.version' "$plugin"
  [ "$status" -eq 0 ]
  [ "$output" = "0.3.0" ]

  run jq -er '.plugins[] | select(.name == "development-react") | .version' \
    "$REPO_ROOT/.claude-plugin/marketplace.json"
  [ "$status" -eq 0 ]
  [ "$output" = "0.3.0" ]
}

@test "the marketplace entry points at ./development-react" {
  run jq -er '.plugins[] | select(.name == "development-react") | .source' \
    "$REPO_ROOT/.claude-plugin/marketplace.json"
  [ "$status" -eq 0 ]
  [ "$output" = "./development-react" ]
}

@test "ARCHITECTURE.md's Topic TABLE ROW lists development-react (not merely a mention elsewhere)" {
  row="$(grep -E '^\| \*\*Topic\*\* \|' "$REPO_ROOT/ARCHITECTURE.md")"
  [ -n "$row" ]
  contains "$row" 'development-react'
}

@test "development-react is registered in the docs-reference generator, so the command reference includes it" {
  body="$(cat "$REPO_ROOT/scripts/generate-docs-reference.py")"
  contains "$body" '"development-react"'
  contains "$(cat "$REPO_ROOT/docs/reference/commands.md")" '/development-react:maintenance'
}

@test "docs/reference/plugins.md documents the development-react plugin" {
  grep -Fq '## development-react' "$REPO_ROOT/docs/reference/plugins.md"
}

# --- #959: detect-stack.sh's is_react — the review-dispatch marker ------------
# review-dispatch.zsh adds development-react:review when detect-stack reports
# is_react, so detect-stack carries a SECOND copy of the search above. It is held
# identical to the recipe, not merely similar: the find expression is extracted
# from both bounded blocks and compared whole, after flattening line
# continuations and whitespace. The failure handling around it deliberately
# differs (the recipe answers a predicate; detect-stack reports an unfinished
# search as `is_react: null` on a JS repo), which is why the comparison is over
# the expression, not the block.

# the bounded is-react-marker block of detect-stack.sh
detect_react_block() {
  [ "$(grep -c '^# is-react-marker:begin$' "$DETECT")" -eq 1 ]
  [ "$(grep -c '^# is-react-marker:end$' "$DETECT")" -eq 1 ]
  sed -n '/^# is-react-marker:begin$/,/^# is-react-marker:end$/p' "$DETECT"
}

# the find expression in $1, from `find .` through the per-file `{} \;`, with
# line continuations joined and whitespace squeezed to single spaces
find_expr_of() {
  printf '%s\n' "$1" | sed -e 's/\\$//' | tr '\n\t' '  ' | tr -s ' ' \
    | grep -oE 'find \. .*\{\} \\;'
}

@test "is_react: detect-stack's search is IDENTICAL to the SKILL.md recipe's (#959)" {
  local block recipe_expr detect_expr
  block="$(detect_react_block)"
  [ -n "$block" ]
  [ "$(printf '%s\n' "$block" | wc -l)" -le 45 ]
  recipe_expr="$(find_expr_of "$RECIPE")"
  detect_expr="$(find_expr_of "$block")"
  [ -n "$recipe_expr" ]
  [ -n "$detect_expr" ]
  # exactly one find expression in each, so the comparison cannot pick a stray one
  [ "$(printf '%s\n' "$recipe_expr" | wc -l)" -eq 1 ]
  [ "$(printf '%s\n' "$detect_expr" | wc -l)" -eq 1 ]
  [ "$detect_expr" = "$recipe_expr" ]
  # ...and it says the load-bearing things, so two identically WRONG copies
  # cannot pass by agreeing
  contains "$detect_expr" '-mindepth 1'
  contains "$detect_expr" '-name package.json ! -type d'
  contains "$detect_expr" ".dependencies.react // empty"
  lacks "$detect_expr" 'devDependencies'
}

@test "is_react: detect-stack's prune set is detect_lang's too (the third copy, same oracle)" {
  local detect_set block_set
  detect_set="$(sed -n '/^detect_lang()/,/^}/p' "$DETECT" \
    | grep -oE "\-path '[^']+' -prune" | sort -u)"
  block_set="$(detect_react_block | grep -oE "\-path '[^']+' -prune" | sort -u)"
  [ -n "$detect_set" ]
  [ "$block_set" = "$detect_set" ]
}

@test "is_react: the non-vacuity control — a widened copy is caught by the comparison" {
  # the same extraction over a copy with devDependencies added must DIFFER from
  # the recipe, or the identity test above proves nothing
  local widened
  widened="$(detect_react_block | sed "s/'.dependencies.react \/\/ empty'/'(.dependencies.react \/\/ .devDependencies.react) \/\/ empty'/")"
  [ "$(find_expr_of "$widened")" != "$(find_expr_of "$RECIPE")" ]
}

# Run the REAL detect-stack in the current fixture dir with `run`, asserting ITS
# exit status (not a pipeline's) before handing back is_react as $IS_REACT.
# `-c` so a null stays the literal `null`, distinct from a missing key.
detect_is_react() {
  run --separate-stderr "$@" bash "$DETECT"
  [ "$status" -eq 0 ] || { printf 'detect-stack exited %s: %s\n' "$status" "$stderr" >&2; return 1; }
  IS_REACT="$(printf '%s' "$output" | jq -c '.is_react')"
}

# A PATH holding every tool detect-stack needs EXCEPT jq, so only the jq branch
# can differ from a normal run.
no_jq_path() {
  local stub="$BATS_TEST_TMPDIR/nojq" t
  mkdir -p "$stub"
  for t in bash find grep sed awk tr sort head cat dirname basename git uname wc cut mktemp rm \
           printf test env date ls tail xargs; do
    if command -v "$t" >/dev/null 2>&1 && [ -x "$(command -v "$t")" ]; then
      ln -sf "$(command -v "$t")" "$stub/$t"
    fi
  done
  [ ! -e "$stub/jq" ]
  printf '%s' "$stub"
}

# A `find` wrapper that runs the real search, then exits 1 when — and only when
# — its arguments carry the react block's own jq filter. An unreadable directory
# cannot isolate the react branch (the kubernetes and opentofu blocks walk the
# same tree first and abort on it), and matching on `package.json` alone would
# also hit detect_lang's own search, which merely happens to ignore find's status.
react_find_shim() {
  local shim="$BATS_TEST_TMPDIR/findshim" real_find
  real_find="$(command -v find)"
  mkdir -p "$shim"
  printf '#!/usr/bin/env bash\n"%s" "$@"\ncase "$*" in *".dependencies.react // empty"*) exit 1 ;; esac\n' \
    "$real_find" > "$shim/find"
  chmod +x "$shim/find"
  printf '%s' "$shim"
}

@test "is_react: true for a runtime react dependency in the root package.json" {
  write_pkg ./package.json dependencies
  detect_is_react
  [ "$IS_REACT" = "true" ]
}

@test "is_react: true for a monorepo sub-package even when the root lacks react" {
  jq -n '{name: "root", private: true}' > package.json
  write_pkg ./packages/web/package.json dependencies
  detect_is_react
  [ "$IS_REACT" = "true" ]
}

@test "is_react: false for devDependencies-only" {
  write_pkg ./package.json devDependencies
  detect_is_react
  [ "$IS_REACT" = "false" ]
}

@test "is_react: false for peerDependencies-only" {
  write_pkg ./package.json peerDependencies
  detect_is_react
  [ "$IS_REACT" = "false" ]
}

@test "is_react: false for react-dom without react (exact key, not a prefix)" {
  write_pkg ./package.json dependencies react-dom
  detect_is_react
  [ "$IS_REACT" = "false" ]
}

@test "is_react: false when the only match is in a pruned tree (node_modules, templates, dist)" {
  write_pkg ./package.json dependencies lodash
  write_pkg ./node_modules/lib/package.json dependencies
  write_pkg ./templates/app/package.json dependencies
  write_pkg ./dist/package.json dependencies
  detect_is_react
  [ "$IS_REACT" = "false" ]
}

@test "is_react: a malformed manifest on its own is a non-match (false), not an unfinished search" {
  mkdir -p ./packages/aaa-bad
  printf 'not json at all\n' > ./packages/aaa-bad/package.json
  detect_is_react
  [ "$IS_REACT" = "false" ]
}

@test "is_react: a malformed manifest does not mask a real sibling match" {
  mkdir -p ./packages/aaa-bad
  printf 'not json at all\n' > ./packages/aaa-bad/package.json
  write_pkg ./packages/web/package.json dependencies
  detect_is_react
  [ "$IS_REACT" = "true" ]
}

@test "is_react: a missing jq on a JS repo is null — could not evaluate — and the run still completes" {
  write_pkg ./package.json dependencies
  local p
  p="$(no_jq_path)"
  detect_is_react env PATH="$p"
  [ "$IS_REACT" = "null" ]
  # silent: a success path that wrote to stderr would corrupt any caller that
  # captures both streams together (three detect-stack suites do, #1153/#1177)
  [ -z "$stderr" ]
}

@test "is_react: a missing jq on a repo with no JS manifest is simply false (core output needs no jq)" {
  printf '# readme\n' > README.md
  local p
  p="$(no_jq_path)"
  detect_is_react env PATH="$p"
  [ "$IS_REACT" = "false" ]
}

@test "is_react: a react search that did not complete with no hit is null, and the run still completes" {
  write_pkg ./package.json dependencies lodash
  local p
  p="$(react_find_shim)"
  detect_is_react env PATH="$p:$PATH"
  [ "$IS_REACT" = "null" ]
  [ -z "$stderr" ]
}

@test "is_react: a hit stands even when the react search did not complete" {
  write_pkg ./package.json dependencies
  local p
  p="$(react_find_shim)"
  detect_is_react env PATH="$p:$PATH"
  [ "$IS_REACT" = "true" ]
}

@test "is_react: a NON-JS repo with an unreadable subtree is false, not null, and the run completes (the #1153 shape)" {
  # the shape that reddened three existing detect-stack suites when the react
  # block aborted: kubernetes and opentofu answer from their hits, the react
  # search cannot finish — and with no JS manifest the answer is false, since a
  # null here would make review-dispatch refuse to plan a repo that cannot be
  # React
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  printf 'apiVersion: v2\nname: web\n' > Chart.yaml
  printf 'resource "null_resource" "x" {}\n' > main.tf
  mkdir -p ./locked
  chmod 000 ./locked
  run --separate-stderr bash "$DETECT"
  chmod 755 ./locked
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.is_react')" = "false" ]
  [ "$(printf '%s' "$output" | jq -c '.is_kubernetes')" = "true" ]
  # the react block adds nothing to stderr on this success path
  lacks "$stderr" 'react'
}

@test "is_react: a JS repo with an unreadable subtree and no hit is null, and the run completes" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  printf 'apiVersion: v2\nname: web\n' > Chart.yaml
  printf 'resource "null_resource" "x" {}\n' > main.tf
  write_pkg ./package.json dependencies lodash
  mkdir -p ./locked
  chmod 000 ./locked
  run --separate-stderr bash "$DETECT"
  chmod 755 ./locked
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.is_react')" = "null" ]
  [ "$(printf '%s' "$output" | jq -c '.languages')" = '["javascript"]' ]
}

@test "is_react: a non-JS repo whose react search did not complete is false (the javascript gate), via the find shim" {
  # the shim isolates the gate from the unreadable-directory mechanics above
  printf '# readme\n' > README.md
  local p
  p="$(react_find_shim)"
  detect_is_react env PATH="$p:$PATH"
  [ "$IS_REACT" = "false" ]
}
