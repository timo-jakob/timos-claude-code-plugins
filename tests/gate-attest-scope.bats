#!/usr/bin/env bats
#
# Behavioural tests for the gate scope rule and the per-round gate record in
# resolve-story-loop.zsh (#1973). Pinned here:
#   * a gate's scope is the scope_mode of the round it precedes: a
#     `selected:<id>` --gate-attest skips the loop's own gate on a --resume into
#     a DELTA round, and NEVER on a --resume into the closing full sweep, where
#     --test-cmd runs; a bare <id> is #981's attestation, unchanged;
#   * each history[] entry carries `gate` — {scope, attested, wall_s, slowest, jobs}
#     from the loop's own run-gate.zsh run (attested:false) or from
#     --gate-summary (attested:true), else null — while `rounds` stays an
#     integer; --gate-summary never decides a skip on its own, but a green
#     full summary of the attested tree lifts the .selected-attest backstop;
#   * the loop never selects: --test-cmd runs exactly as given, in step and hook
#     mode alike, and CI's script-tests workflow runs the gate with no selection.
#
# The fixture follows resolve-story-loop-step.bats: a real git repo, detection
# stubbed, findings supplied per round. --test-cmd 'false' is the discriminator
# — it would exit ERROR (1) if it ran.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/resolve-story-loop.zsh"
  TIDS="$REPO_ROOT/development/skills/resolve-issue/scripts/git-tree-id.zsh"

  STUB="$BATS_TEST_TMPDIR/detect.sh"
  printf '#!/usr/bin/env bash\necho "$DETECT_LANGS_JSON"\n' > "$STUB"
  chmod +x "$STUB"

  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  echo base > "$R/README.md"
  # the loop's own `.review/` artifacts are ignored, as in this repo — so a
  # round's bookkeeping never moves the tree identity a held attestation names
  printf '.review/\n' > "$R/.gitignore"
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" branch -M main
  echo "print(1)" > "$R/app.py"

  WD="$BATS_TEST_TMPDIR/wd"
  F="$BATS_TEST_TMPDIR/findings.json"
  ST="$BATS_TEST_TMPDIR/status.json"
  ACCT="$BATS_TEST_TMPDIR/acct.json"
  CRIT='[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"T","description":"d","reviewer":"r"}]'

  # a --test-cmd that prints a run-gate.zsh summary (12 files, so `slowest`
  # must keep 10, sorted), records that it ran and with what argv, and passes
  GATE_CMD="$BATS_TEST_TMPDIR/gate.sh"
  cat > "$GATE_CMD" <<'EOF'
#!/usr/bin/env bash
echo ran >> "$BATS_TEST_TMPDIR/gate-ran"
printf '%s\n' "$#" > "$BATS_TEST_TMPDIR/gate-argc"
echo "some suite chatter"
# a decoy summary BEFORE the real one: the LAST summary line is the gate's
jq -cn '{mode:"parallel", jobs:1, scope:"full", ok:1, not_ok:0, total:1, exit:0,
         wall_s:1, tap:"/tmp/d", tree:"", files:[]}'
jq -cn '{mode:"parallel", jobs:10, scope:"full", ok:5, not_ok:0, total:5, exit:0,
         wall_s:120.5, tap:"/tmp/t", tree:"",
         files:[range(1;13) | {file:"tests/f\(.).bats", wall_s:(. * 1.5)}]}'
EOF
  chmod +x "$GATE_CMD"

  # a session-side summary, as --gate-summary receives it
  SUMMARY="$BATS_TEST_TMPDIR/summary.json"
  jq -cn '{mode:"parallel", jobs:10, scope:"selected", ok:3, not_ok:0, total:3, exit:0,
           wall_s:40.25, tap:"/tmp/t", tree:"selected:abc",
           files:[{file:"tests/a.bats", wall_s:1}, {file:"tests/b.bats", wall_s:30}]}' > "$SUMMARY"

  # per-step timings the conductor passes for one round (#2197)
  TIMINGS="$BATS_TEST_TMPDIR/timings.json"
}

# one step-mode invocation: stdout (the status JSON) kept apart from stderr
step() {
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --status-file "$ST" "$@"
}

