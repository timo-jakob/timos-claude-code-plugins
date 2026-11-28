#!/usr/bin/env bats
#
# The linked docs repository of /development:bootstrap (#3355, epic #3198):
# `--docs-repo <url>` mounts a docs repository as a submodule pinned to its
# newest version tag, marked `reference-docs = true` in `.gitmodules`, and binds
# it in CLAUDE.md with the `## Linked reference documents` section.
# link-reference-docs.zsh runs here for real, against local bare fixture
# repositories reached by an absolute path (no network); the template and the
# SKILL.md step are pinned clause by clause.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  # a git hook or `rebase --exec` exports these, and `git -C` does not override
  # them: the fixture repos would land in the REAL index
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GITHUB_ACTIONS
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BS="$REPO_ROOT/development/skills/bootstrap"
  SCRIPT="$BS/scripts/link-reference-docs.zsh"
  TMPL="$BS/templates/common/claude-md-linked-reference-docs.md.tmpl"
  SKILL="$BS/SKILL.md"
  W="$BATS_TEST_TMPDIR"
  # an isolated git: no signing, a fixed identity, and the file protocol a
  # local submodule remote needs (git refuses it by default since 2.38.1)
  printf '[user]\n\tname = Fixture\n\temail = fixture@example.invalid\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n[protocol "file"]\n\tallow = always\n' > "$W/gitconfig"
  export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
}

# A bare docs repository at $1, one commit per tag in $2..., then a commit past
# the last tag on main (the branch head a fallback would pick).
make_docs() {
  local bare="$1" work="$1.work" t
  shift
  git init -q "$work"
  mkdir -p "$work/docs/architecture"
  for t in "$@"; do
    printf '# Target architecture %s\n' "$t" > "$work/docs/architecture/target-architecture.md"
    git -C "$work" add -A
    git -C "$work" commit -qm "release $t"
    git -C "$work" tag "$t"
  done
  printf 'unreleased\n' > "$work/docs/architecture/target-architecture.md"
  git -C "$work" commit -qam "unreleased work"
  git clone -q --bare "$work" "$bare"
}

# A service repo at $1 with one commit (and $2 as its CLAUDE.md, when given).
make_app() {
  git init -q "$1"
  printf 'service\n' > "$1/README.md"
  [ -z "${2-}" ] || printf '%s' "$2" > "$1/CLAUDE.md"
  git -C "$1" add -A
  git -C "$1" commit -qm init
}

tagged_commit() { git -C "$1" rev-parse "refs/tags/$2^{commit}"; }

# .gitmodules, the index and the git config, as one comparable fingerprint.
repo_state() {
  local f
  for f in "$1/.gitmodules" "$1/.git/index" "$1/.git/config"; do
    if [ -f "$f" ]; then cksum < "$f"; else printf 'absent\n'; fi
  done
  git -C "$1" status --porcelain 2>/dev/null || true
}

# --- apply: the add ---------------------------------------------------------------

@test "apply: pins the newest version tag, marks the entry, writes no branch line, stages and never commits" {
  make_docs "$W/docs.git" v1.2.0 v1.10.0
  make_app "$W/app"
  local head_before
  head_before="$(git -C "$W/app" rev-parse HEAD)"
  run --separate-stderr zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  [ "$status" -eq 0 ]
  [ "$output" = linked ]
  [ -z "$stderr" ]
  [ "$(git -C "$W/app/linked-docs" rev-parse HEAD)" = "$(tagged_commit "$W/docs.git" v1.10.0)" ]
  [ "$(git -C "$W/app" config -f .gitmodules submodule.linked-docs.path)" = linked-docs ]
  [ "$(git -C "$W/app" config -f .gitmodules submodule.linked-docs.url)" = "$W/docs.git" ]
  [ "$(git -C "$W/app" config -f .gitmodules submodule.linked-docs.reference-docs)" = true ]
  run git -C "$W/app" config -f .gitmodules --get-regexp 'branch'
  [ "$status" -eq 1 ]
  run git -C "$W/app" diff --cached --name-only
  [ "$output" = $'.gitmodules\nlinked-docs' ]
  [ "$(git -C "$W/app" ls-files -s linked-docs | awk '{print $1, $2}')" = "160000 $(tagged_commit "$W/docs.git" v1.10.0)" ]
  [ "$(git -C "$W/app" rev-parse HEAD)" = "$head_before" ]
}

@test "apply: the tag order is numeric per part; pre-release and other tags are ignored" {
  make_docs "$W/docs.git" v1.9.0 v1.10.0 1.2.0 v2.0.0-rc.1 nightly v01.0.0 v1.10
  make_app "$W/app"
  run zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  [ "$status" -eq 0 ]
  [ "$(git -C "$W/app/linked-docs" rev-parse HEAD)" = "$(tagged_commit "$W/docs.git" v1.10.0)" ]
}

