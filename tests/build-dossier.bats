#!/usr/bin/env bats
#
# Behavioral tests for build-dossier.zsh (#563): the PR "Review dossier" — the
# durable audit record for why auto-merge happened. Human-readable for
# reviewers; a hidden, dimension-tagged JSON block the Approver re-ingests. A PR
# with no loop (--no-review) must get no dossier at all (epic #557).

# `run --separate-stderr` (the buffered-render guards, #1064) needs 1.5.0+
bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/build-dossier.zsh"
  ST="$BATS_TEST_TMPDIR/status.json"
  cat > "$ST" <<'EOF'
{"status":"CONVERGED","rounds":2,"max_rounds":3,"repo_type":"python",
 "round_changelists":[
   {"round":1,"summary":{"critical":1,"high":0,"low":1,"blocking":1,"conflicts":0},
    "blocking":[{"priority":"Critical","dimension":"bugs","file":"app.py","line":1,"title":"None deref","reviewers":["python-bug-hunter","python-security-reviewer"]}],
    "suggestions":[{"priority":"Low","dimension":"code_quality","file":"app.py","line":9,"title":"rename var","reviewers":["python-code-quality"]}]},
   {"round":2,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},"blocking":[],"suggestions":[]}
 ],
 "final_changelist":{"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},"blocking":[],"suggestions":[]}}
EOF
}

# extract the hidden dossier JSON from the rendered output
hidden_json() { echo "$output" | grep -o '<!-- review-dossier: .* -->' | sed -E 's/^<!-- review-dossier: (.*) -->$/\1/'; }

@test "renders the dossier section for a looped story (rounds + reviewers + waived)" {
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^## Review dossier'
  echo "$output" | grep -q '2 round(s)'
  echo "$output" | grep -q 'Round 1: 1 blocking'
  # anchored: both strings also appear inside the hidden JSON, so an unanchored
  # needle would leave the human-readable half entirely unasserted
  echo "$output" | grep -qE '^\*\*Reviewers:\*\*.*python-bug-hunter'
  # waived Low suggestion is logged, not a blocker
  echo "$output" | grep -qE '^- .app\.py:9. \[code_quality\] rename var'
}

@test "hidden JSON is present, dimension-tagged with the #449 enum, and valid" {
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  hidden_json | jq -e '.dimensions | has("bugs") and has("security") and has("performance") and has("code_quality") and has("tests")' >/dev/null
  # a dimension the panel never flagged is 'clean' — the Approver lowers its weight
  [ "$(hidden_json | jq -r '.dimensions.security.clean')" = "true" ]
  # a dimension with a fixed blocker is not clean
  [ "$(hidden_json | jq -r '.dimensions.bugs.clean')" = "false" ]
  [ "$(hidden_json | jq -r '.dimensions.bugs.blocking')" = "1" ]
  # waived Low carried as context
  [ "$(hidden_json | jq '.waived_low | length')" -eq 1 ]
  [ "$(hidden_json | jq -r '.status')" = "CONVERGED" ]
  # fields the Approver register consumes, previously unasserted
  [ "$(hidden_json | jq -r '.repo_type')" = "python" ]
  [ "$(hidden_json | jq -r '.final.blocking')" = "0" ]
  # a single-phase run must carry NO promotion object and no promotion prose —
  # emitting promotion:{selected:0,promoted:0} on every ordinary PR would read to
  # the Approver as "a promotion phase ran and raised nothing"
  [ "$(hidden_json | jq -r 'has("promotion")')" = "false" ]
  [ "$(echo "$output" | grep -c 'suggestion-promotion phase')" -eq 0 ]
  [ "$(echo "$output" | grep -c '^- Promotion round')" -eq 0 ]
}

@test "reviewers are unioned and deduped across rounds" {
  run zsh "$S" --status "$ST"
  [ "$(hidden_json | jq '.reviewers | length')" -eq 3 ]
}

@test "no loop (--no-review / zero rounds) yields no dossier at all — PR is as today" {
  echo '{"status":"SKIPPED","rounds":0,"round_changelists":[]}' > "$BATS_TEST_TMPDIR/skip.json"
  run zsh "$S" --status "$BATS_TEST_TMPDIR/skip.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "usage: --status is required (exit 2)" {
  run zsh "$S"
  [ "$status" -eq 2 ]
  # the diagnostic IS the contract: a bare exit 2 could come from any guard
  echo "$output" | grep -q 'usage: build-dossier.zsh'
}

@test "internal: invalid status JSON is exit 1, not a crash" {
  echo 'not json' > "$BATS_TEST_TMPDIR/bad.json"
  run zsh "$S" --status "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- '--status unreadable, or not a JSON object'
}

# ---- non-core dimensions (resilience #966, swift6_compliance #447) ----------
#
# ARCHITECTURE.md's dimension-enum section makes a claim about what reaches the
# dossier when a panel gains a dimension outside the #449 core five. These two
# tests pin BOTH halves of it — the half that works, and the half that does not
# (#1148) — so the doc and the script cannot drift apart silently.

@test "a non-core dimension WITH findings is carried into the dossier" {
  cat > "$BATS_TEST_TMPDIR/res.json" <<'EOF'
{"status":"CONVERGED","rounds":1,"repo_type":"go",
 "round_changelists":[{"round":1,
   "summary":{"critical":0,"high":1,"low":0,"blocking":1,"conflicts":0},
   "blocking":[{"file":"client.go","line":42,"dimension":"resilience",
     "title":"no breaker on the pricing-api call","priority":"High",
     "reviewers":["go-resilience-reviewer"]}],
   "suggestions":[]}],
 "final_changelist":{"summary":{"critical":0,"high":1,"low":0,"blocking":1,"conflicts":0},
   "blocking":[],"suggestions":[]}}
EOF
  run zsh "$S" --status "$BATS_TEST_TMPDIR/res.json"
  [ "$status" -eq 0 ]
  hidden_json | jq -e '.dimensions | has("resilience")' >/dev/null
  [ "$(hidden_json | jq -r '.dimensions.resilience.blocking')" = "1" ]
  [ "$(hidden_json | jq -r '.dimensions.resilience.clean')" = "false" ]
  # Anchored to the RENDERED lines: a bare name would also match the hidden
  # JSON's .reviewers array, which the assertions above already require, so the
  # human-readable half of the dossier would go unasserted.
  echo "$output" | grep -qE '^\*\*Reviewers:\*\*.*go-resilience-reviewer'
  echo "$output" | grep -qE '^- .resilience. — 1 blocking'
}

@test "a CLEAN non-core dimension is ABSENT from the dossier (known gap, #1148)" {
  # Pinned as-is, not as it should be: $core is the hardcoded #449 five, and
  # $dims unions it only with dimensions that PRODUCED findings. So a clean
  # resilience round emits no key, indistinguishable from "never ran" — while a
  # clean CORE dimension emits clean:true (asserted above for `security`).
  # When #1148 lands this test flips to has("resilience") == true / clean == true.
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.dimensions | has("resilience")')" = "false" ]
  # the contrast that makes the asymmetry concrete
  [ "$(hidden_json | jq -r '.dimensions.security.clean')" = "true" ]
}

# ---- merged promotion phase (#1064) ----------------------------------------
#
# A suggestion-promotion phase (#994) is a second run of the same state machine,
# so it leaves a SECOND status JSON. The Approver parses exactly ONE hidden
# block, so both phases must merge into one section and one block here.

