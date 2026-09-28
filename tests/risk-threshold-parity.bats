#!/usr/bin/env bats
#
# #1921 AC7: consolidate-findings.zsh (the in-loop demotion) and
# build-residue-issues.zsh (the residue filter) read `corner_case_risk_threshold`
# through ONE parser, risk-threshold-lib.zsh. If they disagreed on a single
# spelling, a finding could be demoted in the loop and then filed as residue, or
# the reverse, with nothing downstream noticing.
#
# Checked two ways. Behaviourally: each value in #1920's table is fed to both
# scripts, and the state (off / ignored / on) and threshold_thousandths each one
# acts on are read back from what it produces and compared. Structurally: both
# scripts source the library and neither carries a parser of its own, so a
# future edit cannot quietly fork the rule.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/resolve-issue/scripts"
  CON="$SCRIPTS/consolidate-findings.zsh"
  RES="$SCRIPTS/build-residue-issues.zsh"
  LIB="$SCRIPTS/risk-threshold-lib.zsh"

  # one WARNING finding, assessed at risk 0 so it is demoted whenever the
  # threshold is on — the stamp then carries the threshold the consolidator used
  F="$BATS_TEST_TMPDIR/findings.json"
  printf '%s' '[{"severity":"WARNING","dimension":"bugs","file":"a.zsh","line":1,"title":"t","description":"d","reviewer":"r"}]' > "$F"
  RISK="$BATS_TEST_TMPDIR/risk.json"
  printf '%s' '[{"file":"a.zsh","line":1,"dimension":"bugs","title":"t","p":0,"p_why":"w","impact":0.1,"impact_why":"w"}]' > "$RISK"

  # the residue side: the same finding as a residual blocker
  ST="$BATS_TEST_TMPDIR/status.json"
  printf '%s' '{"status":"CONVERGED_WITH_RESIDUE","rounds":1,"final_changelist":{"blocking":[]}}' > "$ST"
  CL="$BATS_TEST_TMPDIR/changelist.json"
  printf '%s' '{"round":1,"blocking":[{"file":"a.zsh","line":1,"dimension":"bugs","title":"t","priority":"High"}]}' > "$CL"
  DROPPED="$BATS_TEST_TMPDIR/dropped.json"
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

# the residue builder's reading, from its dropped record — removed first, so a
# run that writes none cannot be read as the previous value's
res_reading() {  # $1 = the value
  rm -f "$DROPPED"
  run -0 --separate-stderr env corner_case_risk_threshold="$1" GH_BIN=/usr/bin/false \
    zsh "$RES" --status "$ST" --changelist "$CL" --issue 1 --dry-run --risk "$RISK" --dropped-file "$DROPPED"
  reading=$(jq -r '"\(.threshold_state) \(.threshold_thousandths // "-")"' "$DROPPED")
}

@test "#1921 AC7 both scripts read every value in #1920's table into the same state and thousandths" {
  local v reading
  local -a values=('' 0 0.0 .000 0.05 .05 1 1.0 30 1.5 -0.1 0.0005 abc)
  local -a expect=('off -' 'off -' 'off -' 'off -' 'on 50' 'on 50' 'on 1000' 'on 1000'
                   'ignored -' 'ignored -' 'ignored -' 'ignored -' 'ignored -')
  local i
  for i in "${!values[@]}"; do
    v="${values[$i]}"
    con_reading "$v"
    [ "value [$v] consolidator: $reading" = "value [$v] consolidator: ${expect[$i]}" ]
    res_reading "$v"
    [ "value [$v] residue: $reading" = "value [$v] residue: ${expect[$i]}" ]
  done
}

@test "#1921 AC7 unset reads as off in both" {
  run --separate-stderr env -u corner_case_risk_threshold zsh "$CON" --findings "$F" --risk "$RISK"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '[.blocking[], .suggestions[]] | all(has("risk_assessment") | not)' >/dev/null
  run --separate-stderr env -u corner_case_risk_threshold GH_BIN=/usr/bin/false \
    zsh "$RES" --status "$ST" --changelist "$CL" --issue 1 --dry-run --risk "$RISK" --dropped-file "$DROPPED"
  [ "$status" -eq 0 ]
  [ "$(jq -r .threshold_state "$DROPPED")" = "off" ]
}

@test "#1921 AC7 one parser: every reader sources the library, and none carries its own" {
  local s
  for s in "$CON" "$RES" "$SCRIPTS/resolve-story-loop.zsh"; do
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
}
