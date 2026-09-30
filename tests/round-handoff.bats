#!/usr/bin/env bats
#
# round-handoff.zsh (#1934, epic #1933) — the write/read door for the review
# loop's round-handoff/v1 and round-verdict/v1 files. Two halves:
#
#   - a write -> read round-trip for every panel mode, both fix triggers, the
#     decide handoff, and every verdict kind (panel not_applicable included);
#   - one case per validator rejection, each asserting exit 3, exactly one
#     `round-handoff:` stderr line, and — for a writer — no file written.
#
# Every fixture is a valid object built by a helper and then broken by ONE jq
# edit, so each rejection case differs from a passing round-trip by exactly the
# rule under test.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/round-handoff.zsh"
  WD="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WD"
  # The script resolves paths with :A, so compare against the resolved form
  # (macOS puts TMPDIR under a /var -> /private/var symlink).
  WD_REAL="$(cd "$WD" && pwd -P)"
}

# --- valid fixtures ---------------------------------------------------------

panel_handoff() { # $1 = mode
  local entries='[]'
  [ "$1" = round ] || entries='[{"file":"development/skills/resolve-issue/reference/review-loop.md","dimension":"prose_logic","title":"Carry arm names no stop"}]'
  jq -n --arg wd "$WD" --arg mode "$1" --argjson entries "$entries" '{
    schema: "round-handoff/v1", kind: "panel", round: 3, tree_id: "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
    work_dir: $wd, status_file: "/tmp/resolve-1934/status.json",
    mode: $mode, delta_base: null, carried_finding_ids: ["f-12"], carry_entries: $entries }'
}

fix_handoff() { # $1 = trigger
  jq -n --arg wd "$WD" --arg trig "$1" '{
    schema: "round-handoff/v1", kind: "fix", round: 2, tree_id: "9f3c1e7a",
    work_dir: $wd, status_file: "/tmp/resolve-1934/status.json",
    trigger: $trig, grant: {rounds: 2, severity_bar: "CRITICAL"}, guidance: null,
    rule2_mandatory: false, profile_fix_rules: "development-claude-plugin:resolve-profile § Fix-pass rules" }
    + (if $trig == "awaiting-fix" then {changelist: ($wd + "/changelist-2.json")}
       else {gate_log: ($wd + "/gate-2.log")} end)'
}

decide_handoff() {
  jq -n --arg wd "$WD" '{
    schema: "round-handoff/v1", kind: "decide", round: 4, tree_id: "c0ffee42",
    work_dir: $wd, status_file: "/tmp/resolve-1934/status.json",
    aggregate_findings_file: ($wd + "/findings-round-4.json"),
    worktree_root: "/Users/dev/repos/plugins/.claude/worktrees/tidy-otter",
    retired_file: ($wd + "/decides-retired.txt") }'
}

panel_verdict_ok() {
  jq -n --arg wd "$WD" '{
    schema: "round-verdict/v1", kind: "panel", round: 3, outcome: "ok", cause: null,
    aggregate_findings_file: ($wd + "/findings-round-3.json"),
    carry_accounting_file: ($wd + "/carry-round-3.json"),
    carry_lines_file: ($wd + "/carry-lines-3.txt"), findings_count: 7 }'
}

panel_verdict_na() {
  jq -n '{
    schema: "round-verdict/v1", kind: "panel", round: 3, outcome: "not_applicable", cause: "not-applicable",
    aggregate_findings_file: null, carry_accounting_file: null, carry_lines_file: null, findings_count: null }'
}

fix_verdict_ok() {
  jq -n '{ schema: "round-verdict/v1", kind: "fix", round: 2, outcome: "ok", cause: null,
    fix_applied: true, files_changed: 3 }'
}

decide_verdict_ok() {
  jq -n --arg wd "$WD" '{
    schema: "round-verdict/v1", kind: "decide", round: 4, outcome: "ok", cause: null,
    decided_red: 1, decided_green: 3, malformed: 0, ran_commands_file: ($wd + "/decides-ran-4.txt") }'
}

# --- drivers ----------------------------------------------------------------

# write <handoff|verdict> <json>
write() {
  run --separate-stderr zsh "$S" "write-$1" --work-dir "$WD" <<<"$2"
}

# Assert a contract rejection: exit 3, one `round-handoff:` stderr line naming
# $1, nothing on stdout, and no handoff/verdict file left in the work-dir.
rejected() {
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  starts_with "$stderr" "round-handoff: "
  contains "$stderr" "$1"
  [ -z "$(find "$WD" -name '*.json' -print)" ]
}

