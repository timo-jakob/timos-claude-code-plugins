#!/usr/bin/env bats
#
# The review panel's terminating severity bars (issue #1433, child 2 of epic #1431).
#
# Why this file exists: #1433's entire deliverable is PROSE inside two agent
# definitions — `claude-plugin-test-reviewer`'s mutation bar and
# `claude-plugin-contract-integrity`'s consumer bar. Before this suite, nothing
# in tests/ read either section. The only test naming an affected file was
# tests/resilience-review-dimension.bats's `[ -f ... ]` existence probe, which
# passes on a file stripped to its frontmatter, and no test named
# claude-plugin-contract-integrity.md at all. So the mutation that both bars
# exist to prevent — deleting or weakening a bar back to its unbounded
# predecessor — left the whole bats suite green, i.e. this change could be
# silently reverted or half-reverted by any later edit.
#
# What is pinned, and why it is driven over THREE agents:
# #1433's acceptance criteria require that the three bars be "visibly the same
# convention". A test that read only the two changed files could not observe
# that. `claude-plugin-prose-logic` is the reference the other two copy and
# #1433 pins it UNCHANGED — asserting its bar here is what makes "unchanged"
# mean something, since nothing else in the suite reads it either.
#
# The roster is DERIVED, not transcribed (the repo-wide-invariant rule adopted
# after a closed swept-file list rotted, #936 / #1188). `BAR_AGENTS` is checked
# against a set discovered by sweeping EVERY tracked `*/agents/*.md` in the
# repo — not just this plugin's — so it fails in BOTH directions: a fourth
# reviewer given a bar that nobody added here reds the roster test rather than
# silently escaping every sweep, and a deleted bar reds it too. That failure
# mode is not hypothetical — round 1 of this very story shipped two bars that
# sat outside the sibling file's closed ALL_SITES list until a reviewer noticed,
# and round 3 caught the first version of this very sweep scoped to one
# directory while its comment claimed the tree.
#
# Non-vacuity control. Each of the 37 mutations below was APPLIED to the real
# tree and the suite confirmed RED, then reverted — a record of runs, not a
# claim. Numbering is contiguous and one number is one mutation, so a gap or a
# duplicate is itself a defect in the record:
#   1. delete the `## The consumer bar` section from claude-plugin-contract-integrity.md
#   2. weaken contract-integrity's WARNING row back to "or misleads the next editor"
#   3. replace test-reviewer's "**A coverage gap clears this bar trivially**"
#      (which would make the agent under-report the class it must keep blocking)
#   4. blunt #982 carve-out (1), "Tests and coverage … always in-scope"
#   5. rename the `## The mutation bar` heading (also proves the ordering test)
#   6. drop "only coverage gaps confined to code the change never touched are demotable"
#   7. drop "the *Scope-bounded severity* rule below still applies"
#   8. narrow the WARNING enum back to "exit code, failure branch, or promised side effect"
#   9. replace 'A "consumer" is someone performing a task, not someone reading
#      a file.' — the task test, without which a naming test excludes nothing
#  10. replace "**A dangling reference clears this bar trivially**"
#  11. weaken prose-logic's own "**The rule:**" sentence — the reference bar
#      #1433 pins UNCHANGED, so this file is what makes "unchanged" observable
#  12. flatten the dangling-reference tiers to "and always blocks"
#  13. delete the execute tier
#  14. delete the planned-target branch
#  15. revert the CRITICAL row's operative predicate to a judgement call
#  16. re-admit "too weak" as the WARNING row's predicate (the scoped negative)
#  17. delete the rejected bar's name from the test reviewer's preamble
#  18. delete "**Nothing here tells you not to report something.**"
#  19. turn contract-integrity's fallback into a suppression ("do not report")
#  20. delete the fail-closed "treat it as touched" tail
#  21. drift .claude-plugin/marketplace.json's version away from plugin.json
#  22. rewrite a numeral-free restatement into the CURRENT digit form, and
#  23. delete one — both against tests/review-loop-budget-consistency.bats
#
# Added after round 3, which found that several round-2 assertions did not bite:
#  24. delete "**First, check status.**" — the tier PRECEDENCE, without which a
#      planned execute-target lands on CRITICAL, the one case the bullet forbids
#  25. drop "whatever the target is for" from the status branch
#  26. revert the closing sentence to the naming test the paragraph above rejects
#  27. delete "**Confirm the target is genuinely absent before tiering.**"
#  28. delete the consumer-bar cell from docs/reference/plugins.md, and
#  29. the mutation-bar cell — that page is hand-written and CI-unchecked
#  30. delete the mutation-bar clause from the test reviewer's frontmatter, and
#  31. the consumer-bar clause from contract-integrity's
#  32. move the mutation clause OUT of `## Reporting Format` into the following
#      section — the mutation the round-2 `_load_section` silently passed
#  33. re-admit the rejected bar into the contract table as a PARAPHRASE
#      ("misleads a future editor of the file"), and
#  34. into the tests table ("the assertions are visibly weak") — both slipped
#      past round 2's literal-substring negatives
#  35. mint a digit site as "(5 rounds by default)",
#  36. as "its 5-round budget", and
#  37. as the word form "after five rounds" — all three passed round 2's
#      three-named-spellings ban, which is why it now bans the numeral SHAPE
#
# A caveat worth keeping, because it bit twice while building this control: the
# clauses above are re-wrapped across source lines, so a line-oriented
# `perl -pi` substitution silently matches NOTHING and the suite stays green —
# which reads exactly like a vacuous assertion. Mutations 4 and 6 first
# "passed" for that reason alone. Any future re-verification must use a
# whole-file (`perl -0pi`), whitespace-tolerant (`\s+`) pattern AND confirm the
# file actually changed before trusting a green result.
#
# Idioms this file follows, per tests/README.md and the repo's guards:
#   * one assertion per line — never `contains … && contains …`, whose left
#     operand is swallowed by the AND-list errexit exemption on every bash;
#   * every haystack is existence-guarded and asserted non-empty BEFORE it is
#     read, because `contains "$(cat missing)"` yields an empty haystack that
#     trivially lacks everything and would make a `lacks` assertion vacuous;
#   * a needle is chosen to be unique to the branch it asserts — a phrase that
#     also occurs elsewhere in the same file proves nothing about the sentence
#     under test, so per-agent fallbacks are pinned on their own wording;
#   * haystacks are SCOPED to the section that must carry the clause, so a
#     clause moved out of the block the test names cannot still satisfy it;
#   * multi-line clauses are matched against a whitespace-flattened copy under
#     LC_ALL=C (these files are dense with em dashes, and `tr`'s treatment of
#     multibyte input is otherwise locale-dependent — the same hazard
#     review-loop-budget-consistency.bats pins LC_ALL=C on grep_num for);
#   * negative assertions are SCOPED and carry a positive control, so a `lacks`
#     can never be applied to a capture that could not have held the needle.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AGENT_DIR="$REPO_ROOT/development-claude-plugin/agents"

  PROSE_LOGIC="$AGENT_DIR/claude-plugin-prose-logic.md"
  TEST_REVIEWER="$AGENT_DIR/claude-plugin-test-reviewer.md"
  CONTRACT="$AGENT_DIR/claude-plugin-contract-integrity.md"

  # The panel agents that carry a terminating severity bar, DERIVED from the
  # tree rather than transcribed, and derived REPO-WIDE rather than from one
  # directory: epic #1431's remaining children work on the `development` plugin,
  # so a fourth reviewer given a bar is at least as likely to land in
  # development/agents/ as here. A directory-scoped sweep would be the same
  # closed-list rot (#936 / #1188) one level up, with a comment claiming a
  # guarantee it does not deliver.
  #
  # git ls-files (tracked) is the enumerator on BOTH rosters this change adds,
  # so the two agree about what "the tree" means. The cost is that an untracked
  # new agent is invisible here — which is the repo's standing "git add new
  # files BEFORE the gate" rule, and fails loudly in CI rather than quietly on
  # one machine. The per-file grep runs in a read loop rather than through
  # `xargs`: xargs word-splits its input, and on empty input GNU xargs runs grep
  # once with no operands (falling through to stdin) where BSD xargs runs
  # nothing at all — a cross-leg divergence in exactly the degenerate case.
  #  * `-c core.quotePath=false` with `-z` / `read -d ''`: git C-quotes paths
  #    holding a non-ASCII byte, a quote or a backslash, and grep cannot open the
  #    quoted literal — it exits 2 and the file drops out of the roster silently.
  #    That is the one direction that fails OPEN, so an agent whose filename
  #    happened to be quoted would carry a bar no sweep sees.
  #  * the NUL stream is read STRAIGHT from the process substitution, never
  #    through a `$(...)` capture: command substitution cannot carry NUL bytes —
  #    bash drops them — so capturing first collapses the whole listing into one
  #    unopenable path and the roster silently comes out EMPTY. (That is not
  #    hypothetical: it is how this block first shipped, and the parallel gate
  #    caught it.) git's own status is checked by the `rev-parse` probe instead.
  #  * `</dev/null` on the probe: `grep -q PAT ""` reads STDIN, which here is the
  #    enumerator's own pipe — an empty path would eat the rest of the listing
  #    and silently truncate the roster.
  #  * dedup on compare, because a conflicted index lists a path once per stage.
  git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || {
    printf 'not a git worktree, cannot derive the bar roster: %s\n' "$REPO_ROOT" >&2
    return 1
  }
  DISCOVERED=()
  while IFS= read -r -d '' cand; do
    if [ -n "$cand" ] && grep -q '^## The .* bar (severity rule' -- "$REPO_ROOT/$cand" </dev/null; then
      DISCOVERED+=("$REPO_ROOT/$cand")
    fi
  done < <(cd "$REPO_ROOT" && git -c core.quotePath=false ls-files -z '*/agents/*.md')

  BAR_AGENTS=("$CONTRACT" "$PROSE_LOGIC" "$TEST_REVIEWER")
}

