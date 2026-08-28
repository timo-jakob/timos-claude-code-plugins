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
# is now driven except the two NAMED below (the empty-MANIFEST guard and the source-range branch) — one reachable through the CLI, one
# that needs a mutated copy of the script — both tracked in **#1551**. The count
# is deliberately not restated as a numeral: #1582 added three sweep arms and a
# numeral would have gone stale in the same edit that added
# them. This block is the map — read it as the whole answer, because the
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
# sweep including a digit-bearing name; the duplicate-sentinel check; the
# separate reporting of chunk failures vs sentinel problems; and (#1582) all
# three split-span sweep arms — the halves out of ORDER, a split sentinel
# MISSING, and a split sentinel DUPLICATED (the last of which the stray sweep
# cannot see, since it greps only the opening form) — plus the inherited
# GIT_DIR/GIT_WORK_TREE scrub, driven under both names and under GIT_WORK_TREE
# alone.
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
# NOT driven, deliberately: the branch printing `could not locate the
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
#   * SENTINEL / CHUNK behaviour needs a tree whose eight declared chunks
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
  contains "$output" "sentinel problem"
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
  # the heading the rule lives under is still the protocol's own
  grep -qF -- '## The round protocol' "$f"
  # build the scope block from scope_abs[], not changed_files alone
  grep -qF -- 'Build each reviewer'"'"'s scope block from the plan'"'"'s `scope_abs[]`' "$f"
  # the negation, pinned on the clause it actually turns on rather than on a
  # generic `never from` that any future sentence could satisfy
  grep -qF -- '`changed_files` alone (#1582)' "$f"
  # It names the frozen instruction it governs. Anchored on the NEW sentence, not
  # on the quoted fragment: `scoped to the plan's `changed_files`` also occurs
  # inside the byte-frozen tail chunk, where it can never be removed — so a
  # whole-file grep for it can only ever match and would prove nothing.
  grep -qF -- 'This governs step 1 below, whose frozen text' "$f"

  # POSITION, not just presence. Every needle above is a whole-file grep, so
  # without this the entire rule block could be moved to the end of the file —
  # below the protocol it governs — with the suite still green.
  local head_close tail_open rule
  head_close=$(grep -nxF -- '<!-- /moved: round-protocol-head -->' "$f" | cut -d: -f1)
  tail_open=$(grep -nxF -- '<!-- moved: round-protocol-tail -->' "$f" | cut -d: -f1)
  rule=$(grep -nF -- "Build each reviewer's scope block" "$f" | cut -d: -f1)
  # one per line: in an `&&`-list only the LAST status reaches errexit, so a
  # joined guard reads as three checks and is one (#1067)
  [ -n "$head_close" ]
  [ -n "$tail_open" ]
  [ -n "$rule" ]
  [ "$rule" -gt "$head_close" ]
  [ "$rule" -lt "$tail_open" ]
}

