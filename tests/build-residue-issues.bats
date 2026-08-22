#!/usr/bin/env bats
#
# Behavioral tests for build-residue-issues.zsh (#1435): the follow-up-issue
# PLAN a CONVERGED_WITH_RESIDUE run files for its remaining blockers.
#
# The script is a BUILDER on the build-vs-post split build-escalation.zsh
# already uses — it must never create anything — and it is idempotent on a
# pinned key: the `review-residue` label AND an exact title match among the
# parent's native sub-issues. Both halves are exercised, in both directions.
#
# `gh` is stubbed through the GH_BIN seam, so nothing here touches the network.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/build-residue-issues.zsh"
  ST="$BATS_TEST_TMPDIR/status.json"
  CL="$BATS_TEST_TMPDIR/changelist.json"
  LOG="$BATS_TEST_TMPDIR/gh.log"
  : > "$LOG"

  cat > "$ST" <<'EOF'
{"status":"CONVERGED_WITH_RESIDUE","rounds":5,"max_rounds":5,"repo_type":"claude-plugin",
 "escalation_reasons":[],"history":[],"round_changelists":[],"final_changelist":{"blocking":[]}}
EOF
  # two residual blockers, differing on every field a body has to name
  cat > "$CL" <<'EOF'
{"round":5,"summary":{"critical":0,"high":2,"low":0,"blocking":2,"conflicts":0,"false_trips":0},
 "blocking":[
  {"file":"development/skills/resolve-issue/scripts/resolve-story-loop.zsh","line":1421,
   "dimension":"script_quality","title":"the residue guard reads an unquoted path",
   "description":"An unquoted expansion in the membership test breaks on a path with a space.",
   "suggested_fix":"Quote the expansion.","priority":"High","non_converging":false,
   "class":"incomplete_propagation"},
  {"file":"tests/resolve-story-loop.bats","line":88,
   "dimension":"tests","title":"the new case never asserts the exit code",
   "description":"It asserts the status string but not the code, so a wrong code passes.",
   "suggested_fix":"Assert both.","priority":"High","non_converging":false,
   "class":"under_assertion"}],
 "suggestions":[],"conflicts":[],"non_converging":false,"false_trips":[]}
EOF
}

# a stub that FAILS the moment it is called and writes nothing — so "the log is
# empty" is a real observation about the builder, not about the stub
stub_fail() {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/gh"
  chmod +x "$BATS_TEST_TMPDIR/gh"
}

# a stub that LOGS every invocation, refuses to create anything, and replays $1
# as the parent's native sub-issue list
stub_replay() {  # $1 = JSON array of {title, labels}
  cat > "$BATS_TEST_TMPDIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$LOG"
case "\$*" in
  *"issue create"*) echo "the builder must never create an issue" >&2; exit 9 ;;
esac
cat <<'REPLAY_JSON'
$1
REPLAY_JSON
EOF
  chmod +x "$BATS_TEST_TMPDIR/gh"
}

# --separate-stderr, always: the builder warns on stderr whenever it could not
# read the parent (the FAIL-OPEN path, which several fixtures below deliberately
# take), and a merged stream would put that warning ahead of the JSON contract
# on stdout — every `jq` here would then parse a prose line.
build() { run --separate-stderr env GH_BIN="$BATS_TEST_TMPDIR/gh" zsh "$S" --status "$ST" --changelist "$CL" "$@"; }

@test "#1435 tc-happy-residue-issues-built: one entry per residual blocker, both labels, nothing created" {
  stub_fail
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  # a failing gh never runs a create, so the log stays empty — the builder is
  # incapable of filing anything, which is the whole point of the split
  [ ! -s "$LOG" ]
  # AC13: BOTH labels, on EVERY entry of a multi-finding fixture
  echo "$output" | jq -e 'all(.[]; (.labels | index("review-residue")) != null
                                   and (.labels | index("needs-refinement")) != null)' >/dev/null
}

@test "#1435 each body names the file, line, dimension, severity and class, and links the story" {
  stub_fail
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  local body
  body="$(echo "$output" | jq -r '.[0].body')"
  contains "$body" "development/skills/resolve-issue/scripts/resolve-story-loop.zsh"
  contains "$body" "1421"
  contains "$body" "script_quality"
  contains "$body" "High"
  contains "$body" "incomplete_propagation"
  contains "$body" "#1435"
  # the finding's own detail rides along, so the issue is actionable without
  # opening the run's work-dir
  contains "$body" "breaks on a path with a space"
  # ...and its suggested fix, which is the one field that says what to DO —
  # deleting that block would otherwise leave every case green
  contains "$body" "Suggested fix"
  contains "$body" "Quote the expansion."
  # what --status contributes, which nothing else could supply: the terminal and
  # the round count. Without these, replacing the status read with an empty
  # object makes every body claim "after 0 round(s)" and the suite still passes.
  contains "$body" "CONVERGED_WITH_RESIDUE"
  contains "$body" "after 5 round(s)"
  # ...and the OTHER entry carries its own class, not the first one's
  contains "$(echo "$output" | jq -r '.[1].body')" "under_assertion"
}

@test "#1435 the body's run context FOLLOWS --status rather than being a constant" {
  # The pair to the assertions above: same changelist, different status, so the
  # values are proven to come from the operand.
  cat > "$ST" <<'EOF'
{"status":"CONVERGED_WITH_RESIDUE","rounds":3,"max_rounds":5,"repo_type":"claude-plugin",
 "escalation_reasons":[],"history":[],"round_changelists":[],"final_changelist":{"blocking":[]}}
EOF
  # the changelist's own round must agree with the status, or the cross-check
  # refuses the pair — which is itself the point of the next test
  jq '.round = 3' "$CL" > "$CL.x" && mv "$CL.x" "$CL"
  stub_fail
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  contains "$(echo "$output" | jq -r '.[0].body')" "after 3 round(s)"
}

