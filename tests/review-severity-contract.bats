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
  # the contract is staged: #3158 landed it for the claude-plugin panel, and
  # the other reviewers follow it once #3159–#3167 land
  contains "$flat" "That rule holds for every panel's reviewers, whether or not they carry a bar."
  contains "$flat" '**Only the reviewers #3158 rewrote follow this contract yet**, in the claude-plugin panel. The other reviewer agents still report a below-the-bar finding as a `SUGGESTION`, and the `development-react` panel still fixes one check at `SUGGESTION` (above), until children #3159–#3167 of #3122 rewrite them.'
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
  # the two staged parts name the children that ship them
  contains "$flat" 'The dossier has no *Suggested follow-ups* section until #3170 lands, so until then such a defect appears in the dossier'"'"'s **Waived suggestions** list.'
  contains "$flat" 'The claude-plugin panel'"'"'s reviewers follow it since #3158; the other panels'"'"' reviewers still report below-the-bar observations as suggestions until #3159–#3167 land.'
  lacks "$flat" 'suggestions until #3158–#3167 land.'
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
  local a f flat format
  for a in go-bug-hunter go-code-quality go-performance-reviewer go-resilience-reviewer go-security-reviewer go-test-reviewer; do
    f="$REPO_ROOT/development-go/agents/$a.md"
    flat="$(flatten <"$f")"
    format="$(go_format "$f")"
    [ -n "$format" ]
    lacks "$format" '**SUGGESTION:**'
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
