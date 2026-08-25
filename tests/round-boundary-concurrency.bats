#!/usr/bin/env bats
#
# #1497: the review loop's ROUND BOUNDARY runs the full-suite gate and the
# reviewer panel CONCURRENTLY over one minted tree.
#
# WHY THIS FILE EXISTS. The change is entirely an ordering the driving session
# performs: `resolve-story-loop.zsh` never starts the gate and never spawns the
# panel, so nothing in the state machine can enforce — or even observe — that
# the two overlapped. The story adds no flag and no script on purpose. So the
# only thing that can catch the cadence being lost, or drifting between the
# three artifacts that state it, is a sweep over the prose.
#
# The hazard is specific, and it is a REGRESSION to the serial shape: the
# sentence "after the gate is green, dispatch the panel" reads perfectly well,
# costs nothing to write, and silently restores the wait this story removed.
# The first non-vacuity control below plants exactly that wording.
#
# SHAPE, and why each half earns its place:
#
#   * the ORDERING half pins §3.5's seven-step boundary — mint, background gate,
#     panel, blocking wait, green-consolidate, red-restart, drifted-green — both
#     by CONTENT inside the window around its banner (so an unrelated paragraph
#     cannot satisfy a needle in a 5000-line SKILL.md, MAINTAINING.md's *Scope
#     the needle to the statement*) and by POSITION, asserting the seven gate
#     lines are strictly increasing. Presence alone would let items 3 and 4 be
#     swapped — the panel queued behind the gate again — with every `contains`
#     still matching;
#   * the RECONCILIATION half pins the two sentences ABOVE the banner that make
#     the boundary reachable at all: §3.5's "under way, not green" entry
#     condition, and the carve-out that exempts the gate from §3.5's own ban on
#     background tasks. Both sit outside the banner window, and without them the
#     block can stand intact while nothing ever enters it;
#   * the ATTESTATION-PAIR half pins the invariant sentence — including the
#     OUTSIDE-a-boundary exception, without which the rule licenses passing a
#     fresh mint as `--gate-attest` and skipping a gate that never ran — and
#     checks every flag placeholder in the file, not one block: the two flags
#     must resolve to the same `T` at every site, and the occurrence count is a
#     tripwire so a new site reds;
#   * the DOC half pins the two documentation sites BY CONTENT — that they state
#     the cadence, and that they point at §3.5 rather than restating it;
#   * a ROSTER TRIPWIRE over `git ls-files '*.md' '*.md.tmpl'`, so a fourth site
#     stating the cadence reds rather than drifting in silence. Derived, never
#     transcribed (MAINTAINING.md, *Derive the roster, never transcribe it*).
#     It reads the INDEX, so a new site must be `git add`ed before the gate —
#     the #1189 lesson, recorded here because the derivation cannot see an
#     untracked file at all;
#   * NON-VACUITY controls, one per gap kind the sweep can report, each over a
#     real site copied into `$BATS_TEST_TMPDIR` so no control can leave a decoy
#     behind for the tripwire above to measure.
#
# Needles are normalised through `load prose-lockstep` (#1432) — the shared
# derivation, so emphasis, code ticks and reflows cannot silently retire a pin.
# Every gate needle is chosen to fit on ONE source line, which
# `prose_gate_lines` requires; the wrap-tolerant clause tests run over
# `prose_window`, which collapses whitespace, and the two COUNTING pins run over
# `prose_body`, which collapses the whole file — a count keyed on
# `prose_gate_lines` would miss a wrapped occurrence, and for a count the
# fail-open direction is under-counting.
#
# The version bump the story also asks for is deliberately NOT swept here: the
# only honest bats assertion is "greater than origin/main", which depends on the
# base ref being fetched in the runner. `tests/check-marketplace-sync.bats`
# already proves the two manifests AGREE; the bump itself is a CI/review check.
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
  # #1504 moved §3's plugin-repo gate rules — the attestation bullet among them —
  # out of the conductor and into `development-<repo_type>:resolve-profile`. The
  # cadence's CONSUMING SITES therefore span the conductor corpus and every
  # shipped profile, so the sweeps that COUNT them read both; the sweeps that pin
  # WHERE a sentence lives read the one file it lives in, which for that bullet
  # is now the profile below.
  PROFILE="$REPO_ROOT/development-claude-plugin/skills/resolve-profile/SKILL.md"
  # DERIVED from the index, never a transcribed roster: a second profile that
  # cites the cadence must raise the count rather than slip past a closed list.
  CADENCE="$BATS_TEST_TMPDIR/cadence-corpus.md"
  cat "$SKILL" > "$CADENCE"
  PROFILE_PATHS=()
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    PROFILE_PATHS+=("$REPO_ROOT/$_p")
    printf '\n' >> "$CADENCE"
    cat "$REPO_ROOT/$_p" >> "$CADENCE"
  done < <(git -C "$REPO_ROOT" ls-files 'development-*/skills/resolve-profile/SKILL.md')
  # The roster is real — every negative pin below iterates it, so an empty one
  # would make them pass having examined nothing.
  [ "${#PROFILE_PATHS[@]}" -ge 1 ]

  # The content-anchored heading of the one normative statement. It carries the
  # issue number, so it can never collide with the pointers, which name the
  # section instead.
  BANNER='The round boundary is concurrent — one minted tree, two readers (#1497).'
  # What a POINTER looks like: the cadence's name plus where it lives, and no
  # ordering.
  POINTER='The round boundary is concurrent (§3.5)'
  # The roster needle — the shortest phrase every site shares. Deliberately
  # WITHOUT the issue number, so the tripwire sees a new site that states the
  # cadence in prose as readily as one that cites it.
  ROSTER_NEEDLE='the gate and the panel'

  # One one-line gate per ordering step, IN ORDER. Used twice: for presence and
  # for position, which are different failures.
  STEP_GATES=(
    '1. Mint the tree identity once, before either activity starts.'
    '2. Start the gate out of band, so that it runs without blocking the panel'
    '3. Plan and dispatch the panel (the Each round panel step below) against'
    "4. Observe the gate's completion before consolidating"
    '5. Green → consolidate (the Each round loop-invocation step below),'
    '6. Red → the round is not consolidated and neither attest is passed.'
    '7. Green on a REPORTED tree that is not T — reachable on a plugin repo'
  )
}

# Lines of $1 whose normalised text carries the literal $2, as a COUNT.
#
# `prose_gate_lines` prints one line number per hit and nothing at all on a
# miss, so `wc -l` over its output is the occurrence count — but only once the
# helper's own status has been checked, because a 2 (unreadable file, empty
# needle) also prints nothing and would otherwise read as a clean zero.
_hits() {
  [ "$#" -eq 2 ] || { printf '_hits: needs a file and a needle\n' >&2; return 2; }
  [ -n "$2" ] || { printf '_hits: empty needle\n' >&2; return 2; }
  local out
  out="$(prose_gate_lines "$1" "$2")" || return 2
  if [ -z "$out" ]; then printf '0\n'; return 0; fi
  printf '%s\n' "$out" | wc -l | tr -d ' '
}

# Occurrences of the literal $2 in $1's WHOLE normalised body, as a COUNT.
#
# `_hits` is per line, which is right for gating but wrong for counting: a
# pointer that wraps mid-phrase — several do — is simply invisible to it, and
# for a count the fail-open direction is under-counting. `prose_body` collapses
# the file, so a reflow cannot retire an occurrence.
_body_hits() {
  [ "$#" -eq 2 ] || { printf '_body_hits: needs a file and a needle\n' >&2; return 2; }
  [ -n "$2" ] || { printf '_body_hits: empty needle\n' >&2; return 2; }
  local body out rc=0
  body="$(prose_body "$1")" || return 2
  # Only grep's status 1 is a genuine zero. `|| true` would absorb a 2 (an I/O
  # or resource error on the collapsed body) as a clean count of 0 — fail-OPEN
  # for the negative doc pin, whose whole meaning is that 0 means clean.
  out="$(printf '%s\n' "$body" | grep -oF -e "$2")" || rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" | grep -c . ;;
    1) printf '0\n' ;;
    *) printf '_body_hits: grep failed (%s)\n' "$rc" >&2; return 2 ;;
  esac
}

# The placeholder token a flag carries inside a fenced invocation block.
#
# $1 file, $2 the 1-based line the block starts at, $3 how many lines past that
# start to read, $4 the flag. Prints the token following the flag; prints
# nothing and returns 1 when the flag does not appear, so a caller comparing two
# tokens can never read "both absent" as "both equal" — which is how a
# structural pin goes vacuous. Misuse (wrong arity, empty flag) returns 2: with
# an empty `$4` the pattern would degenerate to ` [^] ]+` and match almost every
# line, handing both callers the same arbitrary token.
_flag_placeholder() {
  [ "$#" -eq 4 ] || { printf '_flag_placeholder: needs file, line, span, flag\n' >&2; return 2; }
  [ -n "$4" ] || { printf '_flag_placeholder: empty flag\n' >&2; return 2; }
  local tok
  tok="$(sed -n "$2,$(($2 + $3))p" "$1" | grep -oE -- "$4 [^] ]+" | head -1 \
    | awk '{print $2}')"
  [ -n "$tok" ] || return 1
  printf '%s\n' "$tok"
}

