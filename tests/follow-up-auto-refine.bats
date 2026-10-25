#!/usr/bin/env bats
#
# #2588: follow-up-auto-refine.zsh — the decisions behind refine-issue's
# unattended follow-up mode. A pure helper, so every mode is driven directly:
# origin, eligible (and its three refusals), seed (both record kinds, with and
# without a story-spec block), decide (all four outcomes and their order) and
# note (the comment and the telemetry object). Then the wiring sentences that
# tell a session to use it.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  export HOME="$BATS_TEST_TMPDIR/home"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  F="$REPO_ROOT/development/skills/refine-issue/scripts/follow-up-auto-refine.zsh"
  O="$REPO_ROOT/development/skills/resolve-issue/scripts/follow-up-origin.zsh"
  D="$BATS_TEST_TMPDIR"
  printf '%s\n' '{"file":"scripts/a.zsh","line":3,"dimension":"bugs","title":"unquoted path","round":2}' > "$D/finding.json"
  printf '%s\n' '{"child":2,"of":3,"criteria":["The second criterion, verbatim.","And its pair."]}' > "$D/seam.json"
  zsh "$O" render --kind parked-finding --repo o/r --source 7 --finding "$D/finding.json" > "$D/parked.md"
  zsh "$O" render --kind split-child --repo o/r --source 7 --seam "$D/seam.json" > "$D/split.md"
  # the follow-up's comments, as gh issue view --json comments prints them
  jq -n --rawfile b "$D/parked.md" '{comments: [{authorAssociation: "OWNER", body: "A human note."}, {authorAssociation: "OWNER", body: $b}]}' > "$D/fu.json"
  jq -n --rawfile b "$D/split.md" '{comments: [{authorAssociation: "OWNER", body: $b}]}' > "$D/fu-split.json"
  # the source story, with sentinel-wrapped prose and a story-spec block
  jq -n '{number: 7, title: "Source story", comments: [],
          body: "Lead-in outside the sentinels.\n<!-- story-spec:prose:start -->\n## Problem\n\nThe source prose.\n<!-- story-spec:prose:end -->\n\n```json\n{\"schema\":\"story-spec/v1\",\"provenance\":{\"prose_sha256\":\"abc123\"},\"acceptance_criteria\":[\"x\"]}\n```\n"}' > "$D/source.json"
}

flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

# --- origin -------------------------------------------------------------------

@test "origin prints the follow-up's record, and exits 1 when no comment holds one" {
  run -0 zsh "$F" origin --comments "$D/fu.json"
  printf '%s' "$output" | jq -e '.kind == "parked-finding" and .source.issue == 7' >/dev/null
  printf '%s\n' '{"comments":[{"authorAssociation":"OWNER","body":"no record here"}]}' > "$D/none.json"
  run -1 --separate-stderr zsh "$F" origin --comments "$D/none.json"
  contains "$stderr" "no follow-up-origin/v1 record"
  [ -z "$output" ]
}

# --- eligible -----------------------------------------------------------------

@test "eligible admits a follow-up with an origin record, no refine-auto marker and a first-generation source" {
  run -0 zsh "$F" eligible --comments "$D/fu.json" --source "$D/source.json"
  [ "$output" = '{"eligible":true,"reason":"eligible","source_issue":7,"ignored_untrusted":0}' ]
}

@test "eligible refuses a follow-up with no origin record (no-origin-record)" {
  printf '%s\n' '{"comments":[{"authorAssociation":"OWNER","body":"Filed by hand."}]}' > "$D/none.json"
  run -1 zsh "$F" eligible --comments "$D/none.json" --source "$D/source.json"
  [ "$output" = '{"eligible":false,"reason":"no-origin-record","source_issue":null,"ignored_untrusted":0}' ]
}

@test "eligible refuses a follow-up already attempted, so a second run does nothing (already-attempted)" {
  zsh "$F" seed --comments "$D/fu.json" --source "$D/source.json" > "$D/seed.json"
  printf '[]\n' > "$D/answers.json"
  zsh "$F" note --seed "$D/seed.json" --answers "$D/answers.json" --threshold-milli 900 --decision park-deferred > "$D/note.md"
  jq -n --rawfile b "$D/parked.md" --rawfile n "$D/note.md" '{comments: [{authorAssociation: "OWNER", body: $b}, {authorAssociation: "OWNER", body: $n}]}' > "$D/fu2.json"
  run -1 zsh "$F" eligible --comments "$D/fu2.json" --source "$D/source.json"
  [ "$output" = '{"eligible":false,"reason":"already-attempted","source_issue":7,"ignored_untrusted":0}' ]
}

@test "eligible refuses a second-generation follow-up whose source is itself a follow-up (second-generation)" {
  jq --rawfile b "$D/split.md" '.comments = [{authorAssociation: "OWNER", body: $b}]' "$D/source.json" > "$D/source-fu.json"
  run -1 zsh "$F" eligible --comments "$D/fu.json" --source "$D/source-fu.json"
  [ "$output" = '{"eligible":false,"reason":"second-generation","source_issue":7,"ignored_untrusted":0}' ]
}

