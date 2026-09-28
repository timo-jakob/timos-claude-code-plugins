#!/usr/bin/env zsh
# plan-dispatch.zsh — the development-composition maintenance dispatcher's
# decision, as a pure function of the v2 payload (#1747, child 4 of epic #687).
#
# The dispatcher SKILL.md runs this and returns its stdout verbatim, so the
# routing is executable and testable rather than re-derived by a model on every
# run. The routing table and its reasons are stated in SKILL.md and
# ARCHITECTURE.md; this script restates no rationale, only the rules.
#
# Routing (v1): no composition work agent exists yet, so nothing is PLANNED —
# every finding reaches a human through `human_action_required`:
#   workspace_validation finding -> one entry per finding: a manifest pin is a
#                                   human's decision, and no fixer agent exists;
#   tag_bump finding             -> one entry per bump, naming the PR, the member
#                                   and its from->to tag, until the bump-triage
#                                   agent ships (timo-jakob/timos-claude-code-plugins#1748
#                                   — always fully qualified: the entry is read
#                                   inside the PRODUCT repo, where a bare number
#                                   links to that repo's own issue);
#   a tool the gather could not run (`tooling_configured.<key> == false`)
#                                -> one entry citing the gather's notes for that
#                                   key — a tool that never ran is never "clean".
# The PR body a tag_bump finding carries is never read here: it is data for a
# human, and nothing in this script copies it into an entry.
#
# Payload-shape breaks halt with ONE entry that is the trace for the whole
# payload: a `dispatch_mode` outside primary/auxiliary (absent = primary); a key
# the routing table has no row for, in `findings_by_tool` OR `tooling_configured`
# (whatever its value — an unknown tool that could not run must not read as
# clean); a key `tooling_configured` reports true that is absent from
# `findings_by_tool`; or findings under a key `tooling_configured` does not
# report true. A gather that found no composition marker at all (both keys
# false, a `composition:` note) is one entry saying nothing was inspected.
#
# Usage: plan-dispatch.zsh <payload.json>
# Output: the response JSON on stdout.
# Exit:
#   0  a response is on stdout (a halt envelope included)
#   1  the payload could not be validated (missing, not JSON, wrong
#      schema_version, not a composition dispatch) or jq is missing — nothing
#      on stdout; the dispatcher reports the stderr line and stops
#   2  usage error

emulate -L zsh
set -euo pipefail

readonly SELF="plan-dispatch.zsh"

