#!/usr/bin/env bats
#
# The review loop's budget numbers (issue #993) are restated across several live
# artifacts, and only THREE of them are executable: MAX_REVIEW_ROUNDS in
# resolve-story-loop.zsh (the default round cap), the grant soft cap rendered by
# build-escalation.zsh, and the closing sweep's one-round grant, derived from
# `closing_sweep_round=$(( round + 1 ))` in resolve-story-loop.zsh (#1434). The
# human-approved extension increment (+3) is pure prose — the session implements
# it by following SKILL.md — so nothing but these tests can catch a site drifting
# back to the old 3 / +2 spellings, or a retune that moves a constant without
# moving its transcriptions.
#
# All three executable numbers are READ from their source, and every DIGIT-form
# site is checked against them, so a retune fails here instead of silently
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

load resolve-issue-corpus

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LOOP="$REPO_ROOT/development/skills/resolve-issue/scripts/resolve-story-loop.zsh"
  ESCALATE="$REPO_ROOT/development/skills/resolve-issue/scripts/build-escalation.zsh"
  # #1503 split the resolve-issue skill into a conductor (SKILL.md — each step's
  # invocation contract, exit-code table and a pointer) plus on-demand
  # reference/*.md carrying the procedure behind each branch. Every budget
  # statement this file sweeps moved with its procedure, byte-for-byte:
  #   - the closing full sweep's one-round grant → reference/review-loop.md
  #     (the AWAITING_FIX branch it is decided on);
  #   - the +3 increment, the worked ceiling and the soft-cap nudge →
  #     reference/interactive.md (the interactive extension).
  # So the sweeps below name THOSE files. Naming the conductor instead would
  # leave every needle unfindable — or, worse, findable in a corpus while
  # nothing pinned which file it landed in.
  CONDUCTOR="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  SKILL="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md"
  EXTENSION="$REPO_ROOT/development/skills/resolve-issue/reference/interactive.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  # The panel-duties block of ARCHITECTURE.md, extracted ONCE and asserted
  # against instead of the whole file (#1434). Every ARCH needle in the
  # panel-duties test below is a `grep -F` fragment, and a fragment run over a
  # 3000-line document silently stops pinning its own sentence the moment the
  # same bytes appear anywhere else — which happened three times in this
  # story's own review, each time "fixed" by a longer fragment that the next
  # edit re-broke. Scoping to the section makes locality hold by construction,
  # so a recurrence elsewhere in the file can no longer retire a pin.
  ARCH_PANEL_DUTIES="$BATS_TEST_TMPDIR/arch-panel-duties.md"
  awk '/^## Review finding schema/{f=1} f&&/^### /{exit} f' "$ARCH" > "$ARCH_PANEL_DUTIES"
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
  # #1434 added a SECOND number to this file's remit: the closing full sweep's
  # one-round grant. It is a budget statement — it moves the ceiling — but it is
  # not a retune of MAX_REVIEW_ROUNDS or the +3 increment, so it needs its own
  # pin rather than riding on either.
  #
  # #1434 also brought this file its first NON-numeric invariant: the two duties
  # every review panel owes the loop (the panel-duties roster below). They live
  # in the same review-loop contract as the budget and would otherwise have no
  # sweep at all, which is why they are here rather than in a suite of their own.
  #
  # THREE sites, not the two the story named. #1434 scoped the prose work to the
  # two instruction sites (SKILL.md and the explanation page), but the loop's
  # contract section in ARCHITECTURE.md states the same grant and had to be
  # brought current in the same change — and guarding two of three would mint
  # exactly the unread third site the roster tripwire below exists to prevent
  # (the #1433 lesson). All three are already in ALL_SITES for the stale sweeps;
  # they are named separately here so the grant's own test says which sites it
  # governs.
  SWEEP_SITES=("$SKILL" "$EXPLAIN" "$ARCH")
  # DERIVED, not transcribed. The grant has no named constant, but it does have
  # an executable statement — the loop writes `round + 1` into the closing-sweep
  # marker — so the increment can be read out of the source like MAXR and
  # SOFTCAP are, instead of being a literal asserted against itself. A retune to
  # `round + 2` then reds here rather than passing a tautology.
  # `|| true` so an absent needle reaches the guard below with its explanation,
  # instead of failing setup on the pipeline's own exit status (the SOFTCAP
  # idiom above). The digits are extracted with sed, not a second grep anchored
  # at end-of-line: the matched text ends in `))`, not in the number.
  SWEEP_GRANT="$(grep -Eom1 'closing_sweep_round=\$\(\( round \+ [0-9]+ \)\)' "$LOOP" \
    | sed -E 's/.*round \+ ([0-9]+).*/\1/' || true)"
  [ -n "$SWEEP_GRANT" ] || {
    printf 'the closing-sweep increment (closing_sweep_round=$(( round + N ))) was not found in %s — the guard has nothing to check against\n' \
      "$LOOP" >&2
    return 1
  }
  # every live prose site, for the sweeps that must cover all of them at once
  # DERIVED over the skill, transcribed only for the non-skill sites (#1503).
  # The move turned one skill file into six, and the two negative sweeps
  # ALL_SITES feeds are the ones that must cover ALL of them — a transcribed
  # list that gained three of the six would leave reference/{residue,promotion,
  # escalation}.md unswept, and reference/promotion.md already discusses
  # --max-rounds, so it is a plausible carrier of a stale spelling. Deriving is
  # also what makes a SEVENTH skill file join automatically.
  #
  # The producer's STATUS is observed, never read through `< <(...)`:
  # `resolve_issue_files` returns 1 and prints nothing when `reference/` and its
  # roster disagree — exactly the case the derivation was added for — and both
  # consumers of ALL_SITES are NEGATIVE sweeps (`run -1 grep -Eq …`). Read
  # blindly, that path would drop all six skill files and make both sweeps PASS
  # while covering none of the skill: the vacuity deriving is supposed to
  # prevent. No count guard follows it: any figure derived from the same
  # producer is equal by construction and could never fire.
  local _f _listing
  _listing="$(resolve_issue_files "$REPO_ROOT")" || {
    printf 'the resolve-issue roster failed; ALL_SITES would be missing every skill file\n' >&2
    return 1
  }
  ALL_SITES=()
  while IFS= read -r _f; do [ -n "$_f" ] || continue; ALL_SITES+=("$_f"); done <<< "$_listing"
  # The NEGATIVE counterpart of SWEEP_SITES, built BEFORE the non-skill sites
  # are appended so it is the skill plus the two budget documentation pages —
  # not the panel agents and the motivation page, which have no business being
  # swept for a grant spelling.
  #
  # The two lists are deliberately different. A POSITIVE sweep asks "does every
  # site that must state the grant state it?", so it names only the sites that
  # carry it — after #1503 the conductor does not. A NEGATIVE sweep asks "has a
  # wrong spelling landed anywhere?", which must cover every file a drifted
  # restatement could land in, the conductor most of all: it is the one file
  # every run loads on every round. Retargeting the two TOGETHER is what left
  # the negative half sweeping a file with zero occurrences.
  NEG_SITES=("${ALL_SITES[@]}" "$EXPLAIN" "$ARCH")

  ALL_SITES+=("$ARCH" "$EXPLAIN" "$MOTIV" "$GATE" "$PROSE" "$TELEM" \
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
  # `--` so a needle that begins with a dash (e.g. a flag name) is a PATTERN,
  # not an option: without it `grep_site … '--fix-verification'` dies with
  # "unrecognized option", which `|| return 1` then reports as a missing needle.
  grep -Fq -e "$2" -- "$1" || {
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
  grep_num "$CONDUCTOR" "MAX_REVIEW_ROUNDS=$MAXR"
  grep_num "$ARCH" "MAX_REVIEW_ROUNDS=$MAXR"
  # ...and no OTHER value of the constant survives anywhere in the live prose.
  #
  # Swept over NEG_SITES — the DERIVED skill file set plus the two doc pages —
  # not a transcribed operand list. #1503 turned one skill file into six, and a
  # transcribed list is how the skill half of a negative sweep goes quiet: naming
  # only reference/review-loop.md read a file with ZERO occurrences of the
  # constant and passed on ARCHITECTURE.md's copy alone, and naming it plus the
  # conductor still left reference/promotion.md — which discusses the
  # MAX_REVIEW_ROUNDS default — unswept. Deriving is what makes a seventh skill
  # file join without an edit here.
  run grep -Eho 'MAX_REVIEW_ROUNDS=[0-9]+' "${NEG_SITES[@]}"
  [ "$status" -eq 0 ]
  while IFS= read -r hit; do
    [ "$hit" = "MAX_REVIEW_ROUNDS=$MAXR" ]
  done <<< "$output"
}

@test "the user-facing docs spell the default cap as five rounds (#993)" {
  grep -Fq 'five rounds by default' "$EXPLAIN"
  grep -Fq 'up to five rounds' "$MOTIV"
  grep -Fq 'five review rounds' "$CONDUCTOR"
  grep -Fq 'five review rounds' "$GATE"
}

@test "the digit-form restatements agree with the constant too (#993)" {
  # agent instructions quote the cap as a numeral, so the word-form sweep above
  # would never reach them — and a bare -F needle would match inside a bigger
  # number, so both are anchored
  grep_num "$PROSE" "escalates after $MAXR rounds"
  grep_num "$ARCH" "$MAXR-round default"
  # No other numeral claims to be the default cap — over NEG_SITES, so a drifted
  # cap in ANY skill file reds. $ARCH alone swept no skill file at all.
  run grep -Eho '[0-9]+-round default' "${NEG_SITES[@]}"
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

@test "the closing full sweep's one-round grant is stated identically at every live site (#1434)" {
  # The grant is the one place the review loop may run PAST the ceiling the
  # caller set, so a site that drifts to a different size is a site that
  # mis-describes the budget. Positive pins first, so deleting the statement
  # reds here instead of silently retiring the guard.
  [ "$SWEEP_GRANT" -eq 1 ]   # the word form below is spelled for this value
  local site
  for site in "${SWEEP_SITES[@]}"; do
    # `closing full sweep` is INERT as a guard — it also matches the unrelated
    # promotion prose at every site — so it stays only as a cheap presence
    # check; the pins that do the work are below it.
    grep_site "$site" 'closing full sweep'
    grep_site "$site" 'exactly one round beyond'
  done
  # ...and the two qualifications that ride with the SIZE. Without them the
  # grant could be reworded repeatable ("each time it is needed"), or the
  # not-a-retune claim deleted, with the size needle still matching — and a
  # session reading either would then have no reason not to "fix" the overrun
  # by raising --max-rounds itself, which the same paragraph forbids. Pinned
  # per site because each states them in its own voice.
  grep_site "$SKILL" 'beyond the ceiling, once'
  grep_site "$ARCH" 'beyond `--max-rounds`, once'
  grep_site "$EXPLAIN" 'once, and only for that sweep'
  grep_site "$SKILL" 'still reports what you passed'
  grep_site "$ARCH" 'keeps reporting what the caller passed'
  grep_site "$EXPLAIN" 'is still what gets reported'
  # Ban the REPEATABLE shape outright, in either spelling — over NEG_SITES, not
  # SWEEP_SITES. The two lists differ on purpose: SWEEP_SITES is where the grant
  # IS stated (the conductor legitimately no longer states it, so the positive
  # loop above must not read it), while a NEGATIVE sweep must cover every file a
  # drifted restatement could land in — the conductor most of all, since it is
  # the one file every run loads on every round.
  run -1 grep -Eqi 'rounds? beyond [^.]*(each|every) time|granted (again|repeatedly)' \
    "${NEG_SITES[@]}"
  # Ban the SHAPE, not three sentences: any OTHER count of rounds "beyond" the
  # ceiling, in either spelling, including a digit form of the correct value —
  # the canonical spelling is the word form, and a digit twin is a second site
  # the next retune would not read. "one round beyond" is deliberately not
  # matched: neither the word alternation nor `[0-9]+` can reach it.
  run -1 grep -Eqi '(exactly )?(two|three|four|five|six|seven|eight|nine|ten|[0-9]+) (more |extra |additional )?rounds? beyond' \
    "${NEG_SITES[@]}"
}

@test "every review panel carries all FOUR loop obligations, and the roster is exactly six (#1434)" {
  # ARCHITECTURE.md asserts a cross-file invariant over seven sites: each of the
  # six `development-*/skills/review/SKILL.md` panels states (a) that an EMPTY
  # scope handed down by the loop is never a licence to review everything, and
  # that on a DELTA round that carries nothing the panel must still write `[]`
  # rather than no file at all — with its THREE mandatory qualifications: not on
  # a FULL round, where an empty scope means the story diff itself is empty; not
  # with a non-empty carry, where a bare `[]` would retire carried blockers
  # unconfirmed; and not on a null/unreadable carry at round >= 2, which is a
  # caller slip rather than an empty carry. Plus the confirmation-count report,
  # and its SCOPE (any non-empty carry, whatever is written). Each is needled
  # separately below. And (b)
  # that from round 2 on it forwards the plan's two carry paths into every
  # agent's prompt. Neither duty had a sweep, so a seventh panel — or a
  # refactor of an existing one — could land without either and ship green.
  #
  # The invariant is the two DUTIES, not the bytes: each panel spells them in
  # its own scope vocabulary (repo / project / rendered temp tree), so the
  # needles below are the load-bearing fragments common to all six, never a
  # whole sentence. Adding a panel means adding both duties, not matching
  # anyone's phrasing.
  local discovered expected panel
  local found=()
  git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || {
    printf 'not a git worktree, cannot derive the roster: %s\n' "$REPO_ROOT" >&2
    return 1
  }
  # `-z` + `read -d ''` for the same reason the rosters below use it: git
  # C-quotes an awkward path, grep then exits 2, and the file would drop out
  # SILENTLY — the fail-OPEN direction this tripwire exists to catch.
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    found+=("$f")
  done < <(cd "$REPO_ROOT" \
    && git -c core.quotePath=false ls-files -z 'development-*/skills/review/SKILL.md')
  discovered="$(printf '%s\n' "${found[@]}" | sort -u)"
  expected="$(printf '%s\n' \
    "development-claude-plugin/skills/review/SKILL.md" \
    "development-go/skills/review/SKILL.md" \
    "development-java/skills/review/SKILL.md" \
    "development-kubernetes/skills/review/SKILL.md" \
    "development-python/skills/review/SKILL.md" \
    "development-swift/skills/review/SKILL.md" | sort -u)"
  # roster equality FIRST: a new panel reds here before the duty checks below
  # can pass over it
  [ "${#found[@]}" -ge 1 ]
  [ -n "$discovered" ]
  [ "$discovered" = "$expected" ]
  # the SEVENTH site: ARCHITECTURE.md states the same invariant and hardcodes
  # the roster's size, so without these a drift there (or a seventh panel that
  # never reaches the contract doc) leaves the suite green
  [ "${#found[@]}" -eq 6 ]
  # Fragments unique to the sentence each one pins — the bare descriptor tokens
  # recur in the same section's JSON sample, so they are presence checks only.
  grep_site "$ARCH_PANEL_DUTIES" 'a second injection duty'
  grep_site "$ARCH_PANEL_DUTIES" "forward both into each agent's launch prompt"
  grep_site "$ARCH_PANEL_DUTIES" 'All six panels (`claude-plugin`'
  grep_site "$ARCH_PANEL_DUTIES" 'carry **both rules**'
  grep_site "$ARCH_PANEL_DUTIES" 'never a licence to'
  grep_site "$ARCH_PANEL_DUTIES" 'fix_verification_path'
  grep_site "$ARCH_PANEL_DUTIES" 'adjudicated_path'
  # ...including the two qualifications it declares mandatory, so deleting them
  # from the contract doc cannot pass either
  # Each ARCH needle is UNIQUE to the panel-duties section. `CONVERGED
  # condition` on its own is not: it occurs three more times 700 lines away, in
  # the refusal discussion, so the qualification could be deleted here and the
  # sweep would still pass on that unrelated prose — the same wrong-branch
  # defect this test was hardened for on the panel half.
  grep_site "$ARCH_PANEL_DUTIES" 'Not on a **full** round'
  grep_site "$ARCH_PANEL_DUTIES" 'over a story that changed nothing'
  # `fix_verification_path` holds entries` became INERT once the widened
  # confirmation-count paragraph introduced a second line carrying the same
  # bytes — grep -F is line-oriented, so it now matches that paragraph and no
  # longer pins the qualification it was written for. Pin the qualification on
  # fragments unique to its own sentence instead, and keep the old needle only
  # as a presence check.
  grep_site "$ARCH_PANEL_DUTIES" '`fix_verification_path` holds entries'
  grep_site "$ARCH_PANEL_DUTIES" 'would retire carried'
  grep_site "$ARCH_PANEL_DUTIES" 'the panel dispatches with the carry'
  grep_site "$ARCH_PANEL_DUTIES" 'reports how many carried entries it confirmed'
  grep_site "$ARCH_PANEL_DUTIES" 'confirmation-count report'
  # (2) the SCOPE of the count duty — the widening itself, not merely that a
  # count exists. Every needle above survives a re-narrowing to "when it writes
  # `[]`", which is the regression the widening exists to prevent.
  grep_site "$ARCH_PANEL_DUTIES" 'whatever it writes to the'
  grep_site "$ARCH_PANEL_DUTIES" '`[]` or otherwise'
  # (3) the THIRD qualification: a null carry is a caller slip, not an empty one
  grep_site "$ARCH_PANEL_DUTIES" 'write **no findings file at all** there'
  for panel in "${found[@]}"; do
    # (a) the empty-scope duty. FOUR needles, not two, and each chosen to be
    # unique to the branch it asserts:
    #   * the refusal to widen;
    #   * the obligation to write `[]` anyway — as `still write `[]``, NOT the
    #     bare `write `[]``, which every panel also carries in the paragraph
    #     saying the OPPOSITE ("Do **not** write `[]` there"). With the bare
    #     needle the positive half could be deleted outright and this sweep
    #     would still pass on the negative half's bytes;
    #   * the FULL-round qualification, and
    #   * the CARRY precondition — ARCHITECTURE calls both mandatory ("a panel
    #     is not correctly wired without them"), so a sweep that reaches
    #     neither lets either be deleted silently.
    grep_site "$REPO_ROOT/$panel" 'never a licence to'
    grep_site "$REPO_ROOT/$panel" 'still write `[]`'
    grep_site "$REPO_ROOT/$panel" 'CONVERGED condition'
    # `carried blocker you c` — NOT the bare `carried blocker`, which also
    # matches the EXEMPTION paragraph ("every carried blocker landed"), so the
    # prohibition could be deleted outright and the sweep would pass on the
    # sentence granting the opposite permission.
    grep_site "$REPO_ROOT/$panel" 'carried blocker you c'
    # ...and the confirmation-count REPORT, which §3.5 step 2 keys a recovery
    # arm on: without the count a caller cannot tell a `[]` that passed
    # verification from one that skipped it
    grep_site "$REPO_ROOT/$panel" 'you confirmed N carried'
    # ...and the SCOPE of that duty, which the needle above survives losing
    grep_site "$REPO_ROOT/$panel" 'whatever you write to the findings file'
    grep_site "$REPO_ROOT/$panel" '`[]` or otherwise'
    # the null-carry terminal, the third qualification
    grep_site "$REPO_ROOT/$panel" 'Absence of the carry is never'
    grep_site "$REPO_ROOT/$panel" '--fix-verification'
    # (b) the two-carry injection duty. The descriptor tokens alone do NOT
    # pin it: they also occur in the maintainer-facing narrative that
    # introduces the duty, and kubernetes' prompt binds {FIX VERIFICATION} /
    # {ADJUDICATED} instead — so deleting both prompt lines from all six would
    # leave every token needle matching. Pin the PROMPT LINES themselves, which
    # are byte-identical across all six.
    grep_site "$REPO_ROOT/$panel" 'fix_verification_path'
    grep_site "$REPO_ROOT/$panel" 'adjudicated_path'
    grep_site "$REPO_ROOT/$panel" "the previous round's blockers. Confirm each one actually landed"
    grep_site "$REPO_ROOT/$panel" 'Say in your report how many of them you confirmed landed'
    grep_site "$REPO_ROOT/$panel" 'suggestions earlier rounds surfaced and the human waived'
  done
}

@test "the five language panels state the delta-carry block in LOCKSTEP, not merely in fragments (#1434)" {
  # A structural assertion, deliberately NOT another needle. The per-panel
  # `grep -F` fragments above cannot express two things this invariant asserts,
  # and every recurrence of "the sweep was green on a broken panel" in this
  # story traced to one of them:
  #
  #   * a fragment is LINE-oriented, and every load-bearing sentence here wraps,
  #     so no needle can span a clause. Inverting a prohibition — "do not write
  #     a bare `[]`" -> "you may still write a bare `[]`" — leaves every
  #     fragment matching, because the negation and its object are on different
  #     lines.
  #   * a fragment set is BLIND between its needles. A dangling aside and a
  #     duplicated line survived five panels for a full round precisely there.
  #
  # Normalise the block (wraps joined, emphasis stripped) and require the five
  # language panels to agree byte-for-byte. Any of those mutations changes the
  # string in at least one panel, so all of them red. kubernetes is excluded on
  # purpose: its render-first flow states the same duties in its own vocabulary,
  # which the per-panel needles above cover.
  local -a lang=(
    "$REPO_ROOT/development-claude-plugin/skills/review/SKILL.md"
    "$REPO_ROOT/development-go/skills/review/SKILL.md"
    "$REPO_ROOT/development-java/skills/review/SKILL.md"
    "$REPO_ROOT/development-python/skills/review/SKILL.md"
    "$REPO_ROOT/development-swift/skills/review/SKILL.md"
  )
  local f ln ref="" cur
  for f in "${lang[@]}"; do
    # the block runs from the delta-carry heading to the FULL-round heading
    ln="$(grep -n -e 'On a DELTA round that' -- "$f" | head -n 1 | cut -d: -f1)"
    [ -n "$ln" ] || { printf 'no delta-carry block in %s\n' "$f" >&2; return 1; }
    cur="$(awk -v s="$ln" 'NR>=s{print} NR>s && /^\*\*That `\[\]` is the DELTA-round rule/{exit}' "$f" \
           | tr -d '*`' | tr -s '[:space:]' ' ')"
    [ -n "$cur" ] || { printf 'empty delta-carry block in %s\n' "$f" >&2; return 1; }
    # a duplicated line is invisible to a fragment set but not to this
    if [ -z "$ref" ]; then ref="$cur"; else
      [ "$cur" = "$ref" ] || {
        printf 'delta-carry block differs in %s\n  ref: %s\n  cur: %s\n' "$f" "$ref" "$cur" >&2
        return 1
      }
    fi
  done
  # ...and it really does say the load-bearing things, so five identically
  # BROKEN panels cannot pass by agreeing with each other
  case "$ref" in
    *"do not write a bare []"*) : ;;
    *) printf 'the agreed block does not forbid a bare []: %s\n' "$ref" >&2; return 1 ;;
  esac
  case "$ref" in
    *"re-raise every carried blocker you cannot confirm"*) : ;;
    *) printf 'the agreed block does not require the re-raise: %s\n' "$ref" >&2; return 1 ;;
  esac
  case "$ref" in
    *"Absence of the carry is never evidence of an empty one."*) : ;;
    *) printf 'the agreed block lacks the null-carry terminal: %s\n' "$ref" >&2; return 1 ;;
  esac
}

