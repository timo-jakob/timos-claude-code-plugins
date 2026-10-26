#!/usr/bin/env bats
#
# clean-stop.zsh (#2579): the durable state of an unattended run that stops
# without converging — the work-dir any later session can derive, the
# clean-stop.json marker written at the stop, the attended `--resume` check,
# and the clear. The end-to-end cases drive the real review loop into a
# BUDGET_EXHAUSTED stop on the durable work-dir and resume it from the marker.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/resolve-issue/scripts"
  CS="$SCRIPTS/clean-stop.zsh"

  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  git -C "$R" remote add origin https://github.com/Acme/Widget.git
  echo base > "$R/README.md"
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" branch -M main
  echo "print(1)" > "$R/app.py"

  BASE="$HOME/.claude/resolve-issue/acme-widget/77"
  STUB="$BATS_TEST_TMPDIR/detect.sh"
  printf '#!/usr/bin/env bash\necho "$DETECT_LANGS_JSON"\n' > "$STUB"
  chmod +x "$STUB"
  F="$BATS_TEST_TMPDIR/findings.json"
}

# a status file in the durable dir, written by hand; $1 = status, $2 = blocking counts
hand_status() {
  mkdir -p "$BASE/work-dir"
  jq -n --arg st "$1" --argjson counts "$2" '
    ($counts | length) as $n
    | {status:$st, rounds:$n, max_rounds:5, effective_max_rounds:5,
       history:[range($n) as $i | {round:($i+1), blocking:$counts[$i], conflicts:0}],
       round_changelists:[range($n) as $i | {round:($i+1),
         blocking:[range($counts[$i]) | {priority:"Warning", dimension:"bugs", file:"a.py", line:., title:"t\(.)", non_converging:false}]}],
       final_changelist:{blocking:[]}}' > "$BASE/status.json"
}

# one step-mode loop invocation on the durable work-dir
loop() {
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$SCRIPTS/resolve-story-loop.zsh" --repo "$R" --base main \
    --work-dir "$BASE/work-dir" --status-file "$BASE/status.json" --findings-file "$F" "$@"
}

@test "#2579 dir names the durable layout under the telemetry sink's own repo slug, and creates nothing" {
  run -0 zsh "$CS" dir --repo-dir "$R" --issue 77
  [ "$(jq -r '.base' <<<"$output")" = "$BASE" ]
  [ "$(jq -r '.work_dir' <<<"$output")" = "$BASE/work-dir" ]
  [ "$(jq -r '.status_file' <<<"$output")" = "$BASE/status.json" ]
  [ "$(jq -r '.marker' <<<"$output")" = "$BASE/clean-stop.json" ]
  [ ! -e "$HOME/.claude/resolve-issue" ]
  # the slug is the one the user-level telemetry sink uses for this repo
  local slug
  slug=$(zsh -c 'source "$1"; tlm_repo_slug "$(tlm_derive_repo "$2")"' _ \
    "$REPO_ROOT/development/scripts/telemetry/telemetry-sink-lib.zsh" "$R")
  [ "$slug" = "acme-widget" ]
}

@test "#2579 write, verdict-failed arm: the marker carries branch, status file, last round, ceiling, the failing conditions and the run id" {
  hand_status BUDGET_EXHAUSTED '[2,4]'
  run -0 --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch feat/77-x --run-id resolve-issue-1-abcd
  [ "$(jq -c . "$BASE/clean-stop.json")" = "$output" ]
  [ "$output" = "{\"schema\":\"clean-stop/v1\",\"issue\":77,\"branch\":\"feat/77-x\",\"work_dir\":\"$BASE/work-dir\",\"status_file\":\"$BASE/status.json\",\"status\":\"BUDGET_EXHAUSTED\",\"last_round\":2,\"ceiling\":5,\"convergence_failures\":[\"trend\"],\"run_id\":\"resolve-issue-1-abcd\"}" ]
}

@test "#2579 write, cap-reached arm: a passing verdict is refused without --cap-reached and records cap with it" {
  hand_status ESCALATE_NO_CONVERGENCE '[4,2]'
  run --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r
  [ "$status" -eq 2 ]
  contains "$stderr" "the convergence verdict passes, so this exit takes the automatic grant, not a clean stop"
  [ ! -e "$BASE/clean-stop.json" ]
  run -0 --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r --cap-reached
  [ "$(jq -c '.convergence_failures' <<<"$output")" = '["cap"]' ]
}

