#!/usr/bin/env bats
#
# #3157 — the review severity contract, stated once in ARCHITECTURE.md before
# any reviewer changes (#3122 child 0). A reviewer reports only what blocks;
# SUGGESTION survives in two reviewer lanes only (an evidence-capped tool claim
# carrying `decides:`, and a scope-bounded defect carrying `follow-up:`); and
# the consolidator discards a reviewer-emitted Low that carries neither line.
#
# Every needle is anchored by its section HEADING and quoted text, never by a
# line number, and is matched against the section FLATTENED to single spaces,
# so a re-wrap of the prose cannot move a needle off its sentence. Each section
# is asserted non-empty first: a negative over an empty capture proves nothing.

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  EXPLANATION="$REPO_ROOT/docs/explanation/review-loop.md"
}

# Flatten stdin to one line with single spaces.
flatten() {
  LC_ALL=C tr -s '[:space:]' ' '
}

# The body of the `###` section whose heading line starts with $2, up to the
# next `##` or `###` heading, so the range closes on the enclosing level too.
arch_section() {
  awk -v h="$2" 'index($0, h) == 1 { f = 1; next } f && /^###? / { exit } f' "$1"
}

# The consolidator bullet: from its opening line to the next top-level bullet.
consolidator_bullet() {
  awk '/^- \*\*`consolidate-findings\.zsh`\*\* is the deterministic engine/ { f = 1; print; next }
       f && /^- \*\*/ { exit } f' "$ARCH"
}

@test "#3157 Terminating severity bars states the reviewer reports only what blocks, with two SUGGESTION lanes" {
  local flat
  flat="$(arch_section "$ARCH" '### Terminating severity bars (#1433)' | flatten)"
  [ -n "$flat" ]
  contains "$flat" '**A reviewer reports only what blocks: `CRITICAL` or `WARNING`. A plain observation below the bar is not reported.**'
  contains "$flat" '`SUGGESTION` survives in two reviewer lanes only: the evidence-capped severity of a tool-verdict claim that carries `decides:` / `proposed-severity:` (#1584, the evidence rule below), which the decided pass can still raise on a real red; and a scope-bounded defect that carries a `follow-up:` line (*Scope-bounded severity* above).'
  contains "$flat" 'a finding a bar demotes below `WARNING` — the delta-round rule below included — is not reported unless it falls in one of the two lanes.'
  # every panel's reviewers follow the contract since #3167, the last of
  # #3158–#3167, so the staging sentence is gone
  contains "$flat" "That rule holds for every panel's reviewers, whether or not they carry a bar."
  lacks "$flat" 'follow this contract yet'
  lacks "$flat" 'until children #3159–#3167'
  # the development-react panel no longer fixes a check at SUGGESTION (#3166)
  lacks "$flat" 'panel still fixes one check at `SUGGESTION`'
  lacks "$flat" 'still pins the agents to the earlier report-as-'
  # the delta-round rule demotes below the bar, not to a reported SUGGESTION
  contains "$flat" 'demotes an untested branch or an unpinned sentence below the bar when it lies inside a range the previous fix pass **added**'
  lacks "$flat" 'still reported and logged in the dossier, so no dimension loses coverage.'
  lacks "$flat" 'demotes an untested branch or an unpinned sentence to `SUGGESTION`'
}

@test "#3157 Scope-bounded severity states the follow-up: lane and the rewritten Nothing is lost sentence" {
  local flat
  flat="$(arch_section "$ARCH" '### Scope-bounded severity (#982)' | flatten)"
  [ -n "$flat" ]
  contains "$flat" '**A pre-existing defect that would block, but whose only correct fix expands the change beyond the story scope**'
  contains "$flat" '**is reported at `SUGGESTION` with a Description line `follow-up: <the defect, in one line>`.**'
  contains "$flat" 'Such a finding never blocks a round, and the dossier lists it under *Suggested follow-ups*.'
  # the dossier section is staged: #3170 adds it
  contains "$flat" 'That dossier section is not built yet: #3170 adds it to `build-dossier.zsh`, and until then the finding appears in the dossier'"'"'s **Waived suggestions** list.'
  contains "$flat" 'whose Low filter keeps a Low carrying a `follow-up:` line once #3169 lands'
  contains "$flat" 'A plain out-of-diff observation below the bar is not reported at all.'
  contains "$flat" 'Nothing blocking-grade is lost, because the defect rides into the dossier under *Suggested follow-ups* as a non-blocking Low; only an observation that would not block anyway is dropped.'
  # the three carve-outs are unchanged
  contains "$flat" '**Three carve-outs keep this from muzzling real blockers.**'
  contains "$flat" '(1) **Tests and coverage for the change under review are always in-scope**'
  contains "$flat" "(2) A **defect the change under review *introduces*** is always in-scope"
  contains "$flat" "(3) When the reviewer is **not given the issue's stated scope**"
  # the retired wording is gone
  lacks "$flat" 'spin off a follow-up issue'
  lacks "$flat" 'Nothing is lost (the observation still rides into the dossier as a suggestion)'
}

