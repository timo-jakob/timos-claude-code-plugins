#!/usr/bin/env bats
#
# The panel the loop dispatches each round: the #2909 fallback panel, the
# #1434/#1485 refusals of a full round that produced no findings, the #1072
# topic panels and the #2009 skippable dimensions — all hook mode (#562).
#
# One of the resolve-story-loop.zsh suites #3085 split by concern; the shared
# setup, the omniscient-panel wrapper and the helpers more than one suite uses
# are tests/resolve-story-loop-fixture.bash.

bats_require_minimum_version 1.5.0
load assertions
load resolve-story-loop-fixture

setup_file() { loop_fixture_setup_file "$BATS_TEST_DIRNAME/../development/skills/resolve-issue/scripts/resolve-story-loop.zsh"; }
setup() {
  export HOME="$BATS_TEST_TMPDIR/home"  # the user-level telemetry default stays out of the real ~/.claude (#1972)
  loop_fixture_setup
}
teardown() { loop_fixture_teardown; }

@test "#1434 hook mode: a FULL round whose panel writes NO findings is refused, never converged" {
  # Hook mode has no --findings-file guards at all, so this branch is the only
  # thing that keeps a silent panel from converging a run. Round 1 is always
  # full, so `--review-cmd 'true'` (which writes nothing) lands squarely on it.
  loop --review-cmd 'true' --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  # the HOOK-mode wording: it names $REVIEW_FINDINGS, the file the hook must
  # write, not the --findings-file a step-mode caller passes
  contains "$output" "is a FULL round and --review-cmd produced no findings"
}

# #2909: a stub panel that is NOT APPLICABLE in its repo-type mode and reviews
# only in fallback mode. Every call logs round, mode, skill, scope mode and
# topics; $1 is the fallback-mode body (default: write []).
fallback_review() {
  local body="${1:-printf \"[]\" > \"\$REVIEW_FINDINGS\"}"
  printf '%s' 'printf "%s|%s|%s|%s|%s\n" "$REVIEW_ROUND" "$REVIEW_MODE" "$REVIEW_SKILL" "$REVIEW_SCOPE_MODE" "$REVIEW_TOPIC_SKILLS" >> "'"$BATS_TEST_TMPDIR"'/hook.log"; if [ "$REVIEW_MODE" = fallback ]; then '"$body"'; fi'
}

@test "#2909 hook mode: a full round with no findings engages the fallback panel in the same round and converges" {
  loop --review-cmd "$(fallback_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
  lacks "$output" "is a FULL round and --review-cmd produced no findings"
  # one line names the repo-type panel and the fallback; nothing is asked
  contains "$output" "Decision taken (not asked): development-python:review is NOT APPLICABLE on this diff, so development-claude-plugin:review reviews it in fallback mode"
  run cat "$BATS_TEST_TMPDIR/hook.log"
  [ "${lines[0]}" = "1||development-python:review|full|[]" ]
  [ "${lines[1]}" = "1|fallback|development-claude-plugin:review|full|[]" ]
  [ "${#lines[@]}" -eq 2 ]
  # the engagement is a --work-dir marker naming the round it engaged on
  [ "$(cat "$BATS_TEST_TMPDIR/wd/.fallback-engaged")" = "1" ]
}

