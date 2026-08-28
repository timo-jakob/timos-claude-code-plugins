#!/usr/bin/env bats
#
# `development/skills/resolve-issue/scripts/verify-reference-move.zsh` is the gate
# the whole #1503 carve-out rests on: it is what lets a reviewer accept ~2 500
# moved lines as MOVED rather than re-read them as new prose, and it is what
# stops a moved chunk drifting between reference files later. Its exit-code table
# (0 / 1 / 2) is therefore a contract, and every fail-closed branch in it is
# load-bearing.
#
# WHY THIS FILE EXISTS. Before it, the script's only coverage was two tests in
# `tests/resolve-issue-conductor-budget.bats` — exit 0 on the real tree, exit 1
# on one mutated chunk. Exit 2 was never asserted, and every guard the review
# loop added to the script over four rounds could be deleted with the suite
# still green. Each of those exists because a review round named a way the gate
# could report success having verified less than it claimed. (Filed as #1547 and
# deliberately parked during the review loop under *A fix pass subtracts* rule 4
# — a new fixture family is not something a fix pass may add — then un-parked by
# an explicit human decision.)
#
# WHAT THIS FILE DOES AND DOES NOT REACH. **The lists below are POSITIVE: what
# they name really is driven here. They are not exhaustive in either direction,
# so a branch's absence from them means "not recorded", never "not pinned" —
# grep the suite before concluding anything from a silence.**
#
# This block used to claim the converse — "every fail-closed branch is driven
# except the ones named below" — and that universal was falsified by its own
# suite four times over as the script grew guards: each new arm made the claim
# false until someone remembered to extend the exception list, and each extension
# was itself a restatement that could go stale. A positive, non-exhaustive
# inventory cannot rot that way: adding a guard leaves it merely incomplete
# rather than actively wrong. Do not re-tighten it into a closure claim either —
# "a branch it does not name is not driven" is false today (`--help` and the
# byte-identical/summary branch are both driven and both unlisted), and it fails
# in the same shape, just in the safe direction.
#
# The NOT-driven paragraphs below are kept, but as **annotations** — they explain
# why particular unpinned branches are worth knowing about (and, for #1551, what
# is parked). They are not a complete enumeration of everything unpinned, and
# nothing should be inferred from a branch's absence from them.
#
# Branches are cited by their CODE, never
# by line number: an earlier cut of this block pinned `script :279` / `:196` and
# both rotted inside the very round that wrote them, which is what the repo's
# anchor-by-content rule (#1189) is about. Counts are likewise not restated as
# numerals — a numeral goes stale in the same edit that adds the arm.
#
# Driven here: an unknown argument; both empty-flag guards; a `--repo` that is
# not a directory; a `--base` that is not a commit; a `--base` whose commit has
# no SKILL.md (`could not read`); the script-relative `--repo` DEFAULT;
# `--quiet`'s suppression; a chunk whose bytes DIFFER, with its first-difference
# report; the empty-chunk refusal; a missing reference file; a chunk whose
# sentinel PAIR is gone (`no <!-- moved: NAME --> block`); the stray-sentinel
# sweep including a digit-bearing name; the duplicate-sentinel check; the
# separate reporting of chunk failures vs sentinel problems; and (#1582) the
# split-span sweep arms it drives — the halves out of ORDER, a split sentinel
# MISSING, and a split sentinel DUPLICATED (the last of which the stray sweep
# cannot see, since it greps only the opening form) — plus the inherited
# GIT_DIR/GIT_WORK_TREE scrub, driven under both names together and under
# GIT_DIR alone; and (#1588) BOTH halves of the malformed-manifest-row guard —
# a row whose REF_FILE field is removed (too few fields, refused), and a row
# carrying a FOURTH tab (the tolerance half, which must NOT be refused, and is
# what pins `< 3` rather than `!= 3`).
#
# The FOURTH-tab case ALSO drives `could not locate the source range`, which it
# asserts by name: its mutated row's LAST_LINE anchor no longer resolves in the
# pinned commit, so deleting the `extract_range` guard reds it. That branch was
# listed here as deliberately undriven until #1588; it is now pinned incidentally
# rather than by a case written for it, so #1551 keeps only whatever it wants a
# dedicated driver for. (The old rationale for not driving it — that `--base
# HEAD` would resolve every anchor because HEAD was still the pre-move commit —
# no longer holds either: #1503 has merged, and HEAD's SKILL.md carries none of
# the manifest's anchor lines.)
#
# GIT_DIR is the only name driven alone, and deliberately: this script's git
# calls are `rev-parse --verify` and `git show`, both pure object-DB reads that a
# work-tree override cannot redirect, so a GIT_WORK_TREE-alone arm PASSES with
# `GIT_WORK_TREE` deleted from the `unset` — it read as coverage and pinned
# nothing (#1588 measured that and replaced it). `GIT_WORK_TREE`/`GIT_INDEX_FILE`
# remain in the scrub as defence in depth and are pinned by NO case here; do not
# read their presence in the `unset` as tested. The `review-dispatch.zsh` twin
# runs work-tree-sensitive commands, so its GIT_WORK_TREE arm does discriminate.
#
# The #1582 split-anchor ADJACENCY arm is driven too, in both directions — an
# anchor MOVED INWARD (which migrates original conductor prose into the
# unverified gap while every per-chunk byte comparison still passes) and a split
# row REMOVED from the manifest. Both use a `sed`-mutated copy of the script,
# because the anchors are read out of the MANIFEST: an earlier cut hardcoded them
# as literals and compared them against the pinned, immutable `$pre`, which made
# the whole assertion a constant that could never fire on the one edit it exists
# to catch. Driving it is what proved that; the map said "driven by nothing here"
# for exactly as long as the check was vacuous.
#
# NOT driven — the empty-MANIFEST guard, and deleting it ships green today: the
# `(( ${#MANIFEST} == 0 ))` guard. Its driver needs a `sed`-mutated copy of the
# script — a fixture family *A fix pass subtracts* rule 4 forbids a fix pass from
# adding. Be precise about what its absence costs, because the earlier wording
# here was wrong and #1551 carries the correction: an emptied MANIFEST against
# the REAL reference tree is still caught, by the stray-sentinel sweep, which
# finds eight sentinels no manifest row declares and exits 1 — measured, not
# reasoned. The guard is the second net for the case where BOTH were lost
# together (an emptied manifest AND a reference tree carrying no sentinels),
# which is the only state that would otherwise reach `all 0 declared chunks are
# byte-identical` at exit 0.
#
# NOT driven — the status-read arms #1588 added, and deleting any of them
# ships green today. Called out individually because each one's ABSENCE is
# expensive to rediscover, not because this list is exhaustive (it is not — see
# the framing above):
#   * `FAIL <name>: could not normalise the source chunk` and its `moved chunk`
#     twin — the `|| { … }` on each `strip_blanks` substitution. Their driver
#     needs a mutated copy of the script whose `strip_blanks` fails (an `awk`
#     that is not on PATH, say). Without them a dead `awk` returns an empty
#     string and the empty-chunk refusal below reports `empty chunk after
#     normalisation` — a verdict about a chunk's CONTENT from a normalisation
#     that never ran.
#   * `FAIL: could not sweep <REF_DIR> for sentinels (grep exit N)` and
#     `FAIL: could not normalise the sentinel sweep output`. Their driver needs
#     an unreadable subtree under `reference/` (and a root-skip guard, since root
#     reads it anyway), or a mutated copy. Without them a failed or partial walk
#     leaves the undeclared/duplicated-sentinel invariant vacuous rather than
#     satisfied — it passes by having stopped looking.
#   * two arms of the split-span ADJACENCY block: `FAIL: the split anchors named
#     by the manifest are not both present in <base>:<path>` (its `awk_rc`
#     capture — the anchor-moved-inward case rewrites the head anchor to a line
#     that IS present in the pinned commit, so that mutant reaches the
#     `no longer adjacent` arm instead and never this one), and the
#     `(( ${#mrow_tabs} >= 3 )) || continue` malformed-row skip #1588 added
#     there (both malformed-row mutants corrupt a row this block's `case`
#     ignores). Deleting the `awk_rc` capture is the costly one: an `awk` exiting
#     3 then leaves `between` empty, the `[[ -n "$between" ]]` arm passes, and
#     the adjacency invariant reports success having located neither anchor.
# Every one of them is worth driving; none is driven here, and this block is the
# only place that says so. Named rather than counted, for the reason the header
# above gives about numerals.
#
# The `verified + chunk_failures != ${#MANIFEST}` reconciliation is in neither
# list: every loop path increments exactly one counter before `continue`, so it
# is unreachable by construction — defence-in-depth against a future edit, not a
# branch a test can drive.
#
# SHAPE. Two kinds of case, and the split is what keeps the file fast:
#
#   * USAGE errors (exit 2) need no repository at all — the script rejects them
#     during flag parsing, before any git work. They are pure and instant.
#   * SENTINEL / CHUNK behaviour needs a tree whose declared chunks all
#     resolve, because the MANIFEST is embedded in the script and pinned to the
#     real pre-move anchors. So those cases stage a FAKE tree: a `.git` GITFILE
#     pointing at the real admin dir (O(1) — never `cp -R` of the object store,
#     which on a `fetch-depth: 0` CI checkout copies the whole history), plus a
#     copy of the real `reference/` tree, which is then mutated per case.
#
# Every case asserts the DIAGNOSTIC as well as the status, because exit 1 is the
# script's code for both "a chunk differs" and "an input could not be read" — a
# bare `[ "$status" -eq 1 ]` is satisfied by a staging failure and would report
# green while proving nothing.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_DIR="$REPO_ROOT/development/skills/resolve-issue"
  VERIFY="$SKILL_DIR/scripts/verify-reference-move.zsh"
  REF_DIR="$SKILL_DIR/reference"

  # Single-sourced from the script, exactly as tests/resolve-issue-conductor-budget.bats
  # does — a re-pin must not be able to leave the two disagreeing.
  PRE_MOVE_SHA="$(sed -n 's/^typeset -r PRE_MOVE_DEFAULT=\([0-9a-f]\{40\}\)$/\1/p' "$VERIFY")"
  [ -n "$PRE_MOVE_SHA" ] || {
    echo "could not read PRE_MOVE_DEFAULT out of $VERIFY" >&2; return 1; }
}

