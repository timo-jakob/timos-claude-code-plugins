#!/usr/bin/env bats
#
# User-facing C4 documentation (issue #797, epic #746). Four Diátaxis pages
# document the C4 machinery AS BUILT. mkdocs build --strict (the docs CI gate)
# already proves the pages exist, are nav-registered, and their links resolve —
# so these tests assert the content-level acceptance criteria the strict build
# can't see: the machinery is described correctly (working-tree detection, NOT the
# `elevated` risk gate; development-docs owns c4_drift; the inconclusive rule),
# the placeholder claims this story owns are retired, and no page overclaims that
# the strict build validates diagram content.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DOCS="$REPO_ROOT/docs"
  ADOPT="$DOCS/how-to/adopt-c4-architecture-docs.md"
  AMEND="$DOCS/how-to/amend-a-c4-diagram.md"
  EXPLAIN="$DOCS/explanation/c4-architecture-docs.md"
  DRIFT="$DOCS/reference/c4-drift-findings.md"
}

# A negative grep assertion that ACTUALLY fails the test on a match. A bare
# `! grep ...` on a non-last line does NOT: bats runs with errexit, and POSIX
# exempts a pipeline beginning with `!` from errexit, so a non-last `! grep`
# that matches is a silent no-op. This helper returns non-zero on a match, which
# errexit catches wherever it is called.
refute_grep() {  # refute_grep <grep args...> ; fails if grep matches
  if grep "$@"; then return 1; fi
  return 0
}
refute_flat() {  # refute_flat <ERE> <file> ; newline-collapsed; fails on match
  if tr '\n' ' ' < "$2" | grep -Eqi "$1"; then return 1; fi
  return 0
}

@test "the four Diátaxis pages exist in the named quadrants (#797)" {
  [ -f "$ADOPT" ]
  [ -f "$AMEND" ]
  [ -f "$EXPLAIN" ]
  [ -f "$DRIFT" ]
}

@test "all four pages are registered in the mkdocs nav (#797)" {
  local nav="$REPO_ROOT/mkdocs.yml"
  grep -Fq 'how-to/adopt-c4-architecture-docs.md' "$nav"
  grep -Fq 'how-to/amend-a-c4-diagram.md' "$nav"
  grep -Fq 'explanation/c4-architecture-docs.md' "$nav"
  grep -Fq 'reference/c4-drift-findings.md' "$nav"
}

@test "all four pages are linked from the docs MOC (#797)" {
  local moc="$DOCS/index.md"
  grep -Fq 'how-to/adopt-c4-architecture-docs.md' "$moc"
  grep -Fq 'how-to/amend-a-c4-diagram.md' "$moc"
  grep -Fq 'explanation/c4-architecture-docs.md' "$moc"
  grep -Fq 'reference/c4-drift-findings.md' "$moc"
}

@test "the same-PR how-to states the working-tree-detection trigger (#797)" {
  # anchor to the trigger framing, not a bare token that could appear in an aside
  grep -Eqi 'trigger.*working-tree|working-tree.*(structural|detect)' "$AMEND"
}

@test "the string 'elevated' never appears as the trigger in the new pages (#797)" {
  # #792's trigger is working-tree structural detection, NOT the elevated risk
  # gate; documenting it as `elevated` would be wrong-as-built
  refute_grep -Fqi 'elevated' "$ADOPT"
  refute_grep -Fqi 'elevated' "$AMEND"
  refute_grep -Fqi 'elevated' "$EXPLAIN"
  refute_grep -Fqi 'elevated' "$DRIFT"
}

@test "the c4_drift reference names development-docs as the owning plugin (#797)" {
  # tie the token to OWNERSHIP — the token also appears in the unrelated dispatcher
  # sentence, so a bare match wouldn't pin the acceptance criterion
  grep -Eqi 'owned by (the )?[^.]*development-docs' "$DRIFT"
}

@test "the adopt how-to documents the inconclusive verdict and the fill-gaps-by-hand rule (#797)" {
  grep -Fqi 'inconclusive' "$ADOPT"
  grep -Fqi 'by hand' "$ADOPT"
}

@test "the explanation states the level policy and the Mermaid validation cost (#797)" {
  # level policy: Context + Container required, Code never — anchored, not the
  # ubiquitous substring 'code' (matches 'codebase', 'the code')
  grep -Fqi 'Context' "$EXPLAIN"
  grep -Fqi 'Container' "$EXPLAIN"
  grep -Eqi 'required' "$EXPLAIN"
  grep -Eqi 'never .*Code|Code .*never' "$EXPLAIN"
  # the honest cost: the strict build does not validate the diagram body
  grep -Fqi 'client-side' "$EXPLAIN"
}

@test "no new page claims the strict build validates diagram content (#797)" {
  # the AC forbids overclaiming; the pages say the OPPOSITE (build can't parse the
  # body). The negative statement wraps across lines, so collapse newlines before
  # matching the concept
  local explain_flat
  explain_flat="$(tr '\n' ' ' < "$EXPLAIN")"
  echo "$explain_flat" | grep -Eqi 'never parses the diagram|cannot tell you the Mermaid|does not (and cannot )?.*validate'
  # and no page makes the false claim: the build "validates" the mermaid/diagram.
  # Keyed on the finite affirmative conjugation "validates" (and "is validated"),
  # NOT the base verb — so it matches the overclaim ("the build validates the
  # diagram") but never the honest disclaimers ("does not validate the Mermaid
  # diagram body", "the Mermaid is valid", "never parses the diagram body").
  local bad='validates (the )?(mermaid|diagram)|(mermaid|diagram) [a-z]*is validated'
  refute_flat "$bad" "$ADOPT"
  refute_flat "$bad" "$AMEND"
  refute_flat "$bad" "$EXPLAIN"
}

@test "the two placeholder claims this story owns are retired, with replacement (#797)" {
  local guide="$DOCS/how-to/authoring-guide.md" stack="$DOCS/explanation/target-repo-docs-stack.md"
  # context-scoped: no LINE ties architecture to "placeholder" (grep is
  # line-oriented, so a future unrelated use of the word elsewhere in the file
  # must not false-fail this)
  refute_grep -Eqi 'architecture.*placeholder|placeholder.*architecture' "$guide"
  refute_grep -Eqi 'architecture.*placeholder|placeholder.*architecture' "$stack"
  # retirement-with-replacement: the pages now describe the diagrams as maintained
  # ('kept true' — the shared replacement marker; kept short so a line wrap in the
  # prose can't split the match)
  grep -Fqi 'kept true' "$guide"
  grep -Fqi 'kept true' "$stack"
}

@test "all four new pages cross-link the ARCHITECTURE.md contract as an absolute URL (#797)" {
  # one source of truth: link the contract, don't restate its normative rules
  local url='https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md'
  grep -Fq "$url" "$ADOPT"
  grep -Fq "$url" "$AMEND"
  grep -Fq "$url" "$EXPLAIN"
  grep -Fq "$url" "$DRIFT"
}
