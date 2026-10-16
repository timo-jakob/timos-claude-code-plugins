#!/usr/bin/env bats
#
# #1435 AC15: the residue terminal has to be findable wherever the loop's
# endings are described, and NO surviving site may still claim that only
# `CONVERGED` opens a PR.
#
# A grep suite rather than a behavioural one, because the observable IS the
# prose: `CONVERGED_WITH_RESIDUE` is the first ending that opens a PR without a
# human ever seeing an escalation, so a doc that omits it does not merely lag —
# it tells a reader the opposite of what the code does.
#
# Shape, and why. The NEGATIVE half sweeps the whole tree (`git ls-files`), not
# a list written here: a stale claim reintroduced in a file nobody thought of is
# exactly what a closed list cannot see, and this repo has already paid for that
# once. The POSITIVE half is a named roster — the sites the story enumerated —
# carrying a count tripwire, so a roster that grows or shrinks reds here rather
# than passing in silence.
#
# Deliberately NOT registered as a MAINTAINING.md restatement invariant: those
# pin literal WORDING across sites that must agree clause for clause. This pins
# only that a TERM and its exit code are present, and each site says it in its
# own voice — a wording pin would red on every legitimate rephrase.
#
# #2580 RETIRED the terminal: `CONVERGED` is the only review-loop ending that
# opens a PR again. The sites that named the terminal are being migrated one
# story at a time, so this suite now holds two explicit lists instead of a
# roster: NOT_YET_MIGRATED (the sites later stories own, each of which must still
# name the terminal until its own story migrates it and shrinks the list in the
# same PR) and KEPT (the seven sites that keep naming it — six inside byte-frozen
# spans, and condition-2-removed.md, which #2601 deletes whole). Every other
# markdown site naming it is a stray, except ARCHITECTURE.md, whose telemetry
# recipes still count historical records carrying the status.

bats_require_minimum_version 1.5.0
load assertions

load resolve-issue-corpus

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"  # the user-level telemetry default stays out of the real ~/.claude (#1972)
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # #1503 split this skill into a conductor plus reference/*.md. A sweep that
  # counts or reads ACROSS the skill takes the corpus; one that pins WHERE a
  # sentence lives takes the single file. See resolve-issue-corpus.bash.
  RI_REF="$REPO_ROOT/development/skills/resolve-issue/reference"
  SKILL="$(resolve_issue_corpus "$REPO_ROOT" "$BATS_TEST_TMPDIR/resolve-issue-corpus.md")"
  SCRIPTS="$REPO_ROOT/development/skills/resolve-issue/scripts"
  # #2580 AC7: the sites later stories still own, repo-relative, each with the
  # story that migrates it. Each must still name the terminal; the story that
  # migrates one removes it from this list in its own PR.
  # #2600 migrated the last two (it deleted them with the filing path), so the
  # list is empty; the test below keeps it that way.
  NOT_YET_MIGRATED=()
  # ...and the sites that keep naming it: six inside byte-frozen spans, plus
  # condition-2-removed.md, kept unedited because #2601 deletes it whole. Only
  # #2601 shrinks this set (by residue/branch.md and condition-2-removed.md).
  KEPT=(
    "development/skills/resolve-issue/reference/escalation.md"
    "development/skills/resolve-issue/reference/interactive/extension-grant.md"
    "development/skills/resolve-issue/reference/promotion/step-4-sub-loop.md"
    "development/skills/resolve-issue/reference/promotion/step-7-terminal.md"
    "development/skills/resolve-issue/reference/residue/branch.md"
    "development/skills/resolve-issue/reference/review-loop/exit-20-awaiting-fix.md"
    "development/skills/resolve-issue/reference/residue/condition-2-removed.md"
  )
}

# Every tracked markdown file AND every shipped markdown TEMPLATE, minus the
# vendored superpowers tree, which restates nothing of ours — the same exclusion
# the sibling sweeps use.
#
# The `.md.tmpl` half is not pedantry. `approver-policy-core.md.tmpl` carries a
# full residue restatement — the terminal, its two firing conditions, the
# `review-residue`/`needs-refinement` label pair, and the rule that open blockers
# left behind are NOT grounds for REQUEST_CHANGES — and it is the artifact the
# Approver actually reads the dossier through in every bootstrapped repo. A stale
# claim there is precisely what these sweeps exist to catch, and a `*.md`-only
# glob cannot see it.
all_markdown() {
  git -C "$REPO_ROOT" ls-files '*.md' '*.md.tmpl' | grep -v '^docs/superpowers/'
}

# flattened text of $1: several of the claims below wrap across lines, and a
# per-line grep would answer a question about line breaks rather than about the
# claim
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

# Does $1 state the cadence invariant INSIDE the AWAITING_FIX branch, near its
# top? Prints a diagnostic and returns 1 otherwise.
#
# ONE ASSERTION PER LINE, never an `&&` chain. bash exempts every command of an
# AND-list EXCEPT THE LAST from errexit, so
#   [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
# swallows a failure of the first two operands. Measured on the shape this
# replaced: with the second locator EMPTY (a rewrap split its needle) the chain
# short-circuited at the exempt operand and the body ran on, and the proximity
# check then read the empty value as 0 and compared a NEGATIVE span, so it
# passed — the reflow mutation was invisible. The wrong-order input DID red,
# because the ordering compare is the command following the final `&&` and so is
# not exempt; the hazard was narrower than a chain-is-always-inert reading
# suggests, and `claude-plugin-test-reviewer.md` forbids flagging that converse.
# `find-inert-bracket-assertions.zsh` catches this shape with neither rule
# (#1067), so convention rather than lint is what keeps it out.
#
# Position is asserted over a flattened WINDOW anchored to the branch heading,
# not by comparing two line numbers. That pins "inside the branch, near its top"
# in one step and is reflow-proof: locating the sentence on a RAW line while
# matching it on FLATTENED text is what made the old code red on a cosmetic
# rewrap while missing the real mutation.
_invariant_in_awaiting_fix_branch() {
  local f="$1" ln window
  # No `head -1`: a duplicated heading yields two lines, which the numeric guard
  # below then refuses — the "or ambiguous" half only means something if the
  # multiplicity survives long enough to be seen.
  ln="$(grep -n '^3\. \*\*On `AWAITING_FIX` (exit 20)\*\*' "$f" | cut -d: -f1)"
  case "$ln" in ''|*[!0-9]*)
    printf 'AWAITING_FIX branch heading missing or ambiguous in %s: "%s"\n' "$f" "$ln" >&2
    return 1 ;;
  esac
  window="$(sed -n "${ln},$(( ln + 30 ))p" "$f" | tr '\n' ' ' | tr -s ' ')"
  grep -q 'a round.s findings reach the loop BEFORE that round.s fix pass runs, always' \
    <<< "$window" || {
    printf 'the cadence invariant is not in the first 30 lines of the AWAITING_FIX branch of %s\n' "$f" >&2
    return 1
  }
}


