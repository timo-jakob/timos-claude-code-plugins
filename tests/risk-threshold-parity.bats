#!/usr/bin/env bats
#
# #1921 AC7: consolidate-findings.zsh (the in-loop demotion) and
# resolve-story-loop.zsh (the up-front --risk check) read
# `corner_case_risk_threshold` through ONE parser, risk-threshold-lib.zsh. If
# they disagreed on a single spelling, the loop could refuse an assessment the
# consolidator would have ignored, or let through one it then reads differently,
# with nothing downstream noticing. (#2600 removed the third reader, the residue
# filing script, with the filing path.)
#
# Checked two ways. Behaviourally: each value in #1920's table is fed to both
# scripts, and the state (off / ignored / on) and threshold_thousandths each one
# acts on are read back from what it produces and compared. Structurally: both
# scripts source the library and neither carries a parser of its own, so a
# future edit cannot quietly fork the rule.

bats_require_minimum_version 1.5.0

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"  # the user-level telemetry default stays out of the real ~/.claude (#1972)
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/resolve-issue/scripts"
  CON="$SCRIPTS/consolidate-findings.zsh"
  LOOP="$SCRIPTS/resolve-story-loop.zsh"
  LIB="$SCRIPTS/risk-threshold-lib.zsh"

  # one WARNING finding, assessed at risk 0 so it is demoted whenever the
  # threshold is on — the stamp then carries the threshold the consolidator used
  F="$BATS_TEST_TMPDIR/findings.json"
  printf '%s' '[{"severity":"WARNING","dimension":"bugs","file":"a.zsh","line":1,"title":"t","description":"d","reviewer":"r"}]' > "$F"
  RISK="$BATS_TEST_TMPDIR/risk.json"
  printf '%s' '[{"file":"a.zsh","line":1,"dimension":"bugs","title":"t","p":0,"p_why":"w","impact":0.1,"impact_why":"w"}]' > "$RISK"
  # ...and the same entry malformed (an impact off the four anchors), which the
  # loop refuses up front only when it parses the threshold as on
  BAD="$BATS_TEST_TMPDIR/bad-risk.json"
  printf '%s' '[{"file":"a.zsh","line":1,"dimension":"bugs","title":"t","p":0,"p_why":"w","impact":0.5,"impact_why":"w"}]' > "$BAD"

  # the loop side: a one-file repo whose story diff holds the finding's file
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  echo base > "$R/README.md"
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" branch -M main
  echo 'print 1' > "$R/a.zsh"
  STUB="$BATS_TEST_TMPDIR/detect.sh"
  printf '#!/usr/bin/env bash\necho "$DETECT_LANGS_JSON"\n' > "$STUB"
  chmod +x "$STUB"
  WD="$BATS_TEST_TMPDIR/wd"
}

# Each helper runs its script and leaves its reading, "<state> <thousandths|->",
# in $reading. They are called as plain commands, never inside $(…): an
# assertion in a command substitution cannot fail the test.

# the consolidator's reading
con_reading() {  # $1 = the value
  run -0 --separate-stderr env corner_case_risk_threshold="$1" zsh "$CON" --findings "$F" --risk "$RISK"
  local milli
  milli=$(printf '%s' "$output" | jq -r '[.blocking[], .suggestions[]][0].risk_assessment.threshold_thousandths // empty')
  if [ -n "$milli" ]; then
    reading="on $milli"
  elif grep -qF IGNORED <<< "$stderr"; then
    reading="ignored -"
  else
    reading="off -"
  fi
}

# one fresh step-mode round of the loop on $R, with $2 as its --risk
loop_round() {  # $1 = the value, $2 = the --risk file
  rm -rf "$WD"
  run --separate-stderr env corner_case_risk_threshold="$1" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$LOOP" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --risk "$2"
}

# the loop's reading. Its own parse decides one thing, whether the up-front check
# validates the --risk file: a malformed file is exit 2 exactly when the loop
# reads the threshold as on. The thousandths and the ignored notice come from
# the round it then runs, stamped into changelist-1.json. The two must agree.
loop_reading() {  # $1 = the value
  local gate milli
  loop_round "$1" "$BAD"
  if [ "$status" -eq 2 ]; then gate=on; else gate=not-on; fi
  loop_round "$1" "$RISK"
  milli=$(jq -r '[.blocking[], .suggestions[]][0].risk_assessment.threshold_thousandths // empty' "$WD/changelist-1.json")
  if [ -n "$milli" ]; then
    reading="on $milli"
  elif grep -qF IGNORED <<< "$stderr"; then
    reading="ignored -"
  else
    reading="off -"
  fi
  # the gate and the round agree on whether the threshold is on
  local round_on=not-on
  [ "${reading%% *}" != on ] || round_on=on
  [ "value [$1] gate: $gate" = "value [$1] gate: $round_on" ]
}

