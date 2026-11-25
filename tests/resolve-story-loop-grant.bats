#!/usr/bin/env bats
#
# Grants and escalation: the human-grant ceiling sidecar, <work-dir>/.max-rounds
# (#1576), with one end-to-end run of its writer; the unattended automatic grant
# (#2576, #3076); residue-shaped runs reaching the convergence verdict and the
# clean stop (#2580); --risk, the round's risk assessment (#1921), and the
# extension bar (#2577).
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

# ---- the human-grant ceiling sidecar, `<work-dir>/.max-rounds` (#1576) -------
#
# The WRITER (record-grant.zsh) has its own file, tests/record-grant.bats. What
# follows is the READER: adoption, its refusal and clamp arms, the fresh-run clear,
# the adoption order against #1434's closing sweep, and one end-to-end case that
# actually runs the writer and then resumes — the write-then-read seam is
# precisely what #1558 lost, so it is proven rather than assumed.
#
# Every case below is expressible against the hook-mode seam, which drives a
# whole run in one invocation, so none of them is written in step mode.

@test "#1576 a .max-rounds sidecar raises the EFFECTIVE ceiling, never max_rounds itself" {
  # AC 4. The invariant #1434 established stands: max_rounds keeps reporting
  # what the caller passed, so build-escalation.zsh's header, its
  # BUDGET_EXHAUSTED line and build-telemetry-record.zsh's payload all keep
  # reading the number the command line actually carried.
  WD="$BATS_TEST_TMPDIR/wd-adopt"
  seed_resumable "$WD"
  printf '8\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 8 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "work-dir" ]
}

@test "#1576 with NO sidecar the two agree and the source is the flag" {
  WD="$BATS_TEST_TMPDIR/wd-nosidecar"
  seed_resumable "$WD"
  [ ! -e "$WD/.max-rounds" ]
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
}

@test "#1576 both keys are ALWAYS present — on a resumed run and on the --no-review fast path" {
  # Same argument closing_sweep_granted carries: a consumer
  # must never have to tell a value from "a status file that predates the key".
  # The fast path is the one that would silently drop them, because it emits
  # without ever entering the --resume block that adopts the sidecar.
  loop --no-review
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("effective_max_rounds") and has("max_rounds_source")' >/dev/null
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]

  WD="$BATS_TEST_TMPDIR/wd-present"
  seed_resumable "$WD"
  printf '8\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  echo "$output" | jq -e 'has("effective_max_rounds") and has("max_rounds_source")' >/dev/null
}

@test "#1576 reader arm (a): a whitespace-padded sidecar is stripped and adopted, silently" {
  WD="$BATS_TEST_TMPDIR/wd-ws"
  seed_resumable "$WD"
  printf '  8\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 8 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "work-dir" ]
  # a legitimate value is not a diagnostic
  lacks "$stderr" "max-rounds sidecar"
}

@test "#1576 reader arm (a): internal whitespace is NOT collapsed — a multi-token file is refused" {
  # The strip is leading/trailing ONLY. Collapsing internal whitespace would
  # repair `1\n2` into a ceiling of 12 that nobody wrote. 12 sits INSIDE the
  # soft cap, so if the collapse regressed it would be silently ADOPTED rather
  # than tripping arm (c) — which is why the fixture is chosen this way.
  WD="$BATS_TEST_TMPDIR/wd-multitoken"
  seed_resumable "$WD"
  printf '1\n2\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  contains "$stderr" "ignoring an unreadable max-rounds sidecar"
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
}

@test "#1576 a ZERO-BYTE sidecar is treated as absent by the reader, with no diagnostic" {
  # Both ends gate on `-s`. An `-e` would emit 'unreadable sidecar (got:
  # <empty>)' on every resume of a work-dir where a truncated write left the
  # file, sending the operator after a corruption that does not exist.
  WD="$BATS_TEST_TMPDIR/wd-zerobyte"
  seed_resumable "$WD"
  : > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  lacks "$stderr" "max-rounds sidecar"
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
}

@test "#1576 reader arm (b): a non-numeric sidecar is refused loudly and falls back to the flag" {
  WD="$BATS_TEST_TMPDIR/wd-garbage"
  seed_resumable "$WD"
  printf 'eight\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  contains "$stderr" "ignoring an unreadable max-rounds sidecar"
  contains "$stderr" "$WD/.max-rounds"
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
}

@test "#1576 reader arm (b): an OVER-WIDE (19-digit) sidecar is refused too" {
  # The guard is two-part (`<->` AND an 18-digit cap); the non-numeric case
  # above exercises only the first conjunct. All-digits-but-enormous is the
  # same corrupt-sidecar class the loop already guards for --max-rounds, .t0
  # and .closing-sweep.
  WD="$BATS_TEST_TMPDIR/wd-wide"
  seed_resumable "$WD"
  printf '9999999999999999999\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  contains "$stderr" "ignoring an unreadable max-rounds sidecar"
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
}

@test "#1576 reader arm (c): a sidecar beyond the soft cap is CLAMPED and adopted, naming the cap" {
  # A WELL-FORMED but wrong number is the road that actually defeats a budget —
  # exactly what #1434's clamp learned. The cap is derived, never transcribed,
  # so a retune of MAX_ROUNDS_SIDECAR_SLACK moves the fixture with it.
  local slack cap over
  slack=$(sidecar_slack)
  cap=$(( 5 + slack ))
  over=$(( cap + 1 ))
  WD="$BATS_TEST_TMPDIR/wd-overcap"
  seed_resumable "$WD"
  printf '%s\n' "$over" > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  contains "$stderr" "beyond the soft cap"
  contains "$stderr" "$WD/.max-rounds"
  contains "$stderr" "cap $cap"
  # CLAMPED to the cap, not discarded. Dropping it would collapse the ceiling
  # back to --max-rounds and, on a run already past that round, brick every
  # later --resume with exit 2 — stranding a granted, in-progress run.
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq "$cap" ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "work-dir" ]
}

