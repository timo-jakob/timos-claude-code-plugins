#!/usr/bin/env bats
#
# #1584 — a read-only reviewer's tool-verdict claim is a SUGGESTION until the
# conductor runs the tool.
#
# Two halves, and this file guards both:
#
#   1. Every read-only reviewer in the repo (every tracked `*/agents/*.md`
#      whose frontmatter tool set normalises to `Read, Grep, Glob`, so it can
#      read and grep but cannot EXECUTE a linter, a suite, a validator or a
#      version-sync script) states the evidence rule under a heading naming it,
#      tells the reviewer to name the deciding command, and gives those lines a
#      slot in its Reporting Format — unless it is listed, with a reason, in
#      tests/reviewer-evidence-rule.exemptions (#1644).
#   2. The conductor's run-the-command-before-consolidating step is stated
#      EXACTLY ONCE, in development/skills/resolve-issue/reference/review-loop.md,
#      and docs/explanation/review-loop.md points at it instead of restating it.
#
# The roster in half 1 is DERIVED from the frontmatter, never a hard-coded list:
# a closed list rots the moment another read-only reviewer is added, and the new
# agent would then carry no evidence rule with every test still green. The
# derived set is additionally compared against the roster known today, so ADDING
# a read-only reviewer is a deliberate, visible edit to this file.
#
# The sweep is REPO-WIDE (#1644): `git ls-files '*/agents/*.md'`, not a path
# glob, so a reviewer added under any plugin is in the roster the moment it is
# tracked. `tests/` is excluded — a fixture agent there is test data, not a
# shipped reviewer. The set is never implicitly split: a derived agent either
# carries the rule or is named, with a reason, in the exemption list, and the
# list is gated both ways (a stale or unreasoned entry reds, and so does an
# exempted agent that carries the rule anyway).
#
# NEEDLES ARE SECTION-SCOPED, NOT FILE-WIDE. These sections are maintained
# as byte-identical copies, so the realistic edit is a UNIFORM one, and a
# file-wide grep cannot tell "the clause is in the evidence rule" from "the
# clause is anywhere in a 200-line agent". Matching file-wide would let the
# fenced `decides:` block be moved out of the section into Reporting Format with
# every test still green — while AC 1 requires the rule *under a heading naming
# it*.

bats_require_minimum_version 1.5.0

setup() {
  # git exports these inside hooks and `git rebase --exec`; `-C` does not
  # override them, so the fixture repo's init/add would hit the REAL index.
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # repo-relative, so the non-vacuity fixture can resolve it inside its own tree
  EXEMPTIONS_REL='tests/reviewer-evidence-rule.exemptions'
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
  # The read-only agents known today, repo-relative, in `LC_ALL=C sort` order.
  # Compared against the derived set, so an addition is a visible edit here.
  EXPECTED_ROSTER="development-claude-plugin/agents/claude-plugin-contract-integrity.md
development-claude-plugin/agents/claude-plugin-manifest-check.md
development-claude-plugin/agents/claude-plugin-prose-logic.md
development-claude-plugin/agents/claude-plugin-script-reviewer.md
development-claude-plugin/agents/claude-plugin-test-reviewer.md
development-go/agents/go-bug-hunter.md
development-go/agents/go-code-quality.md
development-go/agents/go-performance-reviewer.md
development-go/agents/go-resilience-reviewer.md
development-go/agents/go-security-reviewer.md
development-go/agents/go-test-reviewer.md
development-java/agents/java-bug-hunter.md
development-java/agents/java-code-quality.md
development-java/agents/java-performance-reviewer.md
development-java/agents/java-resilience-reviewer.md
development-java/agents/java-security-reviewer.md
development-java/agents/java-test-reviewer.md
development-kubernetes/agents/argocd-advisor.md
development-kubernetes/agents/kubernetes-reliability-reviewer.md
development-kubernetes/agents/kubernetes-security-reviewer.md
development-opentofu/agents/opentofu-module-advisor.md
development-opentofu/agents/opentofu-security-reviewer.md
development-python/agents/python-bug-hunter.md
development-python/agents/python-code-quality.md
development-python/agents/python-performance-reviewer.md
development-python/agents/python-resilience-reviewer.md
development-python/agents/python-security-reviewer.md
development-python/agents/python-test-reviewer.md
development-swift/agents/bug-hunter.md
development-swift/agents/code-quality.md
development-swift/agents/performance-reviewer.md
development-swift/agents/security-reviewer.md
development-swift/agents/swift-resilience-reviewer.md
development-swift/agents/test-reviewer.md
development/agents/bootstrap-config-consistency.md
development/agents/bootstrap-idempotency-reviewer.md
development/agents/bootstrap-security-reviewer.md"
  EXPECTED_COUNT=37
}