@test "#1435 a changelist from the WRONG round is refused, naming both numbers" {
  # The status already inlines the run's final changelist, so --changelist can
  # only ever ADD a disagreement — and SKILL.md asks a model to compute the path
  # by hand. An off-by-one would file issues for findings the fix pass already
  # cleared, with titles new enough that the idempotency read filters none.
  jq '.round = 4' "$CL" > "$CL.x" && mv "$CL.x" "$CL"
  stub_fail
  build --issue 1435 --epic 1431
  [ "$status" -eq 2 ]
  contains "$stderr" "--changelist is round 4"
  contains "$stderr" "ended at round 5"
  # the remedy names the file to pass, not just the problem
  contains "$stderr" "changelist-5.json"
}

@test "#1435 a changelist with no .round at all is accepted, not refused" {
  # An older or hand-built fixture legitimately lacks it; refusing would invent a
  # failure mode for a file that is otherwise fine.
  jq 'del(.round)' "$CL" > "$CL.x" && mv "$CL.x" "$CL"
  stub_fail
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
}

@test "#1435 a finding with no line renders no colon in the title and says so in the body" {
  # Neither arm of the line branch is otherwise taken. An unconditional one would
  # put `:null` into a title that is half the idempotency key, so that residue
  # would re-file itself on every run.
  cat > "$CL" <<'EOF'
{"round":5,"summary":{"critical":0,"high":2,"low":0,"blocking":2,"conflicts":0,"false_trips":0},
 "blocking":[
  {"file":"a.zsh","dimension":"bugs","title":"no line at all","description":"d",
   "priority":"High","non_converging":false,"class":"new_defect"},
  {"file":"b.zsh","line":null,"dimension":"bugs","title":"explicit null line","description":"d",
   "priority":"High","non_converging":false,"class":"new_defect"}],
 "suggestions":[],"conflicts":[],"non_converging":false,"false_trips":[]}
EOF
  stub_fail
  build --issue 1435
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].title')" = "review residue: no line at all — a.zsh [bugs]" ]
  [ "$(echo "$output" | jq -r '.[1].title')" = "review residue: explicit null line — b.zsh [bugs]" ]
  contains "$(echo "$output" | jq -r '.[0].body')" "_(none recorded)_"
}

@test "#1435 a finding with no description and no suggested_fix omits those sections entirely" {
  cat > "$CL" <<'EOF'
{"round":5,"summary":{"critical":0,"high":1,"low":0,"blocking":1,"conflicts":0,"false_trips":0},
 "blocking":[{"file":"a.zsh","line":1,"dimension":"bugs","title":"bare finding","description":"",
              "priority":"High","non_converging":false,"class":"new_defect"}],
 "suggestions":[],"conflicts":[],"non_converging":false,"false_trips":[]}
EOF
  stub_fail
  build --issue 1435
  [ "$status" -eq 0 ]
  local body; body="$(echo "$output" | jq -r '.[0].body')"
  lacks "$body" "**Detail**"
  lacks "$body" "**Suggested fix**"
  # ...while the table the issue is actually for is still there
  contains "$body" "| class |"
  contains "$body" "bare finding"
}

@test "#1435 the title carries file, line and dimension, so it is stable across two runs of one round" {
  stub_fail
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  local t1; t1="$(echo "$output" | jq -r '.[0].title')"
  contains "$t1" "review residue:"
  contains "$t1" "resolve-story-loop.zsh:1421"
  contains "$t1" "[script_quality]"
  # deterministic: the same inputs give byte-identical titles, which is what the
  # idempotency key rests on
  build --issue 1435 --epic 1431
  [ "$(echo "$output" | jq -r '.[0].title')" = "$t1" ]
}

@test "#1435 AC12: --epic parents every entry to the epic" {
  stub_fail
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'all(.[]; .parent == 1431)' >/dev/null
}

@test "#1435 tc-corner-residue-no-epic-parent: without --epic the parent is the story itself" {
  stub_fail
  build --issue 1435
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'all(.[]; .parent == 1435)' >/dev/null
  # ...and the labels are unaffected by the linkage shape
  echo "$output" | jq -e 'all(.[]; (.labels | index("review-residue")) != null
                                   and (.labels | index("needs-refinement")) != null)' >/dev/null
}

@test "#1435 tc-corner-residue-idempotent: a labelled, exactly-titled sub-issue suppresses its candidate" {
  # run 1 against a parent with nothing attached
  stub_replay '[]'
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  local filed; filed="$(echo "$output" | jq -c '[.[] | {title: .title, labels: ["review-residue"]}]')"

  # run 2: the stub replays run 1's issues as the parent's sub-issues
  : > "$LOG"
  stub_replay "$filed"
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
  # the read really went to the PARENT's sub-issues. Without this, pointing the
  # API at the story instead passes every case here — the stub replays the same
  # JSON whatever it is handed — while a real epic-parented run would query the
  # wrong issue and re-file every residue issue on every run.
  contains "$(cat "$LOG")" "repos/{owner}/{repo}/issues/1431/sub_issues"
  # ...paginated, or a parent with more than one page of sub-issues silently
  # loses its idempotency key
  contains "$(cat "$LOG")" "--paginate"
  # ...and it got there without creating anything
  run ! grep -q 'issue create' "$LOG"
}

@test "#1435 without --epic the idempotency read targets the STORY's sub-issues" {
  # the other half of the linkage: the read must follow the same parent the plan
  # parents to, or the two disagree about what "already filed" means
  stub_replay '[]'
  build --issue 1435
  [ "$status" -eq 0 ]
  contains "$(cat "$LOG")" "repos/{owner}/{repo}/issues/1435/sub_issues"
}

@test "#1435 reviewer-authored text is length-capped, title and body alike" {
  # The caps are what keep a pathological title under the GitHub limit — and the
  # title is half the idempotency key, so a 422 that a caller works around by
  # shortening it creates an issue the next run cannot match.
  local long_title long_desc
  long_title="$(printf 'w%.0s' {1..400})"
  long_desc="$(printf 'd%.0s' {1..3000})"
  jq -n --arg t "$long_title" --arg d "$long_desc" \
    '{round:5, summary:{critical:0,high:1,low:0,blocking:1,conflicts:0,false_trips:0},
      blocking:[{file:"a.zsh", line:1, dimension:"bugs", title:$t, description:$d,
                 priority:"High", non_converging:false, class:"new_defect"}],
      suggestions:[], conflicts:[], non_converging:false, false_trips:[]}' > "$CL"
  stub_fail
  build --issue 1435
  [ "$status" -eq 0 ]
  local t; t="$(echo "$output" | jq -r '.[0].title')"
  # comfortably inside GitHub's 256-character issue-title limit
  [ "${#t}" -le 250 ]
  # ...and the body's own cap holds, so one finding cannot produce a megabyte issue
  [ "$(echo "$output" | jq -r '.[0].body' | wc -c)" -lt 4000 ]
}

