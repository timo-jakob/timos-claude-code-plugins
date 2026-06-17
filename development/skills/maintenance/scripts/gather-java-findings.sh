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
#       "format_lint": true|false,  # Spotless (google-java-format) via Gradle
#       "sonarcloud":  true|false   # SonarCloud / self-hosted SonarQube
#     },
#     "findings_by_tool": {
#       "format_lint": [ ... or omitted if not configured ... ],
#       "sonarcloud":  [ ... normalized Sonar findings ... ]
#     },
#     "coverage": {                 # measured via JaCoCo (gradle jacocoTestReport)
#       "overall": 0..100|null,     # null = withheld (untrustworthy / unmeasured)
#       "by_module": { "src/main/java/.../Foo.java": 92.0, ... },
#       "measurement": { "source", "gradle_exit", "reliable", "reason" }
#     },
#     "sonar_quality_gate": { ... }|null,  # main-branch QG verdict (user-facing)
#     "notes": [ ... ]
#   }
#
# SCOPE (issue #306, #296 Java/Gradle epic). Tool universe so far:
#   - format_lint (Spotless)        — first slice
#   - sonarcloud + JaCoCo coverage  — this slice
# semgrep, code_scanning, and dependabot land in later slices, each alongside
# its triage agent.
#
# Failure modes are graceful: a configured tool that can't run (no JDK, gradle
# wrapper absent, daemon error, missing token) is reported as
# configured-but-no-findings with a `notes` entry explaining why. A coverage
# figure is WITHHELD (null) rather than fabricated when the build can't be
# trusted (no gradle, no JaCoCo report, or an abnormal build exit).

set -euo pipefail

# Resolve sibling-script dir (needed to invoke gather-sonarcloud.zsh).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

repo="${1:-}"
[[ -n "$repo" && -d "$repo" ]] || {
	echo "usage: $0 <repo_path>" >&2
	exit 2
}

cd "$repo"

notes=()

# --- pick a Gradle invocation ------------------------------------------------
# Prefer the project's wrapper (./gradlew) so the build runs with the version
# the project pins; fall back to a system `gradle`. Empty when neither exists.
GRADLE_BIN=""
if [[ -x "./gradlew" ]]; then
	GRADLE_BIN="./gradlew"
elif command -v gradle >/dev/null 2>&1; then
	GRADLE_BIN="gradle"
fi

# --- tooling_configured ------------------------------------------------------
# Spotless: the com.diffplug.spotless plugin (or a bare `spotless {` block) in a
# Gradle build script (Groovy or Kotlin DSL).
has_format_lint_config="false"
spotless_marker='com\.diffplug\.spotless|spotless[[:space:]]*\{'
if grep -rqE "$spotless_marker" \
	--include='build.gradle' --include='build.gradle.kts' . 2>/dev/null; then
	has_format_lint_config="true"
fi

# SonarCloud / SonarQube: configured when sonar-project.properties is present.
has_sonar_config="false"
if [[ -f "sonar-project.properties" ]]; then
	has_sonar_config="true"
fi

# JaCoCo: the jacoco plugin in a Gradle build script. Drives whether we attempt
# a coverage measurement at all.
has_jacoco_config="false"
if grep -rqE 'jacoco' \
	--include='build.gradle' --include='build.gradle.kts' . 2>/dev/null; then
	has_jacoco_config="true"
fi

# --- findings_by_tool --------------------------------------------------------
findings_dir="$(mktemp -d)"
trap 'rm -rf "$findings_dir"' EXIT

# format_lint — `gradle spotlessCheck` exits non-zero when files violate the
# format. We emit one finding per violating .java path. A non-zero exit WITHOUT
# the Spotless violation signature is a build/compile error, not a formatting
# finding — we must not mis-attribute it.
if [[ "$has_format_lint_config" == "true" ]]; then
	if [[ -n "$GRADLE_BIN" ]]; then
		check_log="$findings_dir/spotless-check.log"
		check_exit=0
		"$GRADLE_BIN" spotlessCheck --quiet >"$check_log" 2>&1 || check_exit=$?

		if [[ "$check_exit" -eq 0 ]]; then
			echo "[]" >"$findings_dir/format_lint.json"
		elif ! grep -qiE 'spotlessApply|format violations' "$check_log" 2>/dev/null; then
			echo "[]" >"$findings_dir/format_lint.json"
			notes+=("format_lint: spotlessCheck exited $check_exit without a Spotless violation signature — the Gradle build likely failed for an unrelated reason (compile error, missing JDK toolchain, daemon issue). Treated as 'no format findings'; fix the build and re-run.")
		else
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
						message: "File is not formatted per google-java-format; run spotlessApply.",
						key: ("format_lint:" + .)
					}' | jq -s '.' >"$findings_dir/format_lint.json"
			else
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

