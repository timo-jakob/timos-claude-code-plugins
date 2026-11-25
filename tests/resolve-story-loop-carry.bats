#!/usr/bin/env bats
#
# Carry accounting (#1583, #2010) — confirmed / re-raised / unconfirmed, in hook
# mode (the <findings-path>.carry.json sidecar) and in step mode
# (--carry-accounting) — and the one-shot all-ambiguous auto-continue (#1498)
# with the closing-sweep ceilings around it (#1571, #2580).
#
# Coverage note for the #1583 carry-accounting arm (_carry_account in the
# loop): every refusal ground and the stamp-write failure are driven below.
# These exits are NOT driven — deleting any one ships green today:
#   * the two `could not read the carry accounting at round R` arms, which
#     guard a jq read of $acct — JSON the same function just produced, so no
#     fixture can make that read fail without also failing the earlier shape
#     check (which IS driven);
#   * `could not build the carry_accounting stamp`, the same shape;
#   * `could not compute the carry accounting`, the jq program that produces
#     $acct — its inputs (the carry, the accounting, the changelist) have all
#     passed their own shape checks by then, so no fixture reaches it either;
#   * the two `$fix_verification` read guards at the top of the function
#     (`could not read the fix-verification carry` and `non-numeric
#     fix-verification length`), which guard a jq read of verify-R.json — a
#     file the loop itself wrote from the consolidator's `.blocking` one
#     invocation earlier, so the same class: raised and waived in round 1.
# They are defensive exits on values the loop itself produced, not behaviour;
# listed here so a reviewer does not read their absence from the suite as a
# gap — and so the inventory is complete, not a sample.
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

# --- #1583: carry accounting in HOOK mode (the <findings-path>.carry.json sidecar)

@test "#1583 AC 2 hook mode: a carried round whose panel writes no <findings-path>.carry.json is refused as CARRY-UNACCOUNTED" {
  WD="$BATS_TEST_TMPDIR/wd"
  # the $S wrapper still prepends the $CARRY_ALL prelude, so this panel DELETES
  # the sidecar the prelude just wrote — that deletion is load-bearing: it is
  # what leaves round 2 with a carry and no accounting
  loop --max-rounds 3 --status-file "$BATS_TEST_TMPDIR/st.json" \
    --review-cmd 'rm -f "$REVIEW_FINDINGS.carry.json"; if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "STALE_FINDINGS" ]
  contains "$output" 'carry unaccounted: round 2 carries 1 entries but no carry accounting was supplied'
  # hook mode names the CONCRETE sidecar it expected, never the step-mode flag
  # (which hook mode refuses as a usage error)
  contains "$output" 'findings-round-2.json.carry.json, which the hook must write on a carried round'
  lacks "$output" '--carry-accounting FILE in step mode'
  [ "$(jq -c '.carry_unconfirmed' "$BATS_TEST_TMPDIR/st.json")" = "[]" ]
  # the safety invariant
  [ ! -e "$WD/verify-3.json" ]
  [ "$(jq 'length' "$WD/verify-2.json")" -eq 1 ]
  grep -q -- '^\*\*Refused (round 2):\*\* stale findings — carry unaccounted' "$WD/progress.md"
  # ...and a ZERO-BYTE sidecar — the realistic shape of a hook whose jq write
  # failed — is told apart from an absent one (a fresh run, same work-dir)
  loop --max-rounds 3 --status-file "$BATS_TEST_TMPDIR/st2.json" \
    --review-cmd ': > "$REVIEW_FINDINGS.carry.json"; if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'true'
  [ "$status" -eq 2 ]
  contains "$output" 'findings-round-2.json.carry.json, which exists but is empty — the hook'"'"'s write failed'
}

@test "#1583 hook mode: an UNCONFIRMED sidecar refuses the round naming the entry, and lists it in carry_unconfirmed" {
  WD="$BATS_TEST_TMPDIR/wd"
  loop --max-rounds 3 --status-file "$BATS_TEST_TMPDIR/st.json" \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; jq "[.[] | {file, dimension, title, confirmed: [], re_raised: [], unconfirmed: [\"bug-hunter\"]}]" "$REVIEW_FIX_VERIFICATION" > "$REVIEW_FINDINGS.carry.json"; fi' \
    --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "STALE_FINDINGS" ]
  contains "$output" 'carry unaccounted: round 2 carried entry "T" (app.py, bugs) was neither confirmed nor re-raised by any reviewer (unconfirmed by: bug-hunter)'
  [ "$(jq -c '.carry_unconfirmed' "$BATS_TEST_TMPDIR/st.json")" = '[{"file":"app.py","dimension":"bugs","title":"T"}]' ]
  [ ! -e "$WD/verify-3.json" ]
  [ "$(jq '.round_changelists | length' "$BATS_TEST_TMPDIR/st.json")" -eq 1 ]
  # the status JSON's final_changelist is round 1's — the carry's origin — never
  # the refused round's zero-blocker changelist that already sits on disk
  [ "$(jq '.final_changelist.blocking | length' "$BATS_TEST_TMPDIR/st.json")" -eq 1 ]
  [ "$(jq -r '.final_changelist.blocking[0].title' "$BATS_TEST_TMPDIR/st.json")" = "T" ]
}

# --- #2010: one owner per carried entry

@test "#2010 (a) hook mode: an entry accounted for by its owner alone passes, and the hook is handed the per-dimension split" {
  WD="$BATS_TEST_TMPDIR/wd"
  # round 2's panel records the split map it was handed, then confirms the one
  # carried entry under ONE reviewer — the owner of the "bugs" dimension
  loop --max-rounds 3 --status-file "$BATS_TEST_TMPDIR/st.json" \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "%s" "$REVIEW_FIX_VERIFICATION_BY_DIMENSION" > "'"$BATS_TEST_TMPDIR"'/map-$REVIEW_ROUND.json"; printf "[]" > "$REVIEW_FINDINGS"; jq "[.[] | {file, dimension, title, confirmed: [\"bug-hunter\"], re_raised: [], unconfirmed: []}]" "$REVIEW_FIX_VERIFICATION" > "$REVIEW_FINDINGS.carry.json"; fi' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "CONVERGED" ]
  [ "$(jq -c '.round_changelists[1].carry_accounting.confirmed' "$BATS_TEST_TMPDIR/st.json")" = '[{"file":"app.py","dimension":"bugs","title":"T"}]' ]
  # the hook saw the split map beside the unchanged whole-round carry
  [ "$(jq -c 'keys' "$BATS_TEST_TMPDIR/map-2.json")" = '["bugs"]' ]
  [ "$(jq -r '.bugs' "$BATS_TEST_TMPDIR/map-2.json")" = "$WD/verify-2-bugs.json" ]
  [ "$(jq -c '[.[].dimension] | unique' "$WD/verify-2-bugs.json")" = '["bugs"]' ]
}

@test "#2010 (b) hook mode: an entry its owner never accounted for is refused CARRY-UNACCOUNTED, on the final round too" {
  WD="$BATS_TEST_TMPDIR/wd"
  # --max-rounds 2: round 2 is the run's LAST round, and the refusal still fires
  # — no round is exempt from the one-owner rule (fail-closed)
  loop --max-rounds 2 --status-file "$BATS_TEST_TMPDIR/st.json" \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; jq "[.[] | {file, dimension, title, confirmed: [], re_raised: [], unconfirmed: []}]" "$REVIEW_FIX_VERIFICATION" > "$REVIEW_FINDINGS.carry.json"; fi' \
    --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "STALE_FINDINGS" ]
  contains "$output" 'carry unaccounted: round 2 carried entry "T" (app.py, bugs) was neither confirmed nor re-raised by any reviewer (no reviewer reported it)'
  [ "$(jq -c '.carry_unconfirmed' "$BATS_TEST_TMPDIR/st.json")" = '[{"file":"app.py","dimension":"bugs","title":"T"}]' ]
  [ ! -e "$WD/verify-3.json" ]
}

@test "#2010 (c) hook mode: a record naming two distinct reviewers is refused on the wrong-shape ground" {
  WD="$BATS_TEST_TMPDIR/wd"
  # the retired every-reviewer shape: the owner confirms AND a second reviewer
  # reports the same entry unconfirmed. Before #2010 this was accepted (one
  # confirmation retired the entry); now it is the wrong shape.
  loop --max-rounds 3 --status-file "$BATS_TEST_TMPDIR/st.json" \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; jq "[.[] | {file, dimension, title, confirmed: [\"bug-hunter\"], re_raised: [], unconfirmed: [\"security-reviewer\"]}]" "$REVIEW_FIX_VERIFICATION" > "$REVIEW_FINDINGS.carry.json"; fi' \
    --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "STALE_FINDINGS" ]
  contains "$output" 'records with one reviewer each'
  contains "$output" '"T" (app.py, bugs) names bug-hunter, security-reviewer'
  # the wrong-shape ground, not the unconfirmed one: nothing is listed as unconfirmed
  [ "$(jq -c '.carry_unconfirmed' "$BATS_TEST_TMPDIR/st.json")" = "[]" ]
  [ ! -e "$WD/verify-3.json" ]
  [ "$(jq 'length' "$WD/verify-2.json")" -eq 1 ]
}

@test "#2010 hook mode: a carry split-carry refuses stops the loop before the panel runs" {
  WD="$BATS_TEST_TMPDIR/wd"
  local crit_sp="${CRIT/\"bugs\"/\"prose logic\"}"
  loop --max-rounds 3 --status-file "$BATS_TEST_TMPDIR/st.json" \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'$crit_sp'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'true'
  [ "$status" -eq 1 ]
  contains "$output" 'could not split the fix-verification carry'
  [ ! -e "$WD/verify-3.json" ]
}

@test "#2010 hook mode: REVIEW_FIX_VERIFICATION_BY_DIMENSION is {} on round 1, where nothing is carried" {
  loop --max-rounds 1 --status-file "$BATS_TEST_TMPDIR/st.json" \
    --review-cmd 'printf "%s" "$REVIEW_FIX_VERIFICATION_BY_DIMENSION" > "'"$BATS_TEST_TMPDIR"'/map-$REVIEW_ROUND.json"; printf "[]" > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/map-1.json")" = "{}" ]
}