@test "#1576 an over-cap sidecar does NOT strand a run already past --max-rounds" {
  # The concrete harm of discarding: with the ceiling collapsed back to the
  # flag, the resume guard refuses every subsequent invocation and the human's
  # granted run is unrunnable without hand-editing the sidecar, which the
  # docs forbid.
  local slack over
  slack=$(sidecar_slack)
  over=$(( 1 + slack + 5 ))
  WD="$BATS_TEST_TMPDIR/wd-overcap-strand"
  seed_resumable "$WD"          # exhausted at --max-rounds 1, so round 2 is next
  printf '%s\n' "$over" > "$WD/.max-rounds"
  resume_clean "$WD" 1
  # clamped, so round 2 is admitted rather than refused with exit 2
  [ "$status" -ne 2 ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq $(( 1 + slack )) ]
}

@test "#1576 reader arm (c) non-vacuity: the value AT the cap is still adopted" {
  # Without this the clamp could be off by one (or reject everything) and the
  # refusal test above would stay green.
  local slack cap
  slack=$(sidecar_slack)
  cap=$(( 5 + slack ))
  WD="$BATS_TEST_TMPDIR/wd-atcap"
  seed_resumable "$WD"
  printf '%s\n' "$cap" > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  lacks "$stderr" "beyond the soft cap"
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq "$cap" ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "work-dir" ]
}

@test "#1576 the slack constant covers the sanctioned grant sequence, incl. the #1434 round" {
  # The derivation is 5 grants x +3 PLUS the one closing-sweep round
  # record-grant.zsh folds into its base. A slack of 15 would clamp away exactly
  # the round the fifth sanctioned grant of a sweep-granted run bought.
  local slack softcap increment
  slack=$(sidecar_slack)
  softcap=5
  increment=3
  [ "$slack" -eq $(( softcap * increment + 1 )) ]
}

@test "#1576 reader arm (d): a sidecar at or below the passed flag simply loses to it" {
  # This is what makes "a passed value ABOVE the file wins" a special case of
  # one rule rather than a second rule to keep in sync: a human raising
  # --max-rounds further needs no sidecar edit.
  WD="$BATS_TEST_TMPDIR/wd-below"
  seed_resumable "$WD"
  printf '4\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
  # arm (d) is not a refusal — nothing is wrong with the file
  lacks "$stderr" "max-rounds sidecar"
}

@test "#1576 reader arm (d): a sidecar EQUAL to the passed flag also loses to it" {
  # The realistic shape: the conductor passes `prev_max + 3`, which is exactly
  # the value the sidecar holds. A `<` instead of `<=` would stamp
  # max_rounds_source: "work-dir" on a run where no grant is in force, so the
  # two keys would disagree about the same run.
  WD="$BATS_TEST_TMPDIR/wd-atflag"
  seed_resumable "$WD"
  printf '8\n' > "$WD/.max-rounds"
  resume_clean "$WD" 8
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 8 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
  lacks "$stderr" "max-rounds sidecar"
}

@test "#1576 the sidecar SURVIVES an adopting resume and is re-adopted by the next one" {
  # Step mode runs every round as its own --resume, so a sidecar consumed once
  # would fund exactly ONE round and the next resume would be refused by the
  # ceiling guard — sending the conductor back to the human for rounds already
  # granted. The file is per-RUN, cleared on a fresh start, NOT on a resume.
  WD="$BATS_TEST_TMPDIR/wd-survive"
  seed_resumable "$WD"
  printf '3\n' > "$WD/.max-rounds"
  # An ADOPTING resume: the sidecar is what lets round 2 run at all (the flag
  # is still 1). The terminal is deliberately not asserted — this case is about
  # the file's lifetime, and pinning a terminal here would couple it to the
  # non-convergence rung's fingerprint rules.
  resume_clean "$WD" 1
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 3 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "work-dir" ]
  # THE assertion: still on disk, unchanged, for the NEXT invocation. In step
  # mode every round is its own --resume, so a sidecar consumed once would fund
  # exactly one round and the next resume would be refused by the ceiling guard.
  [ -e "$WD/.max-rounds" ]
  [ "$(cat "$WD/.max-rounds")" = "3" ]
}

@test "#1576 non-vacuity: the fresh-run clear DOES remove it, so survival is a resume property" {
  # Without this pair, a reader could not tell "survives a resume" from "is
  # never cleared at all" — and the per-run contract depends on both halves.
  WD="$BATS_TEST_TMPDIR/wd-survive-neg"
  seed_resumable "$WD"
  printf '3\n' > "$WD/.max-rounds"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 2 \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ ! -e "$WD/.max-rounds" ]
}

@test "#1576 no refusal arm is fatal: every one exits exactly as the no-sidecar run does" {
  # The whole reader is fail-open by design — losing a grant costs one re-grant,
  # dying costs the resumable run. Compare each arm against the control rather
  # than hard-coding 0, so a change to the fixture's terminal moves both.
  WD="$BATS_TEST_TMPDIR/wd-ctl"
  seed_resumable "$WD"
  resume_clean "$WD" 5
  local control="$status"
  # validate the control itself: without this, a regression that broke EVERY
  # resume would move all four values together and the test would pass while
  # proving nothing
  [ "$control" -eq 0 ]

  local slack over
  slack=$(sidecar_slack)
  over=$(( 5 + slack + 1 ))
  local bad
  for bad in eight 9999999999999999999 "$over"; do
    WD="$BATS_TEST_TMPDIR/wd-fatal-$bad"
    seed_resumable "$WD"
    printf '%s\n' "$bad" > "$WD/.max-rounds"
    resume_clean "$WD" 5
    [ "$status" -eq "$control" ]
  done
}

@test "#1576 a fresh (non---resume) run CLEARS a stale .max-rounds rather than inheriting it" {
  # The largest blast radius of the per-run set: a previous story's granted
  # ceiling would silently FUND rounds this run never earned.
  WD="$BATS_TEST_TMPDIR/wd-fresh"
  mkdir -p "$WD"
  printf '99\n' > "$WD/.max-rounds"
  # ...and the writer's atomic-rename debris, which record-grant.zsh's own trap
  # comment promises this same clear sweeps
  printf '9\n' > "$WD/.max-rounds.tmp.99"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 5 \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  # assert on the loop's own output BEFORE any further `run` overwrites it
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
  [ ! -e "$WD/.max-rounds" ]
  [ ! -e "$WD/.max-rounds.tmp.99" ]
}

