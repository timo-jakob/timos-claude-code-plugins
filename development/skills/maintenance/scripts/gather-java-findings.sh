#!/usr/bin/env bash
# gather-java-findings.sh — produces the per-tool maintenance payload for a
# Java/Gradle project: which tools are configured, the findings they report,
# and per-module coverage.
#
# Usage:
#   gather-java-findings.sh <repo_path>
#
# Output (stdout, JSON):
#   {
#     "tooling_configured": {
#       "format_lint": true|false   # Spotless (google-java-format) via Gradle
#     },
#     "findings_by_tool": {
#       "format_lint": [ ... or omitted if not configured ... ]
#     },
#     "coverage": {
#       "overall": null,            # JaCoCo coverage is DEFERRED in this slice
#       "by_module": {},            # (#306) — format/lint is pure-mechanical and
#       "measurement": { ... }      # exempt from the coverage floor, so a full
#     },                            # test run isn't needed here. The
#                                   # java-coverage-improver slice wires real
#                                   # JaCoCo gathering.
#     "notes": [ ... ]
#   }
#
# SCOPE (issue #306, first slice of the #296 Java/Gradle epic): the Java tool
# universe currently holds only `format_lint` (Spotless). sonarcloud,
# code_scanning, semgrep, dependabot, and JaCoCo coverage land in later slices,
# each alongside its triage agent. Keeping the universe small keeps the
# dispatch contract honest: the dispatcher reports exactly what it can act on.
#
# Failure modes are graceful: a configured tool that can't run (no JDK, gradle
# wrapper absent, daemon error) is reported as configured-but-no-findings with a
# `notes` entry explaining why. The orchestrator surfaces these notes.

set -euo pipefail

repo="${1:-}"
[[ -n "$repo" && -d "$repo" ]] || {
	echo "usage: $0 <repo_path>" >&2
	exit 2
}

cd "$repo"

notes=()

# --- pick a Gradle invocation ------------------------------------------------
# Prefer the project's wrapper (./gradlew) so the build runs with the version
# the project pins; fall back to a system `gradle` if present. Empty when
# neither is available — downstream adds a note and emits no findings.
GRADLE_BIN=""
if [[ -x "./gradlew" ]]; then
	GRADLE_BIN="./gradlew"
elif command -v gradle >/dev/null 2>&1; then
	GRADLE_BIN="gradle"
fi

# --- tooling_configured ------------------------------------------------------
# Spotless is configured when the com.diffplug.spotless plugin appears in a
# Gradle build script (Groovy or Kotlin DSL), or a bare `spotless {` block is
# present. We scan the root build scripts plus one level of subprojects.
has_format_lint_config="false"
spotless_marker='com\.diffplug\.spotless|spotless[[:space:]]*\{'
if grep -rqE "$spotless_marker" \
	--include='build.gradle' --include='build.gradle.kts' . 2>/dev/null; then
	has_format_lint_config="true"
fi

# --- findings_by_tool --------------------------------------------------------
findings_dir="$(mktemp -d)"
trap 'rm -rf "$findings_dir"' EXIT

# format_lint — `gradle spotlessCheck` exits non-zero when files violate the
# format. We capture the violating .java paths it reports and emit one finding
# per file so the planner has real components to group. spotlessApply (run by
# java-format-lint-fixer) is the behavior-preserving remedy.
if [[ "$has_format_lint_config" == "true" ]]; then
	if [[ -n "$GRADLE_BIN" ]]; then
		check_log="$findings_dir/spotless-check.log"
		check_exit=0
		"$GRADLE_BIN" spotlessCheck --quiet >"$check_log" 2>&1 || check_exit=$?

		# Spotless prints a recognizable signature when (and only when) the
		# non-zero exit is due to FORMAT violations — it names spotlessApply as
		# the remedy. Any other non-zero exit is a build/compile/config error,
		# NOT a formatting finding; we must not mis-attribute it (a non-buildable
		# project would otherwise look like it had format violations).
		if [[ "$check_exit" -eq 0 ]]; then
			# Clean — no formatting violations.
			echo "[]" >"$findings_dir/format_lint.json"
		elif ! grep -qiE 'spotlessApply|format violations' "$check_log" 2>/dev/null; then
			# Non-zero, but not a Spotless violation → the build itself failed.
			echo "[]" >"$findings_dir/format_lint.json"
			notes+=("format_lint: spotlessCheck exited $check_exit without a Spotless violation signature — the Gradle build likely failed for an unrelated reason (compile error, missing JDK toolchain, daemon issue). Treated as 'no format findings'; fix the build and re-run.")
		else
			# Extract violating files. Spotless prints lines that contain the
			# offending source path; collect anything ending in `.java`. Dedup.
			violating=$(grep -oE '[][:alnum:]_./-]*\.java' "$check_log" 2>/dev/null |
				sort -u || true)
			if [[ -n "$violating" ]]; then
				printf '%s\n' "$violating" |
					jq -R '{
						type: "format",
						severity: "MINOR",
						rule: "spotless:google-java-format",
						component: .,
						line: 0,
						message: ("File is not formatted per google-java-format; run spotlessApply."),
						key: ("format_lint:" + .)
					}' | jq -s '.' >"$findings_dir/format_lint.json"
			else
				# Check failed but we could not attribute files (e.g. the daemon
				# errored, or output format changed). Emit one generic finding so
				# the violation isn't silently dropped.
				jq -n '[{
					type: "format",
					severity: "MINOR",
					rule: "spotless:google-java-format",
					component: "(project)",
					line: 0,
					message: "spotlessCheck reported violations; run spotlessApply to fix.",
					key: "format_lint:project"
				}]' >"$findings_dir/format_lint.json"
				notes+=("format_lint: spotlessCheck failed (exit $check_exit) but no .java paths were attributable from its output; emitted one project-level finding. See the build log if this recurs.")
			fi
		fi
	else
		echo "[]" >"$findings_dir/format_lint.json"
		notes+=("format_lint (Spotless) is configured but no Gradle invocation is available (no ./gradlew wrapper and no 'gradle' on PATH); install a JDK + the Gradle wrapper, or run /development:bootstrap.")
	fi
fi

# --- coverage (deferred this slice) ------------------------------------------
# JaCoCo coverage gathering runs the full test suite and parses
# build/reports/jacoco/.../*.xml — heavyweight, and not load-bearing for the
# pure-mechanical format/lint work this slice ships (spotlessApply is
# behavior-preserving). So we WITHHOLD coverage honestly (null, reliable=false)
# rather than emit a fabricated number. The dispatcher's pure-mechanical
# exception lets format_lint proceed without a coverage floor. Real JaCoCo
# gathering lands with the java-coverage-improver slice.
coverage_reason="JaCoCo coverage gathering is not yet wired for Java (#306 ships format/lint only, which is pure-mechanical and exempt from the coverage floor). Coverage will be measured when the java-coverage-improver slice lands."
notes+=("coverage measurement: source=none, reliable=false — $coverage_reason")

# --- emit --------------------------------------------------------------------
emit_findings() {
	local tool="$1"
	local configured="$2"
	local path="$findings_dir/${tool}.json"
	if [[ "$configured" == "true" && -s "$path" ]]; then
		jq '.' "$path"
	else
		echo "null"
	fi
}

notes_json=$(printf '%s\n' "${notes[@]+"${notes[@]}"}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

jq -n \
	--argjson format_lint_cfg "$has_format_lint_config" \
	--argjson format_lint_findings "$(emit_findings format_lint "$has_format_lint_config")" \
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
      source: "none",
      reliable: false,
      reason: $coverage_reason
    }
  },
  notes: $notes
}
'