tid() { zsh "$TIDS" "$R"; }

# confirm every carried entry, so a round 2 after a blocker is not refused as
# CARRY-UNACCOUNTED (#1583)
confirm_carry() {  # $1 = round
  jq '[.[] | {file, dimension, title, confirmed:["r"], re_raised:[], unconfirmed:[]}]' \
    "$WD/verify-$1.json" > "$ACCT"
}

# round 1: one blocker, AWAITING_FIX. Then the in-session fix.
round1_then_fix() {
  printf '%s' "$CRIT" > "$F"
  step "$@"
  [ "$status" -eq 20 ]
  echo "x = 1" > "$R/fixed.py"
}

# round 2 (delta): clean, which promotes round 3 to the closing full sweep
round2_clean() {
  confirm_carry 2
  printf '[]' > "$F"
  step --resume --carry-accounting "$ACCT" "$@"
  [ "$status" -eq 20 ]
  [ "$(cat "$WD/.closing-sweep")" = "3" ]
}

# ---- the scope rule -------------------------------------------------------------

@test "a selected attestation SKIPS the gate on a --resume into a delta round" {
  round1_then_fix
  confirm_carry 2
  printf '[]' > "$F"
  step --resume --carry-accounting "$ACCT" --test-cmd 'false' --gate-attest "selected:$(tid)"
  [ "$status" -eq 20 ]
  contains "$stderr" "skipping the duplicate --test-cmd run"
  grep -q 'skipped the duplicate selected-gate run' "$WD/progress.md"
}

@test "a selected attestation into the closing full sweep is refused: --test-cmd RUNS" {
  round1_then_fix
  round2_clean
  printf '[]' > "$F"
  # the tree identity matches exactly — only the `selected:` scope stops the skip
  step --resume --test-cmd 'false' --gate-attest "selected:$(tid)"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.status' "$ST")" = "ERROR" ]
  contains "$stderr" "only a full gate can attest a full-scope round"
}

@test "control: a BARE attestation into the closing sweep still skips (#981 unchanged)" {
  round1_then_fix
  round2_clean
  printf '[]' > "$F"
  step --resume --test-cmd 'false' --gate-attest "$(tid)"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$ST")" = "CONVERGED" ]
}

@test "the closing sweep bought by a grant beyond the ceiling refuses a selected attestation too" {
  round1_then_fix --max-rounds 2
  round2_clean --max-rounds 2
  printf '[]' > "$F"
  step --resume --max-rounds 2 --test-cmd 'false' --gate-attest "selected:$(tid)"
  [ "$status" -eq 1 ]
  contains "$stderr" "only a full gate can attest a full-scope round"
}

@test "a BARE re-pass of a selected attestation into the promoted closing sweep still runs --test-cmd" {
  # the sweep a zero-blocker delta round promotes runs no new gate; a session
  # that rebuilds the held attestation from its bare T must not skip the full gate
  round1_then_fix
  local held; held="$(tid)"
  confirm_carry 2
  printf '[]' > "$F"
  step --resume --carry-accounting "$ACCT" --test-cmd 'false' --gate-attest "selected:$held"
  [ "$status" -eq 20 ]
  [ "$(cat "$WD/.closing-sweep")" = "3" ]
  [ "$(tid)" = "$held" ]            # the tree did not move: the bare id MATCHES
  printf '[]' > "$F"
  step --resume --test-cmd 'false' --gate-attest "$held"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.status' "$ST")" = "ERROR" ]
  contains "$stderr" "names a tree only a SELECTED gate run proved"
}

# the zero-blocker delta round after a selected gate: promotes the sweep with
# the selected id held, and returns it
selected_then_promoted() {
  round1_then_fix
  held="$(tid)"
  confirm_carry 2
  printf '[]' > "$F"
  step --resume --carry-accounting "$ACCT" --test-cmd 'false' --gate-attest "selected:$held"
  [ "$status" -eq 20 ]
  [ -s "$WD/.selected-attest" ]
}

