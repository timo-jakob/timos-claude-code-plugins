#!/usr/bin/env bats
#
# Behavioral tests for consolidate-findings.zsh (#561): the deterministic engine
# that turns a review round's aggregate findings (issue #558 schema) into one
# prioritised changelist for the autonomous review loop (epic #557). Covers the
# four acceptance criteria — dedup, severity->blocking mapping, conflict
# detection, and cross-round non-convergence — plus edges.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/consolidate-findings.zsh"
  F="$BATS_TEST_TMPDIR/findings.json"
}

con() { run zsh "$S" --findings "$F" "$@"; }

@test "dedup: overlapping findings from two reviewers merge to one item" {
  cat > "$F" <<'EOF'
[
 {"severity":"WARNING","dimension":"bugs","file":"a.py","line":10,"title":"maybe None","description":"short","reviewer":"python-bug-hunter"},
 {"severity":"CRITICAL","dimension":"bugs","file":"a.py","line":10,"title":"None deref","description":"a considerably longer and more detailed description of the same defect","reviewer":"python-security-reviewer"}
]
EOF
  con
  [ "$status" -eq 0 ]
  # one consolidated item, highest severity wins, both reviewers credited,
  # most-detailed description kept
  [ "$(echo "$output" | jq '.blocking | length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.blocking[0].severity')" = "CRITICAL" ]
  [ "$(echo "$output" | jq '.blocking[0].agreement')" -eq 2 ]
  echo "$output" | jq -e '.blocking[0].description | test("considerably longer")' >/dev/null
}

@test "severity: WARNING maps to High and blocks; SUGGESTION maps to Low and never blocks" {
  cat > "$F" <<'EOF'
[
 {"severity":"WARNING","dimension":"performance","file":"b.py","line":5,"title":"N+1 query","description":"d","reviewer":"python-performance-reviewer"},
 {"severity":"SUGGESTION","dimension":"code_quality","file":"c.py","line":8,"title":"rename var","description":"d","reviewer":"python-code-quality"}
]
EOF
  con
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blocking[0].priority')" = "High" ]
  [ "$(echo "$output" | jq '.summary.blocking')" -eq 1 ]
  # the SUGGESTION is a logged suggestion, never in blocking
  [ "$(echo "$output" | jq -r '.suggestions[0].priority')" = "Low" ]
  echo "$output" | jq -e '.blocking | all(.title != "rename var")' >/dev/null
}

@test "conflict: co-located performance vs code_quality yields a conflict item + escalation" {
  cat > "$F" <<'EOF'
[
 {"severity":"WARNING","dimension":"performance","file":"d.py","line":20,"title":"inline the hot loop","description":"d","reviewer":"python-performance-reviewer"},
 {"severity":"SUGGESTION","dimension":"code_quality","file":"d.py","line":20,"title":"extract a helper for clarity","description":"d","reviewer":"python-code-quality"}
]
EOF
  con
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.conflicts | length')" -eq 1 ]
  echo "$output" | jq -e '.conflicts[0].between == ["performance","code_quality"]' >/dev/null
  echo "$output" | jq -e '.escalation_reasons | index("unresolved_conflict")' >/dev/null
}

@test "non-convergence: a blocker surviving two consecutive rounds sets non_converging" {
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":30,"title":"Race on shared counter","description":"d","reviewer":"python-bug-hunter"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"
  [ "$(echo "$output" | jq '.non_converging')" = "false" ]

  # round 2: same defect, a different reviewer, punctuation reword + shifted
  # line — still blocks (identity is file+dimension+line-proximity, not title).
  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":31,"title":"Race on shared counter!","description":"still here","reviewer":"python-security-reviewer"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.non_converging')" = "true" ]
  echo "$output" | jq -e '.escalation_reasons | index("non_converging_blocker")' >/dev/null
}

@test "non-convergence: a SEMANTICALLY reworded blocker (same file/dimension) still fires (#606)" {
  # The #606 regression: round-to-round the reviewer re-words the SAME finding.
  # A title-based fingerprint misses it and wastes a third round; identity must
  # be [file, dimension] + line proximity, not the free-text title.
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"security","file":"client.py","line":40,"title":"Disabling TLS verification exposes API key and document PII to MITM","description":"verify=False","reviewer":"python-security-reviewer"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"
  [ "$(echo "$output" | jq '.non_converging')" = "false" ]

  # round 2: same defect (verify=False still present), title reworded with an
  # extra clause and the line drifted by 2 — the old title fingerprint would NOT
  # have matched, so it must still fire on file+dimension+proximity.
  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"security","file":"client.py","line":42,"title":"Disabling TLS verification exposes API key and document PII to MITM (now wired and reachable)","description":"verify=False still present","reviewer":"python-security-reviewer"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.non_converging')" = "true" ]
  echo "$output" | jq -e '.escalation_reasons | index("non_converging_blocker")' >/dev/null
}

