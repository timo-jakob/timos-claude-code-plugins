#!/usr/bin/env bats
#
# #3215: the record a scheduled /development:maintenance run leaves.
# write-run-record.zsh writes one maintenance-run/v1 file per repo per wave,
# atomically; post-maintenance-log.zsh posts it as one comment on the repo's
# standing Maintenance log issue and writes the comment URL back. `gh` is a
# stub that keeps the fixture repo's issues in $FIX; it sits FIRST on PATH, so
# a host copy of `gh` (the ubuntu runner ships one in /usr/bin) is never
# reached. Every login, repo and title here is invented.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GITHUB_ACTIONS GH_TOKEN
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/maintenance/scripts"
  WRITE="$SCRIPTS/write-run-record.zsh"
  POST="$SCRIPTS/post-maintenance-log.zsh"
  export FIX="$BATS_TEST_TMPDIR/fix"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  export MAINTENANCE_RUN_DIR="$BATS_TEST_TMPDIR/runs"
  REC="$MAINTENANCE_RUN_DIR/acme__widgets.json"
  mkdir -p "$FIX"
  printf '[]\n' > "$FIX/issues.json"
  [ -x "$WRITE" ]
  [ -x "$POST" ]
  stub_gh
}

# gh: logs argv. `issue list` serves $FIX/issues.json; `issue create` adds
# issue 77 to it and prints its URL; `issue comment` keeps the --body in
# $FIX/comment-<n>.md and prints the comment's URL. GH_FAIL=list|create|comment
# fails that call, GH_FAIL=all fails every call (GitHub unreachable); a failing
# call prints `gh: offline` on stderr.
stub_gh() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
fail() { [ "${GH_FAIL:-}" != "$1" ] || { echo "gh: offline" >&2; exit 1; }; }
fail all
case "$1 $2" in
  "issue list") fail list; cat "$FIX/issues.json" ;;
  "label create") exit 0 ;;
  "issue create")
    fail create
    printf '[{"number":77,"title":"Maintenance log"}]\n' > "$FIX/issues.json"
    echo "https://github.com/acme/widgets/issues/77" ;;
  "issue comment")
    fail comment
    n=$(( $(ls "$FIX" | grep -c '^comment-') + 1 ))
    while [ $# -gt 0 ]; do
      [ "$1" != --body ] || printf '%s\n' "$2" > "$FIX/comment-$n.md"
      shift
    done
    echo "https://github.com/acme/widgets/issues/77#issuecomment-$n" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
}

summary() {
  cat > "$BATS_TEST_TMPDIR/summary.json" <<'EOF'
{"started_at": "2026-11-28T02:00:00Z", "ended_at": "2026-11-28T03:25:10Z",
 "concerns": {"security": {"merged": [{"number": 12, "title": "Bump | `left-pad` [x]",
                                       "url": "https://github.com/acme/widgets/pull/12", "note": "green"}],
                           "deferred": [{"number": null, "title": "semgrep group", "note": "cap"}]},
              "codequality": {"waiting": [{"number": 14, "title": "Tidy imports"}]}},
 "bugs": {"fixed": [{"number": 9, "title": "Crash on an empty cart"}],
          "awaiting_confirmation": [{"number": 10, "title": "Totals off by one"}]}}
EOF
}

write_record() {
  run --separate-stderr zsh "$WRITE" "$@"
}

# ---- write-run-record.zsh ---------------------------------------------------

@test "write: a completed run's summary becomes the full record shape" {
  summary
  write_record --repo acme/widgets --outcome completed --from "$BATS_TEST_TMPDIR/summary.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]
  [ "$(jq -r '[.schema, .repo, .outcome, .started_at, .ended_at] | join(" ")' "$REC")" = "maintenance-run/v1 acme/widgets completed 2026-11-28T02:00:00Z 2026-11-28T03:25:10Z" ]
  [ "$(jq -c 'keys' "$REC")" = '["bugs","concerns","ended_at","log_comment_url","outcome","reason","repo","schema","started_at"]' ]
  [ "$(jq -c '.concerns | keys_unsorted' "$REC")" = '["security","dependencies","bugs","codequality","topic"]' ]
  [ "$(jq -c '[.concerns[] | keys_unsorted] | unique' "$REC")" = '[["merged","opened","waiting","parked","deferred"]]' ]
  [ "$(jq -c '.bugs | keys_unsorted' "$REC")" = '["analysed","awaiting_confirmation","fixed","not_a_bug","not_eligible","not_reproducing"]' ]
  [ "$(jq -c '.concerns.codequality.waiting' "$REC")" = '[{"number":14,"title":"Tidy imports","url":null,"note":null}]' ]
  [ "$(jq -c '[.reason, .log_comment_url, (.concerns.topic.merged | length), (.bugs.fixed[0].number)]' "$REC")" = '[null,null,0,9]' ]
}

