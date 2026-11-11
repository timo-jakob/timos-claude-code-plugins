#!/usr/bin/env bats
#
# chain-queue.zsh (#2942): the queue of pending issues in a human-started
# resolve-issue chain — the named issue's blockers, the named issue and every
# follow-up through every generation — kept in ONE file in the named issue's
# durable directory so a re-run resumes it. These cases cover the order, the
# durable path, the done condition, the stop report and the follow-up cycle
# refusal, plus clean-stop.zsh clear keeping the queue file.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/resolve-issue/scripts"
  Q="$SCRIPTS/chain-queue.zsh"
  CS="$SCRIPTS/clean-stop.zsh"

  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" remote add origin https://github.com/Acme/Widget.git

  BASE="$HOME/.claude/resolve-issue/acme-widget/10"
  QF="$BASE/chain-queue.json"
}

q() { zsh "$Q" "$1" --repo-dir "$R" --issue 10 "${@:2}"; }
fnd() { printf '{"file":"%s","line":%s,"dimension":"tests","title":"%s"}' "$1" "$2" "$3"; }
order() { jq -c '[.entries[].issue]' "$QF"; }

@test "the queue file lives in the named issue's durable base, the one clean-stop.zsh dir prints" {
  run -0 q add --entry 10 --kind named
  base="$(zsh "$CS" dir --repo-dir "$R" --issue 10 | jq -r .base)"
  [ "$base" = "$BASE" ]
  [ -f "$QF" ]
  [ "$(jq -r .schema "$QF")" = "chain-queue/v1" ]
  [ "$(jq -r .named "$QF")" = "10" ]
}

@test "order: blockers deepest-first, then the named issue, then follow-ups first-filed first" {
  q add --entry 10 --kind named >/dev/null
  q add --entry 3 --kind blocker --depth 1 >/dev/null
  q add --entry 2 --kind blocker --depth 2 >/dev/null
  q add --entry 4 --kind blocker --depth 1 >/dev/null
  q add --entry 20 --kind follow-up --after 10 --finding "$(fnd a 1 x)" >/dev/null
  q add --entry 21 --kind follow-up --after 10 --finding "$(fnd b null y)" >/dev/null
  [ "$(order)" = "[2,3,4,10,20,21]" ]
}

@test "a follow-up's follow-ups go after it, and its own blockers go directly before it" {
  q add --entry 10 --kind named >/dev/null
  q add --entry 20 --kind follow-up --after 10 --finding "$(fnd a 1 x)" >/dev/null
  q add --entry 21 --kind follow-up --after 10 --finding "$(fnd b 2 y)" >/dev/null
  q add --entry 30 --kind follow-up --after 20 --finding "$(fnd c 3 z)" >/dev/null
  q add --entry 25 --kind blocker --before 30 >/dev/null
  q add --entry 31 --kind follow-up --after 20 --finding "$(fnd d 4 w)" >/dev/null
  [ "$(order)" = "[10,20,25,30,31,21]" ]
}

@test "each entry records its issue, kind, state, PR and, for a follow-up, its finding identity" {
  q add --entry 10 --kind named >/dev/null
  q add --entry 20 --kind follow-up --after 10 --finding '{"file":"a.md","line":7,"dimension":"tests","title":"t","extra":1}' >/dev/null
  run -0 jq -c '.entries[1] | {issue, kind, state, pr, filed_by, finding}' "$QF"
  [ "$output" = '{"issue":20,"kind":"follow-up","state":"queued","pr":null,"filed_by":10,"finding":{"file":"a.md","line":7,"dimension":"tests","title":"t"}}' ]
  run -0 jq -c '.entries[0] | {kind, finding}' "$QF"
  [ "$output" = '{"kind":"named","finding":null}' ]
}

@test "an issue already queued is not added twice, and add --pr records its PR" {
  q add --entry 10 --kind named >/dev/null
  q add --entry 10 --kind named --pr 55 >/dev/null
  [ "$(jq '.entries | length' "$QF")" = "1" ]
  [ "$(jq '.entries[0].pr' "$QF")" = "55" ]
  q add --entry 20 --kind follow-up --after 10 --finding "$(fnd a 1 x)" >/dev/null
  run -0 q add --entry 20 --pr 56
  [ "$(jq '.entries[1].pr' "$QF")" = "56" ]
}