@test "#1435 the assembled title is capped, not merely its title component" {
  # A short finding title plus a very deep path still clears the limit, which the
  # per-component cap alone would not catch.
  local deep
  deep="$(printf 'a-very-long-directory-segment/%.0s' {1..12})file.zsh"
  jq -n --arg f "$deep" \
    '{round:5, summary:{critical:0,high:1,low:0,blocking:1,conflicts:0,false_trips:0},
      blocking:[{file:$f, line:1, dimension:"script_quality", title:"short",
                 description:"d", priority:"High", non_converging:false, class:"new_defect"}],
      suggestions:[], conflicts:[], non_converging:false, false_trips:[]}' > "$CL"
  stub_fail
  build --issue 1435
  [ "$status" -eq 0 ]
  local t; t="$(echo "$output" | jq -r '.[0].title')"
  [ "${#t}" -le 250 ]
  # the path really was over-long, or this pins nothing
  [ "${#deep}" -gt 250 ]
}

@test "#1435 --epic is validated as an issue number, like --issue" {
  # Without the guard the value reaches --argjson as raw JSON and dies as an
  # internal error, misdiagnosing a caller mistake.
  stub_fail
  build --issue 1435 --epic '#1431'
  [ "$status" -eq 2 ]
  contains "$stderr" "--epic must be a positive issue number"
}

@test "#1435 an unknown flag and an unexpected argument are usage errors" {
  stub_fail
  build --issue 1435 --bogus
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown flag"

  build --issue 1435 leftover
  [ "$status" -eq 2 ]
  contains "$stderr" "unexpected argument"
}

@test "#1435 --help prints the usage and exits 0" {
  stub_fail
  run --separate-stderr env GH_BIN="$BATS_TEST_TMPDIR/gh" zsh "$S" --help
  [ "$status" -eq 0 ]
  contains "$output" "usage: build-residue-issues.zsh"
}

@test "#1435 a DIRECTORY operand is named as one, not relabelled a content problem" {
  stub_fail
  run --separate-stderr env GH_BIN="$BATS_TEST_TMPDIR/gh" zsh "$S" \
    --status "$BATS_TEST_TMPDIR" --changelist "$CL" --issue 1435
  [ "$status" -eq 2 ]
  contains "$stderr" "--status is a directory"
}

@test "#1435 an EMPTY operand file is an input failure (1), not a caller mistake (2)" {
  stub_fail
  : > "$BATS_TEST_TMPDIR/empty.json"
  run --separate-stderr env GH_BIN="$BATS_TEST_TMPDIR/gh" zsh "$S" \
    --status "$ST" --changelist "$BATS_TEST_TMPDIR/empty.json" --issue 1435
  [ "$status" -eq 1 ]
  contains "$stderr" "--changelist file is empty"
}

@test "#1435 a non-existent --changelist is a caller mistake (2), like --status" {
  stub_fail
  run --separate-stderr env GH_BIN="$BATS_TEST_TMPDIR/gh" zsh "$S" \
    --status "$ST" --changelist "$BATS_TEST_TMPDIR/nope.json" --issue 1435
  [ "$status" -eq 2 ]
  contains "$stderr" "--changelist file does not exist"
}

@test "#1435 a same-title sub-issue WITHOUT the label does not suppress the candidate" {
  stub_fail
  build --issue 1435 --epic 1431
  local titles; titles="$(echo "$output" | jq -c '[.[] | {title: .title, labels: ["bug"]}]')"
  stub_replay "$titles"
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  # both halves of the key are required: a collision on title alone is somebody
  # else's issue, not this residue already filed
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
}

@test "#1435 a LABELLED sub-issue with a different title does not suppress the candidate" {
  stub_replay '[{"title":"review residue: something else — other.zsh:1 [bugs]","labels":["review-residue"]}]'
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
}

@test "#1435 a failed GitHub read is FAIL-OPEN, loudly — the plan still lands" {
  stub_fail
  run --separate-stderr env GH_BIN="$BATS_TEST_TMPDIR/gh" zsh "$S" \
    --status "$ST" --changelist "$CL" --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  # refusing would block a green, reviewed PR on a GitHub outage — so it warns
  # instead, and the warning has to say what the risk is. It names BOTH sources,
  # because with both lost the plan really is unfiltered — naming only the
  # parent read would understate it.
  contains "$stderr" "could not read EITHER idempotency source"
  contains "$stderr" "#1431"
  contains "$stderr" "may duplicate them"
  # ...and the NARROWED-filter warnings must stay silent here: both of them claim
  # a filter that did in fact run, which is false when neither read returned.
  # Without this the gate collapses back to a single condition and the run log
  # asserts a narrow filter three lines above the fail-open line denying it.
  lacks "$stderr" "the plan is filtered only against"
}

@test "#1435 --dry-run makes NO GitHub call at all and says the plan is unfiltered" {
  stub_replay '[]'
  run --separate-stderr env GH_BIN="$BATS_TEST_TMPDIR/gh" zsh "$S" \
    --status "$ST" --changelist "$CL" --issue 1435 --epic 1431 --dry-run
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  [ ! -s "$LOG" ]
  contains "$stderr" "NOT filtered"
}

@test "#1435 a changelist with no blockers yields an empty plan, and skips the read entirely" {
  cat > "$CL" <<'EOF'
{"round":5,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0,"false_trips":0},
 "blocking":[],"suggestions":[],"conflicts":[],"non_converging":false,"false_trips":[]}
EOF
  stub_replay '[]'
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  # there is nothing an existing-issue list could remove, so the round-trip is
  # skipped rather than spent
  [ ! -s "$LOG" ]
}

