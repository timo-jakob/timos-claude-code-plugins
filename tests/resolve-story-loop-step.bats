#!/usr/bin/env bats
#
# Behavioral tests for resolve-story-loop.zsh in STEP mode (#971): one
# invocation per round, findings supplied via --findings-file, fixes applied
# in-session between invocations (so the loop exits AWAITING_FIX instead of
# running a fix hook). Its terminals, usage errors, the stale-findings guard
# (#974), --test-cmd, progress.md (#969), delta scoping and the closing full
# sweep (#1434), the retired --promote (#3134, #3168, #3169), and the tree
# identities checked against git-tree-id.zsh: the gate attestation (#981) and the
# cadence guard (#1435 §10).
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

@test "#1485 a written [] on a FULL round over an EMPTY story diff is REFUSED, never converged" {
  # The half #1434 left open: the aggregate exists and is `[]`, so the
  # missing-file arm above does not fire, and zero blockers on a full round is
  # the CONVERGED condition. Only the round's empty scope says nobody saw
  # anything.
  rm -f "$R/app.py"                  # the story diff is now empty
  printf '[]' > "$F"
  step
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  contains "$output" "round 1 is a FULL round over an EMPTY story diff"
  contains "$output" "go back to §2 (Implement)"
  # ...and its second remedy, for a story that needs no code change
  contains "$output" "say so and stop"
  contains "$output" "never invent a change"
  # distinguishable from the missing-file arm, which routes to a different recovery
  lacks "$output" "is a FULL round and --findings-file is missing or empty"
  # refused before any accumulator write
  [ ! -s "$WD/history.jsonl" ]
  [ ! -s "$WD/changelists.jsonl" ]
  # ...but AFTER the digest step: this is the one fixture that produces a BLIND
  # round (scope empty AND findings `[]`), so it pins the `round_scope_empty &&
  # round_findings_empty` branch that records no digest for it (#1491). Without
  # that branch the round writes a digest of `[]` before the refusal fires.
  [ ! -e "$WD/.findings-digest-1" ]
}

@test "#1485 a story whose only changes are the repo-internal --work-dir is REFUSED, never converged" {
  rm -f "$R/app.py"
  printf '[]' > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$R/.loop-wd" --findings-file "$F"
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  contains "$output" "FULL round over an EMPTY story diff"
  # the repo really does show the work-dir as changed — so it is the FILTER that
  # emptied the scope, not an already-empty diff (the test above)
  git -C "$R" status --porcelain --untracked-files=all | grep -q '^?? \.loop-wd/'
}

@test "#1485 a story whose only change is its own repo-internal --findings-file is REFUSED, never converged" {
  # The loop-state-FILE shape, as distinct from the work-dir prefix: the exact
  # list (_drop_loop_internal_paths) must empty the scope too. A work-dir-prefix
  # filter alone would leave findings-round-1.json in scope and converge on it.
  rm -f "$R/app.py"
  local IF="$R/findings-round-1.json"
  printf '[]' > "$IF"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$IF"
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  contains "$output" "FULL round over an EMPTY story diff"
  git -C "$R" status --porcelain --untracked-files=all | grep -qx '?? findings-round-1.json'
}

@test "#1485 a MISSING findings file on a FULL round over an EMPTY story diff names the empty diff, not 'write []'" {
  # the step-mode twin of the hook-mode contract test: a panel that honoured
  # "empty scope on a full round: write no findings file" gets the real remedy
  rm -f "$R/app.py" "$F"
  step
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  contains "$output" "round 1 is a FULL round over an EMPTY story diff"
  # the SAME wording as the post-consolidation site: one helper, one remedy
  contains "$output" "say so and stop"
  contains "$output" "never invent a change"
  lacks "$output" "is a FULL round and --findings-file is missing or empty"
}

