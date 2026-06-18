#!/usr/bin/env zsh
setopt err_exit nounset pipefail
# derive-release-scope.zsh — compute the SemVer bump scope (major | minor |
# patch) from the Conventional Commits made since the last release tag.
#
# This is how the release pipeline OBEYS Semantic Versioning automatically:
# the change set itself declares its impact via conventional-commit types, so
# the bump is derived, not guessed.
#   - a breaking change  -> major   (`type!:` header, or a `BREAKING CHANGE` footer)
#   - a feature          -> minor   (`feat:` / `feat(scope):` header)
#   - anything else       -> patch  (fix / chore / docs / refactor / perf / …)
#
# Output: prints `major`, `minor`, or `patch` on stdout (nothing else), so it
# can feed `./gradlew final -Prelease.scope=$(derive-release-scope.zsh)`.
#
# Usage:
#   derive-release-scope.zsh [<since-ref>]
#     <since-ref>  range start (exclusive). Defaults to the most recent tag;
#                  if there are no tags, the whole history is considered.
#
# Requires a full clone (tags + history) — in CI use actions/checkout with
# fetch-depth: 0. zsh per the project scripting convention; the release
# workflow installs zsh before invoking it on Linux runners.

emulate -L zsh

local since="${1:-}"
[[ -z "$since" ]] && since="$(git describe --tags --abbrev=0 2>/dev/null || true)"

local range="HEAD"
[[ -n "$since" ]] && range="${since}..HEAD"

# Commit subjects + bodies in the range (empty if the range is empty).
local log
log="$(git log --format='%s%n%b' "$range" 2>/dev/null || true)"

# Breaking change: a `!` before the `:` in a conventional header (`feat!:`,
# `fix(api)!:`) OR a `BREAKING CHANGE:` / `BREAKING-CHANGE:` line anywhere.
if print -r -- "$log" | grep -qE '^[a-zA-Z]+(\([^)]*\))?!:|BREAKING[ -]CHANGE'; then
  print -- "major"
# Feature: a `feat:` / `feat(scope):` header.
elif print -r -- "$log" | grep -qE '^feat(\([^)]*\))?:'; then
  print -- "minor"
else
  print -- "patch"
fi