@test "#1435 two findings that would produce the same title collapse to one entry" {
  # The title carries file, line and dimension, so a collision means the same
  # defect at the same place. Filing both would defeat the idempotency promise
  # on the very first run, before any second run could.
  cat > "$CL" <<'EOF'
{"round":5,"summary":{"critical":0,"high":2,"low":0,"blocking":2,"conflicts":0,"false_trips":0},
 "blocking":[
  {"file":"a.zsh","line":10,"dimension":"bugs","title":"same title","description":"one",
   "priority":"High","non_converging":false,"class":"new_defect"},
  {"file":"a.zsh","line":10,"dimension":"bugs","title":"same title","description":"two",
   "priority":"High","non_converging":false,"class":"new_defect"}],
 "suggestions":[],"conflicts":[],"non_converging":false,"false_trips":[]}
EOF
  stub_fail
  build --issue 1435
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 1 ]
}

@test "#1435 a reviewer-authored title cannot forge markdown or break the JSON" {
  cat > "$CL" <<'EOF'
{"round":5,"summary":{"critical":0,"high":1,"low":0,"blocking":1,"conflicts":0,"false_trips":0},
 "blocking":[
  {"file":"a.zsh","line":1,"dimension":"bugs",
   "title":"line one\nline two `whoami`","description":"d",
   "priority":"High","non_converging":false,"class":"new_defect"}],
 "suggestions":[],"conflicts":[],"non_converging":false,"false_trips":[]}
EOF
  stub_fail
  build --issue 1435
  [ "$status" -eq 0 ]
  local t; t="$(echo "$output" | jq -r '.[0].title')"
  # newlines and backticks are neutralised: the title becomes a GitHub issue
  # title AND half of an equality test, so neither may carry either
  run ! grep -q '`' <<< "$t"
  [ "$(printf '%s' "$t" | grep -c '')" -eq 1 ]
}

@test "#1435 a --status that is not a residue run is refused, naming what it got" {
  # Residue is only filed for a run that OPENED its PR, and the terminal residue
  # replaces is an escalation that opened none. The round cross-check cannot
  # catch this: an escalation status paired with its OWN final-round changelist
  # is self-consistent, so both numbers agree and it sails through.
  stub_fail
  local st
  for st in ESCALATE_NO_CONVERGENCE BUDGET_EXHAUSTED ESCALATE_CONFLICT CONVERGED; do
    jq --arg s "$st" '.status = $s' "$ST" > "$ST.x"
    mv "$ST.x" "$ST"
    build --issue 1435 --epic 1431
    [ "$st: $status" = "$st: 2" ]
    # the diagnostic echoes the value, so an arm printing a constant is excluded
    contains "$stderr" "got: $st"
    contains "$stderr" "must be a CONVERGED_WITH_RESIDUE run"
    # ...and nothing is planned, so no caller can file from a refused run
    [ -z "$output" ]
  done
}

@test "#1435 a status JSON with no .status at all is refused, naming the gap" {
  stub_fail
  jq 'del(.status)' "$ST" > "$ST.x"
  mv "$ST.x" "$ST"
  build --issue 1435 --epic 1431
  [ "$status" -eq 2 ]
  contains "$stderr" "got: <none>"
}

@test "#1435 the title's discriminating tail survives, so two lenses on one spot stay distinct" {
  # The whole point of building the tail first: two findings at the SAME
  # file+line differing only in dimension are the ordinary case (two reviewers,
  # different lenses), and a right-truncating cap would render them identically —
  # and the rendered title is the pinned idempotency key.
  local long_title
  long_title="$(printf 'w%.0s' {1..300})"
  jq -n --arg t "$long_title" \
    '{round:5, summary:{critical:0,high:2,low:0,blocking:2,conflicts:0,false_trips:0},
      blocking:[{file:"development/skills/resolve-issue/scripts/resolve-story-loop.zsh", line:10,
                 dimension:"bugs", title:$t, description:"d", priority:"High",
                 non_converging:false, class:"new_defect"},
                {file:"development/skills/resolve-issue/scripts/resolve-story-loop.zsh", line:10,
                 dimension:"script_quality", title:$t, description:"d", priority:"High",
                 non_converging:false, class:"new_defect"}],
      suggestions:[], conflicts:[], non_converging:false, false_trips:[]}' > "$CL"
  stub_fail
  build --issue 1435
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  local t0 t1
  t0="$(echo "$output" | jq -r '.[0].title')"
  t1="$(echo "$output" | jq -r '.[1].title')"
  # the titles are DISTINCT — a right-truncating cap renders them identical
  [ "$t0" != "$t1" ]
  # ...because each kept its own tail, not merely because they differ somewhere
  contains "$t0" "[bugs]"
  contains "$t1" "[script_quality]"
  contains "$t0" "resolve-story-loop.zsh:10"
  contains "$t1" "resolve-story-loop.zsh:10"
  # ...and both are still inside the GitHub limit
  [ "${#t0}" -le 250 ]
  [ "${#t1}" -le 250 ]
}

@test "#1435 the deep-path title still ends in its dimension, so the floor arm is not free" {
  local deep
  deep="$(printf 'a-very-long-directory-segment/%.0s' {1..12})file.zsh"
  jq -n --arg f "$deep" \
    '{round:5, summary:{critical:0,high:1,low:0,blocking:1,conflicts:0,false_trips:0},
      blocking:[{file:$f, line:1, dimension:"script_quality", title:"short",
                 description:"d", priority:"High", non_converging:false, class:"new_defect"}],
      suggestions:[], conflicts:[], non_converging:false, false_trips:[]}' > "$CL"
  stub_fail
  build --issue 1435
  [ "$status" -eq 0 ]
  local t; t="$(echo "$output" | jq -r '.[0].title')"
  [ "${#t}" -le 250 ]
  # the tail is bounded BEFORE assembly, so it is never the part that gets cut —
  # ENDS_WITH, not contains: containment cannot tell "the tail survived" from
  # "the tail sits mid-string", which is the whole claim here
  ends_with "$t" "[script_quality]"
  # ...and the body still carries the FULL path, which has no length contract
  contains "$(echo "$output" | jq -r '.[0].body')" "$deep"
}

