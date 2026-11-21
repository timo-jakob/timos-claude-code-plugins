#!/usr/bin/env bats
#
# #3212: the bugs concern of /development:maintenance, first half — who may
# file an eligible bug (codeowners-logins.zsh), what state every open bug is in
# (list-bugs.zsh), the bug spec on the issue body (bug-spec.zsh) and whether a
# code owner confirmed it (check-bug-confirmation.zsh). `gh` is a stub that
# serves fixture JSON from $FIX; it sits FIRST on PATH, so a host copy of `gh`
# (the ubuntu runner ships one in /usr/bin) is never reached. Every login, team
# and repo here is invented.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GITHUB_ACTIONS GH_TOKEN
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/maintenance/scripts"
  OWNERS="$SCRIPTS/codeowners-logins.zsh"
  LIST="$SCRIPTS/list-bugs.zsh"
  SPEC="$SCRIPTS/bug-spec.zsh"
  CHECK="$SCRIPTS/check-bug-confirmation.zsh"
  CODEOWNERS_FIXTURE="$REPO_ROOT/tests/fixtures/maintenance-bugs/CODEOWNERS"
  export FIX="$BATS_TEST_TMPDIR/fix"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$FIX" "$TMPDIR" "$CHECKOUT/.github"
  cp "$CODEOWNERS_FIXTURE" "$CHECKOUT/.github/CODEOWNERS"
  printf '[{"login":"Carol-Core"},{"login":"dave-core"}]\n' > "$FIX/team-acme-core.json"
  printf '[]\n' > "$FIX/prs.json"
  printf '[]\n' > "$FIX/issues.json"
  stub_gh
}

# gh: logs argv; `repo view`, `issue list`, `pr list`, a team's members and a
# GraphQL issue read are served from $FIX. GH_FAIL names one of those to fail.
stub_gh() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "repo view") [ "${GH_FAIL:-}" != repo ] || exit 1; echo acme/widgets ;;
  "issue list") [ "${GH_FAIL:-}" != issues ] || exit 1; cat "$FIX/issues.json" ;;
  "pr list") [ "${GH_FAIL:-}" != prs ] || exit 1; cat "$FIX/prs.json" ;;
  "api --paginate")
    [ "${GH_FAIL:-}" != team ] || exit 1
    team="$(printf '%s' "$3" | sed -n 's|^orgs/\([^/]*\)/teams/\([^/]*\)/members$|\1-\2|p')"
    [ -f "$FIX/team-$team.json" ] || exit 1
    cat "$FIX/team-$team.json" ;;
  "api graphql")
    [ "${GH_FAIL:-}" != graphql ] || exit 1
    n=""
    for a in "$@"; do case "$a" in number=*) n="${a#number=}" ;; esac; done
    [ -f "$FIX/issue-$n.json" ] || exit 1
    cat "$FIX/issue-$n.json" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
}

# An analysis the bug-analyst agent could return; $1 is the verdict.
analysis() {
  local verdict="${1:-bug}" reclass=null
  [ "$verdict" = bug ] || reclass='"feature"'
  jq -n --arg v "$verdict" --argjson r "$reclass" '{
    observed: "Exporting a report with an umlaut in its title writes a mangled file name.",
    falsifying_test: {path: "tests/export.bats", name: "an umlaut survives the export", command: "bats tests/export.bats"},
    repro_steps: ["Create a report titled Müller-Quartal", "Export it"],
    expected: "The file is named Müller-Quartal.pdf.",
    cites: ["docs/reference/export.md"],
    verdict: $v, reclassify_as: $r, intentional_per: null,
    fixed_when: ["the falsifying test passes", "nothing else specified changes"],
    draft_prose: "### Observed\n\nExporting a report titled Müller-Quartal writes M?ller-Quartal.pdf; the test `bats tests/export.bats` fails on it today.\n\n### Expected\n\nThe file is named Müller-Quartal.pdf, as docs/reference/export.md says.\n\n### Verdict\n\nA bug.\n\n### Fixed when\n\n- the falsifying test passes\n- nothing else specified changes"
  }'
}