@test "#2580 AC7 every site is migrated: the not-yet-migrated list is empty" {
  # #2580 listed the sites later stories owned; each story shrank the list in its
  # own PR, and #2600 removed the last two. A site re-added here would be a
  # migration nobody owns.
  [ "${#NOT_YET_MIGRATED[@]}" -eq 0 ]
}

@test "#2580 AC7 the kept set is exactly seven sites, and each still names the terminal" {
  [ "${#KEPT[@]}" -eq 7 ]
  local f
  for f in "${KEPT[@]}"; do
    grep -q 'CONVERGED_WITH_RESIDUE' "$REPO_ROOT/$f" || {
      echo "kept site no longer names the residue terminal: $f"; return 1; }
  done
}

@test "#2580 AC7 tripwire: every markdown site naming the terminal is on a list, or is ARCHITECTURE.md" {
  # The derived set, root-anchored on the way in and re-relativised on the way
  # out (all_markdown emits repo-relative paths, which a bare `xargs grep` would
  # resolve against the caller's cwd). A migrated site that names the terminal
  # again, or a new site that starts to, reds here. ARCHITECTURE.md is the one
  # stated exception: its telemetry recipes and legacy attribution still count
  # historical records carrying the status, and #2580's state-machine section
  # names it to retire it.
  local found want e
  found="$(all_markdown | sed "s#^#$REPO_ROOT/#" \
           | xargs grep -l 'CONVERGED_WITH_RESIDUE' 2>/dev/null \
           | sed "s#^$REPO_ROOT/##" | sort)"
  want="$( { printf '%s\n' "${KEPT[@]}" ARCHITECTURE.md
             for e in "${NOT_YET_MIGRATED[@]}"; do printf '%s\n' "${e%%|*}"; done; } \
           | grep -E '\.md(\.tmpl)?$' | sort)"
  [ "$found" = "$want" ] || {
    echo "the markdown sites naming the residue terminal changed; expected:"
    echo "$want"; echo "got:"; echo "$found"; return 1; }
}

@test "#2580 ARCHITECTURE keeps the historical mapping and drops the loop's residue arm" {
  # The legacy attribution still reads historical records carrying the status as
  # the success they were; the loop's own narrowing has no arm for it, since the
  # loop no longer emits it.
  grep -q '`CONVERGED`/`CONVERGED_WITH_RESIDUE`/`SKIPPED` →' "$REPO_ROOT/ARCHITECTURE.md"
  local t; t="$(flat "$REPO_ROOT/ARCHITECTURE.md")"
  grep -q 'narrows onto the contract.s 4-value `outcome` enum: `CONVERGED` and `SKIPPED` → `success`' <<< "$t"
  grep -q 'The loop has no arm for `CONVERGED_WITH_RESIDUE` (#1435) since #2580 retired it' <<< "$t"
  run ! grep -q 'CONVERGED`, `CONVERGED_WITH_RESIDUE` (#1435) and `SKIPPED` → `success`' <<< "$t"
}

@test "#2580 AC5 AC10 the migrated sites state that CONVERGED is the only ending that opens a PR" {
  # #1435 swept the tree for this claim as stale; #2580 makes it the rule again,
  # so the sweep is inverted into positive pins at the sites that state it.
  local skill arch
  skill="$(flat "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")"
  arch="$(flat "$REPO_ROOT/ARCHITECTURE.md")"
  grep -q '\*\*`CONVERGED` is the only review-loop ending that opens a PR\*\*' <<< "$skill"
  grep -q '\*\*Exit 14 is retired (#2580)\*\* and is never reused.' <<< "$skill"
  grep -q '\*\*`CONVERGED` is the only review-loop ending that opens a PR\*\*; no escalation has ever opened one.' <<< "$arch"
  grep -q '### The residue terminal — retired (#1435, #2580)' "$REPO_ROOT/ARCHITECTURE.md"
  grep -q 'A residue-shaped round now ends the way it did before #1435: `ESCALATE_NO_CONVERGENCE` (12) at a non-converging rung, `BUDGET_EXHAUSTED` (13) at the ceiling.' <<< "$arch"
  grep -q 'Only `CONVERGED` proceeds to commit + open-pr' <<< "$arch"
  # the frontmatter, and the page generated from it
  local g
  for g in "$REPO_ROOT/development/skills/resolve-issue/SKILL.md" "$REPO_ROOT/docs/reference/commands.md"; do
    grep -q 'CONVERGED is the only review-loop ending that opens a PR: the residue terminal (exit 14) is retired' <<< "$(flat "$g")" || {
      echo "$g does not state the rule in the frontmatter wording"; return 1; }
  done
  grep -q 'The residue terminal is retired (#2580), so nothing reaches this branch.' <<< "$(flat "$RI_REF/residue.md")"
}

@test "#2580 AC1 the loop's header and exit table state the retirement" {
  local t; t="$(flat "$SCRIPTS/resolve-story-loop.zsh")"
  grep -q 'opened until this exits CONVERGED (0), the only review-loop ending that opens a # PR' <<< "$t"
  grep -qE '^#   14  retired by #2580' "$SCRIPTS/resolve-story-loop.zsh"
  # ...and nothing can emit it: no status, no code, no predicate, no next_ref row
  run ! grep -q 'loop_status="CONVERGED_WITH_RESIDUE"' "$SCRIPTS/resolve-story-loop.zsh"
  run ! grep -qE 'CONVERGED_WITH_RESIDUE\) +code=14' "$SCRIPTS/resolve-story-loop.zsh"
  run ! grep -q '_residue_holds()' "$SCRIPTS/resolve-story-loop.zsh"
  run ! grep -q 'next_ref="reference/residue/branch.md"' "$SCRIPTS/resolve-story-loop.zsh"
}

@test "#2580 non-vacuity: the list checks and the tripwire red on a planted mutation" {
  # (1) a not-yet-migrated site that loses the term reds the list check
  local probe="$BATS_TEST_TMPDIR/probe.md"
  printf 'The loop exits CONVERGED and opens a PR.\n' > "$probe"
  run ! grep -q 'CONVERGED_WITH_RESIDUE' "$probe"
  # (2) the tripwire's derivation sees a planted stray: copy a migrated site,
  # plant the term, and the same grep the tripwire runs now finds it
  sed 's/^## Single-issue flow$/## Single-issue flow — CONVERGED_WITH_RESIDUE/' \
    "$REPO_ROOT/development/skills/resolve-issue/SKILL.md" > "$probe"
  grep -q 'CONVERGED_WITH_RESIDUE' "$probe"
  run ! grep -q 'CONVERGED_WITH_RESIDUE' "$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  # (3) the inverted pin reds when the rule sentence is reverted
  sed 's/\*\*`CONVERGED` is the only review-loop ending that opens a$/**`CONVERGED` and the residue terminal open a/' \
    "$REPO_ROOT/development/skills/resolve-issue/SKILL.md" > "$probe"
  run ! grep -q '\*\*`CONVERGED` is the only review-loop ending that opens a PR\*\*' <<< "$(flat "$probe")"
}

