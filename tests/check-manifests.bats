#!/usr/bin/env bats
#
# Behavioral tests for check-manifests.zsh (#2008) — the claude-plugin panel's
# `manifest` dimension as a pure script. The contract that matters:
#   - each of the six title templates fires for its fixture at its severity,
#     and a clean or plugin-neutral change emits [];
#   - the change is read against --base, committed or not, and a file moved
#     between plugins is a change to both;
#   - every finding is a Review-finding-schema object with dimension
#     "manifest", reviewer "check-manifests.zsh", round = --round, and no
#     proposed-severity line (the script IS the tool run);
#   - its lockstep detection agrees with gather-claude-plugin-findings.zsh;
#   - the carry contract: a fixed entry is confirmed at the version line, a
#     still-present one re-raised verbatim, a foreign entry exits 2, and the
#     --carry-out file holds one line per entry plus the triple.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CM="$REPO_ROOT/development-claude-plugin/skills/review/scripts/check-manifests.zsh"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-claude-plugin-findings.zsh"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  local p
  for p in alpha beta; do
    mkdir -p "$R/$p/.claude-plugin" "$R/$p/skills/demo" "$R/$p/docs"
    jq -n --arg n "$p" '{name: $n, version: "1.0.0", description: "fixture plugin"}' \
      > "$R/$p/.claude-plugin/plugin.json"
    printf 'body\n' > "$R/$p/skills/demo/SKILL.md"
    printf 'guide\n' > "$R/$p/docs/guide.md"
  done
  mkdir -p "$R/.claude-plugin" "$R/tests"
  jq -n '{name: "fixture-market", plugins: [{name: "alpha", version: "1.0.0", source: "./alpha"}, {name: "beta", version: "1.0.0", source: "./beta"}]}' > "$R/.claude-plugin/marketplace.json"
  printf 'x\n' > "$R/tests/a.bats"
  git -C "$R" add -A
  git -C "$R" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm base
  BASE="$(git -C "$R" rev-parse HEAD)"
}

# set_pj <plugin> <version>
set_pj() {
  jq --arg v "$2" '.version = $v' "$R/$1/.claude-plugin/plugin.json" > "$R/t"
  mv "$R/t" "$R/$1/.claude-plugin/plugin.json"
}
# set_market <plugin> <field> <value>
set_market() {
  jq --arg n "$1" --arg k "$2" --arg v "$3" '(.plugins[] | select(.name == $n))[$k] = $v' \
    "$R/.claude-plugin/marketplace.json" > "$R/t"
  mv "$R/t" "$R/.claude-plugin/marketplace.json"
}
# bump <plugin> <version> — both manifests, in lockstep
bump() { set_pj "$1" "$2"; set_market "$1" version "$2"; }
cm() { zsh "$CM" --repo "$R" --base "$BASE" "$@"; }
# commit_all — commit the working tree on top of BASE, so HEAD != BASE
commit_all() { git -C "$R" add -A && git -C "$R" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm change; }
titles() { jq -r '[.[] | "\(.severity) \(.title)"] | sort | .[]' <<< "$1"; }