@test "eligible refuses a --source that is not the issue the origin record names (exit 2)" {
  jq '.number = 8' "$D/source.json" > "$D/other.json"
  run -2 --separate-stderr zsh "$F" eligible --comments "$D/fu.json" --source "$D/other.json"
  contains "$stderr" "--source is issue #8, but the origin record names #7"
  [ -z "$output" ]
}

# --- trusted authors (#2645) --------------------------------------------------

@test "origin, eligible and seed ignore an origin record from an untrusted author, and still find a trusted one later" {
  local assoc
  for assoc in NONE CONTRIBUTOR FIRST_TIME_CONTRIBUTOR FIRST_TIMER MANNEQUIN; do
    jq -n --rawfile s "$D/split.md" --rawfile p "$D/parked.md" --arg a "$assoc" \
      '{comments: [{authorAssociation: $a, author: {login: "stranger"}, body: $s}, {authorAssociation: "COLLABORATOR", body: $p}]}' > "$D/mixed.json"
    run -0 zsh "$F" origin --comments "$D/mixed.json"
    printf '%s' "$output" | jq -e '.kind == "parked-finding"' >/dev/null || { echo "origin trusted $assoc"; return 1; }
    run -0 zsh "$F" seed --comments "$D/mixed.json" --source "$D/source.json"
    printf '%s' "$output" | jq -e '.origin.kind == "parked-finding"' >/dev/null || { echo "seed trusted $assoc"; return 1; }
    run -0 zsh "$F" eligible --comments "$D/mixed.json" --source "$D/source.json"
    [ "$output" = '{"eligible":true,"reason":"eligible","source_issue":7,"ignored_untrusted":1}' ] || { echo "eligible $assoc"; return 1; }
  done
  jq -n --rawfile s "$D/split.md" '{comments: [{authorAssociation: "NONE", author: {login: "stranger"}, body: $s}]}' > "$D/only.json"
  run -1 --separate-stderr zsh "$F" origin --comments "$D/only.json"
  [ -z "$output" ]
  contains "$stderr" "(1 untrusted comments holding a record or the marker were ignored)"
  run -2 --separate-stderr zsh "$F" seed --comments "$D/only.json" --source "$D/source.json"
  contains "$stderr" "seed: no follow-up-origin/v1 record"
  run -1 zsh "$F" eligible --comments "$D/only.json" --source "$D/source.json"
  [ "$output" = '{"eligible":false,"reason":"no-origin-record","source_issue":null,"ignored_untrusted":1}' ]
}

@test "OWNER, MEMBER and COLLABORATOR are trusted, and so is this repository owner's Maintenance App, in its [bot] login form" {
  local assoc
  for assoc in OWNER MEMBER COLLABORATOR; do
    jq -n --rawfile p "$D/parked.md" --arg a "$assoc" '{comments: [{authorAssociation: $a, body: $p}]}' > "$D/t.json"
    run -0 zsh "$F" origin --comments "$D/t.json"
    printf '%s' "$output" | jq -e '.kind == "parked-finding"' >/dev/null || { echo "$assoc"; return 1; }
  done
  local login
  for login in 'claude-maintenance-o[bot]' 'Claude-Maintenance-O[bot]'; do
    jq -n --rawfile p "$D/parked.md" --arg l "$login" \
      '{comments: [{authorAssociation: "NONE", author: {login: $l}, url: "https://github.com/o/r/issues/5#issuecomment-1", body: $p}]}' > "$D/app.json"
    run -0 zsh "$F" origin --comments "$D/app.json"
    printf '%s' "$output" | jq -e '.kind == "parked-finding"' >/dev/null || { echo "app login $login"; return 1; }
  done
  # an owner with capitals in the url
  jq -n --rawfile p "$D/parked.md" \
    '{comments: [{authorAssociation: "NONE", author: {login: "claude-maintenance-o[bot]"}, url: "https://github.com/O/r/issues/5#issuecomment-1", body: $p}]}' > "$D/appO.json"
  run -0 zsh "$F" origin --comments "$D/appO.json"
  printf '%s' "$output" | jq -e '.kind == "parked-finding"' >/dev/null
}

@test "the bare and app/ login forms of the Maintenance App are not trusted, since a user account can hold the bare one" {
  local login
  for login in claude-maintenance-o app/claude-maintenance-o; do
    jq -n --rawfile p "$D/parked.md" --arg l "$login" \
      '{comments: [{authorAssociation: "NONE", author: {login: $l}, url: "https://github.com/o/r/issues/5#issuecomment-1", body: $p}]}' > "$D/app.json"
    run -1 --separate-stderr zsh "$F" origin --comments "$D/app.json"
    [ -z "$output" ] || { echo "app login $login trusted"; return 1; }
  done
}