@test "the residue filing path is gone: no tracked file names the builder or a step shard" {
  # #2600 deleted the filing script, its suite and the three step shards. Dead
  # code a suite keeps green looks alive, so the sweep covers every tracked file,
  # minus the dated records under docs/superpowers/, the fixtures, and this suite
  # (which has to spell the names to look for them).
  local hits
  hits="$(_filing_path_mentions "$REPO_ROOT")"
  [ -z "$hits" ] || { echo "the removed filing path is still named in:"; echo "$hits"; return 1; }
  # ...and the files themselves are gone
  local f
  for f in scripts/build-residue-issues.zsh reference/residue/step-1-plan.md \
           reference/residue/steps-2-3.md reference/residue/steps-4-5.md; do
    [ ! -e "$REPO_ROOT/development/skills/resolve-issue/$f" ]
  done
  [ ! -e "$REPO_ROOT/tests/build-residue-issues.bats" ]
}

@test "non-vacuity: the filing-path sweep reds on a planted mention" {
  # A scratch repo with one planted mention per needle in a swept file, the same
  # mentions in each excluded place, and a clean file: the sweep must name
  # exactly the swept files, so an empty result above means absence, not
  # blindness, and the exclusions exclude only what they say.
  local root="$BATS_TEST_TMPDIR/planted-tree" n
  mkdir -p "$root/docs/superpowers" "$root/tests/fixtures" "$root/a"
  git -C "$root" init -q
  local -a plants=(build-residue-issues step-1-plan.md steps-2-3.md steps-4-5.md)
  for n in 0 1 2 3; do
    printf 'see %s\n' "${plants[$n]}" > "$root/a/swept-$n.md"
  done
  printf 'see build-residue-issues\n' > "$root/docs/superpowers/old.md"
  printf 'see steps-4-5.md\n' > "$root/tests/fixtures/f.md"
  printf 'see step-1-plan.md\n' > "$root/tests/residue-terminal-documented.bats"
  printf 'nothing here\n' > "$root/a/clean.md"
  git -C "$root" add -A
  run _filing_path_mentions "$root"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'a/swept-0.md\na/swept-1.md\na/swept-2.md\na/swept-3.md')" ]
}

@test "open-pr appends a dossier and opens a PR only on CONVERGED, pinned by content" {
  # open-pr/SKILL.md is the delegated procedure for opening the PR. #2599 made
  # CONVERGED its only PR-opening ending: a loop that ran a round and ended
  # anything else, or a build-dossier refusal (including open > 0), stops it.
  local F="$REPO_ROOT/development/skills/open-pr/SKILL.md"
  local t; t="$(flat "$F")"
  grep -qF 'it ended **`CONVERGED`** (exit 0), the only review-loop ending that opens a PR,' <<< "$t"
  grep -qF "**If the caller's loop ran a round and ended anything else, stop and report to the caller: open no PR.**" <<< "$t"
  grep -qF '**A non-zero exit stops the PR**' <<< "$t"
  grep -qF "That includes build-dossier's refusal of a status that still carries open blockers (\`open > 0\`)" <<< "$t"
  grep -qF 'when the loop is known to have run a round and ended `CONVERGED`, treat empty output at exit 0 as the same error.' <<< "$t"
  grep -qF 'never open it without the dossier' <<< "$t"
  # the retired ending is gone from the procedure entirely
  run grep -c 'CONVERGED_WITH_RESIDUE' "$F"
  [ "$output" = "0" ]
}

@test "non-vacuity: open-pr's CONVERGED-only gate reds when the residue ending is restored" {
  # Revert the append gate to the two-ending wording in a scratch copy, the way
  # a regression would, and prove the gate needle above fails on it.
  local F="$REPO_ROOT/development/skills/open-pr/SKILL.md"
  local m="$BATS_TEST_TMPDIR/openpr.md"
  sed 's/^it ended \*\*`CONVERGED`\*\* (exit 0), the only review-loop ending that opens a PR,$/it reached a **PR-opening terminal** — `CONVERGED` (exit 0) **or** `CONVERGED_WITH_RESIDUE` (exit 14),/' "$F" > "$m"
  # the mutation landed
  grep -qF 'CONVERGED_WITH_RESIDUE' "$m"
  run grep -qF 'it ended **`CONVERGED`** (exit 0), the only review-loop ending that opens a PR,' <<< "$(flat "$m")"
  [ "$status" -eq 1 ]
}

@test "#2586 the Approver template treats open > 0 as a finding, pinned by CONTENT" {
  # The template is the artifact every bootstrapped repo's Approver reads the
  # dossier through. #1435 had it extend leniency to open blockers; #2580 retired
  # the terminal that produced them, and #2586 turned the rule round: open > 0
  # now means something bypassed the loop, so it is a REQUEST_CHANGES finding.
  local F="$REPO_ROOT/development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl"
  local t; t="$(flat "$F")"
  grep -q '`dimensions.<lens>.open > 0` is a finding: `REQUEST_CHANGES`.' <<< "$t"
  grep -q 'So a dossier that reports `open > 0` means something bypassed the loop, or the dossier does not describe this PR.' <<< "$t"
  grep -q 'raise a finding naming each lens with `open > 0`, and do not lower that lens.s residual-risk weight.' <<< "$t"
  grep -q 'An older dossier carries no `open` key at all; absent means 0.' <<< "$t"
  # the section's closing sentence names open > 0 as the dossier's one gate, and
  # Confidence calibration binds the posted verdict to it
  grep -q 'Within a dossier, `open > 0` (above) is the one thing that adds a gate; everything else in it is context that only ever \*reduces\* unnecessary friction.' <<< "$t"
  grep -q -- '- A Review dossier reporting `open > 0` on any lens: cap at `LOW`, whatever else holds.' <<< "$t"
  # the maintenance-bot special case yields to that cap rather than overriding it
  grep -q 'the bot is on the allowlist by default. It does not apply when the Review dossier reports `open > 0` on any lens: the cap at `LOW` above holds.' <<< "$t"
  run ! grep -q 'the dossier only ever \*reduces\* unnecessary friction, never adds a gate.' <<< "$t"
  # the leniency and its two companions are gone (#2586 AC2)
  run ! grep -q 'Do \*\*not\*\* `REQUEST_CHANGES` merely because `open > 0`' <<< "$t"
  run ! grep -q 'Read the Summary before extending that leniency' <<< "$t"
  run ! grep -q 'Unless it reports `open > 0`' <<< "$t"
  run ! grep -q 'CONVERGED_WITH_RESIDUE' "$F"
}

@test "#2586 non-vacuity: the template's open > 0 rule reds when inverted back to leniency" {
  # Invert the rule in a scratch copy, the way a regression would, and prove the
  # positive pin above fails on it.
  local F="$REPO_ROOT/development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl"
  local m="$BATS_TEST_TMPDIR/policy.md.tmpl"
  sed 's/is a finding: `REQUEST_CHANGES`\.\*\* The review$/is tracked risk: do not `REQUEST_CHANGES`.** The review/' "$F" > "$m"
  # the mutation landed
  run ! cmp -s "$F" "$m"
  run ! grep -q '`dimensions.<lens>.open > 0` is a finding: `REQUEST_CHANGES`.' <<< "$(flat "$m")"
}

