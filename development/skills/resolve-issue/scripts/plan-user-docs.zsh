#!/usr/bin/env zsh
# plan-user-docs.zsh — turn a story-spec/v1 block into the same-PR user-docs
# plan (#767, epic #745).
#
# story-readiness classifies each story's runtime surface (#242 taxonomy,
# carried in the block's `interface_surfaces`). When a story touches a surface,
# its feature PR must also update the target repo's `docs/` — the how-to page
# for that surface (the #766 seed convention), seeded from the block's
# `use_case` — mirroring the same-PR test-case lifecycle (#696): target-repo
# docs are born maintained, not seeded-then-abandoned. This is the planning
# primitive: given the story-spec block, it lists — per classified surface —
# which docs page the PR must add or update.
#
# surface → docs page (the #766 bootstrap seed convention):
#   cli → docs/how-to/use-the-cli.md · rest → docs/how-to/use-the-rest-api.md
#   web-ui → docs/how-to/use-the-web-ui.md · grpc → docs/how-to/use-the-grpc-api.md
#
# It reads the story-spec block (from `--file` or stdin — typically piped from
# read-story-spec.zsh, #577) and prints a compact JSON array, one object per
# classified surface:
#   { "surface": "...", "kind": "how-to", "page": "docs/how-to/use-the-<...>.md" }
#
# Whether the target repo HAS the docs machinery (mkdocs.yml etc., #766) is the
# caller's check, not this planner's — the plan is a pure function of the block.
#
# Exit codes:
#   0 — the plan is on stdout. It is `[]` for a no-surface story (docs, chores,
#       refactors, library-internal work need no user-docs step) and non-empty
#       when the story touches at least one runtime surface.
#   1 — NO block (empty input from read-story-spec.zsh) — the caller falls back
#       to the prose-only flow with no docs step. Not an error.
#   2 — usage error.
#   3 — runtime error (bad JSON, jq missing, an unknown surface value).
#
# Usage:
#   read-story-spec.zsh --file body.md | plan-user-docs.zsh
#   plan-user-docs.zsh --file story-spec.json

emulate -L zsh
set -euo pipefail

local file=""
while (( $# > 0 )); do
  case "$1" in
    --file)
      (( $# >= 2 )) || { print -u2 "plan-user-docs.zsh: --file needs a value"; exit 2; }
      file="$2"; shift 2 ;;
    -h|--help)
      print -r -- "usage: plan-user-docs.zsh [--file <story-spec.json>]  (else reads stdin)"
      print -r -- "prints the per-surface user-docs plan; [] for a no-surface story; exit 1 when no block."
      exit 0 ;;
    *) print -u2 "plan-user-docs.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

[[ -z "$file" || -f "$file" ]] || { print -u2 "plan-user-docs.zsh: file not found: $file"; exit 3; }
command -v jq >/dev/null 2>&1 || { print -u2 "plan-user-docs.zsh: jq not found on PATH"; exit 3; }

local spec
if [[ -n "$file" ]]; then spec="$(<"$file")"; else spec="$(cat)"; fi
# Empty input (read-story-spec.zsh found no block and wrote nothing) is the
# no-block fallback (exit 1) — the unrefined-issue path, NOT a bad-JSON error.
[[ -n "${spec//[[:space:]]/}" ]] || exit 1
print -r -- "$spec" | jq -e . >/dev/null 2>&1 || { print -u2 "plan-user-docs.zsh: input is not valid JSON"; exit 3; }

# Build the plan: one entry per surface in `interface_surfaces`, mapped to its
# #766 how-to page. `none`/`library` never carry a user-docs page and are
# dropped (a `none`-surface story legitimately has an empty plan); any OTHER
# unmappable value is a hard error (a malformed block), not a silent skip.
local plan
plan="$(print -r -- "$spec" | jq -c '
  { "cli":    "docs/how-to/use-the-cli.md",
    "rest":   "docs/how-to/use-the-rest-api.md",
    "web-ui": "docs/how-to/use-the-web-ui.md",
    "grpc":   "docs/how-to/use-the-grpc-api.md" } as $pages
  | [ (.interface_surfaces // [])[]
      | select(. != "none" and . != "library")
      | { surface: .,
          kind: "how-to",
          # guard the index: a non-string surface (null/number) would make
          # $pages[.] error before `// null` could act — route it to page:null
          # so the friendly "unknown surface" diagnostic below names it.
          page: (if (.|type) == "string" then ($pages[.] // null) else null end) } ]')" \
  || { print -u2 "plan-user-docs.zsh: failed to build plan"; exit 3; }

# Any surface with no page mapping → error (name it).
if print -r -- "$plan" | jq -e 'any(.[]; .page == null)' >/dev/null 2>&1; then
  local bad
  bad="$(print -r -- "$plan" | jq -r 'map(select(.page==null) | (.surface|tostring)) | join(", ")')"
  print -u2 "plan-user-docs.zsh: unknown surface value(s) in interface_surfaces: $bad"
  exit 3
fi

print -r -- "$plan"