# A fake tree whose reference/ is a mutable copy of the real one and whose git
# objects are the real ones, reached through a gitfile. Echoes the tree path.
_fake_tree() {
  local fake="$BATS_TEST_TMPDIR/fake-$1"
  mkdir -p "$fake/development/skills/resolve-issue"
  cp -R "$REF_DIR" "$fake/development/skills/resolve-issue/reference"
  printf 'gitdir: %s\n' "$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)" > "$fake/.git"
  # The staging must be sound before any case builds on it, or a broken fixture
  # would be indistinguishable from the defect each case is trying to show.
  git -C "$fake" rev-parse --absolute-git-dir >/dev/null
  printf '%s\n' "$fake"
}

# Skip only for a genuinely shallow clone — never for a stale pin, which must
# fail loudly. Same rule as the sibling suite.
_require_pre_move_commit() {
  git -C "$REPO_ROOT" cat-file -e "$PRE_MOVE_SHA^{commit}" 2>/dev/null && return 0
  if [ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
    skip "pre-move commit $PRE_MOVE_SHA is absent from this SHALLOW clone"
  fi
  echo "PRE_MOVE_SHA ($PRE_MOVE_SHA) no longer resolves in a full clone —" >&2
  echo "re-pin PRE_MOVE_DEFAULT in $VERIFY." >&2
  return 1
}

# The 1-based line number of the FIRST line of $2 (a fixed string) in file $1.
# Prints nothing and returns 1 when the needle is absent, so a caller's
# assignment fails loudly under bats' errexit rather than comparing an empty
# string as if it were a line number.
#
# Factored for the #1582 gap-prose family (#1588): those tests' needles were
# whole-file greps, so the entire reviewer-path rule could be relocated BELOW
# the protocol it governs — out of the unverified gap and past step 1 — with
# every one of them still matching. Bracketing a representative needle between
# the head-close and tail-open sentinels is what pins it in place.
# `-x` matches the needle as a WHOLE LINE. The two sentinels need it — not
# because of anything in THIS file, but because of the file being grepped:
# `reference/review-loop.md`'s preamble quotes BOTH sentinels inline inside
# backticks on one line, in the sentence explaining the gap. A substring search
# therefore returns that one preamble line for both bounds, and every comparison
# built on them is made against the wrong pair. (`extract_chunk` and the
# stray-sentinel sweep match at column 0 for the same reason.)
_gap_line() {  # [-x] $1 = file, $2 = fixed-string needle
  local mode=-F
  if [ "$1" = "-x" ]; then mode=-xF; shift; fi
  [ "$#" -eq 2 ] || { printf '_gap_line: needs [-x] file, needle\n' >&2; return 2; }
  local n
  n=$(grep -n "$mode" -- "$2" "$1" | head -1 | cut -d: -f1)
  [ -n "$n" ] || { printf '_gap_line: needle not found: %s\n' "$2" >&2; return 1; }
  printf '%s\n' "$n"
}

# The whitespace-normalised text of the #1582 unverified gap ALONE — strictly
# between the head-close and tail-open sentinels.
#
# This is what the gap-prose needles run against, and it collapses presence and
# position into ONE assertion (#1588). The earlier cut ran each needle over the
# whole file and then bracketed a single *representative* anchor, which is weaker
# than it looks two ways: the anchor generally sat in a different sub-block from
# the needles, so moving the asserted paragraph out of the gap left every needle
# matching and the anchor unmoved — suite green, which is precisely the
# relocation these checks exist to catch; and several anchors occur twice inside
# the gap, so deleting the earlier sub-block silently re-anchored on the later
# one. Grepping the gap's own text has neither failure mode, and needs no anchor.
_gap_text() {  # $1 = file
  [ "$#" -eq 1 ] || { printf '_gap_text: needs a file\n' >&2; return 2; }
  local hc to
  hc="$(_gap_line -x "$1" '<!-- /moved: round-protocol-head -->')" || return 1
  to="$(_gap_line -x "$1" '<!-- moved: round-protocol-tail -->')" || return 1
  # STRICTLY greater by more than one, not merely greater: on an EMPTY gap
  # (`to == hc + 1`) the `sed` range's end precedes its start, and POSIX/GNU/BSD
  # sed all then select exactly ONE line — line `hc+1`, which in that state is
  # the tail sentinel itself. `_gap_text` would return that, non-empty, and every
  # caller's `[ -n "$flat" ]` would pass over a gap holding nothing at all.
  [ "$to" -gt "$((hc + 1))" ] || {
    printf '_gap_text: the gap between the sentinels is empty or inverted (head close %s, tail open %s)\n' \
      "$hc" "$to" >&2
    return 1
  }
  # The blockquote marker is stripped while the text is still LINE-ORIENTED, and
  # only at the start of a line. Doing it after the flatten (`sed 's/> //g'` over
  # the whole string) also rewrites the `-> ` arrows in the both-spellings
  # examples to `-`, so a needle written for that arrow — the load-bearing
  # rendering of "Both, not either" — could only ever be written wrong.
  sed -n "$((hc + 1)),$((to - 1))p" "$1" | sed 's/^> \{0,1\}//' | tr '\n' ' ' | tr -s ' '
}

# --- usage errors: exit 2, no repository needed ------------------------------

@test "#1547 an unknown argument exits 2 and names it" {
  run -2 zsh "$VERIFY" --bogus
  contains "$output" "unknown argument: --bogus"
}

@test "#1547 --base with an EMPTY value exits 2 rather than reading the git index" {
  # An empty --base made `git show ":<path>"` read the INDEX — git's staged-blob
  # syntax — and report success against whatever happened to be staged.
  run -2 zsh "$VERIFY" --base ''
  contains "$output" "--base needs a non-empty value"
}

@test "#1547 --repo with an EMPTY value exits 2 rather than falling back to the real tree" {
  # An empty --repo used to fall through to the script-relative default and
  # verify the REAL tree while the caller believed it verified the one it named.
  run -2 zsh "$VERIFY" --repo ''
  contains "$output" "--repo needs a non-empty value"
}

@test "#1547 a --repo that is not a directory exits 2" {
  run -2 zsh "$VERIFY" --repo "$BATS_TEST_TMPDIR/no-such-tree"
  contains "$output" "not a directory"
}

@test "#1547 --help exits 0 and prints the usage line" {
  run -0 zsh "$VERIFY" --help
  contains "$output" "usage: verify-reference-move.zsh"
}

# --- base resolution ---------------------------------------------------------

@test "#1547 a --base that is not a commit exits 1 and says so" {
  # Distinct from a usage error: the flag was well-formed, the ref is not.
  run -1 zsh "$VERIFY" --base 'refs/heads/definitely-not-a-branch' --repo "$REPO_ROOT" --quiet
  contains "$output" "does not resolve to a commit"
}

@test "#1547 a base whose commit has no SKILL.md exits 1 and says it could not READ it" {
  # Distinct from the rev-parse guard above: the ref IS a commit, so `rev-parse
  # --verify` succeeds and `git show` still fails because the PATH is absent from
  # that commit's tree — a base predating the skill, or one taken across a
  # rename. Without the guard `$pre` is empty and every chunk instead reports
  # `could not locate the source range`, sending the reader after anchors that
  # are not the problem. The repo's root commit is the stable driver: it predates
  # the skill entirely, and unlike a pinned SHA it cannot rot.
  local root
  root="$(git -C "$REPO_ROOT" rev-list --max-parents=0 HEAD | tail -1)"
  # Every other guard in this file says why it refused; an unborn or unreadable
  # HEAD is the one input that reaches here, and a bare `[ -n … ]` would red
  # without naming it.
  [ -n "$root" ] || {
    echo "could not derive a root commit from HEAD in $REPO_ROOT" >&2; return 1; }
  if git -C "$REPO_ROOT" cat-file -e "$root:development/skills/resolve-issue/SKILL.md" 2>/dev/null; then
    skip "the root commit reachable here already carries SKILL.md (grafted/shallow clone)"
  fi
  run -1 zsh "$VERIFY" --base "$root" --repo "$REPO_ROOT"
  contains "$output" "could not read"
}

# --- the happy path, and that it is not vacuous ------------------------------

@test "#1547 the real tree verifies, reporting all eight declared chunks" {
  _require_pre_move_commit
  run -0 zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$REPO_ROOT"
  contains "$output" "all 8 declared chunks are byte-identical"
}

@test "#1547 --quiet suppresses the ok lines and the summary, leaving stdout empty" {
  # `--quiet` is what CI and the conductor invoke, and every other invocation in
  # the tree — here and in resolve-issue-conductor-budget.bats — reads only the
  # status. So `--quiet) quiet=0 ;;` would make the flag a no-op, print eight
  # `ok` lines and the summary on every quiet run, and no test would notice.
  # Paired with the case above, which pins that they ARE printed without it.
  _require_pre_move_commit
  run -0 zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$REPO_ROOT" --quiet
  [ -z "$output" ]
}

@test "#1547 with no --repo the script resolves the tree relative to ITSELF" {
  # `--repo` is documented as optional and defaults to `${0:A:h}/../../../..`,
  # and the empty-`--repo` case above exists precisely because that default used
  # to be reached by accident — yet every other invocation in the tree, here and
  # in resolve-issue-conductor-budget.bats, passes it explicitly. So a default
  # one level short (`../../..` resolves to development/, an existing
  # directory that the `-d` guard accepts) would break the bare documented
  # invocation forever with the whole suite green.
  #
  # Run from ELSEWHERE, which is what makes the title's "relative to ITSELF"
  # claim testable: bats is driven from the repo root in both CI and the Docker
  # lane, so a default rewritten to `$PWD` would pass from there while breaking
  # every other caller. And assert the summary, not just the status — the
  # default must reach the RIGHT tree, not merely a tolerable one.
  _require_pre_move_commit
  cd "$BATS_TEST_TMPDIR"
  run -0 zsh "$VERIFY" --base "$PRE_MOVE_SHA"
  contains "$output" "all 8 declared chunks are byte-identical"
}

# --- per-chunk failures ------------------------------------------------------

@test "#1547 a mutated chunk exits 1 and names THAT chunk" {
  _require_pre_move_commit
  local fake; fake="$(_fake_tree mutated)"
  # Mutate INSIDE the sentinels — an append after the closing sentinel is
  # invisible to the verifier by design, and would make this control vacuous.
  python3 - "$fake/development/skills/resolve-issue/reference/residue.md" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
assert s.count("Runs **only** on") == 1
io.open(p, "w", encoding="utf-8").write(s.replace("Runs **only** on", "Runs only on", 1))
PY
  run -1 zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$fake"
  contains "$output" "FAIL residue-branch"
  # ...and it failed for the right reason, not because the fixture was broken
  lacks "$output" "reference file not found"
  contains "$output" "did not move verbatim"
  # The OTHER direction of the two-summary separation (#1588). The sweep summary
  # must be absent on a chunk-only failure, exactly as the sweep-only case pins
  # the chunk summary's absence. Without this, widening the sweep summary's guard
  # to `(( chunk_failures || sweep_failures ))` prints
  # `0 sentinel/split-span problem(s)` beside every chunk failure — the
  # mis-direction the #1588 reword removed — with the whole file green.
  lacks "$output" "sentinel/split-span problem"
  # The report itself, not just the verdict. The script's header promises "it
  # prints the first differing line, with both sides"; without this the whole
  # report loop could be deleted and the suite would stay green, leaving the gate
  # able to say a chunk mismatched but not WHERE.
  contains "$output" "first difference at chunk line"
}

@test "#1547 a missing reference file exits 1 and names it" {
  _require_pre_move_commit
  local fake; fake="$(_fake_tree missing)"
  rm "$fake/development/skills/resolve-issue/reference/promotion.md"
  run -1 zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$fake"
  contains "$output" "reference file not found"
}

@test "#1547 a chunk whose sentinels lost their body exits 1 rather than counting as verified" {
  # The empty-chunk refusal. Without it an empty-vs-empty comparison passes and
  # is counted as `verified` — the gate signing off on a chunk containing
  # nothing, which is the one thing it exists to notice.
  _require_pre_move_commit
  local fake; fake="$(_fake_tree emptied)"
  python3 - "$fake/development/skills/resolve-issue/reference/escalation.md" <<'PY'
import io, sys
p = sys.argv[1]
lines = io.open(p, encoding="utf-8").read().split("\n")
o = lines.index("<!-- moved: escalation-head -->")
c = lines.index("<!-- /moved: escalation-head -->")
io.open(p, "w", encoding="utf-8").write("\n".join(lines[:o + 1] + lines[c:]))
PY
  run -1 zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$fake"
  contains "$output" "empty chunk after normalisation"
}

@test "#1547 a chunk whose sentinel PAIR is gone exits 1 and names the missing block" {
  # Third distinct shape, and the diagnostics must not collapse into each other:
  # the case above it is the file absent, the one before this is sentinels
  # present with the body gone, this is the body present with the sentinels
  # gone. Both lines must go — removing only the opening one falls into the
  # empty-chunk branch, and removing only the closing one leaves the stray sweep
  # silent, since it greps opening sentinels alone.
  _require_pre_move_commit
  local fake; fake="$(_fake_tree unsentinelled)"
  python3 - "$fake/development/skills/resolve-issue/reference/escalation.md" <<'PY'
import io, sys
p = sys.argv[1]
lines = io.open(p, encoding="utf-8").read().split("\n")
keep = [x for x in lines if x not in ("<!-- moved: escalation-head -->",
                                      "<!-- /moved: escalation-head -->")]
assert len(keep) == len(lines) - 2, "expected exactly one sentinel pair"
io.open(p, "w", encoding="utf-8").write("\n".join(keep))
PY
  run -1 zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$fake"
  contains "$output" "no <!-- moved: escalation-head --> block"
  # ...and it did NOT degrade into either neighbouring diagnostic
  lacks "$output" "empty chunk after normalisation"
  lacks "$output" "reference file not found"
}

# --- the sentinel sweep ------------------------------------------------------

@test "#1547 a sentinel the MANIFEST does not declare exits 1" {
  # This is the guard between "moved" and "moved, plus new prose smuggled inside
  # sentinels nothing verifies".
  _require_pre_move_commit
  local fake; fake="$(_fake_tree stray)"
  {
    printf '\n<!-- moved: undeclared-chunk -->\n'
    printf 'prose that no manifest row covers.\n'
    printf '<!-- /moved: undeclared-chunk -->\n'
  } >> "$fake/development/skills/resolve-issue/reference/residue.md"
  run -1 zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$fake"
  contains "$output" "undeclared-chunk"
  contains "$output" "does not verify"
}

@test "#1547 a sentinel name carrying a DIGIT is still swept" {
  # The name class is `.+`, not `[a-z-]+`. A narrow class does not reject an
  # undeclared chunk — it makes the sweep skip the line entirely, leaving the
  # chunk unverified with the script still exiting 0. This repo names things
  # after issue numbers, so a digit in a chunk name is realistic.
  _require_pre_move_commit
  local fake; fake="$(_fake_tree digit)"
  {
    printf '\n<!-- moved: epic-1431 -->\n'
    printf 'prose that no manifest row covers.\n'
    printf '<!-- /moved: epic-1431 -->\n'
  } >> "$fake/development/skills/resolve-issue/reference/promotion.md"
  run -1 zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$fake"
  contains "$output" "epic-1431"
}

@test "#1547 the SAME chunk declared by two sentinels exits 1" {
  # extract_chunk stops at the first closing sentinel, so a copy-pasted chunk
  # has an unverified twin free to drift.
  _require_pre_move_commit
  local fake; fake="$(_fake_tree dupe)"
  {
    printf '\n<!-- moved: residue-branch -->\n'
    printf 'a divergent second copy.\n'
    printf '<!-- /moved: residue-branch -->\n'
  } >> "$fake/development/skills/resolve-issue/reference/promotion.md"
  run -1 zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$fake"
  contains "$output" "more than one"
  contains "$output" "residue-branch"
}

@test "#1547 chunk failures and sentinel problems are reported as different things" {
  # The two counts share no denominator: N undeclared sentinels is not "N of the
  # declared chunks did not move verbatim". Reporting them together is how a reader is
  # sent to look for a prose regression that did not happen.
  _require_pre_move_commit
  local fake; fake="$(_fake_tree both)"
  {
    printf '\n<!-- moved: undeclared-chunk -->\n'
    printf 'x\n'
    printf '<!-- /moved: undeclared-chunk -->\n'
  } >> "$fake/development/skills/resolve-issue/reference/residue.md"
  run -1 zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$fake"
  # `sentinel/split-span problem` since #1588: the counter is incremented by
  # several arms and only two of them are "undeclared or duplicated in reference/",
  # so the old label mis-sent the operator on the arms it does not describe. What
  # this case pins is the SEPARATION of the two summaries, not their wording.
  # The COUNT too, not just the label: the fixture appends exactly one undeclared
  # chunk, so it is deterministic. This is a computed value read back from the
  # subject, not a restated numeral of the kind the header forbids — and it is
  # what catches the summary reporting the wrong counter.
  contains "$output" "1 sentinel/split-span problem"
  # no chunk actually differs, so the chunk line must be absent
  lacks "$output" "did not move verbatim"
}

# ---- #1582: the reviewer path rule, and the span re-cut that made room for it.
#
# The rule sits in the UNVERIFIED gap between the two round-protocol chunks, so
# `verify-reference-move.zsh` cannot notice if it is edited or deleted. These
# needles are the only thing standing between that gap and silent drift, which
# is exactly why they are pinned by content rather than by line number.

@test "#1582 the round protocol states the scope_abs rule, IN the gap above step 1" {
  local f="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md"
  # The heading the rule lives under is still the protocol's own — and still
  # ABOVE the span it titles (#1588). A presence-only grep proved it existed
  # somewhere: the heading sits outside every byte-verified chunk (above the
  # head-open sentinel), so moving it to the bottom of the file left this test
  # and the byte gate both green while the gap prose no longer sat under it.
  local h_line hopen
  h_line="$(_gap_line -x "$f" '## The round protocol')"
  hopen="$(_gap_line -x "$f" '<!-- moved: round-protocol-head -->')"
  [ "$h_line" -lt "$hopen" ]
  # build the scope block from scope_abs[], not changed_files alone
  # Run against the GAP's flattened text (#1588), which makes presence and
  # position one assertion — these three straddle a wrap point in their
  # paragraph, so a line-oriented grep over them rots on the next re-flow.
  local flat
  flat="$(_gap_text "$f")"
  [ -n "$flat" ]
  printf '%s' "$flat" | grep -qF -- 'Build each reviewer'"'"'s scope block from the plan'"'"'s `scope_abs[]`'
  # the negation, pinned on the clause it actually turns on rather than on a
  # generic `never from` that any future sentence could satisfy
  printf '%s' "$flat" | grep -qF -- '`changed_files` alone (#1582)'
  # It names the frozen instruction it governs. Anchored on the NEW sentence, not
  # on the quoted fragment: `scoped to the plan's `changed_files`` also occurs
  # inside the byte-frozen tail chunk, where it can never be removed — so a
  # whole-file grep for it can only ever match and would prove nothing. Grepping
  # the gap alone removes that hazard outright: the tail chunk is not in it.
  printf '%s' "$flat" | grep -qF -- 'This governs step 1 below, whose frozen text'
}

@test "#1582 BOTH forms of the verbatim reviewer sentence are stated" {
  local f="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md"
  # whitespace-normalised, for the same reason as the relay test below: these are
  # reflowed blockquote sentences, and a line-oriented needle over them passes or
  # fails on where the paragraph happens to wrap
  local flat
  flat="$(_gap_text "$f")"
  # non-vacuity: an empty gap must never satisfy the needles below
  [ -n "$flat" ]
  # two-clause form, for a linked worktree
  printf '%s' "$flat" | grep -qF -- "Read every file you are given under \`<worktree_root>\`; this run's tree is that directory, not \`<original_root>\`."
  # single-clause form, for original_root == null
  printf '%s' "$flat" | grep -qF -- "Read every file you are given under \`<worktree_root>\`. Report every finding's"
  # the prohibition that makes the null case unambiguous — flattened like the
  # two above (#1588); it is ordinary wrapped prose, not a code-block line
  printf '%s' "$flat" | grep -qF -- 'Never render the literal `null` into the sentence.'
  # the sentence must not be readable as a SCOPE instruction — it names which
  # tree, never how much of it
  printf '%s' "$flat" | grep -qF -- 'it never widens the round'"'"'s scope'

}

@test "#1582 the reporting rule is relayed INTO the reviewer prompt, not just stated" {
  # The reviewer writes `.file`, so the reviewer is who must be told. If this
  # only ever appeared as prose addressed to the driving session, a session that
  # followed the rule literally would hand out absolute paths with no reporting
  # instruction, scope-findings would discard EVERY finding, and the round would
  # read as zero-blocker — CONVERGED on a review nobody saw.
  local f="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md"
  # Needle the MANDATED SENTENCE on whitespace-normalised text, not line by
  # line. It is reflowed prose inside a blockquote, so each form wraps at a
  # different word and a line-oriented grep matches neither reliably — which is
  # how a needle over prose rots into a no-op.
  local flat
  flat="$(_gap_text "$f")"
  # non-vacuity: an empty gap must never satisfy the needles below
  [ -n "$flat" ]
  # BOTH forms carry the reporting sentence — the two-clause one and the
  # first-clause-only one for `original_root: null`
  [ "$(printf '%s' "$flat" | grep -o -- "Report every finding's \`file\` using the repo-relative name shown for it in the scope block — never the absolute path you read." | wc -l | tr -d ' ')" -eq 2 ]
  printf '%s' "$flat" | grep -qF -- 'so the reviewer is who'
  # the scope block must carry BOTH spellings, or the reporting rule above names
  # a column the prompt does not contain — the contradiction two reviewers found
  printf '%s' "$flat" | grep -qF -- 'giving **both spellings of every file**'
  printf '%s' "$flat" | grep -qF -- 'Both, not either'

}

@test "#1582 the rule keeps a finding's .file repo-relative" {
  local f="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md"
  # reflowable prose, whitespace-normalised (#1588)
  local flat
  flat="$(_gap_text "$f")"
  # non-vacuity: an empty gap must never satisfy the needles below
  [ -n "$flat" ]
  printf '%s' "$flat" | grep -qF -- "A finding's \`.file\` stays repo-relative"
  # the load-bearing prohibition — scope_abs[] is the absolute spelling a
  # reviewer now HAS to hand, so forbidding it is the operative half
  printf '%s' "$flat" | grep -qF -- 'never an entry from `scope_abs[]`'
  printf '%s' "$flat" | grep -qF -- 'silently DISCARDS'

}

@test "#1582 the rule carries the work-dir subtraction, the confirm step and the deletion arm" {
  local f="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md"
  # Reflowable prose runs against WHITESPACE-NORMALISED text (#1588). These are
  # wrapped paragraph sentences, so a line-oriented `grep -qF` matches or misses
  # on where the paragraph happens to wrap — three needles in this family broke
  # exactly that way inside #1582's own loop, and the verdict needle below broke
  # again the moment it was written line-oriented.
  local flat
  flat="$(_gap_text "$f")"
  # non-vacuity: an empty gap must never satisfy the needles below
  [ -n "$flat" ]

  # scope_abs is the RAW changed_files joined to the root, so the subtraction
  # step 1 mandates has to be restated for the absolute list or the panel gets
  # dispatched over the loop's own state
  printf '%s' "$flat" | grep -qF -- 'same `--work-dir` subtraction'
  # plan reports the roots of whatever --repo it was handed; it cannot know it
  # was the right one
  printf '%s' "$flat" | grep -qF -- 'First confirm the descriptor describes the tree the STORY was implemented in'
  # ...and the arm a naive cwd test gets backwards: an epic child runs in its own
  # worktree while the invoking session's cwd stays at the original checkout, so
  # a cwd mismatch on a CORRECT descriptor must not trigger a re-plan.
  #
  # Needle the VERDICT, not the connective (#1588). The former needle was
  # `even when that`, which survives the mutation it existed to catch: rewriting
  # the arm to `→ re-plan, **even when that differs…**` inverts the rule and the
  # connective still matches. Binding the descriptor clause to its verdict is
  # what makes the needle red on that inversion.
  printf '%s' "$flat" | grep -qF -- 'IS the implementation worktree** → proceed, **even when that differs from your own cwd**'
  printf '%s' "$flat" | grep -qF -- 'Never re-plan against your cwd'
  # and the re-plan arm must keep the round-scoping flags — a bare
  # `plan --repo <wt>` defaults --round to 1 and silently reviews the whole diff
  printf '%s' "$flat" | grep -qF -- 'every other flag unchanged'
  # changed_files lists deletions, so scope_abs provably contains unreadable paths
  printf '%s' "$flat" | grep -qF -- 'a file the story DELETED'
  # the deletion excerpt is ROOTED at the descriptor's tree, not at your cwd —
  # the same hazard the confirm step above exists for
  printf '%s' "$flat" | grep -qF -- 'root the command at the tree the descriptor names'
  # ...and an empty excerpt is a stop, or a `[DELETED]` marking tells the
  # reviewer not to question a file nobody reviewed
  printf '%s' "$flat" | grep -qF -- 'An EMPTY excerpt is a stop'
  # the carried entries are the one thing a reviewer opens beyond the scope
  # block, and they get the same both-spellings treatment
  printf '%s' "$flat" | grep -qF -- 'The carried entries are the one exception'
  # ...these two are CODE-BLOCK lines, not reflowable prose, so they stay
  # line-oriented: a fenced block does not re-wrap.
  # Gap-scoped and DISCRIMINATING (#1588). These were whole-file greps for two
  # strings that are not unique — `Carried entries to verify` renders twice and
  # `[DELETED by this story]` five times — so each was satisfied by an occurrence
  # other than the one it pins, and deleting the fenced block that renders the
  # marked carried entry (the concrete form the rule points at) left the suite
  # green. Count the carried blocks, and bind the marking to the header that
  # immediately precedes it. `tr -s ' '` has already collapsed the block's
  # indentation, so the entry flattens to a single-spaced form.
  # Each block pinned by its OWN body, not by a shared count. A count of 2 reds
  # on deleting either block, but it does not notice a block being GUTTED, and it
  # would red falsely if a third legitimate rendering were ever added. Binding
  # each marking to the header immediately above it does both jobs. The first
  # needle also exercises the `-> ` arrow, which is the load-bearing rendering of
  # "Both, not either" and the reason the blockquote strip runs before the
  # flatten rather than after it.
  printf '%s' "$flat" | grep -qF -- 'report under the repo-relative name beside it: development/skills/resolve-issue/scripts/review-dispatch.zsh -> /abs/path/to/<worktree>/development/skills/resolve-issue/scripts/review-dispatch.zsh'
  printf '%s' "$flat" | grep -qF -- 'report under the repo-relative name beside it: development/skills/resolve-issue/scripts/old-helper.zsh [DELETED by this story]'
  # ...and the SCOPE block's own two renderings, by the same shape
  printf '%s' "$flat" | grep -qF -- "report each finding's \`file\` under the repo-relative name beside it: development/skills/resolve-issue/scripts/review-dispatch.zsh -> /abs/path/to/<worktree>/"
  printf '%s' "$flat" | grep -qF -- 'say what to do with them: ```text development/skills/resolve-issue/scripts/old-helper.zsh [DELETED by this story]'

}

@test "#1588 the carried section carries an arm for a carried-and-DELETED file" {
  # Items 11-12. A carried entry whose file the previous fix pass deleted sat in
  # both lists with OPPOSITE instructions: the scope block said not to raise a
  # finding about the missing path, the carried header said to read the absolute
  # path. The reviewer had to pick one, and neither choice was stated.
  local f="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md"
  local flat
  flat="$(_gap_text "$f")"
  # non-vacuity: an empty gap must never satisfy the needles below
  [ -n "$flat" ]

  # it KEEPS its place — dropping it would retire a blocker nobody confirmed
  printf '%s' "$flat" | grep -qF -- 'A carried entry whose file no longer exists keeps its place here'
  # the marking REPLACES "read the absolute path" for that entry...
  printf '%s' "$flat" | grep -qF -- 'The marking **replaces** "read the absolute path" for that entry'
  # ...and the excerpt is what the reviewer confirms the landing from
  printf '%s' "$flat" | grep -qF -- 'confirms the carried blocker landed from the excerpt'
  # item 12: the single-spelling exception is STATED, not left implicit in an example
  printf '%s' "$flat" | grep -qF -- 'a `[DELETED by this story]` entry is the one exception to "Both, not either"'

  # The rule REACHES THE REVIEWER. Stating it only to the driving session leaves
  # the scope block's blockquote as the sole marker-keyed instruction in the
  # prompt — and that one says not to question the entry, which on a CARRIED
  # entry means nobody accounts for the blocker and it is stalled or retired.
  # Same relay failure as the reporting rule, so the same remedy: a verbatim
  # sentence, plus the re-raise duty that makes it non-optional.
  printf '%s' "$flat" | grep -qF -- 'in the **carried** section has no'
  printf '%s' "$flat" | grep -qF -- 're-raise it at its original severity if you cannot'
  # ...and the scope block's blockquote is SCOPED so it cannot be read as
  # governing the carried section too
  printf '%s' "$flat" | grep -qF -- '`[DELETED by this story]` **in the scope block** is expected'

  # The antecedent is TESTED, not inferred from which round deleted the file —
  # the carried section is built by string-prefixing verify-<R>.json and checks
  # nothing, and keying on "the previous fix pass" would miss an entry deleted
  # earlier and still unconfirmed.
  printf '%s' "$flat" | grep -qF -- 'test whether its file exists under `<worktree_root>`'
  printf '%s' "$flat" | grep -qF -- 'whatever round removed it'

  # THE NOTE ARM, pinned in its own right. The blockquote has two arms and keys
  # on which the entry carries; pinning only the excerpt arm left the note arm —
  # the reviewer-facing half of the whole fix — deletable with the suite green,
  # which is the same relay failure this family exists to catch, one level up.
  printf '%s' "$flat" | grep -qF -- 'Where it carries the note **`exists in neither tree`** instead'
  printf '%s' "$flat" | grep -qF -- 'count the entry as confirmed, say so in your count, and do not re-raise it'
  # ...and emitting NEITHER form is forbidden, which is what makes the keying
  # non-optional rather than a stylistic choice
  printf '%s' "$flat" | grep -qF -- 'Emit one or the other, never neither'

  # The empty-excerpt rule is stated ONCE and governs BOTH sections, so the
  # scope block's abbreviated "report it and stop" cannot be read as the whole
  # rule. Its probe must establish it can answer before any per-entry verdict.
  printf '%s' "$flat" | grep -qF -- 'governs **both** sections'
  printf '%s' "$flat" | grep -qF -- 'Establish the probe can answer at all'
  printf '%s' "$flat" | grep -qF -- 'never by how many entries came back one way'

  # The two arms of the per-entry split.
  printf '%s' "$flat" | grep -qF -- 'absent at `<base>` too'
  printf '%s' "$flat" | grep -qF -- 'do not stop'
  printf '%s' "$flat" | grep -qF -- 'present at `<base>`**, excerpt still empty'

  # ...and the DELTA-round reachability that makes the scope block need the rule
  # too. An earlier cut asserted the scope block was immune because its entries
  # come from `git diff --name-only`; on a delta round they come from
  # `diff-tree <prior_tree> <cur>`, which does list a created-then-deleted file,
  # so that assertion would have aborted a healthy delta round.
  printf '%s' "$flat" | grep -qF -- 'Both sections reach case 2'"'"'s first arm'
  printf '%s' "$flat" | grep -qF -- 'which lists a file that existed at `prior_tree` and is gone now'
  printf '%s' "$flat" | grep -qF -- 'it is immune on full rounds only'
}

@test "#1582 the round-protocol span is re-cut into head + tail, and the old name is gone" {
  local v="$REPO_ROOT/development/skills/resolve-issue/scripts/verify-reference-move.zsh"
  local ref="$REPO_ROOT/development/skills/resolve-issue/reference"

  # manifest: exactly the two new rows, and no surviving `round-protocol` row.
  # The row test is anchored on the TAB that follows the name, so
  # `round-protocol-head` cannot satisfy a search for `round-protocol`.
  grep -qF -- "\"round-protocol-head	review-loop.md	" "$v"
  grep -qF -- "\"round-protocol-tail	review-loop.md	" "$v"
  run grep -qF -- "\"round-protocol	review-loop.md	" "$v"
  [ "$status" -ne 0 ]

  # The ANCHORS, in full — not just the row prefixes. The gap is defined entirely
  # by the head's LAST_LINE and the tail's FIRST_LINE, so pinning only the
  # prefixes would let both anchors be moved (shrinking a chunk and silently
  # enlarging the unverified gap) with every assertion here still green.
  grep -qF -- "	**The round boundary is concurrent — one minted tree, two readers (#1497).**	Each round:" "$v"
  grep -qF -- "	1. **Review panel, in-session.** Get the dispatch plan (\\\`review-dispatch.zsh	   is how the two statements of it came to disagree once already." "$v"

  # sentinels: all four present, each at column 0 (whole-line match), in exact
  # parity with the manifest names — `extract_chunk` and the stray-sentinel
  # sweep both match at column 0, so an indented one would be invisible.
  local n
  for n in round-protocol-head round-protocol-tail; do
    [ "$(grep -cxF -- "<!-- moved: $n -->" "$ref/review-loop.md")" -eq 1 ]
    [ "$(grep -cxF -- "<!-- /moved: $n -->" "$ref/review-loop.md")" -eq 1 ]
  done
  # ...and neither old sentinel survives anywhere in reference/
  run grep -rxF -- '<!-- moved: round-protocol -->' "$ref"
  [ "$status" -ne 0 ]
  run grep -rxF -- '<!-- /moved: round-protocol -->' "$ref"
  [ "$status" -ne 0 ]
}

@test "#1582 the unverified gap holds NEW prose only — the split anchors stay adjacent" {
  # What the split actually promises is not a gap SIZE but that no ORIGINAL
  # conductor line entered the gap: in the pre-move file the head's last anchor
  # and the tail's first anchor are adjacent modulo blank lines, so everything
  # between the sentinels today is text that did not exist there. A size cap only
  # approximated that — and worse, any number it named could be raised in the
  # same edit that violated it, which is why the script now asserts adjacency
  # directly and this test checks that it does.
  local f="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md"
  # Through the helper (#1588), not a hand-rolled `grep -nxF | cut`: one lookup
  # path, and its loud not-found message instead of a silently empty variable.
  local head_close tail_open span
  head_close="$(_gap_line -x "$f" '<!-- /moved: round-protocol-head -->')"
  tail_open="$(_gap_line -x "$f" '<!-- moved: round-protocol-tail -->')"
  [ "$tail_open" -gt "$head_close" ]
  span=$(( tail_open - head_close - 1 ))
  # non-vacuous: the gap really does hold the rule
  [ "$span" -gt 0 ]

  # In the PINNED pre-move conductor, nothing but blank lines sits between the
  # two anchors — the invariant the script enforces, checked here independently
  # so a broken enforcement and a broken tree are distinguishable.
  _require_pre_move_commit
  local between
  between="$(git -C "$REPO_ROOT" show "$PRE_MOVE_SHA:development/skills/resolve-issue/SKILL.md" | awk '
    $0 == "Each round:" { seen = 1; next }
    seen && $0 == "1. **Review panel, in-session.** Get the dispatch plan (`review-dispatch.zsh" { exit }
    seen && $0 ~ /[^[:space:]]/ { print }
  ')"
  [ -z "$between" ]

  # No needle here on the script's own diagnostic text (#1588). That the script
  # really ENFORCES the invariant rather than merely documenting it is driven
  # behaviourally, by the two cases `#1582 the adjacency invariant FIRES when a
  # manifest anchor is moved inward` and `#1582 the adjacency invariant FIRES
  # when the manifest stops declaring a split row` — each running a mutated copy
  # and asserting it exits 1. A `grep` for the sentence was redundant beside
  # those, not merely weak: it red on a harmless reword and passed on a gutted
  # check, which is backwards on both counts.
}

@test "#1582 the split still verifies byte-identical, at eight chunks" {
  _require_pre_move_commit
  run -0 zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$REPO_ROOT"
  contains "$output" "all 8 declared chunks are byte-identical"
  # both halves accounted for, so a row silently dropped from the manifest
  # cannot leave this green
  contains "$output" "ok   round-protocol-head"
  contains "$output" "ok   round-protocol-tail"
}

@test "#1582 the unverified gap is DECLARED in the script, not discovered later" {
  # The gap is the cost of the re-cut. If nobody records it, the next reader
  # assumes the whole span is still proven — which is the false-confidence this
  # story exists to remove.
  #
  # THIS NEEDLE IS A DELIBERATE DOCUMENTATION TRIPWIRE, and the only one in the
  # #1582 family (#1588). It pins COMMENT PROSE on purpose: the thing being
  # guarded IS the recording, so there is no behaviour to assert instead, and
  # reddening on deletion of the record is exactly the intent. Narrowed to the
  # one token that carries the admission, so a reword around it stays green.
  #
  # Its former companion `SPLIT into head + tail (#1582)` was deleted rather
  # than kept: unlike this one it named a CONDITION (that the span is split) and
  # would have gone on passing if the gap were re-enlarged, so it did not guard
  # what it named. Every other needle in this family pins behaviour.
  local v="$REPO_ROOT/development/skills/resolve-issue/scripts/verify-reference-move.zsh"
  grep -qF -- 'verified by NOTHING' "$v"
}

# --- #1582: the split-span sweep arms, DRIVEN (not merely re-derived) --------
# The bats-side arithmetic in the case that recomputes the anchor adjacency from the pinned commit proves the tree
# is currently sound; it does not prove the SCRIPT would notice if it stopped
# being. These three drive the script's own fail-closed arms against a mutated
# copy of the reference tree, so deleting any of them reds here.

@test "#1582 the sweep FAILS when the split halves are out of order" {
  _require_pre_move_commit
  local fake; fake="$(_fake_tree splitswap)"
  local f="$fake/development/skills/resolve-issue/reference/review-loop.md"
  # swap the two inner sentinels: head's closer moves below tail's opener
  local hc to
  # through the helper, like every other sentinel lookup in this file (#1588):
  # its not-found message names WHICH sentinel went missing, where an empty
  # variable reaching the `sed` address below only yields a usage error
  hc="$(_gap_line -x "$f" '<!-- /moved: round-protocol-head -->')"
  to="$(_gap_line -x "$f" '<!-- moved: round-protocol-tail -->')"
  sed -i.bak -e "${hc}s|.*|<!-- moved: round-protocol-tail -->|" \
             -e "${to}s|.*|<!-- /moved: round-protocol-head -->|" "$f"
  rm -f "$f.bak"

  run zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$fake"
  [ "$status" -eq 1 ]
  contains "$stderr$output" "the split halves are out of order"

  # BOTH summaries, because this fixture drives BOTH counters (#1588). Swapping
  # the sentinels makes `extract_chunk` overrun both round-protocol chunks into
  # the gap, so chunk_failures is 2 alongside sweep_failures 1 — measured, not
  # reasoned. This is the CO-OCCURRENCE arm of the separation the script's
  # exit-code table promises ("counted and reported separately … but both land
  # here"); the two single-defect directions are pinned by the chunk-only and
  # sweep-only cases above. Without it, chaining the sweep summary onto the
  # chunk summary as an `elif` leaves every case green while a both-defect run
  # tells the operator only about chunks — the mis-attribution the separate
  # reporting exists to prevent, inverted.
  contains "$stderr$output" "did not move verbatim"
  contains "$stderr$output" "1 sentinel/split-span problem"
}

@test "#1582 the sweep FAILS when a split sentinel is missing" {
  _require_pre_move_commit
  local fake; fake="$(_fake_tree splitgone)"
  local f="$fake/development/skills/resolve-issue/reference/review-loop.md"
  # drop the tail opener; the manifest still declares round-protocol-tail
  grep -vxF -- '<!-- moved: round-protocol-tail -->' "$f" > "$f.new"
  mv "$f.new" "$f"

  run zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$fake"
  [ "$status" -eq 1 ]
  contains "$stderr$output" "must appear exactly once each"
}

@test "#1582 the sweep FAILS when a split sentinel is DUPLICATED" {
  # The one the stray-sentinel sweep cannot see: it greps only the OPENING form,
  # so a duplicated `/moved:` closer is invisible to it. Before the array-capture
  # fix this assigned a multi-line string to a `typeset -i`.
  _require_pre_move_commit
  local fake; fake="$(_fake_tree splitdupe)"
  local f="$fake/development/skills/resolve-issue/reference/review-loop.md"
  printf '\n<!-- /moved: round-protocol-head -->\n' >> "$f"

  run zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$fake"
  [ "$status" -eq 1 ]
  contains "$stderr$output" "must appear exactly once each"
}

@test "#1582 verify-reference-move.zsh scrubs an inherited GIT_DIR/GIT_WORK_TREE" {
  # Without the scrub these override `git -C "$repo"`, so the pinned commit and
  # SKILL.md are read out of ANOTHER repository. Worst case: that repo also
  # holds the pinned commit (a clone or worktree of this one does), and the gate
  # prints `all N declared chunks are byte-identical` at exit 0 having verified
  # nothing about the tree `--repo` named.
  _require_pre_move_commit
  local other="$BATS_TEST_TMPDIR/other-for-verify"
  mkdir -p "$other"
  git -C "$other" init -q
  git -C "$other" config user.email t@example.com
  git -C "$other" config user.name tester
  echo other > "$other/README.md"
  git -C "$other" add -A
  git -C "$other" commit -qm base

  run -0 env GIT_DIR="$other/.git" GIT_WORK_TREE="$other" \
    zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$REPO_ROOT" --quiet
  [ -z "$output" ]

  # GIT_DIR alone — the name that actually redirects this script's reads, so
  # this arm DISCRIMINATES: removing `GIT_DIR` from the scrub reds it (#1588).
  #
  # It replaces a GIT_WORK_TREE-alone arm that could not fail. This script's
  # only git calls are `rev-parse --verify <base>^{commit}` and
  # `git show <base>:<path>` — pure object-DB reads, which a work-tree override
  # does not touch — so both assertions held with `GIT_WORK_TREE` removed from
  # the `unset` entirely, and the arm read as coverage while proving nothing.
  #
  # `GIT_WORK_TREE`/`GIT_INDEX_FILE` stay in the script's `unset` as
  # DEFENCE-IN-DEPTH for this script, not because this suite pins them: no call
  # here consults either. The `review-dispatch.zsh` twin is different — it runs
  # work-tree-sensitive commands, so its GIT_WORK_TREE arm genuinely
  # discriminates and stays.
  run -0 env GIT_DIR="$other/.git" \
    zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$REPO_ROOT" --quiet
  [ -z "$output" ]
}

@test "#1588 ARCHITECTURE.md's byte-identity claim carries the unverified-gap carve-out" {
  # Item 10. The claim is true of the EIGHT DECLARED CHUNKS and not of the whole
  # of reference/: the #1582 re-cut opened a gap that no byte comparison covers.
  # `reference/review-loop.md`'s preamble and the script header were both
  # corrected; ARCHITECTURE.md was the third restatement site and still said it
  # file-wide, which is the overclaim a reader would rely on.
  #
  # Whitespace-normalised, because this is wrapped prose in a long paragraph and
  # a line-oriented needle over it rots on the next reflow (#1588).
  local a="$REPO_ROOT/ARCHITECTURE.md"
  local flat
  flat="$(tr '\n' ' ' < "$a" | tr -s ' ')"
  # NOT "the eight declared chunks": a numeral here is the counted enumeration
  # the fix-pass rules say to replace with a name, and #1582 already moved this
  # one from seven to eight with nothing comparing it to the manifest (#1588).
  printf '%s' "$flat" | grep -qF -- 'for the chunks the manifest declares, which are not the whole of'
  printf '%s' "$flat" | grep -qF -- 'the text in that gap is verified by nothing'
  printf '%s' "$flat" | grep -qF -- 'asserting the two anchors stay adjacent in the pinned commit'
  # The carve-out's scope is stated as a CONDITION, not a closed site roster —
  # and the condition is on the CLAIM'S SHAPE, not on which file it is about.
  # Keying it on the file contradicted the very next sentence, which correctly
  # excludes tests/resolve-issue-corpus.bash: that file's sweep does cover
  # review-loop.md, so "a claim about a gap-containing file" caught it while the
  # exclusion said it was not owed (#1588).
  printf '%s' "$flat" | grep -qF -- 'owed by the **shape of the claim**, not by which file the claim is'
  printf '%s' "$flat" | grep -qF -- 'covering a gap-containing file **as a whole**'
  # ...and the per-chunk claims are named as NOT owing it, with the reason
  printf '%s' "$flat" | grep -qF -- 'A claim scoped to **each declared chunk** does not need it'
  # ...and the numeral is really gone, not merely reworded around
  lacks "$flat" "eight declared chunks"
}

@test "#1588 a manifest row with fewer than four fields exits 1 and prints the row" {
  # Field-peeling is forgiving in the wrong direction: `${row%%$'\t'*}` /
  # `${row#*$'\t'}` on a THREE-field row leave `first` and `last` holding the
  # same string, so the operator is told "could not locate the source range"
  # beneath two IDENTICAL anchors — a message pointing at the anchors when the
  # fault is the row. Never a silent pass (the empty-chunk guard and the counter
  # reconciliation close those exits), so the cost is diagnosis time; this pins
  # the diagnosis. Mutation: delete the `(( ${#row_tabs} < 3 ))` guard and the
  # run reports the misleading source-range failure instead.
  _require_pre_move_commit
  local mutant="$BATS_TEST_TMPDIR/verify-short-row.zsh"
  # Drop the REF_FILE field from the first manifest row, leaving three fields.
  # The first row, so no other row is processed before the guard fires.
  sed 's|^"interactive-remediation	interactive.md	|"interactive-remediation	|' \
    "$VERIFY" > "$mutant"
  # the mutation must have applied, or this case proves nothing (`run !`, since
  # a bare `!` is inert in bats, #829)
  run ! grep -qF '"interactive-remediation	interactive.md	' "$mutant"

  run zsh "$mutant" --base "$PRE_MOVE_SHA" --repo "$REPO_ROOT"
  [ "$status" -eq 1 ]
  contains "$stderr$output" "needs 4 tab-separated fields, found 3"
  # the OFFENDING ROW is printed — that is the whole point of the guard, and a
  # message naming only the count would leave the operator hunting for which row
  contains "$stderr$output" "interactive-remediation"
  # ...and it did NOT reach the misleading diagnosis the guard exists to replace
  lacks "$stderr$output" "could not locate the source range"
}

@test "#1588 a manifest row with a FOURTH tab is not refused — the guard is < 3, not != 3" {
  # The other half of the guard's contract, and the half an earlier cut left
  # undriven: `last` absorbs everything after the third tab, so a tab INSIDE an
  # anchor line is legitimate and must keep working. Changing `< 3` to `!= 3`
  # reds this case while leaving the too-few-fields case green, which is exactly
  # the asymmetry that makes it worth driving.
  #
  # It drives the SCRIPT rather than re-deriving the arithmetic in the test: an
  # earlier attempt re-implemented the tab count in bats and proved nothing about
  # the subject.
  _require_pre_move_commit
  local mutant="$BATS_TEST_TMPDIR/verify-extra-tab.zsh"
  # Append a tab plus a token to the FIRST row's last field. The row now has four
  # tabs; the anchor no longer matches the pinned commit, so the run still fails —
  # but it must fail as an unlocatable RANGE, never as a malformed row.
  sed 's|^\("interactive-remediation	interactive.md	[^	]*	.*\)$|\1	TRAILING|' \
    "$VERIFY" > "$mutant"
  run ! grep -qF '	TRAILING' "$VERIFY"
  run -0 grep -qF '	TRAILING' "$mutant"

  run zsh "$mutant" --base "$PRE_MOVE_SHA" --repo "$REPO_ROOT"
  [ "$status" -eq 1 ]
  # the field-count guard did NOT fire — four tabs is a legitimate row shape
  lacks "$stderr$output" "needs 4 tab-separated fields"
  # ...it failed for the right reason instead
  contains "$stderr$output" "could not locate the source range"
}

@test "#1582 the adjacency invariant FIRES when a manifest anchor is moved inward" {
  # THE case the whole check exists for, and the one an earlier cut of it could
  # not reach: moving the head row's LAST anchor to an earlier line migrates
  # original conductor prose into the unverified gap while every per-chunk byte
  # comparison still passes. It is only catchable because both anchors are read
  # out of the MANIFEST — an assertion built from literals against the pinned
  # (immutable) `$pre` is a constant and can never fire.
  _require_pre_move_commit
  local fake; fake="$(_fake_tree adjacency)"

  # A mutated copy of the SCRIPT with the head row's last anchor moved inward to
  # a line that really does sit earlier inside the head chunk.
  local mutant="$BATS_TEST_TMPDIR/verify-anchor-moved.zsh"
  sed 's|	Each round:$|	The ordering, and it is the whole of it:|' "$VERIFY" > "$mutant"
  # the mutation must have applied, or this case proves nothing. `run !`, not a
  # bare `!` — the latter is inert in bats (#829).
  run ! grep -qF '	Each round:' "$mutant"

  run zsh "$mutant" --base "$PRE_MOVE_SHA" --repo "$fake"
  [ "$status" -eq 1 ]
  contains "$stderr$output" "no longer adjacent"
}

@test "#1582 the adjacency invariant FIRES when the manifest stops declaring a split row" {
  # The other way the check can be defeated: drop a split row, and the anchors it
  # supplied vanish. Reported as its own named failure rather than silently
  # skipping the invariant.
  _require_pre_move_commit
  local fake; fake="$(_fake_tree adjacency-norow)"
  local mutant="$BATS_TEST_TMPDIR/verify-row-dropped.zsh"
  # rename the tail row so `round-protocol-tail` no longer resolves in the loop,
  # while leaving a syntactically valid manifest
  sed 's|^"round-protocol-tail	|"round-protocol-renamed	|' "$VERIFY" > "$mutant"
  run ! grep -qF '"round-protocol-tail	' "$mutant"

  run zsh "$mutant" --base "$PRE_MOVE_SHA" --repo "$fake"
  [ "$status" -eq 1 ]
  contains "$stderr$output" "no longer declares both round-protocol split rows"
}
