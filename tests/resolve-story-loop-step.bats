#!/usr/bin/env bats
#
# Behavioral tests for resolve-story-loop.zsh STEP MODE (#971): one invocation
# per round, findings supplied via --findings-file, fixes applied in-session
# between invocations (so the loop exits AWAITING_FIX instead of running a fix
# hook). Detection is stubbed via DETECT_STACK_BIN; git runs for real.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/resolve-story-loop.zsh"

  STUB="$BATS_TEST_TMPDIR/detect.sh"
  printf '#!/usr/bin/env bash\necho "$DETECT_LANGS_JSON"\n' > "$STUB"
  chmod +x "$STUB"

  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  echo base > "$R/README.md"
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" branch -M main
  echo "print(1)" > "$R/app.py"   # the story's diff (in-scope file)

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
}

# a test that chmods a dir read-only (the failed-consume case) must not leave it
# un-removable if an assertion aborts the test mid-way — bats' rm -rf of the
# tmpdir would then fail and bury the real failure. Restore write perms always.
teardown() {
  chmod -R u+rwX "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

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

@test "usage: --findings-file with --review-cmd is a usage error (exit 2)" {
  printf '[]' > "$F"
  step --review-cmd 'true'
  [ "$status" -eq 2 ]
}

@test "usage: --findings-file with --fix-cmd is a usage error (exit 2)" {
  printf '[]' > "$F"
  step --fix-cmd 'true'
  [ "$status" -eq 2 ]
}

@test "blockers with budget left exit AWAITING_FIX (20), accumulators populated" {
  printf '%s' "$CRIT" > "$F"
  step
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 1 ]
  [ "$(echo "$output" | jq '.round_changelists | length')" -eq 1 ]
  [ "$(echo "$output" | jq '.final_changelist.summary.blocking')" -eq 1 ]
  # stdout stays exactly the one-line status JSON
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]
}

@test "clean findings converge in round 1 (exit 0)" {
  printf '[]' > "$F"
  step
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]
}

@test "#1434 a missing findings file on a FULL round is REFUSED, never read as a clean review" {
  # Round 1 is always full, so zero blockers there is the CONVERGED condition —
  # reading an absent aggregate as `[]` converges the run on a review nobody
  # performed. It is also the only thing that enforces the terminal every panel
  # now carries: on a full round with an empty scope (or, on kubernetes, any
  # not-applicable shape) the panel reports to its caller and writes NO file
  # *precisely so the loop refuses*.
  rm -f "$F"
  step
  [ "$status" -eq 2 ]
  # `grep '^{'`: the refusal prints its diagnostic on stderr, which `run` merges
  # into $output ahead of the status JSON
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  # the STEP-mode wording: it must name the caller's own --findings-file,
  # and must NOT send them to write into the dispatch sink, which the alias
  # guard then refuses — one mistake, two contradictory refusals
  contains "$output" "is a FULL round and --findings-file is missing or empty"
  contains "$output" "never the dispatch sink"
}

@test "#1434 a missing findings file on a DELTA round is refused by the --resume arm, not the FULL-round arm" {
  # The two refusal arms must stay distinguishable: they name different causes
  # and route to different recovery arms in §3.5 step 2. In STEP mode the `[]`
  # delta default is in fact unreachable — round 1 is always full, and every
  # later round arrives via --resume, where the #974 missing-on-resume arm
  # fires first — so the surviving default is pinned in HOOK mode instead, by
  # "a DELTA round whose panel writes NO findings" in tests/resolve-story-loop.bats.
  seed_awaiting                      # round 1 (full): one blocker
  echo "print(2)" > "$R/fixed.py"    # the in-session fix, so round 2 is a real delta
  rm -f "$F"
  step --resume --findings-file "$WD/absent-findings.json"
  [ "$status" -eq 2 ]
  # ...refused, but by the #974 missing-on-resume arm, NOT by the full-round
  # arm — the two must stay distinguishable
  # the arm-UNIQUE prefix: "did this round's review panel run" is shared with
  # the byte-identical arm, so asserting on it alone would not tell the three
  # apart — which is the whole point of this test
  contains "$output" "--findings-file is missing or empty on --resume"
  lacks "$output" "is a FULL round and --findings-file is missing or empty"
  lacks "$output" "byte-identical to round"
}

@test "a findings file that is not exactly ONE JSON array is an internal error (exit 1)" {
  # Three shapes, because the guard has three conjuncts. The multi-value case
  # is the one a bare `jq -e` misses: its status reflects only the LAST output
  # value, so two concatenated arrays (a panel writing with `>>` instead of
  # `>`) emit true,true and pass — after which every consumer downstream
  # multiplies and the run emits a BLANK status JSON beside an exit code that
  # claims a verdict.
  local bad
  for bad in 'not json' '{"a":1}' '[]
[]'; do
    printf '%s' "$bad" > "$F"
    step
    [ "shape $bad: $status" = "shape $bad: 1" ]
    contains "$output" "must hold exactly ONE JSON array"
  done
}

@test "blockers on the last budget round exit BUDGET_EXHAUSTED (13), not AWAITING_FIX" {
  printf '%s' "$CRIT" > "$F"
  step --max-rounds 1
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
}

@test "step mode's default cap is 5: rounds 1-4 AWAITING_FIX, round 5 BUDGET_EXHAUSTED (#993)" {
  # Step mode is the CANONICAL production wiring, so the raised default must
  # move its AWAITING_FIX -> BUDGET_EXHAUSTED boundary too — and no --max-rounds
  # is passed anywhere here, so the boundary IS MAX_REVIEW_ROUNDS.
  spend_default_budget
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 5 ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 5 ]
}

@test "step mode: a granted extension resumes past the default cap with --max-rounds 8 (#993)" {
  # The executable half of the +2 -> +3 increment: SKILL.md's interactive
  # extension re-invokes the loop with `--resume --max-rounds <prev_max + 3>`,
  # i.e. 8 once the default 5 is spent — a resume whose ceiling is ABOVE
  # MAX_REVIEW_ROUNDS, in the canonical step-mode wiring. A regression that
  # re-derived the resume ceiling from the compiled constant (or refused
  # resume_round + 1 > MAX_REVIEW_ROUNDS) would kill every granted extension at
  # round 5 while the rest of the suite stayed green.
  spend_default_budget
  [ "$status" -eq 13 ]   # budget spent at the default cap — the human is asked

  # ... the human grants +3: the ceiling becomes 8 and the loop continues
  distinct_blocker 6 > "$F"
  step --resume --max-rounds 8
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 6 ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 8 ]

  # and it converges inside the granted rounds — round 7 is the clean delta
  # round that promotes the closing sweep, round 8 is the sweep that converges
  converge_clean --max-rounds 8
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 8 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 8 ]
}

@test "a surviving conflict exits ESCALATE_CONFLICT (11) in step mode too" {
  printf '%s' '[{"severity":"WARNING","dimension":"performance","file":"app.py","line":1,"title":"c","description":"d","reviewer":"p"},{"severity":"WARNING","dimension":"code_quality","file":"app.py","line":1,"title":"e","description":"d","reviewer":"q"}]' > "$F"
  step
  [ "$status" -eq 11 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_CONFLICT" ]
}

@test "resume with clean findings converges at the closing sweep; accumulators span invocations" {
  # Since #1434 a clean DELTA round (round 2) promotes the closing full sweep
  # rather than ending the run, so convergence lands on round 3 — and the
  # accumulators still span every invocation, which is what this test is for.
  seed_awaiting
  converge_clean
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 3 ]
  [ "$(echo "$output" | jq '.round_changelists | length')" -eq 3 ]
}

@test "resume with the same blocker re-worded (same file/dimension/line) trips ESCALATE_NO_CONVERGENCE" {
  seed_awaiting
  printf '%s' "$CRIT2" > "$F"   # re-found by a real panel run: same identity, fresh evidence
  step --resume
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  # the cross-round match was made on [file, dimension, line] (#606), not on text
  [ "$(echo "$output" | jq -r '.final_changelist.blocking[0].matched_prior.title')" = "T" ]
}

# --- stale-findings guard (#974) --------------------------------------------

@test "re-invoking with the same UNCHANGED findings path is a usage error (2), not a phantom ESCALATE_NO_CONVERGENCE" {
  seed_awaiting
  # the session forgot to run the panel / rewrite the file — $F is untouched
  step --resume
  [ "$status" -eq 2 ]
  contains "$output" "byte-identical to round 1"
  contains "$output" "did this round's review panel run?"
}

@test "the guard is content-based: a fresh per-round path holding the previous round's bytes also exits 2" {
  seed_awaiting
  F2="$BATS_TEST_TMPDIR/findings-round-2.json"
  cp "$F" "$F2"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F2" --resume
  [ "$status" -eq 2 ]
  contains "$output" "$F2"
}

@test "the refusal is typed: it overwrites the prior AWAITING_FIX verdict with STALE_FINDINGS" {
  ST="$BATS_TEST_TMPDIR/status.json"
  T="$BATS_TEST_TMPDIR/refusal-telemetry.jsonl"
  printf '%s' "$CRIT" > "$F"
  step --status-file "$ST" --telemetry-file "$T"
  [ "$status" -eq 20 ]
  # separate-stderr so the stdout-is-one-JSON-line contract is actually observed,
  # not blurred by bats merging stderr into $output
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume \
    --status-file "$ST" --telemetry-file "$T"
  [ "$status" -eq 2 ]
  # with --separate-stderr, $output is stdout and $stderr is stderr:
  # stdout is exactly the one-line status JSON; the human complaint is on stderr
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]
  [ "$(jq -r '.status' <<<"$output")" = "STALE_FINDINGS" ]
  contains "$stderr" "did this round's review panel run?"
  # no stale verdict survives: the status file names THIS invocation's refusal
  [ "$(jq -r '.status' "$ST")" = "STALE_FINDINGS" ]
  [ "$(jq -r '.rounds' "$ST")" -eq 1 ]
  # the carried accumulators are real prior state, not empty stubs
  [ "$(jq '.history | length' "$ST")" -eq 1 ]
  [ "$(jq '.round_changelists | length' "$ST")" -eq 1 ]
  [ "$(jq '.final_changelist.round' "$ST")" -eq 1 ]
  # ...but it is NOT terminal: no telemetry record, no round block, no Final line
  [ ! -e "$T" ]
  # AC3's negative is about the WHOLE stream, not just the named sink
  [ ! -e "$R/.claude/telemetry/telemetry.jsonl" ]
  run -1 grep -q '^## Round 2' "$WD/progress.md"
  run -1 grep -q '^\*\*Final:' "$WD/progress.md"
  grep -q '^\*\*Refused (round 2):\*\* stale findings' "$WD/progress.md"
}

