#!/usr/bin/env bats
#
# The user-facing telemetry docs (#1009, epic #740 child (g)).
#
# WHY A TEST FOR PROSE: this story's acceptance criteria are mostly statements
# the docs must make and links they must carry, and `mkdocs build --strict`
# checks neither — it catches an omitted nav entry and a broken link, but not a
# page that quietly stops saying telemetry is git-ignored, nor a MOC entry that
# is dropped while the nav keeps building fine. The sibling telemetry suites set
# the same precedent (tests/telemetry-rollup.bats pins the #1007 how-to's
# registration in all three places; tests/telemetry-grafana-dashboard.bats does
# it for both #1008 pages), so the registration checks here are the third
# instance of an established pattern, not a new one.
#
# Scope: the CLAIMS this story owns. The rollup's own behaviour is
# tests/telemetry-rollup.bats's, and the telemetry/v1 contract is
# tests/telemetry-validate.bats's — neither is re-asserted here.

bats_require_minimum_version 1.5.0

load assertions

# The remedy assertion, in ONE place. The guard below and the self-regression
# test both call it, so weakening the needle reddens the mutation test too —
# which a second, private copy of the needles could not do.
#
# Both statuses are returned (no `&&` join), so neither half can be swallowed.
assert_remedy_names_the_entry() {
  contains "$1" 'add `.claude/telemetry/` to your `.gitignore`' || return 1
  lacks "$1" 'add `.claude/` to your `.gitignore`'
}

# A page flattened to one line, so a needle cannot be defeated by a line wrap.
flattened_page() {
  tr -s '[:space:]' ' ' < "$1"
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  EXPLAIN="$REPO_ROOT/docs/explanation/pipeline-telemetry.md"
  HOWTO="$REPO_ROOT/docs/how-to/read-pipeline-telemetry.md"
  REVIEW_LOOP="$REPO_ROOT/docs/explanation/review-loop.md"
  REFINE="$REPO_ROOT/development/skills/refine-issue/docs/END-TO-END-WALKTHROUGH.md"
}

# ------------------------------------------------------------ registration (AC5)

@test "the explanation page is registered in the nav, the MOC and its section index" {
  # All three, because the strict build only catches the nav omission — the MOC
  # and section-index entries can be dropped with the site still building.
  run grep -qF 'explanation/pipeline-telemetry.md' "$REPO_ROOT/mkdocs.yml"
  [ "$status" -eq 0 ]
  run grep -qF 'explanation/pipeline-telemetry.md' "$REPO_ROOT/docs/index.md"
  [ "$status" -eq 0 ]
  # parenthesised for the same reason as the cross-link test below: a bare
  # `pipeline-telemetry.md` would also match a see-also link to the how-to
  run grep -qF '(pipeline-telemetry.md)' "$REPO_ROOT/docs/explanation/index.md"
  [ "$status" -eq 0 ]
}

# ----------------------------------------------------- what is / isn't collected (AC2)

@test "the docs state the sink is local and git-ignored" {
  # BOTH pages, because both make the claim and the how-to is the one a reader
  # lands on first. Pinning only the explanation would let the how-to's whole
  # "What's collected" list be deleted with the suite green.
  local page
  for page in "$EXPLAIN" "$HOWTO"; do
    run grep -qF '.claude/telemetry/telemetry.jsonl' "$page"
    [ "$status" -eq 0 ]
    run grep -qF 'git-ignored' "$page"
    [ "$status" -eq 0 ]
  done
}

