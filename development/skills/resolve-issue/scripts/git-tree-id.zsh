#!/usr/bin/env zsh
# git-tree-id.zsh — a deterministic identity for a repo's WORKING TREE (#981).
#
# Why: the review loop's --resume gate re-runs the FULL test suite to gate the
# previous round's in-session fix (resolve-story-loop.zsh), even when the
# driving session JUST ran that identical suite green in SKILL.md Step 3. That
# byte-identical re-verification of an unchanged tree was ~24 min in the #976
# session. Gate attestation (#981 design 1) removes the duplicate: the session
# passes the tree identity it gated green via --gate-attest, and the loop skips
# its own run ONLY on an exact match — any mismatch, absence, or failure to
# compute an identity re-runs the gate (fail-closed; the gate never weakens).
#
# The identity must therefore satisfy two properties:
#   * STABLE — the same tree content yields the same id across two computations
#     (the session's and the loop's), or the optimization never fires; and
#   * COMPLETE — it changes whenever ANY test-relevant content changes, tracked
#     OR untracked (a fix pass that adds a new test file must break the match),
#     or the skip would be a false green.
#
# COMPLETE is scoped to git's view of the tree: `git add -A` honors .gitignore,
# so a change confined to an IGNORED file (a local .env, an ignored fixture
# cache) does not move the id. Likewise a submodule records as a gitlink (its
# HEAD commit), so uncommitted edits INSIDE a submodule do not move the id. In
# these repos ignored paths are build artifacts the suite does not read and
# there are no submodules, so exposure is nil — but a caller that edits an
# ignored (or in-submodule) test-relevant file after the green gate is the one
# edit class this identity cannot catch; it must re-run the gate (not pass a
# stale attestation).
#
# `git stash create` fails COMPLETE — it ignores untracked files, so a round
# whose only change is a new untracked file would keep the same id and be
# skipped wrongly. So the id is `git write-tree` over a THROWAWAY temp index
# holding `git add -A` (tracked modifications/deletions AND untracked,
# .gitignore-respecting, files). It touches neither the real index nor the
# working tree (GIT_INDEX_FILE points at a temp file); the blob objects `add`
# writes into the object DB are harmless (as `git stash create` also writes) and
# get gc'd.
#
# Usage:  git-tree-id.zsh [REPO_PATH]     # default: .
# Output: the 40-hex tree hash on stdout, or NOTHING with a non-zero exit when
#         the path is not a git repo or git is unavailable. Callers MUST treat
#         "no identity" (empty output / non-zero exit) as fail-closed — never as
#         a match. Never touches the caller's index or working tree.
#
# Seam (tests):  GIT_TREE_ID_BIN overrides the `git` binary (the DETECT_STACK_BIN
#                convention) — point it at a missing name to force the
#                unavailable-git path, or a stub to force a canned id.

emulate -L zsh
setopt nounset

# Isolate from an inherited git environment: GIT_DIR / GIT_WORK_TREE would
# override `git -C "$repo"` and silently compute the identity for a DIFFERENT
# repo (git hooks, filters, some CI wrappers export these), and an inherited
# GIT_INDEX_FILE could leak into a git call that lacks the explicit per-command
# assignment below. Unset all three so `-C "$repo"` is authoritative.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

local repo="${1:-.}"
local git_bin="${GIT_TREE_ID_BIN:-git}"

command -v "$git_bin" >/dev/null 2>&1 || exit 1
"$git_bin" -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || exit 1

local tmp_index
tmp_index="$(mktemp "${TMPDIR:-/tmp}/git-tree-id.XXXXXX")" || exit 1
# always remove the throwaway index, however we leave
trap 'rm -f -- "$tmp_index"' EXIT

# Seed the temp index from HEAD when there is one (so `add -A` records deletions
# too); an unborn branch (no commits yet) starts from an empty index.
if ! GIT_INDEX_FILE="$tmp_index" "$git_bin" -C "$repo" read-tree HEAD 2>/dev/null; then
  GIT_INDEX_FILE="$tmp_index" "$git_bin" -C "$repo" read-tree --empty 2>/dev/null || exit 1
fi

# Stage every change — tracked edits/removals and untracked (.gitignore-honored)
# additions — into the temp index, then hash it. `add -A` failing (nothing to do
# is exit 0; a real failure is not) leaves us with the HEAD tree, so gate it.
GIT_INDEX_FILE="$tmp_index" "$git_bin" -C "$repo" add -A 2>/dev/null || exit 1

local tree
tree="$(GIT_INDEX_FILE="$tmp_index" "$git_bin" -C "$repo" write-tree 2>/dev/null)" || exit 1
[[ -n "$tree" ]] || exit 1
print -r -- "$tree"