@test "apply: the patch and major parts order numerically too" {
  make_docs "$W/p.git" v0.1.2 v0.1.10 v0.1.9
  make_docs "$W/m.git" v9.0.0 v10.0.0 v2.0.0
  make_app "$W/app"
  run zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/p.git" --path p
  [ "$status" -eq 0 ]
  [ "$(git -C "$W/app/p" rev-parse HEAD)" = "$(tagged_commit "$W/p.git" v0.1.10)" ]
  run zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/m.git" --path m
  [ "$status" -eq 0 ]
  [ "$(git -C "$W/app/m" rev-parse HEAD)" = "$(tagged_commit "$W/m.git" v10.0.0)" ]
}

@test "apply: the bare X.Y.Z form counts, and the v form wins where both name one version" {
  make_docs "$W/bare.git" 1.2.0 1.10.0
  make_docs "$W/both.git" 1.10.0 v1.10.0 1.9.0
  make_app "$W/app"
  run zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/bare.git" --path a
  [ "$status" -eq 0 ]
  [ "$(git -C "$W/app/a" rev-parse HEAD)" = "$(tagged_commit "$W/bare.git" 1.10.0)" ]
  run zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/both.git" --path b
  [ "$status" -eq 0 ]
  [ "$(git -C "$W/app/b" rev-parse HEAD)" = "$(tagged_commit "$W/both.git" v1.10.0)" ]
  [ "$(tagged_commit "$W/both.git" v1.10.0)" != "$(tagged_commit "$W/both.git" 1.10.0)" ]
}

@test "apply: an annotated version tag pins its commit, not the tag object" {
  make_docs "$W/docs.git" v1.0.0
  git -C "$W/docs.git.work" tag -a v1.1.0 -m annotated HEAD
  git -C "$W/docs.git.work" push -q "$W/docs.git" v1.1.0
  make_app "$W/app"
  run zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  [ "$status" -eq 0 ]
  [ "$(git -C "$W/app/linked-docs" rev-parse HEAD)" = "$(tagged_commit "$W/docs.git" v1.1.0)" ]
}

@test "apply: a URL with a scheme is absolute and mounts" {
  make_docs "$W/docs.git" v1.0.0
  make_app "$W/app"
  run zsh "$SCRIPT" apply --repo-dir "$W/app" --url "file://$W/docs.git"
  [ "$status" -eq 0 ]
  [ "$output" = linked ]
  [ "$(git -C "$W/app" config -f .gitmodules submodule.linked-docs.url)" = "file://$W/docs.git" ]
}

@test "apply: a repo and a mount whose paths hold spaces" {
  make_docs "$W/docs.git" v1.2.0 v1.10.0
  make_app "$W/my service"
  run zsh "$SCRIPT" apply --repo-dir "$W/my service" --url "$W/docs.git" --path "linked docs"
  [ "$status" -eq 0 ]
  [ "$output" = linked ]
  [ "$(git -C "$W/my service" config -f .gitmodules 'submodule.linked docs.reference-docs')" = true ]
  run zsh "$SCRIPT" check --repo-dir "$W/my service" --url "$W/docs.git" --path "linked docs"
  [ "$status" -eq 0 ]
  [ "$output" = linked ]
}

@test "apply: a nested mount and a trailing slash name the same mount" {
  make_docs "$W/docs.git" v1.0.0
  make_app "$W/app"
  run zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git" --path docs/linked/
  [ "$status" -eq 0 ]
  [ "$(git -C "$W/app" config -f .gitmodules submodule.docs/linked.path)" = docs/linked ]
  run zsh "$SCRIPT" check --repo-dir "$W/app" --url "$W/docs.git" --path docs/linked
  [ "$status" -eq 0 ]
}

@test "apply: a repo with another submodule keeps that entry byte for byte" {
  make_docs "$W/docs.git" v1.0.0
  make_app "$W/app"
  printf '[submodule "styleguide"]\n\tpath = styleguide\n\turl = https://example.invalid/sg.git\n' > "$W/app/.gitmodules"
  run zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  [ "$status" -eq 0 ]
  [ "$(head -n 3 "$W/app/.gitmodules")" = "$(printf '[submodule "styleguide"]\n\tpath = styleguide\n\turl = https://example.invalid/sg.git')" ]
  run git -C "$W/app" config -f .gitmodules submodule.styleguide.reference-docs
  [ "$status" -eq 1 ]
}

# --- check, and the re-run ---------------------------------------------------------

