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

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/resolve-issue/scripts"
  # the story's Scope §8 site list, as paths
  ROSTER=(
    "$SCRIPTS/resolve-story-loop.zsh"
    "$SCRIPTS/build-dossier.zsh"
    "$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
    "$REPO_ROOT/development/skills/open-pr/SKILL.md"
    "$REPO_ROOT/ARCHITECTURE.md"
    "$REPO_ROOT/docs/explanation/review-loop.md"
    "$REPO_ROOT/docs/reference/commands.md"
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

@test "#1435 every site in the story's roster names CONVERGED_WITH_RESIDUE" {
  local f
  for f in "${ROSTER[@]}"; do
    grep -q 'CONVERGED_WITH_RESIDUE' "$f" || {
      echo "site does not name the residue terminal: $f"; return 1; }
  done
}

@test "#1435 the exit code 14 is stated wherever the terminal is introduced" {
  # A status name without its code sends a reader to guess at the one thing a
  # caller actually branches on. build-dossier is excluded on purpose: it names
  # the terminal but never dispatches on the code.
  #
  # The needle is anchored to the terminal, NOT to a bare `14`: every one of
  # these files carries the attribution `#1435`, whose own text contains `14`, so
  # a loose match would pass on all five with every mention of the exit code
  # deleted — a green test about nothing. Requiring `14` within a short span of
  # `CONVERGED_WITH_RESIDUE` on the FLATTENED text ties the number to its role
  # while still tolerating a line wrap between them.
  #
  # Proximity ALONE is not enough, though, and this is the trap: the real sites
  # spell it `` `CONVERGED_WITH_RESIDUE` (#1435) `` — backtick, space, paren,
  # hash — four non-alphanumerics, well inside the span, so `1435` itself would
  # satisfy a needle that stops at `14`. The trailing `([^0-9]|$)` is what
  # requires the matched `14` to be a whole number rather than a prefix of one.
  # (`grep -E` has no lookahead, so the character class is the portable form; it
  # still matches `(14, #1435)`, `(exit 14)` and `#   14  CONVERGED…`.)
  # open-pr/SKILL.md is IN this list, and is the site the comment above is really
  # about: its procedure is the one that branches on the loop's exit status when
  # deciding whether to append the dossier. Omitting it would let
  # "(exit 14, #1435)" be deleted from the delegated procedure with the whole
  # suite green.
  local f
  for f in "$SCRIPTS/resolve-story-loop.zsh" \
           "$REPO_ROOT/development/skills/resolve-issue/SKILL.md" \
           "$REPO_ROOT/development/skills/open-pr/SKILL.md" \
           "$REPO_ROOT/ARCHITECTURE.md" \
           "$REPO_ROOT/docs/explanation/review-loop.md" \
           "$REPO_ROOT/docs/reference/commands.md"; do
    grep -qE 'CONVERGED_WITH_RESIDUE[^A-Za-z0-9]{0,40}(exit )?[`*]{0,2}14([^0-9]|$)' <<< "$(flat "$f")" || {
      echo "site does not state exit 14 next to the terminal it belongs to: $f"; return 1; }
  done
}

@test "#1435 roster tripwire: exactly six markdown sites name the terminal" {
  # A derived sweep answers "do the sites agree?", never "did a site appear or
  # vanish?" — so the count is recorded here and a seventh (or fifth) restatement
  # reds until this file is updated in the same PR.
  #
  # It has already earned its keep: `open-pr/SKILL.md` is NOT in the story's
  # Scope §8 list, but it owns the delegated procedure that appends the dossier,
  # and it gated that on `CONVERGED` alone — so a residue PR would have shipped
  # with no dossier at all. Adding it here is the tripwire working, not a
  # loosening of it.
  # ROOT-ANCHORED on the way in, re-relativised on the way out: all_markdown
  # emits repo-relative paths, which a bare `xargs grep` resolves against the
  # CALLER's cwd — so the sweep would find nothing (and the comparison would fail
  # for a reason that has nothing to do with the roster) whenever bats runs from
  # anywhere but the repo root. The sibling repo-wide sweep below already
  # prefixes "$REPO_ROOT/" for the same reason.
  local found
  found="$(all_markdown | sed "s#^#$REPO_ROOT/#" \
           | xargs grep -l 'CONVERGED_WITH_RESIDUE' 2>/dev/null \
           | sed "s#^$REPO_ROOT/##" | sort)"
  [ "$found" = "ARCHITECTURE.md
development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl
development/skills/open-pr/SKILL.md
development/skills/resolve-issue/SKILL.md
docs/explanation/review-loop.md
docs/reference/commands.md" ] || {
    echo "markdown roster changed; expected the six known sites, got:"
    echo "$found"; return 1; }
}