@test "a green FULL gate's summary of the same tree lifts the backstop: the sweep skips the duplicate run" {
  # item 3: the session starts the full gate at the promoted sweep; its bare
  # tree equals the held selected hex because the tree did not move
  local held; selected_then_promoted
  jq -cn --arg t "$held" '{mode:"parallel", jobs:10, scope:"full", ok:9, not_ok:0, total:9, exit:0,
                           wall_s:300, tap:"/tmp/t", tree:$t, files:[]}' > "$BATS_TEST_TMPDIR/full.json"
  printf '[]' > "$F"
  step --resume --test-cmd 'false' --gate-attest "$held" --gate-summary "$BATS_TEST_TMPDIR/full.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$ST")" = "CONVERGED" ]
  contains "$stderr" "proves a green FULL run on the attested tree"
  [ ! -e "$WD/.selected-attest" ]
}

@test "a summary that does not prove a green full run of the same tree keeps the backstop" {
  local held s; selected_then_promoted
  # a selected summary, a red full one, and a full one of another tree
  for s in '{"scope":"selected","exit":0}' '{"scope":"full","exit":1}' '{"scope":"full","exit":0,"tree":"0000"}'; do
    jq -c --arg t "$held" '. + (if has("tree") then {} else {tree:$t} end) + {wall_s:1, files:[]}' <<< "$s" > "$BATS_TEST_TMPDIR/sum.json"
    printf '[]' > "$F"
    step --resume --test-cmd 'false' --gate-attest "$held" --gate-summary "$BATS_TEST_TMPDIR/sum.json"
    [ "$status" -eq 1 ]
    contains "$stderr" "names a tree only a SELECTED gate run proved"
  done
}

@test "a selected attestation of a DIFFERENT tree runs the gate (fail-closed)" {
  round1_then_fix
  confirm_carry 2
  printf '[]' > "$F"
  step --resume --carry-accounting "$ACCT" --test-cmd 'false' \
    --gate-attest "selected:0000000000000000000000000000000000000000"
  [ "$status" -eq 1 ]
  contains "$stderr" "does not match the working tree"
}

@test "an empty selected: attestation runs the gate (fail-closed)" {
  round1_then_fix
  confirm_carry 2
  printf '[]' > "$F"
  step --resume --carry-accounting "$ACCT" --test-cmd 'false' --gate-attest "selected:"
  [ "$status" -eq 1 ]
}

# ---- history[].gate -------------------------------------------------------------

@test "the loop's own run-gate.zsh gate is recorded for the round it precedes (attested:false, 10 slowest)" {
  round1_then_fix
  confirm_carry 2
  printf '[]' > "$F"
  step --resume --carry-accounting "$ACCT" --test-cmd "$GATE_CMD"
  [ "$status" -eq 20 ]
  [ -s "$BATS_TEST_TMPDIR/gate-ran" ]
  jq -e '.history[0].gate == null' "$ST"
  jq -e '.history[1].round == 2 and .history[1].gate.scope == "full"
         and .history[1].gate.attested == false and .history[1].gate.wall_s == 120.5
         and (.history[1].gate.slowest | length) == 10
         and .history[1].gate.slowest[0] == {file:"tests/f12.bats", wall_s:18}
         and .history[1].gate.slowest[9] == {file:"tests/f3.bats", wall_s:4.5}
         and .history[1].gate.jobs == 10
         and (.history[1].gate | keys) == ["attested","jobs","scope","slowest","wall_s"]' "$ST"
  # rounds stays the integer count; stdout is the status JSON alone
  jq -e '(.rounds | type) == "number" and .rounds == 2' "$ST"
  echo "$output" | jq -e '.status == "AWAITING_FIX"'
  # the gate's own stdout is mirrored to stderr, never onto the status channel
  contains "$stderr" "some suite chatter"
}

@test "an attested round takes its record from --gate-summary (attested:true)" {
  round1_then_fix
  confirm_carry 2
  printf '[]' > "$F"
  step --resume --carry-accounting "$ACCT" --test-cmd 'false' \
    --gate-attest "selected:$(tid)" --gate-summary "$SUMMARY"
  [ "$status" -eq 20 ]
  jq -e '.history[1].gate == {scope:"selected", attested:true, wall_s:40.25,
         slowest:[{file:"tests/b.bats", wall_s:30}, {file:"tests/a.bats", wall_s:1}], jobs:10}' "$ST"
}