# A body carrying a rendered spec of verdict $1, written to $2.
spec_body() {
  analysis "$1" > "$BATS_TEST_TMPDIR/analysis.json"
  printf 'The export breaks on umlauts.\n' > "$BATS_TEST_TMPDIR/orig.md"
  zsh "$SPEC" render --analysis "$BATS_TEST_TMPDIR/analysis.json" --body-file "$BATS_TEST_TMPDIR/orig.md" \
    --generated-at 2026-11-01T10:00:00Z > "$2"
}

# The GraphQL document for issue $1: body file $2, labels (JSON array of names)
# $3, label events (JSON array of {createdAt, label: {name}, actor: {login}}) $4,
# lastEditedAt $5 (or null).
graphql_issue() {
  jq -n --rawfile body "$2" --argjson labels "$3" --argjson events "$4" --argjson edited "$5" '
    {data: {repository: {issue: {body: $body, lastEditedAt: $edited,
      labels: {nodes: ($labels | map({name: .}))}, timelineItems: {nodes: $events}}}}}' > "$FIX/issue-$1.json"
}

# An event applying `confirmed` by $1 at $2.
confirmed_by() {
  jq -cn --arg who "$1" --arg at "$2" '[{createdAt: $at, label: {name: "confirmed"}, actor: {login: $who}}]'
}

# A confirmed issue $1: a bug spec, the label applied by $2 (default an owner).
confirmed_issue() {
  spec_body bug "$BATS_TEST_TMPDIR/body-$1.md"
  graphql_issue "$1" "$BATS_TEST_TMPDIR/body-$1.md" '["bug","confirmed"]' \
    "$(confirmed_by "${2:-alice-owner}" 2026-11-02T09:00:00Z)" '"2026-11-01T10:00:05Z"'
}

# ---- codeowners-logins.zsh -------------------------------------------------

@test "codeowners: a login, a team's members and a repeated owner, lowercased, sorted and unique" {
  run --separate-stderr zsh "$OWNERS" --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'alice-owner\nbob-owner\ncarol-core\ndave-core')" ]
  contains "$(cat "$GH_LOG")" 'api --paginate orgs/acme/teams/core/members'
  lacks "$output" mallory
}

@test "codeowners: an e-mail entry is skipped, never read as a login" {
  run --separate-stderr zsh "$OWNERS" --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
  lacks "$output" 'example.com'
  lacks "$output" 'docs-team'
}

@test "codeowners: the root CODEOWNERS is read when .github/ has none" {
  mv "$CHECKOUT/.github/CODEOWNERS" "$CHECKOUT/CODEOWNERS"
  run --separate-stderr zsh "$OWNERS" --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
  contains "$output" 'bob-owner'
}

@test "codeowners: docs/CODEOWNERS is read when neither earlier location has one" {
  mkdir -p "$CHECKOUT/docs"
  mv "$CHECKOUT/.github/CODEOWNERS" "$CHECKOUT/docs/CODEOWNERS"
  run --separate-stderr zsh "$OWNERS" --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
  contains "$output" 'bob-owner'
}

@test "codeowners: the first location wins, in GitHub's order" {
  printf '* @root-only\n' > "$CHECKOUT/CODEOWNERS"
  mkdir -p "$CHECKOUT/docs"
  printf '* @docs-only\n' > "$CHECKOUT/docs/CODEOWNERS"
  run --separate-stderr zsh "$OWNERS" --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
  lacks "$output" 'root-only'
  lacks "$output" 'docs-only'
  rm "$CHECKOUT/.github/CODEOWNERS"
  run --separate-stderr zsh "$OWNERS" --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
  [ "$output" = root-only ]
}

