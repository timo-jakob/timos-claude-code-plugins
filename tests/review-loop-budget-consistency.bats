#!/usr/bin/env bats
#
# The review loop's budget numbers (issue #993) are restated across several live
# artifacts, and only two of them are executable: MAX_REVIEW_ROUNDS in
# resolve-story-loop.zsh (the default round cap) and the grant soft cap rendered
# by build-escalation.zsh. The human-approved extension increment (+3) is pure
# prose — the session implements it by following SKILL.md — so nothing but these
# tests can catch a site drifting back to the old 3 / +2 spellings, or a retune
# that moves a constant without moving its transcriptions.
#
# Both executable numbers are READ from their source, and every DIGIT-form site
# is checked against them, so a retune fails here instead of silently
# disagreeing. The WORD forms ("five rounds", "three more rounds") are spelled
# out by hand — they cannot be derived — so a retune must re-spell them here;
# the value assertions at the top of the file are what force that to happen.
# Every live restatement is listed, in BOTH spellings the repo uses: the word
# form ("five rounds") in human-facing prose and the digit form ("after 5
# rounds", "5-round default") in agent instructions. A site guarded in only one
# spelling is a site that can drift.
#
# A third kind exists since #1433: NUMERAL-FREE restatements ("escalates once
# its round budget runs out") in the two panel agents that gained a severity
# bar. They quote no number, so no value assertion can reach them and they are
# absent from the digit-form test. They get their OWN test — positive on the
# numeral-free spelling, negative on any numeral form — because ALL_SITES
# membership alone would not catch a rewrite into the CURRENT digit form: the
# two sweeps ALL_SITES feeds ban the superseded 3/+2 literals only. Membership
# is kept as the second line of defence, not as the guard.
#
# Scope: LIVE instruction/documentation only. Dated design records under
# docs/superpowers/{plans,specs}/ are deliberately frozen snapshots of what was
# decided at the time — they still say 3 / +2 and must NOT be swept.
#
# Two idioms this file is deliberate about:
#   - negative assertions use `run -1`, not `run !`: grep exits 1 for
#     "searched, found nothing" but 2 for "file missing/unreadable", and a bare
#     negation accepts the error exit — so a renamed doc would silently retire
#     the guard instead of failing it;
#   - digit-adjacent needles are matched with an anchored -E pattern, never
#     `grep -F`: the fixed string "5-round default" is a substring of a drifted
#     "15-round default".

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LOOP="$REPO_ROOT/development/skills/resolve-issue/scripts/resolve-story-loop.zsh"
  ESCALATE="$REPO_ROOT/development/skills/resolve-issue/scripts/build-escalation.zsh"
  SKILL="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  EXPLAIN="$REPO_ROOT/docs/explanation/review-loop.md"
  MOTIV="$REPO_ROOT/docs/explanation/motivation.md"
  GATE="$REPO_ROOT/development/agents/story-readiness.md"
  PROSE="$REPO_ROOT/development-claude-plugin/agents/claude-plugin-prose-logic.md"
  # #1009: the user-facing telemetry explanation cites the budget as its worked
  # example of a telemetry-driven decision, so it is a live restatement too.
  # NOTE it also narrates the OLD budget (the 3 -> 5 raise is the whole point of
  # the passage), which the stale sweeps below would flag if it were reworded to
  # any of their banned spellings. Phrase that history so it never collides with
  # them — "defaulted to 3", not "up to three rounds" — and, on a retune, reword
  # the whole evidence sentence rather than only the word form: the 1,3,3,3,6,10
  # data produced *five*, and must not be re-attached to a later cap.
  TELEM="$REPO_ROOT/docs/explanation/pipeline-telemetry.md"
  # #1433 gave two more panel agents a severity bar, and each opens by restating
  # the same escalation rule. Both are deliberately NUMERAL-FREE ("escalates
  # once its round budget runs out"), so neither belongs in the digit-form test
  # above. They join ALL_SITES for the stale 3/+2 sweeps, but membership alone
  # does NOT catch the drift worth catching here: those sweeps ban the
  # SUPERSEDED literals, so a rewrite into the CURRENT digit form ("escalates
  # after 5 rounds") would trip neither and mint a site the next retune never
  # reads. The dedicated test below is what actually guards them, in both
  # directions; ALL_SITES membership is the second line of defence.
  BAR_TESTS="$REPO_ROOT/development-claude-plugin/agents/claude-plugin-test-reviewer.md"
  BAR_CONTRACT="$REPO_ROOT/development-claude-plugin/agents/claude-plugin-contract-integrity.md"
  # every live prose site, for the sweeps that must cover all of them at once
  ALL_SITES=("$SKILL" "$ARCH" "$EXPLAIN" "$MOTIV" "$GATE" "$PROSE" "$TELEM" \
    "$BAR_TESTS" "$BAR_CONTRACT")

  # the executable copies — every prose site is checked AGAINST these
  MAXR="$(grep -Eom1 'MAX_REVIEW_ROUNDS=[0-9]+' "$LOOP" | cut -d= -f2)"
  [ -n "$MAXR" ] || {
    printf 'MAX_REVIEW_ROUNDS=<n> not found in %s — the guard has nothing to check against\n' \
      "$LOOP" >&2
    return 1
  }
  # `|| true` so an absent needle reaches the guard below with its explanation,
  # instead of failing setup on the pipeline's own exit status
  SOFTCAP="$(grep -Eom1 'soft cap [0-9]+' "$ESCALATE" | grep -Eo '[0-9]+' || true)"
  [ -n "$SOFTCAP" ] || {
    printf '"soft cap <n>" not found in %s — the ceiling arithmetic has no source\n' \
      "$ESCALATE" >&2
    return 1
  }
  # the one number with no executable source: the per-grant increment. It lives
  # only in prose, which is exactly why every site below is pinned to it.
  INCREMENT=3
}