@test "check: gap before the apply, linked after it; neither changes a byte nor reads the remote" {
  make_docs "$W/docs.git" v1.0.0
  make_app "$W/app"
  local before
  before="$(repo_state "$W/app")"
  mv "$W/docs.git" "$W/away.git"
  run --separate-stderr zsh "$SCRIPT" check --repo-dir "$W/app" --url "$W/docs.git"
  [ "$status" -eq 1 ]
  [ "$output" = gap ]
  [ -z "$stderr" ]
  [ "$(repo_state "$W/app")" = "$before" ]
  mv "$W/away.git" "$W/docs.git"
  run zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  [ "$status" -eq 0 ]
  before="$(repo_state "$W/app")"
  mv "$W/docs.git" "$W/away.git"
  run --separate-stderr zsh "$SCRIPT" check --repo-dir "$W/app" --url "$W/docs.git"
  [ "$status" -eq 0 ]
  [ "$output" = linked ]
  [ -z "$stderr" ]
  [ "$(repo_state "$W/app")" = "$before" ]
}

@test "apply: a re-run on a linked repo reads no remote, prints linked and changes no byte" {
  make_docs "$W/docs.git" v1.0.0 v1.1.0
  make_app "$W/app"
  run zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  [ "$status" -eq 0 ]
  local before head
  before="$(repo_state "$W/app")"
  head="$(git -C "$W/app/linked-docs" rev-parse HEAD)"
  git -C "$W/docs.git.work" tag v1.11.0
  git -C "$W/docs.git.work" push -q "$W/docs.git" v1.11.0
  run --separate-stderr zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  [ "$status" -eq 0 ]
  [ "$output" = linked ]
  [ -z "$stderr" ]
  [ "$(repo_state "$W/app")" = "$before" ]
  [ "$(git -C "$W/app/linked-docs" rev-parse HEAD)" = "$head" ]
}

@test "apply: a submodule of that URL without the key gets the key, keeps its pin and reads no remote" {
  make_docs "$W/docs.git" v1.2.0 v1.10.0
  make_app "$W/app"
  git -C "$W/app" submodule --quiet add --name linked-docs -- "$W/docs.git" linked-docs
  git -C "$W/app/linked-docs" -c advice.detachedHead=false checkout -q v1.2.0
  git -C "$W/app" add linked-docs .gitmodules
  git -C "$W/app" commit -qm "docs by hand"
  run zsh "$SCRIPT" check --repo-dir "$W/app" --url "$W/docs.git"
  [ "$status" -eq 1 ]
  [ "$output" = gap ]
  mv "$W/docs.git" "$W/away.git"
  run --separate-stderr zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  [ "$status" -eq 0 ]
  [ "$output" = linked ]
  [ -z "$stderr" ]
  [ "$(git -C "$W/app" config -f .gitmodules submodule.linked-docs.reference-docs)" = true ]
  run git -C "$W/app" diff --cached --name-only
  [ "$output" = .gitmodules ]
  [ "$(git -C "$W/app" ls-files -s linked-docs | awk '{print $2}')" = "$(tagged_commit "$W/away.git" v1.2.0)" ]
}

@test "check: a key git does not read as true is no link" {
  make_docs "$W/docs.git" v1.0.0
  make_app "$W/app"
  run zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  git -C "$W/app" config -f .gitmodules submodule.linked-docs.reference-docs false
  run zsh "$SCRIPT" check --repo-dir "$W/app" --url "$W/docs.git"
  [ "$status" -eq 1 ]
  [ "$output" = gap ]
}

# --- the stops --------------------------------------------------------------------

# Run $@ and assert stop <code>: nothing on stdout, one line on stderr, and the
# repo's .gitmodules, index, config and status unchanged.
assert_stop() {
  local code="$1" repo="$2" before
  shift 2
  before="$(repo_state "$repo")"
  run --separate-stderr "$@"
  [ "$status" -eq "$code" ] || { echo "status $status, want $code: $stderr"; return 1; }
  [ -z "$output" ] || { echo "stdout: $output"; return 1; }
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ] || { echo "stderr: $stderr"; return 1; }
  starts_with "$stderr" "link-reference-docs: " || return 1
  [ "$(repo_state "$repo")" = "$before" ] || { echo "the repo changed"; return 1; }
}

@test "stop 3: an unreachable URL, stdin closed, names the URL and returns at once" {
  make_app "$W/app"
  assert_stop 3 "$W/app" zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/no-such-docs.git" </dev/null
  contains "$stderr" "$W/no-such-docs.git"
  [ ! -e "$W/app/linked-docs" ]
  [ ! -e "$W/app/.gitmodules" ]
}

@test "stop 3: an scp-style URL that cannot be read prompts for nothing" {
  make_app "$W/app"
  GIT_SSH_COMMAND=false assert_stop 3 "$W/app" zsh "$SCRIPT" apply --repo-dir "$W/app" --url "git@example.invalid:org/docs.git" </dev/null
  contains "$stderr" "git@example.invalid:org/docs.git"
}