@test "#1583 hook mode: a sidecar left at the findings path by an EARLIER run is cleared before the panel runs, and a directory there fails loudly" {
  # The findings path is per round (.review/findings-round-N.json), so nothing
  # stale survives WITHIN a run — the hazard is a second run in the same repo.
  # Plant last run's confirm-all sidecar at round 2's path, for an identity that
  # is NOT in this run's carry, and run a panel that writes no sidecar on round
  # 2 (the REAL loop, so the wrapper's prelude cannot write one either). Read,
  # the planted file would refuse the round as naming an entry not in
  # verify-2.json; cleared, the round is refused for want of an accounting —
  # the two refusals are distinguishable, and only the second is correct.
  mkdir -p "$R/.review"
  printf '[{"file":"other.py","dimension":"bugs","title":"stale","confirmed":["r"],"re_raised":[],"unconfirmed":[]}]' \
    > "$R/.review/findings-round-2.json.carry.json"
  WD="$BATS_TEST_TMPDIR/wd-stale"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$LOOP_REAL" --repo "$R" --base main --work-dir "$WD" --max-rounds 3 --status-file "$BATS_TEST_TMPDIR/st.json" \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'true'
  [ "$status" -eq 2 ]
  contains "$output" 'carry unaccounted: round 2 carries 1 entries but no carry accounting was supplied'
  lacks "$output" 'names entries that are not in verify-2.json'
  [ ! -e "$R/.review/findings-round-2.json.carry.json" ]
  # ...and a directory planted at the sidecar path makes the clear fail LOUDLY
  # (exit 1, named), never get silently read as this round's accounting
  rm -rf "$R/.review" "$WD"
  mkdir -p "$R/.review/findings-round-2.json.carry.json"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$LOOP_REAL" --repo "$R" --base main --work-dir "$WD" --max-rounds 3 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'true'
  [ "$status" -eq 1 ]
  contains "$output" 'could not clear the stale carry-accounting sidecar'
}

@test "#1583 hook mode: a confirming sidecar is accepted and stamped, and the triple renders beside the new/carried split" {
  # the fix pass moves the tree, so round 2 is a real delta with a carry; the
  # prelude confirms it, round 2 finds nothing, and the promoted closing sweep
  # (empty carry) converges — every round's changelist carries the stamp
  WD="$BATS_TEST_TMPDIR/wd-stamp"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 4 --status-file "$BATS_TEST_TMPDIR/st.json" \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then echo "print(2)" >> "$REVIEW_REPO/app.py"; fi'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "CONVERGED" ]
  [ "$(jq '.rounds' "$BATS_TEST_TMPDIR/st.json")" -eq 3 ]
  [ "$(jq -c '.carry_unconfirmed' "$BATS_TEST_TMPDIR/st.json")" = "[]" ]
  [ "$(jq -c '.round_changelists[1].carry_accounting' "$BATS_TEST_TMPDIR/st.json")" = \
    '{"total":1,"confirmed":[{"file":"app.py","dimension":"bugs","title":"T"}],"re_raised":[],"unconfirmed":[]}' ]
  [ "$(jq -c '.round_changelists[2].carry_accounting' "$BATS_TEST_TMPDIR/st.json")" = \
    '{"total":0,"confirmed":[],"re_raised":[],"unconfirmed":[]}' ]
  grep -q -- 'carried: confirmed 1 / re-raised 0 / unconfirmed 0 of 1' "$WD/progress.md"
  # a round that HAS blockers renders the triple beside the new/carried split,
  # on the same line — the stuck shape: the carry is re-raised in the findings
  # file, and the prelude also confirms it (a confirmation decides the
  # accounting outcome; the re-raise still blocks on its own evidence)
  WD2="$BATS_TEST_TMPDIR/wd-stuck"
  stuck_loop --max-rounds 3 --work-dir "$WD2"
  [ "$status" -eq 12 ]
  grep -q -- '- blockers: 1 (critical: 1, warning: 0) (new: 0, carried: 1), conflicts: 0, suggestions: 0, carried: confirmed 1 / re-raised 0 / unconfirmed 0 of 1' "$WD2/progress.md"
}

# --- #1583: carry accounting — confirmed / re-raised / unconfirmed -------------
#
# From round 2 on the loop reads, per carried entry, which reviewers confirmed
# it, which re-raised it (with evidence, in the findings file) and which left it
# unconfirmed. A reviewer's ignorance is a count, not a defect: the loop refuses
# only a carried identity that NO reviewer confirmed and NO reviewer re-raised,
# and it does so BEFORE verify-<R+1>.json is written, so the carry survives.


@test "#1583 AC 2 step mode: a carried round with NO --carry-accounting is refused as CARRY-UNACCOUNTED; with one it is accepted; an empty carry needs none" {
  seed_awaiting
  local before; before="$(shasum -a 256 "$WD/verify-2.json")"
  printf '[]' > "$F"
  # bypass the wrapper's confirm-all default: invoke the REAL loop, flag omitted
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$LOOP_REAL" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume \
    --status-file "$BATS_TEST_TMPDIR/st.json"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "STALE_FINDINGS" ]
  contains "$output" 'carry unaccounted: round 2 carries 1 entries but no carry accounting was supplied'
  contains "$output" '--carry-accounting FILE in step mode, <findings-path>.carry.json in hook mode'
  # the safety invariant: nothing was consumed and the carry chain is untouched
  [ ! -e "$WD/verify-3.json" ]
  [ "$(shasum -a 256 "$WD/verify-2.json")" = "$before" ]
  [ "$(jq '.rounds' "$BATS_TEST_TMPDIR/st.json")" -eq 1 ]
  # the SAME round with a well-formed accounting is accepted: a zero-blocker
  # delta round, which promotes the closing sweep (#1434)
  step --resume --carry-accounting "$(carry_record '["r"]' '[]' '[]')"
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  [ "$(jq 'length' "$WD/verify-3.json")" -eq 0 ]
  # ...and the closing sweep carries nothing, so it needs no accounting at all
  # (the REAL loop again, so the wrapper cannot supply one)
  printf '[]' > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$LOOP_REAL" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq -c '.round_changelists[2].carry_accounting')" = '{"total":0,"confirmed":[],"re_raised":[],"unconfirmed":[]}' ]
}

@test "#1583 AC 3(a), #2010 the owner confirms X -> accepted, X not blocking, carry_unconfirmed empty" {
  # #2010 retired the union rule: X is shown only to its own dimension's
  # reviewer, so its record names that one owner. (The old fixture — the owner
  # confirming beside a second reviewer's unconfirmed report — is now the
  # wrong-shape refusal, pinned in the next test.)
  seed_awaiting
  printf '[]' > "$F"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" \
    --carry-accounting "$(carry_record '["claude-plugin-tests"]' '[]' '[]')"
  [ "$status" -eq 20 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "AWAITING_FIX" ]
  [ "$(jq -c '.carry_unconfirmed' "$BATS_TEST_TMPDIR/st.json")" = "[]" ]
  [ "$(jq '.final_changelist.blocking | length' "$BATS_TEST_TMPDIR/st.json")" -eq 0 ]
  # the stamp: one carried entry, confirmed, spelled exactly as the carry spelled it
  [ "$(jq -c '.round_changelists[1].carry_accounting' "$BATS_TEST_TMPDIR/st.json")" = \
    '{"total":1,"confirmed":[{"file":"app.py","dimension":"bugs","title":"T"}],"re_raised":[],"unconfirmed":[]}' ]
  # AC 4: round 1 carried nothing, and its stamp says so rather than omitting the key
  [ "$(jq -c '.round_changelists[0].carry_accounting' "$BATS_TEST_TMPDIR/st.json")" = \
    '{"total":0,"confirmed":[],"re_raised":[],"unconfirmed":[]}' ]
  # the progress block renders the triple, and only that (the carried: N of the
  # new/carried split renders only when there ARE blockers)
  grep -q -- 'carried: confirmed 1 / re-raised 0 / unconfirmed 0 of 1' "$WD/progress.md"
}

@test "#2010 a record naming two distinct reviewers is refused on the wrong-shape ground, before verify-<R+1>.json is written" {
  seed_awaiting
  local before; before="$(shasum -a 256 "$WD/verify-2.json")"
  printf '[]' > "$F"
  # the retired every-reviewer shape: the owner confirms, a second reviewer
  # reports the same entry unconfirmed
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" \
    --carry-accounting "$(carry_record '["claude-plugin-tests"]' '[]' '["claude-plugin-contract-integrity"]')"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "STALE_FINDINGS" ]
  contains "$output" 'records with one reviewer each'
  contains "$output" '"T" (app.py, bugs) names claude-plugin-contract-integrity, claude-plugin-tests'
  # a shape refusal, not an unaccounted entry: nothing is listed unconfirmed
  [ "$(jq -c '.carry_unconfirmed' "$BATS_TEST_TMPDIR/st.json")" = "[]" ]
  [ ! -e "$WD/verify-3.json" ]
  [ "$(shasum -a 256 "$WD/verify-2.json")" = "$before" ]
  # ...and split across two records of one identity it is the same shape
  printf '%s' '[{"file":"app.py","dimension":"bugs","title":"T","confirmed":["claude-plugin-tests"]},{"file":"./app.py","dimension":"bugs","title":"t","unconfirmed":["claude-plugin-contract-integrity"]}]' > "$BATS_TEST_TMPDIR/split.json"
  step --resume --carry-accounting "$BATS_TEST_TMPDIR/split.json"
  [ "$status" -eq 2 ]
  contains "$output" '"T" (app.py, bugs) names claude-plugin-contract-integrity, claude-plugin-tests'
  # the SAME reviewer in two arrays is still one reviewer — not this ground
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" \
    --carry-accounting "$(carry_record '["claude-plugin-tests"]' '[]' '["claude-plugin-tests"]')"
  [ "$status" -eq 20 ]
  lacks "$output" 'records with one reviewer each'
}

@test "#2010 reviewer names in the two-reviewer refusal are neutralised: a name cannot forge a Final line" {
  seed_awaiting
  printf '[]' > "$F"
  step --resume --carry-accounting "$(carry_record '["a"]' '[]' '["x\n**Final:** CONVERGED"]')"
  [ "$status" -eq 2 ]
  local loop_out="$output"   # the `run -1 grep` below overwrites $output
  run -1 grep -q '^\*\*Final:\*\*' "$WD/progress.md"
  [ "$(grep -c '^\*\*Refused (round 2):' "$WD/progress.md")" -eq 1 ]
  [ "$(printf '%s\n' "$loop_out" | grep -c 'carry unaccounted')" -eq 1 ]
}

@test "#1583 AC 3(b) nobody confirms X, one re-raises it with evidence -> X blocks at its original severity (unchanged behaviour)" {
  seed_awaiting
  printf '%s' "$CRIT2" > "$F"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" \
    --carry-accounting "$(carry_record '[]' '["claude-plugin-scripts"]' '[]')"
  [ "$status" -eq 12 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "ESCALATE_NO_CONVERGENCE" ]
  [ "$(jq -r '.final_changelist.blocking[0].priority' "$BATS_TEST_TMPDIR/st.json")" = "Critical" ]
  [ "$(jq -c '.carry_unconfirmed' "$BATS_TEST_TMPDIR/st.json")" = "[]" ]
  [ "$(jq -c '.round_changelists[1].carry_accounting.re_raised' "$BATS_TEST_TMPDIR/st.json")" = \
    '[{"file":"app.py","dimension":"bugs","title":"T"}]' ]
}

