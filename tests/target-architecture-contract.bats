#!/usr/bin/env bats
#
# The target architecture contract (#3353, a child of #3198): pins the
# load-bearing sentences of ARCHITECTURE.md's *Target architecture contract
# (`target-architecture/v1`)*, scoped to that section so a clause stated
# elsewhere in the document cannot satisfy a needle, and checks that the
# section and the validator name the same rules.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GITHUB_ACTIONS
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  S="$REPO_ROOT/development/scripts/reference-docs/validate-target-architecture.zsh"
  # from the section's own heading to the next `## ` or `### ` heading, fences skipped
  RAW="$(awk '/^```/ { fence = !fence }
              !fence && /^### Target architecture contract \(`target-architecture\/v1`\)$/ { f = 1; print; next }
              f && !fence && /^##+ / { exit } f' "$ARCH")"
  SECTION="$(printf '%s' "$RAW" | tr -s '[:space:]' ' ')"
}

@test "the section exists and comes right after Linked reference documents" {
  [ -n "$SECTION" ]
  local next
  next="$(awk '/^```/ { fence = !fence; next } fence { next }
               /^### Linked reference documents$/ { f = 1; next } f && /^##+ / { print; exit }' "$ARCH")"
  [ "$next" = '### Target architecture contract (`target-architecture/v1`)' ]
}

@test "the contract fixes the file path, found by the lookup, and the layout" {
  contains "$SECTION" 'It lives at `docs/architecture/target-architecture.md`, found by the lookup above'
  contains "$SECTION" 'sits between `<!-- target-architecture:prose:start -->` and `<!-- target-architecture:prose:end -->`'
  contains "$SECTION" 'It is followed by a collapsed `<details>` block holding one fenced `json` object'
}

@test "the contract reads one entry file only, and nothing is rewritten" {
  contains "$SECTION" '**This one entry file is the only layout the contract reads.** An existing target architecture or an API styleguide is made citeable through `ref` clauses that point at its existing pages. Nothing is rewritten, and the contract reads no other existing layout.'
}

@test "a clause is never deleted, and an id is never reused or renumbered" {
  contains "$SECTION" '**A clause is never deleted.** A clause that no longer holds becomes `retired`, and a change records its retirement by naming it in `affects`.'
  contains "$SECTION" '**An id is unique in the file, and never reused or renumbered.**'
}

@test "the contract states the validator's single-file limit" {
  contains "$SECTION" '**The validator checks a single file, so it cannot see an active clause reworded in place, a clause deleted, an id renumbered or reused, or a retired clause named only by the change that introduced it.**'
  contains "$SECTION" 'Catching those means comparing the file with its earlier versions'
  contains "$SECTION" "whoever changes a clause's meaning adds a change, and the human who approves the PR reads the diff for every one of them."
}

@test "the rule bullets on affects and ref paths are stated" {
  contains "$SECTION" 'Every id in `affects` names a clause of the file.'
  contains "$SECTION" 'A `ref` path is a file of the target architecture'"'"'s own repository. A path found only in a linked submodule does not count. The `ref` anchor is not checked.'
}

@test "the validator's exit codes and repo root are stated" {
  contains "$SECTION" '`validate-target-architecture.zsh <file>` checks one file. It exits 0 on a valid file, printing `target-architecture: valid`, and 1 on an invalid one, with one stderr line `target-architecture: <rule>: <detail>` for every violation, not only the first.'
  contains "$SECTION" 'It exits 2 on a usage error or an unreadable file; a missing `jq` and a lookup that fails internally exit 2 too, since neither is a verdict on the file.'
  contains "$SECTION" 'The repo is the git work tree holding the file, or the current directory outside git.'
}

@test "provenance is the persona contract's mechanism, given as a link and not restated" {
  contains "$SECTION" "Provenance is the persona contract's mechanism, unchanged"
  contains "$SECTION" '[Provenance and staleness detection](#provenance-and-staleness-detection)'
  run grep -c '^### Provenance and staleness detection$' "$ARCH"
  [ "$output" = "1" ]
  lacks "$SECTION" 'strip trailing whitespace'
  lacks "$SECTION" 'line endings to'
}

@test "the clause and change shapes are stated" {
  contains "$SECTION" '**A clause** has `id` (`TA-<n>`), `area`'
  contains "$SECTION" 'exactly one of `statement` (a string) or `ref` (`{ "path", "anchor", "title" }`: a page of the file'"'"'s own repository'
  contains "$SECTION" '**A change** has `id` (`TC-<yyyy>-<mm>-<n>`, the year and month of its `date`), `date`'
  contains "$SECTION" '`status` (`active` or `retired`) and exactly one'
  contains "$SECTION" '`date` (an ISO calendar date, `YYYY-MM-DD`), `from`, `to` and `rationale` (each a non-empty string; a change that introduces a clause says in `from` that nothing held before), `affects[]` (the ids of the clauses it introduced, changed or retired) and `evidence[]` (issue or PR references; may be empty).'
}

@test "the contract's rule table names exactly the validator's rules" {
  local doc script
  doc="$(printf '%s\n' "$RAW" | sed -n '/^| Rule | A violation |$/,/^$/p' | sed -n 's/^| `\([a-z-]*\)` | .*/\1/p' | sort)"
  script="$(sed -n '/^# where <rule> is one of/,/^#$/p' "$S" | tr -d '#,.' | tr -s '[:space:]' '\n' \
    | grep -E '^[a-z]+(-[a-z]+)*$' | grep -vx -e where -e rule -e is -e one -e of | sort)"
  [ "$(printf '%s\n' "$doc" | wc -l | tr -d ' ')" -eq 10 ]
  [ "$doc" = "$script" ]
}

@test "the example has three clauses, one a ref, and one change retiring a clause" {
  local block="$BATS_TEST_TMPDIR/example.json"
  printf '%s\n' "$RAW" | awk '/^```json$/ { f = 1; next } f && /^```$/ { exit } f' > "$block"
  run jq -r '[.schema, (.clauses | length), ([.clauses[] | select(has("ref"))] | length), (.changes | length)] | @tsv' "$block"
  [ "$output" = $'target-architecture/v1\t3\t1\t1' ]
  run jq -r '([.clauses[] | select(.status == "retired") | .id] | length), ([.clauses[] | select(.status == "retired") | .id] - .changes[0].affects | length)' "$block"
  [ "$output" = $'1\n0' ]
  contains "$SECTION" 'TA-3 shows how a page such as an API styleguide becomes citeable: it is a `ref` clause'
}