# Print every tracked agent file in the git work tree $1, repo-relative, sorted.
# `tests/` is excluded: an agent there is a fixture, not a shipped reviewer.
agent_files_in() {
  git -C "$1" ls-files -- '*/agents/*.md' ':(exclude)tests/' | LC_ALL=C sort
}

# Print the normalised tool set of the agent file $1 (sorted, space-joined, with
# a trailing space), or nothing when the frontmatter declares no `tools:` key.
tool_set_of() {
  awk -F': *' '
    /^---$/ { n++; if (n == 2) exit; next }
    n == 1 && /^tools:/ { print $2; exit }
  ' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' | LC_ALL=C sort | tr '\n' ' '
}

# Print the repo-relative path of every agent in the git work tree $1 whose
# frontmatter declares the read-only tool set. One definition, used by the real
# sweep AND by the non-vacuity fixtures below, so they can never test different
# rules.
#
# The tool set is NORMALISED (split on commas, trimmed, sorted) rather than
# matched as a literal line: `tools: Glob, Grep, Read` is the same read-only
# agent as `tools: Read, Grep, Glob`, and a spelling-exact grep would make a
# reordered new agent invisible to BOTH this sweep and the roster tripwire —
# it would ship with no evidence rule and the suite would stay green.
# The roster comes from `git ls-files`, not a directory glob, so no plugin and
# no basename convention can hide a reviewer from it (#1644).
read_only_agents_in() {
  local root="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$(tool_set_of "$root/$f")" = "Glob Grep Read " ] || continue
    printf '%s\n' "$f"
  done < <(agent_files_in "$root")
}

# Print the path of every entry in the work tree $1's exemption list, sorted.
exempt_agents_in() {
  local file="$1/$EXEMPTIONS_REL"
  [ -f "$file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$file" \
    | sed 's/[[:space:]]*|.*$//; s/^[[:space:]]*//' | LC_ALL=C sort
}

# Print every derived read-only agent that is NOT exempt: the rule's carriers.
carriers_in() {
  local root="$1" a exempt
  exempt="$(exempt_agents_in "$root")"
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    printf '%s\n' "$exempt" | grep -qxF -- "$a" && continue
    printf '%s\n' "$a"
  done < <(read_only_agents_in "$root")
}

# Print every carrier in $1 that is MISSING the evidence rule heading. Empty
# output = the sweep passes.
missing_evidence_rule_in() {
  local root="$1" a
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    grep -qF -- "$HEADING" "$root/$a" || printf '%s\n' "$a"
  done < <(carriers_in "$root")
}

# Print one line per defect in the work tree $1's exemption list. Empty output =
# the list is sound. Gated BOTH ways against the derived roster: an entry naming
# no derived agent is stale (it would silently exempt whatever later takes the
# path), an entry with no reason is not "an explicit, reasoned exemption", and an
# exempted agent that carries the rule anyway makes the list lie about the set.
exemption_problems_in() {
  local root="$1" file="$1/$EXEMPTIONS_REL" roster line path reason
  [ -f "$file" ] || { printf 'no exemption list at %s\n' "$EXEMPTIONS_REL"; return 0; }
  roster="$(read_only_agents_in "$root")"
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *' | '*) ;;
      *) printf 'malformed (want "<path> | <reason>"): %s\n' "$line"; continue ;;
    esac
    path="${line%% | *}"
    reason="${line#* | }"
    reason="$(printf '%s' "$reason" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$reason" ] || printf 'no reason given: %s\n' "$path"
    printf '%s\n' "$roster" | grep -qxF -- "$path" \
      || printf 'not a derived read-only agent: %s\n' "$path"
    if [ -f "$root/$path" ] && grep -qF -- "$HEADING" "$root/$path"; then
      printf 'exempt but carries the rule: %s\n' "$path"
    fi
  done < "$file"
}