@test "another owner's Maintenance App, or an App comment without a url, is not trusted" {
  jq -n --rawfile p "$D/parked.md" \
    '{comments: [{authorAssociation: "NONE", author: {login: "claude-maintenance-evil[bot]"}, url: "https://github.com/o/r/issues/5#issuecomment-1", body: $p}]}' > "$D/evil.json"
  run -1 --separate-stderr zsh "$F" origin --comments "$D/evil.json"
  [ -z "$output" ]
  jq -n --rawfile p "$D/parked.md" '{comments: [{authorAssociation: "NONE", author: {login: "claude-maintenance-o[bot]"}, body: $p}]}' > "$D/nourl.json"
  run -1 --separate-stderr zsh "$F" origin --comments "$D/nourl.json"
  [ -z "$output" ]
  jq -n --rawfile p "$D/parked.md" \
    '{comments: [{authorAssociation: "NONE", author: {login: "claude-maintenance-o[bot]"}, url: "https://github.com/evil/r/issues/5#issuecomment-1", body: $p}]}' > "$D/otherurl.json"
  run -1 --separate-stderr zsh "$F" origin --comments "$D/otherurl.json"
  [ -z "$output" ]
}

@test "a refine-auto marker from an untrusted author does not make eligible refuse already-attempted" {
  zsh "$F" seed --comments "$D/fu.json" --source "$D/source.json" > "$D/seed.json"
  printf '[]\n' > "$D/answers.json"
  zsh "$F" note --seed "$D/seed.json" --answers "$D/answers.json" --threshold-milli 900 --decision park-deferred > "$D/note.md"
  jq -n --rawfile b "$D/parked.md" --rawfile n "$D/note.md" \
    '{comments: [{authorAssociation: "OWNER", body: $b}, {authorAssociation: "NONE", author: {login: "stranger"}, body: $n}]}' > "$D/fu3.json"
  run -0 zsh "$F" eligible --comments "$D/fu3.json" --source "$D/source.json"
  [ "$output" = '{"eligible":true,"reason":"eligible","source_issue":7,"ignored_untrusted":1}' ]
}

@test "an untrusted origin record on the source does not make eligible refuse second-generation" {
  jq --rawfile b "$D/split.md" '.comments = [{authorAssociation: "CONTRIBUTOR", author: {login: "stranger"}, body: $b}]' "$D/source.json" > "$D/source-u.json"
  run -0 zsh "$F" eligible --comments "$D/fu.json" --source "$D/source-u.json"
  [ "$output" = '{"eligible":true,"reason":"eligible","source_issue":7,"ignored_untrusted":1}' ]
  # both ignored at once: the count adds the follow-up's and the source's
  jq -n --rawfile s "$D/split.md" --rawfile p "$D/parked.md" \
    '{comments: [{authorAssociation: "NONE", body: $s}, {authorAssociation: "OWNER", body: $p}]}' > "$D/mixed.json"
  run -0 zsh "$F" eligible --comments "$D/mixed.json" --source "$D/source-u.json"
  printf '%s' "$output" | jq -e '.ignored_untrusted == 2' >/dev/null
  # an untrusted comment holding neither is not counted
  jq -n --rawfile p "$D/parked.md" '{comments: [{authorAssociation: "NONE", body: "Just a note."}, {authorAssociation: "OWNER", body: $p}]}' > "$D/plainu.json"
  run -0 zsh "$F" eligible --comments "$D/plainu.json" --source "$D/source.json"
  printf '%s' "$output" | jq -e '.ignored_untrusted == 0' >/dev/null
}

@test "comments as bare strings, or objects without authorAssociation, are exit 2, on the follow-up and on the source" {
  jq -n --rawfile p "$D/parked.md" '[$p]' > "$D/bare.json"
  local m
  for m in origin eligible seed; do
    if [ "$m" = origin ]; then
      run -2 --separate-stderr zsh "$F" origin --comments "$D/bare.json"
    else
      run -2 --separate-stderr zsh "$F" "$m" --comments "$D/bare.json" --source "$D/source.json"
    fi
    [ -z "$output" ] || { echo "$m printed"; return 1; }
    contains "$stderr" "is not a comment list of objects with authorAssociation"
  done
  jq -n --rawfile p "$D/parked.md" '{comments: [{author: {login: "u"}, body: $p}]}' > "$D/noassoc.json"
  run -2 --separate-stderr zsh "$F" origin --comments "$D/noassoc.json"
  contains "$stderr" "a bare body string carries no author"
  # an empty file, or two JSON documents, is not one comment list
  : > "$D/empty.json"
  run -2 --separate-stderr zsh "$F" origin --comments "$D/empty.json"
  contains "$stderr" "is not a comment list of objects with authorAssociation"
  cat "$D/fu.json" "$D/fu.json" > "$D/two.json"
  run -2 --separate-stderr zsh "$F" origin --comments "$D/two.json"
  contains "$stderr" "is not a comment list of objects with authorAssociation"
  # a malformed --source is exit 2 for eligible too, even with no origin record
  printf '%s\n' '{"comments":[{"authorAssociation":"OWNER","body":"no record here"}]}' > "$D/none.json"
  printf 'not json\n' > "$D/badsrc.json"
  run -2 --separate-stderr zsh "$F" eligible --comments "$D/none.json" --source "$D/badsrc.json"
  [ -z "$output" ]
  contains "$stderr" "must be an issue object with number, title and body"
  [ "$(grep -cF 'the comments of --source' <<< "$stderr")" = 0 ]
  jq '.comments = ["a bare body"]' "$D/source.json" > "$D/source-bare.json"
  run -2 --separate-stderr zsh "$F" eligible --comments "$D/fu.json" --source "$D/source-bare.json"
  [ -z "$output" ]
  contains "$stderr" "the comments of --source"
}