@test "#2197 a summary with no jobs records jobs:null, never a guess" {
  jq -c 'del(.jobs)' "$SUMMARY" > "$BATS_TEST_TMPDIR/nojobs.json"
  round1_then_fix --gate-summary "$BATS_TEST_TMPDIR/nojobs.json"
  jq -e '.history[0].gate.jobs == null and .history[0].gate.wall_s == 40.25' "$ST"
}

@test "an attested round with no --gate-summary records null" {
  round1_then_fix
  confirm_carry 2
  printf '[]' > "$F"
  step --resume --carry-accounting "$ACCT" --test-cmd 'false' --gate-attest "selected:$(tid)"
  [ "$status" -eq 20 ]
  jq -e '.history[1].gate == null and (.history | length) == 2' "$ST"
}

@test "round 1 takes its record from the Step 3 gate's --gate-summary" {
  round1_then_fix --gate-summary "$SUMMARY"
  jq -e '.history[0].gate.attested == true and .history[0].gate.wall_s == 40.25' "$ST"
}

@test "--gate-summary never decides the skip: without an attestation the gate still runs" {
  round1_then_fix
  confirm_carry 2
  printf '[]' > "$F"
  step --resume --carry-accounting "$ACCT" --test-cmd 'false' --gate-summary "$SUMMARY"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.status' "$ST")" = "ERROR" ]
}

@test "when the loop runs its own gate, a --gate-summary is not recorded in its place" {
  round1_then_fix
  confirm_carry 2
  printf '[]' > "$F"
  step --resume --carry-accounting "$ACCT" --test-cmd "$GATE_CMD" --gate-summary "$SUMMARY"
  [ "$status" -eq 20 ]
  jq -e '.history[1].gate.attested == false and .history[1].gate.wall_s == 120.5' "$ST"
}

@test "a --gate-summary that is not a run-gate summary records null, with a note" {
  echo '{"not":"a summary"}' > "$BATS_TEST_TMPDIR/bogus.json"
  round1_then_fix --gate-summary "$BATS_TEST_TMPDIR/bogus.json"
  jq -e '.history[0].gate == null' "$ST"
  contains "$stderr" "no run-gate.zsh summary for the round 1 gate"
}

@test "an unreadable --gate-summary records null, with a note, and costs the round nothing" {
  round1_then_fix --gate-summary "$BATS_TEST_TMPDIR/no-such-file.json"
  jq -e '.history[0].gate == null and .status == "AWAITING_FIX"' "$ST"
  contains "$stderr" "--gate-summary is not a readable file"
}

@test "a re-invocation of the same round drops the earlier attempt's gate record" {
  round1_then_fix
  # an earlier attempt at round 2 recorded a gate; this attempt records none
  echo '{"scope":"full","attested":true,"wall_s":9,"slowest":[]}' > "$WD/gate-2.json"
  confirm_carry 2
  printf '[]' > "$F"
  step --resume --carry-accounting "$ACCT" --test-cmd 'true'
  [ "$status" -eq 20 ]
  jq -e '.history[1].gate == null' "$ST"
}

@test "a --test-cmd that is not run-gate.zsh records null, silently" {
  round1_then_fix
  confirm_carry 2
  printf '[]' > "$F"
  step --resume --carry-accounting "$ACCT" --test-cmd 'true'
  [ "$status" -eq 20 ]
  jq -e '.history[1].gate == null' "$ST"
  run ! grep -q 'no run-gate.zsh summary' <<< "$stderr"
}

@test "a fresh run clears a previous run's gate records from a re-used work-dir" {
  mkdir -p "$WD"
  echo '{"scope":"full","attested":false,"wall_s":1,"slowest":[]}' > "$WD/gate-1.json"
  printf '%s' "$CRIT" > "$F"
  step
  [ "$status" -eq 20 ]
  jq -e '.history[0].gate == null' "$ST"
}

# ---- the loop never selects ---------------------------------------------------------