@test "#1435 the loop's own four internal sites carry the terminal" {
  local S="$SCRIPTS/resolve-story-loop.zsh"
  # the exit-code header block
  grep -qE '^#   14  CONVERGED_WITH_RESIDUE' "$S"
  # the $loop_status -> exit code map
  grep -qE 'CONVERGED_WITH_RESIDUE\) code=14' "$S"
  # the per-round verdict case, which is what progress.md renders
  grep -q 'CONVERGED_WITH_RESIDUE)$' "$S"
  # ...and the telemetry outcome mapping, whose deliberate catch-all is
  # `failed`, so an unnamed status would be counted a failure
  grep -qE 'CONVERGED\|CONVERGED_WITH_RESIDUE\|SKIPPED\)' "$S"
}

@test "#1435 ARCHITECTURE carries BOTH copies of the outcome mapping" {
  # The mapping is written twice — once for v1 records, once for the v0 legacy
  # attribution — and a half-applied edit would make the rollup disagree with
  # itself about whether a residue run succeeded.
  grep -q 'CONVERGED`, `CONVERGED_WITH_RESIDUE` (#1435) and `SKIPPED` → `success`' \
    "$REPO_ROOT/ARCHITECTURE.md"
  grep -q '`CONVERGED`/`CONVERGED_WITH_RESIDUE`/`SKIPPED` →' "$REPO_ROOT/ARCHITECTURE.md"
}

@test "#1435 no tracked markdown still asserts that ONLY CONVERGED opens a PR" {
  # REPO-WIDE, not a roster: the failure mode this guards against is a stale
  # claim surviving in a file nobody listed.
  local f hits=""
  while IFS= read -r f; do
    local t; t="$(flat "$REPO_ROOT/$f")"
    grep -q 'Only `CONVERGED` proceeds to commit' <<< "$t" && hits+="$f (only-CONVERGED-opens-a-PR)"$'\n'
    grep -q 'no PR is opened until it exits `CONVERGED`\.' <<< "$t" && hits+="$f (until-it-exits-CONVERGED)"$'\n'
    grep -q 'every run the loop \*\*converges\*\* ends on a' <<< "$t" && hits+="$f (every-converging-run-ends-full)"$'\n'
  done < <(all_markdown)
  [ -z "$hits" ] || { echo "stale pre-#1435 claims still present:"; echo "$hits"; return 1; }
}

@test "#1435 the loop's own header no longer ends its sentence at CONVERGED" {
  # the script half of the same claim — the sweep above only reads markdown
  run ! grep -q 'opened until this exits CONVERGED\.' "$SCRIPTS/resolve-story-loop.zsh"
}

