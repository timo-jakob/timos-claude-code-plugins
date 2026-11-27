#!/usr/bin/env bats
#
# The target-architecture validator (#3353, a child of #3198):
# development/scripts/reference-docs/validate-target-architecture.zsh checks one
# file against `target-architecture/v1` (ARCHITECTURE.md, *Target architecture
# contract*) and reports every violation as `target-architecture: <rule>: <detail>`.
#
# Two invented fixtures are committed under tests/fixtures/target-architecture/:
# a valid file and the repo-local page its `ref` clause points at. setup() copies
# them into a throwaway git repo, and each violating file is derived from the
# valid one by a helper named after its rule (`derive_<rule>`), so no violating
# file is committed.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  # a git hook or `rebase --exec` exports these, and `git -C` does not override
  # them: the throwaway repo's init would land in the real repository
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GITHUB_ACTIONS
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/scripts/reference-docs/validate-target-architecture.zsh"
  HASHER="$REPO_ROOT/development/skills/refine-issue/scripts/story-spec-prose-hash.zsh"
  FIX="$REPO_ROOT/tests/fixtures/target-architecture"
  R="$BATS_TEST_TMPDIR/repo"
  build_repo "$R"
  F="$R/docs/architecture/target-architecture.md"
}

# build_repo <dir> — a git repo holding the two fixtures where a repo keeps them
build_repo() {
  mkdir -p "$1/docs/architecture"
  cp "$FIX/target-architecture.md" "$FIX/api-styleguide.md" "$1/docs/architecture/"
  git -C "$1" init -q
}

# edit_block <jq-filter> — rewrite the file's json block through jq, leaving
# the prose (and so its hash) untouched
edit_block() {
  local block="$BATS_TEST_TMPDIR/block.json" out="$BATS_TEST_TMPDIR/ta.out"
  awk '/^```json$/ { f = 1; next } f && /^```$/ { exit } f' "$F" | jq "$1" > "$block"
  awk -v bf="$block" '
    /^```json$/ && !done { print; while ((getline l < bf) > 0) print l; skip = 1; done = 1; next }
    skip && /^```$/ { skip = 0 }
    !skip' "$F" > "$out"
  mv "$out" "$F"
}

# One helper per rule, each breaking exactly that rule.
derive_schema()                    { edit_block '.schema = "target-architecture/v2"'; }
derive_bad_id_shape()              { edit_block '.clauses[0].id = "TA-01"'; }
derive_duplicate_id()              { edit_block '.clauses[2].id = "TA-1"'; }
derive_statement_and_ref()         { edit_block '.clauses[2].statement = "Public APIs follow the styleguide."'; }
derive_neither_statement_nor_ref() { edit_block '.clauses[0] |= del(.statement)'; }
derive_retired_unnamed()           { edit_block '.changes[0].affects = []'; }
derive_unresolved_affects()        { edit_block '.changes[0].affects += ["TA-9"]'; }
derive_ref_missing()               { edit_block '.clauses[2].ref.path = "docs/architecture/missing.md"'; }
derive_bad_date()                  { edit_block '.changes[0].date = "2026-11-31"'; }
# the prose changes and the stored hash does not
derive_stale_prose() {
  sed 's/^  ticketing database\.$/  booking database./' "$F" > "$F.new"
  if cmp -s "$F" "$F.new"; then
    echo "derive_stale_prose: sed left the file unchanged" >&2
    return 1
  fi
  mv "$F.new" "$F"
}
derive_two_violations() { derive_duplicate_id; derive_bad_date; }
derive_crlf()           { sed 's/$/\r/' "$F" > "$F.new"; mv "$F.new" "$F"; }

# only_rule <rule> — the last run exited 1 with exactly one stderr line, for <rule>
only_rule() {
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  starts_with "$stderr" "target-architecture: $1: "
}

@test "the valid file passes" {
  run --separate-stderr zsh "$S" "$F"
  [ "$status" -eq 0 ]
  [ "$output" = "target-architecture: valid" ]
  [ -z "$stderr" ]
}

@test "schema: a block whose schema is not target-architecture/v1" {
  derive_schema
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'schema is target-architecture/v2, expected "target-architecture/v1"'
}