@test "#2579 write, cap-reached on a failing verdict: the failing conditions, then cap" {
  hand_status BUDGET_EXHAUSTED '[2,4]'
  run -0 --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r --cap-reached
  [ "$(jq -c '.convergence_failures' <<<"$output")" = '["trend","cap"]' ]
}

@test "#2579 write: the ceiling is effective_max_rounds, else max_rounds" {
  hand_status BUDGET_EXHAUSTED '[2,4]'
  jq '.effective_max_rounds = 8' "$BASE/status.json" > "$BASE/s.tmp" && mv "$BASE/s.tmp" "$BASE/status.json"
  run -0 --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r
  [ "$(jq -r '.ceiling' <<<"$output")" = "8" ]
  jq 'del(.effective_max_rounds)' "$BASE/status.json" > "$BASE/s.tmp" && mv "$BASE/s.tmp" "$BASE/status.json"
  run -0 --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r
  [ "$(jq -r '.ceiling' <<<"$output")" = "5" ]
}

@test "#2579 write: an empty or non-JSON status file, and a marker that cannot be written, are internal errors" {
  mkdir -p "$BASE/work-dir"
  : > "$BASE/status.json"
  run --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r
  [ "$status" -eq 1 ]
  contains "$stderr" "the durable status file is missing or empty"
  echo 'not json' > "$BASE/status.json"
  run --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r
  [ "$status" -eq 1 ]
  contains "$stderr" "the status file is not JSON"
  [ "$(id -u)" -ne 0 ] || skip "root ignores the read-only base directory"
  hand_status BUDGET_EXHAUSTED '[2,4]'
  chmod 500 "$BASE"
  run --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r
  chmod 700 "$BASE"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "could not write the marker"
  [ ! -e "$BASE/clean-stop.json" ]
}

@test "#2579 write: a tmp file that is written but cannot be moved into place is removed" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores the read-only directory"
  hand_status BUDGET_EXHAUSTED '[2,4]'
  mkdir "$BASE/clean-stop.json"
  chmod 500 "$BASE/clean-stop.json"
  run --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r
  chmod 700 "$BASE/clean-stop.json"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "could not write the marker"
  [ -z "$(find "$BASE" -maxdepth 1 -name 'clean-stop.json.tmp.*')" ]
  [ -z "$(ls -A "$BASE/clean-stop.json")" ]
}

@test "#2579 write refuses a status that cannot stop cleanly, and a missing durable state" {
  local st
  for st in ESCALATE_CONFLICT ESCALATE_AMBIGUOUS CONVERGED; do
    hand_status "$st" '[2,4]'
    run --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r
    [ "$st: $status" = "$st: 2" ]
    contains "$stderr" "only BUDGET_EXHAUSTED or ESCALATE_NO_CONVERGENCE stops cleanly (got: $st)"
  done
  rm -rf "$BASE"
  run --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r
  [ "$status" -eq 1 ]
  contains "$stderr" "the durable work-dir does not exist"
}

@test "#2579 read: the marker in an attended session, refused unattended (4) and with no marker (3)" {
  run --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode attended
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "no clean stop is kept for issue #77"
  hand_status BUDGET_EXHAUSTED '[2,4]'
  run -0 --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r
  local written="$output"
  run --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode unattended
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  contains "$stderr" "--resume is for an attended session only"
  run -0 --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode attended
  [ "$output" = "$written" ]
  echo '{"schema":"other"}' > "$BASE/clean-stop.json"
  run --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode attended
  [ "$status" -eq 1 ]
  contains "$stderr" "the marker is malformed"
}

@test "#2579 read refuses a marker with any required field missing or mistyped, or not exactly one object" {
  hand_status BUDGET_EXHAUSTED '[2,4]'
  run -0 --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r
  local good="$output" bad
  for bad in 'del(.work_dir)' '.work_dir = 1' 'del(.status_file)' '.status_file = null' \
             'del(.branch)' '.branch = 1' 'del(.convergence_failures)' '.convergence_failures = "trend"' \
             'del(.schema)' '[.]'; do
    jq -c "$bad" <<<"$good" > "$BASE/clean-stop.json"
    run --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode attended
    [ "$bad: $status" = "$bad: 1" ]
    [ -z "$output" ]
    contains "$stderr" "the marker is malformed"
  done
  printf '%s\n%s\n' "$good" "$good" > "$BASE/clean-stop.json"
  run --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode attended
  [ "$status" -eq 1 ]
  contains "$stderr" "the marker is malformed"
  echo 'not json' > "$BASE/clean-stop.json"
  run --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode attended
  [ "$status" -eq 1 ]
  contains "$stderr" "the marker is malformed"
  # the untouched marker still reads, so each refusal above is its one broken field
  printf '%s\n' "$good" > "$BASE/clean-stop.json"
  run -0 --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode attended
  [ "$output" = "$good" ]
}