@test "#3157 the consolidator paragraph states the Low filter and names the follow-up: lane" {
  local flat
  flat="$(consolidator_bullet | flatten)"
  [ -n "$flat" ]
  contains "$flat" '`WARNING→High`, `SUGGESTION→Low`'
  contains "$flat" '`consolidate-findings.zsh` discards a reviewer-emitted Low with neither `decides:` nor `follow-up:`, keeps one that carries either line (never as a blocker), and never discards a risk-demoted item (`demoted: true`), which the consolidator writes itself — child 12 of #3122 (#3169) implements it'
  contains "$flat" 'a scope-bounded defect a reviewer reported in the `follow-up:` lane per *Scope-bounded severity* above rides into the dossier without ever forcing a round'
  lacks "$flat" 'reviewer downgraded to `SUGGESTION` per *Scope-bounded severity*'
}

@test "#3157 the review-loop explanation describes no waived suggestion as a reviewer output" {
  local flat
  flat="$(flatten < "$EXPLANATION")"
  [ -n "$flat" ]
  contains "$flat" 'A reviewer reports blockers (Critical + Warning), evidence-capped tool claims and scope-bounded follow-ups only'
  contains "$flat" '## Suggested follow-ups'
  contains "$flat" 'A reviewer reports blockers, evidence-capped tool claims and scope-bounded follow-ups only; a plain observation below the bar is not reported at all.'
  contains "$flat" 'is reported with a one-line `follow-up:` note, so the PR'"'"'s review dossier lists it under *Suggested follow-ups* rather than spending a round on work the story never asked for.'
  # the one staged part names the child that ships it; every panel's
  # reviewers follow the contract since #3167
  contains "$flat" 'This is the contract the loop is moving to, and one part of it has not shipped yet. The dossier has no *Suggested follow-ups* section until #3170 lands, so until then such a defect appears in the dossier'"'"'s **Waived suggestions** list.'
  lacks "$flat" 'reviewers still report below-the-bar observations as suggestions'
  lacks "$flat" 'two parts of it have not shipped yet'
  # the risk-demoted paragraph stays
  contains "$flat" 'is **demoted to a suggestion**: logged in the round'
  # the retired reviewer-output wording, one needle per rewritten passage
  lacks "$flat" '## Promoting a suggestion'
  lacks "$flat" 'split into **blockers** (Critical + Warning) and **Suggestions**'
  lacks "$flat" 'a green leaves it a logged suggestion'
  lacks "$flat" 'suggestions earlier rounds already surfaced and you already let go'
  lacks "$flat" 'An already-waived suggestion re-raised'
  lacks "$flat" 'Suggestions remaining is still converged, and the run waives them'
  lacks "$flat" 'every one the panel raised has been **waived**'
}

@test "#3157 the per-panel adjudicated_path needle is retired; the panel-duties one stays" {
  local f="$REPO_ROOT/tests/review-loop-budget-consistency.bats" n
  [ -f "$f" ]
  # the ARCHITECTURE.md panel-duties needle stays until #3168
  n="$(grep -cF "grep_site \"\$ARCH_PANEL_DUTIES\" 'adjudicated_path'" "$f")"
  [ "$n" -eq 1 ]
  # the per-panel prompt-line needle is gone
  n="$(grep -cF "grep_site \"\$REPO_ROOT/\$panel\" 'adjudicated_path'" "$f" || true)"
  [ "$n" -eq 0 ]
}

# The Go panel (#3160): the six read-only reviewers report only what blocks.
# Each reviewer's Reporting Format is the file's last section, so the capture
# runs from its heading to EOF.
go_format() {
  awk '/^## Reporting Format$/ { f = 1; next } f' "$1" | flatten
}

@test "#3160 the six Go reviewers drop plain SUGGESTION and keep only their SUGGESTION lanes" {
  local a f flat format n want
  for a in go-bug-hunter go-code-quality go-performance-reviewer go-resilience-reviewer go-security-reviewer go-test-reviewer; do
    f="$REPO_ROOT/development-go/agents/$a.md"
    flat="$(flatten <"$f")"
    format="$(go_format "$f")"
    [ -n "$format" ]
    lacks "$format" '**SUGGESTION:**'
    # Whole-file invariant: SUGGESTION appears only on the lines of its lanes
    # (evidence rule, template title, severity-set line(s), the reserved-for
    # sentence, and go-test-reviewer's scope-bounded follow-up). Any new
    # SUGGESTION route, however spelled, moves this count.
    want=6
    [ "$a" = go-test-reviewer ] && want=8
    n="$(grep -c SUGGESTION "$f")"
    [ "$n" -eq "$want" ]
    contains "$format" 'An observation below the blocking bar is not reported.'
    contains "$format" '### [CRITICAL|WARNING|SUGGESTION] Title'
    contains "$format" 'decides: <the command that settles it> proposed-severity: CRITICAL|WARNING'
    if [ "$a" = go-test-reviewer ]; then
      contains "$format" '`SUGGESTION` is reserved for the two lanes of ARCHITECTURE.md *Terminating severity bars*: a tool-verdict claim capped by the evidence rule above, and a scope-bounded follow-up under *Scope-bounded severity* below.'
      contains "$format" 'decides: <the command that settles it> proposed-severity: CRITICAL|WARNING — or, for a scope-bounded follow-up (*Scope-bounded severity* below), this one line appended to the **Description** field, with the severity set to SUGGESTION: follow-up: <the defect, in one line>'
    else
      contains "$format" '`SUGGESTION` is reserved for a tool-verdict claim capped by the evidence rule above, the one lane of ARCHITECTURE.md *Terminating severity bars* this agent carries.'
      lacks "$flat" 'follow-up:'
    fi
  done
}

