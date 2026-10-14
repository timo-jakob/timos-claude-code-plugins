#!/usr/bin/env bats
#
# build-approver-telemetry-record.zsh (#1231): the pure payload builder for one
# posted Approver review — the payload's exact keys and their sources (the
# review and its parsed hidden block), risk_register_size counted from the
# block's `risk` findings, the verdict <-> GitHub state consistency refusal, the
# key-shape refusals that keep any token-shaped value out of a payload, and
# --print-outcome (always success). The collector that feeds it from GitHub is
# tests/collect-approver-telemetry.bats.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home"
  B="$REPO_ROOT/development/scripts/telemetry/build-approver-telemetry-record.zsh"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  RV="$BATS_TEST_TMPDIR/review.json"
  BL="$BATS_TEST_TMPDIR/block.json"
  printf '%s' '{"id":2930481177,"user":{"login":"claude-approver-timo-jakob[bot]","type":"Bot"},"state":"CHANGES_REQUESTED","submitted_at":"2026-10-04T10:03:34Z","commit_id":"4f2c9e1a0b","body":"ignored by the builder"}' > "$RV"
  printf '%s' '{"approver_version":"v1","language":"python","dimensions":["bugs","security","performance","code_quality","tests","resilience"],"started_at":1791108000,"verdict":"REQUEST_CHANGES","confidence":"LOW","type_detected":"feat","findings":[{"category":"risk","dimension":"security"},{"category":"test_quality","dimension":null},{"category":"risk","dimension":"resilience"}]}' > "$BL"
}

edit_review() { jq -c "$1" "$RV" > "$RV.new" && mv "$RV.new" "$RV"; }
edit_block() { jq -c "$1" "$BL" > "$BL.new" && mv "$BL.new" "$BL"; }
build() { run --separate-stderr zsh "$B" --review "$RV" --block "$BL" "$@"; }
refused() {  # $1 = the refusal text expected on stderr
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "$1"
}

# ------------------------------------------------------------------- payload

@test "the payload carries exactly the documented keys, each copied from the review or its block" {
  build
  [ "$status" -eq 0 ]
  [ "$(jq -c 'keys_unsorted' <<<"$output")" = '["verdict","confidence","risk_register_size","dimensions","pr_type","language","review_id","head_sha","approver_version"]' ]
  [ "$(jq -c '[.verdict, .confidence, .pr_type, .language, .review_id, .head_sha, .approver_version]' <<<"$output")" = '["REQUEST_CHANGES","LOW","feat","python",2930481177,"4f2c9e1a0b","v1"]' ]
  [ "$(jq -c .dimensions <<<"$output")" = '["bugs","security","performance","code_quality","tests","resilience"]' ]
}

@test "risk_register_size counts only the block's risk findings" {
  build
  [ "$(jq -r .risk_register_size <<<"$output")" = 2 ]
  edit_block '.findings = []'
  build
  [ "$(jq -r .risk_register_size <<<"$output")" = 0 ]
  edit_block '.findings = [{"category":"baseline"},{"category":"risk"}]'
  build
  [ "$(jq -r .risk_register_size <<<"$output")" = 1 ]
}

@test "dimensions keep the block's walk order, any length" {
  edit_block '.language = "claude-plugin" | .dimensions = ["bugs","security","performance","code_quality","tests","prose_logic","contract","script_quality","manifest_bump","manifest"]'
  build
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.language, .dimensions]' <<<"$output")" = '["claude-plugin",["bugs","security","performance","code_quality","tests","prose_logic","contract","script_quality","manifest_bump","manifest"]]' ]
}

# ------------------------------------------------- verdict <-> state refusal

@test "each verdict is accepted against its own GitHub state" {
  local pair
  for pair in APPROVE:APPROVED REQUEST_CHANGES:CHANGES_REQUESTED COMMENT:COMMENTED; do
    edit_block ".verdict = \"${pair%%:*}\""
    edit_review ".state = \"${pair#*:}\""
    build
    [ "$status" -eq 0 ] || { printf 'refused: %s\n' "$pair" >&2; return 1; }
    [ "$(jq -r .verdict <<<"$output")" = "${pair%%:*}" ]
  done
}

@test "a verdict that disagrees with the review state is refused with no output" {
  local pair
  for pair in REQUEST_CHANGES:APPROVED APPROVE:CHANGES_REQUESTED APPROVE:COMMENTED COMMENT:APPROVED REQUEST_CHANGES:COMMENTED COMMENT:CHANGES_REQUESTED REQUEST_CHANGES:PENDING; do
    edit_block ".verdict = \"${pair%%:*}\""
    edit_review ".state = \"${pair#*:}\""
    build
    printf 'case: %s\n' "$pair" >&2
    refused "review refused — block verdict ${pair%%:*} disagrees with the review state ${pair#*:}"
  done
}