@test "#1576 the fresh-run clear NAMES the sidecar, in the rm diagnostic and the header inventory" {
  # A clear whose failure diagnostic does not name the file it failed to remove
  # leaves the operator guessing which foreign state was adopted.
  run grep -c 'max-rounds sidecar (\.max-rounds, \.max-rounds\.tmp\.\*)' "$LOOP_REAL"
  [ "$output" = "1" ]
  # ...and the file is inventoried in the header beside its siblings
  run grep -c '`<work-dir>/\.max-rounds`' "$LOOP_REAL"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "#1576 adoption order: a STALE .closing-sweep is still refused against the granted ceiling" {
  # THE order test. The clamp measures one round beyond the ceiling IN FORCE,
  # so the grant must be VALIDATED before the sweep is judged. A foreign marker
  # is still refused — here 99 against a granted ceiling of 8.
  WD="$BATS_TEST_TMPDIR/wd-order"
  seed_resumable "$WD"
  printf '99\n' > "$WD/.closing-sweep"
  printf '8\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  contains "$stderr" "beyond the one-round grant"
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "false" ]
  # ...while the grant itself is adopted normally
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 8 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "work-dir" ]
}

@test "#1576 adoption order: a sweep promoted DURING granted rounds is accepted, not refused" {
  # The defect this ordering exists to prevent. With the clamp measured against
  # the bare flag, a legitimate sweep at round 7 under a granted ceiling of 8
  # is 7 > 5+1 and would be REFUSED — which makes the promoted round a delta
  # round, and §9 forbids a delta round from declaring CONVERGED, so the run
  # could only ever end BUDGET_EXHAUSTED however clean it was.
  WD="$BATS_TEST_TMPDIR/wd-order-during"
  seed_resumable "$WD"
  printf '7\n' > "$WD/.closing-sweep"
  printf '8\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  lacks "$stderr" "beyond the one-round grant"
  # 7 is within the granted ceiling of 8, so it is not a GRANT of an extra round
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "false" ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 8 ]
}

@test "#1576 a closing sweep may NOT lower a grant-raised ceiling" {
  # _promote_closing_sweep raises rather than assigns. Keyed on the passed flag
  # it would pull a granted ceiling of 8 down to the sweep's own 7, throwing
  # away the human's last granted round and reporting BUDGET_EXHAUSTED for
  # rounds they had already given.
  WD="$BATS_TEST_TMPDIR/wd-nolower"
  seed_resumable "$WD"
  printf '6\n' > "$WD/.closing-sweep"
  printf '9\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  # the sweep sits BELOW the granted ceiling, so the ceiling is untouched
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 9 ]
}

@test "#1576 max_rounds_source stays 'flag' when only the #1434 sweep raised the ceiling" {
  # The field distinguishes a HUMAN grant from the loop's own safety net. With
  # no sidecar at all, a sweep-raised ceiling must not claim a grant it never
  # got — the one thing this key exists to tell apart.
  WD="$BATS_TEST_TMPDIR/wd-sweeponly"
  seed_resumable "$WD"
  printf '6\n' > "$WD/.closing-sweep"
  [ ! -e "$WD/.max-rounds" ]
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "true" ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 6 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
}

@test "#1576 a sweep one past the GRANTED ceiling is itself granted, and raises it again" {
  # The grant is "one round beyond the ceiling in force", and since #1576 that
  # ceiling can be a human grant. A sweep at 9 against a granted 8 is exactly
  # one past, so it is granted and the ceiling becomes 9 — the safety net still
  # works at the top of an extended run, which is when it matters most.
  WD="$BATS_TEST_TMPDIR/wd-order-ok"
  seed_resumable "$WD"
  printf '9\n' > "$WD/.closing-sweep"
  printf '8\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "true" ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 9 ]
  # ...and max_rounds still reports what the caller passed
  [ "$(echo "$output" | jq '.max_rounds')" -eq 5 ]
}

@test "#1576 END-TO-END: record-grant.zsh writes the ceiling and the very next --resume runs under it" {
  # The seam #1558 actually lost. Every other case here hand-seeds the file,
  # which proves the reader but would stay green if the two ends disagreed on
  # the format. This one runs the real writer against the real status JSON and
  # asserts the resume adopts exactly the ceiling it echoed.
  WD="$BATS_TEST_TMPDIR/wd-e2e"
  local ST="$BATS_TEST_TMPDIR/e2e-status.json"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 1 --status-file "$ST" \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]

  local RG="$REPO_ROOT/development/skills/resolve-issue/scripts/record-grant.zsh"
  run zsh "$RG" --work-dir "$WD" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  local echoed="$output"
  [ "$echoed" = "4" ]   # base 1 (max_rounds, no sweep grant) + 3

  # ...and the resume, still passing the ORIGINAL ceiling, runs under the grant
  resume_clean "$WD" 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq "$echoed" ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "work-dir" ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 1 ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
}

@test "#1576 non-vacuity: without the grant, that same resume is REFUSED by the ceiling guard" {
  # Proves the end-to-end case is really exercising the grant: the identical
  # resume at --max-rounds 1 with no sidecar cannot start round 2 at all.
  WD="$BATS_TEST_TMPDIR/wd-e2e-neg"
  seed_resumable "$WD"
  [ ! -e "$WD/.max-rounds" ]
  resume_clean "$WD" 1
  [ "$status" -eq 2 ]
  contains "$stderr" "raise --max-rounds"
}

# ---- the unattended automatic grant (#2576), end to end ----------------------
#
# A run whose blocking count falls (2 -> 1, the second round's blocker a new
# one, nothing carried, no CRITICAL on the last round) exhausts its budget; the convergence verdict
# passes; record-grant.zsh --source automatic raises the ceiling; and the very
# next --resume runs under it and converges with no prompt — the grant counted
# as automatic in the status JSON.