# round_trip <handoff|verdict> <json> <expected file name>
round_trip() {
  write "$1" "$2"
  [ "$status" -eq 0 ]
  [ "$output" = "$WD_REAL/$3" ]
  [ -f "$WD/$3" ]
  run --separate-stderr zsh "$S" "read-$1" --file "$WD/$3"
  [ "$status" -eq 0 ]
  [ "$(jq -S . <<<"$output")" = "$(jq -S . <<<"$2")" ]
}

# --- round-trips ------------------------------------------------------------

@test "round-trip: panel handoff, mode round" {
  round_trip handoff "$(panel_handoff round)" handoff-3-panel.json
}

@test "round-trip: panel handoff, mode carry-redispatch" {
  round_trip handoff "$(panel_handoff carry-redispatch)" handoff-3-panel.json
}

@test "round-trip: panel handoff, mode carry-repair" {
  round_trip handoff "$(panel_handoff carry-repair)" handoff-3-panel.json
}

@test "round-trip: fix handoff, trigger awaiting-fix" {
  round_trip handoff "$(fix_handoff awaiting-fix)" handoff-2-fix.json
}

@test "round-trip: fix handoff, trigger gate-red" {
  round_trip handoff "$(fix_handoff gate-red)" handoff-2-fix.json
}

@test "round-trip: fix handoff with an explicit null changelist under gate-red" {
  round_trip handoff "$(fix_handoff gate-red | jq '.changelist = null')" handoff-2-fix.json
}

@test "round-trip: fix handoff with an explicit null gate_log under awaiting-fix" {
  round_trip handoff "$(fix_handoff awaiting-fix | jq '.gate_log = null')" handoff-2-fix.json
}

@test "round-trip: panel handoff with a string delta_base" {
  round_trip handoff "$(panel_handoff round | jq '.delta_base = "f2760859"')" handoff-3-panel.json
}

@test "round-trip: fix handoff with no grant, a guidance string and no profile rules" {
  round_trip handoff "$(fix_handoff awaiting-fix | jq '.grant = null | .guidance = "Suggestion unless it names a mutation" | .profile_fix_rules = null')" handoff-2-fix.json
}

@test "round-trip: a failed panel verdict carries every cause in the panel set" {
  local c
  for c in dimension-not-run render-failed fix-verification-null fix-verification-unreadable \
    carry-unconfirmed plan-failed wrong-worktree-root empty-excerpt story-diff-empty \
    not-applicable no-agent-tool; do
    round_trip verdict "$(panel_verdict_na | jq --arg c "$c" '.outcome = "failed" | .cause = $c')" verdict-3-panel.json
  done
}

@test "round-trip: decide handoff" {
  round_trip handoff "$(decide_handoff)" handoff-4-decide.json
}

@test "round-trip: panel verdict ok" {
  round_trip verdict "$(panel_verdict_ok)" verdict-3-panel.json
}

@test "round-trip: panel verdict ok with no carry (both carry files null)" {
  round_trip verdict "$(panel_verdict_ok | jq '.carry_accounting_file = null | .carry_lines_file = null')" verdict-3-panel.json
}

@test "round-trip: panel verdict not_applicable" {
  round_trip verdict "$(panel_verdict_na)" verdict-3-panel.json
}

@test "round-trip: panel verdict failed" {
  round_trip verdict "$(panel_verdict_na | jq '.outcome = "failed" | .cause = "dimension-not-run"')" verdict-3-panel.json
}

@test "round-trip: fix verdict ok" {
  round_trip verdict "$(fix_verdict_ok)" verdict-2-fix.json
}

@test "round-trip: fix verdict cannot-fix" {
  round_trip verdict "$(fix_verdict_ok | jq '.outcome = "failed" | .cause = "cannot-fix" | .fix_applied = false | .files_changed = 0')" verdict-2-fix.json
}

@test "round-trip: decide verdict ok" {
  round_trip verdict "$(decide_verdict_ok)" verdict-4-decide.json
}

@test "round-trip: decide verdict failed" {
  round_trip verdict "$(decide_verdict_ok | jq '.outcome = "failed" | .cause = "wrong-worktree-root" | .decided_red = null | .decided_green = null | .malformed = null | .ran_commands_file = null')" verdict-4-decide.json
}