# --- seed ---------------------------------------------------------------------

@test "seed builds {origin, source} for a parked-finding record, with the sentinel prose and the story spec" {
  run -0 zsh "$F" seed --comments "$D/fu.json" --source "$D/source.json"
  printf '%s' "$output" | jq -e 'keys == ["origin", "source"] and (.source | keys) == ["number", "prose", "story_spec", "title"]' >/dev/null
  printf '%s' "$output" | jq -e '.origin.kind == "parked-finding" and .origin.finding.title == "unquoted path"' >/dev/null
  printf '%s' "$output" | jq -e '.source == {number: 7, title: "Source story", prose: "## Problem\n\nThe source prose.", story_spec: .source.story_spec}' >/dev/null
  printf '%s' "$output" | jq -e '.source.story_spec.provenance.prose_sha256 == "abc123"' >/dev/null
}

@test "seed builds the same shape for a split-child record, its seam criteria verbatim" {
  run -0 zsh "$F" seed --comments "$D/fu-split.json" --source "$D/source.json"
  printf '%s' "$output" | jq -e '.origin.kind == "split-child" and .origin.seam.criteria == ["The second criterion, verbatim.", "And its pair."]' >/dev/null
}

@test "seed sets story_spec to null for a source without a block, and takes the whole body without sentinels" {
  jq '.body = "Just prose, no sentinels and no block."' "$D/source.json" > "$D/plain.json"
  run -0 zsh "$F" seed --comments "$D/fu.json" --source "$D/plain.json"
  printf '%s' "$output" | jq -e '.source.story_spec == null and .source.prose == "Just prose, no sentinels and no block."' >/dev/null
}

@test "seed exits 2 on a follow-up with no origin record and on a malformed --source" {
  printf '%s\n' '{"comments":[]}' > "$D/none.json"
  run -2 --separate-stderr zsh "$F" seed --comments "$D/none.json" --source "$D/source.json"
  contains "$stderr" "seed: no follow-up-origin/v1 record"
  printf '%s\n' '{"number":7}' > "$D/bad.json"
  run -2 --separate-stderr zsh "$F" seed --comments "$D/fu.json" --source "$D/bad.json"
  contains "$stderr" "must be an issue object with number, title and body"
}

# --- decide -------------------------------------------------------------------

_split() { printf '%s\n' "{\"threshold\":\"0.900\",\"auto\":$1,\"ask\":$2}" > "$D/split-out.json"; }
# a third argument replaces the draft fields; pass an empty one for a turn with no draft
DRAFT=',"proposed_prose":"P","proposed_story_spec":{}'
_turn()  { printf '%s\n' "{\"questions\":$1,\"resolved_objections\":$2${3-$DRAFT}}" > "$D/turn.json"; }

@test "decide parks needs-decision on any ask question, even when everything else converged" {
  _split '[]' '[{"question":"q","reason":"below-threshold"}]'
  _turn '[]' '[{"objection":"o","resolved":true}]'
  run -0 zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 1
  [ "$output" = '{"decision":"park","park_type":"needs-decision"}' ]
}

@test "decide accepts on convergence: every objection resolved and no question left" {
  _split '[{"question":"q","answer":"a","confidence":"0.95"}]' '[]'
  _turn '[]' '[{"objection":"o","resolved":true},{"objection":"p","resolved":true}]'
  run -0 zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 3
  [ "$output" = '{"decision":"accept","park_type":null}' ]
}

@test "decide accepts only when both halves hold: an unresolved objection or a left question is not accept" {
  _split '[]' '[]'
  _turn '[]' '[{"objection":"o","resolved":true},{"objection":"p","resolved":false}]'
  run -0 zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 2
  [ "$output" = '{"decision":"continue","park_type":null}' ]
  _turn '[{"question":"q"}]' '[{"objection":"o","resolved":true}]'
  run -0 zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 2
  [ "$output" = '{"decision":"continue","park_type":null}' ]
}

@test "decide never accepts a converged turn without a draft or with no objection list" {
  _split '[]' '[]'
  _turn '[]' '[{"objection":"o","resolved":true}]' ''
  run -0 zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 2
  [ "$output" = '{"decision":"continue","park_type":null}' ]
  run -0 zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 3
  [ "$output" = '{"decision":"park","park_type":"deferred"}' ]
  _turn '[]' '[{"objection":"o","resolved":true}]' ',"proposed_prose":"  ","proposed_story_spec":{}'
  run -0 zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 2
  [ "$output" = '{"decision":"continue","park_type":null}' ]
  _turn '[]' '[]'
  run -0 zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 2
  [ "$output" = '{"decision":"continue","park_type":null}' ]
}

