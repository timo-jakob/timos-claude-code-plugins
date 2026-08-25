#!/usr/bin/env bash
#
# The resolve-issue skill is no longer ONE file (#1503). It is a conductor —
# `development/skills/resolve-issue/SKILL.md`, which keeps each step's
# invocation contract, exit-code table and a pointer — plus on-demand
# `reference/*.md` files carrying the procedure behind each branch. The move was
# byte-preserving per chunk: each `<!-- moved: … -->` block is byte-identical to
# the text it was carved from, which `scripts/verify-reference-move.zsh` proves.
# (It does not prove conservation — that gap is tracked as #1548.)
#
# That splits the sweeps in this suite into two kinds, and they need different
# targets:
#
#   - a sweep that pins WHERE a sentence lives ("the conductor's §3 gate step
#     points at the boundary", "the round protocol states the red-gate arm")
#     must read the ONE file that section lives in. Use the per-file paths.
#     Pointing such a sweep at the corpus would let the sentence migrate between
#     conductor and reference without reddening anything, which is precisely the
#     locality these tests exist to hold.
#
#   - a sweep that COUNTS sites across the skill, or asserts a roster of them
#     ("exactly eight sites point at the cadence", "every flag placeholder
#     resolves to the one T"), must read all of them. Before #1503 that was one
#     file; now it is the corpus. Pointing such a sweep at the conductor alone
#     silently drops every site that moved, and the count "passes" by having
#     stopped looking.
#
# The corpus is a CONCATENATION: the conductor first, then the reference files
# in a FIXED declared order. That order does NOT reproduce pre-move document
# order and cannot: interactive.md holds two chunks (the §0a remediation and the
# interactive extension) that were not adjacent in the pre-move file, so no
# file ordering could interleave them correctly. Order-sensitive assertions
# therefore must NOT use the corpus — use the per-file paths, exactly as the
# count-vs-locality rule above already says. Within any one member, order is of
# course preserved.
#
# It is written to a caller-supplied path (use `$BATS_TEST_TMPDIR`), never into
# the repo: a file landing under the worktree would change the tree identity the
# review loop attests (#981).

# Print the skill's files, one per line: the conductor, then the reference files.
#
# The reference half is DERIVED from the directory, with the declared list kept
# only as an expected-set tripwire. A transcribed roster is the shape this
# repo's own "position guards need a repo-wide invariant" rule (#936/#1188)
# forbids: add a sixth reference file and every corpus sweep in five suites
# would keep passing over a haystack that no longer contains it — the count
# "passing" by having stopped looking, which is the exact failure the header
# above says the corpus exists to prevent.
resolve_issue_files() {
  local base="$1/development/skills/resolve-issue"
  local -a found
  local f

  # ONE roster, in declared order — review-loop first because it is the branch
  # every run takes, then the terminals, then the interactive procedures. This
  # same array is both what the tripwire compares against AND what is emitted, so
  # there is no second transcription for a maintainer to update in isolation.
  # (An earlier cut had a separate `expected` list: satisfying the tripwire by
  # editing only that one left the emitted list six paths long and every corpus
  # sweep silently blind to the new file — the "count passing by having stopped
  # looking" failure this derivation exists to prevent, restored one indirection
  # later.)
  local -a ordered
  ordered=(review-loop.md residue.md promotion.md escalation.md interactive.md)

  for f in "$base"/reference/*.md; do
    [ -e "$f" ] || continue
    found+=("${f##*/}")
  done

  local got_s exp_s
  got_s="$(printf '%s\n' "${found[@]}" | sort | tr '\n' ' ')"
  exp_s="$(printf '%s\n' "${ordered[@]}" | sort | tr '\n' ' ')"
  if [ "$got_s" != "$exp_s" ]; then
    printf 'resolve_issue_files: reference/ holds [%s] but the roster declares [%s] — update `ordered` in resolve-issue-corpus.bash in the same PR\n' \
      "$got_s" "$exp_s" >&2
    return 1
  fi

  printf '%s\n' "$base/SKILL.md"
  for f in "${ordered[@]}"; do
    printf '%s\n' "$base/reference/$f"
  done
}