# The markdown files under $1 that state the cadence, one per line.
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
  [ "$#" -eq 2 ] || { printf '_roster_hits: needs a root and a needle\n' >&2; return 2; }
  [ -n "$2" ] || { printf '_roster_hits: empty needle\n' >&2; return 2; }
  local root="$1" needle="$2" f rc
  while IFS= read -r -d '' f; do
    case "$f" in docs/superpowers/*) continue ;; esac
    # -r as well as -f: `grep` never opens the file here — `sed` does, and
    # `grep` reads a pipe — and bats runs no `pipefail`, so an unreadable file
    # would leave `grep` on an empty stream returning 1, i.e. folded into "does
    # not state the cadence". This guard is what actually prevents that
    # under-count; the `rc` case below only catches grep's own stream errors.
    if [ ! -f "$root/$f" ] || [ ! -r "$root/$f" ]; then
      printf 'roster: listed path is not a readable file: %s\n' "$f" >&2
      return 2
    fi
    rc=0
    # -a so a stray NUL cannot turn a match into "Binary file … matches"; -i
    # because a site may state the cadence mid-sentence, where the article is
    # lowercase — the shape that would otherwise be a fourth site in silence.
    #
    # `tr -s '[:space:]' ' '` because this asks a FILE-level question and needs
    # no line numbers: without it the needle has to fall inside one physical
    # line, and a mention wrapped mid-phrase across two lines — the likeliest
    # shape for a mid-sentence one — drops out of the roster silently.
    sed 's/^[[:space:]]*#[[:space:]]\{0,1\}//' "$root/$f" | tr -d '*`' \
      | tr -s '[:space:]' ' ' | grep -qaiF -e "$needle" || rc=$?
    case "$rc" in
      0) printf '%s\n' "$f" ;;
      1) ;;
      *) printf 'roster: grep failed (%s) on %s\n' "$rc" "$f" >&2; return 2 ;;
    esac
  done
}

# --- AC1: the concurrent ordering, stated once, under its own heading -------

@test "#1497 AC1 the concurrent round boundary carries its banner, exactly once" {
  local n
  n="$(_hits "$SKILL" "$BANNER")"
  [ "$n" -eq 1 ]
}

@test "#1497 AC1 the banner states the guardrail the story puts out of scope" {
  # Without it a reader is licensed to weaken the gate in the name of the
  # overlap, which is the one thing the story forbids.
  local ln body
  ln="$(prose_gate_lines "$SKILL" "$BANNER")"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 10)"
  contains "$body" 'the whole suite still runs on every round that applied a fix, a red gate still blocks consolidation'
  contains "$body" 'the boundary starts them together instead of making the panel queue behind the gate'
  # …and the measured figure, because docs/explanation/review-loop.md defers to
  # it by name — deleting it here leaves that page pointing at nothing
  contains "$body" 'worth roughly min(gate, panel) per round, about ten minutes a round across the #1435'
}

@test "#1497 AC1 the seven steps are present, in ORDER, and inside the block" {
  # Presence AND position AND locality in one pin, because a window wide enough
  # to hold all seven would reach as far backwards into §3, where an unrelated
  # paragraph could satisfy a needle.
  #
  # The regression position catches and presence cannot: swap items 3 and 4 and
  # the panel queues behind the gate again while every needle still matches.
  local needle ln prev end
  prev="$(prose_gate_lines "$SKILL" "$BANNER")"
  [ -n "$prev" ]
  end="$(prose_gate_lines "$SKILL" 'At a round boundary the attestation pair is the invariant.')"
  [ -n "$end" ]
  local out
  for needle in "${STEP_GATES[@]}"; do
    out="$(prose_gate_lines "$SKILL" "$needle")" || return 1
    ln="$(printf '%s\n' "$out" | head -1)"
    if [ -z "$ln" ]; then
      printf 'ordering pin: no line carries the gate "%s"\n' "$needle" >&2
      return 1
    fi
    if [ "$ln" -le "$prev" ]; then
      printf 'ordering pin: "%s" is at line %s, not after %s\n' "$needle" "$ln" "$prev" >&2
      return 1
    fi
    prev="$ln"
  done
  # …and the last of them still precedes the invariant, so the list has not
  # sprawled out of the block it belongs to
  [ "$prev" -lt "$end" ]
}

@test "#1497 AC1 the ordering is scoped by STACK where the gate reports no tree" {
  # `run-gate.zsh` emits `tree` on plugin repos only. Stated unconditionally,
  # step 5's condition is unsatisfiable on a pytest/Gradle/Go repo — every round
  # falls to the drifted-green arm, discards its panel and restarts forever —
  # and the same sentence tells the session to pass a flag SKILL.md's own four
  # rules forbid off plugin repos.
  local ln body
  ln="$(prose_gate_lines "$SKILL" '5. Green → consolidate (the Each round loop-invocation step below),')"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 22)"
  contains "$body" 'a plugin repo whose <full gate> is run-gate.zsh and reported a tree — the only stack that reports one — additionally requires that tree to equal T, and passes --gate-attest "$T"'
  # …and the COMPOUND arm, without which arm 1 captures a plugin repo whose gate
  # is compound and the loop skips the whole compound on a tree match
  contains "$body" 'a plugin repo whose <full gate> is compound'
  contains "$body" 'omits --gate-attest entirely, whatever tree the embedded run-gate.zsh reported'
  # the arm's REASON, pinned here as well as at the writing-gate site, so one
  # site cannot lose it while the other keeps it
  contains "$body" "the four rules' first rule governs, and a match would skip the whole compound including the parts that run never executed"
  # …and the stated count, so prose and structure move together with the
  # closure pin below
  contains "$body" 'decided by what the gate reported, in four arms'
  contains "$body" 'every other stack emits no tree at all, so green alone is the condition and --gate-attest is omitted entirely'
  # …and the third arm: run-gate.zsh documents an EMPTY tree as a degradation,
  # and reading it as drift would abort the run on two consecutive GREEN gates
  contains "$body" "a plugin repo whose reported tree is empty is run-gate.zsh's documented degradation, not drift"
  contains "$body" 'omit --gate-attest so the loop runs its own gate'
  # The drifted-green arm has to inherit the same scope, or it becomes the
  # never-converging arm on every non-plugin stack — pinned on its own anchor
  # below, since it sits past this window.
}

@test "#1497 AC1 step 5's arm list is CLOSED — exactly four arms" {
  # Per-arm content pins cannot see an INSERTION: a fifth arm re-licensing the
  # compound attest leaves every needle matching and the suite green, which is
  # the blind spot the seven numbered steps already close. Counted structurally
  # between step 5's gate line and step 6's, the way that pin counts.
  local start end n
  start="$(prose_gate_lines "$SKILL" '5. Green → consolidate (the Each round loop-invocation step below),')"
  [ -n "$start" ]
  end="$(prose_gate_lines "$SKILL" '6. Red → the round is not consolidated and neither attest is passed.')"
  [ -n "$end" ]
  # any indent: pinning today's one would let a re-indented fifth arm land green
  n="$(sed -n "${start},${end}p" "$SKILL" | grep -acE '^[[:space:]]*-[[:space:]]' || true)"
  # a grep that ERRORS prints nothing, and `[ "" -ne 4 ]` inside an `if` is
  # exempt from errexit — the branch is skipped and the pin reports ok having
  # counted nothing
  case "$n" in ''|*[!0-9]*)
    printf 'arm closure pin: grep produced no count\n' >&2; return 1 ;;
  esac
  if [ "$n" -ne 4 ]; then
    printf 'expected exactly 4 arms under step 5, found %s\n' "$n" >&2
    return 1
  fi
}

@test "#1497 AC1 an unmintable tree identity is a report-and-stop, not a restart" {
  # `git-tree-id.zsh` prints nothing and exits non-zero when it cannot compute
  # an identity, and contracts its callers to fail closed. An empty `T` carried
  # forward disarms `--gate-attest` silently and aborts the loop on
  # `--findings-tree` with a usage error that names neither cause.
  local ln body
  ln="$(prose_gate_lines "$SKILL" '1. Mint the tree identity once, before either activity starts.')"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 18)"
  contains "$body" 'prints nothing and exits non-zero when it cannot compute an identity'
  contains "$body" 'An unmintable T is a report-and-stop, never a restart'
  contains "$body" 'would silently disarm --gate-attest while aborting the loop on --findings-tree'
  # the snippet's own exit arm, not just the prose about it: a bare echo returns
  # zero and lets the boundary carry an empty T straight into step 2
  contains "$body" 'exit 1; }'
  contains "$body" 'hence the exit 1 rather than a bare echo, whose zero status would let the boundary carry straight on'
}

@test "#1497 AC1 the no-fix rounds and the tree-writing gate are exempted, not contradicted" {
  # Two pre-existing rules the unconditional ordering would have overridden: the
  # zero-blocker closing sweep must NOT re-run the suite (#981's attest-skip
  # exists for it), and a gate whose SUITE writes into the tree — a fixture
  # regenerator, or a compound `--test-cmd` with a fixing step — invalidates a
  # pre-gate mint. Fixing `pre-commit` hooks are explicitly NOT that case: §3
  # runs them before the mint and they are never part of `<full gate>`.
  local ln body
  ln="$(prose_gate_lines "$SKILL" 'Two kinds of round take a different boundary, and both are stated here rather')"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 48)"
  contains "$body" 'No fix pass ran since the last boundary'
  contains "$body" 'The tree has not moved: mint nothing and skip steps 2 and 4'
  # …and step 3 is NOT skipped on the promotion: its full-diff panel is the
  # whole point of the sweep, and skipping it converges on an unreviewed round
  contains "$body" 'Step 3 still applies on the closing-sweep promotion'
  contains "$body" 'Only the findings-file recovery re-invokes skip it too'
  # …and only those whose aggregate exists: a missing/empty refusal caused by a
  # panel that NEVER ran must still dispatch one, or the re-invoke is refused
  # again on the same absent file
  contains "$body" 'but only those whose aggregate really is intact'
  contains "$body" 'caused by a panel that never ran takes step 3 like any other round'
  # …and the flags, because step 5's arms all branch on a gate report that does
  # not exist on a round where no gate ran
  contains "$body" 'passing --findings-tree "$T" and, on a plugin repo whose <full gate> is run-gate.zsh, the held --gate-attest "$T"'
  # …and the compound case, where the previous boundary omitted the attest so
  # there is nothing to hold — without it this bullet overrides step 5's
  # compound arm and the loop skips the whole compound on a tree match
  contains "$body" 'Nothing is held unless that boundary actually passed one'
  contains "$body" "a compound <full gate> omitted it (step 5's compound arm), and so did an empty reported tree (step 5's documented-degradation arm)"
  contains "$body" 'the four rules license T only once a gate reported green on that same T, which a blanked field never did'
  contains "$body" "Step 5's reported-tree arms do not apply at all, because no gate ran this round"
  # …and the exclusion that keeps the cadence refusal out of that set, which is
  # the one recovery where the tree really did move
  contains "$body" 'The CADENCE refusal is not one of these'
  # …and the writing-gate fallback, whose rule an earlier round INVERTED: the
  # gate runs first and T is minted once the suite has settled, and
  # run-gate.zsh's reported tree is explicitly NOT used there (it is captured
  # before the suite runs). The comment said the opposite for a round, which is
  # how a later fix pass "repairs" the skill backwards.
  contains "$body" 'The <full gate> SUITE writes into the tree'
  # the trigger examples, so the bullet cannot go back to illustrating itself
  # with the one instance the sentence below it excludes
  contains "$body" 'a suite that regenerates a fixture, or a compound --test-cmd with a fixing step inside it'
  # …and the carve-out that keeps the bullet's trigger and §3's ordering the
  # same condition: fixing pre-commit hooks run BEFORE the mint and are never
  # part of <full gate>, so the bullet must not claim them
  contains "$body" 'Fixing pre-commit hooks are not this case: §3 runs them before the mint, and they are never part of <full gate>'
  contains "$body" 'run the gate first and mint T once it has settled — on every stack, plugin repos included'
  # the reason, which is a fact about run-gate.zsh rather than a preference:
  # it captures its tree BEFORE the suite runs
  contains "$body" "Do not take run-gate.zsh's reported tree there: it is captured before the suite runs"
  contains "$body" 'every round would be refused by the cadence guard'
  contains "$body" "step 5's equality check no longer gates consolidation and step 7 does not fire"
  # the compound-gate omission rule — this clause IS round 8's remedy, and an
  # unpinned remedy is one a later fix pass can revert green
  contains "$body" "On a compound <full gate> --gate-attest is omitted entirely — the four rules' first rule governs"
  contains "$body" 'a tree match would let the loop skip the whole compound including the parts the attested run never executed'
  contains "$body" 'It rides along only where <full gate> is run-gate.zsh and its reported tree happens to equal that post-settle mint'
}

@test "#1497 AC1 the exempted-round list is CLOSED — exactly two kinds" {
  # Content pins cannot see an INSERTION: a third bullet re-licensing the
  # compound attest on a no-fix round leaves every needle matching and the suite
  # green. Counted structurally between the list's heading and the invariant
  # paragraph, the same shape as step 5's arm-closure pin.
  local start end n
  start="$(prose_gate_lines "$SKILL" 'Two kinds of round take a different boundary, and both are stated here rather')"
  [ -n "$start" ]
  end="$(prose_gate_lines "$SKILL" 'At a round boundary the attestation pair is the invariant.')"
  [ -n "$end" ]
  n="$(sed -n "${start},${end}p" "$SKILL" | grep -acE '^[[:space:]]*-[[:space:]]' || true)"
  # a grep that ERRORS prints nothing, and `[ "" -ne 2 ]` inside an `if` is
  # exempt from errexit — the branch is skipped and the pin reports ok having
  # counted nothing
  case "$n" in ''|*[!0-9]*)
    printf 'exempted-round closure pin: grep produced no count\n' >&2; return 1 ;;
  esac
  if [ "$n" -ne 2 ]; then
    printf 'expected exactly 2 exempted-round bullets, found %s\n' "$n" >&2
    return 1
  fi
}

@test "#1497 AC1 the boundary says what to do with the in-flight gate when the panel aborts" {
  # The panel step has several arms that end the round without a findings file.
  # Without this the session either waits on a gate whose round it abandoned, or
  # starts a second full-suite gate over the first — both worse than the serial
  # shape the overlap replaced.
  local ln body
  ln="$(prose_gate_lines "$SKILL" '3. Plan and dispatch the panel (the Each round panel step below) against')"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 22)"
  contains "$body" 'If that step refuses or aborts the round'
  # kill, not merely ignore: a second gate over a live one oversubscribes the
  # host, and a byte the abandoned suite writes lands after the next mint
  contains "$body" 'stop the gate using the handle step 2 recorded'
  # the destructive path this forbids: on a plain background detach the handle's
  # process group is the driving session's own
  contains "$body" 'Never derive something to kill from that handle'
  contains "$body" "the handle's process group is the driving session's own, and killing it takes down the run"
  contains "$body" 'On a round where step 2 was skipped there is no handle and nothing to stop'
  contains "$body" 'a byte the abandoned suite writes lands after the next mint'
  # …and the no-fix carve-out on the RESUME half, or step 3 sends the promoted
  # closing sweep to re-mint the T the no-fix bullet just told it to hold
  contains "$body" 'Unless step 2 was skipped and the recovery did not move the tree'
  contains "$body" 're-dispatch against the same held T and mint nothing'
  # …and the arm does not override the recoveries it names, three of which are
  # report-and-stop — a universal "return to step 1" would loop on them
  contains "$body" "take that arm's own recovery, which this step never overrides"
  contains "$body" 'several are report-and-stop, and stopping is the whole recovery'
  contains "$body" 'Only where the recovery resumes the round'
  # …and the OVERLAP itself, which is what a serial rewrite would quietly drop
  contains "$body" 'against that same tree, while the gate is still running'
}

@test "#1497 AC1 the invariant names ONE tree, minted before BOTH activities" {
  # The sentence the whole story reduces to. Without "minted before both", the
  # ordering is satisfied by a value minted after either — the self-attestation
  # #981 and #1435 §10 each forbid, which matches trivially and certifies
  # nothing.
  local ln body
  ln="$(prose_gate_lines "$SKILL" 'At a round boundary the attestation pair is the invariant.')"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 12)"
  contains "$body" 'name the same minted tree, minted before both the gate and the panel start'
  contains "$body" 'matches the working tree trivially and certifies nothing'
  # …that this is an ordering, not new machinery — the story's own bound
  contains "$body" 'This needs no new flag and no new script'
  # …and the exception, without which the invariant licenses passing a FRESH
  # mint as `--gate-attest` on a cadence-refusal recovery, skipping a gate that
  # never ran on the post-fix tree
  contains "$body" 'Outside a boundary the two legitimately differ.'
  contains "$body" 'never pass the fresh mint as --gate-attest, which would skip a gate that never ran on the post-fix tree'
}

# --- the two sentences that make the boundary reachable at all --------------

@test "#1497 §3.5's entry condition is UNDER WAY, not green" {
  # The sentence that decides when the loop is entered. Reverted to "green", the
  # seven-step block still exists and every content pin still matches while
  # round 1's panel queues behind the full suite — the saving never realised.
  local ln body
  ln="$(prose_gate_lines "$CONDUCTOR" "Once §3's gate is under way, run the local review loop before")"
  [ -n "$ln" ]
  body="$(prose_window "$CONDUCTOR" "$ln" 8)"
  contains "$body" 'Under way, not green: the round boundary starts the gate and the panel together'
  contains "$body" 'it is consolidation — never the panel — that waits for green'
}

@test "#1497 the gate is carved out of §3.5's own background-task ban" {
  # §3.5 bans running the loop as a background task. The boundary starts the
  # GATE in the background, so without this carve-out the section contradicts
  # itself and a session is licensed to refuse step 2.
  local ln body
  ln="$(prose_gate_lines "$CONDUCTOR" 'Both rules are about model-driven steps. The gate is not one — it is a')"
  [ -n "$ln" ]
  body="$(prose_window "$CONDUCTOR" "$ln" 6)"
  contains "$body" 'which is why the round boundary below runs it in the background on purpose'
  contains "$body" 'The loop invocation, the panel and every fix pass stay in-session'
}

@test "#1497 §3's own gate step points at the boundary instead of implying a serial wait" {
  # A model executing the skill top-down finishes §3 before reading §3.5. Left
  # as a bare "only proceed when green", it waits out the full suite and only
  # then enters the loop — the serial shape, on every run.
  local ln body
  ln="$(prose_gate_lines "$CONDUCTOR" "Run the repo's own test + lint gate and only proceed when green. Green")"
  [ -n "$ln" ]
  body="$(prose_window "$CONDUCTOR" "$ln" 12)"
  contains "$body" 'Green gates consolidating and committing, not dispatching the panel'
  contains "$body" "$POINTER"
  # the round-6 mint-ordering fix: what the boundary starts, and the order of
  # the tree-writing checks relative to the mint. Unpinned, reverting it
  # re-ships both round-6 blockers with the suite green.
  contains "$body" 'what it starts is the whole-suite <full gate> alone, not this whole list'
  contains "$body" 'run the checks below that write into the tree first'
  contains "$body" "Where the suite itself writes, §3.5's The <full gate> SUITE writes into the tree bullet governs instead and the mint follows the gate"
}

# --- AC2: the red-gate arm --------------------------------------------------

@test "#1497 the intro gloss says committed-or-pushed, not reaches-review" {
  # The first paragraph a model reading the skill top-down consumes, and it made
  # the same cadence claim §3.5 makes normatively. Reverted to "before it ever
  # reaches review" it re-teaches the serial shape at the site read before §3.5
  # exists for the reader, with every §3.5 pin still matching. Gated on the
  # UNCHANGED clause beside it, so the needle cannot follow the revert.
  local ln body
  ln="$(prose_gate_lines "$CONDUCTOR" 'sequence of them — with the story gated for readiness up front and the')"
  [ -n "$ln" ]
  body="$(prose_window "$CONDUCTOR" "$ln" 4)"
  contains "$body" 'tested before it is ever committed or pushed'
}

@test "#1497 the Guardrails bullet says what the gate gates, not that green precedes review" {
  # Guardrails is the checklist a session consults last and compiles as its
  # invariants. Reverted to "green tests are the precondition for review (the
  # per-issue gate)", it holds the boundary's step 3 until the full suite is
  # green — the serial boundary this story removes — while the seven-step block
  # above still reads correctly. Gated on the bullet's unchanged opening.
  local ln body
  ln="$(prose_gate_lines "$CONDUCTOR" 'Never open a PR on a red gate')"
  [ -n "$ln" ]
  body="$(prose_window "$CONDUCTOR" "$ln" 4)"
  contains "$body" 'a red per-issue gate blocks consolidation and the commit, so nothing reaches a PR'
}

@test "#1497 AC2 §3.5 states the red-gate arm — no consolidate, no attest, discard, restart" {
  # The arm that pays for the overlap, and every clause is load-bearing on its
  # own: drop "neither attest is passed" and a session attests a tree the gate
  # never proved; drop "discarded" and it consolidates findings about a
  # superseded tree, which is exactly what the #1435 §10 cadence guard refuses.
  local ln body
  ln="$(prose_gate_lines "$SKILL" '6. Red → the round is not consolidated and neither attest is passed.')"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 10)"
  contains "$body" 'Red → the round is not consolidated and neither attest is passed.'
  contains "$body" 'restart this boundary from its step 1'
  contains "$body" "this round's panel findings describe the superseded tree and are discarded"
  # …and that the cost is named honestly rather than hidden
  contains "$body" 'That discard is the one cost of the overlap, and it is agent tokens rather than wall-clock'
}

@test "#1497 AC2 the drifted-green arm is separate, diagnosable and BOUNDED" {
  # Fused into the red arm it inherits a remedy it cannot execute ("fix the
  # red") and no bound — so a systematic mismatch (a gate started from another
  # cwd, a work-dir inside the repo) discards a panel every round with nothing
  # to fix, until the budget is gone.
  local ln body
  ln="$(prose_gate_lines "$SKILL" '7. Green on a REPORTED tree that is not T — reachable on a plugin repo')"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 12)"
  # the stack scope, which this arm inherits: off plugin repos no `tree` is
  # reported at all, so an unscoped arm would swallow every green round
  contains "$body" 'reachable on a plugin repo only, and only when a tree was actually reported'
  contains "$body" "an empty one is step 5's documented-degradation arm, not this"
  contains "$body" 'there is no red to fix: something moved the tree between the mint and the gate'
  contains "$body" 'a gate started in a different worktree or outside the repo entirely'
  contains "$body" 'restart this boundary once; a second drifted green is reported, and you stop'
}

# --- AC3: the two flags share ONE placeholder -------------------------------

@test "#1497 AC3 the canonical consolidation invocation gives both flags one placeholder" {
  # Structural, not a literal `<T>`: the criterion is that the two flags SHARE a
  # name, so a rename that keeps them equal is fine and only a split back into
  # two names is the defect. `_flag_placeholder` returns 1 on an absent flag, so
  # "both missing" can never read as "both equal".
  local ln g f
  ln="$(grep -n '^2\. \*\*One loop invocation\.\*\*' "$SKILL" | head -1 | cut -d: -f1)"
  [ -n "$ln" ]
  g="$(_flag_placeholder "$SKILL" "$ln" 11 '--gate-attest')"
  f="$(_flag_placeholder "$SKILL" "$ln" 11 '--findings-tree')"
  if [ "$g" != "$f" ]; then
    printf 'canonical block: --gate-attest %s but --findings-tree %s\n' "$g" "$f" >&2
    return 1
  fi
}

@test "#1497 AC3 EVERY flag placeholder in SKILL.md resolves to the one T" {
  # The sibling sweep (#982), derived rather than pinned to one block. SKILL.md
  # carries the pair at the canonical block, the two shell examples, the
  # promotion sub-loop, the granted resume and the boundary's own step 5, and
  # each flag additionally alone wherever the prose names it — which is why the
  # occurrence count below is not twice the number of sites. A split spelled
  # `<panel-T>` at any of them teaches the invariant backwards at the moments
  # §3.5 says it is most easily forgotten.
  local spellings
  spellings="$(grep -oE -- '--(gate-attest|findings-tree) (<[^>]*>|"[^"]*")' "$SKILL" \
    | awk '{print $2}' | sort -u)"
  [ -n "$spellings" ]
  if [ "$spellings" != "$(printf '"$T"\n<T>')" ]; then
    printf 'expected only <T> and "$T" as placeholders, found:\n%s\n' "$spellings" >&2
    return 1
  fi
}

@test "#1497 AC3 the number of flag-placeholder sites is a tripwire" {
  # A count, so a NEW invocation site reds here rather than being swept by an
  # assertion nobody extended. The spelling pin above cannot see an added site
  # that happens to use `<T>` correctly — which is the site most likely to be
  # added and then edited wrongly later.
  local n
  n="$(grep -oE -- '--(gate-attest|findings-tree) (<[^>]*>|"[^"]*")' "$SKILL" \
    | grep -c . || true)"
  case "$n" in ''|*[!0-9]*)
    printf 'placeholder tripwire: grep produced no count\n' >&2; return 1 ;;
  esac
  if [ "$n" -ne 18 ]; then
    printf 'expected 18 flag-placeholder occurrences in SKILL.md, found %s\n' "$n" >&2
    return 1
  fi
}

# --- AC4: the two documentation sites, pinned by content --------------------

@test "#1497 AC4 the review-loop explanation states the cadence and points at §3.5" {
  local ln body
  ln="$(prose_gate_lines "$EXPLAIN" 'The gate and the panel run concurrently.')"
  [ -n "$ln" ]
  body="$(prose_window "$EXPLAIN" "$ln" 14)"
  # what the cadence IS — without this the page names it and points at §3.5
  # while saying nothing about what happens
  contains "$body" 'mints one tree identity, starts the full suite in the background and dispatches the panel against that same tree'
  # …the guardrail, or a reader takes the overlap for a weakened gate
  contains "$body" 'the whole suite still runs on every round that applied a fix, and consolidation still waits for it to come back green'
  # …the cost, which is the half a summary drops first
  contains "$body" 'a red gate discards that round'
  contains "$body" "§3.5's round protocol"
  contains "$body" 'nothing here restates them'
  # …and the magnitude is deferred rather than independently derived, so the two
  # sites cannot quote different totals for the same run
  contains "$body" 'the shorter of the two, per round; §3.5 carries the measured figure'

  # The page states the cadence TWICE, and the numbered list is the half a
  # reader hits first. Held separately, because the paragraph above can stand
  # intact while the list is flipped serial — a doc-internal contradiction in
  # the one artifact AC4 is about.
  ln="$(prose_gate_lines "$EXPLAIN" '1. Review — and re-test, alongside it.')"
  [ -n "$ln" ]
  body="$(prose_window "$EXPLAIN" "$ln" 16)"
  contains "$body" 'while the full test suite runs against the same tree at the same time'
  contains "$body" 'the suite is the one thing that does run in the background'
  contains "$body" 'Consolidate — and this is what waits for the suite'
  contains "$body" "A suite that comes back red discards that round's findings and restarts the boundary"
}

@test "#1497 AC4 ARCHITECTURE states the cadence once, scoped, and points at §3.5" {
  local ln body
  ln="$(prose_gate_lines "$ARCH" 'Both flags nonetheless carry one identity per round where both are')"
  [ -n "$ln" ]
  body="$(prose_window "$ARCH" "$ln" 10)"
  contains "$body" 'runs the gate and the panel concurrently over a single tree minted before either starts (#1497)'
  # the scope, or the contract doc contradicts its own plugin-repo-only rule for
  # --gate-attest two pages earlier
  contains "$body" 'Off plugin repos only --findings-tree is passed'
  contains "$body" 'the concurrency is an ordering, not a flag pair that exists everywhere'
  contains "$body" "development/skills/resolve-issue/reference/review-loop.md § The round protocol"
  # The load-bearing half: the ordering is the SESSION's, so the loop enforces
  # nothing here. A doc that said otherwise would licence a reader to assume a
  # mechanical guard that does not exist.
  contains "$body" 'the loop itself is unchanged by it'
  contains "$body" 'restated nowhere else'
}

@test "#1497 AC4 neither doc site restates the ordering it disclaims" {
  # The banner pin is SKILL-scoped and the roster tripwire counts FILES, so
  # without this the ordering could be pasted verbatim into either doc —
  # disclaimer intact — with the whole suite green. Counted over the collapsed
  # BODY, not per line: a paste that re-wraps at the doc's own column width
  # would slip past a per-line matcher, and fail-open is the wrong direction for
  # a negative pin.
  #
  # Assign, never `if [ "$(_body_hits …)" -ne 0 ]`: a command substitution inside
  # a condition swallows the helper's typed 2 AND `[`'s own "integer expression
  # expected", so a dead pin would read as a clean bill of health.
  # The profiles are a file class this pin never knew about (#1504). They now
  # CITE the cadence (the attestation bullet moved into one), which is exactly
  # the shape that grows into a restatement — and the roster tripwire below
  # cannot see it, because its needle appears in none of the STEP_GATES.
  local f needle n
  for f in "$EXPLAIN" "$ARCH" "${PROFILE_PATHS[@]}"; do
    for needle in "$BANNER" "${STEP_GATES[@]}"; do
      n="$(_body_hits "$f" "$needle")" || return 1
      if [ "$n" -ne 0 ]; then
        printf 'the ordering is restated in %s: %s\n' "$f" "$needle" >&2
        return 1
      fi
    done
  done
}

@test "#1497 exactly eight consuming sites point at the cadence" {
  # Every place a session reaches for the boundary from outside it: §3's gate
  # step and its attestation bullet, the panel step's empty-full-scope recovery,
  # the ordinary fix turn, the fix-pass tail, the granted-rounds fix pass, the
  # extension's AWAITING_FIX arm, and the granted resume's mint instruction.
  # Counted, so a pointer lost to a rewrite reds — and so does one that grows
  # back into a restatement, since the ordering pins above would then find a
  # second copy.
  #
  # Read over the conductor corpus PLUS the shipped profiles (#1504): the
  # attestation bullet is a claude-plugin rule and now lives in that type's
  # profile, so a sweep scoped to the conductor alone would count 7 and read a
  # rule that MOVED as a rule that was LOST.
  # Split per SIDE, not one union total: the invariant #1504 has to protect is
  # that the attestation bullet MOVED rather than was lost, and a union sum
  # cannot see a pointer sliding from one side to the other. The total falls out
  # of the two, and the failure message says which side changed.
  local in_skill in_profiles=0 p n
  in_skill="$(_body_hits "$SKILL" "$POINTER")"
  for p in "${PROFILE_PATHS[@]}"; do
    n="$(_body_hits "$p" "$POINTER")" || return 1
    in_profiles=$(( in_profiles + n ))
  done
  if [ "$in_skill" -ne 7 ]; then
    printf 'expected 7 cadence pointers in the conductor corpus, found %s\n' "$in_skill" >&2
    return 1
  fi
  if [ "$in_profiles" -ne 1 ]; then
    printf 'expected 1 cadence pointer across the shipped profiles, found %s\n' "$in_profiles" >&2
    return 1
  fi
  if [ "$(( in_skill + in_profiles ))" -ne 8 ]; then
    printf 'expected 8 pointers at the cadence in total, found %s\n' \
      "$(( in_skill + in_profiles ))" >&2
    return 1
  fi
}

# --- roster tripwire --------------------------------------------------------

@test "#1497 exactly five tracked markdown sites state the cadence" {
  # Derived, not transcribed. `docs/superpowers/` is vendored and restates
  # nothing of ours — the same exclusion the sibling sweeps use. SHIPPED
  # TEMPLATES are in scope: `approver-policy-core.md.tmpl` already restates
  # review-loop rules, so a copy landing there is exactly the fourth site this
  # tripwire exists to see.
  local hits n raw roster="$BATS_TEST_TMPDIR/roster.z"
  # Materialise the list with an OBSERVABLE status. A process substitution's
  # exit status is never reported, so a `git ls-files` that died after emitting
  # some paths would leave `_roster_hits` returning 0 over a partial roster —
  # and the three expected paths sort early, so a truncation past them would
  # still count 3 and pass every identity check below.
  git -C "$REPO_ROOT" -c core.quotePath=false ls-files -z '*.md' '*.md.tmpl' \
    > "$roster" || {
      printf 'could not derive the roster from %s\n' "$REPO_ROOT" >&2
      return 1
    }
  # Capture the helper's OWN status. Piping it straight into `sort -u` would
  # hand the substitution sort's status (always 0), so a `return 2` mid-walk —
  # an unreadable path — would leave the hits it had already printed and the
  # count could still read 3, certifying a half-derived roster.
  raw="$(_roster_hits "$REPO_ROOT" "$ROSTER_NEEDLE" < "$roster")" || return 1
  # `sort -u`: a conflicted index lists a path once per STAGE, which would
  # otherwise report more sites than exist while nothing drifted.
  hits="$(printf '%s\n' "$raw" | sort -u)"
  n="$(printf '%s\n' "$hits" | grep -c . || true)"
  case "$n" in ''|*[!0-9]*)
    printf 'roster tripwire: grep produced no count\n' >&2; return 1 ;;
  esac
  if [ "$n" -ne 5 ]; then
    printf 'expected 5 markdown sites stating the cadence, found %s:\n%s\n' "$n" "$hits" >&2
    return 1
  fi
  # …and they are the roster the story named, so a swap reds here too. -F
  # because an unanchored `.` in a path is a regex wildcard.
  # #1503 moved the review-loop procedure into reference/*.md, so the roster
  # names those files where the text now lives — the same sites, re-homed.
  printf '%s\n' "$hits" | grep -qxF 'development/skills/resolve-issue/SKILL.md'
  printf '%s\n' "$hits" | grep -qxF 'development/skills/resolve-issue/reference/review-loop.md'
  printf '%s\n' "$hits" | grep -qxF 'development/skills/resolve-issue/reference/interactive.md'
  printf '%s\n' "$hits" | grep -qxF 'docs/explanation/review-loop.md'
  printf '%s\n' "$hits" | grep -qxF 'ARCHITECTURE.md'
}

@test "#1497 AC1 the ordering list is CLOSED — exactly seven numbered steps" {
  # Order and locality cannot see an INSERTION: a new item between two gates
  # leaves every needle matching and every line number still increasing, so
  # `3. Block on the gate before dispatching the panel` could land green and
  # reinstate the exact wait this story removed. Counted structurally, the way
  # `tests/fix-pass-subtracts.bats` closes its own list.
  local start end n
  start="$(prose_gate_lines "$SKILL" "$BANNER")"
  [ -n "$start" ]
  end="$(prose_gate_lines "$SKILL" 'At a round boundary the attestation pair is the invariant.')"
  [ -n "$end" ]
  # Any indent, any emphasis: pinning the one shape the seven happen to use
  # today would let a re-indented eighth land green. Widening only ever fails
  # CLOSED — a re-indent of the existing seven still counts 7.
  n="$(sed -n "${start},${end}p" "$SKILL" | grep -cE '^[[:space:]]*[0-9]+\.[[:space:]]' || true)"
  # a grep that ERRORS prints nothing, and `[ "" -ne 7 ]` inside an `if`
  # condition is exempt from errexit — the branch is skipped and this
  # load-bearing pin reports ok having counted nothing
  case "$n" in ''|*[!0-9]*)
    printf 'closure pin: grep produced no count\n' >&2; return 1 ;;
  esac
  if [ "$n" -ne 7 ]; then
    printf 'expected exactly 7 numbered boundary steps, found %s\n' "$n" >&2
    return 1
  fi
}

@test "#1497 AC1 each ordering step appears exactly ONCE across everything a session reads" {
  # Uniqueness is asserted for the banner and non-restatement for the two doc
  # files, but nothing bounded how many times the steps themselves appear HERE.
  # A second copy pasted into a consuming site — banner omitted — leaves the
  # banner count 1, the ordering pin's first occurrences unchanged and the
  # pointer count intact, with two copies free to drift against each other.
  # Over $CADENCE — the conductor corpus AND the shipped profiles (#1504) — so
  # "exactly once" means once across everything a session reads, not once per
  # file class. A second copy in a profile is the same drift as a second copy in
  # the conductor.
  local needle n
  for needle in "${STEP_GATES[@]}"; do
    n="$(_body_hits "$CADENCE" "$needle")" || return 1
    if [ "$n" -ne 1 ]; then
      printf 'expected exactly 1 occurrence of "%s", found %s\n' "$needle" "$n" >&2
      return 1
    fi
  done
}

@test "#1497 non-vacuity: an ordering step pasted into a PROFILE reds the uniqueness pin" {
  # The mutation #1504 opened and nothing else would catch: the pointer count
  # stays 8 (the paste adds no pointer), the banner count stays 1, and the doc
  # pin's own fixtures are untouched. Drive the SAME haystack the real pin uses,
  # so the control measures that pin rather than a paraphrase of it.
  local F="$BATS_TEST_TMPDIR/cadence-with-planted-step.md" n
  cp "$CADENCE" "$F"
  printf '\n%s\n' "${STEP_GATES[1]}" >> "$F"
  n="$(_body_hits "$F" "${STEP_GATES[1]}")" || return 1
  [ "$n" -eq 2 ]
  # ...and the unmutated haystack still reads 1, so the control is measuring the
  # paste rather than a detector that counts everything twice
  n="$(_body_hits "$CADENCE" "${STEP_GATES[1]}")" || return 1
  [ "$n" -eq 1 ]
}

@test "#1497 AC1 step 2 names the mechanism, and step 4 the wait it implies" {
  # The two clauses that carry the concurrency itself. Step 2's gate line is the
  # heading, so deleting the sentence beneath it leaves every existing pin
  # matching while the one instruction saying HOW to run the gate off the
  # foreground is gone; step 4 had no content assertion at all, so deleting its
  # rule licensed a foreground poll and consolidating a gate that never
  # returned.
  local ln body
  ln="$(prose_gate_lines "$SKILL" '2. Start the gate out of band, so that it runs without blocking the panel')"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 42)"
  # The step states PROPERTIES and points at the one implementation that has
  # them; it deliberately does not restate the recipe. Three fix passes in a row
  # found fresh holes in a prescribed recipe rather than in the story, which is
  # why this pin holds the disclaimer as tightly as the properties.
  contains "$body" 'This step says what the launch must guarantee, and deliberately not how to write one'
  # the reference is a SHAPE, not a runner: that script only ever launches
  # claude -p, so handing it the gate would make the round's verdict a model
  # run's exit status and break §3.5's own first hard rule
  contains "$body" "the --detach block of development-claude-plugin:test's run-headless.zsh"
  contains "$body" 'a shape reference, never a runner you hand the gate to'
  contains "$body" 'That script only ever launches claude -p, which the gate must never be'
  contains "$body" 'do not invent a third one, and do not re-derive a recipe here'
  # …and the two properties the reference does NOT demonstrate, without which
  # "reproduce it" reproduces the gaps
  contains "$body" 'Two of these the reference shape does not demonstrate'
  contains "$body" "take from it the detach and the pre-launch clear, not the marker's dual role"
  # what to launch, and the whole-suite guarantee, which a smoke subset would
  # silently contradict
  contains "$body" 'the same <full gate> command §3 runs'
  # property 1 — survives the turn, with the #811 verdict spelled out rather
  # than merely cited, or the reconciliation can be inverted while green
  contains "$body" 'it survives the turn that started it'
  # the CONDITION is where the licence lives: without it the step permits any
  # harness background command, which is the class #811 documents as killed at
  # the turn boundary
  contains "$body" 'may stand in, but only where it is documented to outlive the turn and re-invoke the session when it exits'
  contains "$body" 'verify that; never assume it'
  contains "$body" "records the opposite for Claude Code's Bash run_in_background (#811: killed the instant the turn ends, SIGTERM-ing the child mid-run)"
  # property 2 — the signal is separate from the verdict AND cleared before the
  # launch: the half-written read and the stale-marker read both land on step 5
  # as a verdict no gate gave
  contains "$body" 'it signals completion only once the verdict is complete, and the signal is cleared before the launch'
  contains "$body" 'Either separate the two, or rename a fully-written payload into place'
  contains "$body" "a signal that survives a boundary restart is last round's answer to this round's question"
  contains "$body" 'The signal means finished, never green'
  # property 3 — the verdict, scoped by stack, which is what stops a non-plugin
  # stack report-and-stopping on a green round
  contains "$body" "the gate's exit status on every stack, plus run-gate.zsh's JSON summary where <full gate> is run-gate.zsh — the only stack that emits one"
  # property 4 — the handle step 3 needs
  contains "$body" 'it is killable — by a handle that stops the SUITE, not merely whatever launched it.'
  # the whole bullet, not just its requirement: the QUALIFICATION is the half
  # that makes the requirement applicable to the shape step 2 says to reproduce,
  # and deleting it ships the wrapper-pid trap three round-4 blockers named
  contains "$body" "Record that handle beside the signal. A pid naming a supervisor whose child keeps running does not satisfy this, and it is the easy mistake: the reference shape prints its wrapper's pid, so a reproduction has to make the recorded handle reach the process actually running the suite"
  # …and the second site, which is what keeps "Two of these" naming two
  contains "$body" "and its printed pid is the wrapper's, per the property above"
  # …and the outside-the-repo requirement, without which every round writes
  # bytes under the tree between the mint and the gate's hashing
  contains "$body" 'Everything it writes goes outside the repo'

  ln="$(prose_gate_lines "$SKILL" "4. Observe the gate's completion before consolidating")"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 18)"
  contains "$body" "wait for step 2's signal, with a generous bound (a full suite runs minutes, not hours)"
  # the ban is SCOPED — an unqualified one would forbid the only wait a
  # signal-file mechanism has
  contains "$body" 'What is banned is a poll that runs while the panel could have been running'
  # …and the arm for a gate that never returns, without which the bound is a
  # detection with no action and the session either spins or consolidates anyway
  contains "$body" 'A gate whose signal never arrives, or whose recorded verdict cannot be read, is neither green nor red'
  contains "$body" "stop it with step 3's handle, do not consolidate, and report and stop"
  contains "$body" "never read a missing verdict as step 5's empty-tree arm"
  contains "$body" 'Never consolidate a gate that has not returned.'
}

@test "#1497 the consuming sites keep their ORDERING clauses, not just their pointers" {
  # The pointer count says a site still cites the cadence; it says nothing about
  # what the site claims. Each of these can be flipped serial — or, at §3,
  # flipped to a mint AFTER the gate, which is the self-attestation the
  # invariant forbids — with the count intact.
  local ln body
  # §3's attestation bullet moved to the claude-plugin profile (#1504); the pin
  # names the file that holds the sentence, which is the point of pinning WHERE.
  ln="$(prose_gate_lines "$PROFILE" "§3.5's round boundary on, that identity is the T minted before this")"
  [ -n "$ln" ]
  body="$(prose_window "$PROFILE" "$ln" 6)"
  contains "$body" 'that identity is the T minted before this gate was started'
  contains "$body" 'this profile restates none of it'

  ln="$(prose_gate_lines "$SKILL" 'is concurrent (§3.5) — which mints T, starts the full gate and dispatches')"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 4)"
  contains "$body" "starts the full gate and dispatches that round's panel together"

  ln="$(prose_gate_lines "$SKILL" "T, starts the gate and dispatches that round's panel in-session together,")"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 10)"
  contains "$body" "starts the gate and dispatches that round's panel in-session together"
  # the round-6 red-arm fix at the same site: unpinned, it reverts to the
  # serial-era wording that resumes with the pre-fix panel's findings
  contains "$body" "a red gate takes the boundary's own step 6"
  contains "$body" "this round's panel findings are discarded, neither attest is passed, and the boundary restarts from its step 1"
  contains "$body" 'The grant is not consumed twice: the restarted boundary is the same granted round'

  ln="$(prose_gate_lines "$SKILL" "granted resume is one: mint T at that round's boundary — before the gate and")"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 4)"
  contains "$body" "mint T at that round's boundary — before the gate and the panel"

  # The ordinary fix turn and the interactive extension's AWAITING_FIX arm were
  # held by the pointer COUNT alone. Each needle spans the insertion point, so
  # a "gate to green, then" clause added beside an intact pointer breaks the
  # contiguous match rather than sailing past a count that is still 8.
  ln="$(prose_gate_lines "$SKILL" "anything other than this round's number + 1 → an ordinary fix turn. Fix,")"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 4)"
  contains "$body" "an ordinary fix turn. Fix, take the next round's boundary — The round boundary is concurrent (§3.5) — and plan that round without --final"

  ln="$(prose_gate_lines "$SKILL" 'On AWAITING_FIX (20) → continue the §3.5 round protocol (narrate, fix')"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 4)"
  contains "$body" "narrate, fix in-session, then the next round's boundary per The round boundary is concurrent (§3.5)"

  # The empty-full-scope recovery, which this round converted from the fifth
  # serial restatement into a pointer. The pointer COUNT alone was holding it:
  # rewriting the site to "re-run §3's gate to green and re-dispatch" keeps the
  # pointer phrase, so the count stays 8 and the serial shape comes back green.
  ln="$(prose_gate_lines "$SKILL" 'concurrent (§3.5) — which mints T, starts the gate and re-dispatches this')"
  [ -n "$ln" ]
  body="$(prose_window "$SKILL" "$ln" 4)"
  contains "$body" "starts the gate and re-dispatches this round's panel together"
  contains "$body" 'do not gate to green first'
}

@test "#1497 the Each-round step-2 pointers stay disambiguated from the boundary's" {
  # §3.5 now holds TWO numbered lists, so a bare "§3.5 step 2" names both the
  # loop invocation (which owns the recover-by-cause list) and the boundary's
  # "Start the gate out of band" (which owns no cause list at all). A session
  # that follows the bare form on a STALE_FINDINGS exit lands on the gate step,
  # never reaches its cause's recovery, and on an ALIAS refusal re-runs the
  # panel that recovery forbids in so many words.
  #
  # Counted, not gated on one site: the count is what notices a sixth pointer
  # arriving bare. Deliberately NOT a zero-count ban on the bare "§3.5 step "
  # form — the round-1 template legitimately carries "§3.5 step 1".
  local n
  n="$(_body_hits "$SKILL" "§3.5's Each round step 2")" || return 1
  if [ "$n" -ne 4 ]; then
    printf 'expected 4 qualified Each-round step-2 pointers, found %s\n' "$n" >&2
    return 1
  fi
  # …the fifth spells it with the hyphenated "step-2 refusal", which is the same
  # qualification in the exit taxonomy's own vocabulary
  n="$(_body_hits "$SKILL" '§3.5 Each round step-2')" || return 1
  [ "$n" -eq 1 ]
}

@test "#1497 AC3 both shell examples carry the plugin-repo-only qualifier" {
  # The examples show `--gate-attest "$T"`, which the four rules forbid off a
  # plugin repo. The spelling sweep only reads the placeholder token and the
  # tripwire only counts occurrences, so deleting the qualifying comment leaves
  # both green while the skill again shows a pytest/Gradle/Go session passing a
  # flag no gate output can confirm.
  local n
  n="$(_body_hits "$SKILL" '--gate-attest "$T" # plugin repos only — omit on any other stack')" || return 1
  if [ "$n" -ne 2 ]; then
    printf 'expected 2 qualified --gate-attest examples, found %s\n' "$n" >&2
    return 1
  fi
}

# --- non-vacuity ------------------------------------------------------------
#
# Each control mutates a REAL site copied into $BATS_TEST_TMPDIR and shows the
# corresponding assertion reds. Fixtures rather than the repo, so a control can
# never leave a decoy behind for the tripwire above to measure.

@test "#1497 non-vacuity: the OLD SERIAL wording reds the AC1 ordering pin" {
  # The acceptance criterion's own control, and the exact regression this file
  # exists to catch: "after the gate is green, dispatch the panel" reads
  # perfectly well and silently restores the wait the story removed.
  local F="$BATS_TEST_TMPDIR/skill-serial.md" ln body
  awk '
    index($0, "**The round boundary is concurrent") > 0 {
      print "**After the gate is green, dispatch the panel.** The panel is spawned"
      print "once the full suite has come back green, against the tree it proved."
      serial = 1
      next
    }
    serial == 1 && index($0, "Each round:") > 0 { serial = 0 }
    serial == 1 { next }
    { print }
  ' "$SKILL" > "$F"
  # the banner is gone, so the gate phrase finds nothing at all and every clause
  # pin above is unreachable
  ln="$(prose_gate_lines "$F" "$BANNER")"
  [ -z "$ln" ]
  # …and the serial wording really is what replaced it, so the control is not
  # merely proving that deleting a block deletes it. Anchored on the planted
  # line, since `prose_body` over a 5000-line file is the misuse its own
  # docstring names.
  ln="$(prose_gate_lines "$F" 'After the gate is green, dispatch the panel.')"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 20)"
  contains "$body" 'After the gate is green, dispatch the panel.'
  lacks "$body" 'Mint the tree identity once, before either activity starts.'
}

@test "#1497 non-vacuity: swapping two ordering steps reds the ORDER pin" {
  # The mutation presence cannot see: item 4's wait moved ahead of item 3's
  # dispatch, so the panel queues behind the gate while every `contains` in the
  # content pin still matches.
  local F="$BATS_TEST_TMPDIR/skill-reordered.md" needle out ln prev=0 reds=none step4
  # Lift step 4's gate line out and re-emit it BEFORE step 3's, so the wait
  # precedes the dispatch. The moved text is taken FROM THE SOURCE rather than
  # retyped: a retyped line has to reproduce the source's punctuation exactly,
  # and a mismatch would make the control red through the PRESENCE branch — the
  # branch the serial-wording control already covers — leaving the order
  # comparison, which is the only thing this control exists to exercise,
  # untouched.
  step4="$(grep -n '^4\. \*\*Observe the gate' "$SKILL" | head -1 | cut -d: -f2-)"
  [ -n "$step4" ]
  awk -v s4="$step4" '
    index($0, "4. **Observe the gate") > 0 { dropped = 1; next }
    index($0, "3. **Plan and dispatch the panel") > 0 { print s4; inserted = 1 }
    { print }
    END {
      if (!dropped || !inserted) {
        print "control: step 3/4 gate lines did not match the fixture" > "/dev/stderr"
        exit 1
      }
    }
  ' "$SKILL" > "$F"
  # Walk the way the pin does — capturing the helper status BEFORE the pipe,
  # since `| head -1` hands back head's (always 0) and a dead helper call would
  # otherwise set the flag for a reason that proves nothing.
  for needle in "${STEP_GATES[@]}"; do
    out="$(prose_gate_lines "$F" "$needle")" || return 1
    ln="$(printf '%s\n' "$out" | head -1)"
    if [ -z "$ln" ]; then reds=missing; break; fi
    if [ "$ln" -le "$prev" ]; then reds=order; break; fi
    prev="$ln"
  done
  # …and require the ORDER branch specifically: `missing` would mean the plant
  # mangled a needle, not that the pin caught a reordering.
  if [ "$reds" != order ]; then
    printf 'expected the ORDER branch to fire, got: %s\n' "$reds" >&2
    return 1
  fi
}

@test "#1497 non-vacuity: a red-gate arm that KEEPS the findings reds the AC2 pin" {
  # The subtler regression: the ordering survives, but the discard does not —
  # and a round that consolidates panel findings against an already-fixed tree
  # is precisely what the #1435 §10 guard refuses, one refusal per round.
  local F="$BATS_TEST_TMPDIR/skill-keeps-findings.md" ln body
  sed 's/\*\*discarded\*\*\./**kept**./' "$SKILL" > "$F"
  ln="$(prose_gate_lines "$F" '6. Red → the round is not consolidated and neither attest is passed.')"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 10)"
  lacks "$body" "this round's panel findings describe the superseded tree and are discarded"
  # the rest of the arm is untouched, so the control isolates the discard
  contains "$body" 'Red → the round is not consolidated and neither attest is passed.'
}

@test "#1497 non-vacuity: dropping the stack scope reds the AC1 stack pin" {
  # The CRITICAL this round fixed: an unconditional step 5 makes the round
  # boundary unsatisfiable off plugin repos.
  local F="$BATS_TEST_TMPDIR/skill-unscoped.md" ln body
  sed 's/every other stack emits no `tree` at all/every stack reports a `tree`/' \
    "$SKILL" > "$F"
  ln="$(prose_gate_lines "$F" '5. Green → consolidate (the Each round loop-invocation step below),')"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 22)"
  lacks "$body" 'every other stack emits no tree at all, so green alone is the condition and --gate-attest is omitted entirely'
  # the other two arms are untouched, so the control isolates the scope clause
  contains "$body" "a plugin repo whose reported tree is empty is run-gate.zsh's documented degradation, not drift"
}

@test "#1497 non-vacuity: dropping 'minted before both' reds the invariant pin" {
  # The one clause that distinguishes the invariant from a self-attestation.
  local F="$BATS_TEST_TMPDIR/skill-late-mint.md" ln body
  sed 's/same minted tree, minted before both/same minted tree, minted at some point around/' \
    "$SKILL" > "$F"
  ln="$(prose_gate_lines "$F" 'At a round boundary the attestation pair is the invariant.')"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 12)"
  lacks "$body" 'name the same minted tree, minted before both the gate and the panel start'
}

@test "#1497 non-vacuity: reverting the entry condition to GREEN reds its pin" {
  local F="$BATS_TEST_TMPDIR/skill-green-entry.md" ln
  sed "s/Once §3's gate is \*\*under way\*\*/Once §3's gate is **green**/" "$CONDUCTOR" > "$F"
  ln="$(prose_gate_lines "$F" "Once §3's gate is under way, run the local review loop before")"
  [ -z "$ln" ]
}

