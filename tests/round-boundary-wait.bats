#!/usr/bin/env bats
#
# #1513: at a round boundary the driver WAITS by ending its turn — it never
# busy-polls for the reviewer panel or the background gate.
#
# WHY THIS FILE EXISTS. The rule's whole content is prose. Nothing in
# `resolve-story-loop.zsh` can see a driving session's turns, and a harness-side
# refusal (a hook that blocks `date +%T`) is explicitly out of scope on the
# story. So the only thing that can catch the rule drifting — or being lost to a
# reflow of the boundary it lives in — is a sweep.
#
# The defect it pins is measured, not theoretical: on session `eb1a0e78`
# (`/development:resolve-issue 1497`) 366 of 1 159 assistant turns were
# `Waiting.` + `Bash: date +%T`, burning 235M of 658M input tokens before the
# run hit the weekly limit mid-round. The session before it, driving the same
# loop without the new boundary prose, polled zero times — so what changed the
# behaviour was the TEXT, which is precisely what a needle sweep can hold.
#
# SHAPE, and why each half earns its place:
#
#   * the NORMATIVE half asserts one banner, exactly once, and that the
#     paragraph under it still carries all three of its parts — end-the-turn,
#     the four banned heartbeats, and the single-bounded-call exception. Pinned
#     as clauses rather than as a heading, because a heading survives having its
#     paragraph gutted;
#   * the POINTER half asserts the two consuming sites carry a pointer and no
#     restatement. Counted, so a pointer that grows back into a copy of the rule
#     reds here — the shape #1496's rule 2 bans, and the shape a fix pass
#     produces;
#   * the DOC half pins `docs/explanation/review-loop.md` BY CONTENT: that it
#     names the rule, and that it points at §3.5 rather than restating it;
#   * a ROSTER TRIPWIRE over `git ls-files '*.md' '*.md.tmpl'`, so a third site
#     naming the rule reds rather than passing in silence. Derived, never
#     transcribed (MAINTAINING.md, *Derive the roster, never transcribe it*);
#   * NON-VACUITY controls that mutate a real site copied into a fixture, one
#     per gap kind the sweep can report.
#
# Needles are normalised through `load prose-lockstep` (#1432) — the shared
# derivation, so emphasis, code ticks and reflows cannot silently retire a pin.
# Every gate needle fits on ONE source line, which `prose_gate_lines` requires;
# the wrap-tolerant clause tests run over `prose_window`, which collapses
# whitespace.
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

  # The banner of the one normative statement. It carries the issue number, so
  # it can never collide with a pointer, which names the paragraph instead.
  BANNER='How to wait — end the turn (#1513).'
  # What a POINTER looks like: the rule's name plus where it lives, and no rule.
  # Direction-neutral ("this section") on purpose — the paragraph sits between
  # its two consumers, so "above"/"below" would make the two pointers differ and
  # the count below impossible to write.
  POINTER='How to wait (this section) governs the wait'
  # The bare phrase, for the roster tripwire and the SKILL-wide count.
  # Deliberately WITHOUT the issue number, so the tripwire sees a new site that
  # names the rule in prose as readily as one that cites it.
  ROSTER_NEEDLE='How to wait'

  # What a RESTATEMENT looks like — one needle per substantive clause of the
  # paragraph, since a copy built only from the unguarded ones would pass.
  # Wrap-tolerant, so they are only ever used against `prose_window`.
  #
  # NONE of them starts with the pronoun the source happens to use: `lacks`
  # matches literally and `prose-lockstep` deliberately does not fold case, so a
  # needle anchored on a mid-sentence `it` misses the very shape a restatement
  # takes — a SENTENCE, which begins `It does not run …`.
  RESTATEMENT_NEEDLES=(
    'does not run date, sleep, echo, git status or any other heartbeat'
    'one bounded blocking call'
    'does not schedule short wake-ups to poll work the harness already tracks'
    'there is nothing left for this turn to do, so end it'
    'arrives as a harness notification that re-invokes you'
    'The gate is not one of these'
    'for a signal the harness does not deliver'
    'Monitor, with a timeout generous enough for the wait'
    'One call, never one probe per turn'
    'signal-never-arrived arm instead of blocking again'
  )
}

