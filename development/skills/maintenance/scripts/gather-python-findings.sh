#!/usr/bin/env bash
# gather-python-findings.sh — produces the per-tool maintenance payload for
# a Python project: which tools are configured, the findings they report,
# and per-module coverage.
#
# Usage:
#   gather-python-findings.sh <repo_path>
#
# Output (stdout, JSON):
#   {
#     "tooling_configured": {
#       "ruff":           true|false,
#       "semgrep":        true|false,
#       "code_scanning":  true|false,   # GitHub Code Scanning (CodeQL etc.)
#       "snyk_prs":       true|false,   # Snyk auto-Fix/Upgrade PRs
#       "sonarcloud":     true|false,
#       "dependabot":     true|false
#     },
#     "findings_by_tool": {
#       "ruff":                 [ ... or omitted if not configured ... ],
#       "code_scanning_alerts": [ ... SAST alerts from gh code-scanning ... ],
#       "snyk_prs":             [ ... Snyk-opened PRs (snyk-fix-*/snyk-upgrade-*) ... ],
#       "dependabot":           [ ... Dependabot-opened PRs ... ],
#       ...
#     },
#     "coverage": {
#       "overall": 0..100|null,
#       "by_module": { "src/x.py": 92, ... }
#     },
#     "sonar_quality_gate": {        # main-branch Quality Gate verdict (#50);
#       "status": "OK|ERROR|WARN|NONE",  # null when sonar isn't configured or
#       "conditions": [ ... ]            # the fetch failed. User-facing only —
#     }                                  # never copied into the dispatch payload.
#   }
#
# Note (timos-claude-code-plugins#87): the legacy `snyk_code`/`snyk_oss`
# keys produced by gather-snyk.zsh's Snyk REST API path were retired in
# PR ε. SAST replacement is `code_scanning_alerts` (free, GitHub-native);
# OSS-vuln replacement is Snyk's own auto-Fix-PRs flowing through the
# `snyk_prs` key alongside Dependabot.
#
# Failure modes are graceful: a configured tool that can't run (auth missing,
# command not in PATH, etc.) is reported as configured-but-no-findings with a
# `notes` field at the bottom of the JSON explaining why. The orchestrator
# surfaces these notes to the user.

set -euo pipefail

# Resolve sibling-script directory (needed to invoke gather-sonarcloud.zsh).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

repo="${1:-}"
[[ -n "$repo" && -d "$repo" ]] || {
	echo "usage: $0 <repo_path>" >&2
	exit 2
}

cd "$repo"

notes=()

# --- pick a Python interpreter -----------------------------------------------
# Many projects keep pytest + coverage tooling inside a project-local venv
# rather than on the global PATH. Check the conventional venv locations
# first; fall back to system python3 / pytest if no venv is present.
#
# Sets PY_BIN (python3 to use) and PYTEST_BIN (pytest to use). Either may
# be empty if nothing is found — downstream code adds notes in that case.
PY_BIN=""
PYTEST_BIN=""
PY_SOURCE="system"
for venv_dir in .venv venv env; do
	if [[ -x "$venv_dir/bin/python3" ]]; then
		PY_BIN="$repo/$venv_dir/bin/python3"
		[[ -x "$venv_dir/bin/pytest" ]] && PYTEST_BIN="$repo/$venv_dir/bin/pytest"
		PY_SOURCE="$venv_dir"
		break
	fi
done
[[ -z "$PY_BIN" ]] && command -v python3 >/dev/null 2>&1 && PY_BIN="$(command -v python3)"
[[ -z "$PYTEST_BIN" ]] && command -v pytest >/dev/null 2>&1 && PYTEST_BIN="$(command -v pytest)"

# --- tooling_configured ------------------------------------------------------
has_ruff_config="false"
if [[ -f "ruff.toml" ]] || grep -q '^\[tool\.ruff' pyproject.toml 2>/dev/null; then
	has_ruff_config="true"
fi