@test "#1435 dedupe is keyed on the raw identity, not on the rendered title" {
  # Two genuinely different findings whose titles cap to the same string. A
  # title-keyed dedupe drops one SILENTLY — a residual blocker never filed, in
  # the one mechanism whose whole point is that the remainder lands somewhere.
  local a b
  a="$(printf 'x%.0s' {1..300})A"
  b="$(printf 'x%.0s' {1..300})B"
  jq -n --arg a "$a" --arg b "$b" \
    '{round:5, summary:{critical:0,high:2,low:0,blocking:2,conflicts:0,false_trips:0},
      blocking:[{file:"a.zsh", line:5, dimension:"bugs", title:$a, description:"one",
                 priority:"High", non_converging:false, class:"new_defect"},
                {file:"a.zsh", line:5, dimension:"bugs", title:$b, description:"two",
                 priority:"High", non_converging:false, class:"new_defect"}],
      suggestions:[], conflicts:[], non_converging:false, false_trips:[]}' > "$CL"
  stub_fail
  build --issue 1435
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  # the non-vacuity control: the fixture really does render ONE string, so a
  # title-keyed dedupe would have collapsed it
  [ "$(echo "$output" | jq -r '.[0].title')" = "$(echo "$output" | jq -r '.[1].title')" ]
  # ...and the two entries are distinguishable where it matters
  [ "$(echo "$output" | jq -r '.[0].body')" != "$(echo "$output" | jq -r '.[1].body')" ]
}

@test "#1435 the plan keeps the changelist's order — Critical first, never re-sorted" {
  # The reduce is deliberately not `unique_by`, which SORTS: the consolidator
  # ranks the changelist Critical-first and §3.5 creates issues in plan order, so
  # re-alphabetising would file the worst findings last. The input order here is
  # deliberately ANTI-alphabetical, or `unique_by` would pass.
  cat > "$CL" <<'EOF'
{"round":5,"summary":{"critical":1,"high":1,"low":0,"blocking":2,"conflicts":0,"false_trips":0},
 "blocking":[
  {"file":"z-app.zsh","line":1,"dimension":"bugs","title":"critical first","description":"d",
   "priority":"Critical","non_converging":false,"class":"new_defect"},
  {"file":"a-lib.zsh","line":2,"dimension":"bugs","title":"high second","description":"d",
   "priority":"High","non_converging":false,"class":"new_defect"}],
 "suggestions":[],"conflicts":[],"non_converging":false,"false_trips":[]}
EOF
  stub_fail
  build --issue 1435
  [ "$status" -eq 0 ]
  contains "$(echo "$output" | jq -r '.[0].title')" "z-app.zsh"
  contains "$(echo "$output" | jq -r '.[1].title')" "a-lib.zsh"
}

@test "#1435 a missing required flag is a usage error" {
  stub_fail
  run --separate-stderr env GH_BIN="$BATS_TEST_TMPDIR/gh" zsh "$S" --status "$ST" --issue 1435
  [ "$status" -eq 2 ]
  contains "$stderr" "usage: build-residue-issues.zsh"
}

@test "#1435 a dangling value flag, and one whose value is the next flag, are usage errors" {
  stub_fail
  build --issue
  [ "$status" -eq 2 ]
  contains "$stderr" "--issue requires a value"

  build --issue --epic 1431
  [ "$status" -eq 2 ]
  contains "$stderr" "got the flag"
}

@test "#1435 a non-numeric --issue never reaches jq as raw JSON or GitHub as a path" {
  stub_fail
  build --issue "#1435"
  [ "$status" -eq 2 ]
  contains "$stderr" "--issue must be a positive issue number"
}

@test "#1435 a non-existent operand is the CALLER's mistake (2), so a path typo stays distinguishable" {
  stub_fail
  run --separate-stderr env GH_BIN="$BATS_TEST_TMPDIR/gh" zsh "$S" \
    --status "$BATS_TEST_TMPDIR/nope.json" --changelist "$CL" --issue 1435
  [ "$status" -eq 2 ]
  contains "$stderr" "--status file does not exist"
}

@test "#1435 an UNREADABLE operand is an input failure (1), keeping the taxonomy split" {
  # The pair to the non-existent case above: a path that does not exist is the
  # CALLER's mistake (2), one that exists but cannot be read is an input failure
  # (1). Collapsing the two would erase the distinction the script's own header
  # documents, and every sibling suite in this directory tests this arm.
  stub_fail
  chmod 000 "$ST"
  if [ -r "$ST" ]; then chmod 644 "$ST"; skip "running as a user that bypasses file permissions"; fi
  run --separate-stderr env GH_BIN="$BATS_TEST_TMPDIR/gh" zsh "$S" \
    --status "$ST" --changelist "$CL" --issue 1435
  chmod 644 "$ST"
  [ "$status" -eq 1 ]
  contains "$stderr" "--status file not readable"
}

@test "#1435 an absent jq is named as such, not misdiagnosed as invalid JSON" {
  # The guard exists because the `||` branches below it would otherwise report
  # "not exactly one JSON object" for an environment problem — the wrong
  # diagnosis this directory has already had to fix once. Deleting it passes
  # every other case.
  stub_fail
  mkdir -p "$BATS_TEST_TMPDIR/nojq"
  ln -sf "$(command -v zsh)" "$BATS_TEST_TMPDIR/nojq/zsh"
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/nojq" GH_BIN="$BATS_TEST_TMPDIR/gh" \
    "$(command -v zsh)" "$S" --status "$ST" --changelist "$CL" --issue 1435
  [ "$status" -eq 1 ]
  contains "$stderr" "jq not found on PATH"
  # ...and the wrong diagnosis is what is being excluded
  lacks "$stderr" "not exactly one JSON object"
}

@test "#1435 an explicitly EMPTY value gets its own diagnostic, not the generic usage line" {
  # `--issue ""` is the realistic `--issue "$VAR"` slip with VAR unset. Both
  # arms exit 2, so only the message distinguishes them — which is the whole
  # value of the arm.
  stub_fail
  build --issue ""
  [ "$status" -eq 2 ]
  contains "$stderr" "--issue requires a non-empty value"
}