@test "write: each outcome writes a valid record with empty lists, and --reason is kept" {
  local o
  for o in completed cut-off could-not-start outside-window skipped-running; do
    write_record --repo acme/widgets --outcome "$o" --reason "because $o"
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.outcome, .reason] | join("/")' "$REC")" = "$o/because $o" ]
    [ "$(jq '[.concerns[][], .bugs[]] | map(length) | add' "$REC")" = "0" ]
    [ "$(jq '[.concerns[][]] | length' "$REC")" = "25" ]
    matches "$(jq -r .started_at "$REC")" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  done
  write_record --repo acme/widgets --outcome completed
  [ "$(jq -c .reason "$REC")" = "null" ]
}

@test "write: usage errors exit 2 and write nothing" {
  write_record --repo acme/widgets --outcome finished
  [ "$status" -eq 2 ]
  contains "$stderr" "--outcome must be one of"
  write_record --repo widgets --outcome completed
  [ "$status" -eq 2 ]
  write_record --repo acme/widgets --repo acme/other --outcome completed
  [ "$status" -eq 2 ]
  write_record --repo acme/widgets --outcome completed --bogus
  [ "$status" -eq 2 ]
  write_record --repo acme/widgets --outcome
  [ "$status" -eq 2 ]
  MAINTENANCE_RUN_DIR='' run --separate-stderr zsh "$WRITE" --repo acme/widgets --outcome completed
  [ "$status" -eq 2 ]
  contains "$stderr" "MAINTENANCE_RUN_DIR is not set"
  [ ! -e "$MAINTENANCE_RUN_DIR" ]
}

@test "write: a summary that is not valid exits 1 and leaves the earlier record as it was" {
  write_record --repo acme/widgets --outcome completed --reason first
  cp "$REC" "$BATS_TEST_TMPDIR/before.json"
  local bad
  for bad in 'not json' '[]' '{"concerns": {"style": {}}}' '{"concerns": {"security": {"merged": {}}}}' \
             '{"concerns": {"security": {"won": []}}}' '{"bugs": {"fixed": ["#9"]}}' '{"started_at": "last night"}' \
             '{"bugs": {"fixed": [{"number": "#12", "title": "x"}]}}' '{"bugs": {"fixed": [{"pr": 12, "title": "x"}]}}'; do
    printf '%s\n' "$bad" > "$BATS_TEST_TMPDIR/bad.json"
    write_record --repo acme/widgets --outcome completed --from "$BATS_TEST_TMPDIR/bad.json"
    [ "$status" -eq 1 ]
    contains "$stderr" "not a valid summary"
    cmp -s "$REC" "$BATS_TEST_TMPDIR/before.json"
  done
  write_record --repo acme/widgets --outcome completed --from "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 1 ]
  contains "$stderr" "cannot read"
}

@test "write: a writer killed midway leaves no partial record, and a rewrite leaves no temp file" {
  write_record --repo acme/widgets --outcome completed --reason first
  cp "$REC" "$BATS_TEST_TMPDIR/before.json"
  # the summary arrives half-written and the writer is killed while reading it;
  # the feeder then closes the pipe, so the orphaned reader ends too
  mkfifo "$BATS_TEST_TMPDIR/slow.json"
  ( printf '{"concerns":'; sleep 2 ) > "$BATS_TEST_TMPDIR/slow.json" 3>&- &
  zsh "$WRITE" --repo acme/widgets --outcome cut-off --from "$BATS_TEST_TMPDIR/slow.json" >/dev/null 2>&1 3>&- &
  local pid=$!
  sleep 1
  kill -9 "$pid"
  wait "$pid" || true
  cmp -s "$REC" "$BATS_TEST_TMPDIR/before.json"
  [ "$(ls -A "$MAINTENANCE_RUN_DIR")" = "acme__widgets.json" ]
  write_record --repo acme/widgets --outcome cut-off
  [ "$status" -eq 0 ]
  [ "$(jq -r .outcome "$REC")" = "cut-off" ]
  [ "$(ls -A "$MAINTENANCE_RUN_DIR")" = "acme__widgets.json" ]
}

