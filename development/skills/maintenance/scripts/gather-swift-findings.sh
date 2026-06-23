#!/usr/bin/env bash
# gather-swift-findings.sh — per-tool maintenance payload for a Swift project.
# Slice B (#442) of the #297 Swift full-maintenance epic.
#
# Usage:
#   gather-swift-findings.sh <repo_path>
#
# Output (stdout, JSON):
#   {
#     "tooling_configured": {
#       "format_lint": true|false   # swift-format + SwiftLint (the blessed stack)
#     },
#     "findings_by_tool": {
#       "format_lint": [ ... or omitted when not configured ... ]
#     },
#     "coverage": {                 # WITHHELD this slice — arrives in Slice D (#444)
#       "overall": null,
#       "by_module": {},
#       "measurement": { "source", "reliable", "reason" }
#     },
#     "notes": [ ... ]
#   }
#
# SCOPE (#442, first slice of the #297 Swift epic). Tool universe so far:
#   - format_lint (swift-format + SwiftLint)  — this slice (the runnable loop)
# Later slices add: sonarcloud / code_scanning / semgrep (Slice C, #443),
# coverage via xccov / llvm-cov (Slice D, #444), and vendor PRs (Slice F, #446).
# Each new tool extends `tooling_configured` + `findings_by_tool` the same way
# the Java gather grew across its slices.
#
# format_lint = swift-format (Apple, bundled with the Swift 6 toolchain) as the
# mechanical formatter, plus SwiftLint's autocorrectable rules. Configured when
# a `.swift-format` or `.swiftlint.yml` config is committed (the blessed stack
# bootstrap renders — Slice E #445). Findings come from `swift-format lint`,
# which reports formatting violations WITHOUT changing files — every finding is
# mechanically fixable, the same guarantee Spotless gives the Java gather.
# Non-autocorrectable SwiftLint quality rules are NOT format_lint; they belong
# to a triage agent in a later slice.
#
# Failure modes are graceful: a configured tool whose binary is absent is
# reported configured-but-no-findings with a `notes` entry explaining why.

set -euo pipefail

repo="${1:-}"
if [[ -z "$repo" || ! -d "$repo" ]]; then
	echo "usage: gather-swift-findings.sh <repo_path>" >&2
	exit 2
fi
cd "$repo"

notes=()

# --- tooling_configured: format_lint ----------------------------------------
# Configured when a swift-format or SwiftLint config is committed — the blessed
# Swift format/lint stack (bootstrap Slice E renders these). swift-format is the
# mechanical formatter; SwiftLint contributes its autocorrectable rules.
has_format_lint_config="false"
if [[ -f ".swift-format" || -f ".swiftlint.yml" || -f ".swiftlint.yaml" ]]; then
	has_format_lint_config="true"
fi

# --- format_lint findings ----------------------------------------------------
# `swift-format lint` reports formatting violations without changing files — the
# clean mechanical signal (analogous to `gradle spotlessCheck`). One finding per
# unformatted .swift file. A missing binary -> note, no findings.
format_lint_json="null"
if [[ "$has_format_lint_config" == "true" ]]; then
	if command -v swift-format >/dev/null 2>&1; then
		lint_log="$(mktemp)"
		# Lint recursively over the repo; --strict so any deviation is reported.
		# swift-format prints `path:line:col: warning: ...`; ignore its exit code
		# (non-zero under --strict just means "found issues") and parse the paths.
		swift-format lint --recursive --strict . >"$lint_log" 2>&1 || true
		violating=$(grep -oE '[][:alnum:]_./-]*\.swift' "$lint_log" 2>/dev/null | sort -u || true)
		if [[ -n "$violating" ]]; then
			format_lint_json=$(printf '%s\n' "$violating" | jq -R '{
				type: "format",
				severity: "MINOR",
				rule: "swift-format:format",
				component: .,
				line: 0,
				message: "File is not formatted per swift-format; run swift-format format -i.",
				key: ("format_lint:" + .)
			}' | jq -s '.')
		else
			format_lint_json="[]"
		fi
		rm -f "$lint_log"
	else
		format_lint_json="[]"
		notes+=("format_lint is configured but 'swift-format' is not on PATH; it ships with the Swift 6 toolchain (or 'brew install swift-format'). Findings can't be collected until it's available.")
	fi
fi

# --- coverage: WITHHELD this slice (arrives in Slice D #444) -----------------
# Emitted in the honest withheld shape (null + reliable=false + reason) so the
# dispatcher's forward-compatible pre-flight reads a trustworthy signal. In this
# slice the only tool (format_lint) is behavior-preserving and coverage-exempt,
# so a missing floor never blocks anything.
coverage_reason="Swift coverage (xccov / swift test --enable-code-coverage) is not measured in this slice; it arrives in Slice D (#444). format_lint is coverage-exempt, so this does not block any work."

# --- notes -> JSON -----------------------------------------------------------
if [[ ${#notes[@]} -gt 0 ]]; then
	notes_json=$(printf '%s\n' "${notes[@]}" | jq -R . | jq -s '.')
else
	notes_json="[]"
fi

# --- emit --------------------------------------------------------------------
jq -n \
	--argjson format_lint_cfg "$has_format_lint_config" \
	--argjson format_lint_findings "$format_lint_json" \
	--arg coverage_reason "$coverage_reason" \
	--argjson notes "$notes_json" '
{
  tooling_configured: {
    format_lint: $format_lint_cfg
  },
  findings_by_tool: (
    {} +
    (if $format_lint_findings != null then {format_lint: $format_lint_findings} else {} end)
  ),
  coverage: {
    overall: null,
    by_module: {},
    measurement: {
      source:   "none",
      reliable: false,
      reason:   $coverage_reason
    }
  },
  notes: $notes
}
'
