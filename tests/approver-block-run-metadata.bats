#!/usr/bin/env bats
#
# The hidden `claude-approver:findings` block's run metadata (#1231): each of
# the five approver agents — go, java, python, swift, claude-plugin — declares
# `language`, exactly its pinned `dimensions` list and `started_at` in its
# block schema (approver_version stays v1), says where `started_at` is
# captured, and the swift agent names the block marker literally. The keys are
# mirrored in the four language docs companions and in the bootstrap
# approver-policy template. collect-approver-telemetry.zsh reads these keys
# back from posted reviews (tests/collect-approver-telemetry.bats).

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home"
  SIX='  "dimensions": ["bugs", "security", "performance", "code_quality", "tests", "resilience"],'
  SEVEN='  "dimensions": ["bugs", "security", "performance", "code_quality", "tests", "swift6_compliance", "resilience"],'
  TEN='  "dimensions": ["bugs", "security", "performance", "code_quality", "tests", "prose_logic", "contract", "script_quality", "manifest_bump", "manifest"],'
}

agent() {  # $1 = go | java | python | swift | claude-plugin
  printf '%s/development-%s/agents/%s-approver.md' "$REPO_ROOT" "$1" "$1"
}
# schema_lines FILE PATTERN — the lines of FILE's "## Output JSON schema" section matching PATTERN
schema_lines() {
  awk -v pat="$2" '/^## Output JSON schema/ { f = 1; next } /^## / { f = 0 } f && index($0, pat)' "$1"
}
flat() { tr -s '[:space:]' ' ' < "$1"; }

# ------------------------------------------------------------- AC 3: dimensions

@test "each agent's block schema declares exactly its pinned dimensions list" {
  [ "$(schema_lines "$(agent go)" '"dimensions":')" = "$SIX" ]
  [ "$(schema_lines "$(agent java)" '"dimensions":')" = "$SIX" ]
  [ "$(schema_lines "$(agent python)" '"dimensions":')" = "$SIX" ]
  [ "$(schema_lines "$(agent swift)" '"dimensions":')" = "$SEVEN" ]
  [ "$(schema_lines "$(agent claude-plugin)" '"dimensions":')" = "$TEN" ]
}

@test "each agent's rendered block example carries the same dimensions list as its schema" {
  local l
  for l in go java python; do
    [ "$(grep -cxF -- "$SIX" "$(agent "$l")")" = 2 ] || { printf 'not twice: %s\n' "$l" >&2; return 1; }
  done
  [ "$(grep -cxF -- "$TEN" "$(agent claude-plugin)")" = 2 ]
  [ "$(grep -cxF -- "$SEVEN" "$(agent swift)")" = 1 ]
}

@test "each agent's block schema declares its language and started_at, and approver_version stays v1" {
  local l
  for l in go java python swift claude-plugin; do
    [ "$(schema_lines "$(agent "$l")" '"language":')" = "  \"language\": \"$l\"," ] || { printf 'language: %s\n' "$l" >&2; return 1; }
    [ "$(schema_lines "$(agent "$l")" '"started_at":')" = '  "started_at": 1791108000,' ] || { printf 'started_at: %s\n' "$l" >&2; return 1; }
    [ "$(schema_lines "$(agent "$l")" '"approver_version":')" = '  "approver_version": "v1",' ] || { printf 'version: %s\n' "$l" >&2; return 1; }
  done
}

@test "each agent explains the three keys as output-only run metadata read by the collector" {
  local l a step
  for l in go java python swift claude-plugin; do
    a="$(flat "$(agent "$l")")"
    contains "$a" "\`language\`, \`dimensions\` and \`started_at\` are run metadata for approver telemetry (#1231), which \`collect-approver-telemetry.zsh\` in the development plugin reads back from the posted review: \`language\` is \`$l\`;"
    contains "$a" "though the run stops before that step — when the walk gains a lens, so does this list;"
    contains "$a" "They are output only: no verdict, finding or calibration reads them."
  done
  for l in go java python; do
    contains "$(flat "$(agent "$l")")" "\`dimensions\` lists the lenses Step 10 walks, in walk order, in full on every block — the hotfix and refusal blocks too, though the run stops before that step —"
  done
  contains "$(flat "$(agent swift)")" "\`dimensions\` lists the lenses step 10 walks, in walk order, in full on every block — the hotfix and refusal blocks too, though the run stops before that step —"
  contains "$(flat "$(agent claude-plugin)")" "\`dimensions\` lists the lenses Step 9 walks, in walk order, in full on every block — the hotfix and refusal blocks too, though the run stops before that step —"
}

# ---------------------------------------------------------- where started_at comes from

@test "go, java, python and swift record started_at before any other command, hotfix included" {
  local l
  for l in go java python swift; do
    contains "$(flat "$(agent "$l")")" "**Record the start time first (#1231).** Before any other command of this run — the hard-fail checks and the hotfix check included — run \`date +%s\` and keep the number it prints: it is the hidden block's \`started_at\`, and every block you render carries it, the hotfix one too."
  done
  for l in go java python; do
    contains "$(flat "$(agent "$l")")" '"started_at": <the date +%s number recorded before Step 1>,'
  done
}