@test "codeowners: no CODEOWNERS file at all is exit 3, and stderr says so" {
  rm "$CHECKOUT/.github/CODEOWNERS"
  run --separate-stderr zsh "$OWNERS" --repo-dir "$CHECKOUT"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'no CODEOWNERS file'
}

@test "codeowners: a file whose only owners are e-mail entries is exit 3" {
  printf '# mail only\n*  team@example.com\n/docs/ docs@example.com\n' > "$CHECKOUT/.github/CODEOWNERS"
  run --separate-stderr zsh "$OWNERS" --repo-dir "$CHECKOUT"
  [ "$status" -eq 3 ]
  contains "$stderr" '.github/CODEOWNERS names no resolvable owner'
}

@test "codeowners: a team whose members cannot be read is exit 1, never a partial list" {
  run --separate-stderr env GH_FAIL=team zsh "$OWNERS" --repo-dir "$CHECKOUT"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" 'could not read the members of team @acme/core'
}

@test "codeowners: an unknown flag or a missing value is usage, exit 2" {
  run --separate-stderr zsh "$OWNERS" --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$OWNERS" --repo-dir
  [ "$status" -eq 2 ]
}

# ---- bug-spec.zsh ----------------------------------------------------------

@test "bug-spec: render writes the four headings, the sentinels and a bug-spec/v1 mirror below the original body" {
  spec_body bug "$BATS_TEST_TMPDIR/body.md"
  local b
  b="$(cat "$BATS_TEST_TMPDIR/body.md")"
  starts_with "$b" 'The export breaks on umlauts.'
  contains "$b" '<!-- bug-spec:prose:start -->'
  contains "$b" '### Observed'
  contains "$b" '### Expected'
  contains "$b" '### Verdict'
  contains "$b" '### Fixed when'
  contains "$b" '<!-- bug-spec:prose:end -->'
  ends_with "$b" '<!-- bug-spec:end -->'
  run --separate-stderr zsh "$SPEC" read --body-file "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.block.schema' <<< "$output")" = bug-spec/v1 ]
  [ "$(jq -r '.block.provenance.generated_at' <<< "$output")" = 2026-11-01T10:00:00Z ]
  [ "$(jq -r '.block.falsifying_test.command' <<< "$output")" = 'bats tests/export.bats' ]
  [ "$(jq -r '[.block | keys[]] | join(",")' <<< "$output")" = 'cites,falsifying_test,fixed_when,provenance,reclassify_as,repro_steps,schema,verdict' ]
  [ "$(jq -c '.block | [.repro_steps, .cites, .fixed_when]' <<< "$output")" = "$(jq -c '[.repro_steps, .cites, .fixed_when]' "$BATS_TEST_TMPDIR/analysis.json")" ]
}

@test "bug-spec: the mirror's prose hash is refine-issue's prose hash of the prose region" {
  spec_body bug "$BATS_TEST_TMPDIR/body.md"
  local want
  want="$(jq -r '.draft_prose + "\n\nFalsifying test: `" + .falsifying_test.command + "`"' "$BATS_TEST_TMPDIR/analysis.json" \
    | zsh "$REPO_ROOT/development/skills/refine-issue/scripts/story-spec-prose-hash.zsh")"
  run --separate-stderr zsh "$SPEC" read --body-file "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.block.provenance.prose_sha256' <<< "$output")" = "$want" ]
  [ "$(jq -r '.prose_sha256' <<< "$output")" = "$want" ]
}

@test "bug-spec: a re-render replaces the old spec rather than stacking a second one" {
  spec_body bug "$BATS_TEST_TMPDIR/body.md"
  printf '\nA later note from the reporter.\n' >> "$BATS_TEST_TMPDIR/body.md"
  analysis not-a-bug > "$BATS_TEST_TMPDIR/second.json"
  run --separate-stderr zsh "$SPEC" render --analysis "$BATS_TEST_TMPDIR/second.json" \
    --body-file "$BATS_TEST_TMPDIR/body.md" --generated-at 2026-11-03T10:00:00Z
  [ "$status" -eq 0 ]
  [ "$(grep -c 'bug-spec:prose:start' <<< "$output")" -eq 1 ]
  [ "$(grep -c 'bug-spec:end' <<< "$output")" -eq 1 ]
  contains "$output" 'A later note from the reporter.'
  contains "$output" 'The export breaks on umlauts.'
  contains "$output" '"verdict": "not-a-bug"'
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/rerendered.md"
  [ "$(zsh "$SPEC" read --body-file "$BATS_TEST_TMPDIR/rerendered.md" | jq -r '.block.reclassify_as')" = feature ]
}

