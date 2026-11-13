#!/usr/bin/env bats
#
# Behavioral tests for reconcile-test-case-spec.zsh (#3089): resolve-issue §6
# writes a build-disproved test-case expectation into the story's story-spec/v1
# block, and the linked test-case bodies are re-rendered from that block by
# test-case-spinout.zsh, never hand-edited.
#
# `gh` is shadowed via PATH. `issue view` serves the story body from
# $BATS_TEST_TMPDIR/story.md; an `issue edit --body-file` (the story write) copies
# the file to story-written.md; an `issue edit --body` (the spin-out's re-render
# of a linked test case) appends to tc-edits.log. Every gh call is logged to
# calls.log, so "no write" is checkable.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/reconcile-test-case-spec.zsh"
  HASH="$REPO_ROOT/development/skills/refine-issue/scripts/story-spec-prose-hash.zsh"
  T="$BATS_TEST_TMPDIR"
  STUB="$T/bin"
  mkdir -p "$STUB"
  : > "$T/calls.log"; : > "$T/tc-edits.log"

  cat > "$STUB/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/calls.log"
case "\$1 \$2" in
  "issue view")
    [ -f "$T/fail-view" ] && exit 1
    jq -Rs '{body: .}' "$T/story.md"; exit 0 ;;
  "issue edit")
    num="\$3"; bodyfile=""; body=""
    while [ \$# -gt 0 ]; do
      case "\$1" in --body-file) bodyfile="\$2"; shift 2;; --body) body="\$2"; shift 2;; *) shift;; esac
    done
    if [ -n "\$bodyfile" ]; then
      [ -f "$T/fail-story-edit" ] && exit 1
      cp "\$bodyfile" "$T/story-written.md"; exit 0
    fi
    [ -f "$T/fail-tc-edit" ] && exit 1
    printf '=== edit #%s ===\n%s\n' "\$num" "\$body" >> "$T/tc-edits.log"; exit 0 ;;
  "issue create") printf 'https://github.com/o/r/issues/999\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB/gh"

  # The story: sentinel-wrapped prose, then the generated block. The prose
  # deliberately restates the old expectation — the reconcile never rewrites it.
  printf '%s\n' \
    'Intro line outside the sentinels.' \
    '<!-- story-spec:prose:start -->' \
    '## Summary' \
    '' \
    'A bad token is refused with 401.  ' \
    '<!-- story-spec:prose:end -->' > "$T/prose-head.md"
  printf '%s\n' '## Summary' '' 'A bad token is refused with 401.  ' > "$T/prose-region.txt"
  PROSE_SHA="$(zsh "$HASH" --file "$T/prose-region.txt")"
  jq -n --arg sha "$PROSE_SHA" '{
    schema: "story-spec/v1",
    provenance: {generated_by: "issue-refiner via /development:refine-issue",
                 generated_at: "2026-11-13T11:56:55Z", prose_sha256: $sha},
    acceptance_criteria: ["a bad token is refused"],
    test_cases: [
      {id: "tc-error-bad-token", kind: "error", shape: "GET /jobs with an expired token -> 401",
       tooling: "curl", issue: 501, provisional: {assumption: "the API answers 401"}},
      {id: "tc-happy-list-jobs", kind: "happy", shape: "GET /jobs -> 200 [job_ref]",
       tooling: "curl", issue: 502}]}' > "$T/old-spec.json"
  {
    cat "$T/prose-head.md"
    printf '\n<details>\n<summary>machine-readable story spec (story-spec/v1)</summary>\n\n```json\n'
    jq . "$T/old-spec.json"
    printf '```\n\n</details>\n'
  } > "$T/story.md"

  NOTE='Reconciled before close: the build found 403, not 401 (story #3089).'
  jq -n --arg note "$NOTE" \
    '{"tc-error-bad-token": {shape: "GET /jobs with an expired token -> 403", note: $note}}' > "$T/map.json"
}

reconcile() { run env PATH="$STUB:$PATH" zsh "$S" "$@"; }