# Blocking phase waiving TWO Lows; the human promotes both; the sub-loop raises
# only ONE of them — and reports it at a DRIFTED line (9 -> 11), the case that
# makes line-insensitive identity load-bearing.
promo_fixtures() {
  BST="$BATS_TEST_TMPDIR/b.json"
  SEL="$BATS_TEST_TMPDIR/sel.json"
  PST="$BATS_TEST_TMPDIR/p.json"
  cat > "$BST" <<'EOF'
{"status":"CONVERGED","rounds":2,"repo_type":"python",
 "round_changelists":[
  {"round":1,"summary":{"critical":1,"high":0,"low":2,"blocking":1,"conflicts":0},
   "blocking":[{"priority":"Critical","dimension":"bugs","file":"app.py","line":1,"title":"None deref","reviewers":["python-bug-hunter"]}],
   "suggestions":[{"priority":"Low","dimension":"code_quality","file":"app.py","line":9,"title":"rename var","reviewers":["python-code-quality"]},
                  {"priority":"Low","dimension":"code_quality","file":"app.py","line":20,"title":"extract helper","reviewers":["python-code-quality"]}]},
  {"round":2,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},"blocking":[],"suggestions":[]}],
 "final_changelist":{"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},"blocking":[],"suggestions":[]}}
EOF
  cat > "$SEL" <<'EOF'
[{"file":"app.py","line":9,"dimension":"code_quality","title":"rename var"},
 {"file":"app.py","line":20,"dimension":"code_quality","title":"extract helper"}]
EOF
  cat > "$PST" <<'EOF'
{"status":"CONVERGED","rounds":2,"repo_type":"python","promotion_phase":true,
 "round_changelists":[
  {"round":1,"summary":{"critical":0,"high":1,"low":0,"blocking":1,"conflicts":0},
   "blocking":[{"priority":"High","dimension":"code_quality","file":"app.py","line":11,"title":"rename var","promoted":true,"reviewers":["python-code-quality"]}],
   "suggestions":[]},
  {"round":2,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},"blocking":[],"suggestions":[]}],
 "final_changelist":{"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},"blocking":[],"suggestions":[]}}
EOF
}

@test "both phases merge into exactly ONE section and ONE hidden block (#1064)" {
  promo_fixtures
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  # exactly one of each — two blocks would leave the Approver reading the first
  # and silently ignoring the other phase
  [ "$(echo "$output" | grep -c '^## Review dossier')" -eq 1 ]
  [ "$(echo "$output" | grep -c 'review-dossier:')" -eq 1 ]
  # rounds summed across phases
  [ "$(hidden_json | jq -r '.rounds')" = "4" ]
  echo "$output" | grep -q '4 round(s)'
  # both phases' rounds are rendered, the promotion ones labelled as such
  echo "$output" | grep -q '^- Round 1: 1 blocking'
  echo "$output" | grep -q '^- Promotion round 1: 1 blocking (1 promoted)'
}

@test "the promotion object records picked-vs-actually-raised (#1064)" {
  promo_fixtures
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.promotion.selected')" = "2" ]
  [ "$(hidden_json | jq -r '.promotion.promoted')" = "1" ]
  [ "$(hidden_json | jq -r '.promotion.rounds')" = "2" ]
  [ "$(hidden_json | jq -r '.promotion.status')" = "CONVERGED" ]
  # they are NOT the same number, and the prose says both
  echo "$output" | grep -q 'selected \*\*2\*\* waived suggestion(s), of which \*\*1\*\*'
  # the positive half of the status-conditional prose (its negation is pinned
  # by the BUDGET_EXHAUSTED test)
  echo "$output" | grep -q 'raised to blocking over 2 round(s) and cleared\.'
}

@test "a promoted-and-fixed item is dropped from BOTH waived halves, despite line drift (#1064)" {
  promo_fixtures
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  # the raised item was recorded at line 9 by the blocking phase and re-reported
  # at line 11 by the promotion phase: identity is line-INSENSITIVE, so it drops
  [ "$(hidden_json | jq '[.waived_low[] | select(.title == "rename var")] | length')" -eq 0 ]
  # counted, not a bare `! …` — a bare negation is inert in bats (#829)
  [ "$(echo "$output" | grep -c '^- .app\.py:.*rename var')" -eq 0 ]
  # ...and it still counts as blocking, because it WAS found and fixed
  [ "$(hidden_json | jq -r '.dimensions.code_quality.blocking')" = "1" ]
}

@test "a SELECTED but never-raised item stays waived in both halves (#1064)" {
  promo_fixtures
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  # it was picked, but the phase never raised it — so it was never promoted in
  # fact, and is still genuinely un-actioned work
  [ "$(hidden_json | jq '[.waived_low[] | select(.title == "extract helper")] | length')" -eq 1 ]
  # anchored to the rendered WAIVED bullet — a bare needle also matches the
  # hidden JSON, so it would not assert the human-readable half at all
  echo "$output" | grep -qE '^- .app\.py:.*\[code_quality\] extract helper'
  [ "$(hidden_json | jq -r '.dimensions.code_quality.suggestions')" = "1" ]
}

@test "the exclusion is applied ONCE, so rendered and machine halves agree (#1064)" {
  promo_fixtures
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  # the rendered waived bullets and waived_low must have the same cardinality —
  # the drift that a second, separate filter would eventually introduce
  local rendered
  rendered=$(echo "$output" | grep -c '^- `app\.py:.*\[code_quality\]')
  # pin the expected size FIRST: without it, a regression dropping every Low
  # satisfies the two equalities below as 0 == 0 == 0
  [ "$rendered" -eq 1 ]
  [ "$rendered" -eq "$(hidden_json | jq '.waived_low | length')" ]
  # and the per-dimension suggestion count is that same set, not the unfiltered one
  [ "$rendered" -eq "$(hidden_json | jq -r '.dimensions.code_quality.suggestions')" ]
}

@test "status/final describe the PROMOTION phase, the run's terminal state (#1064)" {
  promo_fixtures
  # make the promotion phase terminate differently from the blocking phase so the
  # assertion cannot pass by both being CONVERGED
  jq '.status = "BUDGET_EXHAUSTED" | .final_changelist.summary.blocking = 3' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ "$(hidden_json | jq -r '.final.blocking')" = "3" ]
}

@test "a REWORDED promoted title is NOT dropped — the drop is deliberately stricter (#1064)" {
  # Documented asymmetry, pinned so it cannot drift silently. The overlay also
  # promotes on a shared significant token; the dossier requires an exact
  # normalized title. The failure direction is the reason: leaving a fixed item
  # listed is conservative and visible, whereas token-matching here could drop a
  # genuinely waived NEIGHBOUR that merely shares a word.
  promo_fixtures
  jq '.round_changelists[0].blocking[0].title = "rename var for clarity"' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq '[.waived_low[] | select(.title == "rename var")] | length')" -eq 1 ]
  # the promotion counts still report it as raised — the two are read together
  [ "$(hidden_json | jq -r '.promotion.promoted')" = "1" ]
}

@test "a zero-round blocking status STILL renders a real promotion phase (#1064)" {
  # the old gate counted only the blocking phase, so this combination exited 0
  # with no output, silently discarding the promotion phase's whole record
  promo_fixtures
  echo '{"status":"SKIPPED","rounds":0,"round_changelists":[]}' > "$BST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -q '^## Review dossier'
  [ "$(hidden_json | jq -r '.promotion.promoted')" = "1" ]
}