@test "bug-spec: render refuses an analysis whose draft prose lacks a heading, exit 1" {
  analysis bug | jq '.draft_prose |= sub("### Verdict"; "### Judgement")' > "$BATS_TEST_TMPDIR/a.json"
  run --separate-stderr zsh "$SPEC" render --analysis "$BATS_TEST_TMPDIR/a.json"
  [ "$status" -eq 1 ]
  contains "$stderr" "lacks the heading '### Verdict'"
}

@test "bug-spec: render ends the prose with the falsifying test's line, and writes none without a test (#3213)" {
  analysis bug > "$BATS_TEST_TMPDIR/a.json"
  run --separate-stderr zsh "$SPEC" render --analysis "$BATS_TEST_TMPDIR/a.json"
  [ "$status" -eq 0 ]
  contains "$output" $'- nothing else specified changes\n\nFalsifying test: `bats tests/export.bats`\n<!-- bug-spec:prose:end -->'
  analysis bug | jq '.falsifying_test = null' > "$BATS_TEST_TMPDIR/a.json"
  run --separate-stderr zsh "$SPEC" render --analysis "$BATS_TEST_TMPDIR/a.json"
  [ "$status" -eq 0 ]
  lacks "$output" 'Falsifying test:'
}

@test "bug-spec: read prints the prose region's text beside its hash (#3213)" {
  spec_body bug "$BATS_TEST_TMPDIR/body.md"
  run --separate-stderr zsh "$SPEC" read --body-file "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  # the region opens with the newline after its start sentinel
  [ "$(jq -r '.prose' <<< "$output" | sed '1{/^$/d;}')" = "$(jq -r '.draft_prose + "\n\nFalsifying test: `" + .falsifying_test.command + "`"' "$BATS_TEST_TMPDIR/analysis.json")" ]
}

@test "bug-spec: render refuses a verdict or a reclassification outside its enum, exit 1" {
  analysis bug | jq '.verdict = "maybe"' > "$BATS_TEST_TMPDIR/a.json"
  run --separate-stderr zsh "$SPEC" render --analysis "$BATS_TEST_TMPDIR/a.json"
  [ "$status" -eq 1 ]
  analysis not-a-bug | jq '.reclassify_as = "wish"' > "$BATS_TEST_TMPDIR/a.json"
  run --separate-stderr zsh "$SPEC" render --analysis "$BATS_TEST_TMPDIR/a.json"
  [ "$status" -eq 1 ]
  contains "$stderr" 'not a usable bug-analyst object'
}

@test "bug-spec: render refuses a body whose spec region has no end marker, exit 1" {
  analysis bug > "$BATS_TEST_TMPDIR/a.json"
  printf 'Body\n<!-- bug-spec:prose:start -->\n### Observed\n' > "$BATS_TEST_TMPDIR/cut.md"
  run --separate-stderr zsh "$SPEC" render --analysis "$BATS_TEST_TMPDIR/a.json" --body-file "$BATS_TEST_TMPDIR/cut.md"
  [ "$status" -eq 1 ]
  contains "$stderr" 'no end marker'
}