@test "#1921 AC7 the consolidator and the loop read every value in #1920's table into the same state and thousandths" {
  local v reading
  local -a values=('' 0 0.0 .000 0.05 .05 1 1.0 30 1.5 -0.1 0.0005 abc)
  local -a expect=('off -' 'off -' 'off -' 'off -' 'on 50' 'on 50' 'on 1000' 'on 1000'
                   'ignored -' 'ignored -' 'ignored -' 'ignored -' 'ignored -')
  local i
  for i in "${!values[@]}"; do
    v="${values[$i]}"
    con_reading "$v"
    [ "value [$v] consolidator: $reading" = "value [$v] consolidator: ${expect[$i]}" ]
    loop_reading "$v"
    [ "value [$v] loop: $reading" = "value [$v] loop: ${expect[$i]}" ]
  done
}

@test "#1921 AC7 unset reads as off in both" {
  run --separate-stderr env -u corner_case_risk_threshold zsh "$CON" --findings "$F" --risk "$RISK"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '[.blocking[], .suggestions[]] | all(has("risk_assessment") | not)' >/dev/null
  # the loop forwards a malformed file unread while the threshold is off
  rm -rf "$WD"
  run --separate-stderr env -u corner_case_risk_threshold DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$LOOP" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --risk "$BAD"
  [ "$status" -ne 2 ]
  [ -f "$WD/changelist-1.json" ]
  jq -e '[.blocking[], .suggestions[]] | all(has("risk_assessment") | not)' "$WD/changelist-1.json" >/dev/null
}

@test "#1921 AC7 one parser: every reader sources the library, and none carries its own" {
  local s
  for s in "$CON" "$LOOP"; do
    grep -qF 'risk-threshold-lib.zsh' "$s"
    grep -qF 'risk_threshold_parse' "$s"
    # the parser's regex and the validator's anchor check live in the library only
    run grep -cF '(\.([0-9]{1,3}))?$' "$s"
    [ "$output" = "0" ]
    run grep -cF '[1, 4, 7, 10]' "$s"
    [ "$output" = "0" ]
    # ...nor its own validator, nor a direct read of the variable
    run grep -cE 'def scaled_ok|^[[:space:]]*risk_validate_file\(\)|\$\{corner_case_risk_threshold' "$s"
    [ "$output" = "0" ]
  done
  grep -qF '(\.([0-9]{1,3}))?$' "$LIB"
  grep -qF '[1, 4, 7, 10]' "$LIB"
  # the library names exactly its two remaining readers
  grep -qF '# script that reads either (#1921): consolidate-findings.zsh (the in-loop' "$LIB"
  grep -qF '# demotion) and resolve-story-loop.zsh (the up-front --risk check).' "$LIB"
}

# --- #2577: extension_risk_threshold is read by the same rule -----------------

# the consolidator's reading of extension_risk_threshold, in an extension round
# with the base off: "<state> <thousandths>", default and ignored both acting on
# 100 (ignored is the announced one)
ext_reading() {  # $1 = the value, or UNSET
  if [ "$1" = UNSET ]; then
    run -0 --separate-stderr env -u corner_case_risk_threshold -u extension_risk_threshold zsh "$CON" --findings "$F" --risk "$RISK" --extension
  else
    run -0 --separate-stderr env -u corner_case_risk_threshold extension_risk_threshold="$1" zsh "$CON" --findings "$F" --risk "$RISK" --extension
  fi
  local milli
  milli=$(printf '%s' "$output" | jq -r '[.blocking[], .suggestions[]][0].risk_assessment.threshold_thousandths // empty')
  if [ -z "$milli" ]; then
    reading="off -"
  elif grep -qF "extension_risk_threshold='$1'" <<< "$stderr"; then
    reading="ignored $milli"
  else
    reading="on $milli"
  fi
}

@test "#2577 extension_risk_threshold: every spelling in #1920's table reads as the base rule does, unset and invalid acting on 0.10" {
  local i reading
  local -a values=(UNSET '' 0 0.0 .000 0.05 .05 1 1.0 30 1.5 -0.1 0.0005 abc)
  local -a expect=('on 100' 'on 100' 'off -' 'off -' 'off -' 'on 50' 'on 50' 'on 1000' 'on 1000'
                   'ignored 100' 'ignored 100' 'ignored 100' 'ignored 100' 'ignored 100')
  for i in "${!values[@]}"; do
    ext_reading "${values[$i]}"
    [ "value [${values[$i]}]: $reading" = "value [${values[$i]}]: ${expect[$i]}" ]
  done
}