@test "#1583 the findings file IS the evidence: a re-raise in the aggregate counts as re-raised even when the record says unconfirmed" {
  seed_awaiting
  printf '%s' "$CRIT2" > "$F"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" --carry-accounting "$(carry_record '[]' '[]' '["r"]')"
  [ "$status" -eq 12 ]
  [ "$(jq -c '.round_changelists[1].carry_accounting | {re_raised: (.re_raised | length), unconfirmed: (.unconfirmed | length)}' "$BATS_TEST_TMPDIR/st.json")" = \
    '{"re_raised":1,"unconfirmed":0}' ]
}

@test "#1583 AC 3(c) nobody confirms X, one reports it unconfirmed -> refused naming X, carry_unconfirmed lists it, the carry chain survives, and the re-dispatch clears it" {
  seed_awaiting
  local before; before="$(shasum -a 256 "$WD/verify-2.json")"
  printf '[]' > "$F"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" \
    --carry-accounting "$(carry_record '[]' '[]' '["python-bug-hunter"]')"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "STALE_FINDINGS" ]
  contains "$output" 'carry unaccounted: round 2 carried entry "T" (app.py, bugs) was neither confirmed nor re-raised by any reviewer (unconfirmed by: python-bug-hunter)'
  contains "$output" 'verify-3.json was NOT written and verify-2.json remains the carry'
  [ "$(jq -c '.carry_unconfirmed' "$BATS_TEST_TMPDIR/st.json")" = '[{"file":"app.py","dimension":"bugs","title":"T"}]' ]
  # AC 4, never in .blocking: the refused round was consumed by NOTHING — no
  # changelist, no history line — so its unconfirmed entry is a blocking finding
  # of no round. The status JSON's final_changelist is round 1's verdict, the
  # round that RAISED the blocker (that is the carry's origin, not this round):
  # asserted, because this is the first STALE_FINDINGS arm that fires while a
  # changelist for the CURRENT round already exists on disk, and reporting THAT
  # one would show zero blockers beside a carry that still holds the entry
  [ "$(jq '.final_changelist.blocking | length' "$BATS_TEST_TMPDIR/st.json")" -eq 1 ]
  [ "$(jq -r '.final_changelist.blocking[0].title' "$BATS_TEST_TMPDIR/st.json")" = "T" ]
  [ "$(jq '.round_changelists | length' "$BATS_TEST_TMPDIR/st.json")" -eq 1 ]
  [ "$(jq '.rounds' "$BATS_TEST_TMPDIR/st.json")" -eq 1 ]
  [ ! -e "$WD/verify-3.json" ]
  [ "$(shasum -a 256 "$WD/verify-2.json")" = "$before" ]
  grep -q -- '^\*\*Refused (round 2):\*\* stale findings — carry unaccounted: round 2 carried entry "T"' "$WD/progress.md"
  # the recovery: the panel is re-dispatched for that entry, confirms it, and
  # the same --resume is accepted
  step --resume --carry-accounting "$(carry_record '["python-bug-hunter"]' '[]' '[]')"
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -c '.carry_unconfirmed')" = "[]" ]
}

@test "#2008 a script owner: a carried manifest entry confirmed by check-manifests.zsh is accepted, unchanged" {
  # check-manifests.zsh owns the claude-plugin panel's `manifest` dimension, and
  # its --carry-out lines become ordinary per-identity records — the loop's
  # carry accounting takes a script owner exactly as it takes an agent one.
  printf '%s' '[{"severity":"CRITICAL","dimension":"manifest","file":"app.py","line":null,"title":"fixture: content changed with no version bump","description":"d","suggested_fix":"","reviewer":"check-manifests.zsh","round":1}]' > "$F"
  step
  [ "$status" -eq 20 ]
  printf '[]' > "$F"
  local rec="$BATS_TEST_TMPDIR/carry-manifest.json"
  printf '[{"file":"app.py","dimension":"manifest","title":"fixture: content changed with no version bump","confirmed":["check-manifests.zsh"],"re_raised":[],"unconfirmed":[]}]' > "$rec"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" --carry-accounting "$rec"
  [ "$status" -eq 20 ]
  [ "$(jq -c '.carry_unconfirmed' "$BATS_TEST_TMPDIR/st.json")" = "[]" ]
  [ "$(jq '.round_changelists[1].carry_accounting.confirmed | length' "$BATS_TEST_TMPDIR/st.json")" -eq 1 ]
}

@test "#1583 AC 3(d) nobody mentions X at all -> the same refusal, 'no reviewer reported it'" {
  seed_awaiting
  printf '[]' > "$F"
  printf '[]' > "$BATS_TEST_TMPDIR/silent.json"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" --carry-accounting "$BATS_TEST_TMPDIR/silent.json"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "STALE_FINDINGS" ]
  contains "$output" 'carried entry "T" (app.py, bugs) was neither confirmed nor re-raised by any reviewer (no reviewer reported it)'
  [ "$(jq -c '.carry_unconfirmed' "$BATS_TEST_TMPDIR/st.json")" = '[{"file":"app.py","dimension":"bugs","title":"T"}]' ]
  [ ! -e "$WD/verify-3.json" ]
}

@test "#1583 an accounting record naming no carried identity is refused, never silently ignored" {
  seed_awaiting
  printf '[]' > "$F"
  printf '[{"file":"other.py","dimension":"bugs","title":"nope","confirmed":["r"],"re_raised":[],"unconfirmed":[]}]' \
    > "$BATS_TEST_TMPDIR/bad.json"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" --carry-accounting "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
  contains "$output" 'names entries that are not in verify-2.json: "nope" (other.py, bugs)'
  [ ! -e "$WD/verify-3.json" ]
  # the status JSON is typed on this arm too, and lists nothing as unconfirmed
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "STALE_FINDINGS" ]
  [ "$(jq -c '.carry_unconfirmed' "$BATS_TEST_TMPDIR/st.json")" = "[]" ]
}

@test "#1583 a malformed accounting file is refused by shape, naming the shape" {
  seed_awaiting
  printf '[]' > "$F"
  printf '{"confirmed": true}' > "$BATS_TEST_TMPDIR/bad.json"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" --carry-accounting "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
  contains "$output" 'is not an array of {file, dimension, title, confirmed[], re_raised[], unconfirmed[]} records'
  [ ! -e "$WD/verify-3.json" ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "STALE_FINDINGS" ]
  [ "$(jq -c '.carry_unconfirmed' "$BATS_TEST_TMPDIR/st.json")" = "[]" ]
}

@test "#1583 identity matching normalises the title and a ./ file prefix, the way the consolidator does" {
  seed_awaiting
  printf '[]' > "$F"
  printf '[{"file":"./app.py","dimension":"bugs","title":"  t ","confirmed":["r"],"re_raised":[],"unconfirmed":[]}]' \
    > "$BATS_TEST_TMPDIR/norm.json"
  step --resume --carry-accounting "$BATS_TEST_TMPDIR/norm.json"
  [ "$status" -eq 20 ]
}

@test "#1583 AC 4 / AC 7: carry_unconfirmed is always present, round 1 is stamped total 0, and the contract names the arm and the flag" {
  printf '[]' > "$F"
  step
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.carry_unconfirmed')" = "[]" ]
  [ "$(echo "$output" | jq -c '.round_changelists[0].carry_accounting')" = '{"total":0,"confirmed":[],"re_raised":[],"unconfirmed":[]}' ]
  # a round that carried nothing renders no carried fragment
  run -1 grep -q 'carried:' "$WD/progress.md"
  run zsh "$S" --no-review
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.carry_unconfirmed')" = "[]" ]
  # the loop's own contract comment names the arm, and its usage names the flag
  grep -q 'CARRY-UNACCOUNTED' "$LOOP_REAL"
  run zsh "$S" --help
  [ "$status" -eq 0 ]
  contains "$output" '--carry-accounting FILE'
}

@test "#1583 a record-only re-raise is NOT evidence: re_raised in the accounting with no matching finding is refused by name" {
  # the carry is written from .blocking, so an accounting-only re-raise would
  # retire the entry with nothing to carry it forward — the ride-out the arm
  # exists to close. Refused distinctly from an unconfirmed entry.
  seed_awaiting
  printf '[]' > "$F"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" --carry-accounting "$(carry_record '[]' '["claude-plugin-scripts"]' '[]')"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "STALE_FINDINGS" ]
  contains "$output" 'carried entry "T" (app.py, bugs) is re-raised in the accounting by claude-plugin-scripts but the findings file of this round carries no blocking entry at that identity'
  contains "$output" 'the accounting alone is not evidence'
  # ...and the remedy ROUTES (to a panel re-dispatch) rather than licensing a
  # hand edit of the findings file, which the addendum forbids
  contains "$output" 're-dispatch the panel for that entry'
  contains "$output" 'never edit the findings file by hand'
  lacks "$output" 'was neither confirmed nor re-raised'
  [ ! -e "$WD/verify-3.json" ]
  [ "$(jq -c '.carry_unconfirmed' "$BATS_TEST_TMPDIR/st.json")" = "[]" ]
}

@test "#1583 an accounting file that is missing or zero-byte is refused by its own diagnostic" {
  seed_awaiting
  printf '[]' > "$F"
  step --resume --carry-accounting "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 2 ]
  contains "$output" 'which is missing or empty'
  : > "$BATS_TEST_TMPDIR/empty.json"
  step --resume --carry-accounting "$BATS_TEST_TMPDIR/empty.json"
  [ "$status" -eq 2 ]
  contains "$output" 'which is missing or empty'
  [ ! -e "$WD/verify-3.json" ]
}

@test "#1583 a multi-value accounting file is refused by shape, not read by its last value" {
  seed_awaiting
  printf '[]' > "$F"
  printf '[]\n' > "$BATS_TEST_TMPDIR/multi.json"
  cat "$(carry_record '["r"]' '[]' '[]')" >> "$BATS_TEST_TMPDIR/multi.json"
  step --resume --carry-accounting "$BATS_TEST_TMPDIR/multi.json"
  [ "$status" -eq 2 ]
  contains "$output" 'is not an array of {file, dimension, title, confirmed[], re_raised[], unconfirmed[]} records'
}

@test "#1583 identity matching collapses internal whitespace too, and the match is COUNTED confirmed" {
  printf '%s' '[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"T  two","description":"d","reviewer":"r"}]' > "$F"
  step
  [ "$status" -eq 20 ]
  printf '[]' > "$F"
  printf '[{"file":"./app.py","dimension":"bugs","title":"t two","confirmed":["r"],"re_raised":[],"unconfirmed":[]}]' \
    > "$BATS_TEST_TMPDIR/ws.json"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" --carry-accounting "$BATS_TEST_TMPDIR/ws.json"
  [ "$status" -eq 20 ]
  # spelled as the CARRY spelled it, not as the record did
  [ "$(jq -c '.round_changelists[1].carry_accounting.confirmed' "$BATS_TEST_TMPDIR/st.json")" = \
    '[{"file":"app.py","dimension":"bugs","title":"T  two"}]' ]
}