@test "#1435 a malformed operand is an input failure (1), named by its own flag" {
  stub_fail
  printf 'not json' > "$BATS_TEST_TMPDIR/bad.json"
  run --separate-stderr env GH_BIN="$BATS_TEST_TMPDIR/gh" zsh "$S" --status "$ST" \
    --changelist "$BATS_TEST_TMPDIR/bad.json" --issue 1435
  [ "$status" -eq 1 ]
  contains "$stderr" "--changelist is not exactly one JSON object"
  # ...and never blamed on --status, which is perfectly good
  lacks "$stderr" "--status is not"
}

@test "#1435 issue number 0 is refused on BOTH flags — the shape test alone lets it through" {
  # `0` is the one value the guard's two halves disagree about: `<->` matches it
  # (it is a run of digits) and `${#2} -le 18` accepts it, so ONLY the `>= 1`
  # half rejects it. Every existing guard test passes a non-numeric value, which
  # `<->` already catches — so drop `(( 10#$2 >= 1 ))` and the whole suite stays
  # green while `--issue 0` sails through.
  #
  # What it would produce is not a cosmetic defect: `parent: 0` in the plan, a
  # `repos/{owner}/{repo}/issues/0/sub_issues` probe whose 404 is indistinguishable
  # from the fail-open "could not read existing sub-issues" path, and bodies that
  # say "story #0". The skill then files real residue issues under an issue that
  # does not exist.
  stub_fail
  build --issue 0
  [ "$status" -eq 2 ]
  contains "$stderr" "--issue must be a positive issue number"
  # the message quotes the offending value, so a caller sees WHICH argument
  contains "$stderr" "(got: 0)"

  # ...and the same on --epic, whose guard is a separate call site: a fix applied
  # to one and not the other would leave residue parented to a nonexistent epic.
  stub_fail
  build --issue 1435 --epic 0
  [ "$status" -eq 2 ]
  contains "$stderr" "--epic must be a positive issue number"

  # non-vacuity: the very same invocations with 1 substituted for 0 succeed, so
  # the rejections above are about the value and not about the fixture.
  stub_fail
  build --issue 1
  [ "$status" -eq 0 ]
  stub_fail
  build --issue 1435 --epic 1
  [ "$status" -eq 0 ]
}

# a stub that replays the parent's sub-issues as TWO SEPARATE JSON arrays, which
# is what `gh api --paginate` actually emits for a multi-page result: one array
# per page, concatenated on stdout — NOT one merged array
stub_replay_pages() {  # $1, $2 = JSON arrays of {title, labels}
  cat > "$BATS_TEST_TMPDIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$LOG"
case "\$*" in
  *"issue create"*) echo "the builder must never create an issue" >&2; exit 9 ;;
esac
cat <<'REPLAY_JSON'
$1
$2
REPLAY_JSON
EOF
  chmod +x "$BATS_TEST_TMPDIR/gh"
}

@test "#1435 a MULTI-PAGE sub-issue list is merged, not truncated to its first page" {
  # The builder slurps `gh api --paginate` output with `jq -cs 'add // []'`, and
  # the slurp IS the merge: --paginate emits one array per page, so a single-page
  # fixture cannot tell `add` from `.[0]`. Every stub in this file emits exactly
  # one array, so the only thing asserted about pagination anywhere is a grep for
  # the flag in the command line.
  #
  # Surviving mutation: `jq -cs 'add // []'` -> `jq -cs '.[0] // []'`. Every
  # single-page case stays byte-identical and green, while a parent with more
  # than one page of sub-issues silently loses every page after the first — the
  # pinned idempotency key stops matching those, and their residue issues are
  # re-filed as duplicates on every single run. That is the exact outcome the
  # idempotency contract exists to prevent, and nothing would have caught it.
  stub_replay '[]'
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]

  # split run 1's two candidates across two PAGES, one each
  local p1 p2
  p1="$(echo "$output" | jq -c '[.[0] | {title: .title, labels: ["review-residue"]}]')"
  p2="$(echo "$output" | jq -c '[.[1] | {title: .title, labels: ["review-residue"]}]')"

  : > "$LOG"
  stub_replay_pages "$p1" "$p2"
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  # BOTH are suppressed. Under the `.[0]` mutation the second page is invisible
  # and this is 1, not 0 — which is the whole point of the fixture.
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
}

@test "#1435 non-vacuity: the same two pages, each holding an UNRELATED title, suppress nothing" {
  # Proves the suppression above is the merge doing its job and not the builder
  # dropping candidates for some other reason — swap the titles and both survive.
  stub_replay_pages '[{"title":"review residue: something else — a.zsh:1 [bugs]","labels":["review-residue"]}]' \
                    '[{"title":"review residue: another thing — b.zsh:2 [tests]","labels":["review-residue"]}]'
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
}

@test "#1435 an EMPTY gh body leaves the plan unfiltered instead of failing the run" {
  # The `// []` half of `add // []`. `jq -cs` over no input yields `null`, and
  # `add` over an empty slurp yields `null` too — so without the fallback the
  # filter step dies and the builder exits 1 with "could not filter the plan",
  # turning a parent that simply has no sub-issues (or a gh that printed nothing)
  # into a hard failure of a run that had every right to proceed.
  cat > "$BATS_TEST_TMPDIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$LOG"
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/gh"
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  # exit 0 + an unfiltered plan is ALSO what the loud fail-open branch produces,
  # so those two assertions alone do not identify the branch this test is named
  # for. Surviving mutation without the needle below: `add // []` -> `add //
  # empty`, which makes an empty body print nothing, sends the run down fail-open,
  # and logs "could not read the sub-issues" for a parent that was read perfectly
  # well and simply has none — a false alarm on every FIRST residue filing, which
  # is exactly the signal the fail-open design tells a human to act on.
  lacks "$stderr" "could not read the sub-issues"
  # ...and the read really was attempted, so the silence is about the parse and
  # not about a call that never happened
  [ -s "$LOG" ]
}