@test "no rounds in EITHER phase still yields no dossier at all (#1064)" {
  promo_fixtures
  echo '{"status":"SKIPPED","rounds":0,"round_changelists":[]}' > "$BST"
  echo '{"status":"SKIPPED","rounds":0,"round_changelists":[]}' > "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- input refusals (#1064) -------------------------------------------------

@test "usage: the promotion flags are an ATOMIC PAIR (exit 2 either way)" {
  promo_fixtures
  run zsh "$S" --status "$BST" --promotion-status "$PST"
  [ "$status" -eq 2 ]
  # branch-UNIQUE needles: both diagnostics end in "atomic pair", so the generic
  # needle passes even if the two arms printed each other's message — which would
  # tell the caller to add the flag they already passed
  echo "$output" | grep -q -- '--promotion-status requires --promoted'
  run zsh "$S" --status "$BST" --promoted "$SEL"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- '--promoted requires --promotion-status'
}

@test "usage: a flag that swallows the next FLAG as its value is refused (exit 2)" {
  promo_fixtures
  run zsh "$S" --status --promoted "$SEL"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- '--status requires a value'
}

@test "--status holding null is exit 1, NOT a silent empty exit 0 (#1064)" {
  # the validation-parity gap: -s alone passed a file holding `null`, and the
  # PR then lost its dossier with no diagnostic anywhere
  echo 'null' > "$BATS_TEST_TMPDIR/null.json"
  run zsh "$S" --status "$BATS_TEST_TMPDIR/null.json"
  [ "$status" -eq 1 ]
  [ -z "$(echo "$output" | grep '^## Review dossier')" ]
  # the diagnostic is the contract: silence was the whole defect
  echo "$output" | grep -q -- '--status unreadable, or not a JSON object'

}

@test "--status holding a non-object (array) is exit 1" {
  echo '[]' > "$BATS_TEST_TMPDIR/arr.json"
  run zsh "$S" --status "$BATS_TEST_TMPDIR/arr.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- '--status unreadable, or not a JSON object'
}

@test "--status pointing at a DIRECTORY is exit 1, blamed on the file not its contents" {
  mkdir -p "$BATS_TEST_TMPDIR/adir"
  run zsh "$S" --status "$BATS_TEST_TMPDIR/adir"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'non-empty regular file'
}

@test "--status holding TWO concatenated objects is exit 1" {
  printf '{"status":"A","round_changelists":[]}\n{"status":"B","round_changelists":[]}\n' \
    > "$BATS_TEST_TMPDIR/two.json"
  run zsh "$S" --status "$BATS_TEST_TMPDIR/two.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'exactly ONE JSON object'
}

@test "--promotion-status gets the SAME validation as --status" {
  promo_fixtures
  echo 'null' > "$BATS_TEST_TMPDIR/null.json"
  run zsh "$S" --status "$BST" --promotion-status "$BATS_TEST_TMPDIR/null.json" --promoted "$SEL"
  [ "$status" -eq 1 ]
  # arm-UNIQUE: the bare flag name appears in all four _read_status messages and
  # in the atomic-pair one, so it would not prove the same arm fired
  echo "$output" | grep -q -- '--promotion-status unreadable, or not a JSON object'
}

@test "--promoted must be an array of identity-key objects (exit 1)" {
  promo_fixtures
  # the shapes a hand- or model-written selection most plausibly takes
  # each asserts the DIAGNOSTIC too: a bare exit 1 is also produced by the
  # --promotion-status validation and by a jq that fails later and blames the
  # wrong input — the very mis-blaming the element-shape check exists to prevent
  echo '["rename var"]' > "$BATS_TEST_TMPDIR/bad1.json"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$BATS_TEST_TMPDIR/bad1.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- 'JSON array of objects'
  echo '[{"title":"rename var"}]' > "$BATS_TEST_TMPDIR/bad2.json"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$BATS_TEST_TMPDIR/bad2.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- 'non-empty file and dimension'
  echo '{"file":"app.py"}' > "$BATS_TEST_TMPDIR/bad3.json"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$BATS_TEST_TMPDIR/bad3.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- 'JSON array of objects'
  # the length > 0 clauses the diagnostic names — an empty file/dimension would
  # compare equal only to a finding whose own field was missing
  echo '[{"file":"","dimension":"code_quality","title":"rename var"}]' > "$BATS_TEST_TMPDIR/bad4.json"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$BATS_TEST_TMPDIR/bad4.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- 'non-empty file and dimension'
  # a non-STRING title would reach normtitle as a number and match nothing
  echo '[{"file":"app.py","dimension":"code_quality","title":5}]' > "$BATS_TEST_TMPDIR/bad5.json"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$BATS_TEST_TMPDIR/bad5.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- 'non-empty file and dimension'
}

@test "--promoted holding TWO concatenated arrays is exit 1" {
  promo_fixtures
  printf '[{"file":"a.py","dimension":"tests","title":"t"}]\n[{"file":"b.py","dimension":"tests","title":"u"}]\n' \
    > "$BATS_TEST_TMPDIR/twoarr.json"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$BATS_TEST_TMPDIR/twoarr.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'exactly ONE JSON array'
}

@test "the hidden block is ONE line — the Approver parses it as such" {
  promo_fixtures
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  # a pretty-printed block would span many lines and the grep-based extraction
  # every consumer uses would capture only the first
  [ "$(echo "$output" | grep -c '^<!-- review-dossier: .* -->$')" -eq 1 ]
  hidden_json | jq -e . >/dev/null
}

# ---- the guards that make the exit-code contract true (#1064) ---------------
#
# 0 ok / 1 internal / 2 usage is only a contract if the failure paths are
# exercised. Both tests below assert stdout is EMPTY, which is the assertion
# that actually pins buffering: a streamed render ships a truncated dossier.

@test "a mid-render failure exits 1 with EMPTY stdout — the render is buffered" {
  # a non-object round summary survives _read_status, the round count and the
  # dossier jq, then makes roundline's .summary.blocking a type error
  cat > "$BATS_TEST_TMPDIR/render.json" <<'EOF'
{"status":"CONVERGED","rounds":1,"repo_type":"python",
 "round_changelists":[{"round":1,"summary":"oops","blocking":[],"suggestions":[]}],
 "final_changelist":{"summary":{"blocking":0,"conflicts":0,"low":0,"critical":0,"high":0}}}
EOF
  run --separate-stderr zsh "$S" --status "$BATS_TEST_TMPDIR/render.json"
  [ "$status" -eq 1 ]
  # the whole point: no partial section, no orphaned half-block in the PR body
  [ -z "$output" ]
  echo "$stderr" | grep -q 'could not render dossier section'
}

@test "a mid-build failure exits 1 with EMPTY stdout and its own diagnostic" {
  # round_changelists as a STRING: it has a length, so the round-count gate
  # passes, and the dossier jq then errors iterating it
  echo '{"status":"CONVERGED","rounds":1,"round_changelists":"2"}' > "$BATS_TEST_TMPDIR/build.json"
  run --separate-stderr zsh "$S" --status "$BATS_TEST_TMPDIR/build.json"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q 'could not build dossier'
}

# ---- the drop identity, component by component (#1064) ---------------------

@test "the drop identity keys on FILE and DIMENSION, not the title alone (#1064)" {
  # If identkey regressed to the title alone, these same-titled neighbours would
  # silently vanish from the waived list — hiding genuinely un-actioned work,
  # the exact failure direction the strict rule is chosen to avoid.
  promo_fixtures
  jq '.round_changelists[0].suggestions += [
       {"priority":"Low","dimension":"code_quality","file":"util.py","line":9,"title":"rename var","reviewers":["python-code-quality"]},
       {"priority":"Low","dimension":"tests","file":"app.py","line":9,"title":"rename var","reviewers":["python-test-reviewer"]}]' \
    "$BST" > "$BST.x"
  mv "$BST.x" "$BST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  # same title, different FILE -> still waived
  [ "$(hidden_json | jq '[.waived_low[] | select(.file == "util.py" and .title == "rename var")] | length')" -eq 1 ]
  # same title and file, different DIMENSION -> still waived
  [ "$(hidden_json | jq '[.waived_low[] | select(.dimension == "tests" and .title == "rename var")] | length')" -eq 1 ]
  # only the genuinely promoted one was dropped
  [ "$(hidden_json | jq '[.waived_low[] | select(.file == "app.py" and .dimension == "code_quality" and .title == "rename var")] | length')" -eq 0 ]
}

@test "the drop identity NORMALIZES case and whitespace (#1064)" {
  # normtitle is the 'exact NORMALIZED title' half of the rule; with every
  # fixture byte-identical, dropping the normalization would go unnoticed
  promo_fixtures
  jq '.round_changelists[0].blocking[0].title = "  Rename   VAR "' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq '[.waived_low[] | select(.title == "rename var")] | length')" -eq 0 ]
  [ "$(hidden_json | jq -r '.dimensions.code_quality.blocking')" = "1" ]
}

