#!/usr/bin/env bats
#
# The size pre-flight's contract (#1437), beyond the six threshold straddles in
# size-preflight.bats:
#   - size-preflight.zsh's exit taxonomy — 0 pass / 1 stop with a verdict on
#     stdout, 2 usage / 3 runtime with NOTHING on stdout (a caller that only
#     checks "did it print a verdict" must never read an error as a pass);
#   - ownership: marketplace plugins, plugins the change creates, unowned
#     repo-root artifacts, the primary-plugin tie, the all-unowned case, and a
#     repo with no marketplace manifest at all;
#   - the #1435 corner: a modest-looking story that trips two triggers;
#   - build-story-preflight-telemetry-record.zsh's payload and outcome mapping,
#     and real story-preflight records through the shared emitter and validator;
#   - the SKILL.md wiring the story's acceptance criteria name.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/resolve-issue/scripts"
  S="$SCRIPTS/size-preflight.zsh"
  B="$SCRIPTS/build-story-preflight-telemetry-record.zsh"
  EMIT="$REPO_ROOT/development/scripts/telemetry/emit-telemetry.zsh"
  VALIDATE="$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh"
  SKILL="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  MANIFEST="$REPO_ROOT/.claude-plugin/marketplace.json"
  INV="$BATS_TEST_TMPDIR/inventory.json"
  V="$BATS_TEST_TMPDIR/verdict.json"
  ZSH="$(command -v zsh)"
  # A PATH holding nothing at all: zsh is invoked by absolute path and needs no
  # external command before the jq probe, so this hides the host's jq (which on
  # macOS lives in /usr/bin) without stubbing anything.
  NOJQ="$BATS_TEST_TMPDIR/empty-bin"
  mkdir -p "$NOJQ"
}

inventory() {
  printf '%s\n' "$@" | jq -R . | jq -s '{files: .}' > "$INV"
}

preflight() {
  run --separate-stderr zsh "$S" --file "$INV" --manifest "$MANIFEST"
}

# Run the pre-flight exactly as SKILL.md does: from a directory, with no
# --manifest, so the cwd default is what is exercised.
preflight_in() {
  run --separate-stderr zsh -c 'cd "$1" && zsh "$2" --file "$3"' _ "$1" "$S" "$INV"
}

# Run a command with a TERMINAL on stdin, via script(1) — BSD and GNU spell it
# differently. The pty merges the command's streams into $output. A regressed
# guard would block on the terminal forever, so perl's alarm bounds the run: a
# hang comes back as a signal status, which is a red, never a stalled suite.
under_tty() {
  command -v script >/dev/null 2>&1 || skip "script(1) is not installed"
  local cmd
  printf -v cmd '%q ' "$@"
  if [ "$(uname)" = Darwin ]; then
    run perl -e 'alarm 30; exec @ARGV' script -q /dev/null zsh -c "$cmd"
  else
    run perl -e 'alarm 30; exec @ARGV' script -qec "$cmd" /dev/null
  fi
}

# Assert the run printed nothing on stdout (bats' $output under --separate-stderr).
no_stdout() {
  [ -z "$output" ] || { printf 'expected no stdout, got: %s\n' "$output" >&2; return 1; }
}

# The §2 pre-flight block of the conductor, from its bold lead-in to the next
# bold section (Sibling-sweep), so a needle cannot be satisfied elsewhere.
preflight_block() {
  awk '/^\*\*Size pre-flight — split before building/{f=1} f&&/^\*\*Sibling-sweep/{exit} f' "$SKILL"
}

# The E3 paragraph on a size-stopped child.
e3_paragraph() {
  awk '/^So does a child whose \*\*size pre-flight stops it\*\*/{f=1} f&&/^$/{exit} f' "$SKILL"
}

# --- exit taxonomy: usage (2) -------------------------------------------------

@test "an unknown flag is a usage error (exit 2) with nothing on stdout" {
  inventory development/SKILL.md
  run --separate-stderr zsh "$S" --file "$INV" --manifest "$MANIFEST" --bogus
  [ "$status" -eq 2 ]
  no_stdout
  contains "$stderr" "unknown arg: --bogus"
}