# Occurrences of the literal $2 in $1's WHOLE normalised body, as a COUNT.
#
# Counted over `prose_body`, which collapses whitespace — NOT over
# `prose_gate_lines`, which is per line. That distinction is the difference
# between a tripwire and a decoration: a mention that happens to wrap between
# `How to` and `wait` is invisible to a per-line matcher, so a fourth naming
# site could land while the "exactly three" pin below still counted three. For a
# COUNT the fail-open direction is under-counting, and every count in this file
# exists to catch an occurrence that should not be there. `prose_gate_lines`
# stays in use for LOCATING windows, where a wrap fails closed instead.
#
# `-i` for the same reason `_roster_hits` uses it: a site may name the rule
# mid-sentence, where the article is lowercase. Without the fold this counting
# half declares such a mention invisible while the roster half declares it a
# site — so a fourth naming site spelled `… how to wait …` would leave the
# "exactly three" tripwire reading three. Under-counting is the fail-open
# direction for every pin here, since each exists to catch an occurrence that
# should not be there.
_hits() {
  local body out rc=0
  body="$(prose_body "$1")" || return 2
  # Only grep's status 1 is a genuine zero. `|| true` would absorb a 2 (an I/O
  # or resource error on the collapsed body) as a clean count of 0 — fail-OPEN
  # for exactly the pins that read 0 as clean.
  out="$(printf '%s\n' "$body" | grep -oiF -e "$2")" || rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" | grep -c . ;;
    1) printf '0\n' ;;
    *) printf '_hits: grep failed (%s)\n' "$rc" >&2; return 2 ;;
  esac
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
_roster_hits() {
  local root="$1" needle="$2" f rc
  while IFS= read -r -d '' f; do
    case "$f" in docs/superpowers/*) continue ;; esac
    # -r as well as -f: `grep` never opens the file here — `sed` does, and
    # `grep` reads a pipe — and bats runs no `pipefail`, so an unreadable file
    # would leave `grep` on an empty stream returning 1, i.e. folded into "does
    # not name the rule".
    if [ ! -f "$root/$f" ] || [ ! -r "$root/$f" ]; then
      printf 'roster: listed path is not a readable file: %s\n' "$f" >&2
      return 2
    fi
    rc=0
    # -a so a stray NUL cannot turn a match into "Binary file … matches";
    # -i because a site may name the rule mid-sentence, where the article is
    # lowercase — the shape that would otherwise be a third site in silence.
    # `tr -s '[:space:]' ' '` because this asks a FILE-level question and needs
    # no line numbers: without it a mention wrapped mid-phrase across two lines
    # drops out of the roster silently.
    sed 's/^[[:space:]]*#[[:space:]]\{0,1\}//' "$root/$f" | tr -d '*`' \
      | tr -s '[:space:]' ' ' | grep -qaiF -e "$needle" || rc=$?
    case "$rc" in
      0) printf '%s\n' "$f" ;;
      1) ;;
      *) printf 'roster: grep failed (%s) on %s\n' "$rc" "$f" >&2; return 2 ;;
    esac
  done
}

# --- AC1: the normative statement, stated exactly once ----------------------

@test "#1513 AC1 the How to wait paragraph carries its banner, exactly once" {
  # The single-occurrence half of AC1. A second copy is the defect a fix pass
  # produces when it "corrects" a stale restatement by pasting a fixed copy
  # beside the original, so the count is the pin, not mere presence.
  local n
  n="$(_hits "$SKILL" "$BANNER")" || return 1
  case "$n" in ''|*[!0-9]*)
    printf 'count is not a number: %s\n' "$n" >&2; return 1 ;;
  esac
  if [ "$n" -ne 1 ]; then
    printf 'expected exactly 1 occurrence of the banner, found %s\n' "$n" >&2
    return 1
  fi
}

@test "#1513 AC1 the paragraph lives INSIDE the round protocol, between its two pointers" {
  # AC1 says "in 3.5", and both pointers say "(this section)" — a claim that is
  # true only while the paragraph sits between them. Since #1503 the section
  # itself lives in reference/review-loop.md, so the bound is that file's
  # `## The round protocol` heading rather than §3.5's own; the conductor keeps
  # only the invocation contract and a pointer, and the corpus would let the
  # paragraph drift between the two files without reddening anything. Nothing else here asserts
  # POSITION: every locator re-finds the banner wherever it landed, so the whole
  # paragraph could be cut out of 3.5 and pasted under a later heading with every
  # other pin still green — both pointers then aiming at a section that does not
  # hold the rule, and the explanation page's pointer dangling.
  #
  # Needles carry no leading marker: prose_gate_lines strips one comment marker,
  # so a needle spelled with the heading's hashes could never match.
  local sec next banner ptr first last _v
  sec="$(prose_gate_lines "$PROTO" 'The round protocol')"
  # The section runs to the end of the reference file, so the upper bound is one
  # past its last line — derived, never a transcribed number.
  next="$(( $(grep -c '' "$PROTO") + 1 ))"
  banner="$(prose_gate_lines "$PROTO" "$BANNER")"
  # One assertion per line, never an `&&` chain: bash's errexit exempts every
  # command in an AND list but the last, so a chained guard whose FIRST operand
  # fails merely returns 1 and the body runs on. The comparisons below then get
  # an empty operand, error with status 2 inside an errexit-exempt `if`
  # condition, and the failure branch is never reached — the test reports ok
  # having asserted nothing. `find-inert-bracket-assertions.zsh` records this
  # shape as caught by NEITHER of its rules (#1067), so it would ship green.
  #
  # The numeric guard earns its place separately: `prose_gate_lines` can return
  # SEVERAL lines, and a two-line locator errors into the same false pass — the
  # state a duplicated banner produces, which is what this pin exists to catch.
  for _v in "$sec" "$next" "$banner"; do
    case "$_v" in ''|*[!0-9]*)
      printf 'locator missing or ambiguous: %s\n' "$_v" >&2; return 1 ;;
    esac
  done
  if [ "$banner" -le "$sec" ] || [ "$banner" -ge "$next" ]; then
    printf 'the paragraph is at line %s, outside the round protocol (%s..%s)\n' \
      "$banner" "$sec" "$next" >&2
    return 1
  fi
  # …and BETWEEN the two pointers, which is the precise claim "(this section)"
  # makes: a paragraph that drifted above the gate-launch step, or below the
  # panel step, would still be inside 3.5 and still read as pointed-at.
  ptr="$(prose_gate_lines "$PROTO" "$POINTER")"
  first="$(printf '%s\n' "$ptr" | head -1)"
  last="$(printf '%s\n' "$ptr" | tail -1)"
  for _v in "$first" "$last"; do
    case "$_v" in ''|*[!0-9]*)
      printf 'pointer locator missing or ambiguous: %s\n' "$_v" >&2; return 1 ;;
    esac
  done
  if [ "$banner" -le "$first" ] || [ "$banner" -ge "$last" ]; then
    printf 'the paragraph is at line %s, not between its pointers (%s, %s)\n' \
      "$banner" "$first" "$last" >&2
    return 1
  fi
}

@test "#1513 AC1 the paragraph states END THE TURN, not merely that waiting is bad" {
  # The operative instruction. Without it the paragraph can describe the
  # problem at length and never say what to do, which is how the #1497 prose
  # licensed the poll it was meant to prevent.
  local ln body
  ln="$(prose_gate_lines "$SKILL" "$BANNER")"
  [ -n "$ln" ]
  # FORWARD-ONLY and paragraph-tight — [banner, banner+18], which is exactly the
  # paragraph. A symmetric span reaches twenty lines back into the attestation
  # paragraph and twenty forward into the panel step, so every clause needle
  # would be satisfiable by prose that is not the rule: move the exception
  # sentence up into the attestation paragraph and these pins stay green while
  # AC1 is false. The AC2 and AC4 pins are forward-only for the same reason.
  body="$(prose_window "$SKILL" "$((ln + 9))" 9)"
  contains "$body" 'there is nothing left for this turn to do, so end it'
  # …and WHY ending is safe, which is the fact a driver has to believe before
  # it will stop polling: the notifications bring it back.
  contains "$body" 'arrives as a harness notification that re-invokes you'
  contains "$body" 'the boundary resumes when the last one lands'
  # …and that the claim stops at the reviewers. The gate is launched out of
  # band, so nothing re-invokes the session when it finishes: a paragraph that
  # swept it into the same sentence would send a driver back to ending its turn
  # on a notification that never comes, and the round would never consolidate.
  contains "$body" 'The gate is not one of these'
  contains "$body" 'its completion is the file case below'
}

@test "#1513 AC1 the paragraph bans the four heartbeats BY NAME" {
  # Named, never "no-op commands": the #1497 session ran `date +%T` while
  # satisfying a rule that banned polling in the abstract. A generic ban is
  # what a driver argues its way past; a list of four is not.
  local ln body
  ln="$(prose_gate_lines "$SKILL" "$BANNER")"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$((ln + 9))" 9)"
  contains "$body" 'it does not run date, sleep, echo, git status or any other heartbeat'
  # the scheduled-wakeup half — a different mechanism, and the one the harness
  # itself calls out; without it the ban reads as being about shell commands
  contains "$body" 'does not schedule short wake-ups to poll work the harness already tracks'
}

@test "#1513 AC1 the paragraph states the single-bounded-call EXCEPTION" {
  # The exception is what keeps the rule usable: a driver that may never block
  # in-turn has no way to collect the gate's marker, and would go back to
  # per-turn probes. Pinned with its scope (a signal the harness does not
  # deliver), its bound (one call), and its single sanctioned form.
  local ln body
  ln="$(prose_gate_lines "$SKILL" "$BANNER")"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$((ln + 9))" 9)"
  contains "$body" 'for a signal the harness does not deliver'
  contains "$body" 'it is one bounded blocking call'
  # ONE form, carrying its own bound. Offering a second, unbounded shell form
  # beside it is what two earlier drafts got wrong — first with a hand-rolled
  # deadline the harness would cut short, then with a duration condition the
  # driver cannot evaluate for the one wait the exception actually names.
  contains "$body" 'Monitor, with a timeout generous enough for the wait'
  # …and how the driver learns which way the call ended. The loop's exit status
  # is 0 whether the signal arrived or not, so a rule that says what to do on
  # expiry without saying how to detect it sends a healthy round to report-and-stop.
  contains "$body" 'A call that returns without its signal is not a retry'
  contains "$body" "judge by re-testing the condition, never by the call's exit status"
  # the bound, spelled as the thing it excludes — the exception is worthless if
  # "one call" can be read as "one call per turn"
  contains "$body" 'One call, never one probe per turn.'
}

# --- AC2: the two consuming sites point, and do not restate -----------------

@test "#1513 AC2 exactly two SKILL.md sites carry the pointer" {
  # The panel-dispatch step and the gate-launch step. A third would mean a
  # consumer was added without being counted; a single one would mean the other
  # lost its pointer to a rewrite.
  local n
  n="$(_hits "$SKILL" "$POINTER")" || return 1
  case "$n" in ''|*[!0-9]*)
    printf 'count is not a number: %s\n' "$n" >&2; return 1 ;;
  esac
  if [ "$n" -ne 2 ]; then
    printf 'expected exactly 2 pointer sites, found %s\n' "$n" >&2
    return 1
  fi
}

@test "#1513 AC2 the phrase appears exactly three times in SKILL.md" {
  # The banner plus the two pointers, and nothing else. This is the tripwire
  # the two counts above cannot be: a THIRD mention that is neither — a
  # paraphrase in some other step, or a restatement that dropped the pointer
  # wording — passes both of them and reds only here.
  local n
  n="$(_hits "$SKILL" "$ROSTER_NEEDLE")" || return 1
  case "$n" in ''|*[!0-9]*)
    printf 'count is not a number: %s\n' "$n" >&2; return 1 ;;
  esac
  if [ "$n" -ne 3 ]; then
    printf 'expected 3 mentions of "%s" in SKILL.md (banner + 2 pointers), found %s\n' \
      "$ROSTER_NEEDLE" "$n" >&2
    return 1
  fi
}

@test "#1513 AC2 the panel-dispatch step points at the rule instead of restating it" {
  # Anchored on the step's own heading text, per the #1189 convention — never
  # on a step ordinal, which this epic renumbers.
  local ln body needle
  ln="$(prose_gate_lines "$SKILL" 'Review panel, in-session. Get the dispatch plan (review-dispatch.zsh')"
  [ -n "$ln" ]
  # FORWARD-ONLY, and it is load-bearing: the normative paragraph sits a few
  # lines ABOVE this step, so a symmetric window would satisfy the `contains`
  # from the rule itself and trip the `lacks` on it — a pin that passes whether
  # or not this step points at anything. Centring at `ln + span` makes the
  # window exactly [ln, ln + 2*span].
  body="$(prose_window "$SKILL" "$((ln + 6))" 6)"
  contains "$body" "$POINTER"
  contains "$body" 'it is not restated here'
  for needle in "${RESTATEMENT_NEEDLES[@]}"; do
    lacks "$body" "$needle"
  done
}

@test "#1513 AC2 the gate-launch step points at the rule instead of restating it" {
  # Anchored on "Start the gate out of band" — the landed heading of #1497's
  # gate-launch step. Its body deliberately gives no `run-gate.zsh` invocation,
  # so the invocation could never have been the anchor.
  local ln body needle
  ln="$(prose_gate_lines "$SKILL" 'Start the gate out of band, so that it runs without blocking the panel —')"
  [ -n "$ln" ]
  # Forward-only (see the panel pin), and wide: the pointer sits at the far end
  # of a step whose body runs four properties deep, so the window is
  # [ln, ln + 56] and a tighter span would silently stop pinning it.
  body="$(prose_window "$SKILL" "$((ln + 28))" 28)"
  contains "$body" "$POINTER"
  contains "$body" 'it is not restated here'
  # The TRIGGER, which is the half a pointer alone gets wrong here: this step
  # only launches the gate, and step 3 has not dispatched the panel yet. A
  # pointer reading "once it is launched" sends the driver to end its turn
  # between the two steps, with a detached suite running and no agent spawned —
  # nothing then re-invokes it and the round never reaches the observe step.
  contains "$body" 'The wait itself begins after step 3, not here'
  for needle in "${RESTATEMENT_NEEDLES[@]}"; do
    lacks "$body" "$needle"
  done
}

# --- AC4: the documentation site, pinned by content -------------------------

@test "#1513 AC4 the review-loop explanation names the rule and points at §3.5" {
  local ln body needle
  ln="$(prose_gate_lines "$EXPLAIN" 'The wait between the two is a turn boundary, not a poll.')"
  [ -n "$ln" ]
  # FORWARD-ONLY, for the reason the AC2 pins give. What makes the needle below
  # safe is stated once, where the needle is; this span is the second guard.
  body="$(prose_window "$EXPLAIN" "$((ln + 6))" 6)"
  # what the rule IS — without this the page names it and points at §3.5 while
  # saying nothing about what it does
  contains "$body" 'the driver ends its turn'
  contains "$body" 'comes back as a harness notification that re-invokes it'
  # the page must not sweep the gate into that clause either — the same defect
  # as the SKILL pin above, in the voice a reader meets first
  contains "$body" 'The background suite is the one thing nothing announces'
  # …and the half that carries the operative instruction. Without it the page
  # can keep the "nothing announces it" clause and still tell a reader to watch
  # the suite, contradicting the rule it claims to defer to.
  contains "$body" 'it is collected once, in a single blocking call, rather than watched'
  # …and why it is a cost rule, which is the half that makes it non-negotiable
  contains "$body" 'a third of its turns and a third of its input tokens'
  # ONE needle, carrying the pointer and the disclaimer together. It is the
  # POINTER half that makes it unique, not the pronoun: the fix-pass paragraph
  # ends in the same singular "…restates it.", so a bare 'nothing here restates
  # it' would be satisfied by that one the moment this window widened.
  contains "$body" "§3.5's How to wait, and nothing here restates it"
  # …and it really does not restate it
  for needle in "${RESTATEMENT_NEEDLES[@]}"; do
    lacks "$body" "$needle"
  done
}

@test "#1513 AC4 the explanation names the rule exactly once" {
  local n
  n="$(_hits "$EXPLAIN" "$ROSTER_NEEDLE")" || return 1
  case "$n" in ''|*[!0-9]*)
    printf 'count is not a number: %s\n' "$n" >&2; return 1 ;;
  esac
  if [ "$n" -ne 1 ]; then
    printf 'expected exactly 1 mention in the explanation, found %s\n' "$n" >&2
    return 1
  fi
}

# --- roster tripwire --------------------------------------------------------

@test "#1513 exactly two tracked markdown sites name the rule" {
  # Derived, not transcribed. `docs/superpowers/` is vendored and restates
  # nothing of ours — the same exclusion the sibling sweeps use. SHIPPED
  # TEMPLATES are in scope: `approver-policy-core.md.tmpl` already restates
  # review-loop rules, so a copy landing there is exactly the third site this
  # tripwire exists to see.
  local hits n raw
  # Probe git first. `&&` binds looser than `|`, so a failed `git ls-files`
  # inside the pipeline would leave the status of `_roster_hits` (0 over empty
  # stdin) and the test would red as "found 0" — sending the reader to hunt a
  # deleted mention that never happened.
  git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || {
    printf 'not a git worktree, cannot derive the roster: %s\n' "$REPO_ROOT" >&2
    return 1
  }
  # Capture the helper's OWN status. Piping it straight into `sort -u` would
  # hand the substitution sort's status (always 0), so a `return 2` mid-walk —
  # an unreadable path — would leave the hits it had already printed and the
  # count could still read 2.
  raw="$(_roster_hits "$REPO_ROOT" "$ROSTER_NEEDLE" \
    < <(cd "$REPO_ROOT" && git -c core.quotePath=false ls-files -z '*.md' '*.md.tmpl'))" \
    || return 1
  # `sort -u`: a conflicted index lists a path once per STAGE, which would
  # otherwise report more sites while nothing drifted.
  hits="$(printf '%s\n' "$raw" | sort -u)"
  n="$(printf '%s\n' "$hits" | grep -c . || true)"
  case "$n" in ''|*[!0-9]*)
    printf 'roster tripwire: grep produced no count\n' >&2; return 1 ;;
  esac
  if [ "$n" -ne 2 ]; then
    printf 'expected 2 markdown sites naming the rule, found %s:\n%s\n' "$n" "$hits" >&2
    return 1
  fi
  # …and they are the roster the story named, so a swap reds here too. -F
  # because an unanchored `.` in a path is a regex wildcard.
  # #1503 moved the review-loop procedure into reference/*.md, so the roster
  # names those files where the text now lives — the same sites, re-homed.
  printf '%s\n' "$hits" | grep -qxF 'development/skills/resolve-issue/reference/review-loop.md'
  printf '%s\n' "$hits" | grep -qxF 'docs/explanation/review-loop.md'
}

# --- non-vacuity ------------------------------------------------------------
#
# Each control mutates a REAL site copied into $BATS_TEST_TMPDIR and shows the
# corresponding assertion reds. Fixtures rather than the repo, so a control can
# never leave a decoy behind for the tripwire above to measure.

@test "#1513 AC3 non-vacuity: a SECOND How to wait paragraph reds the single-occurrence pin" {
  # AC3, and the exact defect this file exists to catch. The fixture plants the
  # paragraph WITHOUT its surrounding step, which is the shape a fix pass
  # produces: it copies the rule it is obeying, not the section around it.
  local F="$BATS_TEST_TMPDIR/skill-doubled.md" n
  cp "$SKILL" "$F"
  {
    printf '\n**How to wait — end the turn (#1513).** Once the boundary has dispatched\n'
    printf 'there is nothing left for this turn to do, so end it.\n'
  } >> "$F"
  n="$(_hits "$F" "$BANNER")" || return 1
  case "$n" in ''|*[!0-9]*)
    printf 'count is not a number: %s\n' "$n" >&2; return 1 ;;
  esac
  if [ "$n" -ne 2 ]; then
    printf 'the doubled fixture should show 2 banners, showed %s\n' "$n" >&2
    return 1
  fi
  # …and the bare-phrase tripwire sees it too, so a planted copy that dropped
  # the issue number would still be caught
  n="$(_hits "$F" "$ROSTER_NEEDLE")" || return 1
  case "$n" in ''|*[!0-9]*)
    printf 'count is not a number: %s\n' "$n" >&2; return 1 ;;
  esac
  [ "$n" -eq 4 ]
  # …including one whose phrase WRAPS mid-source-line, the shape a per-line
  # count cannot see at all. This is the control for counting over the collapsed
  # body rather than line by line: without it, a fourth naming site could land
  # green simply by falling across a reflow.
  {
    printf '\nthe section headed **How to\n'
    printf 'wait** states the rule again here.\n'
  } >> "$F"
  n="$(_hits "$F" "$ROSTER_NEEDLE")" || return 1
  case "$n" in ''|*[!0-9]*)
    printf 'count is not a number: %s\n' "$n" >&2; return 1 ;;
  esac
  if [ "$n" -ne 5 ]; then
    printf 'a wrapped mention was not counted: expected 5, found %s\n' "$n" >&2
    return 1
  fi
}

@test "#1513 non-vacuity: a consuming site that loses its pointer reds the count" {
  local F="$BATS_TEST_TMPDIR/skill-pointer-lost.md" n
  # drop the FIRST pointer line only, leaving the other site intact
  awk 'BEGIN{dropped=0}
       dropped==0 && index($0, "**How to wait** (this section) governs the wait") > 0 { dropped=1; next }
       { print }' "$SKILL" > "$F"
  n="$(_hits "$F" "$POINTER")" || return 1
  case "$n" in ''|*[!0-9]*)
    printf 'count is not a number: %s\n' "$n" >&2; return 1 ;;
  esac
  [ "$n" -eq 1 ]
}

@test "#1513 non-vacuity: a pointer that grows back into a RESTATEMENT reds" {
  # The #1496 rule-2 shape: a pointer site that "helpfully" inlines the rule.
  # Without this control the pointer tests would pass on a site carrying both.
  #
  # The planted text is a SENTENCE — capitalised, as a restatement really is —
  # and the assertion is `${RESTATEMENT_NEEDLES[i]}` itself rather than a
  # hand-written copy. Both matter: a control that asserts its own spelling can
  # go green while the pin it claims to validate would not fire on the very
  # mutation just planted, which is how the first draft of this file shipped a
  # needle anchored on a lowercase mid-sentence pronoun.
  local F="$BATS_TEST_TMPDIR/skill-restated.md" ln body needle
  awk '{ print }
       index($0, "governs the wait — it is not restated here") > 0 && n == 0 {
         n = 1
         print "   It does not run date, sleep, echo, git status or any other heartbeat"
         print "   to hold itself open, and it does not schedule short wake-ups to poll"
         print "   work the harness already tracks. Once dispatched there is nothing left"
         print "   for this turn to do, so end it: every reviewer'"'"'s result arrives as a"
         print "   harness notification that re-invokes you. The gate is not one of these,"
         print "   so the wait for a signal the harness does not deliver is one bounded"
         print "   blocking call: Monitor, with a timeout generous enough for the wait."
         print "   One call, never one probe per turn — then take the boundary'"'"'s own"
         print "   signal-never-arrived arm instead of blocking again." }' \
    "$SKILL" > "$F"
  ln="$(prose_gate_lines "$F" 'Start the gate out of band, so that it runs without blocking the panel —')"
  [ -n "$ln" ]
  # the same forward-only window the real pin uses, or the control would be
  # measuring the normative paragraph rather than the mutation
  body="$(prose_window "$F" "$((ln + 28))" 28)"
  # `contains`, deliberately: this asserts the mutation is VISIBLE to the same
  # window the real pin runs `lacks` over — which is what makes that `lacks`
  # meaningful rather than vacuous.
  #
  # EVERY needle, over the array itself rather than hand-written copies. Both
  # halves earn their place: a needle exercised only by the three `lacks` loops
  # has never been shown capable of FIRING, so one that mis-transcribes the
  # source — a hyphen dropped, a word reflowed — sits in the array permanently
  # green and permanently dead; and a control asserting its own spelling can
  # pass while the pin it claims to validate would miss the very text just
  # planted.
  for needle in "${RESTATEMENT_NEEDLES[@]}"; do
    contains "$body" "$needle"
  done
}

@test "#1513 non-vacuity: a doc site that loses its §3.5 pointer reds" {
  local F="$BATS_TEST_TMPDIR/explain-no-pointer.md" ln body
  sed "s/§3.5's \*\*How to wait\*\*/elsewhere/" "$EXPLAIN" > "$F"
  ln="$(prose_gate_lines "$F" 'The wait between the two is a turn boundary, not a poll.')"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 12)"
  lacks "$body" "§3.5's How to wait"
}

