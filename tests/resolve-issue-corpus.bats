#!/usr/bin/env bats
#
# `tests/resolve-issue-corpus.bash` is load-bearing for six suites: it decides
# WHICH files a sweep of the resolve-issue skill reads. Get it wrong and the
# sweeps do not fail — they go quiet, which is the one failure mode this whole
# family of tests exists to prevent.
#
# WHY THIS FILE EXISTS. Every other shared helper in `tests/` has direct
# coverage — `assertions.bash` -> `assertions.bats`, `prose-lockstep.bash` ->
# `prose-lockstep.bats`, `roster.bash` self-tested via
# `no-inert-bracket-assertions.bats` — and
# `tests/README.md` states the convention. This helper shipped without it.
# Concretely, the roster tripwire that six suites cite as the reason a sixth
# `reference/*.md` file cannot silently drop out of their haystack had NOTHING
# driving its failure branch: deleting the comparison, or flipping its
# `return 1` to `return 0`, left the entire suite green, because `reference/`
# happens to equal the declared roster today. (Filed as #1546 and deliberately
# parked during the review loop under *A fix pass subtracts* rule 4, then
# un-parked by an explicit human decision.)
#
# SHAPE. Every case drives the helpers over a SYNTHETIC tree under
# `$BATS_TEST_TMPDIR`, never the repo: a control that mutated the real
# `reference/` directory would leave a decoy behind for the six suites that read
# it for real. The one case that RUNS the helpers against the repo asserts only
# that the shipped roster and the shipped directory agree, which is the invariant
# the helper is there to hold. (The write-location case reads $REPO_ROOT too,
# read-only, to assert nothing landed there.)

bats_require_minimum_version 1.5.0

load assertions

load resolve-issue-corpus

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # The declared roster, transcribed ONCE here so a change to `ordered` has to be
  # made deliberately in two places rather than silently in one. This is the only
  # copy outside the helper, and it is what makes the "roster changed" case below
  # a real assertion rather than a tautology.
  EXPECTED_REFS=(review-loop.md residue.md promotion.md escalation.md interactive.md sequential.md telemetry.md)
  # #2055 split review-loop.md into shards under reference/review-loop/; the
  # shard roster is transcribed once here for the same reason, in the index's
  # read order.
  EXPECTED_SHARDS=(core.md scope-block.md step-1-panel.md step-2-invocation.md
    exit-2-stale-findings.md exit-20-awaiting-fix.md delta-rounds.md
    topic-panels.md decided-pass.md risk-pass.md carry.md subagents.md
    briefs/panel.md briefs/fix.md briefs/decide.md briefs/risk.md)
  # #2056 split residue.md into reference/residue/, in that index's read order.
  EXPECTED_RESIDUE_SHARDS=(branch.md risk-threshold.md step-1-plan.md steps-2-3.md
    steps-4-5.md condition-2-removed.md)
  # #2057 split promotion.md into reference/promotion/, in that index's read order.
  EXPECTED_PROMOTION_SHARDS=(gate.md step-3-select.md step-4-sub-loop.md
    step-7-terminal.md step-8-status-files.md)
}

# Build a synthetic skill tree at $1 holding SKILL.md plus the named reference
# files (defaults to the declared roster) and, always, the declared review-loop
# shards (#2055), residue shards (#2056) and promotion shards (#2057) — so a
# case about the top-level roster is not tripped by a shard tripwire instead.
_synth() {
  local root="$1"; shift
  local base="$root/development/skills/resolve-issue"
  mkdir -p "$base/reference/review-loop/briefs"
  mkdir -p "$base/reference/residue"
  mkdir -p "$base/reference/promotion"
  printf 'conductor\n' > "$base/SKILL.md"
  local f
  if [ "$#" -eq 0 ]; then set -- "${EXPECTED_REFS[@]}"; fi
  for f in "$@"; do printf 'body of %s\n' "$f" > "$base/reference/$f"; done
  for f in "${EXPECTED_SHARDS[@]}"; do printf 'body of %s\n' "$f" > "$base/reference/review-loop/$f"; done
  for f in "${EXPECTED_RESIDUE_SHARDS[@]}"; do printf 'body of %s\n' "$f" > "$base/reference/residue/$f"; done
  for f in "${EXPECTED_PROMOTION_SHARDS[@]}"; do printf 'body of %s\n' "$f" > "$base/reference/promotion/$f"; done
}

# --- the roster ---------------------------------------------------------------

@test "#1546 resolve_issue_files emits the conductor first, then the roster in declared order" {
  local root="$BATS_TEST_TMPDIR/ok"
  _synth "$root"
  run -0 resolve_issue_files "$root"
  local base="$root/development/skills/resolve-issue"
  local want
  local -a shard_paths residue_paths promotion_paths
  local s
  for s in "${EXPECTED_SHARDS[@]}"; do shard_paths+=("$base/reference/review-loop/$s"); done
  for s in "${EXPECTED_RESIDUE_SHARDS[@]}"; do residue_paths+=("$base/reference/residue/$s"); done
  for s in "${EXPECTED_PROMOTION_SHARDS[@]}"; do promotion_paths+=("$base/reference/promotion/$s"); done
  want="$(printf '%s\n' "$base/SKILL.md" \
    "$base/reference/review-loop.md" \
    "${shard_paths[@]}" \
    "$base/reference/residue.md" \
    "${residue_paths[@]}" \
    "$base/reference/promotion.md" \
    "${promotion_paths[@]}" \
    "$base/reference/escalation.md" \
    "$base/reference/interactive.md" \
    "$base/reference/sequential.md" \
    "$base/reference/telemetry.md")"
  [ "$output" = "$want" ]
}

