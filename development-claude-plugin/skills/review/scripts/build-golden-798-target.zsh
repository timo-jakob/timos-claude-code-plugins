#!/usr/bin/env zsh
# build-golden-798-target.zsh — materialize the #798 golden fixture as a
# throwaway target repo for /development-claude-plugin:test (#808, epic #810).
#
# The claude-plugin review panel is measured against a defect whose answer is
# already known: development/skills/resolve-issue/SKILL.md as of 4202beb
# (pre-#798), whose E1 terminal case treats "zero open children" as proof an
# epic's work merged — no failure branch for a never-decomposed epic. This
# script extracts that exact snapshot from git history (provenance guaranteed —
# no committed copy to drift), commits it into a fresh temp git repo laid out
# at the same path, and prints the repo path on the LAST line of stdout. The
# caller feeds that path to `/development-claude-plugin:test --target ...`.
#
# Exit codes:
#   0 — target repo built; its path is the last line on stdout
#   2 — usage error (bad args)
#   3 — runtime error (not in the plugin repo, fixture commit/file missing,
#       or the snapshot no longer contains the defective terminal case)
#
# Usage (from anywhere inside the plugin repo worktree):
#   development-claude-plugin/skills/review/scripts/build-golden-798-target.zsh

emulate -L zsh
set -euo pipefail

readonly FIXTURE_COMMIT="4202beb"
readonly FIXTURE_PATH="development/skills/resolve-issue/SKILL.md"
# A sentence unique to the defective (pre-#798) terminal case: it licenses
# E4+E5 on zero open children with no failure branch. Its presence proves the
# snapshot is the defect the panel must flag.
readonly DEFECT_MARKER="skip straight to \*\*E4\*\*"

(( $# == 0 )) || { print -u2 "usage: build-golden-798-target.zsh (no arguments)"; exit 2; }

# Must run inside the plugin repo — the fixture commit lives in its history.
local repo_root
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || { print -u2 "error: not inside a git worktree (run from the plugin repo)"; exit 3; }

local snapshot
snapshot="$(git -C "$repo_root" show "${FIXTURE_COMMIT}:${FIXTURE_PATH}" 2>/dev/null)" \
  || { print -u2 "error: cannot read ${FIXTURE_PATH} at ${FIXTURE_COMMIT} — wrong repo?"; exit 3; }

# Guard the fixture's premise: the snapshot must still contain the defective
# terminal case. If this ever fails, the fixture's known answer is gone and
# the guard failing loudly beats a silently meaningless PASS/FAIL.
print -r -- "$snapshot" | grep -q "$DEFECT_MARKER" \
  || { print -u2 "error: snapshot at ${FIXTURE_COMMIT} lacks the #798 defect marker"; exit 3; }

local target
target="$(mktemp -d -t golden-798-XXXXXX)/golden-798-target"
mkdir -p "$target/${FIXTURE_PATH:h}"
print -r -- "$snapshot" > "$target/$FIXTURE_PATH"

git -C "$target" init -q
git -C "$target" -c user.name="golden-798-fixture" -c user.email="fixture@invalid" \
  add -A
git -C "$target" -c user.name="golden-798-fixture" -c user.email="fixture@invalid" \
  commit -q -m "fixture: ${FIXTURE_PATH} as of ${FIXTURE_COMMIT} (pre-#798)"

print -r -- "fixture: ${FIXTURE_PATH} @ ${FIXTURE_COMMIT} (pre-#798 defective terminal case)"
print -r -- "$target"