@test "stop 3: the remote read runs with the terminal prompt and askpass off, and ssh in batch mode" {
  make_app "$W/app"
  unset GIT_SSH_COMMAND GIT_SSH
  git -C "$W/app" config core.sshCommand "ssh -i k"
  local real
  real="$(command -v git)"
  mkdir -p "$W/bin"
  # a git that records the prompt environment of its ls-remote call, then fails it
  printf '#!/bin/sh\ncase "$*" in *ls-remote*) printf "%%s|%%s|%%s|%%s\\n" "$GIT_TERMINAL_PROMPT" "$GIT_ASKPASS" "$SSH_ASKPASS" "$GIT_SSH_COMMAND" > "%s/env"; exit 128 ;; esac\nexec "%s" "$@"\n' "$W" "$real" > "$W/bin/git"
  chmod +x "$W/bin/git"
  PATH="$W/bin:$PATH" assert_stop 3 "$W/app" zsh "$SCRIPT" apply --repo-dir "$W/app" --url "https://example.invalid/docs.git"
  [ "$(cat "$W/env")" = "0|false|false|ssh -i k -o BatchMode=yes" ]
}

@test "stop 4: a repository with no version tag says to tag one, and never checks out the branch head" {
  make_docs "$W/docs.git" nightly v2.0.0-rc.1 v1.0 01.2.3
  make_app "$W/app"
  assert_stop 4 "$W/app" zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  contains "$stderr" "no version tag"
  contains "$stderr" "tag a release"
  [ ! -e "$W/app/linked-docs" ]
  [ ! -e "$W/app/.gitmodules" ]
}

@test "stop 5: a plain directory at the mount stays untouched, for check and apply" {
  make_docs "$W/docs.git" v1.0.0
  make_app "$W/app"
  mkdir "$W/app/linked-docs"
  printf 'our notes\n' > "$W/app/linked-docs/notes.md"
  assert_stop 5 "$W/app" zsh "$SCRIPT" check --repo-dir "$W/app" --url "$W/docs.git"
  assert_stop 5 "$W/app" zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  [ "$(cat "$W/app/linked-docs/notes.md")" = "our notes" ]
}

@test "stop 5: a submodule of another URL at the mount, for check and apply" {
  make_docs "$W/docs.git" v1.0.0
  make_docs "$W/other.git" v1.0.0
  make_app "$W/app"
  git -C "$W/app" submodule --quiet add --name linked-docs -- "$W/other.git" linked-docs
  assert_stop 5 "$W/app" zsh "$SCRIPT" check --repo-dir "$W/app" --url "$W/docs.git"
  assert_stop 5 "$W/app" zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  contains "$stderr" "linked-docs exists and is not a submodule of $W/docs.git"
}

@test "stop 5: the URL is compared byte for byte; another spelling is another URL" {
  make_docs "$W/docs.git" v1.0.0
  make_app "$W/app"
  run zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  [ "$status" -eq 0 ]
  assert_stop 5 "$W/app" zsh "$SCRIPT" check --repo-dir "$W/app" --url "file://$W/docs.git"
}

@test "stop 5: an untracked file, a dangling symlink or an index-only path at the mount" {
  make_docs "$W/docs.git" v1.0.0
  make_app "$W/app"
  printf 'x\n' > "$W/app/linked-docs"
  assert_stop 5 "$W/app" zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  rm "$W/app/linked-docs"
  ln -s "$W/nowhere" "$W/app/linked-docs"
  assert_stop 5 "$W/app" zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  [ -L "$W/app/linked-docs" ]
  rm "$W/app/linked-docs"
  mkdir "$W/app/linked-docs"
  printf 'x\n' > "$W/app/linked-docs/x"
  git -C "$W/app" add -A
  git -C "$W/app" commit -qm x
  rm -rf "$W/app/linked-docs"
  assert_stop 5 "$W/app" zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
}

@test "stop 6: --repo-dir outside a git repo, below its root, or missing, for check and apply" {
  make_app "$W/app"
  mkdir -p "$W/plain" "$W/app/sub"
  assert_stop 6 "$W/plain" zsh "$SCRIPT" apply --repo-dir "$W/plain" --url "$W/docs.git"
  assert_stop 6 "$W/plain" zsh "$SCRIPT" check --repo-dir "$W/plain" --url "$W/docs.git"
  assert_stop 6 "$W/app" zsh "$SCRIPT" apply --repo-dir "$W/app/sub" --url "$W/docs.git"
  assert_stop 6 "$W/app" zsh "$SCRIPT" check --repo-dir "$W/no-such-dir" --url "$W/docs.git"
}