# Read a file into $body (raw) and $flat (whitespace-squeezed), failing loudly
# if it is missing or empty rather than handing an empty haystack to `contains`
# or — far worse — to `lacks`, which any empty string satisfies. Always called
# as a simple command so a failure inside it aborts the test under errexit.
_load_agent() {
  local path="$1"
  [ -f "$path" ] || {
    printf 'agent file missing: %s\n' "$path" >&2
    return 1
  }
  body="$(cat "$path")"
  [ -n "$body" ]
  flat="$(printf '%s' "$body" | LC_ALL=C tr -s '[:space:]' ' ')"
  [ -n "$flat" ]
}

# Flatten one markdown section of a file, so a clause asserted "in the
# Reporting Format" cannot be satisfied by the same words sitting in the bar's
# prose instead. The range ends at the NEXT `## ` heading, whatever it is called.
#
# awk with an exact prefix compare, deliberately not sed: a sed end address of
# `/^## [^<heading>]/` is a negated character CLASS, not a negated string, so for
# "Reporting Format" it cannot match a following `## Reviewing thoroughness`
# (R is in the class) — the range then runs to EOF and the "scoped" haystack is
# the whole file, which is how this helper shipped in round 2 and what round 3
# caught. awk also needs no metacharacter escaping, so a heading containing
# `.`, `*`, `[` or `/` cannot silently widen the capture either.
_load_section() {
  local path="$1" heading="$2"
  [ -f "$path" ]
  section="$(awk -v h="## $heading" 'index($0, h) == 1 { f = 1; next } /^## / { f = 0 } f' "$path")"
  [ -n "$section" ] || {
    printf 'section "%s" not found in %s\n' "$heading" "$path" >&2
    return 1
  }
  section_flat="$(printf '%s' "$section" | LC_ALL=C tr -s '[:space:]' ' ')"
  [ -n "$section_flat" ]
}