@test "a dangling --file is a usage error (exit 2)" {
  run --separate-stderr zsh "$S" --file
  [ "$status" -eq 2 ]
  no_stdout
  contains "$stderr" "--file needs a value"
}

@test "a dangling --manifest is a usage error (exit 2)" {
  inventory development/SKILL.md
  run --separate-stderr zsh "$S" --file "$INV" --manifest
  [ "$status" -eq 2 ]
  no_stdout
  contains "$stderr" "--manifest needs a value"
}

@test "no --file with a terminal on stdin is a usage error (exit 2), not a hang" {
  under_tty zsh "$S" --manifest "$MANIFEST"
  [ "$status" -eq 2 ]
  contains "$output" "no --file and stdin is a terminal"
}

@test "a missing inventory file is a usage error (exit 2) with nothing on stdout" {
  run --separate-stderr zsh "$S" --file "$BATS_TEST_TMPDIR/absent.json" --manifest "$MANIFEST"
  [ "$status" -eq 2 ]
  no_stdout
  contains "$stderr" "inventory not found or unreadable"
}

@test "an unreadable inventory is a usage error (exit 2), never a stop" {
  [ "$(id -u)" -ne 0 ] || skip "root reads a mode-000 file"
  inventory development/SKILL.md
  chmod 000 "$INV"
  run --separate-stderr zsh "$S" --file "$INV" --manifest "$MANIFEST"
  chmod 600 "$INV"
  [ "$status" -eq 2 ]
  no_stdout
  contains "$stderr" "inventory not found or unreadable"
}

@test "an explicit --manifest that is missing is a usage error (exit 2)" {
  inventory development/SKILL.md
  run --separate-stderr zsh "$S" --file "$INV" --manifest "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 2 ]
  no_stdout
  contains "$stderr" "marketplace manifest not found or unreadable"
}

@test "a default manifest that exists but cannot be read is a usage error (exit 2)" {
  [ "$(id -u)" -ne 0 ] || skip "root reads a mode-000 file"
  local repo="$BATS_TEST_TMPDIR/locked-repo"
  mkdir -p "$repo/.claude-plugin"
  cp "$MANIFEST" "$repo/.claude-plugin/marketplace.json"
  chmod 000 "$repo/.claude-plugin/marketplace.json"
  inventory development/SKILL.md
  preflight_in "$repo"
  chmod 600 "$repo/.claude-plugin/marketplace.json"
  [ "$status" -eq 2 ]
  no_stdout
  contains "$stderr" "marketplace manifest unreadable"
}

@test "-h prints its usage on stderr, nothing on stdout, and exits 0" {
  run --separate-stderr zsh "$S" -h
  [ "$status" -eq 0 ]
  no_stdout
  contains "$stderr" "usage: size-preflight.zsh"
}

# --- exit taxonomy: runtime (3) -----------------------------------------------

@test "malformed JSON is a runtime error (exit 3) with nothing on stdout" {
  printf '{"files": [' > "$INV"
  preflight
  [ "$status" -eq 3 ]
  no_stdout
  contains "$stderr" "not exactly one valid JSON document"
}

@test "an empty inventory is refused (exit 3), never read as a verdict" {
  : > "$INV"
  preflight
  [ "$status" -eq 3 ]
  no_stdout
  contains "$stderr" "not exactly one valid JSON document"
}

@test "an inventory of two JSON documents is refused (exit 3), not judged as its last" {
  printf '{"files":["development/a"]}\n{"files":["development/b"]}\n' > "$INV"
  preflight
  [ "$status" -eq 3 ]
  no_stdout
  contains "$stderr" "not exactly one valid JSON document"
}

@test "each malformed inventory shape is exit 3, named, with nothing on stdout" {
  local -a bodies=('[]' '{"files":"development/SKILL.md"}' '{"files":[]}' '{"files":[""]}' '{"files":[1]}' '{"files":["./"]}'
    '{"files":["/Users/someone/repo/development/SKILL.md"]}' '{"files":["development/../development-go/x"]}'
    '{"files":["development/a"],"plugins":"development"}')
  local -a names=('not a JSON object' 'files must be an array' 'at least one path' 'non-empty string' 'non-empty string'
    'not only . or /'
    'repo-relative' 'must not contain a .. segment' 'plugins, when present, must be an array')
  local i
  for i in "${!bodies[@]}"; do
    printf '%s' "${bodies[$i]}" > "$INV"
    preflight
    [ "$status" -eq 3 ] || { printf 'body %s exited %s\n' "${bodies[$i]}" "$status" >&2; return 1; }
    no_stdout
    contains "$stderr" "${names[$i]}"
  done
}