@test "stop 7: a failed git step after the checks undoes the whole add" {
  make_docs "$W/docs.git" v1.0.0
  make_app "$W/app"
  printf '[submodule "styleguide"]\n\tpath = styleguide\n\turl = https://example.invalid/sg.git\n' > "$W/app/.gitmodules"
  git -C "$W/app" add .gitmodules
  git -C "$W/app" commit -qm gm
  local real row
  real="$(command -v git)"
  mkdir -p "$W/bin"
  # <the git call the wrapper intercepts>|<what it does instead>|<the reason>.
  # The add really runs and then reports failure, so there is something to undo.
  for row in \
    'submodule --quiet add|"$real" "$@"; exit 1|git submodule add of' \
    'fetch --quiet origin|exit 1|cannot fetch v1.0.0' \
    'checkout --quiet --detach|exit 1|cannot check out v1.0.0' \
    'checkout --quiet --detach|exit 0|the checkout is not at v1.0.0' \
    'reference-docs true|exit 1|cannot set the reference-docs key' \
    'add -- .gitmodules|exit 1|cannot stage the submodule'; do
    printf '#!/bin/sh\nreal="%s"\ncase "$*" in *"%s"*) %s ;; esac\nexec "$real" "$@"\n' \
      "$real" "${row%%|*}" "$(printf '%s' "$row" | cut -d'|' -f2)" > "$W/bin/git"
    chmod +x "$W/bin/git"
    PATH="$W/bin:$PATH" assert_stop 7 "$W/app" zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git" || { echo "$row"; false; }
    contains "$stderr" "${row##*|}"
    [ ! -e "$W/app/linked-docs" ]
    [ ! -e "$W/app/.git/modules/linked-docs" ]
    run git -C "$W/app" config --get-regexp '^submodule\.'
    [ "$status" -eq 1 ]
  done
}

@test "stop 7: a failed staging of the key alone restores .gitmodules" {
  make_docs "$W/docs.git" v1.0.0
  make_app "$W/app"
  git -C "$W/app" submodule --quiet add --name linked-docs -- "$W/docs.git" linked-docs
  git -C "$W/app" commit -qm "docs by hand"
  local real
  real="$(command -v git)"
  mkdir -p "$W/bin"
  printf '#!/bin/sh\ncase "$*" in *"add -- .gitmodules"*) exit 1 ;; esac\nexec "%s" "$@"\n' "$real" > "$W/bin/git"
  chmod +x "$W/bin/git"
  PATH="$W/bin:$PATH" assert_stop 7 "$W/app" zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  contains "$stderr" "cannot stage .gitmodules"
  run git -C "$W/app" config -f .gitmodules submodule.linked-docs.reference-docs
  [ "$status" -eq 1 ]
}

@test "stop 7: a failure in a repo with no index yet leaves no index behind" {
  make_docs "$W/docs.git" v1.0.0
  git init -q "$W/app"
  [ ! -e "$W/app/.git/index" ]
  local real
  real="$(command -v git)"
  mkdir -p "$W/bin"
  printf '#!/bin/sh\ncase "$*" in *"fetch --quiet origin"*) exit 1 ;; esac\nexec "%s" "$@"\n' "$real" > "$W/bin/git"
  chmod +x "$W/bin/git"
  PATH="$W/bin:$PATH" run --separate-stderr zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  [ "$status" -eq 7 ]
  [ ! -e "$W/app/.git/index" ]
  [ ! -e "$W/app/linked-docs" ]
}

@test "stop 7: a stale submodule git directory stops before any write" {
  make_docs "$W/docs.git" v1.0.0
  make_app "$W/app"
  mkdir -p "$W/app/.git/modules/linked-docs"
  assert_stop 7 "$W/app" zsh "$SCRIPT" apply --repo-dir "$W/app" --url "$W/docs.git"
  contains "$stderr" "a stale submodule git directory exists at "
  [ -d "$W/app/.git/modules/linked-docs" ]
  [ ! -e "$W/app/linked-docs" ]
}

# --- usage ------------------------------------------------------------------------

