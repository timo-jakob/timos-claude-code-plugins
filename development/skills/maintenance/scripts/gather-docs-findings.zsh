#!/usr/bin/env zsh
# gather-docs-findings.zsh — the docs topic's finding gatherer (epic #746 child
# (d), #793). Emits the v2 gather payload the `development-docs` dispatcher
# consumes: `tooling_configured` / `findings_by_tool` / `coverage` / `notes`.
# Topics aren't code with tests, so `coverage` is always null.
#
# v1 ships exactly one tool: **c4_drift** — the C4 Container diagram has fallen
# behind the code. It is a mechanical comparison of the containers the diagram
# DECLARES against the containers detection FINDS, surfaced as a normal
# maintenance finding rather than discovered stale months later:
#
#   declared  ← ../../bootstrap/scripts/extract-declared-containers.zsh (#790 — the
#               canonical parser; this gather never re-implements the parse, or it
#               would diverge from #792 on the same diagram).
#   detected  ← ../../bootstrap/scripts/detect-stack.sh's `containers` +
#               `detection_confidence` (#799 — consumed, not re-derived).
#
# The join folds case and every non-[a-z0-9_] char to `_` — the SAME fold #791's
# seeder and #792's currency check use, so all three agree about the same diagram.
# Two directions:
#   declared_not_detected — in the diagram, not found in the repo. SUPPRESSED when
#       detection_confidence is `inconclusive` (absence of detection is not
#       evidence of absence, #799 — a false finding would train users to ignore
#       the source). A suppression note is emitted.
#   detected_not_declared — found in the repo, missing from the diagram.
#
# `tooling_configured.c4_drift` is the presence of `docs/architecture/` (the topic
# home). When true but `c4-container.md` is absent or unparseable, the tool runs
# and degrades to `[]` + a note — it never crashes the payload.
#
# Usage: gather-docs-findings.zsh [<repo_path>]   (default: current directory)
# Output: JSON on stdout (always exit 0 on a well-formed run).

emulate -L zsh
set -euo pipefail

local repo="${1:-.}"
[[ -d "$repo" ]] || { print -r -u2 -- "gather-docs-findings.zsh: not a directory: $repo"; exit 2; }
command -v jq >/dev/null 2>&1 || { print -r -u2 -- "gather-docs-findings.zsh: jq not found on PATH"; exit 3; }

# This gather lives in development/skills/maintenance/scripts/; the shared #790/#799
# helpers live in development/skills/bootstrap/scripts/ — two levels up, then over.
local here="${0:A:h}"
local extract="$here/../../bootstrap/scripts/extract-declared-containers.zsh"
local detect="$here/../../bootstrap/scripts/detect-stack.sh"
[[ -f "$extract" && -f "$detect" ]] || { print -r -u2 -- "gather-docs-findings.zsh: shared helpers not found under $here/../../bootstrap/scripts/"; exit 3; }

local -a notes=()
local has_c4_drift="false"
local findings="[]"