@test "#2577 one parser: both variables go through the library's one decimal rule" {
  grep -qF 'risk_extension_parse' "$CON"
  grep -qF 'risk_extension_parse' "$SCRIPTS/resolve-story-loop.zsh"
  run grep -cE '\$\{extension_risk_threshold' "$CON" "$SCRIPTS/resolve-story-loop.zsh"
  [ "$output" = "$CON:0
$SCRIPTS/resolve-story-loop.zsh:0" ]
  # the library reads each variable once, and both feed _risk_parse_decimal
  [ "$(grep -c '_risk_parse_decimal "\$thr_raw"' "$LIB")" -eq 1 ]
  [ "$(grep -c '_risk_parse_decimal "\$ext_raw"' "$LIB")" -eq 1 ]
  [ "$(grep -cF '(\.([0-9]{1,3}))?$' "$LIB")" -eq 1 ]
}

@test "#2577 AC7 the default 0.10 and its source are documented in ARCHITECTURE.md and the how-to, and the conductor's procedure is pinned" {
  local arch howto rp
  arch="$(tr '\n' ' ' < "$REPO_ROOT/ARCHITECTURE.md" | tr -s ' ')"
  howto="$(tr '\n' ' ' < "$REPO_ROOT/docs/how-to/set-a-corner-case-risk-threshold.md" | tr -s ' ')"
  rp="$(tr '\n' ' ' < "$SCRIPTS/../reference/review-loop/risk-pass.md" | tr -s ' ')"
  # ARCHITECTURE.md, inside the corner_case_risk_threshold section
  local sect
  sect="$(sed -n '/^## Runtime setting: `corner_case_risk_threshold`/,/^## Runtime setting: `epic_strictly_sequential`/p' "$REPO_ROOT/ARCHITECTURE.md" | tr '\n' ' ' | tr -s ' ')"
  grep -qF 'Unset or `""` is the **default, `0.10`**; any spelling of zero turns the extension bar **off**' <<< "$sect"
  grep -qF '**Effective bar:** `max(corner_case_risk_threshold when on, extension_risk_threshold)`, so an extension round never blocks on less than a normal round.' <<< "$sect"
  grep -qF '576 per-finding assessments in 174 `risk-<R>.json` files written by the #1921 risk pass: 58% are below `0.04`, 81% below `0.10` and 91% below `0.15`. At a `0.04` base 243 of them block; at `0.10`, 109 still do.' <<< "$sect"
  grep -qF 'The #1434 closing sweep of a run with no grant is not one; the closing sweep of an extended run is.' <<< "$arch"
  # the how-to
  grep -qF '| unset or `""` | the default, `0.10` |' <<< "$howto"
  grep -qF '| `0` (or `0.0`) | the extension bar is **off**: the normal floor, exactly like other rounds |' <<< "$howto"
  grep -qF 'The floor in an extension round is the **higher** of `corner_case_risk_threshold` and `extension_risk_threshold`, so it is never lower than in a normal round. It applies even when `corner_case_risk_threshold` is off.' <<< "$howto"
  grep -qF 'Across 576 assessments the risk pass wrote in 174 rounds, 58% were below `0.04`, 81% below `0.10` and 91% below `0.15`.' <<< "$howto"
  # the conductor's procedure
  grep -qF 'run this pass in that round **even when `corner_case_risk_threshold` is off**. Dispatch the risk subagent and pass `--risk` as below. The loop adds `--extension` to the consolidator itself, so pass no extra flag.' <<< "$rp"
  grep -qF 'it behaves as the default, `0.10`. Say so once in your narration, and write a one-line PR Summary note naming the value, once per run, whichever terminal the run reaches.' <<< "$rp"
  # the extension round is decided from the grant ledger, the same signal the loop reads
  grep -qF 'when the work-dir'"'"'s grant ledger, `grants.jsonl`, is non-empty **and** the round'"'"'s number is above the `original_max_rounds` its first line records.' <<< "$rp"
  grep -qF 'the `--max-rounds` you resume with does not decide it.' <<< "$rp"
  grep -qF 'the work-dir'"'"'s grant ledger `grants.jsonl`, which `record-grant.zsh` appends to for human and automatic grants alike (#2576), is non-empty and the round is past the `original_max_rounds` its first line records.' <<< "$arch"
  grep -qF '_is_extension_round $(( resume_round + 1 ))' "$SCRIPTS/resolve-story-loop.zsh"
  grep -qF '_is_extension_round "$round" && consolidate_args+=( --extension )' "$SCRIPTS/resolve-story-loop.zsh"
  # the dispatch rules carry the extension-round exception, pointing at the risk pass
  local subag riskb
  subag="$(tr '\n' ' ' < "$SCRIPTS/../reference/review-loop/subagents.md" | tr -s ' ')"
  riskb="$(tr '\n' ' ' < "$SCRIPTS/../reference/review-loop/briefs/risk.md" | tr -s ' ')"
  grep -qF 'An extension round (#2577) is the exception: it is assessed even then, as *The risk pass* says.' <<< "$subag"
  grep -qF 'In step mode, an extension round (#2577) is the exception: dispatch it there whatever this threshold says, as *The risk pass* defines that round.' <<< "$riskb"
  grep -qF 'and passes `--risk`. In an extension round (below) it does so whatever the threshold says.' <<< "$rp"
  # each rule sentence on its own, as the procedure states it
  grep -qF 'Make no assessment and pass no `--risk`.' <<< "$rp"
  grep -qF 'Dispatch the risk subagent and pass `--risk` as below.' <<< "$rp"
  grep -qF 'The loop adds `--extension` to the consolidator itself, so pass no extra flag.' <<< "$rp"
  grep -qF '**A value the rule does not admit:** it behaves as the default, `0.10`.' <<< "$rp"
  grep -qF 'A human grant'"'"'s `severity_bar` is unaffected: the risk bar decides at consolidation what blocks, and the fix subagent still applies the human'"'"'s bar to what remains.' <<< "$rp"
}
