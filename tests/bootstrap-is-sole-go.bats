#!/usr/bin/env bats
#
# is-sole-go.zsh — the one statement of the sole-Go predicate (#2128, #2615): a
# repo is sole-Go when its primary is `go` and it has no auxiliary JavaScript,
# Python or Java. Swift does not count. render.zsh's SOLE_GO / NOT_SOLE_GO tags,
# refresh-toolchain-files.zsh, branch protection (#2616) and the folded-job skip
# (#2617) all take their answer from it.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SOLE="$REPO_ROOT/development/skills/bootstrap/scripts/is-sole-go.zsh"
}

@test "#2615: is-sole-go exits 0 for a go primary alone and for go with swift, printing nothing" {
  local langs
  for langs in "go" "go swift" "swift go" ""; do
    run --separate-stderr zsh "$SOLE" --primary go --languages "$langs"
    [ "$status" -eq 0 ] || { echo "languages '$langs' -> $status"; return 1; }
    [ -z "$output" ]
    [ -z "$stderr" ]
  done
}

@test "#2615: is-sole-go exits 1 for go with javascript, python or java, and for a non-Go primary" {
  local langs
  for langs in "go python" "go javascript" "go java" "go swift python" "python go"; do
    run --separate-stderr zsh "$SOLE" --primary go --languages "$langs"
    [ "$status" -eq 1 ] || { echo "languages '$langs' -> $status"; return 1; }
    [ -z "$output" ]
  done
  local primary
  for primary in python java javascript swift claude-plugin kubernetes golang ""; do
    run --separate-stderr zsh "$SOLE" --primary "$primary" --languages go
    [ "$status" -eq 1 ] || { echo "primary '$primary' -> $status"; return 1; }
    [ -z "$output" ]
  done
}

@test "#2615: is-sole-go exits 2 on a missing flag, a dangling flag or an unknown argument" {
  run --separate-stderr zsh "$SOLE" --languages go
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "--primary is required"
  run --separate-stderr zsh "$SOLE" --primary go
  [ "$status" -eq 2 ]
  contains "$stderr" "--languages is required"
  run --separate-stderr zsh "$SOLE" --primary go --languages
  [ "$status" -eq 2 ]
  contains "$stderr" "--languages needs a value"
  run --separate-stderr zsh "$SOLE" --primary go --languages go --docker true
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown argument: --docker"
  run --separate-stderr zsh "$SOLE"
  [ "$status" -eq 2 ]
  contains "$stderr" "usage: is-sole-go.zsh"
}