# grep -E with a digit boundary on BOTH sides, so "5-round" never matches
# inside "15-round" and "by 3" never matches inside "by 30". LC_ALL=C so a
# needle carrying a multibyte character (the '×' in the ceiling arithmetic) is
# compared byte-wise instead of erroring out with "illegal byte sequence" under
# whatever locale the runner happens to have.
# The needle is parenthesised so a future pattern containing a top-level `|`
# keeps both anchors instead of silently degrading to a substring match.
grep_num() {  # grep_num <file> <regex, digits at either end already embedded>
  LC_ALL=C grep -Eq "(^|[^0-9])($2)([^0-9]|\$)" "$1"
}

# assert a fixed string is present, naming the file when it is not — the loops
# below check one needle across several sites, and bats reports only the source
# line, so without this a failure cannot say WHICH site drifted
grep_site() {  # grep_site <file> <fixed-string>
  grep -Fq "$2" "$1" || {
    printf 'missing in %s: %s\n' "$1" "$2" >&2
    return 1
  }
}

@test "the executable constants are present and sane (#993)" {
  [ "$MAXR" -ge 1 ]
  [ "$SOFTCAP" -ge 1 ]
  # the values this repo settled on; changing either is a deliberate act that
  # must move every site below with it
  [ "$MAXR" -eq 5 ]
  [ "$SOFTCAP" -eq 5 ]
}

@test "SKILL.md and ARCHITECTURE.md transcribe the script's constant verbatim (#993)" {
  grep_num "$SKILL" "MAX_REVIEW_ROUNDS=$MAXR"
  grep_num "$ARCH" "MAX_REVIEW_ROUNDS=$MAXR"
  # and no OTHER value of the constant survives anywhere in the live prose
  run grep -Eho 'MAX_REVIEW_ROUNDS=[0-9]+' "$SKILL" "$ARCH"
  [ "$status" -eq 0 ]
  while IFS= read -r hit; do
    [ "$hit" = "MAX_REVIEW_ROUNDS=$MAXR" ]
  done <<< "$output"
}

