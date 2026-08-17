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

@test "a missing findings file is treated as no findings (CONVERGED)" {
  rm -f "$F"
  step
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
}

@test "a findings file that is not a JSON array is an internal error (exit 1)" {
  printf 'not json' > "$F"
  step
  [ "$status" -eq 1 ]
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

  # and it converges inside the granted rounds
  printf '[]' > "$F"
  step --resume --max-rounds 8
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 7 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 7 ]
}

@test "a surviving conflict exits ESCALATE_CONFLICT (11) in step mode too" {
  printf '%s' '[{"severity":"WARNING","dimension":"performance","file":"app.py","line":1,"title":"c","description":"d","reviewer":"p"},{"severity":"WARNING","dimension":"code_quality","file":"app.py","line":1,"title":"e","description":"d","reviewer":"q"}]' > "$F"
  step
  [ "$status" -eq 11 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_CONFLICT" ]
}

@test "resume with clean findings converges at round 2; accumulators span invocations" {
  seed_awaiting
  printf '[]' > "$F"
  step --resume
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 2 ]
  [ "$(echo "$output" | jq '.round_changelists | length')" -eq 2 ]
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
  run ! grep -q '^## Round 2' "$WD/progress.md"
  run ! grep -q '^\*\*Final:' "$WD/progress.md"
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

@test "a failed consume records no digest, so the retry with the same bytes is accepted" {
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
  contains "$output" "could not copy"
  [ ! -e "$WD/.findings-digest-2" ]
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
  printf '[]' > "$F"
  step --resume --test-cmd 'true'
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
  printf '[]' > "$F"
  # --test-cmd 'false' would ERROR (1) if it RAN; the exact-match skip lets
  # round 2 converge instead — proving the duplicate run was suppressed.
  step --resume --test-cmd 'false' --gate-attest "$attest"
  [ "$status" -eq 0 ]
  # the skip emits a diagnostic to stderr, so pull the JSON line off the combined output
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
  # pin that the SKIP (not a generic converge) is what fired
  contains "$output" "skipping the duplicate --test-cmd run"
  grep -q 'attested green' "$WD/progress.md"
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
  run grep -q 'attested green' "$WD/progress.md"
  [ "$status" -ne 0 ]
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

@test "gate-attest: a matching attestation still aborts if a red gate would have — it just isn't run; the round proceeds (#981)" {
  seed_awaiting
  local attest; attest="$(TID)"
  printf '[]' > "$F"
  # matching attestation + a GREEN gate: converges either way, proving the skip
  # path leaves the happy case intact.
  step --resume --test-cmd 'true' --gate-attest "$attest"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
}

@test "progress.md gets a per-round block with severity split, new/carried, fixed-since and trend (step mode, #969)" {
  seed_awaiting
  grep -q '^## Round 1 — blockers remain' "$WD/progress.md"
  grep -q -- '- blockers: 1 (critical: 1, warning: 0) (new: 1, carried: 0), conflicts: 0, suggestions: 0' "$WD/progress.md"
  grep -q -- '- by dimension: bugs 1' "$WD/progress.md"
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

@test "AWAITING_FIX writes its round block but NO Final line (non-terminal)" {
  seed_awaiting
  run ! grep -q '^\*\*Final:' "$WD/progress.md"
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
  printf '[]' > "$F"
  step --resume --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$T")" -eq 1 ]
}

@test "terminal telemetry reports whole-loop wall clock from .t0, not the last round's" {
  T="$BATS_TEST_TMPDIR/telemetry-wall.jsonl"
  seed_awaiting
  # back-date the loop's logical start by 100s; the terminal record must span it
  echo "$(( $(date +%s) - 100 ))" > "$WD/.t0"
  printf '[]' > "$F"
  step --resume --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.wall_s >= 100' "$T")" = "true" ]
}

@test "an empty (zero-byte) findings file is treated as no findings (CONVERGED)" {
  : > "$F"
  step
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
}

@test "step mode drops findings on the work-dir's own files (#909/#911 parity)" {
  WDIN="$R/.loop-wd"
  printf '%s' "$CRIT" > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDIN" --findings-file "$F"
  [ "$status" -eq 20 ]
  printf '%s' '[{"severity":"CRITICAL","dimension":"bugs","file":".loop-wd/progress.md","line":1,"title":"phantom","description":"d","reviewer":"r"}]' > "$F"
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
  printf '[]' > "$F"
  step --resume --telemetry-file "$T"
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
  printf '[]' > "$F"
  local NOW; NOW="$(date +%s)"
  step --resume --telemetry-file "$T"
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
  printf '[]' > "$F"
  local NOW; NOW="$(date +%s)"
  step --resume --telemetry-file "$T"
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
  # P2 matches nothing, so the suggestion stays Low and the loop converges
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

  # the fix landed: the panel no longer raises it
  printf '[]' > "$F"
  step --resume --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.blocking')" -eq 0 ]
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
