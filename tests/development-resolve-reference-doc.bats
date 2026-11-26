#!/usr/bin/env bats
#
# The development-side lookup of a linked reference document (#3351, child 1
# of #3198): development/scripts/reference-docs/resolve-reference-doc.zsh
# finds a document with the byte-identical copy of the product lookup and adds
# the pinned version — the gitlink commit the superproject's HEAD records.
#
# Every fixture is invented and built locally in setup() and the helpers below:
# a throwaway superproject and nested repositories created with `git init`, and
# gitlinks written straight into the index. No network, no `git submodule add`,
# nothing taken from any real docs repository.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  # a git hook or `rebase --exec` exports these, and `git -C` does not override
  # them: the fixture repos' init/add would land in the REAL index
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  # scripts that annotate under Actions would change stderr on CI only
  unset GITHUB_ACTIONS
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  D="$REPO_ROOT/development/scripts/reference-docs"
  S="$D/resolve-reference-doc.zsh"
  COPY="$D/resolve-product-doc.zsh"
  CANON="$REPO_ROOT/product/scripts/resolve-product-doc.zsh"
  R="$BATS_TEST_TMPDIR/super repo"
  DOC="architecture/target.md"
  mkdir -p "$R"
  g -C "$R" init -q
  printf 'Harbor Freight Ledger\n' > "$R/README.md"
  g -C "$R" add -- README.md
  g -C "$R" commit -q -m "superproject"
}

# g <git args> — git with an invented identity, no signing and no hooks, so the
# host's global config cannot change a fixture
g() {
  git -c user.name="Fixture Author" -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null -c init.defaultBranch=main "$@"
}

# declare_sub <path> — append a .gitmodules entry for <path>, marked as a linked
# reference-docs repository
declare_sub() {
  printf '[submodule "%s"]\n\tpath = %s\n\turl = https://example.invalid/docs.git\n\treference-docs = true\n' \
    "$1" "$1" >> "$R/.gitmodules"
}

# init_sub <path> — an invented docs repository at <path> holding the document;
# prints nothing, sets SHA to its HEAD
init_sub() {
  mkdir -p "$R/$1/architecture"
  g -C "$R/$1" init -q
  printf '# Target architecture\n\nServices talk gRPC inside, REST outside.\n' > "$R/$1/$DOC"
  g -C "$R/$1" add -- "$DOC"
  g -C "$R/$1" commit -q -m "target architecture v1"
  SHA="$(git -C "$R/$1" rev-parse HEAD)"
}

# pin_sub <path> — commit .gitmodules and the gitlink HEAD records for <path>
pin_sub() {
  g -C "$R" update-index --add --cacheinfo 160000 "$SHA" "$1"
  g -C "$R" add -- .gitmodules
  g -C "$R" commit -q -m "link $1"
}

# linked <path> — the whole linked-docs fixture at <path>
linked() {
  declare_sub "$1"
  init_sub "$1"
  pin_sub "$1"
}

# --- the copy ---------------------------------------------------------------

@test "the development copy of the lookup is byte-identical to the product one" {
  [ -s "$CANON" ]
  [ -x "$COPY" ]
  cmp "$COPY" "$CANON"
}

@test "the cmp check fails when either copy changes alone" {
  local a="$BATS_TEST_TMPDIR/a.zsh" b="$BATS_TEST_TMPDIR/b.zsh"
  cp "$CANON" "$a"
  cp "$COPY" "$b"
  cmp "$a" "$b"
  printf '\n' >> "$a"
  run cmp "$a" "$b"
  [ "$status" -eq 1 ]
  cp "$CANON" "$a"
  printf '# drift\n' >> "$b"
  run cmp "$a" "$b"
  [ "$status" -eq 1 ]
}

# --- found ------------------------------------------------------------------

@test "the repo's own file: origin own, submodule and pinned_commit null" {
  mkdir -p "$R/architecture"
  printf '# Target architecture\n' > "$R/$DOC"
  run --separate-stderr zsh "$S" --repo-dir "$R" "$DOC"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  jq -e --arg p "$(cd "$R" && pwd -P)/$DOC" '.path == $p and .origin == "own" and .submodule == null and .pinned_commit == null and (keys | length) == 4' <<<"$output"
}