# Build a throwaway git work tree under $1 holding every tracked agent file and
# the exemption list, at their real repo-relative paths, so the SAME roster
# functions can be driven over a mutated copy. Prints nothing.
make_fixture_repo() {
  local dest="$1" f
  mkdir -p "$dest"
  git -C "$dest" init -q
  while IFS= read -r f; do
    mkdir -p "$dest/$(dirname "$f")"
    cp -- "$REPO_ROOT/$f" "$dest/$f"
  done < <(agent_files_in "$REPO_ROOT")
  mkdir -p "$dest/tests"
  cp -- "$REPO_ROOT/$EXEMPTIONS_REL" "$dest/$EXEMPTIONS_REL"
  git -C "$dest" add -A
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

@test "#1644 the read-only reviewer roster is derived repo-wide, non-empty, and is the set known today" {
  # This is ALSO the non-vacuity control for every loop in this file: a broken
  # `git ls-files`, a wrong REPO_ROOT, or a frontmatter change that hides an
  # agent reds here rather than silently emptying the sweeps below.
  run read_only_agents_in "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" = "$EXPECTED_ROSTER" ] || {
    diff <(printf '%s\n' "$EXPECTED_ROSTER") <(printf '%s\n' "$output") >&2
    return 1
  }
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq "$EXPECTED_COUNT" ]
  # repo-wide really means beyond the plugin panel #1584 started from
  printf '%s\n' "$output" | grep -qv '^development-claude-plugin/'
}

@test "#1644 every read-only reviewer states the evidence rule under a heading naming it, unless exempted" {
  run missing_evidence_rule_in "$REPO_ROOT"
  [ "$status" -eq 0 ]
  # Name the offenders rather than just failing a count.
  [ -z "$output" ] || {
    printf 'agents missing the evidence rule (add it, or exempt them with a reason): %s\n' "$output" >&2
    return 1
  }
  # the carriers are the roster minus the exemptions — never an empty set
  [ -n "$(carriers_in "$REPO_ROOT")" ]
}

@test "#1644 the exemption list is sound: every entry is a derived agent, reasoned, and does not carry the rule" {
  [ -f "$REPO_ROOT/$EXEMPTIONS_REL" ]
  run exemption_problems_in "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
  # carriers + exemptions partition the roster exactly
  local carriers exempt
  carriers="$(carriers_in "$REPO_ROOT" | wc -l | tr -d ' ')"
  exempt="$(exempt_agents_in "$REPO_ROOT" | wc -l | tr -d ' ')"
  [ "$exempt" -gt 0 ]
  [ $((carriers + exempt)) -eq "$EXPECTED_COUNT" ]
}

@test "#1644 NON-VACUITY: the same sweep fails an agent that lacks the section, and a NEW read-only agent" {
  # Copy the real agents into a throwaway git tree, mutate it, and run the SAME
  # functions. If the sweep were vacuous (a pathspec that matches nothing, a grep
  # that always succeeds), this would pass silently and the tests above would
  # prove nothing.
  fixture="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$fixture"
  # the copy must still yield the full roster and a clean sweep, or the control
  # proves nothing
  [ "$(read_only_agents_in "$fixture")" = "$EXPECTED_ROSTER" ]
  [ -z "$(missing_evidence_rule_in "$fixture")" ]

  # (a) strip the section from one carrier OUTSIDE the plugin panel
  victim="development-python/agents/python-test-reviewer.md"
  awk -v h="$HEADING" '
    $0 == h { skipping = 1 }
    skipping && /^## / && $0 != h { skipping = 0 }
    !skipping { print }
  ' "$fixture/$victim" > "$fixture/$victim.stripped"
  mv -- "$fixture/$victim.stripped" "$fixture/$victim"
  run grep -qF -- "$HEADING" "$fixture/$victim"
  [ "$status" -ne 0 ]   # the strip really happened

  run missing_evidence_rule_in "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "$victim" ]

  # (b) a brand-new read-only agent in a plugin the roster has never seen, with a
  # reordered tool list and no rule, is swept in the moment it is tracked
  mkdir -p "$fixture/development-newlang/agents"
  printf -- '---\nname: newlang-bug-hunter\ntools: Glob,Read , Grep\n---\n\n## Reporting Format\n' \
    > "$fixture/development-newlang/agents/newlang-bug-hunter.md"
  git -C "$fixture" add -A
  run missing_evidence_rule_in "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "development-newlang/agents/newlang-bug-hunter.md
$victim" ]
}

