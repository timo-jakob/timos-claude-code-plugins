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
#       "format_lint":   true|false,  # Spotless (google-java-format) via Gradle
#       "sonarcloud":    true|false,  # SonarCloud / self-hosted SonarQube
#       "code_scanning": true|false,  # GitHub Code Scanning (CodeQL + Scorecard)
#       "semgrep":       true|false,  # semgrep (--config=auto)
#       "dependabot":    true|false,  # open Dependabot PRs
#       "snyk_prs":      true|false,   # open Snyk auto-Fix/Upgrade PRs
#       "renovate":      true|false,   # open Renovate PRs (third vendor source)
#       "versioning":    true|false,   # build-driven vs hardcoded version
#       "grpc":          true|false,   # gRPC/protobuf code-gen (.proto present)
#       "openapi":       true|false   # non-Spring contract-first OpenAPI
#     },
#     "findings_by_tool": {
#       "format_lint":          [ ... or omitted if not configured ... ],
#       "sonarcloud":           [ ... normalized Sonar findings ... ],
#       "code_scanning_alerts": [ ... CodeQL + Scorecard alerts ... ],
#       "semgrep":              [ ... semgrep results array ... ],
#       "dependabot":           [ ... open Dependabot PR records ... ],
#       "snyk_prs":             [ ... open Snyk PR records ... ],
#       "renovate":             [ ... open Renovate PR records ... ],
#       "versioning":           [ ... hardcoded-version findings ... ],
#       "grpc":                 [ ... proto-audit finding ... ],
#       "openapi":              [ ... contract-audit finding ... ]
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
#   - sonarcloud + JaCoCo coverage  — second slice
#   - code_scanning + semgrep       — third slice
#   - dependabot + snyk_prs         — vendor PR triage + majors
#   - renovate                      — third vendor-PR source (#335)
# The JDK runtime-upgrade special case (docker base-image bumps that are the
# JDK itself) is deferred to a later slice (#308); docker bumps currently route
# to human-review.
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

# Code Scanning: assume configured when a CodeQL workflow is present (bootstrap
# generates .github/workflows/codeql.yml). The helper still tries the API and
# returns [] gracefully if it's disabled at the repo-settings level.
has_code_scanning_config="false"
if ls .github/workflows/codeql*.yml >/dev/null 2>&1; then
	has_code_scanning_config="true"
fi

