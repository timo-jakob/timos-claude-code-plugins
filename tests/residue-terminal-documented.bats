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

load resolve-issue-corpus

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # #1503 split this skill into a conductor plus reference/*.md. A sweep that
  # counts or reads ACROSS the skill takes the corpus; one that pins WHERE a
  # sentence lives takes the single file. See resolve-issue-corpus.bash.
  RI_REF="$REPO_ROOT/development/skills/resolve-issue/reference"
  SKILL="$(resolve_issue_corpus "$REPO_ROOT" "$BATS_TEST_TMPDIR/resolve-issue-corpus.md")"
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

# The §9 precondition, tied to the terminal it qualifies rather than matched
# anywhere in the file. A file-wide topic match was not a check at all: three of
# the required sites mention "full sweep" many times for unrelated reasons, so
# the precondition could be deleted from the exit-table entry beside
# CONVERGED_WITH_RESIDUE and the sweep would still pass on a leftover mention
# hundreds of lines away. Either order, because sites state it both ways.
# `{0,250}` and not more: BSD grep caps an interval at 255 repetitions.
SWEEP_NEAR_TERMINAL='CONVERGED_WITH_RESIDUE.{0,250}(full sweep|closing sweep)|(full sweep|closing sweep).{0,250}CONVERGED_WITH_RESIDUE'

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
  # residue.md and promotion.md joined this list with #1503: each INTRODUCES the
  # terminal (residue.md's whole subject is it), so each owes the exit code
  # beside it. review-loop.md deliberately does not — it names the terminal only
  # as a hand-off from the AWAITING_FIX branch, and the conductor's exit table is
  # what introduces it with its code.
  local f
  for f in "$SCRIPTS/resolve-story-loop.zsh" \
           "$REPO_ROOT/development/skills/resolve-issue/SKILL.md" \
           "$REPO_ROOT/development/skills/resolve-issue/reference/residue.md" \
           "$REPO_ROOT/development/skills/resolve-issue/reference/promotion.md" \
           "$REPO_ROOT/development/skills/open-pr/SKILL.md" \
           "$REPO_ROOT/ARCHITECTURE.md" \
           "$REPO_ROOT/docs/explanation/review-loop.md" \
           "$REPO_ROOT/docs/reference/commands.md"; do
    grep -qE 'CONVERGED_WITH_RESIDUE[^A-Za-z0-9]{0,40}(exit )?[`*]{0,2}14([^0-9]|$)' <<< "$(flat "$f")" || {
      echo "site does not state exit 14 next to the terminal it belongs to: $f"; return 1; }
  done
}

@test "#1435 non-vacuity: a distant 'full sweep' does not satisfy the §9 detector" {
  # The detector's whole point is PROXIMITY. Prove it: a file that names the
  # terminal and also says "full sweep" — but hundreds of characters away, which
  # is exactly the shape a file-wide topic match accepted — must NOT satisfy it,
  # while the same two phrases adjacent must.
  local far="$BATS_TEST_TMPDIR/far.md" near="$BATS_TEST_TMPDIR/near.md" pad
  pad="$(head -c 600 < /dev/zero | tr '\0' 'x')"
  printf 'the loop may exit CONVERGED_WITH_RESIDUE here.\n%s\nand only a full sweep may declare it.\n' \
    "$pad" > "$far"
  run -1 grep -qiE "$SWEEP_NEAR_TERMINAL" <<< "$(flat "$far")"
  printf 'CONVERGED_WITH_RESIDUE is declarable only from the closing full sweep.\n' > "$near"
  grep -qiE "$SWEEP_NEAR_TERMINAL" <<< "$(flat "$near")"
}