@test "declared plugins that disagree with the derived set are a malformed inventory (exit 3)" {
  printf '{"files":["development/SKILL.md","development-go/x.md"],"plugins":["development"]}' > "$INV"
  preflight
  [ "$status" -eq 3 ]
  no_stdout
  contains "$stderr" "disagree"
}

@test "a manifest that is not JSON, or lists no local plugins, is exit 3" {
  inventory development/SKILL.md
  printf 'not json' > "$BATS_TEST_TMPDIR/m1.json"
  run --separate-stderr zsh "$S" --file "$INV" --manifest "$BATS_TEST_TMPDIR/m1.json"
  [ "$status" -eq 3 ]
  no_stdout
  contains "$stderr" "not valid JSON"
  printf '{"plugins":[]}' > "$BATS_TEST_TMPDIR/m2.json"
  run --separate-stderr zsh "$S" --file "$INV" --manifest "$BATS_TEST_TMPDIR/m2.json"
  [ "$status" -eq 3 ]
  no_stdout
  contains "$stderr" "lists no local plugins"
}

@test "a manifest entry whose source is not a local path is skipped, not an error" {
  printf '{"plugins":[{"name":"remote","source":{"source":"github","repo":"o/r"}},{"name":"development","source":"./development"}]}' \
    > "$BATS_TEST_TMPDIR/m3.json"
  inventory development/a.md
  run --separate-stderr zsh "$S" --file "$INV" --manifest "$BATS_TEST_TMPDIR/m3.json"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.primary_plugin == "development" and .unowned == 0' >/dev/null
}

@test "a missing jq is a runtime error (exit 3) with nothing on stdout, never a pass" {
  inventory development/SKILL.md
  run --separate-stderr env PATH="$NOJQ" "$ZSH" "$S" --file "$INV" --manifest "$MANIFEST"
  [ "$status" -eq 3 ]
  no_stdout
  contains "$stderr" "jq not found"
}

# --- inputs -----------------------------------------------------------------------

@test "declared plugins that match the derived set are accepted, and ./ paths stay owned" {
  printf '{"files":["development/SKILL.md","./development/b.zsh"],"plugins":["development"]}' > "$INV"
  preflight
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.files == 2 and .plugins == 1 and .unowned == 0
    and .primary_plugin == "development"' >/dev/null
}

@test "declared plugins are compared as a set: order and duplicates do not matter" {
  printf '{"files":["development/a.md","development-go/b.md"],"plugins":["development-go","development","development"]}' > "$INV"
  preflight
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  printf '%s' "$output" | jq -e '.triggers == ["plugin"]' >/dev/null
}

@test "spellings of one path count as one distinct file" {
  inventory development/a.md ./development/a.md development//a.md development/./a.md .//development/a.md
  preflight
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.files == 1' >/dev/null
}

@test "the inventory is read from stdin when --file is absent" {
  run --separate-stderr zsh -c 'printf "%s" "$1" | zsh "$2" --manifest "$3"' _ \
    '{"files":["development/SKILL.md"]}' "$S" "$MANIFEST"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.verdict == "pass" and .primary_plugin == "development"' >/dev/null
}

@test "with no --manifest the cwd's .claude-plugin/marketplace.json is used, as SKILL.md runs it" {
  inventory development/a.md development-go/b.md
  preflight_in "$REPO_ROOT"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.plugins == 2 and .triggers == ["plugin"]' >/dev/null
}

@test "a repo with no marketplace manifest owns nothing: only the file count can stop it" {
  local app="$BATS_TEST_TMPDIR/app-repo"
  mkdir -p "$app"
  inventory src/app/main.py src/app/api.py tests/test_api.py \
    development/skills/bootstrap/templates/x.tmpl development-go/y.md
  preflight_in "$app"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.verdict == "pass" and .plugins == 0 and .unowned == 5
    and .primary_plugin == null' >/dev/null
  local -a paths=() i
  for (( i = 1; i <= 21; i++ )); do paths+=("src/app/m$i.py"); done
  inventory "${paths[@]}"
  preflight_in "$app"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.triggers == ["files"]' >/dev/null
}

