#!/usr/bin/env bats
#
# The charter validator (#3205, task 4 of #3195):
# product/scripts/validate-charter.zsh checks one charter against `charter/v1`
# (ARCHITECTURE.md, *Product charter contract*) and reports every violation as
# `charter: <rule>: <detail>`.
#
# Three invented fixtures are committed under tests/fixtures/product-charter/:
# a valid charter, the persona registry it serves, and the repo-local page its
# ref and appendices point at. setup() copies them into a throwaway git repo,
# and each violating charter is derived from the valid one by a helper named
# after its rule (`derive_<rule>`), so no violating file is committed.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  # a git hook or `rebase --exec` exports these, and `git -C` does not override
  # them: the throwaway repo's init would land in the real repository
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/product/scripts/validate-charter.zsh"
  FIX="$REPO_ROOT/tests/fixtures/product-charter"
  R="$BATS_TEST_TMPDIR/repo"
  build_repo "$R"
  C="$R/docs/product/charter.md"
}

# build_repo <dir> — a git repo holding the three fixtures where a target repo
# keeps them
build_repo() {
  mkdir -p "$1/docs/product"
  cp "$FIX/charter.md" "$1/docs/product/charter.md"
  cp "$FIX/personas.md" "$FIX/principles.md" "$1/docs/"
  git -C "$1" init -q
}

# edit_block <jq-filter> — rewrite the charter's json block through jq, leaving
# the prose (and so its hash) untouched
edit_block() {
  local block="$BATS_TEST_TMPDIR/block.json" out="$BATS_TEST_TMPDIR/charter.out"
  awk '/^```json$/ { f = 1; next } f && /^```$/ { exit } f' "$C" | jq "$1" > "$block"
  awk -v bf="$block" '
    /^```json$/ && !done { print; while ((getline l < bf) > 0) print l; skip = 1; done = 1; next }
    skip && /^```$/ { skip = 0 }
    !skip' "$C" > "$out"
  mv "$out" "$C"
}

# One helper per rule, each breaking exactly that rule.
derive_schema()                    { edit_block '.schema = "charter/v2"'; }
derive_bad_id_shape()              { edit_block '.scope[1].id = "S-02"'; }
derive_duplicate_id()              { edit_block '.scope[1].id = "S-1"'; }
derive_statement_and_ref()         { edit_block '.values[0].statement = "Calm by default."'; }
derive_neither_statement_nor_ref() { edit_block '.values[1] |= del(.statement)'; }
derive_retired_unnamed()           { edit_block '.direction_changes[0].affects = ["NG-2"]'; }
derive_unresolved_affects()        { edit_block '.direction_changes[0].affects += ["V-9"]'; }
derive_unresolved_serves()         { edit_block '.serves += ["kofi-archivist"]'; }
derive_ref_missing()               { edit_block '.values[0].ref.path = "docs/missing.md"'; }
derive_appendix_missing()          { edit_block '.appendices = ["docs/appendix-gone.md"]'; }
derive_bad_date()                  { edit_block '.direction_changes[0].date = "2026-11-31"'; }
# the prose changes and the stored hash does not
derive_stale_prose() {
  sed 's/^- \*\*S-2\*\* Sync to a laptop reader\.$/- **S-2** Sync to any laptop reader./' "$C" > "$C.new"
  if cmp -s "$C" "$C.new"; then
    echo "derive_stale_prose: sed left the charter unchanged" >&2
    return 1
  fi
  mv "$C.new" "$C"
}
derive_two_violations() { derive_duplicate_id; derive_bad_date; }
derive_crlf()           { sed 's/$/\r/' "$C" > "$C.new"; mv "$C.new" "$C"; }

# only_rule <rule> — the last run exited 1 with exactly one stderr line, for <rule>
only_rule() {
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  starts_with "$stderr" "charter: $1: "
}

@test "the valid charter passes" {
  run --separate-stderr zsh "$S" "$C"
  [ "$status" -eq 0 ]
  [ "$output" = "charter: valid" ]
  [ -z "$stderr" ]
}

@test "schema: a block whose schema is not charter/v1" {
  derive_schema
  run --separate-stderr zsh "$S" "$C"
  only_rule schema
  contains "$stderr" 'schema is charter/v2, expected "charter/v1"'
}