@test "usage: every malformed call is exit 2 with the usage on stderr, writing nothing" {
  make_app "$W/app"
  local args
  for args in \
    '' \
    'bogus' \
    'apply --repo-dir APP' \
    'check --url /abs' \
    'apply --repo-dir APP --url ../docs' \
    'apply --repo-dir APP --url ./docs' \
    'apply --repo-dir APP --url docs' \
    'apply --repo-dir APP --url /abs --path /abs' \
    'apply --repo-dir APP --url /abs --path ../out' \
    'apply --repo-dir APP --url /abs --path a/../b' \
    'apply --repo-dir APP --url /abs --path .git' \
    'apply --repo-dir APP --url /abs --path -x' \
    'apply --repo-dir APP --url /abs --bogus x' \
    'apply --repo-dir APP --url' \
    'check --repo-dir APP --url /abs --claude-md CM' \
    'check-section' \
    'check-section --claude-md CM --template TM' \
    'check-section --claude-md CM --url /abs' \
    'apply-section --claude-md CM' \
    'apply-section --claude-md CM --template NOPE'; do
    printf '# Ours\n' > "$W/cm.md"
    # shellcheck disable=SC2086  # word-split on purpose: one call per row
    set -- $args
    set -- "${@/APP/$W/app}"
    set -- "${@/CM/$W/cm.md}"
    set -- "${@/TM/$TMPL}"
    set -- "${@/NOPE/$W/no-such.tmpl}"
    run --separate-stderr zsh "$SCRIPT" "$@"
    [ "$status" -eq 2 ] || { echo "'$args': status $status"; return 1; }
    [ -z "$output" ] || { echo "'$args': stdout $output"; return 1; }
    contains "$stderr" "usage: link-reference-docs.zsh check|apply"
    [ "$(cat "$W/cm.md")" = "# Ours" ]
  done
  [ ! -e "$W/app/.gitmodules" ]
}

# --- check-section / apply-section --------------------------------------------------

@test "section: check-section is gap without the section, present with it, case and trailing blanks ignored" {
  printf '# Ours\n' > "$W/CLAUDE.md"
  run --separate-stderr zsh "$SCRIPT" check-section --claude-md "$W/CLAUDE.md"
  [ "$status" -eq 1 ]
  [ "$output" = gap ]
  printf '# Ours\n\n## LINKED reference DOCUMENTS  \r\n' > "$W/CLAUDE.md"
  run zsh "$SCRIPT" check-section --claude-md "$W/CLAUDE.md"
  [ "$status" -eq 0 ]
  [ "$output" = present ]
}

@test "section: a heading inside a fence or mid-line is no section" {
  printf '# Ours\n\n```md\n## Linked reference documents\n```\n\nSee ## Linked reference documents.\n' > "$W/CLAUDE.md"
  run zsh "$SCRIPT" check-section --claude-md "$W/CLAUDE.md"
  [ "$status" -eq 1 ]
  [ "$output" = gap ]
}

@test "section: apply-section appends the template's section after one blank line and keeps every byte" {
  printf '# Ours\n\nKeep this.\n' > "$W/CLAUDE.md"
  cp "$W/CLAUDE.md" "$W/before.md"
  run --separate-stderr zsh "$SCRIPT" apply-section --claude-md "$W/CLAUDE.md" --template "$TMPL"
  [ "$status" -eq 0 ]
  [ "$output" = applied ]
  [ "$(head -c "$(wc -c < "$W/before.md")" "$W/CLAUDE.md" | cksum)" = "$(cksum < "$W/before.md")" ]
  { cat "$W/before.md"; printf '\n'; cat "$TMPL"; } > "$W/want.md"
  cmp "$W/CLAUDE.md" "$W/want.md"
}

@test "section: a second apply-section is present and changes no byte" {
  printf '# Ours\n' > "$W/CLAUDE.md"
  run zsh "$SCRIPT" apply-section --claude-md "$W/CLAUDE.md" --template "$TMPL"
  [ "$status" -eq 0 ]
  cp "$W/CLAUDE.md" "$W/once.md"
  run zsh "$SCRIPT" apply-section --claude-md "$W/CLAUDE.md" --template "$TMPL"
  [ "$status" -eq 0 ]
  [ "$output" = present ]
  cmp "$W/CLAUDE.md" "$W/once.md"
}

@test "section: an empty file gets no separator; a missing final newline gets one" {
  : > "$W/empty.md"
  run zsh "$SCRIPT" apply-section --claude-md "$W/empty.md" --template "$TMPL"
  [ "$status" -eq 0 ]
  cmp "$W/empty.md" "$TMPL"
  printf '# Ours' > "$W/nonl.md"
  run zsh "$SCRIPT" apply-section --claude-md "$W/nonl.md" --template "$TMPL"
  [ "$status" -eq 0 ]
  { printf '# Ours\n\n'; cat "$TMPL"; } > "$W/want.md"
  cmp "$W/nonl.md" "$W/want.md"
}

@test "section: a CRLF file gets the section in CRLF" {
  printf '# Ours\r\n' > "$W/crlf.md"
  run zsh "$SCRIPT" apply-section --claude-md "$W/crlf.md" --template "$TMPL"
  [ "$status" -eq 0 ]
  { printf '# Ours\r\n\r\n'; sed 's/$/\r/' "$TMPL"; } > "$W/want.md"
  cmp "$W/crlf.md" "$W/want.md"
}