@test "#1546 an UNDECLARED reference file makes the roster refuse, naming both sets" {
  # THE tripwire six suites lean on. Before this file, nothing drove it.
  local root="$BATS_TEST_TMPDIR/extra"
  _synth "$root"
  printf 'notes\n' > "$root/development/skills/resolve-issue/reference/notes.md"
  run -1 resolve_issue_files "$root"
  contains "$output" "notes.md"
  contains "$output" "update"
}

@test "#2055 an UNDECLARED review-loop shard, at any depth, makes the roster refuse" {
  local root="$BATS_TEST_TMPDIR/extra-shard"
  _synth "$root"
  mkdir -p "$root/development/skills/resolve-issue/reference/review-loop/deep/er"
  printf 'notes\n' > "$root/development/skills/resolve-issue/reference/review-loop/deep/er/notes.md"
  run -1 resolve_issue_files "$root"
  contains "$output" "deep/er/notes.md"
  contains "$output" "shard roster"
}

@test "#2055 a MISSING declared review-loop shard makes the roster refuse" {
  local root="$BATS_TEST_TMPDIR/short-shard"
  _synth "$root"
  rm "$root/development/skills/resolve-issue/reference/review-loop/briefs/risk.md"
  run -1 resolve_issue_files "$root"
  contains "$output" "briefs/risk.md"
}

@test "#2056 an UNDECLARED residue shard makes the roster refuse, naming the residue roster" {
  local root="$BATS_TEST_TMPDIR/extra-residue"
  _synth "$root"
  printf 'notes\n' > "$root/development/skills/resolve-issue/reference/residue/notes.md"
  run -1 resolve_issue_files "$root"
  contains "$output" "reference/residue/ holds"
  contains "$output" "notes.md"
  contains "$output" '`residue_shards`'
}

@test "#2056 a MISSING declared residue shard makes the roster refuse" {
  local root="$BATS_TEST_TMPDIR/short-residue"
  _synth "$root"
  rm "$root/development/skills/resolve-issue/reference/residue/condition-2-removed.md"
  run -1 resolve_issue_files "$root"
  contains "$output" "condition-2-removed.md"
}

@test "#2057 an UNDECLARED promotion shard makes the roster refuse, naming the promotion roster" {
  local root="$BATS_TEST_TMPDIR/extra-promotion"
  _synth "$root"
  printf 'notes\n' > "$root/development/skills/resolve-issue/reference/promotion/notes.md"
  run -1 resolve_issue_files "$root"
  contains "$output" "reference/promotion/ holds"
  contains "$output" "notes.md"
  contains "$output" '`promotion_shards`'
}

@test "#2057 a MISSING declared promotion shard makes the roster refuse" {
  local root="$BATS_TEST_TMPDIR/short-promotion"
  _synth "$root"
  rm "$root/development/skills/resolve-issue/reference/promotion/step-7-terminal.md"
  run -1 resolve_issue_files "$root"
  contains "$output" "step-7-terminal.md"
}

@test "#1546 a MISSING declared reference file makes the roster refuse" {
  local root="$BATS_TEST_TMPDIR/short"
  _synth "$root" review-loop.md residue.md promotion.md escalation.md
  run -1 resolve_issue_files "$root"
  contains "$output" "interactive.md"
}

@test "#1546 an empty reference/ makes the roster refuse rather than emitting the conductor alone" {
  # The dangerous direction: a roster that quietly shrinks to one file would let
  # every corpus sweep pass over almost nothing.
  local root="$BATS_TEST_TMPDIR/none"
  mkdir -p "$root/development/skills/resolve-issue/reference"
  printf 'conductor\n' > "$root/development/skills/resolve-issue/SKILL.md"
  run -1 resolve_issue_files "$root"
}

@test "#1546 the SHIPPED roster and the SHIPPED reference/ directory agree" {
  # The one case that RUNS the helpers against the repo. If this reds, `ordered`
  # in resolve-issue-corpus.bash AND `EXPECTED_REFS` above both need updating in
  # the same PR as the new file. The count is DERIVED from EXPECTED_REFS rather
  # than transcribed a third time: a sixth reference file correctly added to both
  # rosters must not red here with an opaque count mismatch.
  run -0 resolve_issue_files "$REPO_ROOT"
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq "$(( ${#EXPECTED_REFS[@]} + ${#EXPECTED_SHARDS[@]} + ${#EXPECTED_RESIDUE_SHARDS[@]} + ${#EXPECTED_PROMOTION_SHARDS[@]} + 1 ))" ]
}

# --- the corpus ---------------------------------------------------------------