@test "#2579 read appends the ledger to an existing stopped-run-ids, so an earlier stop's ids are kept" {
  hand_status BUDGET_EXHAUSTED '[2,4]'
  run -0 --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r
  printf 'old-id\n' > "$BASE/stopped-run-ids"
  printf 'new-id\n' > "$BASE/work-dir/.telemetry-run-ids"
  run -0 --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode attended
  [ "$(cat "$BASE/stopped-run-ids")" = "$(printf 'old-id\nnew-id')" ]
  [ ! -e "$BASE/work-dir/.telemetry-run-ids" ]
}

@test "#2579 read: a ledger that cannot be set aside is an internal error, and the ledger stays in place" {
  hand_status BUDGET_EXHAUSTED '[2,4]'
  run -0 --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r
  printf 'new-id\n' > "$BASE/work-dir/.telemetry-run-ids"
  # a directory where the append target belongs: the append fails, even as root
  mkdir "$BASE/stopped-run-ids"
  run --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode attended
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "could not set the stopped run's review-loop id ledger aside"
  [ "$(cat "$BASE/work-dir/.telemetry-run-ids")" = "new-id" ]
}

@test "#2579 read: a refused read, unattended (4) or on a malformed marker (1), leaves the ledger untouched" {
  hand_status BUDGET_EXHAUSTED '[2,4]'
  run -0 --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id r
  printf 'new-id\n' > "$BASE/work-dir/.telemetry-run-ids"
  run --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode unattended
  [ "$status" -eq 4 ]
  [ "$(cat "$BASE/work-dir/.telemetry-run-ids")" = "new-id" ]
  [ ! -e "$BASE/stopped-run-ids" ]
  echo '{"schema":"other"}' > "$BASE/clean-stop.json"
  run --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode attended
  [ "$status" -eq 1 ]
  contains "$stderr" "the marker is malformed"
  [ "$(cat "$BASE/work-dir/.telemetry-run-ids")" = "new-id" ]
  [ ! -e "$BASE/stopped-run-ids" ]
}

@test "#2579 clear removes only this issue's durable directory, and an absent one is fine" {
  hand_status BUDGET_EXHAUSTED '[2,4]'
  mkdir -p "$HOME/.claude/resolve-issue/acme-widget/78"
  run -0 zsh "$CS" clear --repo-dir "$R" --issue 77
  [ ! -e "$BASE" ]
  [ -d "$HOME/.claude/resolve-issue/acme-widget/78" ]
  run zsh "$CS" clear --repo-dir "$R" --issue 77
  [ "$status" -eq 0 ]
}

@test "#2579 usage: subcommand, issue and per-subcommand flags are checked" {
  run zsh "$CS"
  [ "$status" -eq 2 ]
  run zsh "$CS" stop --repo-dir "$R" --issue 77
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$CS" dir --repo-dir "$R" --issue 07
  [ "$status" -eq 2 ]
  contains "$stderr" "--issue must be an issue number"
  run --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77
  [ "$status" -eq 2 ]
  contains "$stderr" "read needs --mode attended|unattended"
  run --separate-stderr zsh "$CS" dir --repo-dir "$R" --issue 77 --cap-reached
  [ "$status" -eq 2 ]
  contains "$stderr" "--cap-reached is for write only"
  run --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b
  [ "$status" -eq 2 ]
  contains "$stderr" "write needs --branch and --run-id"
}