# --- ownership ----------------------------------------------------------------------

@test "an all-unowned inventory has primary_plugin null and no plugin trigger" {
  inventory ARCHITECTURE.md MAINTAINING.md docs/index.md tests/x.bats .github/workflows/ci.yml
  preflight
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.primary_plugin == null and .plugins == 0 and .unowned == 5 and .triggers == []' >/dev/null
}

@test "unowned files count toward the file total but not toward the plugin rule" {
  local -a paths=(development/SKILL.md)
  local i
  for (( i = 1; i <= 20; i++ )); do paths+=("docs/page-$i.md"); done
  inventory "${paths[@]}"
  preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.files == 21 and .unowned == 20 and .plugins == 1 and .triggers == ["files"]' >/dev/null
}

@test "an even owned-file split between two plugins is a tie: plugin stops, primary null" {
  inventory development/a.md development/b.md development-go/c.md development-go/d.md
  preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.primary_plugin == null and .triggers == ["plugin"]' >/dev/null
}

@test "a plugin this change creates is owned — its files trip the plugin rule" {
  inventory development/skills/bootstrap/SKILL.md \
    development-newplugin/.claude-plugin/plugin.json development-newplugin/skills/x/SKILL.md
  preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.plugins == 2 and .unowned == 0 and .triggers == ["plugin"]' >/dev/null
}

@test "a directory with no marketplace entry and no created manifest is unowned" {
  inventory development/skills/bootstrap/SKILL.md development-newplugin/skills/x/SKILL.md
  preflight
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.plugins == 1 and .unowned == 1' >/dev/null
}

@test "an unowned file beside a bootstrap template does not straddle" {
  inventory development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl \
    docs/how-to/bootstrap.md
  preflight
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.triggers == []' >/dev/null
}

@test "only the templates' own plugin manifest is excepted: another plugin's still straddles" {
  inventory development/skills/bootstrap/templates/a.tmpl development-go/.claude-plugin/plugin.json
  preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.triggers == ["plugin", "bootstrap-straddle"]' >/dev/null
}

@test "a directory spelling of the templates cannot dodge the straddle check" {
  local dir
  for dir in development/skills/bootstrap/templates/ development/skills/bootstrap/templates; do
    inventory "$dir" development/skills/resolve-issue/SKILL.md
    preflight
    [ "$status" -eq 1 ] || { printf '%s exited %s\n' "$dir" "$status" >&2; return 1; }
    printf '%s' "$output" | jq -e '.triggers == ["bootstrap-straddle"]' >/dev/null
  done
}

@test "the bootstrap skill's own directory beside a template is not a straddle" {
  inventory development/skills/bootstrap development/skills/bootstrap/templates/a.tmpl
  preflight
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.triggers == []' >/dev/null
}

@test "a sibling whose name only starts like the bootstrap skill is outside it" {
  inventory development/skills/bootstrap-extra/x.md development/skills/bootstrap/templates/a.tmpl
  preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.triggers == ["bootstrap-straddle"]' >/dev/null
}

@test "a sibling whose name only starts like the templates directory is not a template" {
  inventory development/skills/bootstrap/templates-old/x.md development/scripts/y.zsh
  preflight
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.triggers == []' >/dev/null
}

@test "the park and clear commands are separate blocks: the park never removes its own label" {
  local block park clear
  block="$(preflight_block)"
  park="$(printf '%s\n' "$block" | awk '/^# park block/{f=1; next} /^# clear block/{exit} f')"
  clear="$(printf '%s\n' "$block" | awk '/^# clear block/{f=1; next} f && /^```/{exit} f')"
  contains "$park" '--add-label needs-split'
  lacks "$park" '--remove-label'
  contains "$clear" 'gh issue edit <N> --remove-label needs-split 2>/dev/null || true'
  lacks "$clear" '--add-label'
}

