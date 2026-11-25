# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2027,SC2086,SC2089,SC2090
# SC2034: the variables set here are read by the suites that load this file.
# SC2154: status and output are set by bats' `run`. The rest: the hook-mode
# helpers splice JSON into a --review-cmd string by switching quote styles on
# purpose; the loop's shell parses that string, not this one.
#
# Shared fixture for the resolve-story-loop.zsh suites (#3085): every
# tests/resolve-story-loop-*.bats file loads it. Those files were two, one per
# wiring — hook mode (#562) and step mode (#971) — until #3085 split them by
# concern, so that select-tests.zsh can pick the part a change can affect, and
# moved the per-test setup they repeated into this file.
#
# What the fixture gives every test:
#   * R     — a real git repo on branch `main`, one commit (README.md), plus an
#             untracked app.py: the story's in-scope diff. Detection is stubbed
#             via DETECT_STACK_BIN ($STUB echoes $DETECT_LANGS_JSON); git runs
#             for real.
#   * S     — the loop behind the omniscient-panel wrapper (below); LOOP_REAL is
#             the real script, for a test that reads its source or must bypass
#             the wrapper.
#   * WD, F — the step-mode work-dir and findings file; CRIT, CRIT2, CRIT_FILE —
#             one CRITICAL blocker (CRIT2 is the same blocker as a second panel
#             run would word it: same identity, different text, #606/#974).
#   * DEFAULT_SINK — the user-level telemetry default for R, which has no
#             remote, so its identity is "repo". HOME is the SUITE's to set,
#             in its own setup() before loop_fixture_setup, so the #1972 sweep
#             in tests/telemetry-emit.bats sees it; loop_fixture_setup refuses
#             to run without it.
#
# The omniscient panel (#1583): a round that carries entries to verify must
# account for each one (confirmed / re-raised / unconfirmed per reviewer) or the
# loop refuses it as CARRY-UNACCOUNTED. The fixture panels are omniscient: every
# carried entry is CONFIRMED by reviewer "r" unless a test supplies its own
# accounting. That default is applied by a WRAPPER the tests invoke as $S:
#   * hook mode — every --review-cmd runs the $CARRY_ALL prelude first, which
#     writes the <findings-path>.carry.json sidecar (nothing on an empty carry);
#     a test that wants a re-raise or an unconfirmed entry writes its own
#     sidecar after the prelude, or deletes it;
#   * step mode — a --resume without --carry-accounting gets a confirm-all file
#     built from the carry the round is about to read (the highest verify-N.json
#     in --work-dir).
# A --review-cmd whose value is empty or a flag is passed through untouched, so
# the usage-error tests still exercise the real parser.
#
# Cost (#3085). The template repo, the detect stub, the prelude and the wrapper
# are written ONCE per file, in setup_file, and only read by the tests: each test
# copies the template repo rather than running git init/add/commit again. On
# macOS, /usr/bin/git is an xcrun trampoline that roughly doubles each git
# start-up, and a loop test starts dozens of git processes, so when `git`
# resolves to /usr/bin/git the directory of the binary it trampolines to goes
# first on PATH. That is the same git, reached without the detour; elsewhere,
# and when git is not /usr/bin/git, PATH is left as it is.
#
# Each suite calls, with the loop script's repo path spelled in the suite itself
# (so select-tests.zsh maps a change to that script to every suite):
#   setup_file() { loop_fixture_setup_file "$BATS_TEST_DIRNAME/../development/…/resolve-story-loop.zsh"; }
#   setup()      { export HOME="$BATS_TEST_TMPDIR/home"; loop_fixture_setup; }
#   teardown()   { loop_fixture_teardown; }