# Semgrep: configured when a semgrep hook (pre-commit) or CI job is wired.
has_semgrep_config="false"
if grep -qE 'returntocorp/semgrep|semgrep/semgrep' .pre-commit-config.yaml 2>/dev/null ||
	grep -qE 'semgrep ci|returntocorp/semgrep|semgrep/semgrep' .github/workflows/*.yml 2>/dev/null; then
	has_semgrep_config="true"
fi

# Dependabot: configured when .github/dependabot.yml exists.
has_dependabot_config="false"
if [[ -f ".github/dependabot.yml" ]]; then
	has_dependabot_config="true"
fi

# Snyk auto-Fix/Upgrade PRs: configured when a .snyk policy file is present.
has_snyk_prs_config="false"
if [[ -f ".snyk" ]]; then
	has_snyk_prs_config="true"
fi

# Renovate: configured when a Renovate config file is present. A third
# vendor-PR source alongside Dependabot + Snyk — many real Java/Gradle repos
# use Renovate. Its open PRs feed the same java-dependabot-snyk-triage path.
has_renovate_config="false"
if [[ -f "renovate.json" || -f "renovate.json5" || -f ".github/renovate.json" ||
	-f ".github/renovate.json5" || -f ".renovaterc" || -f ".renovaterc.json" ||
	-f ".renovaterc.json5" || -f ".gitlab/renovate.json" ]]; then
	has_renovate_config="true"
fi

# Versioning: the tool applies to any Gradle project — it polices whether the
# version is build-driven (derived from git tags) vs hardcoded. "Configured"
# whenever a Gradle build file exists; findings fire on a hardcoded version.
has_versioning_config="false"
if find . -maxdepth 2 -path '*/build/*' -prune -o \
	\( -name 'build.gradle' -o -name 'build.gradle.kts' \) -print -quit 2>/dev/null | grep -q .; then
	has_versioning_config="true"
fi

# gRPC / protobuf: configured when .proto files exist (the authoritative API
# contract). The java-grpc-advisor audits whether the com.google.protobuf
# Gradle plugin is wired to generate Java + gRPC stubs from them.
has_grpc_config="false"
if find . -path '*/build/*' -prune -o -path '*/.git/*' -prune -o \
	-name '*.proto' -print -quit 2>/dev/null | grep -q .; then
	has_grpc_config="true"
fi

# OpenAPI (NON-Spring): contract-first OpenAPI applies to non-Spring Java HTTP
# services. Configured when a committed OpenAPI spec exists AND the repo is NOT
# a Spring web app — Spring repos are handled by development-spring's
# spring-api-advisor (the `spring` generator), so we defer to avoid
# double-handling (mirrors the org.springframework.boot bump deferral). This
# advisor uses the non-Spring `jaxrs-spec` generator.
has_openapi_config="false"
if find . -path '*/build/*' -prune -o -path '*/.git/*' -prune -o \
	\( -iname 'openapi.yaml' -o -iname 'openapi.yml' -o -iname 'openapi.json' \) \
	-print -quit 2>/dev/null | grep -q .; then
	if ! grep -rqE 'spring-boot-starter-web(flux)?' \
		--include='build.gradle' --include='build.gradle.kts' . 2>/dev/null; then
		has_openapi_config="true"
	fi
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

# code_scanning — GitHub Code Scanning alerts (CodeQL java pack + Scorecard),
# via the language-agnostic gather-github-security.zsh helper (gh API; free,
# no quota burn). Alert shape is identical across languages — only the CodeQL
# rule IDs differ (java/sql-injection, etc.).
if [[ "$has_code_scanning_config" == "true" ]]; then
	cs_stderr=$(mktemp)
	cs_helper="$SCRIPT_DIR/gather-github-security.zsh"
	if [[ ! -x "$cs_helper" ]]; then
		echo "[]" >"$findings_dir/code_scanning_alerts.json"
		notes+=("Code Scanning gather: helper script not found or not executable at $cs_helper. Update your plugin install (cd to the marketplace dir, 'git pull').")
	else
		if "$cs_helper" "$repo" >"$findings_dir/cs_api.json" 2>"$cs_stderr"; then
			jq '.code_scanning_alerts' "$findings_dir/cs_api.json" >"$findings_dir/code_scanning_alerts.json"
			cs_exit_label="ok"
		else
			echo "[]" >"$findings_dir/code_scanning_alerts.json"
			cs_exit_label="failed"
		fi
		cs_stderr_content=$(tr '\n' ' ' <"$cs_stderr" 2>/dev/null | sed 's/[[:space:]]*$//' || true)
		if [[ -n "$cs_stderr_content" ]]; then
			notes+=("Code Scanning gather ($cs_exit_label): $cs_stderr_content")
		fi
		rm -f "$cs_stderr"
	fi
fi

# semgrep — local run (--config=auto covers Java). `--error` makes it exit
# non-zero on findings, which we tolerate; normalize to just the results array.
if [[ "$has_semgrep_config" == "true" ]]; then
	if command -v semgrep >/dev/null 2>&1; then
		semgrep --config=auto --json --quiet --error --metrics=off . \
			>"$findings_dir/semgrep_raw.json" 2>/dev/null || true
		[[ -s "$findings_dir/semgrep_raw.json" ]] || echo '{"results":[]}' >"$findings_dir/semgrep_raw.json"
		jq '.results // []' "$findings_dir/semgrep_raw.json" >"$findings_dir/semgrep.json"
	else
		echo "[]" >"$findings_dir/semgrep.json"
		notes+=("semgrep is configured but the 'semgrep' binary is not on PATH; install with 'brew install semgrep' or 'pip install semgrep'.")
	fi
fi

# dependabot — open PRs authored by dependabot[bot]. Raw PR records; the
# planner classifies ecosystem (gradle / github-actions / docker) + bump level
# and routes. Requires gh authenticated.
if [[ "$has_dependabot_config" == "true" ]]; then
	if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
		gh pr list --author "app/dependabot" --state open --json number,title,body,headRefName \
			>"$findings_dir/dependabot.json" 2>/dev/null || echo "[]" >"$findings_dir/dependabot.json"
	else
		echo "[]" >"$findings_dir/dependabot.json"
		notes+=("dependabot is configured but 'gh' is not available/authenticated; can't list open Dependabot PRs.")
	fi
fi

# snyk_prs — open PRs whose head branch starts with snyk-fix- or snyk-upgrade-
# (opened by Snyk's GitHub App). Treated alongside Dependabot PRs by
# java-dependabot-snyk-triage.
if [[ "$has_snyk_prs_config" == "true" ]]; then
	if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
		{
			gh pr list --state open --search "head:snyk-fix-" \
				--json number,title,body,headRefName 2>/dev/null || echo "[]"
			gh pr list --state open --search "head:snyk-upgrade-" \
				--json number,title,body,headRefName 2>/dev/null || echo "[]"
		} | jq -s 'add // []' >"$findings_dir/snyk_prs.json" 2>/dev/null ||
			echo "[]" >"$findings_dir/snyk_prs.json"
	else
		echo "[]" >"$findings_dir/snyk_prs.json"
		notes+=(".snyk file present but 'gh' is not available/authenticated; can't list open Snyk PRs.")
	fi
fi

# renovate — open PRs authored by renovate[bot] (branch prefix renovate/).
# A third vendor-PR source; java-maintenance-planner classifies ecosystem +
# bump level from the Renovate title/branch and routes alongside Dependabot.
if [[ "$has_renovate_config" == "true" ]]; then
	if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
		gh pr list --author "app/renovate" --state open --json number,title,body,headRefName \
			>"$findings_dir/renovate.json" 2>/dev/null || echo "[]" >"$findings_dir/renovate.json"
	else
		echo "[]" >"$findings_dir/renovate.json"
		notes+=("renovate is configured but 'gh' is not available/authenticated; can't list open Renovate PRs.")
	fi
fi

# versioning — flag a HARDCODED version (a manual-bump SemVer risk). The
# java-versioning-advisor recommends build-driven versioning (nebula-release,
# version derived from git tags) where the release bump is derived from
# Conventional Commits. Match `version = '...'` / `version = "..."` in a Gradle
# build script, and `version=...` in gradle.properties.
if [[ "$has_versioning_config" == "true" ]]; then
	ver_hits="$(grep -rnE "^[[:space:]]*version[[:space:]]*=[[:space:]]*['\"]" \
		--include='build.gradle' --include='build.gradle.kts' . 2>/dev/null || true)"
	if [[ -f "gradle.properties" ]]; then
		gp_hits="$(grep -nE '^[[:space:]]*version[[:space:]]*=' gradle.properties 2>/dev/null |
			sed 's#^#./gradle.properties:#' || true)"
		ver_hits="$(printf '%s\n%s\n' "$ver_hits" "$gp_hits")"
	fi
	# Each hit: "<path>:<line>:<text>". Capture the grep'd lines first — a
	# no-match grep exits 1, which under `set -euo pipefail` (pipefail) would
	# abort the whole script if left mid-pipeline. `|| true` tolerates it.
	echo "[]" >"$findings_dir/versioning.json"
	ver_lines="$(printf '%s\n' "$ver_hits" | grep -E ':[0-9]+:' || true)"
	if [[ -n "$ver_lines" ]]; then
		printf '%s\n' "$ver_lines" |
			while IFS= read -r hit; do
				vfile="${hit%%:*}"
				rest="${hit#*:}"
				vline="${rest%%:*}"
				jq -n --arg c "${vfile#./}" --argjson l "$vline" '{
					type: "config", severity: "MINOR", rule: "versioning:hardcoded-version",
					component: $c, line: $l,
					message: "Hardcoded project version — a manual-bump SemVer risk. Adopt build-driven versioning (nebula-release derives the version from git tags; the release workflow derives the bump from Conventional Commits).",
					key: ("versioning:hardcoded:" + $c + ":" + ($l|tostring))
				}'
			done | jq -s '.' >"$findings_dir/versioning.json"
	fi
fi

# grpc — emit one proto-audit finding (referencing the root build file) when
# .proto files exist. The java-grpc-advisor reads the build script and checks
# the com.google.protobuf / protoc / gRPC wiring (a grep can't reliably judge
# the multi-block plugin config), recommending the setup when it's missing.
if [[ "$has_grpc_config" == "true" ]]; then
	echo "[]" >"$findings_dir/grpc.json"
	grpc_build="$(find . -maxdepth 2 -path '*/build/*' -prune -o \
		\( -name 'build.gradle' -o -name 'build.gradle.kts' \) -print 2>/dev/null | head -n1)"
	if [[ -n "$grpc_build" ]]; then
		jq -n --arg c "${grpc_build#./}" '[{
			type: "config", severity: "MINOR", rule: "grpc:proto-audit",
			component: $c, line: 0,
			message: "Audit the gRPC/protobuf code-generation wiring — the com.google.protobuf Gradle plugin running protoc + the gRPC plugin to generate Java + gRPC stubs from the authoritative .proto contract, with generated sources on the compile path and excluded from coverage.",
			key: ("grpc:proto-audit:" + $c)
		}]' >"$findings_dir/grpc.json"
	fi
fi

# openapi — emit one contract-audit finding (referencing the root build file)
# when a committed OpenAPI spec exists in a non-Spring repo. The
# java-openapi-advisor reads the build script and checks the openapi-generator
# wiring (jaxrs-spec generator), recommending the setup when it's missing.
if [[ "$has_openapi_config" == "true" ]]; then
	echo "[]" >"$findings_dir/openapi.json"
	oa_build="$(find . -maxdepth 2 -path '*/build/*' -prune -o \
		\( -name 'build.gradle' -o -name 'build.gradle.kts' \) -print 2>/dev/null | head -n1)"
	if [[ -n "$oa_build" ]]; then
		jq -n --arg c "${oa_build#./}" '[{
			type: "config", severity: "MINOR", rule: "openapi:contract-audit",
			component: $c, line: 0,
			message: "Audit the contract-first OpenAPI wiring (non-Spring) — a committed OpenAPI spec as the authoritative HTTP surface, with openapi-generator producing JAX-RS (jaxrs-spec) interfaces the resources implement, so code/spec drift fails the build.",
			key: ("openapi:contract-audit:" + $c)
		}]' >"$findings_dir/openapi.json"
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
	--argjson code_scanning_cfg "$has_code_scanning_config" \
	--argjson semgrep_cfg "$has_semgrep_config" \
	--argjson dependabot_cfg "$has_dependabot_config" \
	--argjson snyk_prs_cfg "$has_snyk_prs_config" \
	--argjson renovate_cfg "$has_renovate_config" \
	--argjson versioning_cfg "$has_versioning_config" \
	--argjson grpc_cfg "$has_grpc_config" \
	--argjson openapi_cfg "$has_openapi_config" \
	--argjson format_lint_findings "$(emit_findings format_lint "$has_format_lint_config")" \
	--argjson sonar_findings "$(emit_findings sonarcloud "$has_sonar_config")" \
	--argjson cs_findings "$(emit_findings code_scanning_alerts "$has_code_scanning_config")" \
	--argjson semgrep_findings "$(emit_findings semgrep "$has_semgrep_config")" \
	--argjson dependabot_findings "$(emit_findings dependabot "$has_dependabot_config")" \
	--argjson snyk_prs_findings "$(emit_findings snyk_prs "$has_snyk_prs_config")" \
	--argjson renovate_findings "$(emit_findings renovate "$has_renovate_config")" \
	--argjson versioning_findings "$(emit_findings versioning "$has_versioning_config")" \
	--argjson grpc_findings "$(emit_findings grpc "$has_grpc_config")" \
	--argjson openapi_findings "$(emit_findings openapi "$has_openapi_config")" \
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
    format_lint:   $format_lint_cfg,
    sonarcloud:    $sonar_cfg,
    code_scanning: $code_scanning_cfg,
    semgrep:       $semgrep_cfg,
    dependabot:    $dependabot_cfg,
    snyk_prs:      $snyk_prs_cfg,
    renovate:      $renovate_cfg,
    versioning:    $versioning_cfg,
    grpc:          $grpc_cfg,
    openapi:       $openapi_cfg
  },
  findings_by_tool: (
    {} +
    (if $format_lint_findings != null then {format_lint:          $format_lint_findings} else {} end) +
    (if $sonar_findings       != null then {sonarcloud:           $sonar_findings}       else {} end) +
    (if $cs_findings          != null then {code_scanning_alerts: $cs_findings}          else {} end) +
    (if $semgrep_findings     != null then {semgrep:              $semgrep_findings}     else {} end) +
    (if $dependabot_findings  != null then {dependabot:           $dependabot_findings}  else {} end) +
    (if $snyk_prs_findings    != null then {snyk_prs:             $snyk_prs_findings}    else {} end) +
    (if $renovate_findings    != null then {renovate:             $renovate_findings}    else {} end) +
    (if $versioning_findings  != null then {versioning:           $versioning_findings}  else {} end) +
    (if $grpc_findings        != null then {grpc:                 $grpc_findings}        else {} end) +
    (if $openapi_findings     != null then {openapi:              $openapi_findings}     else {} end)
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