@test "schema: prose sections out of the contract's order" {
  awk '/^## Values$/ { print "## What we build"; next } /^## What we build$/ { print "## Values"; next } 1' \
    "$C" > "$C.new"
  mv "$C.new" "$C"
  # re-hash the reordered prose, so only the order is wrong
  local h
  h="$(awk '/^<!-- charter:prose:end -->$/ { f = 0 } f; /^<!-- charter:prose:start -->$/ { f = 1 }' "$C" \
    | zsh "$REPO_ROOT/product/scripts/prose-hash.zsh")"
  edit_block ".provenance.prose_sha256 = \"$h\""
  run --separate-stderr zsh "$S" "$C"
  only_rule schema
  contains "$stderr" 'prose sections are'
}

@test "schema: no prose sentinels, a duplicated one, or swapped ones" {
  cp "$C" "$BATS_TEST_TMPDIR/valid.md"
  grep -v '^<!-- charter:prose:' "$C" > "$C.new"
  mv "$C.new" "$C"
  run --separate-stderr zsh "$S" "$C"
  only_rule schema
  awk '{ print } /^<!-- charter:prose:start -->$/ { print }' "$BATS_TEST_TMPDIR/valid.md" > "$C"
  run --separate-stderr zsh "$S" "$C"
  only_rule schema
  contains "$stderr" 'found 2 and 1'
  awk '/^<!-- charter:prose:start -->$/ { print "<!-- charter:prose:end -->"; next }
       /^<!-- charter:prose:end -->$/ { print "<!-- charter:prose:start -->"; next } 1' \
    "$BATS_TEST_TMPDIR/valid.md" > "$C"
  run --separate-stderr zsh "$S" "$C"
  only_rule schema
  contains "$stderr" 'comes before'
}

@test "schema: an empty json block" {
  awk '/^```json$/ { print; f = 1; next } f && /^```$/ { f = 0 } !f' "$C" > "$C.new"
  mv "$C.new" "$C"
  run --separate-stderr zsh "$S" "$C"
  only_rule schema
  contains "$stderr" 'the json block is not one valid JSON object'
}

@test "schema: no fenced json block after the prose" {
  awk '/^```json$/ { f = 1; next } f && /^```$/ { f = 0; next } !f' "$C" > "$C.new"
  mv "$C.new" "$C"
  run --separate-stderr zsh "$S" "$C"
  only_rule schema
  contains "$stderr" 'no fenced json block follows the prose'
}

@test "schema: a json block that is not valid JSON" {
  awk '/^```json$/ { print; print "{ not json"; f = 1; next } f && /^```$/ { f = 0 } !f' "$C" > "$C.new"
  mv "$C.new" "$C"
  run --separate-stderr zsh "$S" "$C"
  only_rule schema
  contains "$stderr" 'the json block is not one valid JSON object'
}

@test "schema: provenance with no prose_sha256" {
  edit_block 'del(.provenance.prose_sha256)'
  run --separate-stderr zsh "$S" "$C"
  only_rule schema
  contains "$stderr" 'prose_sha256 is not 64 lowercase hex digits'
}

@test "schema: a non-goal statement with no rationale" {
  edit_block '.non_goals[1] |= del(.rationale)'
  run --separate-stderr zsh "$S" "$C"
  only_rule schema
  contains "$stderr" 'NG-2: a non-goal with a statement needs a rationale'
}

@test "bad-id-shape: an id that is not <prefix>-<n>" {
  derive_bad_id_shape
  run --separate-stderr zsh "$S" "$C"
  only_rule bad-id-shape
  contains "$stderr" 'S-02'
}

@test "bad-id-shape: a direction change id that is not DC-<yyyy>-<mm>-<n>" {
  edit_block '.direction_changes[0].id = "DC-26-11-1"'
  run --separate-stderr zsh "$S" "$C"
  only_rule bad-id-shape
  contains "$stderr" 'DC-26-11-1 does not match DC-<yyyy>-<mm>-<n>'
}

