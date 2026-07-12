#!/usr/bin/env zsh
# plan-acceptance-tests.zsh — turn a story-spec/v1 block into the same-PR
# acceptance-test plan (#696, epic #573).
#
# Once refinement defines outside-in `test_cases[]` (#670) and spins them out as
# linked `test-case` issues (#671), `resolve-issue` implements the feature AND
# its acceptance tests in ONE PR, closing story + test-case issues together, so
# tests and feature can never drift. This is the planning primitive: given the
# story-spec block, it lists — for each test case that has a **linked** issue —
# where its acceptance test goes (`tests/acceptance/<surface>/`, the #243
# convention) and which issue it closes.
#
# tooling → surface directory (the #243 tree `tests/acceptance/{rest,grpc,web,cli}/`):
#   curl → rest · grpcurl → grpc · playwright → web · cli → cli
#
# It reads the story-spec block (from `--file` or stdin — typically piped from
# read-story-spec.zsh, #577) and prints a compact JSON array, one object per
# LINKED test case:
#   { "issue": <n>, "id": "...", "kind": "happy|corner|error",
#     "tooling": "...", "dir": "tests/acceptance/<surface>" }
#
# Exit codes:
#   0 — one or more linked test cases; the plan (a non-empty array) is on stdout.
#   1 — NO linked test cases (block absent test_cases, or none carry an issue) —
#       the caller falls back to implementing ONLY the story. Not an error.
#   2 — usage error.
#   3 — runtime error (bad JSON, jq missing, a linked case with unknown tooling).
#
# Usage:
#   read-story-spec.zsh --file body.md | plan-acceptance-tests.zsh
#   plan-acceptance-tests.zsh --file story-spec.json

emulate -L zsh
set -euo pipefail

local file=""
while (( $# > 0 )); do
  case "$1" in
    --file)
      (( $# >= 2 )) || { print -u2 "plan-acceptance-tests.zsh: --file needs a value"; exit 2; }
      file="$2"; shift 2 ;;
    -h|--help)
      print -r -- "usage: plan-acceptance-tests.zsh [--file <story-spec.json>]  (else reads stdin)"
      print -r -- "prints the linked acceptance-test plan; exit 1 when none (fall back to story-only)."
      exit 0 ;;
    *) print -u2 "plan-acceptance-tests.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

[[ -z "$file" || -f "$file" ]] || { print -u2 "plan-acceptance-tests.zsh: file not found: $file"; exit 3; }
command -v jq >/dev/null 2>&1 || { print -u2 "plan-acceptance-tests.zsh: jq not found on PATH"; exit 3; }

local spec
if [[ -n "$file" ]]; then spec="$(<"$file")"; else spec="$(cat)"; fi
# Empty input (e.g. read-story-spec.zsh found no block and wrote nothing) is the
# story-only fallback (exit 1), the same as "a block with no linked cases" — NOT
# a bad-JSON runtime error. This keeps the common no-block path off the exit-3
# (abort) branch in the caller.
[[ -n "${spec//[[:space:]]/}" ]] || exit 1
print -r -- "$spec" | jq -e . >/dev/null 2>&1 || { print -u2 "plan-acceptance-tests.zsh: input is not valid JSON"; exit 3; }

# Build the plan: one entry per test case with a numeric `issue` link, mapping
# tooling to its surface directory. A linked case whose tooling isn't in the
# taxonomy is a hard error (a malformed block), not a silent skip.
local plan
plan="$(print -r -- "$spec" | jq -c '
  { "curl":"rest", "grpcurl":"grpc", "playwright":"web", "cli":"cli" } as $dirs
  | [ (.test_cases // [])[]
      | select((.issue|type) == "number")
      | { issue, id, kind, tooling,
          # guard the index: a non-string tooling (absent/null/number) would
          # make $dirs[.tooling] error before `// null` could act, hiding the
          # friendly "unknown tooling" diagnostic below. Route it to dir:null.
          dir: (if (.tooling|type) == "string" then ($dirs[.tooling] // null) else null end) } ]')" \
  || { print -u2 "plan-acceptance-tests.zsh: failed to build plan"; exit 3; }

# Any linked case with an unmappable tooling → error (name it).
if print -r -- "$plan" | jq -e 'any(.[]; .dir == null)' >/dev/null 2>&1; then
  local bad
  bad="$(print -r -- "$plan" | jq -r 'map(select(.dir==null) | "\(.id // "?"):\(.tooling // "?")") | join(", ")')"
  print -u2 "plan-acceptance-tests.zsh: linked test case(s) with unknown tooling: $bad"
  exit 3
fi

# No linked test cases → fall back to story-only (exit 1, a normal signal).
if [[ "$(print -r -- "$plan" | jq 'length')" -eq 0 ]]; then
  exit 1
fi

# Prefix the dir with the acceptance-test root and emit the plan.
print -r -- "$plan" | jq -c 'map(.dir = "tests/acceptance/\(.dir)")'