@test "a clean change (content + lockstep bump) emits []" {
  printf 'more\n' >> "$R/alpha/skills/demo/SKILL.md"
  bump alpha 1.0.1
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "a change that touches no plugin content emits []" {
  printf 'y\n' >> "$R/tests/a.bats"
  printf 'root\n' > "$R/ARCHITECTURE.md"
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "skills/ change with no bump: content-changed CRITICAL on the changed file" {
  printf 'more\n' >> "$R/alpha/skills/demo/SKILL.md"
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$(titles "$output")" = "CRITICAL alpha: content changed with no version bump" ]
  [ "$(jq -r '.[0].file' <<< "$output")" = "alpha/skills/demo/SKILL.md" ]
  [ "$(jq -r '.[0].line' <<< "$output")" = "null" ]
}

@test "docs/ change with no bump is content too: content-changed CRITICAL" {
  printf 'more\n' >> "$R/beta/docs/guide.md"
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$(titles "$output")" = "CRITICAL beta: content changed with no version bump" ]
}

@test "an untracked new agent with no bump is content: content-changed CRITICAL" {
  mkdir -p "$R/alpha/agents"
  printf 'agent\n' > "$R/alpha/agents/new.md"
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$(titles "$output")" = "CRITICAL alpha: content changed with no version bump" ]
  [ "$(jq -r '.[0].file' <<< "$output")" = "alpha/agents/new.md" ]
}

@test "a hooks/ change with no bump is content too: content-changed CRITICAL" {
  mkdir -p "$R/alpha/hooks"
  printf 'hook\n' > "$R/alpha/hooks/on-start.zsh"
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$(titles "$output")" = "CRITICAL alpha: content changed with no version bump" ]
  [ "$(jq -r '.[0].file' <<< "$output")" = "alpha/hooks/on-start.zsh" ]
}

@test "a committed skills/ change with no bump, on top of BASE: content-changed CRITICAL" {
  printf 'more\n' >> "$R/alpha/skills/demo/SKILL.md"
  commit_all
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$(titles "$output")" = "CRITICAL alpha: content changed with no version bump" ]
}

@test "a committed content change with a lockstep bump, on top of BASE, emits []" {
  printf 'more\n' >> "$R/alpha/skills/demo/SKILL.md"
  bump alpha 1.0.1
  commit_all
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "a file moved between plugins is a change to both: two bumps emit [], no bump flags both" {
  mkdir -p "$R/beta/skills/moved"
  git -C "$R" mv alpha/skills/demo/SKILL.md beta/skills/moved/SKILL.md
  commit_all
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$(titles "$output" | tr '\n' '|')" = "CRITICAL alpha: content changed with no version bump|CRITICAL beta: content changed with no version bump|" ]
  bump alpha 1.0.1
  bump beta 1.1.0
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "a move out of an unbumped plugin names its no-bump finding at a path in the rename-aware diff" {
  mkdir -p "$R/beta/skills/moved"
  git -C "$R" mv alpha/skills/demo/SKILL.md beta/skills/moved/SKILL.md
  bump beta 1.1.0
  commit_all
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$(titles "$output")" = "CRITICAL alpha: content changed with no version bump" ]
  [ "$(jq -r '.[0].file' <<< "$output")" = "beta/skills/moved/SKILL.md" ]
  git -C "$R" diff --name-only "$BASE" | grep -qxF "$(jq -r '.[0].file' <<< "$output")"
}

@test "plugin.json bumped alone: lockstep CRITICAL at the plugin.json version line" {
  printf 'more\n' >> "$R/alpha/skills/demo/SKILL.md"
  set_pj alpha 1.0.1
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$(titles "$output")" = "CRITICAL alpha: plugin.json and marketplace.json versions out of lockstep" ]
  [ "$(jq -r '.[0].file' <<< "$output")" = "alpha/.claude-plugin/plugin.json" ]
  [ "$(jq -r '.[0].line' <<< "$output")" = "3" ]
}

@test "marketplace.json moved alone: lockstep CRITICAL at the entry's version line" {
  set_market beta version 1.0.1
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$(titles "$output")" = "CRITICAL beta: plugin.json and marketplace.json versions out of lockstep" ]
  [ "$(jq -r '.[0].file' <<< "$output")" = ".claude-plugin/marketplace.json" ]
  [ "$(sed -n "$(jq -r '.[0].line' <<< "$output")p" "$R/.claude-plugin/marketplace.json")" = '      "version": "1.0.1",' ]
}

@test "a new plugin.json with no marketplace entry: one-manifest CRITICAL" {
  mkdir -p "$R/gamma/.claude-plugin"
  jq -n '{name: "gamma", version: "0.1.0", description: "new"}' > "$R/gamma/.claude-plugin/plugin.json"
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$(titles "$output")" = "CRITICAL gamma: listed in only one manifest" ]
  [ "$(jq -r '.[0].file' <<< "$output")" = "gamma/.claude-plugin/plugin.json" ]
}

@test "a marketplace entry with no plugin.json: one-manifest CRITICAL on marketplace.json" {
  git -C "$R" rm -q -r beta
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$(titles "$output")" = "CRITICAL beta: listed in only one manifest" ]
  [ "$(jq -r '.[0].file' <<< "$output")" = ".claude-plugin/marketplace.json" ]
}

@test "a source path that is not the plugin directory: source CRITICAL" {
  set_market alpha source ./alpha-old
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$(titles "$output")" = "CRITICAL alpha: marketplace.json source path does not match the plugin directory" ]
  [ "$(sed -n "$(jq -r '.[0].line' <<< "$output")p" "$R/.claude-plugin/marketplace.json")" = '      "source": "./alpha-old"' ]
}

@test "a bump with only a change outside the plugin: needless-bump WARNING" {
  printf 'y\n' >> "$R/tests/a.bats"
  bump alpha 1.0.1
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$(titles "$output")" = "WARNING alpha: needless version bump (no plugin content changed)" ]
  [ "$(jq -r '.[0].file' <<< "$output")" = "alpha/.claude-plugin/plugin.json" ]
  [ "$(jq -r '.[0].line' <<< "$output")" = "3" ]
}

@test "a version that is not plain X.Y.Z: SUGGESTION on each manifest that carries it" {
  printf 'more\n' >> "$R/alpha/skills/demo/SKILL.md"
  bump alpha 1.0.1-rc1
  run cm --round 1
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[] | "\(.severity) \(.title) \(.file)"] | sort | join("|")' <<< "$output")" = \
    "SUGGESTION alpha: version is not plain X.Y.Z .claude-plugin/marketplace.json|SUGGESTION alpha: version is not plain X.Y.Z alpha/.claude-plugin/plugin.json" ]
}

@test "every finding carries dimension manifest, reviewer check-manifests.zsh, round = --round, the nine schema fields and no proposed-severity line" {
  printf 'more\n' >> "$R/alpha/skills/demo/SKILL.md"
  set_market beta version 2.0
  run cm --round 4
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -ge 3 ]
  jq -e 'all(.[]; .dimension == "manifest" and .reviewer == "check-manifests.zsh" and .round == 4)' <<< "$output"
  jq -e 'all(.[]; keys == ["description","dimension","file","line","reviewer","round","severity","suggested_fix","title"])' <<< "$output"
  jq -e 'all(.[]; .description | test("proposed-severity") | not)' <<< "$output"
}

@test "parity: check-manifests and gather-claude-plugin-findings agree on which plugins are out of lockstep" {
  set_pj alpha 1.1.0                                   # version_mismatch
  mkdir -p "$R/gamma/.claude-plugin"                   # missing_from_marketplace
  jq -n '{name: "gamma", version: "0.1.0", description: "new"}' > "$R/gamma/.claude-plugin/plugin.json"
  git -C "$R" rm -q -r beta                            # missing_plugin_json
  mine="$(cm --round 1 | jq -c '[.[] | select(.title | test(": (plugin\\.json and marketplace\\.json versions out of lockstep|listed in only one manifest)$")) | .title | sub(": .*$"; "")] | unique')"
  theirs="$(zsh "$GATHER" "$R" | jq -c '[.findings_by_tool.plugin_version_check[].plugin] | unique')"
  [ "$mine" = '["alpha","beta","gamma"]' ]
  [ "$mine" = "$theirs" ]
}

@test "carry: a fixed entry is confirmed at the plugin.json version line" {
  printf 'more\n' >> "$R/alpha/skills/demo/SKILL.md"
  bump alpha 1.0.1
  jq -n '[{file: "alpha/skills/demo/SKILL.md", line: null, dimension: "manifest", severity: "CRITICAL", title: "alpha: content changed with no version bump"}]' > "$BATS_TEST_TMPDIR/v.json"
  run cm --round 2 --fix-verification "$BATS_TEST_TMPDIR/v.json" --carry-out "$BATS_TEST_TMPDIR/out.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/out.txt" | tr -d ' ')" -eq 2 ]
  [ "$(sed -n 1p "$BATS_TEST_TMPDIR/out.txt")" = 'carried entry "alpha: content changed with no version bump" (alpha/skills/demo/SKILL.md, manifest): confirmed at alpha/.claude-plugin/plugin.json:3' ]
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/out.txt")" = 'carried: confirmed 1 / re-raised 0 / unconfirmed 0 of 1' ]
}

