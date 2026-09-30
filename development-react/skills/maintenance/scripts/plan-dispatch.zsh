#!/usr/bin/env zsh
# plan-dispatch.zsh — the development-react maintenance dispatcher's decision, as
# a pure function of the v2 payload (#1948, following development-composition's
# #1747).
#
# The dispatcher SKILL.md runs this and returns its stdout verbatim, so the
# routing is executable and testable rather than re-derived by a model on every
# run. The routing table and its reasons are stated in SKILL.md; this script
# restates no rationale, only the rules.
#
# Routing: one group per handled tool whose finding list is non-empty (and which
# any `dispatch_filter.only_tools` allows), both to react-webui-quality-advisor:
#   a11y              -> files: the de-duplicated union of the findings' files,
#                        first-seen order; priority_score 0.5
#   lighthouse_budget -> files: ["lighthouserc.json"]; priority_score 0.4
# Finding ids pass through unchanged. A tool the routing table has no row for
# that carries findings is never planned and never dropped: it gets one
# `missing_tooling` entry. So does a handled tool that carries no findings but
# that `tooling_configured` does not report true or a `<tool>:` note names — the
# gather could not audit it, which must never read as clean.
#
# Usage: plan-dispatch.zsh <payload.json>
# Output: the response JSON on stdout.
# Exit:
#   0  a response is on stdout
#   1  the payload could not be validated (missing, not JSON, wrong
#      schema_version) or jq is missing — nothing on stdout; the dispatcher
#      reports the stderr line and stops
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
  || { print -r -u2 -- "$SELF: unexpected payload schema (want schema_version 2, found: $(jq -r '.schema_version // "absent"' "$payload"))"; exit 1; }

jq '
  def known: ["a11y", "lighthouse_budget"];
  def shape($tool; $fs):
    if $tool == "a11y" then
      { description: ("Triage " + ($fs | length | tostring) + " accessibility-gate finding(s)"),
        files: (reduce ($fs[] | (.files // [])[]) as $f ([]; if index([$f]) then . else . + [$f] end)),
        rationale: "the axe package and toHaveNoViolations matcher findings triaged together by react-webui-quality-advisor",
        suggested_pr_title: "test(a11y): register the axe toHaveNoViolations matcher",
        priority_score: 0.5 }
    else
      { description: ("Triage " + ($fs | length | tostring) + " Lighthouse budget finding(s)"),
        files: ["lighthouserc.json"],
        rationale: "the lighthouserc.json budget findings triaged together by react-webui-quality-advisor",
        suggested_pr_title: "ci(lighthouse): align lighthouserc.json with the family byte budgets",
        priority_score: 0.4 }
    end;

  (.findings_by_tool // {}) as $fbt
  | (.tooling_configured // {}) as $tc
  | (.notes // []) as $notes
  | (.dispatch_filter.only_tools // null) as $only
  | [ known[] as $t
      | select(($fbt[$t] // []) | length > 0)
      | select($only == null or ($only | index([$t])))
      | ($fbt[$t]) as $fs
      | { tool: $t, findings: [$fs[].id] } + shape($t; $fs)
        + { agent: "react-webui-quality-advisor", isolation: true } ] as $groups
  | { schema_version: "2",
      ci_fixer_agent: "js-ci-fixer",
      plan: [ $groups | to_entries[]
              | { group_id: (.key + 1) } + .value
              | { group_id, tool, description, findings, files, rationale, agent,
                  isolation, suggested_pr_title, priority_score } ],
      missing_tooling: ([ known[] as $k
                         | ([$notes[] | strings | select(startswith($k + ":"))]) as $why
                         | select((($tc[$k] // false) != true or ($why | length) > 0)
                                  and (($fbt[$k] // []) | length == 0))
                         | { tool: $k,
                             summary: ("the gather could not audit `" + $k + "`, so it was not fully inspected"
                                       + (if ($why | length) > 0 then ": " + ($why | join(" ")) else "." end)),
                             what_it_provides: (if $k == "a11y" then "the axe package and toHaveNoViolations matcher audit"
                                                else "the lighthouserc.json byte-budget and timing-gate audit" end),
                             how_to_add: "fix what the gather notes name, then re-run /development:maintenance" } ]
                     + [ $fbt | to_entries[]
                         | select(.key as $k | known | index([$k]) | not)
                         | select((.value | type) == "array" and (.value | length) > 0)
                         | { tool: .key,
                             summary: "findings present for a tool development-react does not handle yet",
                             what_it_provides: "the finding source this dispatcher has no routing-table entry for",
                             how_to_add: "register the tool in Step 2\u0027s routing table and give it a group shape in Step 3" } ]) }
' "$payload" || { print -r -u2 -- "$SELF: could not build the response from $payload"; exit 1; }