# The prose region (between the sentinels) of a body file.
prose_of() { awk '/^<!-- story-spec:prose:end -->$/{f=0} f; /^<!-- story-spec:prose:start -->$/{f=1}' "$1"; }
spec_of() { zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/read-story-spec.zsh" --file "$1"; }

@test "a contradicted entry: shape set, provisional dropped, reconciled set, prose and provenance unchanged" {
  reconcile --repo o/r --story 3089 --map "$T/map.json"
  [ "$status" -eq 0 ]
  [ -f "$T/story-written.md" ]
  local spec; spec="$(spec_of "$T/story-written.md")"
  [ "$(jq -r '.test_cases[0].shape' <<<"$spec")" = "GET /jobs with an expired token -> 403" ]
  [ "$(jq -r '.test_cases[0] | has("provisional")' <<<"$spec")" = "false" ]
  [ "$(jq -r '.test_cases[0].reconciled' <<<"$spec")" = "$NOTE" ]
  [ "$(jq -r '.test_cases[0].issue' <<<"$spec")" = "501" ]
  # the other entry is untouched
  [ "$(jq -c '.test_cases[1]' <<<"$spec")" = "$(jq -c '.test_cases[1]' "$T/old-spec.json")" ]
  # provenance carried over, and the prose region is byte-identical, so the hash verifies
  [ "$(jq -c '.provenance' <<<"$spec")" = "$(jq -c '.provenance' "$T/old-spec.json")" ]
  [ "$(prose_of "$T/story-written.md")" = "$(prose_of "$T/story.md")" ]
  prose_of "$T/story-written.md" > "$T/written-prose.txt"
  [ "$(zsh "$HASH" --file "$T/written-prose.txt")" = "$(jq -r '.provenance.prose_sha256' <<<"$spec")" ]
  # everything before the opening fence is byte-identical too
  local open; open="$(grep -n '^```json$' "$T/story.md" | cut -d: -f1)"
  cmp <(head -n "$open" "$T/story.md") <(head -n "$open" "$T/story-written.md")
  # the summary (stdout's last line, after the spin-out's progress) names the updated case and its issue
  [ "$(jq -c '.updated' <<<"${lines[${#lines[@]}-1]}")" = '[{"id":"tc-error-bad-token","issue":501,"shape":"GET /jobs with an expired token -> 403"}]' ]
}

@test "the linked test-case body is re-rendered by the spin-out, with the note beneath ## Shape" {
  reconcile --repo o/r --story 3089 --map "$T/map.json"
  [ "$status" -eq 0 ]
  local log; log="$(cat "$T/tc-edits.log")"
  contains "$log" '=== edit #501 ==='
  contains "$log" '<!-- managed by /development:refine-issue test-case spin-out (#671)'
  contains "$log" $'## Shape\n\nGET /jobs with an expired token -> 403\n\n'"$NOTE"$'\n\n---'
  lacks "$log" '-> 401'
  # no orphan is closed and nothing new is created: the case set is unchanged
  run ! grep -q -e '^issue close' -e '^issue create' "$T/calls.log"
}

@test "the spin-out is called with --spec on the new block and --old-spec on the block before" {
  # a scratch plugin tree whose spin-out only logs what it was given
  P="$T/plug/development"
  mkdir -p "$P/skills/resolve-issue/scripts" "$P/skills/refine-issue/scripts"
  cp "$S" "$REPO_ROOT/development/skills/resolve-issue/scripts/read-story-spec.zsh" "$P/skills/resolve-issue/scripts/"
  cat > "$P/skills/refine-issue/scripts/test-case-spinout.zsh" <<EOF
#!/usr/bin/env zsh
print -r -- "\$*" > "$T/spinout-argv"
while (( \$# > 0 )); do
  case "\$1" in --spec) cp "\$2" "$T/spinout-spec.json";; --old-spec) cp "\$2" "$T/spinout-old.json";; esac
  shift
done
jq -c '.test_cases' "$T/spinout-spec.json"
EOF
  chmod +x "$P/skills/refine-issue/scripts/test-case-spinout.zsh"
  run env PATH="$STUB:$PATH" zsh "$P/skills/resolve-issue/scripts/reconcile-test-case-spec.zsh" \
    --repo o/r --story 3089 --map "$T/map.json"
  [ "$status" -eq 0 ]
  contains "$(cat "$T/spinout-argv")" '--repo o/r --story 3089 --spec '
  contains "$(cat "$T/spinout-argv")" ' --old-spec '
  [ "$(jq -r '.test_cases[0].shape' "$T/spinout-spec.json")" = "GET /jobs with an expired token -> 403" ]
  [ "$(jq -r '.test_cases[0].shape' "$T/spinout-old.json")" = "GET /jobs with an expired token -> 401" ]
}

@test "an entry that already matches the shipped expectation writes nothing" {
  jq -n --arg note "$NOTE" \
    '{"tc-happy-list-jobs": {shape: "GET /jobs -> 200 [job_ref]", note: $note}}' > "$T/match.json"
  reconcile --repo o/r --story 3089 --map "$T/match.json"
  [ "$status" -eq 0 ]
  [ "$output" = '{"updated":[],"unchanged":["tc-happy-list-jobs"]}' ]
  [ ! -f "$T/story-written.md" ]
  [ ! -s "$T/tc-edits.log" ]
  run ! grep -q '^issue edit' "$T/calls.log"
}

@test "a re-run on the reconciled story writes nothing" {
  reconcile --repo o/r --story 3089 --map "$T/map.json"
  [ "$status" -eq 0 ]
  cp "$T/story-written.md" "$T/story.md"
  rm -f "$T/story-written.md"; : > "$T/calls.log"; : > "$T/tc-edits.log"
  reconcile --repo o/r --story 3089 --map "$T/map.json"
  [ "$status" -eq 0 ]
  [ "$output" = '{"updated":[],"unchanged":["tc-error-bad-token"]}' ]
  run ! grep -q '^issue edit' "$T/calls.log"
}

@test "a failed re-render exits 1 and leaves the story's block unwritten, and a re-run completes it" {
  touch "$T/fail-tc-edit"
  reconcile --repo o/r --story 3089 --map "$T/map.json"
  [ "$status" -eq 1 ]
  [ ! -f "$T/story-written.md" ]
  rm "$T/fail-tc-edit"
  reconcile --repo o/r --story 3089 --map "$T/map.json"
  [ "$status" -eq 0 ]
  [ -f "$T/story-written.md" ]
  contains "$(cat "$T/tc-edits.log")" "$NOTE"
}

@test "a failed story write exits 1, and a re-run renders and writes again" {
  touch "$T/fail-story-edit"
  reconcile --repo o/r --story 3089 --map "$T/map.json"
  [ "$status" -eq 1 ]
  [ ! -f "$T/story-written.md" ]
  rm "$T/fail-story-edit"
  reconcile --repo o/r --story 3089 --map "$T/map.json"
  [ "$status" -eq 0 ]
  [ "$(spec_of "$T/story-written.md" | jq -r '.test_cases[0].reconciled')" = "$NOTE" ]
}

@test "a map id the story-spec does not carry exits 1 before any write" {
  jq -n --arg note "$NOTE" '{"tc-nope": {shape: "x -> y", note: $note}}' > "$T/bad.json"
  reconcile --repo o/r --story 3089 --map "$T/bad.json"
  [ "$status" -eq 1 ]
  contains "$output" 'has no test case with id: tc-nope'
  run ! grep -q '^issue edit' "$T/calls.log"
}

@test "a story with no story-spec block exits 1 before any write" {
  printf 'just prose\n' > "$T/story.md"
  reconcile --repo o/r --story 3089 --map "$T/map.json"
  [ "$status" -eq 1 ]
  contains "$output" 'carries no readable story-spec/v1 block'
  run ! grep -q '^issue edit' "$T/calls.log"
}

@test "an unreadable story exits 1" {
  touch "$T/fail-view"
  reconcile --repo o/r --story 3089 --map "$T/map.json"
  [ "$status" -eq 1 ]
  contains "$output" 'could not read story #3089'
}

@test "--help prints the header's usage and exits 0 without calling gh" {
  reconcile --help
  [ "$status" -eq 0 ]
  contains "$output" 'reconcile-test-case-spec.zsh --repo <owner/name> --story <N> --map <map.json>'
  run ! grep -q '^issue' "$T/calls.log"
}

@test "usage errors exit 2: missing flags, a non-numeric story, a malformed map" {
  reconcile --story 3089 --map "$T/map.json"
  [ "$status" -eq 2 ]; contains "$output" '--repo is required'
  reconcile --repo o/r --map "$T/map.json"
  [ "$status" -eq 2 ]; contains "$output" '--story is required'
  reconcile --repo o/r --story 3089
  [ "$status" -eq 2 ]; contains "$output" '--map is required'
  reconcile --repo o/r --story abc --map "$T/map.json"
  [ "$status" -eq 2 ]; contains "$output" '--story must be a number'
  reconcile --repo o/r --story 3089 --map
  [ "$status" -eq 2 ]; contains "$output" '--map needs a value'
  reconcile --repo o/r --story 3089 --bogus x
  [ "$status" -eq 2 ]; contains "$output" 'unknown arg: --bogus'
  reconcile --repo o/r --story 3089 --map "$T/nope.json"
  [ "$status" -eq 2 ]; contains "$output" 'map file not found'
  jq -n '{"tc-error-bad-token": {shape: "x", note: "not the note"}}' > "$T/badnote.json"
  reconcile --repo o/r --story 3089 --map "$T/badnote.json"
  [ "$status" -eq 2 ]; contains "$output" "each note one 'Reconciled before close: ' line"
  jq -n '{}' > "$T/empty.json"
  reconcile --repo o/r --story 3089 --map "$T/empty.json"
  [ "$status" -eq 2 ]
  run ! grep -q '^issue' "$T/calls.log"
}
