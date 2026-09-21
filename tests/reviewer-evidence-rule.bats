#!/usr/bin/env bats
#
# #1584 — a read-only reviewer's tool-verdict claim is a SUGGESTION until the
# conductor runs the tool.
#
# Two halves, and this file guards both:
#
#   1. Every read-only reviewer in development-claude-plugin/agents/ (the ones
#      whose frontmatter is `tools: Read, Grep, Glob`, so they can read and grep
#      but cannot EXECUTE a linter, a suite, a validator or a version-sync
#      script) states the evidence rule under a heading naming it, tells the
#      reviewer to name the deciding command, and gives those lines a slot in its
#      Reporting Format.
#   2. The conductor's run-the-command-before-consolidating step is stated
#      EXACTLY ONCE, in development/skills/resolve-issue/reference/review-loop.md,
#      and docs/explanation/review-loop.md points at it instead of restating it.
#
# The roster in half 1 is DERIVED from the frontmatter, never a hard-coded list:
# a closed list rots the moment a sixth read-only reviewer is added, and the new
# agent would then carry no evidence rule with every test still green. The
# derived set is additionally compared against the five known today, so ADDING a
# read-only reviewer is a deliberate, visible edit to this file.
#
# The sweep stops at `development-claude-plugin/agents/`, which is #1584's stated
# scope. Roughly thirty agents in OTHER plugins declare the same read-only tool
# set and carry no evidence rule; widening this roster to `git ls-files
# '*/agents/*.md'` is #1644, and belongs with the edit that gives them the rule.
#
# NEEDLES ARE SECTION-SCOPED, NOT FILE-WIDE. These five sections are maintained
# as byte-identical copies, so the realistic edit is a UNIFORM one, and a
# file-wide grep cannot tell "the clause is in the evidence rule" from "the
# clause is anywhere in a 200-line agent". Matching file-wide would let the
# fenced `decides:` block be moved out of the section into Reporting Format with
# every test still green — while AC 1 requires the rule *under a heading naming
# it*.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AGENT_DIR="$REPO_ROOT/development-claude-plugin/agents"
  REFERENCE="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md"
  EXPLANATION="$REPO_ROOT/docs/explanation/review-loop.md"
  PROFILE="$REPO_ROOT/development-claude-plugin/skills/resolve-profile/SKILL.md"
  HEADING="## The evidence rule (a tool's verdict needs the tool run)"
  # ONE spelling of the section title, from which BOTH the target's heading and
  # the pointers' italic reference are derived — so a rename cannot move the
  # heading without also reding the two pointer tests.
  SECTION_NAME='The decided pass'
  REF_HEADING="### $SECTION_NAME"
  POINTER_NAME="*$SECTION_NAME*"
  # The five known read-only reviewers, sorted. Compared against the derived set.
  EXPECTED_ROSTER="claude-plugin-contract-integrity
claude-plugin-manifest-check
claude-plugin-prose-logic
claude-plugin-script-reviewer
claude-plugin-test-reviewer"
  EXPECTED_COUNT=5
}

# Print the basename of every agent in $1 whose frontmatter
# declares the read-only tool set. One definition, used by the real sweep AND by
# the non-vacuity fixture below, so the two can never test different rules.
#
# The tool set is NORMALISED (split on commas, trimmed, sorted) rather than
# matched as a literal line: `tools: Glob, Grep, Read` is the same read-only
# agent as `tools: Read, Grep, Glob`, and a spelling-exact grep would make a
# reordered sixth agent invisible to BOTH this sweep and the roster tripwire —
# it would ship with no evidence rule and the suite would stay green.
# The glob is `*.md`, not `claude-plugin-*.md`: the tool-set filter already
# excludes everything that is not a read-only reviewer, and a future reviewer
# added under another basename would otherwise escape BOTH this sweep and the
# EXPECTED_ROSTER tripwire that is supposed to make an addition visible.
read_only_agents_in() {
  local dir="$1" f tools
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    tools="$(awk -F': *' '
      /^---$/ { n++; if (n == 2) exit; next }
      n == 1 && /^tools:/ { print $2; exit }
    ' "$f" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
      | grep -v '^$' | sort | tr '\n' ' ')"
    [ "$tools" = "Glob Grep Read " ] || continue
    basename "$f" .md
  done | sort
}

