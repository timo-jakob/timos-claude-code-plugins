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
#       "ruff":       true|false,
#       "semgrep":    true|false,
#       "snyk_code":  true|false,
#       "snyk_oss":   true|false,
#       "sonarcloud": true|false,
#       "dependabot": true|false
#     },
#     "findings_by_tool": {
#       "ruff":       [ ... or omitted if not configured ... ],
#       ...
#     },
#     "coverage": {
#       "overall": 0..100|null,
#       "by_module": { "src/x.py": 92, ... }
#     }
#   }
#
# Failure modes are graceful: a configured tool that can't run (auth missing,
# command not in PATH, etc.) is reported as configured-but-no-findings with a
# `notes` field at the bottom of the JSON explaining why. The orchestrator
# surfaces these notes to the user.

set -euo pipefail

# Resolve sibling-script directory (needed to invoke gather-sonarcloud.zsh).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

repo="${1:-}"
[[ -n "$repo" && -d "$repo" ]] || { echo "usage: $0 <repo_path>" >&2; exit 2; }

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
[[ -z "$PY_BIN"     ]] && command -v python3 >/dev/null 2>&1 && PY_BIN="$(command -v python3)"
[[ -z "$PYTEST_BIN" ]] && command -v pytest  >/dev/null 2>&1 && PYTEST_BIN="$(command -v pytest)"

# --- tooling_configured ------------------------------------------------------
has_ruff_config="false"
if [[ -f "ruff.toml" ]] || grep -q '^\[tool\.ruff' pyproject.toml 2>/dev/null; then
  has_ruff_config="true"
fi