loop_fixture_setup_file() {  # $1 = the loop script
  # a git hook or `rebase --exec` exports these, and `git -C` does not override
  # them: the template build would land in the REAL repository
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  local loop_script real=""
  loop_script="$(cd "${1%/*}" && pwd)/${1##*/}"
  [ -f "$loop_script" ] || { echo "loop_fixture_setup_file: no loop script at $1" >&2; return 1; }
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LOOP_REAL="$loop_script"

  if [ "$(uname -s)" = Darwin ] && [ "$(command -v git)" = /usr/bin/git ]; then
    real="$(xcrun -f git 2>/dev/null)" || real=""
    if [ -n "$real" ] && [ -x "$real" ]; then
      PATH="${real%/*}:$PATH"
    fi
  fi

  local fx="$BATS_FILE_TMPDIR/loop-fixture"
  mkdir -p "$fx/home"
  STUB="$fx/detect.sh"
  printf '#!/usr/bin/env bash\necho "$DETECT_LANGS_JSON"\n' > "$STUB"
  chmod +x "$STUB"

  # the template repo, built under a scratch HOME so no global git config (a
  # signing hook, a template dir) reaches it — exactly as the per-test HOME did
  LOOP_TEMPLATE_REPO="$fx/repo"
  mkdir -p "$LOOP_TEMPLATE_REPO"
  HOME="$fx/home" git -C "$LOOP_TEMPLATE_REPO" init -q
  HOME="$fx/home" git -C "$LOOP_TEMPLATE_REPO" config user.email t@example.com
  HOME="$fx/home" git -C "$LOOP_TEMPLATE_REPO" config user.name tester
  echo base > "$LOOP_TEMPLATE_REPO/README.md"
  HOME="$fx/home" git -C "$LOOP_TEMPLATE_REPO" add -A
  HOME="$fx/home" git -C "$LOOP_TEMPLATE_REPO" commit -qm base
  HOME="$fx/home" git -C "$LOOP_TEMPLATE_REPO" branch -M main
  echo "print(1)" > "$LOOP_TEMPLATE_REPO/app.py"   # the story's diff (in-scope file)

  CARRY_ALL="$fx/carry-all.sh"
  cat > "$CARRY_ALL" <<'EOF'
#!/usr/bin/env bash
if [ -n "${REVIEW_FIX_VERIFICATION:-}" ] && [ -s "$REVIEW_FIX_VERIFICATION" ] \
   && [ "$(jq 'length' "$REVIEW_FIX_VERIFICATION")" != "0" ]; then
  jq '[.[] | {file, dimension, title, confirmed: ["r"], re_raised: [], unconfirmed: []}]' \
    "$REVIEW_FIX_VERIFICATION" > "$REVIEW_FINDINGS.carry.json"
fi
EOF
  chmod +x "$CARRY_ALL"
  LOOP_WRAPPER="$fx/loop-with-omniscient-panel.zsh"
  cat > "$LOOP_WRAPPER" <<'EOF'
#!/usr/bin/env zsh
emulate -L zsh
local -a args=()
# every name initialised: at a script's top level a bare `local NAME` whose name
# is already in the environment PRINTS it to stdout — which here is the status
# JSON every test parses (the hazard resolve-story-loop.zsh documents about itself)
local wd="" resume=0 has_acct=0 has_review=0 i=0 n="" v="" c=""
for (( i=1; i<=$#; i++ )); do
  case "${@[i]}" in
    --work-dir) wd="${@[i+1]:-}" ;;
    --resume) resume=1 ;;
    --carry-accounting) has_acct=1 ;;
    --review-cmd) has_review=1 ;;
  esac