@test "#1485 a RESUMED full round over an emptied story diff with no findings file names the empty diff, not 'write []'" {
  # The --resume missing-file arm fires before the full-round one, so it needs
  # the same guard. Reach a resumed FULL round with an empty scope: round 1
  # blocks on app.py, the in-session fix REVERTS the story (deletes app.py),
  # round 2 (delta: the deletion) confirms the carry clean and promotes the
  # closing sweep, and round 3 IS that sweep — over a story diff that is now
  # empty. A contract-following panel writes nothing there.
  seed_awaiting
  rm -f "$R/app.py"
  printf '[]' > "$WD/findings-round-2.json"
  step --resume --findings-file "$WD/findings-round-2.json"
  [ "$status" -eq 20 ]
  [ "$(cat "$WD/.closing-sweep")" = "3" ]
  step --resume --findings-file "$WD/findings-round-3.json"
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  contains "$output" "round 3 is a FULL round over an EMPTY story diff"
  contains "$output" "say so and stop"
  lacks "$output" "must still write []"
  lacks "$output" "is missing or empty on --resume"
}

@test "#1485 a written [] on a FULL round with a NON-empty story diff still converges" {
  # the regression guard: the refusal keys on the empty scope, never on `[]` alone
  printf '[]' > "$F"
  step
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq -r '.rounds')" = "1" ]
  lacks "$output" "EMPTY story diff"
}