@test "hook mode: the post-fix gate runs as given and is recorded for the NEXT round" {
  local crit="$BATS_TEST_TMPDIR/crit.json" n="$BATS_TEST_TMPDIR/n"
  printf '%s' "$CRIT" > "$crit"
  # round 1 finds the blocker, every later round finds nothing
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --status-file "$ST" \
    --review-cmd "if [ -e '$n' ]; then echo '[]' > \"\$REVIEW_FINDINGS\"; else touch '$n'; cp '$crit' \"\$REVIEW_FINDINGS\"; fi; \
if [ -s \"\${REVIEW_FIX_VERIFICATION:-}\" ] && [ \"\$(jq length \"\$REVIEW_FIX_VERIFICATION\")\" != 0 ]; then \
jq '[.[] | {file, dimension, title, confirmed:[\"r\"], re_raised:[], unconfirmed:[]}]' \"\$REVIEW_FIX_VERIFICATION\" > \"\$REVIEW_FINDINGS.carry.json\"; fi" \
    --fix-cmd "echo 'x = 2' > '$R/fixed.py'" --test-cmd "$GATE_CMD"
  [ "$status" -eq 0 ]
  jq -e '.status == "CONVERGED"' "$ST"
  jq -e '.history[0].gate == null and .history[1].gate.attested == false
         and .history[1].gate.scope == "full"' "$ST"
  # run exactly as given: no argument (no selection flag) was added
  [ "$(cat "$BATS_TEST_TMPDIR/gate-argc")" = "0" ]
}

# ---- per-step wall times (#2197) ------------------------------------------------
# Each history line carries step_wall_s {panel, decide, risk, fix}: from the
# conductor's --step-timings in step mode, from the loop's own clock in hook
# mode. Telemetry only — nothing unusable costs the round.

@test "#2197 step mode: --step-timings lands on the history line of the round as step_wall_s" {
  round1_then_fix
  jq -e '.history[0].step_wall_s == {panel:null, decide:null, risk:null, fix:null}' "$ST"
  confirm_carry 2
  printf '[]' > "$F"
  printf '{"panel":600,"decide":null,"risk":45,"fix":900}' > "$TIMINGS"
  step --resume --carry-accounting "$ACCT" --test-cmd 'true' --step-timings "$TIMINGS"
  [ "$status" -eq 20 ]
  jq -e '.history[1].step_wall_s == {panel:600, decide:null, risk:45, fix:900}' "$ST"
  # no gate key: gate time lives in gate.wall_s only
  jq -e '(.history[1].step_wall_s | keys) == ["decide","fix","panel","risk"]' "$ST"
}

@test "#2197 step mode: the fix of round 1 is always null — no fix pass preceded it" {
  printf '{"panel":120,"decide":5,"risk":30,"fix":300}' > "$TIMINGS"
  round1_then_fix --step-timings "$TIMINGS"
  jq -e '.history[0].step_wall_s == {panel:120, decide:5, risk:30, fix:null}' "$ST"
}

@test "#2197 a non-object --step-timings records four nulls with a note, and the round is still recorded" {
  printf '[1,2]' > "$TIMINGS"
  printf '%s' "$CRIT" > "$F"
  step --step-timings "$TIMINGS"
  [ "$status" -eq 20 ]
  jq -e '.history[0].step_wall_s == {panel:null, decide:null, risk:null, fix:null}
         and (.history | length) == 1' "$ST"
  contains "$stderr" "--step-timings is not one JSON object"
}

@test "#2197 a missing --step-timings file records four nulls with a note" {
  printf '%s' "$CRIT" > "$F"
  step --step-timings "$BATS_TEST_TMPDIR/no-such.json"
  [ "$status" -eq 20 ]
  jq -e '.history[0].step_wall_s == {panel:null, decide:null, risk:null, fix:null}' "$ST"
  contains "$stderr" "--step-timings is not a readable file"
}

@test "#2197 a value that is not a non-negative number reads as null, named in a note; the rest stand" {
  printf '{"panel":-5,"decide":"soon","risk":45}' > "$TIMINGS"
  printf '%s' "$CRIT" > "$F"
  step --step-timings "$TIMINGS"
  [ "$status" -eq 20 ]
  jq -e '.history[0].step_wall_s == {panel:null, decide:null, risk:45, fix:null}' "$ST"
  contains "$stderr" "not a non-negative number for round 1: panel, decide"
}