@test "a bare plugin directory is owned by that plugin" {
  inventory development/ development-go/x.md
  preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.plugins == 2 and .unowned == 0 and .triggers == ["plugin"]' >/dev/null
}

@test "a . segment cannot hide a bootstrap template from the straddle check" {
  inventory development/./skills/bootstrap/templates/a.tmpl development/scripts/x.zsh
  preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.triggers == ["bootstrap-straddle"]' >/dev/null
}

@test "the #1435 shape: 27 development files straddling templates and resolve-issue stop on files + straddle, not plugin" {
  local -a paths=(development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl)
  local i
  for (( i = 1; i <= 26; i++ )); do
    paths+=("$(printf 'development/skills/resolve-issue/scripts/s%02d.zsh' "$i")")
  done
  inventory "${paths[@]}"
  preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.verdict == "stop" and .files == 27 and .plugins == 1
    and .triggers == ["files", "bootstrap-straddle"]' >/dev/null
}

# --- the telemetry record -------------------------------------------------------------

@test "a pass builds a pass payload with override_by null and outcome success" {
  printf '{"verdict":"pass","triggers":[],"files":3,"plugins":1,"primary_plugin":"development","unowned":1}' > "$V"
  run --separate-stderr zsh "$B" --state "$V"
  [ "$status" -eq 0 ]
  [ "$output" = '{"verdict":"pass","triggers":[],"files":3,"plugins":1,"override_by":null}' ]
  run --separate-stderr zsh "$B" --state "$V" --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = success ]
}

@test "a stop builds a stop payload with outcome parked" {
  printf '{"verdict":"stop","triggers":["files"],"files":21,"plugins":1}' > "$V"
  run --separate-stderr zsh "$B" --state "$V"
  [ "$status" -eq 0 ]
  [ "$output" = '{"verdict":"stop","triggers":["files"],"files":21,"plugins":1,"override_by":null}' ]
  run --separate-stderr zsh "$B" --state "$V" --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = parked ]
}

@test "a bootstrap-straddle stop builds its payload with outcome parked" {
  printf '{"verdict":"stop","triggers":["files","bootstrap-straddle"],"files":27,"plugins":1}' > "$V"
  run --separate-stderr zsh "$B" --state "$V"
  [ "$status" -eq 0 ]
  [ "$output" = '{"verdict":"stop","triggers":["files","bootstrap-straddle"],"files":27,"plugins":1,"override_by":null}' ]
  run --separate-stderr zsh "$B" --state "$V" --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = parked ]
}

@test "an override of a stop is recorded as overridden by the human, outcome success" {
  printf '{"verdict":"stop","triggers":["plugin"],"files":4,"plugins":2}' > "$V"
  run --separate-stderr zsh "$B" --state "$V" --override human
  [ "$status" -eq 0 ]
  [ "$output" = '{"verdict":"overridden","triggers":["plugin"],"files":4,"plugins":2,"override_by":"human"}' ]
  run --separate-stderr zsh "$B" --state "$V" --override human --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = success ]
}