@test "every site stating the closing-sweep grant is on the roster (#1434)" {
  # The closed-list tripwire, same construction as the #1433 one below-ish: a
  # sibling of #1431 that restates the grant in a file SWEEP_SITES does not name
  # would go unguarded, and the sweep above would happily pass over the two we
  # happen to list. Derive the real set from the tree and require equality.
  #
  # Enumerated exactly like the sibling roster in the #1433 test: `-z` +
  # `read -d ''` because git C-quotes a path holding a non-ASCII byte, a quote
  # or a backslash — grep then exits 2, the `if` is false, and the file drops
  # out SILENTLY, which is the fail-OPEN direction and precisely the case this
  # tripwire exists to catch. `--` and `</dev/null` on the probe so a path
  # beginning with `-` is not parsed as options and an empty path cannot eat the
  # loop's stdin. `sort -u` on both sides so a conflicted index (one path listed
  # per stage) does not red mid-rebase.
  #
  # Frozen design records under docs/superpowers/ are excluded for the same
  # reason the rest of this file excludes them: they are dated snapshots, not
  # live instruction.
  local discovered expected
  local found=()
  git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || {
    printf 'not a git worktree, cannot derive the roster: %s\n' "$REPO_ROOT" >&2
    return 1
  }
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    if grep -q 'exactly one round beyond' -- "$REPO_ROOT/$f" </dev/null; then
      found+=("$f")
    fi
  done < <(cd "$REPO_ROOT" \
    && git -c core.quotePath=false ls-files -z '*.md' ':!:docs/superpowers/**')
  [ "${#found[@]}" -ge 1 ]
  discovered="$(printf '%s\n' "${found[@]}" | sort -u)"
  [ -n "$discovered" ]
  # SWEEP_SITES holds absolute paths; the listing is repo-relative
  local rel=() s
  for s in "${SWEEP_SITES[@]}"; do rel+=("${s#"$REPO_ROOT/"}"); done
  expected="$(printf '%s\n' "${rel[@]}" | sort -u)"
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
  # reference/interactive.md — the offer texts, the bookkeeping note, the
  # ceiling semantics and the invocation that implements them (#1503 moved the
  # interactive extension there byte-for-byte; the conductor keeps the exit-code
  # table and a pointer, neither of which states a number)
  grep_num "$EXTENSION" "Grant \+$INCREMENT rounds"
  grep_num "$EXTENSION" "Grant \+$INCREMENT with guidance"
  grep_num "$EXTENSION" "retry \(\+$INCREMENT\)"
  grep_num "$EXTENSION" "\+$INCREMENT/.grants. bookkeeping"
  grep -Fq 'exactly three more rounds' "$EXTENSION"
  grep -Fq 'grant "three more rounds"' "$EXTENSION"
  grep_num "$EXTENSION" "ceiling raised by $INCREMENT"
  grep_num "$EXTENSION" "raises the \*ceiling\* by $INCREMENT"
  grep -Fq 'leaves more than three' "$EXTENSION"
  grep_num "$EXTENSION" "prev_max \+ $INCREMENT"
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
  grep_num "$EXTENSION" "ceiling $first_ceiling after the default budget, rounds $(( MAXR + 1 ))-$first_ceiling"
  grep_num "$EXTENSION" "ceiling $first_ceiling after a round-2 exit = $(( first_ceiling - 2 )) rounds left"
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
  for site in "$EXPLAIN" "$EXTENSION" "$ARCH"; do
    grep_num "$site" "$MAXR \+ ${SOFTCAP}×$INCREMENT = $ceiling"
  done
  # SKILL.md also restates the derived number on its own; recompute it too
  grep_num "$EXTENSION" "$ceiling-round figure"
}

@test "the soft cap is a nudge at every site that states it (#993)" {
  local site
  for site in "$EXTENSION" "$ARCH" "$EXPLAIN"; do
    grep_site "$site" 'not a hard stop'
  done
  # and the cap's own value agrees with what build-escalation.zsh renders,
  # in the digit form...
  grep_num "$EXTENSION" "grants >= $SOFTCAP"
  grep_num "$ARCH" "$SOFTCAP-grant soft cap"
  # ...and in the word form the human-facing prose uses. Both spellings, or the
  # unguarded one drifts (the whole point of this file).
  [ "$SOFTCAP" -eq 5 ]   # the word forms below are spelled for this value
  grep -Fq 'five grants' "$EXPLAIN"
  grep -Fq 'five-grant point' "$EXPLAIN"
  grep -Fq 'by the fifth grant' "$EXTENSION"
  grep -Fq 'by the fifth grant' "$ARCH"
}