@test "an item raised in SEVERAL promotion rounds counts once (#1064)" {
  # otherwise the human-facing counter can report more raised than selected
  promo_fixtures
  jq '.round_changelists[1].summary.blocking = 1 | .round_changelists[1].summary.high = 1
      | .round_changelists[1].blocking = [.round_changelists[0].blocking[0]]' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.promotion.promoted')" = "1" ]
  echo "$output" | grep -q 'of which \*\*1\*\*'
  [ "$(hidden_json | jq '[.waived_low[] | select(.title == "rename var")] | length')" -eq 0 ]
}

@test "PROMOTION FIRST wins the exact-same-line collision (#1064)" {
  # the ordering only decides this case; with the promotion view losing, the
  # item would be kept as Low, then dropped, and the fixed defect would vanish
  # from the dossier entirely (blocking falls to 0)
  promo_fixtures
  jq '.round_changelists[0].blocking[0].line = 9' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.dimensions.code_quality.blocking')" = "1" ]
  [ "$(hidden_json | jq '[.waived_low[] | select(.title == "rename var")] | length')" -eq 0 ]
  [ "$(hidden_json | jq -r '.dimensions.code_quality.suggestions')" = "1" ]
}

@test "an UNPROMOTED Low re-reported at a drifted line is not double-listed (#1064)" {
  # the merged stream is deduped by [file,line,dimension,title], which line drift
  # defeats — so the cross-phase Low dedupe uses the same line-insensitive
  # identity as the drop, or every waived Low the promotion panel re-finds is
  # listed twice and counted twice
  promo_fixtures
  jq '.round_changelists[0].suggestions = [
       {"priority":"Low","dimension":"code_quality","file":"app.py","line":26,"title":"extract helper","reviewers":["python-code-quality"]}]
      | .round_changelists[0].summary.low = 1' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq '[.waived_low[] | select(.title == "extract helper")] | length')" -eq 1 ]
  [ "$(hidden_json | jq -r '.dimensions.code_quality.suggestions')" = "1" ]
  [ "$(echo "$output" | grep -cE '^- .app\.py:.*\[code_quality\] extract helper')" -eq 1 ]
  # WHICH copy survives is user-visible (the bullet cites the line), and it is
  # decided by the PROMOTION-FIRST order feeding the reduce — pin it
  # sorted by unique_by([file,line,dimension,title]) BEFORE the reduce, so the
  # LOWER line precedes and the reduce keeps it
  [ "$(hidden_json | jq -r '.waived_low[] | select(.title=="extract helper") | .line')" = "20" ]
}

# ---- rendering details the PR body depends on (#1064) ----------------------

@test "a title containing an HTML comment terminator cannot truncate the block (#1064)" {
  # jq compact output does not escape '>', and the block lives inside an HTML
  # comment — so an unescaped '-->' in a reviewer title would close it early,
  # spilling JSON into the visible body and truncating the Approver's payload
  cat > "$BATS_TEST_TMPDIR/arrow.json" <<'EOF'
{"status":"CONVERGED","rounds":1,"repo_type":"go",
 "round_changelists":[{"round":1,"summary":{"critical":0,"high":0,"low":1,"blocking":0,"conflicts":0},
   "blocking":[],"suggestions":[{"priority":"Low","dimension":"tests","file":"a.go","line":3,
     "title":"diagram a --> b is unclear","reviewers":["r"]}]}],
 "final_changelist":{"summary":{"critical":0,"high":0,"low":1,"blocking":0,"conflicts":0}}}
EOF
  run zsh "$S" --status "$BATS_TEST_TMPDIR/arrow.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c '^<!-- review-dossier: .* -->$')" -eq 1 ]
  # still exactly one terminator on that line, and the payload still parses
  local body
  body=$(echo "$output" | grep '^<!-- review-dossier:' | sed -E 's/^<!-- review-dossier: (.*) -->$/\1/')
  [ "$(printf '%s' "$body" | grep -c -- '-->')" -eq 0 ]
  printf '%s' "$body" | jq -e . >/dev/null
  # and the escape is lossless — the reviewer's title survives round-tripping
  [ "$(printf '%s' "$body" | jq -r '.waived_low[0].title')" = "diagram a --> b is unclear" ]
}

@test "the hidden block is the LAST line, preceded by a blank one (#1064)" {
  # open-pr appends this output verbatim into the PR body, and $(...) strips the
  # trailing newline the section ends with — so the separator is re-emitted
  promo_fixtures
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  echo "$output" | tail -1 | grep -q '^<!-- review-dossier:'
  [ -z "$(echo "$output" | tail -2 | head -1)" ]
}

@test "a zero-promoted round omits the parenthetical; conflicts still render (#1064)" {
  promo_fixtures
  jq '.round_changelists[0].summary.conflicts = 2' "$BST" > "$BST.x"
  mv "$BST.x" "$BST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  # exact line: no "(0 promoted)" noise on rounds that promoted nothing
  echo "$output" | grep -q '^- Promotion round 2: 0 blocking, 0 suggestion(s) logged$'
  echo "$output" | grep -q '^- Round 1: 1 blocking, 2 conflict(s), 2 suggestion(s) logged$'
}

@test "the waived-suggestions heading is omitted entirely when nothing is waived (#1064)" {
  promo_fixtures
  # raise BOTH selected Lows, so the exclusion empties the waived set
  jq '.round_changelists[0].blocking += [{"priority":"High","dimension":"code_quality","file":"app.py","line":21,
        "title":"extract helper","promoted":true,"reviewers":["python-code-quality"]}]
      | .round_changelists[0].summary.blocking = 2 | .round_changelists[0].summary.high = 2' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq '.waived_low | length')" -eq 0 ]
  [ "$(echo "$output" | grep -c 'Waived suggestions')" -eq 0 ]
  [ "$(hidden_json | jq -r '.promotion.promoted')" = "2" ]
  # the section still renders its tail
  echo "$output" | grep -q '^\*\*Reviewers:\*\*'
}

@test "a non-CONVERGED promotion phase does not claim its items were cleared (#1064)" {
  promo_fixtures
  jq '.status = "BUDGET_EXHAUSTED"' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c 'and cleared')" -eq 0 ]
  echo "$output" | grep -q 'the phase exited \*\*BUDGET_EXHAUSTED\*\*'
}

@test "promotion-phase suggestions and reviewers join the merged dossier (#1064)" {
  promo_fixtures
  jq '.round_changelists[1].suggestions = [{"priority":"Low","dimension":"performance","file":"app.py",
        "line":40,"title":"cache the lookup","reviewers":["python-performance-reviewer"]}]
      | .round_changelists[1].summary.low = 1' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  # a NEW Low logged during the promotion pass is genuinely waived
  [ "$(hidden_json | jq '[.waived_low[] | select(.title == "cache the lookup")] | length')" -eq 1 ]
  # ...and a reviewer seen only in the promotion phase is in the union
  hidden_json | jq -e '.reviewers | index("python-performance-reviewer")' >/dev/null
  echo "$output" | grep -qE '^\*\*Reviewers:\*\*.*python-performance-reviewer'
}

@test "repo_type falls back to the promotion phase when the blocking one lacks it (#1064)" {
  promo_fixtures
  jq 'del(.repo_type)' "$BST" > "$BST.x"
  mv "$BST.x" "$BST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.repo_type')" = "python" ]
}

@test "an EMPTY selection is REFUSED — the pair should not have been passed (#1064)" {
  # Same rule the LOOP applies to its own --promote (which also refuses []):
  # selecting nothing is contracted to skip the sub-loop entirely, so an empty
  # array here means no phase ran and the pair should not have been passed.
  # Emitting selected:0 would assert in the durable audit record that a phase
  # happened which by contract cannot have.
  promo_fixtures
  echo '[]' > "$SEL"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- 'not a NON-EMPTY JSON array of objects'
}