@test "#3160 go-resilience-reviewer does not report a violation it cannot prove" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-go/agents/go-resilience-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'If a wrapper you cannot see might already supply the timeout or breaker, and you cannot name the failure, do not report it; do not assert a violation you cannot prove.'
  lacks "$flat" 'drop to SUGGESTION'
}

@test "#3160 go-security-reviewer does not report a trusted-input or unreachable sink" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-go/agents/go-security-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'If input is trusted or the sink is unreachable, do not report it.'
  contains "$flat" 'Exploitable under specific conditions, or a defense-in-depth gap: a control the change removes or weakens.'
  contains "$flat" 'Hardening that only adds a new layer, with no attack path you can name, is below the bar and not reported.'
  contains "$flat" 'In a module whose `go` directive is 1.22 or later this is **pinning/hardening, not exposure**, and is not reported'
  contains "$flat" 'In a module whose `go` directive is below 1.22, a server `tls.Config` without `MinVersion` still accepts TLS 1.0/1.1: report it.'
  lacks "$flat" 'say so and downgrade'
  lacks "$flat" 'Only a finding with a plausible path from untrusted input'
}

@test "#3160 go-code-quality does not report style or idiom alone" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-go/agents/go-code-quality.md")"
  [ -n "$flat" ]
  contains "$flat" 'Style or idiom alone is below the bar and not reported, unless it misleads a caller or harms maintainability at a cost you can name.'
  contains "$flat" 'A nit that does not change how the code reads is below the bar and not reported.'
}

@test "#3160 go-test-reviewer, go-bug-hunter and go-performance-reviewer do not report their named sub-bar items" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-go/agents/go-test-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'The debuggability and speed checks above — `t.Helper()`, the case name in `t.Errorf`, `t.Run` subtests, `t.Parallel()` for speed, `-coverpkg` — are below the bar and not reported, unless you can name the regression or the flakiness they let through.'
  flat="$(flatten <"$REPO_ROOT/development-go/agents/go-bug-hunter.md")"
  [ -n "$flat" ]
  contains "$flat" 'a performance nit, never a leak, so it is below the bar and not reported.'
  flat="$(flatten <"$REPO_ROOT/development-go/agents/go-performance-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'an allocation finding is speculation, below the bar and not reported.'
}

@test "#3160 go-test-reviewer's Scope-bounded severity reports the follow-up lane and keeps its three carve-outs" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-go/agents/go-test-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'A finding blocks (CRITICAL/WARNING) only when its fix stays within the issue'"'"'s stated scope. A pre-existing defect that would block, but whose only correct fix expands the change beyond that scope, is reported at **SUGGESTION** with a Description line `follow-up: <the defect, in one line>`, and it never blocks a round. A plain out-of-diff observation below the bar is not reported.'
  lacks "$flat" 'spin off a follow-up issue'
  contains "$flat" 'Three carve-outs keep this from muzzling real blockers. **(1) Tests and coverage for the change under review are always in-scope**'
  contains "$flat" '**(2) A defect the change under review *introduces* is always in-scope**'
  contains "$flat" "**(3) When the issue's stated scope is not provided in your prompt**"
}

@test "#3160 the Go panel carries no waived list and reports only capped claims and follow-ups below WARNING" {
  local panel="$REPO_ROOT/development-go/skills/review/SKILL.md" section
  [ -f "$panel" ]
  run -1 grep -Fq -e 'Already waived' -- "$panel"
  run -1 grep -Fq -e 'adjudicated_path' -- "$panel"
  run -1 grep -Fq -e 'REVIEW_ADJUDICATED' -- "$panel"
  # the report template holds its own `## ` lines, so capture Step 3 up to
  # Step 4 rather than stopping at the first of them
  section="$(awk '/^## Step 3: Synthesize the Review/ { f = 1; next } /^## Step 4: / { f = 0 } f' "$panel")"
  [ -n "$section" ]
  contains "$section" '## Suggested follow-ups and capped claims'
  contains "$section" 'Only the SUGGESTION findings that carry a `follow-up:` or `decides:` line'
  contains "$section" '(Y critical, Z warnings, W capped or follow-up suggestions)'
  run -1 grep -qx '## Suggestions' <<<"$section"
  lacks "$section" 'W suggestions)'
}

# The Java panel (#3161): the six read-only reviewers report only what blocks.
# go_format captures any reviewer's Reporting Format to EOF, so it serves here
# too; java-test-reviewer's Reviewing thoroughness section follows it.

@test "#3161 the six Java reviewers drop plain SUGGESTION and keep only their SUGGESTION lanes" {
  local a f flat format n want
  for a in java-bug-hunter java-code-quality java-performance-reviewer java-resilience-reviewer java-security-reviewer java-test-reviewer; do
    f="$REPO_ROOT/development-java/agents/$a.md"
    flat="$(flatten <"$f")"
    format="$(go_format "$f")"
    [ -n "$format" ]
    lacks "$format" '**SUGGESTION:**'
    # Whole-file invariant: SUGGESTION appears only on the lines of its lanes
    # (evidence rule, template title, severity-set line(s), the reserved-for
    # sentence, and java-test-reviewer's scope-bounded follow-up). Any new
    # SUGGESTION route, however spelled, moves this count.
    want=6
    [ "$a" = java-test-reviewer ] && want=8
    n="$(grep -c SUGGESTION "$f")"
    [ "$n" -eq "$want" ]
    contains "$format" 'An observation below the blocking bar is not reported.'
    contains "$format" '### [CRITICAL|WARNING|SUGGESTION] Title'
    contains "$format" 'decides: <the command that settles it> proposed-severity: CRITICAL|WARNING'
    if [ "$a" = java-test-reviewer ]; then
      contains "$format" '`SUGGESTION` is reserved for the two lanes of ARCHITECTURE.md *Terminating severity bars*: a tool-verdict claim capped by the evidence rule above, and a scope-bounded follow-up under *Scope-bounded severity* below.'
      contains "$format" 'decides: <the command that settles it> proposed-severity: CRITICAL|WARNING — or, for a scope-bounded follow-up (*Scope-bounded severity* below), this one line appended to the **Description** field, with the severity set to SUGGESTION: follow-up: <the defect, in one line>'
    else
      contains "$format" '`SUGGESTION` is reserved for a tool-verdict claim capped by the evidence rule above, the one lane of ARCHITECTURE.md *Terminating severity bars* this agent carries.'
      lacks "$flat" 'follow-up:'
    fi
  done
}