@test "#2579 usage: each flag outside its subcommand, a bad value, an unknown flag and a stray argument exit 2" {
  hand_status BUDGET_EXHAUSTED '[2,4]'
  run --separate-stderr zsh "$CS" dir --repo-dir "$R" --issue 77 --branch b
  [ "$status" -eq 2 ]; contains "$stderr" "--branch is for write only"
  run --separate-stderr zsh "$CS" dir --repo-dir "$R" --issue 77 --run-id r
  [ "$status" -eq 2 ]; contains "$stderr" "--run-id is for write only"
  run --separate-stderr zsh "$CS" dir --repo-dir "$R" --issue 77 --mode attended
  [ "$status" -eq 2 ]; contains "$stderr" "--mode is for read only"
  run --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode bogus
  [ "$status" -eq 2 ]; contains "$stderr" "read needs --mode attended|unattended"
  run --separate-stderr zsh "$CS" dir --repo-dir "$BATS_TEST_TMPDIR/nonexistent" --issue 77
  [ "$status" -eq 2 ]; contains "$stderr" "--repo-dir is not a directory"
  run --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch --run-id r
  [ "$status" -eq 2 ]; contains "$stderr" "--branch requires a non-empty value"
  run --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch b --run-id ''
  [ "$status" -eq 2 ]; contains "$stderr" "--run-id requires a non-empty value"
  run --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode
  [ "$status" -eq 2 ]; contains "$stderr" "--mode requires a value"
  run --separate-stderr zsh "$CS" dir --repo-dir --issue 77
  [ "$status" -eq 2 ]; contains "$stderr" "--repo-dir requires a non-empty value"
  run --separate-stderr zsh "$CS" dir --repo-dir "$R" --issue
  [ "$status" -eq 2 ]; contains "$stderr" "--issue requires a value"
  run --separate-stderr zsh "$CS" dir --issue --repo-dir "$R"
  [ "$status" -eq 2 ]; contains "$stderr" "--issue requires a non-empty value"
  run --separate-stderr zsh "$CS" dir --repo-dir "$R" --issue 77 --bogus
  [ "$status" -eq 2 ]; contains "$stderr" "unknown flag: --bogus"
  run --separate-stderr zsh "$CS" dir --repo-dir "$R" --issue 77 stray
  [ "$status" -eq 2 ]; contains "$stderr" "unexpected argument: stray"
  # none of the refusals wrote a marker
  [ ! -e "$BASE/clean-stop.json" ]
}

@test "#2579 end to end: a real BUDGET_EXHAUSTED stop on the durable work-dir is marked, and an attended resume continues from the last round" {
  local wd="$BASE/work-dir"
  mkdir -p "$wd"
  printf '%s' '[{"severity":"WARNING","dimension":"bugs","file":"app.py","line":1,"title":"print without flush","description":"d","reviewer":"r"}]' > "$F"
  loop --max-rounds 1
  [ "$status" -eq 13 ]
  [ "$(jq -r '.status' "$BASE/status.json")" = "BUDGET_EXHAUSTED" ]
  # the unattended stop: one round is too few to show convergence
  run -0 --separate-stderr zsh "$CS" write --repo-dir "$R" --issue 77 --branch feat/77-x --run-id r1
  [ "$(jq -c '{last_round, ceiling, convergence_failures}' <<<"$output")" = '{"last_round":1,"ceiling":1,"convergence_failures":["too-few-rounds"]}' ]
  # write leaves the loop's id ledger in place: the stopped run emits its record after the marker
  [ -s "$wd/.telemetry-run-ids" ]
  local stopped_ids
  stopped_ids="$(cat "$wd/.telemetry-run-ids")"
  # a later attended session: the marker hands back the work-dir and status file
  run -0 --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode attended
  local mwd msf
  mwd=$(jq -r '.work_dir' <<<"$output"); msf=$(jq -r '.status_file' <<<"$output")
  [ "$mwd" = "$wd" ]
  # ...and sets the stopped run's ledger aside, so the resumed run's record never lists those ids
  [ ! -e "$wd/.telemetry-run-ids" ]
  [ "$(cat "$BASE/stopped-run-ids")" = "$stopped_ids" ]
  # the human grants +3 through the interactive extension, and the loop resumes
  # from the last round on the kept work-dir
  run -0 --separate-stderr zsh "$SCRIPTS/record-grant.zsh" --work-dir "$mwd" --status "$msf" --add 3
  [ "$output" = "4" ]
  echo "print(2)" > "$R/app.py"
  jq '[.[] | {file, dimension, title, confirmed: ["r"], re_raised: [], unconfirmed: []}]' "$mwd/verify-2.json" \
    > "$BATS_TEST_TMPDIR/carry.json"
  printf '[]' > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$SCRIPTS/resolve-story-loop.zsh" --repo "$R" --base main --work-dir "$mwd" --status-file "$msf" \
    --findings-file "$F" --resume --max-rounds 4 --carry-accounting "$BATS_TEST_TMPDIR/carry.json"
  [ "$status" -eq 20 ]
  [ "$(jq '.rounds' <<<"$output")" -eq 2 ]
  [ "$(jq -c '.grants' <<<"$output")" = '{"human":1,"automatic":0}' ]
  # the resumed run opens its PR in the end, and the durable dir goes with it
  run -0 zsh "$CS" clear --repo-dir "$R" --issue 77
  [ ! -e "$BASE" ]
}