# ---- remaining input refusals (#1064) --------------------------------------

@test "--promoted must be a non-empty regular file (absent / empty / directory)" {
  promo_fixtures
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- '--promoted must be a non-empty regular file'
  : > "$BATS_TEST_TMPDIR/empty.json"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$BATS_TEST_TMPDIR/empty.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- '--promoted must be a non-empty regular file'
  mkdir -p "$BATS_TEST_TMPDIR/pdir"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$BATS_TEST_TMPDIR/pdir"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- '--promoted must be a non-empty regular file'
}

@test "usage: every flag rejects a missing, flag-shaped or EMPTY value (exit 2)" {
  promo_fixtures
  # each flag swallowing the next FLAG
  run zsh "$S" --promotion-status --promoted "$SEL"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- '--promotion-status requires a value'
  run zsh "$S" --promoted --promotion-status "$PST"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- '--promoted requires a value'
  # each flag as the LAST argument
  run zsh "$S" --status
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- '--status requires a value'
  run zsh "$S" --status "$BST" --promotion-status
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- '--promotion-status requires a value'
  # an EMPTY value on ANY flag: without the guard each falls through to a
  # DIFFERENT wrong error that blames a flag the caller did pass
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted ""
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- '--promoted requires a non-empty value'
  run zsh "$S" --status ""
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- '--status requires a non-empty value'
  run zsh "$S" --status "$BST" --promotion-status "" --promoted "$SEL"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- '--promotion-status requires a non-empty value'
}

@test "usage: unknown flag, stray positional and --help (exit 2 / 2 / 0)" {
  # a mistyped --promotion_status must NOT degrade to a single-phase dossier
  run zsh "$S" --promotion_status foo
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'unknown flag'
  run zsh "$S" --status "$ST" extra
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'unexpected argument'
  run zsh "$S" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '--promotion-status FILE --promoted FILE'
}

# ---- the stamp is the whole verdict (#1064) --------------------------------

@test "an UNSTAMPED promotion blocker promotes nothing — the stamp IS the verdict (#1064)" {
  # The single most load-bearing rule of #1064: the drop set comes from the
  # engine's own `promoted: true` stamp, never from re-matching here. Every other
  # fixture stamps whatever it puts in the promotion phase's blocking[], so both
  # `select(.promoted == true)` filters could be deleted with the suite green.
  # Here the sub-loop independently re-finds an unrelated High at the SAME
  # [file, dimension, title] as a waived Low: nothing was promoted, so that Low
  # is still genuinely un-actioned and must stay waived.
  promo_fixtures
  jq 'del(.round_changelists[0].blocking[0].promoted)' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.promotion.promoted')" = "0" ]
  [ "$(hidden_json | jq '[.waived_low[] | select(.title == "rename var")] | length')" -eq 1 ]
  echo "$output" | grep -qE '^- .app\.py:.*\[code_quality\] rename var'
  # ...and the round line carries no promoted parenthetical
  echo "$output" | grep -q '^- Promotion round 1: 1 blocking, 0 suggestion(s) logged$'
}

@test "an explicit promoted:false is treated exactly as unstamped (#1064)" {
  promo_fixtures
  jq '.round_changelists[0].blocking[0].promoted = false' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.promotion.promoted')" = "0" ]
  [ "$(hidden_json | jq '[.waived_low[] | select(.title == "rename var")] | length')" -eq 1 ]
}

@test "the round-count guard is exit 1 with EMPTY stdout — the third failure path" {
  # completes the trio: count / build / render all fail closed with a diagnostic
  echo '{"status":"CONVERGED","rounds":1,"round_changelists":true}' > "$BATS_TEST_TMPDIR/count.json"
  run --separate-stderr zsh "$S" --status "$BATS_TEST_TMPDIR/count.json"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q 'could not count rounds'
}

@test "rounds falls back to the changelist length in BOTH phases (#1064)" {
  # every fixture sets `rounds` explicitly AND equal to the changelist length,
  # so neither the field nor the fallback is distinguishable today
  promo_fixtures
  jq 'del(.rounds)' "$BST" > "$BST.x"
  mv "$BST.x" "$BST"
  jq 'del(.rounds)' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  [ "$(jq -r 'has("rounds")' "$BST")" = "false" ]
  [ "$(jq -r 'has("rounds")' "$PST")" = "false" ]
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.rounds')" = "4" ]
  [ "$(hidden_json | jq -r '.promotion.rounds')" = "2" ]
  echo "$output" | grep -q '\*\*4 round(s)\*\*'
  # not the string "null" anywhere in the prose
  [ "$(echo "$output" | grep -c 'null round(s)')" -eq 0 ]
}

@test "an all-clean run renders every core lens clean and an em-dash reviewer line" {
  # the commonest real dossier — a loop that ran and found nothing — and the only
  # input that reaches the `length==0 then "—"` reviewers branch
  cat > "$BATS_TEST_TMPDIR/clean.json" <<'EOF'
{"status":"CONVERGED","rounds":1,"repo_type":"python",
 "round_changelists":[{"round":1,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},
   "blocking":[],"suggestions":[]}],
 "final_changelist":{"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0}}}
EOF
  run zsh "$S" --status "$BATS_TEST_TMPDIR/clean.json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -q '^\*\*Reviewers:\*\* —$'
  for d in bugs security performance code_quality tests; do
    echo "$output" | grep -q "^- \`$d\` — ✓ clean (reviewed, no findings)$"
  done
  [ "$(hidden_json | jq '.waived_low | length')" -eq 0 ]
  [ "$(echo "$output" | grep -c 'Waived suggestions')" -eq 0 ]
}

# ---- round-3 coverage: the deliberately-chosen behaviours (#1064) -----------

@test "the reviewer union actually DEDUPES a repeated reviewer" {
  # $ST names three distinct reviewers, so `| unique` could be deleted with the
  # suite green. Repeat one across findings and pin the exact sorted array.
  jq '.round_changelists[0].suggestions[0].reviewers = ["python-code-quality","python-bug-hunter"]' \
    "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -c '.reviewers')" = '["python-bug-hunter","python-code-quality","python-security-reviewer"]' ]
}

@test "a reviewer named ONLY by a dropped duplicate still reaches the dossier (#1064)" {
  # Both the promoted-item exclusion and the cross-phase dedupe drop whole
  # findings; the union is taken from the widest set precisely so a reviewer
  # whose only finding was dropped does not vanish from the audit record.
  promo_fixtures
  # the promoted (and therefore EXCLUDED) Low gets a reviewer of its own, so the
  # exclusion half of the rule is genuinely pinned: with the union taken from the
  # post-exclusion set this reviewer disappears
  jq '.round_changelists[0].suggestions[0].reviewers = ["python-exclusion-only"]' "$BST" > "$BST.x"
  mv "$BST.x" "$BST"
  # the promotion phase re-reports the same waived Low at a drifted line, naming
  # a reviewer the blocking-phase copy does not
  jq '.round_changelists[0].suggestions = [
       {"priority":"Low","dimension":"code_quality","file":"app.py","line":26,
        "title":"extract helper","reviewers":["python-second-opinion"]}]
      | .round_changelists[0].summary.low = 1' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  # the finding itself is deduped to one entry...
  [ "$(hidden_json | jq '[.waived_low[] | select(.title == "extract helper")] | length')" -eq 1 ]
  # ...but BOTH reviewers survive
  hidden_json | jq -e '.reviewers | index("python-second-opinion")' >/dev/null
  hidden_json | jq -e '.reviewers | index("python-code-quality")' >/dev/null
  echo "$output" | grep -qE '^\*\*Reviewers:\*\*.*python-second-opinion'
  # and the reviewer whose ONLY finding was promoted-and-excluded survives too
  hidden_json | jq -e '.reviewers | index("python-exclusion-only")' >/dev/null
  echo "$output" | grep -qE '^\*\*Reviewers:\*\*.*python-exclusion-only'
}