@test "the user-facing docs spell the default cap as five rounds (#993)" {
  grep -Fq 'five rounds by default' "$EXPLAIN"
  grep -Fq 'up to five rounds' "$MOTIV"
  grep -Fq 'five review rounds' "$SKILL"
  grep -Fq 'five review rounds' "$GATE"
}

@test "the digit-form restatements agree with the constant too (#993)" {
  # agent instructions quote the cap as a numeral, so the word-form sweep above
  # would never reach them — and a bare -F needle would match inside a bigger
  # number, so both are anchored
  grep_num "$PROSE" "escalates after $MAXR rounds"
  grep_num "$ARCH" "$MAXR-round default"
  # no other numeral claims to be the default cap
  run grep -Eho '[0-9]+-round default' "$ARCH"
  [ "$status" -eq 0 ]
  while IFS= read -r hit; do
    [ "$hit" = "$MAXR-round default" ]
  done <<< "$output"
}

@test "the numeral-free bar restatements stay numeral-free (#1433)" {
  # The guard the ALL_SITES entries do NOT buy. Positive: the spelling is
  # actually there, so deleting the escalation clause reds instead of silently
  # retiring the site. Negative: no round count in ANY form may appear in either
  # file — that is the "minting a site the retune never reads" drift, and the
  # stale-3 sweep cannot see it because "escalates after 5 rounds" is the
  # CURRENT spelling, not a superseded one.
  local site
  for site in "$BAR_TESTS" "$BAR_CONTRACT"; do
    grep_site "$site" 'escalates once its round budget runs out'
  done
  # Ban the SHAPE, not three sentences. Three named spellings would still let
  # "escalates once its 5-round budget runs out", "a budget of 5 rounds", or the
  # word form "after five rounds" through — each of which mints exactly the
  # unread digit site this test exists to prevent, alongside an intact
  # numeral-free clause the positive pin above still matches.
  #
  # Safe against these files' real content: they cite issues as (#982), (#994),
  # (#1067) and #1433, never a round count, so no digit here abuts a round word.
  #
  # The word branch mirrors the digit branch shape-for-shape. An earlier version
  # only matched "<word> rounds" — a space and a plural — so "the panel's
  # five-round budget", "its round budget of five" and any retune past "eight"
  # all slipped through and minted precisely the unread site this bans.
  #
  # The word branch carries the `review` variant too: "five review rounds" is
  # this repo's commonest human-facing spelling — pinned as live prose by the
  # word-form test above — and the digit companion below already bans its digit
  # form, so without it the two branches stayed asymmetric on the one spelling
  # the repo actually writes.
  #
  # Verified against the real files: both agents say "one instance per round"
  # and "across extra rounds", and neither contains "review round", "one round"
  # or "one-round" — no count precedes "round" anywhere in them — so this cannot
  # false-red on today's content.
  run -1 grep -Eqi '[0-9]+[- ]rounds?|[0-9]+ (more )?rounds|round budget of [0-9]+|(one|two|three|four|five|six|seven|eight|nine|ten)[- ](more )?(review )?rounds?|round budget of (one|two|three|four|five|six|seven|eight|nine|ten)' \
    "$BAR_TESTS" "$BAR_CONTRACT"
  # and the superseded spellings stay banned too, belt and braces
  run -1 grep -Eq 'escalates after [0-9]+ rounds|[0-9]+-round default|[0-9]+ review rounds' \
    "$BAR_TESTS" "$BAR_CONTRACT"
}