@test "#1583 an explicit [] accounting on an EMPTY-carry round is accepted; a stale non-empty one is refused" {
  seed_awaiting
  printf '[]' > "$F"
  step --resume
  [ "$status" -eq 20 ]                # zero-blocker delta: the closing sweep is promoted, verify-3.json is []
  printf '[]' > "$F"
  printf '[]' > "$BATS_TEST_TMPDIR/none.json"
  printf '[{"file":"app.py","dimension":"bugs","title":"T","confirmed":["r"],"re_raised":[],"unconfirmed":[]}]' \
    > "$BATS_TEST_TMPDIR/stale.json"
  # the stale record first: a carry of [] has no identity for it to name
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$LOOP_REAL" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume \
    --carry-accounting "$BATS_TEST_TMPDIR/stale.json"
  [ "$status" -eq 2 ]
  contains "$output" 'names entries that are not in verify-3.json'
  # the explicit empty array is the documented benign shape
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$LOOP_REAL" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume \
    --carry-accounting "$BATS_TEST_TMPDIR/none.json" --status-file "$BATS_TEST_TMPDIR/st.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "CONVERGED" ]
  [ "$(jq -c '.round_changelists[2].carry_accounting' "$BATS_TEST_TMPDIR/st.json")" = '{"total":0,"confirmed":[],"re_raised":[],"unconfirmed":[]}' ]
}

@test "#1583 a TWO-entry carry: the stamp counts both, the refusal names both, and each owner's report is named" {
  printf '%s' '[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"A","description":"d","reviewer":"r"},{"severity":"WARNING","dimension":"tests","file":"app.py","line":7,"title":"B","description":"d","reviewer":"r"}]' > "$F"
  step
  [ "$status" -eq 20 ]
  [ "$(jq 'length' "$WD/verify-2.json")" -eq 2 ]
  printf '[]' > "$F"
  # A silent, B reported unconfirmed by its owner: both refused, both named
  printf '[{"file":"app.py","dimension":"tests","title":"B","confirmed":[],"re_raised":[],"unconfirmed":["y"]}]' \
    > "$BATS_TEST_TMPDIR/two-unaccounted.json"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" --carry-accounting "$BATS_TEST_TMPDIR/two-unaccounted.json"
  [ "$status" -eq 2 ]
  contains "$output" 'carried entry "A" (app.py, bugs) was neither confirmed nor re-raised by any reviewer (no reviewer reported it); carried entry "B" (app.py, tests) was neither confirmed nor re-raised by any reviewer (unconfirmed by: y)'
  [ "$(jq '.carry_unconfirmed | length' "$BATS_TEST_TMPDIR/st.json")" -eq 2 ]
  [ "$(jq -c '[.carry_unconfirmed[].title]' "$BATS_TEST_TMPDIR/st.json")" = '["A","B"]' ]
  # confirm both: total 2, both under confirmed, nothing else
  printf '[{"file":"app.py","dimension":"bugs","title":"A","confirmed":["x"],"re_raised":[],"unconfirmed":[]},{"file":"app.py","dimension":"tests","title":"B","confirmed":["y"],"re_raised":[],"unconfirmed":[]}]' \
    > "$BATS_TEST_TMPDIR/two-confirmed.json"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" --carry-accounting "$BATS_TEST_TMPDIR/two-confirmed.json"
  [ "$status" -eq 20 ]
  [ "$(jq -c '.round_changelists[1].carry_accounting | {total, c: (.confirmed | length), r: (.re_raised | length), u: (.unconfirmed | length)}' "$BATS_TEST_TMPDIR/st.json")" = \
    '{"total":2,"c":2,"r":0,"u":0}' ]
  grep -q -- 'carried: confirmed 2 / re-raised 0 / unconfirmed 0 of 2' "$WD/progress.md"
}

@test "#1583 --carry-accounting beside --review-cmd is a usage error, not a silently ignored flag" {
  printf '[]' > "$BATS_TEST_TMPDIR/acct.json"
  run zsh "$LOOP_REAL" --repo "$R" --base main --work-dir "$WD" \
    --review-cmd 'true' --fix-cmd 'true' --carry-accounting "$BATS_TEST_TMPDIR/acct.json"
  [ "$status" -eq 2 ]
  contains "$output" '--carry-accounting is step-mode only'
}

@test "#1583 a re-raise at a SHIFTED line still counts as evidence — identity is file, dimension and title, never the proximity window" {
  # a fix pass that inserts more than the consolidator's ten-line window above
  # the defect moves the honest re-raise out of the cross-round match, so the
  # consolidator emits it as a NEW blocker; the accounting must still read it
  # as the carried entry's re-raise, or every honest re-submission is refused
  seed_awaiting                       # carried at line 1
  printf '%s' '[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":40,"title":"T","description":"still there, further down","reviewer":"r"}]' > "$F"
  # no record for T at all: the findings file alone is the evidence
  printf '[]' > "$BATS_TEST_TMPDIR/silent.json"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" --carry-accounting "$BATS_TEST_TMPDIR/silent.json"
  [ "$status" -eq 20 ]
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "AWAITING_FIX" ]
  [ "$(jq -c '.round_changelists[1].carry_accounting.re_raised' "$BATS_TEST_TMPDIR/st.json")" = \
    '[{"file":"app.py","dimension":"bugs","title":"T"}]' ]
  # ...and it carries forward, as a re-raise must
  [ "$(jq -r '.[0].title' "$WD/verify-3.json")" = "T" ]
}

@test "#1583 an unevidenced re-raise and an unconfirmed entry are refused TOGETHER, and carry_unconfirmed lists the unconfirmed one" {
  printf '%s' '[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"A","description":"d","reviewer":"r"},{"severity":"WARNING","dimension":"tests","file":"app.py","line":7,"title":"B","description":"d","reviewer":"r"}]' > "$F"
  step
  [ "$status" -eq 20 ]
  printf '[]' > "$F"
  printf '[{"file":"app.py","dimension":"bugs","title":"A","confirmed":[],"re_raised":["x"],"unconfirmed":[]},{"file":"app.py","dimension":"tests","title":"B","confirmed":[],"re_raised":[],"unconfirmed":["y"]}]' \
    > "$BATS_TEST_TMPDIR/both.json"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" --carry-accounting "$BATS_TEST_TMPDIR/both.json"
  [ "$status" -eq 2 ]
  contains "$output" 'carried entry "A" (app.py, bugs) is re-raised in the accounting by x but the findings file of this round carries no blocking entry at that identity'
  contains "$output" 'carried entry "B" (app.py, tests) was neither confirmed nor re-raised by any reviewer (unconfirmed by: y)'
  # one refusal names both, so the operator needs one round-trip, not two —
  # and the status key lists only the UNCONFIRMED identity (the unevidenced
  # one was accounted for, wrongly)
  [ "$(jq -c '.carry_unconfirmed' "$BATS_TEST_TMPDIR/st.json")" = '[{"file":"app.py","dimension":"tests","title":"B"}]' ]
  [ ! -e "$WD/verify-3.json" ]
}

@test "#1583 a failed carry_accounting stamp write aborts the round by name, leaving the changelist valid and unstamped" {
  seed_awaiting
  printf '[]' > "$F"
  # a directory at the temp path the stamp is written through
  mkdir -p "$WD/changelist-2.json.carry-tmp"
  step --resume --carry-accounting "$(carry_record '["r"]' '[]' '[]')"
  [ "$status" -eq 1 ]
  contains "$output" 'could not stamp carry_accounting into the round 2 changelist'
  # the changelist the consolidator wrote survives, unstamped — never a half-written one
  jq -e 'has("carry_accounting") | not' "$WD/changelist-2.json" >/dev/null
  # ...and neither the accumulators nor the next carry moved
  [ ! -e "$WD/verify-3.json" ]
  [ "$(wc -l < "$WD/changelists.jsonl" | tr -d ' ')" -eq 1 ]
}

@test "#1583 --carry-accounting beside --no-review is a usage error too — the fast path would ignore it just as silently" {
  printf '[]' > "$BATS_TEST_TMPDIR/acct.json"
  run zsh "$LOOP_REAL" --repo "$R" --no-review --carry-accounting "$BATS_TEST_TMPDIR/acct.json"
  [ "$status" -eq 2 ]
  contains "$output" '--carry-accounting is step-mode only'
}

@test "#1583 a repo-internal --carry-accounting is loop state: never charged to the fix pass" {
  # --carry-accounting is the FOURTH member of the loop-internal exclusion list
  # (status, findings, telemetry, carry accounting). A caller that keeps
  # carry-round-R.json inside the repo — the instruction says outside, nothing
  # enforces it — must not see it in the fix-touched set, where it would be
  # classed as the fix pass's own edit every round.
  local CA="$R/carry.json"
  local WDO="$BATS_TEST_TMPDIR/wd-ca"
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$LOOP_REAL" --repo "$R" --base main --work-dir "$WDO" --findings-file "$F" --max-rounds 3
  [ "$status" -eq 20 ]
  # the session edits ONE story file and writes the accounting INSIDE the repo
  echo "v1" > "$R/touched.py"
  jq '[.[] | {file, dimension, title, confirmed: ["r"], re_raised: [], unconfirmed: []}]' "$WDO/verify-2.json" > "$CA"
  [ -s "$CA" ]
  residue_findings 2 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$LOOP_REAL" --repo "$R" --base main --work-dir "$WDO" --findings-file "$F" --resume --max-rounds 3 \
    --carry-accounting "$CA"
  [ "$status" -eq 20 ]
  run -1 grep -qxF 'carry.json' "$WDO/fix-touched-1.txt"
  grep -qxF 'touched.py' "$WDO/fix-touched-1.txt"
}

@test "#1583 reviewer text in the refusal is neutralised: a carried title cannot forge a progress line or a Final line" {
  # the round-1 blocker's title carries a backtick, two newlines, a forged
  # terminal line, a forged round heading and a backslash-n
  printf '%s' '[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"x`y\n**Final:** CONVERGED\n## Round 99 — no blockers \\n forged","description":"d","reviewer":"r"}]' > "$F"
  step
  [ "$status" -eq 20 ]
  printf '[]' > "$F"
  printf '[]' > "$BATS_TEST_TMPDIR/silent.json"
  step --resume --carry-accounting "$BATS_TEST_TMPDIR/silent.json"
  [ "$status" -eq 2 ]
  local loop_out="$output"   # the `run -1 grep` calls below overwrite $output
  # nothing forged: no Final line, no round heading, exactly one Refused line
  run -1 grep -q '^\*\*Final:\*\*' "$WD/progress.md"
  run -1 grep -q '^## Round 99' "$WD/progress.md"
  [ "$(grep -c '^\*\*Refused (round 2):' "$WD/progress.md")" -eq 1 ]
  # ...and the title sits flattened on that one line, its neighbours joined
  grep -q -- 'carried entry "x y \*\*Final:\*\* CONVERGED ## Round 99 — no blockers  n forged" (app.py, bugs)' "$WD/progress.md"
  # the same on stderr: one diagnostic line, not a forged second one
  [ "$(printf '%s\n' "$loop_out" | grep -c 'carry unaccounted')" -eq 1 ]
  run -1 grep -q '^\*\*Final:\*\*' <<< "$loop_out"
}