@test "claude-plugin records started_at at Step 2's work-directory creation" {
  local a; a="$(agent claude-plugin)"
  grep -qxF 'work=$(mktemp -d) && echo "work=$work"' "$a"
  [ "$(grep -A1 -xF 'work=$(mktemp -d) && echo "work=$work"' "$a" | tail -n 1)" = 'started_at=$(date +%s) && echo "started_at=$started_at"' ]
  contains "$(flat "$a")" "The \`started_at\` it prints is the hidden block's \`started_at\` (#1231): keep the number for Step 11."
  contains "$(flat "$a")" '"started_at": <the started_at number Step 2 printed>,'
}

@test "the swift agent names the block marker literally" {
  local a; a="$(flat "$(agent swift)")"
  contains "$a" "The block closes the body, rendered literally as \`<!-- claude-approver:findings\` on its own line, the JSON on the lines below it, then \`-->\` — the same marker every approver renders."
}

@test "every approver agent names the <!-- claude-approver:findings marker" {
  local l
  for l in go java python swift claude-plugin; do
    grep -qF '<!-- claude-approver:findings' "$(agent "$l")" || { printf 'no marker: %s\n' "$l" >&2; return 1; }
  done
}

# ------------------------------------------------------------ docs + template mirror

@test "the go, java and python docs mirror the three keys in their JSON schema and explain them" {
  local l d
  for l in go java python; do
    d="$REPO_ROOT/development-$l/docs/$l-approver.md"
    grep -qxF "  \"language\": \"$l\"," "$d" || { printf 'language: %s\n' "$l" >&2; return 1; }
    grep -qxF -- "$SIX" "$d" || { printf 'dimensions: %s\n' "$l" >&2; return 1; }
    grep -qxF '  "started_at": 1791108000,' "$d" || { printf 'started_at: %s\n' "$l" >&2; return 1; }
    contains "$(flat "$d")" "\`language\`, \`dimensions\` and \`started_at\` are run metadata for approver telemetry (#1231): \`language\` is \`$l\`, \`dimensions\` lists the lenses the risk register walks, in walk order, in full on every block (the hotfix and refusal blocks too), and \`started_at\` is the unix seconds the agent recorded at its first step. \`collect-approver-telemetry.zsh\` reads them back from the posted review; no verdict, finding or calibration reads them."
  done
  contains "$(flat "$REPO_ROOT/development-go/docs/go-approver.md")" '{ "approver_version": "v1", "language": "go", "dimensions": [ ... ], "started_at": ..., "verdict": "...",'
}

@test "the swift doc records the swift block's run metadata and its literal marker" {
  local d; d="$(flat "$REPO_ROOT/development-swift/docs/swift-approver.md")"
  contains "$d" "**The hidden block's run metadata (#1231)** carries \`\"language\": \"swift\"\` and the seven-lens list \`\"dimensions\": [\"bugs\", \"security\", \"performance\", \"code_quality\", \"tests\", \"swift6_compliance\", \"resilience\"]\`, beside the \`started_at\` every approver records at its first step."
  contains "$d" "The agent names the \`<!-- claude-approver:findings\` marker literally, so its block renders like every other approver's."
}

@test "no claude-plugin approver docs companion is created" {
  [ ! -e "$REPO_ROOT/development-claude-plugin/docs/claude-plugin-approver.md" ]
}

@test "the approver-policy template's JSON-block section carries the three keys" {
  local t="$REPO_ROOT/development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl"
  grep -qxF '  "language": "{{APPROVER_LANG}}",' "$t"
  grep -qxF '  "dimensions": ["bugs", "security", "performance", "code_quality", "tests", "…"],' "$t"
  grep -qxF '  "started_at": 1791108000,' "$t"
  grep -qxF '  "approver_version": "v1",' "$t"
  contains "$(flat "$t")" "\`language\`, \`dimensions\` and \`started_at\` are run metadata for approver telemetry (#1231), carried on every verdict's block: \`language\` is \`{{APPROVER_LANG}}\`, \`dimensions\` lists the lenses the risk register walks, in walk order, in full on every block (the hotfix and refusal blocks too), and \`started_at\` is the unix seconds the Approver recorded at its first step. They are output only — no verdict, finding or calibration reads them."
}

# ------------------------------------------------- the collector reads what they declare

@test "a block shaped like each agent's schema is accepted by the builder" {
  local l dims b="$BATS_TEST_TMPDIR/block.json" r="$BATS_TEST_TMPDIR/review.json"
  printf '%s' '{"id":7,"state":"APPROVED","commit_id":"4f2c9e1a0b"}' > "$r"
  for l in go java python swift claude-plugin; do
    dims="$(schema_lines "$(agent "$l")" '"dimensions":' | sed -e 's/^ *"dimensions": //' -e 's/,$//')"
    jq -n -c --arg l "$l" --argjson d "$dims" '{approver_version: "v1", language: $l, dimensions: $d, started_at: 1791108000, verdict: "APPROVE", confidence: "HIGH", type_detected: "fix", findings: []}' > "$b"
    run --separate-stderr zsh "$REPO_ROOT/development/scripts/telemetry/build-approver-telemetry-record.zsh" --review "$r" --block "$b"
    [ "$status" -eq 0 ] || { printf 'refused: %s %s\n' "$l" "$stderr" >&2; return 1; }
    [ "$(jq -c .dimensions <<<"$output")" = "$(jq -c . <<<"$dims")" ]
  done
}
