#!/usr/bin/env bats
#
# The conductor budget (#1503).
#
# `development/skills/resolve-issue/SKILL.md` reached ~3 890 lines, of which
# ~2 250 described branches a given run never takes — loaded into context on
# every run of every repo type. #1503 moved those branches into on-demand
# `reference/*.md`, byte-for-byte, leaving the conductor with each step's
# invocation contract, its exit-code table and a pointer.
#
# Nothing stops that from growing straight back. A review round can only ever
# report "this file is getting long" as a Suggestion, and Suggestions are waived
# by construction — which is how it got to 3 890 in the first place. So the
# budget is a RED GATE here rather than a round-N finding, and it has two
# halves, because either one alone is trivially satisfiable:
#
#   - a LINE CEILING, so the conductor cannot simply accrete; and
#   - a NO-RESTATEMENT rule, so it cannot stay under the ceiling by summarising
#     what the references say. A summary of a procedure is the propagation drift
#     #1432 exists to prevent — two statements of one rule, drifting apart —
#     and it is exactly the shape a "helpful" edit produces.
#
# The pointer sweep is the third leg: a conductor that points at nothing, or at
# a heading that has been renamed, is worse than one that restates, because the
# session reaches the step and finds no procedure at all.
#
# Every assertion is anchored by CONTENT, never by line number (#1189) — the one
# exception being the ceiling itself, which is a line COUNT and not a position.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_DIR="$REPO_ROOT/development/skills/resolve-issue"
  CONDUCTOR="$SKILL_DIR/SKILL.md"
  REF_DIR="$SKILL_DIR/reference"

  # The ceiling. Set by ONE stated rule — the smallest multiple of 5 at or above
  # the measured size x 1.10 — so it is room for a genuinely new step's
  # invocation contract and not much else. Raising it is a deliberate act that
  # belongs in a PR that states the new measurement; that is the point of a
  # stated number rather than a ratio nobody notices. #1503 set it from 1 382
  # lines; #1504 re-measured 1 484 after moving the plugin-only rules into
  # `development-claude-plugin:resolve-profile`, adding the §1b load step, and
  # adding the no-profile floors §3, §4 and E4 need for the fallback path.
  CEILING=1635

  VERIFY="$SKILL_DIR/scripts/verify-reference-move.zsh"
  # The pre-move commit, READ OUT OF THE SCRIPT rather than transcribed here.
  # It is pinned as a SHA, not as `origin/main`: once this change merges,
  # `origin/main` holds the POST-move file and the verifier could never find a
  # source chunk again. Single-sourcing it means a re-pin cannot leave the script
  # and its gate disagreeing — the shape where the gate skips and the script
  # reds, or worse, the reverse.
  PRE_MOVE_SHA="$(sed -n 's/^typeset -r PRE_MOVE_DEFAULT=\([0-9a-f]\{40\}\)$/\1/p' "$VERIFY")"
  [ -n "$PRE_MOVE_SHA" ] || {
    echo "could not read PRE_MOVE_DEFAULT out of $VERIFY" >&2; return 1; }
}

# --- helpers ----------------------------------------------------------------

