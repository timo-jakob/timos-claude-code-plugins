#!/usr/bin/env bats
#
# #1498 AC18/AC19: the one-shot all-ambiguous auto-continue changes what a human
# is asked, so every site that DESCRIBES the ask has to change with it. Two of
# those sites made a claim this story falsifies outright — the SKILL's extension
# arm offered a plain grant precisely for the case that no longer reaches a
# human, and §3.5 said an escalating possible false trip can only ever appear on
# an escalating round — so this file is as much about ABSENCE as presence.
#
# A grep suite rather than a behavioural one, because the observable IS the
# prose: an instruction that offers an option for an unreachable state does not
# merely lag, it sends the model looking for a choice that is not there.
#
# Shape, and why. The NEGATIVE half sweeps the whole tree (`git ls-files`), not a
# list written here: a stale claim reintroduced in a file nobody thought of is
# exactly what a closed list cannot see, and this repo has already paid for that
# once. The POSITIVE half is a named roster — the sites AC 19 enumerates —
# carrying a count tripwire, so a roster that grows or shrinks reds here rather
# than passing in silence. The same construction as
# tests/residue-terminal-documented.bats, which this file follows deliberately.
#
# Deliberately NOT registered as a MAINTAINING.md restatement invariant: those
# pin literal WORDING across sites that must agree clause for clause. This pins
# that a FACT is present (or gone), and each site says it in its own voice.

bats_require_minimum_version 1.5.0
load assertions


setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/resolve-issue/scripts"
  # #1503 split this skill into a conductor plus reference/*.md. Every pin in
  # this file asks WHERE a sentence lives, so all of them read a single file and
  # none reads the corpus — hence no corpus build here.
  PROTO="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md"
  EXTENSION="$REPO_ROOT/development/skills/resolve-issue/reference/interactive.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  EXPL="$REPO_ROOT/docs/explanation/review-loop.md"
  # AC 19's site list, as paths. REAL paths, never the corpus: the per-site
  # diagnostics below name `$f`, and a $BATS_TEST_TMPDIR corpus path tells a
  # reader nothing about which site drifted.
  ROSTER=(
    "$PROTO"
    "$EXTENSION"
    "$ARCH"
    "$EXPL"
  )
}

# Every tracked markdown file AND every shipped markdown TEMPLATE, minus the
# vendored superpowers tree and the frozen design records under docs/superpowers/
# — dated snapshots, not live instruction. The same exclusion the sibling sweeps
# use.
all_markdown() {
  git -C "$REPO_ROOT" ls-files '*.md' '*.md.tmpl' | grep -v '^docs/superpowers/'
}

# flattened text of $1: every claim below wraps across lines, and a per-line grep
# would answer a question about line breaks rather than about the claim
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

# --- the NEGATIVE half: claims this story falsifies ---------------------------

@test "#1498 AC18 no site still offers a plain grant for the all-possible-false-trip case" {
  # The removed sentence told the model to add a **Grant +3 rounds** option when
  # the assessment reports every carried match as a possible false trip. That
  # state no longer reaches the extension on its first occurrence, so the option
  # would be offered for a state that cannot arrive — and on the SECOND
  # occurrence the blocker is stuck, which is exactly what the guidance-only
  # framing is for.
  local f hit=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if grep -qE 'assessment reports [*]{0,2}every[*]{0,2} carried match as a possible' \
         <<< "$(flat "$REPO_ROOT/$f")"; then hit="$hit $f"; fi
  done < <(all_markdown)
  [ -z "$hit" ] || { echo "stale plain-grant offer survives in:$hit"; return 1; }
}

@test "#1498 AC18 no site still claims a possible false trip can never appear on an AWAITING_FIX round" {
  # §3.5 used to say the escalating shape "can only appear on an escalating
  # round (an ESCALATE_NO_CONVERGENCE, never AWAITING_FIX)". After this story it
  # appears on AWAITING_FIX rounds by design, which is the one narration the
  # session reads before deciding what its fix pass owes the match.
  local f hit=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if grep -qE 'can only appear on an [*]{0,2}escalating[*]{0,2} round' \
         <<< "$(flat "$REPO_ROOT/$f")"; then hit="$hit $f"; fi
  done < <(all_markdown)
  [ -z "$hit" ] || { echo "stale never-on-AWAITING_FIX claim survives in:$hit"; return 1; }
}

@test "#1498 AC19 no user-facing page still promises the grant option on a not-converging exit" {
  local f hit=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if grep -qF 'not-converging exit where every carried blocker is flagged as a suspected false alarm' \
         <<< "$(flat "$REPO_ROOT/$f")"; then hit="$hit $f"; fi
  done < <(all_markdown)
  [ -z "$hit" ] || { echo "stale not-converging grant offer survives in:$hit"; return 1; }
}