@test "SINGLE-phase output still lists a same-title Low re-reported at a drifted line" {
  # The cross-phase dedupe is gated on a promotion phase being present. The same
  # collision is reachable within ONE phase (a Low re-reported by a later round
  # after a fix shifted it), where the pre-#1064 script listed BOTH — so an
  # ungated reduce would silently change every ordinary PR's dossier.
  cat > "$BATS_TEST_TMPDIR/drift1.json" <<'EOF'
{"status":"CONVERGED","rounds":2,"repo_type":"python",
 "round_changelists":[
  {"round":1,"summary":{"critical":0,"high":0,"low":1,"blocking":0,"conflicts":0},"blocking":[],
   "suggestions":[{"priority":"Low","dimension":"code_quality","file":"app.py","line":9,"title":"rename var","reviewers":["q"]}]},
  {"round":2,"summary":{"critical":0,"high":0,"low":1,"blocking":0,"conflicts":0},"blocking":[],
   "suggestions":[{"priority":"Low","dimension":"code_quality","file":"app.py","line":14,"title":"rename var","reviewers":["q"]}]}],
 "final_changelist":{"summary":{"critical":0,"high":0,"low":1,"blocking":0,"conflicts":0}}}
EOF
  run zsh "$S" --status "$BATS_TEST_TMPDIR/drift1.json"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq '[.waived_low[] | select(.title == "rename var")] | length')" -eq 2 ]
  [ "$(hidden_json | jq -r '.dimensions.code_quality.suggestions')" = "2" ]
  [ "$(echo "$output" | grep -cE '^- .app\.py:(9|14). \[code_quality\] rename var')" -eq 2 ]
}

@test "the rounds FIELD wins over the changelist length, and sums across phases" {
  # every other fixture sets rounds EQUAL to the changelist count, so the field
  # and the fallback are indistinguishable; a resumed loop reports more rounds
  # than it kept changelists
  promo_fixtures
  jq '.rounds = 5' "$BST" > "$BST.x"
  mv "$BST.x" "$BST"
  jq '.rounds = 3' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.rounds')" = "8" ]
  [ "$(hidden_json | jq -r '.promotion.rounds')" = "3" ]
  echo "$output" | grep -q '\*\*8 round(s)\*\*'
}

@test "repo_type PREFERS the blocking phase over the promotion phase (#1064)" {
  # the fallback is tested elsewhere; this pins the precedence, which an
  # inversion would otherwise satisfy
  promo_fixtures
  jq '.repo_type = "go"' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.repo_type')" = "python" ]
}

@test "a zero-round blocking phase contributes no round lines and sums to the promotion rounds" {
  promo_fixtures
  echo '{"status":"SKIPPED","rounds":0,"round_changelists":[]}' > "$BST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.rounds')" = "2" ]
  echo "$output" | grep -q '\*\*2 round(s)\*\*'
  [ "$(echo "$output" | grep -c '^- Round ')" -eq 0 ]
  [ "$(echo "$output" | grep -c '^- Promotion round ')" -eq 2 ]
}

@test "the section's static scaffolding headings are present" {
  # only ever asserted negatively before, so deleting a heading while keeping
  # its bullets would ship an unlabelled PR body
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^\*\*Per round\*\*$'
  echo "$output" | grep -q '^\*\*Dimensions reviewed\*\* (#449 lenses)$'
  echo "$output" | grep -q '^\*\*Waived suggestions\*\* (Low — logged, never blocking)$'
  grep_needle="_Machine-readable dossier below is consumed by the Approver"
  echo "$output" | grep -q "$grep_needle"
}

@test "a whitespace-only input hits the 'yielded no JSON value' guard, not a later stage" {
  # reachable, not merely belt-and-braces: a file of whitespace passes [[ -f && -s ]],
  # jq then runs the filter zero times and exits 0 with empty output. Without the
  # guard the empty capture reaches --argjson and the failure is relabelled as a
  # later stage, mis-blaming the input.
  promo_fixtures
  printf '   \n' > "$BATS_TEST_TMPDIR/ws.json"
  run zsh "$S" --status "$BATS_TEST_TMPDIR/ws.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- '--status yielded no JSON value'
  run zsh "$S" --status "$BST" --promotion-status "$BATS_TEST_TMPDIR/ws.json" --promoted "$SEL"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- '--promotion-status yielded no JSON value'
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$BATS_TEST_TMPDIR/ws.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- '--promoted file yielded no JSON value'
}

@test "the -s (empty file) arm is enforced for BOTH status inputs" {
  # the realistic failure: the loop created the scratch file but never wrote it,
  # or a > redirection truncated it. Only the -f half was covered before.
  promo_fixtures
  : > "$BATS_TEST_TMPDIR/empty-status.json"
  run zsh "$S" --status "$BATS_TEST_TMPDIR/empty-status.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- '--status must be a non-empty regular file'
  run zsh "$S" --status "$BATS_TEST_TMPDIR/nonexistent.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- '--status must be a non-empty regular file'
  run zsh "$S" --status "$BST" --promotion-status "$BATS_TEST_TMPDIR/empty-status.json" --promoted "$SEL"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- '--promotion-status must be a non-empty regular file'
}

@test "promotion.promoted counts KEYS raised, never distinct stamped findings (#1064)" {
  # Found by dogfooding this change: the overlay is one-to-one per ROUND, not per
  # phase, so across rounds ONE key can be re-matched to a succession of
  # different findings as the text it names moves. Counting stamped identities
  # then exceeds `selected` and renders "selected 1, of which 2 were raised".
  promo_fixtures
  # the same promoted key raises a DIFFERENTLY-TITLED finding in each round
  jq '.round_changelists[1].summary.blocking = 1 | .round_changelists[1].summary.high = 1
      | .round_changelists[1].blocking = [{"priority":"High","dimension":"code_quality",
          "file":"app.py","line":12,"title":"rename var (reworded next round)",
          "promoted":true,"reviewers":["python-code-quality"]}]' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  # one pick only
  jq -c '[ .[0] ]' "$SEL" > "$SEL.x"
  mv "$SEL.x" "$SEL"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.promotion.selected')" = "1" ]
  # two stamped identities, but ONE key — so 1, never 2
  [ "$(hidden_json | jq -r '.promotion.promoted')" = "1" ]
  # and the prose can never read "of which 2" against "selected 1"
  echo "$output" | grep -q 'selected \*\*1\*\* waived suggestion(s), of which \*\*1\*\*'
}

@test "promotion.promoted is 0 when no stamped identity shares a picked key's file+dimension" {
  promo_fixtures
  jq '.round_changelists[0].blocking[0].file = "unrelated.py"' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.promotion.promoted')" = "0" ]
}

# --- #1435: a residue PR must not claim its open blockers were fixed ---------

