#!/usr/bin/env bats
#
# Behavioral tests for merge-driver-claude-plugin.zsh — the rebase-oriented
# manifest merge driver (#1821, epic #1820). Each test writes the three sides
# git would hand the driver (<O> base, <A> main's side, <B> the replayed PR
# commit) and checks the merged <A>, the exit code and, on a refusal, that <A>
# is byte-identical to what it was.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DRIVER="$REPO_ROOT/development/scripts/merge/merge-driver-claude-plugin.zsh"
  W="$BATS_TEST_TMPDIR/sides"
  mkdir -p "$W"
  unset MERGE_DRIVER_RECORD
  # A plugin.json shaped like the real ones, with a non-ASCII character and
  # nested values so byte preservation is exercised beyond flat strings.
  BASE_PLUGIN='{
  "name": "development",
  "description": "Generic workflows — base notes.",
  "version": "1.193.1",
  "author": {
    "name": "Timo Jakob"
  },
  "license": "MIT",
  "keywords": [
    "workflow",
    "review"
  ]
}'
  BASE_MARKET='{
  "name": "timos-claude-code-plugins",
  "description": "Marketplace description.",
  "owner": {
    "name": "Timo Jakob"
  },
  "plugins": [
    {
      "name": "development",
      "description": "Generic workflows — base notes.",
      "version": "1.193.1",
      "source": "./development",
      "category": "development"
    },
    {
      "name": "development-go",
      "description": "Go.",
      "version": "0.4.0",
      "source": "./development-go",
      "category": "development"
    }
  ]
}'
}

# side <name> <json> [jq filter] — write one side, 2-space formatted like the
# repo's manifests (jq round-trips them byte for byte).
side() {
  printf '%s\n' "$2" | jq "${3:-.}" > "$W/$1"
}

# drive <path> — run the driver the way git does: %O %A %B %P.
drive() {
  cp "$W/A" "$W/A.orig"
  run zsh "$DRIVER" "$W/O" "$W/A" "$W/B" "$1"
}

plugin_path=development/.claude-plugin/plugin.json
market_path=.claude-plugin/marketplace.json

a_unchanged() {
  cmp "$W/A" "$W/A.orig"
}

# ---- interface -------------------------------------------------------------

@test "--patterns prints exactly the manifest pattern and exits 0" {
  run zsh "$DRIVER" --patterns
  [ "$status" -eq 0 ]
  [ "$output" = '**/.claude-plugin/*.json' ]
}

@test "wrong argument count exits 2" {
  run zsh "$DRIVER"
  [ "$status" -eq 2 ]
  run zsh "$DRIVER" a b c
  [ "$status" -eq 2 ]
  run zsh "$DRIVER" a b c d e
  [ "$status" -eq 2 ]
  run zsh "$DRIVER" --patterns extra
  [ "$status" -eq 2 ]
  run zsh "$DRIVER" foo
  [ "$status" -eq 2 ]
}

@test "a path that is not a plugin manifest exits 1 and leaves <A> unchanged" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  drive x/.claude-plugin/other.json
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "invalid JSON on one side exits 1 and leaves <A> unchanged" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  printf '{ not json\n' > "$W/B"
  drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "a side holding two JSON documents exits 1 and leaves <A> unchanged" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  printf '{}\n' >> "$W/B"
  drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "jq missing from PATH exits 1 and leaves <A> unchanged" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  zsh_bin="$(command -v zsh)"
  mkdir "$BATS_TEST_TMPDIR/empty"
  cp "$W/A" "$W/A.orig"
  PATH="$BATS_TEST_TMPDIR/empty" run "$zsh_bin" "$DRIVER" "$W/O" "$W/A" "$W/B" "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "an uncreatable work directory exits 1 and leaves <A> unchanged" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  # macOS mktemp falls back from an unusable TMPDIR, so fail it with a stub.
  mkdir "$BATS_TEST_TMPDIR/stub"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/stub/mktemp"
  chmod +x "$BATS_TEST_TMPDIR/stub/mktemp"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "a result that cannot be rendered exits 1 and leaves <A> unchanged" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  mkdir "$BATS_TEST_TMPDIR/stub"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = .result ] && exit 1; done\nexec %s "$@"\n' "$(command -v jq)" \
    > "$BATS_TEST_TMPDIR/stub/jq"
  chmod +x "$BATS_TEST_TMPDIR/stub/jq"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "records that cannot be rendered exit 1, leave <A> unchanged and write no record" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  mkdir "$BATS_TEST_TMPDIR/stub"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = ".records[]" ] && exit 1; done\nexec "%s" "$@"\n' "$(command -v jq)" \
    > "$BATS_TEST_TMPDIR/stub/jq"
  chmod +x "$BATS_TEST_TMPDIR/stub/jq"
  export MERGE_DRIVER_RECORD="$BATS_TEST_TMPDIR/records.jsonl"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged
  [ ! -e "$MERGE_DRIVER_RECORD" ]
}