@test "schema: no prose sentinels, a duplicated one, or swapped ones" {
  cp "$F" "$BATS_TEST_TMPDIR/valid.md"
  grep -v '^<!-- target-architecture:prose:' "$F" > "$F.new"
  mv "$F.new" "$F"
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'found 0 and 0'
  awk '{ print } /^<!-- target-architecture:prose:start -->$/ { print }' "$BATS_TEST_TMPDIR/valid.md" > "$F"
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'found 2 and 1'
  awk '/^<!-- target-architecture:prose:start -->$/ { print "<!-- target-architecture:prose:end -->"; next }
       /^<!-- target-architecture:prose:end -->$/ { print "<!-- target-architecture:prose:start -->"; next } 1' \
    "$BATS_TEST_TMPDIR/valid.md" > "$F"
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'comes before'
}

@test "schema: no fenced json block, an invalid one, and one outside <details>" {
  cp "$F" "$BATS_TEST_TMPDIR/valid.md"
  awk '/^```json$/ { f = 1; next } f && /^```$/ { f = 0; next } !f' "$F" > "$F.new"
  mv "$F.new" "$F"
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'no fenced json block follows the prose'
  awk '/^```json$/ { print; print "{ not json"; f = 1; next } f && /^```$/ { f = 0 } !f' \
    "$BATS_TEST_TMPDIR/valid.md" > "$F"
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'the json block is not one valid JSON object'
  grep -v -e '^<details>$' -e '^</details>$' "$BATS_TEST_TMPDIR/valid.md" > "$F"
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'not inside a <details> element'
}

@test "schema: provenance with no prose_sha256" {
  edit_block 'del(.provenance.prose_sha256)'
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'prose_sha256 is not 64 lowercase hex digits'
}

@test "schema: a block with no provenance" {
  edit_block 'del(.provenance)'
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'provenance is missing or not an object'
}

@test "schema: clauses or changes that are not an array of objects" {
  edit_block '.changes = {}'
  run --separate-stderr zsh "$S" "$F"
  [ "$status" -eq 1 ]
  contains "$stderr" 'target-architecture: schema: changes is not an array of objects'
  edit_block '.changes = [] | .clauses = "TA-1"'
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'clauses is not an array of objects'
}

@test "schema: a clause with no area, a bad status, an empty statement or a malformed ref" {
  edit_block '.clauses[0] |= del(.area)'
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'TA-1: area is missing or empty'
  edit_block '.clauses[0].area = "services" | .clauses[0].status = "draft"'
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'TA-1: status is draft, expected active or retired'
  edit_block '.clauses[0].status = "active" | .clauses[0].statement = " "'
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'TA-1: statement is empty or not a string'
  edit_block '.clauses[0].statement = "Separate services." | .clauses[2].ref |= del(.title)'
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'TA-3: ref needs string path, anchor and title'
}

@test "schema: a change with a missing field or a non-array affects" {
  edit_block '.changes[0] |= del(.rationale)'
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'TC-2026-11-1: rationale is missing or empty'
  edit_block '.changes[0].rationale = "Releases waited." | .changes[0] |= del(.from)'
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'TC-2026-11-1: from is missing or empty'
  edit_block '.changes[0].from = "One shared database." | .changes[0] |= del(.to)'
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'TC-2026-11-1: to is missing or empty'
  edit_block '.changes[0].to = "One database each." | .changes[0].evidence = "#42"'
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  contains "$stderr" 'TC-2026-11-1: evidence is not an array of strings'
}

@test "bad-id-shape: a clause id that is not TA-<n>" {
  derive_bad_id_shape
  run --separate-stderr zsh "$S" "$F"
  only_rule bad-id-shape
  contains "$stderr" 'TA-01 does not match TA-<n>'
}

@test "bad-id-shape: a change id that is not TC-<yyyy>-<mm>-<n>" {
  edit_block '.changes[0].id = "TC-26-11-1"'
  run --separate-stderr zsh "$S" "$F"
  only_rule bad-id-shape
  contains "$stderr" 'TC-26-11-1 does not match TC-<yyyy>-<mm>-<n>'
}

@test "duplicate-id: one id on two clauses" {
  derive_duplicate_id
  run --separate-stderr zsh "$S" "$F"
  only_rule duplicate-id
  contains "$stderr" 'TA-1 is used 2 times'
}

@test "duplicate-id: one id on two changes" {
  edit_block '.changes += [.changes[0]]'
  run --separate-stderr zsh "$S" "$F"
  only_rule duplicate-id
  contains "$stderr" 'TC-2026-11-1 is used 2 times'
}

@test "statement-and-ref: a clause with both" {
  derive_statement_and_ref
  run --separate-stderr zsh "$S" "$F"
  only_rule statement-and-ref
  contains "$stderr" 'TA-3 has both a statement and a ref'
}

@test "neither-statement-nor-ref: a clause with neither" {
  derive_neither_statement_nor_ref
  run --separate-stderr zsh "$S" "$F"
  only_rule neither-statement-nor-ref
  contains "$stderr" 'TA-1 has neither a statement nor a ref'
}

