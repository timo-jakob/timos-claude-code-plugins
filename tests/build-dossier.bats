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
  # a dossier carries NO promotion object and no promotion prose (#3131): the
  # promotion phase is retired, and a promotion:{…} key would read to the
  # Approver as "a promotion phase ran"
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

# ---- input refusals (#1064) -------------------------------------------------

@test "the retired promotion flags are refused like any other unknown option (exit 2)" {
  # #3131: no run produces a promotion phase any more, so --promotion-status and
  # --promoted are gone, with no atomic-pair message of their own
  echo '[{"file":"app.py","line":9,"dimension":"code_quality","title":"rename var"}]' > "$BATS_TEST_TMPDIR/sel.json"
  local flag
  for flag in --promotion-status --promoted; do
    run --separate-stderr zsh "$S" --status "$ST" "$flag" "$BATS_TEST_TMPDIR/sel.json"
    [ "$flag: $status" = "$flag: 2" ]
    [ -z "$output" ]
    [ "$stderr" = "unknown flag: $flag" ]
  done
}

@test "a promoted stamp in the status changes nothing — no promotion paragraph, no round suffix" {
  # #3131: the dossier no longer reads the `promoted` stamp, so a stamped
  # blocker renders exactly as an unstamped one
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  local plain="$output"
  jq '.round_changelists[0].blocking[0].promoted = true' "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  [ "$output" = "$plain" ]
  echo "$output" | grep -q '^- Round 1: 1 blocking, 1 suggestion(s) logged$'
  [ "$(echo "$output" | grep -c 'promot')" -eq 0 ]
}