@test "passing the round's own dispatch findings_path as --findings-file is refused up front, panel output intact" {
  # round 1's real panel output lives at the dispatch sink; a caller that aims
  # --findings-file there must be refused BEFORE the loop truncates it
  SINK="$R/.review/findings-round-1.json"
  mkdir -p "$R/.review"
  printf '%s' "$CRIT" > "$SINK"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$SINK"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.status' <<<"$output")" = "STALE_FINDINGS" ]
  contains "$stderr" "must not be the round's own findings_path"
  # the refusal did not destroy the file it pointed at
  [ -s "$SINK" ]
  [ "$(cat "$SINK")" = "$CRIT" ]
}

@test "a missing findings file on --resume is refused (2) — silence is not a clean round" {
  seed_awaiting
  rm -f "$F"
  step --resume
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  contains "$output" "missing or empty on --resume"
  contains "$output" "must still write []"
}

@test "a zero-byte findings file on --resume is refused (2) too" {
  seed_awaiting
  : > "$F"
  step --resume
  [ "$status" -eq 2 ]
  contains "$output" "missing or empty on --resume"
}

@test "the guard compares only the immediately preceding round — and the window moves with it" {
  echo "print(2)" > "$R/lib.py"   # a second in-scope file, so round 2 differs in identity
  seed_awaiting                   # round 1 consumed $CRIT (app.py:1)
  LIB='[{"severity":"CRITICAL","dimension":"bugs","file":"lib.py","line":1,"title":"L","description":"d","reviewer":"r"}]'
  printf '%s' "$LIB" > "$F"
  step --resume --max-rounds 4    # round 2: a different blocker — no non-convergence
  [ "$status" -eq 20 ]
  # round 3 re-passing ROUND 2's bytes is refused: the comparison window moved
  step --resume --max-rounds 4
  [ "$status" -eq 2 ]
  contains "$output" "byte-identical to round 2"
  printf '%s' "$CRIT" > "$F"      # round 3: byte-identical to ROUND 1, not to round 2
  step --resume --max-rounds 4
  [ "$status" -eq 20 ]            # allowed through: only the adjacent round is compared
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
}

@test "a fresh (non-resume) run wipes a previous run's digests from a reused work-dir" {
  echo "print(2)" > "$R/lib.py"
  seed_awaiting                   # round 1
  printf '%s' '[{"severity":"CRITICAL","dimension":"bugs","file":"lib.py","line":1,"title":"L","description":"d","reviewer":"r"}]' > "$F"
  step --resume --max-rounds 4    # round 2
  [ "$status" -eq 20 ]
  [ -s "$WD/.findings-digest-2" ]
  printf '%s' "$CRIT" > "$F"      # a NEW loop from round 1 in the same work-dir
  step
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]
  [ ! -e "$WD/.findings-digest-2" ]   # the stale round-2 digest is gone...
  [ -s "$WD/.findings-digest-1" ]     # ...and this run's round 1 recorded its own
}

@test "#1434 a failed scope extraction aborts the round by name (round-1 call site)" {
  # write_round_scope contracts a non-zero return, and both call sites carry
  # `|| exit 1`. A directory at the path makes the redirection fail whatever
  # the uid. Only the ROUND-1 (ordinary) site is reachable by a fixture: both
  # calls redirect to the SAME $scope_file, so anything that breaks the
  # re-plan write breaks the first one first, and the re-plan descriptor comes
  # from the real review-dispatch.zsh with no seam to corrupt. The re-plan
  # site's `|| exit 1` is therefore unpinned on purpose, not by oversight.
  mkdir -p "$WD/scope.txt"
  printf '[]' > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F"
  [ "$status" -eq 1 ]
  contains "$stderr" "could not extract scope at round 1"
  [ ! -e "$WD/changelist-1.json" ]
}

@test "#1434 the findings-sink mkdir guard names the DIRECTORY, not the truncation" {
  # A regular FILE at .review, so `mkdir -p` itself fails: without its own
  # guard the round dies one line later on the truncation and reports an
  # unwritable repo root as a sink-truncation problem.
  rm -rf "$R/.review"
  printf 'x' > "$R/.review"
  printf '[]' > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F"
  [ "$status" -eq 1 ]
  contains "$stderr" "could not create the findings sink directory"
  lacks "$stderr" "could not truncate the round 1 findings sink"
}

@test "an aborted round records no digest and no empty-findings marker, so the retry with the same bytes is accepted" {
  seed_awaiting
  mkdir -p "$R/.review"
  chmod 555 "$R/.review"          # read-only dir: the round's cp cannot land
  # tests/Dockerfile runs the suite as root, where `chmod 555` is not a barrier
  # at all — root writes into a read-only directory regardless, so the copy
  # succeeds and the failure path this test exists for never executes (#1360).
  # The EFFECT test rather than a uid test: it also covers CAP_DAC_OVERRIDE and
  # root-squashed mounts, and `-w` is what root actually bypasses here.
  if [ -w "$R/.review" ]; then skip "running as a user that bypasses directory permissions"; fi
  printf '%s' "$CRIT2" > "$F"
  step --resume
  [ "$status" -eq 1 ]
  # the round aborts on the read-only .review directory. Since #1434 that is
  # caught one statement earlier — at the sink's own truncation rather than at
  # the cp — which is a better diagnosis and, for this test, the same fact: the
  # consume failed, so no digest may be recorded.
  contains "$output" "could not truncate the round 2 findings sink"
  # all three side effects of a consumed round must be absent, not just the
  # digest: a marker or a changelist left behind would speak for a round that
  # never happened
  [ ! -e "$WD/.findings-digest-2" ]
  [ ! -e "$WD/.findings-empty-2" ]
  [ ! -e "$WD/changelist-2.json" ]
  chmod 755 "$R/.review"
  step --resume                   # same bytes, now consumable
  [ "$status" -eq 12 ]            # a verdict, never a phantom refusal
}

@test "without a sha256 tool the byte-identical detection degrades, it does not fail the run" {
  BIN="$BATS_TEST_TMPDIR/nodigest"
  mkdir -p "$BIN"
  for t in shasum sha256sum; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/$t"
    chmod +x "$BIN/$t"
  done
  printf '%s' "$CRIT" > "$F"
  run env PATH="$BIN:$PATH" DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F"
  [ "$status" -eq 20 ]
  [ ! -e "$WD/.findings-digest-1" ]   # nothing recorded: the guard is simply off
  run env PATH="$BIN:$PATH" DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume
  [ "$status" -eq 12 ]   # degraded to the pre-#974 behaviour, not an abort
}

# both digest implementations must actually work — the arm is chosen by tool
# existence, so on a host with shasum the sha256sum arm is otherwise unreachable.
# RESOLVE_LOOP_DIGEST_TOOL pins it; skip the arm whose tool this host lacks.
_digest_arm_refuses() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 || skip "$tool not installed on this host"
  printf '%s' "$CRIT" > "$F"
  run env RESOLVE_LOOP_DIGEST_TOOL="$tool" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F"
  [ "$status" -eq 20 ]
  [ -s "$WD/.findings-digest-1" ]   # this arm produced a digest
  run env RESOLVE_LOOP_DIGEST_TOOL="$tool" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume
  [ "$status" -eq 2 ]   # byte-identical → refused by this arm
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
}

@test "the shasum digest arm powers the byte-identical guard" {
  _digest_arm_refuses shasum
}

@test "the sha256sum digest arm powers the byte-identical guard" {
  _digest_arm_refuses sha256sum
}

@test "an unknown RESOLVE_LOOP_DIGEST_TOOL pin disables the guard loudly, not silently" {
  printf '%s' "$CRIT" > "$F"
  run env RESOLVE_LOOP_DIGEST_TOOL=sha256 DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F"
  [ "$status" -eq 20 ]                        # the run itself is unaffected
  contains "$output" "RESOLVE_LOOP_DIGEST_TOOL=sha256 not usable"
  [ ! -e "$WD/.findings-digest-1" ]           # guard is off: no digest recorded
  # ...and with the guard off, byte-identical findings are consumed, not refused
  run env RESOLVE_LOOP_DIGEST_TOOL=sha256 DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume
  [ "$status" -eq 12 ]
}

@test "a hardlinked --findings-file to the dispatch sink is caught, panel output intact" {
  # canonical-path compare misses a hardlink (different name, same inode); -ef catches it
  SINK="$R/.review/findings-round-1.json"
  mkdir -p "$R/.review"
  printf '%s' "$CRIT" > "$SINK"
  LINK="$BATS_TEST_TMPDIR/hardlink.json"
  ln "$SINK" "$LINK" || skip "hardlink not supported here"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$LINK"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.status' <<<"$output")" = "STALE_FINDINGS" ]
  [ -s "$SINK" ]                              # not truncated through the link
}

@test "hook mode is unaffected: identical findings two rounds running still escalate (12), never exit 2" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd-hook-nc" \
    --review-cmd "cp '$CRIT_FILE' \"\$REVIEW_FINDINGS\"" --fix-cmd 'true'
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
}

@test "a fresh step-mode run does NOT execute --test-cmd (step 3's gate already ran)" {
  printf '%s' "$CRIT" > "$F"
  step --test-cmd 'false'
  # if --test-cmd ran, this would be exit 1; the round must proceed to AWAITING_FIX
  [ "$status" -eq 20 ]
}

@test "--test-cmd red at the start of a step-mode resume is ERROR (exit 1) — the prior fix broke the gate" {
  seed_awaiting
  printf '[]' > "$F"
  step --resume --test-cmd 'false'
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "ERROR" ]
}

@test "--test-cmd green at the start of a step-mode resume lets the round proceed" {
  seed_awaiting
  # two resumes since #1434: the clean delta round promotes the closing sweep,
  # and the gate runs at the start of BOTH — which is the point here
  converge_clean --test-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
}

# --- gate attestation: one full-gate run per round (#981) --------------------
# The session already ran the full suite green in Step 3; on --resume the loop
# skips its byte-identical duplicate run ONLY on an exact tree match, and runs
# the gate on any mismatch/absence (fail-closed — the gate never weakens).

TID() { zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/git-tree-id.zsh" "$R"; }

@test "gate-attest: a matching attestation skips the duplicate resume gate (#981)" {
  seed_awaiting
  local attest; attest="$(TID)"
  [ -n "$attest" ]
  # the in-session fix, applied BEFORE the attestation is taken — so the
  # attestation matches the tree the loop will see, and round 2 is a real delta
  # round rather than a blind one (a blind round records no empty-findings
  # marker, which would leave the sweep's byte-identical guard armed)
  echo "x = 1" > "$R/fixed.py"
  attest="$(TID)"
  printf '[]' > "$F"
  # --test-cmd 'false' would ERROR (1) if it RAN; the exact-match skip lets
  # round 2 proceed instead — proving the duplicate run was suppressed.
  step --resume --test-cmd 'false' --gate-attest "$attest"
  [ "$status" -eq 20 ]
  # pin that the SKIP (not a generic pass) is what fired
  contains "$output" "skipping the duplicate --test-cmd run"
  grep -q 'attested green' "$WD/progress.md"
  # Since #1434 that clean delta round promotes the closing sweep, so there is
  # one more resume — and it needs a FRESH attestation, because the round just
  # wrote its own findings sink into the repo and moved the tree. That is what
  # a driving session does anyway (SKILL.md: capture the `tree` from the green
  # gate you just ran, never re-pass a stale one), and the skip fires again.
  local attest2; attest2="$(TID)"
  [ "$attest2" != "$attest" ]
  printf '[]' > "$F"
  step --resume --test-cmd 'false' --gate-attest "$attest2"
  [ "$status" -eq 0 ]
  # the skip emits a diagnostic to stderr, so pull the JSON line off the combined output
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
  contains "$output" "skipping the duplicate --test-cmd run"
}

@test "gate-attest: an uncomputable current identity runs the gate (fail-closed, #981)" {
  seed_awaiting
  local attest; attest="$(TID)"   # the identity that WOULD match if computable
  printf '[]' > "$F"
  # force git-tree-id dark (its git unavailable) while a would-match attest is passed:
  # the ONLY reason the identities don't match is the uncomputable current tree.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_TREE_ID_BIN="$BATS_TEST_TMPDIR/no-such-git" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" \
    --resume --test-cmd 'false' --gate-attest "$attest"
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "ERROR" ]
}