@test "#1644 NON-VACUITY: the exemption check reds on a stale, an unreasoned, a malformed and a rule-carrying entry" {
  fixture="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$fixture"
  [ -z "$(exemption_problems_in "$fixture")" ]
  list="$fixture/$EXEMPTIONS_REL"

  # stale: names no derived agent
  printf 'development-go/agents/go-no-such-reviewer.md | gone\n' >> "$list"
  run exemption_problems_in "$fixture"
  [ "$output" = "not a derived read-only agent: development-go/agents/go-no-such-reviewer.md" ]

  # an entry naming an agent that holds Bash is not in the roster either
  cp -- "$REPO_ROOT/$EXEMPTIONS_REL" "$list"
  printf 'development/agents/story-readiness.md | holds Bash\n' >> "$list"
  run exemption_problems_in "$fixture"
  [ "$output" = "not a derived read-only agent: development/agents/story-readiness.md" ]

  # unreasoned
  cp -- "$REPO_ROOT/$EXEMPTIONS_REL" "$list"
  printf 'development-go/agents/go-bug-hunter.md |  \n' >> "$list"
  run exemption_problems_in "$fixture"
  printf '%s\n' "$output" | grep -qxF 'no reason given: development-go/agents/go-bug-hunter.md'

  # malformed: no separator at all
  cp -- "$REPO_ROOT/$EXEMPTIONS_REL" "$list"
  printf 'development-go/agents/go-bug-hunter.md\n' >> "$list"
  run exemption_problems_in "$fixture"
  printf '%s\n' "$output" | grep -qF 'malformed'

  # exempt but carrying the rule — and exempting it really removes it from the
  # carriers, so the missing-rule sweep would no longer have looked at it
  cp -- "$REPO_ROOT/$EXEMPTIONS_REL" "$list"
  printf 'development-go/agents/go-bug-hunter.md | a reason\n' >> "$list"
  run exemption_problems_in "$fixture"
  [ "$output" = "exempt but carries the rule: development-go/agents/go-bug-hunter.md" ]
  run carriers_in "$fixture"
  printf '%s\n' "$output" | grep -qxF 'development-go/agents/go-bug-hunter.md' && return 1
  true
}

@test "#1584 the evidence rule is stated identically in every carrier, so it cannot drift apart" {
  # The copies are one rule restated per agent (the same shape the severity
  # bars use). Byte-identity of the section is what keeps them one rule.
  ref=""
  n=0
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    n=$((n + 1))
    section="$(section_of "$REPO_ROOT/$a" "$HEADING")"
    [ -n "$section" ]
    if [ -z "$ref" ]; then
      ref="$section"
    else
      [ "$section" = "$ref" ] || {
        printf 'evidence rule in %s differs from the first agent\n' "$a" >&2
        return 1
      }
    fi
  done < <(carriers_in "$REPO_ROOT")
  [ "$n" -eq "$(carriers_in "$REPO_ROOT" | wc -l | tr -d ' ')" ]
  [ "$n" -gt 0 ]
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
    section="$(section_of "$REPO_ROOT/$a" "$HEADING")"
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
  done < <(carriers_in "$REPO_ROOT")
  [ "$n" -gt 0 ]
}

@test "#1584 each carrier's Reporting Format gives the two lines a slot" {
  # Without a slot in the template the rule is advisory: a model filling in the
  # Reporting Format has nowhere to put the two lines the conductor keys on, and
  # emits a capped finding nothing ever settles. Section-scoped to Reporting
  # Format, so a copy of the lines elsewhere in the file does not satisfy it.
  n=0
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    n=$((n + 1))
    rf="$(section_of "$REPO_ROOT/$a" '## Reporting Format')"
    [ -n "$rf" ] || { printf '%s: no Reporting Format section\n' "$a" >&2; return 1; }
    printf '%s' "$rf" | grep -qF 'decides: <the command that settles it>' || {
      printf '%s: Reporting Format has no decides: slot\n' "$a" >&2; return 1; }
    printf '%s' "$rf" | grep -qF 'proposed-severity: CRITICAL|WARNING' || {
      printf '%s: Reporting Format has no proposed-severity: slot\n' "$a" >&2; return 1; }
  done < <(carriers_in "$REPO_ROOT")
  [ "$n" -gt 0 ]
}