# Flatten a file's YAML frontmatter — the block between the first two `---`
# lines. The `description:` clause a dispatcher reads (and that
# generate-docs-reference.py reproduces into docs/reference/agents.md) lives
# here, so asserting it against the whole file would be satisfied by the same
# words restated anywhere in the body.
_load_frontmatter() {
  local path="$1"
  [ -f "$path" ]
  frontmatter="$(awk 'NR==1 && /^---$/ { f=1; next } f && /^---$/ { exit } f' "$path")"
  [ -n "$frontmatter" ] || {
    printf 'no frontmatter block in %s\n' "$path" >&2
    return 1
  }
  frontmatter_flat="$(printf '%s' "$frontmatter" | LC_ALL=C tr -s '[:space:]' ' ')"
  [ -n "$frontmatter_flat" ]
}

# Capture EXACTLY the severity table's own lines — header, separator and rows —
# and nothing after it, so the negatives below can never be applied to prose that
# legitimately QUOTES a rejected bar.
#
# awk stopping at the first line that is not a table row, deliberately not a sed
# `,/^[^|]/` range: `[^|]` requires a character, and the blank line after every
# table has none, so that range over-ran into the `**The rule: …**` paragraph.
# The negatives below would then have been asserted against prose, and moving a
# rejected-bar quotation under the table would have reddened the suite for a
# non-defect.
_load_table() {
  local path="$1"
  [ -f "$path" ]
  table="$(awk '/^\| Severity \| Bar \|/ { f = 1 } f && !/^\|/ { exit } f' "$path")"
  [ -n "$table" ] || {
    printf 'severity table not found in %s\n' "$path" >&2
    return 1
  }
}