@test "write overwrites an existing file atomically and leaves no temp file" {
  write handoff "$(decide_handoff)"
  [ "$status" -eq 0 ]
  write handoff "$(decide_handoff | jq '.tree_id = "deadbeef"')"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tree_id "$WD/handoff-4-decide.json")" = deadbeef ]
  [ "$(find "$WD" -name '.*' -type f -print | wc -l | tr -d ' ')" -eq 0 ]
}

# --- rejections: schema, kind, mode, trigger ---------------------------------

@test "rejects an unknown handoff schema" {
  write handoff "$(decide_handoff | jq '.schema = "round-handoff/v2"')"
  rejected "unknown schema"
}

@test "rejects an unknown verdict schema" {
  write verdict "$(fix_verdict_ok | jq '.schema = "round-handoff/v1"')"
  rejected "unknown schema"
}

@test "rejects an unknown kind" {
  write handoff "$(decide_handoff | jq '.kind = "judge"')"
  rejected "unknown kind"
}

@test "rejects a kind that is only a substring of a real one" {
  write handoff "$(panel_handoff round | jq '.kind = "pan"')"
  rejected "unknown kind"
}

@test "rejects an unknown mode" {
  write handoff "$(panel_handoff round | jq '.mode = "carry-rebuild"')"
  rejected "unknown mode"
}

@test "rejects an unknown trigger" {
  write handoff "$(fix_handoff gate-red | jq '.trigger = "gate-flaky"')"
  rejected "unknown trigger"
}

# --- rejections: key presence -----------------------------------------------

@test "rejects a missing common field" {
  write handoff "$(decide_handoff | jq 'del(.tree_id)')"
  rejected "missing field: tree_id"
}

@test "rejects a missing mode on a panel handoff" {
  write handoff "$(panel_handoff round | jq 'del(.mode)')"
  rejected "missing field: mode"
}

@test "rejects an omitted or-null field (delta_base) as missing" {
  write handoff "$(panel_handoff round | jq 'del(.delta_base)')"
  rejected "missing field: delta_base"
}

@test "rejects an omitted or-null verdict field (cause) as missing" {
  write verdict "$(fix_verdict_ok | jq 'del(.cause)')"
  rejected "missing field: cause"
}

@test "rejects a missing changelist on trigger awaiting-fix" {
  write handoff "$(fix_handoff awaiting-fix | jq 'del(.changelist)')"
  rejected "missing field: changelist"
}

@test "rejects a missing gate_log on trigger gate-red" {
  write handoff "$(fix_handoff gate-red | jq 'del(.gate_log)')"
  rejected "missing field: gate_log"
}

@test "rejects a null changelist on trigger awaiting-fix" {
  write handoff "$(fix_handoff awaiting-fix | jq '.changelist = null')"
  rejected "changelist is not an absolute path"
}

@test "rejects a null gate_log on trigger gate-red" {
  write handoff "$(fix_handoff gate-red | jq '.gate_log = null')"
  rejected "gate_log is not an absolute path"
}

@test "rejects a non-null changelist under trigger gate-red" {
  write handoff "$(fix_handoff gate-red | jq --arg wd "$WD" '.changelist = ($wd + "/changelist-2.json")')"
  rejected "changelist is set on trigger gate-red"
}

@test "rejects a non-null gate_log under trigger awaiting-fix" {
  write handoff "$(fix_handoff awaiting-fix | jq --arg wd "$WD" '.gate_log = ($wd + "/gate-2.log")')"
  rejected "gate_log is set on trigger awaiting-fix"
}

@test "rejects a null in a field that is not or-null (tree_id)" {
  write handoff "$(decide_handoff | jq '.tree_id = null')"
  rejected "tree_id is not a non-empty string"
}

@test "rejects an unlisted key on a handoff" {
  write handoff "$(panel_handoff round | jq '.findings = []')"
  rejected "unlisted key for kind panel: findings"
}

@test "rejects an unlisted key on a verdict (no finding text)" {
  write verdict "$(panel_verdict_ok | jq '.summary = "3 blockers in review-loop.md"')"
  rejected "unlisted key for kind panel: summary"
}

@test "rejects another kind's field as unlisted" {
  write handoff "$(decide_handoff | jq '.mode = "round"')"
  rejected "unlisted key for kind decide: mode"
}

# --- rejections: round -------------------------------------------------------

@test "rejects round 0" {
  write handoff "$(decide_handoff | jq '.round = 0')"
  rejected "round is not an integer >= 1"
}

@test "rejects a fractional round" {
  write verdict "$(fix_verdict_ok | jq '.round = 1.5')"
  rejected "round is not an integer >= 1"
}