@test "#2576 END-TO-END: a falling, unstuck run is granted +3 automatically and resumes to CONVERGED" {
  WD="$BATS_TEST_TMPDIR/wd-auto"
  local ST="$BATS_TEST_TMPDIR/auto-status.json" CNT="$BATS_TEST_TMPDIR/auto-round"
  # round 1 carries a CRITICAL (it once kept the residue terminal, retired by
  # #2580, off the two-round window); the LAST round's is a WARNING only
  local TWO='[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"first","description":"d","reviewer":"r"},{"severity":"WARNING","dimension":"bugs","file":"app.py","line":2,"title":"second","description":"d","reviewer":"r"}]'
  local ONE='[{"severity":"WARNING","dimension":"tests","file":"app.py","line":400,"title":"a different one","description":"d","reviewer":"r"}]'
  local REV="$BATS_TEST_TMPDIR/auto-review.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    "c=\$(cat '$CNT' 2>/dev/null || echo 0); c=\$((c + 1)); echo \"\$c\" > '$CNT'" \
    "if [ \"\$c\" -eq 1 ]; then printf '%s' '$TWO' > \"\$REVIEW_FINDINGS\"; else printf '%s' '$ONE' > \"\$REVIEW_FINDINGS\"; fi" > "$REV"
  chmod +x "$REV"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 2 --status-file "$ST" \
    --review-cmd "$REV" --fix-cmd 'true'
  [ "$status" -eq 13 ] || { echo "status=$status"; echo "$output" | jq -c '{status, h: [.history[] | {blocking, non_converging}], esc: .escalation_reasons}'; return 1; }
  [ "$(jq -c '[.history[].blocking]' "$ST")" = '[2,1]' ]

  local BE="$REPO_ROOT/development/skills/resolve-issue/scripts/build-escalation.zsh"
  run zsh "$BE" --status "$ST" --format verdict
  [ "$status" -eq 0 ]
  [ "$(jq -r '.converging' <<<"$output")" = "true" ]

  local RG="$REPO_ROOT/development/skills/resolve-issue/scripts/record-grant.zsh"
  run --separate-stderr zsh "$RG" --work-dir "$WD" --status "$ST" --add 3 --source automatic
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]   # 2 + 3 = 5, cut to the cap of 2 x the original 2

  resume_clean "$WD" 2
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 4 ]
  [ "$(echo "$output" | jq -c '.grants')" = '{"human":0,"automatic":1}' ]
}

@test "#2576 grants is always present, {0,0} with no ledger, and a fresh run clears the ledger" {
  WD="$BATS_TEST_TMPDIR/wd-ledger"
  seed_resumable "$WD"
  [ "$(echo "$output" | jq -c '.grants')" = '{"human":0,"automatic":0}' ]
  printf '%s\n' '{"source":"human","add":3,"ceiling":4,"original_max_rounds":1}' > "$WD/grants.jsonl"
  # a FRESH run on the same work-dir must not inherit the previous run's grants
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 1 \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ ! -e "$WD/grants.jsonl" ]
  [ "$(echo "$output" | jq -c '.grants')" = '{"human":0,"automatic":0}' ]
}

@test "#2576 the cap bounds GRANTS only: a capped automatic grant still gets its one closing-sweep round" {
  # --max-rounds 1: the automatic cap is 2, so the grant is cut to a ceiling of
  # 2. A zero-blocker delta round 2 at that ceiling still promotes the closing
  # full sweep to round 3 — one past the cap, once, the #1434 safety net.
  WD="$BATS_TEST_TMPDIR/wd-capsweep"
  local ST="$BATS_TEST_TMPDIR/capsweep-status.json"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 1 --status-file "$ST" \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]
  local RG="$REPO_ROOT/development/skills/resolve-issue/scripts/record-grant.zsh"
  run --separate-stderr zsh "$RG" --work-dir "$WD" --status "$ST" --add 3 --source automatic
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  # the granted round's fix pass, as the conductor applies it before resuming:
  # it moves the tree, so round 2 is a DELTA round (a zero-blocker one)
  echo "x = 2" > "$R/helper.py"
  resume_clean "$WD" 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  # the grant's ceiling stays 2; the sweep's one round is what reads as 3
  [ "$(cat "$WD/.max-rounds")" = "2" ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 3 ]
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "true" ]
  [ "$(echo "$output" | jq -c '.grants')" = '{"human":0,"automatic":1}' ]
}

@test "#3076 END-TO-END: a stuck but falling run takes one self-guided retry, converges, and its record says so" {
  WD="$BATS_TEST_TMPDIR/wd-guided"
  local ST="$BATS_TEST_TMPDIR/guided-status.json" CNT="$BATS_TEST_TMPDIR/guided-round"
  # round 1: three blockers; round 2: the same first one again, so it is carried
  local THREE='[{"severity":"WARNING","dimension":"tests","file":"app.py","line":7,"title":"weak assert","description":"checks nothing","suggested_fix":"pin the line","reviewer":"r"},{"severity":"WARNING","dimension":"bugs","file":"app.py","line":200,"title":"b","description":"d","reviewer":"r"},{"severity":"WARNING","dimension":"bugs","file":"app.py","line":300,"title":"c","description":"d","reviewer":"r"}]'
  local ONE='[{"severity":"WARNING","dimension":"tests","file":"app.py","line":7,"title":"weak assert","description":"checks nothing","suggested_fix":"pin the line","reviewer":"r"}]'
  local REV="$BATS_TEST_TMPDIR/guided-review.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    "c=\$(cat '$CNT' 2>/dev/null || echo 0); c=\$((c + 1)); echo \"\$c\" > '$CNT'" \
    "if [ \"\$c\" -eq 1 ]; then printf '%s' '$THREE' > \"\$REVIEW_FINDINGS\"; else printf '%s' '$ONE' > \"\$REVIEW_FINDINGS\"; fi" > "$REV"
  chmod +x "$REV"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 5 --status-file "$ST" \
    --review-cmd "$REV" --fix-cmd 'true'
  [ "$status" -eq 12 ] || { echo "status=$status"; echo "$output" | jq -c '{status, h: [.history[] | {blocking, non_converging}]}'; return 1; }
  [ "$(jq -r '.auto_guided_retry' "$ST")" = "false" ]

  local BE="$REPO_ROOT/development/skills/resolve-issue/scripts/build-escalation.zsh"
  run zsh "$BE" --status "$ST" --format verdict --work-dir "$WD"
  [ "$status" -eq 0 ]
  [ "$(jq -c '{failures, eligible: .self_guided.eligible}' <<<"$output")" = '{"failures":["stuck"],"eligible":true}' ]

  local RG="$REPO_ROOT/development/skills/resolve-issue/scripts/record-grant.zsh"
  run --separate-stderr zsh "$RG" --work-dir "$WD" --status "$ST" --add 3 --source automatic --guided
  [ "$status" -eq 0 ]
  [ "$output" = "8" ]

  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq -r '.auto_guided_retry')" = "true" ]
  # the loop's record carries it, with the retry's outcome
  local rec
  rec=$(tail -n 1 "$DEFAULT_SINK")
  [ "$(jq -c '{outcome, g: .payload.auto_guided_retry}' <<<"$rec")" = '{"outcome":"success","g":true}' ]
  # the retry is spent: the same stuck status, judged again, refuses a second one
  run zsh "$BE" --status "$ST" --format verdict --work-dir "$WD"
  [ "$(jq -c '{failures, refusals: .self_guided.refusals}' <<<"$output")" = '{"failures":["stuck"],"refusals":["already-retried"]}' ]
  local arch
  arch="$(tr '\n' ' ' < "$REPO_ROOT/ARCHITECTURE.md" | tr -s ' ')"
  contains "$arch" '`auto_guided_retry` (#3076) is an **always-present** boolean, `true` once the ledger holds a line `record-grant.zsh --guided` wrote (the run'"'"'s one self-guided retry), so every status after that retry says it ran'
}

