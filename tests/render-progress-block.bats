#!/usr/bin/env bats
#
# Tests for render-progress-block.zsh (#971, enriched per #969): changelist
# JSON in, one human-readable progress.md block on stdout. Every round shows
# the severity split (critical/warning; "suggestions" IS the Suggestion
# count), and — when the inputs allow — new/carried, fixed-since-prior
# (--prev), the cumulative blocking trend (--history), and per-blocker
# possible-false-trip lines. The new/carried split (and what derives from it)
# must render ONLY when every blocker carries the #913 non_converging stamp —
# a stamp-less or mixed changelist gets totals only (no label rather than a
# confident wrong one).

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/render-progress-block.zsh"
  CL="$BATS_TEST_TMPDIR/changelist.json"
}

@test "stamped blockers render the severity split, new/carried, and per-dimension counts" {
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":1,"high":1,"low":1,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x","non_converging":true},
             {"file":"b.py","line":2,"dimension":"tests","title":"y","non_converging":false}],
 "suggestions":[{}],"conflicts":[],"non_converging":true}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "awaiting fix"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^## Round 2 — blockers remain'
  echo "$output" | grep -q -- '- blockers: 2 (critical: 1, warning: 1) (new: 1, carried: 1), conflicts: 0, suggestions: 1'
  echo "$output" | grep -q -- '- by dimension: bugs 1, tests 1'
  echo "$output" | grep -q -- '- awaiting fix'
}