@test "usage: a flag that swallows the next FLAG as its value is refused (exit 2)" {
  run zsh "$S" --status --help
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

@test "the hidden block is ONE line — the Approver parses it as such" {
  run zsh "$S" --status "$ST"
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
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  echo "$output" | tail -1 | grep -q '^<!-- review-dossier:'
  [ -z "$(echo "$output" | tail -2 | head -1)" ]
}

@test "a round line renders its conflicts, in its exact form (#1064)" {
  jq '.round_changelists[0].summary.conflicts = 2' "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^- Round 1: 1 blocking, 2 conflict(s), 1 suggestion(s) logged$'
  echo "$output" | grep -q '^- Round 2: 0 blocking, 0 suggestion(s) logged$'
}

# ---- remaining input refusals (#1064) --------------------------------------

@test "usage: --status rejects a missing or EMPTY value (exit 2)" {
  # the flag as the LAST argument
  run zsh "$S" --status
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- '--status requires a value'
  # an EMPTY value: without the guard it falls through to the bare usage line
  run zsh "$S" --status ""
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- '--status requires a non-empty value'
}

@test "usage: unknown flag, stray positional and --help (exit 2 / 2 / 0)" {
  run zsh "$S" --status "$ST" --bogus foo
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'unknown flag: --bogus'
  run zsh "$S" --status "$ST" extra
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'unexpected argument'
  run zsh "$S" --help
  [ "$status" -eq 0 ]
  [ "$output" = "usage: build-dossier.zsh --status FILE" ]
}

# ---- the stamp is the whole verdict (#1064) --------------------------------

@test "the round-count guard is exit 1 with EMPTY stdout — the third failure path" {
  # completes the trio: count / build / render all fail closed with a diagnostic
  echo '{"status":"CONVERGED","rounds":1,"round_changelists":true}' > "$BATS_TEST_TMPDIR/count.json"
  run --separate-stderr zsh "$S" --status "$BATS_TEST_TMPDIR/count.json"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q 'could not count rounds'
}

@test "rounds falls back to the changelist length (#1064)" {
  # every fixture sets `rounds` explicitly AND equal to the changelist length,
  # so neither the field nor the fallback is distinguishable today
  jq 'del(.rounds)' "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  [ "$(jq -r 'has("rounds")' "$ST")" = "false" ]
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.rounds')" = "2" ]
  echo "$output" | grep -q '\*\*2 round(s)\*\*'
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

@test "a same-title Low re-reported at a drifted line is listed at both lines" {
  # A Low re-reported by a later round after a fix shifted it is listed at
  # both lines: the dossier dedupes on [file, line, dimension, title] only.
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

@test "the rounds FIELD wins over the changelist length" {
  # every other fixture sets rounds EQUAL to the changelist count, so the field
  # and the fallback are indistinguishable; a resumed loop reports more rounds
  # than it kept changelists
  jq '.rounds = 5' "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -r '.rounds')" = "5" ]
  echo "$output" | grep -q '\*\*5 round(s)\*\*'
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
  printf '   \n' > "$BATS_TEST_TMPDIR/ws.json"
  run zsh "$S" --status "$BATS_TEST_TMPDIR/ws.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- '--status yielded no JSON value'
}

@test "the -s (empty file) arm is enforced for --status" {
  # the realistic failure: the loop created the scratch file but never wrote it,
  # or a > redirection truncated it. Only the -f half was covered before.
  : > "$BATS_TEST_TMPDIR/empty-status.json"
  run zsh "$S" --status "$BATS_TEST_TMPDIR/empty-status.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- '--status must be a non-empty regular file'
  run zsh "$S" --status "$BATS_TEST_TMPDIR/nonexistent.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- '--status must be a non-empty regular file'
}

# --- #2599: CONVERGED is the only PR-opening status, and open is always 0 -----

@test "backstop: a CONVERGED_WITH_RESIDUE --status is refused like an escalation, with nothing on stdout" {
  # #2580 retired the residue terminal; a status file left over from before it,
  # or one written by hand, must not produce a PR whose dossier reports open > 0
  # (#2599). The shape is the one a residue run left: rounds ran, a blocker open.
  jq '.status = "CONVERGED_WITH_RESIDUE"
      | .final_changelist.summary = {critical:0,high:1,low:0,blocking:1,conflicts:0}
      | .final_changelist.blocking = [{"priority":"High","dimension":"bugs","file":"app.py","line":9,
                                       "title":"still open","reviewers":["python-bug-hunter"]}]' \
    "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  run --separate-stderr zsh "$S" --status "$ST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -qF '(CONVERGED_WITH_RESIDUE)'
  echo "$stderr" | grep -q 'did not end CONVERGED'
}

@test "backstop: a looped --status must be CONVERGED (allow-list), and the three no-op shapes still no-op" {
  # An ALLOW-list (#2599): every status that ran a round and is not CONVERGED is
  # refused, including one the loop has never written — a deny-list would let it
  # through by default. The diagnostic echoes what it got, so an arm printing a
  # constant is excluded.
  local st
  for st in ESCALATE_NO_CONVERGENCE BUDGET_EXHAUSTED ESCALATE_CONFLICT ERROR STALE_FINDINGS AWAITING_FIX \
            SOMETHING_THE_LOOP_NEVER_WROTE; do
    jq --arg s "$st" '.status = $s' "$ST" > "$ST.x"
    mv "$ST.x" "$ST"
    run --separate-stderr zsh "$S" --status "$ST"
    [ "$st: $status" = "$st: 1" ]
    echo "$stderr" | grep -qF "($st)"
    [ -z "$output" ]
  done
  # a status-less file that ran a round is refused too
  jq 'del(.status)' "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  run --separate-stderr zsh "$S" --status "$ST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -qF '(no status)'

  # the three no-op shapes: SKIPPED (--no-review), a zero-round status, and a
  # status-less zero-round file. Each exits 0 and prints nothing.
  jq '.status = "SKIPPED" | .round_changelists = [] | .final_changelist = null' "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  run --separate-stderr zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  jq '.status = "ESCALATE_NO_CONVERGENCE" | .rounds = 0 | .round_changelists = []' "$ST" > "$ST.x"
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

@test "backstop: a CONVERGED status still carrying an open blocker is refused (open > 0)" {
  # The count is read from the final changelist whatever the
  # status (#2599), so a CONVERGED label cannot launder an open blocker into a
  # dossier. Two open blockers, so the diagnostic must echo the real count.
  jq '.final_changelist.summary = {critical:0,high:2,low:0,blocking:2,conflicts:0}
      | .final_changelist.blocking = [
          {"priority":"High","dimension":"bugs","file":"app.py","line":9,"title":"third bug","reviewers":["python-bug-hunter"]},
          {"priority":"High","dimension":"tests","file":"t.py","line":2,"title":"weak assertion","reviewers":["python-test-reviewer"]}]' \
    "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  run --separate-stderr zsh "$S" --status "$ST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q 'still carries 2 open blocker(s)'
  echo "$stderr" | grep -qF '(open > 0)'
}

@test "#2926 backstop: a CONVERGED status whose final round's gate only selected is refused" {
  # a PR opens only on a whole-suite green on the final tree: a selected-only
  # attestation that reached CONVERGED must not become a dossier
  jq '.history = [{round:1, gate:{scope:"full", attested:true}}, {round:2, gate:{scope:"selected", attested:true}}]' \
    "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  run --separate-stderr zsh "$S" --status "$ST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "final round's gate only SELECTED tests"
}

@test "#2926 control: a full final gate, a selected EARLIER round, or no gate record still renders" {
  local h
  for h in '[{round:1, gate:{scope:"selected", attested:true}}, {round:2, gate:{scope:"full", attested:false}}]' \
           '[{round:1, gate:null}]' '[]'; do
    jq ".history = $h" "$ST" > "$BATS_TEST_TMPDIR/s.json"
    run zsh "$S" --status "$BATS_TEST_TMPDIR/s.json"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '^## Review dossier'
  done
}

@test "every emitted dossier reports open 0 in every dimension" {
  # The epic's invariant (#2599): the dossier never reports open > 0 on a PR the
  # loop opened. The key stays in the hidden block because the Approver
  # backstops read it (#2586, #2587), so it must be present AND zero.
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  hidden_json | jq -e '(.dimensions | length) > 0 and ([.dimensions[] | has("open")] | all)' >/dev/null
  hidden_json | jq -e '[.dimensions[].open] | all(. == 0)' >/dev/null
  echo "$output" | grep -q -- '- `bugs` — 1 blocking found & fixed, 0 suggestion(s)'
}

@test "the rendered section never claims residue or a still-open blocker" {
  # The residue paragraph and the per-dimension "still open (filed as follow-up
  # issue(s))" arm are gone (#2599).
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  run grep -qE 'This PR carries residue|still open|CONVERGED_WITH_RESIDUE' <<< "$output"
  [ "$status" -eq 1 ]
}

# --- #1921: risk-demoted findings in the PR body --------------------------------

# a two-round status whose rounds demote findings: the same identity in both
# rounds (the later record must win), one only in round 1, one ordinary waived
# suggestion, and a title carrying a pipe, a backtick and a newline
demoted_status() {
  cat > "$ST" <<'EOF'
{"status":"CONVERGED","rounds":2,"max_rounds":5,"repo_type":"claude-plugin",
 "round_changelists":[
   {"round":1,"summary":{"critical":0,"high":0,"low":3,"blocking":0,"conflicts":0,"risk_demoted":2},
    "blocking":[],
    "suggestions":[
      {"priority":"Low","dimension":"tests","file":"tests/a.bats","line":10,"title":"mutation drops the check","demoted":true,
       "risk_assessment":{"p":0.07,"p_why":"round-one view","impact":0.7,"impact_why":"a hang","risk":0.049,"risk_thousandths":49,"threshold":"0.05","threshold_thousandths":50}},
      {"priority":"Low","dimension":"bugs","file":"src/b.zsh","line":5,"title":"a | pipe, a `tick`\nand a forged line","demoted":true,
       "risk_assessment":{"p":0.01,"p_why":"rare | really","impact":1.0,"impact_why":"a false `green`","risk":0.01,"risk_thousandths":10,"threshold":"0.05","threshold_thousandths":50}},
      {"priority":"Low","dimension":"code_quality","file":"src/c.zsh","line":9,"title":"rename var","reviewers":["claude-plugin-prose-logic"]}]},
   {"round":2,"summary":{"critical":0,"high":0,"low":1,"blocking":0,"conflicts":0,"risk_demoted":1},
    "blocking":[],
    "suggestions":[
      {"priority":"Low","dimension":"tests","file":"tests/a.bats","line":10,"title":"mutation drops the check","demoted":true,
       "risk_assessment":{"p":0.04,"p_why":"round-two view","impact":0.7,"impact_why":"a hang","risk":0.028,"risk_thousandths":28,"threshold":"0.05","threshold_thousandths":50}}]}
 ],
 "final_changelist":{"summary":{"critical":0,"high":0,"low":1,"blocking":0,"conflicts":0},"blocking":[],"suggestions":[]}}
EOF
}

@test "#1921 AC9 demoted findings get their own paragraph and table above the waived list" {
  demoted_status
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qxF -- "**Demoted by the risk threshold (\`corner_case_risk_threshold\` = \`0.05\`):** these findings cleared a reviewer's blocking bar, but each one's risk (probability × impact) is below the threshold, so the loop logged them as suggestions and did not fix them."
  [ "$(echo "$output" | grep -c '[Pp]romot')" -eq 0 ]
  echo "$output" | grep -qxF -- '| finding | round | p | impact | risk | why |'
  # one row per identity, the LATEST round's record winning
  [ "$(echo "$output" | grep -c -- '^| `mutation drops the check`')" -eq 1 ]
  echo "$output" | grep -qxF -- '| `mutation drops the check` — `tests/a.bats:10` | 2 | 0.04 | 0.7 | 0.028 | round-two view; a hang |'
  # untrusted text is neutralised: newline and backticks stripped, pipes escaped
  echo "$output" | grep -qxF -- '| `a \| pipe, a tick and a forged line` — `src/b.zsh:5` | 1 | 0.01 | 1.0 | 0.01 | rare \| really; a false green |'
  [ "$(echo "$output" | grep -c '^and a forged line')" -eq 0 ]
  # the table sits above the waived list, which no longer lists a demoted finding
  local tline wline
  tline=$(echo "$output" | grep -n -- '^\*\*Demoted by the risk threshold' | cut -d: -f1)
  wline=$(echo "$output" | grep -n -- '^\*\*Waived suggestions\*\*' | cut -d: -f1)
  [ "$tline" -lt "$wline" ]
  echo "$output" | grep -qE '^- .src/c\.zsh:9. \[code_quality\] rename var'
  [ "$(echo "$output" | grep -cE '^- `(tests/a\.bats|src/b\.zsh):')" -eq 0 ]
}

@test "#1921 AC9 the hidden block carries risk_demoted, and its waived_low still holds the demoted findings for the Approver" {
  demoted_status
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq -c '.risk_demoted')" = \
    '[{"file":"tests/a.bats","line":10,"dimension":"tests","title":"mutation drops the check","round":2,"p":0.04,"impact":0.7,"risk_thousandths":28},{"file":"src/b.zsh","line":5,"dimension":"bugs","title":"a | pipe, a `tick`\nand a forged line","round":1,"p":0.01,"impact":1.0,"risk_thousandths":10}]' ]
  # the Approver folds waived_low into its risk register, so a demoted finding
  # must not leave it; only the RENDERED waived list omits it (tested above)
  [ "$(hidden_json | jq -c '[.waived_low[].title] | sort')" = \
    '["a | pipe, a `tick`\nand a forged line","mutation drops the check","rename var"]' ]
}

@test "#1921 AC9 without a demoted item the dossier is byte-identical — stamps alone change nothing" {
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  local plain="$output"
  jq '.round_changelists[0].blocking[0].risk_assessment = {p: 0.5, impact: 0.7, risk: 0.35, risk_thousandths: 350, threshold: "0.05", threshold_thousandths: 50}
      | .round_changelists[0].summary.risk_demoted = 0
      | .round_changelists[0].suggestions[0].demoted = false' "$ST" > "$BATS_TEST_TMPDIR/stamped.json"
  run zsh "$S" --status "$BATS_TEST_TMPDIR/stamped.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$plain" ]
  hidden_json | jq -e 'has("risk_demoted") | not' >/dev/null
}

@test "#1921 AC9 a finding whose LATEST occurrence is not demoted is not listed — here, kept blocking in a later round" {
  demoted_status
  # round 2 re-raises "mutation drops the check" and it is kept blocking this time
  jq '.round_changelists[1].suggestions = []
      | .round_changelists[1].blocking = [{"priority":"High","dimension":"tests","file":"tests/a.bats","line":10,
          "title":"Mutation drops the  check","risk_assessment":{"p":0.6,"impact":0.7,"risk":0.42,"risk_thousandths":420,"threshold":"0.05","threshold_thousandths":50}}]' \
    "$ST" > "$BATS_TEST_TMPDIR/st.json"
  run zsh "$S" --status "$BATS_TEST_TMPDIR/st.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c -- '^| `mutation drops the check`')" -eq 0 ]
  [ "$(hidden_json | jq -c '[.risk_demoted[].title]')" = '["a | pipe, a `tick`\nand a forged line"]' ]
}