@test "#1435 roster tripwire: exactly eleven markdown sites name the terminal" {
  # A derived sweep answers "do the sites agree?", never "did a site appear or
  # vanish?" — so the roster is recorded here and a site that appears or vanishes
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
  # #1503 moved the review-loop procedure into reference/*.md, so five of these
  # are the same sites re-homed: the conductor keeps the exit-code table (hence
  # SKILL.md stays on the roster) while residue.md, promotion.md, escalation.md,
  # interactive.md and review-loop.md carry the procedure behind each branch.
  [ "$found" = "ARCHITECTURE.md
development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl
development/skills/open-pr/SKILL.md
development/skills/resolve-issue/SKILL.md
development/skills/resolve-issue/reference/escalation.md
development/skills/resolve-issue/reference/interactive.md
development/skills/resolve-issue/reference/promotion.md
development/skills/resolve-issue/reference/residue.md
development/skills/resolve-issue/reference/review-loop.md
docs/explanation/review-loop.md
docs/reference/commands.md" ] || {
    echo "markdown roster changed; expected the eleven known sites, got:"
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

@test "#1435 the residue reference actually invokes the builder, with both labels" {
  # build-residue-issues.zsh has NO caller inside the repo's scripts — the skill
  # is the only thing that runs it and the only thing that turns its plan into
  # real issues. Without this, deleting the residue branch's code block leaves
  # the suite green while a shipped script becomes dead code and residue runs
  # file nothing. #1503 moved that branch, byte-for-byte, into
  # reference/residue.md — read it THERE rather than through the corpus, so the
  # invocation cannot drift back into the conductor unnoticed.
  local S="$RI_REF/residue.md"
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
  # (b) BOTH firing conditions, which are what make the leniency safe. Since
  #     #1571 the second is the FULL-SWEEP read, not the fix-touched membership
  #     that condition 2 used to require — the template must not keep promising
  #     an Approver a guarantee the loop stopped making.
  grep -q 'found \*\*zero Criticals\*\* and the round declaring it had read the \*\*whole\*\* change' <<< "$t"
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

@test "#1435 AC22 the round protocol states the cadence invariant on the AWAITING_FIX branch" {
  # §10's stated half. It has to live ON the branch where the session decides
  # what to do next — not in a preamble it will have scrolled past — because the
  # mistake it prevents is made exactly there: panel, then fix, then resume.
  # Pinned like the §8 documentation sites, since the sentence IS the deliverable.
  # #1503 moved the AWAITING_FIX branch into reference/review-loop.md, so that is
  # the file the invariant must live in; reading the corpus instead would let it
  # drift into the conductor, which a session reaching AWAITING_FIX has already
  # left behind for the reference.
  local F="$RI_REF/review-loop.md"
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

@test "#1435 §9 every site that names exit 14 also states the full-sweep precondition" {
  # The amendment is explicit that this is part of what exit 14 MEANS, not a
  # separate rule filed beside it — so it belongs at the same sites, and a site
  # that names the terminal while omitting the precondition tells a reader the
  # loop can open a PR off a delta round, which is the defect being fixed.
  #
  # DERIVED since #1503, not transcribed. The old closed list did not grow when
  # the move added five files that name the terminal, so the property had quietly
  # stopped covering them — a roster that reds only when someone remembers to
  # edit it. Candidates are now every markdown site naming the terminal, minus an
  # exclusion set that is STATED and pinned rather than left to omission:
  #
  #   - open-pr/SKILL.md and approver-policy-core.md.tmpl are CONSUMERS — they
  #     react to a residue PR; they never tell anyone when residue may be
  #     declared, so the precondition is not theirs to state (both were excluded
  #     by omission before, with no reason recorded);
  #   - reference/{promotion,escalation,interactive}.md carry PROCEDURE
  #     moved byte-for-byte by #1503 and frozen by verify-reference-move.zsh. The
  #     conductor's exit table introduces the terminal and states the
  #     precondition, and reference/review-loop.md — where the declaring round
  #     lives — is REQUIRED below rather than excluded.
  #   - reference/residue.md LEFT this set in #1571. Its frozen span still says
  #     nothing about the precondition, but the section that story appended
  #     outside the span states it while explaining which condition was removed —
  #     so the file now satisfies the sweep on its own text. It is listed nowhere
  #     here on purpose: re-adding it would re-permit a residue.md that never
  #     names the precondition.
  #
  # The exclusion set is itself asserted, so a NEW site naming the terminal
  # without the precondition reds here instead of quietly joining the excluded.
  local f t exp got
  exp="$(printf '%s\n' \
    'development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl' \
    'development/skills/open-pr/SKILL.md' \
    'development/skills/resolve-issue/reference/escalation.md' \
    'development/skills/resolve-issue/reference/interactive.md' \
    'development/skills/resolve-issue/reference/promotion.md' | sort)"
  got=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -q 'CONVERGED_WITH_RESIDUE' "$REPO_ROOT/$f" || continue
    t="$(flat "$REPO_ROOT/$f")"
    if grep -qiE "$SWEEP_NEAR_TERMINAL" <<< "$t"; then
      continue
    fi
    got="$got$f"$'\n'
  done < <(all_markdown)
  got="$(printf '%s' "$got" | sort)"
  if [ "$got" != "$exp" ]; then
    echo "the set of exit-14 sites WITHOUT the sweep precondition changed."
    echo "expected (the stated consumers + the frozen procedure files):"
    printf '%s\n' "$exp"
    echo "got:"
    printf '%s\n' "$got"
    return 1
  fi
  # ...and every site that is NOT excluded really does state it, including the
  # loop itself and the round protocol the declaring round lives in.
  for f in "$SCRIPTS/resolve-story-loop.zsh" \
           "$REPO_ROOT/development/skills/resolve-issue/SKILL.md" \
           "$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md" \
           "$REPO_ROOT/ARCHITECTURE.md" \
           "$REPO_ROOT/docs/explanation/review-loop.md" \
           "$REPO_ROOT/docs/reference/commands.md"; do
    t="$(flat "$f")"
    grep -qiE "$SWEEP_NEAR_TERMINAL" <<< "$t" || {
      echo "site names exit 14 but never the sweep precondition NEAR the terminal: $f"; return 1; }
  done
  # The two normative sites say it in the strong form. Since #1571 that form
  # names the SURVIVING PAIR by their original numbers — condition 2 was removed
  # and 3 was deliberately NOT renumbered, so "1 and 3" is the assertion, and a
  # site that renumbers the full-sweep rule to 2 reds here. That is the point:
  # every other surface says "condition 3" meaning the full sweep.
  grep -q 'Conditions 1 and 3, BOTH required' <<< "$(flat "$SCRIPTS/resolve-story-loop.zsh")"
  grep -q 'Conditions 1 and 3, BOTH required' <<< "$(flat "$REPO_ROOT/ARCHITECTURE.md")"

  # PER-SITE CONTENT PINS for the two PROSE sites, because proximity alone is
  # satisfied there by an ACCIDENT. In both files the only pair inside the
  # ±250-char window is a neighbouring bullet about a DIFFERENT rule — the #1434
  # one-round grant abutting the terminal's own heading — while the real
  # precondition sits ~600-1000 flattened chars away and satisfies nothing. So
  # the derived sweep above would stay green with the actual sentence deleted.
  # It remains the tripwire for a NEW site; these pins hold the sentence that
  # matters at the sites that have one.
  grep -q 'the declaring round ran as a \*\*full sweep\*\*' \
    <<< "$(flat "$REPO_ROOT/ARCHITECTURE.md")" || {
    echo "ARCHITECTURE.md no longer states condition 3 (the declaring round ran as a full sweep)"
    return 1; }
  grep -q 'only that sweep may declare residue' \
    <<< "$(flat "$REPO_ROOT/docs/explanation/review-loop.md")" || {
    echo "the explanation page no longer says only the closing sweep may declare residue"
    return 1; }
  grep -q 'reached only from a full sweep' \
    <<< "$(flat "$REPO_ROOT/docs/explanation/review-loop.md")" || {
    echo "the explanation page no longer says the terminal is reached only from a full sweep"
    return 1; }
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

@test "#1435 the remainder rule is stated ONCE, and the other sites point at it" {
  # This rule fragmented across five sites over three review rounds, and every
  # round found another site restating it inconsistently — a CRITICAL twice. The
  # cure is structural, not another patch: ONE statement, with pointers.
  #
  # So the pin is a COUNT, not a wording check. A future edit that "helpfully"
  # re-explains the three rows at a consumer site reds here, which is the whole
  # point — the sites disagreed precisely because each carried its own copy.
  #
  # Counted across the whole skill (#1503), not the conductor alone: the rule
  # itself moved to reference/residue.md while §6's pointer stayed in SKILL.md,
  # so a conductor-only count would read 0 canonical statements and a
  # reference-only count would miss a copy planted back in the conductor.
  local F="$SKILL"

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
  # #1503 re-homed §6's pointer from "§3.5's remainder rule" to the file the rule
  # now lives in; the claim it makes — §6 POINTS rather than restating — is
  # unchanged.
  grep -q 'decided by \*\*.reference/residue.md..s remainder rule\*\*' <<< "$t"
}

@test "#1435 the arm-vs-remainder distinction is stated where the mistake is made" {
  # Both CRITICALs in this area were the same error: reading the ARM the run
  # arrived by instead of the remainder's state. The rule says so outright, and
  # the two sites most likely to shortcut it repeat the warning locally — that is
  # a pointer with a reason attached, not a restatement of the rows.
  #
  # Read from reference/residue.md, NOT the corpus (#1503): the test's whole
  # claim is WHERE the warning sits, and residue.md is the only file a session
  # reaching CONVERGED_WITH_RESIDUE opens. On the corpus these three sentences
  # could migrate into the conductor with the suite still green, leaving the
  # residue branch without the warning at the two arms where both prior
  # CRITICALs were made.
  local F="$RI_REF/residue.md"
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
  # than because it is unique. Mutates the corpus, matching the pin above.
  local F="$SKILL"
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

@test "#1571 AC1 the predicate's header states the removal AND names the upstream rail" {
  local t; t="$(flat "$SCRIPTS/resolve-story-loop.zsh")"
  # the removal itself, said in words rather than left as a silent deletion
  grep -q 'Condition 2 .* was REMOVED' <<< "$t" || {
    echo "the header no longer records that condition 2 was removed"; return 1; }
  # ...and WHERE the guarantee went, which is the whole reason removing it is safe
  grep -q 'scope-findings.* filters every round.s findings' <<< "$t" || {
    echo "the header no longer names scope-findings as the upstream rail"; return 1; }
  # ...and WHY the round-granular reading had to go, or a later reader
  # "restores" it and makes the terminal unreachable again.
  #
  # A bare `unreachable` needle does NOT do that: the same file says "the
  # sha256sum arm is otherwise unreachable and untestable" and "that no longer
  # makes residue unreachable on the sweep", so deleting the explanation would
  # still match. Pin the explanation's own claim instead.
  grep -q 'unreachable FROM the closing sweep' <<< "$t" || {
    echo "the header no longer says why the round-granular reading was unreachable"; return 1; }
  grep -q 'against an empty set every blocker is' <<< "$t" || {
    echo "the header no longer gives the MECHANISM (an empty set puts every blocker outside)"; return 1; }
}

@test "#1571 AC2 the predicate reads no fix-touched set and no ceiling — one rule, both rungs" {
  # Extracted from the FUNCTION BODY, not the file: the header legitimately
  # discusses the retired condition at length, and a file-wide grep would be
  # satisfied by that prose while the code still read the set.
  local body
  body="$(awk '/^_residue_holds\(\) \{/{f=1} f{print} f&&/^\}/{exit}' \
    "$SCRIPTS/resolve-story-loop.zsh")"
  [ -n "$body" ]
  # non-vacuity: the extraction really did capture the predicate
  grep -q 'summary.critical' <<< "$body" || {
    echo "the extracted body is not _residue_holds"; return 1; }
  grep -q 'fix-touched' <<< "$body" && {
    echo "_residue_holds still reads a fix-touched set"; return 1; }
  grep -qE 'effective_max|max_rounds' <<< "$body" && {
    echo "_residue_holds carries a ceiling test — the rungs decide that, not the predicate"; return 1; }
  return 0
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

@test "#1571 reference/residue.md states the SURVIVING pair and the upstream rail, by content" {
  # residue.md left the §9 exclusion set in #1571, but the derived detector is
  # proximity-based and matches its HISTORICAL sentence, not its normative one —
  # the same accidental-proximity shape this file already pins per-site for
  # ARCHITECTURE.md and the explanation page. residue.md is the one file a
  # session that reaches the terminal actually opens, so pin it too.
  local t; t="$(flat "$RI_REF/residue.md")"
  # Pin what the conditions ARE, not just their numbers: a needle that stops at
  # "and condition 3" leaves the parenthetical saying what condition 3 IS
  # deletable with the whole suite green — the proximity sweep is satisfied by
  # this file's HISTORICAL sentence, not by its normative one.
  grep -q 'condition 1 (the last two rounds are both zero-CRITICAL) and condition 3' <<< "$t" || {
    echo "residue.md no longer states which two conditions survived"; return 1; }
  grep -q 'condition 3 (the declaring round ran as a full sweep)' <<< "$t" || {
    echo "residue.md names condition 3 without saying it is the full sweep"; return 1; }
  # Pin the RAIL SENTENCE, not the bare tool name: residue.md says
  # `scope-findings` twice, and the second is a different claim (what this story
  # did NOT change). A bare-name needle is satisfied by that one, so the rail
  # could be narrowed to a single round and this test would stay green — and a
  # one-round rail is exactly the reading that does not justify the removal.
  grep -q 'filters \*\*every\*\* round.s findings to the story diff' <<< "$t" || {
    echo "residue.md no longer states that scope-findings filters EVERY round's findings"; return 1; }
  grep -q 'only\*\* input to the changelist' <<< "$t" || {
    echo "residue.md no longer states that \$scoped is the only input to .blocking"; return 1; }
}

@test "#1571 non-vacuity: AC2's negative needles red on a predicate that DID read the set" {
  # AC2 asserts two ABSENCES over the extracted `_residue_holds` body. Its only
  # control proves the extraction found the function — not that either needle
  # could ever fire. An awk range that terminated early, or a restored read
  # spelled `fix_touched` / `$ft_file`, would leave both bans vacuous while the
  # condition was back. So drive the SHIPPED extraction over a scratch copy with
  # the pre-#1571 reads planted back in, and prove each needle bites.
  local probe="$BATS_TEST_TMPDIR/probe-loop.zsh"
  # Plant BOTH banned shapes immediately after the predicate's opening line, so
  # the awk range certainly captures them. One streaming pass, not an in-place
  # edit: `sed -i` and `perl -0pi` differ across platforms in ways that fail
  # SILENTLY here — a plant that does not land makes this control pass while
  # proving nothing, which is the exact failure it exists to rule out.
  awk '{ print }
       /^_residue_holds\(\) \{/ {
         print "  touched=\"$work_dir/fix-touched-$(( r - 1 )).txt\""
         print "  (( round == effective_max )) || return 1"
       }' "$SCRIPTS/resolve-story-loop.zsh" > "$probe"
  # the plant really landed, or every assertion below is vacuous
  grep -q 'fix-touched-\$(( r - 1 ))' "$probe"

  local body
  body="$(awk '/^_residue_holds\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$probe")"
  [ -n "$body" ]
  # the extraction still found the predicate (same control AC2 uses)...
  grep -q 'summary.critical' <<< "$body"
  # ...and now BOTH of AC2's needles must fire, or AC2 proves nothing
  grep -q 'fix-touched' <<< "$body" || {
    echo "AC2's fix-touched needle does not fire on a body that reads the set"; return 1; }
  grep -qE 'effective_max|max_rounds' <<< "$body" || {
    echo "AC2's ceiling needle does not fire on a body carrying a ceiling test"; return 1; }
}

@test "#1571 the EXPLANATION page carries a positive pin, not only the negative sweep" {
  # This file's own methodology (see the per-site pins above): a negative sweep
  # bans literal transcriptions of the OLD claim, so a REWORDED revert slips
  # past it; a positive pin requires the CURRENT claim to be present, which a
  # revert cannot satisfy however it is phrased. residue.md, ARCHITECTURE.md and
  # resolve-story-loop.zsh each got one for #1571. The user-facing page — the one
  # a human actually reads — did not, so a reworded return to three conditions
  # passed the whole suite.
  local t; t="$(flat "$REPO_ROOT/docs/explanation/review-loop.md")"
  grep -q '\*\*Two\*\* conditions are required' <<< "$t" || {
    echo "the explanation page no longer states the residue terminal's TWO conditions"; return 1; }
  grep -q 'A third condition used to sit between them' <<< "$t" || {
    echo "the explanation page no longer records that condition 2 was removed"; return 1; }
  grep -q 'removed\*\* (#1571)' <<< "$t" || {
    echo "the explanation page no longer attributes the removal to #1571"; return 1; }
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
  local t; t="$(flat "$RI_REF/review-loop.md")"
  grep -q 'Residue condition 2 was removed (#1571)' <<< "$t" || {
    echo "review-loop.md no longer records that condition 2 was removed"; return 1; }
  grep -q 'takes \*\*two\*\* conditions' <<< "$t" || {
    echo "review-loop.md no longer states the surviving pair"; return 1; }
  grep -q 'Only the residue predicate stopped reading it' <<< "$t" || {
    echo "review-loop.md no longer says the fix-touched set is still load-bearing elsewhere"; return 1; }
  # ...and the correction to the frozen parking rule, which is the one claim in
  # that span this story makes false
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
  # ...and the file must NOT carry the instruction the deferral replaced
  run ! grep -q 'has to drop those' "$RI_REF/review-loop.md"
}

@test "#1571 the skill frontmatter and its generated page carry a positive pin" {
  # The LAST #1571 site covered only by the negative sweep. Every other one
  # (the loop header, residue.md, review-loop.md, the explanation page,
  # ARCHITECTURE.md, the Approver template) has a positive pin, for the reason
  # this file states elsewhere: a negative sweep bans literal transcriptions of
  # the OLD claim, so a REWORDED revert slips past it. Mutation this closes:
  # rewrite the frontmatter to "blockers all sit in the files its own last fix
  # pass touched" and regenerate commands.md — no condition-2 needle matches
  # that wording, and the user-facing command reference then documents a firing
  # condition the loop no longer applies.
  local f="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  local g="$REPO_ROOT/docs/reference/commands.md"
  local ft; ft="$(flat "$f")"
  grep -q 'non-critical ends .CONVERGED_WITH_RESIDUE. (exit 14)' <<< "$ft" || {
    echo "SKILL.md's frontmatter no longer states the post-#1571 residue condition"; return 1; }
  # the generated page must say the same thing, or the two have drifted
  local gt; gt="$(flat "$g")"
  grep -q 'non-critical ends .CONVERGED_WITH_RESIDUE. (exit 14)' <<< "$gt" || {
    echo "docs/reference/commands.md was not regenerated from the frontmatter"; return 1; }
  # non-vacuity: neither may carry the retired clause in ANY spelling that
  # still names the last fix pass
  run ! grep -qE 'last fix pass touched|confined to its own last fix pass' "$f"
  run ! grep -qE 'last fix pass touched|confined to its own last fix pass' "$g"
}

@test "#1571 the cross-file pointer resolves — both ends pinned" {
  # The explanation page tells the reader to open a section of residue.md BY
  # NAME. Nothing asserted either end: rename the heading (leaving every body
  # sentence intact) or delete the pointer, and the suite stayed green while a
  # user-facing instruction named a section that does not exist. (The parked
  # section's pointer went to #1581 with the rest of that handling, so this is
  # the only pointer of the shape left in-tree — the pin stands on its own.)
  local heading='Condition 2 — removed; the story-diff rail is upstream'
  grep -qF "## $heading (#1571)" "$RI_REF/residue.md" || {
    echo "residue.md's #1571 section heading changed — the explanation page points at it by name"
    return 1; }
  grep -qF "$heading" "$REPO_ROOT/docs/explanation/review-loop.md" || {
    echo "the explanation page no longer points at residue.md's #1571 section"; return 1; }
}