@test "#1513 non-vacuity: the roster tripwire counts a third site" {
  # Drives the SAME derivation over a synthetic roster, so the count really is
  # what the tripwire reads — not a restatement of the number 2. The third site
  # spells the rule with emphasis INSIDE the phrase, the fourth is a shipped
  # TEMPLATE, the fifth names it mid-sentence and the sixth WRAPS it across two
  # lines: four shapes a raw-bytes, `*.md`-only, per-line derivation misses.
  local D="$BATS_TEST_TMPDIR/roster" n raw
  mkdir -p "$D/docs/superpowers"
  printf 'How to wait\n' > "$D/one.md"
  printf 'How to wait\n' > "$D/two.md"
  printf 'see **How to wait** for the rule\n' > "$D/three.md"
  printf '# How to wait\n' > "$D/four.md.tmpl"
  printf 'the boundary explains how to wait for both\n' > "$D/five.md"
  printf 'the section headed How to\nwait states the rule\n' > "$D/six.md"
  # the vendored tree is excluded even when it names the rule
  printf 'How to wait\n' > "$D/docs/superpowers/vendored.md"
  raw="$(_roster_hits "$D" "$ROSTER_NEEDLE" \
    < <(printf '%s\0' one.md two.md three.md four.md.tmpl five.md six.md \
          docs/superpowers/vendored.md))" || return 1
  n="$(printf '%s\n' "$raw" | grep -c . || true)"
  case "$n" in ''|*[!0-9]*)
    printf 'roster control: grep produced no count\n' >&2; return 1 ;;
  esac
  if [ "$n" -ne 6 ]; then
    printf 'expected 6 synthetic roster hits, found %s\n' "$n" >&2
    return 1
  fi
}