@test "#1435 a residue terminal reports blockers STILL OPEN, never 'found & fixed'" {
  # The shape a CONVERGED_WITH_RESIDUE run leaves, built so it cannot pass under
  # the two mutations a narrower fixture misses. TWO dimensions carry open
  # blockers with DIFFERENT found counts (bugs: 3 found / 1 open, tests: 1/1), so
  # neither "report the run-wide total for every dimension" nor "swap the found
  # and open numbers" renders the same text.
  jq '.status = "CONVERGED_WITH_RESIDUE"
      | .round_changelists[0].blocking = [
          {"priority":"Critical","dimension":"bugs","file":"app.py","line":1,"title":"None deref","reviewers":["python-bug-hunter"]},
          {"priority":"High","dimension":"bugs","file":"app.py","line":5,"title":"second bug","reviewers":["python-bug-hunter"]},
          {"priority":"High","dimension":"bugs","file":"app.py","line":9,"title":"third bug","reviewers":["python-bug-hunter"]},
          {"priority":"High","dimension":"tests","file":"t.py","line":2,"title":"weak assertion","reviewers":["python-test-reviewer"]}]
      | .final_changelist.summary = {critical:0,high:2,low:0,blocking:2,conflicts:0}
      | .final_changelist.blocking = [
          {"priority":"High","dimension":"bugs","file":"app.py","line":9,"title":"third bug","reviewers":["python-bug-hunter"]},
          {"priority":"High","dimension":"tests","file":"t.py","line":2,"title":"weak assertion","reviewers":["python-test-reviewer"]}]' \
    "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'exited \*\*CONVERGED_WITH_RESIDUE\*\*'
  # the two numbers are different AND in the documented order, so swapping them
  # cannot render the same line
  echo "$output" | grep -q -- '- `bugs` — 3 blocking found, 1 still open (filed as follow-up issue(s))'
  echo "$output" | grep -q -- '- `tests` — 1 blocking found, 1 still open (filed as follow-up issue(s))'
  # the section says residue outright, so it cannot be read as an ordinary run
  echo "$output" | grep -q 'This PR carries residue'
  echo "$output" | grep -q '\*\*2\*\* blocking finding(s) still open'
  # ...and the machine-readable half carries per-dimension counts, so a CLEAN
  # lens is proven not to inherit the run-wide total. Asserted BEFORE the
  # negative below, which uses `run` and would reset $output — the very variable
  # hidden_json reads.
  [ "$(hidden_json | jq -r '.dimensions.bugs.open')" = "1" ]
  [ "$(hidden_json | jq -r '.dimensions.tests.open')" = "1" ]
  [ "$(hidden_json | jq -r '.dimensions.security.open')" = "0" ]
  # the false claim must be gone from those dimensions, not merely joined
  run ! grep -qE -- '- `(bugs|tests)` — [0-9]+ blocking found & fixed' <<< "$output"
}

@test "#1435 open comes from the BLOCKING phase, so a promotion phase can neither zero nor inflate it" {
  # §3.5 routes a residue run through the promotion offer BEFORE the residue
  # branch, so a promotion status is the normal companion, not a corner. Keyed on
  # the terminal phase alone, the promotion phase (which converges clean) would
  # supply the counts, every dimension would read 0, and the body would pair a
  # Summary naming the residue ending with a dossier asserting the blockers were
  # fixed. The source is the BLOCKING phase specifically — residue is
  # single-phase, so that is the only phase whose leftovers can be "still open"
  # AND the only one the residue branch files from. Summing the promotion phase
  # in would let a renderable-but-not-clean one (#1064 keeps that shape) inflate
  # a count the very next line calls filed; the second half below pins that.
  jq '.status = "CONVERGED_WITH_RESIDUE"
      | .final_changelist.summary = {critical:0,high:1,low:0,blocking:1,conflicts:0}
      | .final_changelist.blocking = [{"priority":"High","dimension":"bugs","file":"app.py","line":9,
                                       "title":"still open","reviewers":["python-bug-hunter"]}]' \
    "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  local PST="$BATS_TEST_TMPDIR/promo-status.json" SEL="$BATS_TEST_TMPDIR/promoted.json"
  cat > "$PST" <<'EOF'
{"status":"CONVERGED","rounds":1,"max_rounds":3,"repo_type":"python",
 "round_changelists":[{"round":1,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},
                       "blocking":[],"suggestions":[]}],
 "final_changelist":{"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},"blocking":[],"suggestions":[]}}
EOF
  # a real selection — `--promoted` is contracted as a NON-EMPTY array, since a
  # phase with nothing picked never runs the sub-loop at all
  printf '[{"file":"app.py","line":9,"dimension":"code_quality","title":"rename var"}]' > "$SEL"
  run zsh "$S" --status "$ST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- `bugs` — 1 blocking found, 1 still open (filed as follow-up issue(s))'
  # `status` still reports the terminal PHASE by the #1064 rule, so the residue
  # paragraph is what keeps the section from contradicting its own dimension line
  echo "$output" | grep -q 'This PR carries residue'
  echo "$output" | grep -q 'CONVERGED_WITH_RESIDUE'
  [ "$(hidden_json | jq -r '.dimensions.bugs.open')" = "1" ]

  # ...and a promotion phase carrying its OWN leftover blockers does not inflate
  # it. #1064 renders such a phase rather than hiding it, so this is supported
  # input; summing it in would report 2 still open and call both filed.
  jq '.status = "BUDGET_EXHAUSTED"
      | .final_changelist.summary = {critical:0,high:1,low:0,blocking:1,conflicts:0}
      | .final_changelist.blocking = [{"priority":"High","dimension":"code_quality","file":"app.py","line":3,
                                       "title":"promotion leftover","reviewers":["python-code-quality"]}]' \
    "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$ST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.dimensions.bugs.open')" = "1" ]
  [ "$(hidden_json | jq -r '.dimensions.code_quality.open')" = "0" ]
  echo "$output" | grep -q '[*][*]1[*][*] blocking finding(s) still open'
}

@test "#1435 a PR-OPENING status is required: an escalation is refused, not rendered as residue" {
  # An escalation's final_changelist carries blockers by construction, so `open`
  # would fire and the residue paragraph would assert — in the audit record —
  # that a PR was opened, that the blockers were non-critical and fix-touched,
  # and that each was filed. Three claims nothing established. Refusing the
  # operand closes the whole class rather than one sentence, and it is the same
  # guard build-residue-issues.zsh applies to the same operand.
  local st
  for st in ESCALATE_NO_CONVERGENCE BUDGET_EXHAUSTED ESCALATE_CONFLICT ERROR STALE_FINDINGS AWAITING_FIX; do
    jq --arg s "$st" '.status = $s
        | .final_changelist.summary = {critical:0,high:1,low:0,blocking:1,conflicts:0}
        | .final_changelist.blocking = [{"priority":"High","dimension":"bugs","file":"app.py","line":9,
                                         "title":"still open","reviewers":["python-bug-hunter"]}]' \
      "$ST" > "$ST.x"
    mv "$ST.x" "$ST"
    run --separate-stderr zsh "$S" --status "$ST"
    [ "$st: $status" = "$st: 1" ]
    # the diagnostic echoes what it got, so an arm printing a constant is excluded
    echo "$stderr" | grep -q "($st)"
    echo "$stderr" | grep -q 'non-PR-opening or non-terminal status'
    # ...and NOTHING is emitted, so a half-rendered section can never reach a PR body
    [ -z "$output" ]
  done
}