if [[ -d "$repo/docs/architecture" ]]; then
  has_c4_drift="true"

  # --- declared half (#790's parser). Capture stderr so its named cause (which
  # line/alias) can be carried into the degrade note. ---
  local declared rc errf why
  errf="$(mktemp)" || { print -r -u2 -- "gather-docs-findings.zsh: mktemp failed"; exit 3; }
  trap 'rm -f "$errf"' EXIT INT TERM
  declared="$(zsh "$extract" --repo "$repo" 2>"$errf")" && rc=0 || rc=$?
  local declared_ok="false"
  case $rc in
    0) # a helper contract breach (exit 0 but non-array stdout) must degrade with a
       # note, never crash the jq below — validate the shape symmetrically.
       if print -r -- "$declared" | jq -e 'type == "array"' >/dev/null 2>&1; then
         declared_ok="true"
       else
         notes+=("c4_drift: extract-declared-containers.zsh returned unexpected output — skipped.")
       fi ;;
    1) notes+=("c4_drift: no docs/architecture/c4-container.md yet — nothing to compare.") ;;
    *) why="$(head -1 "$errf" 2>/dev/null || true)"
       notes+=("c4_drift: docs/architecture/c4-container.md is unparseable — skipped${why:+ (${why})}.") ;;
  esac

  # --- detected half (#799's detect-stack, consumed not re-derived). A detection
  # FAILURE (weaker than inconclusive) must skip the comparison, keep findings [],
  # and note it (naming the cause) — never crash the payload. The guard requires an
  # OBJECT: a bare truthy scalar/array would clear `jq -e .` but crash `.containers`. ---
  local detected drc
  if [[ "$declared_ok" == "true" ]]; then
    detected="$( ( cd "$repo" && bash "$detect" ) 2>"$errf" )" && drc=0 || drc=$?
    if (( drc != 0 )) || ! print -r -- "$detected" | jq -e 'type == "object"' >/dev/null 2>&1; then
      declared_ok="false"
      why="$(head -1 "$errf" 2>/dev/null || true)"
      notes+=("c4_drift: container detection failed — skipped (cannot compare without a detected set)${why:+ (${why})}.")
    fi
  fi

  if [[ "$declared_ok" == "true" ]]; then
    local confidence
    confidence="$(print -r -- "$detected" | jq -r '.detection_confidence // "inconclusive"')"

    # Folded identifier sets — the shared #790/#791/#792 rule.
    local declared_set detected_set
    declared_set="$(print -r -- "$declared" | jq -c '[.[].alias | ascii_downcase | gsub("[^a-z0-9_]";"_")] | unique')"
    detected_set="$(print -r -- "$detected" | jq -c '[(.containers // [])[].name | ascii_downcase | gsub("[^a-z0-9_]";"_")] | unique')"

    # Set-diff each direction, captured to a variable first (a jq failure inside a
    # for-word expansion would silently swallow findings). Both sides are folded to
    # [a-z0-9_], so newline word-splitting is safe.
    local detected_only declared_only nm
    detected_only="$(print -r -- "$detected_set" | jq -r --argjson d "$declared_set" '.[] | select(. as $x | ($d | index($x)) | not)')"
    declared_only="$(print -r -- "$declared_set" | jq -r --argjson d "$detected_set" '.[] | select(. as $x | ($d | index($x)) | not)')"

    local -a objs=()
    # detected_not_declared: found in the repo, missing from the diagram.
    for nm in ${(f)detected_only}; do
      [[ -n "$nm" ]] || continue
      objs+=("$(jq -n --arg n "$nm" '{
        id: ("c4_drift:detected_not_declared:" + $n), tool: "c4_drift",
        type: "detected_not_declared", severity: "MINOR",
        message: ("Container `" + $n + "` is detected in the repo but not declared in docs/architecture/c4-container.md."),
        fix: ("Add `" + $n + "` to the Container diagram (see the c4/v1 contract in ARCHITECTURE.md)."),
        files: ["docs/architecture/c4-container.md"]}')")
    done

    # declared_not_detected: in the diagram, not found in the repo — SUPPRESSED on
    # an inconclusive detection (absence of detection is not evidence of absence).
    local -a declared_arr=()
    for nm in ${(f)declared_only}; do [[ -n "$nm" ]] && declared_arr+=("$nm"); done
    if [[ "$confidence" == "inconclusive" ]]; then
      (( ${#declared_arr[@]} > 0 )) && notes+=("c4_drift: detection is inconclusive — suppressed ${#declared_arr[@]} declared-but-not-detected finding(s); absence of detection is not evidence the container is gone.")
    else
      for nm in "${declared_arr[@]}"; do
        objs+=("$(jq -n --arg n "$nm" '{
          id: ("c4_drift:declared_not_detected:" + $n), tool: "c4_drift",
          type: "declared_not_detected", severity: "MINOR",
          message: ("Container `" + $n + "` is declared in docs/architecture/c4-container.md but not detected in the repo."),
          fix: ("Remove `" + $n + "` from the Container diagram, or add the missing Dockerfile/compose service/build config if it should exist."),
          files: ["docs/architecture/c4-container.md"]}')")
      done
    fi

    (( ${#objs[@]} > 0 )) && findings="$(printf '%s\n' "${objs[@]}" | jq -s '.')"
  fi
else
  notes+=("c4_drift: no docs/architecture/ directory — the docs topic is not configured for this repo, skipped.")
fi

local notes_json
if (( ${#notes[@]} > 0 )); then
  notes_json="$(printf '%s\n' "${notes[@]}" | jq -R . | jq -s '.')"
else
  notes_json='[]'
fi

jq -n \
  --argjson c4_cfg "$has_c4_drift" \
  --argjson c4_findings "$findings" \
  --argjson notes "$notes_json" '
{
  tooling_configured: { c4_drift: $c4_cfg },
  findings_by_tool: ( {} + (if $c4_cfg then {c4_drift: $c4_findings} else {} end) ),
  coverage: null,
  notes: $notes
}
'
