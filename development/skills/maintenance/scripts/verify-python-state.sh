#!/usr/bin/env bash
# verify-python-state.sh — makes sure the project has a usable local .venv
# built against the Python version it declares. Bootstraps one when none
# exists, and recreates it when an existing one is on the wrong interpreter.
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
#   0  State is OK OR was successfully recovered/bootstrapped.
#      On a create-or-recreate, stdout is JSON:
#        {"recovered": true, "action": "created"|"recreated",
#         "from_py": "<old>|none", "to_py": "<new>",
#         "install_target": "<what pip installed>"}
#      "created"   = there was no .venv, so one was bootstrapped (#624) — a
#                    local-only side effect the orchestrator reports even
#                    under --dry-run.
#      "recreated" = an existing .venv was on the wrong interpreter.
#   1  User intervention required — the interpreter isn't on PATH, or no
#      dependency manifest is present to install from. Stderr carries the
#      actionable message; the orchestrator forwards it.
#   2  The `pip install` step failed. Stdout is JSON:
#        {"recreate_failed": true, "project_py": "...", "venv_py": "...",
#         "install_target": "...", "install_log_excerpt": "..."}
#      Orchestrator handles this via R.4 (AskUserQuestion + fallback).

set -euo pipefail

# --- args --------------------------------------------------------------------
target_py=""
repo=""
for arg in "$@"; do
	case "$arg" in
	--target-py=*) target_py="${arg#*=}" ;;
	--*)
		echo "unknown flag: $arg" >&2
		exit 1
		;;
	*) repo="$arg" ;;
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
	# `|| true` on both: a no-match grep exits 1, which under `set -euo pipefail`
	# would abort before the empty-result paths handle "no pin found" gracefully.
	if [[ -f Dockerfile ]]; then
		project_py=$(grep -E '^FROM[[:space:]]+python:' Dockerfile 2>/dev/null |
			head -1 | sed -E 's|.*python:([0-9]+\.[0-9]+).*|\1|' || true)
	fi
	if [[ -z "$project_py" && -f pyproject.toml ]]; then
		project_py=$(grep -E '^[[:space:]]*requires-python' pyproject.toml 2>/dev/null |
			grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
	fi
fi

# --- resolve venv_py ---------------------------------------------------------
venv_py=""
if [[ -x .venv/bin/python ]]; then
	venv_py=$(.venv/bin/python -c \
		"import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" \
		2>/dev/null || true)
fi

# --- detect the pip install target -------------------------------------------
# Not every project is `.[dev]`. Prefer a dev/test extra of an installable
# project, then editable-plus-requirements, then a bare requirements install.
# Populates the globals INSTALL_ARGS (the pip argv, kept as an array so
# `.[dev]` can't be glob-expanded) and INSTALL_LABEL (a human string for the
# summary + JSON). Returns 1 when nothing is derivable (caller escalates).
INSTALL_ARGS=()
INSTALL_LABEL=""
detect_install_target() {
	local extras
	if [[ -f pyproject.toml || -f setup.py || -f setup.cfg ]]; then
		# Pull the optional-dependency extra names out of pyproject.toml.
		extras=$(awk '
			/^\[project\.optional-dependencies\]/ { inopt = 1; next }
			/^\[/                                 { inopt = 0 }
			inopt && /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/ {
				key = $0; sub(/[[:space:]]*=.*/, "", key); gsub(/[[:space:]]/, "", key)
				print key
			}
		' pyproject.toml 2>/dev/null || true)
		if grep -qx 'dev' <<<"$extras"; then
			INSTALL_ARGS=(-e '.[dev]')
			INSTALL_LABEL='.[dev]'
		elif grep -qx 'test' <<<"$extras"; then
			INSTALL_ARGS=(-e '.[test]')
			INSTALL_LABEL='.[test]'
		elif [[ -f requirements-dev.txt ]]; then
			INSTALL_ARGS=(-e . -r requirements-dev.txt)
			INSTALL_LABEL='. + requirements-dev.txt'
		else
			INSTALL_ARGS=(-e .)
			INSTALL_LABEL='.'
		fi
		return 0
	fi
	# Not an installable package (app-style) — fall back to requirements files.
	if [[ -f requirements-dev.txt ]]; then
		INSTALL_ARGS=(-r requirements-dev.txt)
		INSTALL_LABEL='requirements-dev.txt'
	elif [[ -f requirements.txt ]]; then
		INSTALL_ARGS=(-r requirements.txt)
		INSTALL_LABEL='requirements.txt'
	else
		return 1
	fi
	return 0
}

# --- decide the action -------------------------------------------------------
# Four cases:
#   * no .venv present             → bootstrap one (action="created", #624)
#   * .venv present, no project pin → leave it (any venv is OK)
#   * .venv present, matches pin    → leave it
#   * .venv present, wrong pin      → recreate it (action="recreated")
action=""
from_py=""
bootstrap_ver=""
bootstrap_cmd=""

if [[ -z "$venv_py" ]]; then
	# No .venv at all. This used to early-exit, which left coverage
	# unmeasurable and every worktree fix-agent with no environment to
	# self-verify against (#624); bootstrap one instead.
	action="created"
	from_py="none"
	if [[ -n "$project_py" ]]; then
		bootstrap_ver="$project_py"
		bootstrap_cmd="python$project_py"
	else
		# No declared interpreter — bootstrap against system python3, and
		# derive the version label from it below.
		bootstrap_cmd="python3"
	fi
else
	# A .venv exists.
	[[ -z "$project_py" ]] && exit 0            # nothing pinned → any venv OK
	[[ "$project_py" == "$venv_py" ]] && exit 0 # matches → done
	action="recreated"
	from_py="$venv_py"
	bootstrap_ver="$project_py"
	bootstrap_cmd="python$project_py"
fi

# --- R.1: the interpreter must be on PATH ------------------------------------
if ! command -v "$bootstrap_cmd" >/dev/null 2>&1; then
	if [[ -n "$bootstrap_ver" ]]; then
		cat >&2 <<EOF
Project declares Python $bootstrap_ver but $bootstrap_cmd is not on PATH
(local .venv is on Python ${venv_py:-(none)}). Install it first:

    brew install python@$bootstrap_ver

Then re-run /development:maintenance.
EOF
	else
		cat >&2 <<EOF
No .venv found and no python3 on PATH to bootstrap one. Install Python
(e.g. 'brew install python3'), then re-run /development:maintenance.
EOF
	fi
	exit 1
fi

# Derive the version label when it wasn't pinned (no-venv, no declared runtime).
if [[ -z "$bootstrap_ver" ]]; then
	bootstrap_ver=$("$bootstrap_cmd" -c \
		"import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" \
		2>/dev/null || echo "unknown")
fi

# --- resolve the install target (escalate if none) ---------------------------
if ! detect_install_target; then
	cat >&2 <<EOF
Can't bootstrap a virtualenv for $repo: no dependency manifest found. Expected
a pyproject.toml / setup.py (optionally with a [dev] or [test] extra),
requirements-dev.txt, or requirements.txt.

Add one, then re-run /development:maintenance.
EOF
	exit 1
fi

# --- R.2: (re)create the venv + install --------------------------------------
echo "Bootstrapping .venv ($action) against Python $bootstrap_ver (was $from_py); installing ${INSTALL_LABEL}…" >&2
rm -rf .venv
"$bootstrap_cmd" -m venv .venv
.venv/bin/pip install --quiet --upgrade pip

install_log=$(mktemp)
trap 'rm -f "$install_log"' EXIT

if .venv/bin/pip install "${INSTALL_ARGS[@]}" >"$install_log" 2>&1; then
	cat "$install_log" >&2
	jq -n \
		--arg action "$action" \
		--arg from "$from_py" \
		--arg to "$bootstrap_ver" \
		--arg it "$INSTALL_LABEL" \
		'{recovered: true, action: $action, from_py: $from, to_py: $to, install_target: $it}'
	exit 0
fi

# --- R.2 failed: surface for R.4 handling ------------------------------------
cat "$install_log" >&2
log_excerpt=$(tail -30 "$install_log")
jq -n \
	--arg pp "$bootstrap_ver" \
	--arg vp "${venv_py:-none}" \
	--arg it "$INSTALL_LABEL" \
	--arg log "$log_excerpt" \
	'{recreate_failed: true, project_py: $pp, venv_py: $vp, install_target: $it, install_log_excerpt: $log}'
exit 2