@test "a result that cannot be moved into <A> exits 1 and leaves <A> unchanged" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  mkdir "$BATS_TEST_TMPDIR/stub"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/stub/mv"
  chmod +x "$BATS_TEST_TMPDIR/stub/mv"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "a result that cannot be staged beside <A> exits 1 and leaves <A> unchanged" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  cp "$W/A" "$W/A.orig"
  chmod 555 "$W"
  run zsh "$DRIVER" "$W/O" "$W/A" "$W/B" "$plugin_path"
  chmod 755 "$W"
  [ "$status" -eq 1 ]
  a_unchanged
}

# ---- rule 1: version -------------------------------------------------------

@test "both bumped version: a patch PR lands one patch above main" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$W/A")" = 1.194.1 ]
}

@test "both bumped version to the same minor: the replayed PR becomes the next minor" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.194.0"'
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$W/A")" = 1.195.0 ]
}

@test "both bumped version: a minor PR resets main's non-zero patch" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.3"'
  side B "$BASE_PLUGIN" '.version="1.194.0"'
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$W/A")" = 1.195.0 ]
}

@test "both bumped version: a major PR resets minor and patch above main" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="2.0.0"'
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$W/A")" = 2.0.0 ]
}

@test "both bumped version: a major PR bumps main's major, not the PR's value" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="2.1.0"'
  side B "$BASE_PLUGIN" '.version="2.0.0"'
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$W/A")" = 3.0.0 ]
}

@test "only main changed version: main's value is kept" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.keywords += ["merge"]'
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$W/A")" = 1.194.0 ]
}

@test "only the PR changed version: the PR's value is taken" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.license="Apache-2.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$W/A")" = 1.193.2 ]
  [ "$(jq -r .license "$W/A")" = Apache-2.0 ]
}

@test "a non-MAJOR.MINOR.PATCH version where both changed exits 1 and leaves <A> unchanged" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged

  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2-rc.1"'
  drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged

  # A fourth component is refused too, not truncated: it pins the regex's $
  # anchor, which the cases above pass without (#1885).
  side B "$BASE_PLUGIN" '.version="1.193.2.1"'
  drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "a PR version that is not a bump of the base exits 1 and leaves <A> unchanged" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.0"'
  drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged

  side B "$BASE_PLUGIN" '.version="1.192.5"'
  drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged

  side B "$BASE_PLUGIN" '.version="0.194.0"'
  drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

# ---- rule 2: description ---------------------------------------------------

@test "both appended to description: main's text plus the PR's suffix" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.description += " Main note."'
  side B "$BASE_PLUGIN" '.description += " PR note."'
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ "$(jq -r .description "$W/A")" = "Generic workflows — base notes. Main note. PR note." ]
}

@test "the PR rewrote text inside the base description: exits 1 and leaves <A> unchanged" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.description += " Main note."'
  side B "$BASE_PLUGIN" '.description = "Generic workflows — edited notes. PR note."'
  drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "only one side changed description: that side is taken" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.description = "Rewritten entirely."'
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ "$(jq -r .description "$W/A")" = "Rewritten entirely." ]
}

# ---- rule 3: every other key -----------------------------------------------

@test "another key changed differently on both sides exits 1 and leaves <A> unchanged" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.license="Apache-2.0"'
  side B "$BASE_PLUGIN" '.license="GPL-3.0"'
  drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "another key changed the same way on both sides exits 0 with that value" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.license="Apache-2.0" | .version="1.194.0"'
  side B "$BASE_PLUGIN" '.license="Apache-2.0" | .version="1.193.2"'
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ "$(jq -r .license "$W/A")" = Apache-2.0 ]
  [ "$(jq -r .version "$W/A")" = 1.194.1 ]
}

@test "a key removed on one side and edited on the other exits 1 and leaves <A> unchanged" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" 'del(.license)'
  side B "$BASE_PLUGIN" '.license="GPL-3.0"'
  drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "keys new on the PR side are appended after main's keys, in the PR's order" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2" | .homepage="https://h" | .repository="https://r"'
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ "$(jq -c 'keys_unsorted' "$W/A")" = '["name","description","version","author","license","keywords","homepage","repository"]' ]
}

@test "keys reordered on the PR side keep main's order" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2" | to_entries | reverse | from_entries'
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ "$(jq -c 'keys_unsorted' "$W/A")" = "$(jq -c 'keys_unsorted' "$W/A.orig")" ]
}

@test "a key removed on one side only stays removed" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2" | del(.keywords)'
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ "$(jq 'has("keywords")' "$W/A")" = false ]
}