# ---- post-maintenance-log.zsh -----------------------------------------------

@test "post: with no log issue it creates the label and the issue once, then reuses it" {
  summary
  write_record --repo acme/widgets --outcome completed --from "$BATS_TEST_TMPDIR/summary.json"
  run --separate-stderr zsh "$POST" "$REC"
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/acme/widgets/issues/77#issuecomment-1" ]
  [ "$(jq -r .log_comment_url "$REC")" = "$output" ]
  contains "$(cat "$GH_LOG")" "label create maintenance-log --repo acme/widgets"
  contains "$(cat "$GH_LOG")" "issue create --repo acme/widgets --title Maintenance log --label maintenance-log"
  run --separate-stderr zsh "$POST" "$REC"
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/acme/widgets/issues/77#issuecomment-2" ]
  [ "$(grep -c '^issue create' "$GH_LOG")" = "1" ]
  [ "$(grep -c '^issue comment 77 --repo acme/widgets' "$GH_LOG")" = "2" ]
  [ "$(grep -c 'issue close\|issue edit' "$GH_LOG")" = "0" ]
}

@test "post: it picks the lowest open issue titled exactly Maintenance log" {
  printf '%s\n' '[{"number":40,"title":"Maintenance log (old)"},{"number":31,"title":"Maintenance log"},{"number":25,"title":"Maintenance log"}]' > "$FIX/issues.json"
  write_record --repo acme/widgets --outcome completed
  run --separate-stderr zsh "$POST" "$REC"
  [ "$status" -eq 0 ]
  contains "$(cat "$GH_LOG")" "issue list --repo acme/widgets --state open --label maintenance-log"
  [ "$(grep -c '^issue comment 25 ' "$GH_LOG")" = "1" ]
  [ "$(grep -c '^issue create\|^label create' "$GH_LOG")" = "0" ]
}

@test "post: the comment lists every non-empty list and omits the empty ones" {
  summary
  write_record --repo acme/widgets --outcome cut-off --reason "the window closed" --from "$BATS_TEST_TMPDIR/summary.json"
  run --separate-stderr zsh "$POST" "$REC"
  [ "$status" -eq 0 ]
  local c
  c="$(cat "$FIX/comment-1.md")"
  starts_with "$c" "**Maintenance run: cut-off**, 2026-11-28T02:00:00Z to 2026-11-28T03:25:10Z (1h 25m)"
  contains "$c" "Reason: the window closed"
  contains "$c" "#### security"
  contains "$c" "Merged:"
  contains "$c" "Deferred:
- semgrep group — cap"
  contains "$c" "#### codequality

Waiting for a human:
- #14 Tidy imports"
  contains "$c" "#### Bugs"
  contains "$c" "Awaiting confirmation:
- #10 Totals off by one"
  contains "$c" "Fixed:
- #9 Crash on an empty cart"
  lacks "$c" "#### dependencies"
  lacks "$c" "#### topic"
  lacks "$c" "Opened:"
  lacks "$c" "Parked:"
  lacks "$c" "Analysed:"
  lacks "$c" "Not a bug:"
}