@test "every numeral-free bar restatement is on the roster (#1433)" {
  # The closed-list tripwire. A sibling of #1431 that gives a fourth reviewer a
  # bar restates this clause in a file ALL_SITES does not name, and the test
  # above would sweep only the two we happen to list. Derive the real set from
  # the tree and require it to equal the rostered one, so a new site fails
  # here rather than going unguarded — the repo-wide-invariant rule adopted
  # after a closed swept-file list rotted (#936 / #1188).
  #
  # Swept REPO-WIDE, not over one plugin's agents dir: the rest of epic #1431
  # works on the `development` plugin, so the likeliest fourth site is
  # development/agents/ or a SKILL.md — scoping the sweep to
  # development-claude-plugin/agents/ would be the same closed-list rot the
  # comment above disclaims, one level up.
  #
  # A read loop rather than `xargs`: xargs word-splits its input, and on empty
  # input GNU xargs runs grep once with no operands (falling through to stdin)
  # where BSD xargs runs nothing — the two CI legs would disagree in exactly the
  # degenerate case this tripwire is meant to catch.
  # Enumerated exactly like the sibling roster in
  # tests/claude-plugin-review-severity-bars.bats, so the two really do agree
  # about what "the tree" means rather than merely claiming to:
  #  * `-c core.quotePath=false` with `-z` / `read -d ''`, because git C-quotes
  #    a path holding a non-ASCII byte, a quote or a backslash, and grep then
  #    cannot open the literal — it exits 2, the `if` is false, and the file
  #    drops out SILENTLY. That is the fail-OPEN direction, and since `expected`
  #    is fixed it only changes the verdict when the dropped file DOES carry the
  #    clause — i.e. exactly the fourth site this tripwire exists to catch.
  #  * the NUL stream read straight from the process substitution: a `$(...)`
  #    capture cannot carry NUL bytes, so capturing first would collapse the
  #    whole listing into one unopenable path and empty the roster.
  #  * `--` and `</dev/null` on the probe, so a path beginning with `-` is not
  #    parsed as options, and an empty path cannot read the loop's own stdin and
  #    swallow the rest of the listing.
  #  * `sort -u` on both sides: a conflicted index lists a path once per stage,
  #    and the equality below would otherwise red mid-rebase while nothing had
  #    changed — a realistic state given this repo's sequential-PR cadence.
  local discovered expected
  local found=()
  git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || {
    printf 'not a git worktree, cannot derive the roster: %s\n' "$REPO_ROOT" >&2
    return 1
  }
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    if grep -q 'escalates once its round budget runs out' -- "$REPO_ROOT/$f" </dev/null; then
      found+=("$f")
    fi
  done < <(cd "$REPO_ROOT" \
    && git -c core.quotePath=false ls-files -z '*.md' ':!:docs/superpowers/**')
  [ "${#found[@]}" -ge 1 ]
  discovered="$(printf '%s\n' "${found[@]}" | sort -u)"
  [ -n "$discovered" ]
  expected="$(printf '%s\n' \
    "development-claude-plugin/agents/claude-plugin-contract-integrity.md" \
    "development-claude-plugin/agents/claude-plugin-test-reviewer.md" | sort -u)"
  [ "$discovered" = "$expected" ]
}

@test "no stale round-count spelling survives at any live site (#993)" {
  run -1 grep -Eq 'three rounds by default|up to three rounds|three review rounds|escalates after 3 rounds|(^|[^0-9])3-round default' \
    "${ALL_SITES[@]}"
}

@test "the telemetry explanation states the CURRENT round cap (#1009)" {
  # It cites the 3 -> 5 raise as its worked example of a telemetry-driven
  # decision, so a retune that left it saying "five" would make the page's
  # evidence story quietly false.
  local word
  case "$MAXR" in
    5) word="five" ;;
    *) printf 'no word form mapped for MAX_REVIEW_ROUNDS=%s — extend this case\n' "$MAXR" >&2
       return 1 ;;
  esac
  grep -Fq "raised to **$word rounds**" "$TELEM"
}