# Every `## ` heading text across the reference files, one per line.
_ref_headings() {
  grep -h '^## ' "$REF_DIR"/*.md | sed 's/^## //'
}

# Every heading text in a markdown file, at any level, one per line.
_headings_of() {
  grep -E '^#{1,6} ' "$1" | sed -E 's/^#{1,6} //'
}

# Print any reference heading that is restated as a heading of $1. Prints
# nothing and returns 0 when there is none — the shape both the real assertion
# and its non-vacuity control use, so the control proves the REAL detector, not
# a paraphrase of it.
_restated_headings() {
  local file="$1" h
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    if _headings_of "$file" | grep -qxF -- "$h"; then
      printf '%s\n' "$h"
    fi
  done < <(_ref_headings)
}

# Require the pre-move commit, and SKIP only for a reason that is really a
# shallow clone. A bare `cat-file -e || skip` cannot tell "this clone lacks the
# object" from "the constant is a typo" or "a squash-merge rewrote it" — and this
# repo squash-merges by policy, so the pin WILL stop resolving on main one day.
# Left as an unconditional skip, both byte-preservation tests would then report
# ok forever and every mutation of a moved chunk would pass.
_require_pre_move_commit() {
  git -C "$REPO_ROOT" cat-file -e "$PRE_MOVE_SHA^{commit}" 2>/dev/null && return 0
  if [ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
    skip "pre-move commit $PRE_MOVE_SHA is absent from this SHALLOW clone"
  fi
  echo "PRE_MOVE_SHA ($PRE_MOVE_SHA) no longer resolves in a full clone —" >&2
  echo "re-pin PRE_MOVE_DEFAULT in $VERIFY to the pre-move commit." >&2
  return 1
}

# Every pointer in $1, as `file<TAB>heading`. The pointer form is fixed: the
# literal "see `reference/X.md` § " followed by the heading, which RUNS TO THE
# END OF THE LINE. That last part is what makes the sweep mechanical — a pointer
# with prose after the heading would swallow it and never resolve.
#
# The split is done in awk, NOT with `sed 's/.../\1\t/'`: GNU sed expands `\t` in
# the replacement, BSD sed (/usr/bin/sed on macOS, which is what run-gate.zsh
# drives on this maintainer's host) emits a literal `t`. Under BSD the heading
# would land glued to the filename, `IFS=$'\t' read -r f h` would leave $h EMPTY,
# and the heading sweep below would `continue` past every row and PASS having
# checked nothing — vacuous on one CI leg and meaningful on the other.
#
# The filename class is `[^`]+`, NOT `[a-z-]+`: the existence check below is what
# judges the name, and a narrow class does not reject a bad pointer — it makes
# the row VANISH before any sweep sees it. A one-character typo
# (`reference/review_loop.md`) would then leave the conductor pointing at a file
# that does not exist with all four pointer sweeps green. Fail closed: extract
# everything that looks like a pointer, and let the checks reject it. (Same
# charset defect the panel blocked on in verify-reference-move.zsh's
# stray-sentinel sweep — #982, every sibling instance in the same round.)
_pointers_of() {
  grep -oE 'see `reference/[^`]+\.md` § .*$' "$1" \
    | awk -F'` § ' '{ sub(/^see `reference\//, "", $1); printf "%s\t%s\n", $1, $2 }'
}

# Every raw pointer occurrence in $1, however malformed — the denominator the
# extractor's output is checked against, so a pointer the extractor cannot parse
# reds instead of disappearing.
#
# It counts OCCURRENCES, not matching lines: two pointers on one line must not
# read as one, or the extractor's greedy `.*$` could swallow the second into the
# first's heading with the denominator none the wiser.
#
# The extraction is SPLIT from the counting so the status tested is the
# extractor's. bats runs bash without pipefail, where `rc=$?` after a pipeline is
# the last element's status — and `pipefail` does not fix it either: it reports
# the RIGHTMOST non-zero, so `grep -c`'s ordinary exit 1 (empty input, count 0)
# masks `grep -o`'s exit 2 just the same. Verified against a mode-000 file and a
# missing path: both make grep exit 2, and only this split form reaches the
# guard. Without it the guard, and both callers' error arms, are dead code
# asserting the opposite of what happens — and an unreadable member would drop
# the same pointers from `rows` and `raw` alike, leaving the completeness check
# vacuous for exactly the file it could not read.
_raw_pointer_count() {
  local out rc
  out="$(grep -o 'see `reference/' "$1")"
  rc=$?
  [ "$rc" -le 1 ] || {
    printf 'could not scan %s for pointers (grep exit %s)\n' "$1" "$rc" >&2
    return 1
  }
  [ -n "$out" ] || { printf '0\n'; return 0; }
  printf '%s\n' "$out" | grep -c ''
}

# THE pointer universe: the conductor plus every reference file. Factored into
# one helper because the three sweeps below and the completeness check all need
# the same set, and three inline rebuilds of it are three chances for the checks
# to drift apart — which is exactly how the completeness check came to cover the
# conductor alone while the sweeps it guards read all six files.
_all_pointer_files() {
  printf '%s\n' "$CONDUCTOR"
  local r
  for r in "$REF_DIR"/*.md; do
    [ -e "$r" ] || continue
    printf '%s\n' "$r"
  done
}

# Every pointer across that universe, as `file<TAB>heading`.
_all_pointers() {
  local f
  while IFS= read -r f; do
    _pointers_of "$f"
  done < <(_all_pointer_files)
}

# The raw denominator across the same universe.
_all_raw_pointer_count() {
  local f total=0 n
  while IFS= read -r f; do
    n="$(_raw_pointer_count "$f")" || return 1
    total=$(( total + n ))
  done < <(_all_pointer_files)
  printf '%s\n' "$total"
}

# --- the ceiling ------------------------------------------------------------

@test "#1503 the conductor is under its line ceiling" {
  local n
  n="$(grep -c '' "$CONDUCTOR")"
  case "$n" in ''|*[!0-9]*)
    printf 'could not count the conductor: %s\n' "$n" >&2; return 1 ;;
  esac
  if [ "$n" -gt "$CEILING" ]; then
    printf 'SKILL.md is %s lines, over the %s-line ceiling.\n' "$n" "$CEILING" >&2
    printf 'Move the procedure into reference/ rather than raising the ceiling;\n' >&2
    printf 'if the ceiling really must move, say why in the PR.\n' >&2
    return 1
  fi
}

@test "#1503 the ceiling is not vacuous — it is close to the real size" {
  # A ceiling of 100 000 would pass forever and guard nothing. Assert the
  # headroom is real but bounded: the conductor must be within 25% of it, so a
  # future edit that raises the ceiling to buy room has to raise it visibly.
  local n floor
  n="$(grep -c '' "$CONDUCTOR")"
  floor=$(( CEILING * 75 / 100 ))
  if [ "$n" -lt "$floor" ]; then
    printf 'SKILL.md is %s lines but the ceiling is %s — the ceiling has drifted\n' "$n" "$CEILING" >&2
    printf 'far above the real size and no longer constrains anything. Lower it.\n' >&2
    return 1
  fi
}

# --- no restatement ---------------------------------------------------------

@test "#1503 no reference-file heading is restated in the conductor" {
  local restated
  restated="$(_restated_headings "$CONDUCTOR")"
  if [ -n "$restated" ]; then
    printf 'SKILL.md restates reference heading(s) that should live only in reference/:\n%s\n' \
      "$restated" >&2
    return 1
  fi
}

@test "#1503 non-vacuity: a planted copy of a reference heading reds the check" {
  # AC5. Proves the detector is doing work — without this it could be passing
  # because `_ref_headings` returns nothing, or because the comparison never
  # matches anything at all.
  local planted="$BATS_TEST_TMPDIR/skill-with-planted-heading.md" first
  first="$(_ref_headings | head -1)"
  [ -n "$first" ]
  cp "$CONDUCTOR" "$planted"
  printf '\n#### %s\n\nsome restated procedure.\n' "$first" >> "$planted"
  local restated
  restated="$(_restated_headings "$planted")"
  [ -n "$restated" ]
  printf '%s\n' "$restated" | grep -qxF -- "$first"
}

@test "#1503 the reference files really do declare headings to protect" {
  # The control above plants the FIRST heading; this proves the set is the whole
  # roster rather than a single lucky entry, so a reference file that lost its
  # `##` heading (and with it its protection) reds here.
  #
  # SEVEN since #1571: residue.md gained ONE `##` section, stating why condition 2
  # was removed. (The parked-blocker handling that story surfaced is #1581's, not
  # this one's, so it adds no second heading here.) The count is deliberately exact
  # rather than a minimum — a new reference heading is a new protected
  # restatement, and it should be a decision someone made here, not one that
  # arrives unnoticed. (reference/review-loop.md's #1571 note is a PARAGRAPH,
  # not a heading, on purpose: a second `##` there also makes
  # round-boundary-wait.bats' section locator ambiguous.)
  local n
  n="$(_ref_headings | grep -c .)"
  [ "$n" -eq 7 ]
}

# --- pointers resolve -------------------------------------------------------

@test "#1503 the pointer extractor emits two non-empty fields per pointer" {
  # The heading sweep below `continue`s on a row whose file half does not resolve,
  # so an extractor that emitted the whole pointer as ONE field would make it pass
  # having checked nothing. That is not hypothetical: the first cut used
  # `sed 's/.../\1\t/'`, which emits a literal `t` on BSD sed and was therefore
  # vacuous on exactly the leg the maintainer runs. Pin the SHAPE, so the sweep
  # cannot go quiet again.
  # Over the WHOLE pointer universe, not the conductor alone: the three sweeps
  # below read the reference files too, and a malformed pointer in one of THEM
  # would otherwise vanish before every check — the same disappear-don't-reject
  # failure, closed for one file out of six. The reference files' own pointers
  # live in the connective prose OUTSIDE the byte-frozen sentinels, so the
  # verifier does not cover them either.
  local f h rows=0
  while IFS=$'\t' read -r f h; do
    [ -n "$f" ] || { echo "pointer row has an empty file field"; return 1; }
    [ -n "$h" ] || { echo "pointer row has an empty heading field: $f"; return 1; }
    case "$f" in *.md) : ;; *) echo "pointer file field is not a .md name: $f"; return 1 ;; esac
    rows=$(( rows + 1 ))
  done < <(_all_pointers)
  # EVERY raw pointer occurrence was parsed. Without this, a pointer the
  # extractor cannot match simply disappears and every sweep below reports clean
  # over a smaller set — the failure a widened charset alone does not close,
  # because the next narrowing would reintroduce it silently.
  local raw
  raw="$(_all_raw_pointer_count)" || {
    echo "could not count raw pointer occurrences"; return 1; }
  [ "$rows" -eq "$raw" ] || {
    echo "the skill holds $raw pointer occurrence(s) but the extractor parsed $rows"
    return 1
  }
}

@test "#1503 the skill carries exactly the pointers it is supposed to" {
  # A COUNT, not a floor. `-ge 5` moved WITH a deletion rather than against it:
  # delete a whole pointer line and both `rows` and `raw` drop by one and stay
  # equal, so the completeness check above cannot see it either. With 8 real
  # pointers a floor of 5 let three be deleted silently — and a delegating step
  # that loses its pointer is the failure this file's header calls worse than
  # restating, because the session reaches the step and finds no procedure.
  local rows
  rows="$(_all_pointers | grep -c .)"
  if [ "$rows" -ne 8 ]; then
    printf 'the skill carries %s pointer(s), expected 8.\n' "$rows" >&2
    printf 'A pointer was added or removed — update this count in the same PR,\n' >&2
    printf 'and check the step that gained or lost one still reaches its procedure.\n' >&2
    _all_pointers >&2
    return 1
  fi
}

@test "#1503 non-vacuity: a pointer whose filename is unconventional is still extracted" {
  # The charset guard. A narrow class does not REJECT a malformed pointer, it
  # makes the row vanish before any check runs — so prove the extractor still
  # emits one for a name outside [a-z-]+, and that the existence check is what
  # rejects it.
  local probe="$BATS_TEST_TMPDIR/odd-name.md" f h rows=0
  printf 'see `reference/review_loop.md` § The round protocol\n' > "$probe"
  while IFS=$'\t' read -r f h; do
    [ "$f" = "review_loop.md" ] || { echo "extracted the wrong file half: $f"; return 1; }
    [ "$h" = "The round protocol" ] || { echo "extracted the wrong heading: $h"; return 1; }
    rows=$(( rows + 1 ))
  done < <(_pointers_of "$probe")
  [ "$rows" -eq 1 ]
  # ...and it does not exist, which is what the sweep is entitled to report
  [ ! -f "$REF_DIR/review_loop.md" ]
}

@test "#1503 every pointer names a reference file that exists" {
  local f h bad=""
  while IFS=$'\t' read -r f h; do
    [ -n "$f" ] || continue
    [ -f "$REF_DIR/$f" ] || bad+="$f (no such file)"$'\n'
  done < <(_all_pointers)
  [ -z "$bad" ] || { printf 'dangling pointer target(s):\n%s\n' "$bad" >&2; return 1; }
}

@test "#1503 every pointer resolves to a heading in the file it names" {
  # AC3. The half that a "file exists" check cannot see: a heading renamed in
  # the reference leaves the pointer aiming into the middle of a file that has
  # no such section, and the session reaching that step finds nothing.
  local f h bad=""
  while IFS=$'\t' read -r f h; do
    [ -n "$f" ] || continue
    [ -f "$REF_DIR/$f" ] || continue   # reported by the test above
    if ! _headings_of "$REF_DIR/$f" | grep -qxF -- "$h"; then
      bad+="$f § $h"$'\n'
    fi
  done < <(_all_pointers)
  [ -z "$bad" ] || { printf 'pointer(s) naming no such heading:\n%s\n' "$bad" >&2; return 1; }
}

@test "#1503 non-vacuity: a pointer at a renamed heading reds the sweep" {
  local probe="$BATS_TEST_TMPDIR/probe.md" f h
  printf 'see `reference/residue.md` § No Such Heading At All\n' > "$probe"
  local resolved=0
  while IFS=$'\t' read -r f h; do
    _headings_of "$REF_DIR/$f" | grep -qxF -- "$h" && resolved=1
  done < <(_pointers_of "$probe")
  [ "$resolved" -eq 0 ]
  # ...and the same machinery DOES resolve the real thing, so the control is
  # measuring the sweep rather than a broken extractor
  printf 'see `reference/residue.md` § Residue branch — file the remainder, then ship (#1435)\n' > "$probe"
  resolved=0
  while IFS=$'\t' read -r f h; do
    _headings_of "$REF_DIR/$f" | grep -qxF -- "$h" && resolved=1
  done < <(_pointers_of "$probe")
  [ "$resolved" -eq 1 ]
}

@test "#1503 every reference file is pointed AT by at least one pointer" {
  # An unreferenced reference file is dead prose: nothing in the skill sends a
  # session there, so the procedure it holds is unreachable — the failure mode a
  # move is most likely to produce, and one the pointer sweep above cannot see.
  #
  # The reachable set is the whole pointer union, so reachability here is
  # TRANSITIVE: a reference file pointed at only from another reference file
  # counts. That is true of the tree today (all five are pointed at from the
  # conductor directly), but it does mean a pair of orphans pointing at each
  # other would satisfy this check.
  local targets r bad=""
  targets="$(_all_pointers | cut -f1 | sort -u)"
  for r in "$REF_DIR"/*.md; do
    printf '%s\n' "$targets" | grep -qxF -- "${r##*/}" || bad+="${r##*/}"$'\n'
  done
  [ -z "$bad" ] || { printf 'reference file(s) nothing points at:\n%s\n' "$bad" >&2; return 1; }
}