@test "#2586 #2599 ARCHITECTURE states the dossier open field as always 0 and open > 0 as a finding, by content" {
  # The Review dossier section is the contract the template and build-dossier.zsh
  # implement; a revert to the residue-era leniency would contradict both.
  local t; t="$(flat "$REPO_ROOT/ARCHITECTURE.md")"
  grep -qF 'and `build-dossier.zsh` refuses anything else (#2599) — so every dossier it emits reports `open` 0, and the section has no "still open" rendering and no residue paragraph.' <<< "$t"
  grep -qF 'The field stays because the Approver backstops read it: `approver-policy-core` treats `open > 0` as a `REQUEST_CHANGES` finding with confidence capped at `LOW` (#2586)' <<< "$t"
  # the residue-era tracked-risk reading and the filed-follow-up rendering are gone
  run ! grep -qF 'reads `open > 0` as scoped, disclosed, *tracked* risk' <<< "$t"
  run ! grep -qF 'K still open (filed as follow-up issue(s))' <<< "$t"
}

@test "#2586 non-vacuity: the ARCHITECTURE dossier pins red when the rule reverts to leniency" {
  local F="$REPO_ROOT/ARCHITECTURE.md"
  local m="$BATS_TEST_TMPDIR/ARCHITECTURE.md"
  sed -e 's/treats$/reads/' -e 's/^   `open > 0` as a `REQUEST_CHANGES` finding with confidence capped at `LOW`$/   `open > 0` as scoped, disclosed, *tracked* risk/' -e 's/and `build-dossier.zsh` refuses$/and `build-dossier.zsh` accepts/' "$F" > "$m"
  # the mutation landed
  run ! cmp -s "$F" "$m"
  run ! grep -qF 'treats `open > 0` as a `REQUEST_CHANGES` finding with confidence capped at `LOW` (#2586)' <<< "$(flat "$m")"
  run ! grep -qF 'and `build-dossier.zsh` refuses anything else (#2599)' <<< "$(flat "$m")"
  run grep -qF 'reads `open > 0` as scoped, disclosed, *tracked* risk' <<< "$(flat "$m")"
  [ "$status" -eq 0 ]
}

@test "#1435 AC22 the round protocol states the cadence invariant on the AWAITING_FIX branch" {
  # §10's stated half. It has to live ON the branch where the session decides
  # what to do next — not in a preamble it will have scrolled past — because the
  # mistake it prevents is made exactly there: panel, then fix, then resume.
  # Pinned like the §8 documentation sites, since the sentence IS the deliverable.
  # #1503 moved the AWAITING_FIX branch into reference/review-loop.md, so that is
  # the file the invariant must live in; reading the corpus instead would let it
  # drift into the conductor, which a session reaching AWAITING_FIX has already
  # left behind for the reference. #2055 split review-loop.md into shards; the
  # AWAITING_FIX branch is now reference/review-loop/exit-20-awaiting-fix.md.
  local F="$RI_REF/review-loop/exit-20-awaiting-fix.md"
  local t; t="$(flat "$F")"
  grep -q 'a round.s findings reach the loop BEFORE that round.s fix pass runs, always' <<< "$t"
  # ...and it names the mechanical half, or the invariant is advice with no teeth
  grep -qF -- '--findings-tree' <<< "$t"
  grep -q 'STALE_FINDINGS' <<< "$t"
  # ...and it keeps the two attestations distinct, which is the thing a reader
  # is most likely to conflate
  grep -q 'separate from `--gate-attest`' <<< "$t"

  # ...and it sits INSIDE the AWAITING_FIX branch, near its top — not in a
  # preamble the session has already scrolled past. That is a POSITION claim,
  # and it is asserted by the helper above this test, so the non-vacuity control
  # below can drive the same code rather than re-deriving it.
  _invariant_in_awaiting_fix_branch "$F"
}

@test "#1435 non-vacuity: AC22's position pin reds when the invariant leaves its branch" {
  # A position claim that cannot fail is worse than none — it reports the
  # invariant is on the branch while it sits somewhere the session never reads.
  # Both halves drive the SHIPPED helper, so deleting the helper's guard reds
  # here rather than leaving a control that only re-measures grep.
  local F="$BATS_TEST_TMPDIR/moved-invariant.md"

  # (a) hoisted ABOVE the branch heading — the mutation AC22 exists to catch
  {
    printf 'a round%ss findings reach the loop BEFORE that round%ss fix pass runs, always.\n' "'" "'"
    printf 'filler\n'
    printf '3. **On `AWAITING_FIX` (exit 20)** — the round is over.\n'
  } > "$F"
  run -1 _invariant_in_awaiting_fix_branch "$F"

  # (b) present and correctly placed, but REFLOWED across two source lines. This
  #     must still PASS: the window is flattened before matching, so a cosmetic
  #     rewrap is not a defect and must not red. The pre-repair code got this
  #     backwards — it matched the sentence on flattened text but located it on a
  #     raw line, so a rewrap emptied the locator.
  {
    printf '3. **On `AWAITING_FIX` (exit 20)** — the round is over.\n'
    printf 'a round%ss findings reach the loop BEFORE that\n' "'"
    printf "round%ss fix pass runs, always.\n" "'"
  } > "$F"
  _invariant_in_awaiting_fix_branch "$F"

  # (c) the branch heading itself missing — the helper must refuse, not compute
  {
    printf 'a round%ss findings reach the loop BEFORE that round%ss fix pass runs, always.\n' "'" "'"
  } > "$F"
  run -1 _invariant_in_awaiting_fix_branch "$F"
}

@test "#1435 §9 non-vacuity: the PRE-AMENDMENT two-condition wording is gone everywhere" {
  # The pre-amendment claim, transcribed verbatim. If any site still says the
  # terminal takes two conditions IN THIS WORDING, a reader following it
  # concludes a delta round may declare residue — exactly what #1435 forbids.
  #
  # #1571 did NOT retire this guard, and the distinction is easy to lose: the
  # terminal really does take two conditions again — but they are 1 and 3, the
  # zero-CRITICAL window and the FULL SWEEP. The banned literal names the OTHER
  # pair, 1 and 2, from before the sweep was required; it is the one shape that
  # licenses a delta round to declare residue. So the ban stands on the literal
  # while the surviving pair is asserted, positively and by number, above.
  #
  # Never "fix" a red here by rewording the pair as `TWO conditions, BOTH
  # required` — that is the claim this test exists to keep out of the repo.
  local f hits=""
  while IFS= read -r f; do
    local t; t="$(flat "$REPO_ROOT/$f")"
    grep -q 'TWO conditions, BOTH required' <<< "$t" && hits+="$f (two-conditions)"$'\n'
    grep -q 'Two conditions, BOTH required' <<< "$t" && hits+="$f (two-conditions)"$'\n'
  done < <(all_markdown)
  grep -q 'TWO conditions, BOTH required' "$SCRIPTS/resolve-story-loop.zsh" && hits+="resolve-story-loop.zsh (two-conditions)"$'\n'
  [ -z "$hits" ] || { echo "stale two-condition claims still present:"; echo "$hits"; return 1; }
}