@test "post: each of the eleven list labels renders its own list" {
  # one item per list, built from the same key=label table the assertions walk,
  # so a dropped or misspelt row of the script's label map fails here
  local labels=(merged=Merged opened=Opened "waiting=Waiting for a human" parked=Parked deferred=Deferred
                analysed=Analysed "awaiting_confirmation=Awaiting confirmation" fixed=Fixed
                "not_a_bug=Not a bug" "not_eligible=Not eligible" "not_reproducing=Not reproducing")
  local pair key concern='{}' bugs='{}' c
  for pair in "${labels[@]:0:5}"; do
    key="${pair%%=*}"
    concern="$(jq -c --arg k "$key" '. + {($k): [{number: null, title: ("item " + ($k | gsub("_"; "-")))}]}' <<<"$concern")"
  done
  for pair in "${labels[@]:5}"; do
    key="${pair%%=*}"
    bugs="$(jq -c --arg k "$key" '. + {($k): [{number: null, title: ("item " + ($k | gsub("_"; "-")))}]}' <<<"$bugs")"
  done
  jq -n --argjson c "$concern" --argjson b "$bugs" '{concerns: {security: $c}, bugs: $b}' > "$BATS_TEST_TMPDIR/all.json"
  write_record --repo acme/widgets --outcome completed --from "$BATS_TEST_TMPDIR/all.json"
  [ "$status" -eq 0 ]
  run --separate-stderr zsh "$POST" "$REC"
  [ "$status" -eq 0 ]
  c="$(cat "$FIX/comment-1.md")"
  [ "${#labels[@]}" -eq 11 ]
  for pair in "${labels[@]}"; do
    key="${pair%%=*}"
    contains "$c" "${pair#*=}:
- item ${key//_/-}"
  done
}

@test "post: markdown and @mentions in a title, note or reason stay literal text on one line" {
  printf '%s\n' '{"concerns": {"security": {"merged": [{"number": 12, "title": "Bump | `left-pad` [x]\nby @alice *_<>#~\\",
    "url": "https://github.com/acme/widgets/pull/12", "note": "a | b `c`"}]}}}' > "$BATS_TEST_TMPDIR/s.json"
  write_record --repo acme/widgets --outcome cut-off --reason $'window [x]\nclosed' --from "$BATS_TEST_TMPDIR/s.json"
  [ "$(jq -r .reason "$REC")" = "window [x] closed" ]
  run --separate-stderr zsh "$POST" "$REC"
  [ "$status" -eq 0 ]
  local c zw
  c="$(cat "$FIX/comment-1.md")"
  zw="$(printf '\342\200\213')"   # U+200B, the zero-width space that defuses a mention
  contains "$c" '- [#12](https://github.com/acme/widgets/pull/12) Bump \| \`left-pad\` \[x\] by @'"$zw"'alice \*\_\<\>\#\~\\ — a \| b \`c\`'
  contains "$c" 'Reason: window \[x\] closed'
  lacks "$c" "@alice"
  [ "$(grep -c 'left-pad' "$FIX/comment-1.md")" = "1" ]
}

@test "post: a record with every list empty says so" {
  write_record --repo acme/widgets --outcome could-not-start --reason "keychain locked"
  run --separate-stderr zsh "$POST" "$REC"
  [ "$status" -eq 0 ]
  local c
  c="$(cat "$FIX/comment-1.md")"
  contains "$c" "Reason: keychain locked"
  contains "$c" "Nothing merged, opened, waiting, parked or deferred, and no bug handled."
  lacks "$c" "####"
}