@test "#1497 non-vacuity: deleting the background-task carve-out reds its pin" {
  local F="$BATS_TEST_TMPDIR/skill-no-carveout.md" ln
  sed '/^Both rules are about \*\*model-driven\*\* steps\./d' "$CONDUCTOR" > "$F"
  ln="$(prose_gate_lines "$F" 'Both rules are about model-driven steps. The gate is not one — it is a')"
  [ -z "$ln" ]
}

@test "#1497 non-vacuity: a canonical block split back into two placeholders reds AC3" {
  local F="$BATS_TEST_TMPDIR/skill-split.md" ln g f spellings
  sed 's/\[--findings-tree <T>\]/[--findings-tree <panel-T>]/' "$SKILL" > "$F"
  ln="$(grep -n '^2\. \*\*One loop invocation\.\*\*' "$F" | head -1 | cut -d: -f1)"
  [ -n "$ln" ]
  g="$(_flag_placeholder "$F" "$ln" 11 '--gate-attest')"
  f="$(_flag_placeholder "$F" "$ln" 11 '--findings-tree')"
  [ "$g" != "$f" ]
  # …and the derived spelling sweep reds on the same mutation, which is what
  # covers the five sites the canonical-block pin never reads
  spellings="$(grep -oE -- '--(gate-attest|findings-tree) (<[^>]*>|"[^"]*")' "$F" \
    | awk '{print $2}' | sort -u)"
  [ "$spellings" != "$(printf '"$T"\n<T>')" ]
}