# ---- marketplace.json ------------------------------------------------------

@test "marketplace: entries are matched by name and resolved per entry" {
  side O "$BASE_MARKET"
  side A "$BASE_MARKET" '.plugins[0].version="1.194.0" | .plugins[1].version="0.5.0"'
  side B "$BASE_MARKET" '.plugins[0].version="1.193.2" | .plugins[0].description += " PR note."'
  drive "$market_path"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.plugins[0].version' "$W/A")" = 1.194.1 ]
  [ "$(jq -r '.plugins[0].description' "$W/A")" = "Generic workflows — base notes. PR note." ]
  [ "$(jq -r '.plugins[1].version' "$W/A")" = 0.5.0 ]
}

@test "marketplace: entries reordered on the PR side are still matched by name" {
  side O "$BASE_MARKET"
  side A "$BASE_MARKET" '.plugins[0].version="1.194.0"'
  side B "$BASE_MARKET" '.plugins[0].version="1.193.2" | .plugins |= reverse'
  drive "$market_path"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.plugins[0].name' "$W/A")" = development ]
  [ "$(jq -r '.plugins[0].version' "$W/A")" = 1.194.1 ]
}

@test "marketplace: an entry added on the PR side is appended; one removed on main stays removed" {
  side O "$BASE_MARKET"
  side A "$BASE_MARKET" 'del(.plugins[1]) | .plugins[0].version="1.194.0"'
  side B "$BASE_MARKET" '.plugins += [{"name":"development-new","version":"0.1.0"},{"name":"development-newer","version":"0.2.0"}] | .plugins[0].version="1.193.2"'
  drive "$market_path"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.plugins[].name]' "$W/A")" = '["development","development-new","development-newer"]' ]
  [ "$(jq -c '.plugins[2]' "$W/A")" = '{"name":"development-newer","version":"0.2.0"}' ]
  [ "$(jq -r '.plugins[0].version' "$W/A")" = 1.194.1 ]
}

@test "marketplace: an entry removed on one side and edited on the other exits 1" {
  side O "$BASE_MARKET"
  side A "$BASE_MARKET" 'del(.plugins[1])'
  side B "$BASE_MARKET" '.plugins[1].version="0.4.1"'
  drive "$market_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "marketplace: another entry key changed differently on both sides exits 1" {
  side O "$BASE_MARKET"
  side A "$BASE_MARKET" '.plugins[0].category="a"'
  side B "$BASE_MARKET" '.plugins[0].category="b"'
  drive "$market_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "marketplace: the top-level description takes rule 3, not the append rule" {
  side O "$BASE_MARKET"
  side A "$BASE_MARKET" '.description += " Main."'
  side B "$BASE_MARKET" '.description += " PR."'
  drive "$market_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "marketplace: duplicate entry names are refused" {
  side O "$BASE_MARKET"
  side A "$BASE_MARKET" '.plugins[0].version="1.194.0"'
  side B "$BASE_MARKET" '.plugins[1].name="development"'
  drive "$market_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "marketplace: an entry without a name is refused" {
  side O "$BASE_MARKET"
  side A "$BASE_MARKET" '.plugins[0].version="1.194.0"'
  side B "$BASE_MARKET" '.plugins += [{"version":"0.1.0"}]'
  drive "$market_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "plugin.json and the matching marketplace entry resolve to the same version" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  plugin_version="$(jq -r .version "$W/A")"

  side O "$BASE_MARKET"
  side A "$BASE_MARKET" '.plugins[0].version="1.194.0"'
  side B "$BASE_MARKET" '.plugins[0].version="1.193.2"'
  drive "$market_path"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.plugins[0].version' "$W/A")" = "$plugin_version" ]
  [ "$plugin_version" = 1.194.1 ]
}

# ---- formatting ------------------------------------------------------------

@test "a resolved plugin.json differs from <A> only in the resolved values" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0" | .description += " Main note."'
  side B "$BASE_PLUGIN" '.version="1.193.2" | .description += " PR note."'
  # The expectation is edited from <A>'s BYTES, not re-rendered by jq.
  sed -e 's/"version": "1.194.0"/"version": "1.194.1"/' \
      -e 's/Main note\."/Main note. PR note."/' "$W/A" > "$W/expected"
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  cmp "$W/A" "$W/expected"
}