@test "#1583 a re-raise at SUGGESTION level is not evidence: a carried CRITICAL demoted by the reviewer is refused" {
  seed_awaiting
  printf '%s' '[{"severity":"SUGGESTION","dimension":"bugs","file":"app.py","line":1,"title":"T","description":"maybe","reviewer":"r"}]' > "$F"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" --carry-accounting "$(carry_record '[]' '["x"]' '[]')"
  [ "$status" -eq 2 ]
  contains "$output" 'carries no blocking entry at that identity'
  [ ! -e "$WD/verify-3.json" ]
}

# a work-dir one AWAITING_FIX round deep whose one blocker is a WARNING — the
# only severity the risk pass may demote — at the identity carry_record names
seed_awaiting_warning() {
  printf '%s' '[{"severity":"WARNING","dimension":"bugs","file":"app.py","line":1,"title":"T","description":"d","reviewer":"r"}]' > "$F"
  step
  [ "$status" -eq 20 ]
}

@test "a re-raise the risk pass demoted is evidence: the carried WARNING retires as demoted, not CARRY-UNACCOUNTED" {
  seed_awaiting_warning
  export corner_case_risk_threshold=0.05
  printf '%s' '[{"severity":"WARNING","dimension":"bugs","file":"app.py","line":1,"title":"T","description":"still there","reviewer":"x"}]' > "$F"
  printf '%s' '[{"file":"app.py","line":1,"dimension":"bugs","title":"T","p":0.01,"p_why":"needs out-of-order events","impact":0.4,"impact_why":"a stale label"}]' > "$BATS_TEST_TMPDIR/risk-2.json"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" --risk "$BATS_TEST_TMPDIR/risk-2.json" \
    --carry-accounting "$(carry_record '[]' '["x"]' '[]')"
  [ "$status" -eq 20 ]
  lacks "$output" 'carry unaccounted'
  [ "$(jq -c '.round_changelists[1].carry_accounting' "$BATS_TEST_TMPDIR/st.json")" = \
    '{"total":1,"confirmed":[],"re_raised":[],"unconfirmed":[],"demoted":[{"file":"app.py","dimension":"bugs","title":"T"}]}' ]
  # retired: nothing blocks, so nothing is carried into round 3
  [ "$(jq 'length' "$WD/verify-3.json")" -eq 0 ]
  grep -q -- 'carried: confirmed 0 / re-raised 0 / unconfirmed 0 / demoted by risk 1 of 1' "$WD/progress.md"
}

@test "a risk-demoted finding at ANOTHER identity is not evidence for the carried entry: still refused" {
  seed_awaiting_warning
  export corner_case_risk_threshold=0.05
  printf '%s' '[{"severity":"WARNING","dimension":"bugs","file":"app.py","line":1,"title":"another defect","description":"d","reviewer":"x"}]' > "$F"
  printf '%s' '[{"file":"app.py","line":1,"dimension":"bugs","title":"another defect","p":0.01,"p_why":"rare","impact":0.4,"impact_why":"minor"}]' > "$BATS_TEST_TMPDIR/risk-2.json"
  step --resume --risk "$BATS_TEST_TMPDIR/risk-2.json" --carry-accounting "$(carry_record '[]' '["x"]' '[]')"
  [ "$status" -eq 2 ]
  contains "$output" 'carries no blocking entry at that identity'
  [ ! -e "$WD/verify-3.json" ]
}

@test "#1583 a confirmation outranks an unevidenced re-raise: the owner confirms X and claims a re-raise nobody filed -> accepted, X retired as confirmed" {
  # The ordered ladder is confirmed > re_raised > unevidenced > unconfirmed.
  # Every other fixture keeps confirmed[] and re_raised[] disjoint, so the
  # precedence between the first rung and the third was never observed: a
  # reorder that tests the record-only re-raise BEFORE the confirmation would
  # refuse this round as CARRY-UNACCOUNTED. Since #2010 a record names one
  # owner, so the two rungs meet in that owner's record (two reviewers here
  # would be the wrong-shape refusal instead).
  seed_awaiting
  printf '[]' > "$F"
  step --resume --status-file "$BATS_TEST_TMPDIR/st.json" \
    --carry-accounting "$(carry_record '["a"]' '["a"]' '[]')"
  [ "$status" -eq 20 ]
  lacks "$output" 'is re-raised in the accounting by'
  lacks "$output" 'carry unaccounted'
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/st.json")" = "AWAITING_FIX" ]
  [ "$(jq -c '.round_changelists[1].carry_accounting' "$BATS_TEST_TMPDIR/st.json")" = \
    '{"total":1,"confirmed":[{"file":"app.py","dimension":"bugs","title":"T"}],"re_raised":[],"unconfirmed":[]}' ]
  [ -s "$WD/verify-3.json" ]
}

@test "#1583 the refusal line is written raw: a caller path holding a backslash escape survives to the remedy" {
  # `safe` neutralises REVIEWER text; a caller PATH ($src) is interpolated as
  # is, so only the sink's -r keeps a `\c` in it from swallowing the rest of
  # the line — including the `verify-<R+1>.json was NOT written` remedy the
  # conductor recovers by. Without -r both needles below vanish from stderr.
  seed_awaiting
  printf '[]' > "$F"
  step --resume --carry-accounting "$BATS_TEST_TMPDIR/a\\cb.json"
  [ "$status" -eq 2 ]
  contains "$output" 'a\cb.json, which is missing or empty'
  contains "$output" 'verify-3.json was NOT written'
  # ...and the progress.md copy of the same detail is written raw as well
  grep -qF -- 'a\cb.json, which is missing or empty' "$WD/progress.md"
  [ ! -e "$WD/verify-3.json" ]
}

# --- #1498: the one-shot all-ambiguous auto-continue ---------------------------
#
# ONE fixture shape, defined once, so a half-applied edit cannot make the
# positive and the veto cases exercise different things. Round 1 raises two
# WARNINGs 55 lines apart — further than LINEWIN (10), so neither can ever
# gather the other's prior and the one-to-one attribution is unambiguous. Round 2
# raises two more, each three lines from its OWN prior and each sharing
# significant (>= 4-char) tokens with it without matching it exactly. That is
# precisely the AMBIGUOUS verdict: not a verified survivor (no exact title), not
# a #983 disjoint false trip (tokens are shared).
#
# WARNING, never CRITICAL: a Critical anywhere in the carried set vetoes the
# rung, which the veto test below drives on purpose.
#
# Round 1's first title is deliberately NOT already normalised — mixed case, a
# double space, and a literal tab. The marker records `normtitle`, so the
# expected content below stays lower-cased and single-spaced, which is what
# makes the `diff` kill a lost `ascii_downcase`, a lost `gsub("\\s+"; " ")`, and
# a tab reaching the marker (where it would forge a fourth field and break the
# `cut -f2-` round-trip the one-shot bound depends on). With every fixture title
# pre-normalised, all three of those deletions passed the suite.
pft_round1='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":5,\"title\":\"Unquoted  Variable\\tIn The Matcher\",\"description\":\"d1\",\"reviewer\":\"r\"},{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":60,\"title\":\"missing timeout on the fetch helper\",\"description\":\"d1\",\"reviewer\":\"r\"}]'
pft_round2='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":8,\"title\":\"unquoted variable in the dispatcher\",\"description\":\"d2\",\"reviewer\":\"r\"},{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":63,\"title\":\"missing timeout on the upload helper\",\"description\":\"d2\",\"reviewer\":\"r\"}]'

# The marker this run should write, in full. Asserted as CONTENT rather than as
# a line count: the identity rule (#1498) records BOTH titles of every match —
# the item's own and its matched prior's — so a per-item count would pass on an
# implementation that recorded only one of them, which is exactly the hole a
# re-wording would then walk through. `unique` inside the loop sorts them, so
# the expected order is lexicographic.
pft_expected_marker() {   # $1 = the round that continued
  printf '%s\tapp.py\ttests\tmissing timeout on the fetch helper\n' "$1"
  printf '%s\tapp.py\ttests\tmissing timeout on the upload helper\n' "$1"
  printf '%s\tapp.py\ttests\tunquoted variable in the dispatcher\n' "$1"
  printf '%s\tapp.py\ttests\tunquoted variable in the matcher\n' "$1"
}

# `$1` is the round-3 findings document (escaped for the printf inside the hook);
# rounds 4+ are always clean, so a run that gets past round 3 converges rather
# than drifting into the budget and reporting the wrong terminal for the wrong
# reason.
pft_review() {  # $1 = round-3 findings (default: none)
  local r3="${1:-[]}"
  printf '%s' 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "'"$pft_round1"'" > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 2 ]; then printf "%s" "'"$pft_round2"'" > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 3 ]; then printf "%s" "'"$r3"'" > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi'
}

@test "#1498 tc-happy-possible-false-trip-auto-continue: an all-ambiguous carried set continues instead of exiting 12" {
  loop --review-cmd "$(pft_review)" --fix-cmd 'true'
  # the run did NOT stop at round 2 — it took the round it already had and then
  # converged on the clean round 3
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  # ...and round 2 really was the state this rung is about: two carried matches,
  # both ambiguous, no Critical. Without this the test would pass on a run that
  # never reached the rung at all.
  echo "$output" | jq -e '.round_changelists[1].non_converging == true' >/dev/null
  echo "$output" | jq -e '[.round_changelists[1].blocking[]
      | select(.non_converging == true)] | length == 2' >/dev/null
  echo "$output" | jq -e '[.round_changelists[1].blocking[]
      | select(.non_converging == true)] | (length > 0) and all(.possible_false_trip == true)' >/dev/null
  echo "$output" | jq -e '.round_changelists[1].summary.critical == 0' >/dev/null
  # the count is of CONTINUATIONS, not identities: four records, one round
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  diff <(pft_expected_marker 2) "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
  # ...and exactly four records. A lost whitespace collapse would split round 1's
  # tab-bearing title into an extra field rather than adding a line, so the diff
  # above is what catches that; this catches the reverse — a normalisation that
  # merges or drops one of the four identities.
  [ "$(wc -l < "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued" | tr -d ' ')" -eq 4 ]
}

@test "#1498 the continued round says so in progress.md, distinctly from #983's line" {
  loop --review-cmd "$(pft_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  local r2
  r2="$(awk '/^## Round 2 /{f=1} f{print} /^## Round 3 /{exit}' "$BATS_TEST_TMPDIR/wd/progress.md")"
  # the per-blocker line carries the marker, on BOTH carried matches
  [ "$(grep -c -- '- possible false trip auto-continued (#1498):' <<< "$r2")" -eq 2 ]
  # ...and the round verdict says the run continued without a grant
  grep -q 'auto-continued once, no grant consumed (#1498)' <<< "$r2"
  # #983's line is for a DISJOINT-title match, which this round has none of —
  # so the two must not be collapsible into one another
  run ! grep -q -- '- false trip auto-continued (#983):' <<< "$r2"
}