@test "decide never accepts a converged turn whose story-spec is missing or null, or whose prose is not a string" {
  _split '[]' '[]'
  _turn '[]' '[{"objection":"o","resolved":true}]' ',"proposed_prose":"P"'
  run -0 zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 2
  [ "$output" = '{"decision":"continue","park_type":null}' ]
  _turn '[]' '[{"objection":"o","resolved":true}]' ',"proposed_prose":"P","proposed_story_spec":null'
  run -0 zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 2
  [ "$output" = '{"decision":"continue","park_type":null}' ]
  _turn '[]' '[{"objection":"o","resolved":true}]' ',"proposed_prose":42,"proposed_story_spec":{}'
  run -0 zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 2
  [ "$output" = '{"decision":"continue","park_type":null}' ]
  _turn '[]' '[{"objection":"o","resolved":true}]' ',"proposed_prose":"P","proposed_story_spec":{}'
  run -0 zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 2
  [ "$output" = '{"decision":"accept","park_type":null}' ]
}

@test "decide parks deferred at the round cap without convergence, and continues below it" {
  _split '[{"question":"q","answer":"a","confidence":"0.95"}]' '[]'
  _turn '[{"question":"q"}]' '[{"objection":"o","resolved":false}]'
  run -0 zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 3
  [ "$output" = '{"decision":"park","park_type":"deferred"}' ]
  run -0 zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 2
  [ "$output" = '{"decision":"continue","park_type":null}' ]
  run -0 zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 2 --max-rounds 2
  [ "$output" = '{"decision":"park","park_type":"deferred"}' ]
}

@test "decide refuses a malformed split, turn or round (exit 2)" {
  _split '[]' '[]'
  _turn '[]' '[]'
  printf '{"auto":[]}\n' > "$D/bad-split.json"
  run -2 --separate-stderr zsh "$F" decide --split "$D/bad-split.json" --turn "$D/turn.json" --round 1
  contains "$stderr" "--split is not split-refiner-questions.zsh output"
  printf '{"questions":[]}\n' > "$D/bad-turn.json"
  run -2 --separate-stderr zsh "$F" decide --split "$D/split-out.json" --turn "$D/bad-turn.json" --round 1
  contains "$stderr" "--turn has no questions and resolved_objections arrays"
  run -2 --separate-stderr zsh "$F" decide --split "$D/split-out.json" --turn "$D/turn.json" --round 0
  contains "$stderr" "--round must be a positive integer"
}

# --- note ---------------------------------------------------------------------

@test "note renders the marker, the source and its prose hash, the finding, the answers, the threshold and the accept score" {
  zsh "$F" seed --comments "$D/fu.json" --source "$D/source.json" > "$D/seed.json"
  printf '%s\n' '[{"question":"Which shell?","answer":"zsh","confidence":"0.95"},{"question":"Exit code?","answer":"2","confidence":"0.91"}]' > "$D/answers.json"
  run -0 zsh "$F" note --seed "$D/seed.json" --answers "$D/answers.json" --threshold-milli 900 --decision accept
  [ "${lines[0]}" = "<!-- refine-auto: follow-up-origin/v1 -->" ]
  contains "$output" "**Refined unattended from #7**"
  contains "$output" 'story-spec `prose_sha256` `abc123`'
  contains "$output" '- Finding: `scripts/a.zsh`:3 (bugs, round 2): unquoted path'
  contains "$output" "- Threshold: 0.9; accept score: 0.91"
  contains "$output" "| Which shell? → zsh | gap | 0.95 |"
  contains "$output" "Outcome: accepted: the draft was written back and re-gated."
}

@test "#2900 note lists each answer's kind, and an implementation answer's confidence scores nothing" {
  zsh "$F" seed --comments "$D/fu.json" --source "$D/source.json" > "$D/seed.json"
  printf '%s\n' '[{"question":"Which helper?","kind":"implementation","answer":"jq","confidence":"0.40"},{"question":"Exit code?","kind":"intent","answer":"2","confidence":"0.91"}]' > "$D/answers.json"
  run -0 zsh "$F" note --seed "$D/seed.json" --answers "$D/answers.json" --threshold-milli 900 --decision accept
  contains "$output" "| Which helper? → jq | implementation | 0.40 |"
  contains "$output" "- Threshold: 0.9; accept score: 0.91"
  contains "$output" "| Exit code? → 2 | intent | 0.91 |"
  run -0 zsh "$F" note --seed "$D/seed.json" --answers "$D/answers.json" --threshold-milli 900 --decision accept --format json
  printf '%s' "$output" | jq -e '.confidences == [0.91] and .accept_score == 0.91' >/dev/null
}

@test "note lists a split child's seam criteria verbatim" {
  zsh "$F" seed --comments "$D/fu-split.json" --source "$D/source.json" > "$D/seed.json"
  printf '[]\n' > "$D/answers.json"
  run -0 zsh "$F" note --seed "$D/seed.json" --answers "$D/answers.json" --threshold-milli 1000 --decision park-needs-decision
  contains "$output" "- Seam: child 2 of 3, assigned criteria:"
  contains "$output" "  - The second criterion, verbatim."
  contains "$output" "No answer was taken automatically."
  contains "$output" "accept score: none (no question was answered automatically)"
}