@test "carry: a still-present entry is re-raised verbatim (carried file, title, line) and not duplicated" {
  printf 'more\n' >> "$R/alpha/skills/demo/SKILL.md"
  set_pj alpha 1.0.1
  jq -n '[{file: "alpha/.claude-plugin/plugin.json", line: 7, dimension: "manifest", severity: "CRITICAL", title: "alpha: plugin.json and  marketplace.json versions out of lockstep"}]' > "$BATS_TEST_TMPDIR/v.json"
  run cm --round 3 --fix-verification "$BATS_TEST_TMPDIR/v.json" --carry-out "$BATS_TEST_TMPDIR/out.txt"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 1 ]
  [ "$(jq -c '.[0] | [.file, .line, .dimension, .severity, .round]' <<< "$output")" = '["alpha/.claude-plugin/plugin.json",7,"manifest","CRITICAL",3]' ]
  [ "$(jq -r '.[0].title' <<< "$output")" = 'alpha: plugin.json and  marketplace.json versions out of lockstep' ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/out.txt" | tr -d ' ')" -eq 2 ]
  [ "$(sed -n 1p "$BATS_TEST_TMPDIR/out.txt")" = 'carried entry "alpha: plugin.json and  marketplace.json versions out of lockstep" (alpha/.claude-plugin/plugin.json, manifest): re-raised (see finding)' ]
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/out.txt")" = 'carried: confirmed 0 / re-raised 1 / unconfirmed 0 of 1' ]
}