@test "gate-attest: inert in HOOK mode — a matching identity never suppresses the post-fix gate (#981)" {
  # the gate-attest skip is guarded by (step_mode && resume); hook mode is
  # step_mode=0, so --gate-attest must be a no-op. Round 1 hook: review finds a
  # CRIT, fix is a no-op, then --test-cmd 'false' runs after the fix -> ERROR.
  # A matching attestation must NOT stop that gate from running.
  local attest; attest="$(TID)"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd-hook-attest" \
    --review-cmd "cp '$CRIT_FILE' \"\$REVIEW_FINDINGS\"" --fix-cmd 'true' \
    --test-cmd 'false' --gate-attest "$attest"
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "ERROR" ]
}

@test "gate-attest: on a FRESH (non-resume) run --gate-attest is inert — no skip, round proceeds (#981)" {
  # the resume-start gate block is --resume-only, so --gate-attest must do nothing
  # on a fresh round (Step 3's gate has not run in-loop yet). --test-cmd 'false'
  # is also not run on a fresh run, so the CRIT blocker reaches AWAITING_FIX.
  printf '%s' "$CRIT" > "$F"
  local attest; attest="$(TID)"
  step --test-cmd 'false' --gate-attest "$attest"
  [ "$status" -eq 20 ]
  # position-independent and errexit-visible: a `|| !`-inverted list is exempt
  # from errexit, so the old spelling passed even when the string WAS present
  # `run -1`, not `-ne 0`: grep exits 1 for "searched, found nothing" but 2 for
  # "file missing/unreadable", and `-ne 0` accepts the error exit — a
  # progress.md that was never written would silently satisfy this
  run -1 grep -q 'attested green' "$WD/progress.md"
}

@test "gate-attest: a NON-matching attestation still runs the gate (fail-closed, #981)" {
  seed_awaiting
  printf '[]' > "$F"
  step --resume --test-cmd 'false' \
    --gate-attest "0000000000000000000000000000000000000000"
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "ERROR" ]
}

@test "gate-attest: a tree changed since the attestation runs the gate (fail-closed, #981)" {
  seed_awaiting
  local attest; attest="$(TID)"
  echo "print(2)  # changed after the attested gate" >> "$R/app.py"
  printf '[]' > "$F"
  step --resume --test-cmd 'false' --gate-attest "$attest"
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "ERROR" ]
}

@test "gate-attest: an empty --gate-attest value runs the gate (fail-closed, #981)" {
  seed_awaiting
  printf '[]' > "$F"
  step --resume --test-cmd 'false' --gate-attest ''
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "ERROR" ]
}

@test "gate-attest: no --gate-attest is unchanged — the resume gate still runs (#981)" {
  seed_awaiting
  printf '[]' > "$F"
  step --resume --test-cmd 'false'
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "ERROR" ]
}

@test "gate-attest: a STALE attestation falls back to the gate (fail-closed) and the run still converges (#981)" {
  # The name and the assertions follow what this test can actually drive.
  # An earlier spelling called itself a MATCHING-attestation case, but
  # converge_clean writes into the repo between the attestation and the resume,
  # so the loop took the fail-closed MISMATCH branch on both invocations and
  # the gate simply ran — making it a silent duplicate of the plain
  # --test-cmd convergence test. The matching arm is pinned, with a RED
  # --test-cmd as its discriminator, by "a matching attestation skips the
  # duplicate resume gate" above; this is the other arm.
  seed_awaiting
  local attest; attest="$(TID)"
  converge_clean --test-cmd 'true' --gate-attest "$attest"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
  # the FALLBACK is what fired — a green gate alone would look identical, and
  # without this the whole --gate-attest argument could be deleted from the
  # invocation and the test would still pass
  contains "$output" "does not match the working tree"
  contains "$output" "running --test-cmd (fail-closed"
}

@test "progress.md gets a per-round block with severity split, new/carried, fixed-since and trend (step mode, #969)" {
  seed_awaiting
  grep -q '^## Round 1 — blockers remain' "$WD/progress.md"
  grep -q -- '- blockers: 1 (critical: 1, warning: 0) (new: 1, carried: 0), conflicts: 0, suggestions: 0' "$WD/progress.md"
  grep -q -- '- by dimension: bugs 1' "$WD/progress.md"
  # the ORDINARY AWAITING_FIX verdict — the other half of the #1434 if/else
  # whose skip arm is pinned elsewhere. Without both, the two wordings can
  # collapse into one and a round that DOES have blockers is told to apply no
  # fix (or vice versa).
  grep -q -- '- awaiting fix — apply blockers in-session, then --resume' "$WD/progress.md"
  run -1 grep -q 'apply no fix' "$WD/progress.md"
  printf '%s' "$CRIT2" > "$F"
  step --resume
  [ "$status" -eq 12 ]
  grep -q '^## Round 2 — blockers remain' "$WD/progress.md"
  grep -q -- 'new: 0, carried: 1' "$WD/progress.md"
  # the round-2 block carries the found/fixed count and the cumulative trend
  grep -q -- '- fixed since round 1: 0 of 1' "$WD/progress.md"
  grep -q -- '- trend: blocking 1 → 1' "$WD/progress.md"
  # CRIT2 rewords the title ("T" -> "T (still)"), so the carried match is
  # flagged as a possible line-proximity false trip, legibly, in the block
  grep -q -- 'possible false trip' "$WD/progress.md"
  grep -q '^\*\*Final:\*\* ESCALATE_NO_CONVERGENCE' "$WD/progress.md"
}

@test "progress.md ends with a Final line naming the terminal status (converged run)" {
  printf '[]' > "$F"
  step
  [ "$status" -eq 0 ]
  grep -q '^## Round 1 — no blockers' "$WD/progress.md"
  grep -q '^\*\*Final:\*\* CONVERGED' "$WD/progress.md"
}

# NB: the negative below is anchored by a positive on the same file — a bare
# `run -1 grep` for an absent needle passes just as happily on a progress.md
# that was never written at all.
@test "AWAITING_FIX writes its round block but NO Final line (non-terminal)" {
  seed_awaiting
  # the positive first, so the negative below is anchored to a file that
  # demonstrably exists and has content
  grep -q '^## Round 1' "$WD/progress.md"
  run -1 grep -q '^\*\*Final:' "$WD/progress.md"
}

@test "hook mode also writes progress.md (both wirings are observable)" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd-hook" \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  grep -q '^## Round 1 — blockers remain' "$BATS_TEST_TMPDIR/wd-hook/progress.md"
  grep -q -- '- fix pass (in-loop), continuing' "$BATS_TEST_TMPDIR/wd-hook/progress.md"
  grep -q '^## Round 2 — no blockers' "$BATS_TEST_TMPDIR/wd-hook/progress.md"
  grep -q '^\*\*Final:\*\* CONVERGED' "$BATS_TEST_TMPDIR/wd-hook/progress.md"
}

@test "an unwritable progress.md never aborts the run (transparency is non-fatal)" {
  mkdir -p "$WD/progress.md"   # a DIRECTORY at the target path defeats appends
  printf '[]' > "$F"
  step
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
}

@test "no telemetry record on AWAITING_FIX; exactly one on the terminal invocation" {
  T="$BATS_TEST_TMPDIR/telemetry.jsonl"
  printf '%s' "$CRIT" > "$F"
  step --telemetry-file "$T"
  [ "$status" -eq 20 ]
  # `! -e`, not `! -s`: the contract is that AWAITING_FIX writes NOTHING, so a
  # regression that merely touches the sink before the terminal guard must fail
  [ ! -e "$T" ]
  # ...and nothing landed in the default sink either (AC3 is about the stream)
  [ ! -e "$R/.claude/telemetry/telemetry.jsonl" ]
  # two resumes since #1434 (the clean delta round promotes the closing sweep),
  # and the AWAITING_FIX in between must ALSO write nothing — which is exactly
  # the claim, now tested across one more non-terminal exit
  converge_clean --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$T")" -eq 1 ]
}

@test "terminal telemetry reports whole-loop wall clock from .t0, not the last round's" {
  T="$BATS_TEST_TMPDIR/telemetry-wall.jsonl"
  seed_awaiting
  # back-date the loop's logical start by 100s; the terminal record must span it
  echo "$(( $(date +%s) - 100 ))" > "$WD/.t0"
  converge_clean --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.wall_s >= 100' "$T")" = "true" ]
}

@test "#1434 an empty (zero-byte) findings file on a FULL round is REFUSED too" {
  # Same argument as the missing file: a truncated write is not a clean review.
  : > "$F"
  step
  [ "$status" -eq 2 ]
  # `grep '^{'`: the refusal prints its diagnostic on stderr, which `run` merges
  # into $output ahead of the status JSON
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  # the STEP-mode wording: it must name the caller's own --findings-file,
  # and must NOT send them to write into the dispatch sink, which the alias
  # guard then refuses — one mistake, two contradictory refusals
  contains "$output" "is a FULL round and --findings-file is missing or empty"
  contains "$output" "never the dispatch sink"
}

@test "step mode drops findings on the work-dir's own files (#909/#911 parity)" {
  WDIN="$R/.loop-wd"
  printf '%s' "$CRIT" > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDIN" --findings-file "$F"
  [ "$status" -eq 20 ]
  # the phantom finding is dropped, so round 2 sees zero blockers — but since
  # #1434 that clean DELTA round promotes the closing sweep rather than ending
  # the run, and round 3 is what converges. The claim under test (a finding on
  # the work-dir's own files never counts) is unchanged.
  printf '%s' '[{"severity":"CRITICAL","dimension":"bugs","file":".loop-wd/progress.md","line":1,"title":"phantom","description":"d","reviewer":"r"}]' > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDIN" --findings-file "$F" --resume
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.final_changelist.summary.blocking')" -eq 0 ]
  printf '%s' '[{"severity":"CRITICAL","dimension":"bugs","file":".loop-wd/history.jsonl","line":1,"title":"phantom two","description":"d","reviewer":"r"}]' > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDIN" --findings-file "$F" --resume
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
}