@test "#1497 non-vacuity: a split in the PROMOTION sub-loop block reds the derived sweep" {
  # The site the canonical-block pin structurally cannot see, and one of the two
  # §3.5 calls the invariant is most easily forgotten.
  local F="$BATS_TEST_TMPDIR/skill-promo-split.md" spellings
  awk '
    index($0, "--promote <promoted.json> --test-cmd") > 0 { promo = 1 }
    promo == 1 && index($0, "[--gate-attest <T>] [--findings-tree <T>]") > 0 {
      sub(/\[--findings-tree <T>\]/, "[--findings-tree <panel-T>]"); promo = 0 }
    { print }
  ' "$SKILL" > "$F"
  grep -qF -- '[--findings-tree <panel-T>]' "$F"
  spellings="$(grep -oE -- '--(gate-attest|findings-tree) (<[^>]*>|"[^"]*")' "$F" \
    | awk '{print $2}' | sort -u)"
  [ "$spellings" != "$(printf '"$T"\n<T>')" ]
}

@test "#1497 non-vacuity: an absent flag is NOT read as a matching pair" {
  # The vacuity a structural comparison invites: delete both flags from the
  # block and two empty strings compare equal. `_flag_placeholder`'s typed 1 is
  # what closes it, and this control is what proves the typed 1 is honoured.
  local F="$BATS_TEST_TMPDIR/skill-no-flags.md" ln
  sed -e 's/\[--gate-attest <T>\]//' -e 's/\[--findings-tree <T>\]//' "$SKILL" > "$F"
  ln="$(grep -n '^2\. \*\*One loop invocation\.\*\*' "$F" | head -1 | cut -d: -f1)"
  [ -n "$ln" ]
  run _flag_placeholder "$F" "$ln" 11 '--gate-attest'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "#1497 non-vacuity: a misused helper returns 2 rather than a vacuous match" {
  # Without the arity/empty guards an empty flag degenerates the pattern to
  # ` [^] ]+`, which matches nearly every line — so both callers would receive
  # the same arbitrary token and AC3 would report ok while pinning nothing.
  run _flag_placeholder "$SKILL" 1 5 ''
  [ "$status" -eq 2 ]
  run _roster_hits "$REPO_ROOT" ''
  [ "$status" -eq 2 ]
  run _body_hits "$SKILL" ''
  [ "$status" -eq 2 ]
}

@test "#1497 non-vacuity: the ordering pasted into a DOC reds the doc pin" {
  # The five-copies-of-one-rule hazard, in the direction the roster tripwire
  # cannot see: a paste into a file already on the roster.
  local F="$BATS_TEST_TMPDIR/explain-restated.md" n
  cp "$EXPLAIN" "$F"
  {
    printf '\n1. **Mint the tree identity once**, before either activity\n'
    printf '   starts. This one value is what both attestations will name.\n'
  } >> "$F"
  n="$(_body_hits "$F" 'Mint the tree identity once, before either activity starts.')" || return 1
  [ "$n" -eq 1 ]
}

@test "#1497 non-vacuity: a doc site that loses its §3.5 pointer reds" {
  local F="$BATS_TEST_TMPDIR/explain-no-pointer.md" ln body
  sed "s|\`/development:resolve-issue\` §3.5's round protocol|elsewhere|" "$EXPLAIN" > "$F"
  ln="$(prose_gate_lines "$F" 'The gate and the panel run concurrently.')"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 14)"
  lacks "$body" "§3.5's round protocol"
}