@test "the extension increment is +3 at every live site (#993)" {
  # Digit-terminal needles go through grep_num (both boundaries), so a drift to
  # "+30" / "by 30" cannot satisfy them; the rest are plain fixed strings.
  #
  # SKILL.md — the offer texts, the bookkeeping note, the ceiling semantics and
  # the invocation that implements them
  grep_num "$SKILL" "Grant \+$INCREMENT rounds"
  grep_num "$SKILL" "Grant \+$INCREMENT with guidance"
  grep_num "$SKILL" "retry \(\+$INCREMENT\)"
  grep_num "$SKILL" "\+$INCREMENT/.grants. bookkeeping"
  grep -Fq 'exactly three more rounds' "$SKILL"
  grep -Fq 'grant "three more rounds"' "$SKILL"
  grep_num "$SKILL" "ceiling raised by $INCREMENT"
  grep_num "$SKILL" "raises the \*ceiling\* by $INCREMENT"
  grep -Fq 'leaves more than three' "$SKILL"
  grep_num "$SKILL" "prev_max \+ $INCREMENT"
  # ARCHITECTURE.md — the contract restatement, in both spellings
  grep_num "$ARCH" "offers \+$INCREMENT to the round ceiling"
  grep_num "$ARCH" "raises .--max-rounds. by $INCREMENT"
  # docs/explanation — the human-facing spelling
  grep -Fq 'Grant three more rounds' "$EXPLAIN"
  grep -Fq "raises the run's *ceiling* by three" "$EXPLAIN"
  grep_num "$EXPLAIN" "\+$INCREMENT to the ceiling each time"
  # the word form of the same sentence, wherever it is restated
  local site
  for site in "$EXPLAIN" "$ARCH"; do
    grep_site "$site" 'exactly three more rounds'
  done
}

@test "the worked example of a first grant is arithmetically right (#993)" {
  # SKILL.md illustrates both exits with concrete numbers; recompute them so a
  # retune of the cap or the increment cannot leave a stale example behind
  local first_ceiling=$(( MAXR + INCREMENT ))
  grep_num "$SKILL" "ceiling $first_ceiling after the default budget, rounds $(( MAXR + 1 ))-$first_ceiling"
  grep_num "$SKILL" "ceiling $first_ceiling after a round-2 exit = $(( first_ceiling - 2 )) rounds left"
}

@test "no stale +2 increment spelling survives in the live instructions (#993)" {
  run -1 grep -Eq '\+2 rounds|\+2 with guidance|retry \(\+2\)|\+2/|raised by 2|ceiling\* by 2|by two\.|prev_max \+ 2|two more rounds|two rounds at a time|\+2 to the ceiling' \
    "${ALL_SITES[@]}"
}

@test "the documented ceiling matches cap + soft cap x increment (#993)" {
  # the soft cap stays a NUDGE, so the figure the docs quote is the ceiling AT
  # the soft cap, not a hard bound. Recompute it from both executable constants
  # rather than trusting the prose.
  #
  # One anchored -E pass over the WHOLE expression, so both boundaries apply to
  # the same occurrence: "5 + 5×3 = 20" must not match inside "15 + 5×3 = 200".
  # Under LC_ALL=C the multibyte '×' is just two literal bytes in the pattern —
  # no escaping needed, and no "illegal byte sequence" from the runner's locale.
  # ${SOFTCAP} must stay braced: under a byte-oriented locale bash folds the
  # first byte of '×' into an unbraced variable name.
  local ceiling=$(( MAXR + SOFTCAP * INCREMENT ))
  local site
  for site in "$EXPLAIN" "$SKILL" "$ARCH"; do
    grep_num "$site" "$MAXR \+ ${SOFTCAP}×$INCREMENT = $ceiling"
  done
  # SKILL.md also restates the derived number on its own; recompute it too
  grep_num "$SKILL" "$ceiling-round figure"
}

@test "the soft cap is a nudge at every site that states it (#993)" {
  local site
  for site in "$SKILL" "$ARCH" "$EXPLAIN"; do
    grep_site "$site" 'not a hard stop'
  done
  # and the cap's own value agrees with what build-escalation.zsh renders,
  # in the digit form...
  grep_num "$SKILL" "grants >= $SOFTCAP"
  grep_num "$ARCH" "$SOFTCAP-grant soft cap"
  # ...and in the word form the human-facing prose uses. Both spellings, or the
  # unguarded one drifts (the whole point of this file).
  [ "$SOFTCAP" -eq 5 ]   # the word forms below are spelled for this value
  grep -Fq 'five grants' "$EXPLAIN"
  grep -Fq 'five-grant point' "$EXPLAIN"
  grep -Fq 'by the fifth grant' "$SKILL"
  grep -Fq 'by the fifth grant' "$ARCH"
}