@test "#1434 a missing findings file on a DELTA round is refused by the --resume arm, not the FULL-round arm" {
  # The two refusal arms must stay distinguishable: they name different causes
  # and route to different recovery arms in §3.5 step 2. In STEP mode the `[]`
  # delta default is in fact unreachable — round 1 is always full, and every
  # later round arrives via --resume, where the #974 missing-on-resume arm
  # fires first — so the surviving default is pinned in HOOK mode instead, by
  # "a DELTA round whose panel writes NO findings" in tests/resolve-story-loop-panel.bats.
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
  [ ! -e "$DEFAULT_SINK" ]
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

# --- --promote is retired (#3134) ---------------------------------------------

@test "#3134 step mode: --promote is an unknown option, refused before any round work" {
  P="$BATS_TEST_TMPDIR/promote.json"
  printf '%s' '[{"file":"app.py","line":1,"dimension":"code_quality","title":"extract the magic number"}]' > "$P"
  printf '%s' '[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"extract the magic number","description":"follow-up: d","reviewer":"q"}]' > "$F"
  step --promote "$P"
  [ "$status" -eq 2 ]
  [ "$output" = "unknown flag: --promote" ]
  # nothing was set up: no round state and no persisted promoted set
  [ ! -e "$WD/history.jsonl" ]
  [ ! -e "$WD/.promote" ]
}

@test "#3134 step mode: a suggestion-only round converges, and a stale .promote in the work-dir is ignored" {
  # a work-dir an older loop left a promoted set in: the loop no longer reads it,
  # so the waived suggestion stays waived and round 1 converges
  mkdir -p "$WD"
  P="$BATS_TEST_TMPDIR/promote.json"
  printf '%s' '[{"file":"app.py","line":1,"dimension":"code_quality","title":"extract the magic number"}]' > "$P"
  printf '%s\n' "$P" > "$WD/.promote"
  printf '%s' '[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"extract the magic number","description":"follow-up: d","reviewer":"q"}]' > "$F"
  step
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.round_changelists[0].summary.blocking')" -eq 0 ]
  echo "$output" | jq -e 'has("promotion_phase") | not' >/dev/null
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

@test "#2909 step mode: the loop keeps the fallback marker the panel brief wrote" {
  # in step mode round 1's panel runs, and writes the marker, BEFORE the
  # loop's first (fresh) invocation; neither that nor a --resume clears it
  mkdir -p "$WD"
  echo 1 > "$WD/.fallback-engaged"
  printf '%s' "$CRIT" > "$F"
  step
  [ "$status" -eq 20 ]
  [ "$(cat "$WD/.fallback-engaged")" = "1" ]
  echo "print(2)" > "$R/fixed.py"
  printf '[]' > "$F"
  step --resume
  [ "$status" -eq 20 ]
  [ "$(cat "$WD/.fallback-engaged")" = "1" ]
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
  local SUGG_ONLY='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":9,"title":"rename the temp variable","description":"follow-up: d","reviewer":"r"}]'
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
  local SUGG_ONLY='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":9,"title":"rename the temp variable","description":"follow-up: d","reviewer":"r"}]'
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
  # the wrapper derives its confirm-all accounting FROM verify-2.json, which
  # this test removed — so the accounting for the rebuilt carry is explicit
  step --resume --carry-accounting "$(carry_record '["r"]' '[]' '[]')"
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
  printf '%s' '[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":3,"title":"n","description":"follow-up: d","reviewer":"r"}]' > "$F"
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

@test "#1491 step mode: a failed scope write on the empty-delta --final re-plan aborts the round" {
  # Both write_round_scope calls write the same scope.txt, and the re-plan's
  # descriptor comes from the real review-dispatch.zsh, so no fixture can break
  # the SECOND write without breaking the first. The RESOLVE_LOOP_DISPATCH_BIN
  # seam can: this stub delegates every invocation to the real dispatch, and on
  # the one carrying --final alone replaces scope.txt with a directory, so the
  # re-derived scope cannot be written. Its descriptor stays valid JSON, so the
  # `could not read scope_mode after the re-plan` guard just before passes.
  local real="$REPO_ROOT/development/skills/resolve-issue/scripts/review-dispatch.zsh"
  local stub="$BATS_TEST_TMPDIR/dispatch-breaks-final-scope.sh"
  cat > "$stub" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = --final ]; then rm -f "$WD/scope.txt" && mkdir "$WD/scope.txt"; fi
done
exec "$real" "\$@"
EOF
  chmod +x "$stub"
  export RESOLVE_LOOP_DISPATCH_BIN="$stub"
  seed_awaiting                       # round 1 (through the stub): one blocker
  [ "$(grep -c '' "$WD/history.jsonl")" -eq 1 ]
  [ "$(grep -c '' "$WD/changelists.jsonl")" -eq 1 ]
  printf '[]' > "$F"                  # no fix: round 2's delta is empty, carry is not
  step --resume
  [ "$status" -eq 1 ]
  contains "$output" "could not extract scope at round 2"
  # the stub really did reach the re-plan — not some earlier abort
  [ -d "$WD/scope.txt" ]
  # the aborted round added nothing to either accumulator
  [ "$(grep -c '' "$WD/history.jsonl")" -eq 1 ]
  [ "$(grep -c '' "$WD/changelists.jsonl")" -eq 1 ]
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
  # explicit accounting for the same reason as the missing-carry test above:
  # the wrapper cannot derive it from a zero-byte carry
  step --resume --carry-accounting "$(carry_record '["r"]' '[]' '[]')"
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
  # wording identical while the round has already re-planned and truncated
  # the dispatch sink.
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
  # wording identical while the round has already re-planned and truncated
  # the dispatch sink.
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
  # wording identical while the round has already re-planned and truncated
  # the dispatch sink.
  [ ! -e "$WD/changelist-2.json" ]
  [ ! -e "$R/.review/findings-round-2.json" ]
  [ ! -e "$WD/.findings-digest-2" ]
  [ -s "$F" ]
}

@test "#3169 step mode: a round builds no adjudicated.json, and its history line has no drop count" {
  seed_awaiting
  echo "print(2)" > "$R/fixed.py"
  local SUGG_ONLY='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":9,"title":"rename the temp variable","description":"follow-up: rename the temp variable","reviewer":"r"}]'
  printf '%s' "$SUGG_ONLY" > "$F"
  step --resume
  [ "$status" -eq 20 ]
  # non-vacuity: round 2 completed and logged its lane suggestion
  [ "$(jq -s 'length' "$WD/history.jsonl")" -eq 2 ]
  [ "$(jq '.summary.low' "$WD/changelist-2.json")" -eq 1 ]
  [ ! -e "$WD/adjudicated.json" ]
  jq -es 'all(.[]; has("adjudicated_dropped") | not)' "$WD/history.jsonl" >/dev/null
  jq -e '.summary | has("adjudicated_dropped") | not' "$WD/changelist-2.json" >/dev/null
}

@test "#3169 step mode: a leftover adjudicated.json is ignored on --resume, never read, re-initialised or deleted" {
  # An older run's work-dir may still hold the list. A damaged one is no longer
  # re-initialised, and a well-formed one naming this round's suggestion
  # suppresses nothing: the file is simply not the loop's any more.
  local leftover i=0
  for leftover in '{"blocking":' \
                  '[{"file":"app.py","line":9,"dimension":"code_quality","title":"rename the temp variable"}]'; do
    i=$(( i + 1 ))
    seed_awaiting
    printf '%s' "$leftover" > "$WD/adjudicated.json"
    cp "$WD/adjudicated.json" "$BATS_TEST_TMPDIR/leftover-$i.json"
    echo "print($i)" > "$R/fixed-$i.py"
    printf '%s' '[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":9,"title":"rename the temp variable","description":"follow-up: rename the temp variable","reviewer":"r"}]' > "$F"
    run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
      zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume --max-rounds 3
    [ "leftover $i: $status" = "leftover $i: 20" ]
    lacks "$stderr" "re-initialising"
    lacks "$stderr" "adjudicated"
    cmp "$BATS_TEST_TMPDIR/leftover-$i.json" "$WD/adjudicated.json"
    [ "leftover $i: $(jq '.summary.low' "$WD/changelist-2.json")" = "leftover $i: 1" ]
    rm -rf "$WD"; mkdir -p "$WD"
  done
}

@test "#3168 step mode: the loop never hands the waived list to the plan, on round 1 or round 2" {
  # The stub logs every dispatch invocation's arguments, one per line, then
  # delegates to the real review-dispatch.zsh. Round 2 is a carried delta round,
  # where --adjudicated used to ride beside --fix-verification.
  local real="$REPO_ROOT/development/skills/resolve-issue/scripts/review-dispatch.zsh"
  local stub="$BATS_TEST_TMPDIR/dispatch-logs-args.sh" log="$BATS_TEST_TMPDIR/dispatch-args.log"
  cat > "$stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exec "$real" "\$@"
EOF
  chmod +x "$stub"
  export RESOLVE_LOOP_DISPATCH_BIN="$stub"
  seed_awaiting                       # round 1 (through the stub): one blocker
  echo "print(2)" > "$R/fixed.py"
  printf '[]' > "$F"
  step --resume
  [ "$status" -eq 20 ]
  # non-vacuity: both rounds' plans went through the stub, round 2's carrying
  # the fix-verification carry
  grep -q -- '^plan .*--round 1' "$log"
  grep -q -- '^plan .*--round 2 .*--fix-verification ' "$log"
  run -1 grep -qF -- '--adjudicated' "$log"
  # ...and since #3169 there is no list for anyone
  [ ! -e "$WD/adjudicated.json" ]
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

# --- #1435 §10: the cadence guard -------------------------------------------
# A round's findings are only true about the tree its panel read. Step mode is
# the wiring where that can go wrong, because the panel runs BETWEEN
# invocations: a session that fixes first hands the loop findings describing a
# tree that no longer exists, and the loop — which cannot see a fix pass it did
# not invoke — would attribute every one of those blockers to it. The arithmetic
# stays internally consistent while every input is false, which is the one
# mistake a terminal that opens a PR without human review must not make.
# (NB: no stray apostrophes in these comments — the inert-assertion scanner
# tracks quote parity across lines and an odd one desyncs the whole scan.)

# the identity the session attests its panel ran against
_tree_now() { zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/git-tree-id.zsh" "$R"; }

@test "#1435 AC21 step mode: findings produced against a stale tree are REFUSED, naming both" {
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 3
  [ "$status" -eq 20 ]

  # the WRONG cadence: apply round 1 fix, run round 2 panel (attesting the tree
  # it read), and THEN fix again before consolidating
  echo "v1" > "$R/touched.py"
  local T1; T1="$(_tree_now)"
  residue_findings 2 touched.py > "$F"
  echo "v1-extra" > "$R/touched.py"
  local T2; T2="$(_tree_now)"
  [ "$T1" != "$T2" ]

  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" \
    --resume --max-rounds 3 --findings-tree "$T1"
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | jq -r '.status')" = "STALE_FINDINGS" ]
  # BOTH identities are named, so the operator can tell which tree is which.
  # T1 is asserted by value — it is the attestation the session passed. The
  # second is asserted by SHAPE, not by the $T2 computed above: the loop mints
  # its own at consolidation time, by which point it has written this round
  # dispatch sink, so the two are not required to be equal and pinning them
  # would test the fixture rather than the guard.
  echo "$stderr" | grep -qF "$T1"
  echo "$stderr" | grep -qE 'but the working tree is now [0-9a-f]{40}'
  # ...and the file that moved is named too, so the diagnosis is actionable
  echo "$stderr" | grep -q 'touched.py'
  # The early guard derives its OWN round (`round` is not in scope that early),
  # and that value drives both the progress line and the completed-round count.
  # Deriving it one lower left the suite green while the refusal named round 1
  # and reported zero completed rounds for a run with one in history — the exact
  # contract the sibling byte-identical arm pins explicitly.
  echo "$stderr" | grep -q "round 2's findings were produced against tree"
  [ "$(echo "$output" | jq -r '.rounds')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.status')" != "CONVERGED_WITH_RESIDUE" ]
  # no fix-touched set was written from a false input
  [ ! -e "$WD/fix-touched-1.txt" ]
  grep -q '^\*\*Refused (round 2):\*\* stale findings' "$WD/progress.md"
  # ...and they really are different identities, which is the whole claim.
  # LAST, because `run` reassigns BOTH $output and $stderr — every assertion
  # that reads either has to come first.
  run ! grep -qE "but the working tree is now $T1" <<< "$stderr"
}

@test "#1435 AC21 the RIGHT cadence proceeds, with and without --gate-attest" {
  # Non-vacuity for the refusal above: the identical fixture, with the panel run
  # AFTER the fix, is not refused. Without this the guard could be refusing
  # everything and the test above would still pass.
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 3
  [ "$status" -eq 20 ]

  echo "v1" > "$R/touched.py"
  local T1; T1="$(_tree_now)"
  residue_findings 2 touched.py > "$F"
  step --resume --max-rounds 3 --findings-tree "$T1"
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
}

@test "#1435 AC21 --gate-attest neither causes nor suppresses the cadence refusal" {
  # The two answer different questions — "may I skip the duplicate test run" vs
  # "were these findings produced here" — so one must never stand in for the
  # other. A matching --gate-attest on a stale-cadence round is still refused.
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 3
  [ "$status" -eq 20 ]

  echo "v1" > "$R/touched.py"
  local T1; T1="$(_tree_now)"
  residue_findings 2 touched.py > "$F"
  echo "v1-extra" > "$R/touched.py"
  local T2; T2="$(_tree_now)"

  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" \
    --resume --max-rounds 3 --findings-tree "$T1" --gate-attest "$T2" --test-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | jq -r '.status')" = "STALE_FINDINGS" ]
}

@test "#1435 AC21 a run passing NO attestation is not refused — the guard fails quiet" {
  # The guard detects a cadence MISTAKE; it is not a mandate. A session that
  # attests nothing (an older driver, a hand-run round) loses the detection, not
  # the run — the same fail-quiet rule every other missing-state path here takes.
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 3
  [ "$status" -eq 20 ]

  echo "v1" > "$R/touched.py"
  residue_findings 2 touched.py > "$F"
  echo "v1-extra" > "$R/touched.py"
  step --resume --max-rounds 3
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
}


@test "#1435 a repo-internal --status-file is excluded too, and its .bak sibling is NOT" {
  # Two findings in one fixture, because they share a setup and each kills a
  # different mutation.
  #
  # (a) --status-file is the FIRST name in the exclusion list and had no test at
  #     all: every --status-file in this suite points outside the repo, so
  #     dropping it from the loop left the whole suite green while an in-repo
  #     status file — written by emit_and_exit AFTER the fix-base stamp — came
  #     back in the resume diff as a file the session fix pass supposedly touched.
  #
  # (b) The list is matched EXACTLY, not by prefix, and the script says why:
  #     `--status-file "$repo/loop.json"` must not also swallow `loop.json.bak`.
  #     Turning the exact match into a prefix match passed every earlier fixture,
  #     because none of them had a prefix-sibling in the diff. This one does, and
  #     asserts BOTH directions — the sibling IS charged to the fix pass, the
  #     status file is not.
  # (NB: no stray apostrophes in these comments — the inert-assertion scanner
  # tracks quote parity across lines and an odd one desyncs the whole scan.)
  local SF="$R/loop-status.json"
  local WDO="$BATS_TEST_TMPDIR/wd-sf"
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDO" --findings-file "$F" \
    --status-file "$SF" --max-rounds 3
  [ "$status" -eq 20 ]
  # the status file really is in the repo, or the absence below proves nothing
  [ -s "$SF" ]

  # the session edits ONE story file and ALSO writes the prefix sibling
  echo "v1" > "$R/touched.py"
  echo backup > "$R/loop-status.json.bak"
  residue_findings 2 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDO" --findings-file "$F" \
    --status-file "$SF" --resume --max-rounds 3
  [ "$status" -eq 20 ]
  # (a) the loop own status file is NOT attributed to the fix pass
  run ! grep -qxF 'loop-status.json' "$WDO/fix-touched-1.txt"
  # (c) --telemetry-file is the THIRD member of that same exclusion list, and it
  #     is pinned STRUCTURALLY rather than behaviourally on purpose: the sink is
  #     written only at a TERMINAL exit, so the reachable shape is
  #     escalate -> grant -> --resume, not this AWAITING_FIX pair. Asserting its
  #     absence from a file this fixture never creates would be vacuous — the
  #     trap this suite has had to fix twice. What is real, and what a deletion
  #     would break, is its membership in the list all three consumers read.
  grep -qF 'for _lp in "$status_file" "$findings_file" "$telemetry_file" "$carry_accounting"' "$LOOP_REAL"
  # (b) ...but its prefix sibling IS — the match is exact, not a prefix
  grep -qxF 'loop-status.json.bak' "$WDO/fix-touched-1.txt"
  grep -qxF 'touched.py' "$WDO/fix-touched-1.txt"
}

@test "#1435 the exclusion matches LITERALLY: a glob metacharacter in the path still excludes" {
  # The refactor replaced a sed regex splice with zsh literal matching precisely
  # so a caller-chosen path stops being a PATTERN. Every fixture so far uses a
  # metachar-free name, so deleting the `(b)` glob-quoting behaves identically
  # and the whole suite stays green — while in production a supported work-dir
  # like `wd[1]` stops matching and the loop own state files leak back into the
  # set that stamps `class`. That is the fail-OPEN direction.
  local IWD="$R/wd[1]"
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$IWD" --findings-file "$F" --max-rounds 3
  [ "$status" -eq 20 ]
  [ -f "$IWD/changelist-1.json" ]

  echo "v1" > "$R/touched.py"
  residue_findings 2 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$IWD" --findings-file "$F" --resume --max-rounds 3
  [ "$status" -eq 20 ]
  [ "$(cat "$IWD/fix-touched-1.txt")" = "touched.py" ]
  run ! grep -qF 'wd[1]' "$IWD/fix-touched-1.txt"
}

@test "#1435 the in-place rewrite preserves a path containing WHITESPACE" {
  # The helper rewrites the fix-touched file whenever any exclusion is active, so
  # it owns the file contents. Two mutations survive every existing fixture:
  # reading with word-splitting instead of per-line, and dropping `-r` from the
  # print. No test anywhere has a repo path with a space — the awkward-path
  # fixture the suite carries is a non-ASCII name, which survives both.
  #
  # In production, with a repo-internal work-dir (supported and tested), an edit
  # to `src/my file.py` would be rewritten as two bogus lines, so the blocker
  # .file no longer matches the set: stamped new_defect, and a class histogram
  # that is confidently wrong — the same spelling-agreement
  # failure the quotePath flag exists to prevent, reached from the other end.
  mkdir -p "$R/src"
  echo "v0" > "$R/src/my file.py"
  local IWD="$R/.loop-wd"
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$IWD" --findings-file "$F" --max-rounds 3
  [ "$status" -eq 20 ]

  echo "v1" > "$R/touched.py"
  echo "v1" > "$R/src/my file.py"
  residue_findings 2 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$IWD" --findings-file "$F" --resume --max-rounds 3
  [ "$status" -eq 20 ]
  # the whitespace path survives WHOLE...
  grep -qxF 'src/my file.py' "$IWD/fix-touched-1.txt"
  # ...and was not split into fragments: exactly two lines, not three
  [ "$(grep -c . "$IWD/fix-touched-1.txt")" -eq 2 ]
  run ! grep -qxF 'src/my' "$IWD/fix-touched-1.txt"
}


@test "#1435 the EXACT-match arm is literal too: a metachar in --findings-file still excludes" {
  # The helper has TWO arms depending on the pattern-expansion flag: the work-dir
  # prefix (already pinned by the `wd[1]` fixture) and the exact-match list for
  # --status-file / --findings-file / --telemetry-file. Every fixture for that
  # second arm uses a metachar-free name, so dropping the expansion there behaves
  # identically and the suite stays green — while a supported repo-internal path
  # like `state[1]/loop.json` stops being excluded and the loop own bookkeeping
  # leaks back into the set that stamps `class` and into the review scope.
  # (NB: no stray apostrophes in these comments — the inert-assertion scanner
  # tracks quote parity across lines and an odd one desyncs the whole scan.)
  mkdir -p "$R/state[1]"
  local IF="$R/state[1]/findings.json"
  local WDO="$BATS_TEST_TMPDIR/wd-meta"
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$IF"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDO" --findings-file "$IF" --max-rounds 3
  [ "$status" -eq 20 ]

  echo "v1" > "$R/touched.py"
  residue_findings 2 touched.py > "$IF"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDO" --findings-file "$IF" --resume --max-rounds 3
  [ "$status" -eq 20 ]
  [ "$(cat "$WDO/fix-touched-1.txt")" = "touched.py" ]
  run ! grep -qF 'state[1]' "$WDO/fix-touched-1.txt"
}

@test "#2580 AC2 step mode: a residue-shaped DELTA round at the non-converging rung ends ESCALATE_NO_CONVERGENCE (12) and promotes no sweep" {
  # The other rung of the same shape. The SAME title at a CONSTANT line makes
  # round 2 non-converging; both rounds are zero-CRITICAL. This round used to
  # promote the closing sweep for the retired residue terminal (#1435 §9); it now
  # ends 12, so the automatic grant (#2576) or the interactive extension decides.
  echo "v0" > "$R/touched.py"
  printf '[{"severity":"WARNING","dimension":"bugs","file":"touched.py","line":10,"title":"unquoted expansion in the matcher","description":"d1","reviewer":"r"}]' > "$F"
  step --max-rounds 5
  [ "$status" -eq 20 ]

  echo "v1" > "$R/touched.py"
  printf '[{"severity":"WARNING","dimension":"bugs","file":"touched.py","line":10,"title":"unquoted expansion in the matcher","description":"d2","reviewer":"r"}]' > "$F"
  step --resume --max-rounds 5
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  echo "$output" | jq -e '.final_changelist.non_converging == true' >/dev/null
  echo "$output" | jq -e '[.round_changelists[].summary.critical] == [0, 0]' >/dev/null
  [ ! -e "$WD/.closing-sweep" ]
  run ! grep -q 'residue conditions hold' "$WD/progress.md"
}


@test "#1435 §10 an UNRESOLVABLE --findings-tree degrades LOUDLY, it does not refuse" {
  # The rev-parse validation had no test: deleting it behaves identically at the
  # exit level (diff-tree fails, pipefail fires, the failure arm returns 0), so
  # the suite stayed green while the announcement vanished and a caller who
  # mistyped or mis-minted the identity was left believing the rail was armed.
  # (NB: no stray apostrophes in these comments — the inert-assertion scanner
  # tracks quote parity across lines and an odd one desyncs the whole scan.)
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 3
  [ "$status" -eq 20 ]

  echo "v1" > "$R/touched.py"
  residue_findings 2 touched.py > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" \
    --resume --max-rounds 3 --findings-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  # DEGRADED, not refused — an unusable attestation must not cost the round
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  # ...but it says so, which is the whole difference from a silent pass
  echo "$stderr" | grep -q 'does not resolve to a tree'
  echo "$stderr" | grep -q 'cadence guard is OFF for round 2'
}

@test "#1435 §10 the attested check runs BEFORE --test-cmd, so a writing gate is not a cadence violation" {
  # The ordering is documented and half-pinned (before the CAPTURE). This pins
  # the other half. Surviving mutation: move the --test-cmd block above the
  # cadence block. Every existing fixture stays green — the only one combining
  # the two uses a no-op gate and expects a refusal anyway — while in production
  # every honest round on a repo whose gate regenerates a fixture or runs a
  # formatter is refused for a cadence mistake that never happened.
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 3
  [ "$status" -eq 20 ]

  # correct cadence: fix, THEN mint, THEN panel
  echo "v1" > "$R/touched.py"
  local T1; T1="$(_tree_now)"
  residue_findings 2 touched.py > "$F"
  step --resume --max-rounds 3 --findings-tree "$T1" \
    --test-cmd 'echo regenerated > "'"$R"'/fixture.txt"'
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  # the gate really wrote into the repo, or this fixture proves nothing
  [ -f "$R/fixture.txt" ]
}

@test "#1435 §10 an honest round carrying BOTH attestations proceeds" {
  # The sibling test advertises "with and without --gate-attest" but passes only
  # --findings-tree, so the with-half did not exist — and the only fixture
  # carrying both expects a refusal. Surviving mutation: make the equal-identity
  # short-circuit also require an empty gate_attest. The suite stays green while
  # every session following the skill template — which passes both on each
  # resume — is refused on a perfectly correct round: one flag suppressing the
  # other, which the contract explicitly forbids.
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 3
  [ "$status" -eq 20 ]

  echo "v1" > "$R/touched.py"
  local T1; T1="$(_tree_now)"
  residue_findings 2 touched.py > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" \
    --resume --max-rounds 3 --findings-tree "$T1" --gate-attest "$T1" --test-cmd 'true'
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  # ...and the gate attestation was CONSUMED, not merely tolerated
  echo "$stderr" | grep -q 'matches the working tree'
}

@test "#1435 §10 the guard is armed on ROUND 1 too, where a false green opens the PR" {
  # Round 1 is a FULL round, so zero blockers IS the CONVERGED condition. Gating
  # the attested arm on --resume left exactly that uncovered: a session that ran
  # the panel, then edited, then invoked would exit 0 and open a PR on a panel
  # that read a tree which no longer exists — while the flag was accepted without
  # complaint. Surviving mutation before the fix: re-add the resume conjunct.
  echo "v0" > "$R/touched.py"
  local T1; T1="$(_tree_now)"
  printf '[]' > "$F"
  # the session edits AFTER its panel ran — the wrong order
  echo "v1-after-the-panel" > "$R/touched.py"

  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" \
    --max-rounds 3 --findings-tree "$T1"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q '"status":"STALE_FINDINGS"'
  echo "$stderr" | grep -q "round 1's findings were produced against tree"
  # the false green it prevents: an empty findings file on a FULL round is the
  # CONVERGED condition, so without the guard this run would have exited 0
  [ "$(echo "$output" | jq -r '.status')" != "CONVERGED" ]
}