@test "#1435 non-vacuity: each negative needle reds on a real mutated site" {
  # A grep for a string nobody writes passes forever. Mutate a PROSE site and a
  # CODE site back to their pre-#1435 wording and prove each needle catches it,
  # so a green run means the claim is genuinely gone rather than never
  # expressible. Both file kinds, because the flattening these needles depend on
  # can behave differently on a comment-wrapped line than on prose.
  local probe="$BATS_TEST_TMPDIR/probe.md"

  # (1) PROSE site — ARCHITECTURE's two-line sentence, verbatim as it stood
  printf 'runs\n**entirely in the worktree** — nothing is pushed and no PR is opened until it\nexits `CONVERGED`. It sits in\n' > "$probe"
  grep -q 'no PR is opened until it exits `CONVERGED`\.' <<< "$(flat "$probe")"

  # (2) PROSE site — the open-pr sentence, and review-loop.md's full-sweep promise
  printf 'Only `CONVERGED` proceeds to commit + open-pr; no escalation ever opens a PR\n' > "$probe"
  grep -q 'Only `CONVERGED` proceeds to commit' <<< "$(flat "$probe")"
  printf 'escalating opens no PR at all. So: every run the loop **converges** ends on a\nfull-diff review.\n' > "$probe"
  grep -q 'every run the loop \*\*converges\*\* ends on a' <<< "$(flat "$probe")"

  # (3) CODE site — the loop header comment, wrapped exactly as it was
  local cprobe="$BATS_TEST_TMPDIR/probe.zsh"
  printf '# round budget. Runs entirely in the worktree: nothing is pushed and no PR is\n# opened until this exits CONVERGED.\n' > "$cprobe"
  grep -q 'opened until this exits CONVERGED\.' "$cprobe"

  # (4) and the ROSTER check reds when a site loses the term
  local roster_probe="$BATS_TEST_TMPDIR/roster.md"
  printf 'The loop exits CONVERGED and opens a PR.\n' > "$roster_probe"
  run ! grep -q 'CONVERGED_WITH_RESIDUE' "$roster_probe"

  # (5) the exit-14 needle is NOT the bare substring `14`: a site that names the
  # terminal and cites the issue, but never states the code, must red. Both
  # spellings are probed — the DISTANT one, and the ADJACENT one the real sites
  # actually use, which is the shape a proximity-only needle passes on.
  local code_probe="$BATS_TEST_TMPDIR/code.md"
  printf 'A run can end CONVERGED_WITH_RESIDUE instead of escalating (#1435).\n' > "$code_probe"
  run ! grep -qE 'CONVERGED_WITH_RESIDUE[^A-Za-z0-9]{0,40}(exit )?[`*]{0,2}14([^0-9]|$)' <<< "$(flat "$code_probe")"
  printf '### Residue: `CONVERGED_WITH_RESIDUE` (#1435)\n' > "$code_probe"
  run ! grep -qE 'CONVERGED_WITH_RESIDUE[^A-Za-z0-9]{0,40}(exit )?[`*]{0,2}14([^0-9]|$)' <<< "$(flat "$code_probe")"
  printf '`CONVERGED`, `CONVERGED_WITH_RESIDUE` (#1435) and `SKIPPED` are success.\n' > "$code_probe"
  run ! grep -qE 'CONVERGED_WITH_RESIDUE[^A-Za-z0-9]{0,40}(exit )?[`*]{0,2}14([^0-9]|$)' <<< "$(flat "$code_probe")"
  # ...and it matches when the code IS stated, in each spelling the sites use
  printf 'ends `CONVERGED_WITH_RESIDUE` (exit 14) instead (#1435).\n' > "$code_probe"
  grep -qE 'CONVERGED_WITH_RESIDUE[^A-Za-z0-9]{0,40}(exit )?[`*]{0,2}14([^0-9]|$)' <<< "$(flat "$code_probe")"
  printf '#   14  CONVERGED_WITH_RESIDUE    (the run OPENS ITS PR)\n' > "$code_probe"
  grep -qE '^#   14  CONVERGED_WITH_RESIDUE' "$code_probe"
}