@test "#1435 a created-but-UNATTACHED issue is caught by the repo-wide half of the key" {
  # The sub-issue read alone leaves a hole exactly where the filing is least
  # atomic: SKILL.md creates each entry and THEN attaches it, two API calls, so a
  # create that succeeds before a failed or interrupted attach leaves a real
  # `review-residue` issue no parent-scoped read can see. The re-run files it
  # again, and the duplicate carries `needs-refinement`, so once attached it
  # halts the parent epic walk twice on one finding.
  #
  # The stub below models exactly that state: the parent has NO sub-issues, while
  # the repo-wide listing DOES carry one of the two candidate titles.
  stub_replay '[]'
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  # gh's REAL shape for `--json labels` is an array of OBJECTS, not strings. The
  # script normalises them in-process (`if type == "object" then .name`), and
  # that jq — unlike the sub-issue read's, which runs inside gh — is reachable
  # from here. Every other fixture uses plain strings, so deleting the
  # normalisation would leave them all green while production suppressed nothing
  # and the unattached-duplicate hole reopened. This fixture is the object arm.
  local orphan
  orphan="$(echo "$output" | jq -c '[.[0] | {title: .title, labels: [{name: "review-residue", color: "ededed"}]}]')"

  : > "$LOG"
  cat > "$BATS_TEST_TMPDIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$LOG"
case "\$*" in
  *"issue create"*) echo "the builder must never create an issue" >&2; exit 9 ;;
  *"issue list"*)   cat <<'REPO_JSON'
$orphan
REPO_JSON
                    exit 0 ;;
esac
# the parent has no sub-issues — the orphan was created but never attached
echo '[]'
EOF
  chmod +x "$BATS_TEST_TMPDIR/gh"

  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  # the orphan is suppressed, so the re-run does NOT duplicate it
  [ "$(echo "$output" | jq 'length')" -eq 1 ]
  # ...and the read really was repo-wide, on the pinned label
  contains "$(cat "$LOG")" "issue list"
  contains "$(cat "$LOG")" "review-residue"
}

@test "#1435 the repo-wide read is BEST-EFFORT: an OUTER failure keeps the sub-issue answer" {
  # Scoped honestly: this covers the case where the `gh issue list` CALL itself
  # fails, which skips the whole enclosing block. It does NOT reach the
  # temp-and-commit merge guard — the sibling UNPARSEABLE test does that, by
  # making the call succeed with output that will not parse. Stating the wrong
  # scope here is how a test comes to assert something that still holds under the
  # mutation it names.
  stub_replay '[]'
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  local filed
  filed="$(echo "$output" | jq -c '[.[] | {title: .title, labels: ["review-residue"]}]')"

  : > "$LOG"
  cat > "$BATS_TEST_TMPDIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$LOG"
case "\$*" in
  *"issue create"*) echo "the builder must never create an issue" >&2; exit 9 ;;
  *"issue list"*)   echo "repo-wide read exploded" >&2; exit 1 ;;
esac
cat <<'REPLAY_JSON'
$filed
REPLAY_JSON
EOF
  chmod +x "$BATS_TEST_TMPDIR/gh"

  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  # the sub-issue answer still suppressed BOTH — the failed widening changed nothing
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
  # ...and this is NOT the loud fail-open path: the parent read succeeded
  lacks "$stderr" "could not read the sub-issues"
  # ...but the lost widening IS announced. Without this, running the repo-wide
  # read unconditionally (no `if` wrapper) would make a hard failure silent: the
  # empty raw value parses to the STRING `[]`, which is non-empty, so the guard
  # never fires — exactly the regression the warning exists to prevent.
  contains "$stderr" "repo-wide review-residue read failed"
  contains "$stderr" "only against #1431"
}


# a stub that answers the TWO reads DIFFERENTLY: $1 for the parent's sub-issues,
# $2 for the repo-wide listing. Every earlier stub replayed one array to both,
# which made the union indistinguishable from either half alone.
stub_two_sources() {  # $1 = sub_issues JSON, $2 = repo-wide JSON
  cat > "$BATS_TEST_TMPDIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$LOG"
case "\$*" in
  *"issue create"*) echo "the builder must never create an issue" >&2; exit 9 ;;
  *"issue list"*)   cat <<'REPO_JSON'
$2
REPO_JSON
                    exit 0 ;;
esac
cat <<'SUB_JSON'
$1
SUB_JSON
EOF
  chmod +x "$BATS_TEST_TMPDIR/gh"
}

@test "#1435 the two reads are UNIONED, never one replacing the other" {
  # Every earlier fixture replayed identical content to both calls, so `$a + $b`,
  # `$a` alone and `$b` alone were indistinguishable. Surviving mutation: change
  # the merge to `$b` — the repo-wide answer REPLACES the sub-issue answer, which
  # the script comment explicitly forbids. In production a genuinely attached
  # sub-issue whose title falls outside the repo-wide window stops being
  # suppressed and is duplicated on every re-run.
  stub_replay '[]'
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  local sub_only repo_only
  sub_only="$(echo "$output" | jq -c '[.[0] | {title: .title, labels: ["review-residue"]}]')"
  repo_only="$(echo "$output" | jq -c '[.[1] | {title: .title, labels: ["review-residue"]}]')"

  : > "$LOG"
  stub_two_sources "$sub_only" "$repo_only"
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  # BOTH suppressed — one from each source. Under `$a` alone or `$b` alone this
  # is 1, which is exactly the mutation the earlier fixtures could not see.
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
}

@test "#1435 the repo-wide read asks for CLOSED issues too, and a wide enough window" {
  # `--state all` and `--limit 200` are load-bearing, not decoration. Dropping
  # the state flag makes an already-filed residue issue a human CLOSED invisible
  # to the key, so it is re-filed on every run — the duplicate wave the widening
  # exists to prevent. Dropping the limit falls back to gh's default of 30,
  # silently truncating the repo-wide half exactly like the first-page truncation
  # the multi-page test was written for.
  stub_replay '[]'
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  local filed
  filed="$(echo "$output" | jq -c '[.[] | {title: .title, labels: ["review-residue"]}]')"

  : > "$LOG"
  stub_two_sources '[]' "$filed"
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
  contains "$(cat "$LOG")" "--state all"
  contains "$(cat "$LOG")" "--limit 200"
  # the label half of the key depends entirely on this field selection: drop
  # `labels` and every entry arrives unlabelled, the membership test matches
  # nothing, and the repo-wide half suppresses nothing — the same duplicate wave
  # as dropping `--state all`, which this test already guards.
  contains "$(cat "$LOG")" "--json title,labels"
  # ...and a run where the read WORKED does not cry wolf. Tightening the guard to
  # also fire on an empty array — a plausible reading of its own wording — would
  # warn on every FIRST residue filing, where `[]` is the correct answer.
  lacks "$stderr" "repo-wide review-residue read failed"
}

