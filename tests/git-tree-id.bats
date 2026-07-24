#!/usr/bin/env bats
#
# Behavioural tests for git-tree-id.zsh (#981): the deterministic working-tree
# identity behind gate attestation. What these pin down:
#   * STABLE — the same tree yields the same id across two computations (so the
#     session's attestation and the loop's check can exact-match);
#   * COMPLETE — the id changes on ANY tracked OR untracked (non-ignored) change,
#     including a brand-new untracked file (the explicit reason `git write-tree`
#     over a temp index was chosen over `git stash create`, which is blind to
#     untracked files and would false-match);
#   * .gitignore boundary — an ignored file's change does NOT move the id;
#   * fail-closed — a non-repo or an unavailable git yields empty stdout + a
#     non-zero exit, so callers never read "no identity" as a match;
#   * the unborn-branch path (no commits yet) still produces an id;
#   * NO MUTATION — it never touches the caller's index or working tree.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/git-tree-id.zsh"

  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  echo base > "$R/f.txt"
  git -C "$R" add -A
  git -C "$R" commit -qm base
}

id_of() { zsh "$S" "$R"; }

@test "STABLE: two computations of the same tree produce the same id" {
  local a b
  a="$(id_of)"; b="$(id_of)"
  [ -n "$a" ]
  [ "$a" = "$b" ]
  [[ "$a" =~ ^[0-9a-f]{40}$ ]] || [[ "$a" =~ ^[0-9a-f]{64}$ ]]
}

@test "COMPLETE: a modified TRACKED file changes the id" {
  local before after
  before="$(id_of)"
  echo changed >> "$R/f.txt"
  after="$(id_of)"
  [ "$before" != "$after" ]
}

@test "COMPLETE: a NEW UNTRACKED file changes the id (the git-stash-create trap)" {
  local before after
  before="$(id_of)"
  echo new > "$R/untracked.txt"       # never added — git stash create would miss this
  after="$(id_of)"
  [ "$before" != "$after" ]
  # and removing it returns to the original id (the change is exactly this file)
  rm -f "$R/untracked.txt"
  [ "$(id_of)" = "$before" ]
}

@test "COMPLETE: a deleted tracked file changes the id" {
  local before after
  before="$(id_of)"
  rm -f "$R/f.txt"
  after="$(id_of)"
  [ "$before" != "$after" ]
}

@test "COMPLETE: the id follows the WORKING TREE, not a stale/divergent real index" {
  # the false-green class this must prevent is 'worktree changed, id didn't'.
  # The id is built by seeding a temp index from HEAD then `add -A` the worktree,
  # so it must reflect the worktree regardless of what the REAL index holds.
  local pristine; pristine="$(id_of)"          # clean worktree == HEAD ("base")
  echo staged-only > "$R/f.txt"
  git -C "$R" add f.txt                          # REAL index now diverges from HEAD
  printf 'base\n' > "$R/f.txt"                    # worktree restored to HEAD content
  # index says 'staged-only', worktree says 'base' — the id must track the worktree
  [ "$(id_of)" = "$pristine" ]
}

@test ".gitignore boundary: a change to an IGNORED file does NOT move the id" {
  printf 'ignored/\n' > "$R/.gitignore"
  git -C "$R" add .gitignore && git -C "$R" commit -qm ignore
  mkdir -p "$R/ignored"
  local before after
  before="$(id_of)"
  echo secret > "$R/ignored/local.env"   # ignored -> invisible to the identity
  after="$(id_of)"
  [ "$before" = "$after" ]
}

@test "path spelling is irrelevant: relative-cwd and absolute-path agree" {
  local abs rel
  abs="$(zsh "$S" "$R")"
  rel="$(cd "$R" && zsh "$S" .)"
  [ "$abs" = "$rel" ]
}

@test "fail-closed: a non-git directory yields empty stdout and a non-zero exit" {
  local nonrepo="$BATS_TEST_TMPDIR/plain"
  mkdir -p "$nonrepo"
  run zsh "$S" "$nonrepo"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "fail-closed: git unavailable (GIT_TREE_ID_BIN) yields empty stdout, non-zero exit" {
  run env GIT_TREE_ID_BIN="$BATS_TEST_TMPDIR/no-such-git" zsh "$S" "$R"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "unborn branch (no commits yet) still yields an id" {
  local fresh="$BATS_TEST_TMPDIR/unborn"
  mkdir -p "$fresh"
  git -C "$fresh" init -q          # no commit -> no HEAD
  echo x > "$fresh/a.txt"
  run zsh "$S" "$fresh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{40}$ ]] || [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

@test "NO MUTATION: the caller's index and working tree are untouched" {
  # a dirty-but-unstaged tree before the call...
  echo pending >> "$R/f.txt"
  echo brand-new > "$R/n.txt"
  local porcelain_before; porcelain_before="$(git -C "$R" status --porcelain)"
  local staged_before; staged_before="$(git -C "$R" diff --cached --name-only)"
  id_of >/dev/null
  # ...must be byte-identical after
  [ "$(git -C "$R" status --porcelain)" = "$porcelain_before" ]
  [ "$(git -C "$R" diff --cached --name-only)" = "$staged_before" ]
  # nothing got staged (the temp index absorbed the add -A, not the real one)
  [ -z "$staged_before" ]
  [ -z "$(git -C "$R" diff --cached --name-only)" ]
}