@test "carry: one confirmed and one re-raised entry give one line each and the triple" {
  printf 'more\n' >> "$R/alpha/skills/demo/SKILL.md"
  printf 'more\n' >> "$R/beta/skills/demo/SKILL.md"
  bump alpha 1.0.1
  jq -n '[{file: "alpha/skills/demo/SKILL.md", line: null, dimension: "manifest", severity: "CRITICAL", title: "alpha: content changed with no version bump"}, {file: "beta/skills/demo/SKILL.md", line: null, dimension: "manifest", severity: "CRITICAL", title: "beta: content changed with no version bump"}]' > "$BATS_TEST_TMPDIR/v.json"
  run cm --round 2 --fix-verification "$BATS_TEST_TMPDIR/v.json" --carry-out "$BATS_TEST_TMPDIR/out.txt"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[].title' <<< "$output")" = "beta: content changed with no version bump" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/out.txt" | tr -d ' ')" -eq 3 ]
  [ "$(tail -1 "$BATS_TEST_TMPDIR/out.txt")" = "carried: confirmed 1 / re-raised 1 / unconfirmed 0 of 2" ]
  run ! grep -q 'unconfirmed$' "$BATS_TEST_TMPDIR/out.txt"
}

@test "carry: two same-title entries re-raise one finding each, matched by file" {
  # the marketplace entry is carried FIRST, so a title-only match would take
  # the plugin.json finding; each live finding must absorb exactly one entry
  printf 'more\n' >> "$R/alpha/skills/demo/SKILL.md"
  bump alpha 1.0.1-rc1
  jq -n '[{file: ".claude-plugin/marketplace.json", line: null, dimension: "manifest", severity: "SUGGESTION", title: "alpha: version is not plain X.Y.Z"}, {file: "alpha/.claude-plugin/plugin.json", line: null, dimension: "manifest", severity: "SUGGESTION", title: "alpha: version is not plain X.Y.Z"}]' > "$BATS_TEST_TMPDIR/v.json"
  run cm --round 2 --fix-verification "$BATS_TEST_TMPDIR/v.json" --carry-out "$BATS_TEST_TMPDIR/out.txt"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].file] | sort | join("|")' <<< "$output")" = '.claude-plugin/marketplace.json|alpha/.claude-plugin/plugin.json' ]
  # a re-raise overwrites .file, so only the description shows which finding absorbed the entry
  [ "$(jq -r '.[] | select(.file == "alpha/.claude-plugin/plugin.json") | .description' <<< "$output")" = 'alpha/.claude-plugin/plugin.json carries version "1.0.1-rc1", which is not plain X.Y.Z semver.' ]
  [ "$(sed -n 1p "$BATS_TEST_TMPDIR/out.txt")" = 'carried entry "alpha: version is not plain X.Y.Z" (.claude-plugin/marketplace.json, manifest): re-raised (see finding)' ]
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/out.txt")" = 'carried entry "alpha: version is not plain X.Y.Z" (alpha/.claude-plugin/plugin.json, manifest): re-raised (see finding)' ]
  [ "$(sed -n 3p "$BATS_TEST_TMPDIR/out.txt")" = 'carried: confirmed 0 / re-raised 2 / unconfirmed 0 of 2' ]
  # two entries that prefer the same finding: the second takes the other one
  jq '.[0].file = "alpha/.claude-plugin/plugin.json"' "$BATS_TEST_TMPDIR/v.json" > "$BATS_TEST_TMPDIR/v2.json"
  run cm --round 2 --fix-verification "$BATS_TEST_TMPDIR/v2.json" --carry-out "$BATS_TEST_TMPDIR/out.txt"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].file] | join("|")' <<< "$output")" = 'alpha/.claude-plugin/plugin.json|alpha/.claude-plugin/plugin.json' ]
}