@test "the real repo marketplace.json is preserved byte for byte outside the resolved version" {
  real="$REPO_ROOT/.claude-plugin/marketplace.json"
  v="$(jq -r '.plugins[] | select(.name=="development") | .version' "$real")"
  IFS=. read -r major minor patch <<< "$v"
  cp "$real" "$W/O"
  jq --arg v "$major.$((minor + 1)).0" '(.plugins[] | select(.name=="development") | .version) = $v' "$real" > "$W/A"
  jq --arg v "$major.$minor.$((patch + 1))" '(.plugins[] | select(.name=="development") | .version) = $v' "$real" > "$W/B"
  sed -e "s/\"version\": \"$major.$((minor + 1)).0\"/\"version\": \"$major.$((minor + 1)).1\"/" "$W/A" > "$W/expected"
  # The edit must be unique, or the byte comparison proves less than it claims.
  [ "$(cmp -l "$W/A" "$W/expected" | wc -l)" -ge 1 ]
  [ "$(grep -c "\"version\": \"$major.$((minor + 1)).1\"" "$W/expected")" -eq 1 ]
  drive "$market_path"
  [ "$status" -eq 0 ]
  cmp "$W/A" "$W/expected"
}

# ---- verdict record ----------------------------------------------------------

@test "MERGE_DRIVER_RECORD: one line per both-sides-resolved field, with the six keys" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0" | .description += " Main note."'
  side B "$BASE_PLUGIN" '.version="1.193.2" | .description += " PR note." | .license="Apache-2.0"'
  export MERGE_DRIVER_RECORD="$BATS_TEST_TMPDIR/records.jsonl"
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MERGE_DRIVER_RECORD")" -eq 2 ]
  run jq -s -c '[.[] | keys_unsorted] | unique' "$MERGE_DRIVER_RECORD"
  [ "$output" = '[["path","plugin","field","main","pr","result"]]' ]
  run jq -c 'select(.field=="version")' "$MERGE_DRIVER_RECORD"
  [ "$output" = '{"path":"development/.claude-plugin/plugin.json","plugin":"development","field":"version","main":"1.194.0","pr":"1.193.2","result":"1.194.1"}' ]
  run jq -r 'select(.field=="description") | .result' "$MERGE_DRIVER_RECORD"
  [ "$output" = "Generic workflows — base notes. Main note. PR note." ]
}

@test "MERGE_DRIVER_RECORD: marketplace records name the entry's plugin and append" {
  side O "$BASE_MARKET"
  side A "$BASE_MARKET" '.plugins[1].version="0.5.0"'
  side B "$BASE_MARKET" '.plugins[1].version="0.4.1"'
  export MERGE_DRIVER_RECORD="$BATS_TEST_TMPDIR/records.jsonl"
  printf '{"earlier":true}\n' > "$MERGE_DRIVER_RECORD"
  drive "$market_path"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MERGE_DRIVER_RECORD")" -eq 2 ]
  run jq -c 'select(.field=="version") | [.path, .plugin, .main, .pr, .result]' "$MERGE_DRIVER_RECORD"
  [ "$output" = '[".claude-plugin/marketplace.json","development-go","0.5.0","0.4.1","0.5.1"]' ]
}

@test "MERGE_DRIVER_RECORD: one-side takes are not recorded" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.description += " Main note."'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  export MERGE_DRIVER_RECORD="$BATS_TEST_TMPDIR/records.jsonl"
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ ! -e "$MERGE_DRIVER_RECORD" ]
}

@test "MERGE_DRIVER_RECORD unset: no file is written" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  before="$(cd "$BATS_TEST_TMPDIR" && find . | sort)"
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  after="$(cd "$BATS_TEST_TMPDIR" && find . | sort)"
  # Only the A.orig copy drive() itself made may be new.
  [ "$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))" = ./sides/A.orig ]
}

@test "MERGE_DRIVER_RECORD set but empty: the merge resolves and nothing is written" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  export MERGE_DRIVER_RECORD=""
  before="$(cd "$BATS_TEST_TMPDIR" && find . | sort)"
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$W/A")" = 1.194.1 ]
  after="$(cd "$BATS_TEST_TMPDIR" && find . | sort)"
  [ "$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))" = ./sides/A.orig ]
}

@test "a refused merge writes no record" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0" | .license="Apache-2.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2" | .license="GPL-3.0"'
  export MERGE_DRIVER_RECORD="$BATS_TEST_TMPDIR/records.jsonl"
  drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged
  [ ! -e "$MERGE_DRIVER_RECORD" ]
}

@test "an unwritable MERGE_DRIVER_RECORD exits 1 and restores <A>" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  export MERGE_DRIVER_RECORD="$BATS_TEST_TMPDIR/no-such-dir/records.jsonl"
  drive "$plugin_path"
  [ "$status" -eq 1 ]
  a_unchanged
}

@test "no temporary files are left beside <A>" {
  side O "$BASE_PLUGIN"
  side A "$BASE_PLUGIN" '.version="1.194.0"'
  side B "$BASE_PLUGIN" '.version="1.193.2"'
  drive "$plugin_path"
  [ "$status" -eq 0 ]
  [ -z "$(find "$W" -name '.merge-driver-*')" ]
}