# --- #1435 restatement sweeps: the two claims that kept going stale ----------
#
# These are not belt-and-braces. Both invariants below were restated at half a
# dozen sites, both were changed mid-story, and BOTH were caught by reviewers at
# sites a targeted edit had missed — three rounds running. A closed list of files
# cannot fix that (the misses were always the site nobody listed), so these sweep
# the tracked tree and fail on the STALE CLAIM itself.
#
# (NB: no stray apostrophes in these comments — the inert-assertion scanner
# tracks quote parity across lines and an odd one desyncs the whole scan.)

# every tracked file that could carry a restatement, minus the vendored tree and
# minus this file (which must be able to quote the stale wording to test for it)
sweepable() {
  git -C "$REPO_ROOT" ls-files '*.md' '*.md.tmpl' '*.zsh' \
    | grep -v '^docs/superpowers/' \
    | grep -v '^tests/residue-terminal-documented.bats$'
}

# Every tracked file under $1 that names the removed residue filing path (#2600):
# the builder or one of the three step shards. Excluded the way sweepable()
# excludes: the dated records, the fixtures, and this suite. Prints repo-relative
# paths, one per line; prints nothing when none does.
_filing_path_mentions() {
  local root="$1"
  git -C "$root" ls-files \
    | grep -v -e '^docs/superpowers/' -e '^tests/fixtures/' -e '^tests/residue-terminal-documented.bats$' \
    | tr '\n' '\0' \
    | (cd "$root" && xargs -0 grep -lIE 'build-residue-issues|step-1-plan[.]md|steps-2-3[.]md|steps-4-5[.]md' 2>/dev/null) \
    || true
}

@test "#1435 no site still describes the residue idempotency key as parent-scoped" {
  # The key became label + exact title resolved over the UNION of the parent's
  # sub-issues and a repo-wide listing. The old key's TELL is the consequence it
  # implied: that an unattached issue is invisible to the read and gets
  # duplicated. That is now false and load-bearing — step 3's
  # created-but-unparented arm exists only because the key is repo-wide, so a
  # site still claiming the old key leads a model to reject that arm and route a
  # recoverable state to the wrong-changelist anomaly instead.
  local f hits=""
  while IFS= read -r f; do
    local t; t="$(tr '\n' ' ' < "$REPO_ROOT/$f" | tr -s ' ')"
    grep -q 'invisible to the idempotency read' <<< "$t" && hits+="$f (invisible-to-the-read)"$'\n'
    grep -q 'invisible to that read' <<< "$t" && hits+="$f (invisible-to-that-read)"$'\n'
    grep -qE 'every re-run duplicates them' <<< "$t" && hits+="$f (re-run-duplicates)"$'\n'
    # the same claim in the Approver template's spelling — "idempotency KEY",
    # "the NEXT run duplicates it". The needles above were transcribed from the
    # wordings that existed when the sweep was written, and that literalism is
    # exactly how this site slipped through: a sweep for stale CLAIMS has to
    # cover the phrasings the claim actually takes.
    grep -q 'invisible to the idempotency key' <<< "$t" && hits+="$f (invisible-to-the-key)"$'\n'
    grep -q 'the next run duplicates it' <<< "$t" && hits+="$f (next-run-duplicates)"$'\n'
    grep -qE 'so re-running this branch \*\*will\*\* duplicate it' <<< "$t" && hits+="$f (will-duplicate)"$'\n'
  done < <(sweepable)
  [ -z "$hits" ] || { echo "stale parent-scoped idempotency claims:"; echo "$hits"; return 1; }
}

@test "#1435 no site still states the residue rule as TWO conditions" {
  # Condition 3 (the declaring round ran as a full sweep) is what makes exit 14
  # speak for the whole diff. A site that omits it tells a reader a delta round
  # may declare residue — the defect the amendment exists to close — and this
  # exact miss survived two targeted sweeps, in the loop's own file header.
  local f hits=""
  while IFS= read -r f; do
    local t; t="$(tr '\n' ' ' < "$REPO_ROOT/$f" | tr -s ' ')"
    grep -q 'TWO conditions, BOTH required' <<< "$t" && hits+="$f (two-conditions-literal)"$'\n'
    grep -q 'Two conditions, BOTH required' <<< "$t" && hits+="$f (two-conditions-literal)"$'\n'
    grep -q '\*\*Both\*\* conditions are required' <<< "$t" && hits+="$f (both-conditions)"$'\n'
    grep -q 'when the residue condition holds: the last TWO rounds' <<< "$t" && hits+="$f (header-two-condition)"$'\n'
  done < <(sweepable)
  [ -z "$hits" ] || { echo "stale two-condition residue claims:"; echo "$hits"; return 1; }
}

@test "#1435 non-vacuity: both sweeps red on a planted stale claim" {
  # A grep for a string nobody writes passes forever. Plant each stale claim in a
  # scratch file the sweep would cover and prove the needle fires.
  local m="$BATS_TEST_TMPDIR/planted.md"
  printf 'an unparented issue is invisible to the idempotency read, whose key is\na sub-issue of the parent\n' > "$m"
  local t; t="$(tr '\n' ' ' < "$m" | tr -s ' ')"
  grep -q 'invisible to the idempotency read' <<< "$t"

  printf 'residue takes TWO conditions, BOTH required, and nothing else\n' > "$m"
  t="$(tr '\n' ' ' < "$m" | tr -s ' ')"
  grep -q 'TWO conditions, BOTH required' <<< "$t"

  # ...and the sweep really does read the files it claims to: the loop script is
  # in the list, and it really does mention the terminal.
  sweepable | grep -qx 'development/skills/resolve-issue/scripts/resolve-story-loop.zsh'
  sweepable | grep -qx 'development/skills/resolve-issue/SKILL.md'
  sweepable | grep -qx 'ARCHITECTURE.md'
}

@test "#1571 the fix-touched capture and its class consumer are DELIBERATELY untouched" {
  # Removing the predicate's read is not a licence to delete the capture: the
  # `class` stamp, the progress histogram and the waived-suggestion exemption all
  # still depend on it. This is the guard against an over-eager cleanup.
  local t; t="$(flat "$SCRIPTS/resolve-story-loop.zsh")"
  grep -q '_capture_fix_touched' <<< "$t" || {
    echo "the fix-touched capture is gone — the class stamp has no input"; return 1; }
  grep -q -- '--fix-touched' <<< "$t" || {
    echo "the consolidator is no longer handed --fix-touched — every blocker loses its class"; return 1; }
}