@test "a stamp-less changelist degrades to totals + severity only (no new/carried label)" {
  cat > "$CL" <<'EOF'
{"round":1,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x"},
             {"file":"b.py","line":2,"dimension":"bugs","title":"y"}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 1 --verdict "budget exhausted"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- blockers: 2 (critical: 2, warning: 0), conflicts: 0, suggestions: 0'
  run ! grep -q 'new:' <<< "$output"
}

@test "a MIXED changelist (one stamped, one not) also degrades to totals only" {
  cat > "$CL" <<'EOF'
{"round":1,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x","non_converging":true},
             {"file":"b.py","line":2,"dimension":"bugs","title":"y"}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 1 --verdict "v"
  [ "$status" -eq 0 ]
  run ! grep -q 'new:' <<< "$output"
  run ! grep -q 'false trip' <<< "$output"
}

@test "a converged round renders 'no blockers', no severity split, and omits the dimension line" {
  cat > "$CL" <<'EOF'
{"round":3,"summary":{"critical":0,"high":0,"low":2,"blocking":0,"conflicts":0},
 "blocking":[],"suggestions":[{},{}],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 3 --verdict "converged"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^## Round 3 — no blockers'
  echo "$output" | grep -q -- '- blockers: 0, conflicts: 0, suggestions: 2'
  echo "$output" | grep -q -- '- converged'
  run ! grep -q 'by dimension' <<< "$output"
}

@test "--prev renders fixed-since-prior from the previous round's blocking array (#969)" {
  cat > "$BATS_TEST_TMPDIR/prev.json" <<'EOF'
{"round":1,"summary":{"critical":2,"high":1,"low":0,"blocking":3,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x","non_converging":false},
             {"file":"b.py","line":2,"dimension":"bugs","title":"y","non_converging":false},
             {"file":"c.py","line":3,"dimension":"bugs","title":"z","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":1,"high":1,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x","non_converging":true,"possible_false_trip":false,"matched_prior":{"line":1,"title":"x"}},
             {"file":"d.py","line":4,"dimension":"bugs","title":"w","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":true}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v" --prev "$BATS_TEST_TMPDIR/prev.json"
  [ "$status" -eq 0 ]
  # 3 prior blockers, 1 distinct prior carried -> 2 of 3 fixed
  echo "$output" | grep -q -- '- fixed since round 1: 2 of 3'
}

@test "--prev without the per-item stamps renders NO fixed-since line (no confident wrong number)" {
  cat > "$BATS_TEST_TMPDIR/prev.json" <<'EOF'
{"round":1,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":10,"dimension":"bugs","title":"X","non_converging":false},
             {"file":"a.py","line":200,"dimension":"bugs","title":"Y","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":1,"high":0,"low":0,"blocking":1,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x"}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v" --prev "$BATS_TEST_TMPDIR/prev.json"
  [ "$status" -eq 0 ]
  run ! grep -q 'fixed since' <<< "$output"
}

@test "--history renders the cumulative blocking trend across rounds (#969)" {
  cat > "$BATS_TEST_TMPDIR/history.jsonl" <<'EOF'
{"round":1,"blocking":10,"conflicts":0,"non_converging":false}
{"round":2,"blocking":5,"conflicts":0,"non_converging":false}
{"round":3,"blocking":2,"conflicts":0,"non_converging":false}
EOF
  cat > "$CL" <<'EOF'
{"round":3,"summary":{"critical":0,"high":2,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x","non_converging":false},
             {"file":"b.py","line":2,"dimension":"bugs","title":"y","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 3 --verdict "v" --history "$BATS_TEST_TMPDIR/history.jsonl"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- trend: blocking 10 → 5 → 2'
}

@test "--history with a single round renders no trend line (nothing to compare yet)" {
  cat > "$BATS_TEST_TMPDIR/history.jsonl" <<'EOF'
{"round":1,"blocking":3,"conflicts":0,"non_converging":false}
EOF
  cat > "$CL" <<'EOF'
{"round":1,"summary":{"critical":3,"high":0,"low":0,"blocking":3,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 1 --verdict "v" --history "$BATS_TEST_TMPDIR/history.jsonl"
  [ "$status" -eq 0 ]
  run ! grep -q 'trend:' <<< "$output"
}

@test "an empty dimension renders as '?' in the by-dimension line (#969)" {
  cat > "$CL" <<'EOF'
{"round":1,"summary":{"critical":1,"high":0,"low":0,"blocking":1,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"","title":"x","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 1 --verdict "v"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- by dimension: ? 1'
}

@test "a flagged possible_false_trip blocker gets its own recognisable line (#969)" {
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":1,"high":0,"low":0,"blocking":1,"conflicts":0},
 "blocking":[{"file":"a.py","line":50,"dimension":"bugs","title":"Off-by-one in retry counter",
              "non_converging":true,"possible_false_trip":true,
              "matched_prior":{"line":42,"title":"Race on shared counter"}}],
 "suggestions":[],"conflicts":[],"non_converging":true}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- possible false trip: `a.py:50` \[bugs\] matched prior-round blocker at line 42'
  echo "$output" | grep -q 'Race on shared counter'
  echo "$output" | grep -q 'may be a NEW finding'
}

@test "an UNflagged carried blocker (genuine repeat) renders no false-trip line" {
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":1,"high":0,"low":0,"blocking":1,"conflicts":0},
 "blocking":[{"file":"a.py","line":43,"dimension":"bugs","title":"Race on shared counter",
              "non_converging":true,"possible_false_trip":false,
              "matched_prior":{"line":42,"title":"Race on shared counter"}}],
 "suggestions":[],"conflicts":[],"non_converging":true}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v"
  [ "$status" -eq 0 ]
  run ! grep -q 'false trip' <<< "$output"
}

@test "a false trip whose matched prior has no line says file-wide, not a bogus line" {
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":1,"high":0,"low":0,"blocking":1,"conflicts":0},
 "blocking":[{"file":"a.py","line":50,"dimension":"bugs","title":"Off-by-one in retry counter",
              "non_converging":true,"possible_false_trip":true,
              "matched_prior":{"line":null,"title":"Race somewhere in a.py"}}],
 "suggestions":[],"conflicts":[],"non_converging":true}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'matched prior-round blocker file-wide'
  run ! grep -q 'at line null' <<< "$output"
}

@test "a verified false trip (#983) renders its own auto-continue line, distinct from an escalating possible-false-trip" {
  # false_trip:true, non_converging:false — the loop auto-continued (no
  # escalation, no human grant). It must render a line the human recognises as
  # "continued, not escalated", separate from the escalating $ftrips line.
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":1,"high":0,"low":0,"blocking":1,"conflicts":0,"false_trips":1},
 "blocking":[{"file":"m.zsh","line":103,"dimension":"correctness","title":"missing pipefail on the download pipeline",
              "non_converging":false,"false_trip":true,"possible_false_trip":true,
              "matched_prior":{"line":100,"title":"unquoted variable in the matcher loop"}}],
 "suggestions":[],"conflicts":[],"non_converging":false,"false_trips":[{"file":"m.zsh"}]}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- false trip auto-continued (#983): `m.zsh:103` \[correctness\] landed in the match window'
  echo "$output" | grep -q 'no escalation, no human grant consumed'
  # a false trip is NOT the escalating "possible false trip" line
  run ! grep -q 'possible false trip:' <<< "$output"
}

@test "a converged round with --prev still renders the fixed-since line (empty blocking is stamped, #969)" {
  cat > "$BATS_TEST_TMPDIR/prev.json" <<'EOF'
{"round":1,"summary":{"critical":1,"high":1,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x","non_converging":false},
             {"file":"b.py","line":2,"dimension":"tests","title":"y","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":0,"high":0,"low":1,"blocking":0,"conflicts":0},
 "blocking":[],"suggestions":[{}],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "converged" --prev "$BATS_TEST_TMPDIR/prev.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- fixed since round 1: 2 of 2'
  # the blockers line stays clean: no severity split, no new/carried on zero blockers
  echo "$output" | grep -q -- '- blockers: 0, conflicts: 0, suggestions: 1'
}

@test "fixed-since counts DISTINCT matched priors: two carried matches of ONE prior do not hide a fixed second prior (#969)" {
  cat > "$BATS_TEST_TMPDIR/prev.json" <<'EOF'
{"round":1,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":10,"dimension":"bugs","title":"X","non_converging":false},
             {"file":"a.py","line":200,"dimension":"bugs","title":"Y","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":5,"dimension":"bugs","title":"x","non_converging":true,"possible_false_trip":true,"matched_prior":{"line":10,"title":"X"}},
             {"file":"a.py","line":15,"dimension":"bugs","title":"y","non_converging":true,"possible_false_trip":true,"matched_prior":{"line":10,"title":"X"}}],
 "suggestions":[],"conflicts":[],"non_converging":true}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v" --prev "$BATS_TEST_TMPDIR/prev.json"
  [ "$status" -eq 0 ]
  # both current blockers match prior X@10 -> 1 distinct prior carried, so the
  # OTHER prior was fixed: 1 of 2 (the per-item count would wrongly say 0)
  echo "$output" | grep -q -- '- fixed since round 1: 1 of 2'
}

@test "fixed-since keeps same-file/line/title priors in DIFFERENT dimensions distinct (#969)" {
  # two carried blockers whose matched priors coincide on (line, title) but
  # belong to different dimensions — both priors still open, nothing fixed
  cat > "$BATS_TEST_TMPDIR/prev.json" <<'EOF'
{"round":1,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":10,"dimension":"security","title":"Unsanitized input","non_converging":false},
             {"file":"a.py","line":10,"dimension":"script_quality","title":"Unsanitized input","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":11,"dimension":"security","title":"Unsanitized input","non_converging":true,"possible_false_trip":false,"matched_prior":{"line":10,"title":"Unsanitized input"}},
             {"file":"a.py","line":11,"dimension":"script_quality","title":"Unsanitized input","non_converging":true,"possible_false_trip":false,"matched_prior":{"line":10,"title":"Unsanitized input"}}],
 "suggestions":[],"conflicts":[],"non_converging":true}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v" --prev "$BATS_TEST_TMPDIR/prev.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- fixed since round 1: 0 of 2'
}

@test "fixed-since clamps at 0 when carried priors exceed the prior blocking total" {
  cat > "$BATS_TEST_TMPDIR/prev.json" <<'EOF'
{"round":1,"summary":{"critical":1,"high":0,"low":0,"blocking":1,"conflicts":0},
 "blocking":[{"file":"a.py","line":5,"dimension":"bugs","title":"x","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":5,"dimension":"bugs","title":"x","non_converging":true,"possible_false_trip":false,"matched_prior":{"line":5,"title":"x"}},
             {"file":"b.py","line":9,"dimension":"bugs","title":"y","non_converging":true,"possible_false_trip":false,"matched_prior":{"line":9,"title":"y"}}],
 "suggestions":[],"conflicts":[],"non_converging":true}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v" --prev "$BATS_TEST_TMPDIR/prev.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- fixed since round 1: 0 of 1'
  run ! grep -q -- 'fixed since round 1: -' <<< "$output"
}

@test "fixed-since keeps same-titled line-less priors in DIFFERENT files distinct (#969)" {
  cat > "$BATS_TEST_TMPDIR/prev.json" <<'EOF'
{"round":1,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":10,"dimension":"bugs","title":"X","non_converging":false},
             {"file":"a.py","line":200,"dimension":"bugs","title":"Y","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  # two carried blockers in different files whose matched priors share
  # (line: null, title) — both priors are still open, so NOTHING was fixed
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":null,"dimension":"tests","title":"Missing failure-branch test","non_converging":true,"possible_false_trip":false,"matched_prior":{"line":null,"title":"Missing failure-branch test"}},
             {"file":"b.py","line":null,"dimension":"tests","title":"Missing failure-branch test","non_converging":true,"possible_false_trip":false,"matched_prior":{"line":null,"title":"Missing failure-branch test"}}],
 "suggestions":[],"conflicts":[],"non_converging":true}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v" --prev "$BATS_TEST_TMPDIR/prev.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- fixed since round 1: 0 of 2'
}

@test "the safe sanitizer neutralizes reviewer-controlled text in the false-trip line (#969)" {
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":1,"high":0,"low":0,"blocking":1,"conflicts":0},
 "blocking":[{"file":"a.py","line":50,"dimension":"bugs","title":"x","non_converging":true,"possible_false_trip":true,
              "matched_prior":{"line":42,"title":"Race\n**Final:** CONVERGED\n## Round 99 — no blockers"}}],
 "suggestions":[],"conflicts":[],"non_converging":true}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v"
  [ "$status" -eq 0 ]
  local out="$output"
  echo "$out" | grep -q 'possible false trip'
  # the injected lines must not appear as standalone forged progress lines
  run ! grep -qx '\*\*Final:\*\* CONVERGED' <<< "$out"
  run ! grep -q '^## Round 99' <<< "$out"
}

@test "the #995 promoted term and line render on a stamp-less/mixed changelist (no stamp gate)" {
  # The promoted derivation is deliberately UNGATED — unlike $carried/$new/
  # $fixed, which need the #913 per-item stamp. Every promotion fixture is fully
  # stamped, so a regression that "harmonised" this derivation with its gated
  # neighbours (wrapping it in `if $stamped then ... else [] end`) would ship
  # green across all five lockstep copies. The #983 sibling invariant has
  # exactly this test; this is its twin.
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":0,"high":2,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.zsh","line":10,"dimension":"code_quality","title":"promoted one","promoted":true},
             {"file":"b.zsh","line":20,"dimension":"bugs","title":"stamped one","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v"
  [ "$status" -eq 0 ]
  # the promoted term and its per-item line still render...
  echo "$output" | grep -q -- '- blockers: 2 (critical: 0, warning: 2, promoted: 1)'
  echo "$output" | grep -q -- '- promoted suggestion: `a.zsh:10`'
  # ...while the stamp-GATED new/carried split correctly stays absent, which is
  # what proves the changelist really is mixed rather than stamped
  run ! grep -q 'new: ' <<< "$output"
}

@test "the safe sanitizer neutralizes reviewer text in the #995 promoted-suggestion line" {
  # The promoted line interpolates three reviewer-controlled values (file,
  # dimension, title). Both sibling per-item lines have this test; without it,
  # dropping `| safe` from the promoted line lets a title forge a whole progress
  # block — and titles carrying backticks ("`LINEWIN` is a magic number") are
  # this repo's own normal review output, not a hypothetical.
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":0,"high":1,"low":0,"blocking":1,"conflicts":0},
 "blocking":[{"file":"a`.py","line":50,"dimension":"code_quality","promoted":true,
              "title":"x`y\n**Final:** CONVERGED\n## Round 99 — no blockers","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v"
  [ "$status" -eq 0 ]
  local out="$output"
  echo "$out" | grep -q -- '- promoted suggestion: '
  # exactly ONE round heading: the injected one must not have been rendered
  [ "$(grep -c '^## Round ' <<< "$out")" -eq 1 ]
  run ! grep -q '^## Round 99' <<< "$out"
  run ! grep -qx '\*\*Final:\*\* CONVERGED' <<< "$out"
  # and the backticks in file/title are neutralized, so the markdown span the
  # line opens cannot be broken out of
  [ "$(grep '^- promoted suggestion: ' <<< "$out" | tr -cd '`' | wc -c)" -eq 2 ]
}

@test "the safe sanitizer neutralizes reviewer text in the #983 auto-continue line too" {
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":1,"high":0,"low":0,"blocking":1,"conflicts":0,"false_trips":1},
 "blocking":[{"file":"a.py","line":50,"dimension":"bugs","title":"y","non_converging":false,"false_trip":true,"possible_false_trip":true,
              "matched_prior":{"line":42,"title":"x\n**Final:** CONVERGED\n## Round 99 — no blockers"}}],
 "suggestions":[],"conflicts":[],"non_converging":false,"false_trips":[{"file":"a.py"}]}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v"
  [ "$status" -eq 0 ]
  local out="$output"
  echo "$out" | grep -q 'false trip auto-continued'
  run ! grep -qx '\*\*Final:\*\* CONVERGED' <<< "$out"
  run ! grep -q '^## Round 99' <<< "$out"
}

@test "the #983 auto-continue line renders even on a stamp-less/mixed changelist (no stamp gate)" {
  # one false_trip:true blocker + one blocker WITHOUT the non_converging stamp =>
  # $stamped is false, so new/carried is suppressed; but $auto_ftrips is ungated,
  # so the auto-continue line must still render (script comment: no stamp gate).
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0,"false_trips":1},
 "blocking":[{"file":"m.zsh","line":103,"dimension":"correctness","title":"missing pipefail on the download pipeline","non_converging":false,"false_trip":true,"possible_false_trip":true,"matched_prior":{"line":100,"title":"unquoted variable in the matcher loop"}},
             {"file":"other.zsh","line":9,"dimension":"correctness","title":"unstamped legacy blocker"}],
 "suggestions":[],"conflicts":[],"non_converging":false,"false_trips":[{"file":"m.zsh"}]}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v"
  [ "$status" -eq 0 ]
  local out="$output"
  # the ungated auto-continue line is still rendered
  echo "$out" | grep -q 'false trip auto-continued'
  # stamp-less => no new/carried label on the blockers line
  echo "$out" | grep -q '^- blockers:'
  run ! grep -q 'new:' <<< "$out"
}

@test "the #983 auto-continue line with a line-less matched prior says (file-wide), never 'at line null'" {
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":1,"high":0,"low":0,"blocking":1,"conflicts":0,"false_trips":1},
 "blocking":[{"file":"a.py","line":50,"dimension":"bugs","title":"y","non_converging":false,"false_trip":true,"possible_false_trip":true,
              "matched_prior":{"line":null,"title":"race somewhere in a.py"}}],
 "suggestions":[],"conflicts":[],"non_converging":false,"false_trips":[{"file":"a.py"}]}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'false trip auto-continued'
  echo "$output" | grep -q '(file-wide)'
  run ! grep -q 'at line null' <<< "$output"
}

@test "a --prev that parses but is not an object is rejected up front (exit 1) with the --prev message" {
  cat > "$CL" <<'EOF'
{"round":1,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},
 "blocking":[],"suggestions":[],"conflicts":[],"non_converging":false}
EOF
  printf '[]' > "$BATS_TEST_TMPDIR/arr.json"
  run --separate-stderr zsh "$S" --changelist "$CL" --round 2 --verdict v --prev "$BATS_TEST_TMPDIR/arr.json"
  [ "$status" -eq 1 ]
  contains "$stderr" "invalid --prev JSON"
}

@test "missing required args is a usage error (exit 2)" {
  run zsh "$S" --changelist "$CL" --round 1
  [ "$status" -eq 2 ]
}

@test "a missing changelist file is an internal error (exit 1)" {
  run zsh "$S" --changelist "$BATS_TEST_TMPDIR/nope.json" --round 1 --verdict v
  [ "$status" -eq 1 ]
}

@test "invalid changelist JSON is an internal error (exit 1)" {
  printf 'not json' > "$CL"
  run zsh "$S" --changelist "$CL" --round 1 --verdict v
  [ "$status" -eq 1 ]
}

@test "a passed-but-missing --prev or --history is an internal error (exit 1), not a silent omission" {
  cat > "$CL" <<'EOF'
{"round":1,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},
 "blocking":[],"suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict v --prev "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 1 ]
  run zsh "$S" --changelist "$CL" --round 1 --verdict v --history "$BATS_TEST_TMPDIR/nope.jsonl"
  [ "$status" -eq 1 ]
}

@test "a present-but-malformed --prev or --history is an internal error (exit 1), never consumed as data" {
  cat > "$CL" <<'EOF'
{"round":1,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},
 "blocking":[],"suggestions":[],"conflicts":[],"non_converging":false}
EOF
  printf 'not json' > "$BATS_TEST_TMPDIR/bad.json"
  run zsh "$S" --changelist "$CL" --round 2 --verdict v --prev "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 1 ]
  printf '{"round":1,"blocking":1}\nnot jsonl\n' > "$BATS_TEST_TMPDIR/bad.jsonl"
  run zsh "$S" --changelist "$CL" --round 1 --verdict v --history "$BATS_TEST_TMPDIR/bad.jsonl"
  [ "$status" -eq 1 ]
}

@test "--prev on round 1 is a usage error (exit 2) — no round 0 to have fixed since" {
  cat > "$CL" <<'EOF'
{"round":1,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},
 "blocking":[],"suggestions":[],"conflicts":[],"non_converging":false}
EOF
  cat > "$BATS_TEST_TMPDIR/prev-ok.json" <<'EOF'
{"round":0,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},
 "blocking":[],"suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run --separate-stderr zsh "$S" --changelist "$CL" --round 1 --verdict v --prev "$BATS_TEST_TMPDIR/prev-ok.json"
  [ "$status" -eq 2 ]
  contains "$stderr" "--prev requires --round >= 2"
}

@test "--round 0 and leading-zero rounds are usage errors (exit 2) with the accurate message" {
  cat > "$CL" <<'EOF'
{"round":1,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},
 "blocking":[],"suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 0 --verdict v
  [ "$status" -eq 2 ]
  run zsh "$S" --changelist "$CL" --round 007 --verdict v
  [ "$status" -eq 2 ]
}

@test "a non-numeric --round is a usage error (exit 2), not a confusing jq failure" {
  cat > "$CL" <<'EOF'
{"round":1,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},
 "blocking":[],"suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round abc --verdict v
  [ "$status" -eq 2 ]
}

# ---- adjudicated re-raise drops (#1434) -------------------------------------

@test "a non-zero adjudicated_dropped renders its own line (#1434)" {
  cat > "$CL" <<'EOF'
{"round":3,"summary":{"critical":0,"high":1,"low":2,"blocking":1,"conflicts":0,"false_trips":0,"adjudicated_dropped":2},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x","non_converging":false}],
 "suggestions":[{},{}],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 3 --verdict "awaiting fix"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- adjudicated re-raises dropped: 2'
}

@test "a ZERO adjudicated_dropped renders nothing — and neither does an absent key (#1434)" {
  # Rendered only when there is something to say, the same rule the promoted
  # term follows: that is what keeps a run with no adjudicated list byte-
  # identical to before the count existed, and what lets a pre-#1434 changelist
  # (no key at all) still render.
  cat > "$CL" <<'EOF'
{"round":3,"summary":{"critical":0,"high":1,"low":0,"blocking":1,"conflicts":0,"false_trips":0,"adjudicated_dropped":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 3 --verdict "awaiting fix"
  [ "$status" -eq 0 ]
  local with_zero="$output"
  run -1 grep -q -- 'adjudicated re-raises dropped' <<< "$with_zero"

  # the same changelist with the key removed entirely renders identically
  cat > "$CL" <<'EOF'
{"round":3,"summary":{"critical":0,"high":1,"low":0,"blocking":1,"conflicts":0,"false_trips":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 3 --verdict "awaiting fix"
  [ "$status" -eq 0 ]
  # the timestamp in the heading is the only thing that could differ, so compare
  # the body lines rather than the whole block
  [ "$(echo "$output" | tail -n +2)" = "$(echo "$with_zero" | tail -n +2)" ]
}

# --- #1435: the per-round residue class row ----------------------------------

@test "#1435 a fully class-stamped round renders the by-class row" {
  # Deliberately UNEVEN counts (2 / 1 / 3). A 1/1/1 fixture is permutation-
  # invariant: swapping two of the three `select(.class == ...)` expressions
  # renders a byte-identical row, so the test would pass while every real round
  # with an uneven split had its class row mislabelled in the one surface a human
  # tails live. The three sibling renderings use uneven splits for the same
  # reason.
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":0,"high":6,"low":0,"blocking":6,"conflicts":0},
 "blocking":[{"file":"a.zsh","line":1,"dimension":"bugs","title":"x","non_converging":false,"class":"new_defect"},
             {"file":"a.zsh","line":9,"dimension":"bugs","title":"x2","non_converging":false,"class":"new_defect"},
             {"file":"b.zsh","line":2,"dimension":"bugs","title":"y","non_converging":false,"class":"incomplete_propagation"},
             {"file":"c.bats","line":3,"dimension":"tests","title":"z","non_converging":false,"class":"under_assertion"},
             {"file":"c.bats","line":30,"dimension":"tests","title":"z2","non_converging":false,"class":"under_assertion"},
             {"file":"d.bats","line":4,"dimension":"tests","title":"z3","non_converging":false,"class":"under_assertion"}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "awaiting fix"
  [ "$status" -eq 0 ]
  contains "$output" "- by class: new_defect 2, incomplete_propagation 1, under_assertion 3"
}

@test "#1435 tc-corner-class-unstamped-null: an unstamped round OMITS the row rather than printing zeros" {
  # a pre-#1435 changelist, or one the loop had no fix-touched set for: three
  # zeros here would assert a classification nobody made
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":0,"high":1,"low":0,"blocking":1,"conflicts":0},
 "blocking":[{"file":"a.zsh","line":1,"dimension":"bugs","title":"x","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "awaiting fix"
  [ "$status" -eq 0 ]
  lacks "$output" "by class:"
}

@test "#1435 a PARTIALLY stamped round omits the row too — all or nothing" {
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":0,"high":2,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.zsh","line":1,"dimension":"bugs","title":"x","non_converging":false,"class":"new_defect"},
             {"file":"b.zsh","line":2,"dimension":"bugs","title":"y","non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "awaiting fix"
  [ "$status" -eq 0 ]
  lacks "$output" "by class:"
}

@test "#1435 a converged (zero-blocker) round renders no class row" {
  # counting three zeros on a clean round is noise, not information — and the
  # empty array trivially satisfies the "every item is stamped" predicate
  cat > "$CL" <<'EOF'
{"round":3,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},
 "blocking":[],"suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 3 --verdict "converged"
  [ "$status" -eq 0 ]
  lacks "$output" "by class:"
}

# --- #1498: --possible-false-trip-continued -----------------------------------
#
# The renderer is a pure function of the changelist, and the changelist carries
# no record of which way the ladder went — an escalating all-ambiguous round and
# an auto-continued one are byte-identical documents. So the LOOP supplies the
# fact, and these pin both halves: the flag changes the line, and its absence
# leaves the output exactly as it was before the flag existed.
pft_changelist() {   # $1 = target file
  cat > "$1" <<'EOF'
{"round":2,"summary":{"critical":0,"high":1,"low":0,"blocking":1,"conflicts":0},
 "blocking":[{"file":"a.py","line":50,"dimension":"bugs","title":"Off-by-one in the retry counter",
              "non_converging":true,"false_trip":false,"possible_false_trip":true,
              "matched_prior":{"line":42,"title":"Off-by-one in the backoff counter"}}],
 "suggestions":[],"conflicts":[],"non_converging":true}
EOF
}

@test "#1498 --possible-false-trip-continued renders the auto-continued line" {
  pft_changelist "$CL"
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v" --possible-false-trip-continued
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- possible false trip auto-continued (#1498): `a.py:50` \[bugs\] matched prior-round blocker at line 42'
  # the evidence a human needs to judge it is still there...
  echo "$output" | grep -q 'Off-by-one in the backoff counter'
  echo "$output" | grep -q 'may be a NEW finding'
  # ...plus what the flag exists to say: the run did not stop, and it gets one
  # such round per identity
  echo "$output" | grep -q 'continued once without a human grant, and a second ambiguous match on this identity escalates'
}

@test "#1498 without the flag the output is byte-identical to before the flag existed" {
  pft_changelist "$CL"
  # `--verdict` is fixed and the only other varying input is the timestamp, so
  # the two runs are compared with it stripped — an unflagged run must not
  # differ from the flagged one by anything BUT the marked line.
  local plain flagged
  plain="$(zsh "$S" --changelist "$CL" --round 2 --verdict "v" | sed 's/([0-9][0-9]:[0-9][0-9]:[0-9][0-9])/(TS)/')"
  flagged="$(zsh "$S" --changelist "$CL" --round 2 --verdict "v" --possible-false-trip-continued | sed 's/([0-9][0-9]:[0-9][0-9]:[0-9][0-9])/(TS)/')"
  # the unflagged render is exactly today's wording
  grep -q -- '- possible false trip: `a.py:50` \[bugs\] matched prior-round blocker at line 42' <<< "$plain"
  run ! grep -q '1498' <<< "$plain"
  run ! grep -q 'auto-continued' <<< "$plain"
  # ...and the ONLY difference between the two is that one line
  [ "$(diff <(printf '%s\n' "$plain") <(printf '%s\n' "$flagged") | grep -c '^[<>]')" -eq 2 ]
}

@test "#1498 the auto-continued line stays distinct from #983's verified false-trip line" {
  # A round can legitimately carry BOTH: one identity-cleared disjoint match
  # (#983, non_converging false) and one ambiguous match the loop continued on
  # (#1498, non_converging true). Collapsing them would tell the human the wrong
  # thing about half the round.
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":0,"high":2,"low":0,"blocking":2,"conflicts":0,"false_trips":1},
 "blocking":[{"file":"a.py","line":50,"dimension":"bugs","title":"Off-by-one in the retry counter",
              "non_converging":true,"false_trip":false,"possible_false_trip":true,
              "matched_prior":{"line":42,"title":"Off-by-one in the backoff counter"}},
             {"file":"m.zsh","line":103,"dimension":"correctness","title":"missing pipefail on the download pipeline",
              "non_converging":false,"false_trip":true,"possible_false_trip":true,
              "matched_prior":{"line":100,"title":"unquoted variable in the matcher loop"}}],
 "suggestions":[],"conflicts":[],"non_converging":true,"false_trips":[{"file":"m.zsh"}]}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v" --possible-false-trip-continued
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- possible false trip auto-continued (#1498): `a.py:50`'
  echo "$output" | grep -q -- '- false trip auto-continued (#983): `m.zsh:103`'
  # exactly one of each — neither line rendered for the other one's blocker
  [ "$(grep -c -- '(#1498)' <<< "$output")" -eq 1 ]
  [ "$(grep -c -- '(#983)' <<< "$output")" -eq 1 ]
}

@test "#1498 the flag renders NOTHING on a round with no escalating possible-false-trip set" {
  # The flag is a fact about the ladder, not a line to print unconditionally: a
  # round the loop could never have auto-continued must look the same either way.
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":0,"high":1,"low":0,"blocking":1,"conflicts":0},
 "blocking":[{"file":"a.py","line":43,"dimension":"bugs","title":"Race on shared counter",
              "non_converging":true,"false_trip":false,"possible_false_trip":false,
              "matched_prior":{"line":42,"title":"Race on shared counter"}}],
 "suggestions":[],"conflicts":[],"non_converging":true}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v" --possible-false-trip-continued
  [ "$status" -eq 0 ]
  run ! grep -q 'false trip' <<< "$output"
}

@test "#1498 the flag takes no value, and an unknown flag is still a usage error" {
  pft_changelist "$CL"
  # it is a BOOLEAN: the next argument must still be parsed as a flag, not eaten
  run zsh "$S" --changelist "$CL" --possible-false-trip-continued --round 2 --verdict "v"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^## Round 2'
  run zsh "$S" --changelist "$CL" --round 2 --verdict "v" --possible-false-trip
  [ "$status" -eq 2 ]
}
