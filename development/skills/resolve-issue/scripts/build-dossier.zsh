#!/usr/bin/env zsh
# build-dossier.zsh — turn a CONVERGED review-loop status JSON (from
# resolve-story-loop.zsh, #562) into the PR "Review dossier" section: the durable
# audit record for why auto-merge happened (epic #557, issue #563).
#
# It emits, on stdout:
#   1. a human-readable "## Review dossier" markdown section — per-round blockers
#      found/fixed, dimensions reviewed, waived Low suggestions, reviewers, and
#      the final consolidator state; and
#   2. a hidden JSON block  <!-- review-dossier: {…} -->  dimension-tagged with
#      the #449 enum, so the Approver re-ingests reviewer verdicts into its risk
#      register the same way maintenance re-ingests Approver findings today. An
#      empty (clean) dimension lets the Approver lower that lens's residual-risk
#      weight; the waived-Low list is context, not a finding.
#
# If the loop did not run (--no-review / no rounds), nothing is emitted (exit 0)
# so the PR body is exactly as it is today.
#
# Usage:  build-dossier.zsh --status FILE
# Exit codes: 0 ok (may be empty) · 2 usage · 1 internal (invalid status JSON)

emulate -L zsh
setopt nounset pipefail

local status_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --status) status_file="$2"; shift 2 ;;
  -h|--help) print -r -- "usage: build-dossier.zsh --status FILE"; exit 0 ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$status_file" ]] || { print -u2 -- "usage: build-dossier.zsh --status FILE"; exit 2 }
[[ -s "$status_file" ]] || { print -u2 -- "build-dossier: status file missing or empty: $status_file"; exit 1 }

# nothing to render when the loop did not run (SKIPPED / no rounds)
local nrounds
nrounds=$(jq -r '(.round_changelists // []) | length' "$status_file" 2>/dev/null) || {
  print -u2 -- "build-dossier: invalid status JSON"; exit 1 }
[[ "$nrounds" -gt 0 ]] || exit 0

# --- the machine-readable dossier object (dimension-tagged, #449 enum) -------
local dossier
dossier=$(jq -c '
  ["bugs","security","performance","code_quality","tests"] as $core
  | . as $s
  | [ $s.round_changelists[] | (.blocking[]?, .suggestions[]?) ] as $allf
  | ( [ $allf[] | {file, line, dimension, title,
                   priority: (.priority // "Low"),
                   reviewers: (.reviewers // [])} ]
      | unique_by([.file, .line, .dimension, .title]) ) as $u
  | (($core + ($u | map(.dimension))) | unique) as $dims
  | ( reduce $dims[] as $d ({};
        . + { ($d): {
          blocking: ([ $u[] | select(.dimension==$d and (.priority=="Critical" or .priority=="High")) ] | length),
          suggestions: ([ $u[] | select(.dimension==$d and .priority=="Low") ] | length),
          clean: ([ $u[] | select(.dimension==$d) ] | length == 0)
        }}) ) as $dimmap
  | {
      status: $s.status,
      rounds: $s.rounds,
      repo_type: $s.repo_type,
      dimensions: $dimmap,
      waived_low: [ $u[] | select(.priority=="Low") | {file, line, dimension, title} ],
      reviewers: ([ $u[] | .reviewers[]? ] | unique),
      final: ($s.final_changelist.summary // {})
    }' "$status_file") || { print -u2 -- "build-dossier: could not build dossier"; exit 1 }

# --- human-readable section, rendered from the status + dossier --------------
{
  print -r -- "## Review dossier"
  print -r --
  jq -r '"The local review loop ran **\(.rounds) round(s)** and exited **\(.status)** "
    + "before this PR was opened — CI is only spent on code the reviewer panel already converged on."' "$status_file"
  print -r --

  print -r -- "**Per round**"
  print -r --
  jq -r '.round_changelists[] |
    "- Round \(.round): \(.summary.blocking) blocking"
    + (if .summary.conflicts > 0 then ", \(.summary.conflicts) conflict(s)" else "" end)
    + ", \(.summary.low) suggestion(s) logged"' "$status_file"
  print -r --

  print -r -- "**Dimensions reviewed** (#449 lenses)"
  print -r --
  print -r -- "$dossier" | jq -r '.dimensions | to_entries[] |
    if .value.clean then "- `\(.key)` — ✓ clean (reviewed, no findings)"
    else "- `\(.key)` — \(.value.blocking) blocking found & fixed, \(.value.suggestions) suggestion(s)" end'
  print -r --

  local waived_n
  waived_n=$(print -r -- "$dossier" | jq '.waived_low | length')
  if [[ "$waived_n" -gt 0 ]]; then
    print -r -- "**Waived suggestions** (Low — logged, never blocking)"
    print -r --
    print -r -- "$dossier" | jq -r '.waived_low[] | "- `\(.file):\(.line)` [\(.dimension)] \(.title)"'
    print -r --
  fi

  local reviewers
  reviewers=$(print -r -- "$dossier" | jq -r '.reviewers | if length==0 then "—" else join(", ") end')
  print -r -- "**Reviewers:** ${reviewers}"
  print -r --
  print -r -- "_Machine-readable dossier below is consumed by the Approver's risk register._"
  print -r --
  print -r -- "<!-- review-dossier: ${dossier} -->"
}