@test "#1435 SKILL.md 3.5 actually invokes the builder, with both labels" {
  # build-residue-issues.zsh has NO caller inside the repo's scripts — SKILL.md
  # is the only thing that runs it and the only thing that turns its plan into
  # real issues. Without this, deleting the §3.5 code block leaves the suite
  # green while a shipped script becomes dead code and residue runs file nothing.
  local S="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  grep -q 'scripts/build-residue-issues.zsh' "$S"
  # the label pair the builder EMITS and the pair the skill APPLIES must not
  # drift apart — they are two halves of the same idempotency key
  grep -q -- '--label review-residue' "$S"
  grep -q -- '--label needs-refinement' "$S"
  # ...and the attach that makes the idempotency read able to see them at all
  grep -q 'sub_issues' "$S"

  # The POSITIVE counterpart to the two negative sweeps below. Those ban literal
  # transcriptions of the OLD claims, so a REWORDED revert slips past them; these
  # require the current claims to be present, which a revert cannot satisfy
  # however it is phrased.
  local t; t="$(flat "$S")"
  # the union key itself
  grep -q 'unparented issue IS matched by the idempotency key' <<< "$t"
  # ...and the fourth-combination diagnostic's stated half, whose only other
  # coverage is the script's own tests — deleting it here is invisible otherwise
  grep -q 'losing only the \*\*parent\*\* read leaves the plan filtered on the repo-wide half' <<< "$t"
}

@test "#1435 open-pr carries BOTH residue rules, pinned independently" {
  # open-pr/SKILL.md is the delegated procedure, and #1435 widened TWO separate
  # rules in it:
  #   (a) the dossier-APPEND gate — which terminals get a dossier at all;
  #   (b) the EMPTY-OUTPUT guard — on which terminals an exit-0 silence from
  #       build-dossier is an error rather than the sanctioned no-loop no-op.
  # Every other assertion in this file is satisfied by rule (a) alone: the roster
  # test greps the file once, the exit-14 proximity test matches at (a) (rule (b)
  # spells the terminal with a letter immediately after, so it never carried that
  # needle), and the roster tripwire counts FILES, not occurrences. Delete rule
  # (b)'s "either PR-opening terminal" clause and the whole suite stays green
  # while the guard reverts to a CONVERGED-means-exit-0 reading — which is
  # precisely how a residue PR ships with an empty dossier, on the silence that
  # rule exists to catch.
  local F="$REPO_ROOT/development/skills/open-pr/SKILL.md"
  local t; t="$(flat "$F")"

  # (a) the append gate names both terminals, with the code beside the new one
  grep -q 'PR-opening terminal\*\* — `CONVERGED` (exit 0) \*\*or\*\* `CONVERGED_WITH_RESIDUE` (exit 14, #1435)' <<< "$t"
  # (b) the empty-output guard names both terminals in its own sentence
  grep -q 'on \*\*either\*\* PR-opening terminal, `CONVERGED` or `CONVERGED_WITH_RESIDUE` — treat empty output at exit 0 as the same error' <<< "$t"

  # ...and an occurrence tripwire, so a THIRD rule (or the loss of one) has to be
  # acknowledged here rather than passing under the file-level roster count. The
  # two occurrences are exactly (a) and (b) above.
  [ "$(grep -c 'CONVERGED_WITH_RESIDUE' "$F")" -eq 2 ]
}

@test "#1435 non-vacuity: each open-pr needle reds when its own rule is reverted" {
  # Both needles above are long literals, and a long literal that nobody proves
  # discriminating is the same trap as a grep for a string nobody writes. Mutate
  # each rule back to its pre-#1435 wording IN ISOLATION and prove the matching
  # needle is the one that fails — otherwise a single edit could satisfy both.
  local F="$REPO_ROOT/development/skills/open-pr/SKILL.md"
  local m="$BATS_TEST_TMPDIR/openpr.md"

  # (a) reverted: the append gate names CONVERGED only
  sed 's/PR-opening terminal\*\* — `CONVERGED` (exit 0) \*\*or\*\*/converged terminal** — `CONVERGED` (exit 0), not/' "$F" > "$m"
  local ta; ta="$(flat "$m")"
  run ! grep -q 'PR-opening terminal\*\* — `CONVERGED` (exit 0) \*\*or\*\* `CONVERGED_WITH_RESIDUE` (exit 14, #1435)' <<< "$ta"
  # rule (b) is untouched, so ITS needle still matches — the two are independent
  grep -q 'on \*\*either\*\* PR-opening terminal, `CONVERGED` or `CONVERGED_WITH_RESIDUE` — treat empty output at exit 0 as the same error' <<< "$ta"

  # (b) reverted: the empty-output guard drops the terminal pair. `sed` is
  # line-oriented and this rule WRAPS, so the pattern has to sit inside one raw
  # line — the needles above read the flattened text, the mutations do not.
  sed 's/^`CONVERGED_WITH_RESIDUE` — treat empty output/it — treat empty output/' "$F" > "$m"
  local tb; tb="$(flat "$m")"
  run ! grep -q 'on \*\*either\*\* PR-opening terminal, `CONVERGED` or `CONVERGED_WITH_RESIDUE` — treat empty output at exit 0 as the same error' <<< "$tb"
  # ...and rule (a) survives, which is exactly why the roster and exit-14 tests
  # stayed green on this mutation before the pin above existed
  grep -q 'PR-opening terminal\*\* — `CONVERGED` (exit 0) \*\*or\*\* `CONVERGED_WITH_RESIDUE` (exit 14, #1435)' <<< "$tb"
}