@test "#1582 BOTH forms of the verbatim reviewer sentence are stated" {
  local f="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md"
  # whitespace-normalised, for the same reason as the relay test below: these are
  # reflowed blockquote sentences, and a line-oriented needle over them passes or
  # fails on where the paragraph happens to wrap
  local flat
  flat="$(tr '\n' ' ' < "$f" | tr -s ' ' | sed 's/> //g')"
  # two-clause form, for a linked worktree
  printf '%s' "$flat" | grep -qF -- "Read every file you are given under \`<worktree_root>\`; this run's tree is that directory, not \`<original_root>\`."
  # single-clause form, for original_root == null
  printf '%s' "$flat" | grep -qF -- "Read every file you are given under \`<worktree_root>\`. Report every finding's"
  # the prohibition that makes the null case unambiguous
  grep -qF -- 'Never render the literal `null` into the sentence.' "$f"
  # the sentence must not be readable as a SCOPE instruction — it names which
  # tree, never how much of it
  grep -qF -- 'it never widens the round'"'"'s scope' "$f"
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
  flat="$(tr '\n' ' ' < "$f" | tr -s ' ' | sed 's/> //g')"
  # BOTH forms carry the reporting sentence — the two-clause one and the
  # first-clause-only one for `original_root: null`
  [ "$(printf '%s' "$flat" | grep -o -- "Report every finding's \`file\` using the repo-relative name shown for it in the scope block — never the absolute path you read." | wc -l | tr -d ' ')" -eq 2 ]
  grep -qF -- 'so the reviewer is who' "$f"
  # the scope block must carry BOTH spellings, or the reporting rule above names
  # a column the prompt does not contain — the contradiction two reviewers found
  grep -qF -- 'giving **both spellings of every file**' "$f"
  grep -qF -- 'Both, not either' "$f"
}

@test "#1582 the rule keeps a finding's .file repo-relative" {
  local f="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md"
  grep -qF -- "A finding's \`.file\` stays repo-relative" "$f"
  # the load-bearing prohibition — scope_abs[] is the absolute spelling a
  # reviewer now HAS to hand, so forbidding it is the operative half
  grep -qF -- 'never an entry from `scope_abs[]`' "$f"
  grep -qF -- 'silently DISCARDS' "$f"
}

@test "#1582 the rule carries the work-dir subtraction, the confirm step and the deletion arm" {
  local f="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md"
  # scope_abs is the RAW changed_files joined to the root, so the subtraction
  # step 1 mandates has to be restated for the absolute list or the panel gets
  # dispatched over the loop's own state
  grep -qF -- 'same `--work-dir` subtraction' "$f"
  # plan reports the roots of whatever --repo it was handed; it cannot know it
  # was the right one
  grep -qF -- 'First confirm the descriptor describes the tree the STORY was implemented in' "$f"
  # ...and the arm a naive cwd test gets backwards: an epic child runs in its own
  # worktree while the invoking session's cwd stays at the original checkout, so
  # a cwd mismatch on a CORRECT descriptor must not trigger a re-plan
  grep -qF -- 'even when that' "$f"
  grep -qF -- 'Never re-plan against your cwd' "$f"
  # and the re-plan arm must keep the round-scoping flags — a bare
  # `plan --repo <wt>` defaults --round to 1 and silently reviews the whole diff
  grep -qF -- 'every other flag unchanged' "$f"
  # changed_files lists deletions, so scope_abs provably contains unreadable paths
  grep -qF -- 'a file the story DELETED' "$f"
  # the deletion excerpt is ROOTED at the descriptor's tree, not at your cwd —
  # the same hazard the confirm step above exists for
  grep -qF -- 'root the command at the tree the descriptor names' "$f"
  # ...and an empty excerpt is a stop, or a `[DELETED]` marking tells the
  # reviewer not to question a file nobody reviewed
  grep -qF -- 'An EMPTY excerpt is a stop' "$f"
  # the carried entries are the one thing a reviewer opens beyond the scope
  # block, and they get the same both-spellings treatment
  grep -qF -- 'The carried entries are the one exception' "$f"
  grep -qF -- 'Carried entries to verify' "$f"
  # and the deletion arm reaches the REVIEWER, who is the party that opens the
  # missing path — the same relay failure as the reporting rule
  grep -qF -- '[DELETED by this story]' "$f"
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
  local head_close tail_open span
  head_close=$(grep -nxF -- '<!-- /moved: round-protocol-head -->' "$f" | cut -d: -f1)
  tail_open=$(grep -nxF -- '<!-- moved: round-protocol-tail -->' "$f" | cut -d: -f1)
  # one per line, same reason as above (#1067)
  [ -n "$head_close" ]
  [ -n "$tail_open" ]
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

  # ...and the script really enforces it, rather than merely documenting it —
  # a declared-but-unapplied invariant would leave this test the only checker
  grep -qF -- 'split anchors are no longer adjacent' "$VERIFY"
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
  local v="$REPO_ROOT/development/skills/resolve-issue/scripts/verify-reference-move.zsh"
  grep -qF -- 'verified by NOTHING' "$v"
  grep -qF -- 'SPLIT into head + tail (#1582)' "$v"
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
  hc=$(grep -nxF -- '<!-- /moved: round-protocol-head -->' "$f" | cut -d: -f1)
  to=$(grep -nxF -- '<!-- moved: round-protocol-tail -->' "$f" | cut -d: -f1)
  sed -i.bak -e "${hc}s|.*|<!-- moved: round-protocol-tail -->|" \
             -e "${to}s|.*|<!-- /moved: round-protocol-head -->|" "$f"
  rm -f "$f.bak"

  run zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$fake"
  [ "$status" -eq 1 ]
  contains "$stderr$output" "the split halves are out of order"
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

  # GIT_WORK_TREE alone, so neither name can be dropped from the scrub
  # independently
  run -0 env GIT_WORK_TREE="$other" \
    zsh "$VERIFY" --base "$PRE_MOVE_SHA" --repo "$REPO_ROOT" --quiet
  [ -z "$output" ]
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