@test "#3161 java-resilience-reviewer does not report a violation it cannot prove" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-java/agents/java-resilience-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'If a wrapper or a config class you cannot see might already supply the timeout or breaker, and you cannot name the failure, do not report it; do not assert a violation you cannot prove.'
  lacks "$flat" 'drop to SUGGESTION'
}

@test "#3161 java-security-reviewer does not report hardening with no attack path" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-java/agents/java-security-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" '**WARNING:** Exploitable under specific conditions, or a defense-in-depth gap: a control the change removes or weakens.'
  contains "$flat" 'Hardening that only adds a new layer, with no attack path you can name, is below the bar and not reported.'
  lacks "$flat" 'violates best practices'
}

@test "#3161 java-code-quality does not report style or idiom alone" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-java/agents/java-code-quality.md")"
  [ -n "$flat" ]
  contains "$flat" 'Style, idiom or tidiness alone — naming, a missing `final`, missing Javadoc, magic numbers, mixed paradigms or date/time APIs, unused code or imports, commented-out code, boolean positional arguments, broader-than-needed visibility, a small repeated pattern, package-layout inconsistency — is below the bar and not reported, unless it misleads a caller or harms maintainability at a cost you can name.'
}

@test "#3161 java-test-reviewer and java-performance-reviewer do not report their named sub-bar items" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-java/agents/java-test-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'The structure and debuggability checks above — assertion messages, `assertTrue` on a complex condition, Arrange-Act-Assert layout, test names, several behaviours in one test method, `@ParameterizedTest`/`@Nested` grouping, duplicated setup, an expensive fixture rebuilt per test — are below the bar and not reported, unless you can name the regression or the flakiness they let through.'
  flat="$(flatten <"$REPO_ROOT/development-java/agents/java-performance-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'An allocation or micro-optimisation finding — autoboxing, `+` concatenation in a loop, a missing initial capacity — with no hot path or load condition you can name is speculation, below the bar and not reported.'
}

@test "#3161 java-test-reviewer's Scope-bounded severity reports the follow-up lane and keeps its three carve-outs" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-java/agents/java-test-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'A finding blocks (CRITICAL/WARNING) only when its fix stays within the issue'"'"'s stated scope. A pre-existing defect that would block, but whose only correct fix expands the change beyond that scope, is reported at **SUGGESTION** with a Description line `follow-up: <the defect, in one line>`, and it never blocks a round. A plain out-of-diff observation below the bar is not reported.'
  lacks "$flat" 'spin off a follow-up issue'
  contains "$flat" 'Three carve-outs keep this from muzzling real blockers. **(1) Tests and coverage for the change under review are always in-scope**'
  contains "$flat" '**(2) A defect the change under review *introduces* is always in-scope**'
  contains "$flat" "**(3) When the issue's stated scope is not provided in your prompt**"
}

@test "#3161 the Java panel carries no waived list and reports only capped claims and follow-ups below WARNING" {
  local panel="$REPO_ROOT/development-java/skills/review/SKILL.md" section
  [ -f "$panel" ]
  run -1 grep -Fq -e 'Already waived' -- "$panel"
  run -1 grep -Fq -e 'adjudicated_path' -- "$panel"
  run -1 grep -Fq -e 'REVIEW_ADJUDICATED' -- "$panel"
  run -1 grep -Fq -e '--adjudicated' -- "$panel"
  grep -Fq -e 'also carries `fix_verification_path`, and the reviewers must be told about it.' -- "$panel"
  # the report template holds its own `## ` lines, so capture Step 3 up to
  # Step 4 rather than stopping at the first of them
  section="$(awk '/^## Step 3: Synthesize the Review/ { f = 1; next } /^## Step 4: / { f = 0 } f' "$panel")"
  [ -n "$section" ]
  contains "$section" '## Suggested follow-ups and capped claims'
  contains "$section" 'Only the SUGGESTION findings that carry a `follow-up:` or `decides:` line'
  contains "$section" '(Y critical, Z warnings, W capped or follow-up suggestions)'
  run -1 grep -qx '## Suggestions' <<<"$section"
  lacks "$section" 'W suggestions)'
}

# The JavaScript panel (#3162): the six read-only reviewers report only what
# blocks. go_format captures any reviewer's Reporting Format to EOF, so it
# serves here too. Five of the six state a Scope-bounded severity rule and so
# carry the follow-up: lane; js-resilience-reviewer states none.