@test "#1921 AC9 blocking in round 1, demoted in round 2: counted a suggestion, kept in waived_low; a same-titled finding at another line stays apart" {
  cat > "$BATS_TEST_TMPDIR/st.json" <<'EOF'
{"status":"CONVERGED","rounds":2,"repo_type":"claude-plugin",
 "round_changelists":[
   {"round":1,"summary":{"blocking":1,"low":1,"conflicts":0},
    "blocking":[{"priority":"High","dimension":"bugs","file":"a.zsh","line":10,"title":"unquoted expansion"}],
    "suggestions":[{"priority":"Low","dimension":"bugs","file":"a.zsh","line":50,"title":"unquoted expansion"}]},
   {"round":2,"summary":{"blocking":0,"low":1,"conflicts":0},"blocking":[],
    "suggestions":[{"priority":"Low","dimension":"bugs","file":"a.zsh","line":10,"title":"unquoted expansion","demoted":true,
      "risk_assessment":{"p":0.01,"p_why":"w","impact":0.4,"impact_why":"w","risk":0.004,"risk_thousandths":4,"threshold":"0.05","threshold_thousandths":50}}]}],
 "final_changelist":{"summary":{"blocking":0},"blocking":[],"suggestions":[]}}
EOF
  run zsh "$S" --status "$BATS_TEST_TMPDIR/st.json"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq '.dimensions.bugs.blocking')" -eq 0 ]
  [ "$(hidden_json | jq -c '[.waived_low[].line] | sort')" = '[10,50]' ]
  [ "$(hidden_json | jq -c '[.risk_demoted[].line]')" = '[10]' ]
  # the line-50 waived suggestion is not hidden by the line-10 demotion
  echo "$output" | grep -qE '^- `a\.zsh:50` \[bugs\] unquoted expansion'
}

