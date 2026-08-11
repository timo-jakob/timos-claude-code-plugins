#!/usr/bin/env bats
#
# The Approver's dry-run contract (#1147 round 5-6).
#
# `--dry-run` is parsed by ONE approve skill: `/development-go:approve`. The
# Java, Python and Swift skills accept an optional PR number and nothing else,
# hardcode `DRY_RUN=false`, and therefore POST a binding review under the
# `claude-approver-<owner>[bot]` identity on every invocation.
#
# Three shipped docs claimed the opposite — the three operator mirrors, the
# adoption how-to ("invoke the agent in your worktree and it executes the same
# logic without posting a review … the three skills wrap this") and the
# explanation page ("runs the same agent locally for a dry-run verdict"). An
# operator following any of them to *preview* a verdict posted a real one
# instead, which is irreversible. The drift shipped because nothing anywhere
# asserted the contract: no bats file referenced `skills/approve` or `DRY_RUN`.
#
# These tests DERIVE the claim from the skills rather than restating it, so the
# docs and the code cannot drift apart again silently.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Every language shipping an `approve` skill. Go is held separately: it is the
  # only one that parses the flag.
  POSTING_ONLY=(development-java development-python development-swift)
}

# skill_file <plugin> — that plugin's approve SKILL.md.
skill_file() { printf '%s/%s/skills/approve/SKILL.md' "$REPO_ROOT" "$1"; }

# flat <path> — blockquote markers stripped, then whitespace-normalised, so a
# needle that a ~70-column wrap splits is still found. These docs are
# hard-wrapped prose and the explanation page states its status inside a `>`
# blockquote, so without the strip a wrapped needle becomes "... flag is > Go-only".
# A line-oriented `lacks` that cannot see a wrapped occurrence passes VACUOUSLY,
# which is exactly how a false claim survives.
#
# HARD-GUARDED on a missing file. A pipeline's status is its LAST command's, so
# `sed missing | tr` would exit 0 with EMPTY output — and `lacks "" <needle>` is
# unconditionally true. A renamed doc would then retire every assertion here
# silently, on the one contract whose violation posts an irreversible review.
# `sed -E` with a repeated group also survives a nested or wide-gutter quote.
flat() {
  [ -f "$1" ] || { printf 'flat: no such file: %s\n' "$1" >&2; return 1; }
  sed -E 's/^[[:space:]]*(>[[:space:]]?)+//' "$1" | tr -s '[:space:]' ' '
}