@test "duplicate-id: one id on two entries" {
  derive_duplicate_id
  run --separate-stderr zsh "$S" "$C"
  only_rule duplicate-id
  contains "$stderr" 'S-1 is used 2 times'
}

@test "statement-and-ref: an entry with both" {
  derive_statement_and_ref
  run --separate-stderr zsh "$S" "$C"
  only_rule statement-and-ref
  contains "$stderr" 'V-1'
}

@test "neither-statement-nor-ref: an entry with neither" {
  derive_neither_statement_nor_ref
  run --separate-stderr zsh "$S" "$C"
  only_rule neither-statement-nor-ref
  contains "$stderr" 'V-2'
}

@test "retired-unnamed: a retired entry no direction change names" {
  derive_retired_unnamed
  run --separate-stderr zsh "$S" "$C"
  only_rule retired-unnamed
  contains "$stderr" 'NG-1 is retired'
}

@test "unresolved-affects: affects names an id the charter does not have" {
  derive_unresolved_affects
  run --separate-stderr zsh "$S" "$C"
  only_rule unresolved-affects
  contains "$stderr" 'DC-2026-11-1 affects V-9, which no value'
}

@test "unresolved-serves: serves names an id the persona registry does not have" {
  derive_unresolved_serves
  run --separate-stderr zsh "$S" "$C"
  only_rule unresolved-serves
  contains "$stderr" 'kofi-archivist is not a persona id in the registry'
}

@test "unresolved-serves: no persona registry anywhere, and serves is not empty" {
  rm "$R/docs/personas.md"
  run --separate-stderr zsh "$S" "$C"
  only_rule unresolved-serves
  contains "$stderr" 'priya-commuter: no persona registry'
}

@test "with no persona registry anywhere, an empty serves is valid" {
  rm "$R/docs/personas.md"
  edit_block '.serves = []'
  run --separate-stderr zsh "$S" "$C"
  [ "$status" -eq 0 ]
  [ "$output" = "charter: valid" ]
}

@test "a persona registry in a linked submodule resolves serves" {
  mkdir -p "$R/product-docs/docs"
  mv "$R/docs/personas.md" "$R/product-docs/docs/personas.md"
  printf '[submodule "product-docs"]\n\tpath = product-docs\n\turl = https://example.invalid/d.git\n' \
    > "$R/.gitmodules"
  run --separate-stderr zsh "$S" "$C"
  [ "$status" -eq 0 ]
  [ "$output" = "charter: valid" ]
}

@test "an uninitialised submodule before the persona registry exits 2, not unresolved-serves" {
  rm "$R/docs/personas.md"
  mkdir -p "$R/product-docs"
  printf '[submodule "product-docs"]\n\tpath = product-docs\n\turl = https://example.invalid/d.git\n' \
    > "$R/.gitmodules"
  run --separate-stderr zsh "$S" "$C"
  [ "$status" -eq 2 ]
  contains "$stderr" 'a declared submodule is not initialised'
}

@test "ref-missing: a ref path that is not in the repo" {
  derive_ref_missing
  run --separate-stderr zsh "$S" "$C"
  only_rule ref-missing
  contains "$stderr" 'V-1: ref path docs/missing.md: no such file in the repo'
}

@test "ref-missing: a ref path that resolves only through a linked submodule" {
  mkdir -p "$R/handbook/docs"
  printf '# Team principles\n' > "$R/handbook/docs/team-principles.md"
  printf '[submodule "handbook"]\n\tpath = handbook\n\turl = https://example.invalid/h.git\n' \
    > "$R/.gitmodules"
  edit_block '.values[0].ref.path = "docs/team-principles.md"'
  run --separate-stderr zsh "$S" "$C"
  only_rule ref-missing
  contains "$stderr" 'found only in linked:handbook'
  edit_block '.values[0].ref.path = "handbook/docs/team-principles.md"'
  run --separate-stderr zsh "$S" "$C"
  only_rule ref-missing
  contains "$stderr" 'lies inside a submodule'
}