@test "next prints the first entry not done; done marks it; an empty queue is the done condition (exit 4)" {
  q add --entry 10 --kind named >/dev/null
  q add --entry 3 --kind blocker >/dev/null
  run -0 q next
  [ "$(jq -r .issue <<< "$output")" = "3" ]
  q done --entry 3 --pr 100 >/dev/null
  run -0 q next
  [ "$(jq -r .issue <<< "$output")" = "10" ]
  q done --entry 10 --pr 101 >/dev/null
  run -4 q next
  contains "$output" "the queue is empty"
}

@test "next on a missing queue file is an empty queue, not an error" {
  run -4 q next
  [ ! -e "$QF" ]
}

@test "report: the stopping issue and reason, every merged PR, every issue still queued" {
  q add --entry 10 --kind named >/dev/null
  q add --entry 3 --kind blocker --depth 2 >/dev/null
  q add --entry 4 --kind blocker >/dev/null
  q add --entry 20 --kind follow-up --after 10 --finding "$(fnd a 1 x)" >/dev/null
  q done --entry 3 --pr 100 >/dev/null
  run -0 q report --stopped 4 --reason 'its CI will not go green'
  expected="$(printf '%s\n' 'chain stopped: #4 — its CI will not go green' 'Merged in this run: #100' 'Still queued: #4, #10, #20')"
  [ "$output" = "$expected" ]
}

@test "report: an epic-kind entry marked done without --pr adds no PR to the merged line" {
  q add --entry 10 --kind named >/dev/null
  q add --entry 20 --kind follow-up --after 10 --finding "$(fnd a 1 x)" >/dev/null
  q done --entry 10 >/dev/null
  run -0 q report --stopped 20 --reason 'it parked'
  expected="$(printf '%s\n' 'chain stopped: #20 — it parked' 'Merged in this run: none' 'Still queued: #20')"
  [ "$output" = "$expected" ]
}

@test "report --pause names the stop a pause, not a failure; an empty run reports none" {
  run -0 q report --stopped 10 --reason 'PR #7 awaits a merge' --pause
  expected="$(printf '%s\n' 'chain stopped: #10 (paused, not failed) — PR #7 awaits a merge' 'Merged in this run: none' 'Still queued: none')"
  [ "$output" = "$expected" ]
}

@test "a follow-up whose finding identity matches a resolved follow-up is refused as a cycle (exit 3), nothing written" {
  q add --entry 10 --kind named >/dev/null
  q add --entry 20 --kind follow-up --after 10 --finding "$(fnd a 1 x)" >/dev/null
  q done --entry 20 --pr 101 >/dev/null
  before="$(cat "$QF")"
  run -3 q add --entry 40 --kind follow-up --after 20 --finding "$(fnd a 1 x)"
  contains "$output" "follow-up cycle"
  [ "$(cat "$QF")" = "$before" ]
}

@test "a matching identity on a follow-up still queued, or a different identity, is not a cycle" {
  q add --entry 10 --kind named >/dev/null
  q add --entry 20 --kind follow-up --after 10 --finding "$(fnd a 1 x)" >/dev/null
  run -0 q add --entry 40 --kind follow-up --after 20 --finding "$(fnd a 1 x)"
  q done --entry 20 >/dev/null
  run -0 q add --entry 41 --kind follow-up --after 20 --finding "$(fnd a 2 x)"
}

@test "clear deletes the queue file; clean-stop.zsh clear keeps it and removes everything else" {
  q add --entry 10 --kind named >/dev/null
  mkdir -p "$BASE/work-dir"; : > "$BASE/status.json"; : > "$BASE/.ledger"
  run -0 zsh "$CS" clear --repo-dir "$R" --issue 10
  [ -f "$QF" ]
  [ "$(ls -A "$BASE")" = "chain-queue.json" ]
  run -0 q clear
  [ ! -e "$BASE" ]
  run -0 q clear
  q add --entry 10 --kind named >/dev/null
  : > "$BASE/status.json"
  run -0 q clear
  [ ! -e "$QF" ]
  [ -f "$BASE/status.json" ]
}

@test "checkpoint.zsh supersede moves kept state aside and leaves the queue file in the base" {
  q add --entry 10 --kind named >/dev/null
  : > "$BASE/clean-stop.json"
  git init -q --bare "$BATS_TEST_TMPDIR/remote.git"
  run -0 --separate-stderr zsh "$SCRIPTS/checkpoint.zsh" supersede --repo-dir "$R" --issue 10 \
    --branch feat/10-x --remote "$BATS_TEST_TMPDIR/remote.git"
  [ -f "$QF" ]
  [ -e "$(jq -r .superseded_to <<<"$output")/clean-stop.json" ]
}