# ---- residue-shaped runs reach #2576's verdict, never a PR (#2580) ------------
#
# A residue-shaped run — zero CRITICAL in its last two rounds, its closing round
# a FULL sweep, non-critical blockers left — used to end CONVERGED_WITH_RESIDUE
# and open its PR. Since #2580 it ends BUDGET_EXHAUSTED, and its status file is
# what #2576's convergence verdict reads: a pass is an automatic grant and the
# run keeps fixing; a fail is #2579's clean stop. Neither opens a PR.

# Runs a two-round residue-shaped loop on the durable clean-stop work-dir for
# issue 2580: round 1 writes $1, round 2 writes $2 (files of findings). The fix
# hook changes nothing, so round 2's delta is empty and, carrying round 1's
# blockers, it runs as a FULL sweep. Sets WD and ST.
residue_shaped_run() {  # $1 = round-1 findings file, $2 = round-2 findings file
  local d
  d="$(zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/clean-stop.zsh" dir --repo-dir "$R" --issue 2580)"
  WD="$(jq -r '.work_dir' <<<"$d")"
  ST="$(jq -r '.status_file' <<<"$d")"
  mkdir -p "$WD"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 2 --status-file "$ST" \
    --review-cmd 'printf "%s" "$REVIEW_SCOPE_MODE" > "'"$BATS_TEST_TMPDIR"'/mode-r$REVIEW_ROUND.txt"; if [ "$REVIEW_ROUND" = 1 ]; then cp "'"$1"'" "$REVIEW_FINDINGS"; else cp "'"$2"'" "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'true'
}

# $1 WARNING findings in app.py, at lines $2, $2+100, ..., titled "<$3> <i>"
warnings() {  # $1 = count, $2 = first line, $3 = title prefix
  jq -nc --argjson n "$1" --argjson l "$2" --arg p "$3" '[range($n) as $i | {severity:"WARNING", dimension:"bugs", file:"app.py", line:($l + $i * 100), title:"\($p) \($i)", description:"d", reviewer:"r"}]'
}

@test "#2580 AC3 a residue-shaped run's status feeds the convergence verdict: a pass is an automatic grant, not a PR" {
  warnings 2 100 "first round" > "$BATS_TEST_TMPDIR/r1.json"
  warnings 1 5000 "fresh sweep finding" > "$BATS_TEST_TMPDIR/r2.json"
  residue_shaped_run "$BATS_TEST_TMPDIR/r1.json" "$BATS_TEST_TMPDIR/r2.json"
  # the ending is an escalation, never the retired exit 14
  [ "$status" -eq 13 ]
  [ "$(jq -r '.status' "$ST")" = "BUDGET_EXHAUSTED" ]
  [ "$(jq -r '.next_ref' "$ST")" = "reference/escalation.md" ]
  # ...on a genuinely residue-shaped run
  [ "$(cat "$BATS_TEST_TMPDIR/mode-r2.txt")" = "full" ]
  [ "$(jq -c '[.round_changelists[].summary.critical]' "$ST")" = "[0,0]" ]
  [ "$(jq -c '[.history[].blocking]' "$ST")" = "[2,1]" ]

  # #2576's verdict passes: falling, nothing stuck, no CRITICAL
  run zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/build-escalation.zsh" --status "$ST" --format verdict
  [ "$status" -eq 0 ]
  [ "$(jq -r '.converging' <<<"$output")" = "true" ]
  # ...so a clean stop is refused: this exit takes the grant
  run --separate-stderr zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/clean-stop.zsh" write --repo-dir "$R" --issue 2580 --branch feat/2580-x --run-id r
  [ "$status" -eq 2 ]
  [ ! -e "$(dirname "$ST")/clean-stop.json" ]
  # the automatic grant raises the ceiling: 2 + 3, cut to the cap of 2 x 2
  run --separate-stderr zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/record-grant.zsh" --work-dir "$WD" --status "$ST" --add 3 --source automatic
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
  # ...and the run keeps fixing under it instead of shipping its blocker
  resume_clean "$WD" 2
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq -c '.grants')" = '{"human":0,"automatic":1}' ]
}

@test "#2580 AC3 a residue-shaped run whose verdict fails (4 -> 5) takes the clean-stop arm, not a PR" {
  warnings 4 100 "first round" > "$BATS_TEST_TMPDIR/r1.json"
  warnings 5 5000 "fresh sweep finding" > "$BATS_TEST_TMPDIR/r2.json"
  residue_shaped_run "$BATS_TEST_TMPDIR/r1.json" "$BATS_TEST_TMPDIR/r2.json"
  [ "$status" -eq 13 ]
  [ "$(jq -r '.status' "$ST")" = "BUDGET_EXHAUSTED" ]
  [ "$(cat "$BATS_TEST_TMPDIR/mode-r2.txt")" = "full" ]
  [ "$(jq -c '[.round_changelists[].summary.critical]' "$ST")" = "[0,0]" ]
  [ "$(jq -c '[.history[].blocking]' "$ST")" = "[4,5]" ]

  # #2576's verdict fails on the trend alone
  run zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/build-escalation.zsh" --status "$ST" --format verdict
  [ "$status" -eq 0 ]
  [ "$(jq -r '.converging' <<<"$output")" = "false" ]
  [ "$(jq -c '.failures' <<<"$output")" = '["trend"]' ]
  # ...so the run stops cleanly: the marker is written and the stop is rendered
  run --separate-stderr zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/clean-stop.zsh" write --repo-dir "$R" --issue 2580 --branch feat/2580-x --run-id r
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = "BUDGET_EXHAUSTED" ]
  [ "$(jq -c '.convergence_failures' <<<"$output")" = '["trend"]' ]
  run --separate-stderr zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/build-escalation.zsh" --status "$ST" --format clean-stop --issue 2580 --branch feat/2580-x
  [ "$status" -eq 0 ]
  contains "$output" 'stopped cleanly'
  contains "$output" 'no PR'
}
# --- #1921: --risk, the round's risk assessment -------------------------------

