#!/usr/bin/env bash
# verify-python-state.sh — confirms the project's local .venv is built
# against the Python version the project declares. Recreates the venv when
# it doesn't match.
#
# Owned by the development-python plugin; lives in the orchestrator's
# scripts directory alongside gather-python-findings.sh to match the
# per-language naming convention the orchestrator expects.
#
# Usage:
#   verify-python-state.sh <repo_path>                — auto-detect target
#   verify-python-state.sh --target-py=X.Y <repo_path> — force a specific
#                                                       Python version
#                                                       (used by R.4 fallback)
#
# Exit codes (consumed by the orchestrator's Phase 3 / Phase 8 step 7):
#   0  State is OK OR was successfully recovered.
#      On recovery, stdout is JSON:
#        {"recovered": true, "from_py": "<old>", "to_py": "<new>"}
#   1  User intervention required (typically: python<X.Y> not on PATH).
#      Stderr carries the actionable message; orchestrator forwards it.
#   2  Recreate's `pip install` failed. Stdout is JSON:
#        {"recreate_failed": true, "project_py": "...", "venv_py": "...",
#         "install_log_excerpt": "..."}
#      Orchestrator handles this via R.4 (AskUserQuestion + fallback).

set -euo pipefail

# --- args --------------------------------------------------------------------
target_py=""
repo=""
for arg in "$@"; do
  case "$arg" in
    --target-py=*) target_py="${arg#*=}" ;;
    --*)           echo "unknown flag: $arg" >&2; exit 1 ;;
    *)             repo="$arg" ;;
  esac
done
[[ -n "$repo" && -d "$repo" ]] || {
  echo "usage: $0 [--target-py=X.Y] <repo_path>" >&2
  exit 1
}
cd "$repo"

# --- resolve project_py (auto-detect mode) -----------------------------------
project_py=""
if [[ -n "$target_py" ]]; then
  project_py="$target_py"
else
  if [[ -f Dockerfile ]]; then
    project_py=$(grep -E '^FROM[[:space:]]+python:' Dockerfile 2>/dev/null \
                 | head -1 | sed -E 's|.*python:([0-9]+\.[0-9]+).*|\1|')
  fi
  if [[ -z "$project_py" && -f pyproject.toml ]]; then
    project_py=$(grep -E '^[[:space:]]*requires-python' pyproject.toml 2>/dev/null \
                 | grep -oE '[0-9]+\.[0-9]+' | head -1)
  fi
fi

# --- resolve venv_py ---------------------------------------------------------
venv_py=""
if [[ -x .venv/bin/python ]]; then
  venv_py=$(.venv/bin/python -c \
    "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" \
    2>/dev/null || true)
fi

# --- early-exit cases (no action needed) -------------------------------------
# No declared runtime → user hasn't pinned anything, any venv is OK.
[[ -z "$project_py" ]] && exit 0
# No venv at all → not our problem; gather's existing notes path surfaces it.
[[ -z "$venv_py" && -z "$target_py" ]] && exit 0
# Match → done.
[[ "$project_py" == "$venv_py" ]] && exit 0

# --- R.1: target interpreter must be on PATH ---------------------------------
if ! command -v "python$project_py" >/dev/null 2>&1; then
  cat >&2 <<EOF
Project declares Python $project_py but local .venv is on Python ${venv_py:-(none)},
and python$project_py is not on PATH. Install it first:

    brew install python@$project_py

Then re-run /development:maintenance.
EOF
  exit 1
fi

# --- R.2: recreate the venv + install ----------------------------------------
echo "Recreating .venv against Python $project_py (was ${venv_py:-none})…" >&2
rm -rf .venv
"python$project_py" -m venv .venv
.venv/bin/pip install --quiet --upgrade pip

install_log=$(mktemp)
trap 'rm -f "$install_log"' EXIT

if .venv/bin/pip install -e ".[dev]" > "$install_log" 2>&1; then
  cat "$install_log" >&2
  jq -n --arg from "${venv_py:-none}" --arg to "$project_py" \
    '{recovered: true, from_py: $from, to_py: $to}'
  exit 0
fi

# --- R.2 failed: surface for R.4 handling ------------------------------------
cat "$install_log" >&2
log_excerpt=$(tail -30 "$install_log")
jq -n \
  --arg pp "$project_py" \
  --arg vp "${venv_py:-none}" \
  --arg log "$log_excerpt" \
  '{recreate_failed: true, project_py: $pp, venv_py: $vp, install_log_excerpt: $log}'
exit 2