@test "#1498 tc-error-second-ambiguous-match: a recorded identity is refused, and the rung escalates" {
  # Round 3 re-raises a title the marker already holds. Its own normalised title
  # IS recorded, so the one-shot bound refuses and the round ends
  # ESCALATE_NO_CONVERGENCE (residue caught the rung from #1571 until #2580).
  local r3='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":11,\"title\":\"unquoted variable in the matcher\",\"description\":\"d3\",\"reviewer\":\"r\"}]'
  loop --review-cmd "$(pft_review "$r3")" --fix-cmd 'true'
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  # round 3 really was another ambiguous carried match — otherwise this pins the
  # wrong thing entirely
  echo "$output" | jq -e '[.round_changelists[2].blocking[]
      | select(.non_converging == true)] | (length > 0) and all(.possible_false_trip == true)' >/dev/null
  # the count did not move, and neither did the marker
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  diff <(pft_expected_marker 2) "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
  # ...and the round that ENDS the run renders the PLAIN line. Without this the loop's
  # `(( pftc )) &&` flag guard is only tested positively: pass the flag
  # unconditionally and every other assertion here still holds, while progress.md
  # tells the human the run continued on a round that in fact stopped.
  local r3
  r3="$(awk '/^## Round 3 /{f=1} f{print}' "$BATS_TEST_TMPDIR/wd/progress.md")"
  grep -q -- '- possible false trip: `app.py:11`' <<< "$r3"
  lacks "$r3" 'possible false trip auto-continued (#1498)'
  lacks "$r3" 'continued once without a human grant'
}

@test "#1498 tc-corner-marker-identity-matched-prior-title: a rewording buys no second continuation" {
  # Round 3's OWN title is fresh — nothing in the marker matches it — but the
  # prior it matched is recorded. Recording only the current title would let the
  # very re-wording that makes a match ambiguous earn an unbounded run of free
  # rounds, one new synonym at a time.
  local r3='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":11,\"title\":\"unquoted variable in the resolver\",\"description\":\"d3\",\"reviewer\":\"r\"}]'
  loop --review-cmd "$(pft_review "$r3")" --fix-cmd 'true'
  [ "$status" -eq 12 ]
  # ...and it really was the matched_prior half that refused: round 3 matched
  # the prior the marker holds. Read BEFORE the `run !` below, which replaces
  # $output with grep's.
  echo "$output" | jq -e '.round_changelists[2].blocking[0].matched_prior.title == "unquoted variable in the dispatcher"' >/dev/null
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  grep -qF 'app.py	tests	unquoted variable in the dispatcher' \
    "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
  # the round-3 title itself is absent from the marker, so nothing but the
  # matched_prior half can have produced the refusal
  run ! grep -qF 'unquoted variable in the resolver' \
    "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
}

@test "#1498 tc-error-mixed-carried-set: one exact-title match vetoes the free round, and the rung escalates" {
  # Round 2 re-raises the second blocker VERBATIM at its own line: an exact
  # normalised-title match, which is a verified survivor (possible_false_trip
  # false). "Every carried match is ambiguous" is then false, and the rung must
  # not fire on a genuinely stuck blocker, so the round escalates.
  local r2='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":8,\"title\":\"unquoted variable in the dispatcher\",\"description\":\"d2\",\"reviewer\":\"r\"},{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":60,\"title\":\"missing timeout on the fetch helper\",\"description\":\"d2\",\"reviewer\":\"r\"}]'
  loop --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "'"$pft_round1"'" > "$REVIEW_FINDINGS"; else printf "%s" "'"$r2"'" > "$REVIEW_FINDINGS"; fi' \
       --fix-cmd 'true'
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  # the mix really is a mix: one ambiguous, one verified
  echo "$output" | jq -e '[.round_changelists[1].blocking[]
      | select(.non_converging == true) | .possible_false_trip] | sort == [false, true]' >/dev/null
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued" ]
}

@test "#1498 tc-error-critical-in-carried-set-escalates: a Critical among the ambiguous matches vetoes" {
  local one='[{\"severity\":\"CRITICAL\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":5,\"title\":\"unquoted variable in the matcher\",\"description\":\"d1\",\"reviewer\":\"r\"}]'
  local two='[{\"severity\":\"CRITICAL\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":8,\"title\":\"unquoted variable in the dispatcher\",\"description\":\"d2\",\"reviewer\":\"r\"}]'
  loop --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "'"$one"'" > "$REVIEW_FINDINGS"; else printf "%s" "'"$two"'" > "$REVIEW_FINDINGS"; fi' \
       --fix-cmd 'true'
  [ "$status" -eq 12 ]
  # the carried match IS ambiguous — the ONLY thing separating this from the
  # happy case is the severity, which is what makes it a test of the veto
  echo "$output" | jq -e '[.round_changelists[1].blocking[]
      | select(.non_converging == true)] | (length > 0) and all(.possible_false_trip == true)' >/dev/null
  echo "$output" | jq -e '.round_changelists[1].summary.critical == 1' >/dev/null
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued" ]
}

@test "#1498 tc-corner-critical-outside-carried-set-auto-continues: the veto is per-match, not round-wide" {
  # A fresh Critical that is NOT part of the ambiguity (non_converging false) has
  # nothing to do with whether the cross-round match is a proximity artifact, so
  # it must not veto. `other.py` exists before the loop starts, so a finding in
  # it survives scope-findings (which scopes against the story diff).
  echo "print(2)" > "$R/other.py"
  local r2='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":8,\"title\":\"unquoted variable in the dispatcher\",\"description\":\"d2\",\"reviewer\":\"r\"},{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"other.py\",\"line\":200,\"title\":\"brand new unrelated defect here\",\"description\":\"d2\",\"reviewer\":\"q\"}]'
  local one='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":5,\"title\":\"unquoted variable in the matcher\",\"description\":\"d1\",\"reviewer\":\"r\"}]'
  loop --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "'"$one"'" > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 2 ]; then printf "%s" "'"$r2"'" > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
       --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # the Critical really was there, and really was outside the carried set
  echo "$output" | jq -e '.round_changelists[1].summary.critical == 1' >/dev/null
  echo "$output" | jq -e '[.round_changelists[1].blocking[]
      | select(.priority == "Critical")] | (length > 0) and all(.non_converging == false)' >/dev/null
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  # The marker's CONTENT, not merely its existence — which is the other half of
  # this test's thesis. The out-of-set Critical must not be given a bound
  # either: `_pft_identities` enumerates the carried set, so dropping its
  # `select(.non_converging == true)` would record `other.py` too, and a bare
  # `-s` cannot see that. The cost of missing it is the rung silently ceasing to
  # fire on any run that also carries unrelated fresh findings.
  local M="$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
  diff <(printf '2\tapp.py\ttests\tunquoted variable in the dispatcher\n2\tapp.py\ttests\tunquoted variable in the matcher\n') "$M"
  run ! grep -qF 'other.py' "$M"
}

@test "#1498 tc-corner-at-ceiling-no-auto-continue: the ceiling stands, and never as a bare-status exit 1" {
  # `round < effective_max` is load-bearing rather than decorative: the while
  # loop exited with an EMPTY loop_status falls through to the exit case's
  # catch-all and emits a bare-status exit 1 — an operational failure, not a
  # terminal. So this asserts the CODE as much as the absence of the marker.
  loop --max-rounds 2 --review-cmd "$(pft_review)" --fix-cmd 'true'
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  # the round really did carry an all-ambiguous set — the ceiling is the ONLY
  # thing that refused it
  echo "$output" | jq -e '[.round_changelists[1].blocking[]
      | select(.non_converging == true)] | (length > 0) and all(.possible_false_trip == true)' >/dev/null
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued" ]
  # ...and the round renders the PLAIN line: a ceiling refusal is still a
  # refusal, so progress.md must not claim a continuation happened
  local r2
  r2="$(awk '/^## Round 2 /{f=1} f{print}' "$BATS_TEST_TMPDIR/wd/progress.md")"
  grep -q -- '- possible false trip: `app.py:8`' <<< "$r2"
  lacks "$r2" 'possible false trip auto-continued (#1498)'
}

@test "#1498 tc-corner-ceiling-unmutated: an auto-continue is not a grant" {
  loop --max-rounds 4 --review-cmd "$(pft_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  # the ceiling the caller passed is what gets reported, the closing-sweep grant
  # is untouched, and the run ended no later than that ceiling
  [ "$(echo "$output" | jq '.max_rounds')" -eq 4 ]
  [ "$(echo "$output" | jq -r '.closing_sweep_granted')" = "false" ]
  echo "$output" | jq -e '.rounds <= .max_rounds' >/dev/null
}

@test "#1498 an auto-continued run still runs OUT of budget on time — the ceiling is observed, not assumed" {
  # The reported `max_rounds` is the caller's value by construction, so asserting
  # it can never see `effective_max`. This drives a run to the ceiling instead:
  # round 2 auto-continues, round 3 IS the ceiling and exhausts the budget. Add
  # `(( effective_max++ ))` beside the auto-continue and the run reaches round 4,
  # so the exact round count and the terminal both red — which is what makes
  # "a CONTINUE, not a grant" a tested claim rather than a stated one.
  echo "print(2)" > "$R/other.py"
  local one='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":5,\"title\":\"unquoted variable in the matcher\",\"description\":\"d1\",\"reviewer\":\"r\"}]'
  local two='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":8,\"title\":\"unquoted variable in the dispatcher\",\"description\":\"d2\",\"reviewer\":\"r\"}]'
  # a genuinely different blocker: another file, and no shared significant token
  local three='[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"other.py\",\"line\":200,\"title\":\"stale cache never invalidated\",\"description\":\"d3\",\"reviewer\":\"q\"}]'
  loop --max-rounds 3 \
    --review-cmd 'case "$REVIEW_ROUND" in 1) printf "%s" "'"$one"'" > "$REVIEW_FINDINGS" ;; 2) printf "%s" "'"$two"'" > "$REVIEW_FINDINGS" ;; *) printf "%s" "'"$three"'" > "$REVIEW_FINDINGS" ;; esac' \
    --fix-cmd 'true'
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  # EXACTLY the ceiling, not merely within it
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 3 ]
  [ "$(echo "$output" | jq -r '.closing_sweep_granted')" = "false" ]
  # ...and the auto-continue really did happen on the way, so the run reached the
  # ceiling THROUGH the rung rather than never touching it
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
}

