#!/usr/bin/env bats
#
# development/skills/resolve-issue/scripts/init-submodules.zsh — a resolve-issue
# work tree's git submodules are ready before its first gate (#3080). What these
# pin down, against real local repos in a temp dir (no network):
#
#   * WITH .gitmodules — a fresh clone's submodule is initialised: a file inside
#     it is present after the script, absent before.
#   * WITHOUT .gitmodules — no `git submodule` command runs at all, and the
#     script reports `none`.
#   * FAILURE — an update that cannot fetch exits 3 and says environment error,
#     not a red gate, quoting git's stderr.
#   * WIRING — §1 runs it after the branch, the §0a --resume checkout and the
#     checkpoint resume run it before §1b, and a chain step's worktree gets it.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  # a git hook or `rebase --exec` exports these, and `git -C` does not override
  # them: the fixture repos' init/add would land in the REAL index
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_DIR="$REPO_ROOT/development/skills/resolve-issue"
  S="$SKILL_DIR/scripts/init-submodules.zsh"
  T="$BATS_TEST_TMPDIR"
  export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"
  mkdir -p "$HOME"
  git config --global user.name t
  git config --global user.email t@example.invalid
  git config --global init.defaultBranch main
  git config --global commit.gpgsign false
  # a local path submodule is a `file` transport, which git refuses by default
  git config --global protocol.file.allow always
}

# new_repo <dir> <file> — a repo with one commit adding <file>
new_repo() {
  git init -q "$1"
  printf '%s\n' "$2" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "add $2"
}

# super_with_sub — $T/super records $T/sub at vendor/sub; $T/clone is a fresh
# clone of it whose submodule is NOT initialised (a new work tree's state)
super_with_sub() {
  new_repo "$T/sub" inside.txt
  new_repo "$T/super" top.txt
  git -C "$T/super" submodule -q add "$T/sub" vendor/sub 2>/dev/null
  git -C "$T/super" commit -q -m "add submodule"
  git clone -q "$T/super" "$T/clone" 2>/dev/null
}

@test "#3080 with .gitmodules: the submodule is initialised, a file inside it present" {
  super_with_sub
  [ ! -e "$T/clone/vendor/sub/inside.txt" ]
  run zsh "$S" --repo-dir "$T/clone"
  [ "$status" -eq 0 ]
  [ "$output" = '{"submodules":"initialised"}' ]
  [ -f "$T/clone/vendor/sub/inside.txt" ]
}

@test "#3080 with .gitmodules: a subdirectory as --repo-dir initialises from the top" {
  super_with_sub
  mkdir -p "$T/clone/deep"
  run zsh "$S" --repo-dir "$T/clone/deep"
  [ "$status" -eq 0 ]
  [ -f "$T/clone/vendor/sub/inside.txt" ]
}

@test "#3080 without .gitmodules: no git submodule command runs, and the report is none" {
  new_repo "$T/plain" a.txt
  # a git on PATH that logs every invocation, then runs the real one
  local real; real="$(command -v git)"
  mkdir -p "$T/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/git.log"\nexec "%s" "$@"\n' "$T" "$real" > "$T/bin/git"
  chmod +x "$T/bin/git"
  : > "$T/git.log"
  PATH="$T/bin:$PATH" run zsh "$S" --repo-dir "$T/plain"
  [ "$status" -eq 0 ]
  [ "$output" = '{"submodules":"none"}' ]
  # the stub did see the script (the log is not vacuously empty)...
  [ -s "$T/git.log" ]
  # ...and none of its calls was a submodule command
  run grep -c submodule "$T/git.log"
  [ "$output" = 0 ]
}

@test "#3080 failure: an update that cannot fetch exits 3 as an environment error" {
  super_with_sub
  # the recorded URL now points nowhere, so the clone of the submodule fails
  git -C "$T/clone" config -f .gitmodules submodule.vendor/sub.url "$T/missing.git"
  rm -rf "$T/sub"
  run --separate-stderr zsh "$S" --repo-dir "$T/clone"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'environment error, not a red gate: git submodule update --init --recursive failed'
  # git's own stderr is quoted, so the cause is visible
  contains "$stderr" 'missing.git'
  [ ! -e "$T/clone/vendor/sub/inside.txt" ]
}

@test "#3080 usage: a missing or unknown flag, or a non-repo, is exit 2" {
  run zsh "$S"
  [ "$status" -eq 2 ]
  run zsh "$S" --bogus
  [ "$status" -eq 2 ]
  run zsh "$S" --repo-dir
  [ "$status" -eq 2 ]
  mkdir -p "$T/notrepo"
  run --separate-stderr zsh "$S" --repo-dir "$T/notrepo"
  [ "$status" -eq 2 ]
  contains "$stderr" 'not a git work tree'
}

@test "#3080 wiring: §1, the --resume checkouts and a chain step's worktree run it before the gate" {
  local skill ckpt steps
  skill="$(tr '\n' ' ' < "$SKILL_DIR/SKILL.md" | tr -s ' ')"
  contains "$skill" '"<skill-base-dir>/scripts/init-submodules.zsh" --repo-dir .'
  contains "$skill" '# then ready the tree'"'"'s submodules before any gate (#3080): exit 3 is an environment error, never a red gate — stop "<skill-base-dir>/scripts/init-submodules.zsh" --repo-dir .'
  contains "$skill" 'Then enter the interactive extension with the marker (`reference/interactive/extension.md`). Run §1'"'"'s `init-submodules.zsh` on that checkout before its first gate (#3080).'
  ckpt="$(tr '\n' ' ' < "$SKILL_DIR/reference/checkpoint.md" | tr -s ' ')"
  contains "$ckpt" 'Then make its submodules ready with `init-submodules.zsh`, as §1 does after a fresh branch (#3080): its exit 3 is an environment error, never a red gate, so report it as one, emit the run'"'"'s record as `failed` and stop. Then run §1b.'
  steps="$(tr '\n' ' ' < "$SKILL_DIR/reference/chain-steps.md" | tr -s ' ')"
  contains "$steps" 'Either way the step'"'"'s §1 runs `init-submodules.zsh` in that work tree before its first gate (#3080)'
  contains "$steps" 'a submodule initialisation that exits 3, an environment error (#3080);'
}