@test "note --format json prints the auto_refinement object, with a null accept score when nothing was auto-answered" {
  zsh "$F" seed --comments "$D/fu.json" --source "$D/source.json" > "$D/seed.json"
  printf '%s\n' '[{"question":"q","answer":"a","confidence":"0.95"},{"question":"r","answer":"b","confidence":"0.92"}]' > "$D/answers.json"
  run -0 zsh "$F" note --seed "$D/seed.json" --answers "$D/answers.json" --threshold-milli 900 --decision accept --format json
  [ "$output" = '{"seed_kind":"parked-finding","source_issue":7,"threshold":0.9,"confidences":[0.95,0.92],"accept_score":0.92,"decision":"accept"}' ]
  printf '[]\n' > "$D/none.json"
  run -0 zsh "$F" note --seed "$D/seed.json" --answers "$D/none.json" --threshold-milli 900 --decision park-deferred --format json
  printf '%s' "$output" | jq -e '.accept_score == null and .confidences == [] and .decision == "park-deferred"' >/dev/null
  run -0 zsh "$F" note --seed "$D/seed.json" --answers "$D/none.json" --threshold-milli 925 --decision accept --format json
  printf '%s' "$output" | jq -e '.threshold == 0.925' >/dev/null
  run -0 zsh "$F" note --seed "$D/seed.json" --answers "$D/none.json" --threshold-milli 925 --decision accept
  contains "$output" "- Threshold: 0.925; accept score: none"
}

@test "note --decision ready renders the already-READY outcome, claiming no write-back" {
  zsh "$F" seed --comments "$D/fu.json" --source "$D/source.json" > "$D/seed.json"
  printf '[]\n' > "$D/answers.json"
  run -0 zsh "$F" note --seed "$D/seed.json" --answers "$D/answers.json" --threshold-milli 900 --decision ready
  contains "$output" "Outcome: already READY: the label was cleared and nothing was written back."
  run -0 zsh "$F" note --seed "$D/seed.json" --answers "$D/answers.json" --threshold-milli 900 --decision ready --format json
  printf '%s' "$output" | jq -e '.decision == "ready" and .accept_score == null and .confidences == []' >/dev/null
}

@test "the note's json object is a valid telemetry auto_refinement for the payload builder" {
  zsh "$F" seed --comments "$D/fu.json" --source "$D/source.json" > "$D/seed.json"
  printf '%s\n' '[{"question":"q","answer":"a","confidence":"0.95"}]' > "$D/answers.json"
  zsh "$F" note --seed "$D/seed.json" --answers "$D/answers.json" --threshold-milli 900 --decision accept --format json > "$D/auto.json"
  jq -n --slurpfile a "$D/auto.json" '{rounds: 2, objections_raised: 1, objections_resolved: 1, outcome: "refined-ready", risk_classification: "normal", auto_refinement: $a[0]}' > "$D/state.json"
  run -0 zsh "$REPO_ROOT/development/skills/refine-issue/scripts/build-refine-telemetry-record.zsh" --state "$D/state.json"
  printf '%s' "$output" | jq -e '.auto_refinement.accept_score == 0.95' >/dev/null
}

@test "note refuses a bad decision, threshold, format, seed and answers (exit 2)" {
  zsh "$F" seed --comments "$D/fu.json" --source "$D/source.json" > "$D/seed.json"
  printf '[]\n' > "$D/answers.json"
  run -2 --separate-stderr zsh "$F" note --seed "$D/seed.json" --answers "$D/answers.json" --threshold-milli 900 --decision approved
  contains "$stderr" "--decision must be accept, ready, park-needs-decision or park-deferred"
  run -2 --separate-stderr zsh "$F" note --seed "$D/seed.json" --answers "$D/answers.json" --threshold-milli 1001 --decision accept
  contains "$stderr" "--threshold-milli must be an integer in 0..1000"
  run -2 --separate-stderr zsh "$F" note --seed "$D/seed.json" --answers "$D/answers.json" --threshold-milli 0.9 --decision accept
  contains "$stderr" "--threshold-milli must be an integer in 0..1000"
  run -2 --separate-stderr zsh "$F" note --seed "$D/seed.json" --answers "$D/answers.json" --threshold-milli 900 --decision accept --format yaml
  contains "$stderr" "--format must be md or json"
  run -2 --separate-stderr zsh "$F" note --seed "$D/answers.json" --answers "$D/answers.json" --threshold-milli 900 --decision accept
  contains "$stderr" "--seed is not a seed"
  printf '[{"question":"q"}]\n' > "$D/bad.json"
  run -2 --separate-stderr zsh "$F" note --seed "$D/seed.json" --answers "$D/bad.json" --threshold-milli 900 --decision accept
  contains "$stderr" "--answers must be an array of {question, answer, confidence}"
}