done
for (( i=1; i<=$#; i++ )); do
  if [[ "${@[i]}" == --review-cmd && $i -lt $# && -n "${@[i+1]}" && "${@[i+1]}" != --* \
        && "${@[i+1]}" != '"$CARRY_ALL"; '* ]]; then
    args+=( --review-cmd "\"\$CARRY_ALL\"; ${@[i+1]}" ); (( i++ ))
  else
    args+=( "${@[i]}" )
  fi
done
if (( resume && ! has_acct && ! has_review )) && [[ -n "$wd" && -d "$wd" ]]; then
  # the highest-numbered verify-N.json that is a REGULAR file — a test that
  # plants a directory at the next carry path (the kill-window test) must not
  # have it read as the carry
  for c in $(ls "$wd" 2>/dev/null | sed -n 's/^verify-\([0-9][0-9]*\)\.json$/\1/p' | sort -rn); do
    [[ -f "$wd/verify-$c.json" ]] && { n="$c"; break; }
  done
  v="$wd/verify-${n:-0}.json"
  if [[ -n "$n" && -s "$v" && "$(jq 'length' "$v" 2>/dev/null)" != 0 ]]; then
    jq '[.[] | {file, dimension, title, confirmed: ["r"], re_raised: [], unconfirmed: []}]' "$v" > "$CARRY_AUTO_FILE" \
      && args+=( --carry-accounting "$CARRY_AUTO_FILE" )
  fi
fi
exec zsh "$LOOP_REAL" "${args[@]}"
EOF
  export PATH REPO_ROOT LOOP_REAL STUB LOOP_TEMPLATE_REPO CARRY_ALL LOOP_WRAPPER
}

loop_fixture_setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  [ "$HOME" = "$BATS_TEST_TMPDIR/home" ] || { echo "loop_fixture_setup: the suite must export HOME=\"\$BATS_TEST_TMPDIR/home\" first (#1972)" >&2; return 1; }
  DEFAULT_SINK="$HOME/.claude/telemetry/repo.jsonl"  # R (below) has no remote: its identity is "repo"
  R="$BATS_TEST_TMPDIR/repo"
  cp -R "$LOOP_TEMPLATE_REPO" "$R"
  WD="$BATS_TEST_TMPDIR/wd"
  F="$BATS_TEST_TMPDIR/findings.json"
  CRIT='[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"T","description":"d","reviewer":"r"}]'
  # the SAME blocker as a real second panel run would report it: same identity
  # ([file, dimension, line] — #606), different evidence text, so it is not
  # byte-identical and clears the stale-findings guard (#974)
  CRIT2='[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"T (still)","description":"d2","reviewer":"r2"}]'
  # same fixture as a file, so hook commands can cp it instead of interpolating
  # JSON into a shell string (word splitting / globbing hazard)
  CRIT_FILE="$BATS_TEST_TMPDIR/crit.json"
  printf '%s' "$CRIT" > "$CRIT_FILE"
  CARRY_AUTO_FILE="$BATS_TEST_TMPDIR/carry-auto.json"
  export CARRY_AUTO_FILE
  S="$LOOP_WRAPPER"
}