@test "#1435 the guard is a DENY-list, so SKIPPED and a status-less file still no-op cleanly" {
  # An allow-list of the two PR-opening terminals would turn two working no-ops
  # into hard failures: `--no-review` leaves SKIPPED, and a zero-round status has
  # nothing to render either way. The invariant that motivates the guard is "an
  # escalation never opens a PR", so that is what it tests.
  jq '.status = "SKIPPED" | .round_changelists = [] | .final_changelist = null' "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  run --separate-stderr zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  jq 'del(.status) | .round_changelists = [] | .final_changelist = null' "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  run --separate-stderr zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "#1435 residue is single-phase, so 'filed' needs no per-phase qualifier" {
  # The loop never declares residue in a promotion sub-loop (#1435), and every
  # other non-clean promotion ending escalates and opens no PR — so every open
  # blocker that reaches the dossier came from the blocking phase, the one the
  # residue branch files from. This pins that the rendering says so plainly
  # rather than hedging, which is what the Approver policy reads.
  jq '.status = "CONVERGED_WITH_RESIDUE"
      | .final_changelist.summary = {critical:0,high:1,low:0,blocking:1,conflicts:0}
      | .final_changelist.blocking = [{"priority":"High","dimension":"bugs","file":"app.py","line":9,
                                       "title":"blocking-phase residue","reviewers":["python-bug-hunter"]}]' \
    "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  local PST="$BATS_TEST_TMPDIR/promo-status.json" SEL="$BATS_TEST_TMPDIR/promoted.json"
  # a CONVERGED promotion phase — the only shape that can accompany a PR
  cat > "$PST" <<'EOF'
{"status":"CONVERGED","rounds":1,"max_rounds":3,"repo_type":"python",
 "round_changelists":[{"round":1,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},
                       "blocking":[],"suggestions":[]}],
 "final_changelist":{"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},"blocking":[],"suggestions":[]}}
EOF
  printf '[{"file":"app.py","line":9,"dimension":"code_quality","title":"rename var"}]' > "$SEL"
  run zsh "$S" --status "$ST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'This PR carries residue'
  echo "$output" | grep -q 'each was filed as a labelled follow-up issue'
  echo "$output" | grep -q -- '- `bugs` — 1 blocking found, 1 still open (filed as follow-up issue(s))'
  [ "$(hidden_json | jq -r '.dimensions.bugs.open')" = "1" ]
  # ...and the rendering is the SAME whether or not a promotion phase ran — which
  # is what "no per-phase qualifier" actually means. A tautological negative on a
  # deleted phrase would pass regardless of behaviour; this reds on a qualifier
  # of ANY spelling.
  local two_phase_line; two_phase_line="$(echo "$output" | grep -- '- `bugs` —')"
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -- '- `bugs` —')" = "$two_phase_line" ]
}

@test "#1435 a CONVERGED terminal is unchanged: open is 0 and the wording still says fixed" {
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- `bugs` — 1 blocking found & fixed, 0 suggestion(s)'
  [ "$(hidden_json | jq -r '.dimensions.bugs.open')" = "0" ]
  # every dimension, not just the one with findings — a clean lens must not
  # acquire a spurious open count
  hidden_json | jq -e '[.dimensions[].open] | all(. == 0)' >/dev/null
  # ...and the residue paragraph is ABSENT. Without this negative the paragraph's
  # gate is unpinned: opening it up would put "This PR carries residue … with 0
  # blocking finding(s) still open … each was filed as a labelled follow-up
  # issue" — three false claims — into the audit record of EVERY ordinary PR,
  # with every positive assertion in this file still green.
  run ! grep -q 'This PR carries residue' <<< "$output"
}

@test "#1435 the residue paragraph names a terminal, so it must never appear on a converged run" {
  # The paragraph hardcodes the terminal name, so its presence IS a claim about
  # the ending. Pinned separately from the wording above because the gate and the
  # text are different mutations.
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  run ! grep -q 'CONVERGED_WITH_RESIDUE' <<< "$output"

  # ...and the same on the two-phase shape, where `status` reports the promotion
  # phase and a count-gated paragraph would key off the wrong thing
  local PST="$BATS_TEST_TMPDIR/promo-clean.json" SEL="$BATS_TEST_TMPDIR/sel-clean.json"
  cat > "$PST" <<'EOF'
{"status":"CONVERGED","rounds":1,"max_rounds":3,"repo_type":"python",
 "round_changelists":[{"round":1,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},
                       "blocking":[],"suggestions":[]}],
 "final_changelist":{"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},"blocking":[],"suggestions":[]}}
EOF
  printf '[{"file":"app.py","line":9,"dimension":"code_quality","title":"rename var"}]' > "$SEL"
  run zsh "$S" --status "$ST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  run ! grep -q 'This PR carries residue' <<< "$output"
}

@test "#1435 a NON-residue terminal with leftover blockers still says 'found & fixed'" {
  # The second `$isresidue` consumer — the per-dimension "still open" arm — pinned
  # from the negative side. Its positive above fires on a residue status that also
  # has leftover blockers, so both halves of `($isresidue and open > 0)` are true
  # there and that test cannot tell which one carries the arm. This fixture makes
  # them disagree: a status that is NOT the residue terminal whose final changelist
  # nevertheless still carries two blocking findings.
  #
  # That is the exact input a count-gated arm gets wrong. Gated on the count alone
  # it would tell the Approver that two findings are "still open (filed as
  # follow-up issue(s))" on a run that filed nothing — a fabricated audit trail
  # pointing at issues that do not exist. The `& fixed` assertions below are the
  # positive half of the same pin: it is not enough that the false line be absent,
  # the true line has to be what replaced it.
  #
  # Both `$isresidue` gates are in the blast radius: the arm's own, and the one on
  # `$openblk` that keeps the machine-readable `open` at 0. Dropping EITHER is
  # caught here — the second because `open` would then be 1 for two dimensions,
  # which the hidden-block assertion reads directly.
  jq '.round_changelists[0].blocking = [
          {"priority":"Critical","dimension":"bugs","file":"app.py","line":1,"title":"None deref","reviewers":["python-bug-hunter"]},
          {"priority":"High","dimension":"bugs","file":"app.py","line":9,"title":"third bug","reviewers":["python-bug-hunter"]},
          {"priority":"High","dimension":"tests","file":"t.py","line":2,"title":"weak assertion","reviewers":["python-test-reviewer"]}]
      | .final_changelist.summary = {critical:0,high:2,low:0,blocking:2,conflicts:0}
      | .final_changelist.blocking = [
          {"priority":"High","dimension":"bugs","file":"app.py","line":9,"title":"third bug","reviewers":["python-bug-hunter"]},
          {"priority":"High","dimension":"tests","file":"t.py","line":2,"title":"weak assertion","reviewers":["python-test-reviewer"]}]' \
    "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'exited \*\*CONVERGED\*\*'
  echo "$output" | grep -q -- '- `bugs` — 2 blocking found & fixed'
  echo "$output" | grep -q -- '- `tests` — 1 blocking found & fixed'
  # the machine-readable half agrees — `open` is 0 despite a non-empty
  # final_changelist.blocking. Read BEFORE the `run !` below, which reassigns the
  # $output that hidden_json parses.
  hidden_json | jq -e '[.dimensions[].open] | all(. == 0)' >/dev/null
  # ...and the residue paragraph stays away too: it reports that same total, so a
  # loosened gate would print "0 blocking finding(s) still open" beside two open
  # ones.
  run ! grep -q 'still open (filed as follow-up issue(s))' <<< "$output"
}

@test "#1435 a NON-ENDING --promotion-status is refused, and an escalating ENDING still renders" {
  # `_refuse_non_ending_promotion` was invoked by no test at all. Surviving
  # mutation: delete its call, or drop AWAITING_FIX from its case list. In
  # production `$terminal` is the PROMOTION status whenever the pair is passed,
  # and AWAITING_FIX is exactly what the sub-loop overwrites its status file with
  # on every intermediate round — so a stale one renders `status: "AWAITING_FIX"`
  # in the machine-readable dossier and prints "the phase exited **AWAITING_FIX**"
  # directly above "the loop ended **CONVERGED_WITH_RESIDUE**": the same
  # self-contradiction in the audit record the sibling --status guard prevents.
  #
  # The deny-list is NARROW on purpose (#1064): an escalating ENDING must still
  # render, so the second half pins the carve-out. Without it the obvious "fix"
  # — widening the list to every non-converged status — passes the first half
  # while silently deleting the promotion dossier #1064 contracts.
  promo_fixtures
  local st
  for st in AWAITING_FIX STALE_FINDINGS ERROR; do
    jq --arg s "$st" '.status = $s' "$PST" > "$PST.x"
    mv "$PST.x" "$PST"
    run --separate-stderr zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
    [ "$st: $status" = "$st: 1" ]
    # the diagnostic echoes what it got, so an arm printing a constant is excluded
    echo "$stderr" | grep -q "($st)"
    echo "$stderr" | grep -q 'is not an ending'
    # ...and NOTHING is emitted, so a half-rendered section never reaches a PR body
    [ -z "$output" ]
  done

  # the carve-out: an escalating ENDING is renderable, and says so
  jq '.status = "BUDGET_EXHAUSTED"' "$PST" > "$PST.x"
  mv "$PST.x" "$PST"
  run zsh "$S" --status "$BST" --promotion-status "$PST" --promoted "$SEL"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'BUDGET_EXHAUSTED'
}