@test "rejects a string round" {
  write verdict "$(fix_verdict_ok | jq '.round = "2"')"
  rejected "round is not an integer >= 1"
}

@test "read rejects a round that does not match the file name" {
  decide_verdict_ok | jq -c '.round = 5' > "$WD/verdict-4-decide.json"
  run --separate-stderr zsh "$S" read-verdict --file "$WD/verdict-4-decide.json"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "does not match its round and kind"
}

@test "read rejects a kind that does not match the file name" {
  fix_verdict_ok | jq -c . > "$WD/verdict-2-panel.json"
  run --separate-stderr zsh "$S" read-verdict --file "$WD/verdict-2-panel.json"
  [ "$status" -eq 3 ]
  contains "$stderr" "does not match its round and kind"
}

@test "read-handoff rejects a verdict file" {
  fix_verdict_ok | jq -c . > "$WD/verdict-2-fix.json"
  run --separate-stderr zsh "$S" read-handoff --file "$WD/verdict-2-fix.json"
  [ "$status" -eq 3 ]
  contains "$stderr" "unknown schema"
}

# --- rejections: types --------------------------------------------------------

@test "rejects a non-bool rule2_mandatory" {
  write handoff "$(fix_handoff gate-red | jq '.rule2_mandatory = "false"')"
  rejected "rule2_mandatory is not a bool"
}

@test "rejects a negative count" {
  write verdict "$(fix_verdict_ok | jq '.files_changed = -1')"
  rejected "files_changed is not a non-negative integer"
}

@test "rejects a fractional findings_count" {
  write verdict "$(panel_verdict_ok | jq '.findings_count = 1.5')"
  rejected "findings_count is not a non-negative integer"
}

@test "rejects a non-integer decide count on ok" {
  write verdict "$(decide_verdict_ok | jq '.malformed = "0"')"
  rejected "are not non-negative integers on outcome ok"
}

@test "rejects a carry_entries item without a title" {
  write handoff "$(panel_handoff carry-repair | jq '.carry_entries[0] |= del(.title)')"
  rejected "carry_entries item lacks string file, dimension and title"
}

@test "rejects a carry_entries item that is a bare string" {
  write handoff "$(panel_handoff carry-repair | jq '.carry_entries = ["review-loop.md"]')"
  rejected "carry_entries item lacks string file, dimension and title"
}

@test "rejects a relative path" {
  write handoff "$(decide_handoff | jq '.worktree_root = "worktrees/tidy-otter"')"
  rejected "worktree_root is not an absolute path"
}

@test "rejects a relative status_file" {
  write handoff "$(panel_handoff round | jq '.status_file = "status.json"')"
  rejected "status_file is not an absolute path"
}

@test "rejects a malformed grant" {
  write handoff "$(fix_handoff gate-red | jq '.grant = {rounds: 2}')"
  rejected "grant is not {rounds, severity_bar} or null"
}

@test "rejects a grant of zero rounds" {
  write handoff "$(fix_handoff gate-red | jq '.grant.rounds = 0')"
  rejected "grant is not {rounds, severity_bar} or null"
}

@test "rejects a non-string guidance" {
  write handoff "$(fix_handoff gate-red | jq '.guidance = 5')"
  rejected "guidance is not a string or null"
}

@test "rejects a non-string profile_fix_rules" {
  write handoff "$(fix_handoff gate-red | jq '.profile_fix_rules = 3')"
  rejected "profile_fix_rules is not a string or null"
}

@test "rejects a non-string delta_base" {
  write handoff "$(panel_handoff round | jq '.delta_base = 5')"
  rejected "delta_base is not a string or null"
}

# --- rejections: conditional rules ---------------------------------------------

@test "rejects empty carry_entries in mode carry-redispatch" {
  write handoff "$(panel_handoff carry-redispatch | jq '.carry_entries = []')"
  rejected "carry_entries is empty in mode carry-redispatch"
}

@test "rejects empty carry_entries in mode carry-repair" {
  write handoff "$(panel_handoff carry-repair | jq '.carry_entries = []')"
  rejected "carry_entries is empty in mode carry-repair"
}

@test "rejects non-empty carry_entries in mode round" {
  write handoff "$(panel_handoff carry-repair | jq '.mode = "round"')"
  rejected "carry_entries is non-empty in mode round"
}

@test "rejects an unknown outcome" {
  write verdict "$(fix_verdict_ok | jq '.outcome = "partial"')"
  rejected "unknown outcome"
}