@test "non-convergence: the match records WHICH prior blocker it hit (matched_prior, #913)" {
  # the escalation needs "matched prior blocker at old line L" so a human can
  # spot a false trip of the proximity window after a fix pass shifted lines
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":30,"title":"Race on shared counter","description":"d","reviewer":"python-bug-hunter"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"
  # round 1 has no prior — no blocker may carry matched_prior
  [ "$(echo "$output" | jq '[.blocking[] | has("matched_prior")] | any')" = "false" ]

  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":38,"title":"Counter increment still racy","description":"still here","reviewer":"python-bug-hunter"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.non_converging')" = "true" ]
  [ "$(echo "$output" | jq '.blocking[0].matched_prior.line')" -eq 30 ]
  [ "$(echo "$output" | jq -r '.blocking[0].matched_prior.title')" = "Race on shared counter" ]
}

@test "non-convergence: with several matching prior blockers, matched_prior is the NEAREST by line; ties keep prior blocking order (#913/#969)" {
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":30,"title":"Race on shared counter","description":"d","reviewer":"python-bug-hunter"},
 {"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":35,"title":"Unlocked read of counter","description":"d","reviewer":"python-bug-hunter"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"

  # both priors sit within the window — the recorded match is the NEAREST by
  # line distance (|35-33|=2 beats |30-33|=3), so co-windowed priors attribute
  # to their own successors and the distinct-priors fixed count stays honest
  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":33,"title":"Counter still racy","description":"d","reviewer":"python-bug-hunter"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.non_converging')" = "true" ]
  [ "$(echo "$output" | jq '.blocking[0].matched_prior.line')" -eq 35 ]
  [ "$(echo "$output" | jq -r '.blocking[0].matched_prior.title')" = "Unlocked read of counter" ]

  # equidistant priors (|30-32|=|34-32|... use 25/35 around 30): stable sort
  # keeps the first in prior blocking-array order — deterministic
  cat > "$BATS_TEST_TMPDIR/r2b.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":32,"title":"Counter still racy somehow","description":"d","reviewer":"python-bug-hunter"}]
EOF
  cat > "$BATS_TEST_TMPDIR/round1b.json" <<'EOF'
{"round":1,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"severity":"CRITICAL","priority":"Critical","dimension":"bugs","file":"e.py","line":30,"title":"Race on shared counter","blocking":true,"non_converging":false},
             {"severity":"CRITICAL","priority":"Critical","dimension":"bugs","file":"e.py","line":34,"title":"Unlocked read of counter","blocking":true,"non_converging":false}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2b.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1b.json"
  [ "$status" -eq 0 ]
  # |30-32| == |34-32| == 2 -> tie keeps the first prior (line 30)
  [ "$(echo "$output" | jq '.blocking[0].matched_prior.line')" -eq 30 ]
}

@test "non-convergence: a line-less prior blocker matches as a wildcard and matched_prior.line is null (#913)" {
  # the producer side of the render-side wildcard test: line_near treats a
  # missing line as a wildcard, and matched_prior must carry line:null (not 0,
  # not an omitted key) so the escalation renders the file-wide caveat
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","title":"Race somewhere in e.py","description":"d","reviewer":"python-bug-hunter"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"

  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":500,"title":"Counter still racy","description":"d","reviewer":"python-bug-hunter"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.non_converging')" = "true" ]
  [ "$(echo "$output" | jq '.blocking[0].matched_prior.line')" = "null" ]
  [ "$(echo "$output" | jq -r '.blocking[0].matched_prior.title')" = "Race somewhere in e.py" ]
}