# Name the offending path on failure — the loops below check one property
# across several agents, and bats reports only the source line, so without this
# a failure cannot say WHICH agent drifted.
_assert_file() {  # _assert_file <path> <test-expr...>
  local path="$1"
  shift
  # arity guard, mirroring _assert_args in tests/assertions.bash: with no
  # remaining arguments `"$@"` runs nothing and returns 0, so a dropped test
  # expression would be a vacuous assertion reporting ok
  [ "$#" -ge 1 ] || {
    printf '_assert_file: no test expression given for %s\n' "$path" >&2
    return 2
  }
  "$@" || {
    printf 'failed for %s: %s\n' "$path" "$*" >&2
    return 1
  }
}

@test "the bar roster is derived, non-empty, and matches the expected set (#1433)" {
  # The tripwire, in both directions: a bar added to a fourth agent appears in
  # DISCOVERED and fails here until it is added to BAR_AGENTS deliberately; a
  # bar deleted from a rostered agent fails here too. This is also the
  # non-vacuity control for every loop below — an emptied array would
  # otherwise run them zero times and report ok.
  [ "${#DISCOVERED[@]}" -ge 3 ]
  local got want
  got="$(printf '%s\n' "${DISCOVERED[@]}" | sort -u)"
  want="$(printf '%s\n' "${BAR_AGENTS[@]}" | sort -u)"
  # compared as deduped SETS: a conflicted index lists a path once per stage, so
  # a raw length check would red mid-rebase while nothing had changed
  [ "$got" = "$want" ]
  [ "$(printf '%s\n' "$got" | grep -c .)" -ge 3 ]
}

@test "all three panel bars state the same convention (#1433)" {
  # The shared shape: a section headed "The <name> bar (severity rule — this
  # bounds you)", a severity table of exactly three rows, and one bolded
  # falsifiable rule. Needles are chosen so a NEGATED or hedged restatement
  # cannot satisfy them.
  local agent rows
  for agent in "${BAR_AGENTS[@]}"; do
    _load_agent "$agent"
    contains "$flat" 'bar (severity rule — this bounds you)'
    contains "$flat" 'Your severities are therefore bounded by a falsifiable rule'
    contains "$flat" '**The rule: a finding may not carry a severity `>= WARNING` unless it names'
    # exactly three severity rows — deleting one is caught by the per-agent
    # needles, ADDING a fourth (e.g. a `BLOCKER` tier) would otherwise pass
    _load_table "$agent"
    # `|| true`: grep -c exits 1 on a zero count while still printing 0, and an
    # errexit abort here would bypass the _assert_file diagnostic in exactly the
    # case (every row deleted) where naming the agent matters most
    rows="$(printf '%s\n' "$table" | grep -c '^| `' || true)"
    _assert_file "$agent" [ "$rows" -eq 3 ]
  done
}