@test "rejects a cause outside the kind's closed set" {
  write verdict "$(fix_verdict_ok | jq '.outcome = "failed" | .cause = "dimension-not-run" | .fix_applied = false | .files_changed = 0')"
  rejected "unknown cause for kind fix"
}

@test "rejects a fix cause on a panel verdict" {
  write verdict "$(panel_verdict_na | jq '.outcome = "failed" | .cause = "cannot-fix"')"
  rejected "unknown cause for kind panel"
}

@test "rejects a panel cause on a decide verdict" {
  write verdict "$(decide_verdict_ok | jq '.outcome = "failed" | .cause = "render-failed" | .decided_red = null | .decided_green = null | .malformed = null | .ran_commands_file = null')"
  rejected "unknown cause for kind decide"
}

@test "rejects not_applicable on a non-panel kind" {
  write verdict "$(fix_verdict_ok | jq '.outcome = "not_applicable" | .cause = "cannot-fix"')"
  rejected "outcome not_applicable on kind fix"
}

@test "rejects a missing cause on a non-ok outcome" {
  write verdict "$(panel_verdict_na | jq '.outcome = "failed" | .cause = null')"
  rejected "cause is missing on outcome failed"
}

@test "rejects a non-null cause on ok" {
  write verdict "$(panel_verdict_ok | jq '.cause = "render-failed"')"
  rejected "cause is set on outcome ok"
}

# --- rejections: nullability ---------------------------------------------------

@test "rejects carry_lines_file null while carry_accounting_file is set" {
  write verdict "$(panel_verdict_ok | jq '.carry_lines_file = null')"
  rejected "are not null together"
}

@test "rejects a null findings_count on ok" {
  write verdict "$(panel_verdict_ok | jq '.findings_count = null')"
  rejected "findings_count is not a non-negative integer on outcome ok"
}

@test "rejects a null aggregate_findings_file on an ok panel verdict" {
  write verdict "$(panel_verdict_ok | jq '.aggregate_findings_file = null')"
  rejected "aggregate_findings_file is not an absolute path on outcome ok"
}

@test "rejects an aggregate_findings_file on a non-ok panel verdict" {
  write verdict "$(panel_verdict_na | jq --arg wd "$WD" '.aggregate_findings_file = ($wd + "/findings-round-3.json")')"
  rejected "aggregate_findings_file is set on outcome not_applicable"
}

@test "rejects a findings_count on a non-ok panel verdict" {
  write verdict "$(panel_verdict_na | jq '.findings_count = 0')"
  rejected "findings_count is set on outcome not_applicable"
}

@test "rejects a null decide count on ok" {
  write verdict "$(decide_verdict_ok | jq '.decided_red = null')"
  rejected "are not non-negative integers on outcome ok"
}

@test "rejects a decide count on failed" {
  write verdict "$(decide_verdict_ok | jq '.outcome = "failed" | .cause = "wrong-worktree-root" | .decided_green = null | .malformed = null | .ran_commands_file = null')"
  rejected "are not null on outcome failed"
}

@test "rejects a null fix_applied" {
  write verdict "$(fix_verdict_ok | jq '.fix_applied = null')"
  rejected "fix_applied is not a bool"
}

@test "rejects a cannot-fix verdict that claims a change" {
  write verdict "$(fix_verdict_ok | jq '.outcome = "failed" | .cause = "cannot-fix"')"
  rejected "must carry fix_applied false and files_changed 0"
}

# --- rejections: containment ---------------------------------------------------

@test "rejects a .. escape of aggregate_findings_file on the decide handoff" {
  write handoff "$(decide_handoff | jq --arg wd "$WD" '.aggregate_findings_file = ($wd + "/../findings-round-4.json")')"
  rejected "path resolves outside the work-dir"
}

@test "rejects a .. escape of aggregate_findings_file on the panel verdict" {
  write verdict "$(panel_verdict_ok | jq --arg wd "$WD" '.aggregate_findings_file = ($wd + "/../findings-round-3.json")')"
  rejected "path resolves outside the work-dir"
}

@test "rejects a symlink escape of aggregate_findings_file on the decide handoff" {
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  ln -s "$BATS_TEST_TMPDIR/outside" "$WD/link"
  write handoff "$(decide_handoff | jq --arg wd "$WD" '.aggregate_findings_file = ($wd + "/link/findings-round-4.json")')"
  rejected "path resolves outside the work-dir"
}

