#!/usr/bin/env zsh
# gather-react-findings.zsh — the React topic's finding gatherer (epic #686, #956).
# Emits the v2 gather payload the `development-react` dispatcher consumes:
# `tooling_configured` / `findings_by_tool` / `coverage` / `notes`. Topics aren't
# code with tests of their own, so `coverage` is always null.
#
# v0.1 ships an **empty tool universe** on purpose. This is the foundation slice:
# its job is to prove the composition wiring end-to-end — that `react` is detected,
# lands in `supported_topics`, and genuinely dispatches to `development-react`
# alongside `development-javascript`. Topic support is gated on **gather-script
# presence**, so a marker with no gather would sit in `unsupported_topics`: detected
# but never dispatched (the state the `docs` topic occupied between #801 and #793),
# leaving the foundation's one job unverified. Hence a real, executable gather that
# honestly reports "no tools yet" rather than a placeholder that reports nothing.
#
# Tools arrive in the later slices of #686 — #957 (bootstrap templates), #958 (React
# Query + MSW API binding), #959 (review panel), #960 (a11y / Playwright /
# Lighthouse budgets) — each registering itself in `tooling_configured` and
# `findings_by_tool` here and in the dispatcher's routing table.
#
# The empty universe is emitted as `{}` for BOTH `tooling_configured` and
# `findings_by_tool`, with a non-empty `notes` naming the slices that add tools, so
# a run is never silently indistinguishable from a crash: an empty object plus an
# explanatory note is a positive statement ("this topic has no tools yet"), whereas
# a bare `{}` with no note would read as "something went wrong".
#
# Usage: gather-react-findings.zsh [<repo_path>]   (default: current directory)
# Output: JSON on stdout (always exit 0 on a well-formed run).
#
# Exit codes:
#   0 — well-formed run (payload on stdout)
#   2 — usage error (no such directory, or extra/empty arguments)
#   3 — runtime error (jq missing, a jq invocation failing, or the repo path
#       could not be entered)
#
# Runtime jq failures are mapped onto 3 explicitly rather than being allowed to
# abort under `set -e` with jq's OWN status — jq exits 2 for a usage/system error,
# which would be indistinguishable from this script's documented "not a directory".

emulate -L zsh
set -euo pipefail

(( $# <= 1 )) || { print -r -u2 -- "gather-react-findings.zsh: too many arguments (expected at most one repo path)"; exit 2; }
# ${1-.} (not ${1:-.}): an explicitly EMPTY argument is a usage error, not a
# silent fallback to the current directory.
local repo="${1-.}"
[[ -n "$repo" ]] || { print -r -u2 -- "gather-react-findings.zsh: empty repo path"; exit 2; }
[[ -d "$repo" ]] || { print -r -u2 -- "gather-react-findings.zsh: not a directory: $repo"; exit 2; }
command -v jq >/dev/null 2>&1 || { print -r -u2 -- "gather-react-findings.zsh: jq not found on PATH"; exit 3; }

# Enter the target repo. A no-op for the empty v0.1 tool universe, but
# correct-by-construction for #957-#960: a tool added below that runs `find .` or a
# node binary must scan the TARGET repo, not the orchestrator's cwd.
cd -- "$repo" || { print -r -u2 -- "gather-react-findings.zsh: cannot enter: $repo"; exit 3; }

# The v0.1 tool universe is empty by design (see the header). `notes` names the
# slices that will fill it, so the payload explains itself to whoever reads a run
# summary and wonders why a detected topic produced nothing.
local -a notes=(
  "react: the v0.1 tool universe is empty by design — this foundation slice (#956) ships the composition wiring only, so a detected React repo dispatches to development-react and correctly reports nothing to do."
  "react: tools arrive with #957 (bootstrap templates), #958 (React Query + MSW API binding), #959 (review panel), and #960 (a11y / Playwright / Lighthouse budgets)."
)

# `jq -R -s` with a length filter, so an EMPTY notes array yields `[]` rather than
# the [""] that `printf '%s\n' "${empty[@]}" | jq -R . | jq -s .` would invent.
# Today `notes` is a non-empty literal, but #957-#960 will make it conditional
# (as gather-docs-findings.zsh already had to), so the trap is disarmed up front.
local notes_json
notes_json="$(printf '%s\n' "${notes[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')" \
  || { print -r -u2 -- "gather-react-findings.zsh: jq failed building notes"; exit 3; }

jq -n --argjson notes "$notes_json" '
{
  tooling_configured: {},
  findings_by_tool: {},
  coverage: null,
  notes: $notes
}
' || { print -r -u2 -- "gather-react-findings.zsh: jq failed emitting the payload"; exit 3; }