@test "#1435 resolve-issue §6 carries its OWN dossier-append gate, pinned by content" {
  # Round 6 pinned open-pr's two rules by content precisely because the roster
  # tripwire counts FILES, not occurrences. The identical gap sat one file over:
  # resolve-issue/SKILL.md §6 restates the same gate in its own words, and nothing
  # grepped it. `CONVERGED_WITH_RESIDUE` occurs dozens of times in that file, so
  # the roster test is satisfied whatever §6 says, and the exit-14 proximity test
  # is satisfied by the terminal list near the top — reverting §6 to
  # CONVERGED-only left the whole suite green while the DELEGATING skill told the
  # operator to skip the dossier on exactly the PR that must not lose it.
  local F="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  local t; t="$(flat "$F")"
  grep -q 'reached a \*\*PR-opening\*\* terminal (§3.5) — `CONVERGED` \*\*or\*\* `CONVERGED_WITH_RESIDUE` (#1435); those two, and no escalation — append the \*\*Review dossier\*\*' <<< "$t"
}

@test "#1435 non-vacuity: §6's gate needle reds when the clause is reverted" {
  local F="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  local m="$BATS_TEST_TMPDIR/skill.md"
  # line-oriented, so the pattern sits inside one raw line (the clause wraps)
  sed 's/^loop ran and reached a \*\*PR-opening\*\* terminal (§3.5) — `CONVERGED` \*\*or\*\*/loop ran and reached `CONVERGED` (§3.5), and/' "$F" > "$m"
  local tm; tm="$(flat "$m")"
  run ! grep -q 'reached a \*\*PR-opening\*\* terminal (§3.5) — `CONVERGED` \*\*or\*\* `CONVERGED_WITH_RESIDUE` (#1435); those two, and no escalation — append the \*\*Review dossier\*\*' <<< "$tm"
  # the mutation is surgical: the file still names the terminal everywhere else,
  # which is exactly why the roster and proximity tests stayed green on it
  grep -q 'CONVERGED_WITH_RESIDUE' <<< "$tm"
}

@test "#1435 the Approver template's residue rule is pinned by CONTENT, not by filename" {
  # The roster tripwire lists approver-policy-core.md.tmpl, but listing a path
  # only asserts that the string occurs somewhere in it. That template is the
  # artifact every bootstrapped repo's Approver actually reads the dossier
  # through, and it carries four claims the residue terminal depends on. Each is
  # pinned separately below, because they fail independently — and the worst of
  # them (the REQUEST_CHANGES rule) can be inverted while leaving the mention
  # that keeps the tripwire green.
  local F="$REPO_ROOT/development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl"
  local t; t="$(flat "$F")"
  # (a) the reading of the machine-readable count
  grep -q '`dimensions.<lens>.open > 0` means blockers were deliberately left open, not missed' <<< "$t"
  # (b) BOTH firing conditions, which are what make the leniency safe
  grep -q 'found \*\*zero Criticals\*\* and every remaining blocker sits in a file the loop' <<< "$t"
  # (c) the label pair, which is how a human finds the follow-ups
  grep -q '`review-residue` + `needs-refinement`' <<< "$t"
  # (d) the rule itself, in the NEGATIVE form — an Approver that blocks on
  #     `open > 0` blocks exactly the PRs this terminal exists to ship
  grep -q 'Do \*\*not\*\* `REQUEST_CHANGES` merely because `open > 0`' <<< "$t"
  # ...and the escape hatch that keeps (d) from being a blank cheque
  grep -q 'Do still raise a finding if the diff shows the open item is \*\*not\*\* what the dossier says it is' <<< "$t"
}