@test "without a queue file clean-stop.zsh clear still removes the whole directory" {
  mkdir -p "$BASE/work-dir"
  run -0 zsh "$CS" clear --repo-dir "$R" --issue 10
  [ ! -e "$BASE" ]
}

@test "usage errors exit 2" {
  run -2 q add --entry 10
  run -2 q add --entry 10 --kind epic
  run -2 q add --entry 11 --kind named
  run -2 q add --entry 20 --kind follow-up --after 10
  run -2 q add --entry 20 --kind follow-up --after 10 --finding '{"file":"a"}'
  run -2 q add --entry 3 --kind blocker --after 10
  run -2 q add --entry 3 --kind named --before 10
  run -2 q done
  run -2 q report --stopped 4
  run -2 q next --entry 4
  run -2 zsh "$Q" bogus --repo-dir "$R" --issue 10
  run -2 zsh "$Q" next --repo-dir "$R" --issue 010
}

@test "an anchor naming no queued entry, or done on an unknown entry, exits 5" {
  q add --entry 10 --kind named >/dev/null
  run -5 q add --entry 20 --kind follow-up --after 99 --finding "$(fnd a 1 x)"
  run -5 q add --entry 3 --kind blocker --before 99
  run -5 q done --entry 99
}

@test "a queue file that is not chain-queue/v1 is refused (exit 1)" {
  mkdir -p "$BASE"; echo '{"schema":"other"}' > "$QF"
  run -1 q next
  contains "$output" "not a chain-queue/v1 document"
}

@test "each usage refusal names its cause" {
  run -2 zsh "$Q"
  contains "$output" "usage: chain-queue.zsh"
  run -0 zsh "$Q" --help
  contains "$output" "usage: chain-queue.zsh"
  run -2 zsh "$Q" bogus --repo-dir "$R" --issue 10
  contains "$output" "unknown subcommand: bogus"
  run -2 q next --entry 4
  contains "$output" "--entry is not a flag of next"
  run -2 q next --nope
  contains "$output" "unknown flag: --nope"
  run -2 q next stray
  contains "$output" "unexpected argument: stray"
  run -2 zsh "$Q" next --repo-dir "$R"
  contains "$output" "usage: chain-queue.zsh"
  run -2 zsh "$Q" next --repo-dir "$BATS_TEST_TMPDIR/absent" --issue 10
  contains "$output" "--repo-dir is not a directory"
  run -2 q next --issue
  contains "$output" "--issue needs a value"
  run -2 zsh "$Q" next --repo-dir "$R" --issue 010
  contains "$output" "--issue must be an issue or PR number (got: 010)"
  run -2 q add --entry 10
  contains "$output" "add needs --entry and --kind"
  run -2 q add --entry 10 --kind epic
  contains "$output" "--kind must be blocker, named or follow-up (got: epic)"
  run -2 q add --entry 3 --kind blocker --depth 0
  contains "$output" "--depth must be a positive integer (got: 0)"
  run -2 q add --entry 3 --kind named --before 10
  contains "$output" "--before is for a blocker only"
  run -2 q add --entry 11 --kind named
  contains "$output" "the named entry must be --issue itself"
  run -2 q add --entry 20 --kind follow-up --after 10
  contains "$output" "a follow-up needs --after and --finding"
  run -2 q add --entry 3 --kind blocker --after 10
  contains "$output" "--after and --finding are for a follow-up only"
  run -2 q add --entry 20 --kind follow-up --after 10 --finding '{"file":"a"}'
  contains "$output" "--finding must be a JSON object {file, line, dimension, title}"
  run -2 q done
  contains "$output" "done needs --entry"
  run -2 q report --stopped 4
  contains "$output" "report needs --stopped and --reason"
}

@test "an already-queued add without --pr leaves the entry as it was and exits 0" {
  q add --entry 10 --kind named --pr 5 >/dev/null
  run -0 q add --entry 10 --kind named
  [ "$(jq '.entries[0].pr' "$QF")" = "5" ]
}

# --- #3078: the approval wait and the last-entry close-out --------------------