@test "#1571 no site still states residue as requiring fix-touched membership" {
  # The #1435 sweeps above needle PRE-#1435 wordings. #1571 retired condition 2
  # and produced a NEW family of stale claims that none of those needles can see
  # — and the whole suite was green with a dozen of them live (the loop's own
  # file header, five runtime diagnostics, the exit-14 verdict rendered into
  # progress.md, the skill frontmatter and the page generated from it, and two
  # sections of the explanation page). This is that family's sweep.
  local f hits=""
  while IFS= read -r f; do
    local t; t="$(tr '\n' ' ' < "$REPO_ROOT/$f" | tr -s ' ')"
    grep -q 'ALL THREE residue conditions' <<< "$t" && hits+="$f (all-three)"$'\n'
    grep -q 'All three\*\* conditions are required' <<< "$t" && hits+="$f (all-three-prose)"$'\n'
    grep -q 'residue is unreachable this round' <<< "$t" && hits+="$f (unreachable-this-round)"$'\n'
    grep -q 'residue will be unreachable next round' <<< "$t" && hits+="$f (unreachable-next-round)"$'\n'
    grep -q "lives in the previous round's own fix-touched files" <<< "$t" && hits+="$f (verdict-claim)"$'\n'
    grep -q 'confined to its own last fix pass' <<< "$t" && hits+="$f (frontmatter-claim)"$'\n'
    grep -q 'blocker in a file nobody had just touched' <<< "$t" && hits+="$f (budget-cause)"$'\n'
    grep -q 'residue condition 2 fails on it forever' <<< "$t" && hits+="$f (condition-2-live)"$'\n'
    grep -q 'the membership count below' <<< "$t" && hits+="$f (membership-count)"$'\n'
  done < <(sweepable)
  # docs/reference/commands.md IS already covered by `sweepable()` — the git
  # pathspec `*.md` matches nested paths, which the roster tripwire relies on.
  # It is read again here deliberately, as a belt-and-braces pin on a GENERATED
  # surface: it restates the frontmatter rather than authoring the claim, so a
  # regeneration is the way the claim comes back.
  local gen="docs/reference/commands.md"
  local gt; gt="$(tr '\n' ' ' < "$REPO_ROOT/$gen" | tr -s ' ')"
  grep -q 'confined to its own last fix pass' <<< "$gt" && hits+="$gen (frontmatter-claim)"$'\n'
  [ -z "$hits" ] || { echo "stale condition-2 claims still present:"; echo "$hits"; return 1; }
}

@test "#1571 non-vacuity: every needle of that sweep fires on a planted claim" {
  # One plant per needle — a sweep whose needles nobody can trip is a green light
  # forever, and this file has already paid for that once. Deliberately NOT a
  # count: a numeral here goes stale the moment a needle is added, and the
  # assertion below derives the pairing instead.
  local m="$BATS_TEST_TMPDIR/planted-1571.md" t
  local -a claims=(
    'the ending fires when ALL THREE residue conditions hold'
    'the terminal is narrow: **All three** conditions are required, always'
    'the set cannot be computed; residue is unreachable this round'
    'no stamp, so residue will be unreachable next round'
    "every blocker lives in the previous round's own fix-touched files"
    'a run whose blockers are confined to its own last fix pass ships'
    'it exhausted its budget on a blocker in a file nobody had just touched'
    'the loop drops them, so residue condition 2 fails on it forever'
    'guarded anyway, because the membership count below is vacuously 0'
  )
  local -a needles=(
    'ALL THREE residue conditions'
    'All three\*\* conditions are required'
    'residue is unreachable this round'
    'residue will be unreachable next round'
    "lives in the previous round's own fix-touched files"
    'confined to its own last fix pass'
    'blocker in a file nobody had just touched'
    'residue condition 2 fails on it forever'
    'the membership count below'
  )
  # `"${!needles[@]}"`, never `{1..8}`: bats runs under bash, whose arrays are
  # ZERO-indexed, so a 1..8 loop over an 8-element array skips element 0 entirely
  # and reads an UNSET index 8 — where both sides expand empty and the grep
  # becomes `grep -q "" <<< " "`, which matches unconditionally. The control then
  # reports eight needles proven while exercising seven and asserting nothing on
  # the eighth.
  local i
  for i in "${!needles[@]}"; do
    printf '%s\n' "${claims[$i]}" > "$m"
    t="$(tr '\n' ' ' < "$m" | tr -s ' ')"
    grep -q "${needles[$i]}" <<< "$t" || {
      echo "needle $i never fires on its own planted claim: ${needles[$i]}"; return 1; }
  done
}

@test "#1571 reference/residue/condition-2-removed.md states the SURVIVING pair and the upstream rail, by content" {
  # residue.md left the §9 exclusion set in #1571, but the derived detector is
  # proximity-based and matches its HISTORICAL sentence, not its normative one —
  # the same accidental-proximity shape this file already pins per-site for
  # ARCHITECTURE.md and the explanation page. The residue reference is what a
  # session that reaches the terminal actually opens, so pin it too — since
  # #2056, in the shard holding the #1571 section.
  local t; t="$(flat "$RI_REF/residue/condition-2-removed.md")"
  # Pin what the conditions ARE, not just their numbers: a needle that stops at
  # "and condition 3" leaves the parenthetical saying what condition 3 IS
  # deletable with the whole suite green — the proximity sweep is satisfied by
  # this file's HISTORICAL sentence, not by its normative one.
  grep -q 'condition 1 (the last two rounds are both zero-CRITICAL) and condition 3' <<< "$t" || {
    echo "residue/condition-2-removed.md no longer states which two conditions survived"; return 1; }
  grep -q 'condition 3 (the declaring round ran as a full sweep)' <<< "$t" || {
    echo "residue/condition-2-removed.md names condition 3 without saying it is the full sweep"; return 1; }
  # Pin the RAIL SENTENCE, not the bare tool name: condition-2-removed.md says
  # `scope-findings` twice, and the second is a different claim (what this story
  # did NOT change). A bare-name needle is satisfied by that one, so the rail
  # could be narrowed to a single round and this test would stay green — and a
  # one-round rail is exactly the reading that does not justify the removal.
  grep -q 'filters \*\*every\*\* round.s findings to the story diff' <<< "$t" || {
    echo "residue/condition-2-removed.md no longer states that scope-findings filters EVERY round's findings"; return 1; }
  grep -q 'only\*\* input to the changelist' <<< "$t" || {
    echo "residue/condition-2-removed.md no longer states that \$scoped is the only input to .blocking"; return 1; }
}

@test "#2599 the explanation pages state CONVERGED as the only PR-opening ending, by content" {
  # A negative sweep bans literal transcriptions of the old claim, so a reworded
  # revert slips past it; these positive pins require the current claim, which a
  # revert cannot satisfy however it is phrased. #2599 rewrote both pages.
  local t; t="$(flat "$REPO_ROOT/docs/explanation/review-loop.md")"
  grep -qF '**`CONVERGED` is the only ending that opens a PR**' <<< "$t"
  grep -qF 'run takes the automatic extension (#2576) instead, and if blockers survive it, the clean stop (#2579)' <<< "$t"
  grep -qF '### Why the residue ending was retired' <<< "$t"
  grep -qF 'still in the tracker under the `review-residue` label, as history.' <<< "$t"
  # the residue section and its conditions are gone, not merely joined
  run grep -qE 'What "residue" costs you|\*\*Two\*\* conditions are required|Converged with residue' <<< "$t"
  [ "$status" -eq 1 ]
  t="$(flat "$REPO_ROOT/docs/explanation/workflow-resolve-issue.md")"
  grep -qF '**This is the only ending that opens a PR.**' <<< "$t"
  grep -qF 'takes an automatic extension (#2576) and, if blockers survive it, stops cleanly (#2579)' <<< "$t"
  run grep -qF 'labelled `review-residue`' <<< "$t"
  [ "$status" -eq 1 ]
}