@test "section: no such file is exit 3 for both commands and creates nothing" {
  run --separate-stderr zsh "$SCRIPT" check-section --claude-md "$W/none.md"
  [ "$status" -eq 3 ]
  run --separate-stderr zsh "$SCRIPT" apply-section --claude-md "$W/none.md" --template "$TMPL"
  [ "$status" -eq 3 ]
  [ ! -e "$W/none.md" ]
}

@test "section: a template without the section or with a placeholder is exit 4 and writes nothing" {
  printf '# Ours\n' > "$W/CLAUDE.md"
  printf '## Who decides what\n\nx\n' > "$W/other.tmpl"
  run --separate-stderr zsh "$SCRIPT" apply-section --claude-md "$W/CLAUDE.md" --template "$W/other.tmpl"
  [ "$status" -eq 4 ]
  printf '## Linked reference documents\n\n{{PROJECT_NAME}}\n' > "$W/raw.tmpl"
  run --separate-stderr zsh "$SCRIPT" apply-section --claude-md "$W/CLAUDE.md" --template "$W/raw.tmpl"
  [ "$status" -eq 4 ]
  [ "$(cat "$W/CLAUDE.md")" = "# Ours" ]
}

@test "section: an unreadable or unwritable file is exit 5, never a gap" {
  [ "$(id -u)" != 0 ] || skip "root reads and writes any file"
  printf '# Ours\n' > "$W/CLAUDE.md"
  chmod 000 "$W/CLAUDE.md"
  run --separate-stderr zsh "$SCRIPT" check-section --claude-md "$W/CLAUDE.md"
  chmod 644 "$W/CLAUDE.md"
  [ "$status" -eq 5 ]
  chmod 444 "$W/CLAUDE.md"
  run --separate-stderr zsh "$SCRIPT" apply-section --claude-md "$W/CLAUDE.md" --template "$TMPL"
  chmod 644 "$W/CLAUDE.md"
  [ "$status" -eq 5 ]
  [ "$(cat "$W/CLAUDE.md")" = "# Ours" ]
}

# --- the template -------------------------------------------------------------------

# The template with its hard wraps joined, so a statement is pinned wherever it wraps.
flat_tmpl() { tr '\n' ' ' < "$TMPL" | tr -s ' '; }

@test "template: the section carries each binding statement" {
  local t
  t="$(flat_tmpl)"
  [ "$(head -n 1 "$TMPL")" = "## Linked reference documents" ]
  contains "$t" 'The git submodules marked `reference-docs` in `.gitmodules` hold the reference documents this repo is built against, such as a target architecture or a styleguide.'
  contains "$t" "Read them before a technical decision."
  contains "$t" "Where they and the plugin family's defaults differ, they win."
  contains "$t" "Cite the clause you follow."
  contains "$t" "Never edit a file under a link's mount"
  contains "$t" "Never move a pin by hand"
  contains "$t" 'An empty mount is fixed with `git submodule update --init`.'
}

@test "template: no placeholder, no mount path, one H2, and CLAUDE.md.tmpl carries no copy" {
  local t
  t="$(cat "$TMPL")"
  lacks "$t" "{{"
  lacks "$t" "linked-docs"
  lacks "$t" "styleguide/"
  [ "$(grep -c '^## ' "$TMPL")" -eq 1 ]
  run grep -c "Linked reference documents" "$BS/templates/common/CLAUDE.md.tmpl"
  [ "$output" = 0 ]
}

# --- SKILL.md -----------------------------------------------------------------------

# SKILL.md with hard wraps joined, so a sentence is pinned whole wherever it wraps.
flat_skill() { tr '\n' ' ' < "$SKILL" | tr -s ' '; }

@test "skill: the --docs-repo flag, its plan line and the step's heading" {
  local s
  s="$(flat_skill)"
  contains "$s" '- `--docs-repo <url>` — a docs repository you control'
  contains "$s" "Never asked for: without the flag nothing is linked."
  contains "$s" "**3a.1. Linked docs repository (\`--docs-repo\`, #3355).** Links a docs repository the repo owner controls"
  contains "$s" 'Linked docs: <url> → linked-docs/ at its newest version tag, and the CLAUDE.md section "## Linked reference documents" # --docs-repo only (§3a.1)'
  contains "$s" 'The `Linked docs:` line** is shown only with `--docs-repo <url>` (§3a.1), naming the link and the section. Without the flag and with no marked submodule the plan mentions neither; a marked submodule whose `CLAUDE.md` lacks the section is reported as §3a.1'"'"'s State D gap.'
  contains "$s" "Without the flag and with no marked submodule, the plan mentions neither the link nor the section and nothing changes."
}