has_semgrep_config="false"
if grep -qE 'returntocorp/semgrep|semgrep/semgrep' .pre-commit-config.yaml 2>/dev/null \
   || grep -qE 'semgrep ci|returntocorp/semgrep' .github/workflows/*.yml 2>/dev/null; then
  has_semgrep_config="true"
fi

has_snyk_config="false"
if [[ -f ".snyk" ]] || grep -qE 'snyk/actions|snyk\s+(code|test|container)' .github/workflows/*.yml 2>/dev/null; then
  has_snyk_config="true"
fi

has_sonar_config="false"
if [[ -f "sonar-project.properties" ]]; then
  has_sonar_config="true"
fi

has_dependabot_config="false"
if [[ -f ".github/dependabot.yml" ]]; then
  has_dependabot_config="true"
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
    ruff check --output-format=json . > "$findings_dir/ruff.json" 2>/dev/null || true
    # If ruff produced nothing (failure or no issues), default to []
    [[ -s "$findings_dir/ruff.json" ]] || echo "[]" > "$findings_dir/ruff.json"
  else
    echo "[]" > "$findings_dir/ruff.json"
    notes+=("ruff is configured (config file present) but the 'ruff' binary is not on PATH; install with 'brew install ruff' or 'pip install ruff'.")
  fi
fi

# semgrep — local run can be slow; we run with --error so it exits non-zero
# on findings, and capture JSON via --json.
if [[ "$has_semgrep_config" == "true" ]]; then
  if command -v semgrep >/dev/null 2>&1; then
    semgrep --config=auto --json --quiet --error --metrics=off . \
      > "$findings_dir/semgrep.json" 2>/dev/null || true
    [[ -s "$findings_dir/semgrep.json" ]] || echo '{"results":[]}' > "$findings_dir/semgrep.json"
    # Normalize to just the results array.
    jq '.results // []' "$findings_dir/semgrep.json" > "$findings_dir/semgrep.normalized.json"
    mv "$findings_dir/semgrep.normalized.json" "$findings_dir/semgrep.json"
  else
    echo "[]" > "$findings_dir/semgrep.json"
    notes+=("semgrep is configured but the 'semgrep' binary is not on PATH; install with 'brew install semgrep' or 'pip install semgrep'.")
  fi
fi

# snyk — fetch findings via the REST API using gather-snyk.zsh. CLI scans
# (`snyk code test`, `snyk test`) each consume one private-test slot from
# the org's monthly quota REGARDLESS of repo visibility, so we go through
# the GitHub-integration-imported project on app.snyk.io instead — API
# reads don't consume quota. See timos-claude-code-plugins#82 for the
# rationale and the original incident (Snyk GitHub App PR checks blocked
# by quota exhaustion).
#
# Per the issue's design choice: if the API path fails for any reason
# (no token, no integration project found, HTTP error), we do NOT fall
# back to CLI scans — falling back would defeat the quota-protection
# purpose. We emit "[]" for both arrays + a note explaining the cause.
if [[ "$has_snyk_config" == "true" ]]; then
  snyk_stderr=$(mktemp)
  if "$SCRIPT_DIR/gather-snyk.zsh" "$repo" \
       > "$findings_dir/snyk_api.json" 2>"$snyk_stderr"; then
    jq '.snyk_code' "$findings_dir/snyk_api.json" > "$findings_dir/snyk_code.json"
    jq '.snyk_oss'  "$findings_dir/snyk_api.json" > "$findings_dir/snyk_oss.json"
  else
    echo "[]" > "$findings_dir/snyk_code.json"
    echo "[]" > "$findings_dir/snyk_oss.json"
  fi
  # The helper writes a single explanatory line to stderr in both success
  # and failure cases — surface it so the user sees which path was used.
  snyk_note=$(tail -1 "$snyk_stderr" 2>/dev/null || true)
  [[ -n "$snyk_note" ]] && notes+=("$snyk_note")
  rm -f "$snyk_stderr"
fi

# sonarcloud — fetch live findings (open issues + TO_REVIEW hotspots) via the
# SonarCloud REST API using gather-sonarcloud.zsh. Token resolution is handled
# inside that helper (env var → macOS keychain → interactive prompt on TTY).
# The helper prints a one-line summary as its FINAL stderr line; we surface
# that to the user via notes[].
if [[ "$has_sonar_config" == "true" ]]; then
  sonar_org=$(grep -E '^[[:space:]]*sonar\.organization' sonar-project.properties 2>/dev/null \
    | head -1 | cut -d= -f2- | tr -d ' \r')
  sonar_project=$(grep -E '^[[:space:]]*sonar\.projectKey' sonar-project.properties 2>/dev/null \
    | head -1 | cut -d= -f2- | tr -d ' \r')

  if [[ -z "$sonar_org" || -z "$sonar_project" ]]; then
    echo "[]" > "$findings_dir/sonarcloud.json"
    notes+=("sonarcloud is configured but sonar-project.properties is missing 'sonar.organization' or 'sonar.projectKey'; live findings can't be fetched until both are set.")
  else
    sonar_stderr=$(mktemp)
    if "$SCRIPT_DIR/gather-sonarcloud.zsh" "$sonar_org" "$sonar_project" \
         > "$findings_dir/sonarcloud.json" 2>"$sonar_stderr"; then
      :  # success — final-line note still picked up below
    else
      echo "[]" > "$findings_dir/sonarcloud.json"
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
      > "$findings_dir/dependabot.json" 2>/dev/null || echo "[]" > "$findings_dir/dependabot.json"
  else
    echo "[]" > "$findings_dir/dependabot.json"
    notes+=("dependabot is configured but 'gh' is not available/authenticated; can't list open Dependabot PRs.")
  fi
fi

# --- coverage ----------------------------------------------------------------
# Run pytest with --cov; produce coverage.json; parse per-module percentages.
# If neither pytest nor pytest-cov is available, leave coverage null + add
# notes explaining what to install.
coverage_overall="null"
coverage_by_module="{}"

if [[ -n "$PYTEST_BIN" && -n "$PY_BIN" ]]; then
  # pytest-cov needs to be importable from the same env. Check using the
  # interpreter we'll actually run.
  if "$PY_BIN" -c 'import pytest_cov' >/dev/null 2>&1; then
    "$PYTEST_BIN" --cov --cov-report=json --cov-report= -q --no-header \
      > /dev/null 2>&1 || true
    if [[ -f "coverage.json" ]]; then
      coverage_overall=$(jq '.totals.percent_covered // null' coverage.json)
      coverage_by_module=$(jq '
        .files
        | to_entries
        | map({ key: .key, value: (.value.summary.percent_covered // 0) })
        | from_entries
      ' coverage.json)
      [[ "$PY_SOURCE" != "system" ]] && \
        notes+=("coverage gathered using $PY_SOURCE/bin/pytest (project-local venv).")
    fi
  else
    notes+=("pytest found at $PYTEST_BIN but pytest-cov is not importable from that interpreter; install with '$PY_BIN -m pip install pytest-cov'.")
  fi
elif [[ -n "$PYTEST_BIN" && -z "$PY_BIN" ]]; then
  notes+=("pytest found but no usable python3 — coverage gathering skipped.")
else
  notes+=("pytest is not available (checked PATH and .venv/, venv/, env/); coverage gathering skipped. Activate your project venv or install pytest globally.")
fi

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
  --argjson ruff_cfg          "$has_ruff_config" \
  --argjson semgrep_cfg       "$has_semgrep_config" \
  --argjson snyk_cfg          "$has_snyk_config" \
  --argjson sonar_cfg         "$has_sonar_config" \
  --argjson dependabot_cfg    "$has_dependabot_config" \
  --argjson ruff_findings     "$(emit_findings ruff       "$has_ruff_config")" \
  --argjson semgrep_findings  "$(emit_findings semgrep    "$has_semgrep_config")" \
  --argjson snyk_code_findings "$(emit_findings snyk_code "$has_snyk_config")" \
  --argjson snyk_oss_findings  "$(emit_findings snyk_oss  "$has_snyk_config")" \
  --argjson sonar_findings     "$(emit_findings sonarcloud "$has_sonar_config")" \
  --argjson dependabot_findings "$(emit_findings dependabot "$has_dependabot_config")" \
  --argjson coverage_overall   "$coverage_overall" \
  --argjson coverage_by_module "$coverage_by_module" \
  --argjson notes              "$notes_json" '
{
  tooling_configured: {
    ruff:       $ruff_cfg,
    semgrep:    $semgrep_cfg,
    snyk_code:  $snyk_cfg,
    snyk_oss:   $snyk_cfg,
    sonarcloud: $sonar_cfg,
    dependabot: $dependabot_cfg
  },
  findings_by_tool: (
    {} +
    (if $ruff_findings        != null then {ruff:       $ruff_findings}        else {} end) +
    (if $semgrep_findings     != null then {semgrep:    $semgrep_findings}     else {} end) +
    (if $snyk_code_findings   != null then {snyk_code:  $snyk_code_findings}   else {} end) +
    (if $snyk_oss_findings    != null then {snyk_oss:   $snyk_oss_findings}    else {} end) +
    (if $sonar_findings       != null then {sonarcloud: $sonar_findings}       else {} end) +
    (if $dependabot_findings  != null then {dependabot: $dependabot_findings}  else {} end)
  ),
  coverage: {
    overall:   $coverage_overall,
    by_module: $coverage_by_module
  },
  notes: $notes
}
'