has_semgrep_config="false"
if grep -qE 'returntocorp/semgrep|semgrep/semgrep' .pre-commit-config.yaml 2>/dev/null ||
	grep -qE 'semgrep ci|returntocorp/semgrep' .github/workflows/*.yml 2>/dev/null; then
	has_semgrep_config="true"
fi

has_sonar_config="false"
if [[ -f "sonar-project.properties" ]]; then
	has_sonar_config="true"
fi

has_dependabot_config="false"
if [[ -f ".github/dependabot.yml" ]]; then
	has_dependabot_config="true"
fi

# Code Scanning: assume configured when the CodeQL workflow is present
# (bootstrap generates .github/workflows/codeql.yml by default). The
# gather-github-security.zsh helper will still try the API and return an
# empty array gracefully if it's disabled at the repo-settings level.
has_code_scanning_config="false"
if ls .github/workflows/codeql*.yml >/dev/null 2>&1; then
	has_code_scanning_config="true"
fi

# Snyk PRs: configured when .snyk file is present (the local marker of
# Snyk integration setup). Even if no snyk-* PRs are currently open, the
# tool counts as "set up" so the dispatcher will check for them.
has_snyk_prs_config="false"
if [[ -f ".snyk" ]]; then
	has_snyk_prs_config="true"
fi

# --- findings_by_tool --------------------------------------------------------
# Each block writes JSON to a temp file, or "[]" if the tool can't produce
# anything. We compose the final structure at the end via jq.
findings_dir="$(mktemp -d)"
trap 'rm -rf "$findings_dir"' EXIT

# ruff — `ruff check --output-format=json`. Capture exit code separately
# because ruff exits non-zero when it finds violations (which is the whole
# point), and we don't want that to abort the script.
if [[ "$has_ruff_config" == "true" ]]; then
	if command -v ruff >/dev/null 2>&1; then
		ruff check --output-format=json . >"$findings_dir/ruff.json" 2>/dev/null || true
		# If ruff produced nothing (failure or no issues), default to []
		[[ -s "$findings_dir/ruff.json" ]] || echo "[]" >"$findings_dir/ruff.json"
	else
		echo "[]" >"$findings_dir/ruff.json"
		notes+=("ruff is configured (config file present) but the 'ruff' binary is not on PATH; install with 'brew install ruff' or 'pip install ruff'.")
	fi
fi

# semgrep — local run can be slow; we run with --error so it exits non-zero
# on findings, and capture JSON via --json.
if [[ "$has_semgrep_config" == "true" ]]; then
	if command -v semgrep >/dev/null 2>&1; then
		semgrep --config=auto --json --quiet --error --metrics=off . \
			>"$findings_dir/semgrep.json" 2>/dev/null || true
		[[ -s "$findings_dir/semgrep.json" ]] || echo '{"results":[]}' >"$findings_dir/semgrep.json"
		# Normalize to just the results array.
		jq '.results // []' "$findings_dir/semgrep.json" >"$findings_dir/semgrep.normalized.json"
		mv "$findings_dir/semgrep.normalized.json" "$findings_dir/semgrep.json"
	else
		echo "[]" >"$findings_dir/semgrep.json"
		notes+=("semgrep is configured but the 'semgrep' binary is not on PATH; install with 'brew install semgrep' or 'pip install semgrep'.")
	fi
fi

# GitHub Code Scanning alerts (SAST) — replaces the Snyk REST API path
# that was retired in PR ε of #87. Code Scanning is free on public repos
# and uses the existing `gh` auth — no quota burn, no paid plan needed.
# The CodeQL workflow generated by bootstrap populates these alerts.
if [[ "$has_code_scanning_config" == "true" ]]; then
	cs_stderr=$(mktemp)
	cs_helper="$SCRIPT_DIR/gather-github-security.zsh"
	if [[ ! -x "$cs_helper" ]]; then
		echo "[]" >"$findings_dir/code_scanning_alerts.json"
		notes+=("Code Scanning gather: helper script not found or not executable at $cs_helper. Update your plugin install (cd to the marketplace dir, 'git pull').")
	else
		if "$cs_helper" "$repo" \
			>"$findings_dir/cs_api.json" 2>"$cs_stderr"; then
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

# sonarcloud — fetch live findings (open issues + TO_REVIEW hotspots) plus
# the main branch's Quality Gate verdict via the SonarCloud REST API using
# gather-sonarcloud.zsh. The helper emits {findings, quality_gate}; findings
# go to findings_by_tool.sonarcloud, the QG verdict to the top-level
# sonar_quality_gate key. Token resolution is handled inside the helper
# (env var → macOS keychain → interactive prompt on TTY). The helper prints
# a one-line summary as its FINAL stderr line; we surface that via notes[].
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
		# The helper's last stderr line is its caller-facing one-liner (success
		# summary or failure note). Surface it either way so the user knows.
		sonar_note=$(tail -1 "$sonar_stderr" 2>/dev/null || true)
		[[ -n "$sonar_note" ]] && notes+=("$sonar_note")
		rm -f "$sonar_stderr"
	fi
fi

# dependabot — query GitHub for open PRs authored by dependabot[bot]. Requires
# 'gh' authenticated.
if [[ "$has_dependabot_config" == "true" ]]; then
	if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
		gh pr list --author "app/dependabot" --state open --json number,title,body,headRefName \
			>"$findings_dir/dependabot.json" 2>/dev/null || echo "[]" >"$findings_dir/dependabot.json"
	else
		echo "[]" >"$findings_dir/dependabot.json"
		notes+=("dependabot is configured but 'gh' is not available/authenticated; can't list open Dependabot PRs.")
	fi
fi

# snyk_prs — query GitHub for open PRs whose head branch starts with
# snyk-fix- or snyk-upgrade-. These are opened by Snyk's GitHub App when
# autoFixPR/autoUpgradePR is enabled per SETUP.md section 2.6. Treated
# alongside Dependabot PRs by python-dependabot-snyk-triage.
if [[ "$has_snyk_prs_config" == "true" ]]; then
	if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
		# Two queries (one per prefix), merged into a single array.
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

# --- coverage ----------------------------------------------------------------
# Run pytest with --cov; produce coverage.json; parse per-module percentages.
#
# A coverage number is only trustworthy when the suite runs in the project's
# OWN environment and pytest completes normally. So we record HOW the
# measurement was taken (interpreter source + pytest exit) and a reliability
# verdict, and we WITHHOLD the number (null) when it cannot be trusted — a
# confident wrong figure is worse than none. Downstream must treat a null
# overall / empty by_module as "coverage unknown", never as 0%.
coverage_overall="null"
coverage_by_module="{}"
coverage_source="none"
coverage_pytest_exit="null"
coverage_reliable="false"
coverage_reason="pytest is not available (checked PATH and .venv/, venv/, env/); coverage was not measured."

if [[ -n "$PYTEST_BIN" && -n "$PY_BIN" ]]; then
	coverage_source="$PY_SOURCE"
	# pytest-cov needs to be importable from the interpreter we'll actually run.
	if "$PY_BIN" -c 'import pytest_cov' >/dev/null 2>&1; then
		# Capture pytest's exit status — do NOT discard it. Non-zero means tests
		# failed (1) or, worse, collection/internal errors (>=2) left the coverage
		# data partial. The `|| pytest_exit=$?` form captures the code without
		# letting `set -e` abort on the (expected) non-zero exit.
		pytest_exit=0
		"$PYTEST_BIN" --cov --cov-report=json --cov-report= -q --no-header >/dev/null 2>&1 ||
			pytest_exit=$?
		coverage_pytest_exit="$pytest_exit"

		if [[ ! -f "coverage.json" ]]; then
			coverage_reason="pytest ran (exit $pytest_exit) via $coverage_source but produced no coverage.json; coverage could not be measured."
		elif [[ "$coverage_source" == "system" ]]; then
			# No project venv found — the system interpreter almost certainly lacks
			# the project's dependencies, so any number is misleading. Withhold it.
			coverage_reason="measured with the system interpreter ($PY_BIN); no project venv at .venv/venv/env, so project dependencies may be missing and the figure is not trustworthy. Activate the project venv and re-run."
		elif ((pytest_exit >= 2)); then
			# 2=interrupted, 3=internal error, 4=usage error, 5=no tests collected.
			coverage_reason="pytest terminated abnormally (exit $pytest_exit) under $coverage_source; coverage.json is partial. Figure withheld."
		else
			# exit 0 (all passed) or 1 (some failed) under a project venv: the lines
			# still executed, so the coverage figure itself is valid.
			coverage_overall=$(jq '.totals.percent_covered // null' coverage.json)
			coverage_by_module=$(jq '
        .files
        | to_entries
        | map({ key: .key, value: (.value.summary.percent_covered // 0) })
        | from_entries
      ' coverage.json)
			coverage_reliable="true"
			coverage_reason="measured with $coverage_source/bin/pytest (exit $pytest_exit)."
			if ((pytest_exit == 1)); then
				notes+=("pytest reported test failures (exit 1) during coverage measurement; the coverage figure is valid but the suite is currently red.")
			fi
		fi
	else
		coverage_reason="pytest found at $PYTEST_BIN but pytest-cov is not importable from $PY_BIN; install with '$PY_BIN -m pip install pytest-cov'. Coverage not measured."
	fi
elif [[ -n "$PYTEST_BIN" && -z "$PY_BIN" ]]; then
	coverage_reason="pytest found but no usable python3 — coverage was not measured."
fi

# Emit one provenance note ALWAYS, so the figure's trust level is never silent.
notes+=("coverage measurement: source=$coverage_source, pytest_exit=$coverage_pytest_exit, reliable=$coverage_reliable — $coverage_reason")

# --- emit --------------------------------------------------------------------
# Build the final JSON. jq lets us compose without manual string escaping.

emit_findings() {
	local tool="$1"
	local configured="$2"
	local path="$findings_dir/${tool}.json"
	if [[ "$configured" == "true" && -s "$path" ]]; then
		jq --arg t "$tool" '.' "$path"
	else
		echo "null"
	fi
}

# Build notes JSON.
notes_json=$(printf '%s\n' "${notes[@]+"${notes[@]}"}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

jq -n \
	--argjson ruff_cfg "$has_ruff_config" \
	--argjson semgrep_cfg "$has_semgrep_config" \
	--argjson code_scanning_cfg "$has_code_scanning_config" \
	--argjson snyk_prs_cfg "$has_snyk_prs_config" \
	--argjson sonar_cfg "$has_sonar_config" \
	--argjson dependabot_cfg "$has_dependabot_config" \
	--argjson ruff_findings "$(emit_findings ruff "$has_ruff_config")" \
	--argjson semgrep_findings "$(emit_findings semgrep "$has_semgrep_config")" \
	--argjson cs_findings "$(emit_findings code_scanning_alerts "$has_code_scanning_config")" \
	--argjson snyk_prs_findings "$(emit_findings snyk_prs "$has_snyk_prs_config")" \
	--argjson sonar_findings "$(emit_findings sonarcloud "$has_sonar_config")" \
	--argjson dependabot_findings "$(emit_findings dependabot "$has_dependabot_config")" \
	--argjson coverage_overall "$coverage_overall" \
	--argjson coverage_by_module "$coverage_by_module" \
	--arg coverage_source "$coverage_source" \
	--argjson coverage_pytest_exit "$coverage_pytest_exit" \
	--argjson coverage_reliable "$coverage_reliable" \
	--arg coverage_reason "$coverage_reason" \
	--argjson sonar_quality_gate "$sonar_quality_gate" \
	--argjson notes "$notes_json" '
{
  tooling_configured: {
    ruff:           $ruff_cfg,
    semgrep:        $semgrep_cfg,
    code_scanning:  $code_scanning_cfg,
    snyk_prs:       $snyk_prs_cfg,
    sonarcloud:     $sonar_cfg,
    dependabot:     $dependabot_cfg
  },
  findings_by_tool: (
    {} +
    (if $ruff_findings         != null then {ruff:                 $ruff_findings}         else {} end) +
    (if $semgrep_findings      != null then {semgrep:              $semgrep_findings}      else {} end) +
    (if $cs_findings           != null then {code_scanning_alerts: $cs_findings}           else {} end) +
    (if $snyk_prs_findings     != null then {snyk_prs:             $snyk_prs_findings}     else {} end) +
    (if $sonar_findings        != null then {sonarcloud:           $sonar_findings}        else {} end) +
    (if $dependabot_findings   != null then {dependabot:           $dependabot_findings}   else {} end)
  ),
  coverage: {
    overall:   $coverage_overall,
    by_module: $coverage_by_module,
    measurement: {
      source:      $coverage_source,
      pytest_exit: $coverage_pytest_exit,
      reliable:    $coverage_reliable,
      reason:      $coverage_reason
    }
  },
  sonar_quality_gate: $sonar_quality_gate,
  notes: $notes
}
'