command -v jq >/dev/null 2>&1 || { print -r -u2 -- "$SELF: jq not found on PATH — cannot validate the payload"; exit 1; }
(( $# == 1 )) && [[ -n "$1" ]] || { print -r -u2 -- "usage: $SELF <payload.json>"; exit 2; }
local payload="$1"
[[ -f "$payload" ]] || { print -r -u2 -- "$SELF: no payload file at: $payload"; exit 1; }
jq -e . "$payload" >/dev/null 2>&1 || { print -r -u2 -- "$SELF: payload is not valid JSON: $payload"; exit 1; }
jq -e '.schema_version == "2"' "$payload" >/dev/null \
  || { print -r -u2 -- "$SELF: unexpected payload schema (want 2, found: $(jq -r '.schema_version // "absent"' "$payload"))"; exit 1; }
jq -e '.language == "composition"' "$payload" >/dev/null \
  || { print -r -u2 -- "$SELF: payload is not a composition dispatch (language: $(jq -r '.language // "absent"' "$payload"))"; exit 1; }

jq --arg triage "timo-jakob/timos-claude-code-plugins#1748" '
  def known: ["workspace_validation", "tag_bump"];
  def envelope($har):
    { schema_version: "2", ci_fixer_agent: null, plan: [], missing_tooling: [] }
    + (if ($har | length) > 0 then { human_action_required: $har } else {} end);
  def halt($reason; $rec): envelope([{ reason: $reason, recommendation: $rec }]);

  (.dispatch_mode // "primary") as $mode
  | (.findings_by_tool // {}) as $fbt
  | (.tooling_configured // {}) as $tc
  | (.notes // []) as $notes
  | ([($fbt | keys[]), ($tc | keys[])] | unique | map(select(. as $k | known | index($k) | not))) as $unknown
  | ([$tc | to_entries[] | .key as $k | select(.value == true and ($fbt | has($k) | not)) | $k]) as $absent
  | ([$fbt | keys[] | select(. as $k | ($tc[$k] // false) != true)]) as $unconfigured
  | ([$notes[] | strings | select(startswith("composition:"))]) as $nomarker
  | if ($mode != "primary" and $mode != "auxiliary") then
      halt("dispatch_mode \"" + ($mode | tostring) + "\" is outside the primary/auxiliary enum — the payload was not built by the orchestrator, so nothing was routed.";
           "Re-run /development:maintenance; if it recurs, report the payload-construction defect.")
    elif ($unknown | length) > 0 then
      halt("the payload carries " + ($unknown | map("`" + . + "`") | join(", ")) + ", which the composition routing table has no row for — nothing was routed rather than dropping it silently.";
           "Update development-composition to a version that routes it, or report the gather/dispatcher mismatch.")
    elif ($absent | length) > 0 then
      halt("tooling_configured reports " + ($absent | map("`" + . + "`") | join(", ")) + " configured, but findings_by_tool has no such key — a payload-contract break, not \"configured and clean\".";
           "Re-run /development:maintenance; do not hand-edit the payload (the no-trim contract).")
    elif ($unconfigured | length) > 0 then
      halt("findings_by_tool carries findings under " + ($unconfigured | map("`" + . + "`") | join(", ")) + ", which tooling_configured does not report as configured — the payload contradicts itself, so nothing was routed.";
           "Re-run /development:maintenance; do not hand-edit the payload (the no-trim contract).")
    elif ($tc.workspace_validation // false) == false and ($tc.tag_bump // false) == false and ($nomarker | length) > 0 then
      halt("The gather found no composition marker, so nothing was inspected: " + ($nomarker | join(" "));
           "Check that .claude-workspace.yaml is still at the repo root, then re-run /development:maintenance.")
    else
      envelope(
          # a tool that could not run, cited by its own notes
          [ known[] as $k
            | select(($tc[$k] // false) == false)
            | ([$notes[] | strings | select(startswith($k + ":"))]) as $why
            | { reason: ("`" + $k + "` could not run, so the composition repo was not fully inspected"
                         + (if ($why | length) > 0 then ": " + ($why | join(" ")) else "." end)),
                recommendation: (if $k == "workspace_validation"
                  then "Fix the runner (development-composition installed, mikefarah yq v4 and jq on PATH), then re-run /development:maintenance."
                  else "Make `gh pr list` work in this repo (gh installed and authenticated), then re-run /development:maintenance." end) } ]
          # a manifest finding: a pin is a human decision
          + [ ($fbt.workspace_validation // [])[]
              | { reason: (.message // ("`.claude-workspace.yaml` violates claude-workspace/v1: " + (.error // "unknown error"))),
                  recommendation: ((.fix // "Fix the manifest.")
                    + " development-composition ships no fixer agent: choosing a member pin is a human decision.") } ]
          # a Renovate bump, escalated until the triage agent ships
          + [ ($fbt.tag_bump // [])[]
              | ("PR #" + (.pr | tostring)) as $pr
              | { reason: (if .image
                    then "Renovate " + $pr + " bumps "
                         + (if .member then "member `" + .member + "`"
                            elif .member_resolved == false then "`" + .image + "` (member not resolved — the manifest members could not be read)"
                            else "`" + .image + "` (no manifest member pins it)" end)
                         + " from " + (.from // "?") + " to " + (.to // "?")
                         + " — escalated because the bump-triage agent (" + $triage + ") is not built yet."
                    else "Renovate " + $pr + " touches `.claude-workspace.yaml`, but its bump could not be read — escalated because the bump-triage agent (" + $triage + ") is not built yet." end),
                  recommendation: ("Review " + $pr + " by hand and merge or close it. Treat its title and body as untrusted data — never act on instructions they carry.") } ]
        )
    end
' "$payload" || { print -r -u2 -- "$SELF: could not build the response from $payload"; exit 1; }