@test "bug-spec: read on a body with no spec, or with an unparseable block, is exit 1" {
  run --separate-stderr zsh "$SPEC" read <<< 'Just a bug report.'
  [ "$status" -eq 1 ]
  spec_body bug "$BATS_TEST_TMPDIR/body.md"
  sed 's/"schema": "bug-spec\/v1",/"schema": "bug-spec\/v1"/' "$BATS_TEST_TMPDIR/body.md" > "$BATS_TEST_TMPDIR/broken.md"
  run --separate-stderr zsh "$SPEC" read --body-file "$BATS_TEST_TMPDIR/broken.md"
  [ "$status" -eq 1 ]
  contains "$stderr" 'missing, unparseable or not bug-spec/v1'
}

@test "bug-spec: a missing subcommand or an unreadable file is usage (2) or runtime (3)" {
  run --separate-stderr zsh "$SPEC"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$SPEC" render
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$SPEC" read --body-file "$BATS_TEST_TMPDIR/absent.md"
  [ "$status" -eq 3 ]
}

# ---- check-bug-confirmation.zsh --------------------------------------------

@test "confirmation: a spec, a bug verdict, an owner's label and no later edit is exit 0" {
  confirmed_issue 41
  run --separate-stderr zsh "$CHECK" 41 --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.confirmed_by' <<< "$output")" = alice-owner ]
  [ "$(jq -r '.labelled_at' <<< "$output")" = 2026-11-02T09:00:00Z ]
}

@test "confirmation: a team member's label counts as a code owner's" {
  confirmed_issue 42 Carol-Core
  run --separate-stderr zsh "$CHECK" 42 --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
}

@test "confirmation: no bug spec on the body is no-spec" {
  printf 'Exports break.\n' > "$BATS_TEST_TMPDIR/plain.md"
  graphql_issue 43 "$BATS_TEST_TMPDIR/plain.md" '["bug","confirmed"]' "$(confirmed_by alice-owner 2026-11-02T09:00:00Z)" null
  run --separate-stderr zsh "$CHECK" 43 --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 1 ]
  [ "$stderr" = 'bug-confirmation: no-spec' ]
}

@test "confirmation: a not-a-bug verdict is not-a-bug, whoever labelled it" {
  spec_body not-a-bug "$BATS_TEST_TMPDIR/b.md"
  graphql_issue 44 "$BATS_TEST_TMPDIR/b.md" '["bug","confirmed"]' "$(confirmed_by alice-owner 2026-11-02T09:00:00Z)" null
  run --separate-stderr zsh "$CHECK" 44 --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 1 ]
  [ "$stderr" = 'bug-confirmation: not-a-bug' ]
}

@test "confirmation: a spec without the confirmed label is no-label" {
  spec_body bug "$BATS_TEST_TMPDIR/b.md"
  graphql_issue 45 "$BATS_TEST_TMPDIR/b.md" '["bug"]' '[]' null
  run --separate-stderr zsh "$CHECK" 45 --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 1 ]
  [ "$stderr" = 'bug-confirmation: no-label' ]
}

@test "confirmation: a label an issue form applied for its non-owner author is label-not-by-code-owner" {
  confirmed_issue 46 erin-reporter
  run --separate-stderr zsh "$CHECK" 46 --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 1 ]
  [ "$stderr" = 'bug-confirmation: label-not-by-code-owner' ]
}

@test "confirmation: only the latest event applying the label counts" {
  spec_body bug "$BATS_TEST_TMPDIR/b.md"
  local owner_then_bot
  owner_then_bot="$(jq -cn '[
    {createdAt: "2026-11-02T09:00:00Z", label: {name: "confirmed"}, actor: {login: "alice-owner"}},
    {createdAt: "2026-11-02T09:30:00Z", label: {name: "priority: high"}, actor: {login: "alice-owner"}},
    {createdAt: "2026-11-03T09:00:00Z", label: {name: "confirmed"}, actor: {login: "some-bot"}}]')"
  graphql_issue 47 "$BATS_TEST_TMPDIR/b.md" '["bug","confirmed"]' "$owner_then_bot" null
  run --separate-stderr zsh "$CHECK" 47 --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 1 ]
  [ "$stderr" = 'bug-confirmation: label-not-by-code-owner' ]
}

