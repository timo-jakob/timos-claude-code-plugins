#!/usr/bin/env bats
#
# Behavioral tests for build-dossier.zsh (#563): the PR "Review dossier" — the
# durable audit record for why auto-merge happened. Human-readable for
# reviewers; a hidden, dimension-tagged JSON block the Approver re-ingests. A PR
# with no loop (--no-review) must get no dossier at all (epic #557).

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
  echo "$output" | grep -q 'python-bug-hunter'
  # waived Low suggestion is logged, not a blocker
  echo "$output" | grep -q 'rename var'
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
}

@test "internal: invalid status JSON is exit 1, not a crash" {
  echo 'not json' > "$BATS_TEST_TMPDIR/bad.json"
  run zsh "$S" --status "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 1 ]
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