@test "#1546 resolve_issue_corpus concatenates the members in order, one blank line between" {
  local root="$BATS_TEST_TMPDIR/cat"
  _synth "$root"
  local out="$BATS_TEST_TMPDIR/corpus.md"
  run -0 resolve_issue_corpus "$root" "$out"
  [ "$output" = "$out" ]
  # `cat member; printf '\n'` per member, so each 1-line member contributes its
  # line plus a blank separator.
  # The #2055 shards follow the index, each with its own separator.
  # The #2056 residue shards and the #2057 promotion shards follow theirs the
  # same way.
  local want shard_bodies="" residue_bodies="" promotion_bodies="" s
  for s in "${EXPECTED_SHARDS[@]}"; do shard_bodies+="body of $s"$'\n\n'; done
  for s in "${EXPECTED_RESIDUE_SHARDS[@]}"; do residue_bodies+="body of $s"$'\n\n'; done
  for s in "${EXPECTED_PROMOTION_SHARDS[@]}"; do promotion_bodies+="body of $s"$'\n\n'; done
  want="$(printf 'conductor\n\nbody of review-loop.md\n\n%sbody of residue.md\n\n%sbody of promotion.md\n\n%sbody of escalation.md\n\nbody of interactive.md\n\nbody of sequential.md\n\nbody of telemetry.md\n' "$shard_bodies" "$residue_bodies" "$promotion_bodies")"
  [ "$(cat "$out")" = "$want" ]
}

@test "#1546 members are never joined into one LINE, and the separator does NOT survive flattening" {
  # Both halves matter, and writing this test is what established the second.
  #
  # (a) Line-oriented sweeps — prose_gate_lines and friends — rely on a member's
  #     last line never being the same LINE as the next member's first. The
  #     `printf '\n'` after each member guarantees that even when the member's
  #     last byte is not itself a newline.
  # (b) The separator does NOT hold at paragraph level: the flattening idiom
  #     these suites use, `tr '\n' ' ' | tr -s ' '`, squeezes the blank line to a
  #     single space, so a FLATTENED needle CAN match across a member boundary.
  #     The helper's comment used to claim the opposite. Do not replace that
  #     with a second reassurance: nothing restores locality above the line
  #     level, the byte-freeze in verify-reference-move.zsh pins only that a
  #     chunk MOVED verbatim and is indifferent to a window crossing a member
  #     boundary, and the three windowed corpus consumers are sound only by
  #     current file lengths — the margins are measured at the separator in
  #     resolve-issue-corpus.bash. Anchor a locality sweep at the per-file path.
  local root="$BATS_TEST_TMPDIR/sep"
  _synth "$root"
  local out="$BATS_TEST_TMPDIR/sep.md"
  resolve_issue_corpus "$root" "$out" >/dev/null

  # (a) no single line carries text from two members
  run -1 grep -q 'conductor.*body of review-loop.md' "$out"

  # (b) flattened, they DO run together — the documented limitation
  grep -q 'conductor body of review-loop.md' <<< "$(tr '\n' ' ' < "$out" | tr -s ' ')"
}

@test "#1546 a member deleted between the listing and the read makes the corpus refuse" {
  # The missing-file guard inside the consumer loop. It cannot be reached
  # through resolve_issue_files (which globs what exists), so it needs a member
  # that vanishes after the roster is built — a real state under a concurrent
  # checkout, and the guard's only reachable input.
  local root="$BATS_TEST_TMPDIR/vanish"
  _synth "$root"
  local base="$root/development/skills/resolve-issue"
  # Make SKILL.md unreadable-as-a-file by replacing it with a directory: the
  # roster still emits its path, the consumer's `[ -f ]` still refuses.
  rm "$base/SKILL.md"
  mkdir "$base/SKILL.md"
  run -1 resolve_issue_corpus "$root" "$BATS_TEST_TMPDIR/vanish.md"
  contains "$output" "missing skill file"
}

@test "#1546 a refusing roster refuses the corpus too, rather than yielding an empty haystack" {
  # The status-observation the helper's own comment is about: read through
  # `< <(...)` the producer's failure is invisible, and every sweep built on the
  # result then passes over nothing.
  local root="$BATS_TEST_TMPDIR/refuse"
  _synth "$root"
  printf 'notes\n' > "$root/development/skills/resolve-issue/reference/notes.md"
  run -1 resolve_issue_corpus "$root" "$BATS_TEST_TMPDIR/refuse.md"
}

@test "#1546 the corpus is written where the caller asked, and nothing is written into the repo" {
  # `$BATS_TEST_TMPDIR` is not incidental: a file landing under the worktree
  # changes the tree identity the review loop attests (#981), so every corpus
  # consumer must be able to rely on this.
  local root="$BATS_TEST_TMPDIR/where"
  _synth "$root"
  local out="$BATS_TEST_TMPDIR/explicit-name.md"
  resolve_issue_corpus "$root" "$out" >/dev/null
  [ -f "$out" ]
  [ ! -e "$REPO_ROOT/resolve-issue-corpus.md" ]
  [ ! -e "$REPO_ROOT/development/skills/resolve-issue/resolve-issue-corpus.md" ]
}