@test "confirmation: a repo with no code owners cannot confirm anything" {
  confirmed_issue 48
  rm "$CHECKOUT/.github/CODEOWNERS"
  run --separate-stderr zsh "$CHECK" 48 --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 1 ]
  starts_with "$stderr" 'bug-confirmation: label-not-by-code-owner'
  contains "$stderr" 'no code owners'
}

@test "confirmation: an owner's label, then a body edit, is spec-edited-after-label" {
  spec_body bug "$BATS_TEST_TMPDIR/b.md"
  graphql_issue 49 "$BATS_TEST_TMPDIR/b.md" '["bug","confirmed"]' \
    "$(confirmed_by alice-owner 2026-11-02T09:00:00Z)" '"2026-11-02T09:00:01Z"'
  run --separate-stderr zsh "$CHECK" 49 --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 1 ]
  starts_with "$stderr" 'bug-confirmation: spec-edited-after-label'
  contains "$stderr" 'edited after the label'
}

@test "confirmation: prose that no longer matches its hash is spec-prose-edited" {
  spec_body bug "$BATS_TEST_TMPDIR/b.md"
  sed 's/^A bug\.$/A bug, and a bad one./' "$BATS_TEST_TMPDIR/b.md" > "$BATS_TEST_TMPDIR/edited.md"
  graphql_issue 50 "$BATS_TEST_TMPDIR/edited.md" '["bug","confirmed"]' \
    "$(confirmed_by alice-owner 2026-11-02T09:00:00Z)" null
  run --separate-stderr zsh "$CHECK" 50 --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 1 ]
  starts_with "$stderr" 'bug-confirmation: spec-prose-edited'
  contains "$stderr" 'no longer matches its hash'
}

@test "confirmation: a not-a-bug spec whose prose was edited is spec-prose-edited, not not-a-bug" {
  spec_body not-a-bug "$BATS_TEST_TMPDIR/b.md"
  sed 's/^A bug\.$/A bug, and a bad one./' "$BATS_TEST_TMPDIR/b.md" > "$BATS_TEST_TMPDIR/edited.md"
  graphql_issue 53 "$BATS_TEST_TMPDIR/edited.md" '["bug"]' '[]' null
  run --separate-stderr zsh "$CHECK" 53 --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 1 ]
  starts_with "$stderr" 'bug-confirmation: spec-prose-edited'
}

@test "confirmation: --owners-file replaces the CODEOWNERS lookup" {
  confirmed_issue 51 frank-elsewhere
  printf 'frank-elsewhere\n' > "$BATS_TEST_TMPDIR/owners"
  run --separate-stderr zsh "$CHECK" 51 --repo acme/widgets --owners-file "$BATS_TEST_TMPDIR/owners"
  [ "$status" -eq 0 ]
}

@test "confirmation: an issue that cannot be read is exit 3, never an answer" {
  run --separate-stderr env GH_FAIL=graphql zsh "$CHECK" 52 --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 3 ]
  starts_with "$stderr" 'check-bug-confirmation: could not read issue #52'
}

@test "confirmation: a missing or non-numeric issue, or a second one, is usage, exit 2" {
  run --separate-stderr zsh "$CHECK"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$CHECK" abc
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$CHECK" 1 2
  [ "$status" -eq 2 ]
}

# ---- list-bugs.zsh ---------------------------------------------------------

# An open bug issue for `gh issue list`: number $1, author $2, created $3,
# extra labels (JSON array) $4.
bug_issue() {
  jq -cn --argjson n "$1" --arg a "$2" --arg c "$3" --argjson l "${4:-[]}" '
    {number: $n, title: "Bug \($n)", author: {login: $a}, createdAt: $c,
     labels: (["bug"] + $l | map({name: .}))}'
}

issues() {
  jq -s '.' > "$FIX/issues.json"
}

state_of() {
  jq -r --argjson n "$1" '.[] | select(.number == $n) | .state' <<< "$output"
}