# a test that chmods a dir read-only must not leave it un-removable if an
# assertion aborts mid-way — bats' rm -rf of the tmpdir would then fail and
# bury the real failure. Restore write perms always.
loop_fixture_teardown() {
  chmod -R u+rwX "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# --- hook mode (#562): the agentic steps (panel + fix) are injected as hook
# commands, so every exit state is driven deterministically ------------------

# run the loop against a python repo with the given hook flags
loop() {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" "$@"
}

# The driving fixtures for each terminal status, defined ONCE so the
# state-machine tests and the telemetry outcome-mapping tests cannot drift apart
# (a half-applied edit to a duplicated fixture would silently change what the
# outcome test exercises instead of failing).
clean_loop() {      # -> CONVERGED
  loop --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true' "$@"
}
stuck_loop() {      # -> ESCALATE_NO_CONVERGENCE (same blocker every round)
  loop --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true' "$@"
}
budget_loop() {     # -> BUDGET_EXHAUSTED (a genuinely distinct blocker each round)
  loop --review-cmd 'printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":$((REVIEW_ROUND*1000)),\"title\":\"b$REVIEW_ROUND\",\"description\":\"d\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"' \
       --fix-cmd 'true' "$@"
}
conflict_loop() {   # -> ESCALATE_CONFLICT (two reviewers, same line, opposed)
  loop --review-cmd 'printf "%s" '"'"'[{"severity":"WARNING","dimension":"performance","file":"app.py","line":1,"title":"c","description":"d","reviewer":"p"},{"severity":"WARNING","dimension":"code_quality","file":"app.py","line":1,"title":"e","description":"d","reviewer":"q"}]'"'"' > "$REVIEW_FINDINGS"' \
       --fix-cmd 'true' "$@"
}
ambiguous_run() {   # -> ESCALATE_AMBIGUOUS (pre-loop: two languages)
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python","java"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wdamb" \
    --review-cmd 'true' --fix-cmd 'true' "$@"
}

# --- telemetry/v1 (#1004): the envelope every emitted record must satisfy ---

# Assert the envelope invariants that must hold on EVERY emitted record,
# whatever the terminal status: exactly one record, the contract's own
# validator, and the fields a regression would most plausibly break.
# $1 sink · $2 expected outcome · $3 expected payload.status
assert_envelope() {
  local f="$1" want_outcome="$2" want_status="$3"
  [ "$(grep -c '' "$f")" -eq 1 ] || { echo "expected exactly 1 record in $f"; return 1; }
  [ "$(jq -r '.schema' "$f")" = "telemetry/v1" ] || {
    echo "schema: want telemetry/v1, got $(jq -r '.schema' "$f")"; return 1; }
  [ "$(jq -r '.kind' "$f")" = "run" ] || {
    echo "kind: want run, got $(jq -r '.kind' "$f")"; return 1; }
  [ "$(jq -r '.pipeline' "$f")" = "review-loop" ] || {
    echo "pipeline: want review-loop, got $(jq -r '.pipeline' "$f")"; return 1; }
  [ "$(jq -r '.outcome' "$f")" = "$want_outcome" ] || {
    echo "outcome: want $want_outcome, got $(jq -r '.outcome' "$f")"; return 1; }
  [ "$(jq -r '.payload.status' "$f")" = "$want_status" ] || {
    echo "payload.status: want $want_status, got $(jq -r '.payload.status' "$f")"; return 1; }
  # AC5: repo is never null — a record must never be anonymous
  [ "$(jq -r '.repo | type' "$f")" = "string" ] || {
    echo "repo type: want string, got $(jq -r '.repo | type' "$f")"; return 1; }
  # a SHAPE check, not an emptiness one (the emitter exits rather than emit an
  # empty repo, so that branch was unreachable): this catches a fabricated
  # multi-segment or whitespace-bearing identity, which is what _derive_repo's
  # local-path handling exists to prevent
  jq -e '.repo | test("^[^/[:space:]]+(/[^/[:space:]]+)?$")' "$f" >/dev/null || {
    echo "repo has a fabricated/ill-formed shape: $(jq -r '.repo' "$f")"; return 1; }
  # AC6: wall_s is a NUMBER on every run record (jq -r prints 0 and null alike,
  # so type is the only assertion that separates them)
  [ "$(jq -r '.wall_s | type' "$f")" = "number" ] || {
    echo "wall_s type: want number, got $(jq -r '.wall_s | type' "$f")"; return 1; }
  # ts is the loop's LOGICAL start (--ts from .t0), not the terminal moment —
  # drop --ts and the emitter silently defaults to now, mis-stamping run_id too
  [ "$(jq -r '.ts | type' "$f")" = "number" ] || {
    echo "ts type: want number, got $(jq -r '.ts | type' "$f")"; return 1; }
  # run_id is the contract's join key — a wrong/empty pipeline prefix must fail
  jq -e '.run_id | test("^review-loop-[0-9]+-[0-9a-f]{4}$")' "$f" >/dev/null || {
    echo "bad run_id: $(jq -r '.run_id' "$f")"; return 1; }
  # AC7: and the whole thing conforms to the contract
  zsh "$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh" "$f" --require-records
}

# --- the human-grant ceiling sidecar (#1576) and the escalation suites ------

# Drive one round to BUDGET_EXHAUSTED so the work-dir holds a resumable history,
# then hand the caller a work-dir to seed. `--max-rounds 1` keeps it to a single
# round; the blocker is what makes it exhaust rather than converge.
seed_resumable() {   # seed_resumable <work-dir>
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$1" --max-rounds 1 \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]
}

# The loop's own sidecar slack, read from source so a retune moves every
# fixture with it. Fails loudly rather than yielding an empty string, which
# would silently turn `$(( 5 + slack ))` into 5 and red a neighbouring test
# with a message about the wrong thing.
sidecar_slack() {
  local v
  v=$(sed -n 's/^typeset -gr MAX_ROUNDS_SIDECAR_SLACK=\([0-9]*\)$/\1/p' "$LOOP_REAL")
  [ -n "$v" ] || { echo "could not read MAX_ROUNDS_SIDECAR_SLACK from $LOOP_REAL" >&2; return 1; }
  printf '%s' "$v"
}

# Resume that work-dir with a clean round, at the given --max-rounds.
resume_clean() {   # resume_clean <work-dir> <max-rounds>
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$1" --resume --max-rounds "$2" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
}

# --- step mode (#971): one invocation per round -----------------------------

# one step-mode invocation against the python repo
step() {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" "$@"
}

# a blocker that is GENUINELY different per round, on BOTH axes the matcher
# uses: the line jumps far beyond the proximity window (#606) AND the titles
# share no significant (>= 4-char) token, so the identity check clears them as
# distinct findings rather than routing to the ambiguous branch (#983). A
# multi-round run therefore spends its budget instead of tripping
# non-convergence, and consecutive rounds are never byte-identical (the #974
# stale-findings guard).
distinct_blocker() {
  local -a titles=(
    "unquoted variable in matcher"
    "missing pipefail on download"
    "stale cache never invalidated"
    "off-by-one window bound"
    "swallowed exit from consolidator"
    "wrong severity mapping"
    "unreachable resume branch"
    "leaked temp file"
  )
  printf '[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":%d,"title":"%s","description":"d%d","reviewer":"r"}]' \
    "$(( $1 * 1000 ))" "${titles[$(( $1 - 1 ))]}" "$1"
}

# burn the whole DEFAULT budget: rounds 1..MAX-1 keep asking for a fix, the last
# one spends it. Shared by the two #993 step-mode budget tests so the ramp
# cannot drift between them.
spend_default_budget() {
  local r
  for r in 1 2 3 4; do
    distinct_blocker "$r" > "$F"
    if [ "$r" -eq 1 ]; then step; else step --resume; fi
    # every assertion carries the round, so a regression at round 3 does not
    # report the same failure message as one at round 1
    [ "round $r: $status" = "round $r: 20" ]
    [ "round $r: $(echo "$output" | jq -r '.status')" = "round $r: AWAITING_FIX" ]
    [ "round $r: $(echo "$output" | jq '.rounds')" = "round $r: $r" ]
  done
  distinct_blocker 5 > "$F"
  step --resume
}

# seed a work-dir one AWAITING_FIX round deep (round 1, one CRITICAL blocker)
seed_awaiting() {
  printf '%s' "$CRIT" > "$F"
  step
  [ "$status" -eq 20 ]
}

# Drive a run that is one AWAITING_FIX round deep all the way to CONVERGED with
# clean findings. Since #1434 that takes TWO more invocations, not one: a clean
# DELTA round cannot end a run — it promotes the next round to the closing full
# sweep, and only that sweep may converge. Defined once so the call sites (which
# care about telemetry, gate attestation or work-dir filtering, not about round
# counting) cannot drift apart on the ramp. Extra flags are forwarded to BOTH
# invocations, exactly as a driving session would keep passing them.
converge_clean() {
  # The in-session fix, applied between invocations exactly as a driving session
  # applies one. It is not decoration, but the reason is narrower than it looks:
  # every call site precedes this with a round that FOUND something, so the
  # carry is non-empty. Without the tree change round 2's delta would be empty
  # WITH a carry, which takes the verification-only branch — re-planned
  # `--final`, scope re-derived to the whole story diff. The run would still
  # converge; it just would not be the ordinary delta round these tests mean to
  # drive. (The blind round — scope-empty AND findings-empty — is not reachable
  # through this helper at all, and is not covered by it.)
  echo "x = converged" > "$R/fixed-by-converge-clean.py"
  printf '[]' > "$F"
  step --resume "$@"
  [ "converge_clean delta round: $status" = "converge_clean delta round: 20" ]
  printf '[]' > "$F"
  step --resume "$@"
}

# a WARNING per round in the given file, at a line and title the round number
# moves, so consecutive rounds are distinct findings (#1435)
residue_findings() {  # $1 = round, $2 = file
  printf '[{"severity":"WARNING","dimension":"bugs","file":"%s","line":%d,"title":"round %d unquoted expansion","description":"d%d","reviewer":"r"}]' \
    "$2" "$(( $1 * 100 ))" "$1" "$1"
}

# the accounting for the round-1 CRIT blocker ("T" in app.py, bugs), with the
# three reviewer lists given as JSON arrays; prints the file's path
carry_record() {  # carry_record <confirmed[]> <re_raised[]> <unconfirmed[]>
  local out="$BATS_TEST_TMPDIR/carry-record-$RANDOM.json"
  printf '[{"file":"app.py","dimension":"bugs","title":"T","confirmed":%s,"re_raised":%s,"unconfirmed":%s}]' \
    "$1" "$2" "$3" > "$out"
  printf '%s' "$out"
}
