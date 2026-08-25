#!/usr/bin/env bats
#
# #1496: a review-loop fix pass SUBTRACTS — it deletes, narrows or collapses,
# and never adds arms, cases, flags, paragraphs or restatements.
#
# WHY THIS FILE EXISTS. The rule's whole content is prose: nothing in
# `resolve-story-loop.zsh` refuses a fix, and nothing ever will (the story puts
# a mechanical refusal explicitly out of scope). So the only thing that can
# catch the rule drifting — or, far more likely, the rule being VIOLATED BY ITS
# OWN RESTATEMENTS — is a sweep.
#
# The self-referential hazard is the point. Rule 2 says a fact restated in more
# than two sites is collapsed to one normative site plus pointers. A story that
# put the rule in §3.5, the promotion sub-loop, the interactive extension,
# `docs/explanation/review-loop.md` and `ARCHITECTURE.md` — five copies of one
# list — would have broken its own rule in the act of stating it. The
# single-occurrence tests below are what make that impossible to land quietly.
#
# SHAPE, and why each half earns its place:
#
#   * the NORMATIVE half asserts the four-item list appears EXACTLY ONCE in
#     `development/skills/resolve-issue/SKILL.md`, item by item. Item by item
#     rather than by a banner count, because a second copy pasted without its
#     banner is exactly the shape a banner count would miss — and it is the
#     shape a fix pass produces, since a fix pass copies the rules it is obeying
#     and not the heading above them;
#   * the POINTER half asserts the two consuming sites carry a pointer and no
#     list. Counted, so a pointer that grows back into a restatement reds here;
#   * the DOC half pins the two documentation sites BY CONTENT — that they
#     mention the rule, and that they point at §3.5 rather than restating it;
#   * a ROSTER TRIPWIRE over `git ls-files '*.md' '*.md.tmpl'`, so a fourth
#     site naming the rule reds rather than passing in silence. Shipped
#     templates are in scope because `approver-policy-core.md.tmpl` already
#     restates review-loop rules. Derived, never transcribed (MAINTAINING.md,
#     *Derive the roster, never transcribe it*);
#   * NON-VACUITY controls that mutate a real site copied into a fixture, one
#     per gap kind the sweep can report.
#
# Needles are normalised through `load prose-lockstep` (#1432) — the shared
# derivation, so emphasis, code ticks and reflows cannot silently retire a pin.
# Every gate needle is chosen to fit on ONE source line, which
# `prose_gate_lines` requires; the wrap-tolerant clause tests run over
# `prose_window`, which collapses whitespace.
#
# This sweep pins WORDING, not meaning. A substantively-correct rephrase at one
# site reds it, and the red is telling you to reword every site, not to relax
# the needle.

bats_require_minimum_version 1.5.0

load assertions
load prose-lockstep

load resolve-issue-corpus

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # #1503 split this skill into a conductor plus reference/*.md. Sweeps that
  # COUNT sites across the skill read the corpus; sweeps that pin WHERE a
  # sentence lives read the one file it lives in. See resolve-issue-corpus.bash.
  CONDUCTOR="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  PROTO="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md"
  SKILL="$(resolve_issue_corpus "$REPO_ROOT" "$BATS_TEST_TMPDIR/resolve-issue-corpus.md")"
  EXPLAIN="$REPO_ROOT/docs/explanation/review-loop.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"

  # The four rules, one distinctive per-line fragment each. Deliberately the
  # RULE's own words rather than its banner: see the header.
  RULE_NEEDLES=(
    'New behaviour is parked, not applied.'
    'A stale restatement at more than two sites is fixed by removal'
    'A stale count is fixed by naming instead of counting'
    'A test-dimension finding is fixed with the ONE assertion'
  )
  # The banner of the one normative statement. It carries the issue number, so
  # it can never collide with the pointers, which name the section instead.
  RULE_HEADING='A fix pass subtracts (#1496)'
  # What a POINTER looks like: the rule's name plus where it lives, and no rule.
  POINTER="A fix pass subtracts (§3.5's round protocol, step 3)"
  # The roster needle — the shortest phrase every site shares. Deliberately
  # WITHOUT the issue number, so the tripwire sees a new site that names the
  # rule in prose as readily as one that cites it.
  ROSTER_NEEDLE='A fix pass subtracts'
}

