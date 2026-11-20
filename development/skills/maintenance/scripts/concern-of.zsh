#!/usr/bin/env zsh
# The tool -> concern mapping of /development:maintenance (#3211). This file is
# the ONE place it lives: Phase 0's `--concern` expansion and Phase 8's concern
# order (order-groups.zsh) both read it from here.
#
# Usage:
#   concern-of.zsh <tool>
#       Print the concern of a findings_by_tool key: security | dependencies |
#       bugs | codequality | topic. Every topic plugin's tool prints `topic`.
#   concern-of.zsh --tools <concern>
#       Print, one per line, the tools of Phase 0's `--tool` list that belong to
#       <concern> — the set `--concern=<concern>` expands to. A concern with no
#       such tool (bugs, topic) prints nothing.
#
# Exit codes:
#   0  printed
#   2  usage: no argument, an unknown tool, or an unknown concern
#
# The concerns rank security < dependencies < bugs < codequality < topic; that
# rank is order-groups.zsh's, stated in ARCHITECTURE.md (*The concern order of a
# full run*). No tool maps to `bugs` yet: the bugs concern's tool arrives with
# the bug-analysis story of the scheduled-maintenance epic (#3210).

set -uo pipefail

usage() {
  print -u2 "usage: concern-of.zsh <tool> | concern-of.zsh --tools <concern>"
  exit 2
}

# Phase 0's `--tool` list, by concern. These are the tools a run can be scoped
# to; together they are exactly that list (tests/maintenance-concern-order.bats
# sweeps SKILL.md against it).
typeset -A DISPATCH=(
  snyk_prs security
  code_scanning security
  semgrep security
  container_scan security
  govulncheck security
  dependabot dependencies
  renovate dependencies
  sonarcloud codequality
  ruff codequality
)
# The same tools in Phase 0's order (an associative array has none).
typeset -a DISPATCH_ORDER=(snyk_prs code_scanning semgrep container_scan govulncheck dependabot renovate sonarcloud ruff)

# Language tools a planner groups by but `--tool` does not accept: linters,
# formatters and config advisors, all code quality.
typeset -A PLANNER_ONLY=(
  format_lint codequality
  grpc codequality
  api_contract codequality
  openapi codequality
  versioning codequality
)

# Every topic plugin's tools (claude-plugin, composition, docs, kubernetes,
# opentofu, react, spring) — the keys of each topic dispatcher's routing table.
typeset -a TOPIC_TOOLS=(
  skill_validation structure_validation reference_checking script_quality plugin_version_check
  tag_bump workspace_validation
  c4_drift
  manifest_validation policy policy_tests
  format lint validate misconfiguration state_encryption
  a11y lighthouse_budget
  spring_api spring_boot_upgrade spring_config spring_container
)

typeset -a CONCERNS=(security dependencies bugs codequality topic)

(( $# >= 1 )) || usage

if [[ "$1" == --tools ]]; then
  (( $# == 2 )) || usage
  concern="$2"
  if (( ! ${CONCERNS[(Ie)$concern]} )); then
    print -u2 "concern-of.zsh: unknown concern '$concern'; known: ${CONCERNS[*]}"
    exit 2
  fi
  for tool in "${DISPATCH_ORDER[@]}"; do
    [[ "${DISPATCH[$tool]}" == "$concern" ]] && print -r -- "$tool"
  done
  exit 0
fi

(( $# == 1 )) || usage
tool="$1"
[[ -n "$tool" ]] || usage

if (( ${+DISPATCH[$tool]} )); then
  print -r -- "${DISPATCH[$tool]}"
elif (( ${+PLANNER_ONLY[$tool]} )); then
  print -r -- "${PLANNER_ONLY[$tool]}"
elif (( ${TOPIC_TOOLS[(Ie)$tool]} )); then
  print -r -- topic
else
  print -u2 "concern-of.zsh: unknown tool '$tool'"
  exit 2
fi