@test "retired-unnamed: a retired clause no change names" {
  derive_retired_unnamed
  run --separate-stderr zsh "$S" "$F"
  only_rule retired-unnamed
  contains "$stderr" 'TA-2 is retired but no change names it in affects'
}

@test "unresolved-affects: affects names an id the file does not have" {
  derive_unresolved_affects
  run --separate-stderr zsh "$S" "$F"
  only_rule unresolved-affects
  contains "$stderr" 'TC-2026-11-1 affects TA-9, which no clause has'
}

@test "ref-missing: a ref path that is not in the repo" {
  derive_ref_missing
  run --separate-stderr zsh "$S" "$F"
  only_rule ref-missing
  contains "$stderr" 'TA-3: ref path docs/architecture/missing.md: no such file in the repo'
}

@test "ref-missing: a ref path that resolves only through a linked submodule, or lies inside one" {
  mkdir -p "$R/handbook/docs"
  printf '# Team styleguide\n' > "$R/handbook/docs/team-styleguide.md"
  printf '[submodule "handbook"]\n\tpath = handbook\n\turl = https://example.invalid/h.git\n' \
    > "$R/.gitmodules"
  edit_block '.clauses[2].ref.path = "docs/team-styleguide.md"'
  run --separate-stderr zsh "$S" "$F"
  only_rule ref-missing
  contains "$stderr" 'found only in linked:handbook'
  edit_block '.clauses[2].ref.path = "handbook/docs/team-styleguide.md"'
  run --separate-stderr zsh "$S" "$F"
  only_rule ref-missing
  contains "$stderr" 'lies inside a submodule'
}

@test "ref-missing: an absolute ref path, and one that leaves the repo" {
  edit_block '.clauses[2].ref.path = "/etc/hosts"'
  run --separate-stderr zsh "$S" "$F"
  only_rule ref-missing
  contains "$stderr" 'not a repo-relative path'
  : > "$BATS_TEST_TMPDIR/outside.md"
  edit_block '.clauses[2].ref.path = "docs/../../outside.md"'
  run --separate-stderr zsh "$S" "$F"
  only_rule ref-missing
  contains "$stderr" 'leaves the repo'
}

@test "bad-date: a change date that is not a calendar date" {
  derive_bad_date
  run --separate-stderr zsh "$S" "$F"
  only_rule bad-date
  contains "$stderr" 'TC-2026-11-1: date 2026-11-31 is not a calendar date'
}

@test "bad-date: a date outside the month its id names" {
  edit_block '.changes[0].date = "2026-10-30"'
  run --separate-stderr zsh "$S" "$F"
  only_rule bad-date
  contains "$stderr" 'not in the month its id names'
}

@test "bad-date: 29 February holds in a leap year only" {
  edit_block '.changes[0].id = "TC-2028-02-1" | .changes[0].date = "2028-02-29"'
  run --separate-stderr zsh "$S" "$F"
  [ "$status" -eq 0 ]
  edit_block '.changes[0].id = "TC-2027-02-1" | .changes[0].date = "2027-02-29"'
  run --separate-stderr zsh "$S" "$F"
  only_rule bad-date
  contains "$stderr" 'TC-2027-02-1: date 2027-02-29 is not a calendar date'
}

@test "stale-prose: the prose changed and the hash did not" {
  derive_stale_prose
  run --separate-stderr zsh "$S" "$F"
  only_rule stale-prose
  contains "$stderr" 'regenerate the block'
}

@test "stale-prose uses the refine-issue skill's prose hash" {
  local h stored
  h="$(awk '/^<!-- target-architecture:prose:end -->$/ { f = 0 } f
            /^<!-- target-architecture:prose:start -->$/ { f = 1 }' "$F" | zsh "$HASHER")"
  stored="$(awk '/^```json$/ { f = 1; next } f && /^```$/ { exit } f' "$F" | jq -r '.provenance.prose_sha256')"
  [ -n "$h" ]
  [ "$stored" = "$h" ]
  run grep -c 'skills/refine-issue/scripts/story-spec-prose-hash.zsh' "$S"
  [ "$output" -ge 1 ]
}

@test "reports every violation, not only the first" {
  derive_two_violations
  run --separate-stderr zsh "$S" "$F"
  [ "$status" -eq 1 ]
  [ "${#stderr_lines[@]}" -eq 2 ]
  contains "$stderr" 'target-architecture: duplicate-id: '
  contains "$stderr" 'target-architecture: bad-date: '
}

