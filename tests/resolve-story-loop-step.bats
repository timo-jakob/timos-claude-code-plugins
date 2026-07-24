#!/usr/bin/env bats
#
# Behavioral tests for resolve-story-loop.zsh STEP MODE (#971): one invocation
# per round, findings supplied via --findings-file, fixes applied in-session
# between invocations (so the loop exits AWAITING_FIX instead of running a fix
# hook). Detection is stubbed via DETECT_STACK_BIN; git runs for real.

bats_require_minimum_version 1.5.0

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
  [[ "$output" == *"byte-identical to round 1"* ]]
  [[ "$output" == *"did this round's review panel run?"* ]]
}

@test "the guard is content-based: a fresh per-round path holding the previous round's bytes also exits 2" {
  seed_awaiting
  F2="$BATS_TEST_TMPDIR/findings-round-2.json"
  cp "$F" "$F2"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F2" --resume
  [ "$status" -eq 2 ]
  [[ "$output" == *"$F2"* ]]
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
  [[ "$stderr" == *"did this round's review panel run?"* ]]
  # no stale verdict survives: the status file names THIS invocation's refusal
  [ "$(jq -r '.status' "$ST")" = "STALE_FINDINGS" ]
  [ "$(jq -r '.rounds' "$ST")" -eq 1 ]
  # the carried accumulators are real prior state, not empty stubs
  [ "$(jq '.history | length' "$ST")" -eq 1 ]
  [ "$(jq '.round_changelists | length' "$ST")" -eq 1 ]
  [ "$(jq '.final_changelist.round' "$ST")" -eq 1 ]
  # ...but it is NOT terminal: no telemetry record, no round block, no Final line
  [ ! -e "$T" ]
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
  [[ "$stderr" == *"must not be the round's own findings_path"* ]]
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
  [[ "$output" == *"missing or empty on --resume"* ]]
  [[ "$output" == *"must still write []"* ]]
}

@test "a zero-byte findings file on --resume is refused (2) too" {
  seed_awaiting
  : > "$F"
  step --resume
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing or empty on --resume"* ]]
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
  [[ "$output" == *"byte-identical to round 2"* ]]
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
  printf '%s' "$CRIT2" > "$F"
  step --resume
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not copy"* ]]
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
  [[ "$output" == *"RESOLVE_LOOP_DIGEST_TOOL=sha256 not usable"* ]]
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

@test "progress.md gets a per-round block with the new/carried split (step mode)" {
  seed_awaiting
  grep -q '^## Round 1 — blockers remain' "$WD/progress.md"
  grep -q -- '- blockers: 1 (new: 1, carried: 0), conflicts: 0, suggestions: 0' "$WD/progress.md"
  grep -q -- '- by dimension: bugs 1' "$WD/progress.md"
  printf '%s' "$CRIT2" > "$F"
  step --resume
  [ "$status" -eq 12 ]
  grep -q '^## Round 2 — blockers remain' "$WD/progress.md"
  grep -q -- 'new: 0, carried: 1' "$WD/progress.md"
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
  [ ! -s "$T" ]
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