@test "the builder reads its state from stdin, by default and as --state -" {
  local stop='{"verdict":"stop","triggers":["files"],"files":21,"plugins":1}'
  local want='{"verdict":"stop","triggers":["files"],"files":21,"plugins":1,"override_by":null}'
  run --separate-stderr zsh -c 'printf "%s" "$1" | zsh "$2"' _ "$stop" "$B"
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
  run --separate-stderr zsh -c 'printf "%s" "$1" | zsh "$2" --state -' _ "$stop" "$B"
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

@test "a pass is never written as an override (exit 1)" {
  printf '{"verdict":"pass","triggers":[],"files":3,"plugins":1}' > "$V"
  run --separate-stderr zsh "$B" --state "$V" --override human
  [ "$status" -eq 1 ]
  no_stdout
  contains "$stderr" "a pass is never an override"
}

@test "the builder's usage errors are exit 2 with nothing on stdout" {
  printf '{"verdict":"stop","triggers":["files"],"files":21,"plugins":1}' > "$V"
  run --separate-stderr zsh "$B" --state "$V" --override timeout
  [ "$status" -eq 2 ]
  no_stdout
  run --separate-stderr zsh "$B" --state "$V" --bogus
  [ "$status" -eq 2 ]
  no_stdout
  contains "$stderr" "unknown arg: --bogus"
  run --separate-stderr zsh "$B" --state
  [ "$status" -eq 2 ]
  no_stdout
  run --separate-stderr zsh "$B" --state "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 2 ]
  no_stdout
  contains "$stderr" "state file missing or unreadable"
}

@test "an unreadable state is a usage error for the builder (exit 2)" {
  [ "$(id -u)" -ne 0 ] || skip "root reads a mode-000 file"
  printf '{"verdict":"stop","triggers":["files"],"files":21,"plugins":1}' > "$V"
  chmod 000 "$V"
  run --separate-stderr zsh "$B" --state "$V"
  chmod 600 "$V"
  [ "$status" -eq 2 ]
  no_stdout
  contains "$stderr" "state file missing or unreadable"
}

@test "the builder with no --state and a terminal on stdin is a usage error (exit 2)" {
  under_tty zsh "$B"
  [ "$status" -eq 2 ]
  contains "$output" "no --state and stdin is a terminal"
}

@test "a state that is not a verdict, or contradicts its triggers, cannot become a payload (exit 1)" {
  local -a states=('{"verdict":"overridden","triggers":[],"files":1,"plugins":1}'
    '{"verdict":"stop","files":21,"plugins":1}' '{"verdict":"stop","triggers":["files"],"files":"21","plugins":1}'
    '{"verdict":"stop","triggers":["files"],"files":21}' 'not json' '[]'
    '{"verdict":"stop","triggers":[],"files":21,"plugins":1}' '{"verdict":"pass","triggers":["files"],"files":21,"plugins":1}'
    '' '{"verdict":"pass","triggers":[],"files":1,"plugins":1} {"verdict":"pass","triggers":[],"files":1,"plugins":1}'
    '{"verdict":"stop","triggers":["size"],"files":21,"plugins":1}' '{"verdict":"stop","triggers":["files"],"files":-2,"plugins":1}'
    '{"verdict":"stop","triggers":["files"],"files":21.5,"plugins":1}'
    '{"verdict":"stop","triggers":["files"],"files":21,"plugins":-1}'
    '{"verdict":"stop","triggers":["files"],"files":21,"plugins":1.5}')
  local s
  for s in "${states[@]}"; do
    printf '%s' "$s" > "$V"
    run --separate-stderr zsh "$B" --state "$V"
    [ "$status" -eq 1 ] || { printf 'state %s exited %s\n' "$s" "$status" >&2; return 1; }
    no_stdout
    run --separate-stderr zsh "$B" --state "$V" --print-outcome
    [ "$status" -eq 1 ] || { printf 'state %s --print-outcome exited %s\n' "$s" "$status" >&2; return 1; }
    no_stdout
  done
}

@test "a missing jq fails the builder (exit 1) with nothing on stdout" {
  printf '{"verdict":"stop","triggers":["files"],"files":21,"plugins":1}' > "$V"
  run --separate-stderr env PATH="$NOJQ" "$ZSH" "$B" --state "$V"
  [ "$status" -eq 1 ]
  no_stdout
  contains "$stderr" "jq not found"
}

@test "pass, stop and overridden verdicts each emit a valid story-preflight run record" {
  local sink="$BATS_TEST_TMPDIR/t.jsonl" case_ inv_files override want_outcome want_verdict
  for case_ in pass stop overridden; do
    case "$case_" in
      pass) inventory development/a.md development/c.md; override=""; want_outcome=success ;;
      stop) inventory development/a.md development-go/b.md development/c.md; override=""; want_outcome=parked ;;
      overridden) inventory development/a.md development-go/b.md development/c.md; override=human; want_outcome=success ;;
    esac
    zsh "$S" --file "$INV" --manifest "$MANIFEST" > "$V" || true
    zsh "$B" --state "$V" ${override:+--override "$override"} > "$BATS_TEST_TMPDIR/p.json"
    local outcome
    outcome="$(zsh "$B" --state "$V" ${override:+--override "$override"} --print-outcome)"
    [ "$outcome" = "$want_outcome" ]
    run zsh "$EMIT" --pipeline story-preflight --outcome "$outcome" --wall-s 42 \
      --repo o/n --repo-dir "$BATS_TEST_TMPDIR" --issue 1437 \
      --payload "$BATS_TEST_TMPDIR/p.json" --telemetry-file "$sink"
    [ "$status" -eq 0 ]
  done
  run zsh "$VALIDATE" "$sink" --require-records
  [ "$status" -eq 0 ]
  [ "$(jq -s 'length' "$sink")" -eq 3 ]
  jq -se '[.[] | {o: .outcome, v: .payload.verdict, b: .payload.override_by}]
    == [{o:"success",v:"pass",b:null},{o:"parked",v:"stop",b:null},{o:"success",v:"overridden",b:"human"}]
    and all(.[]; .pipeline == "story-preflight" and .kind == "run" and .wall_s == 42)' "$sink" >/dev/null
}