# --- the procedure and the contract, pinned -------------------------------------

flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

@test "#2579 AC2 escalation.md: only an unattended BUDGET_EXHAUSTED / NO_CONVERGENCE stops cleanly; everything else keeps the terminal" {
  local esc
  esc="$(flat "$REPO_ROOT/development/skills/resolve-issue/reference/escalation.md")"
  contains "$esc" '**An unattended run that cannot converge stops cleanly (#2579).** When that automatic grant is not taken — the verdict fails, or `record-grant.zsh` exits 3 — a `BUDGET_EXHAUSTED` or `ESCALATE_NO_CONVERGENCE` exit in mode `unattended` takes this clean stop instead of the terminal below.'
  contains "$esc" '`ESCALATE_CONFLICT` and `ESCALATE_AMBIGUOUS` on an unattended run, and every escalation on an attended run, take the terminal below unchanged; their records carry `clean_stop: false`.'
  contains "$esc" 'Pass `--cap-reached` exactly when `record-grant.zsh` exited 3.'
  contains "$esc" 'Emit the run'"'"'s record with `clean_stop: true` and the marker'"'"'s `convergence_failures`'
  # the frozen terminal still follows, unchanged in place
  grep -qxF '<!-- moved: escalation-terminal -->' "$REPO_ROOT/development/skills/resolve-issue/reference/escalation.md"
}

@test "#2579 AC3 SKILL.md: --resume is checked against the session mode and the marker before anything else" {
  local skill ext
  skill="$(flat "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")"
  ext="$(flat "$REPO_ROOT/development/skills/resolve-issue/reference/interactive/extension.md")"
  contains "$skill" 'Exit 4 (mode `unattended`) refuses the resume: relay the stderr line, emit the run'"'"'s record as `failed`, and stop.'
  contains "$skill" 'On exit 0, note `resumed_from: clean_stop`, run the dependency precheck below as usual; on `PROCEED`, check out the marker'"'"'s `branch` from `origin`'
  contains "$skill" 'on `PROCEED`, check out the marker'"'"'s `branch` from `origin` and run §1b (detect the repo type and load its profile), but skip §0b, §1, §2 and §3 (the stopped run passed the readiness gate, so record `gate_verdict: READY`).'
  contains "$skill" 'Then enter the interactive extension with the marker (`reference/interactive/extension.md`).'
  contains "$skill" '**In every session mode they are the durable pair** (#2579, #2920)'
  contains "$skill" '[--telemetry-dir DIR] [--no-review] [--resume]`) and stop.'
  contains "$ext" 'Every resume invocation of the loop passes the marker'"'"'s `work_dir` as `--work-dir` and its `status_file` as `--status-file`, so the loop continues from the marker'"'"'s `last_round`.'
  contains "$ext" 'When the resumed run has opened its PR and §7 has emitted its record, run `clean-stop.zsh clear --repo-dir <worktree> --issue <N>`; any other ending keeps the durable directory.'
}

@test "#2579 AC5 ARCHITECTURE.md names --resume, clean_stop and convergence_failures in the invocation line and the telemetry contract" {
  local arch
  arch="$(flat "$REPO_ROOT/ARCHITECTURE.md")"
  contains "$arch" '**Invocation.** `/development:resolve-issue <issue-number|url> [--telemetry-file PATH] [--telemetry-dir DIR] [--no-review] [--resume]`'
  grep -qF '| `clean_stop` | `true` only for the unattended clean stop (#2579)' "$REPO_ROOT/ARCHITECTURE.md"
  grep -qF '| `convergence_failures` | the clean stop'"'"'s failing conditions, drawn from `too-few-rounds`, `trend`, `stuck`, `critical`, `cap`' "$REPO_ROOT/ARCHITECTURE.md"
  contains "$arch" '`$HOME/.claude/resolve-issue/<repo-slug>/<N>/` (`work-dir/`, `status.json` and the `clean-stop.json` marker), keyed by the user-level telemetry sink'"'"'s repo slug.'
  grep -qF '| `clean_stop`, `convergence_failures` | §3.5 |' "$REPO_ROOT/development/skills/resolve-issue/reference/telemetry.md"
}