@test "the git-ignored claim is qualified by the mechanism that provides it" {
  # It is an ignore ENTRY bootstrap installs, not a property of the path — in a
  # repo adopted without bootstrap the guarantee is simply false, and a reader
  # trusting it unqualified could push a sink into a public PR.
  # Asserted on BOTH pages: the how-to restates the guarantee, so it owes the
  # same qualification — a reader there could otherwise push a sink into a PR.
  local page
  for page in "$EXPLAIN" "$HOWTO"; do
    run grep -qF 'bootstrap' "$page"
    [ "$status" -eq 0 ]
    run grep -qF '.gitignore' "$page"
    [ "$status" -eq 0 ]
    # The remedy must name the entry bootstrap ACTUALLY installs. Advising
    # `.claude/` instead would untrack files meant to be committed — notably
    # .claude/approver-policy.md, which the Approver agents hard-fail without.
    #
    # Asserted on a WHITESPACE-NORMALISED haystack, and against the remedy
    # SENTENCE rather than the bare path. Both matter: the path
    # `.claude/telemetry/` also occurs in the sink mention an earlier test
    # already pins, so a bare-path check is tautological; and the sentence wraps
    # mid-phrase on the explanation page, so a line-anchored needle is inert
    # there. The first version of this guard had both defects and did not fail
    # when the remedy was broken.
    assert_remedy_names_the_entry "$(flattened_page "$page")"
  done
}

@test "the git-ignore remedy guard actually reds when the remedy is broken" {
  # The guard above is the only thing standing between a reader and advice that
  # untracks .claude/approver-policy.md, and its first version was inert. Prove
  # it has teeth against the exact regression it exists for.
  local page fixture
  for page in "$EXPLAIN" "$HOWTO"; do
    fixture="$BATS_TEST_TMPDIR/broken-$(basename "$page")"
    sed 's|`\.claude/telemetry/` to your|`.claude/` to your|' "$page" > "$fixture"
    run diff -q "$page" "$fixture"
    [ "$status" -ne 0 ]
    # Run the GUARD against the broken page and require it to report a
    # mismatch — pinned to 1, not merely non-zero, so an assertion-helper misuse
    # status of 2 cannot masquerade as a caught regression.
    run assert_remedy_names_the_entry "$(flattened_page "$fixture")"
    [ "$status" -eq 1 ]

    # The other regression the guard owes: the remedy sentence DELETED outright.
    # The negative half alone would pass on that (nothing advises `.claude/`), so
    # this fixture is what keeps the positive half load-bearing.
    fixture="$BATS_TEST_TMPDIR/dropped-$(basename "$page")"
    # A single-TOKEN substitution: the surrounding phrase wraps mid-sentence on
    # the explanation page, so anything longer cannot match line-oriented sed.
    sed 's|`\.claude/telemetry/`|`REMOVED`|' "$page" > "$fixture"
    run diff -q "$page" "$fixture"
    [ "$status" -ne 0 ]
    run assert_remedy_names_the_entry "$(flattened_page "$fixture")"
    [ "$status" -eq 1 ]

    # And the third shape, which keeps the correct sentence but ADDS the harmful
    # advice elsewhere on the page — the only regression the negative half
    # catches on its own.
    fixture="$BATS_TEST_TMPDIR/extra-$(basename "$page")"
    cp "$page" "$fixture"
    printf '\nJust add `.claude/` to your `.gitignore` and be done with it.\n' >> "$fixture"
    run assert_remedy_names_the_entry "$(flattened_page "$fixture")"
    [ "$status" -eq 1 ]
  done
}

@test "the docs state there is no network egress" {
  run cat "$EXPLAIN"
  [ "$status" -eq 0 ]
  contains "$output" "No network egress"
  # one line-break-tolerant assertion rather than a generic "nothing in the"
  # fragment, which ordinary prose elsewhere on the page could satisfy
  matches "$output" '.*nothing in the[[:space:]]+emitter speaks a network protocol.*'
  # the how-to restates it, and is unguarded otherwise
  run grep -qF 'no network transport in the emitter' "$HOWTO"
  [ "$status" -eq 0 ]
}

@test "the docs state tokens is deliberately unmeasured, never estimated" {
  local page
  for page in "$EXPLAIN" "$HOWTO"; do
    run grep -qF 'never estimated' "$page"
    [ "$status" -eq 0 ]
  done
}

@test "the docs say the stream undercounts rather than guesses" {
  # The honest consequence of a lossy-by-design stream; without it a reader
  # treats the sink as an audit log.
  run cat "$EXPLAIN"
  [ "$status" -eq 0 ]
  contains "$output" "undercounts"
  contains "$output" "never means a run did not happen"
}