# --- the SKILL.md wiring ----------------------------------------------------------------

@test "§2's ancestor sentence keeps the under-specified clause and drops the size clause" {
  run -1 grep -F 'far larger than its description implies' "$SKILL"
  grep -qF 'genuinely **under-specified**' "$SKILL"
}

@test "the pre-flight block writes the inventory outside the repo and runs the script on that file" {
  local block
  block="$(preflight_block)"
  [ -n "$block" ]
  contains "$block" 'before the first implementation'
  contains "$block" '<scratch>/size-inventory.json'
  contains "$block" 'size-preflight.zsh" --file <scratch>/size-inventory.json'
}

@test "the pre-flight caller treats every exit but 0 and 1 as no verdict (re-run once, then fail), never as a pass" {
  local block
  block="$(preflight_block)"
  printf '%s\n' "$block" | grep -qE '^  0\) echo "PASS" ;;'
  printf '%s\n' "$block" | grep -qE '^  1\) echo "STOP"; cat <scratch>/size-verdict\.json ;;'
  printf '%s\n' "$block" | grep -qE '^  \*\) echo "size pre-flight errored — no verdict"; exit 1 ;;'
  contains "$block" '**An exit 2 or 3 decides nothing, and is never recorded as a verdict.**'
  contains "$block" 're-run
**once**'
  contains "$block" "emit the run's record (§7) and stop"
}

@test "the pre-flight block documents all three stop terminals and records through the emitter" {
  local block
  block="$(preflight_block)"
  contains "$block" '**(a) The human overrides.**'
  contains "$block" '**(b) The human accepts the split.**'
  contains "$block" '**(c) No human present**'
  contains "$block" '**Any other answer** is no override'
  contains "$block" 'else take (b), which records it'
  lacks "$block" 'records a stop (no `--override`)'
  contains "$block" "timeout, an absent human, any other answer or an earlier run's \`OVERRIDDEN\` comment
  never is: a later run asks again, or with no human takes (c)."
  lacks "$block" 'without asking'
  contains "$block" '**Only that explicit answer is an override**'
  contains "$block" 'silence, a
  timeout, an absent human'
  contains "$block" 'the branch **un-pushed**, **no PR**'
  contains "$block" '--pipeline story-preflight'
  contains "$block" '--ts <the noted time> --wall-s <now − the noted time>'
  contains "$block" 'build-story-preflight-telemetry-record.zsh'
  contains "$block" '--override human'
}

@test "the pre-flight block applies needs-split and never the blocked label" {
  local block
  block="$(preflight_block)"
  contains "$block" '--add-label needs-split'
  contains "$block" 'run the clear block below, continue; ask nothing'
  contains "$block" 'size pre-flight: SPLIT — <triggers + counts>'
  contains "$block" 'size pre-flight: OVERRIDDEN by the human — <triggers + counts>'
  contains "$block" 'gh label create needs-split'
  run -1 grep -E -- '--add-label blocked|gh label create blocked' <<< "$block"
}

@test "E3's autonomous branch parks a size-stopped child with needs-split, never blocked" {
  local para
  para="$(e3_paragraph)"
  [ -n "$para" ]
  contains "$para" '`needs-split`'
  contains "$para" '**never** `blocked`'
  contains "$para" '**parked**'
  contains "$para" 'per child only'
  contains "$para" 'A pre-flight **error**'
  run -1 grep -E -- '--add-label blocked' <<< "$para"
}