@test "#1921 AC9 a demoted finding re-assessed and kept blocking counts as blocking found & fixed" {
  # demoted in round 1, re-assessed above the threshold and kept blocking at
  # the same line in round 2, then fixed: counted as blocking found & fixed
  cat > "$BATS_TEST_TMPDIR/st2.json" <<'EOF'
{"status":"CONVERGED","rounds":2,"repo_type":"claude-plugin",
 "round_changelists":[
   {"round":1,"summary":{"blocking":0,"low":1,"conflicts":0},"blocking":[],
    "suggestions":[{"priority":"Low","dimension":"bugs","file":"a.zsh","line":10,"title":"unquoted expansion","demoted":true,
      "risk_assessment":{"p":0.01,"p_why":"w","impact":0.4,"impact_why":"w","risk":0.004,"risk_thousandths":4,"threshold":"0.05","threshold_thousandths":50}}]},
   {"round":2,"summary":{"blocking":1,"low":0,"conflicts":0},"suggestions":[],
    "blocking":[{"priority":"High","dimension":"bugs","file":"a.zsh","line":10,"title":"unquoted expansion"}]}],
 "final_changelist":{"summary":{"blocking":0},"blocking":[],"suggestions":[]}}
EOF
  run zsh "$S" --status "$BATS_TEST_TMPDIR/st2.json"
  [ "$status" -eq 0 ]
  [ "$(hidden_json | jq '.dimensions.bugs.blocking')" -eq 1 ]
  [ "$(hidden_json | jq '.waived_low | length')" -eq 0 ]
}