@test "each bar section precedes the Reporting Format it constrains (#1433)" {
  # prose-logic states the bar BEFORE the reporting format, and #1433 requires
  # the other two "state the bar in the same place and shape". A bar stated
  # after the format it governs would read as an afterthought rather than as
  # the rule the reviewer applies while writing findings.
  local agent bar_line fmt_line
  for agent in "${BAR_AGENTS[@]}"; do
    _assert_file "$agent" [ -f "$agent" ]
    bar_line="$(grep -n '^## The .* bar (severity rule' "$agent" | head -1 | cut -d: -f1)"
    fmt_line="$(grep -n '^## Reporting Format' "$agent" | head -1 | cut -d: -f1)"
    _assert_file "$agent" [ -n "$bar_line" ]
    _assert_file "$agent" [ -n "$fmt_line" ]
    _assert_file "$agent" [ "$bar_line" -lt "$fmt_line" ]
  done
}

@test "prose-logic's Reporting Format demands the wrong action (#1433)" {
  # Scoped to the section, not the file: moving this clause into the bar's
  # prose would leave a file-wide needle green while the reporting template
  # stopped asking the reviewer to write the falsifier down.
  _load_section "$PROSE_LOGIC" "Reporting Format"
  contains "$section_flat" 'for CRITICAL/WARNING — the concrete wrong action a model following the'
}

@test "the test reviewer's Reporting Format demands the mutation (#1433)" {
  _load_section "$TEST_REVIEWER" "Reporting Format"
  contains "$section_flat" 'for CRITICAL/WARNING, the concrete mutation of the source under test that the current suite would pass'
  # proves the scope is REAL, not the whole file: this agent has a section after
  # Reporting Format, and the round-2 helper silently ran to EOF past it
  lacks "$section_flat" 'Reviewing thoroughness'
  lacks "$section_flat" 'Scope-bounded severity'
}

@test "contract-integrity's Reporting Format demands the consumer's wrong action (#1433)" {
  _load_section "$CONTRACT" "Reporting Format"
  contains "$section_flat" 'for CRITICAL/WARNING, the concrete wrong action a consumer takes because of it'
}

@test "claude-plugin-test-reviewer states the mutation bar (#1433)" {
  agent_path="$TEST_REVIEWER"
  _load_agent "$TEST_REVIEWER"

  contains "$body" '## The mutation bar (severity rule — this bounds you)'
  # the frontmatter description advertises the bar, the way prose-logic's does —
  # it is what a dispatcher reads, and what the generated docs/reference/agents.md
  # reproduces. generate-docs-reference.py --check keeps the two copies in step but
  # asserts nothing about the clause EXISTING
  _load_frontmatter "$agent_path"
  contains "$frontmatter_flat" 'severity is bounded by an explicit mutation bar'
  # the falsifier itself
  contains "$flat" 'unless it names a concrete mutation of the source under test that the current suite would pass'
  # the fallback, pinned on wording unique to THIS agent — a bare "is a
  # `SUGGESTION`" also occurs elsewhere and would not prove the rule demotes
  contains "$flat" 'the finding is a `SUGGESTION`, no matter how weak the assertion looks'
  # the rejected bar, named as rejected — deleting the name would leave the
  # section without the thing it exists to exclude
  contains "$flat" 'whose bar is *"these assertions are too weak"* never terminates'
  contains "$flat" "round N's fix is round N+1's finding"
  # every row on its own OPERATIVE clause, not just its parenthetical exemplar
  contains "$flat" 'no mutation of the script under test is caught at all'
  contains "$flat" 'a test that passes on **every** mutation'
  contains "$flat" 'exit code, failure branch, flag/subcommand, output content, promised side effect, or any other behaviour its contract documents'
  contains "$flat" 'a strength concern you cannot express as a passing mutation — never blocks'
  # the carve-out that keeps real coverage gaps blocking, and its tier split
  contains "$flat" 'A coverage gap clears this bar trivially'
  contains "$flat" '`CRITICAL` for a changed script with no tests at all, `WARNING` for an individual untested branch'
  # coverage is bounded by scope, not by this bar — with the fail-closed tail
  contains "$flat" 'the *Scope-bounded severity* rule below still applies'
  contains "$flat" 'treat it as touched and keep full severity'
  # the anti-suppression guarantee, which is what makes this a severity bound
  contains "$flat" '**Nothing here tells you not to report something.**'
  contains "$flat" 'the promotion path (#994) can still raise it'
  contains "$flat" 'This bounds severity, not coverage.'
}