# --------------------------------------------------------- shared-dir mode (AC3)

@test "the how-to documents the shared-directory mode and links the hand-off contract" {
  run cat "$HOWTO"
  [ "$status" -eq 0 ]
  contains "$output" "--telemetry-dir"
  contains "$output" "telemetry-grafana-handoff.md"
}

@test "the shared-directory example does not mint a record attributed to a real pipeline" {
  # An `--pipeline review-loop` example appends a record indistinguishable from a
  # genuine run into an append-only sink a reporting stack reads, inflating
  # run_count and diluting escalation_rate for good — and flatly contradicting
  # the same page's "withheld, never guessed" rule.
  local block
  # flag idiom, not a range: `/^## [^S]/` would run to EOF the moment a section
  # starting with S (e.g. "## See also") followed this one, silently widening
  # the haystack the `lacks` below is asserted over
  block="$(awk '/^## Share it across repos/{f=1;next} /^## /{f=0} f' "$HOWTO")"
  [ -n "$block" ]
  lacks "$block" "## "
  contains "$block" "emit-telemetry.zsh"
  lacks "$block" "--pipeline review-loop"
  contains "$block" "appends a real record"
}

@test "the how-to states the shared directory is telemetry/v1-only" {
  # It sits just below a section saying the rollup happily reads legacy files,
  # so without this a reader copies them in and breaks #1008's consumer contract.
  run cat "$HOWTO"
  [ "$status" -eq 0 ]
  contains "$output" 'telemetry/v1`-only'
  contains "$output" "never copy them"
}

# --------------------------------------------------------------- cross-links (AC7)

@test "the review-loop explanation links to both telemetry pages" {
  # The needles are the parenthesised markdown TARGETS, not bare filenames:
  # `pipeline-telemetry.md` is a substring of `read-pipeline-telemetry.md`, so a
  # bare-name pair would let the how-to link alone satisfy both — the explanation
  # link could be deleted with this test still green.
  run cat "$REVIEW_LOOP"
  [ "$status" -eq 0 ]
  contains "$output" "(../how-to/read-pipeline-telemetry.md)"
  contains "$output" "(pipeline-telemetry.md)"
}

@test "the refine-issue walkthrough links to both telemetry pages" {
  # Plugin-shipped content, so the links are absolute repo/site URLs per the
  # authoring guide's cross-boundary rule, not relative doc paths.
  run cat "$REFINE"
  [ "$status" -eq 0 ]
  contains "$output" "how-to/read-pipeline-telemetry/"
  contains "$output" "explanation/pipeline-telemetry/"
}

# ------------------------------------------------------------ measure coverage (AC1)

@test "every measure the rollup prints is explained in the how-to's table" {
  # AC1 is "interpret every measure it prints" — so the key list comes from the
  # rollup's ACTUAL --json output over a real fixture, never from the script's
  # text. An earlier version grepped `"key":` out of the script and matched only
  # its header COMMENT (the jq object uses unquoted keys), so a measure added to
  # the executable path would have been invisible while the test claimed
  # otherwise. `pipeline` is dropped: it names the group, it is not a measure.
  local rollup fixture keys key
  rollup="$REPO_ROOT/development/scripts/telemetry/rollup-telemetry.zsh"
  fixture="$REPO_ROOT/tests/fixtures/telemetry/v1-mixed.jsonl"
  [ -f "$rollup" ]
  [ -f "$fixture" ]
  keys="$(zsh "$rollup" --json "$fixture" \
          | jq -r '.[0] | keys[] | select(. != "pipeline")' | LC_ALL=C sort -u)"
  [ -n "$keys" ]
  # a floor, not an equality: adding a measure must red the per-key check below,
  # not this guard
  [ "$(printf '%s' "$keys" | grep -c '')" -ge 5 ]
  while IFS= read -r key; do
    run grep -qF "| \`$key\` |" "$HOWTO"
    [ "$status" -eq 0 ]
  done <<< "$keys"
}