@test "#1497 non-vacuity: an ARCHITECTURE site that claims the LOOP enforces it reds" {
  local F="$BATS_TEST_TMPDIR/arch-enforced.md" ln body
  sed 's/the loop itself is unchanged by it/the loop enforces the ordering/' "$ARCH" > "$F"
  ln="$(prose_gate_lines "$F" 'Both flags nonetheless carry one identity per round where both are')"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 10)"
  lacks "$body" 'the loop itself is unchanged by it'
}

@test "#1497 non-vacuity: a consuming site that loses its pointer reds the count" {
  local F="$BATS_TEST_TMPDIR/skill-pointer-lost.md" n
  # Rewrite the FIRST pointer only, leaving the others intact. Driven off ONE
  # pattern — a guard spelled differently from the mutation would latch
  # `dropped` without changing anything — and the END block names a fixture
  # drift instead of leaving the reader to debug the pin.
  awk 'dropped == 0 {
         if (sub(/\*The round boundary is concurrent\* \(§3\.5\)/, "elsewhere")) dropped = 1
       }
       { print }
       END { if (!dropped) { print "control: no pointer matched" > "/dev/stderr"; exit 1 } }' \
    "$CADENCE" > "$F"
  n="$(_body_hits "$F" "$POINTER")"
  [ "$n" -eq 7 ]
}