@test "the approve-skill roster is complete" {
  # The roster is the ONE input this file does not derive, and its header claims
  # completeness. Derive it: the next plugin that copies the java/python/swift
  # skill — which posts — would otherwise join the repo asserted about by
  # nothing, which is precisely the harm here.
  local found=() f
  for f in "$REPO_ROOT"/*/skills/approve/SKILL.md; do
    f="${f#"$REPO_ROOT"/}"
    found+=("${f%%/*}")
  done
  [ "${#found[@]}" -eq "$(( ${#POSTING_ONLY[@]} + 1 ))" ]
  local p
  for p in "${POSTING_ONLY[@]}" development-go; do
    [ -f "$(skill_file "$p")" ]
  done
}

@test "only the Go approve skill parses --dry-run, and it really suppresses the post" {
  # Positive control first: the flag really is implemented somewhere, so the
  # `lacks` below are proving an absence against a live feature rather than
  # against a flag nobody has.
  local go p skill
  go="$(flat "$(skill_file development-go)")"
  [ -n "$go" ]
  contains "$go" '**`--dry-run`**'
  contains "$go" "DRY_RUN=true"
  # ...and that the flag is not merely DOCUMENTED but load-bearing. Without this
  # the conditional could be dropped from the agent prompt, leaving the flag
  # cosmetic: `--dry-run` would post a binding review while every other needle
  # in this file — and every "Go-only" doc claim resting on it — stayed green.
  contains "$go" "print the rendered verdict to stdout and post nothing"
  contains "$go" "strip the flag before resolving the PR number"
  for p in "${POSTING_ONLY[@]}"; do
    skill="$(flat "$(skill_file "$p")")"
    [ -n "$skill" ]
    lacks "$skill" '`--dry-run`'
    # The spelling-independent half: the flag exists only to set this, so an
    # un-backticked re-introduction cannot walk past both needles.
    lacks "$skill" "DRY_RUN=true"
  done
}

@test "the non-Go approve skills hardcode DRY_RUN=false" {
  # The other half of the contract: not merely "no flag" but "always posts".
  local p skill
  for p in "${POSTING_ONLY[@]}"; do
    skill="$(flat "$(skill_file "$p")")"
    [ -n "$skill" ]
    contains "$skill" "DRY_RUN=false"
  done
}

@test "the adoption how-to does not promise a non-posting run from the approve skills" {
  # The exact sentence that drifted, plus the correction that replaced it.
  local doc
  doc="$(flat "$REPO_ROOT/docs/how-to/adopt-the-approver.md")"
  [ -n "$doc" ]
  contains "$doc" "not a dry-run path"
  contains "$doc" "posts a binding review"
  # The retracted claim, in the wording it actually had.
  lacks "$doc" "it executes the same logic without posting a review"
  lacks "$doc" "skills wrap this"
}

@test "the explanation page tells exactly one dry-run story" {
  local doc
  doc="$(flat "$REPO_ROOT/docs/explanation/claude-approver.md")"
  [ -n "$doc" ]
  contains "$doc" 'the `--dry-run` flag is Go-only'
  # The retired CI path must not read as live: it promised a non-binding COMMENT
  # from a `/approve` PR comment, on a page that now says the flag is Go-only.
  lacks "$doc" "runs as a non-binding COMMENT"
  lacks "$doc" "for a dry-run verdict"
}

@test "no operator mirror advertises --dry-run for a skill that lacks it" {
  # Go's mirror legitimately documents the flag, and is the positive control for
  # the EXACT swept sentence — a broader needle would still pass on Go's three
  # other `--dry-run` mentions after the swept sentence was reworded away,
  # leaving the three `lacks` below permanently vacuous.
  local p mirror
  contains "$(flat "$REPO_ROOT/development-go/docs/go-approver.md")" \
    'Pass `--dry-run` for a non-binding evaluation'
  for p in "${POSTING_ONLY[@]}"; do
    mirror="$(flat "$REPO_ROOT/$p/docs/${p#development-}-approver.md")"
    [ -n "$mirror" ]
    lacks "$mirror" 'Pass `--dry-run` for a non-binding evaluation'
    # Pinned POSITIVELY too: the `lacks` is the pre-fix wording verbatim, so a
    # differently-phrased re-introduction slips past it. The corrective claim
    # must be PRESENT, not merely the old one absent.
    contains "$mirror" "Go-only"
  done
}

@test "the retired CI path is marked as history, and no workflow template exists" {
  # Derive the premise rather than restating it: bootstrap ships no approver
  # workflow template. Positive control on the templates tree first, so a moved
  # or renamed directory cannot make the absence check vacuous.
  local tmpl_dir found
  tmpl_dir="$REPO_ROOT/development/skills/bootstrap/templates"
  [ -d "$tmpl_dir" ]
  [ -f "$tmpl_dir/common/approver-policy-core.md.tmpl" ]
  found="$(find "$tmpl_dir" -name 'claude-approver*.yml.tmpl' -print -quit)"
  [ -z "$found" ]
  # ...and both docs say so, so deleting the history marker reds here rather
  # than silently restoring a page that reads as a live CI Approver.
  contains "$(flat "$REPO_ROOT/docs/explanation/claude-approver.md")" "Pre-#476"
  contains "$(flat "$REPO_ROOT/docs/how-to/adopt-the-approver.md")" "No workflow"
}

@test "the rendered policy promises no automatic re-trigger" {
  # The template ships to every bootstrapped repo. It used to promise an
  # automatic `check_suite: completed` re-run that bootstrap renders nothing to
  # deliver — the same false-machinery class as the dry-run claim, and it had
  # the same zero coverage.
  local tmpl
  tmpl="$(flat "$REPO_ROOT/development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl")"
  [ -n "$tmpl" ]
  contains "$tmpl" "no automatic re-trigger"
  contains "$tmpl" "user-invoked locally, not driven by a workflow"
  lacks "$tmpl" "re-runs on the next \`check_suite: completed\`"
}