@test "ref-missing: an absolute ref path, and one that leaves the repo" {
  edit_block '.values[0].ref.path = "/etc/hosts"'
  run --separate-stderr zsh "$S" "$C"
  only_rule ref-missing
  contains "$stderr" 'not a repo-relative path'
  edit_block '.values[0].ref.path = "docs/../../outside.md"'
  : > "$BATS_TEST_TMPDIR/outside.md"
  run --separate-stderr zsh "$S" "$C"
  only_rule ref-missing
  contains "$stderr" 'leaves the repo'
}

@test "appendix-missing: an appendix that is not in the repo" {
  derive_appendix_missing
  run --separate-stderr zsh "$S" "$C"
  only_rule appendix-missing
  contains "$stderr" 'docs/appendix-gone.md'
}

@test "bad-date: a direction change date that is not a calendar date" {
  derive_bad_date
  run --separate-stderr zsh "$S" "$C"
  only_rule bad-date
  contains "$stderr" '2026-11-31'
}

@test "bad-date: a date outside the month its id names" {
  edit_block '.direction_changes[0].date = "2026-10-30"'
  run --separate-stderr zsh "$S" "$C"
  only_rule bad-date
  contains "$stderr" 'not in the month its id names'
}

@test "bad-date: 29 February holds in a leap year only" {
  edit_block '.direction_changes[0].id = "DC-2028-02-1" | .direction_changes[0].date = "2028-02-29"'
  run --separate-stderr zsh "$S" "$C"
  [ "$status" -eq 0 ]
  edit_block '.direction_changes[0].id = "DC-2027-02-1" | .direction_changes[0].date = "2027-02-29"'
  run --separate-stderr zsh "$S" "$C"
  only_rule bad-date
  contains "$stderr" 'DC-2027-02-1: date 2027-02-29 is not a calendar date'
}

@test "stale-prose: the prose changed and the hash did not" {
  derive_stale_prose
  run --separate-stderr zsh "$S" "$C"
  only_rule stale-prose
  contains "$stderr" 'regenerate the block'
}

@test "reports every violation, not only the first" {
  derive_two_violations
  run --separate-stderr zsh "$S" "$C"
  [ "$status" -eq 1 ]
  [ "${#stderr_lines[@]}" -eq 2 ]
  contains "$stderr" 'charter: duplicate-id: '
  contains "$stderr" 'charter: bad-date: '
}

@test "CRLF prose hashes the same as LF: a CRLF copy of the valid charter is valid" {
  derive_crlf
  run grep -c $'\r$' "$C"
  [ "$output" -gt 0 ]
  run --separate-stderr zsh "$S" "$C"
  [ "$status" -eq 0 ]
  [ "$output" = "charter: valid" ]
}

@test "CRLF does not hide a stale prose" {
  derive_stale_prose
  derive_crlf
  run --separate-stderr zsh "$S" "$C"
  only_rule stale-prose
}

@test "spaces in the repo path and the charter's name" {
  local sp="$BATS_TEST_TMPDIR/a repo with spaces"
  build_repo "$sp"
  mv "$sp/docs/product/charter.md" "$sp/docs/product/the charter.md"
  run --separate-stderr zsh "$S" "$sp/docs/product/the charter.md"
  [ "$status" -eq 0 ]
  [ "$output" = "charter: valid" ]
  C="$sp/docs/product/the charter.md"
  derive_ref_missing
  run --separate-stderr zsh "$S" "$C"
  only_rule ref-missing
}

@test "usage errors and an unreadable file exit 2" {
  run --separate-stderr zsh "$S"
  [ "$status" -eq 2 ]
  starts_with "$stderr" 'validate-charter.zsh: a charter file is required'
  run --separate-stderr zsh "$S" "$C" "$C"
  [ "$status" -eq 2 ]
  contains "$stderr" 'more than one charter given'
  run --separate-stderr zsh "$S" --strict "$C"
  [ "$status" -eq 2 ]
  contains "$stderr" 'unknown flag: --strict'
  run --separate-stderr zsh "$S" "$R/docs/product/no-such-charter.md"
  [ "$status" -eq 2 ]
  contains "$stderr" 'cannot read:'
}

@test "--help prints the usage on stdout and exits 0" {
  run --separate-stderr zsh "$S" --help
  [ "$status" -eq 0 ]
  [ "$output" = "usage: validate-charter.zsh <charter.md>" ]
}