@test "#1497 non-vacuity: the roster tripwire counts a fourth site" {
  # Drives the SAME derivation over a synthetic roster, so the count really is
  # what the tripwire reads — not a restatement of the number 3. The fourth
  # site spells the cadence with emphasis INSIDE the phrase, the fifth is a
  # shipped TEMPLATE, the sixth states it mid-sentence with a lowercase article
  # and the seventh WRAPS the phrase across two lines: all four shapes are
  # invisible to a raw-bytes, per-line, `*.md`-only derivation.
  local D="$BATS_TEST_TMPDIR/roster" n raw
  mkdir -p "$D/docs/superpowers"
  printf 'the gate and the panel\n' > "$D/one.md"
  printf 'the gate and the panel\n' > "$D/two.md"
  printf 'the gate and the panel\n' > "$D/three.md"
  printf 'it starts **the gate and the panel** together.\n' > "$D/four.md"
  printf '# the gate and the panel\n' > "$D/five.md.tmpl"
  printf 'The gate and the panel read one tree.\n' > "$D/six.md"
  printf 'the boundary starts the gate\nand the panel together\n' > "$D/seven.md"
  # the vendored tree is excluded even when it states the cadence
  printf 'the gate and the panel\n' > "$D/docs/superpowers/vendored.md"
  # the helper's status is read here too — `| grep -c . || true` would mask it
  # twice, so an abort mid-walk could still count 7 and certify a derivation
  # that never ran to completion
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

@test "#1497 non-vacuity: a THIRD exempted-round bullet reds its closure pin" {
  local F="$BATS_TEST_TMPDIR/skill-three-kinds.md" start end n
  # the shape that motivates the pin: a bullet that hands back the attest the
  # compound arm was added to withhold
  awk '{ print }
       index($0, "- **The `<full gate>` SUITE writes into the tree**") > 0 {
         print "- **A compound gate whose embedded run-gate.zsh proved T** — pass the held attest." }' \
    "$SKILL" > "$F"
  start="$(prose_gate_lines "$F" 'Two kinds of round take a different boundary, and both are stated here rather')"
  [ -n "$start" ]
  end="$(prose_gate_lines "$F" 'At a round boundary the attestation pair is the invariant.')"
  [ -n "$end" ]
  n="$(sed -n "${start},${end}p" "$F" | grep -acE '^[[:space:]]*-[[:space:]]' || true)"
  [ "$n" -eq 3 ]
}

@test "#1497 non-vacuity: a FIFTH arm under step 5 reds the arm-closure pin" {
  local F="$BATS_TEST_TMPDIR/skill-five-arms.md" start end n
  # the shape that motivates the pin: an arm that re-licenses the very attest
  # arms 1 and 2 were split to forbid
  awk '{ print }
       index($0, "a plugin repo whose reported") > 0 {
         print "   - a compound gate whose embedded run-gate.zsh matched may pass it." }' \
    "$SKILL" > "$F"
  start="$(prose_gate_lines "$F" '5. Green → consolidate (the Each round loop-invocation step below),')"
  [ -n "$start" ]
  end="$(prose_gate_lines "$F" '6. Red → the round is not consolidated and neither attest is passed.')"
  [ -n "$end" ]
  n="$(sed -n "${start},${end}p" "$F" | grep -acE '^[[:space:]]*-[[:space:]]' || true)"
  [ "$n" -eq 5 ]
}

@test "#1497 non-vacuity: an EIGHTH numbered step reds the closure pin" {
  local F="$BATS_TEST_TMPDIR/skill-eight-steps.md" start end n
  # the shape that motivates the pin: a wait reinstated as its own step, which
  # order and locality both accept
  awk '{ print }
       index($0, "3. **Plan and dispatch the panel") > 0 {
         print "8. **Block on the gate before dispatching** — not a real step." }' \
    "$SKILL" > "$F"
  start="$(prose_gate_lines "$F" "$BANNER")"
  [ -n "$start" ]
  end="$(prose_gate_lines "$F" 'At a round boundary the attestation pair is the invariant.')"
  [ -n "$end" ]
  n="$(sed -n "${start},${end}p" "$F" | grep -cE '^[[:space:]]*[0-9]+\.[[:space:]]' || true)"
  [ "$n" -eq 8 ]
}

@test "#1497 non-vacuity: a SECOND copy of an ordering step reds the uniqueness pin" {
  local F="$BATS_TEST_TMPDIR/skill-step-copied.md" n
  cp "$SKILL" "$F"
  # wrapped, so the pin's whole-body counting is what catches it rather than a
  # per-line matcher that a reflow would defeat
  {
    printf '\n5. **Green** → consolidate (the *Each round* loop-invocation step\n'
    printf '   below), passing more or less the same thing.\n'
  } >> "$F"
  n="$(_body_hits "$F" '5. Green → consolidate (the Each round loop-invocation step below),')" || return 1
  [ "$n" -eq 2 ]
}

@test "#1497 non-vacuity: an ADDED placeholder site reds the count tripwire" {
  # The tripwire's own gap kind: a site added spelled CORRECTLY, which the
  # spelling sweep by construction cannot see.
  local F="$BATS_TEST_TMPDIR/skill-extra-site.md" n
  cp "$SKILL" "$F"
  printf '\n    --gate-attest <T> --findings-tree <T>\n' >> "$F"
  n="$(grep -oE -- '--(gate-attest|findings-tree) (<[^>]*>|"[^"]*")' "$F" \
    | grep -c . || true)"
  [ "$n" -eq 20 ]
}

@test "#1497 non-vacuity: a SECOND banner reds the uniqueness pin" {
  local F="$BATS_TEST_TMPDIR/skill-two-banners.md" n
  cp "$SKILL" "$F"
  printf '\n**The round boundary is concurrent — one minted tree, two readers (#1497).**\n' >> "$F"
  n="$(_hits "$F" "$BANNER")"
  [ "$n" -eq 2 ]
}

@test "#1497 non-vacuity: a consuming site flipped to a POST-gate mint reds its pin" {
  # The §3 bullet is the one consuming site whose flip re-teaches the
  # self-attestation the invariant exists to forbid.
  local F="$BATS_TEST_TMPDIR/skill-post-gate-mint.md" ln body
  sed 's/that identity is the `T` minted \*\*before\*\* this/that identity is the `T` minted **after** this/' \
    "$PROFILE" > "$F"
  ln="$(prose_gate_lines "$F" "§3.5's round boundary on, that identity is the T minted after this")"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 6)"
  lacks "$body" 'that identity is the T minted before this gate was started'
}

@test "#1497 non-vacuity: the empty-full-scope site re-serialised reds its clause pin" {
  # Keeps the pointer — so the count stays 8 — and restores exactly the serial
  # ordering round 1 blocked on.
  local F="$BATS_TEST_TMPDIR/skill-scope-serial.md" ln body n
  sed "s/starts the gate and re-dispatches this/re-runs §3's gate to green, then re-dispatches this/" \
    "$CADENCE" > "$F"
  ln="$(prose_gate_lines "$F" "concurrent (§3.5) — which mints T, re-runs §3's gate to green, then re-dispatches this")"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 4)"
  lacks "$body" "starts the gate and re-dispatches this round's panel together"
  # …and the pointer count is untouched, which is why the clause pin is needed
  n="$(_body_hits "$F" "$POINTER")"
  [ "$n" -eq 8 ]
}

@test "#1497 non-vacuity: dropping a plugin-repo-only qualifier reds its count" {
  local F="$BATS_TEST_TMPDIR/skill-unqualified.md" n
  awk 'BEGIN { done = 0 }
       done == 0 && index($0, "# plugin repos only — omit on any other stack") > 0 {
         sub(/[[:space:]]*# plugin repos only — omit on any other stack/, ""); done = 1 }
       { print }
       END { if (!done) { print "control: no qualifier matched" > "/dev/stderr"; exit 1 } }' \
    "$SKILL" > "$F"
  n="$(_body_hits "$F" '--gate-attest "$T" # plugin repos only — omit on any other stack')" || return 1
  [ "$n" -eq 1 ]
}

@test "#1497 non-vacuity: dropping property 1's CONDITION reds the step-2 pin" {
  # The licence-widening mutation: the opening phrase and the trailing warning
  # both survive it, so only a needle on the condition itself catches it.
  local F="$BATS_TEST_TMPDIR/skill-wide-licence.md" ln body
  # target ONE source line: the clause wraps, and sed is per line
  sed 's/stand in, but only where it is documented to outlive the turn \*and\*/stand in —/' \
    "$SKILL" > "$F"
  ln="$(prose_gate_lines "$F" '2. Start the gate out of band, so that it runs without blocking the panel')"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 42)"
  lacks "$body" 'may stand in, but only where it is documented to outlive the turn and re-invoke the session when it exits'
  # the opening and the warning are untouched, which is the point of the control
  contains "$body" 'it survives the turn that started it'
  contains "$body" 'verify that; never assume it'
}

@test "#1497 non-vacuity: recalibrating step 4's bound to SECONDS reds its pin" {
  # The parenthetical is the bound's only quantifier: 'seconds, not minutes'
  # makes a real full suite trip the signal-never-arrives arm every round, on a
  # green gate, while 'with a generous bound' still matches.
  local F="$BATS_TEST_TMPDIR/skill-short-bound.md" ln body
  sed 's/(a full suite runs minutes, not hours)/(a full suite runs seconds, not minutes)/' \
    "$SKILL" > "$F"
  ln="$(prose_gate_lines "$F" "4. Observe the gate's completion before consolidating")"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 18)"
  lacks "$body" "wait for step 2's signal, with a generous bound (a full suite runs minutes, not hours)"
  contains "$body" "wait for step 2's signal, with a generous bound"
}

@test "#1497 non-vacuity: deleting property 4's wrapper-pid QUALIFICATION reds its pin" {
  # Isolates the qualification from the requirement: the two needles holding
  # "stops the SUITE" survive this mutation, so only the extended needle catches
  # it — which is the gap round 5 reported.
  local F="$BATS_TEST_TMPDIR/skill-no-wrapper-note.md" ln body
  # one source line, since the clause wraps
  sed 's/easy mistake: the reference shape prints its \*wrapper.s\* pid, so a/easy mistake, so a/' \
    "$SKILL" > "$F"
  ln="$(prose_gate_lines "$F" '2. Start the gate out of band, so that it runs without blocking the panel')"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 42)"
  lacks "$body" "the reference shape prints its wrapper's pid, so a reproduction has to make the recorded handle reach the process actually running the suite"
  # the requirement half is untouched — that is what makes this control isolate
  contains "$body" 'it is killable — by a handle that stops the SUITE, not merely whatever launched it.'
}

@test "#1497 non-vacuity: demoting the reference to a RUNNER reds the shape pin" {
  # The over-claim three dimensions caught: run-headless.zsh cannot take the
  # gate, so calling it reusable sends a session to hand its suite to claude -p.
  local F="$BATS_TEST_TMPDIR/skill-runner.md" ln body
  # target ONE source line: the clause wraps after "**a shape reference,"
  sed 's/never a runner you hand the gate to\./reuse it directly./' \
    "$SKILL" > "$F"
  ln="$(prose_gate_lines "$F" '2. Start the gate out of band, so that it runs without blocking the panel')"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 42)"
  lacks "$body" 'a shape reference, never a runner you hand the gate to'
}

@test "#1497 non-vacuity: step 3 rewritten to wait for green reds the overlap pin" {
  # The subtlest regression of all: the seven steps survive, the banner
  # survives, and only the clause that says the panel does not wait is gone.
  local F="$BATS_TEST_TMPDIR/skill-step3-serial.md" ln body
  sed 's/that same tree, while the gate is still running\./that same tree, once the gate has come back green./' \
    "$SKILL" > "$F"
  ln="$(prose_gate_lines "$F" '3. Plan and dispatch the panel (the Each round panel step below) against')"
  [ -n "$ln" ]
  body="$(prose_window "$F" "$ln" 12)"
  lacks "$body" 'against that same tree, while the gate is still running'
}