@test "#1435 non-vacuity: the template's REQUEST_CHANGES rule reds when inverted" {
  # The needle that matters most, proven discriminating: invert the rule while
  # leaving the terminal's name in place, which is the mutation the file-level
  # tripwire cannot see.
  local F="$REPO_ROOT/development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl"
  local m="$BATS_TEST_TMPDIR/policy.md.tmpl"
  sed 's/Do \*\*not\*\* `REQUEST_CHANGES`$/`REQUEST_CHANGES`/' "$F" > "$m"
  local tm; tm="$(flat "$m")"
  run ! grep -q 'Do \*\*not\*\* `REQUEST_CHANGES` merely because `open > 0`' <<< "$tm"
  # the terminal is still named, so the roster tripwire would still list the file
  grep -q 'CONVERGED_WITH_RESIDUE' <<< "$tm"
}

@test "#1435 AC22 SKILL.md states the cadence invariant on the AWAITING_FIX branch" {
  # §10's stated half. It has to live ON the branch where the session decides
  # what to do next — not in a preamble it will have scrolled past — because the
  # mistake it prevents is made exactly there: panel, then fix, then resume.
  # Pinned like the §8 documentation sites, since the sentence IS the deliverable.
  local F="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  local t; t="$(flat "$F")"
  grep -q 'a round.s findings reach the loop BEFORE that round.s fix pass runs, always' <<< "$t"
  # ...and it names the mechanical half, or the invariant is advice with no teeth
  grep -qF -- '--findings-tree' <<< "$t"
  grep -q 'STALE_FINDINGS' <<< "$t"
  # ...and it keeps the two attestations distinct, which is the thing a reader
  # is most likely to conflate
  grep -q 'separate from `--gate-attest`' <<< "$t"

  # the sentence sits INSIDE the AWAITING_FIX branch, not somewhere earlier: the
  # branch heading must precede it, and the next numbered branch must follow it
  local ln_branch ln_rule
  ln_branch="$(grep -n '^3\. \*\*On `AWAITING_FIX` (exit 20)\*\*' "$F" | head -1 | cut -d: -f1)"
  ln_rule="$(grep -n 'reach the loop BEFORE that round' "$F" | head -1 | cut -d: -f1)"
  [ -n "$ln_branch" ] && [ -n "$ln_rule" ] && [ "$ln_branch" -lt "$ln_rule" ]
  # within ~30 lines of the heading — the point is that it is the FIRST thing the
  # branch says, not merely somewhere in it
  [ "$(( ln_rule - ln_branch ))" -lt 30 ]
}

@test "#1435 §9 every site that names exit 14 also states the full-sweep precondition" {
  # The amendment is explicit that this is part of what exit 14 MEANS, not a
  # separate rule filed beside it — so it belongs at the same sites, and a site
  # that names the terminal while omitting the precondition tells a reader the
  # loop can open a PR off a delta round, which is the defect being fixed.
  local f t
  for f in "$SCRIPTS/resolve-story-loop.zsh" \
           "$REPO_ROOT/development/skills/resolve-issue/SKILL.md" \
           "$REPO_ROOT/ARCHITECTURE.md" \
           "$REPO_ROOT/docs/explanation/review-loop.md" \
           "$REPO_ROOT/docs/reference/commands.md"; do
    t="$(flat "$f")"
    grep -qiE '(full sweep|closing full sweep|closing sweep)' <<< "$t" || {
      echo "site names exit 14 but never the sweep precondition: $f"; return 1; }
  done
  # the two normative sites say it in the strong form
  grep -q 'THREE conditions, ALL required' <<< "$(flat "$SCRIPTS/resolve-story-loop.zsh")"
  grep -q 'Three conditions, ALL required' <<< "$(flat "$REPO_ROOT/ARCHITECTURE.md")"
}