# One status JSON from a list of rounds, each round a JSON array of items written
# compactly as {l: line, t: title, pri: "High"|"Low", dem: true} — every item in
# file a.zsh, dimension bugs. A demoted item carries a risk stamp.
window_status() {  # $@ = one JSON array per round
  local rounds="[]" r n=0
  for r in "$@"; do
    n=$(( n + 1 ))
    rounds=$(jq -c --argjson rs "$rounds" --argjson n "$n" '
      [ .[] | { priority: .pri, dimension: "bugs", file: "a.zsh", line: .l, title: (.t // "unquoted expansion") }
              + (if .dem then { demoted: true, risk_assessment: { p: 0.01, p_why: "w", impact: 0.4,
                   impact_why: "w", risk: 0.004, risk_thousandths: 4, threshold: "0.05",
                   threshold_thousandths: 50 } } else {} end) ] as $its
      | $rs + [ { round: $n, summary: { blocking: 0, low: 0, conflicts: 0 },
                  blocking: [ $its[] | select(.priority == "High") ],
                  suggestions: [ $its[] | select(.priority == "Low") ] } ]' <<< "$r")
  done
  jq -n --argjson rs "$rounds" '{status: "CONVERGED", rounds: ($rs | length), repo_type: "claude-plugin",
    round_changelists: $rs, final_changelist: {summary: {blocking: 0}, blocking: [], suggestions: []}}' \
    > "$BATS_TEST_TMPDIR/ws.json"
}

@test "#1921 AC9 following a demoted finding across rounds: null-line wildcard, nearest record, the 10-line boundary, one count per finding" {
  # the row format: rounds (one JSON array each, joined by @@) => jq assertion on the hidden block
  local rows=(
    # a null line on either side continues the record: demoted then kept blocking and fixed
    '[{"l":null,"pri":"Low","dem":true}]@@[{"l":null,"pri":"High"}] => (has("risk_demoted") | not) and .dimensions.bugs.blocking == 1'
    # exactly 10 lines on continues it; 11 does not
    '[{"l":10,"pri":"Low","dem":true}]@@[{"l":20,"pri":"High"}] => (has("risk_demoted") | not) and .dimensions.bugs.blocking == 1'
    '[{"l":10,"pri":"Low","dem":true}]@@[{"l":21,"pri":"High"}] => [.risk_demoted[].line] == [10]'
    # moved within the window: ONE finding, counted once, as its latest occurrence
    '[{"l":10,"pri":"Low","dem":true}]@@[{"l":13,"pri":"High"}] => .dimensions.bugs.blocking == 1 and .dimensions.bugs.suggestions == 0'
    # drift in in-window steps past 10 lines in total: still one finding
    '[{"l":10,"pri":"High"}]@@[{"l":18,"pri":"High"}]@@[{"l":26,"pri":"Low","dem":true}] => .dimensions.bugs.blocking == 0 and ([.waived_low[].line] == [26])'
    # the NEAREST record is continued: 22 continues 25 (3 away), not the demoted 15 (7 away)
    '[{"l":15,"pri":"Low","dem":true},{"l":25,"pri":"Low"}]@@[{"l":22,"pri":"High"}] => [.risk_demoted[].line] == [15]'
    # one exact identity in two records: two findings, two entries
    '[{"l":10,"pri":"Low","dem":true}]@@[{"l":15,"pri":"High"},{"l":10,"pri":"Low","dem":true}] => .dimensions.bugs.blocking == 1 and .dimensions.bugs.suggestions == 1'
    # ...and when the second record was never demoted, it is not lost either
    '[{"l":10,"pri":"Low","dem":true}]@@[{"l":5,"pri":"High"},{"l":10,"pri":"High"}] => .dimensions.bugs.blocking == 2'
  )
  local row spec want
  for row in "${rows[@]}"; do
    want="${row##* => }"
    spec="${row%% => *}"
    local -a parts=()
    IFS=$'\n' read -r -d '' -a parts < <(printf '%s' "${spec//@@/$'\n'}"; printf '\0') || true
    window_status "${parts[@]}"
    run zsh "$S" --status "$BATS_TEST_TMPDIR/ws.json"
    [ "$status" -eq 0 ]
    hidden_json | jq -e "$want" >/dev/null || { echo "row failed: $row"; hidden_json | jq -c '{dimensions, waived_low, risk_demoted}'; return 1; }
  done
}

@test "#1921 AC9 a demoted finding respelled in a later round, in place or moved, is listed once — in the demoted table, never also as waived" {
  local rounds
  for rounds in \
    '[{"l":10,"t":"Weak assertion","pri":"Low","dem":true}]@@[{"l":10,"t":"weak assertion","pri":"Low","dem":true}]' \
    '[{"l":10,"t":"Weak assertion","pri":"Low","dem":true}]@@[{"l":13,"t":"weak  assertion","pri":"Low","dem":true}]'; do
    window_status "${rounds%%@@*}" "${rounds##*@@}"
    run zsh "$S" --status "$BATS_TEST_TMPDIR/ws.json"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c '^| `.*` — `a\.zsh:')" -eq 1 ]
    [ "$(echo "$output" | grep -c '^- `a\.zsh:')" -eq 0 ]
    [ "$(hidden_json | jq '.risk_demoted | length')" -eq 1 ]
    [ "$(hidden_json | jq -c '[.waived_low[] | [.line, .title]] == [.risk_demoted[] | [.line, .title]]')" = "true" ]
  done
}

# --- #2577: extension-bar demotions in the PR body ------------------------------

# round 1 demotes under the base (0.04); round 6, an extension round, demotes a
# second finding under the extension bar (0.10)
ext_demoted_status() {  # $1 = include the base-bar round (1) or not (0)
  local base_rc='{"round":1,"summary":{"critical":0,"high":0,"low":1,"blocking":0,"conflicts":0,"risk_demoted":1},"blocking":[],"suggestions":[{"priority":"Low","dimension":"tests","file":"tests/a.bats","line":10,"title":"mutation drops the check","demoted":true,"risk_assessment":{"p":0.03,"p_why":"base view","impact":0.4,"impact_why":"a weak test","risk":0.012,"risk_thousandths":12,"threshold":"0.04","threshold_thousandths":40}}]}'
  local ext_rc='{"round":6,"summary":{"critical":0,"high":0,"low":1,"blocking":0,"conflicts":0,"risk_demoted":1},"blocking":[],"suggestions":[{"priority":"Low","dimension":"bugs","file":"app.py","line":2000,"title":"stale cache never invalidated","demoted":true,"risk_assessment":{"p":0.15,"p_why":"rare input","impact":0.4,"impact_why":"a wrong message","risk":0.06,"risk_thousandths":60,"threshold":"0.10","threshold_thousandths":100,"bar":"extension"}}]}'
  local rcs
  if [ "$1" = 1 ]; then rcs="[$base_rc,$ext_rc]"; else rcs="[$ext_rc]"; fi
  jq -n --argjson rcs "$rcs" '{status:"CONVERGED",rounds:6,max_rounds:5,repo_type:"claude-plugin",round_changelists:$rcs,
    final_changelist:{summary:{critical:0,high:0,low:1,blocking:0,conflicts:0},blocking:[],suggestions:[]}}' > "$ST"
}

