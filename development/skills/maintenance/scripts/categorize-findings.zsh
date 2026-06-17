#!/usr/bin/env zsh
# Render a cross-tool category inventory of findings for the Phase 9
# maintenance summary (#51, originally #5).
#
# Maps the per-tool findings_by_tool[*] arrays into 5 semantic
# categories (bugs / vulnerabilities / code smells / security hotspots /
# coverage gaps) and prints a compact text block. Categories with zero
# entries are omitted.
#
# Output is text on stdout, ready to paste into the per-language block
# of the orchestrator's Phase 9 summary template.
#
# Usage:
#   categorize-findings.zsh <findings-json-path>
#
# Input JSON shape: the same `findings-<lang>.json` the gather script
# produces and Phase 4 reads — must have `findings_by_tool`,
# `coverage` (with `by_module`), and `policy.coverage_threshold`.
#
# Categorization rules (v1):
#
#   Bugs            ← sonarcloud[type=BUG], semgrep[severity=ERROR]
#   Vulnerabilities ← sonarcloud[type=VULNERABILITY],
#                     code_scanning_alerts[tool=CodeQL],
#                     container_scan (all — Snyk base-image CVEs, #299)
#   Code smells     ← sonarcloud[type=CODE_SMELL],
#                     ruff (all),
#                     semgrep[severity!=ERROR]
#   Security hotspots
#                   ← sonarcloud[type=SECURITY_HOTSPOT]
#   Coverage gaps   ← coverage.by_module entries below
#                     policy.coverage_threshold
#
# Intentionally excluded from category buckets:
#
#   - code_scanning_alerts[tool=Scorecard] — process/hardening,
#     not a "finding" in the bugs/vulns/smells sense. Surfaces in
#     per-tool detail block below the inventory.
#   - dependabot[*], snyk_prs[*] — already first-class PRs.

set -euo pipefail

if (( $# != 1 )); then
  print -u2 "categorize-findings.zsh: expected exactly one argument (findings JSON path)"
  exit 2
fi

findings_path="$1"
if [[ ! -f "$findings_path" ]]; then
  print -u2 "categorize-findings.zsh: not a file: $findings_path"
  exit 2
fi

# Compute counts per category. Each value is an object:
#   { total: N, breakdown: { tool: count, ... } }
#
# `breakdown` keys are short-form tool names ("sonar", "semgrep",
# "ruff", "codeql") rather than the verbose schema keys so the
# rendered line stays compact.
counts=$(jq -r '
  . as $root
  | (.policy.coverage_threshold // 80) as $threshold
  |
  # Per-tool, per-category atomic counts.
  ({
    bugs: {
      sonar:    ((.findings_by_tool.sonarcloud // []) | map(select(.type == "BUG"))                | length),
      semgrep:  ((.findings_by_tool.semgrep    // []) | map(select(((.extra.severity // .severity // "") | ascii_upcase) == "ERROR")) | length)
    },
    vulnerabilities: {
      sonar:     ((.findings_by_tool.sonarcloud // []) | map(select(.type == "VULNERABILITY")) | length),
      codeql:    ((.findings_by_tool.code_scanning_alerts // []) | map(select(.tool == "CodeQL")) | length),
      container: ((.findings_by_tool.container_scan // []) | length)
    },
    code_smells: {
      sonar:    ((.findings_by_tool.sonarcloud // []) | map(select(.type == "CODE_SMELL")) | length),
      ruff:     ((.findings_by_tool.ruff // []) | length),
      semgrep:  ((.findings_by_tool.semgrep // []) | map(select(((.extra.severity // .severity // "") | ascii_upcase) != "ERROR")) | length)
    },
    security_hotspots: {
      sonar:    ((.findings_by_tool.sonarcloud // []) | map(select(.type == "SECURITY_HOTSPOT")) | length)
    },
    coverage_gaps: {
      modules:  ((.coverage.by_module // {})
                 | to_entries
                 | map(select(.value < $threshold))
                 | length)
    }
  })
  |
  # Total per category + retain breakdown.
  with_entries(.value |= {
    total:     ([.[]] | add // 0),
    breakdown: (with_entries(select(.value > 0)))
  })
  |
  # Render to text lines. Skip categories with zero total.
  [
    (.bugs              | select(.total > 0) | "Bugs:              \(.total)   (\(.breakdown | to_entries | map("\(.key): \(.value)") | join(", ")))"),
    (.vulnerabilities   | select(.total > 0) | "Vulnerabilities:   \(.total)   (\(.breakdown | to_entries | map("\(.key): \(.value)") | join(", ")))"),
    (.code_smells       | select(.total > 0) | "Code smells:       \(.total)   (\(.breakdown | to_entries | map("\(.key): \(.value)") | join(", ")))"),
    (.security_hotspots | select(.total > 0) | "Security hotspots: \(.total)   (\(.breakdown | to_entries | map("\(.key): \(.value)") | join(", ")))"),
    (.coverage_gaps     | select(.total > 0) | "Coverage gaps:     \(.total)   (\(.total) module(s) below \($threshold)%)")
  ]
  | .[]
' < "$findings_path")

# Empty inventory — nothing to print. Exit cleanly so the caller can
# detect "no inventory" by checking output emptiness.
if [[ -z "$counts" ]]; then
  exit 0
fi

print -- "📊 Findings by category:"
print -- "$counts" | sed 's/^/  /'