# Build the corpus at $2 and echo that path. Returns non-zero — loudly — if any
# member is missing, so a renamed or deleted reference file fails the sweep that
# depends on it instead of quietly shrinking the haystack.
resolve_issue_corpus() {
  local root="$1" out="$2" f
  local -a files
  local listing
  # Captured with its STATUS observed, not read through `< <(...)`: a process
  # substitution hides the producer's exit code, and `resolve_issue_files` now
  # returns 1 — printing nothing — whenever `reference/` and the roster disagree.
  # Read blindly, that path yields an empty corpus and a silent pass. Any new
  # consumer of this helper needs the same discipline.
  listing="$(resolve_issue_files "$root")" || return 1
  while IFS= read -r f; do [ -n "$f" ] || continue; files+=("$f"); done <<< "$listing"

  # No count guard here on purpose: any figure derived from the same producer is
  # equal to `${#files[@]}` by construction and can never fire. The roster's own
  # `got_s != exp_s` tripwire, and the `|| return 1` above, are what do the work.

  : > "$out" || return 1
  for f in "${files[@]}"; do
    if [ ! -f "$f" ]; then
      printf 'resolve_issue_corpus: missing skill file: %s\n' "$f" >&2
      return 1
    fi
    cat "$f" >> "$out" || return 1
    # A newline after every member, so a member's last line and the next
    # member's first are never the SAME LINE — which is what line-oriented
    # sweeps (prose_gate_lines and friends) rely on, and it holds even for a
    # member whose last byte is not itself a newline.
    #
    # It does NOT separate them at PARAGRAPH level: the flattening these suites
    # use is `tr '\n' ' ' | tr -s ' '`, which squeezes the blank line to a single
    # space, so a FLATTENED needle can still match across a member boundary.
    # Both halves are pinned in tests/resolve-issue-corpus.bats.
    #
    # Nothing restores locality above the line level, and in particular NEITHER
    # rule at the top of this file describes how the corpus is consumed today.
    #
    # The count-vs-locality rule: `prose_window` is flattened and takes +/-span
    # lines around its gate, and round-boundary-concurrency.bats,
    # round-boundary-wait.bats and fix-pass-subtracts.bats all run windowed
    # assertions over `$SKILL` = the corpus. `prose_window` is SYMMETRIC, so the
    # soundness condition is two-directional: every anchor must sit further than
    # its own span from BOTH ends of its member. The binding case is the one
    # against a member's START, not its end, and it is far tighter than it looks:
    # round-boundary-concurrency.bats's `2. Start the gate out of band` anchor is
    # reference/review-loop.md:44 with span 42, which lands at corpus line 1434
    # with `lo` = 1392 while the member itself begins at 1391 — a ONE-line
    # margin, and what it would spill into is the CONDUCTOR's tail. (The tightest
    # end-of-member margin is 10 lines: fix-pass-subtracts.bats's `A fix pass
    # subtracts (#1496)` at review-loop.md:939, span 80, in a 1029-line member.
    # escalation.md is only 71 lines — shorter than the largest span in use, the
    # 80 in fix-pass-subtracts.bats — so a window that size anchored anywhere in
    # it necessarily spills into both neighbours; smaller spans spill only within
    # `span` lines of an edge.) I measured all of those rather than reasoning
    # them. They are accidents of current file lengths, not a mechanism, and the
    # two thresholds are one line apart: delete TWO lines from review-loop.md's
    # preamble and the span-42 window's low bound reaches the blank separator
    # (which the flattening squeezes away, so nothing is read yet); delete THREE
    # and it starts reading the conductor's last lines, where its `contains`
    # needles can pass on a file the assertion was never about. Anchor a locality
    # sweep at the per-file path.
    #
    # The order rule reads as an absolute prohibition and is likewise not what
    # the tree does: round-boundary-concurrency.bats pins the seven-step ordering
    # by comparing `prose_gate_lines` line numbers across the corpus. That holds
    # only because every endpoint happens to land in review-loop.md. A
    # cross-member ordering pin would be meaningless — the declared file order
    # reproduces no document order, as the paragraph above explains.
    printf '\n' >> "$out"
  done
  printf '%s\n' "$out"
}