@test "#3162 the six JavaScript reviewers drop plain SUGGESTION and keep only their SUGGESTION lanes" {
  local a f flat format n want
  for a in js-bug-hunter js-code-quality js-performance-reviewer js-resilience-reviewer js-security-reviewer js-test-reviewer; do
    f="$REPO_ROOT/development-javascript/agents/$a.md"
    flat="$(flatten <"$f")"
    format="$(go_format "$f")"
    [ -n "$format" ]
    lacks "$format" '**SUGGESTION:**'
    # Whole-file invariant: SUGGESTION appears only on the lines of its lanes
    # (evidence rule, template title, the decides: slot, the reserved-for
    # sentence, and in the five scoped agents the follow-up: slot and the
    # Scope-bounded severity bullet). Any new SUGGESTION route moves this count.
    want=8
    [ "$a" = js-resilience-reviewer ] && want=6
    n="$(grep -c SUGGESTION "$f")"
    [ "$n" -eq "$want" ]
    contains "$format" 'An observation below the blocking bar is not reported.'
    contains "$format" '### [CRITICAL|WARNING|SUGGESTION] Title'
    contains "$format" 'decides: <the command that settles it> proposed-severity: CRITICAL|WARNING'
    if [ "$a" = js-resilience-reviewer ]; then
      contains "$format" '`SUGGESTION` is reserved for a tool-verdict claim capped by the evidence rule above, the one lane of ARCHITECTURE.md *Terminating severity bars* this agent carries.'
      lacks "$flat" 'follow-up:'
    else
      contains "$format" '`SUGGESTION` is reserved for the two lanes of ARCHITECTURE.md *Terminating severity bars*: a tool-verdict claim capped by the evidence rule above, and a scope-bounded follow-up under *Scope-bounded severity* above.'
      contains "$format" 'decides: <the command that settles it> proposed-severity: CRITICAL|WARNING — or, for a scope-bounded follow-up (*Scope-bounded severity* above), this one line appended to the **Description** field, with the severity set to SUGGESTION: follow-up: <the defect, in one line>'
    fi
  done
}

@test "#3162 the five scoped JavaScript reviewers report the follow-up lane and keep their carve-outs" {
  local a flat
  for a in js-bug-hunter js-code-quality js-performance-reviewer js-security-reviewer js-test-reviewer; do
    flat="$(flatten <"$REPO_ROOT/development-javascript/agents/$a.md")"
    [ -n "$flat" ]
    contains "$flat" 'A finding blocks (CRITICAL/WARNING) only when its fix stays within the issue'"'"'s stated scope. A pre-existing defect that would block, but whose only correct fix expands the change beyond that scope, is reported at **SUGGESTION** with a Description line `follow-up: <the defect, in one line>`, and it never blocks a round. A plain out-of-diff observation below the bar is not reported.'
    lacks "$flat" 'spin off a follow-up issue'
    if [ "$a" = js-test-reviewer ]; then
      contains "$flat" 'Three carve-outs keep this from muzzling real blockers. **(1) Tests and coverage for the change under review are always in-scope**'
      contains "$flat" '**(2) A defect the change under review *introduces* is always in-scope**'
      contains "$flat" "**(3) When the issue's stated scope is not provided in your prompt**"
    else
      contains "$flat" 'Two carve-outs keep this from muzzling real blockers. **(1) A defect the change under review *introduces* is always in-scope**'
      contains "$flat" "**(2) When the issue's stated scope is not provided in your prompt**"
    fi
  done
}

@test "#3162 js-resilience-reviewer does not report a violation it cannot prove" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-javascript/agents/js-resilience-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'If a shared client factory or wrapper you cannot see might already supply the timeout or breaker, and you cannot name the failure, do not report it; do not assert a violation you cannot prove.'
  lacks "$flat" 'drop to SUGGESTION'
}

@test "#3162 the JavaScript reviewers do not report their named sub-bar items" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-javascript/agents/js-code-quality.md")"
  [ -n "$flat" ]
  contains "$flat" 'Style, idiom or tidiness alone — naming, magic numbers, nesting an early return would flatten, a comment that restates the code, `let` where `const` applies, `.then` chains in otherwise `async` code, mixed module or export styles — is below the bar and not reported, unless it misleads a caller or harms maintainability at a cost you can name.'
  flat="$(flatten <"$REPO_ROOT/development-javascript/agents/js-performance-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'An optimisation with no hot path or load condition you can name, and no user-visible cost today, is speculation, below the bar and not reported.'
  flat="$(flatten <"$REPO_ROOT/development-javascript/agents/js-security-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" '**WARNING:** A weakness that becomes exploitable under plausible conditions, or a missing defence in depth on a sensitive path: a control the change removes or weakens.'
  contains "$flat" 'Hardening that only adds a new layer, with no attack path you can name, is below the bar and not reported.'
  flat="$(flatten <"$REPO_ROOT/development-javascript/agents/js-test-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'The structure checks above — duplicated setup a shared fixture or helper would remove, a snapshot no reviewer reads, a test that leans on implementation details — are below the bar and not reported, unless you can name the regression or the flakiness they let through.'
}