@test "#1571 reference/review-loop.md's correction note is pinned" {
  # The round protocol is byte-frozen and still states the retired condition
  # twice (the parked-blocker guarantee, and "a failure to compute the set only
  # makes a residue ending unreachable"). The ONLY thing correcting them is the
  # note appended below the span — and nothing asserted it: the §9 proximity
  # sweep is satisfied by the FROZEN text, the roster tripwire counts files, and
  # the negative sweep needles literals that appear nowhere in the frozen span.
  # Deleting the whole note passed the suite, leaving the file a session reads on
  # EVERY round telling it a parked-only run escalates by design.
  # #2055 split review-loop.md into shards; the note now follows the frozen
  # span in reference/review-loop/exit-20-awaiting-fix.md.
  local t; t="$(flat "$RI_REF/review-loop/exit-20-awaiting-fix.md")"
  grep -q 'Residue condition 2 was removed (#1571)' <<< "$t" || {
    echo "review-loop.md no longer records that condition 2 was removed"; return 1; }
  grep -q 'takes \*\*two\*\* conditions' <<< "$t" || {
    echo "review-loop.md no longer states the surviving pair"; return 1; }
  grep -q 'Only the residue predicate stopped reading it' <<< "$t" || {
    echo "review-loop.md no longer says the fix-touched set is still load-bearing elsewhere"; return 1; }
  # ...and the correction to the frozen parking rule, which is the one claim in
  # that span this story makes false. #2055 put that correction (and the #1581
  # deferral below) in carry.md, beside the carry rules it amends.
  t="$(flat "$RI_REF/review-loop/carry.md")"
  grep -q 'do not read a parked-only run as escalating by design' <<< "$t" || {
    echo "review-loop.md no longer retires the frozen parked-only inference"; return 1; }
  # Pin the DEFERRAL's claim, not the bare number: `grep '#1581'` matches the
  # digits anywhere, so the round-4 CRITICAL could be restored verbatim —
  # "the residue branch therefore has to drop those parked candidates itself,
  # matching on title; #1581 will settle the exact key" — with every needle here
  # still firing, putting the three-field hand match (which silently drops a
  # NON-parked sibling at a colliding spot) back in the file a session reads
  # every round.
  grep -q 'files its plan as built' <<< "$t" || {
    echo "review-loop.md no longer says the branch files the plan as built"; return 1; }
  grep -q 'Do not attempt it here' <<< "$t" || {
    echo "review-loop.md no longer forbids improvising the parked match"; return 1; }
  grep -q '#1581' <<< "$t" || {
    echo "review-loop.md no longer defers the parked handling to #1581"; return 1; }
  # ...and neither the index nor ANY shard may carry the instruction the
  # deferral replaced — the whole of what review-loop.md was before #2055
  run ! grep -rq 'has to drop those' "$RI_REF/review-loop.md" "$RI_REF/review-loop"
}

@test "#1571 the residue reference keeps its condition-2 heading, and no user page points at it any more" {
  # The explanation page once sent readers to this section by name. #2599
  # retired that page's residue section, so the pointer is gone; the heading
  # stays pinned until #2601 deletes the shard whole.
  local heading='Condition 2 — removed; the story-diff rail is upstream'
  grep -qF "## $heading (#1571)" "$RI_REF/residue/condition-2-removed.md" || {
    echo "residue/condition-2-removed.md's #1571 section heading changed"; return 1; }
  run grep -rqF "$heading" "$REPO_ROOT/docs/explanation" "$REPO_ROOT/docs/how-to"
  [ "$status" -eq 1 ]
}

@test "#1920 reference/residue/ states the risk-threshold procedure, by content" {
  # The procedure lives OUTSIDE the frozen residue-branch span, so nothing that
  # verifies the span guards it. #2600 removed the filing steps it amended, so
  # the needles left are the clauses the loop's risk pass reads from it: how to
  # read the variable and its three states (risk-pass.md takes them from §
  # *Risk threshold*), and both probability definitions and all four impact
  # anchors (risk-pass.md takes them from § *1. Assess every residual blocker*).
  local t; t="$(flat "$RI_REF/residue/risk-threshold.md")"
  local -a needles=(
    'printenv corner_case_risk_threshold'
    'Skip the rest of this section: make no assessment, pass no new flag.'
    'say so in the PR Summary in one line naming the value'
    '**On — any other value** (`0.05`, `.05`, `1`).'
    'the probability that a plausible future change breaks exactly that unpinned behaviour'
    'the probability that the described input or state actually arises'
    '| `1.0` | a false result that is trusted'
    '| `0.7` | a hang, runaway resource use'
    '| `0.4` | degraded or misleading output'
    '| `0.1` | cosmetic'
  )
  local n
  for n in "${needles[@]}"; do
    grep -qF -- "$n" <<< "$t" || { echo "residue/risk-threshold.md lost the #1920 clause: $n"; return 1; }
  done
  # ...and the heading the risk pass names. The pointer is prose, not a
  # `see reference/X.md §` pointer, so the conductor-budget pointer sweep does
  # not check it; the ARCHITECTURE.md section names the same heading.
  grep -qxF '## Risk threshold — assess before filing (#1920)' "$RI_REF/residue/risk-threshold.md" || {
    echo "residue/risk-threshold.md renamed the #1920 section heading that risk-pass.md and ARCHITECTURE.md name"
    return 1; }
  # branch.md, after its frozen block, says the filing steps are gone
  grep -qF -- '**The filing steps the block above leads into were removed (#2600)**' \
    <<< "$(flat "$RI_REF/residue/branch.md")"
}

@test "#1921 AC10 reference/residue/risk-threshold.md keeps the section the risk pass points at, and no builder protocol" {
  # #1921 made the loop's risk pass assess every blocker in-loop, pointing at
  # section 1 for its definitions. #2600 removed the builder that reused those
  # stamps, so what is left is that section and the emptied amendments heading.
  local f="$RI_REF/residue/risk-threshold.md"
  local t; t="$(flat "$f")"
  [ "$(grep -cxF '## Risk threshold — assess before filing (#1920)' "$f")" -eq 1 ]
  [ "$(grep -cxF '### 1. Assess every residual blocker — before step 1' "$f")" -eq 1 ]
  [ "$(grep -cxF '### 2. Amendments to the frozen branch' "$f")" -eq 1 ]
  grep -qF -- 'For a test-strength finding, impact is the impact of the **defect the unpinned behaviour would let through**' <<< "$t"
  grep -qF -- 'The filing steps these amendments changed were removed with the filing path (#2600), so there is nothing left to amend.' <<< "$t"
  # the builder protocol is gone
  lacks "$t" 'builder'
  lacks "$t" '--dropped-file'
  lacks "$t" 'assessed_in'
  lacks "$t" 're-run the builder'
  # the pre-#1921 claim that the loop is untouched, and #1921 as future work, are gone
  lacks "$t" 'what the loop fixes before it gets there, and the dossier itself'
  lacks "$t" 'are the follow-up story (#1921)'
}