@test "#2197 without --step-timings every key is null, silently" {
  printf '%s' "$CRIT" > "$F"
  step
  [ "$status" -eq 20 ]
  jq -e '.history[0].step_wall_s == {panel:null, decide:null, risk:null, fix:null}' "$ST"
  lacks "$stderr" "step-timings"
}

@test "#2197 --step-timings is refused in hook mode and beside --no-review" {
  printf '{}' > "$TIMINGS"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --status-file "$ST" \
    --review-cmd 'true' --fix-cmd 'true' --step-timings "$TIMINGS"
  [ "$status" -eq 2 ]
  contains "$stderr" "--step-timings is step-mode only"
  run --separate-stderr zsh "$S" --no-review --step-timings "$TIMINGS"
  [ "$status" -eq 2 ]
  contains "$stderr" "--step-timings is step-mode only"
}

@test "#2197 hook mode times --review-cmd as panel and --fix-cmd as the fix of the NEXT round" {
  local crit="$BATS_TEST_TMPDIR/crit.json" n="$BATS_TEST_TMPDIR/n"
  printf '%s' "$CRIT" > "$crit"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --status-file "$ST" \
    --review-cmd "if [ -e '$n' ]; then echo '[]' > \"\$REVIEW_FINDINGS\"; else touch '$n'; cp '$crit' \"\$REVIEW_FINDINGS\"; fi; \
if [ -s \"\${REVIEW_FIX_VERIFICATION:-}\" ] && [ \"\$(jq length \"\$REVIEW_FIX_VERIFICATION\")\" != 0 ]; then \
jq '[.[] | {file, dimension, title, confirmed:[\"r\"], re_raised:[], unconfirmed:[]}]' \"\$REVIEW_FIX_VERIFICATION\" > \"\$REVIEW_FINDINGS.carry.json\"; fi" \
    --fix-cmd "sleep 1; echo 'x = 2' > '$R/fixed.py'"
  [ "$status" -eq 0 ]
  jq -e '.history[0].step_wall_s.panel >= 0 and .history[0].step_wall_s.fix == null
         and .history[0].step_wall_s.decide == null and .history[0].step_wall_s.risk == null' "$ST"
  jq -e '.history[1].step_wall_s.fix >= 1 and .history[1].step_wall_s.panel >= 0
         and .history[1].step_wall_s.decide == null and .history[1].step_wall_s.risk == null' "$ST"
}

@test "#2197 step-2-invocation.md tells the conductor to time and pass --step-timings, outside every moved block" {
  local f="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop/step-2-invocation.md"
  local outside inside
  # the text outside every <!-- moved: --> span, and the spans themselves
  outside="$(awk '/<!-- moved: /{m=1} !m{print} /<!-- \/moved: /{m=0}' "$f" | tr -s ' \n' '  ')"
  inside="$(awk '/<!-- moved: /{m=1} m{print} /<!-- \/moved: /{m=0}' "$f")"
  contains "$outside" 'read `date +%s` when you dispatch the panel, decide, risk and fix subagents and again when you observe each one'"'"'s verdict'
  contains "$outside" 'Write the differences as one JSON object, `{"panel": s, "decide": s, "risk": s, "fix": s}`, in whole seconds, with `null` for a step that did not run or was not timed.'
  contains "$outside" 'pass it on the invocation that consolidates the round as `--step-timings <file>`'
  contains "$outside" 'is the sum of its dispatches, each measured from dispatch to verdict'
  contains "$outside" 'Rewrite it before any re-invoke that followed a re-dispatch; re-pass it unchanged only when nothing was re-dispatched.'
  contains "$outside" 'The loop records it as that round'"'"'s `history[].step_wall_s`, which `estimate-step.zsh` reads to build priors.'
  contains "$outside" 'It is telemetry only: a file the loop cannot use costs a stderr note and nulls, never the round.'
  lacks "$inside" '--step-timings'
}