@test "#1498 tc-corner-null-line-file-wide-match: a file-wide match auto-continues on a line-independent identity" {
  # `line: null` is the documented file-wide wildcard: it gathers against every
  # candidate in its file+dimension. The identity is file/dimension/normtitle, so
  # it carries no line either — which is what keeps the one-shot bound working
  # for a match that has no line to be near.
  local one='[{\"severity\":\"WARNING\",\"dimension\":\"resilience\",\"file\":\"app.py\",\"line\":null,\"title\":\"outbound call has no breaker\",\"description\":\"d1\",\"reviewer\":\"r\"}]'
  local two='[{\"severity\":\"WARNING\",\"dimension\":\"resilience\",\"file\":\"app.py\",\"line\":null,\"title\":\"outbound call has no timeout\",\"description\":\"d2\",\"reviewer\":\"r\"}]'
  local three='[{\"severity\":\"WARNING\",\"dimension\":\"resilience\",\"file\":\"app.py\",\"line\":null,\"title\":\"outbound call has no fallback\",\"description\":\"d3\",\"reviewer\":\"r\"}]'
  loop --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "'"$one"'" > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 2 ]; then printf "%s" "'"$two"'" > "$REVIEW_FINDINGS"; else printf "%s" "'"$three"'" > "$REVIEW_FINDINGS"; fi' \
       --fix-cmd 'true'
  # round 2 auto-continued; round 3 matched a RECORDED identity (round 2's own
  # title, which is round 3's matched prior) and was refused a second
  # continuation, so the rung escalates
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  echo "$output" | jq -e '.round_changelists[1].blocking[0].line == null' >/dev/null
  echo "$output" | jq -e '[.round_changelists[1].blocking[]
      | select(.non_converging == true)] | (length > 0) and all(.possible_false_trip == true)' >/dev/null
  grep -qF 'app.py	resilience	outbound call has no timeout' \
    "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
}

@test "#1498 tc-corner-status-key-always-present: an integer on every terminal, 0 when nothing continued" {
  clean_loop
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.possible_false_trip_auto_continues == 0' >/dev/null
  budget_loop
  [ "$status" -eq 13 ]
  echo "$output" | jq -e '.possible_false_trip_auto_continues == 0' >/dev/null
  # ...and it is an INTEGER, not a string or a null, so a consumer never has to
  # tell 0 from a status file predating the key
  echo "$output" | jq -e '(.possible_false_trip_auto_continues | type) == "number"' >/dev/null
  stuck_loop
  [ "$status" -eq 12 ]
  echo "$output" | jq -e '.possible_false_trip_auto_continues == 0' >/dev/null
}

@test "#1498 tc-corner-history-no-new-key: the per-round history line gains NO auto-continue key" {
  loop --review-cmd "$(pft_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  H="$BATS_TEST_TMPDIR/wd/history.jsonl"
  # the six legitimate keys are all still there...
  jq -es 'all(.[]; has("round") and has("blocking") and has("conflicts")
                   and has("non_converging") and has("false_trips")
                   and has("gate"))' "$H" >/dev/null
  # ...and nothing #1498-derived joined them. A REGEX FAMILY over the key names
  # rather than a guess-list of literals, for the reason #1435 records: a fifth
  # spelling would slip straight through a closed list. Still not a closed KEY
  # SET (#1463) — a sibling may legitimately add its own key.
  jq -es 'all(.[]; [keys[] | select(test("continu|auto|possible"))] | length == 0)' "$H" >/dev/null
}

@test "#1498 the history-line regex family really catches an auto-continue-derived key" {
  # Non-vacuity for the negative above: a regex nobody can trip passes forever.
  local probe="$BATS_TEST_TMPDIR/history-probe-1498.jsonl"
  local k
  for k in possible_false_trip_auto_continues auto_continued continued possible_false_trips; do
    jq -nc --arg k "$k" '{round:1, blocking:0, conflicts:0, non_converging:false,
                          false_trips:0, gate:null} + {($k): 1}' > "$probe"
    jq -es 'all(.[]; [keys[] | select(test("continu|auto|possible"))] | length == 0)' \
      "$probe" >/dev/null && { echo "family missed the key: $k"; return 1; }
  done
  # ...and it does not red on the six legitimate keys, so it filters rather than
  # refusing everything
  jq -nc '{round:1, blocking:0, conflicts:0, non_converging:false,
           false_trips:0, gate:null}' > "$probe"
  jq -es 'all(.[]; [keys[] | select(test("continu|auto|possible"))] | length == 0)' "$probe" >/dev/null
}

@test "#1498 tc-error-unstamped-changelist: an absent per-item flag is never read as a pass, and the rung escalates" {
  # The rung reuses the `$stamped` predicate its four sibling surfaces use, and
  # the reason it must is that an UNSTAMPED changelist cannot be distinguished
  # from an all-ambiguous one by reading `.possible_false_trip` alone: both
  # answer "not true" for every item. Reading absence as a pass would
  # auto-continue a round nothing classified.
  #
  # The current consolidator always stamps, so the state is reachable only from
  # an older or a foreign producer. Driven here by running the loop out of a COPY
  # of its scripts directory whose consolidator strips the per-item stamp — no
  # production seam, and `${0:A:h}` resolves to the copy, so every sibling the
  # loop calls comes from it too.
  local dir="$BATS_TEST_TMPDIR/unstamped-scripts"
  cp -R "${LOOP_REAL%/*}" "$dir"
  cat > "$dir/consolidate-findings.zsh" <<EOF
#!/usr/bin/env zsh
"$REPO_ROOT/development/skills/resolve-issue/scripts/consolidate-findings.zsh" "\$@" \\
  | jq -c '.blocking |= map(del(.non_converging))'
EOF
  chmod +x "$dir/consolidate-findings.zsh"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$dir/resolve-story-loop.zsh" --repo "$R" --base main \
    --work-dir "$BATS_TEST_TMPDIR/wdu" \
    --review-cmd "\"\$CARRY_ALL\"; $(pft_review)" --fix-cmd 'true'
  # (the COPY is invoked directly, not through the $S wrapper, so the
  # confirm-all prelude is spelled out here)
  [ "$status" -eq 12 ]
  # The copy sits at a different depth, so the loop cannot reach the telemetry
  # emitter by its relative path and says so on stderr — best-effort, swallowed,
  # and the run is unaffected. `grep '^{'` isolates the status JSON from that
  # note, the same idiom the #1434 hook-mode tests above use.
  local st
  st="$(echo "$output" | grep '^{')"
  # The stamp gate REFUSES the auto-continue — the subject of this test — and the
  # rung escalates (#1571's residue catch went with the terminal in #2580).
  [ "$(echo "$st" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  # the continuation really was refused, or the fall-through proves nothing
  [ "$(echo "$st" | jq '.possible_false_trip_auto_continues')" -eq 0 ]
  # the stripping really happened — otherwise this is just the happy path
  # asserting the wrong thing
  echo "$st" | jq -e '[.round_changelists[1].blocking[] | has("non_converging")] | (length > 0) and (map(.) | any | not)' >/dev/null
  # ...and the round WAS the all-ambiguous shape underneath: the surviving
  # per-item flag still says so, which is exactly why the stamp gate has to be
  # what decides
  echo "$st" | jq -e '[.round_changelists[1].blocking[] | .possible_false_trip] | (length > 0) and all' >/dev/null
  [ "$(echo "$st" | jq '.possible_false_trip_auto_continues')" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/wdu/.possible-false-trip-continued" ]
}

@test "#1498 a fresh run clears a previous run's marker rather than inheriting its bound" {
  # The marker is per-RUN state, like .closing-sweep: a re-used
  # work-dir must not let a previous run's identities deny THIS run the
  # continuation it has not spent, nor let its rounds inflate the reported count.
  mkdir -p "$BATS_TEST_TMPDIR/wd"
  printf '9\tapp.py\ttests\tunquoted variable in the dispatcher\n' \
    > "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
  loop --review-cmd "$(pft_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  # the planted record would have refused round 2 had it survived
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  diff <(pft_expected_marker 2) "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
}

@test "#1498 the bound is per IDENTITY, not per run: a second, disjoint all-ambiguous carry continues too" {
  # Without this, once-per-identity and once-per-RUN are indistinguishable —
  # `(( pft_continues == 0 )) || return 1` at the top of _pft_auto_continue, or a
  # `pft_continues=1` in place of the derivation, would pass every other test
  # here. Two ambiguous pairs in DIFFERENT files, far apart in the run: rounds
  # 1->2 continue on app.py, rounds 3->4 continue on other.py, round 5 is clean.
  echo "print(2)" > "$R/other.py"
  local a1='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":5,\"title\":\"unquoted variable in the matcher\",\"description\":\"d1\",\"reviewer\":\"r\"}]'
  local a2='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":8,\"title\":\"unquoted variable in the dispatcher\",\"description\":\"d2\",\"reviewer\":\"r\"}]'
  local b3='[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"other.py\",\"line\":40,\"title\":\"retry budget never decremented\",\"description\":\"d3\",\"reviewer\":\"q\"}]'
  local b4='[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"other.py\",\"line\":43,\"title\":\"retry budget never inspected\",\"description\":\"d4\",\"reviewer\":\"q\"}]'
  loop --max-rounds 6 \
    --review-cmd 'case "$REVIEW_ROUND" in 1) printf "%s" "'"$a1"'" > "$REVIEW_FINDINGS" ;; 2) printf "%s" "'"$a2"'" > "$REVIEW_FINDINGS" ;; 3) printf "%s" "'"$b3"'" > "$REVIEW_FINDINGS" ;; 4) printf "%s" "'"$b4"'" > "$REVIEW_FINDINGS" ;; *) printf "[]" > "$REVIEW_FINDINGS" ;; esac' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 5 ]
  # BOTH ambiguous rounds really were the rung's state — round 3 is a fresh
  # blocker in another file, so it carries nothing
  echo "$output" | jq -e '[.round_changelists[1].blocking[] | select(.non_converging == true)] | (length == 1) and all(.possible_false_trip == true)' >/dev/null
  echo "$output" | jq -e '.round_changelists[2].non_converging == false' >/dev/null
  echo "$output" | jq -e '[.round_changelists[3].blocking[] | select(.non_converging == true)] | (length == 1) and all(.possible_false_trip == true)' >/dev/null
  # TWO continuations, on two distinct rounds — the count is of continuations
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 2 ]
  local M="$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
  [ "$(cut -f1 "$M" | sort -u | tr '\n' ' ')" = "2 4 " ]
  # ...and all four identities are recorded, both titles of each match
  grep -qF 'app.py	tests	unquoted variable in the matcher' "$M"
  grep -qF 'app.py	tests	unquoted variable in the dispatcher' "$M"
  grep -qF 'other.py	bugs	retry budget never decremented' "$M"
  grep -qF 'other.py	bugs	retry budget never inspected' "$M"
}