reason_of() {
  jq -r --argjson n "$1" '.[] | select(.number == $n) | .reason' <<< "$output"
}

@test "list: a bug filed by someone who is not a code owner is not-eligible" {
  bug_issue 60 erin-reporter 2026-10-01T00:00:00Z | issues
  run --separate-stderr zsh "$LIST" --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
  [ "$(state_of 60)" = not-eligible ]
  [ "$(reason_of 60)" = 'author @erin-reporter is not a code owner' ]
  # an ineligible bug's issue is never read further
  lacks "$(cat "$GH_LOG")" 'api graphql'
}

@test "list: with no CODEOWNERS every bug is not-eligible, and the reason says so" {
  rm "$CHECKOUT/.github/CODEOWNERS"
  { bug_issue 61 alice-owner 2026-10-01T00:00:00Z; bug_issue 62 erin-reporter 2026-10-02T00:00:00Z; } | issues
  run --separate-stderr zsh "$LIST" --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].state] | unique | join(",")' <<< "$output")" = not-eligible ]
  contains "$(reason_of 61)" 'no code owners: no CODEOWNERS file'
}

@test "list: a hold label or an open PR that closes the bug makes it held" {
  { bug_issue 63 alice-owner 2026-10-01T00:00:00Z '["needs-human-decision"]'
    bug_issue 64 alice-owner 2026-10-02T00:00:00Z; } | issues
  printf '[{"number":300,"closingIssuesReferences":[{"number":64}]}]\n' > "$FIX/prs.json"
  run --separate-stderr zsh "$LIST" --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
  [ "$(state_of 63)" = held ]
  [ "$(reason_of 63)" = 'carries needs-human-decision' ]
  [ "$(state_of 64)" = held ]
  [ "$(reason_of 64)" = 'open PR #300' ]
}

@test "list: each spec state comes from the confirmation check" {
  printf 'No spec yet.\n' > "$BATS_TEST_TMPDIR/plain.md"
  graphql_issue 65 "$BATS_TEST_TMPDIR/plain.md" '["bug"]' '[]' null
  spec_body not-a-bug "$BATS_TEST_TMPDIR/nab.md"
  graphql_issue 66 "$BATS_TEST_TMPDIR/nab.md" '["bug"]' '[]' null
  spec_body bug "$BATS_TEST_TMPDIR/await.md"
  graphql_issue 67 "$BATS_TEST_TMPDIR/await.md" '["bug"]' '[]' null
  confirmed_issue 68
  { bug_issue 65 alice-owner 2026-10-01T00:00:00Z; bug_issue 66 bob-owner 2026-10-02T00:00:00Z
    bug_issue 67 Dave-Core 2026-10-03T00:00:00Z; bug_issue 68 alice-owner 2026-10-04T00:00:00Z '["confirmed"]'; } | issues
  run --separate-stderr zsh "$LIST" --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
  [ "$(state_of 65)" = needs-analysis ]
  [ "$(reason_of 65)" = 'no bug spec yet' ]
  [ "$(state_of 66)" = not-a-bug ]
  [ "$(reason_of 66)" = "the bug spec's verdict is not-a-bug" ]
  [ "$(state_of 67)" = awaiting-confirmation ]
  [ "$(reason_of 67)" = no-label ]
  [ "$(state_of 68)" = confirmed ]
}