@test "one line per violation: a tab or a newline in a value does not split it" {
  edit_block '.schema = "a\tb"'
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  [ "$stderr" = 'target-architecture: schema: schema is a b, expected "target-architecture/v1"' ]
  edit_block '.schema = "a\nb"'
  run --separate-stderr zsh "$S" "$F"
  only_rule schema
  [ "$stderr" = 'target-architecture: schema: schema is a b, expected "target-architecture/v1"' ]
  edit_block '.schema = "target-architecture/v1" | .clauses[2].ref.path = "docs/architecture/a\nb.md"'
  run --separate-stderr zsh "$S" "$F"
  only_rule ref-missing
  [ "$stderr" = 'target-architecture: ref-missing: TA-3: ref path docs/architecture/a b.md: no such file in the repo' ]
}

@test "CRLF prose hashes the same as LF: a CRLF copy of the valid file is valid" {
  derive_crlf
  run grep -c $'\r$' "$F"
  [ "$output" -gt 0 ]
  run --separate-stderr zsh "$S" "$F"
  [ "$status" -eq 0 ]
  [ "$output" = "target-architecture: valid" ]
}

@test "CRLF does not hide a stale prose" {
  derive_stale_prose
  derive_crlf
  run --separate-stderr zsh "$S" "$F"
  only_rule stale-prose
}

@test "spaces in the repo path and the file's name" {
  local sp="$BATS_TEST_TMPDIR/a repo with spaces"
  build_repo "$sp"
  mv "$sp/docs/architecture/target-architecture.md" "$sp/docs/architecture/the target architecture.md"
  run --separate-stderr zsh "$S" "$sp/docs/architecture/the target architecture.md"
  [ "$status" -eq 0 ]
  [ "$output" = "target-architecture: valid" ]
  F="$sp/docs/architecture/the target architecture.md"
  derive_ref_missing
  run --separate-stderr zsh "$S" "$F"
  only_rule ref-missing
}

@test "mutation check: breaking each rule's branch stops its derived variant reporting that rule" {
  # a copy of the validator in a mirror of the plugin's layout, so its sibling
  # lookup and the refine-issue hasher resolve as they do in the plugin
  local m="$BATS_TEST_TMPDIR/mirror/development" rule fn
  mkdir -p "$m/scripts/reference-docs" "$m/skills/refine-issue/scripts"
  cp "$REPO_ROOT/development/scripts/reference-docs/resolve-product-doc.zsh" "$m/scripts/reference-docs/"
  cp "$HASHER" "$m/skills/refine-issue/scripts/"
  local mutant="$m/scripts/reference-docs/validate-target-architecture.zsh"
  cp "$F" "$BATS_TEST_TMPDIR/valid.md"
  for rule in schema bad-id-shape duplicate-id statement-and-ref neither-statement-nor-ref retired-unnamed \
              unresolved-affects ref-missing bad-date stale-prose; do
    # every emission of <rule> is renamed, so its branch no longer reports it
    RULE="$rule" perl -pe 's/v\("\Q$ENV{RULE}\E";/v("mutated";/g; s/flag \Q$ENV{RULE}\E /flag mutated /g' "$S" > "$mutant"
    run cmp -s "$S" "$mutant"
    [ "$status" -eq 1 ]
    cp "$BATS_TEST_TMPDIR/valid.md" "$F"
    fn="derive_${rule//-/_}"
    "$fn"
    run --separate-stderr zsh "$S" "$F"
    starts_with "$stderr" "target-architecture: $rule: "
    run --separate-stderr zsh "$mutant" "$F"
    lacks "$stderr" "target-architecture: $rule: "
  done
}

@test "usage errors and an unreadable file exit 2" {
  run --separate-stderr zsh "$S"
  [ "$status" -eq 2 ]
  starts_with "$stderr" 'validate-target-architecture.zsh: a target-architecture file is required'
  run --separate-stderr zsh "$S" "$F" "$F"
  [ "$status" -eq 2 ]
  contains "$stderr" 'more than one file given'
  run --separate-stderr zsh "$S" --strict "$F"
  [ "$status" -eq 2 ]
  contains "$stderr" 'unknown flag: --strict'
  run --separate-stderr zsh "$S" "$R/docs/architecture/no-such-file.md"
  [ "$status" -eq 2 ]
  contains "$stderr" 'cannot read:'
}

@test "--help prints the usage on stdout and exits 0" {
  run --separate-stderr zsh "$S" --help
  [ "$status" -eq 0 ]
  [ "$output" = "usage: validate-target-architecture.zsh <target-architecture.md>" ]
}