@test "an unknown mode, a missing mode and a dangling flag are usage errors (exit 2)" {
  run -2 --separate-stderr zsh "$F"
  contains "$stderr" "usage: follow-up-auto-refine.zsh origin|eligible|seed|decide|note"
  run -2 --separate-stderr zsh "$F" refine
  contains "$stderr" "unknown mode 'refine'"
  run -2 --separate-stderr zsh "$F" decide --round
  contains "$stderr" "--round requires a value"
}

# --- the wiring ---------------------------------------------------------------

@test "refine-issue documents the unattended follow-up mode, and the human-approval invariant stays byte-intact" {
  local s="$REPO_ROOT/development/skills/refine-issue/SKILL.md" t
  t="$(flat "$s")"
  grep -qxF '## Unattended follow-up mode (`--follow-up`, #2588)' "$s"
  grep -qF '**Auto-accept never approves the rewrite.** The threshold only answers the refiner' <<< "$t"
  grep -qF 'The one exception is the unattended follow-up mode below, where its `accept` decision stands in for that approval.' <<< "$t"
  grep -qF '**This mode' <<< "$t"
  grep -qF 'stands in for the human' <<< "$t"
  grep -qF '**A park never stops the caller**: report it and return, so the calling run, its epic walk and the next follow-up go on.' <<< "$t"
  grep -qF 'with `provenance.generated_by` set to `issue-refiner via /development:refine-issue --follow-up (unattended)`' <<< "$t"
  grep -qF '**Auto-refinement never splits**, and it never walks an epic.' <<< "$t"
  grep -qF 'Its marker is what makes a second run refuse `already-attempted`.' <<< "$t"
  grep -qF -- '--arg auto "${AUTO_REFINEMENT:-}"' "$s"
  # the procedure, step by step
  grep -qF 'Exit 1 prints the refusal: `no-origin-record`, `already-attempted` or `second-generation`.' <<< "$t"
  grep -qF '`seed --comments <file> --source <file>` prints the seed.' <<< "$t"
  grep -qF 'run `decide --split <split.json> --turn <turn.json> --round <R>`' <<< "$t"
  grep -qF '`continue` — call the refiner again with the `auto` answers as `human_reply`' <<< "$t"
  grep -qF 'a draft that stops is parked `deferred`, never split.' <<< "$t"
  grep -qF 'Keep every `auto` answer of every round in one list for the note.' <<< "$t"
  grep -qF 'A size-check park names its own reason instead: "the draft' <<< "$t"
  grep -qF 'In the unattended follow-up mode `AUTO_REFINEMENT` is one more, re-stated the same way.' <<< "$t"
  grep -qF 'Write `gh issue view <source> --json number,title,body,comments` to a second file and run `eligible --comments <file> --source <file>`.' <<< "$t"
  # A: Steps 0 and 1 run unattended
  grep -qF '**Steps 0 and 1 run as written, with no prompt:** Step 0 first, Step 1 after the seed (2. below).' <<< "$t"
  grep -qF 'post the note with `--decision ready` after zero rounds, with no answers; otherwise its `refinement_questions` are the objections for the rounds.' <<< "$t"
  # B: every human prompt has a fixed answer, and the guardrails name the exception
  grep -qF '**Every human prompt has a fixed unattended answer:**' <<< "$t"
  grep -qF 'a follow-up without `needs-refinement` is not refined: stop, writing nothing;' <<< "$t"
  grep -qF 'shortcut confirmation — clear the label; - Step 2' <<< "$t"
  grep -qF 'relay and its answers — `decide`; - Step 2' <<< "$t"
  grep -qF 'approval — `accept`; - Step 2' <<< "$t"
  grep -qF 'size check stopping, or a non-null `proposed_split` — park `deferred`, never split; - Step 5' <<< "$t"
  grep -qF 'failed label removal — report it.' <<< "$t"
  grep -qF 'Step 2.5 has no prompt: on `accept` it runs as written, before Step 3.' <<< "$t"
  grep -qF 'write it back as Steps 2.5 and 3 do' <<< "$t"
  grep -qF 'only after they approve the exact rewrite — the unattended follow-up mode' <<< "$t"
  grep -qF '`accept` is the only exception.' <<< "$t"
  grep -qF 'never answers the Step 0, Step 1 or Step 5 prompts; the unattended follow-up mode, the only exception, answers them as it lists.' <<< "$t"
  # C: exit 2
  grep -qF 'from `follow-up-auto-refine.zsh` or `follow-up-origin.zsh` is your own malformed input: fix it and re-run once. A second exit 2 stops the mode for that follow-up: report it and write nothing, so the label stays.' <<< "$t"
  # D: the threshold in thousandths
  grep -qF 'Post `note --seed <seed> --answers <answers> --threshold-milli <milli> --decision <accept|ready|park-needs-decision|park-deferred>`' <<< "$t"
  # E: the park state and the decision mapping
  grep -qF 'text, `decision` the first of them and `owner` "the maintainer — the unattended mode asked no one".' <<< "$t"
  grep -qF 'text plus any remaining questions, never empty: else "no convergence within the round cap".' <<< "$t"
  grep -qF '`accept` on accept, `ready` on Step 1' <<< "$t"
  grep -qF 'shortcut, else `park-needs-decision` or `park-deferred` by the park' <<< "$t"
  # F: no accept without a draft
  grep -qF 'It accepts only a converged turn with a non-empty `resolved_objections`, a non-blank `proposed_prose` and a `proposed_story_spec` object; a converged turn without a draft is `continue` below the cap and `park deferred` at it' <<< "$t"
  # G: the trusted-author rule (#2645)
  grep -qF '**Only a trusted author' <<< "$t"
  grep -qF 'An origin record or a refine-auto marker counts only in a comment whose `authorAssociation` is `OWNER`, `MEMBER` or `COLLABORATOR`, or that the repository owner' <<< "$t"
  grep -qF 's Maintenance App wrote as `claude-maintenance-<owner>[bot]`, on the follow-up and on the source alike; the script ignores every other comment.' <<< "$t"
  grep -qF 'The bare login `gh issue view` prints for an App is not trusted, since a user account can hold it; the pipeline posts these comments with a collaborator' <<< "$t"
  grep -qF 's `gh` login. So always pass `gh issue view --json` output, whose comments carry `authorAssociation`: a comment without it is exit 2.' <<< "$t"
  grep -qF 'When `eligible` reports a non-zero `ignored_untrusted`, name that count in your report.' <<< "$t"
}