WARN_APP='[{"severity":"WARNING","dimension":"bugs","file":"app.py","line":1,"title":"print without flush","description":"d","reviewer":"r"}]'
RISK_APP='[{"file":"app.py","line":1,"dimension":"bugs","title":"print without flush","p":0.01,"p_why":"stdout is line-buffered here","impact":0.4,"impact_why":"a delayed log line"}]'

@test "#1921 AC6 --risk is forwarded to the consolidator: the round's changelist carries the stamp and the demotion" {
  export corner_case_risk_threshold=0.05
  printf '%s' "$WARN_APP" > "$F"
  printf '%s' "$RISK_APP" > "$BATS_TEST_TMPDIR/risk-1.json"
  step --risk "$BATS_TEST_TMPDIR/risk-1.json"
  # the only blocker was demoted, so the full round has zero blockers
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  jq -e '.summary.risk_demoted == 1 and .summary.blocking == 0
         and (.suggestions[0] | .demoted == true and .risk_assessment.risk_thousandths == 4)' \
    "$WD/changelist-1.json" >/dev/null
}

@test "#1921 AC6 --risk applies to its own round only — a later --resume without it stamps nothing" {
  export corner_case_risk_threshold=0.05
  printf '%s' "$CRIT" > "$F"
  printf '%s' '[{"file":"app.py","line":1,"dimension":"bugs","title":"T","p":0.5,"p_why":"common","impact":1.0,"impact_why":"a false green"}]' \
    > "$BATS_TEST_TMPDIR/risk-1.json"
  step --risk "$BATS_TEST_TMPDIR/risk-1.json"
  [ "$status" -eq 20 ]
  jq -e '.blocking[0].risk_assessment.risk_thousandths == 500' "$WD/changelist-1.json" >/dev/null
  # the in-session fix, then round 2 with a new, unassessed WARNING and no --risk
  echo "print(2)" > "$R/app.py"
  printf '%s' "$WARN_APP" > "$F"
  step --resume
  [ -f "$WD/changelist-2.json" ]
  jq -e '[.blocking[], .suggestions[]] | all(has("risk_assessment") | not)' "$WD/changelist-2.json" >/dev/null
  jq -e '.summary | has("risk_demoted") | not' "$WD/changelist-2.json" >/dev/null
}

@test "#1921 AC5 a malformed --risk is exit 2 with the consolidator's message, before any round state is written" {
  export corner_case_risk_threshold=0.05
  printf '%s' "$WARN_APP" > "$F"
  printf '%s' '[{"file":"app.py","line":1,"dimension":"bugs","title":"print without flush","p":0.1,"p_why":"w","impact":0.5,"impact_why":"w"}]' \
    > "$BATS_TEST_TMPDIR/bad.json"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --risk "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
  [ "$stderr" = "resolve-story-loop: malformed --risk $BATS_TEST_TMPDIR/bad.json: entry 0 (print without flush): impact must be one of 0.1, 0.4, 0.7, 1.0 (got 0.5)" ]
  # the consolidator says the same thing after its own prefix
  run --separate-stderr env corner_case_risk_threshold=0.05 zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/consolidate-findings.zsh" \
    --findings "$F" --risk "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
  [ "$stderr" = "consolidate-findings: malformed --risk $BATS_TEST_TMPDIR/bad.json: entry 0 (print without flush): impact must be one of 0.1, 0.4, 0.7, 1.0 (got 0.5)" ]
  # nothing of the round was written, so a corrected re-invocation runs round 1
  [ ! -e "$WD/changelist-1.json" ]
  [ ! -e "$WD/history.jsonl" ]
  [ ! -e "$WD/changelists.jsonl" ]
  printf '%s' "$RISK_APP" > "$BATS_TEST_TMPDIR/risk-1.json"
  step --risk "$BATS_TEST_TMPDIR/risk-1.json"
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]
  [ -f "$WD/changelist-1.json" ]
}

@test "#1921 AC6 --risk beside --no-review or --review-cmd is a usage error" {
  printf '%s' "$RISK_APP" > "$BATS_TEST_TMPDIR/risk-1.json"
  run zsh "$LOOP_REAL" --no-review --risk "$BATS_TEST_TMPDIR/risk-1.json"
  [ "$status" -eq 2 ]
  contains "$output" '--risk is step-mode only'
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$LOOP_REAL" --repo "$R" --base main --work-dir "$WD" --review-cmd true --fix-cmd true \
    --risk "$BATS_TEST_TMPDIR/risk-1.json"
  [ "$status" -eq 2 ]
  contains "$output" '--risk is step-mode only'
}

@test "#1921 AC6 threshold off: a round with --risk writes a changelist byte-identical to the same round without it" {
  printf '%s' "$WARN_APP" > "$F"
  printf '%s' "$RISK_APP" > "$BATS_TEST_TMPDIR/risk-1.json"
  local v
  for v in UNSET 0 abc; do
    rm -rf "$WD" "$BATS_TEST_TMPDIR/wd-plain"
    if [ "$v" = UNSET ]; then unset corner_case_risk_threshold; else export corner_case_risk_threshold="$v"; fi
    step --risk "$BATS_TEST_TMPDIR/risk-1.json"
    [ "$status" -eq 20 ]
    step --work-dir "$BATS_TEST_TMPDIR/wd-plain"
    [ "$status" -eq 20 ]
    cmp "$WD/changelist-1.json" "$BATS_TEST_TMPDIR/wd-plain/changelist-1.json"
  done
}

