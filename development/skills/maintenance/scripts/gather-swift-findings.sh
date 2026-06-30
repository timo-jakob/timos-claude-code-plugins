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
# Resolve the script dir BEFORE cd'ing into the repo, so we can find sibling
# helpers (parse-swift-coverage.py) regardless of the caller's cwd.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
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

# --- sonarcloud (Sonar Swift analyzer) — #443 -------------------------------
# Configured when sonar-project.properties is present. Findings + the main
# branch Quality Gate verdict come from the language-agnostic
# gather-sonarcloud.zsh helper (org+project from the properties file; token
# resolved inside the helper). Swift rule keys look like `swift:Sxxxx`.
has_sonar_config="false"
[[ -f "sonar-project.properties" ]] && has_sonar_config="true"
sonar_json="null"
sonar_quality_gate="null"
if [[ "$has_sonar_config" == "true" ]]; then
	sonar_org=$(grep -E '^[[:space:]]*sonar\.organization' sonar-project.properties 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \r')
	sonar_project=$(grep -E '^[[:space:]]*sonar\.projectKey' sonar-project.properties 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \r')
	if [[ -z "$sonar_org" || -z "$sonar_project" ]]; then
		sonar_json="[]"
		notes+=("sonarcloud is configured but sonar-project.properties is missing 'sonar.organization' or 'sonar.projectKey'; live findings can't be fetched until both are set.")
	else
		sonar_raw="$(mktemp)"
		sonar_stderr="$(mktemp)"
		if "$SCRIPT_DIR/gather-sonarcloud.zsh" "$sonar_org" "$sonar_project" >"$sonar_raw" 2>"$sonar_stderr"; then
			sonar_json="$(jq '.findings // []' "$sonar_raw")"
			sonar_quality_gate="$(jq -c '.quality_gate // null' "$sonar_raw")"
		else
			sonar_json="[]"
		fi
		sonar_note="$(tail -1 "$sonar_stderr" 2>/dev/null || true)"
		[[ -n "$sonar_note" ]] && notes+=("$sonar_note")
		rm -f "$sonar_raw" "$sonar_stderr"
	fi
fi

# --- code_scanning (CodeQL swift + Scorecard) — #443 ------------------------
# Configured when a CodeQL workflow is present (bootstrap generates
# .github/workflows/codeql.yml). Alerts come from the language-agnostic
# gather-github-security.zsh helper (gh API; free, no quota). The alert shape
# is identical across languages — only the CodeQL rule IDs differ (swift/...).
has_code_scanning_config="false"
if ls .github/workflows/codeql*.yml >/dev/null 2>&1; then
	has_code_scanning_config="true"
fi
code_scanning_json="null"
if [[ "$has_code_scanning_config" == "true" ]]; then
	cs_helper="$SCRIPT_DIR/gather-github-security.zsh"
	if [[ ! -x "$cs_helper" ]]; then
		code_scanning_json="[]"
		notes+=("Code Scanning gather: helper script not found or not executable at $cs_helper. Update your plugin install (cd to the marketplace dir, 'git pull').")
	else
		cs_raw="$(mktemp)"
		cs_stderr="$(mktemp)"
		if "$cs_helper" "$repo" >"$cs_raw" 2>"$cs_stderr"; then
			code_scanning_json="$(jq '.code_scanning_alerts' "$cs_raw")"
			cs_label="ok"
		else
			code_scanning_json="[]"
			cs_label="failed"
		fi
		cs_content="$(tr '\n' ' ' <"$cs_stderr" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
		[[ -n "$cs_content" ]] && notes+=("Code Scanning gather ($cs_label): $cs_content")
		rm -f "$cs_raw" "$cs_stderr"
	fi
fi

# --- semgrep — DEFERRED for Swift (#443) ------------------------------------
# Semgrep's Swift support is experimental and the rule registry ships NO Swift
# rules — `--config=auto` finds nothing, so a triage agent would falsely imply
# coverage. Reported as not-configured (never an empty findings array); no
# gather, no agent. Revisit when the registry gains Swift rules (#443).
has_semgrep_config="false"

# --- coverage (xccov / llvm-cov) — #444, #258 reliability --------------------
# Measure per-source-file LINE coverage when the Swift toolchain is available
# AND test targets exist. A figure is only trustworthy when the test run
# completes and a coverage report is produced AND parses; anything else is
# WITHHELD (null + reliable=false) with a reason, never fabricated. Two build
# systems:
#   - SwiftPM: `swift test --enable-code-coverage`, then the llvm-cov export at
#     `swift test --show-codecov-path`.
#   - Xcode:   `xcodebuild test -enableCodeCoverage YES -resultBundlePath …`,
#     then `xcrun xccov view --report --json`.
# parse-swift-coverage.py reads either format. Measurement is gated on test
# presence so a project with nothing to cover (and the hermetic test fixtures)
# never trigger a heavy, pointless toolchain run.
coverage_overall="null"
coverage_by_module="{}"
coverage_regions="[]"
coverage_source="none"
coverage_reliable="false"
coverage_reason="Coverage was not measured."

# Build system: Xcode wins when a project/workspace is present (the app is the
# product); a bare Package.swift is SwiftPM. Mirrors detect-stack.sh.
swift_build_system=""
if find . -path '*/.git' -prune -o -path '*/.build' -prune -o \
	\( -name '*.xcodeproj' -o -name '*.xcworkspace' \) -print -quit 2>/dev/null | grep -q .; then
	swift_build_system="xcode"
elif [[ -f "Package.swift" ]]; then
	swift_build_system="swiftpm"
fi

# Test presence (the real coverage precondition — Swift coverage is
# toolchain-built-in, so there's no config to detect; tests are what gate it).
has_tests="false"
if [[ -f "Package.swift" ]] && grep -qE '\.testTarget\(' "Package.swift" 2>/dev/null; then
	has_tests="true"
elif [[ -d "Tests" ]]; then
	has_tests="true"
elif find . -path '*/.git' -prune -o -path '*/.build' -prune -o \
	\( -name '*Tests.swift' -o -name '*Test.swift' \) -print -quit 2>/dev/null | grep -q .; then
	has_tests="true"
fi

cov_json=""
cov_tmp="$(mktemp -d)"
if [[ "$has_tests" != "true" ]]; then
	coverage_reason="no test targets found (no .testTarget in Package.swift, no Tests/ dir, no *Tests.swift); coverage was not measured — there is nothing to cover."
elif [[ "$swift_build_system" == "swiftpm" ]]; then
	if command -v swift >/dev/null 2>&1; then
		coverage_source="swiftpm"
		test_exit=0
		swift test --enable-code-coverage >"$cov_tmp/test.log" 2>&1 || test_exit=$?
		codecov_path="$(swift test --show-codecov-path 2>/dev/null || true)"
		if [[ -n "$codecov_path" && -f "$codecov_path" ]]; then
			cov_json="$codecov_path"
			((test_exit > 0)) && notes+=("Swift test suite exited $test_exit during coverage measurement; the coverage figure is valid but the suite is currently red.")
		else
			coverage_reason="ran 'swift test --enable-code-coverage' (exit $test_exit) but no llvm-cov export was found at --show-codecov-path; coverage withheld."
		fi
	else
		coverage_reason="SwiftPM project but 'swift' is not on PATH; coverage was not measured (e.g. CI without the toolchain)."
	fi
elif [[ "$swift_build_system" == "xcode" ]]; then
	if command -v xcodebuild >/dev/null 2>&1 && command -v xcrun >/dev/null 2>&1; then
		coverage_source="xcode"
		scheme="$(xcodebuild -list -json 2>/dev/null | jq -r '(.workspace.schemes // .project.schemes // [])[0] // empty' 2>/dev/null || true)"
		if [[ -n "$scheme" ]]; then
			result_bundle="$cov_tmp/Result.xcresult"
			xc_exit=0
			xcodebuild test -scheme "$scheme" -destination 'platform=macOS' \
				-enableCodeCoverage YES -resultBundlePath "$result_bundle" \
				>"$cov_tmp/xcodebuild.log" 2>&1 || xc_exit=$?
			if [[ -d "$result_bundle" ]]; then
				xcrun xccov view --report --json "$result_bundle" >"$cov_tmp/xccov.json" 2>/dev/null || true
				if [[ -s "$cov_tmp/xccov.json" ]]; then
					cov_json="$cov_tmp/xccov.json"
					((xc_exit > 0)) && notes+=("xcodebuild test exited $xc_exit during coverage measurement; the coverage figure is valid but the suite/build is currently red.")
				else
					coverage_reason="xcodebuild test produced a result bundle (exit $xc_exit) but 'xccov view --report --json' yielded no data; coverage withheld."
				fi
			else
				coverage_reason="ran 'xcodebuild test -enableCodeCoverage YES' (exit $xc_exit) for scheme '$scheme' but no .xcresult was produced — likely a build/destination error; coverage withheld."
			fi
		else
			coverage_reason="Xcode project but no scheme could be discovered via 'xcodebuild -list -json'; coverage withheld."
		fi
	else
		coverage_reason="Xcode project but 'xcodebuild'/'xcrun' are not available (not on macOS, or the Command Line Tools are missing); coverage was not measured."
	fi
else
	coverage_reason="No Swift build system detected (no Package.swift, .xcodeproj, or .xcworkspace); coverage was not measured."
fi

# Parse whichever coverage JSON we obtained (already cd'd into the repo, so the
# parser keys paths repo-relative).
if [[ -n "$cov_json" ]]; then
	parsed="$(python3 "$SCRIPT_DIR/parse-swift-coverage.py" "$cov_json" 2>/dev/null || true)"
	if [[ -n "$parsed" ]] && jq -e . >/dev/null 2>&1 <<<"$parsed"; then
		maybe_overall="$(jq '.overall' <<<"$parsed")"
		if [[ "$maybe_overall" != "null" ]]; then
			coverage_overall="$maybe_overall"
			coverage_by_module="$(jq '.by_module' <<<"$parsed")"
			coverage_regions="$(jq -c '.regions // []' <<<"$parsed")"
			coverage_reliable="true"
			coverage_reason="measured via $coverage_source, parsed by parse-swift-coverage.py."
		else
			coverage_reason="coverage report parsed but contained no measurable project source lines; figure withheld."
		fi
	else
		coverage_reason="coverage report found but could not be parsed by parse-swift-coverage.py; coverage withheld."
	fi
fi
rm -rf "$cov_tmp"

# Emit one provenance note ALWAYS, so the figure's trust level is never silent.
notes+=("coverage measurement: source=$coverage_source, reliable=$coverage_reliable — $coverage_reason")

# --- notes -> JSON -----------------------------------------------------------
if [[ ${#notes[@]} -gt 0 ]]; then
	notes_json=$(printf '%s\n' "${notes[@]}" | jq -R . | jq -s '.')
else
	notes_json="[]"
fi

# --- emit --------------------------------------------------------------------
jq -n \
	--argjson format_lint_cfg "$has_format_lint_config" \
	--argjson sonar_cfg "$has_sonar_config" \
	--argjson code_scanning_cfg "$has_code_scanning_config" \
	--argjson semgrep_cfg "$has_semgrep_config" \
	--argjson format_lint_findings "$format_lint_json" \
	--argjson sonar_findings "$sonar_json" \
	--argjson cs_findings "$code_scanning_json" \
	--argjson sonar_quality_gate "$sonar_quality_gate" \
	--argjson coverage_overall "$coverage_overall" \
	--argjson coverage_by_module "$coverage_by_module" \
	--argjson coverage_regions "$coverage_regions" \
	--arg coverage_source "$coverage_source" \
	--argjson coverage_reliable "$coverage_reliable" \
	--arg coverage_reason "$coverage_reason" \
	--argjson notes "$notes_json" '
{
  tooling_configured: {
    format_lint:   $format_lint_cfg,
    sonarcloud:    $sonar_cfg,
    code_scanning: $code_scanning_cfg,
    semgrep:       $semgrep_cfg
  },
  findings_by_tool: (
    {} +
    (if $format_lint_findings != null then {format_lint:          $format_lint_findings} else {} end) +
    (if $sonar_findings       != null then {sonarcloud:           $sonar_findings}       else {} end) +
    (if $cs_findings          != null then {code_scanning_alerts: $cs_findings}          else {} end)
  ),
  coverage: {
    overall:   $coverage_overall,
    by_module: $coverage_by_module,
    regions:   $coverage_regions,
    measurement: {
      source:   $coverage_source,
      reliable: $coverage_reliable,
      reason:   $coverage_reason
    }
  },
  sonar_quality_gate: $sonar_quality_gate,
  notes: $notes
}
'
