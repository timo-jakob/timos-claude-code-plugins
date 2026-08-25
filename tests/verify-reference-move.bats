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
# WHAT THIS FILE DOES AND DOES NOT REACH. Every fail-closed branch in the script
# is now driven except TWO — one reachable through the CLI, one that needs a
# mutated copy of the script — both named below and both tracked in **#1551**. This block is the map — read it as the whole answer, because the
# rounds it was written in learned twice that a not-reached list one branch short
# is the same defect as no list at all. Branches are cited by their CODE, never
# by line number: an earlier cut of this block pinned `script :279` / `:196` and
# both rotted inside the very round that wrote them, which is what the repo's
# anchor-by-content rule (#1189) is about.
#
# Driven here: an unknown argument; both empty-flag guards; a `--repo` that is
# not a directory; a `--base` that is not a commit; a `--base` whose commit has
# no SKILL.md (`could not read`); the script-relative `--repo` DEFAULT;
# `--quiet`'s suppression; a chunk whose bytes DIFFER, with its first-difference
# report; the empty-chunk refusal; a missing reference file; a chunk whose
# sentinel PAIR is gone (`no <!-- moved: NAME --> block`); the stray-sentinel
# sweep including a digit-bearing name; the duplicate-sentinel check; and the
# separate reporting of chunk failures vs sentinel problems.
#
# NOT driven (1 of 2), and deleting it ships green today: the
# `(( ${#MANIFEST} == 0 ))` guard. Its driver needs a `sed`-mutated copy of the
# script — a fixture family *A fix pass subtracts* rule 4 forbids a fix pass from
# adding. Be precise about what its absence costs, because the earlier wording
# here was wrong and #1551 carries the correction: an emptied MANIFEST against
# the REAL reference tree is still caught, by the stray-sentinel sweep, which
# finds seven sentinels no manifest row declares and exits 1 — measured, not
# reasoned. The guard is the second net for the case where BOTH were lost
# together (an emptied manifest AND a reference tree carrying no sentinels),
# which is the only state that would otherwise reach `all 0 declared chunks are
# byte-identical` at exit 0.
#
# NOT driven (2 of 2), deliberately: the branch printing `could not locate the
# source range`. #1551 carries it with its mutation. The obvious driver —
# `--base HEAD`, on the theory that HEAD's SKILL.md is the post-move conductor —
# does NOT work during the window that matters: the review loop gates the STAGED
# tree, so while this PR is in flight HEAD is still the pre-move commit (it is
# byte-identical to PRE_MOVE_DEFAULT right now), every anchor resolves, and the
# case would exit 0. A driver that only starts working after the commit it is
# meant to guard is not a driver.
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
#   * SENTINEL / CHUNK behaviour needs a tree whose seven declared chunks
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

@test "#1547 the real tree verifies, reporting all seven declared chunks" {
  _require_pre_move_commit
  run -0 zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$REPO_ROOT"
  contains "$output" "all 7 declared chunks are byte-identical"
}

@test "#1547 --quiet suppresses the ok lines and the summary, leaving stdout empty" {
  # `--quiet` is what CI and the conductor invoke, and every other invocation in
  # the tree — here and in resolve-issue-conductor-budget.bats — reads only the
  # status. So `--quiet) quiet=0 ;;` would make the flag a no-op, print seven
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
  contains "$output" "all 7 declared chunks are byte-identical"
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
  # The two counts share no denominator: N undeclared sentinels is not "N of 7
  # chunks did not move verbatim". Reporting them together is how a reader is
  # sent to look for a prose regression that did not happen.
  _require_pre_move_commit
  local fake; fake="$(_fake_tree both)"
  {
    printf '\n<!-- moved: undeclared-chunk -->\n'
    printf 'x\n'
    printf '<!-- /moved: undeclared-chunk -->\n'
  } >> "$fake/development/skills/resolve-issue/reference/residue.md"
  run -1 zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$fake"
  contains "$output" "sentinel problem"
  # no chunk actually differs, so the chunk line must be absent
  lacks "$output" "did not move verbatim"
}