@test "#3162 the JavaScript panel carries no waived list and reports only capped claims and follow-ups below WARNING" {
  local panel="$REPO_ROOT/development-javascript/skills/review/SKILL.md" section
  [ -f "$panel" ]
  run -1 grep -Fq -e 'Already waived' -- "$panel"
  run -1 grep -Fq -e 'adjudicated_path' -- "$panel"
  run -1 grep -Fq -e 'REVIEW_ADJUDICATED' -- "$panel"
  run -1 grep -Fq -e '--adjudicated' -- "$panel"
  grep -Fq -e 'also carries `fix_verification_path`, and the reviewers must be told about it.' -- "$panel"
  # the report template holds its own `## ` lines, so capture Step 3 up to
  # Step 4 rather than stopping at the first of them
  section="$(awk '/^## Step 3: Synthesize the Review/ { f = 1; next } /^## Step 4: / { f = 0 } f' "$panel")"
  [ -n "$section" ]
  contains "$section" '## Suggested follow-ups and capped claims'
  contains "$section" 'Only the SUGGESTION findings that carry a `follow-up:` or `decides:` line'
  contains "$section" '(Y critical, Z warnings, W capped or follow-up suggestions)'
  run -1 grep -qx '## Suggestions' <<<"$section"
  lacks "$section" 'W suggestions)'
}

# The Python panel (#3165): the six read-only reviewers report only what blocks.
# go_format captures any reviewer's Reporting Format to EOF, so it serves here
# too; python-test-reviewer's Reviewing thoroughness section follows it.

@test "#3165 the six Python reviewers drop plain SUGGESTION and keep only their SUGGESTION lanes" {
  local a f flat format n want
  for a in python-bug-hunter python-code-quality python-performance-reviewer python-resilience-reviewer python-security-reviewer python-test-reviewer; do
    f="$REPO_ROOT/development-python/agents/$a.md"
    flat="$(flatten <"$f")"
    format="$(go_format "$f")"
    [ -n "$format" ]
    lacks "$format" '**SUGGESTION:**'
    lacks "$format" 'as a suggestion'
    lacks "$format" 'as a `SUGGESTION`'
    # Whole-file invariant: the word appears, in any case, only in its lanes
    # (evidence rule, template title, severity-set line(s), the reserved-for
    # sentence, and python-test-reviewer's scope-bounded follow-up). The count
    # is of occurrences, not lines, so a new mention on an existing line, or a
    # lowercase one, moves it.
    want=6
    [ "$a" = python-test-reviewer ] && want=8
    n="$(grep -oi suggestion "$f" | wc -l | tr -d ' ')"
    [ "$n" -eq "$want" ]
    contains "$format" 'An observation below the blocking bar is not reported.'
    contains "$format" '### [CRITICAL|WARNING|SUGGESTION] Title'
    contains "$format" 'decides: <the command that settles it> proposed-severity: CRITICAL|WARNING'
    if [ "$a" = python-test-reviewer ]; then
      contains "$format" '`SUGGESTION` is reserved for the two lanes of ARCHITECTURE.md *Terminating severity bars*: a tool-verdict claim capped by the evidence rule above, and a scope-bounded follow-up under *Scope-bounded severity* below.'
      contains "$format" 'decides: <the command that settles it> proposed-severity: CRITICAL|WARNING — or, for a scope-bounded follow-up (*Scope-bounded severity* below), this one line appended to the **Description** field, with the severity set to SUGGESTION: follow-up: <the defect, in one line>'
    else
      contains "$format" '`SUGGESTION` is reserved for a tool-verdict claim capped by the evidence rule above, the one lane of ARCHITECTURE.md *Terminating severity bars* this agent carries.'
      lacks "$flat" 'follow-up:'
    fi
  done
}

@test "#3165 python-resilience-reviewer does not report a violation it cannot prove" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-python/agents/python-resilience-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'If a shared session factory or wrapper you cannot see might already supply the timeout or breaker, and you cannot name the failure, do not report it; do not assert a violation you cannot prove.'
  lacks "$flat" 'drop to SUGGESTION'
}

@test "#3165 python-security-reviewer does not report hardening with no attack path" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-python/agents/python-security-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" '**WARNING:** Exploitable under specific conditions, or a defense-in-depth gap: a control the change removes or weakens.'
  contains "$flat" 'Hardening that only adds a new layer, with no attack path you can name, is below the bar and not reported.'
  lacks "$flat" 'violates best practices'
}

@test "#3165 python-code-quality does not report style or idiom alone" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-python/agents/python-code-quality.md")"
  [ -n "$flat" ]
  contains "$flat" 'Style, idiom or tidiness alone — PEP 8 naming, abbreviations, magic numbers, missing type hints or docstrings, mixed `os.path` and `pathlib` or formatting styles, unused code or imports, commented-out code, boolean positional arguments, a missing `__all__`, a small repeated pattern, module-layout inconsistency — is below the bar and not reported, unless it misleads a caller or harms maintainability at a cost you can name.'
}

@test "#3165 python-test-reviewer and python-performance-reviewer do not report their named sub-bar items" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-python/agents/python-test-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'The structure and debuggability checks above — `assertTrue` on a complex condition, Arrange-Act-Assert layout, test names, several behaviours in one test function, a missed `@pytest.mark.parametrize`, duplicated setup, an expensive fixture rebuilt per test — are below the bar and not reported, unless you can name the regression or the flakiness they let through.'
  flat="$(flatten <"$REPO_ROOT/development-python/agents/python-performance-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'An allocation or micro-optimisation finding — `+=` string concatenation in a loop, a list comprehension where a generator would do, a list membership test on a small collection — with no hot path or load condition you can name is speculation, below the bar and not reported.'
}