@test "skill: the step runs apply then apply-section once CLAUDE.md exists, and a stop continues bootstrap" {
  local s
  s="$(flat_skill)"
  contains "$s" "**Run the script** in Step 3, once \`CLAUDE.md\` exists — after §3a's render of it — from the repository root, with absolute paths:"
  contains "$s" '"<skill-base-dir>/scripts/link-reference-docs.zsh" apply --repo-dir "<repo-path>" --url "<url>"'
  contains "$s" '--template "<skill-base-dir>/templates/common/claude-md-linked-reference-docs.md.tmpl"'
  contains "$s" "The Step 5 summary names the URL and the reason (its stderr line), **no section is appended**, and the rest of bootstrap continues."
  contains "$s" "**The report names a stopped docs link** (§3a.1, #3355): when \`link-reference-docs.zsh check\` or \`apply\` stopped, one outstanding item names the URL and the reason from its stderr line"
}

@test "skill: the State D gap is closed like the decision-rights one and keeps the no-drift stop open" {
  local s
  s="$(flat_skill)"
  contains "$s" "A repo with a marked submodule whose \`CLAUDE.md\` lacks the section is an **adoption gap**, closed like the decision-rights one"
  contains "$s" '`link-reference-docs.zsh check-section --claude-md "<repo-path>/CLAUDE.md"` in every State D run that has a marked submodule, before any of steps 3, 4 and 5 ends the run.'
  contains "$s" "Exit 1 is the gap — report it in the Step 2 plan as \"\`CLAUDE.md\` lacks the linked reference documents section\" and, on confirmation, run \`apply-section\` as above."
  contains "$s" "So does a pending linked-docs gap (§3a.1, #3355 — its checks run before this stop is decided): do not stop — continue to the Step 2 plan."
}

@test "skill: the recorded --path and styleguide wording, and the Dependabot sentence" {
  local s
  s="$(flat_skill)"
  contains "$s" 'A further docs repository is linked by running `link-reference-docs.zsh apply` with `--path <mount>`. The `styleguide/` submodule of §3k.5a is mounted by its own script, does not carry the `reference-docs` key and is not a linked docs repository: the `## Linked reference documents` section does not cover it.'
  contains "$s" "Where \`.github/dependabot.yml\` carries a \`gitsubmodule\` entry, Dependabot may propose a move of a linked docs repository's pin, and such a PR is closed, not merged, because the pin moves to version tags only."
}

@test "skill: the step's trigger, plan, apply-section and State D link sentences are pinned whole" {
  local s
  s="$(flat_skill)"
  contains "$s" '`--docs-repo <url>` — a docs repository you control, such as the one holding your target architecture, linked as the `linked-docs/` submodule pinned to its newest version tag and bound in `CLAUDE.md` (§3a.1, #3355).'
  contains "$s" '**Trigger.** `--docs-repo <url>`.'
  contains "$s" "A marked submodule is one whose key git reads as true in \`git config -f .gitmodules --type=bool --get-regexp '^submodule\\..*\\.reference-docs\$'\`."
  contains "$s" 'With `--docs-repo <url>` the plan'"'"'s `Linked docs:` line lists the link (`.gitmodules` and `linked-docs/`) and the `CLAUDE.md` section.'
  contains "$s" 'the submodule is at the mount, checked out at the newest version tag, `.gitmodules` carries the key and no `branch` line, and both are **staged, never committed**: they land in bootstrap'"'"'s one commit (4d). A re-run, or a submodule of that URL that only lacked the key, contacts no remote and keeps its pin. Then run `apply-section` — only after `apply` printed `linked`, never in the same shell call as `apply`:'
  contains "$s" '**exit 2** — a usage error. A `--docs-repo` value that is not absolute is the user'"'"'s and is never rewritten: it is the stop above, its reason the first stderr line. Any other exit 2 is your own malformed call: fix it and re-run.'
  contains "$s" '**`apply-section`** takes the exit codes of the decision-rights rule'"'"'s `apply` (*State D — the decision-rights rule'"'"'s adoption gap*, §3a): exit 0 `applied` or `present`; exit 4 or 5 is an outstanding Step 5 item.'
  contains "$s" 'With `--docs-repo <url>`, also run `check` with the same `--repo-dir` and `--url` (it contacts no remote): exit 1 offers the link in the plan, and `apply` closes it on confirmation; exit 0 needs nothing; exit 5 or 6 is the same stop as `apply`'"'"'s — the link is not offered, `apply` is not run, and the URL and the reason are reported: in the Step 5 summary, or with the no-drift stop'"'"'s message when the run ends there.'
}

@test "plugin: every new file of the step lies under the bootstrap skill" {
  [ -x "$SCRIPT" ]
  [ -f "$TMPL" ]
  run git -C "$REPO_ROOT" ls-files -- 'development/skills/bootstrap/scripts/link-reference-docs.zsh' 'development/skills/bootstrap/templates/common/claude-md-linked-reference-docs.md.tmpl'
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
}