@test "--print-outcome refuses a verdict/state mismatch too" {
  edit_review '.state = "APPROVED"'
  build --print-outcome
  refused "disagrees with the review state APPROVED"
}

@test "a DISMISSED review keeps the block's verdict: its state no longer says what was posted" {
  edit_review '.state = "DISMISSED"'
  build
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<<"$output")" = REQUEST_CHANGES ]
}

# -------------------------------------------------------------- shape refusals

@test "a review or block that breaks a shape rule is refused with no output" {
  local e
  for e in 'R:.id = 0' 'R:.id = "2930481177"' 'R:.commit_id = "not-a-sha"' 'R:del(.commit_id)' \
    'B:.verdict = "MAYBE"' 'B:del(.verdict)' 'B:.confidence = "high"' 'B:.findings = {}' 'B:del(.findings)' \
    'B:.findings = ["risk"]' 'B:.dimensions = []' 'B:.dimensions = "bugs"' 'B:.dimensions = ["Bugs"]' \
    'B:del(.language)' 'B:.language = "Python"' 'B:del(.type_detected)' 'B:.approver_version = 1'; do
    setup
    if [ "${e%%:*}" = R ]; then edit_review "${e#*:}"; else edit_block "${e#*:}"; fi
    build
    [ "$status" -eq 1 ] || { printf 'not refused: %s\n' "$e" >&2; return 1; }
    [ -z "$output" ]
    contains "$stderr" "review refused — "
  done
}

@test "a token-shaped value in any copied block field is refused, never carried into a payload" {
  local e tok="ghs_fake0000"
  for e in ".type_detected = \"$tok\"" ".language = \"$tok\"" ".dimensions = [\"bugs\", \"$tok\"]" \
    ".approver_version = \"$tok\"" '.type_detected = "github_pat_fake0000"' '.language = "ghp_fake0000"'; do
    setup
    edit_block "$e"
    build
    [ "$status" -eq 1 ] || { printf 'not refused: %s\n' "$e" >&2; return 1; }
    [ -z "$output" ]
  done
}

@test "each refusal names its rule" {
  edit_block '.verdict = "MAYBE" | .confidence = "SURE" | .dimensions = []'
  build
  [ "$status" -eq 1 ]
  contains "$stderr" "block verdict must be APPROVE, REQUEST_CHANGES or COMMENT"
  contains "$stderr" "block confidence must be HIGH, MEDIUM or LOW"
  contains "$stderr" "block dimensions must be a non-empty array of lowercase identifiers"
}

# --------------------------------------------------------------------- outcome

@test "--print-outcome prints success for every verdict" {
  local pair
  for pair in APPROVE:APPROVED REQUEST_CHANGES:CHANGES_REQUESTED COMMENT:COMMENTED; do
    edit_block ".verdict = \"${pair%%:*}\""
    edit_review ".state = \"${pair#*:}\""
    build --print-outcome
    [ "$status" -eq 0 ]
    [ "$output" = success ] || { printf '%s -> %s\n' "$pair" "$output" >&2; return 1; }
  done
}

# ----------------------------------------------------------------------- usage

@test "usage errors exit 2 with nothing on stdout" {
  run --separate-stderr zsh "$B"
  [ "$status" -eq 2 ]; [ -z "$output" ]; contains "$stderr" "--review is required"
  run --separate-stderr zsh "$B" --review "$RV"
  [ "$status" -eq 2 ]; contains "$stderr" "--block is required"
  build --bogus
  [ "$status" -eq 2 ]; contains "$stderr" "unknown flag: --bogus"
  build extra
  [ "$status" -eq 2 ]; contains "$stderr" "unexpected argument: extra"
  run --separate-stderr zsh "$B" --review "$RV" --block
  [ "$status" -eq 2 ]; contains "$stderr" "--block requires a value"
  run --separate-stderr zsh "$B" --review "$BATS_TEST_TMPDIR/absent.json" --block "$BL"
  [ "$status" -eq 2 ]; contains "$stderr" "--review file does not exist"
  run --separate-stderr zsh "$B" --review "$RV" --block "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]; contains "$stderr" "--block is a directory"
}

@test "an input that is not one JSON object exits 1" {
  printf '[1]' > "$BL"
  build
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "--block must be a single JSON object"
  printf '{"a":1}{"b":2}' > "$RV"
  build
  [ "$status" -eq 1 ]
  contains "$stderr" "--review must be a single JSON object"
}

# ------------------------------------------------------------- ARCHITECTURE.md