@test "#2577 AC6 extension-bar demotions only: the heading names the extension bar, each row is marked" {
  ext_demoted_status 0
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qxF -- "**Demoted by the extension bar (effective threshold = \`0.10\`):** these findings cleared a reviewer's blocking bar, but each one's risk (probability × impact) is below the threshold, so the loop logged them as suggestions and did not fix them."
  echo "$output" | grep -qxF -- '| `stale cache never invalidated` — `app.py:2000` | 6 | 0.15 | 0.4 | 0.06 (extension bar, threshold 0.10) | rare input; a wrong message |'
  [ "$(echo "$output" | grep -c corner_case_risk_threshold)" -eq 0 ]
  [ "$(hidden_json | jq -c '.risk_demoted')" = \
    '[{"file":"app.py","line":2000,"dimension":"bugs","title":"stale cache never invalidated","round":6,"p":0.15,"impact":0.4,"risk_thousandths":60,"bar":"extension","threshold":"0.10"}]' ]
}

@test "#2577 AC6 extension-bar demotions in two rounds at different thresholds: the heading names the latest round's" {
  local r6='{"round":6,"summary":{"critical":0,"high":0,"low":1,"blocking":0,"conflicts":0,"risk_demoted":1},"blocking":[],"suggestions":[{"priority":"Low","dimension":"bugs","file":"app.py","line":2000,"title":"stale cache never invalidated","demoted":true,"risk_assessment":{"p":0.15,"p_why":"rare input","impact":0.4,"impact_why":"a wrong message","risk":0.06,"risk_thousandths":60,"threshold":"0.10","threshold_thousandths":100,"bar":"extension"}}]}'
  local r7='{"round":7,"summary":{"critical":0,"high":0,"low":1,"blocking":0,"conflicts":0,"risk_demoted":1},"blocking":[],"suggestions":[{"priority":"Low","dimension":"bugs","file":"lib.py","line":5,"title":"retry loop logs twice","demoted":true,"risk_assessment":{"p":0.2,"p_why":"flaky net","impact":0.5,"impact_why":"noisy log","risk":0.1,"risk_thousandths":100,"threshold":"0.15","threshold_thousandths":150,"bar":"extension"}}]}'
  jq -n --argjson rcs "[$r6,$r7]" '{status:"CONVERGED",rounds:7,max_rounds:5,repo_type:"claude-plugin",round_changelists:$rcs, final_changelist:{summary:{critical:0,high:0,low:1,blocking:0,conflicts:0},blocking:[],suggestions:[]}}' > "$ST"
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF -- "**Demoted by the extension bar (effective threshold = \`0.15\`):**"
  [ "$(echo "$output" | grep -cF -- 'effective threshold = `0.10`')" -eq 0 ]
}