# Print the basename of every read-only agent in $1 that is MISSING the evidence
# rule heading. Empty output = the sweep passes.
missing_evidence_rule_in() {
  local dir="$1" a
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    grep -qF -- "$HEADING" "$dir/$a.md" || printf '%s\n' "$a"
  done < <(read_only_agents_in "$dir")
}

# The body of one `## `-delimited section of a markdown file, heading included.
# LEVEL-AWARE end predicate: a `### ` section closes on the next `### ` **or**
# on any `## `. A range blind to the ENCLOSING level silently absorbs every
# following section once a `## ` is inserted between them, which turns a
# "section-scoped" haystack into most of the file — the exact defect the sibling
# severity-bars suite shipped once and documents.
section_of() {  # $1 = file, $2 = heading (exact line), $3 = heading prefix
  awk -v h="$2" -v p="${3:-## }" '
    $0 == h { emit = 1; print; next }
    emit && index($0, p) == 1 { exit }
    emit && p == "### " && index($0, "## ") == 1 { exit }
    emit { print }
  ' "$1"
}

# Collapse a capture to one line, so a needle may be matched against PROSE
# without caring where the author's hard wrap fell. `grep -F` is line-oriented,
# so a needle spanning a wrap simply never matches — and, worse, an embedded
# newline makes `grep -F` treat the needle as an ALTERNATION where either half
# suffices. Every prose needle in this file therefore goes through `flatten`,
# and every needle is written as a single line.
flatten() { tr '\n' ' ' | tr -s ' '; }

# Assert one needle occurs EXACTLY ONCE in a section, flattened. Uniqueness is
# the property that makes a needle discriminating: one that also matches a
# second sentence keeps passing when the sentence it was written for is deleted.
needle_once() {  # $1 = label, $2 = section text, $3 = needle
  local n
  n="$(printf '%s' "$2" | flatten | grep -oF -- "$3" | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || {
    printf '%s: needle matched %s times (want exactly 1): %s\n' "$1" "$n" "$3" >&2
    return 1
  }
}

@test "#1584 CONTROL: needle_once itself reds on an absent needle and on a duplicated one" {
  # Every needle in the two clause tests routes through this helper, and a
  # helper that always returned 0 would make every one of them vacuous. Drive it
  # over a literal fixture rather than over the real sections.
  fixture='alpha the quick brown fox
beta the quick brown fox
gamma a singular sentence
delta a clause that wraps
   with a three-space continuation'

  run needle_once 'ctl' "$fixture" 'a singular sentence'
  [ "$status" -eq 0 ]

  run needle_once 'ctl' "$fixture" 'the quick brown fox'
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'matched 2 times'

  run needle_once 'ctl' "$fixture" 'a needle that is simply not there'
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'matched 0 times'

  # and it must be flattening: a needle spanning the fixture's own line break
  # is one match once flattened, not zero
  run needle_once 'ctl' "$fixture" 'brown fox beta'
  [ "$status" -eq 0 ]

  # …including the SPACE-SQUEEZE half. Every real needle here is matched against
  # markdown whose clauses wrap inside indented list items, so dropping the
  # `tr -s ' '` would break them while a newline-only control stayed green.
  run needle_once 'ctl' "$fixture" 'that wraps with a three-space continuation'
  [ "$status" -eq 0 ]
}

@test "#1584 the read-only reviewer roster is derived, non-empty, and is the five known today" {
  # This is ALSO the non-vacuity control for every loop in this file: a wrong or
  # missing AGENT_DIR, or a frontmatter change that hides an agent, reds here
  # rather than silently emptying the sweeps below.
  [ -d "$AGENT_DIR" ]
  run read_only_agents_in "$AGENT_DIR"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" = "$EXPECTED_ROSTER" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq "$EXPECTED_COUNT" ]
}