@test "#3165 python-test-reviewer's Scope-bounded severity reports the follow-up lane and keeps its three carve-outs" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-python/agents/python-test-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'A finding blocks (CRITICAL/WARNING) only when its fix stays within the issue'"'"'s stated scope. A pre-existing defect that would block, but whose only correct fix expands the change beyond that scope, is reported at **SUGGESTION** with a Description line `follow-up: <the defect, in one line>`, and it never blocks a round. A plain out-of-diff observation below the bar is not reported.'
  lacks "$flat" 'spin off a follow-up issue'
  contains "$flat" 'Three carve-outs keep this from muzzling real blockers. **(1) Tests and coverage for the change under review are always in-scope**'
  contains "$flat" '**(2) A defect the change under review *introduces* is always in-scope**'
  contains "$flat" "**(3) When the issue's stated scope is not provided in your prompt**"
}

@test "#3165 the Python panel carries no waived list and reports only capped claims and follow-ups below WARNING" {
  local panel="$REPO_ROOT/development-python/skills/review/SKILL.md" section
  [ -f "$panel" ]
  run -1 grep -Fq -e 'Already waived' -- "$panel"
  run -1 grep -Fq -e 'adjudicated_path' -- "$panel"
  run -1 grep -Fq -e 'REVIEW_ADJUDICATED' -- "$panel"
  run -1 grep -Fq -e '--adjudicated' -- "$panel"
  run -1 grep -Fq -e 'what the human already waived' -- "$panel"
  grep -Fq -e 'also carries `fix_verification_path`, and the reviewers must be told about it.' -- "$panel"
  # the report template holds its own `## ` lines, so capture Step 3 up to
  # Step 4 rather than stopping at the first of them
  section="$(awk '/^## Step 3: Synthesize the Review/ { f = 1; next } /^## Step 4: / { f = 0 } f' "$panel")"
  [ -n "$section" ]
  contains "$section" '## Suggested follow-ups and capped claims'
  contains "$section" 'Only the SUGGESTION findings that carry a `follow-up:` or `decides:` line'
  contains "$section" '(Y critical, Z warnings, W capped or follow-up suggestions)'
  run -1 grep -qx '## Suggestions' <<<"$section"
  lacks "$section" 'W suggestions)'
}

# The Swift panel (#3167): the six evidence-rule reviewers report only what
# blocks, and swift6-compliance, which carries no evidence rule, has no
# SUGGESTION slot at all. go_format captures a reviewer's Reporting Format to
# EOF, so test-reviewer's Reviewing thoroughness section is inside it.

@test "#3167 the six Swift evidence-rule reviewers drop plain SUGGESTION and keep only their SUGGESTION lanes" {
  local a f flat format n want
  for a in bug-hunter code-quality performance-reviewer security-reviewer swift-resilience-reviewer test-reviewer; do
    f="$REPO_ROOT/development-swift/agents/$a.md"
    flat="$(flatten <"$f")"
    format="$(go_format "$f")"
    [ -n "$format" ]
    lacks "$format" '**SUGGESTION:**'
    lacks "$format" 'as a suggestion'
    lacks "$format" 'as a `SUGGESTION`'
    # Whole-file invariant: the word appears, in any case, only in its lanes
    # (evidence rule, template title, severity-set line(s), the reserved-for
    # sentence, and test-reviewer's scope-bounded follow-up). The count is of
    # occurrences, not lines, so a new mention on an existing line moves it.
    want=6
    [ "$a" = test-reviewer ] && want=8
    n="$(grep -oi suggestion "$f" | wc -l | tr -d ' ')"
    [ "$n" -eq "$want" ]
    contains "$format" 'An observation below the blocking bar is not reported.'
    contains "$format" '### [CRITICAL|WARNING|SUGGESTION] Title'
    contains "$format" 'decides: <the command that settles it> proposed-severity: CRITICAL|WARNING'
    if [ "$a" = test-reviewer ]; then
      contains "$format" '`SUGGESTION` is reserved for the two lanes of ARCHITECTURE.md *Terminating severity bars*: a tool-verdict claim capped by the evidence rule above, and a scope-bounded follow-up under *Scope-bounded severity* below.'
      contains "$format" 'decides: <the command that settles it> proposed-severity: CRITICAL|WARNING — or, for a scope-bounded follow-up (*Scope-bounded severity* below), this one line appended to the **Description** field, with the severity set to SUGGESTION: follow-up: <the defect, in one line>'
    else
      contains "$format" '`SUGGESTION` is reserved for a tool-verdict claim capped by the evidence rule above, the one lane of ARCHITECTURE.md *Terminating severity bars* this agent carries.'
      lacks "$flat" 'follow-up:'
    fi
  done
}

@test "#3167 swift6-compliance reports CRITICAL and WARNING only, and its migrate mode carries no SUGGESTION" {
  local f="$REPO_ROOT/development-swift/agents/swift6-compliance.md" format
  format="$(awk '/^## Reporting Format$/ { f = 1; next } f && /^## / { exit } f' "$f" | flatten)"
  [ -n "$format" ]
  contains "$format" '### [CRITICAL|WARNING] Title'
  lacks "$format" 'SUGGESTION'
  contains "$format" '**WARNING:** An API, flag or construct the compiler or SDK marks deprecated (a deprecation diagnostic), with a clear modern replacement that should be adopted'
  contains "$format" 'An observation below the blocking bar — a modernization opportunity with no compile failure under Swift 6 and no deprecation diagnostic behind it, such as `guard let x = x` rebinding, `#selector` or `@objc` style, Objective-C idioms in pure Swift, `NSError` bridging, untyped `throws`, `any` where `some` would do, `if`/`switch` expressions or ownership modifiers — is not reported, even where a checklist heading above lists it.'
  contains "$format" 'In review mode, a CRITICAL or WARNING finding that claims a compile failure or a deprecation diagnostic is reported only with that diagnostic quoted in its Description, from a build you ran without editing any file (`swift build -Xswiftc -swift-version -Xswiftc 6`, or the project'"'"'s `xcodebuild build`); a compiler claim you could not check is not reported.'
  lacks "$format" 'Deprecated pattern with a clear modern replacement'
  # the word is gone from the whole file, migrate mode included
  run -1 grep -qi suggestion "$f"
  grep -qx '## Migrate mode (#447)' "$f"
}