@test "#2577 AC6 mixed: the heading keeps the base threshold, and only the extension row is marked" {
  ext_demoted_status 1
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF -- "**Demoted by the risk threshold (\`corner_case_risk_threshold\` = \`0.04\`):**"
  echo "$output" | grep -qxF -- '| `mutation drops the check` — `tests/a.bats:10` | 1 | 0.03 | 0.4 | 0.012 | base view; a weak test |'
  echo "$output" | grep -qxF -- '| `stale cache never invalidated` — `app.py:2000` | 6 | 0.15 | 0.4 | 0.06 (extension bar, threshold 0.10) | rare input; a wrong message |'
  # the base-bar entry keeps its #1921 shape in the hidden block
  [ "$(hidden_json | jq -c '[.risk_demoted[] | keys | length]')" = '[8,10]' ]
}

# --- #3131: the docs name only the plain --status invocation ------------------

flat_doc() { tr '\n' ' ' < "$1" | tr -s ' '; }

@test "#3131 the dossier docs name only the plain --status invocation, never the retired pair" {
  local ri="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  local op="$REPO_ROOT/development/skills/open-pr/SKILL.md"
  local arch="$REPO_ROOT/ARCHITECTURE.md"
  local f
  for f in "$ri" "$op" "$arch"; do
    run grep -nE -- '--promotion-status|--promoted( |`|$)' "$f"
    [ "$f: $status" = "$f: 1" ]
  done
  grep -qF 'The dossier is always the plain `--status` invocation.' <<< "$(flat_doc "$ri")"
  grep -qF 'The dossier is always the plain `--status` invocation:' <<< "$(flat_doc "$op")"
  grep -qF 'The once-only rule is about **appended output**, not processes: never append two dossier outputs (two hidden blocks) to one body.' <<< "$(flat_doc "$op")"
  grep -qF '`build-dossier.zsh` no longer reads the stamp: the dossier dropped the promotion phase (#3131).' <<< "$(flat_doc "$arch")"
  grep -qF 'so both flags are refused as unknown options (exit 2), and the dossier neither prints a promotion paragraph nor follows items across two phases.' <<< "$(flat_doc "$arch")"
}