@test "#1435 §9 non-vacuity: the two-condition wording is gone everywhere" {
  # The pre-amendment claim, transcribed. If any site still says the terminal
  # takes two conditions, a reader following it concludes a delta round may
  # declare residue — which is exactly what the amendment forbids.
  local f hits=""
  while IFS= read -r f; do
    local t; t="$(flat "$REPO_ROOT/$f")"
    grep -q 'TWO conditions, BOTH required' <<< "$t" && hits+="$f (two-conditions)"$'\n'
    grep -q 'Two conditions, BOTH required' <<< "$t" && hits+="$f (two-conditions)"$'\n'
  done < <(all_markdown)
  grep -q 'TWO conditions, BOTH required' "$SCRIPTS/resolve-story-loop.zsh" && hits+="resolve-story-loop.zsh (two-conditions)"$'\n'
  [ -z "$hits" ] || { echo "stale two-condition claims still present:"; echo "$hits"; return 1; }
}

@test "#1435 the remainder rule is stated ONCE, and the other sites point at it" {
  # This rule fragmented across five sites over three review rounds, and every
  # round found another site restating it inconsistently — a CRITICAL twice. The
  # cure is structural, not another patch: ONE statement, with pointers.
  #
  # So the pin is a COUNT, not a wording check. A future edit that "helpfully"
  # re-explains the three rows at a consumer site reds here, which is the whole
  # point — the sites disagreed precisely because each carried its own copy.
  local F="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"

  # exactly one canonical statement, carrying the decision table
  [ "$(grep -c 'THE REMAINDER RULE' "$F")" -eq 1 ]
  local t; t="$(flat "$F")"
  # ...and it really is a table with all three rows, or the count pins a heading
  grep -q '| Filed | The Summary owes | Why |' <<< "$t"
  grep -q '| \*\*none\*\* |' <<< "$t"
  grep -q '| \*\*some, not all\*\* |' <<< "$t"
  grep -q '| \*\*all\*\* |' <<< "$t"

  # the definition of "filed" lives with the rule, since every row depends on it
  grep -q 'means \*\*created AND parented\*\*' <<< "$t"

  # the consumers POINT rather than restate
  grep -q 'apply \*\*the remainder rule\*\*' <<< "$t"
  grep -q 'Both feed the remainder rule in step 1' <<< "$t"
  grep -q 'decided by \*\*§3.5.s remainder rule\*\*' <<< "$t"
}

@test "#1435 the arm-vs-remainder distinction is stated where the mistake is made" {
  # Both CRITICALs in this area were the same error: reading the ARM the run
  # arrived by instead of the remainder's state. The rule says so outright, and
  # the two sites most likely to shortcut it repeat the warning locally — that is
  # a pointer with a reason attached, not a restatement of the rows.
  local F="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  local t; t="$(flat "$F")"
  grep -q 'The antecedent is the remainder, never the arm you arrived by' <<< "$t"
  # step 4's create/attach prose, the site that restated it wrongly last round
  grep -q '"every create failed" is a route, not a row' <<< "$t"
  # step 3's unmatched arm, the other one
  grep -q 'this arm is a route, not a row' <<< "$t"
}

@test "#1435 non-vacuity: a second copy of the rule reds the count pin" {
  # Proves the count is doing work. Plant a duplicate heading and the pin fails;
  # without this the `-eq 1` could be passing because the string is rare rather
  # than because it is unique.
  local F="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  local m="$BATS_TEST_TMPDIR/dup.md"
  cat "$F" > "$m"
  printf '\n**THE REMAINDER RULE — restated helpfully somewhere else.**\n' >> "$m"
  [ "$(grep -c 'THE REMAINDER RULE' "$m")" -eq 2 ]
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