@test "#1498 the three absence needles really catch their own stale claims" {
  # Non-vacuity: a needle nobody can trip passes forever. Each removed claim is
  # planted in a scratch file and each sweep is shown to find it there.
  local probe="$BATS_TEST_TMPDIR/probe.md"
  local -a claims=(
    'When the step-1 assessment reports **every** carried match as a possible
false trip (the blockers may be fresh, not stuck), also offer a plain
**Grant +3 rounds** option.'
    'a carried match with no shared prior title that is still ambiguous
can only appear on an *escalating* round (an ESCALATE_NO_CONVERGENCE,
never AWAITING_FIX).'
    'Grant three more rounds (on budget exhausted — or on a
not-converging exit where every carried blocker is flagged as a suspected false alarm,
meaning the blockers may be fresh rather than stuck).'
  )
  local -a needles=(
    'assessment reports [*]{0,2}every[*]{0,2} carried match as a possible'
    'can only appear on an [*]{0,2}escalating[*]{0,2} round'
    'not-converging exit where every carried blocker is flagged as a suspected false alarm'
  )
  local i
  for i in 0 1 2; do
    printf '%s\n' "${claims[$i]}" > "$probe"
    grep -qE "${needles[$i]}" <<< "$(flat "$probe")" || {
      echo "needle $i does not catch the claim it exists to catch"; return 1; }
  done
  # ...and none of them fires on the REPLACEMENT prose, so they are needles for
  # the stale claim rather than for the topic
  local f
  for f in "${ROSTER[@]}"; do
    for i in 0 1 2; do
      if grep -qE "${needles[$i]}" <<< "$(flat "$f")"; then
        echo "needle $i fires on the current $f — it pins the topic, not the stale claim"
        return 1
      fi
    done
  done
}

# --- the POSITIVE half: what every site must now say ---------------------------

@test "#1498 AC18 the round protocol tells the fix pass what an ambiguous match owes it" {
  # #983's "the blocker is fresh, not stuck" is exactly what does NOT hold for an
  # ambiguous match, so the narration has to say what to do instead — otherwise
  # the round the auto-continue buys is spent patching around an incomplete fix.
  #
  # Read from $PROTO, not the corpus (#1503): the sentence has to be in the file
  # a session doing the fix pass has open, which is reference/review-loop.md.
  grep -qF "treat it on its own merits, and where the previous round's fix for the matched prior was incomplete, finish that rather than patch around it" \
    <<< "$(flat "$PROTO")" || {
    echo "the round protocol does not say what the fix pass owes an ambiguous match"; return 1; }
}

@test "#1498 AC18 the round protocol names the auto-continue as a narratable AWAITING_FIX shape" {
  # The line the loop actually renders, so the session can recognise it in
  # progress.md rather than inferring which of the three shapes it has.
  grep -qF 'possible false trip auto-continued (#1498)' <<< "$(flat "$PROTO")" || {
    echo "the round protocol does not name the rendered auto-continue line"; return 1; }
}

@test "#1498 AC18 the interactive extension explains why the exit a human sees differs" {
  # Split from the round-protocol test above (#1503): these needles live in
  # reference/interactive.md, and a session that reaches the extension loads THAT
  # file and nothing else. Asserting both halves against one flattened corpus
  # would let the extension arm migrate into review-loop.md — where the reader
  # never sees it — with the suite still green.
  local t; t="$(flat "$EXTENSION")"
  # A needle unique to THIS arm, not a substring of the rendered line: `#1498`
  # alone is implied by that line, so it would pass with the whole extension-arm
  # sentence deleted.
  grep -qF 'no longer reaches this extension the first time' <<< "$t" || {
    echo "the extension arm does not explain the #1498 exception"; return 1; }
  # ...and it QUALIFIES that exception. The needle above matched the unqualified
  # claim verbatim, so on its own it certifies nothing: an arm saying only "no
  # longer reaches this extension the first time" tells the model that arriving
  # here proves a continuation was spent, which is false on every refusal the
  # rung can take.
  grep -qF 'unless the rung refused it' <<< "$t" || {
    echo "the extension arm states the #1498 exception as absolute"; return 1; }
  grep -qF 'arriving here is not proof a continuation was spent' <<< "$t"
  # the four refusals are the load-bearing enumeration behind that qualifier
  grep -qE 'Critical among the matches.{0,120}ceiling.{0,120}unstamped changelist.{0,120}failed marker write' <<< "$t" || {
    echo "the extension arm does not name the rung's refusals"; return 1; }
}