# Lines of $1 whose normalised text carries the literal $2, as a COUNT.
#
# `prose_gate_lines` prints one line number per hit and nothing at all on a
# miss, so `wc -l` over its output is the occurrence count — but only once the
# helper's own status has been checked, because a 2 (unreadable file, empty
# needle) also prints nothing and would otherwise read as a clean zero.
_hits() {
  local out
  out="$(prose_gate_lines "$1" "$2")" || return 2
  if [ -z "$out" ]; then printf '0\n'; return 0; fi
  printf '%s\n' "$out" | wc -l | tr -d ' '
}

# The markdown files under $1 that name the rule, one per line.
#
# Takes a ROOT and a NUL-SEPARATED file list on stdin rather than shelling out
# to git itself, so the non-vacuity control below can drive the same code over a
# synthetic roster instead of writing a decoy site into the repo — a control
# that mutated the repo would leave the real tripwire above testing the
# mutation. NUL-separated because `git ls-files` without `-z` C-quotes any path
# holding a non-ASCII byte, a quote or a backslash, and splits one holding a
# newline: both then fail the existence check and drop out of the roster
# SILENTLY, which is the one direction a tripwire cannot afford.
#
# The haystack is NORMALISED the same way every other pin in this file is, so a
# site spelling the rule `A **fix pass subtracts**` — emphasis inside the phrase
# rather than around it — is seen. Matching the raw bytes would have counted the
# three current sites only by luck of where their asterisks fall.
_roster_hits() {
  local root="$1" needle="$2" f rc
  while IFS= read -r -d '' f; do
    case "$f" in docs/superpowers/*) continue ;; esac
    # -r as well as -f: `grep` never opens the file here — `sed` does, and
    # `grep` reads a pipe — and bats runs no `pipefail`, so an unreadable file
    # would leave `grep` on an empty stream returning 1, i.e. folded into "does
    # not name the rule". This guard is what actually prevents that under-count;
    # the `rc` case below only catches grep's own stream-level errors.
    if [ ! -f "$root/$f" ] || [ ! -r "$root/$f" ]; then
      printf 'roster: listed path is not a readable file: %s\n' "$f" >&2
      return 2
    fi
    rc=0
    # -a so a stray NUL cannot turn a match into "Binary file … matches";
    # -i because a site may name the rule mid-sentence, where the article is
    # lowercase — the shape that would otherwise be a fourth site in silence.
    #
    # `tr -s '[:space:]' ' '` because this asks a FILE-level question and needs
    # no line numbers: without it `tr -d` keeps the newlines, the needle has to
    # fall inside one physical line, and a mention wrapped mid-phrase across two
    # lines — the likeliest shape for a mid-sentence one — drops out of the
    # roster silently. That is the same collapse `prose_body` performs, and the
    # only reason `prose_gate_lines` cannot do it is that it must keep line
    # numbers, which nothing here wants.
    sed 's/^[[:space:]]*#[[:space:]]\{0,1\}//' "$root/$f" | tr -d '*`' \
      | tr -s '[:space:]' ' ' | grep -qaiF -e "$needle" || rc=$?
    case "$rc" in
      0) printf '%s\n' "$f" ;;
      1) ;;
      *) printf 'roster: grep failed (%s) on %s\n' "$rc" "$f" >&2; return 2 ;;
    esac
  done
}

# --- the normative statement, stated exactly once ---------------------------

@test "#1496 each of the four subtract rules appears exactly ONCE in SKILL.md" {
  local needle n
  for needle in "${RULE_NEEDLES[@]}"; do
    n="$(_hits "$SKILL" "$needle")"
    if [ "$n" -ne 1 ]; then
      printf 'expected exactly 1 occurrence of "%s" in SKILL.md, found %s\n' \
        "$needle" "$n" >&2
      return 1
    fi
  done
}

@test "#1496 the normative statement carries its banner, exactly once" {
  local n
  n="$(_hits "$SKILL" "$RULE_HEADING")"
  [ "$n" -eq 1 ]
}

@test "#1496 the four rules sit under the banner, not scattered across §3.5" {
  # Locality, not mere presence: four fragments that each appear once could
  # still be four paragraphs pages apart, which is the restatement shape the
  # rule bans. The window is generous because the list carries rationale
  # between its items.
  local ln body needle
  ln="$(prose_gate_lines "$SKILL" "$RULE_HEADING")"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 60)"
  for needle in "${RULE_NEEDLES[@]}"; do
    contains "$body" "$needle"
  done
}

@test "#1496 the parked arm files at PARK time and says where the note goes" {
  # Rule 1 is inert without a route out, and the route has to be reachable: a
  # parked blocker is re-raised every later round, so the run trends to
  # ESCALATE_NO_CONVERGENCE — where no terminal arm fires and a
  # file-it-at-the-terminal rule would file nothing at all.
  local ln body
  ln="$(prose_gate_lines "$SKILL" "$RULE_HEADING")"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 70)"
  contains "$body" 'File it NOW, not at a terminal.'
  contains "$body" 'open its follow-up with gh issue create'
  # the exact write, since neither named artifact would accept a note
  contains "$body" 'append a one-line - parked: <title> -> #<issue> note to <work-dir>/progress.md'
  contains "$body" 'never write a note into either'
  # the file-once instruction, not its banner: the banner survives deletion of
  # the sentence that actually prevents a duplicate issue per round
  contains "$body" 'reuse the number from the earlier - parked: note instead of opening a second issue'
  # and why the terminal route was not the rule
  contains "$body" 'trends toward ESCALATE_NO_CONVERGENCE'
  contains "$body" 'escalating by design'
  contains "$body" 'a park nobody filed is a finding the run dropped'
}

# --- the trigger, in the three #1435 class names ----------------------------

@test "#1496 §3.5 states the class trigger that makes collapsing MANDATORY" {
  local ln body
  # gate on the condition itself, which the source keeps on one line
  ln="$(prose_gate_lines "$SKILL" 'incomplete_propagation + under_assertion >= new_defect')"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 20)"
  contains "$body" "rule 2's collapse is MANDATORY for this round"
  # the ARITHMETIC: summed vs per-round give opposite verdicts on the same
  # histogram, and no script computes an aggregate to settle it
  contains "$body" 'Sum the last two rounds'
  contains "$body" 'the literal last two, the same window'
  contains "$body" 'summed, never compared per round'
  # the ABSENT arm, pinned as a CLAUSE. The bare word "advisory" survived a
  # rewrite that deleted the round-1 escape entirely, which is the arm the rule
  # most needs: no fix pass has been stamped yet on round 1.
  contains "$body" "If either of those two rounds is absent, the histogram is absent — round 1, an unstamped round, or a pre-#1435 work-dir — and then only rule 2's collapse relaxes to advisory"
  # …and that the relaxation is SCOPED, or the whole rule reads as optional
  contains "$body" 'Rules 1, 3 and 4, and the ban on adding surface, bind every fix pass'
  # rule 3 is absolute: an earlier draft let the relaxation cover it, which
  # licensed the numeral update rule 3 exists to ban
  contains "$body" 'a stale count is never fixed by updating the numeral, on any round'
  # the zero-blocker round, which renders no progress.md row but is not absent
  contains "$body" 'a zero-blocker round counts as 0/0/0 and is present'
  contains "$body" 'Otherwise the histogram is present.'
}

@test "#1496 the unstamped-cell sentinel is spelled as the script renders it" {
  # build-escalation.zsh emits an EN DASH. A hyphen here would not match the
  # rendered table, and the round would be scored 0/0/0 — precisely the reading
  # the same sentence forbids.
  local ln body
  ln="$(prose_gate_lines "$SKILL" 'incomplete_propagation + under_assertion >= new_defect')"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 20)"
  contains "$body" 'a – cell — an en dash, as that script emits — is the stamp-less sentinel'
}

@test "#1496 the four rules keep their operative clauses, not just their headlines" {
  # The uniqueness pins above match one leading fragment per rule, so every
  # rule's substance is mutable underneath them: delete rule 1's overrides,
  # widen rule 2's threshold, invert rule 3's remedy, drop rule 4's bar — all
  # green. These are the clauses that decide what a fix pass actually does.
  local ln body
  ln="$(prose_gate_lines "$SKILL" "$RULE_HEADING")"
  [ -n "$ln" ]
  # 80, not 70: the binding paragraph sits at the far edge of the block and a
  # tighter span would silently stop pinning it after any reflow
  body="$(prose_window "$SKILL" "$ln" 80)"
  # rule 1's overrides — without them the rule refuses work a human asked for
  contains "$body" 'Three things override this, and all three are somebody asking for the surface on purpose'
  contains "$body" "the story's own acceptance criteria, a human's granted-round guidance, and a human-promoted suggestion"
  # rule 2's threshold, and the two-site side it would otherwise leave open
  contains "$body" 'keep one normative site and make every other site point at it'
  contains "$body" 'At two sites or fewer, correct both copies in this same pass and add no pointer'
  # rule 3's remedy, which four consecutive rounds got wrong by updating a numeral
  contains "$body" 'replace the tally with the names, or with nothing'
  # rule 4's bar
  contains "$body" 'never a new helper, fixture family or counter'
  # and the spread bound, which rule 2's collapse makes unavoidable — with
  # #982's carve-out, or the bound reads as revoking the sibling sweep three
  # lines above it
  contains "$body" 'may edit the sites of the facts this round'
  contains "$body" 'every sibling instance of a pattern a finding names'
  # the paragraph that stops rule 1's overrides being self-granted inside a fix
  # pass: without it, "a human's ask" licenses unreviewed surface
  contains "$body" 'The rule binds this fix pass, not the story.'
  contains "$body" 'rather than smuggled in unreviewed'
  contains "$body" "a human's ask in this fix pass"
}

@test "#1496 the list is CLOSED — exactly four numbered rules under the banner" {
  # "Four rules, and the list is closed" is load-bearing for this whole sweep,
  # and nothing else here would notice a fifth. Counted structurally rather
  # than by pinning the word "Four", since a bare tally is the stale-count
  # shape rule 3 itself bans.
  local ln n
  ln="$(prose_gate_lines "$SKILL" "$RULE_HEADING")"
  [ -n "$ln" ]
  # Any indent, any emphasis: pinning the one shape the four rules happen to
  # use today would let an unemphasised or re-indented fifth item land green.
  # Widening only ever fails CLOSED — a re-indent of the existing four still
  # counts 4.
  n="$(sed -n "${ln},$((ln + 70))p" "$SKILL" | grep -cE '^[[:space:]]*[0-9]+\.[[:space:]]' || true)"
  # a grep that ERRORS prints nothing, and `[ "" -ne 4 ]` inside an `if`
  # condition is exempt from errexit — the branch is skipped and this
  # load-bearing pin reports ok having counted nothing
  case "$n" in ''|*[!0-9]*)
    printf 'closure pin: grep produced no count\n' >&2; return 1 ;;
  esac
  if [ "$n" -ne 4 ]; then
    printf 'expected exactly 4 numbered rules under the banner, found %s\n' "$n" >&2
    return 1
  fi
}

@test "#1496 step 3 points at the rule where it implements the blockers" {
  # The rule is inert if the fix step never reaches it. This pins the reference
  # ON the branch where the session decides what to do next — the sibling sweep
  # treats the same shape as first-class.
  # Located in $PROTO, not the corpus (#1503). The corpus concatenates six files,
  # so `banner > ln` there says nothing about which file the banner is in: moving
  # the rule block into a LATER member would keep the comparison true while step
  # 3's "immediately below" pointed at a rule that is not in the file the session
  # is reading. And "immediately below" is a proximity claim, so assert proximity
  # rather than mere ordering — the ordering alone survives the whole block being
  # pushed hundreds of lines away.
  local ln body
  ln="$(prose_gate_lines "$PROTO" "sibling-sweeping each blocker's pattern across the whole")"
  [ -n "$ln" ]
  body="$(prose_window "$PROTO" "$ln" 6)"
  contains "$body" 'subtracting rather than adding, per the rule stated immediately below'
  local banner
  banner="$(prose_gate_lines "$PROTO" "$RULE_HEADING")"
  [ -n "$banner" ]
  [ "$banner" -gt "$ln" ]
  [ "$(( banner - ln ))" -lt 12 ]
}

@test "#1496 the trigger is stated ONCE, so it cannot drift against itself" {
  local n
  n="$(_hits "$SKILL" 'incomplete_propagation + under_assertion >= new_defect')"
  [ "$n" -eq 1 ]
}

# --- the two consuming sites point, and do not restate ----------------------

@test "#1496 exactly two SKILL.md sites carry the pointer" {
  # The promotion sub-loop's fix step, and the interactive extension's granted
  # fix pass. A third would mean a consumer was added without being counted; a
  # single one would mean the other lost its pointer to a rewrite.
  local n
  n="$(_hits "$SKILL" "$POINTER")"
  [ "$n" -eq 2 ]
}

@test "#1496 the promotion sub-loop points at the rule instead of restating it" {
  local ln body
  ln="$(prose_gate_lines "$SKILL" 'the round protocol above — adding --promote. Its fix passes')"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 8)"
  contains "$body" "$POINTER"
  contains "$body" 'it is not restated'
  lacks "$body" 'New behaviour is parked, not applied.'
}

@test "#1496 the interactive extension points at the rule instead of restating it" {
  local ln body
  ln="$(prose_gate_lines "$SKILL" 'like any other, and a granted round is where it is likeliest')"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 8)"
  contains "$body" "$POINTER"
  contains "$body" 'it is not restated here'
  lacks "$body" 'A stale count is fixed by naming instead of counting'
}

# --- the two documentation sites, pinned by content -------------------------

@test "#1496 the review-loop explanation mentions the rule and points at §3.5" {
  local ln body
  ln="$(prose_gate_lines "$EXPLAIN" 'A fix pass subtracts.')"
  [ -n "$ln" ]
  # FORWARD-ONLY and paragraph-tight, the idiom tests/round-boundary-wait.bats
  # uses for its pins on this page. Both neighbours are BEHIND the gate line —
  # #1513's turn-boundary paragraph immediately above, the concurrency one above
  # that — so a centred span overruns backwards, and every needle below becomes
  # a claim about "somewhere in three paragraphs" rather than about this one:
  # the overrides clause could be moved into a neighbouring paragraph with this
  # sweep still green, which is the drift this pin exists to red on. Forward
  # there is only the next section heading, so the span buys nothing that way.
  body="$(prose_window "$EXPLAIN" "$((ln + 6))" 6)"
  # what the rule IS — without this the page names it and points at §3.5 while
  # saying nothing about what it does
  contains "$body" 'allowed to delete, narrow or collapse; it is not allowed to grow the change'
  contains "$body" 'parked as a follow-up'
  # …and the class trigger, which is the half this story exists to add
  contains "$body" 'stops being advisory and becomes required'
  # ONE compound needle, not two adjacent ones: #1513 added a paragraph to this
  # same page that also ends "… and nothing here restates it", so a bare
  # 'nothing here restates it' would be satisfied by THAT paragraph the moment
  # this window widened — and the disclaimer could then be deleted from this one
  # with the suite still green. Only the pointer text makes the needle unique to
  # this rule; the forward-only span above is the second guard, not the only one.
  contains "$body" "§3.5's round protocol, step 3, and nothing here restates it"
  # and rule 1's overrides are not silently dropped from the summary, which is
  # what made an earlier draft's paraphrase say the opposite of §3.5
  contains "$body" "unless a human, or the story's own acceptance criteria, asked for that surface on purpose"
}

@test "#1496 neither doc site actually restates the rule it disclaims" {
  # The uniqueness pins are SKILL-scoped and the roster tripwire counts FILES,
  # so without this a verbatim copy of the four-item list could be pasted into
  # either doc — disclaimer intact — with the whole suite green. That is the
  # five-copies-of-one-list hazard this file exists to make unlandable.
  # Assign, never `if [ "$(_hits …)" -ne 0 ]`: a command substitution inside a
  # condition swallows the helper's typed 2 AND `[`'s own "integer expression
  # expected", so a dead pin would read as a clean bill of health.
  local f needle n
  for f in "$EXPLAIN" "$ARCH"; do
    for needle in "${RULE_NEEDLES[@]}"; do
      n="$(_hits "$f" "$needle")" || return 1
      if [ "$n" -ne 0 ]; then
        printf 'the rule is restated in %s: %s\n' "$f" "$needle" >&2
        return 1
      fi
    done
    # the trigger condition is one normative site too
    n="$(_hits "$f" 'incomplete_propagation + under_assertion >= new_defect')" || return 1
    if [ "$n" -ne 0 ]; then
      printf 'the trigger condition is restated in %s\n' "$f" >&2
      return 1
    fi
  done
}

@test "#1496 ARCHITECTURE points at §3.5 and disclaims enforcement" {
  local ln body
  ln="$(prose_gate_lines "$ARCH" 'The histogram also gates the FIX pass, skill-side (#1496).')"
  [ -n "$ln" ]
  body="$(prose_window "$ARCH" "$ln" 10)"
  contains "$body" 'A fix pass subtracts'
  # #1503 re-homed this citation from "SKILL.md §3.5's round protocol step 3" to
  # the file the rule now lives in. The claim — ARCHITECTURE points AT the rule
  # rather than restating it — is unchanged.
  contains "$body" "development/skills/resolve-issue/reference/review-loop.md § The round protocol, step 3"
  # The load-bearing half: `class` is reporting-only, so the loop MEASURES
  # compliance and never enforces it. A doc that said otherwise would licence a
  # reader to stop applying the rule by hand.
  contains "$body" 'how compliance is measured, not enforced'
  contains "$body" 'nothing here restates the rule'
}

# --- roster tripwire --------------------------------------------------------

@test "#1496 exactly five tracked markdown sites name the rule" {
  # Derived, not transcribed. `docs/superpowers/` is vendored and restates
  # nothing of ours — the same exclusion the sibling sweeps use. SHIPPED
  # TEMPLATES are in scope: `approver-policy-core.md.tmpl` already restates
  # review-loop rules and talks about fix passes, so a copy landing there is
  # exactly the fourth site this tripwire exists to see.
  local hits n
  # Probe git first. `&&` binds looser than `|`, so a failed `git ls-files`
  # inside the pipeline would leave the status of `_roster_hits` (0 over empty
  # stdin) and the test would red as "found 0" — sending the reader to hunt a
  # deleted restatement that never happened.
  git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || {
    printf 'not a git worktree, cannot derive the roster: %s\n' "$REPO_ROOT" >&2
    return 1
  }
  # Capture the helper's OWN status. Piping it straight into `sort -u` would
  # hand the substitution sort's status (always 0), so a `return 2` mid-walk —
  # an unreadable path — would leave the hits it had already printed and the
  # count could still read 3. The tripwire would pass on a half-derived roster,
  # which is the fail-open direction it exists to close.
  local raw
  raw="$(_roster_hits "$REPO_ROOT" "$ROSTER_NEEDLE" \
    < <(cd "$REPO_ROOT" && git -c core.quotePath=false ls-files -z '*.md' '*.md.tmpl'))" \
    || return 1
  # `sort -u`: a conflicted index lists a path once per STAGE, which would
  # otherwise report 9 sites while nothing drifted.
  hits="$(printf '%s\n' "$raw" | sort -u)"
  n="$(printf '%s\n' "$hits" | grep -c . || true)"
  case "$n" in ''|*[!0-9]*)
    printf 'roster tripwire: grep produced no count\n' >&2; return 1 ;;
  esac
  if [ "$n" -ne 5 ]; then
    printf 'expected 5 markdown sites naming the rule, found %s:\n%s\n' "$n" "$hits" >&2
    return 1
  fi
  # …and they are the roster the story named, so a swap reds here too. -F
  # because an unanchored `.` in a path is a regex wildcard.
  # #1503 moved the review-loop procedure into reference/*.md, so the roster
  # names those files where the text now lives — the same sites, re-homed. The
  # conductor keeps the exit-code table and a pointer, neither of which states
  # the rule, so SKILL.md is legitimately no longer on it.
  printf '%s\n' "$hits" | grep -qxF 'development/skills/resolve-issue/reference/review-loop.md'
  printf '%s\n' "$hits" | grep -qxF 'development/skills/resolve-issue/reference/promotion.md'
  printf '%s\n' "$hits" | grep -qxF 'development/skills/resolve-issue/reference/interactive.md'
  printf '%s\n' "$hits" | grep -qxF 'docs/explanation/review-loop.md'
  printf '%s\n' "$hits" | grep -qxF 'ARCHITECTURE.md'
}

# --- non-vacuity ------------------------------------------------------------
#
# Each control mutates a REAL site copied into $BATS_TEST_TMPDIR and shows the
# corresponding assertion reds. Fixtures rather than the repo, so a control can
# never leave a decoy behind for the tripwire above to measure.

@test "#1496 non-vacuity: a SECOND copy of the list reds the single-occurrence pin" {
  # AC4, and the exact defect this file exists to catch — a fix pass that
  # "fixes" a stale restatement by pasting a corrected copy beside the original.
  local F="$BATS_TEST_TMPDIR/skill-doubled.md" needle n
  cat "$SKILL" "$SKILL" > "$F"
  for needle in "${RULE_NEEDLES[@]}"; do
    n="$(_hits "$F" "$needle")"
    [ "$n" -eq 2 ]
  done
}

@test "#1496 non-vacuity: one duplicated RULE, without its banner, still reds" {
  # A banner count alone would pass here — which is precisely why the pin is
  # per rule rather than per heading.
  local F="$BATS_TEST_TMPDIR/skill-one-rule-copied.md" n
  cp "$SKILL" "$F"
  {
    printf '\n2. **A stale restatement at more than two sites is fixed by removal\n'
    printf '   plus a pointer, never by correcting the copy in place.**\n'
  } >> "$F"
  n="$(_hits "$F" 'A stale restatement at more than two sites is fixed by removal')"
  [ "$n" -eq 2 ]
  n="$(_hits "$F" "$RULE_HEADING")"
  [ "$n" -eq 1 ]
}

@test "#1496 non-vacuity: a consuming site that loses its pointer reds the count" {
  local F="$BATS_TEST_TMPDIR/skill-pointer-lost.md" n
  # drop the FIRST pointer line only, leaving the other site intact
  awk 'BEGIN{dropped=0}
       dropped==0 && index($0, "A fix pass subtracts* (§3.5") > 0 { dropped=1; next }
       { print }' "$SKILL" > "$F"
  n="$(_hits "$F" "$POINTER")"
  [ "$n" -eq 1 ]
}

@test "#1496 non-vacuity: a FIFTH numbered rule reds the closure pin" {
  local F="$BATS_TEST_TMPDIR/skill-five-rules.md" ln n
  # insert the fifth item right after rule 4's last line, so it lands inside
  # the banner window the closure pin counts over
  awk '{ print }
       /never a new helper, fixture family or counter/ {
         print "   5. A finding you disagree with is dropped. Not a rule." }' \
    "$SKILL" > "$F"
  ln="$(prose_gate_lines "$F" "$RULE_HEADING")"
  [ -n "$ln" ]
  n="$(sed -n "${ln},$((ln + 70))p" "$F" | grep -cE '^[[:space:]]*[0-9]+\.[[:space:]]' || true)"
  [ "$n" -eq 5 ]
}

@test "#1496 non-vacuity: the four-item list pasted into a DOC reds the doc pin" {
  local F="$BATS_TEST_TMPDIR/explain-restated.md" needle hit=0
  cp "$EXPLAIN" "$F"
  {
    printf '\n1. **New behaviour is parked, not applied.**\n'
    printf '2. **A stale restatement at more than two sites is fixed by removal plus a\n'
    printf '   pointer.**\n'
  } >> "$F"
  local n
  for needle in "${RULE_NEEDLES[@]}"; do
    n="$(_hits "$F" "$needle")" || return 1
    if [ "$n" -ne 0 ]; then hit=$((hit + 1)); fi
  done
  [ "$hit" -eq 2 ]
}

@test "#1496 non-vacuity: a doc site that loses its §3.5 pointer reds" {
  local F="$BATS_TEST_TMPDIR/explain-no-pointer.md" ln body
  sed "s/§3.5's round protocol, step 3/elsewhere/" "$EXPLAIN" > "$F"
  ln="$(prose_gate_lines "$F" 'A fix pass subtracts.')"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 14)"
  lacks "$body" "§3.5's round protocol, step 3"
}

@test "#1496 non-vacuity: an ARCHITECTURE site that claims ENFORCEMENT reds" {
  local F="$BATS_TEST_TMPDIR/arch-enforced.md" ln body
  sed 's/how compliance is measured, not enforced/how the loop enforces the rule/' \
    "$ARCH" > "$F"
  ln="$(prose_gate_lines "$F" 'The histogram also gates the FIX pass, skill-side (#1496).')"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 10)"
  lacks "$body" 'how compliance is measured, not enforced'
}

@test "#1496 non-vacuity: the roster tripwire counts a sixth site" {
  # Drives the SAME derivation over a synthetic roster, so the count really is
  # what the tripwire reads — not a restatement of the number 3. The fourth
  # site spells the rule with the emphasis INSIDE the phrase and the fifth is a
  # shipped TEMPLATE: both were invisible to the raw-bytes, `*.md`-only
  # derivation this control now pins against.
  local D="$BATS_TEST_TMPDIR/roster" n
  mkdir -p "$D/docs/superpowers"
  printf 'A fix pass subtracts\n' > "$D/one.md"
  printf 'A fix pass subtracts\n' > "$D/two.md"
  printf 'A fix pass subtracts\n' > "$D/three.md"
  printf 'A **fix pass subtracts**, it never adds.\n' > "$D/four.md"
  printf '# A fix pass subtracts\n' > "$D/five.md.tmpl"
  # …and the sixth names it MID-SENTENCE, lowercase article: the third shape
  # the round-1 finding named, and the one -i exists for
  printf 'the loop assumes a fix pass subtracts here\n' > "$D/six.md"
  # …and the seventh WRAPS the phrase across two lines, which a per-line
  # matcher cannot see at all
  printf 'the budget goes on itself, which is why a fix pass\nsubtracts rather than adds\n' \
    > "$D/seven.md"
  # the vendored tree is excluded even when it names the rule
  printf 'A fix pass subtracts\n' > "$D/docs/superpowers/vendored.md"
  # the helper's status is read here too — `| grep -c . || true` masked it
  # twice, so an abort mid-walk could still count 5 and certify a derivation
  # that never ran to completion
  local raw
  raw="$(_roster_hits "$D" "$ROSTER_NEEDLE" \
    < <(printf '%s\0' one.md two.md three.md four.md five.md.tmpl six.md \
          seven.md docs/superpowers/vendored.md))" || return 1
  n="$(printf '%s\n' "$raw" | grep -c . || true)"
  case "$n" in ''|*[!0-9]*)
    printf 'roster control: grep produced no count\n' >&2; return 1 ;;
  esac
  if [ "$n" -ne 7 ]; then
    printf 'expected 7 synthetic roster hits, found %s\n' "$n" >&2
    return 1
  fi
}