@test "ARCHITECTURE.md states the trusted-author rule of the unattended follow-up mode (#2645)" {
  local a; a="$(flat "$REPO_ROOT/ARCHITECTURE.md")"
  grep -qF '**Trusted authors (#2645).** On a public repository anyone can comment, and this mode rewrites an issue body without a human approving the text.' <<< "$a"
  grep -qF 'So an origin record or a refine-auto marker counts only in a comment whose `authorAssociation` is `OWNER`, `MEMBER` or `COLLABORATOR`, or whose author is the repository owner' <<< "$a"
  grep -qF 's Maintenance App as `claude-maintenance-<owner>[bot]`, the owner read from the comment' <<< "$a"
  grep -qF 'No user account can hold a `[bot]` login, but one can hold the bare login `gh issue view` prints for an App, so the bare form is not trusted; the pipeline posts these comments with a collaborator' <<< "$a"
  grep -qF 'That holds on the follow-up and on the source alike. A planted record cannot steer the rewrite, and a planted marker cannot block it.' <<< "$a"
  grep -qF '`eligible` reports how many of them held a record or the marker as `ignored_untrusted`.' <<< "$a"
  grep -qF 'A comment without `authorAssociation`, a bare body string included, is refused (exit 2) rather than trusted.' <<< "$a"
}

@test "the refiner takes the seed as context below the issue body, never as an answer or a waiver" {
  local t; t="$(flat "$REPO_ROOT/development/agents/issue-refiner.md")"
  grep -qF '**`seed`** (optional, #2588) is present only in refine-issue' <<< "$t"
  grep -qF 'Use it as **context below `issue.body`**' <<< "$t"
  grep -qF 'It is never a human answer, and never a waiver of an objection.' <<< "$t"
}

@test "resolve-issue refines the parked follow-ups once per run, before its record, without stopping on a park" {
  local t; t="$(flat "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")"
  grep -qF '**First, refine the run' <<< "$t"
  grep -qF 'invoke `/development:refine-issue <issue> --follow-up` for each issue it prints' <<< "$t"
  grep -qF 'On an attended run ask once, listing them, with auto-refinement recommended' <<< "$t"
  grep -qF '**A follow-up that parks never stops this run or its epic walk**' <<< "$t"
  grep -qF 'run `follow-up-origin.zsh parked-issues --progress <work-dir>/progress.md`; exit 1 means nothing was parked.' <<< "$t"
  grep -qF 'Once per run, before the record, at every ending after a review loop ran, escalations included — the §6 PR, #2579' <<< "$t"
  grep -qF 's clean stop and an escalation terminal, where a parked blocker' <<< "$t"
  grep -qF 'usually ends (`ESCALATE_NO_CONVERGENCE`)' <<< "$t"
  grep -qF 'On an unattended run (`resolve-session.zsh`, #2575) do it without asking.' <<< "$t"
}

@test "ARCHITECTURE.md and the how-to state the mode and the auto_refinement key" {
  local a; a="$(flat "$REPO_ROOT/ARCHITECTURE.md")"
  grep -qF '### The unattended follow-up mode — `refine-issue --follow-up` (#2588)' "$REPO_ROOT/ARCHITECTURE.md"
  grep -qF 'This accept stands in for the human' <<< "$a"
  grep -qF 'Everywhere else auto-accept still never approves a rewrite.' <<< "$a"
  grep -qF 'A second optional key (#2588), `auto_refinement`' <<< "$a"
  local h; h="$(flat "$REPO_ROOT/docs/how-to/let-refine-issue-answer-confident-questions.md")"
  grep -qF '## Follow-ups the pipeline filed' "$REPO_ROOT/docs/how-to/let-refine-issue-answer-confident-questions.md"
  grep -qF 'This is the one place a rewrite is accepted for you.' <<< "$h"
}