@test "#1498 AC19 ARCHITECTURE.md states the ladder exception, the status key and the extension change" {
  local t; t="$(flat "$ARCH")"
  # The ladder sentence carries the exception, next to the rung it excepts. Two
  # short spans rather than one long one: `grep -E` caps a repetition count at
  # 255, so a single `.{0,400}` bridge is a runtime error rather than a stricter
  # test — and an anchored pair says the same thing without the cap.
  grep -qE 'ESCALATE_NO_CONVERGENCE.{0,200}save for one exception \(#1498\)' <<< "$t" || {
    echo "ARCHITECTURE.md's ladder sentence does not carry the #1498 exception"; return 1; }
  grep -qE 'possible-false-trip-continued.{0,60}auto-continues once' <<< "$t" || {
    echo "ARCHITECTURE.md does not say what the exception does"; return 1; }
  # ...and says residue still wins, which is the whole of the rung's placement
  grep -qF 'strictly **below** the residue rung' <<< "$t"
  # the status-JSON key list carries the new key, with its always-present reading
  grep -qE 'closing_sweep_granted, possible_false_trip_auto_continues' <<< "$t" || {
    echo "ARCHITECTURE.md's status-JSON key list omits the new key"; return 1; }
  grep -qE 'possible_false_trip_auto_continues.{0,120}always-present' <<< "$t"
  # the interactive-extension paragraph says the case no longer enters it first
  grep -qE 'no longer enters the extension on its [*]{0,2}first[*]{0,2} occurrence' <<< "$t" || {
    echo "ARCHITECTURE.md's interactive-extension paragraph is stale"; return 1; }
}

@test "#1498 AC19 the explanation page describes the free round and what bounds it" {
  local t; t="$(flat "$EXPL")"
  # both halves of the ending list and the extension section were touched, so
  # both are pinned — and the section that explains it must state its FOUR bounds
  grep -qF 'The free round on an all-ambiguous carry' <<< "$t" || {
    echo "docs/explanation/review-loop.md has no section on the new behaviour"; return 1; }
  # what it costs and what it does not — the distinction a reader would
  # otherwise take from the closing-sweep grant three paragraphs above, which
  # really does buy a round beyond the ceiling
  grep -qF 'It costs no grant, but it does cost a round' <<< "$t"
  grep -qF 'strictly below the ceiling' <<< "$t"
  grep -qF 'once per identity' <<< "$t"
  # the not-converging ending says the auto-continue is now upstream of it
  grep -qE 'only when the loop could not take the free round' <<< "$t" || {
    echo "the not-converging ending does not mention the free round"; return 1; }
}

@test "#1498 the always-present status key is stated identically by the code and the docs" {
  # One fact, two readers. The loop emits it unconditionally; ARCHITECTURE.md
  # promises a consumer never has to tell 0 from an older status file. A drift
  # here is exactly the kind that surfaces as a null-vs-zero bug months later.
  grep -qF 'possible_false_trip_auto_continues:$pftc' "$SCRIPTS/resolve-story-loop.zsh" || {
    echo "the loop does not emit the key unconditionally"; return 1; }
  grep -qF 'possible_false_trip_auto_continues' "$SCRIPTS/build-telemetry-record.zsh" || {
    echo "the telemetry payload does not carry the key"; return 1; }
  grep -qF 'possible_false_trip_auto_continues' "$SCRIPTS/build-escalation.zsh" || {
    echo "the escalation does not read the key"; return 1; }
}

@test "#1498 roster tripwire: exactly four markdown sites name the auto-continue" {
  # A derived sweep answers "do the sites agree?", never "did a site appear or
  # vanish?" — so the count is recorded here and a fourth (or second)
  # restatement reds until this file is updated in the same PR.
  # ROOT-ANCHORED on the way in, re-relativised on the way out: all_markdown
  # emits repo-relative paths, which a bare `xargs grep` would resolve against
  # the CALLER's cwd.
  local found
  found="$(all_markdown | sed "s#^#$REPO_ROOT/#" \
           | xargs grep -l 'possible_false_trip_auto_continues\|possible false trip auto-continued\|all-ambiguous' 2>/dev/null \
           | sed "s#^$REPO_ROOT/##" | sort)"
  # #1503 moved the review-loop procedure into reference/*.md, so the roster
  # names those files where the text now lives — the same sites, re-homed.
  [ "$found" = "ARCHITECTURE.md
development/skills/resolve-issue/reference/interactive.md
development/skills/resolve-issue/reference/review-loop.md
docs/explanation/review-loop.md" ] || {
    echo "roster drift — the sites naming the #1498 auto-continue are now:"
    printf '%s\n' "$found"
    return 1; }
}
