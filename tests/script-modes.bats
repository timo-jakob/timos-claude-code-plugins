#!/usr/bin/env bats
#
# The executable bit of every tracked shell script outside tests/ (#2619).
# resolve-session.zsh shipped 100644 while SKILL.md runs it by path, so every
# install hit `permission denied` (exit 126) at §0a. The invariant is swept over
# every tracked *.zsh and *.sh rather than a named list, so a script added
# without the bit fails here the day it lands — the pattern of
# bootstrap-template-modes.bats (#1632). The rule runs one way only: a shebang
# implies 100755. Sourced, shebang-less libraries keep whatever mode they have.
# The mode checked is the one git RECORDS — what a clone and an install get —
# never the working-tree bit, which is a local accident.

load assertions

setup() {
  # a git hook or `rebase --exec` exports these, and `git -C` does not override
  # them: the fixture repos' init/add would land in the REAL index
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# sweep_modes <repo-root>: print one line per tracked *.zsh / *.sh outside tests/
# that starts with `#!` but is recorded as anything other than 100755. Returns 1
# when it found any, 2 when the sweep saw no files or no shebangs (a mis-pathed
# sweep must fail, not pass vacuously), 0 otherwise.
sweep_modes() {
  local root=$1 line meta mode file first seen=0 shebangs=0 bad=()
  while IFS= read -r line; do
    # `<mode> <sha> <stage>\t<path>` — split on the tab so a path may hold spaces
    meta=${line%%$'\t'*}
    file=${line#*$'\t'}
    mode=${meta%% *}
    seen=$((seen + 1))
    first=$(head -c2 "$root/$file")
    if [ "$first" = '#!' ]; then
      shebangs=$((shebangs + 1))
      [ "$mode" = 100755 ] || bad+=("shebang but $mode: $file")
    fi
  done < <(git -C "$root" ls-files -s -- '*.zsh' '*.sh' ':(exclude)tests/')
  if [ "$seen" -eq 0 ] || [ "$shebangs" -eq 0 ]; then
    echo "vacuous sweep: $seen files, $shebangs shebangs"
    return 2
  fi
  if [ "${#bad[@]}" -gt 0 ]; then
    printf '%s\n' "${bad[@]}"
    return 1
  fi
}

# fixture_repo: a fresh git repo whose index records modes without a commit.
fixture_repo() {
  FIX="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FIX"
  git -C "$FIX" init -q
}

# add_file <path> <first-line> <+x|-x>: write and stage a file at a given mode.
add_file() {
  mkdir -p "$FIX/$(dirname "$1")"
  printf '%s\necho hi\n' "$2" > "$FIX/$1"
  git -C "$FIX" add --chmod="$3" -- "$1"
}

@test "every tracked shell script outside tests/ with a shebang is committed 100755 (#2619)" {
  run sweep_modes "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the scripts #2619 re-moded are recorded 100755" {
  local f mode
  for f in development/skills/resolve-issue/scripts/resolve-session.zsh \
           development/skills/maintenance/scripts/format-drift-issue.zsh; do
    mode=$(git -C "$REPO_ROOT" ls-files -s -- "$f" | cut -d' ' -f1)
    [ "$mode" = 100755 ] || { echo "$f is $mode"; return 1; }
  done
}

@test "shebang-less sourced libraries keep their recorded modes: the rule runs one way only" {
  local f want mode
  for f in development/scripts/telemetry/telemetry-sink-lib.zsh:100644 \
           development/skills/resolve-issue/scripts/risk-threshold-lib.zsh:100644 \
           development/skills/bootstrap/scripts/lib.sh:100755; do
    want=${f##*:}
    f=${f%:*}
    [ "$(head -c2 "$REPO_ROOT/$f")" != '#!' ] || { echo "$f has a shebang"; return 1; }
    mode=$(git -C "$REPO_ROOT" ls-files -s -- "$f" | cut -d' ' -f1)
    [ "$mode" = "$want" ] || { echo "$f is $mode, want $want"; return 1; }
  done
}

@test "the sweep fails on a shebang script recorded 100644, listing every offending path" {
  fixture_repo
  add_file good/ok.zsh '#!/usr/bin/env zsh' +x
  add_file skills/x/scripts/foo.zsh '#!/usr/bin/env zsh' -x
  add_file "with space/bar.sh" '#!/bin/sh' -x
  run sweep_modes "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "shebang but 100644: skills/x/scripts/foo.zsh"
  contains "$output" "shebang but 100644: with space/bar.sh"
  lacks "$output" "good/ok.zsh"
}

@test "the sweep passes a shebang-less library at 100644 or 100755" {
  fixture_repo
  add_file run.zsh '#!/usr/bin/env zsh' +x
  add_file lib-a.zsh '# sourced, no shebang' -x
  add_file lib-b.sh '# sourced, no shebang' +x
  run sweep_modes "$FIX"
  [ "$status" -eq 0 ]
}

@test "the sweep ignores scripts under tests/" {
  fixture_repo
  add_file run.zsh '#!/usr/bin/env zsh' +x
  add_file tests/helper.zsh '#!/usr/bin/env zsh' -x
  run sweep_modes "$FIX"
  [ "$status" -eq 0 ]
}

@test "the sweep fails, not passes vacuously, when it sees no files" {
  fixture_repo
  add_file README.md '# not a script' -x
  run sweep_modes "$FIX"
  [ "$status" -eq 2 ]
  contains "$output" "vacuous sweep: 0 files"
}

@test "the sweep fails, not passes vacuously, when it sees no shebangs" {
  fixture_repo
  add_file lib.zsh '# sourced, no shebang' -x
  run sweep_modes "$FIX"
  [ "$status" -eq 2 ]
  contains "$output" "vacuous sweep: 1 files, 0 shebangs"
}