@test "carry: an entry of another dimension exits 2 and prints and writes nothing" {
  jq -n '[{file: "alpha/skills/demo/SKILL.md", line: 1, dimension: "contract", severity: "WARNING", title: "alpha: content changed with no version bump"}]' > "$BATS_TEST_TMPDIR/v.json"
  run --separate-stderr cm --round 2 --fix-verification "$BATS_TEST_TMPDIR/v.json" --carry-out "$BATS_TEST_TMPDIR/out.txt"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/out.txt" ]
  contains "$stderr" "not a manifest entry this script owns"
}

@test "carry: a manifest entry whose title matches no template exits 2" {
  jq -n '[{file: "alpha/.claude-plugin/plugin.json", line: 3, dimension: "manifest", severity: "WARNING", title: "alpha: bump undersells a new agent"}]' > "$BATS_TEST_TMPDIR/v.json"
  run cm --round 2 --fix-verification "$BATS_TEST_TMPDIR/v.json" --carry-out "$BATS_TEST_TMPDIR/out.txt"
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/out.txt" ]
}

@test "carry: an empty carry writes only the zero triple" {
  printf '[]' > "$BATS_TEST_TMPDIR/v.json"
  run cm --round 2 --fix-verification "$BATS_TEST_TMPDIR/v.json" --carry-out "$BATS_TEST_TMPDIR/out.txt"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/out.txt")" = "carried: confirmed 0 / re-raised 0 / unconfirmed 0 of 0" ]
}

@test "usage: a missing --base, a bad --round, an unresolvable base and a lone carry flag each exit 2" {
  run zsh "$CM" --repo "$R" --round 1
  [ "$status" -eq 2 ]
  run cm --round 0
  [ "$status" -eq 2 ]
  run cm --round x
  [ "$status" -eq 2 ]
  run zsh "$CM" --repo "$R" --base no-such-rev --round 1
  [ "$status" -eq 2 ]
  run cm --round 1 --fix-verification "$BATS_TEST_TMPDIR/v.json"
  [ "$status" -eq 2 ]
  run cm --round 1 --carry-out "$BATS_TEST_TMPDIR/out.txt"
  [ "$status" -eq 2 ]
}