@test "#1644 every agent OUTSIDE the roster can actually run tools, and carries no evidence rule" {
  # The rule exists because the agent cannot execute, so an agent holding Bash is
  # rightly outside it. Assert that POSITIVELY: checking only "not in the roster,
  # and has no rule" would silently bless an agent declaring `tools: Read, Grep`
  # — read-only, just not the exact three — which falls out of the roster, escapes
  # the EXPECTED_ROSTER tripwire, and ships with no evidence rule while this test
  # reports it as correctly excluded. That is the file's own closed-set rot, one
  # level down.
  roster="$(read_only_agents_in "$REPO_ROOT")"
  [ -n "$roster" ]
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$roster" | grep -qxF -- "$f" && continue
    n=$((n + 1))
    tools="$(tool_set_of "$REPO_ROOT/$f")"
    # an EMPTY set may only mean "no tools: key": a key the parser could not read
    # (a YAML block list) must not pass as inherit-everything
    [ -n "$tools" ] || ! awk '/^---$/ { n++; if (n == 2) exit; next } n == 1 && /^tools:/ { found = 1 } END { exit !found }' "$REPO_ROOT/$f" || {
      printf '%s declares a tools: key this sweep cannot parse\n' "$f" >&2
      return 1
    }
    # either it declares Bash, or it declares no tools: key at all (inheriting
    # everything, which includes Bash)
    if [ -n "$tools" ]; then
      printf '%s' "$tools" | grep -qw 'Bash' || {
        printf '%s is neither read-only-with-the-rule nor Bash-holding: tools: %s\n' \
          "$f" "$tools" >&2
        return 1
      }
    fi
    run grep -qF -- "$HEADING" "$REPO_ROOT/$f"
    [ "$status" -ne 0 ]
  done < <(agent_files_in "$REPO_ROOT")
  # there really are non-roster agents to have checked
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
    "ships with every panel's read-only reviewers" \
    'tests/reviewer-evidence-rule.exemptions'
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
  # #1644: the split is closed, so no text on the WHOLE page (not just this
  # section) may still describe the reviewer half as partly adopted. The page is
  # asserted non-empty first: a negative over an empty capture proves nothing.
  whole="$(flatten < "$EXPLANATION")"
  [ -n "$whole" ]
  for stale in 'different rates' 'yet to adopt' 'Closing that split'; do
    run bash -c "printf '%s' \"\$1\" | grep -ciF -- \"\$2\"" _ "$whole" "$stale"
    [ "$output" = "0" ] || {
      printf 'the explanation page still describes a partial adoption: %s\n' "$stale" >&2
      return 1
    }
  done
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

@test "#1644 ROSTER TRIPWIRE: MAINTAINING's row states the derived counts, and they are the derived counts" {
  # The counts are transcribed in prose while only this file derives them, so a
  # new read-only reviewer (or a new exemption) would red HERE and leave the
  # prose stale. Read the figures back OUT of the registry row and compare, the
  # way the sibling invariants do — the numbers then move together or the PR reds.
  local maint row roster gated stated_roster stated_gated
  maint="$REPO_ROOT/MAINTAINING.md"
  [ -f "$maint" ]
  row="$(grep -F -- '**#1584 evidence rule**' "$maint")"
  [ -n "$row" ] || { echo "MAINTAINING.md has no #1584 evidence rule row" >&2; return 1; }

  roster="$(read_only_agents_in "$REPO_ROOT" | wc -l | tr -d ' ')"
  [ "$roster" -eq "$EXPECTED_COUNT" ]
  gated="$(carriers_in "$REPO_ROOT" | wc -l | tr -d ' ')"
  [ "$gated" -gt 0 ]

  # the row states "roster == N" and "gated == M"
  stated_roster="$(printf '%s' "$row" | grep -oE 'roster == [0-9]+' | grep -oE '[0-9]+$')"
  stated_gated="$(printf '%s' "$row" | grep -oE 'gated == [0-9]+' | grep -oE '[0-9]+$')"
  [ -n "$stated_roster" ] || {
    echo "the #1584 row states no 'roster == N' figure" >&2; return 1; }
  [ -n "$stated_gated" ] || {
    echo "the #1584 row states no 'gated == M' figure" >&2; return 1; }
  [ "$stated_roster" -eq "$roster" ] || {
    printf 'MAINTAINING says roster %s, the frontmatter derives %s\n' "$stated_roster" "$roster" >&2
    return 1
  }
  [ "$stated_gated" -eq "$gated" ] || {
    printf 'MAINTAINING says gated %s, roster minus exemptions is %s\n' "$stated_gated" "$gated" >&2
    return 1
  }
}

@test "#1644 every touched plugin's manifest is in lockstep with the marketplace" {
  market="$REPO_ROOT/.claude-plugin/marketplace.json"
  for p in development development-claude-plugin development-go development-java \
    development-kubernetes development-python development-swift; do
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