@test "possible_false_trip: a matched prior with a DIFFERENT title is flagged; a case/whitespace reword is not (#969)" {
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":30,"title":"Race on shared counter","description":"d","reviewer":"python-bug-hunter"},
 {"severity":"CRITICAL","dimension":"tests","file":"t.py","line":10,"title":"Missing failure-branch test","description":"d","reviewer":"python-test-reviewer"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"
  # round 1 has no prior — nothing may carry the flag
  [ "$(echo "$output" | jq '[.blocking[] | has("possible_false_trip")] | any')" = "false" ]

  # round 2: e.py match has a genuinely different title (a different finding
  # inside the window) -> flagged; t.py match differs only in case/whitespace
  # (a pure reword of the same finding) -> NOT flagged
  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":33,"title":"Off-by-one in retry counter","description":"d","reviewer":"python-bug-hunter"},
 {"severity":"CRITICAL","dimension":"tests","file":"t.py","line":11,"title":"missing   FAILURE-branch test ","description":"d","reviewer":"python-test-reviewer"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.blocking[] | select(.file=="e.py")][0].possible_false_trip')" = "true" ]
  [ "$(echo "$output" | jq '[.blocking[] | select(.file=="t.py")][0].possible_false_trip')" = "false" ]
}

@test "possible_false_trip: an exact-title match ANYWHERE in the match set wins over an earlier different-titled one (#969)" {
  # both priors sit inside the round-2 window; the FIRST has a different title
  # but the SECOND is repeated verbatim — the strongest evidence of a genuine
  # repeat, so the flag must NOT fire and matched_prior must name the exact one
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":30,"title":"Race on shared counter","description":"d","reviewer":"python-bug-hunter"},
 {"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":35,"title":"Unlocked read of counter","description":"d","reviewer":"python-bug-hunter"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"

  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":36,"title":"Unlocked read of counter","description":"still here","reviewer":"python-bug-hunter"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.blocking[0].possible_false_trip')" = "false" ]
  [ "$(echo "$output" | jq '.blocking[0].matched_prior.line')" -eq 35 ]
  [ "$(echo "$output" | jq -r '.blocking[0].matched_prior.title')" = "Unlocked read of counter" ]
}

@test "non-string titles do not abort the round — normtitle coerces before downcasing (#969)" {
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":30,"title":42,"description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"

  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":31,"title":42,"description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  # identical (coerced) titles -> a genuine repeat, not a false trip
  [ "$(echo "$output" | jq '.blocking[0].possible_false_trip')" = "false" ]
}

@test "matched_prior attributes co-windowed priors to their NEAREST successor, not the first in array order (#969)" {
  # two priors 5 lines apart share the round-2 windows; each reworded
  # successor must record ITS OWN prior, or the distinct-priors fixed-since
  # count downstream collapses them and overstates what was fixed
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":10,"title":"Race on counter A","description":"d","reviewer":"r"},
 {"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":15,"title":"Unlocked read of B","description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"

  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":10,"title":"Counter A still racy","description":"d","reviewer":"r"},
 {"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":15,"title":"B read still unlocked","description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.blocking[] | select(.line==10)][0].matched_prior.line')" -eq 10 ]
  [ "$(echo "$output" | jq '[.blocking[] | select(.line==15)][0].matched_prior.line')" -eq 15 ]
  # distinct matched priors -> 2, so downstream fixed-since reads 0 of 2
  [ "$(echo "$output" | jq '[.blocking[] | .matched_prior] | unique | length')" -eq 2 ]
}

@test "matched_prior: duplicate-TITLED co-windowed priors also attribute to their nearest successor (#969)" {
  # same title at lines 10 and 15 (a repeated code-pattern finding); round 2
  # re-finds both at 11 and 16 — the title-identical branch must also pick
  # the NEAREST, or both would attribute to the prior at 10 and the distinct-
  # priors fixed count would collapse
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"security","file":"a.py","line":10,"title":"Unsanitized input","description":"d","reviewer":"r"},
 {"severity":"CRITICAL","dimension":"security","file":"a.py","line":15,"title":"Unsanitized input","description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"

  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"security","file":"a.py","line":11,"title":"Unsanitized input","description":"d","reviewer":"r"},
 {"severity":"CRITICAL","dimension":"security","file":"a.py","line":16,"title":"Unsanitized input","description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.blocking[] | select(.line==11)][0].matched_prior.line')" -eq 10 ]
  [ "$(echo "$output" | jq '[.blocking[] | select(.line==16)][0].matched_prior.line')" -eq 15 ]
  # identical titles -> genuine repeats, not false trips
  [ "$(echo "$output" | jq '[.blocking[] | .possible_false_trip] | all')" = "false" ]
  [ "$(echo "$output" | jq '[.blocking[] | .matched_prior] | unique | length')" -eq 2 ]
}

@test "matched_prior: a proximate NUMBERED prior outranks a co-windowed line-less one (#969)" {
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","title":"Race somewhere in e.py","description":"d","reviewer":"r"},
 {"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":30,"title":"Race on shared counter","description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"

  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":32,"title":"Counter still racy","description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  # both priors match (wildcard + within window), but the numbered one is
  # nearer than the wildcard rank — matched_prior must not be the line-less one
  [ "$(echo "$output" | jq '.blocking[0].matched_prior.line')" -eq 30 ]
}

@test "matched_prior attribution is one-to-one: two carried blockers never claim the same prior (#969)" {
  # P1@11 and P2@20 re-found (reworded) as C1@11 and C2@12 — C2 is nearer to
  # P1 than to P2, but P1 is already claimed by C1, so C2 must claim P2 and
  # the distinct-priors fixed count downstream reads 0 of 2, not 1 of 2
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":11,"title":"Race on counter A","description":"d","reviewer":"r"},
 {"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":20,"title":"Unlocked read of B","description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"

  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":11,"title":"Counter A trouble remains","description":"d","reviewer":"r"},
 {"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":12,"title":"B read trouble remains","description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.blocking[] | select(.line==11)][0].matched_prior.line')" -eq 11 ]
  [ "$(echo "$output" | jq '[.blocking[] | select(.line==12)][0].matched_prior.line')" -eq 20 ]
  [ "$(echo "$output" | jq '[.blocking[] | .matched_prior] | unique | length')" -eq 2 ]
}

@test "one-to-one claiming: with more carried blockers than priors, the overflow blocker still gets a REAL matched_prior (#969)" {
  # two priors, three co-windowed carried blockers: the first two claim
  # distinct priors, the third finds every candidate claimed and must fall
  # back to a real prior — never a null matched_prior that would add a
  # spurious distinct entry to the fixed-since counts
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":10,"title":"Race on counter A","description":"d","reviewer":"r"},
 {"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":15,"title":"Unlocked read of B","description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"

  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":10,"title":"A trouble remains","description":"d","reviewer":"r"},
 {"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":12,"title":"more A trouble","description":"d","reviewer":"r"},
 {"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":14,"title":"B trouble remains","description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  # every carried blocker records a real prior line — no null matched_prior
  [ "$(echo "$output" | jq '[.blocking[] | .matched_prior.line] | map(select(. != null)) | length')" -eq 3 ]
  # and only the two real priors appear as distinct claims
  [ "$(echo "$output" | jq '[.blocking[] | .matched_prior.line] | unique | length')" -eq 2 ]
}

@test "possible_false_trip: two title-LESS findings carry no title evidence, so the flag fires (#969)" {
  # empty normalized titles must NOT count as the strongest title-identical
  # evidence — with no title evidence either way, fall through to nearest and
  # flag, so the human is told the match may be a fresh finding
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":30,"description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"

  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":31,"description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.blocking[0].non_converging')" = "true" ]
  [ "$(echo "$output" | jq '.blocking[0].possible_false_trip')" = "true" ]
  # matched_prior is still recorded (nearest of the match set)
  [ "$(echo "$output" | jq '.blocking[0].matched_prior.line')" -eq 30 ]
}

@test "a non-string dimension is coerced to a string at normalization (#969)" {
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":42,"file":"e.py","line":30,"title":"x","description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blocking[0].dimension')" = "42" ]
  [ "$(echo "$output" | jq -r '.blocking[0].dimension | type')" = "string" ]
}

@test "a non-numeric line is coerced to null at normalization — no reviewer string ever reaches a renderer (#969)" {
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":"5`\ninjected","title":"x","description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.blocking[0].line')" = "null" ]

  # a digit-only STRING line is recovered losslessly, not discarded
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":"42","title":"x","description":"d","reviewer":"r"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.blocking[0].line')" -eq 42 ]
}

@test "non-convergence: a NEW same-file/dimension blocker far from the prior line does not fire" {
  # Line proximity guards against a false positive: round-1 blocker is fixed and
  # a genuinely different blocker of the same dimension appears elsewhere in the
  # file — the loop is still converging, so non_converging must stay false.
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"security","file":"client.py","line":40,"title":"Disabling TLS verification","description":"verify=False","reviewer":"python-security-reviewer"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"
  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"security","file":"client.py","line":400,"title":"Unvalidated redirect in fetch()","description":"a different, unrelated defect","reviewer":"python-security-reviewer"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.non_converging')" = "false" ]
}

@test "non-convergence: a DIFFERENT blocker in round 2 does not set non_converging" {
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":30,"title":"Race on shared counter","description":"d","reviewer":"python-bug-hunter"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"
  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"security","file":"z.py","line":9,"title":"SQL injection","description":"d","reviewer":"python-security-reviewer"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.non_converging')" = "false" ]
}

@test "empty findings: a clean empty changelist, nothing blocking" {
  echo '[]' > "$F"
  con
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.summary.blocking')" -eq 0 ]
  [ "$(echo "$output" | jq '.blocking | length')" -eq 0 ]
  [ "$(echo "$output" | jq '.non_converging')" = "false" ]
}

@test "usage: --findings is required (exit 2)" {
  run zsh "$S" --round 1
  [ "$status" -eq 2 ]
}

@test "internal: invalid JSON findings is exit 1, not a crash" {
  echo 'not json' > "$F"
  con
  [ "$status" -eq 1 ]
}