@test "claude-plugin-contract-integrity states the consumer bar (#1433)" {
  agent_path="$CONTRACT"
  _load_agent "$CONTRACT"

  contains "$body" '## The consumer bar (severity rule — this bounds you)'
  _load_frontmatter "$agent_path"
  contains "$frontmatter_flat" 'severity is bounded by an explicit consumer bar'
  # the falsifier itself
  contains "$flat" 'unless it names the concrete wrong action a consumer — human or model — takes because of the drift'
  # the fallback, on wording unique to THIS agent (see the note above)
  contains "$flat" 'the finding is a `SUGGESTION`, however untidy the inconsistency'
  # every row on its own OPERATIVE clause
  contains "$flat" 'following the artifact **will** fail or produce a wrong result'
  contains "$flat" 'a reference the artifact tells a model to *execute* does not resolve, or the drift breaks the consumer outright'
  contains "$flat" 'a named consumer **may** take a concrete wrong action because of the drift'
  contains "$flat" 'inconsistency with no named consumer who acts wrongly — never blocks'
  # the clause that stops the rejected bar re-entering wearing the word
  # "action". It must be a TASK test: a naming test is satisfied by the
  # Reporting Format's own mandatory File: header and so excludes nothing.
  contains "$flat" 'A "consumer" is someone performing a task, not someone reading a file.'
  contains "$flat" 'Naming a file is not the test'
  # the dangling-reference carve-out, tiered — without the tiers a doc link and
  # an unresolvable subagent_type land on the same guess
  contains "$flat" 'A dangling reference clears this bar trivially. Tier it in this order'
  # the ORDER is the load-bearing part: a planned target is usually a script or
  # subagent_type, so tiering by purpose first sends exactly the case the bullet
  # forbids blocking (an epic child citing a sibling's work) to CRITICAL
  contains "$flat" '**First, check status.**'
  contains "$flat" 'whatever the target is for'
  contains "$flat" 'Never block an epic child for pointing at a sibling'
  contains "$flat" '**Otherwise tier by purpose.**'
  contains "$flat" 'the artifact tells its reader — model **or** human — to **execute** the target'
  # the marking is the test, and it may not be inferred from the prompt's epic
  # number — without this the carve-out silences the class it exists to keep blocking
  contains "$flat" '**Never infer the marking.**'
  # a rejector is not required: silent wrong results are consumer actions too
  contains "$flat" 'carries through silently to a wrong result'
  contains "$flat" 'anything else that does not resolve'
  # and the fail-closed branch for a target whose absence cannot be established
  contains "$flat" 'Confirm the target is genuinely absent before tiering.'
  # the closing sentence must restate the TASK test, not the naming test the
  # paragraph above rejects
  contains "$flat" "whose consumer's wrong action you cannot state — naming a consumer is not enough"
  lacks "$flat" 'The bar bites only on drift whose consumer you cannot name.'
  # the anti-suppression guarantee
  contains "$flat" '**Nothing here tells you not to report something.**'
  contains "$flat" 'the promotion path (#994) can still raise it'
  contains "$flat" 'This bounds severity, not coverage.'
}