@test "post: GitHub unreachable exits 1 and leaves the record valid, with no comment URL" {
  summary
  write_record --repo acme/widgets --outcome completed --from "$BATS_TEST_TMPDIR/summary.json"
  cp "$REC" "$BATS_TEST_TMPDIR/before.json"
  local f
  for f in all list create comment; do
    GH_FAIL="$f" run --separate-stderr zsh "$POST" "$REC"
    [ "$status" -eq 1 ]
    contains "$stderr" ": gh: offline"
    [ "$output" = "" ]
    cmp -s "$REC" "$BATS_TEST_TMPDIR/before.json"
    [ "$(jq -c '[.schema, .log_comment_url, (.concerns.security.merged | length)]' "$REC")" = '["maintenance-run/v1",null,1]' ]
  done
  [ "$(id -u)" -ne 0 ] || skip "root writes into a read-only directory"
  chmod a-w "$MAINTENANCE_RUN_DIR"
  run --separate-stderr zsh "$POST" "$REC"
  chmod u+w "$MAINTENANCE_RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  contains "$stderr" "comment posted (https://github.com/acme/widgets/issues/77#issuecomment-1) but cannot rewrite"
  cmp -s "$REC" "$BATS_TEST_TMPDIR/before.json"
}

@test "post: anything but one maintenance-run/v1 record is a usage error" {
  run --separate-stderr zsh "$POST"
  [ "$status" -eq 2 ]
  printf '{"schema":"telemetry/v1","repo":"acme/widgets"}\n' > "$BATS_TEST_TMPDIR/other.json"
  run --separate-stderr zsh "$POST" "$BATS_TEST_TMPDIR/other.json"
  [ "$status" -eq 2 ]
  contains "$stderr" "is not a maintenance-run/v1 record"
  run --separate-stderr zsh "$POST" "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 2 ]
  [ ! -e "$GH_LOG" ]
}

# ---- the prose that wires the record in -------------------------------------

# A file's text as one line, so a pinned sentence survives re-wrapping.
flat() {
  tr '\n' ' ' < "$REPO_ROOT/$1" | tr -s ' '
}

@test "SKILL.md: under --scheduled Phase 9 writes the record and posts the log as the run's last act" {
  local s skill="$REPO_ROOT/development/skills/maintenance/SKILL.md"
  s="$(flat development/skills/maintenance/SKILL.md)"
  contains "$s" "**Under \`--scheduled\` — the run record and the Maintenance log (#3215).**"
  contains "$s" "every ending writes the run's \`maintenance-run/v1\` record with \`write-run-record.zsh\` and posts it to the repo's standing *Maintenance log* issue with \`post-maintenance-log.zsh\`, as the run's **last act** — a cut-off run and a stop at or before Phase 2's gate included."
  contains "$s" "\`reference/report.md\` § The scheduled run's record and the Maintenance log (#3215)"
  contains "$s" "Without \`--scheduled\`, or under \`--dry-run\`, neither script runs."
  contains "$s" "Any stop from here on, under it, still writes and posts the run record (Phase 9, *Under \`--scheduled\` — the run record and the Maintenance log*)."
  local emit sub p10
  emit=$(grep -n "^### Emit the run's record" "$skill" | cut -d: -f1)
  sub=$(grep -n '^\*\*Under `--scheduled` — the run record' "$skill" | cut -d: -f1)
  p10=$(grep -n '^## Phase 10' "$skill" | cut -d: -f1)
  [ "$emit" -lt "$sub" ]
  [ "$sub" -lt "$p10" ]
}

@test "report.md: the outcome table, the summary's sources and both failure arms are stated" {
  local r
  r="$(flat development/skills/maintenance/reference/report.md)"
  contains "$r" "## The scheduled run's record and the Maintenance log (#3215)"
  contains "$r" "the normal ending, a cut-off run, and a stop at or before Phase 2's gate, which emits no telemetry record."
  contains "$r" "Under \`--dry-run\` neither script runs: a dry run performs no outward actions."
  contains "$r" "The summary below is written before *Run complete — clear the checkpoint*, since it reads the checkpoint; the two script calls are the run's last act — after Phase 10's report, after the Phase 9 emit when Phase 10 is skipped, or where an earlier stop stops."
  contains "$r" "**The outcome.** Take the first that holds:"
  local f="$REPO_ROOT/development/skills/maintenance/reference/report.md" row prev=0
  for row in '`skipped-running` |' '`could-not-start` |' '`cut-off` |' '`completed` |'; do
    row=$(grep -nF "$row" "$f" | head -n 1 | cut -d: -f1)
    [ "$row" -gt "$prev" ]
    prev=$row
  done
  contains "$r" "\`started_at\` (the start stamp's time, \`jq -r '.ts | todate' <scratch>/maintenance-run.json\`)"
  contains "$r" "\`merged\` — PRs merged this run; \`opened\` — PRs this run opened that are still open and not waiting for a human; \`waiting\` — open PRs and \`advisory\` stages (\`number\` null, the entries in \`note\`) waiting for a human's approval or decision;"
  contains "$r" "\`parked\` — anything else that ended needing a human, the reason in \`note\`: escalated or held stages and bugs, bug fixes that left no open or merged PR, failed analyses, and a target Phase 7 halted or a language Phase 3 skipped (a topic's under \`topic\`, a language's under \`codequality\`); \`deferred\` — groups and bugs not started, \`note\` naming the \`deferred_by\` or the reason;"
  contains "$r" "\`fixed\` — a bug belongs here only when its fix was confirmed by its PR merging this run, never when the fix was merely attempted: an open fix PR goes under the \`bugs\` concern's \`opened\` or \`waiting\`, a \`spec-does-not-reproduce\` stop under \`not_reproducing\`, and every other ending of a fix run under the concern's \`parked\`, the ending in \`note\`;"
  contains "$(flat development/skills/maintenance/reference/bugs.md)" "called fixed only when its PR merged, never when the fix was merely attempted"
  contains "$(flat ARCHITECTURE.md)" "\`bugs.fixed\` holds a bug only when its fix PR merged this run, never a fix merely attempted;"
  contains "$r" "A stop at or before Phase 2's gate writes no summary, passes no \`--from\`, and takes a fresh \`mktemp -d\` as \`<scratch>\`. \`<owner/name>\` is what follows \`github.com/\` or \`github.com:\` in \`git remote get-url origin\`, \`.git\` dropped, so it needs no network. With no git repo, no \`origin\`, or an origin not on github.com, never guess one: run neither script, and report that the run record could not be written."
  contains "$r" "--repo <owner/name> --outcome <outcome>"
  contains "$r" "post-maintenance-log.zsh\" <record>"
  contains "$r" "Its exit 2 is your own malformed call: fix it and re-run once."
  contains "$r" "the next run's comment is the next attempt."
  contains "$r" "Once both have run, relay the record's path and the comment's URL, or the failure, as the run's final output."
  contains "$r" "| ended at the resume entry because a younger checkpoint says a run may still be going (\`reference/scheduled.md\` § 1) | \`skipped-running\` |"
  contains "$r" "| stopped in Phase 0 or 1, or at Phase 2's gate | \`could-not-start\` |"
  contains "$r" "| deferred any group, stage or bug by \`cutoff\` | \`cut-off\` |"
  contains "$r" "| ended any other way | \`completed\` |"
  contains "$r" "\`outside-window\` is never a session's: the wave that starts the run writes it, with the same script, for a repo it did not start before the cutoff."
  contains "$r" "Pass the stop's reason as \`--reason\` whenever the run did not end normally."
  contains "$r" "never reconstructed from the rendered summary."
  contains "$r" "The scheduler exports \`MAINTENANCE_RUN_DIR\`; a \`--scheduled\` run typed by hand keeps its record in \`<scratch>\`."
  contains "$r" "A \`write-run-record.zsh\` exit 1 on the summary: report its stderr and write again without \`--from\`, the reason saying the summary was refused, so a record exists."
  contains "$r" "A \`post-maintenance-log.zsh\` exit 1 leaves the record valid with \`log_comment_url: null\`: report its stderr, and retry nothing"
  contains "$r" "Neither script ever closes the log issue."
}

@test "ARCHITECTURE.md: the maintenance-run/v1 contract names the fixed shape and the five outcomes" {
  local a o
  a="$(flat ARCHITECTURE.md)"
  contains "$a" "### Maintenance run record (\`maintenance-run/v1\`) (#3215)"
  contains "$a" "Every \`--scheduled\` run but a \`--dry-run\` leaves one record per repo per wave, at \`\$MAINTENANCE_RUN_DIR/<owner>__<name>.json\`"
  contains "$a" "\`concerns\` always holds all five concerns in concern order, each with all five lists, and \`bugs\` all six lists; a list with nothing in it is \`[]\`, never absent."
  for o in completed cut-off could-not-start outside-window skipped-running; do
    contains "$a" "\`$o\`"
  done
  # each outcome means what report.md's outcome table says it means
  contains "$a" "\`cut-off\` (something was deferred by the cutoff), \`could-not-start\` (stopped in Phase 0 or 1, or at Phase 2's gate), \`outside-window\` (written by the wave for a repo it did not start before the cutoff) or \`skipped-running\` (an earlier run may still be going)."
  contains "$a" "which it opens once on first use and never closes. With GitHub unreachable it stays \`null\` and the record is otherwise complete."
}