# sonarcloud — fetch live findings (open issues + TO_REVIEW hotspots) plus the
# main branch's Quality Gate verdict via the language-agnostic
# gather-sonarcloud.zsh helper (org+project from sonar-project.properties; token
# resolved inside the helper). Java rule keys look like `java:Sxxxx`.
sonar_quality_gate="null"
if [[ "$has_sonar_config" == "true" ]]; then
	sonar_org=$(grep -E '^[[:space:]]*sonar\.organization' sonar-project.properties 2>/dev/null |
		head -1 | cut -d= -f2- | tr -d ' \r')
	sonar_project=$(grep -E '^[[:space:]]*sonar\.projectKey' sonar-project.properties 2>/dev/null |
		head -1 | cut -d= -f2- | tr -d ' \r')

	if [[ -z "$sonar_org" || -z "$sonar_project" ]]; then
		echo "[]" >"$findings_dir/sonarcloud.json"
		notes+=("sonarcloud is configured but sonar-project.properties is missing 'sonar.organization' or 'sonar.projectKey'; live findings can't be fetched until both are set.")
	else
		sonar_stderr=$(mktemp)
		if "$SCRIPT_DIR/gather-sonarcloud.zsh" "$sonar_org" "$sonar_project" \
			>"$findings_dir/sonarcloud_raw.json" 2>"$sonar_stderr"; then
			jq '.findings // []' "$findings_dir/sonarcloud_raw.json" >"$findings_dir/sonarcloud.json"
			sonar_quality_gate=$(jq -c '.quality_gate // null' "$findings_dir/sonarcloud_raw.json")
		else
			echo "[]" >"$findings_dir/sonarcloud.json"
		fi
		# The helper's last stderr line is its caller-facing one-liner.
		sonar_note=$(tail -1 "$sonar_stderr" 2>/dev/null || true)
		[[ -n "$sonar_note" ]] && notes+=("$sonar_note")
		rm -f "$sonar_stderr"
	fi
fi

# --- coverage (JaCoCo) -------------------------------------------------------
# Run the test suite + JaCoCo report, parse per-source-file LINE coverage. A
# figure is only trustworthy when Gradle completes normally (exit 0 = green, or
# 1 = tests failed but lines still executed) AND a report was produced. Any
# other exit (>=2: compile/config error) leaves the report partial → WITHHELD.
# Mirrors the Python coverage-reliability discipline (#258).
coverage_overall="null"
coverage_by_module="{}"
coverage_source="none"
coverage_gradle_exit="null"
coverage_reliable="false"
coverage_reason="JaCoCo is not configured (no jacoco plugin in the Gradle build); coverage was not measured."

if [[ "$has_jacoco_config" == "true" ]]; then
	if [[ -n "$GRADLE_BIN" ]]; then
		coverage_source="gradle"
		gradle_exit=0
		"$GRADLE_BIN" test jacocoTestReport --quiet >/dev/null 2>&1 || gradle_exit=$?
		coverage_gradle_exit="$gradle_exit"

		# Collect every JaCoCo XML report (single- and multi-module builds).
		reports=$(find . -path '*/build/reports/jacoco/*' -name '*.xml' \
			-not -path '*/.git/*' 2>/dev/null || true)

		if [[ -z "$reports" ]]; then
			coverage_reason="ran '$GRADLE_BIN test jacocoTestReport' (exit $gradle_exit) but produced no JaCoCo XML report; coverage could not be measured. Ensure jacocoTestReport has 'xml.required = true'."
		elif ((gradle_exit >= 2)); then
			coverage_reason="Gradle terminated abnormally (exit $gradle_exit) — likely a compile/config error; the JaCoCo report is partial. Figure withheld."
		else
			# Parse the XML report(s) with python3 (stdlib only). Resolves each
			# sourcefile to its repo-relative path so keys match Sonar's
			# `component` paths the dispatcher floors against.
			# shellcheck disable=SC2086
			parsed=$(python3 "$SCRIPT_DIR/parse-jacoco.py" $reports 2>/dev/null || true)
			if [[ -n "$parsed" ]] && jq -e . >/dev/null 2>&1 <<<"$parsed"; then
				coverage_overall=$(jq '.overall' <<<"$parsed")
				coverage_by_module=$(jq '.by_module' <<<"$parsed")
				coverage_reliable="true"
				coverage_reason="measured with '$GRADLE_BIN test jacocoTestReport' (exit $gradle_exit)."
				if ((gradle_exit == 1)); then
					notes+=("Gradle reported test failures (exit 1) during coverage measurement; the JaCoCo figure is valid but the suite is currently red.")
				fi
			else
				coverage_reason="JaCoCo report(s) found but could not be parsed; coverage withheld."
			fi
		fi
	else
		coverage_reason="JaCoCo is configured but no Gradle invocation is available (no ./gradlew and no 'gradle' on PATH); coverage was not measured."
	fi
fi

# Emit one provenance note ALWAYS, so the figure's trust level is never silent.
notes+=("coverage measurement: source=$coverage_source, gradle_exit=$coverage_gradle_exit, reliable=$coverage_reliable — $coverage_reason")

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
	--argjson sonar_cfg "$has_sonar_config" \
	--argjson format_lint_findings "$(emit_findings format_lint "$has_format_lint_config")" \
	--argjson sonar_findings "$(emit_findings sonarcloud "$has_sonar_config")" \
	--argjson coverage_overall "$coverage_overall" \
	--argjson coverage_by_module "$coverage_by_module" \
	--arg coverage_source "$coverage_source" \
	--argjson coverage_gradle_exit "$coverage_gradle_exit" \
	--argjson coverage_reliable "$coverage_reliable" \
	--arg coverage_reason "$coverage_reason" \
	--argjson sonar_quality_gate "$sonar_quality_gate" \
	--argjson notes "$notes_json" '
{
  tooling_configured: {
    format_lint: $format_lint_cfg,
    sonarcloud:  $sonar_cfg
  },
  findings_by_tool: (
    {} +
    (if $format_lint_findings != null then {format_lint: $format_lint_findings} else {} end) +
    (if $sonar_findings       != null then {sonarcloud:  $sonar_findings}       else {} end)
  ),
  coverage: {
    overall:   $coverage_overall,
    by_module: $coverage_by_module,
    measurement: {
      source:      $coverage_source,
      gradle_exit: $coverage_gradle_exit,
      reliable:    $coverage_reliable,
      reason:      $coverage_reason
    }
  },
  sonar_quality_gate: $sonar_quality_gate,
  notes: $notes
}
'