@test "neither new bar's operative rows re-admit its rejected predicate (#1433)" {
  # SCOPED negatives: each preamble legitimately QUOTES the bar it rejects, so
  # a file-wide `lacks` could never pass. What must not carry the predicate is
  # the severity TABLE — the operative rows. Each capture carries a positive
  # control first, so the `lacks` can only ever run against real rows.
  _load_table "$CONTRACT"
  contains "$table" '| `CRITICAL` |'
  contains "$table" '| `SUGGESTION` |'
  lacks "$table" 'misleads the next editor'
  # the short token too, so a PARAPHRASE ("misleads a future editor of the file")
  # cannot re-admit the rejected bar past a literal-substring guard. Safe: no
  # operative row of this table legitimately says "editor"
  lacks "$table" 'editor'

  _load_table "$TEST_REVIEWER"
  contains "$table" '| `CRITICAL` |'
  contains "$table" '| `SUGGESTION` |'
  lacks "$table" 'too weak'
  # same, for "the assertions are visibly weak"; no operative row says "weak"
  lacks "$table" 'weak'

  # and each rejection must still be STATED as a rejection, not merely deleted
  _load_agent "$CONTRACT"
  contains "$flat" 'never terminates: every incomplete restatement misleads some hypothetical next editor'
  _load_agent "$TEST_REVIEWER"
  contains "$flat" 'whose bar is *"these assertions are too weak"* never terminates'
}

@test "claude-plugin-prose-logic's reference bar is unchanged (#1433)" {
  # #1433 pins this file. Nothing else in the suite reads its bar, so without
  # this the "leave prose-logic alone" criterion is unobservable.
  agent_path="$PROSE_LOGIC"
  _load_agent "$PROSE_LOGIC"

  contains "$body" '## The behavioural bar (severity rule — this bounds you)'
  _load_frontmatter "$agent_path"
  contains "$frontmatter_flat" 'severity is bounded by an explicit behavioural bar'
  contains "$flat" 'unless it names the concrete wrong action a model would take'
  contains "$flat" 'a model following this **will** act wrongly'
  contains "$flat" 'a model following this **may** act wrongly'
  contains "$flat" 'wording, tone, or clarity with **no behavioural delta** — never blocks'
}

@test "the test reviewer keeps its #982 scope-bounding intact (#1433)" {
  # #1433 explicitly requires the scope-bounded-severity rule and its three
  # carve-outs survive the change. Carve-out (1) is the one the new mutation
  # bar interacts with, so it is pinned by its exact clause.
  _load_agent "$TEST_REVIEWER"

  contains "$body" '## Reviewing thoroughness (#982)'
  contains "$flat" '**Scope-bounded severity.**'
  contains "$flat" '**(1) Tests and coverage for the change under review are always in-scope**'
  contains "$flat" '**(2) A defect the change under review *introduces* is'
  contains "$flat" "**(3) When the issue's stated scope is not provided in your prompt**"
  contains "$flat" 'only coverage gaps confined to code the change never touched are demotable'
}