# bounded-wait.zsh pr against a gh stub. Each gh call takes the next line of
# $GH_STATES (the last line repeats).
pr_stub() {
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export GH_STATES="$BATS_TEST_TMPDIR/states" GH_CALLS="$BATS_TEST_TMPDIR/calls"
  printf '%s\n' "$@" > "$GH_STATES"; : > "$GH_CALLS"
  cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
n=$(wc -l < "$GH_CALLS"); total=$(wc -l < "$GH_STATES")
(( n > total )) && n=$total
printf '{"state":"%s"}\n' "$(sed -n "${n}p" "$GH_STATES")"
SH
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH"
  BW="$SCRIPTS/bounded-wait.zsh"
}

@test "#3078 AC5: a PR awaiting approval that merges within the wait ends merged, exit 0" {
  pr_stub OPEN OPEN MERGED
  run --separate-stderr zsh "$BW" pr --repo Acme/Widget --pr 41 --timeout-s 30 --interval-s 0
  [ "$status" -eq 0 ]
  [ "$(jq -r .result <<<"$output")" = merged ]
  [ "$(jq -r .kind <<<"$output")" = pr ]
  run grep -cx 'pr view 41 --repo Acme/Widget --json state' "$GH_CALLS"
  [ "$output" = 3 ]
}

@test "#3078 AC5: a PR still unmerged at the bound ends timeout, exit 3 — the --pause stop" {
  pr_stub OPEN
  run --separate-stderr zsh "$BW" pr --repo Acme/Widget --pr 41 --timeout-s 1 --interval-s 1
  [ "$status" -eq 3 ]
  [ "$(jq -r .result <<<"$output")" = timeout ]
}

@test "#3078 AC5: a PR already merged is not waited on" {
  pr_stub MERGED
  run --separate-stderr zsh "$BW" pr --repo Acme/Widget --pr 41 --timeout-s 600 --interval-s 60
  [ "$status" -eq 0 ]
  [ "$(jq -r .result <<<"$output")" = already-merged ]
  [ "$(jq -r .reads <<<"$output")" = 1 ]
}

@test "#3078: a PR closed without merging ends closed-unmerged, exit 4" {
  pr_stub OPEN CLOSED
  run --separate-stderr zsh "$BW" pr --repo Acme/Widget --pr 41 --timeout-s 30 --interval-s 0
  [ "$status" -eq 4 ]
  [ "$(jq -r .result <<<"$output")" = closed-unmerged ]
}

@test "#3078: a PR already closed without merging on the first read is closed-unmerged, never already-merged" {
  pr_stub CLOSED
  run --separate-stderr zsh "$BW" pr --repo Acme/Widget --pr 41 --timeout-s 600 --interval-s 60
  [ "$status" -eq 4 ]
  [ "$(jq -r .result <<<"$output")" = closed-unmerged ]
  [ "$(jq -r .reads <<<"$output")" = 1 ]
}

@test "#3078 AC3: close-out of the last paused entry marks it done and clears the queue, asking nothing" {
  q add --entry 10 --kind named --pr 41 >/dev/null
  run --separate-stderr q report --stopped 10 --reason 'PR #41 awaits a merge' --pause
  [ -f "$QF" ]
  run -0 --separate-stderr q close-out --entry 10 --pr 41
  [ "$(jq -c . <<<"$output")" = '{"cleared":true,"next":null}' ]
  [ ! -e "$QF" ]
  run q next
  [ "$status" -eq 4 ]
}

@test "#3078: close-out of an entry with more queued records its PR and prints the next entry" {
  q add --entry 3 --kind blocker >/dev/null
  q add --entry 10 --kind named >/dev/null
  run -0 --separate-stderr q close-out --entry 3 --pr 40
  [ "$(jq -r .cleared <<<"$output")" = false ]
  [ "$(jq -r .next.issue <<<"$output")" = 10 ]
  [ "$(jq -c '[.entries[] | {issue, state, pr}]' "$QF")" = '[{"issue":3,"state":"done","pr":40},{"issue":10,"state":"queued","pr":null}]' ]
}

@test "#3078: close-out needs --entry and --pr, and refuses an unknown entry" {
  q add --entry 10 --kind named >/dev/null
  run --separate-stderr q close-out --entry 10
  [ "$status" -eq 2 ]
  run --separate-stderr q close-out --pr 41
  [ "$status" -eq 2 ]
  run --separate-stderr q close-out --entry 99 --pr 41
  [ "$status" -eq 5 ]
  [ -f "$QF" ]
}