@test "#1921 AC11 reference/review-loop.md states the risk pass after the decided pass, by content" {
  # #2055 split review-loop.md into shards, one per pass: each heading is now
  # pinned in its own shard, and "after" is the index's read order, which is
  # the only order three separate files have.
  local L="$RI_REF/review-loop"
  local f="$L/risk-pass.md"
  grep -qxF '### The decided pass — run every `decides:` command before consolidating (#1584)' "$L/decided-pass.md"
  grep -qxF '### The risk pass — assess every blocking finding before consolidating (#1921)' "$f"
  grep -qxF '### Carry accounting — confirmed, re-raised, unconfirmed (#1583)' "$L/carry.md"
  local decided risk carry
  decided=$(grep -nF '`reference/review-loop/decided-pass.md`' "$RI_REF/review-loop.md" | cut -d: -f1)
  risk=$(grep -nF '`reference/review-loop/risk-pass.md`' "$RI_REF/review-loop.md" | cut -d: -f1)
  carry=$(grep -nF '`reference/review-loop/carry.md`' "$RI_REF/review-loop.md" | cut -d: -f1)
  [ -n "$decided" ]
  [ -n "$risk" ]
  [ -n "$carry" ]
  [ "$decided" -lt "$risk" ]
  [ "$risk" -lt "$carry" ]
  local t; t="$(flat "$f")"
  local -a needles=(
    'printenv corner_case_risk_threshold'
    '**Off** (unset, empty, any spelling of zero): skip this pass, except in an extension round (below).'
    '**Ignored** (not a decimal in [0, 1] with at most three decimals): behave as off'
    'whose severity is `CRITICAL` or `WARNING` after the decided pass'
    'Use the definitions `reference/residue/risk-threshold.md` § *1. Assess every residual blocker* gives'
    '**Severity and impact are independent.**'
    '**Assess afresh every round.** A finding re-raised in a later round is assessed again'
    '`<work-dir>/risk-<R>.json`'
    '--risk <work-dir>/risk-<R>.json'
    '**Never demoted**, at any threshold or risk: a `CRITICAL` item, a human-promoted item (`promoted: true`), and an item a tool decided red'
    'A dedup group is demoted only when every `WARNING` member was assessed and its **highest** member risk is below the threshold.'
    'A demoted finding never disappears.'
    'The residue branch reuses the final round'"'"'s stamp instead of assessing a blocker a second time'
  )
  local n
  for n in "${needles[@]}"; do
    grep -qF -- "$n" <<< "$t" || { echo "review-loop.md lost the #1921 clause: $n"; return 1; }
  done
}

# --- #2580: the retirement notes, outside the frozen spans ------------------

@test "#2580 AC4 AC5 every kept shard carries its retirement note outside the frozen span" {
  grep -q 'The exit-14 arm of step 5 is retired by #2580 and can no longer fire.' <<< "$(flat "$RI_REF/interactive/extension-grant.md")"
  grep -q 'The residue terminal is retired (#2580).\*\* The block above still sends a `CONVERGED_WITH_RESIDUE` exit to the residue branch; that can no longer happen.' <<< "$(flat "$RI_REF/escalation.md")"
  grep -q 'the promotion phase only ever follows `CONVERGED`.' <<< "$(flat "$RI_REF/promotion/step-4-sub-loop.md")"
  grep -q 'so the phase only ever follows `CONVERGED`, and the sub-loop.s exit 14 stays as unreachable as the block already says.' <<< "$(flat "$RI_REF/promotion/step-7-terminal.md")"
  grep -q 'only a \*\*zero-blocker\*\* delta round promotes the closing sweep' <<< "$(flat "$RI_REF/review-loop/exit-20-awaiting-fix.md")"
  grep -q 'Retired with the residue terminal (#2580).\*\* The block below runs only on `CONVERGED_WITH_RESIDUE` (exit 14), which the loop no longer emits, so this branch never runs.' <<< "$(flat "$RI_REF/residue/branch.md")"
  # every note sits OUTSIDE its file's frozen span: the frozen text still matches
  # the pinned pre-move commit
  run -0 zsh "$SCRIPTS/verify-reference-move.zsh"
}

@test "#2580 AC5 the migrated shards no longer route anything to the residue branch" {
  grep -q 'continue to the version bump (§4). The waived suggestions still' <<< "$(flat "$RI_REF/promotion/gate.md")"
  grep -q 'the round that can open one (`CONVERGED`) is a full-scope round' <<< "$(flat "$RI_REF/review-loop/delta-rounds.md")"
  # the conductor still lists the residue branch's pointer (the reachability
  # sweeps need every shipped shard reachable) but says it can no longer be
  # reached; #2600 removes both with the filing path
  grep -q 'The residue branch it pointed to stays listed below, unreachable, until #2600 removes the filing path.' <<< "$(flat "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")"
}

@test "#2580 AC6 SKILL.md §6 no longer carries the residue Summary duty" {
  local t; t="$(flat "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")"
  grep -q 'The residue Summary duty (#1435) went with its terminal (#2580): a run that opens its PR has no open blocker left to disclose.' <<< "$t"
  grep -q 'reached `CONVERGED` (§3.5) — the only PR-opening terminal since #2580 — append the \*\*Review dossier\*\*' <<< "$t"
  run ! grep -q 'Residue in the PR body (#1435)' <<< "$t"
  run ! grep -q 'reference/residue/step-1-plan.md' "$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
}

@test "#2580 the rule sentences of the retirement are pinned where they are stated" {
  grep -qF '**Exit 14 is retired (#2580)** and is never reused.' "$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  grep -qF 'and continue to the version bump (§4). The waived suggestions still' <<< "$(flat "$RI_REF/promotion/gate.md")"
  local r; r="$(flat "$RI_REF/residue.md")"
  grep -qF 'The loop no longer emits that status and no `next_ref` names these shards: `CONVERGED` is the only review-loop ending that opens a PR.' <<< "$r"
  grep -qF '#2600 removed the filing path — the script that built the plan and the three step shards that filed it. `reference/residue/risk-threshold.md` stays for good, because the risk pass reads it.' <<< "$r"
  grep -qF 'It is split into shards under `reference/residue/`, each at most 20,000 bytes (#2056).' <<< "$r"
  grep -qF 'One such block remains: `residue-branch` in `branch.md`. The three step blocks were deleted with their shards (#2600).' <<< "$r"
  grep -qF 'Nothing reaches this branch, and there is nothing further to read for it: `reference/residue/risk-threshold.md` § *Risk threshold — assess before filing (#1920)* stays only because the loop'"'"'s risk pass reads it.' <<< "$(flat "$RI_REF/residue/branch.md")"
  grep -qF '`CONVERGED` is the only ending that opens a PR.' <<< "$(flat "$RI_REF/review-loop/exit-20-awaiting-fix.md")"
}