@test "ARCHITECTURE.md's statement of the convention matches the agents (#1433)" {
  # ARCHITECTURE.md names THIS file as "the guard" for the bar convention, but
  # until now the guard never read it — so the contract statement could drift
  # from the agents it describes with the whole suite green. That is the "same
  # rule stated in two files where an edit changed only one" class, on the more
  # load-bearing restatement: the contract reviewer checks drift AGAINST
  # ARCHITECTURE.md.
  #
  # Scoped with its own awk range: the section is a `### ` heading, and every
  # claim asserted here must live inside it, not merely somewhere in a
  # 3000-line document.
  local arch section flat agent bar
  arch="$REPO_ROOT/ARCHITECTURE.md"
  [ -f "$arch" ]
  # `/^###? /` closes on a level-2 heading too: a range blind to the ENCLOSING
  # level is how _load_section shipped in round 2 — it ran to EOF and made a
  # "scoped" haystack the whole file. This one is tight today only because
  # another `###` follows; make it tight by construction.
  section="$(awk '/^### Terminating severity bars \(#1433\)/ { f = 1; next } f && /^###? / { exit } f' "$arch")"
  [ -n "$section" ]
  flat="$(printf '%s' "$section" | LC_ALL=C tr -s '[:space:]' ' ')"
  [ -n "$flat" ]

  # the shape it documents must be the shape the agents carry
  contains "$flat" '`## The <name> bar (severity rule — this bounds you)`'
  contains "$flat" 'three-row'
  # the phrase, not the bare token: "a rule that is *not* falsifiable" would
  # satisfy `contains "$flat" 'falsifiable'`
  contains "$flat" 'one bolded, **falsifiable** rule'
  # and the SEMANTIC claims, without which the paragraph can be gutted to its
  # skeleton while every structural needle still matches: which falsifier each
  # bar demands, that the Reporting Format requires it, and the coverage
  # guarantee whose agent-side mirror this same file pins
  contains "$flat" 'a concrete mutation of the source under test that the current suite would'
  contains "$flat" 'the concrete wrong action a named consumer takes'
  contains "$flat" "Each agent's Reporting Format then requires that falsifier"
  contains "$flat" 'still raisable by the #994 promotion path'
  # each carrier and its bar name, driven off the same pairing the inventory
  # test uses, so one edit cannot move them apart
  for agent in claude-plugin-prose-logic:behavioural \
    claude-plugin-contract-integrity:consumer \
    claude-plugin-test-reviewer:mutation; do
    bar="${agent##*:}"
    agent="${agent%%:*}"
    contains "$flat" "\`$agent\` (the *$bar* bar"
  done
  # the guard it names must exist — a renamed suite would leave this dangling
  contains "$flat" 'tests/claude-plugin-review-severity-bars.bats'
  [ -f "$REPO_ROOT/tests/claude-plugin-review-severity-bars.bats" ]
  # it must NOT transcribe a reviewer count: the roster is derived, and a
  # transcribed count goes stale the moment a fourth reviewer gains a bar
  # the SHAPE, not one historical literal: this file already learned twice that a
  # paraphrase walks past a literal-substring negative (ledger 33/34), and the
  # fix there was a short-token ban. "Three of the five panel reviewers…" would
  # sail past `lacks 'Three of its five'` and re-transcribe the very count the
  # derived roster exists to make unnecessary.
  run -1 grep -Eqi '(one|two|three|four|five|six|[0-9]+) of (its|the|our)( [a-z]+)* reviewers' <<<"$flat"
  lacks "$flat" 'Three of its five'
  # and it must point the remaining-bars follow-up at the epic that filed the
  # convention, not at the scope-bounding follow-up above it
  contains "$flat" 'epic #1431'
}

@test "the hand-written plugin inventory records all three bars (#1433)" {
  # docs/reference/plugins.md is hand-written narrative: no generator covers it
  # and reference-drift.yml does not check it, so without this the bar clauses
  # added to its rows can be deleted with the whole suite green — the "same rule
  # stated in two files where an edit changed only one" class this panel exists
  # to catch, in the panel's own inventory.
  local page row agent bar
  page="$REPO_ROOT/docs/reference/plugins.md"
  [ -f "$page" ]
  for agent in claude-plugin-prose-logic:behavioural \
    claude-plugin-contract-integrity:consumer \
    claude-plugin-test-reviewer:mutation; do
    bar="${agent##*:}"
    agent="${agent%%:*}"
    # `|| true`: a bare substitution takes grep's status, so a deleted row would
    # abort here under errexit and the _assert_file diagnostic below — the whole
    # reason the helper exists — would never name which agent lost its row
    row="$(grep -F "| $agent |" "$page" || true)"
    _assert_file "$page ($agent)" [ -n "$row" ]
    contains "$row" "severity bounded by the $bar bar"
    # and the falsifier, not just the bar's name: a cell naming a bar without
    # its rule documents nothing
    contains "$row" 'without naming'
  done
}

@test "development-claude-plugin's real manifest pair is in lockstep (#1433)" {
  # tests/check-marketplace-sync.bats is FIXTURE-only — it copies the script
  # into a tmpdir and runs it against synthetic manifests, so it passes
  # byte-identically whatever the real pair says. Nothing else in the suite
  # reads this plugin's actual versions, which is how a round-2 reviewer came
  # to report a drift that did not exist. Pin the real pair here, in the test
  # file that belongs to the change that bumps it.
  local pj mv
  pj="$(jq -r .version "$REPO_ROOT/development-claude-plugin/.claude-plugin/plugin.json")"
  mv="$(jq -r '.plugins[] | select(.name=="development-claude-plugin") | .version' \
    "$REPO_ROOT/.claude-plugin/marketplace.json")"
  [ -n "$pj" ]
  [ "$pj" != "null" ]
  [ -n "$mv" ]
  [ "$mv" != "null" ]
  [ "$pj" = "$mv" ]
}