@test "#1921 a repo-internal --risk is loop state: never charged to the fix pass" {
  # --risk joined the loop-internal exclusion list; an assessment written inside
  # the repo must not appear in the fix-touched set as the fix pass's own edit
  local RK="$R/risk-2.json"
  local WDO="$BATS_TEST_TMPDIR/wd-rk"
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDO" --findings-file "$F" --max-rounds 3
  [ "$status" -eq 20 ]
  echo "v1" > "$R/touched.py"
  printf '[]\n' > "$RK"
  residue_findings 2 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDO" --findings-file "$F" --resume --max-rounds 3 \
    --risk "$RK"
  [ "$status" -eq 20 ]
  run -1 grep -qxF 'risk-2.json' "$WDO/fix-touched-1.txt"
  grep -qxF 'touched.py' "$WDO/fix-touched-1.txt"
}

@test "#1921 AC6 threshold off or ignored: the loop never reads --risk, so a malformed file is no error" {
  printf '%s' "$WARN_APP" > "$F"
  printf 'not json\n' > "$BATS_TEST_TMPDIR/bad.json"
  local v
  for v in UNSET abc; do
    rm -rf "$WD" "$BATS_TEST_TMPDIR/wd-plain"
    if [ "$v" = UNSET ]; then unset corner_case_risk_threshold; else export corner_case_risk_threshold="$v"; fi
    step --risk "$BATS_TEST_TMPDIR/bad.json"
    [ "threshold $v: $status" = "threshold $v: 20" ]
    step --work-dir "$BATS_TEST_TMPDIR/wd-plain"
    [ "$status" -eq 20 ]
    cmp "$WD/changelist-1.json" "$BATS_TEST_TMPDIR/wd-plain/changelist-1.json"
  done
}

# --- #2577: the extension bar -------------------------------------------------
# A WARNING assessed at p 0.15 x impact 0.4 = risk 0.060: above a 0.04 base,
# below the 0.10 extension default. Round 1 is the ceiling (--max-rounds 1), a
# grant buys round 2, and the extension round demotes what the normal round kept.

ext_warn() {  # $1 = line, $2 = title
  printf '[{"severity":"WARNING","dimension":"bugs","file":"app.py","line":%d,"title":"%s","description":"d","reviewer":"r"}]' "$1" "$2"
}
ext_risk() {  # $1 = line, $2 = title
  printf '[{"file":"app.py","line":%d,"dimension":"bugs","title":"%s","p":0.15,"p_why":"needs a rare input","impact":0.4,"impact_why":"a wrong message"}]' "$1" "$2"
}

# round 1 at the ceiling with the risk-0.060 WARNING, then a grant of +3 ($1 =
# record-grant's --source, default human). The grant's echoed ceiling is left in
# $EXT_CEILING: the documented resume passes it as --max-rounds
# (reference/interactive/extension-grant.md step 5; the automatic grant resumes
# at the ceiling record-grant.zsh echoed).
ext_round1_and_grant() {
  ext_warn 1 "print without flush" > "$F"
  ext_risk 1 "print without flush" > "$BATS_TEST_TMPDIR/risk-1.json"
  step --max-rounds 1 --status-file "$BATS_TEST_TMPDIR/st.json" --risk "$BATS_TEST_TMPDIR/risk-1.json"
  [ "round 1: $status" = "round 1: 13" ]
  run -0 --separate-stderr zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/record-grant.zsh" \
    --work-dir "$WD" --status "$BATS_TEST_TMPDIR/st.json" --add 3 --source "${1:-human}"
  EXT_CEILING="$output"
  echo "print(2)" > "$R/app.py"   # the in-session fix
  ext_warn 2000 "stale cache never invalidated" > "$F"
  ext_risk 2000 "stale cache never invalidated" > "$BATS_TEST_TMPDIR/risk-2.json"
}

@test "#2577 AC1 base 0.04, extension unset: the risk-0.060 WARNING blocks in a normal round and is demoted in the extension round" {
  export corner_case_risk_threshold=0.04
  unset extension_risk_threshold
  ext_round1_and_grant
  [ "$EXT_CEILING" = "4" ]
  # round 1 (normal): kept blocking under the base, no extension mark
  jq -e '.summary.blocking == 1 and (.blocking[0].risk_assessment | .threshold == "0.04" and .threshold_thousandths == 40 and (has("bar") | not))' "$WD/changelist-1.json" >/dev/null
  # round 2 (extension, bought by the grant), resumed as documented with the
  # RAISED ceiling: the flag ties the sidecar, so the source is "flag" — the
  # grant ledger, not the flag, makes it an extension round
  step --resume --max-rounds "$EXT_CEILING" --status-file "$BATS_TEST_TMPDIR/st.json" --risk "$BATS_TEST_TMPDIR/risk-2.json"
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
  jq -e '.summary.blocking == 0 and .summary.risk_demoted == 1 and (.suggestions[0] | .demoted == true and .risk_assessment.risk_thousandths == 60 and .risk_assessment.threshold == "0.10" and .risk_assessment.threshold_thousandths == 100 and .risk_assessment.bar == "extension")' "$WD/changelist-2.json" >/dev/null
}

@test "#2577 AC1 a resume that passes the ORIGINAL --max-rounds detects the extension round too (the sidecar is adopted)" {
  export corner_case_risk_threshold=0.04
  unset extension_risk_threshold
  ext_round1_and_grant
  step --resume --max-rounds 1 --status-file "$BATS_TEST_TMPDIR/st.json" --risk "$BATS_TEST_TMPDIR/risk-2.json"
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "work-dir" ]
  jq -e '.summary.blocking == 0 and (.suggestions[0] | .demoted == true and .risk_assessment.bar == "extension")' "$WD/changelist-2.json" >/dev/null
}

@test "#2577 AC1 an AUTOMATIC grant resumed at its echoed ceiling makes an extension round as well" {
  export corner_case_risk_threshold=0.04
  unset extension_risk_threshold
  ext_round1_and_grant automatic
  # the automatic cap (2 x the original 1) cuts the +3 to a ceiling of 2
  [ "$EXT_CEILING" = "2" ]
  step --resume --max-rounds "$EXT_CEILING" --status-file "$BATS_TEST_TMPDIR/st.json" --risk "$BATS_TEST_TMPDIR/risk-2.json"
  jq -e '.summary.blocking == 0 and (.suggestions[0] | .demoted == true and .risk_assessment.bar == "extension")' "$WD/changelist-2.json" >/dev/null
}

