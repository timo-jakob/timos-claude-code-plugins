#!/usr/bin/env zsh
# format-drift-issue.zsh — render the GitHub-issue body for the scheduled
# template-drift watcher (#402) from detect-template-drift.zsh JSON output.
#
# Pure formatter: reads the findings JSON (stdin, or `--from-file <path>`) and
# writes a markdown body to stdout. No gh / network — the watcher workflow does
# the issue create/update/close; this is the testable seam.
#
# Usage:
#   detect-template-drift.zsh <repo> | format-drift-issue.zsh
#   format-drift-issue.zsh --from-file drift.json

set -euo pipefail

src="/dev/stdin"
if [[ "${1:-}" == "--from-file" ]]; then
  src="${2:-}"
  [[ -n "$src" && -f "$src" ]] || { print -u2 -- "usage: $0 --from-file <path>"; exit 2; }
fi

findings=$(cat "$src")

print -- "The scheduled \`template-drift-watch\` job found this repo's"
print -- "bootstrap-rendered files have drifted from the current templates."
print -- "Re-run \`/development:bootstrap\` to re-render them (it's idempotent), or"
print -- "patch by hand against the upstream template."
print --

if [[ "$(printf '%s' "$findings" | jq 'any(.[]; .blocking == true)')" == "true" ]]; then
  print -- "> ⚠ **One or more of these changes the behavior of a REQUIRED CI check.**"
  print -- "> Until you re-bootstrap, this repo keeps the OLD behavior (for example, an"
  print -- "> app/dependency PR still blocked by an image scan it shouldn't trigger)."
  print --
fi

print -- "## Drifted files"
print --

printf '%s' "$findings" | jq -c '.[]' | while IFS= read -r f; do
  file=$(printf '%s' "$f" | jq -r '.file')
  sev=$(printf '%s' "$f" | jq -r '.severity')
  case "$sev" in
    drifted)
      mv=$(printf '%s' "$f" | jq -r '.marker_version')
      cv=$(printf '%s' "$f" | jq -r '.current_version')
      print -- "### \`${file}\`  (v${mv} → v${cv})"
      if [[ "$(printf '%s' "$f" | jq '.fixes | length')" -gt 0 ]]; then
        print -- "Re-bootstrap would apply:"
        printf '%s' "$f" | jq -r '
          .fixes[]
          | "- " + (if .blocking then "⚠ " else "" end)
            + "#\(.issue) — \(.summary)"
            + (if .blocking then " (BLOCKING required-check change)" else "" end)'
      else
        print -- "Template changed upstream — re-bootstrap to pick up the latest fixes."
      fi
      print --
      ;;
    unknown_provenance)
      print -- "### \`${file}\`  (no provenance marker)"
      print -- "Rendered before drift tracking shipped, or hand-created — re-bootstrap to"
      print -- "add a marker so drift is tracked on future runs."
      print --
      ;;
    *)
      msg=$(printf '%s' "$f" | jq -r '.message')
      print -- "### \`${file}\`  (${sev})"
      print -- "${msg}"
      print --
      ;;
  esac
done

print -- "---"
print -- "_Filed automatically by \`.github/workflows/template-drift-watch.yml\`._"
print -- "_Updates on each run and closes itself when the drift clears._"