@test "the loop's code never invokes the selector or passes --select-base" {
  # comments may name the flag to explain the rule; no code line may use it
  run ! grep -nE '^[^#]*(select-base|select-tests)' "$S"
}

# ---- the amended guardrails, as the session reads them ----------------------------
# Each needle is a clause whose loss would put a session back on a wrong action:
# selecting before a full-scope round, rebuilding a held attestation bare, or
# crediting a round with another round's gate. Matched on whitespace-flattened
# text, so a reflow cannot red them.

flat() { tr '\n' ' ' | tr -s ' '; }

# the #1973 section of review-loop.md, up to the next H3 — since #2055 split
# review-loop.md into shards, the section lives in review-loop/delta-rounds.md
selected_section() {
  awk '/^### Selected gates for delta rounds \(#1973\)$/ { on = 1; next }
       on && /^### / { exit } on { print }' \
    "$REPO_ROOT/development/skills/resolve-issue/reference/review-loop/delta-rounds.md" | flat
}

@test "review-loop.md: the selected-gate section pins its scope rule and its overrides" {
  local s needle; s="$(selected_section)"
  [ -n "$s" ]
  for needle in \
    'a gate'"'"'s scope is the `scope_mode` of the round it precedes' \
    'any round ≥ 2 that is **not** the closing sweep' \
    'Only one gate shape can select: a plugin repo whose `<full gate>` is `run-gate.zsh` alone**' \
    'a **compound** `<full gate>` (`run-gate.zsh` plus anything else as one command) and a gate whose suite writes into the tree start their `<full gate>` unchanged' \
    'starts `<full gate>` with `--select-base <base>` appended**' \
    'names, the grant beyond the ceiling included — starts the **full** gate' \
    'whenever the attestation held from that round is `selected:`**: there the *No fix pass ran since the last boundary* exemption does **not** apply' \
    'a red is step 6'"'"'s (fix, restart the boundary)' \
    'Never pass `--select-base` there.' \
    'keep the prefix and never rebuild the value from `T`' \
    'the *No fix pass ran since the last boundary* bullet' \
    'the boundary'"'"'s steps 2, 5 and 7' \
    'Pass it only when this boundary started a gate.' \
    'A boundary that skipped the gate (a zero-blocker promotion held on a full run'"'"'s attestation, the findings-file recovery re-invokes) omits it'; do
    grep -qF -- "$needle" <<< "$s" || { echo "review-loop.md lost: $needle"; return 1; }
  done
}

@test "resolve-issue SKILL.md: the #604 amendment keeps round 1, the sweep, hook mode and CI full" {
  local s; s="$(flat < "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")"
  grep -qF -- '**#1973 amends this for intermediate (delta) review rounds only:**' <<< "$s"
  grep -qF -- 'round 1'"'"'s gate (this one), the closing sweep, hook mode and CI stay on the whole suite' <<< "$s"
}

@test "claude-plugin resolve-profile: the amended whole-suite rule names every full-suite gate" {
  local s; s="$(flat < "$REPO_ROOT/development-claude-plugin/skills/resolve-profile/SKILL.md")"
  grep -qF -- 'amended for intermediate (delta) review rounds only (#1973)' <<< "$s"
  grep -qF -- 'which the loop accepts as an attestation only into a delta round' <<< "$s"
  grep -qF -- 'the closing sweep (the grant beyond the ceiling included), the loop'"'"'s own `--test-cmd`, hook mode, §E4 and CI stay on the whole suite' <<< "$s"
}

@test "run-gate.zsh's header states the #979 amendment for delta rounds only" {
  local s; s="$(flat < "$REPO_ROOT/development/skills/resolve-issue/scripts/run-gate.zsh")"
  grep -qF -- 'amended by #1973 for intermediate DELTA review # rounds only' <<< "$s"
}

@test "CI: script-tests.yml passes no selection flag or env var to the bats run" {
  local wf="$REPO_ROOT/.github/workflows/script-tests.yml"
  grep -qE '^ *zsh development/skills/resolve-issue/scripts/run-gate\.zsh --tests-dir tests$' "$wf"
  run ! grep -nE 'select-base|select-tests|GATE_SELECT' "$wf"
}