# --- #1498: the one-shot all-ambiguous auto-continue, in step mode -------------
#
# The same fixture shape as the hook-mode suite, written as findings FILES since
# step mode is handed the aggregate directly: two WARNINGs 55 lines apart in
# round 1 (further than LINEWIN, so neither can gather the other's prior), and in
# round 2 two more, each three lines from its own prior and sharing significant
# tokens with it without matching it exactly — the AMBIGUOUS verdict.
#
# What step mode adds over hook mode is that every round is its own INVOCATION,
# so the marker is the only thing carrying the one-shot bound (and the reported
# count) from one process to the next.
pft_findings() {  # $1 = round
  case "$1" in
  # round 1's first title is deliberately NOT already normalised (mixed case, a
  # double space, a tab), so the marker assertions below exercise `normtitle`
  # rather than passing on a value that needed no normalising
  1) printf '%s' '[{"severity":"WARNING","dimension":"tests","file":"app.py","line":5,"title":"Unquoted  Variable\tIn The Matcher","description":"d1","reviewer":"r"},{"severity":"WARNING","dimension":"tests","file":"app.py","line":60,"title":"missing timeout on the fetch helper","description":"d1","reviewer":"r"}]' ;;
  2) printf '%s' '[{"severity":"WARNING","dimension":"tests","file":"app.py","line":8,"title":"unquoted variable in the dispatcher","description":"d2","reviewer":"r"},{"severity":"WARNING","dimension":"tests","file":"app.py","line":63,"title":"missing timeout on the upload helper","description":"d2","reviewer":"r"}]' ;;
  esac
}

@test "#1498 tc-happy-auto-continue-step-mode: the round exits AWAITING_FIX (20), not 12" {
  pft_findings 1 > "$F"
  step
  [ "$status" -eq 20 ]
  pft_findings 2 > "$F"
  step --resume
  # the ladder reached the non-convergence rung and took the continue, so the
  # round ends exactly as an ordinary continuing round does
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  # ...and it really was the state this rung is about, not merely a round with
  # blockers left
  echo "$output" | jq -e '.final_changelist.non_converging == true' >/dev/null
  echo "$output" | jq -e '[.final_changelist.blocking[] | select(.non_converging == true)] | (length == 2) and all(.possible_false_trip == true)' >/dev/null
  echo "$output" | jq -e '.final_changelist.summary.critical == 0' >/dev/null
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  [ -s "$WD/.possible-false-trip-continued" ]
  # BOTH titles of every match, so a re-wording cannot buy a second continuation
  [ "$(wc -l < "$WD/.possible-false-trip-continued" | tr -d ' ')" -eq 4 ]
  grep -qF 'app.py	tests	unquoted variable in the dispatcher' "$WD/.possible-false-trip-continued"
  grep -qF 'app.py	tests	unquoted variable in the matcher' "$WD/.possible-false-trip-continued"
  # the session is told what to do next, in the round verdict it narrates
  grep -q 'auto-continued once, no grant consumed (#1498)' "$WD/progress.md"
}

@test "#1498 the marker survives --resume, and the refused second match escalates" {
  pft_findings 1 > "$F"
  step
  [ "$status" -eq 20 ]
  pft_findings 2 > "$F"
  step --resume
  [ "$status" -eq 20 ]
  local before
  before="$(cat "$WD/.possible-false-trip-continued")"
  # round 3 re-raises an identity the marker already holds, from a FRESH process
  # that knows nothing but the work-dir
  printf '%s' '[{"severity":"WARNING","dimension":"tests","file":"app.py","line":11,"title":"unquoted variable in the matcher","description":"d3","reviewer":"r"}]' > "$F"
  step --resume
  # The marker refuses the second continuation, and the rung ends where it
  # always could: ESCALATE_NO_CONVERGENCE. (#1571 had residue catch it; #2580
  # retired that terminal.)
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  [ ! -e "$WD/.closing-sweep" ]
  # round 3 really was another ambiguous carried match — the marker is the ONLY
  # thing that refused it
  echo "$output" | jq -e '[.final_changelist.blocking[] | select(.non_converging == true)] | (length > 0) and all(.possible_false_trip == true)' >/dev/null
  # the count came back across the process boundary rather than restarting at 0,
  # and the marker did not grow
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  [ "$(cat "$WD/.possible-false-trip-continued")" = "$before" ]
}

@test "#1498 a marker the loop cannot write REFUSES the continuation rather than spending the bound unrecorded" {
  # The fail-closed direction the rung's header states: continuing on a lost
  # record spends the one-shot bound invisibly and lets the same identity
  # continue again next round. Untested, `return 1` could become `return 0` with
  # the whole suite green.
  [ "$(id -u)" -ne 0 ] || skip "running as root — chmod 000 would not bite"
  pft_findings 1 > "$F"
  step
  [ "$status" -eq 20 ]
  : > "$WD/.possible-false-trip-continued"
  chmod 000 "$WD/.possible-false-trip-continued"
  pft_findings 2 > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume
  # the continuation is refused (the bound must not be spent invisibly), so the
  # rung escalates — nothing catches it since #2580 retired the residue terminal
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  [ ! -e "$WD/.closing-sweep" ]
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 0 ]
  contains "$stderr" "could not record the round 2 possible-false-trip auto-continue"
  chmod 644 "$WD/.possible-false-trip-continued"
  # nothing was recorded, so the bound was not silently spent
  [ ! -s "$WD/.possible-false-trip-continued" ]
}

@test "#1498 an unreadable marker is ANNOUNCED, not silently counted as zero" {
  # `_pft_count` reports 0 for a marker it cannot parse — but says so, the same
  # treatment the closing-sweep adoption gives a garbage sidecar. Untested, the
  # stderr line could be deleted and the run would report
  # possible_false_trip_auto_continues: 0 off a corrupt marker with no signal at
  # all, feeding a confident wrong number to the escalation summary and the
  # telemetry payload.
  pft_findings 1 > "$F"
  step
  [ "$status" -eq 20 ]
  printf 'garbage line with no round field\n' > "$WD/.possible-false-trip-continued"
  pft_findings 2 > "$F"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume
  contains "$stderr" "ignoring an unreadable possible-false-trip marker"
  # ...and the degradation is BOUNDED: the round still runs to its documented
  # terminal, and the garbage line is ignored by the count rather than poisoning
  # it — this round appended its own records, so the derivation is 1
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
}

# --- #1571: condition 2 removed — residue reachable from a promoted sweep ----
#
# The #1558 shape, and the exact sequence exit 14 could never reach before. A
# zero-blocking DELTA round promotes the closing sweep and runs no fix pass, so
# the loop writes it an EMPTY fix-touched set on purpose — and under the retired
# condition 2 every blocker the sweep then raised counted as "outside" that set,
# so the run exited BUDGET_EXHAUSTED. That is why the terminal built for the
# closing sweep was unreachable FROM the closing sweep.

@test "#2580 AC2 step mode: the zero-blocker closing-sweep promotion is unchanged, and its sweep with a WARNING at the ceiling ends 13, never 14" {
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 2
  [ "$status" -eq 20 ]

  # round 2: the in-session fix, then a CLEAN delta round — it still promotes
  # the closing sweep, under the one-round grant (#1434, kept by #2580)
  echo "v1" > "$R/touched.py"
  printf '[]' > "$F"
  step --resume --max-rounds 2
  [ "$status" -eq 20 ]
  [ "$(cat "$WD/.closing-sweep")" = "3" ]
  echo "$output" | jq -e '.closing_sweep_granted == true' >/dev/null

  # round 3: the promoted FULL sweep raises one WARNING past the ceiling — the
  # shape the retired residue terminal shipped as exit 14. It ends 13 now.
  residue_findings 3 touched.py > "$F"
  step --resume --max-rounds 2
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  [ "$(echo "$output" | jq '.final_changelist.blocking | length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.next_ref')" = "reference/escalation.md" ]
}

@test "#1571 AC4 non-vacuity: a CRITICAL in that same sweep still refuses 14 (condition 1 bites)" {
  # Identical fixture to AC3 except the sweep's finding is CRITICAL. If
  # condition 1 were dropped along with condition 2, this would ship a PR with a
  # Critical outstanding — so this is the assertion that keeps the removal
  # honest, and it fails the moment the zero-CRITICAL window stops being checked.
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 2
  [ "$status" -eq 20 ]

  echo "v1" > "$R/touched.py"
  printf '[]' > "$F"
  step --resume --max-rounds 2
  [ "$status" -eq 20 ]

  printf '[{"severity":"CRITICAL","dimension":"bugs","file":"touched.py","line":300,"title":"round 3 null dereference","description":"d3","reviewer":"r"}]' > "$F"
  step --resume --max-rounds 2
  # The DOCUMENTED terminal, not merely "not the good ending": `-ne 14` alone is
  # satisfied by exit 1 (a verdictless fall-through) and exit 2 (a
  # STALE_FINDINGS refusal) too, so a regression that turned the failed-residue
  # ceiling rung into an operational error would have read as a pass.
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ "$(echo "$output" | jq '.final_changelist.summary.critical')" -eq 1 ]
}

@test "#1498 the free round is spent first at the nonconv rung, and the next refused match escalates" {
  # A carried blocker that recurs trips non-convergence; #1498 grants one
  # auto-continue for a POSSIBLE false trip. The auto-continue is spent FIRST
  # (round 2), and the rung escalates only afterwards (round 3). (#1571 had the
  # residue terminal catch round 3; #2580 retired it.)
  echo "v0" > "$R/touched.py"
  printf '[{"severity":"WARNING","dimension":"bugs","file":"touched.py","line":100,"title":"unquoted expansion in the matcher","description":"d1","reviewer":"r"}]' > "$F"
  step --max-rounds 5
  [ "$status" -eq 20 ]

  # Round 2 must be a POSSIBLE false trip, which is a narrow target: an EXACT
  # title match is a verified survivor (never ambiguous), and a fully disjoint
  # title is a verified false trip (#983 auto-continues it without spending the
  # #1498 allowance). So the titles must DIFFER while sharing significant
  # tokens, and the lines must sit inside the proximity window.
  echo "v1" > "$R/touched.py"
  printf '[{"severity":"WARNING","dimension":"bugs","file":"touched.py","line":103,"title":"unquoted expansion in the dispatcher","description":"d2","reviewer":"r2"}]' > "$F"
  step --resume --max-rounds 5
  [ "$status" -eq 20 ]
  # the free round was spent HERE, not an ending
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]

  # ...and the OTHER half of the title: round 3 re-raises the same identity, the
  # marker refuses a second free round, and the rung escalates.
  echo "v2" > "$R/touched.py"
  printf '[{"severity":"WARNING","dimension":"bugs","file":"touched.py","line":106,"title":"unquoted expansion in the matcher","description":"d3","reviewer":"r3"}]' > "$F"
  step --resume --max-rounds 5
  # Name the ending, rather than only ruling one out. A `!=` assertion is
  # satisfied by a verdictless exit 1 and by a STALE_FINDINGS exit 2 alike — the
  # very shape AC4 above was just corrected to stop using, so leaving it here
  # would be the same defect one test down (#982).
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  [ ! -e "$WD/.closing-sweep" ]
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
}