@test "a .t0 stamped in the FUTURE clamps wall_s to 0 instead of losing the record (#1004)" {
  # .t0 survives only across a --resume (a fresh run rewrites it), which is
  # exactly where a copied work-dir or an NTP step back bites. The emitter
  # rejects a negative --wall-s (exit 2) and the loop swallows that with
  # `|| true`, so without the clamp the whole terminal record vanishes.
  T="$BATS_TEST_TMPDIR/future-wall.jsonl"
  seed_awaiting
  echo "$(( $(date +%s) + 600 ))" > "$WD/.t0"
  converge_clean --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$T")" -eq 1 ]
  [ "$(jq '.wall_s' "$T")" -eq 0 ]
}

@test "an over-wide .t0 falls back to the run's own start rather than losing the record (#1004)" {
  # digits alone are not enough: --ts carries the emitter's 18-digit cap, so a
  # 20-digit .t0 would be rejected there and cost the record
  T="$BATS_TEST_TMPDIR/wide-t0.jsonl"
  seed_awaiting
  echo "99999999999999999999" > "$WD/.t0"
  local NOW; NOW="$(date +%s)"
  converge_clean --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$T")" -eq 1 ]
  local TS
  TS="$(jq -r '.ts' "$T")"
  [ "${#TS}" -le 11 ]        # a real epoch, not the unusable stamp
  # ...and specifically THIS invocation's start, not some other epoch: `$now`
  # is captured just before the resume, so a fallback to .t0 (or anything
  # older) fails here rather than passing on a vacuous `>= 0`
  [ "$TS" -ge "$NOW" ]
}

@test "the step-mode RESUME ERROR path emits a telemetry record too (#1004)" {
  # a second emission call site: the red-gate-after-a-fix abort. It passes
  # repo_type="" and the resumed round, unlike every path covered elsewhere.
  T="$BATS_TEST_TMPDIR/resume-error.jsonl"
  seed_awaiting
  printf '[]' > "$F"
  step --resume --test-cmd 'false' --telemetry-file "$T"
  [ "$status" -eq 1 ]
  [ "$(grep -c '' "$T")" -eq 1 ]
  [ "$(jq -r '.schema' "$T")" = "telemetry/v1" ]
  [ "$(jq -r '.pipeline' "$T")" = "review-loop" ]
  [ "$(jq -r '.outcome' "$T")" = "failed" ]
  [ "$(jq -r '.payload.status' "$T")" = "ERROR" ]
  [ "$(jq -r '.repo_type' "$T")" = "null" ]
  [ "$(jq -r '.wall_s | type' "$T")" = "number" ]
  run zsh "$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh" "$T" --require-records
  [ "$status" -eq 0 ]
}

@test "a NON-NUMERIC .t0 falls back to this run's start — the record survives and the exit is untouched (#1004)" {
  # The guard is two-part (`<->` AND width); the width half is covered above,
  # this is the digits half. A corrupt .t0 — a truncated write, a hand-edited
  # or copied work-dir, the same corruption class this suite already tests for
  # history.jsonl and changelists.jsonl — would otherwise reach `--ts`, which
  # the emitter rejects as non-numeric behind `|| true` (losing the whole
  # record), and would make `$(( ... - t_begin ))` evaluate a bare identifier
  # under `setopt nounset`, aborting the loop with exit 1 instead of its verdict.
  T="$BATS_TEST_TMPDIR/corrupt-t0.jsonl"
  seed_awaiting
  printf 'not-a-number\n' > "$WD/.t0"
  local NOW; NOW="$(date +%s)"
  converge_clean --telemetry-file "$T"
  # the verdict is the loop's own, NOT an operational abort
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
  # ...and the record still landed, stamped from this invocation's start
  [ "$(grep -c '' "$T")" -eq 1 ]
  [ "$(jq -r '.ts | type' "$T")" = "number" ]
  [ "$(jq '.ts' "$T")" -ge "$NOW" ]
  [ "$(jq -r '.wall_s | type' "$T")" = "number" ]
  run zsh "$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh" "$T" --require-records
  [ "$status" -eq 0 ]
}

# --- suggestion promotion across INVOCATIONS (#994, test case #1021) ---------
#
# In step mode each round is its own invocation, so "the overlay is applied every
# round" is a claim about CROSS-INVOCATION state, not about one process's loop.
# The promoted set therefore lives in the work-dir and is re-adopted on --resume.
# Without that, a --resume which omitted --promote would consolidate with no
# overlay, demote the item back to Low, reach zero blockers and exit CONVERGED —
# the feature failing as a terminal SUCCESS.

SUGG='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"extract the magic number","description":"d","reviewer":"q"}]'
SUGG2='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"extract the magic number","description":"d2 (still there)","reviewer":"q2"}]'

promote_file() {
  P="$BATS_TEST_TMPDIR/promote.json"
  printf '%s' '[{"file":"app.py","line":1,"dimension":"code_quality","title":"extract the magic number"}]' > "$P"
}

@test "#1021 step mode: --promote makes round 1 block instead of converging" {
  promote_file
  printf '%s' "$SUGG" > "$F"
  step --promote "$P"
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  [ "$(echo "$output" | jq '.round_changelists[0].summary.blocking')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.round_changelists[0].blocking[0].priority')" = "High" ]
}

