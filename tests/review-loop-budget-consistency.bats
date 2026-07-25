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
  # every live prose site, for the sweeps that must cover all of them at once
  ALL_SITES=("$SKILL" "$ARCH" "$EXPLAIN" "$MOTIV" "$GATE" "$PROSE")

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

@test "no stale round-count spelling survives at any live site (#993)" {
  run -1 grep -Eq 'three rounds by default|up to three rounds|three review rounds|escalates after 3 rounds|(^|[^0-9])3-round default' \
    "${ALL_SITES[@]}"
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