@test "#2579 the remaining rule sentences of the procedure are pinned" {
  local skill esc ext
  skill="$(flat "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")"
  esc="$(flat "$REPO_ROOT/development/skills/resolve-issue/reference/escalation.md")"
  ext="$(flat "$REPO_ROOT/development/skills/resolve-issue/reference/interactive/extension.md")"
  contains "$skill" '**Without `--resume`**, an unattended run always runs `"<skill-base-dir>/scripts/clean-stop.zsh" clear --repo-dir <worktree> --issue <N>` before round 1, whether or not a marker exists, so it never adopts a stopped run'"'"'s work-dir, status file or grant ledger.'
  contains "$skill" 'An attended run moves any kept state aside instead, deleting nothing.'
  contains "$esc" 'Write the marker beside the durable work-dir the run has been using (`clean-stop.zsh dir`, §3.5):'
  contains "$esc" 'An exit 2 is your own call: a passing verdict without `--cap-reached` was a grant, not a stop.'
  contains "$esc" 'Build the comment with the clean-stop format, then post it and add `needs-human-decision` as the terminal'"'"'s step 3 does:'
  contains "$ext" '**Entered from `--resume` (#2579).**'
  contains "$ext" '**Entered from `--resume` (#2579).** An attended `/development:resolve-issue <N> --resume` comes here directly, with the stopped run'"'"'s status'
}

@test "#2579 the resume check, the durable pair, the clean-stop steps and the resume entry are pinned sentence by sentence" {
  local skill esc ext arch escf="$REPO_ROOT/development/skills/resolve-issue/reference/escalation.md"
  skill="$(flat "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")"
  esc="$(flat "$escf")"
  ext="$(flat "$REPO_ROOT/development/skills/resolve-issue/reference/interactive/extension.md")"
  arch="$(flat "$REPO_ROOT/ARCHITECTURE.md")"
  contains "$skill" 'check the kept clean stop before anything else: `"<skill-base-dir>/scripts/clean-stop.zsh" read --repo-dir <worktree> --issue <N> --mode <mode>`.'
  contains "$skill" '`clean-stop.zsh dir --repo-dir <worktree> --issue <N>` prints `work_dir` and `status_file` under `$HOME/.claude/resolve-issue/<repo-slug>/<N>/`, outside every checkout'
  contains "$skill" 'can find. Create the work-dir before round 1, and pass `--checkpoint <mode>` on every blocking-loop invocation.'
  contains "$esc" 'An unattended `BUDGET_EXHAUSTED` / `ESCALATE_NO_CONVERGENCE` that the automatic grant does not converge takes the clean stop below instead of the terminal.'
  contains "$esc" '1. Push the branch as the bot and create no PR object, exactly as the terminal'"'"'s step 1.'
  grep -qxF '   "<skill-base-dir>/scripts/clean-stop.zsh" write --repo-dir <worktree> \' "$escf"
  grep -qxF '     --issue <N> --branch <branch> --run-id <this run'"'"'s run_id> [--cap-reached]' "$escf"
  contains "$esc" 'The marker'"'"'s `convergence_failures` are the failing conditions, plus `cap`.'
  grep -qxF '   "<skill-base-dir>/scripts/build-escalation.zsh" --status <status.json> \' "$escf"
  grep -qxF '     --format clean-stop --issue <N> --branch <branch> \' "$escf"
  grep -qxF '     --compare-url "https://github.com/$REPO/tree/<branch>" \' "$escf"
  grep -qxF '     --work-dir <the marker'"'"'s work_dir> [--cap-reached]' "$escf"
  contains "$ext" 'the marker `clean-stop.zsh read` printed (§0a) names its `status_file` and `work_dir`. Start at step 1 with that status file.'
  contains "$ext" 'The run'"'"'s record passes that `work_dir` as `--loop-work-dir`: `read` already set the stopped run'"'"'s id ledger aside, so the record lists only this run'"'"'s loops.'
  contains "$arch" 'A successful `clean-stop.zsh read` moves the work-dir'"'"'s `.telemetry-run-ids` ledger aside to `stopped-run-ids` in the durable directory, so a resumed run'"'"'s record never lists the stopped run'"'"'s review-loop ids again.'
}

@test "#2579 --help prints the usage and exits 0" {
  run zsh "$CS" --help
  [ "$status" -eq 0 ]
  contains "$output" "usage: clean-stop.zsh dir   --repo-dir DIR --issue N"
  contains "$output" "clean-stop.zsh read  --repo-dir DIR --issue N --mode attended|unattended"
}