@test "rejects a symlink escape of aggregate_findings_file on the panel verdict" {
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  ln -s "$BATS_TEST_TMPDIR/outside" "$WD/link"
  write verdict "$(panel_verdict_ok | jq --arg wd "$WD" '.aggregate_findings_file = ($wd + "/link/findings-round-3.json")')"
  rejected "path resolves outside the work-dir"
}

@test "rejects a carry_accounting_file outside the work-dir" {
  write verdict "$(panel_verdict_ok | jq '.carry_accounting_file = "/tmp/carry-round-3.json"')"
  rejected "path resolves outside the work-dir"
}

@test "rejects a carry_lines_file outside the work-dir" {
  write verdict "$(panel_verdict_ok | jq '.carry_lines_file = "/tmp/carry-lines-3.txt"')"
  rejected "path resolves outside the work-dir"
}

@test "rejects a ran_commands_file outside the work-dir" {
  write verdict "$(decide_verdict_ok | jq '.ran_commands_file = "/tmp/decides-ran-4.txt"')"
  rejected "path resolves outside the work-dir"
}

@test "rejects the work-dir itself as a contained path (strictly under)" {
  write verdict "$(decide_verdict_ok | jq --arg wd "$WD" '.ran_commands_file = $wd')"
  rejected "path resolves outside the work-dir"
}

@test "read rejects a verdict whose path field resolves outside its directory" {
  decide_verdict_ok | jq -c '.ran_commands_file = "/tmp/decides-ran-4.txt"' > "$WD/verdict-4-decide.json"
  run --separate-stderr zsh "$S" read-verdict --file "$WD/verdict-4-decide.json"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "path resolves outside the work-dir"
}

@test "rejects a handoff whose work_dir is not the directory it is written to" {
  mkdir -p "$BATS_TEST_TMPDIR/other"
  write handoff "$(decide_handoff | jq --arg o "$BATS_TEST_TMPDIR/other" '.work_dir = $o')"
  rejected "is not the directory the file is in"
}

@test "read rejects a handoff whose work_dir is not the directory it sits in" {
  mkdir -p "$BATS_TEST_TMPDIR/moved"
  decide_handoff | jq -c . > "$BATS_TEST_TMPDIR/moved/handoff-4-decide.json"
  run --separate-stderr zsh "$S" read-handoff --file "$BATS_TEST_TMPDIR/moved/handoff-4-decide.json"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "is not the directory the file is in"
}

# --- rejections: input and files -----------------------------------------------

@test "read exits 3 on a missing file" {
  run --separate-stderr zsh "$S" read-verdict --file "$WD/verdict-9-panel.json"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  starts_with "$stderr" "round-handoff: file missing or unreadable"
}

@test "read exits 3 on an unreadable file" {
  decide_verdict_ok | jq -c . > "$WD/verdict-4-decide.json"
  chmod 000 "$WD/verdict-4-decide.json"
  if [ -r "$WD/verdict-4-decide.json" ]; then skip "running as a user the permission barrier does not bind"; fi
  run --separate-stderr zsh "$S" read-verdict --file "$WD/verdict-4-decide.json"
  chmod 600 "$WD/verdict-4-decide.json"
  [ "$status" -eq 3 ]
  starts_with "$stderr" "round-handoff: file missing or unreadable"
}

@test "a writer given invalid JSON exits 3 and writes no file" {
  write verdict '{"schema": "round-verdict/v1",'
  rejected "not exactly one valid JSON document"
}

@test "a writer given two documents exits 3 and writes no file" {
  write verdict "$(fix_verdict_ok) $(fix_verdict_ok)"
  rejected "not exactly one valid JSON document"
}

@test "a writer given a non-object exits 3 and writes no file" {
  write handoff '["handoff"]'
  rejected "not a JSON object"
}

# --- usage -------------------------------------------------------------------

@test "usage: an unknown subcommand exits 2" {
  run --separate-stderr zsh "$S" write-changelist --work-dir "$WD"
  [ "$status" -eq 2 ]
}

@test "usage: a writer without --work-dir exits 2" {
  run --separate-stderr zsh "$S" write-verdict <<<"$(fix_verdict_ok)"
  [ "$status" -eq 2 ]
}

@test "usage: a --work-dir that is not a directory exits 2" {
  run --separate-stderr zsh "$S" write-verdict --work-dir "$WD/nope" <<<"$(fix_verdict_ok)"
  [ "$status" -eq 2 ]
}

@test "usage: a dangling --file exits 2" {
  run --separate-stderr zsh "$S" read-handoff --file
  [ "$status" -eq 2 ]
}