@test "#3167 swift-resilience-reviewer does not report a violation it cannot prove" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-swift/agents/swift-resilience-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'When a client type you cannot see might already supply the timeout or breaker, and you cannot name the failure, do not report it; do not assert a violation you cannot prove.'
  lacks "$flat" 'drop to SUGGESTION'
  lacks "$flat" 'A hardening improvement with no failure mode you can name.'
}

@test "#3167 swift security-reviewer does not report hardening with no attack path" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-swift/agents/security-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" '**WARNING:** Exploitable under specific conditions, or a defense-in-depth gap: a control the change removes or weakens. Hardening that only adds a new layer, with no attack path you can name, is below the bar and not reported.'
  lacks "$flat" 'violates best practices'
}

@test "#3167 the Swift code-quality, performance and test reviewers do not report their named sub-bar items" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-swift/agents/code-quality.md")"
  [ -n "$flat" ]
  contains "$flat" 'Style, idiom or tidiness alone — naming and API Design Guidelines conventions, abbreviations, magic numbers, missing documentation comments, a missing default parameter value, broader-than-needed access control, unused code or imports, commented-out code, a small repeated pattern, mixed coding or file-organization styles — is below the bar and not reported, unless it misleads a caller or harms maintainability at a cost you can name.'
  flat="$(flatten <"$REPO_ROOT/development-swift/agents/performance-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'An allocation or micro-optimisation finding — a class where a struct would do, string interpolation, `filter` + `first` instead of `first(where:)`, an `any Protocol` existential, `AnyPublisher` type erasure — with no hot path or load condition you can name is speculation, below the bar and not reported.'
  flat="$(flatten <"$REPO_ROOT/development-swift/agents/test-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'The structure, debuggability and framework checks above — assertion messages, `XCTAssertTrue` on a complex condition, Arrange-Act-Assert layout, test names, several behaviours in one test, duplicated setup, test grouping, a move from XCTest to Swift Testing, `@Test(arguments:)` or trait opportunities — are below the bar and not reported, unless you can name the regression or the flakiness they let through.'
}

@test "#3167 Swift test-reviewer's Scope-bounded severity reports the follow-up lane and keeps its three carve-outs" {
  local flat
  flat="$(flatten <"$REPO_ROOT/development-swift/agents/test-reviewer.md")"
  [ -n "$flat" ]
  contains "$flat" 'A finding blocks (CRITICAL/WARNING) only when its fix stays within the issue'"'"'s stated scope. A pre-existing defect that would block, but whose only correct fix expands the change beyond that scope, is reported at **SUGGESTION** with a Description line `follow-up: <the defect, in one line>`, and it never blocks a round. A plain out-of-diff observation below the bar is not reported.'
  lacks "$flat" 'spin off a follow-up issue'
  contains "$flat" 'Three carve-outs keep this from muzzling real blockers. **(1) Tests and coverage for the change under review are always in-scope**'
  contains "$flat" '**(2) A defect the change under review *introduces* is always in-scope**'
  contains "$flat" "**(3) When the issue's stated scope is not provided in your prompt**"
}

@test "#3167 the Swift panel carries no waived list and reports follow-ups and tool claims under their own headings" {
  local panel="$REPO_ROOT/development-swift/skills/review/SKILL.md" section
  [ -f "$panel" ]
  run -1 grep -Fq -e 'Already waived' -- "$panel"
  run -1 grep -Fq -e 'adjudicated_path' -- "$panel"
  run -1 grep -Fq -e 'REVIEW_ADJUDICATED' -- "$panel"
  run -1 grep -Fq -e '--adjudicated' -- "$panel"
  run -1 grep -Fq -e 'carries the waived' -- "$panel"
  run -1 grep -Fq -e 'what the human already waived' -- "$panel"
  grep -Fq -e 'also carries `fix_verification_path`, and the reviewers must be told about it.' -- "$panel"
  # the report template holds its own `## ` lines, so capture Step 3 up to
  # Step 4 rather than stopping at the first of them
  section="$(awk '/^## Step 3: Synthesize the Review/ { f = 1; next } /^## Step 4: / { f = 0 } f' "$panel")"
  [ -n "$section" ]
  grep -qx '## Suggested follow-ups' <<<"$section"
  grep -qx '## Unverified tool claims' <<<"$section"
  contains "$section" 'Only the SUGGESTION findings that carry a `follow-up:` line'
  contains "$section" 'Only the SUGGESTION findings that carry `decides:` / `proposed-severity:` lines'
  contains "$section" '(Y critical, Z warnings, W follow-ups, V tool claims)'
  run -1 grep -qx '## Suggestions' <<<"$section"
  lacks "$section" 'W suggestions)'
}
