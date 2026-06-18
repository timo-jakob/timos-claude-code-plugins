#!/usr/bin/env bats
#
# Tests for derive-release-scope.zsh — the Conventional-Commits -> SemVer scope
# deriver shipped by /development:bootstrap for Java release workflows (#310).
# It is how the release pipeline obeys SemVer automatically: breaking -> major,
# feat -> minor, anything else -> patch, computed from the commits since the
# last tag.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/development/skills/bootstrap/templates/languages/java/scripts/derive-release-scope.zsh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
  cd "$WORK"
  git init -q
  git config user.email t@t
  git config user.name t
  git commit -q --allow-empty -m "chore: init"
  git tag v1.0.0
}

@test "derive-scope: only fixes/chores -> patch" {
  git commit -q --allow-empty -m "fix: a"
  git commit -q --allow-empty -m "chore: b"
  [ "$(zsh "$SCRIPT")" = "patch" ]
}

@test "derive-scope: a feat among fixes -> minor" {
  git commit -q --allow-empty -m "fix: a"
  git commit -q --allow-empty -m "feat: add a thing"
  [ "$(zsh "$SCRIPT")" = "minor" ]
}

@test "derive-scope: feat(scope) -> minor" {
  git commit -q --allow-empty -m "feat(api): x"
  [ "$(zsh "$SCRIPT")" = "minor" ]
}

@test "derive-scope: feat! header -> major" {
  git commit -q --allow-empty -m "feat!: drop the old API"
  [ "$(zsh "$SCRIPT")" = "major" ]
}

@test "derive-scope: fix(api)! header -> major" {
  git commit -q --allow-empty -m "fix(api)!: change return type"
  [ "$(zsh "$SCRIPT")" = "major" ]
}

@test "derive-scope: BREAKING CHANGE footer -> major (overrides a plain feat)" {
  git commit -q --allow-empty -m "feat: new"
  git commit -q --allow-empty -m "refactor: tidy

BREAKING CHANGE: removed the foo() method"
  [ "$(zsh "$SCRIPT")" = "major" ]
}

@test "derive-scope: non-conventional messages -> patch" {
  git commit -q --allow-empty -m "random message"
  git commit -q --allow-empty -m "another one"
  [ "$(zsh "$SCRIPT")" = "patch" ]
}

@test "derive-scope: no tags yet -> whole history considered" {
  rm -rf .git
  git init -q
  git config user.email t@t
  git config user.name t
  git commit -q --allow-empty -m "feat: first feature"
  [ "$(zsh "$SCRIPT")" = "minor" ]
}