# --- the move is still byte-preserving --------------------------------------

@test "#1503 the moved chunks are byte-identical to the pre-move conductor" {
  # AC2, kept as a live seam rather than a PR-only artefact: it is the only
  # thing that can distinguish "moved" from "rewritten while moving", and a
  # later edit inside a moved chunk is exactly what #1431's children will do
  # DELIBERATELY — at which point this test is the record of what changed.
  _require_pre_move_commit
  run zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$REPO_ROOT" --quiet
  [ "$status" -eq 0 ]
}

@test "#1503 the verifier itself reds on a mutated chunk" {
  # The seam above is only worth having if it discriminates. Mutate a moved
  # chunk in a throwaway copy of the tree and show the verifier says so.
  _require_pre_move_commit
  local fake="$BATS_TEST_TMPDIR/fake-repo"
  mkdir -p "$fake/development/skills/resolve-issue"
  cp -R "$REF_DIR" "$fake/development/skills/resolve-issue/reference"
  # A git dir the script can read the base ref through. The script takes ONE
  # --repo for both the object source and the reference tree, so a fake tree
  # needs one of these.
  #
  # In a worktree `.git` is a FILE holding `gitdir: <abs path>`, and copying it
  # is both correct (it still points at the real admin dir) and cheap — which is
  # why the guard below tests the SHAPE explicitly instead of trusting `cp`'s
  # status: `cp -R` succeeds on the file, so a `|| skip` could never fire and the
  # test would silently proceed on a path its own message claimed to skip.
  if [ -e "$REPO_ROOT/.git" ]; then
    cp -R "$REPO_ROOT/.git" "$fake/.git"
  else
    skip "no .git at $REPO_ROOT — cannot stage a throwaway tree"
  fi
  printf 'MUTATED\n' >> "$fake/development/skills/resolve-issue/reference/residue.md"
  # the mutation must land INSIDE the sentinels to be seen, so splice it in
  python3 - "$fake/development/skills/resolve-issue/reference/residue.md" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
s = s.replace("Runs **only** on", "Runs only on", 1)
io.open(p, "w", encoding="utf-8").write(s)
PY
  run zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$fake" --quiet
  [ "$status" -eq 1 ]
}