@test "#1435 the repo-wide read RESCUES a failed parent read" {
  # The branch where the parent-scoped read failed but the repo-wide one
  # succeeded was reached by no fixture: the failing stub fails BOTH calls and
  # every other stub answers both. Surviving mutation: delete that branch — the
  # run falls to the loud fail-open path and re-files every candidate, duplicates
  # in precisely the degraded state the widening was added for.
  stub_replay '[]'
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  local filed
  filed="$(echo "$output" | jq -c '[.[] | {title: .title, labels: ["review-residue"]}]')"

  : > "$LOG"
  cat > "$BATS_TEST_TMPDIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$LOG"
case "\$*" in
  *"issue create"*) echo "the builder must never create an issue" >&2; exit 9 ;;
  *"issue list"*)   cat <<'REPO_JSON'
$filed
REPO_JSON
                    exit 0 ;;
esac
echo "the parent read exploded" >&2; exit 1
EOF
  chmod +x "$BATS_TEST_TMPDIR/gh"

  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  # fully suppressed on the repo-wide half alone — NOT the fail-open path
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
}

@test "#1435 a repo-wide read that returns UNPARSEABLE output keeps the sub-issue answer" {
  # The reachable clobber: the call exits 0 but its output does not parse, so the
  # merge operand is empty and jq fails. The sibling test cannot reach this — its
  # stub makes the call exit 1, skipping the whole block — so it asserted
  # something that still held under its own named mutation. This one enters the
  # block and exercises the temp-and-commit-only-on-success guard.
  stub_replay '[]'
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  local filed
  filed="$(echo "$output" | jq -c '[.[] | {title: .title, labels: ["review-residue"]}]')"

  : > "$LOG"
  cat > "$BATS_TEST_TMPDIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$LOG"
case "\$*" in
  *"issue create"*) echo "the builder must never create an issue" >&2; exit 9 ;;
  *"issue list"*)   printf 'not json\n'; exit 0 ;;
esac
cat <<'SUB_JSON'
$filed
SUB_JSON
EOF
  chmod +x "$BATS_TEST_TMPDIR/gh"

  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  # the narrow read SURVIVED the failed widening
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
  # ...and this is not the loud fail-open path: the parent read succeeded
  lacks "$stderr" "could not read the sub-issues"
  # ...but the degradation IS announced, so it is not a silent loss
  contains "$stderr" "repo-wide review-residue read failed"
}

@test "#1435 an EMPTY repo-wide answer is not a failure: the first residue filing does not cry wolf" {
  # `[]` is the CORRECT answer on a first run — no residue issue exists yet — and
  # it is a non-empty string, which is exactly how an empty-vs-failed conflation
  # gets written. Surviving mutation without this: tighten the gate to fire on
  # `[]` too (a plausible reading of the message's own "or returned nothing
  # usable"), and every first residue filing warns that the read failed. The
  # sibling absence assertion cannot catch it — its stub returns a NON-empty
  # array, so the mutation is invisible there.
  # (NB: no stray apostrophes in these comments — the inert-assertion scanner
  # tracks quote parity across lines and an odd one desyncs the whole scan.)
  stub_two_sources '[]' '[]'
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  # nothing filed yet, so nothing suppressed
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  lacks "$stderr" "repo-wide review-residue read failed"
  lacks "$stderr" "could not read"
  # ...and both reads really were attempted, so the silence is about their
  # ANSWER and not about calls that never happened
  contains "$(cat "$LOG")" "sub_issues"
  contains "$(cat "$LOG")" "issue list"
}

@test "#1435 a failed PARENT read with a working repo-wide read is announced, not silent" {
  # The fourth combination, which had no message at all: the merged value is
  # non-empty (it holds the repo-wide answer), so neither the repo-wide-degraded
  # warning nor the fail-open branch fires. Reachable with a wrong-but-positive
  # --epic: the parent 404s while the listing succeeds, so the ONE diagnostic
  # that named a nonexistent parent went silent while the plan still carried that
  # parent for the skill to attach to.
  cat > "$BATS_TEST_TMPDIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$LOG"
case "\$*" in
  *"issue create"*) echo "the builder must never create an issue" >&2; exit 9 ;;
  *"issue list"*)   echo '[]'; exit 0 ;;
esac
echo "HTTP 404: Not Found" >&2; exit 1
EOF
  chmod +x "$BATS_TEST_TMPDIR/gh"
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  contains "$stderr" "could not read the sub-issues of #1431"
  contains "$stderr" "verify --issue/--epic"
  # NOT the fail-open message: one source did answer, so the plan IS filtered
  lacks "$stderr" "could not read EITHER idempotency source"
}

@test "#1435 the sub-issue read's own --jq is pinned at the seam" {
  # That jq runs INSIDE gh, so no stub can execute it — but the command line is
  # observable, and the label normalisation it carries is load-bearing: the REST
  # sub_issues payload spells labels as OBJECTS, so dropping the object-to-name
  # conversion (or the --jq entirely) makes the parent-scoped half of the key
  # match nothing and every already-attached residue issue is re-filed on every
  # run. The repo-wide arm of the same normalisation is exercised in-process by
  # the object-shaped fixture; this is the boundary assertion for the other arm,
  # the same idiom the --paginate and --json needles already use.
  stub_replay '[]'
  build --issue 1435 --epic 1431
  [ "$status" -eq 0 ]
  contains "$(cat "$LOG")" 'if type == "object"'
  contains "$(cat "$LOG")" '.name'
  contains "$(cat "$LOG")" 'title'
}
