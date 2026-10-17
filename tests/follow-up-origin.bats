#!/usr/bin/env bats
#
# #2581: follow-up-origin.zsh — the follow-up-origin/v1 record that links a
# pipeline-filed follow-up to its source story, its slice and the source
# story's PR. A pure helper, so every mode is driven directly: render, parse,
# set-pr and parked-issues, their refusals, and the wiring sentences in the
# reference and the conductor that tell a session to use it.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  export HOME="$BATS_TEST_TMPDIR/home"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  F="$REPO_ROOT/development/skills/resolve-issue/scripts/follow-up-origin.zsh"
  RI="$REPO_ROOT/development/skills/resolve-issue"
  FINDING="$BATS_TEST_TMPDIR/finding.json"
  printf '%s\n' '{"file":"scripts/a.zsh","line":12,"dimension":"bugs","title":"quoted \"title\" | with a pipe","round":2}' > "$FINDING"
  SEAM="$BATS_TEST_TMPDIR/seam.json"
  printf '%s\n' '{"child":1,"of":2,"criteria":["The first criterion, verbatim.","The second one."]}' > "$SEAM"
}

flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

# --- render -------------------------------------------------------------------

@test "render parked-finding: the visible source line, the marker and a record with exactly the finding" {
  run -0 zsh "$F" render --kind parked-finding --repo owner/name --source 2581 --finding "$FINDING"
  [ "${lines[0]}" = "Filed by /development:resolve-issue from #2581; PR not opened yet." ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/c.md"
  [ "$(grep -cxF -- '<!-- follow-up-origin/v1 -->' "$BATS_TEST_TMPDIR/c.md")" -eq 1 ]
  run -0 zsh "$F" parse < "$BATS_TEST_TMPDIR/c.md"
  printf '%s' "$output" | jq -e '.schema == "follow-up-origin/v1" and .kind == "parked-finding" and .source == {repo: "owner/name", issue: 2581} and .pr == null' >/dev/null
  printf '%s' "$output" | jq -e '(has("seam") | not) and .finding == {file: "scripts/a.zsh", line: 12, dimension: "bugs", title: "quoted \"title\" | with a pipe", round: 2}' >/dev/null
  printf '%s' "$output" | jq -e 'keys_unsorted == ["schema", "kind", "source", "pr", "finding"]' >/dev/null
}

@test "render split-child with --pr: the PR in the visible line and a record with exactly the seam" {
  run -0 zsh "$F" render --kind split-child --repo owner/name --source 7 --seam "$SEAM" --pr 42
  [ "${lines[0]}" = "Filed by /development:resolve-issue from #7, PR #42." ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/c.md"
  run -0 zsh "$F" parse < "$BATS_TEST_TMPDIR/c.md"
  printf '%s' "$output" | jq -e '.kind == "split-child" and .pr == 42 and (has("finding") | not)' >/dev/null
  printf '%s' "$output" | jq -e '.seam == {child: 1, of: 2, criteria: ["The first criterion, verbatim.", "The second one."]}' >/dev/null
}

@test "render refuses a kind/payload mismatch, a missing payload and a missing source (exit 2)" {
  run -2 --separate-stderr zsh "$F" render --kind split-child --repo o/r --source 7 --finding "$FINDING"
  contains "$stderr" "--kind split-child takes --seam, not --finding"
  [ -z "$output" ]
  run -2 --separate-stderr zsh "$F" render --kind parked-finding --repo o/r --source 7 --seam "$SEAM"
  contains "$stderr" "--kind parked-finding takes --finding, not --seam"
  run -2 --separate-stderr zsh "$F" render --kind parked-finding --repo o/r --source 7
  contains "$stderr" "--kind parked-finding requires --finding"
  run -2 --separate-stderr zsh "$F" render --kind parked-finding --repo o/r --finding "$FINDING"
  contains "$stderr" "--source is required"
  [ -z "$output" ]
}

@test "render refuses a malformed source, repo, PR, kind and payload (exit 2)" {
  run -2 --separate-stderr zsh "$F" render --kind parked-finding --repo o/r --source 0 --finding "$FINDING"
  contains "$stderr" "--source must be a positive issue number"
  run -2 --separate-stderr zsh "$F" render --kind parked-finding --repo noslash --source 7 --finding "$FINDING"
  contains "$stderr" "--repo must be owner/name"
  run -2 --separate-stderr zsh "$F" render --kind parked-finding --repo o/r --source 7 --finding "$FINDING" --pr abc
  contains "$stderr" "--pr must be a positive PR number"
  run -2 --separate-stderr zsh "$F" render --kind residue --repo o/r --source 7 --finding "$FINDING"
  contains "$stderr" "--kind must be split-child or parked-finding"
  printf '%s\n' '{"child":3,"of":2,"criteria":["x"]}' > "$BATS_TEST_TMPDIR/bad-seam.json"
  run -2 --separate-stderr zsh "$F" render --kind split-child --repo o/r --source 7 --seam "$BATS_TEST_TMPDIR/bad-seam.json"
  contains "$stderr" "seam.child and seam.of must be positive integers with child <= of"
  printf '%s\n' '{"child":1,"of":2,"criteria":[]}' > "$BATS_TEST_TMPDIR/bad-seam.json"
  run -2 --separate-stderr zsh "$F" render --kind split-child --repo o/r --source 7 --seam "$BATS_TEST_TMPDIR/bad-seam.json"
  contains "$stderr" "seam.criteria must be a non-empty array of strings"
  printf '%s\n' '{"file":"a","line":"twelve","dimension":"bugs","title":"t","round":1}' > "$BATS_TEST_TMPDIR/bad-finding.json"
  run -2 --separate-stderr zsh "$F" render --kind parked-finding --repo o/r --source 7 --finding "$BATS_TEST_TMPDIR/bad-finding.json"
  contains "$stderr" "finding.line must be a positive integer or null"
  printf 'not json\n' > "$BATS_TEST_TMPDIR/bad-finding.json"
  run -2 --separate-stderr zsh "$F" render --kind parked-finding --repo o/r --source 7 --finding "$BATS_TEST_TMPDIR/bad-finding.json"
  contains "$stderr" "is not JSON"
}

@test "render refuses an empty --finding or --seam file (exit 2, nothing on stdout)" {
  : > "$BATS_TEST_TMPDIR/empty.json"
  run -2 --separate-stderr zsh "$F" render --kind parked-finding --repo o/r --source 7 --finding "$BATS_TEST_TMPDIR/empty.json"
  contains "$stderr" "is empty"
  [ -z "$output" ]
  run -2 --separate-stderr zsh "$F" render --kind split-child --repo o/r --source 7 --seam "$BATS_TEST_TMPDIR/empty.json"
  contains "$stderr" "is empty"
  [ -z "$output" ]
}

@test "render accepts a finding with a null line, as consolidate-findings emits it" {
  printf '%s\n' '{"file":"a.zsh","line":null,"dimension":"tests","title":"t","round":1}' > "$BATS_TEST_TMPDIR/f.json"
  run -0 zsh "$F" render --kind parked-finding --repo o/r --source 7 --finding "$BATS_TEST_TMPDIR/f.json"
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/c.md"
  run -0 zsh "$F" parse < "$BATS_TEST_TMPDIR/c.md"
  printf '%s' "$output" | jq -e '.finding.line == null' >/dev/null
}

# --- parse --------------------------------------------------------------------

@test "parse round-trips every render output to the same record" {
  zsh "$F" render --kind parked-finding --repo o/r --source 7 --finding "$FINDING" > "$BATS_TEST_TMPDIR/p.md"
  zsh "$F" render --kind split-child --repo o/r --source 7 --seam "$SEAM" --pr 9 > "$BATS_TEST_TMPDIR/s.md"
  local want
  want="$(jq -c '{schema: "follow-up-origin/v1", kind: "parked-finding", source: {repo: "o/r", issue: 7}, pr: null, finding: .}' "$FINDING")"
  run -0 zsh "$F" parse < "$BATS_TEST_TMPDIR/p.md"
  [ "$output" = "$want" ]
  want="$(jq -c '{schema: "follow-up-origin/v1", kind: "split-child", source: {repo: "o/r", issue: 7}, pr: 9, seam: .}' "$SEAM")"
  run -0 zsh "$F" parse < "$BATS_TEST_TMPDIR/s.md"
  [ "$output" = "$want" ]
}

@test "parse finds the record inside a longer comment, and exits 1 on a body with no marker" {
  { printf 'A human wrote this first.\n\n'
    zsh "$F" render --kind parked-finding --repo o/r --source 7 --finding "$FINDING"
    printf '\nAnd this after.\n'; } > "$BATS_TEST_TMPDIR/long.md"
  run -0 zsh "$F" parse < "$BATS_TEST_TMPDIR/long.md"
  printf '%s' "$output" | jq -e '.source.issue == 7' >/dev/null
  run -1 --separate-stderr zsh "$F" parse <<< 'Filed by /development:resolve-issue from #7, but no record.'
  contains "$stderr" "no <!-- follow-up-origin/v1 --> marker"
  [ -z "$output" ]
}

@test "parse exits 2 on a marker with no valid record after it" {
  printf '<!-- follow-up-origin/v1 -->\n```json\n{"schema":"follow-up-origin/v1"\n```\n' > "$BATS_TEST_TMPDIR/bad.md"
  run -2 --separate-stderr zsh "$F" parse < "$BATS_TEST_TMPDIR/bad.md"
  contains "$stderr" "is not JSON"
  printf '<!-- follow-up-origin/v1 -->\n```json\n{"schema":"follow-up-origin/v2"}\n```\n' > "$BATS_TEST_TMPDIR/bad.md"
  run -2 --separate-stderr zsh "$F" parse < "$BATS_TEST_TMPDIR/bad.md"
  contains "$stderr" "invalid record: schema is not follow-up-origin/v1"
  printf '<!-- follow-up-origin/v1 -->\nno fence follows\n' > "$BATS_TEST_TMPDIR/bad.md"
  run -2 --separate-stderr zsh "$F" parse < "$BATS_TEST_TMPDIR/bad.md"
  contains "$stderr" "not followed by a closed json fence"
}

# --- set-pr -------------------------------------------------------------------

@test "set-pr sets the PR on a parked-finding record and is byte-identical on a second run" {
  zsh "$F" render --kind parked-finding --repo o/r --source 7 --finding "$FINDING" > "$BATS_TEST_TMPDIR/c0.md"
  zsh "$F" set-pr --pr 2640 < "$BATS_TEST_TMPDIR/c0.md" > "$BATS_TEST_TMPDIR/c1.md"
  [ "$(head -1 "$BATS_TEST_TMPDIR/c1.md")" = "Filed by /development:resolve-issue from #7, PR #2640." ]
  run -0 zsh "$F" parse < "$BATS_TEST_TMPDIR/c1.md"
  printf '%s' "$output" | jq -e '.pr == 2640 and .kind == "parked-finding"' >/dev/null
  zsh "$F" set-pr --pr 2640 < "$BATS_TEST_TMPDIR/c1.md" > "$BATS_TEST_TMPDIR/c2.md"
  cmp -s "$BATS_TEST_TMPDIR/c1.md" "$BATS_TEST_TMPDIR/c2.md"
}

@test "set-pr returns an already-set comment unchanged byte for byte, whatever surrounds the record" {
  # the comment as GitHub might hand it back: text around it, no trailing newline
  zsh "$F" render --kind parked-finding --repo o/r --source 7 --finding "$FINDING" --pr 5 > "$BATS_TEST_TMPDIR/r.md"
  { printf 'Context above.\n\n'; cat "$BATS_TEST_TMPDIR/r.md"; printf 'Context below.'; } > "$BATS_TEST_TMPDIR/c.md"
  zsh "$F" set-pr --pr 5 < "$BATS_TEST_TMPDIR/c.md" > "$BATS_TEST_TMPDIR/out.md"
  cmp -s "$BATS_TEST_TMPDIR/c.md" "$BATS_TEST_TMPDIR/out.md"
}

@test "set-pr refuses a different already-set PR and any split-child record (exit 2)" {
  zsh "$F" render --kind parked-finding --repo o/r --source 7 --finding "$FINDING" --pr 5 > "$BATS_TEST_TMPDIR/p.md"
  run -2 --separate-stderr zsh "$F" set-pr --pr 6 < "$BATS_TEST_TMPDIR/p.md"
  contains "$stderr" "already names PR #5; refusing to replace it with #6"
  [ -z "$output" ]
  zsh "$F" render --kind split-child --repo o/r --source 7 --seam "$SEAM" > "$BATS_TEST_TMPDIR/s.md"
  run -2 --separate-stderr zsh "$F" set-pr --pr 6 < "$BATS_TEST_TMPDIR/s.md"
  contains "$stderr" "refusing a split-child record"
  [ -z "$output" ]
}

@test "set-pr exits 1 on a comment with no record, and 2 on a malformed --pr" {
  run -1 --separate-stderr zsh "$F" set-pr --pr 6 <<< 'just a comment'
  contains "$stderr" "no <!-- follow-up-origin/v1 --> marker"
  run -2 --separate-stderr zsh "$F" set-pr --pr 0 <<< 'just a comment'
  contains "$stderr" "--pr must be a positive PR number"
  run -2 --separate-stderr zsh "$F" set-pr --pr
  contains "$stderr" "--pr requires a value"
}

# --- parked-issues ------------------------------------------------------------

@test "parked-issues lists the deduplicated issue numbers of the - parked: notes, first seen first" {
  printf '%s\n' '**Round 2**' '- parked: an arrow -> in the title -> #31' 'some other line' \
    '- parked: second finding -> #29' '- parked: an arrow -> in the title -> #31' \
    '  - parked: indented, not a note -> #99' '- parked: no number -> #' > "$BATS_TEST_TMPDIR/progress.md"
  run -0 zsh "$F" parked-issues --progress "$BATS_TEST_TMPDIR/progress.md"
  [ "$output" = "$(printf '31\n29')" ]
}

@test "parked-issues exits 1 when there is no parked note, and 2 on an unreadable file" {
  printf '%s\n' '**Round 1**' 'nothing parked' > "$BATS_TEST_TMPDIR/progress.md"
  run -1 --separate-stderr zsh "$F" parked-issues --progress "$BATS_TEST_TMPDIR/progress.md"
  contains "$stderr" "no '- parked:' note"
  [ -z "$output" ]
  run -2 --separate-stderr zsh "$F" parked-issues --progress "$BATS_TEST_TMPDIR/missing.md"
  contains "$stderr" "cannot read --progress"
}

@test "an unknown mode, a missing mode and an unknown argument are usage errors (exit 2)" {
  run -2 --separate-stderr zsh "$F"
  contains "$stderr" "usage: follow-up-origin.zsh render|parse|set-pr|parked-issues"
  run -2 --separate-stderr zsh "$F" file
  contains "$stderr" "unknown mode 'file'"
  run -2 --separate-stderr zsh "$F" parse --extra
  contains "$stderr" "parse takes no arguments"
  run -2 --separate-stderr zsh "$F" render --bogus x
  contains "$stderr" "render: unknown argument: --bogus"
}

# --- the wiring ---------------------------------------------------------------

@test "the fix pass posts the origin comment on a parked follow-up, outside the frozen span" {
  # the procedure lives in the fix subagent's own brief
  local b; b="$(flat "$RI/reference/review-loop/briefs/fix.md")"
  grep -qF '**Parked follow-ups carry their origin (#2581).** When you park a finding and file its follow-up, also post one origin comment on that issue.' <<< "$b"
  grep -qF 'follow-up-origin.zsh" render --kind parked-finding' <<< "$b"
  grep -qF 'Take `--repo` from `gh repo view --json nameWithOwner -q .nameWithOwner`, run in `worktree_root`.' <<< "$b"
  grep -qF 'Take `--source` from the branch name, which `/development:git-branch-naming` fixes as `<type>/<N>-<slug>`: run `git -C <worktree_root> rev-parse --abbrev-ref HEAD` and use the digits after the first `/`.' <<< "$b"
  grep -qF 'When the branch does not have that shape, post no origin comment and write the parked note as `- parked: <title> (no origin: branch <name>) -> #<issue>`; never guess a number.' <<< "$b"
  grep -qF 'Otherwise post the render output as a comment on the issue you just filed, with no `--pr`' <<< "$b"
  grep -qF 'Post it once, when the issue is filed — a later round that reuses the number posts nothing.' <<< "$b"
  grep -qF 'An exit 2 is your own malformed identity: fix the file and re-run.' <<< "$b"
  # exit-20 keeps only a short note pointing at the brief
  local t; t="$(flat "$RI/reference/review-loop/exit-20-awaiting-fix.md")"
  grep -qF '**Parked follow-ups carry their origin (#2581).**' <<< "$t"
  grep -qF 'it also posts one origin comment on the filed issue, which the fix brief (`reference/review-loop/briefs/fix.md`) says how to do.' <<< "$t"
  # the note sits after the frozen span closes, and the span still verifies
  local close note
  close="$(grep -nxF '<!-- /moved: round-protocol-steps-3-4 -->' "$RI/reference/review-loop/exit-20-awaiting-fix.md" | cut -d: -f1)"
  note="$(grep -nF '**Parked follow-ups carry their origin (#2581).**' "$RI/reference/review-loop/exit-20-awaiting-fix.md" | cut -d: -f1)"
  [ -n "$close" ]
  [ -n "$note" ]
  [ "$note" -gt "$close" ]
  run -0 zsh "$RI/scripts/verify-reference-move.zsh" --quiet
}

@test "SKILL.md §6 sets the PR on the parked follow-ups once the PR opens, idempotently" {
  local t; t="$(flat "$RI/SKILL.md")"
  grep -qF '**Link parked follow-ups to the PR (#2581).**' <<< "$t"
  grep -qF 'follow-up-origin.zsh parked-issues --progress <work-dir>/progress.md' <<< "$t"
  grep -qF 'follow-up-origin.zsh set-pr --pr <N>' <<< "$t"
  grep -qF 'edit the comment only when the output differs from it' <<< "$t"
  grep -qF 'An issue with no origin comment (filed before #2581), or an exit 2 from `set-pr`, is named in the Summary and left as it is — never post a second origin comment.' <<< "$t"
}

@test "ARCHITECTURE.md states the follow-up-origin/v1 contract" {
  local t; t="$(flat "$REPO_ROOT/ARCHITECTURE.md")"
  grep -qF '### `follow-up-origin/v1` — where a pipeline-filed follow-up came from (#2581)' "$REPO_ROOT/ARCHITECTURE.md"
  grep -qF 'The record lives in **one comment** on the follow-up, never in its body' <<< "$t"
  grep -qF 'Two producers and one reader' <<< "$t"
  grep -qF '`<!-- follow-up-origin/v1 -->`' <<< "$t"
}