@test "ARCHITECTURE.md documents the decision, the collector and builder, the exit contract and the payload keys" {
  local arch
  arch="$(tr -s '[:space:]' ' ' < "$ARCH")"
  contains "$arch" "## Approver telemetry (#1231)"
  contains "$arch" "**Collected from the reviews the Approver posted.**"
  contains "$arch" "Vendoring the emitter into every approver plugin was rejected: five copies of the contract is the drift the telemetry trilogy exists to end."
  contains "$arch" "Emitting from the \`/development-*:approve\` skill's local step was rejected: the skill reaches the development plugin only by the repo-relative path its token mint uses, which resolves only inside this repo — so no other repo would ever get a record — and it would need a new agent-to-skill hand-off."
  contains "$arch" "Deferring to epic 3's \`approver_verdict\` enrichment (#742) was rejected: it loses the confidence, the risk-register size and the PR type, which only the Approver knows."
  contains "$arch" "The approve skills' repo-relative \`mint-approver-token.zsh\` reference is unchanged by #1231, and approver telemetry does not depend on it; that path bug is tracked as #2099."
  contains "$arch" "\`development/scripts/telemetry/collect-approver-telemetry.zsh --repo OWNER/NAME [--telemetry-file PATH] [--telemetry-dir DIR]\`"
  contains "$arch" "one \`kind: \"run\"\` record, \`pipeline: \"approve\"\`, per instrumented review a \`claude-approver\` Bot posted"
  contains "$arch" "A review whose id is already \`payload.review_id\` on a \`pipeline: \"approve\"\` record in **that one file** is skipped; a record in any other file does not count."
  contains "$arch" "A review with no block, a block that is not one JSON object, no integer \`started_at\`, or a non-positive \`submitted_at − started_at\` yields no record — \`wall_s\` is required and never guessed — and is counted as not instrumented; so is a block the builder refuses."
  contains "$arch" "A review by any other author is ignored, uncounted, even when its body carries a block."
  contains "$arch" "\`build-approver-telemetry-record.zsh\`"
  contains "$arch" "It refuses a block whose \`verdict\` disagrees with the review's GitHub state — \`APPROVE\`↔\`APPROVED\`, \`REQUEST_CHANGES\`↔\`CHANGES_REQUESTED\`, \`COMMENT\`↔\`COMMENTED\` — with exit 1 and no output; a \`DISMISSED\` review's state no longer says what was posted, so the block's verdict stands against it."
  contains "$arch" "| \`0\` | the collection completed — including nothing to collect and reviews counted as not instrumented |"
  contains "$arch" "| \`2\` | usage — no \`--repo\`, a malformed one, an unknown or dangling flag, a positional, a \`--telemetry-dir\` that exists and is not a directory; judged before any \`gh\` call |"
  contains "$arch" "| \`3\` | a \`gh\` call failed — the pulls listing (a \`--repo\` that does not exist or the token cannot see answers 404 there, and that is a failure too) or a reviews listing — or the emitter failed, or a tool (\`jq\`, \`gh\`), the builder (any exit but its refusal) or the sink is unusable |"
  contains "$arch" "Every exit 3 prints one stderr line naming the repo, the failing endpoint or script, and the PR number and review id it was processing"
  contains "$arch" "after a transient failure (\`gh\`, the emitter) a re-run resumes through idempotency; an unusable tool, builder or sink fails again on every re-run until it is fixed."
  local k
  for k in verdict confidence risk_register_size dimensions pr_type language review_id head_sha approver_version; do
    contains "$arch" "| \`$k\` |"
  done
  contains "$arch" "| \`success\` | a review was posted — any verdict; \`REQUEST_CHANGES\` is a successful review |"
  contains "$arch" "| \`parked\`, \`escalated\`, \`failed\` | not used by this pipeline: a run that posts no review (a conflict stop, a hard-fail refusal, a mint failure) leaves no settled trace, and no code path hands off to a human as a distinct event — \`COMMENT\` with reservations is a posted review |"
  contains "$arch" '| go, java, python | `["bugs","security","performance","code_quality","tests","resilience"]` |'
  contains "$arch" '| swift | `["bugs","security","performance","code_quality","tests","swift6_compliance","resilience"]` |'
  contains "$arch" '| claude-plugin | `["bugs","security","performance","code_quality","tests","prose_logic","contract","script_quality","manifest_bump","manifest"]` |'
  contains "$arch" "**The block's run metadata.** All five approver agents — go, java, python, swift and claude-plugin — add three keys to the hidden block, \`approver_version\` staying \`v1\`"
  contains "$arch" "and the swift agent names the \`<!-- claude-approver:findings\` marker literally. They are output only: no verdict, policy, risk-register or calibration logic reads them."
  contains "$arch" "\`collect-approver-telemetry.zsh\` (#1231, *Approver telemetry*, below)."
}