@test "#1584 every read-only reviewer states the evidence rule under a heading naming it" {
  [ -d "$AGENT_DIR" ]
  run missing_evidence_rule_in "$AGENT_DIR"
  [ "$status" -eq 0 ]
  # Name the offenders rather than just failing a count.
  [ -z "$output" ] || {
    printf 'agents missing the evidence rule: %s\n' "$output" >&2
    return 1
  }
}

@test "#1584 NON-VACUITY: the same sweep fails an otherwise-identical agent that lacks the section" {
  # Copy the real agents, strip the section from exactly one, and run the SAME
  # function. If the sweep were vacuous (a glob that matches nothing, a grep that
  # always succeeds), this would pass silently and the test above would prove
  # nothing.
  fixture="$BATS_TEST_TMPDIR/agents"
  mkdir -p "$fixture"
  cp "$AGENT_DIR"/*.md "$fixture/"
  # the copy must still yield the full roster, or the control proves nothing
  [ "$(read_only_agents_in "$fixture")" = "$EXPECTED_ROSTER" ]

  victim="$fixture/claude-plugin-prose-logic.md"
  # Drop from the evidence-rule heading up to (not including) the next heading.
  awk -v h="$HEADING" '
    $0 == h { skipping = 1 }
    skipping && /^## / && $0 != h { skipping = 0 }
    !skipping { print }
  ' "$victim" > "$victim.stripped"
  mv -- "$victim.stripped" "$victim"
  run grep -qF -- "$HEADING" "$victim"
  [ "$status" -ne 0 ]   # the strip really happened

  run missing_evidence_rule_in "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-plugin-prose-logic" ]
}

@test "#1584 the evidence rule is stated identically in all five, so it cannot drift apart" {
  # The five copies are one rule restated per agent (the same shape the severity
  # bars use). Byte-identity of the section is what keeps five copies one rule.
  ref=""
  n=0
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    n=$((n + 1))
    section="$(section_of "$AGENT_DIR/$a.md" "$HEADING")"
    [ -n "$section" ]
    if [ -z "$ref" ]; then
      ref="$section"
    else
      [ "$section" = "$ref" ] || {
        printf 'evidence rule in %s differs from the first agent\n' "$a" >&2
        return 1
      }
    fi
  done < <(read_only_agents_in "$AGENT_DIR")
  [ "$n" -eq "$EXPECTED_COUNT" ]
  [ -n "$ref" ]
}

@test "#1584 every operative clause of the evidence rule is pinned, SECTION-scoped" {
  # Each needle is unique to its own sentence, so deleting that sentence reds
  # this test. Matched against the SECTION, never the file, so relocating the
  # fenced block out of the rule cannot pass.
  n=0
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    n=$((n + 1))
    section="$(section_of "$AGENT_DIR/$a.md" "$HEADING")"
    [ -n "$section" ]
    for needle in \
      'carries `SUGGESTION`' \
      'a linter would flag this, a suite run would come' \
      'unless you RAN the tool and quote its output' \
      'two lines in the finding'"'"'s **Description**, each on its own line' \
      'decides: <the exact command that settles it' \
      'READ-ONLY, run from the root of the tree you were told to read' \
      'proposed-severity: CRITICAL|WARNING' \
      'the repo'"'"'s **pinned** tool where one exists' \
      'in its **checking** invocation, never a fixing one' \
      'is the severity this finding carries **if that' \
      'Omit either line and the conductor promotes nothing' \
      'only on a **real** red, leaving it `SUGGESTION` on green' \
      'What it covers, and what it does not' \
      '*observation vs. execution*, not subject matter' \
      'two manifests disagreeing about a version' \
      'a changed script with no test file beside it' \
      'a **tool'"'"'s configuration or ruleset** you cannot fully evaluate' \
      'is observation even when some script also happens to check it' \
      'do not dodge the rule by rewording' \
      'is the same claim with the sign flipped' \
      'This bounds severity, not what you report'
    do
      needle_once "$a" "$section" "$needle" || return 1
    done
  done < <(read_only_agents_in "$AGENT_DIR")
  [ "$n" -eq "$EXPECTED_COUNT" ]
}

@test "#1584 each reviewer's Reporting Format gives the two lines a slot" {
  # Without a slot in the template the rule is advisory: a model filling in the
  # Reporting Format has nowhere to put the two lines the conductor keys on, and
  # emits a capped finding nothing ever settles. Section-scoped to Reporting
  # Format, so a copy of the lines elsewhere in the file does not satisfy it.
  n=0
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    n=$((n + 1))
    rf="$(section_of "$AGENT_DIR/$a.md" '## Reporting Format')"
    [ -n "$rf" ]
    printf '%s' "$rf" | grep -qF 'decides: <the command that settles it>' || {
      printf '%s: Reporting Format has no decides: slot\n' "$a" >&2; return 1; }
    printf '%s' "$rf" | grep -qF 'proposed-severity: CRITICAL|WARNING' || {
      printf '%s: Reporting Format has no proposed-severity: slot\n' "$a" >&2; return 1; }
  done < <(read_only_agents_in "$AGENT_DIR")
  [ "$n" -eq "$EXPECTED_COUNT" ]
}

@test "#1584 every agent OUTSIDE the roster can actually run tools, and carries no evidence rule" {
  # The rule exists because the agent cannot execute, so an agent holding Bash is
  # rightly outside it. Assert that POSITIVELY: checking only "not in the roster,
  # and has no rule" would silently bless an agent declaring `tools: Read, Grep`
  # — read-only, just not the exact three — which falls out of the roster, escapes
  # the EXPECTED_ROSTER tripwire, and ships with no evidence rule while this test
  # reports it as correctly excluded. That is the file's own closed-set rot, one
  # level down.
  [ -d "$AGENT_DIR" ]
  roster="$(read_only_agents_in "$AGENT_DIR")"
  n=0
  for f in "$AGENT_DIR"/*.md; do
    [ -e "$f" ] || continue
    printf '%s\n' "$roster" | grep -qxF "$(basename "$f" .md)" && continue
    n=$((n + 1))
    tools="$(awk -F': *' '
      /^---$/ { c++; if (c == 2) exit; next }
      c == 1 && /^tools:/ { print $2; exit }
    ' "$f")"
    # either it declares Bash, or it declares no tools: key at all (inheriting
    # everything, which includes Bash)
    if [ -n "$tools" ]; then
      printf '%s' "$tools" | grep -qw 'Bash' || {
        printf '%s is neither read-only-with-the-rule nor Bash-holding: tools: %s\n' \
          "$(basename "$f")" "$tools" >&2
        return 1
      }
    fi
    run grep -qF -- "$HEADING" "$f"
    [ "$status" -ne 0 ]
  done
  # there really are non-roster claude-plugin agents to have checked
  [ "$n" -gt 0 ]
}

@test "#1584 the conductor's run-before-consolidate step is stated EXACTLY ONCE, in reference/review-loop.md" {
  needle='**Decide every `decides:` claim before you consolidate (#1584).**'
  [ "$(grep -cF -- "$needle" "$REFERENCE")" -eq 1 ]
  # the heading both pointers name must exist IN THE TARGET, or they dangle
  [ "$(grep -cF -- "$REF_HEADING" "$REFERENCE")" -eq 1 ]

  # …and nowhere else in the repo: one normative site is the whole point.
  run bash -c "cd '$REPO_ROOT' && git grep -lF -- '$needle' -- ':(exclude)tests/' | sort"
  [ "$status" -eq 0 ]
  [ "$output" = "development/skills/resolve-issue/reference/review-loop.md" ]
}

@test "#1584 every load-bearing clause of the normative step is pinned, SECTION-scoped" {
  sec="$(section_of "$REFERENCE" \
    "$REF_HEADING — run every \`decides:\` command before consolidating (#1584)" '### ')"
  [ -n "$sec" ]
  # Every needle: ONE line, and unique inside the section. A needle written
  # across two source lines becomes a `grep -F` ALTERNATION where either half
  # suffices; a needle that also matches a second sentence keeps passing when
  # the sentence it guards is deleted. `needle_once` enforces both.
  for needle in \
    'After the boundary'\''s **step 4** has observed the gate' \
    'and before the step-2 invocation, which runs' \
    'skip this pass entirely: in both cases the' \
    'On a round the boundary runs with **no gate**' \
    'this section governs' \
    'Run the command AS WRITTEN — never substitute' \
    'settled like an unrunnable one (step 5) rather than run after the mint' \
    're-run the tool'\''s own no-op invocation' \
    'is none of the malformed shapes above, do both' \
    'Run that command in `<worktree_root>`' \
    'rev-parse --show-toplevel' \
    'report it and stop** (never fall back to your own cwd' \
    'The command must be READ-ONLY' \
    'end-of-file-fixer' \
    'Record it** to `<work-dir>/decided-<R>.log`' \
    'one entry per finding, naming' \
    'Truncate it on this round'\''s first entry' \
    'Identical commands are run **once**' \
    'rewrite that finding'\''s `severity` in the aggregate to its' \
    'It now blocks exactly like a reviewer-raised one' \
    'Red means the command RAN and reported a defect' \
    '126/127' \
    'A green verdict never lowers anything' \
    'that is **not** a red' \
    'no `proposed-severity:` line' \
    'when that value is exactly `CRITICAL` or `WARNING`' \
    'neither `CRITICAL` nor `WARNING`' \
    'Three malformed shapes promote nothing' \
    'already above `SUGGESTION`' \
    'change no severity in either direction' \
    'name the malformed finding in the log and the round narration' \
    'already decided is not re-decided within the round: skip it' \
    'KNOWN LIMITATION' \
    'nothing re-decides it later (#1647)' \
    'The stamp'"'"'s absence proves nothing' \
    'Do **not** look for the `decides:` line' \
    'do **not** take the carry recovery'"'"'s re-dispatch' \
    'retire every `decides:` command this pass ran' \
    'the one exception to the skip rule above' \
    'stamp it even when no severity' \
    'fourth adjudication guard' \
    'chose not to run' \
    'two kinds of edit to that file, and no others' \
    'One other writer touches the same file, and it is not this pass' \
    'the file you will pass as' \
    'findings-round-<R>.json`: that is the dispatch' \
    'should** still match'
  do
    needle_once 'the decided pass' "$sec" "$needle" || return 1
  done
}

@test "#1584 the evidence file is named identically in the reference, the script and ARCHITECTURE" {
  # `decided-<R>.log` is the pass's audit record, named in three artifacts that no
  # other assertion ties together. Renaming it in one leaves the others telling a
  # reader to look in a file nothing writes. Loop with a per-file diagnostic —
  # bats reports only the source line, which would not say which file drifted.
  log='decided-<R>.log'
  for f in \
    "$REFERENCE" \
    "$REPO_ROOT/development/skills/resolve-issue/scripts/consolidate-findings.zsh" \
    "$REPO_ROOT/ARCHITECTURE.md"
  do
    grep -qF -- "$log" "$f" || {
      printf '%s does not name %s\n' "$f" "$log" >&2
      return 1
    }
  done
}

@test "#1584 docs/explanation/review-loop.md POINTS at the normative step without restating it" {
  # FLATTENED: these are prose sentences, and every one of them is hard-wrapped
  # somewhere. A line-oriented grep against the raw file passes or fails on
  # where the author's wrap happened to land, which is not a property worth
  # gating — and this test was red for exactly that reason once.
  # SECTION-scoped, like every other pointer test here: the paragraph has to sit
  # in the section that describes a round, not merely somewhere on the page.
  flat="$(section_of "$EXPLANATION" '## What one round does' | flatten)"
  [ -n "$flat" ]
  for needle in \
    "\`/development:resolve-issue\` §3.5's round protocol, under" \
    "$POINTER_NAME" \
    'capped at **Suggestion**' \
    'observation vs. execution' \
    'have yet to adopt it, so on those runs nothing caps such a claim' \
    'Closing that split is issue #1644'
  do
    printf '%s' "$flat" | grep -qF -- "$needle" || {
      printf 'the explanation page lost the pointer clause: %s\n' "$needle" >&2
      return 1
    }
  done
  # …and it must not carry the normative needle itself (that is the drift this
  # repo's explanation pages exist to avoid). Checked against the FLATTENED
  # text too, so a re-wrap cannot hide a restatement from this negative.
  run bash -c "printf '%s' \"\$1\" | grep -cF -- '**Decide every \`decides:\` claim before you consolidate (#1584).**'" _ "$flat"
  [ "$output" = "0" ]
}

@test "#1584 the claude-plugin resolve profile points at both halves rather than restating them" {
  [ -f "$PROFILE" ]
  # SECTION-scoped to `## Panel`: the pointer has to live in the heading that
  # records the panel, or `tests/resolve-profile-contract.bats`'s Panel contract
  # names a section that points nowhere. A file-wide grep would stay green with
  # the pointer moved into `## Gate`.
  section="$(section_of "$PROFILE" '## Panel')"
  [ -n "$section" ]
  flat="$(printf '%s' "$section" | flatten)"
  for needle in \
    'tools: Read, Grep, Glob' \
    'development/skills/resolve-issue/reference/review-loop.md' \
    "$POINTER_NAME"
  do
    printf '%s' "$flat" | grep -qF -- "$needle" || {
      printf 'the profile Panel section lost the pointer clause: %s\n' "$needle" >&2
      return 1
    }
  done
  # a pointer, not a copy
  run grep -cF -- "$HEADING" "$PROFILE"
  [ "$output" = "0" ]
  # …and the #1505 Panel ban still holds: no severity word may appear there.
  # The capture was asserted non-empty above — a negative assertion over a
  # capture that could not have held the needle proves nothing.
  run bash -c "printf '%s' \"\$1\" | grep -cwE 'CRITICAL|WARNING|SUGGESTION'" _ "$section"
  [ "$output" = "0" ]
}

@test "#1584 ROSTER TRIPWIRE: MAINTAINING's row states the derived count, and it is the derived count" {
  # The count is transcribed in prose at three sites while only this file derives
  # it, so a sixth read-only reviewer would red HERE and leave the prose stale.
  # Read the figure back OUT of the registry row and compare, the way the sibling
  # invariants do — three numbers then move together or the PR reds.
  local maint row derived stated
  maint="$REPO_ROOT/MAINTAINING.md"
  [ -f "$maint" ]
  row="$(grep -F -- '**#1584 evidence rule**' "$maint")"
  [ -n "$row" ] || { echo "MAINTAINING.md has no #1584 evidence rule row" >&2; return 1; }

  derived="$(read_only_agents_in "$AGENT_DIR" | wc -l | tr -d ' ')"
  [ "$derived" -eq "$EXPECTED_COUNT" ]

  # the row states "gated == roster == N"
  stated="$(printf '%s' "$row" | grep -oE 'gated == roster == [0-9]+' | grep -oE '[0-9]+$')"
  [ -n "$stated" ] || {
    echo "the #1584 row states no 'gated == roster == N' figure" >&2; return 1; }
  [ "$stated" -eq "$derived" ] || {
    printf 'MAINTAINING says %s, the frontmatter derives %s\n' "$stated" "$derived" >&2
    return 1
  }
}

@test "#1584 both touched plugins' manifests are in lockstep with the marketplace" {
  market="$REPO_ROOT/.claude-plugin/marketplace.json"
  for p in development development-claude-plugin; do
    pj="$(jq -r .version "$REPO_ROOT/$p/.claude-plugin/plugin.json")"
    mv_="$(jq -r --arg n "$p" '.plugins[] | select(.name == $n) | .version' "$market")"
    # `jq -r` prints the STRING "null" for a missing key, so a non-empty test
    # alone would pass on "null" = "null" — i.e. on both sides having no version.
    #
    # ONE ASSERTION PER LINE, never `[ … ] && [ … ]`: the left operand of an
    # AND-list is exempt from errexit, so joining them would make the non-empty
    # half assert nothing and an empty-string pair would compare equal and pass.
    [ -n "$pj" ]
    [ "$pj" != "null" ]
    [ -n "$mv_" ]
    [ "$mv_" != "null" ]
    [ "$pj" = "$mv_" ] || {
      printf '%s: plugin.json %s != marketplace.json %s\n' "$p" "$pj" "$mv_" >&2
      return 1
    }
  done
}