@test "a linked file: origin linked, its submodule and the full gitlink SHA HEAD records" {
  linked arch-docs
  run --separate-stderr zsh "$S" --repo-dir "$R" "$DOC"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${#SHA}" -eq 40 ]
  jq -e --arg p "$(cd "$R/arch-docs" && pwd -P)/$DOC" --arg sha "$SHA" '.path == $p and .origin == "linked" and .submodule == "arch-docs" and .pinned_commit == $sha' <<<"$output"
}

@test "--repo-dir defaults to the current directory" {
  linked arch-docs
  cd "$R"
  run --separate-stderr zsh "$S" "$DOC"
  [ "$status" -eq 0 ]
  jq -e --arg sha "$SHA" '.origin == "linked" and .pinned_commit == $sha' <<<"$output"
}

@test "--help prints the usage on stdout and exits 0" {
  run --separate-stderr zsh "$S" --help
  [ "$status" -eq 0 ]
  contains "$output" 'usage: resolve-reference-doc.zsh [--repo-dir <dir>] <relative-path>'
}

# --- paths with spaces ------------------------------------------------------

@test "a repo and a submodule whose paths hold spaces resolve, pinned commit included" {
  linked "linked docs"
  run --separate-stderr zsh "$S" --repo-dir "$R" "$DOC"
  [ "$status" -eq 0 ]
  jq -e --arg p "$(cd "$R/linked docs" && pwd -P)/$DOC" --arg sha "$SHA" '.path == $p and .submodule == "linked docs" and .pinned_commit == $sha' <<<"$output"
}

# --- the stops: nothing on stdout -------------------------------------------

@test "usage errors exit 2 with nothing on stdout" {
  run --separate-stderr zsh "$S"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'a relative path is required'
  run --separate-stderr zsh "$S" --bogus "$DOC"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'unknown flag: --bogus'
  run --separate-stderr zsh "$S" --repo-dir
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr zsh "$S" --repo-dir "$BATS_TEST_TMPDIR/no such dir" "$DOC"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" '--repo-dir is not a directory'
  run --separate-stderr zsh "$S" "$DOC" other.md
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'more than one path given'
}

@test "not found exits 3 with nothing on stdout" {
  linked arch-docs
  run --separate-stderr zsh "$S" --repo-dir "$R" docs/missing.md
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'not found: docs/missing.md'
}

@test "an uninitialised declared submodule exits 4, naming it and the init line" {
  declare_sub arch-docs
  g -C "$R" add -- .gitmodules
  g -C "$R" commit -q -m "declare arch-docs"
  run --separate-stderr zsh "$S" --repo-dir "$R" "$DOC"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  contains "$stderr" 'submodule not initialised: arch-docs'
  contains "$stderr" 'git submodule update --init'
}

@test "a path under a submodule's mount exits 5 with nothing on stdout" {
  linked arch-docs
  run --separate-stderr zsh "$S" --repo-dir "$R" "arch-docs/$DOC"
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  contains "$stderr" "lies inside submodule arch-docs"
}

@test "a submodule checked out off its pin exits 6, naming both short SHAs and the init line" {
  linked arch-docs
  local pinned="$SHA" moved
  printf 'Services talk gRPC inside, REST outside, events on NATS.\n' >> "$R/arch-docs/$DOC"
  g -C "$R/arch-docs" commit -q -am "target architecture v2"
  moved="$(git -C "$R/arch-docs" rev-parse HEAD)"
  run --separate-stderr zsh "$S" --repo-dir "$R" "$DOC"
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  contains "$stderr" "checked out at ${moved:0:12}, not at its pinned ${pinned:0:12}"
  contains "$stderr" 'run: git submodule update --init -- arch-docs'
}

@test "exit 6 quotes a submodule path that holds a space in its init line" {
  linked "linked docs"
  printf 'v2\n' >> "$R/linked docs/$DOC"
  g -C "$R/linked docs" commit -q -am "v2"
  run --separate-stderr zsh "$S" --repo-dir "$R" "$DOC"
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  contains "$stderr" "run: git submodule update --init -- 'linked docs'"
}

# --- no pinned version: exit 1 ----------------------------------------------

@test "a declared submodule whose gitlink is not committed yet exits 1, naming the uncommitted link" {
  declare_sub arch-docs
  init_sub arch-docs
  g -C "$R" add -- .gitmodules
  g -C "$R" commit -q -m "declare arch-docs, link not committed"
  run --separate-stderr zsh "$S" --repo-dir "$R" "$DOC"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" 'arch-docs has no pinned version'
  contains "$stderr" 'the link is not committed yet'
}

@test "a linked hit whose submodule directory is no checkout of its own exits 1" {
  declare_sub arch-docs
  init_sub arch-docs
  pin_sub arch-docs
  rm -rf "$R/arch-docs/.git"
  run --separate-stderr zsh "$S" --repo-dir "$R" "$DOC"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" 'cannot read the commit checked out in submodule arch-docs'
}

# --- the contract's statement -----------------------------------------------

@test "ARCHITECTURE.md's Linked reference documents section states the four rules" {
  local section
  section="$(sed -n '/^### Linked reference documents$/,/^## /p' "$REPO_ROOT/ARCHITECTURE.md")"
  [ -n "$section" ]
  contains "$section" 'lookup rule stated in [The `product` plugin](#the-product-plugin--outside-the-languagetopic-model)'
  contains "$section" 'The pinned version of a linked document is the commit the superproject records:'
  contains "$section" 'A linked repository is marked in `.gitmodules` by the key `reference-docs = true` on its'
  contains "$section" '`development/scripts/reference-docs/resolve-reference-doc.zsh [--repo-dir <dir>] <relative-path>`'
  contains "$section" 'It exits 0 found, 2 usage, 3 not found, 4 a declared submodule is not'
  contains "$section" 'holding the file is checked out at a commit other than the pinned one, and 1'
}

@test "docs/reference/repo-scripts.md lists both scripts" {
  local page="$REPO_ROOT/docs/reference/repo-scripts.md"
  run grep -c -e '^| `resolve-product-doc.zsh` |' -e '^| `resolve-reference-doc.zsh` |' "$page"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}