@test "#1021 step mode: a --resume that re-passes --promote keeps the item blocking" {
  promote_file
  printf '%s' "$SUGG" > "$F"
  step --promote "$P"
  [ "$status" -eq 20 ]

  printf '%s' "$SUGG2" > "$F"
  step --resume --promote "$P"
  # the promoted blocker survived two rounds unfixed, so this is the NAMED
  # escalation — asserting the positive verdict, not a != CONVERGED negative
  # which would pass just as happily on an operational abort
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  # still blocking in round 2, so the overlay reached the resumed invocation's
  # consolidator alongside --prev
  [ "$(echo "$output" | jq '.round_changelists[1].summary.blocking')" -eq 1 ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.low')" -eq 0 ]
}

@test "#1021 step mode: a --resume that OMITS --promote re-adopts it from the work-dir" {
  # the one-flag slip in a long command line. Its failure mode was a silent
  # CONVERGED, so the loop persists the set and recovers rather than converging.
  promote_file
  printf '%s' "$SUGG" > "$F"
  step --promote "$P"
  [ "$status" -eq 20 ]
  [ -s "$WD/.promote" ]
  # the path is canonicalised before it is persisted, so cross-invocation state
  # cannot depend on the cwd of whichever invocation wrote it. Compare by INODE
  # (-ef), not by string: the canonical form resolves symlinks (/tmp -> /private/tmp
  # on macOS), so a string compare against the raw path is wrong, and ${P:A} is a
  # zsh modifier bash would not expand here.
  [ "$(cat "$WD/.promote")" -ef "$P" ]
  case "$(cat "$WD/.promote")" in /*) ;; *) return 1 ;; esac

  # separate the streams: the adoption prints a NOTICE to stderr (stdout stays
  # exactly the status JSON), and the merged default would make $output unparseable
  printf '%s' "$SUGG2" > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume
  contains "$stderr" "adopting the run's promoted set"
  [ "$(echo "$output" | jq '.round_changelists[1].summary.blocking')" -eq 1 ]
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
}

@test "#1021 step mode: a fresh run clears a previous run's persisted promoted set" {
  # a re-used work-dir must not resurrect an overlay this run never asked for
  promote_file
  printf '%s' "$SUGG" > "$F"
  step --promote "$P"
  [ "$status" -eq 20 ]
  [ -s "$WD/.promote" ]

  printf '%s' "$SUGG" > "$F"
  step                      # fresh run, no --promote
  [ ! -e "$WD/.promote" ]
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.round_changelists[0].summary.blocking')" -eq 0 ]
  # the suggestion is still THERE, just not promoted — blocking==0 alone would
  # also hold if the run had lost the finding
  [ "$(echo "$output" | jq '.round_changelists[0].summary.low')" -eq 1 ]
}

@test "#1021 step mode: a nonexistent --promote path is a usage error before any round work" {
  # Unchecked, this survived parse and failed mid-round at a bare exit 1 that
  # writes NO status JSON, leaving --status-file holding a previous verdict.
  printf '%s' "$SUGG" > "$F"
  ST="$BATS_TEST_TMPDIR/status.json"
  printf '%s' '{"status":"AWAITING_FIX","rounds":1}' > "$ST"
  step --promote "$BATS_TEST_TMPDIR/nope.json" --status-file "$ST"
  [ "$status" -eq 2 ]
  contains "$output" "--promote must be a non-empty regular file"
  # the stale verdict is untouched, and the round sink was never consumed
  [ "$(jq -r '.status' "$ST")" = "AWAITING_FIX" ]
  [ -s "$F" ]
}

@test "#1021 step mode: an empty --promote file is a usage error too" {
  printf '%s' "$SUGG" > "$F"
  : > "$BATS_TEST_TMPDIR/empty-promote.json"
  step --promote "$BATS_TEST_TMPDIR/empty-promote.json"
  [ "$status" -eq 2 ]
  contains "$output" "--promote must be a non-empty regular file"
}

@test "#1021 step mode: a --resume whose ADOPTED promote path has vanished is refused (2)" {
  # The promote file lives in a scratch dir alongside the work-dir, so a cleaned
  # or rotated scratch between rounds is the production shape of this branch.
  # Forwarding a dead path would fail mid-round as a bare exit 1 that writes no
  # status JSON — the untyped verdict the up-front guard exists to prevent.
  promote_file
  printf '%s' "$SUGG" > "$F"
  step --promote "$P"
  [ "$status" -eq 20 ]

  rm -f "$P"
  ST="$BATS_TEST_TMPDIR/status.json"
  printf '%s' '{"status":"AWAITING_FIX","rounds":1}' > "$ST"
  printf '%s' "$SUGG2" > "$F"
  step --resume --status-file "$ST"
  [ "$status" -eq 2 ]
  # the branch-specific phrase: asserting only the shared prefix could not tell
  # the vanished-file refusal from the wrong-shape one
  contains "$output" "--resume adopted promoted set"
  contains "$output" "must be a non-empty regular file"
  # the prior verdict survives and the round sink was never consumed
  [ "$(jq -r '.status' "$ST")" = "AWAITING_FIX" ]
  [ -s "$F" ]
}

@test "#1021 step mode: an explicit --promote on --resume overrides AND refreshes the persisted set" {
  # Re-passing the SAME path cannot distinguish "the explicit flag won" from
  # "the persisted state was adopted". Re-point it at a set that matches nothing
  # and the two paths diverge — and the NEXT omitted-flag resume must adopt the
  # NEW path, not the superseded one.
  promote_file
  printf '%s' "$SUGG" > "$F"
  step --promote "$P"
  [ "$status" -eq 20 ]

  P2="$BATS_TEST_TMPDIR/promote2.json"
  printf '%s' '[{"file":"app.py","line":1,"dimension":"tests","title":"something else entirely"}]' > "$P2"
  printf '%s' "$SUGG2" > "$F"
  step --resume --promote "$P2"
  # P2 matches nothing, so the suggestion stays Low and the round is clean. It
  # is a DELTA round, so since #1434 it promotes the closing sweep rather than
  # converging; the sweep converges next.
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq '.final_changelist.summary.blocking')" -eq 0 ]
  printf '%s' "$SUGG" > "$F"
  step --resume --promote "$P2"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.blocking')" -eq 0 ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.low')" -eq 1 ]
  # and the persisted state was REFRESHED to P2 — a stale P here would have the
  # next omitted-flag resume silently revert to the superseded selection
  [ "$(cat "$WD/.promote")" -ef "$P2" ]
}

@test "#1021 step mode: a --promote path that is a directory is refused up front" {
  printf '%s' "$SUGG" > "$F"
  step --promote "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  contains "$output" "--promote must be a non-empty regular file"
}

@test "#1021 step mode: a wrong-SHAPE promote file is refused up front, not mid-round" {
  printf '%s' "$SUGG" > "$F"
  BAD="$BATS_TEST_TMPDIR/bad-promote.json"
  printf '%s' '["a bare title"]' > "$BAD"
  ST="$BATS_TEST_TMPDIR/status.json"
  printf '%s' '{"status":"AWAITING_FIX","rounds":1}' > "$ST"
  step --promote "$BAD" --status-file "$ST"
  [ "$status" -eq 2 ]
  contains "$output" "non-empty file and dimension and a string title"
  [ "$(jq -r '.status' "$ST")" = "AWAITING_FIX" ]
  [ -s "$F" ]
}

@test "#1021 step mode: an ADOPTED promote file rewritten to a bad shape is refused (2)" {
  # The promote file lives outside the work-dir, so between rounds it can be
  # rewritten as well as removed. Both branches of the adoption guard must be
  # distinguishable, and neither may forward a bad file into the round.
  promote_file
  printf '%s' "$SUGG" > "$F"
  step --promote "$P"
  [ "$status" -eq 20 ]

  printf '%s' '["a bare title"]' > "$P"
  ST="$BATS_TEST_TMPDIR/status.json"
  printf '%s' '{"status":"AWAITING_FIX","rounds":1}' > "$ST"
  printf '%s' "$SUGG2" > "$F"
  step --resume --status-file "$ST"
  [ "$status" -eq 2 ]
  contains "$output" "--resume adopted promoted set"
  contains "$output" "non-empty file and dimension and a string title"
  [ "$(jq -r '.status' "$ST")" = "AWAITING_FIX" ]
  [ -s "$F" ]
}

@test "#1021 step mode: a RELATIVE --promote is canonicalised, so a later resume from another cwd still adopts it" {
  # With an already-absolute fixture the canonicalisation assertions are
  # tautological — they pass with the :A modifier deleted. A relative path is
  # the only input that can distinguish them.
  promote_file
  printf '%s' "$SUGG" > "$F"
  local rc=0
  # round 1 from INSIDE the promote file's directory, naming it relatively.
  # `run` in a subshell would not export its results, so invoke directly and
  # assert on the persisted file instead.
  ( cd "$BATS_TEST_TMPDIR" && \
    DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
      zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" \
      --promote promote.json >/dev/null 2>&1 ) || rc=$?
  # assert the expected terminal rather than swallowing it: a regression to a
  # usage error would otherwise surface opaquely at the .promote assertion below
  [ "${rc:-0}" -eq 20 ]
  # persisted ABSOLUTE and pointing at the same file, despite the relative input
  # — this is the assertion the :A modifier exists for, and it fails without it
  case "$(cat "$WD/.promote")" in /*) ;; *) return 1 ;; esac
  [ "$(cat "$WD/.promote")" -ef "$P" ]

  # resume with the flag omitted: a non-canonicalised relative path would now be
  # unresolvable and refused (exit 2) instead of adopted
  # separated streams: the adoption prints a NOTICE to stderr, and the merged
  # default would make $output unparseable
  printf '%s' "$SUGG2" > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume
  [ "$status" -eq 12 ]
  contains "$stderr" "adopting the run's promoted set"
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.blocking')" -eq 1 ]
}

@test "#1021 step mode: a failed persist of the promoted set is fatal, not swallowed" {
  # Losing this state silently degrades to a false CONVERGED on a later resume,
  # so the write is deliberately fatal. A directory at the target path defeats
  # the redirect the same way the suite already does for progress.md.
  promote_file
  printf '%s' "$SUGG" > "$F"
  mkdir -p "$WD"
  rm -f "$WD/.promote"
  mkdir "$WD/.promote"
  step --promote "$P"
  [ "$status" -eq 1 ]
  contains "$output" "could not persist the promoted set"
}

@test "#1021 step mode: a promote key with the dimension omitted is refused up front" {
  # It used to match NOTHING — the human's selection silently dropped and the
  # sub-loop converging having done none of the work, with no diagnostic. The
  # identity keys are required now, so it is a typed usage error instead.
  printf '%s' "$SUGG" > "$F"
  BAD="$BATS_TEST_TMPDIR/nodim.json"
  printf '%s' '[{"file":"app.py","line":1,"title":"extract the magic number"}]' > "$BAD"
  step --promote "$BAD"
  [ "$status" -eq 2 ]
  contains "$output" "objects with non-empty file and dimension and a string title"
}

@test "#1021 step mode: the promoted item is fixed and the sub-loop converges with the overlay still active" {
  # The feature's definition-of-done, and the one convergence path no other test
  # covers: every other converge-with-overlay case happens because the overlay
  # matched nothing. A regression making an ACTIVE overlay unable to converge
  # would otherwise show up only as a production hang-to-budget.
  promote_file
  printf '%s' "$SUGG" > "$F"
  step --promote "$P"
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq '.round_changelists[0].summary.blocking')" -eq 1 ]

  # the fix landed: the panel no longer raises it. Round 2 is a delta round, so
  # since #1434 it promotes the closing full sweep; round 3 converges with the
  # overlay still in force. The edit is what makes round 2 a real delta round
  # rather than a blind one.
  echo "x = promoted-fix" > "$R/promoted-fix.py"
  printf '[]' > "$F"
  step --resume --promote "$P"
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq '.final_changelist.summary.blocking')" -eq 0 ]
  printf '[]' > "$F"
  step --resume --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.blocking')" -eq 0 ]
  [ "$(echo "$output" | jq '.round_changelists[2].summary.blocking')" -eq 0 ]
  # the overlay was still active throughout
  [ "$(cat "$WD/.promote")" -ef "$P" ]
}

@test "#1021 step mode: a zero-byte .promote is BROKEN state, refused rather than silently dropped" {
  # `-s` would skip adoption and run with no overlay, converging as a false
  # success — the failure the state file exists to prevent, via the file itself.
  promote_file
  printf '%s' "$SUGG" > "$F"
  step --promote "$P"
  [ "$status" -eq 20 ]

  : > "$WD/.promote"
  printf '%s' "$SUGG2" > "$F"
  step --resume
  [ "$status" -eq 2 ]
  contains "$output" "the promoted set was lost"
}

@test "#1021 step mode: a promote file of key-less objects is refused up front" {
  printf '%s' "$SUGG" > "$F"
  BAD="$BATS_TEST_TMPDIR/keyless.json"
  printf '%s' '[{}]' > "$BAD"
  step --promote "$BAD"
  [ "$status" -eq 2 ]
  contains "$output" "objects with non-empty file and dimension and a string title"
}

@test "#1021 step mode: an EMPTY dimension value is refused by the loop's validator too" {
  # The sibling of the EMPTY-file case, and the one that isolates the
  # `dimension | length > 0` conjunct: the dimension-OMITTED fixture is already
  # refused by `type == "string"` on null, so without this case that conjunct is
  # individually deletable — and an empty dimension then sails past the up-front
  # validator to be refused mid-round by the consolidator, as a BARE exit 1 that
  # writes no status JSON (the #912 hazard this validation exists to close).
  printf '%s' "$SUGG" > "$F"
  BAD="$BATS_TEST_TMPDIR/emptydim.json"
  printf '%s' '[{"file":"app.py","dimension":"","title":"extract the magic number"}]' > "$BAD"
  step --promote "$BAD"
  [ "$status" -eq 2 ]
  contains "$output" "non-empty file and dimension and a string title"
}

@test "#1021 step mode: an EMPTY file value is refused by the loop's validator" {
  # The loop's predicate is documented as mirroring the consolidator's exactly.
  # Every other loop shape test uses key ABSENCE, so a relaxation to presence-only
  # checks would leave them green and let the two validators drift.
  printf '%s' "$SUGG" > "$F"
  BAD="$BATS_TEST_TMPDIR/emptyfile.json"
  printf '%s' '[{"file":"","dimension":"code_quality","title":"extract the magic number"}]' > "$BAD"
  step --promote "$BAD"
  [ "$status" -eq 2 ]
  contains "$output" "non-empty file and dimension and a string title"
}

@test "#1021 step mode: a NULL title is refused by the loop's validator" {
  printf '%s' "$SUGG" > "$F"
  BAD="$BATS_TEST_TMPDIR/nulltitle.json"
  printf '%s' '[{"file":"app.py","dimension":"code_quality","title":null}]' > "$BAD"
  step --promote "$BAD"
  [ "$status" -eq 2 ]
  contains "$output" "non-empty file and dimension and a string title"
}

@test "#1021 step mode: an EMPTY promoted array is refused (selecting none skips the sub-loop)" {
  printf '%s' "$SUGG" > "$F"
  BAD="$BATS_TEST_TMPDIR/emptyarr.json"
  printf '%s' '[]' > "$BAD"
  ST="$BATS_TEST_TMPDIR/status.json"
  printf '%s' '{"status":"AWAITING_FIX","rounds":1}' > "$ST"
  step --promote "$BAD" --status-file "$ST"
  [ "$status" -eq 2 ]
  contains "$output" "non-empty JSON array"
  [ "$(jq -r '.status' "$ST")" = "AWAITING_FIX" ]
}

@test "#1021 step mode: an ADOPTED promote file emptied to [] is refused on resume" {
  # the shape a human "deselect everything" edit produces between rounds — and
  # the adoption path is where a false CONVERGED is most costly
  promote_file
  printf '%s' "$SUGG" > "$F"
  step --promote "$P"
  [ "$status" -eq 20 ]

  printf '%s' '[]' > "$P"
  printf '%s' "$SUGG2" > "$F"
  step --resume
  [ "$status" -eq 2 ]
  contains "$output" "--resume adopted promoted set"
  contains "$output" "non-empty JSON array"
}

# ---- delta scoping, the prior tree, and the closing full sweep (#1434) -------
#
# Step mode is the canonical wiring, so this is where the iteration machinery
# has to work: the session applies fixes BETWEEN invocations, and the loop must
# still know what the previous round's reviewers saw.

@test "#1434 step mode: the prior tree comes from the loop, not from --gate-attest" {
  # A Java repo ships no run-gate.zsh, so the session passes NO --gate-attest at
  # all (SKILL.md tells it to omit the flag off plugin repos). The delta must
  # still be computed, because the loop persists its own identity per round —
  # "unresolvable prior tree" must not become the normal case off plugin repos.
  printf '%s' "$CRIT" > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["java"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F"
  [ "$status" -eq 20 ]
  [ -s "$WD/tree-1.txt" ]

  # the session's in-session fix, applied between invocations
  echo "print(2)" > "$R/fixed.py"
  distinct_blocker 2 > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["java"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume
  [ "$status" -eq 20 ]
  [ -s "$WD/tree-2.txt" ]
  [ "$(cat "$WD/tree-1.txt")" != "$(cat "$WD/tree-2.txt")" ]
  # round 2's scope is exactly what the fix touched
  [ "$(cat "$WD/scope.txt")" = "fixed.py" ]
  run -1 grep -q 'does not resolve to a tree' <<< "$stderr"
  # ...and a finding about app.py — in the story diff but NOT in the delta —
  # still survives, because scope-findings filters on the full story diff
  [ "$(jq '.summary.blocking' "$WD/changelist-2.json")" -eq 1 ]
  [ "$(jq -r '.blocking[0].file' "$WD/changelist-2.json")" = "app.py" ]
}

@test "#1434 step mode: a missing prior tree at round 2 is exit 1, and no round work happens" {
  seed_awaiting
  rm -f "$WD/tree-1.txt"
  distinct_blocker 2 > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume
  [ "$status" -eq 1 ]
  contains "$stderr" "no usable prior tree identity"
  # the abort happens before ANY round work: no scope was planned and the
  # round's findings sink was never created, so nothing was silently reviewed
  # against a full diff instead
  [ ! -e "$R/.review/findings-round-2.json" ]
  [ ! -e "$WD/changelist-2.json" ]
}

@test "#1434 step mode: a fresh run truncates the .findings-empty markers a previous run left" {
  # Both per-run marker families are wiped on a fresh (non---resume) start. The
  # digest half is pinned elsewhere; without this the `.findings-empty-*` term
  # can be deleted and the whole suite stays green, shipping a fail-OPEN
  # regression: a NEW run whose round 2 finds suggestions only (zero blockers,
  # non-empty findings) writes no marker of its own, a stale one from the
  # previous run satisfies the waiver, and the #974 byte-identical guard is
  # disarmed on the run's LAST round.
  seed_awaiting                       # run 1, round 1: one blocker
  echo "print(2)" > "$R/fixed.py"
  printf '[]' > "$F"                  # run 1, round 2: clean delta
  step --resume
  [ "$status" -eq 20 ]
  [ -s "$WD/.findings-empty-2" ]
  # ...now a FRESH run in the same work-dir
  printf '%s' "$CRIT" > "$F"
  step
  [ "$status" -eq 20 ]
  [ ! -e "$WD/.findings-empty-2" ]
  [ ! -e "$WD/.findings-digest-2" ]
}

@test "#1434 step mode: a BLANK prior tree at round 2 is exit 1, not a silent full diff" {
  # The identity is read with the whitespace stripped precisely so a corrupt
  # write cannot become a blank `--prior-tree` value: review-dispatch would
  # refuse that at exit 2, which the loop relabels as the generic "dispatch
  # plan failed" internal error — a confidently misattributed cause, and one
  # that hides the unusable identity the guard exists to name.
  seed_awaiting
  printf '   \n' > "$WD/tree-1.txt"
  printf '[]' > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume --max-rounds 3
  [ "$status" -eq 1 ]
  contains "$stderr" "no usable prior tree identity"
  # the discriminator: the round did no work at all
  [ ! -e "$WD/changelist-2.json" ]
}

@test "#1434 step mode: a zero-blocker delta round exits 20 and promotes the closing sweep" {
  seed_awaiting                       # round 1 (full): one blocker
  echo "print(2)" > "$R/fixed.py"     # the in-session fix
  printf '[]' > "$F"                  # round 2 (delta): nothing found
  step --resume
  [ "$status" -eq 20 ]
  # NOT converged: a delta round has proved nothing about the story as a whole
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  [ "$(echo "$output" | jq '.final_changelist.summary.blocking')" -eq 0 ]
  [ "$(cat "$WD/.closing-sweep")" = "3" ]
  # an in-budget sweep adopted on --resume is NOT a grant. The hook-mode control
  # cannot reach this arm (a single invocation never runs the adoption block),
  # so without this the adoption guard could be deleted and every resumed run
  # would report the flag true.
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "false" ]

  # the session applies NO fix and just resumes; the closing sweep is a FULL
  # sweep and it is what converges. Its findings are byte-identical `[]` to the
  # round before — the expected shape here, and deliberately exempt from the
  # #974 byte-identical refusal.
  printf '[]' > "$F"
  step --resume
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 3 ]
  # ...and THIS is the invocation that runs the --resume adoption block (the one
  # above only promoted the sweep, so the marker did not exist at its
  # resume-start). The sweep is in budget, so adopting it is not a grant.
  # Without the assertion here the adoption guard's `> max_rounds` condition
  # could be deleted and every ordinary resumed run would report the flag true.
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "false" ]
}

@test "#1434 step mode: a ZERO-BYTE .findings-empty marker does not waive the sweep's guard" {
  # The marker is read with `-f && -s`: its own write truncates before it fills,
  # so a zero-byte file is a FAILED write, and `-s` alone would accept a
  # directory left at the path. Reading that as "present"
  # waives the #974 byte-identical guard on the run's LAST round — the one
  # round that could still catch a panel that never ran — which is fail-OPEN.
  seed_awaiting                       # round 1: one blocker
  echo "print(2)" > "$R/fixed.py"     # the in-session fix
  printf '[]' > "$F"                  # round 2 (delta): nothing found
  step --resume
  [ "$status" -eq 20 ]
  [ -s "$WD/.findings-empty-2" ]      # the loop wrote it in full
  : > "$WD/.findings-empty-2"         # ...now simulate the truncated write
  printf '[]' > "$F"                  # the sweep's legitimate `[]` — refused
  step --resume
  [ "$status" -eq 2 ]
  contains "$output" "byte-identical to round 2"
}

@test "#1434 step mode: a zero-blocker delta round AT the ceiling grants one more round" {
  # --max-rounds 2, so round 2 is the ceiling. Without the grant the safety net
  # would be skipped exactly when the run has been longest — and in step mode
  # the --resume would be refused outright by the ceiling guard, making the
  # sweep unreachable.
  printf '%s' "$CRIT" > "$F"
  step --max-rounds 2
  [ "$status" -eq 20 ]

  echo "print(2)" > "$R/fixed.py"
  printf '[]' > "$F"
  step --resume --max-rounds 2
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq '.final_changelist.summary.blocking')" -eq 0 ]
  # the grant is a fact about this run, not a bigger budget
  [ "$(echo "$output" | jq '.max_rounds')" -eq 2 ]
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "true" ]
  [ "$(cat "$WD/.closing-sweep")" = "3" ]

  # ...and the resume into the granted round is ACCEPTED, not refused
  printf '[]' > "$F"
  step --resume --max-rounds 2
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 2 ]
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "true" ]
}

@test "#1434 step mode: a round whose panel saw an EMPTY scope can never converge" {
  # The panel runs BEFORE the invocation, so on an empty delta it reviewed
  # nothing — and `[]` from a round that reviewed nothing must not be able to
  # reach CONVERGED, which would ship round 1's unfixed blockers AND skip the
  # closing sweep (CONVERGED ends the run). The round therefore stays a DELTA
  # round: it promotes the closing sweep instead of ending the run, and the
  # session scopes THAT round with --final and really does review it.
  seed_awaiting                       # round 1: one blocker
  printf '[]' > "$F"                  # no fix applied: round 2's delta is empty
  step --resume
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  [ "$(echo "$output" | jq '.final_changelist.summary.blocking')" -eq 0 ]
  # NOT converged, and the safety net is queued — in budget, so not a grant
  [ "$(cat "$WD/.closing-sweep")" = "3" ]
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "false" ]
  grep -q '^\*\*Scope (round 2):\*\* empty delta' "$WD/progress.md"
  grep -q 'cannot converge' "$WD/progress.md"
  # the round's verdict line names the sweep and forbids a fix — rendering the
  # ordinary "awaiting fix — apply blockers in-session" here would send the
  # session to invent changes on a round that found none, moving the very tree
  # the sweep is about to read
  grep -q -- '- no blockers in the delta — round 3 is the closing full sweep; apply no fix, just --resume' "$WD/progress.md"

  # The round is a verification-only round, so the loop re-plans its SCOPE to
  # the whole story diff — matching what SKILL.md told the session's panel to
  # review — even though it keeps the round a delta round for the convergence
  # decision. That recorded scope is what stops it being classified BLIND, and
  # so the closing sweep it promotes can still converge on its own legitimate
  # `[]`. Reading the round as blind here would wedge the run one round short
  # of CONVERGED, with no action able to change the bytes of an empty array.
  # a CONTENT assertion, not mere non-emptiness: a re-derivation that wrote the
  # wrong non-empty scope (one work-dir file, or the pre-re-plan descriptor's)
  # would satisfy `-s` while the panel had been handed the wrong thing
  grep -qx 'app.py' "$WD/scope.txt"
  [ -s "$WD/.findings-empty-2" ]
  printf '[]' > "$F"
  step --resume
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  # the second control on the adoption path: in budget, so adopted but not granted
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "false" ]
}

@test "#1434 step mode: a failed empty-findings marker WRITE says so, and the waiver stays armed" {
  # The marker is what waives the closing sweep's byte-identical guard. A failed
  # write fails CLOSED (the waiver stays armed), which is right — but silently
  # it would look identical to a healthy blind round.
  seed_awaiting
  echo "print(2)" > "$R/fixed.py"
  mkdir -p "$WD/.findings-empty-2"      # rm/print both refuse a directory
  printf '[]' > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume
  [ "$status" -eq 20 ]
  contains "$stderr" "could not record the round 2 empty-findings marker"
  contains "$stderr" "stay armed"
  # ...and the OBSERVABLE consequence: the sweep's legitimate `[]` is refused
  printf '[]' > "$F"
  step --resume
  [ "$status" -eq 2 ]
  contains "$output" "byte-identical to round 2"
}

@test "#1434 step mode: a failed empty-findings marker CLEAR says so — the fail-OPEN direction" {
  # The clear runs when a round consumed NON-empty findings. Leaving a stale
  # marker behind disarms the #974 guard on the run's last round, so this is
  # the one direction that fails open and nothing else would notice it.
  seed_awaiting
  echo "print(2)" > "$R/fixed.py"
  mkdir -p "$WD/.findings-empty-2"
  local SUGG_ONLY='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":9,"title":"rename the temp variable","description":"d","reviewer":"r"}]'
  printf '%s' "$SUGG_ONLY" > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume
  [ "$status" -eq 20 ]
  contains "$stderr" "could not clear the round 2 empty-findings marker"
  contains "$stderr" "wrongly disarmed"
}

@test "#1434 step mode: the digest waiver needs ALL THREE facts — a sweep AFTER a round that found something is still guarded" {
  # The waiver is keyed on ALL THREE facts — a recorded sweep, the previous
  # round's consumed findings being `[]`, and THAT ROUND'S SCOPE having been
  # non-empty. This test drives the first two; the third is folded into the
  # marker's WRITE (the loop records no marker for a round that saw nothing)
  # rather than into the read, and the neighbouring "an EMPTY scope can never
  # converge" test asserts that half via `grep -qx 'app.py' scope.txt` plus a
  # non-empty marker. The third conjunct is defence-in-depth: every reachable
  # scope-empty round is either refused or re-planned `--final`, so no fixture
  # isolates it. Keying the waiver on the sweep marker alone would waive the
  # guard for a round that found only suggestions — which promotes a sweep just
  # the same — so a caller re-passing that round's file by mistake would have it
  # consumed as the sweep's own findings and converge on a panel that never ran.
  seed_awaiting                                  # round 1: one blocker
  echo "print(2)" > "$R/fixed.py"                # the in-session fix
  local SUGG_ONLY='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":9,"title":"rename the temp variable","description":"d","reviewer":"r"}]'
  printf '%s' "$SUGG_ONLY" > "$F"
  # plant a marker for the round to CLEAR, so the absence asserted below is a
  # real discriminator rather than a fact about a file that never existed —
  # the stale-marker-from-a-retried-round case is the fail-OPEN direction
  printf '1' > "$WD/.findings-empty-2"
  step --resume
  # zero BLOCKERS but non-empty findings: the round promotes the closing sweep
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq '.final_changelist.summary.blocking')" -eq 0 ]
  [ "$(echo "$output" | jq '.final_changelist.summary.low')" -eq 1 ]
  [ "$(cat "$WD/.closing-sweep")" = "3" ]
  # the second fact is recorded by ABSENCE here: a round that consumed non-empty
  # findings must leave no marker, whether or not one existed before it
  [ ! -e "$WD/.findings-empty-2" ]
  # now the caller re-passes round 2's exact bytes on the sweep. The waiver must
  # NOT fire: round 2's consumed findings were not empty.
  printf '%s' "$SUGG_ONLY" > "$F"
  step --resume
  [ "$status" -eq 2 ]
  contains "$output" "byte-identical to round 2"
}

@test "#1434 step mode: a missing verify-<N>.json falls back to the previous changelist" {
  # The carry is normally written at the END of round N-1, so the fallback at
  # round N's start only fires for an older work-dir (or a resume into a run
  # that predates that write). Without it, `carried` computes 0 and an
  # empty-delta round that really does carry blockers is refused as
  # STALE_FINDINGS instead of running as a verification-only round.
  seed_awaiting                       # round 1: one blocker
  rm -f "$WD/verify-2.json"           # simulate the legacy work-dir
  printf '[]' > "$F"                  # no fix: round 2's delta is empty
  step --resume
  [ "$status" -eq 20 ]
  # NOT refused — the fallback rebuilt the carry from round 1's changelist
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  [ "$(jq 'length' "$WD/verify-2.json")" -eq 1 ]
  [ "$(jq -r '.[0].title' "$WD/verify-2.json")" = "T" ]
  [ "$(cat "$WD/.closing-sweep")" = "3" ]
}

@test "#1434 step mode: an empty delta with NOTHING carried is refused here too — the arm is wiring-independent" {
  # The empty-delta arm keys on the round's own state, not on --findings-file,
  # so it fires in BOTH wirings. Every other step-mode empty-delta test seeds a
  # round-1 blocker, so `carried > 0` and only the verification-only branch is
  # taken — leaving the arm itself exercised in hook mode alone, in the wiring
  # that is NOT the canonical one.
  printf '[]' > "$F"
  step                                    # round 1 (full) converges on nothing
  [ "$status" -eq 0 ]
  # a fresh, non-identical findings file, and NO tree change: round 2's delta is
  # empty and round 1 left no blockers to verify
  printf '%s' '[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":3,"title":"n","description":"d","reviewer":"r"}]' > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume --max-rounds 3
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | jq -r '.status')" = "STALE_FINDINGS" ]
  contains "$stderr" "delta against the previous round is EMPTY"
  # ...and it is THIS arm, not the byte-identical one, whose remedy differs
  lacks "$stderr" "byte-identical to round"
  # the arm-unique remedy text, so the recovery half cannot be deleted silently
  contains "$stderr" "restore that marker"
  contains "$stderr" "Do NOT invent a code change"
}

@test "#1434 step mode: the byte-identical guard is NOT pre-empted by an empty delta" {
  # The empty-delta handling is structural, never a refusal, precisely so it
  # cannot displace the more specific #974 diagnosis. Round 2 here has an empty
  # delta AND a re-passed findings file; the caller mistake is the one that
  # must be reported.
  seed_awaiting                       # round 1: one blocker, findings = $CRIT
  step --resume                       # re-pass the identical file
  [ "$status" -eq 2 ]
  contains "$output" "byte-identical to round 1"
  # ...and the refusal is EXTENDED by the round's own scope. The stale-path
  # diagnosis stays (it is the likelier cause and the only one a re-invoke can
  # fix), but on an empty delta the loop also knows the tree did not move — so
  # a panel that really did run would legitimately re-find the same things, and
  # a caller told only "run the panel again" would loop on it forever.
  contains "$output" "did this round's review panel run?"
  contains "$output" "delta was also EMPTY"
  contains "$output" "still unfixed"
}

@test "#1434 step mode: a ZERO-BYTE verify-<N>.json is rebuilt, not forwarded as an empty carry" {
  # The fallback tests `! -s`, not `! -e`, because the end-of-round write
  # truncates before jq fills it: a killed run or a full disk leaves a
  # zero-byte carry. Read as "present", `carried` computes 0 and this round is
  # refused with a claim about round 1 the loop never established.
  seed_awaiting                       # round 1: one blocker
  : > "$WD/verify-2.json"             # a FAILED write, not an empty carry
  printf '[]' > "$F"                  # no fix: round 2's delta is empty
  step --resume
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  # rebuilt from round 1's changelist, exactly as the absent case is
  [ "$(jq 'length' "$WD/verify-2.json")" -eq 1 ]
  [ "$(jq -r '.[0].title' "$WD/verify-2.json")" = "T" ]
}

@test "#1434 step mode: a NON-ARRAY fix-verification carry is refused by shape, before anything consumes it" {
  # A corrupt carry is otherwise invisible on an ordinary delta round: only the
  # empty-delta path ever runs `jq length` on it, so a half-written file would
  # reach the panel as though it were a carry.
  seed_awaiting
  printf '{"blocking":' > "$WD/verify-2.json"   # truncated mid-write
  echo "print(2)" > "$R/fixed.py"
  distinct_blocker 2 > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume --max-rounds 3
  [ "$status" -eq 1 ]
  contains "$stderr" "is not a JSON array"
  # ...and "before anything consumes it" is the half the title claims: moving
  # the guard below the dispatch/consume block keeps the exit code and the
  # wording identical while the round has already re-planned, rewritten
  # adjudicated.json and truncated the dispatch sink.
  [ ! -e "$WD/changelist-2.json" ]
  [ ! -e "$R/.review/findings-round-2.json" ]
  [ ! -e "$WD/.findings-digest-2" ]
  contains "$stderr" "round 1 blockers cannot be verified"
  [ -s "$F" ]
}

@test "#1434 step mode: a WELL-FORMED but non-array carry is refused too — the guard is on shape, not parseability" {
  seed_awaiting
  printf '{"a":1}' > "$WD/verify-2.json"        # valid JSON, wrong type
  echo "print(2)" > "$R/fixed.py"
  distinct_blocker 2 > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume --max-rounds 3
  [ "$status" -eq 1 ]
  contains "$stderr" "is not a JSON array"
  # ...and "before anything consumes it" is the half the title claims: moving
  # the guard below the dispatch/consume block keeps the exit code and the
  # wording identical while the round has already re-planned, rewritten
  # adjudicated.json and truncated the dispatch sink.
  [ ! -e "$WD/changelist-2.json" ]
  [ ! -e "$R/.review/findings-round-2.json" ]
  [ ! -e "$WD/.findings-digest-2" ]
  [ -s "$F" ]
}

@test "#1434 step mode: a MULTI-VALUE carry is refused — jq -e alone reports only its last value" {
  # Two concatenated arrays (a `>>` instead of a `>`) make a bare
  # `jq -e 'type == "array"'` print true,true and exit 0.
  seed_awaiting
  printf '[]\n[]\n' > "$WD/verify-2.json"
  echo "print(2)" > "$R/fixed.py"
  distinct_blocker 2 > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume --max-rounds 3
  [ "$status" -eq 1 ]
  contains "$stderr" "is not a JSON array"
  # ...and "before anything consumes it" is the half the title claims: moving
  # the guard below the dispatch/consume block keeps the exit code and the
  # wording identical while the round has already re-planned, rewritten
  # adjudicated.json and truncated the dispatch sink.
  [ ! -e "$WD/changelist-2.json" ]
  [ ! -e "$R/.review/findings-round-2.json" ]
  [ ! -e "$WD/.findings-digest-2" ]
  [ -s "$F" ]
}

@test "#1434 step mode: nothing is adjudicated when the round aborts inside the kill window" {
  # The adjudicated append is deliberately the round's LAST write, after the
  # history line: anything committed between the changelist append and the
  # history line is state the --resume orphan repair lets a re-run inherit, and
  # a round that re-ran would find its OWN suggestions already adjudicated and
  # drop them — unrecoverably on the closing sweep, whose delta is `[]` so the
  # invalidation cannot restore them.
  #
  # The carry write is a real `|| exit 1` inside that window, so a directory at
  # its path aborts the round there. Any placement of the append above the carry
  # write reds this test.
  seed_awaiting
  echo "print(2)" > "$R/fixed.py"
  local SUGG_ONLY='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":9,"title":"rename the temp variable","description":"d","reviewer":"r"}]'
  printf '%s' "$SUGG_ONLY" > "$F"
  mkdir -p "$WD/verify-3.json"
  step --resume
  [ "$status" -eq 1 ]
  contains "$output" "could not write the round 3 fix-verification carry"
  [ "$(jq 'length' "$WD/adjudicated.json")" -eq 0 ]
  # ...and the abort really did land INSIDE the window, rather than before it:
  # changelists is exactly one line ahead of history, which is the skew the
  # --resume orphan repair reads as "round 2 re-runs"
  [ "$(jq -s 'length' "$WD/changelists.jsonl")" -eq 2 ]
  [ "$(jq -s 'length' "$WD/history.jsonl")" -eq 1 ]
}

@test "#1434 step mode: nothing is adjudicated when the round aborts at the CLOSING end of the kill window" {
  # The test above pins the append below the CARRY write, which is one statement
  # past the window's START. The contract is stronger: the append is the round's
  # LAST write, below the HISTORY line. Without this sibling the whole block
  # could be moved to just above the history append — squarely inside the
  # window — and the suite would stay green.
  seed_awaiting
  echo "print(2)" > "$R/fixed.py"
  local SUGG_ONLY='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":9,"title":"rename the temp variable","description":"d","reviewer":"r"}]'
  printf '%s' "$SUGG_ONLY" > "$F"
  chmod 444 "$WD/history.jsonl"      # the append at the window's closing edge fails
  # tests/Dockerfile runs the suite as root, where `chmod 444` is no barrier at
  # all: root appends to a read-only file regardless, the round completes, and
  # the failure path this test exists for never executes (#1360). The EFFECT
  # test rather than a uid test, for the same reasons the sibling gives.
  if [ -w "$WD/history.jsonl" ]; then skip "running as a user that bypasses file permissions"; fi
  step --resume
  [ "$status" -eq 1 ]
  contains "$output" "could not append the round 2 history line"
  [ "$(jq 'length' "$WD/adjudicated.json")" -eq 0 ]
  [ "$(jq -s 'length' "$WD/changelists.jsonl")" -eq 2 ]
  [ "$(jq -s 'length' "$WD/history.jsonl")" -eq 1 ]
}

@test "#1434 step mode: a round that COMPLETES does adjudicate its suggestions — the control for the two aborts above" {
  # Without this, both abort tests are satisfied by a loop that never adjudicates
  # anything at all.
  seed_awaiting
  echo "print(2)" > "$R/fixed.py"
  local SUGG_ONLY='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":9,"title":"rename the temp variable","description":"d","reviewer":"r"}]'
  printf '%s' "$SUGG_ONLY" > "$F"
  step --resume
  [ "$status" -eq 20 ]
  [ "$(jq 'length' "$WD/adjudicated.json")" -eq 1 ]
  [ "$(jq -r '.[0].title' "$WD/adjudicated.json")" = "rename the temp variable" ]
  [ "$(jq -s 'length' "$WD/history.jsonl")" -eq 2 ]
}

@test "#1434 step mode: a .closing-sweep marker just TWO rounds out is refused — the boundary, not just the far case" {
  # The far-out control (99) leaves the boundary free to move: `> max_rounds + 2`
  # would still refuse 99 and still adopt 4, while a resume passing a smaller
  # --max-rounds than the run that wrote the marker adopts a sweep two rounds
  # out and stamps a grant that was never contracted.
  seed_awaiting
  printf '5\n' > "$WD/.closing-sweep"
  echo "print(2)" > "$R/fixed.py"
  distinct_blocker 2 > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume --max-rounds 3
  [ "$status" -eq 20 ]
  contains "$stderr" "beyond the one-round grant"
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "false" ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 3 ]
}

@test "#1434 step mode: a failed adjudicated append WARNS and the round still stands" {
  # The append is deliberately non-fatal. An `exit 1` there would land between
  # the round's history line and the closing-sweep record, on an ordinary I/O
  # failure rather than a kill: the round would be complete and consistent on
  # disk with the sweep it just earned never written, and every later --resume
  # would plan a delta round against an unmoved tree and refuse it forever.
  #
  # A DIRECTORY at the temp path, so the redirection fails whatever the uid.
  seed_awaiting
  echo "print(2)" > "$R/fixed.py"
  mkdir -p "$WD/.adjudicated-appended.json"
  local SUGG_ONLY='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":9,"title":"rename the temp variable","description":"d","reviewer":"r"}]'
  printf '%s' "$SUGG_ONLY" > "$F"
  # --separate-stderr, not the `step` helper: the warning must land on STDERR,
  # and stdout must stay exactly the one-line status JSON. Merged streams would
  # pass either way, and a consumer piping this round's stdout to jq would then
  # get a parse error on a round the loop says survived.
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume
  [ "$status" -eq 20 ]
  contains "$stderr" "could not record round 2's suggestions as adjudicated"
  contains "$stderr" "the round STANDS"
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]
  # nothing was recorded...
  [ "$(jq 'length' "$WD/adjudicated.json")" -eq 0 ]
  # ...and these are the assertions that fail under a reverted `exit 1`: the
  # round completed, and the sweep it earned is on disk
  [ "$(cat "$WD/.closing-sweep")" = "3" ]
  [ "$(jq -s 'length' "$WD/history.jsonl")" -eq 2 ]
}

@test "#1434 step mode: a well-formed .closing-sweep marker BEYOND the one-round grant is refused" {
  # The format check is not enough: the grant is contracted as ONE round beyond
  # --max-rounds, so a foreign or corrupted marker holding a plausible number
  # would otherwise raise the ceiling by as many rounds as it names, with no
  # diagnostic and BUDGET_EXHAUSTED unreachable.
  seed_awaiting
  printf '99\n' > "$WD/.closing-sweep"
  echo "print(2)" > "$R/fixed.py"
  distinct_blocker 2 > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume --max-rounds 3
  [ "$status" -eq 20 ]
  contains "$stderr" "beyond the one-round grant"
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "false" ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 3 ]
}

@test "#1434 step mode: a marker exactly ONE round beyond the ceiling IS adopted" {
  # the positive control for the clamp: max_rounds + 1 is the contracted grant,
  # so pinning only the refusal would leave the boundary free to move
  seed_awaiting
  printf '4\n' > "$WD/.closing-sweep"
  echo "print(2)" > "$R/fixed.py"
  distinct_blocker 2 > "$F"
  step --resume --max-rounds 3
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "true" ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 3 ]
}

@test "#1434 step mode: a DAMAGED adjudicated.json is re-initialised on resume, never fatal" {
  # It is persistent state, so a truncated file would abort the invalidation jq
  # as a bare exit 1 that writes no status JSON — and every later --resume would
  # die at the same point with the work-dir bricked. Re-initialising costs at
  # most one already-waived suggestion logged again.
  # EIGHT shapes, one per way the predicate can fail. Three container arms:
  # unparseable, a well-formed NON-array, a multi-value file (a `>>` instead of
  # a `>`). Five element arms: an element that is not an object, one missing
  # `dimension`, and then one ISOLATING each field conjunct — an empty `file`,
  # an empty `dimension`, a non-string `title`. The isolating three matter
  # because the over-determined shapes leave each conjunct individually
  # deletable: with only `[{"file":"a.py"}]` in the list, dropping the `title`
  # conjunct stays green (dimension still refuses it) while
  # `[{...,"title":42}]` starts being adopted — and an adopted bad entry is
  # forwarded to the consolidator, which refuses it as the loop's BARE exit 1
  # that writes no status JSON. Since this file is PERSISTENT state, every
  # later --resume then dies at the same point with the work-dir bricked.
  local bad i=0
  for bad in '{"blocking":' '{"a":1}' '[]
[]' '[{"file":"a.py"}]' '["foo"]' \
             '[{"file":"","dimension":"code_quality","title":"t"}]' \
             '[{"file":"a.py","dimension":"","title":"t"}]' \
             '[{"file":"a.py","dimension":"code_quality","title":42}]'; do
    i=$(( i + 1 ))
    seed_awaiting
    printf '%s' "$bad" > "$WD/adjudicated.json"
    # a DISTINCT path per iteration: git-tree-id is content-based, so rewriting
    # the same bytes moves nothing and every iteration after the first would
    # take the empty-delta verification path instead of the ordinary delta path
    # the first one establishes
    echo "print($i)" > "$R/fixed-$i.py"
    distinct_blocker 2 > "$F"
    run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
      zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume --max-rounds 3
    [ "shape $bad: $status" = "shape $bad: 20" ]
    contains "shape $bad: $stderr" "re-initialising to []"
    # ...and the round really ran on a usable list
    [ "shape $bad: $(jq 'type' "$WD/adjudicated.json")" = "shape $bad: \"array\"" ]
    [ "shape $bad: $([ -s "$WD/changelist-2.json" ] && echo yes)" = "shape $bad: yes" ]
    rm -rf "$WD"; mkdir -p "$WD"
  done

  # the positive control: without it the whole loop is satisfied by a guard
  # that re-initialises unconditionally
  seed_awaiting
  printf '%s' '[{"file":"app.py","dimension":"code_quality","title":"keep me"}]' > "$WD/adjudicated.json"
  echo "print(99)" > "$R/fixed-keep.py"
  distinct_blocker 2 > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume --max-rounds 3
  [ "$status" -eq 20 ]
  lacks "$stderr" "re-initialising to []"
  [ "$(jq -r 'map(select(.title == "keep me")) | length' "$WD/adjudicated.json")" -eq 1 ]
}

@test "#1434 step mode: an unreadable .closing-sweep marker is ignored, never a silent grant" {
  seed_awaiting
  printf 'not-a-number\n' > "$WD/.closing-sweep"
  echo "print(2)" > "$R/fixed.py"
  distinct_blocker 2 > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume --max-rounds 3
  [ "$status" -eq 20 ]
  contains "$stderr" "ignoring an unreadable closing-sweep marker"
  # no grant was minted from garbage, and the passed ceiling still governs
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "false" ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 3 ]
}

@test "#1434 step mode: an OVER-WIDE closing-sweep marker is ignored too, never adopted as a ceiling" {
  # The guard is two-part (`<->` AND an 18-digit cap); the non-numeric case
  # above exercises only the first conjunct. A 19-digit marker is all digits, so
  # dropping the width half would let it become `effective_max` and the run
  # would blow past the ceiling the caller passed — the same corrupt-sidecar
  # class the loop already guards for `--issue`, `--max-rounds` and `.t0`.
  seed_awaiting
  printf '9999999999999999999\n' > "$WD/.closing-sweep"
  echo "print(3)" > "$R/fixed-wide.py"
  distinct_blocker 2 > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume --max-rounds 3
  [ "$status" -eq 20 ]
  contains "$stderr" "ignoring an unreadable closing-sweep marker"
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "false" ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 3 ]
}

@test "#1434 step mode: --resume adopts the iteration state a prior invocation left" {
  seed_awaiting
  # everything the next round needs is on disk, written by the invocation that
  # has already exited — that IS the step-mode contract
  [ -s "$WD/tree-1.txt" ]
  [ -s "$WD/adjudicated.json" ]
  local t1; t1="$(cat "$WD/tree-1.txt")"

  echo "print(2)" > "$R/fixed.py"
  distinct_blocker 2 > "$F"
  step --resume
  [ "$status" -eq 20 ]
  # round 1's identity was adopted (not recomputed and not truncated), and this
  # round wrote its own
  [ "$(cat "$WD/tree-1.txt")" = "$t1" ]
  [ -s "$WD/tree-2.txt" ]
  [ -s "$WD/verify-2.json" ]
  [ "$(jq 'length' "$WD/verify-2.json")" -eq 1 ]
}