@test "#2909 hook mode: once engaged, every later round runs the hook once, already in fallback mode" {
  loop --review-cmd "$(fallback_review 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi')" \
       --fix-cmd 'echo "print(2)" > "$REVIEW_REPO/fixed.py"'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
  run cat "$BATS_TEST_TMPDIR/hook.log"
  [ "${lines[0]}" = "1||development-python:review|full|[]" ]
  [ "${lines[1]}" = "1|fallback|development-claude-plugin:review|full|[]" ]
  # round 2 (delta) and round 3 (the closing sweep): one call each, fallback
  [ "${lines[2]}" = "2|fallback|development-claude-plugin:review|delta|[]" ]
  [ "${lines[3]}" = "3|fallback|development-claude-plugin:review|full|[]" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "#2909 hook mode: a caller-exported REVIEW_MODE=fallback never reaches the first hook call" {
  REVIEW_MODE=fallback loop --review-cmd "$(fallback_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/hook.log"
  [ "${lines[0]}" = "1||development-python:review|full|[]" ]
  [ "${lines[1]}" = "1|fallback|development-claude-plugin:review|full|[]" ]
}

@test "#2909 hook mode: a fallback that writes no findings either is still refused as STALE_FINDINGS" {
  loop --review-cmd "$(fallback_review 'true')" --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  contains "$output" "round 1 is a FULL round and --review-cmd produced no findings"
  contains "$output" "The fallback panel development-claude-plugin:review (\$REVIEW_MODE=fallback, #2909) wrote no findings either"
  # the hook ran exactly twice: the repo-type call and the one fallback re-run
  run cat "$BATS_TEST_TMPDIR/hook.log"
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "1|fallback|development-claude-plugin:review|full|[]" ]
}

@test "#2909 hook mode: --resume keeps the engagement; a fresh run on the same work-dir drops it" {
  # round 1 engages the fallback and finds a blocker; the one-round budget ends
  # the first invocation there
  loop --max-rounds 1 --review-cmd "$(fallback_review 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"')" --fix-cmd 'echo "print(2)" > "$REVIEW_REPO/fixed.py"'
  [ "$status" -eq 13 ]
  [ "$(cat "$BATS_TEST_TMPDIR/wd/.fallback-engaged")" = "1" ]
  : > "$BATS_TEST_TMPDIR/hook.log"
  # the resumed invocation's first hook call is already in fallback mode
  loop --resume --max-rounds 3 --review-cmd "$(fallback_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/hook.log"
  # (round 2 runs once, as the resumed run's closing sweep)
  [ "${lines[0]}" = "2|fallback|development-claude-plugin:review|full|[]" ]
  [ "${#lines[@]}" -eq 1 ]
  # a fresh run on the reused work-dir starts on the repo-type panel again
  rm -rf "$BATS_TEST_TMPDIR/wd2"; mkdir -p "$BATS_TEST_TMPDIR/wd2"
  echo 1 > "$BATS_TEST_TMPDIR/wd2/.fallback-engaged"
  : > "$BATS_TEST_TMPDIR/hook.log"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd2" \
    --review-cmd "$(fallback_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/hook.log"
  [ "${lines[0]}" = "1||development-python:review|full|[]" ]
  [ "${lines[1]}" = "1|fallback|development-claude-plugin:review|full|[]" ]
}

@test "#2909 hook mode: a delta round never engages; the closing sweep can, and a later empty fallback is refused with no third call" {
  # repo-type panel: a blocker on round 1, silent after that. Round 2 (delta)
  # consumes the silence as []; round 3 (the closing sweep) engages.
  loop --review-cmd 'printf "%s|%s|%s|%s|%s\n" "$REVIEW_ROUND" "$REVIEW_MODE" "$REVIEW_SKILL" "$REVIEW_SCOPE_MODE" "$REVIEW_TOPIC_SKILLS" >> "'"$BATS_TEST_TMPDIR"'/hook.log"; if [ "$REVIEW_MODE" = fallback ]; then printf "[]" > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; fi' \
       --fix-cmd 'echo "print(2)" > "$REVIEW_REPO/fixed.py"'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
  run cat "$BATS_TEST_TMPDIR/hook.log"
  [ "${lines[0]}" = "1||development-python:review|full|[]" ]
  [ "${lines[1]}" = "2||development-python:review|delta|[]" ]
  [ "${lines[2]}" = "3||development-python:review|full|[]" ]
  [ "${lines[3]}" = "3|fallback|development-claude-plugin:review|full|[]" ]
  [ "${#lines[@]}" -eq 4 ]
  [ "$(cat "$BATS_TEST_TMPDIR/wd/.fallback-engaged")" = "3" ]
}

@test "#2909 hook mode: an engaged fallback that writes nothing on a later full round is refused, never re-engaged" {
  loop --review-cmd "$(fallback_review 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 2 ]; then printf "[]" > "$REVIEW_FINDINGS"; fi')" \
       --fix-cmd 'echo "print(2)" > "$REVIEW_REPO/fixed.py"'
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  contains "$output" "round 3 is a FULL round and --review-cmd produced no findings"
  contains "$output" "wrote no findings either"
  run cat "$BATS_TEST_TMPDIR/hook.log"
  [ "${lines[3]}" = "3|fallback|development-claude-plugin:review|full|[]" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "#2909 hook mode: a claude-plugin repo never engages its own panel as a fallback" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":[],"is_claude_plugin":true}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" \
    --review-cmd "$(fallback_review)" --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  lacks "$output" "wrote no findings either"
  [ ! -e "$BATS_TEST_TMPDIR/wd/.fallback-engaged" ]
  run cat "$BATS_TEST_TMPDIR/hook.log"
  [ "${#lines[@]}" -eq 1 ]
}

@test "#2909 hook mode: the fallback re-run drops the repo-type panel's topic panels" {
  rm -f "$R/app.py"; echo "x" > "$R/app.js"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["javascript"],"is_react":true}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" \
    --review-cmd "$(fallback_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/hook.log"
  [ "${lines[0]}" = '1||development-javascript:review|full|["development-react:review"]' ]
  [ "${lines[1]}" = "1|fallback|development-claude-plugin:review|full|[]" ]
}

@test "#2909 hook mode: an empty fallback round leaves no engagement marker behind" {
  loop --review-cmd "$(fallback_review 'true')" --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/wd/.fallback-engaged" ]
}

@test "#2909 hook mode: an empty story diff never engages the fallback" {
  rm -f "$R/app.py"
  loop --review-cmd "$(fallback_review)" --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/wd/.fallback-engaged" ]
  run cat "$BATS_TEST_TMPDIR/hook.log"
  [ "${#lines[@]}" -eq 1 ]
}

@test "#2909 hook mode: a carried full round never engages the fallback" {
  # round 1's repo-type panel raises a blocker; the fix changes nothing, so
  # round 2 is re-planned to a full round that carries it — and that panel
  # writes nothing
  loop --review-cmd "$(fallback_review)"'; if [ -z "$REVIEW_MODE" ] && [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; fi' \
       --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  lacks "$output" "wrote no findings either"
  [ ! -e "$BATS_TEST_TMPDIR/wd/.fallback-engaged" ]
  lacks "$(cat "$BATS_TEST_TMPDIR/hook.log")" "|fallback|"
  run cat "$BATS_TEST_TMPDIR/hook.log"
  [ "${lines[1]}" = "2||development-python:review|full|[]" ]
}

@test "#2909 hook mode: a failed fallback re-plan exits 1 before the re-run and records nothing" {
  local fake="$BATS_TEST_TMPDIR/fake-dispatch.zsh" real
  real="$REPO_ROOT/development/skills/resolve-issue/scripts/review-dispatch.zsh"
  printf '#!/usr/bin/env zsh\nif [[ " $* " == *" --fallback "* ]]; then exit 1; fi\nexec zsh %q "$@"\n' "$real" > "$fake"
  chmod +x "$fake"
  run --separate-stderr env RESOLVE_LOOP_DISPATCH_BIN="$fake" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" \
    --review-cmd "$(fallback_review)" --fix-cmd 'true'
  [ "$status" -eq 1 ]
  contains "$stderr" "fallback dispatch plan failed at round 1"
  [ ! -e "$BATS_TEST_TMPDIR/wd/.fallback-engaged" ]
  run cat "$BATS_TEST_TMPDIR/hook.log"
  [ "${#lines[@]}" -eq 1 ]
}

@test "#2909 hook mode: every plan call after the engagement passes --fallback to the dispatcher" {
  # a logging shim around the real dispatcher: one line per plan call
  local shim="$BATS_TEST_TMPDIR/log-dispatch.zsh" real
  real="$REPO_ROOT/development/skills/resolve-issue/scripts/review-dispatch.zsh"
  printf '#!/usr/bin/env zsh\nif [[ "$1" == plan ]]; then print -r -- "$*" >> %q; fi\nexec zsh %q "$@"\n' \
    "$BATS_TEST_TMPDIR/plan.log" "$real" > "$shim"
  chmod +x "$shim"
  run --separate-stderr env RESOLVE_LOOP_DISPATCH_BIN="$shim" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" \
    --review-cmd "$(fallback_review 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi')" \
    --fix-cmd 'echo "print(2)" > "$REVIEW_REPO/fixed.py"'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
  # line 1 is the startup repo-type probe, run before any round: it ends at
  # `--round 1` and never carries --fallback, so the per-round reads skip it
  local probe; probe="$(head -n 1 "$BATS_TEST_TMPDIR/plan.log")"
  [ "${probe% --round 1}" != "$probe" ]
  run grep -E -- '--round 1( |$)' <(tail -n +2 "$BATS_TEST_TMPDIR/plan.log")
  # round 1: the repo-type plan, then the one --fallback re-plan
  lacks " ${lines[0]} " " --fallback "
  contains " ${lines[1]} " " --fallback "
  [ "${#lines[@]}" -eq 2 ]
  # rounds 2 and 3 plan with --fallback from the start
  run grep -E -- '--round [23]( |$)' <(tail -n +2 "$BATS_TEST_TMPDIR/plan.log")
  [ "${#lines[@]}" -ge 2 ]
  local l; for l in "${lines[@]}"; do contains " $l " " --fallback "; done
}

@test "#2909 hook mode: a --resume run's plan calls pass --fallback from its first round" {
  loop --max-rounds 1 --review-cmd "$(fallback_review 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"')" --fix-cmd 'echo "print(2)" > "$REVIEW_REPO/fixed.py"'
  [ "$status" -eq 13 ]
  local shim="$BATS_TEST_TMPDIR/log-dispatch.zsh" real
  real="$REPO_ROOT/development/skills/resolve-issue/scripts/review-dispatch.zsh"
  printf '#!/usr/bin/env zsh\nif [[ "$1" == plan ]]; then print -r -- "$*" >> %q; fi\nexec zsh %q "$@"\n' \
    "$BATS_TEST_TMPDIR/plan.log" "$real" > "$shim"
  chmod +x "$shim"
  run --separate-stderr env RESOLVE_LOOP_DISPATCH_BIN="$shim" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" --resume --max-rounds 3 \
    --review-cmd "$(fallback_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  # skip line 1, the startup repo-type probe, which precedes every round
  local probe; probe="$(head -n 1 "$BATS_TEST_TMPDIR/plan.log")"
  [ "${probe% --round 1}" != "$probe" ]
  run grep -E -- '--round [0-9]+( |$)' <(tail -n +2 "$BATS_TEST_TMPDIR/plan.log")
  [ "${#lines[@]}" -ge 1 ]
  local l; for l in "${lines[@]}"; do contains " $l " " --fallback "; done
}

@test "#2909 hook mode: the engagement notice goes to stderr, never stdout, and only once the fallback reviewed something" {
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" \
    --review-cmd "$(fallback_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  contains "$stderr" "Decision taken (not asked): development-python:review is NOT APPLICABLE on this diff, so development-claude-plugin:review reviews it in fallback mode"
  lacks "$output" "Decision taken (not asked)"
  # a fallback that reviewed nothing never announces a decision
  rm -rf "$BATS_TEST_TMPDIR/wd"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" \
    --review-cmd "$(fallback_review 'true')" --fix-cmd 'true'
  [ "$status" -eq 2 ]
  lacks "$stderr" "Decision taken (not asked)"
}

@test "#2909 hook mode: a fallback re-plan that exits 3 ends the run ESCALATE_AMBIGUOUS" {
  local fake="$BATS_TEST_TMPDIR/fake-dispatch.zsh" real
  real="$REPO_ROOT/development/skills/resolve-issue/scripts/review-dispatch.zsh"
  printf '#!/usr/bin/env zsh\nif [[ " $* " == *" --fallback "* ]]; then print -r -- %q; exit 3; fi\nexec zsh %q "$@"\n' \
    '{"error":"ambiguous_repo_type","message":"two supported languages"}' "$real" > "$fake"
  chmod +x "$fake"
  run --separate-stderr env RESOLVE_LOOP_DISPATCH_BIN="$fake" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" \
    --review-cmd "$(fallback_review)" --fix-cmd 'true'
  [ "$status" -eq 10 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "ESCALATE_AMBIGUOUS" ]
  lacks "$stderr" "fallback dispatch plan failed"
  [ ! -e "$BATS_TEST_TMPDIR/wd/.fallback-engaged" ]
  run cat "$BATS_TEST_TMPDIR/hook.log"
  [ "${#lines[@]}" -eq 1 ]
}

@test "#2909 the status JSON keeps naming the repo-type plan; the marker records the engagement" {
  loop --review-cmd "$(fallback_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.review_skill')" = "development-python:review" ]
  [ -e "$BATS_TEST_TMPDIR/wd/.fallback-engaged" ]
  local t; t="$(tr '#\n' '  ' < "$LOOP_REAL" | tr -s ' ')"
  contains "$t" "The status JSON's review_skill and topic_review_skills keep naming the repo-type plan even then; the marker <work-dir>/.fallback-engaged is the record of the engagement"
}

@test "#2909 hook mode: a marker that cannot be recorded is exit 1" {
  # the fallback re-run reviews the round, then blocks the marker path with a
  # directory, so the loop's write of the engagement fails
  loop --review-cmd "$(fallback_review 'printf "[]" > "$REVIEW_FINDINGS"; mkdir -p "'"$BATS_TEST_TMPDIR"'/wd/.fallback-engaged"')" --fix-cmd 'true'
  [ "$status" -eq 1 ]
  contains "$output" "could not record the fallback engagement"
}

@test "#2909 hook mode: a previous run's marker that cannot be cleared is exit 1" {
  # a directory at the marker path makes the fresh run's rm -f fail
  mkdir -p "$BATS_TEST_TMPDIR/wd/.fallback-engaged"
  loop --review-cmd "$(fallback_review)" --fix-cmd 'true'
  [ "$status" -eq 1 ]
  contains "$output" "could not clear a previous run's fallback marker"
  [ ! -e "$BATS_TEST_TMPDIR/hook.log" ]
}

@test "#2909 the --review-cmd header lists \$REVIEW_MODE" {
  run grep -c 'REVIEW_MODE (#2909' "$LOOP_REAL"
  [ "$output" -ge 1 ]
}

@test "#1434 hook mode: a DELTA round whose panel writes NO findings is still consumed as no findings" {
  # The other arm of the same condition, and the reason it is conditional: a
  # delta round cannot converge, so a silent panel there is harmless and the
  # `[]` default stands. Round 1 finds a blocker, the fix hook really moves the
  # tree, and from round 2 on the panel writes nothing.
  loop --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; fi' \
       --fix-cmd 'echo "print(2)" > "$REVIEW_REPO/fixed.py"'
  # round 2 is consumed as zero blockers and promotes the closing sweep; round
  # 3 IS that sweep — a full round whose panel is again silent, so it refuses
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  contains "$output" "round 3 is a FULL round and --review-cmd produced no findings"
  # the delta round really did run and really did promote: without the
  # conditional the run would have refused at round 2 instead
  [ "$(cat "$BATS_TEST_TMPDIR/wd/.closing-sweep")" = "3" ]
  [ -s "$BATS_TEST_TMPDIR/wd/changelist-2.json" ]
  [ "$(jq '.summary.blocking' "$BATS_TEST_TMPDIR/wd/changelist-2.json")" -eq 0 ]
}

@test "#2008 hook mode: the review hook sees the loop's --base as \$REVIEW_BASE" {
  export SNAP="$BATS_TEST_TMPDIR"
  loop --review-cmd 'printf "%s" "$REVIEW_BASE" > "$SNAP/base-r$REVIEW_ROUND.txt"; printf "[]" > "$REVIEW_FINDINGS"' \
       --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/base-r1.txt")" = 'main' ]
}

@test "#1485 hook mode: a FULL round over an EMPTY story diff is refused even on a written []" {
  # The twin of the no-findings-file arm above: this panel DOES write `[]`, so
  # only the round's scope tells "found nothing" from "saw nothing". Hook mode
  # never computed round_scope_empty before #1485, so reverting the hoist makes
  # this run converge.
  rm -f "$R/app.py"                  # the story diff is now empty
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    SNAP="$BATS_TEST_TMPDIR" \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" \
    --review-cmd 'cp "$REVIEW_SCOPE_FILE" "$SNAP/scope-r$REVIEW_ROUND.txt"; printf "%s" "$REVIEW_SCOPE_MODE" > "$SNAP/mode-r$REVIEW_ROUND.txt"; printf "[]" > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  contains "$output" "round 1 is a FULL round over an EMPTY story diff"
  contains "$output" "go back to §2 (Implement)"
  # ...and its second remedy, for a story that needs no code change
  contains "$output" "say so and stop"
  contains "$output" "never invent a change"
  # the fixture really reached the shape: a full round, handed an empty scope
  [ "$(cat "$BATS_TEST_TMPDIR/mode-r1.txt")" = "full" ]
  # present first: `! -s` alone also passes when the cp never ran
  [ -f "$BATS_TEST_TMPDIR/scope-r1.txt" ]
  [ ! -s "$BATS_TEST_TMPDIR/scope-r1.txt" ]
  # refused BEFORE any accumulator write, so the round simply re-runs
  [ ! -s "$BATS_TEST_TMPDIR/wd/history.jsonl" ]
  [ ! -s "$BATS_TEST_TMPDIR/wd/changelists.jsonl" ]
}

@test "#1485 hook mode: a story whose only changes are the repo-internal --work-dir is refused too" {
  # The second reachable shape: the descriptor sees the loop's own state files as
  # changed, the filter strips them, and the panel is handed nothing.
  rm -f "$R/app.py"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$R/.loop-wd" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  contains "$output" "FULL round over an EMPTY story diff"
  # the repo really does show the work-dir as changed — so it is the FILTER that
  # emptied the scope, not an already-empty diff (the test above)
  git -C "$R" status --porcelain --untracked-files=all | grep -q '^?? \.loop-wd/'
}

@test "#1485 hook mode: a panel that honours its contract and writes NOTHING on an empty diff gets the empty-diff remedy, not 'write []'" {
  # Every panel's contract on a full round with an empty scope is "report it and
  # write no findings file". The generic missing-file arm would answer that with
  # "a panel that found nothing must still write []" — advice that leads only
  # into the post-consolidation refusal of the same cause. One cause, one remedy.
  rm -f "$R/app.py"
  loop --review-cmd 'true' --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  contains "$output" "round 1 is a FULL round over an EMPTY story diff"
  # the SAME wording as the post-consolidation site: one helper, one remedy
  contains "$output" "say so and stop"
  contains "$output" "never invent a change"
  lacks "$output" "must still write []"
  lacks "$output" "is a FULL round and --review-cmd produced no findings"
}

# ---- #1072: topic panels reach the hook and the status JSON ----------------

@test "#1072 a registered topic reaches --review-cmd as REVIEW_TOPIC_SKILLS and the status JSON as topic_review_skills" {
  SNAP="$BATS_TEST_TMPDIR/snap-topic"
  mkdir -p "$SNAP"
  export SNAP
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"],"is_react":true}' REVIEW_TOPIC_TABLE="react" \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" \
    --review-cmd 'printf "%s" "$REVIEW_TOPIC_SKILLS" > "$SNAP/topics.json"; printf "[]" > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(jq -c . "$SNAP/topics.json")" = '["development-react:review"]' ]
  [ "$(echo "$output" | jq -c '.topic_review_skills')" = '["development-react:review"]' ]
  [ "$(echo "$output" | jq -r '.review_skill')" = "development-python:review" ]
  # the dispatch's override note reaches the loop's stderr, never its status JSON
  contains "$stderr" "REVIEW_TOPIC_TABLE overrides the shipped review-topic table"
}

@test "#1072 with no topic, REVIEW_TOPIC_SKILLS is the JSON array [] and the status field is []" {
  SNAP="$BATS_TEST_TMPDIR/snap-notopic"
  mkdir -p "$SNAP"
  export SNAP
  run env -u REVIEW_TOPIC_TABLE DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" \
    --review-cmd 'printf "%s" "${REVIEW_TOPIC_SKILLS-UNSET}" > "$SNAP/topics.json"; printf "[]" > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(cat "$SNAP/topics.json")" = "[]" ]
  [ "$(echo "$output" | jq -c '.topic_review_skills')" = "[]" ]
}

@test "#1072 topic_review_skills is present ([]) on the --no-review exit, before any plan" {
  run zsh "$S" --no-review
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.topic_review_skills')" = "[]" ]
}

@test "#1072 topic_review_skills is present ([]) on an exit-3 escalation, which names no panel" {
  ambiguous_run
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_AMBIGUOUS" ]
  [ "$(echo "$output" | jq -c '.topic_review_skills')" = "[]" ]
}

@test "#1072 the status JSON's key set is pinned, topic_review_skills right after review_skill" {
  # ARCHITECTURE.md lists these keys in this order; without a pin a key could
  # move or vanish with the suite green
  clean_loop
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r 'keys_unsorted | join(",")')" = \
    "status,rounds,max_rounds,effective_max_rounds,max_rounds_source,grants,auto_guided_retry,closing_sweep_granted,possible_false_trip_auto_continues,carry_unconfirmed,repo_type,review_skill,topic_review_skills,escalation_reasons,residue_replaced_reasons,history,round_changelists,final_changelist,next_ref" ]
}

@test "#1072 a plan whose topic_review_skills is missing or not an array of strings is an internal error, never exported" {
  local fake="$BATS_TEST_TMPDIR/fake-dispatch.zsh" real filt
  real="$REPO_ROOT/development/skills/resolve-issue/scripts/review-dispatch.zsh"
  SNAP="$BATS_TEST_TMPDIR/snap-malformed"
  mkdir -p "$SNAP"
  export SNAP
  for filt in '.topic_review_skills = [1]' '.topic_review_skills = {"a":"development-x:review"}' \
              '.topic_review_skills = "development-x:review"' 'del(.topic_review_skills)'; do
    echo "input: $filt"   # printed on failure, so a red names the shape
    printf '#!/usr/bin/env zsh\nif [[ $1 == plan ]]; then\n  zsh %q "$@" | jq -c %q\nelse\n  exec zsh %q "$@"\nfi\n' \
      "$real" "$filt" "$real" > "$fake"
    chmod +x "$fake"
    rm -rf "$BATS_TEST_TMPDIR/wd" "$SNAP/ran"
    # a stale verdict in the status file, as a previous --resume would leave it
    printf '{"status":"AWAITING_FIX"}' > "$SNAP/status.json"
    run --separate-stderr env RESOLVE_LOOP_DISPATCH_BIN="$fake" DETECT_STACK_BIN="$STUB" \
      DETECT_LANGS_JSON='{"languages":["python"]}' \
      zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" \
      --status-file "$SNAP/status.json" \
      --review-cmd ': > "$SNAP/ran"; printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
    [ "$status" -eq 1 ]
    contains "$stderr" "missing or malformed topic_review_skills"
    # the round never started, so no hook ever saw the malformed value
    [ ! -e "$SNAP/ran" ]
    # the refusal overwrites the stale verdict, and keeps the field well-formed
    [ "$(jq -r '.status' "$SNAP/status.json")" = "ERROR" ]
    [ "$(jq -c '.topic_review_skills' "$SNAP/status.json")" = "[]" ]
  done
}

# --- #2009: skippable_dimensions — the contract dimension on delta rounds
#
# A claude-plugin repo whose contract selector is stubbed to answer `skip`: every
# delta round's plan then carries skippable_dimensions ["contract"], and full
# rounds carry []. The fix pass edits the story file so round 2 is a real,
# non-empty delta (an empty one would be re-planned as a full sweep).

plugin_loop() {
  local sel="$BATS_TEST_TMPDIR/sel-skip.zsh"
  printf '%s\n' '#!/usr/bin/env zsh' 'print -r -- '"'"'{"contract":"skip","triggers":[]}'"'" > "$sel"
  chmod +x "$sel"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":[],"is_claude_plugin":true}' \
    SELECT_CONTRACT_BIN="$sel" \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" "$@"
}

@test "#2009 hook mode: a skipped delta round records skipped_dimensions, and the hook is handed REVIEW_SKIPPABLE_DIMENSIONS" {
  WD="$BATS_TEST_TMPDIR/wd"
  local tblock="${CRIT/\"bugs\"/\"tests\"}"
  # round 1 (full) raises a `tests` blocker; round 2 is a delta whose plan omits
  # contract and whose panel returns no contract verdict — accepted (#2009 AC3);
  # round 3 is the closing full sweep
  plugin_loop --max-rounds 3 --status-file "$BATS_TEST_TMPDIR/st.json" \
    --review-cmd 'printf "%s" "$REVIEW_SKIPPABLE_DIMENSIONS" > "'"$BATS_TEST_TMPDIR"'/skip-$REVIEW_ROUND.json"; if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$tblock"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'echo "print(2)" >> "$REVIEW_REPO/app.py"'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "CONVERGED" ]
  [ "$(cat "$BATS_TEST_TMPDIR/skip-1.json")" = '[]' ]
  # #3311: round 2's fix pass touched only app.py (no dimension's class) and
  # its carry holds the `tests` blocker, so every other dimension is skippable
  [ "$(cat "$BATS_TEST_TMPDIR/skip-2.json")" = '["prose_logic","contract","script_quality","manifest_bump"]' ]
  [ "$(cat "$BATS_TEST_TMPDIR/skip-3.json")" = '[]' ]
  [ "$(cat "$WD/skippable-2.json")" = '["prose_logic","contract","script_quality","manifest_bump"]' ]
  [ "$(jq -sc '[.[] | .skipped_dimensions]' "$WD/history.jsonl")" = '[[],["prose_logic","contract","script_quality","manifest_bump"],[]]' ]
  [ "$(jq -c '[.history[] | .skipped_dimensions]' "$BATS_TEST_TMPDIR/st.json")" = '[[],["prose_logic","contract","script_quality","manifest_bump"],[]]' ]
  # #3311: each history line carries the plan's reasons as skip_reasons
  [ "$(jq -sc '[.[] | .skip_reasons]' "$WD/history.jsonl")" = '[{"prose_logic":"full","contract":"full","script_quality":"full","tests":"full","manifest_bump":"full"},{"prose_logic":"none","contract":"none","script_quality":"none","tests":"carried","manifest_bump":"none"},{"prose_logic":"full","contract":"full","script_quality":"full","tests":"full","manifest_bump":"full"}]' ]
}

@test "#2009 hook mode: a carried contract entry forces contract back in — owner-accounted, it passes and contract is not recorded skipped" {
  WD="$BATS_TEST_TMPDIR/wd"
  local cblock="${CRIT/\"bugs\"/\"contract\"}"
  # the selector said skip, but the split-carry map holds `contract`, so
  # contract-integrity is dispatched (Carry-driven dispatch, #2008) and accounts
  # for its entry
  plugin_loop --max-rounds 3 --status-file "$BATS_TEST_TMPDIR/st.json" \
    --review-cmd 'printf "%s" "$REVIEW_FIX_VERIFICATION_BY_DIMENSION" > "'"$BATS_TEST_TMPDIR"'/map-$REVIEW_ROUND.json"; if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$cblock"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; jq "[.[] | {file, dimension, title, confirmed: [\"claude-plugin-contract-integrity\"], re_raised: [], unconfirmed: []}]" "$REVIEW_FIX_VERIFICATION" > "$REVIEW_FINDINGS.carry.json"; fi' \
    --fix-cmd 'echo "print(2)" >> "$REVIEW_REPO/app.py"'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "CONVERGED" ]
  [ "$(jq -c 'keys' "$BATS_TEST_TMPDIR/map-2.json")" = '["contract"]' ]
  # #3311: the plan reads the carry itself, so contract is not offered
  [ "$(cat "$WD/skippable-2.json")" = '["prose_logic","script_quality","tests","manifest_bump"]' ]
  [ "$(jq -c '.round_changelists[1].carry_accounting.confirmed' "$BATS_TEST_TMPDIR/st.json")" = '[{"file":"app.py","dimension":"contract","title":"T"}]' ]
  [ "$(jq -sc '[.[] | .skipped_dimensions]' "$WD/history.jsonl")" = '[[],["prose_logic","script_quality","tests","manifest_bump"],[]]' ]
  [ "$(jq -sc '.[1].skip_reasons.contract' "$WD/history.jsonl")" = '"carried"' ]
}

@test "#2009 hook mode: the same skipped round with contract-integrity absent is refused CARRY-UNACCOUNTED" {
  WD="$BATS_TEST_TMPDIR/wd"
  local cblock="${CRIT/\"bugs\"/\"contract\"}"
  plugin_loop --max-rounds 3 --status-file "$BATS_TEST_TMPDIR/st.json" \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$cblock"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; jq "[.[] | {file, dimension, title, confirmed: [], re_raised: [], unconfirmed: []}]" "$REVIEW_FIX_VERIFICATION" > "$REVIEW_FINDINGS.carry.json"; fi' \
    --fix-cmd 'echo "print(2)" >> "$REVIEW_REPO/app.py"'
  [ "$status" -eq 2 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "STALE_FINDINGS" ]
  contains "$output" 'carry unaccounted: round 2 carried entry "T" (app.py, contract) was neither confirmed nor re-raised by any reviewer'
  [ ! -e "$WD/verify-3.json" ]
}

@test "#2009 a python repo's rounds record skipped_dimensions [] and its skippable files hold []" {
  WD="$BATS_TEST_TMPDIR/wd"
  loop --max-rounds 3 --status-file "$BATS_TEST_TMPDIR/st.json" \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'echo "print(2)" >> "$REVIEW_REPO/app.py"'
  [ "$status" -eq 0 ]
  [ "$(cat "$WD/skippable-2.json")" = '[]' ]
  [ "$(jq -sc '[.[] | .skipped_dimensions]' "$WD/history.jsonl")" = '[[],[],[]]' ]
  [ "$(jq -sc '[.[] | .skip_reasons]' "$WD/history.jsonl")" = '[{},{},{}]' ]
}