@test "list: an edited spec is needs-analysis whatever its verdict; an unedited not-a-bug is not" {
  spec_body not-a-bug "$BATS_TEST_TMPDIR/nab.md"
  sed 's/^A bug\.$/A bug, and a bad one./' "$BATS_TEST_TMPDIR/nab.md" > "$BATS_TEST_TMPDIR/nab-edited.md"
  graphql_issue 90 "$BATS_TEST_TMPDIR/nab-edited.md" '["bug"]' '[]' null
  graphql_issue 91 "$BATS_TEST_TMPDIR/nab.md" '["bug"]' '[]' null
  spec_body bug "$BATS_TEST_TMPDIR/b.md"
  sed 's/^A bug\.$/A bug, and a bad one./' "$BATS_TEST_TMPDIR/b.md" > "$BATS_TEST_TMPDIR/b-edited.md"
  graphql_issue 92 "$BATS_TEST_TMPDIR/b-edited.md" '["bug","confirmed"]' \
    "$(confirmed_by alice-owner 2026-11-02T09:00:00Z)" null
  { bug_issue 90 alice-owner 2026-10-01T00:00:00Z; bug_issue 91 alice-owner 2026-10-02T00:00:00Z
    bug_issue 92 alice-owner 2026-10-03T00:00:00Z '["confirmed"]'; } | issues
  run --separate-stderr zsh "$LIST" --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
  [ "$(state_of 90)" = needs-analysis ]
  starts_with "$(reason_of 90)" spec-prose-edited
  [ "$(state_of 91)" = not-a-bug ]
  [ "$(state_of 92)" = needs-analysis ]
  starts_with "$(reason_of 92)" spec-prose-edited
}

@test "list: confirmed first, then needs-analysis; high priority first, then oldest, inside each" {
  local n
  for n in 70 71 72; do confirmed_issue "$n"; done
  printf 'No spec yet.\n' > "$BATS_TEST_TMPDIR/plain.md"
  for n in 73 74; do graphql_issue "$n" "$BATS_TEST_TMPDIR/plain.md" '["bug"]' '[]' null; done
  { bug_issue 73 alice-owner 2026-09-01T00:00:00Z
    bug_issue 74 alice-owner 2026-10-05T00:00:00Z '["priority: high"]'
    bug_issue 75 erin-reporter 2026-08-01T00:00:00Z
    bug_issue 70 alice-owner 2026-10-03T00:00:00Z '["confirmed"]'
    bug_issue 71 alice-owner 2026-10-04T00:00:00Z '["confirmed","priority: high"]'
    bug_issue 72 alice-owner 2026-10-01T00:00:00Z '["confirmed"]'; } | issues
  run --separate-stderr zsh "$LIST" --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].number] | join(",")' <<< "$output")" = '71,72,70,74,73,75' ]
  [ "$(jq -r '.[0] | [.priority_high, .author, .created_at] | join(" ")' <<< "$output")" = 'true alice-owner 2026-10-04T00:00:00Z' ]
  [ "$(jq -r '.[0] | keys | join(",")' <<< "$output")" = 'author,created_at,number,priority_high,reason,state,title' ]
}

@test "list: no open bug prints an empty array" {
  run --separate-stderr zsh "$LIST" --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "list: the repo defaults to the session's" {
  run --separate-stderr zsh "$LIST" --repo-dir "$CHECKOUT"
  [ "$status" -eq 0 ]
  contains "$(cat "$GH_LOG")" 'issue list --repo acme/widgets --label bug --state open'
}

@test "list: a failed gh read, or an undecidable check, is exit 1" {
  run --separate-stderr env GH_FAIL=issues zsh "$LIST" --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 1 ]
  contains "$stderr" 'could not list the open bug issues'
  run --separate-stderr env GH_FAIL=prs zsh "$LIST" --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 1 ]
  bug_issue 76 alice-owner 2026-10-01T00:00:00Z | issues
  run --separate-stderr env GH_FAIL=graphql zsh "$LIST" --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 1 ]
  contains "$stderr" 'could not decide #76'
  run --separate-stderr env GH_FAIL=team zsh "$LIST" --repo acme/widgets --repo-dir "$CHECKOUT"
  [ "$status" -eq 1 ]
  contains "$stderr" 'codeowners-logins.zsh failed'
}

@test "list: an unknown flag or a malformed --repo is usage, exit 2" {
  run --separate-stderr zsh "$LIST" --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$LIST" --repo widgets
  [ "$status" -eq 2 ]
}