@test "#2577 the closing full sweep of a grant-extended run is an extension round: the risk-0.060 WARNING is demoted" {
  export corner_case_risk_threshold=0.04
  unset extension_risk_threshold
  printf '%s' "$CRIT" > "$F"
  step --max-rounds 1 --status-file "$BATS_TEST_TMPDIR/st.json"
  [ "round 1: $status" = "round 1: 13" ]
  run -0 --separate-stderr zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/record-grant.zsh" \
    --work-dir "$WD" --status "$BATS_TEST_TMPDIR/st.json" --add 1
  [ "$output" = "2" ]
  echo "print(2)" > "$R/fixed.py"
  printf '[]' > "$F"
  step --resume --max-rounds 2 --status-file "$BATS_TEST_TMPDIR/st.json"
  [ "$status" -eq 20 ]
  [ "$(cat "$WD/.closing-sweep")" = "3" ]
  # round 3 is the closing sweep granted one round past the granted ceiling
  ext_warn 1 "print without flush" > "$F"
  ext_risk 1 "print without flush" > "$BATS_TEST_TMPDIR/risk-3.json"
  step --resume --max-rounds 2 --status-file "$BATS_TEST_TMPDIR/st.json" --risk "$BATS_TEST_TMPDIR/risk-3.json"
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "true" ]
  jq -e '.summary.blocking == 0 and .summary.risk_demoted == 1 and (.suggestions[0] | .demoted == true and .risk_assessment.risk_thousandths == 60 and .risk_assessment.bar == "extension")' "$WD/changelist-3.json" >/dev/null
}

@test "#2577 AC2 the closing sweep of a run with NO grant keeps the base bar: the same WARNING still blocks" {
  export corner_case_risk_threshold=0.04
  unset extension_risk_threshold
  printf '%s' "$CRIT" > "$F"
  step --max-rounds 2
  [ "$status" -eq 20 ]
  echo "print(2)" > "$R/fixed.py"
  printf '[]' > "$F"
  step --resume --max-rounds 2
  [ "$status" -eq 20 ]
  [ "$(cat "$WD/.closing-sweep")" = "3" ]
  # round 3 is past --max-rounds, but no grant bought it
  ext_warn 1 "print without flush" > "$F"
  ext_risk 1 "print without flush" > "$BATS_TEST_TMPDIR/risk-3.json"
  step --resume --max-rounds 2 --risk "$BATS_TEST_TMPDIR/risk-3.json"
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
  jq -e '.summary.blocking == 1 and (.blocking[0].risk_assessment | .threshold == "0.04" and .risk_thousandths == 60 and (has("bar") | not))' "$WD/changelist-3.json" >/dev/null
}

@test "#2577 AC3 base off: the extension round still applies the 0.10 default to --risk" {
  unset corner_case_risk_threshold extension_risk_threshold
  ext_round1_and_grant
  # round 1 (normal, base off): --risk forwarded unread, so no stamp at all
  jq -e '.summary.blocking == 1 and (.blocking[0] | has("risk_assessment") | not)' "$WD/changelist-1.json" >/dev/null
  step --resume --max-rounds "$EXT_CEILING" --status-file "$BATS_TEST_TMPDIR/st.json" --risk "$BATS_TEST_TMPDIR/risk-2.json"
  jq -e '.summary.blocking == 0 and (.suggestions[0] | .demoted == true and .risk_assessment.threshold_thousandths == 100 and .risk_assessment.bar == "extension")' "$WD/changelist-2.json" >/dev/null
}

@test "#2577 AC3 base off: a malformed --risk is refused up front in an extension round, and forwarded unread when the bar is off" {
  unset corner_case_risk_threshold extension_risk_threshold
  ext_round1_and_grant
  printf 'not json\n' > "$BATS_TEST_TMPDIR/bad.json"
  # unset (the 0.10 default) and an invalid value (which behaves as unset) both
  # keep the bar on, so the loop refuses the file before anything is written
  local v
  for v in UNSET abc; do
    if [ "$v" = UNSET ]; then unset extension_risk_threshold; else export extension_risk_threshold="$v"; fi
    run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
      zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume --max-rounds "$EXT_CEILING" \
      --status-file "$BATS_TEST_TMPDIR/st.json" --risk "$BATS_TEST_TMPDIR/bad.json"
    [ "$v: $status" = "$v: 2" ]
    # the path is the canonicalised one (`:A`), so match the message and the name
    contains "$stderr" "resolve-story-loop: --risk is not exactly one JSON array: "
    contains "$stderr" "/bad.json"
    [ ! -e "$WD/changelist-2.json" ]
  done
  # extension_risk_threshold=0 turns the bar off: the file is forwarded unread
  export extension_risk_threshold=0
  step --resume --max-rounds "$EXT_CEILING" --status-file "$BATS_TEST_TMPDIR/st.json" --risk "$BATS_TEST_TMPDIR/bad.json"
  [ -f "$WD/changelist-2.json" ]
  jq -e '.summary.blocking == 1 and (.blocking[0] | has("risk_assessment") | not)' "$WD/changelist-2.json" >/dev/null
}

@test "#2577 AC3 base off: a normal round is byte-identical with or without --risk, whatever extension_risk_threshold says" {
  unset corner_case_risk_threshold
  printf '%s' "$WARN_APP" > "$F"
  printf '%s' "$RISK_APP" > "$BATS_TEST_TMPDIR/risk-1.json"
  local v
  for v in UNSET 0.5 0 abc; do
    rm -rf "$WD" "$BATS_TEST_TMPDIR/wd-plain"
    if [ "$v" = UNSET ]; then unset extension_risk_threshold; else export extension_risk_threshold="$v"; fi
    step --risk "$BATS_TEST_TMPDIR/risk-1.json"
    [ "$status" -eq 20 ]
    step --work-dir "$BATS_TEST_TMPDIR/wd-plain"
    [ "$status" -eq 20 ]
    cmp "$WD/changelist-1.json" "$BATS_TEST_TMPDIR/wd-plain/changelist-1.json"
  done
}
