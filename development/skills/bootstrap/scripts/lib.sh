# shellcheck shell=bash
# Shared helpers for bootstrap automation scripts. Source this file; do not
# execute it directly.

# --- logging ------------------------------------------------------------------
_c_reset=$'\033[0m'
_c_dim=$'\033[2m'
_c_red=$'\033[31m'
_c_green=$'\033[32m'
_c_yellow=$'\033[33m'
_c_blue=$'\033[34m'

log() { printf '%s\n' "$*"; }
info() { printf '%s%s%s\n' "$_c_blue" "$*" "$_c_reset"; }
ok() { printf '%s✓ %s%s\n' "$_c_green" "$*" "$_c_reset"; }
warn() { printf '%s! %s%s\n' "$_c_yellow" "$*" "$_c_reset"; }
err() { printf '%s✗ %s%s\n' "$_c_red" "$*" "$_c_reset" >&2; }
dim() { printf '%s%s%s\n' "$_c_dim" "$*" "$_c_reset"; }

die() {
	err "$*"
	exit 1
}

# --- prompts ------------------------------------------------------------------
# These helpers are sourced from BOTH bash and zsh entry-points. zsh treats
# `read -p` as "read from coprocess", not "prompt", so the bash-style
# `read -r -p '<prompt>' var` fails immediately in zsh with "no coprocess".
# Use `printf > /dev/tty` for the prompt + bare `read < /dev/tty` instead;
# works in both shells, and routing via /dev/tty also survives subshell
# capture (e.g. `value=$(ask_secret ...)`). See #196.

# Ask a yes/no question. Default Y unless second arg is "n".
# In a non-interactive context (stdin not a TTY) returns false — callers must
# pass --assume-yes if they want to skip prompts during automation.
ask_yn() {
	local prompt="$1" default="${2:-y}" answer
	local hint="[Y/n]"
	[[ "$default" == "n" ]] && hint="[y/N]"
	if [[ ! -t 0 ]]; then
		return 1
	fi
	printf '%s %s ' "$prompt" "$hint" >/dev/tty
	if ! read -r answer </dev/tty; then
		return 1
	fi
	answer="${answer:-$default}"
	[[ "$answer" =~ ^[Yy] ]]
}

# Ask for a secret without echoing it. Stores in the named variable.
ask_secret() {
	local prompt="$1" __var="$2" value
	printf '%s ' "$prompt" >/dev/tty
	read -r -s value </dev/tty
	printf '\n' >/dev/tty
	printf -v "$__var" '%s' "$value"
}

# Ask for a freeform string with a default value.
ask_str() {
	local prompt="$1" default="$2" __var="$3" value
	printf '%s [%s]: ' "$prompt" "$default" >/dev/tty
	read -r value </dev/tty
	printf -v "$__var" '%s' "${value:-$default}"
}

# --- browser opening ---------------------------------------------------------
# `open <file-or-url>` on macOS uses the Launch-Services default-app registry,
# which can be empty (no default handler for .html) or wrong (e.g. an IDE
# claimed text/html). In both cases the call fails non-zero and downstream
# scripts (e.g. register-claude-apps.sh's auto-submit HTML page,
# install-claude-apps.sh's App-install URLs) silently hang waiting for a
# request that never comes.
#
# This helper tries common browsers in order and falls back to the default.
# See #197.
open_browser() {
	local target="$1" browser
	for browser in \
		"Google Chrome" \
		"Safari" \
		"Firefox" \
		"Microsoft Edge" \
		"Brave Browser" \
		"Arc"; do
		if [[ -d "/Applications/${browser}.app" || -d "$HOME/Applications/${browser}.app" ]]; then
			open -a "$browser" "$target" 2>/dev/null && return 0
		fi
	done
	# Fallback — may still fail if Launch Services has no .html handler.
	open "$target"
}

# --- pre-flight helpers -------------------------------------------------------
require_macos() {
	[[ "$(uname -s)" == "Darwin" ]] || die "This script supports macOS only. Detected: $(uname -s)"
}

require_brew() {
	command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install from https://brew.sh and re-run."
}

# Fail fast if any of the given tools is missing from PATH. Used by the
# automate-*.sh entry points so users see a clear "run preflight first"
# message instead of a confusing later failure deep in the API flow.
# Args: list of binary names (e.g. `require_tools curl jq gh snyk`).
require_tools() {
	local missing=()
	for t in "$@"; do
		command -v "$t" >/dev/null 2>&1 || missing+=("$t")
	done
	if [[ ${#missing[@]} -gt 0 ]]; then
		err "Required tool(s) not on PATH: ${missing[*]}"
		err ""
		err "Run preflight first to install them all in one step:"
		err "  $SCRIPT_DIR/preflight.sh --visibility <public|private> \\"
		err "    --languages \"<detected langs>\" --has-dockerfile <true|false>"
		err ""
		err "Or install manually via: brew install ${missing[*]}"
		exit 1
	fi
}

# brew_install_if_missing <formula> [--cask]
brew_install_if_missing() {
	local pkg="$1" cask_flag=""
	[[ "${2:-}" == "--cask" ]] && cask_flag="--cask"
	if brew list $cask_flag --formula "$pkg" >/dev/null 2>&1 ||
		brew list --cask "$pkg" >/dev/null 2>&1; then
		ok "$pkg already installed"
		return 0
	fi
	info "Installing $pkg via brew…"
	brew install $cask_flag "$pkg"
}

# --- GitHub secrets ----------------------------------------------------------
# Sets a secret in **both** the regular Actions scope AND the Dependabot scope.
# Why both: Dependabot PRs run CI in a restricted security context where only
# Dependabot secrets are visible — Actions secrets resolve to empty string.
# A workflow that needs SONAR_TOKEN / SNYK_TOKEN / etc. will fail on every
# Dependabot PR unless the same token is also stored in the Dependabot scope.
# This helper keeps the two scopes in sync so each bootstrapped project works
# for both regular contributor PRs and Dependabot PRs from day one.
# Args: <secret name> <value>
gh_secret_set_both() {
	local name="$1" value="$2"
	gh secret set "$name" -b "$value"
	gh secret set "$name" --app dependabot -b "$value"
}

# --- Docker detection --------------------------------------------------------
# Sets:
#   _docker_kind   — desktop | cli-only | absent
#   _docker_status — ok | not-running | missing
#
# "desktop"  = Docker Desktop installed in /Applications (bundles compose).
# "cli-only" = `docker` CLI is on PATH but Docker Desktop is not present —
#              user is likely running Colima, OrbStack, Rancher Desktop, or
#              Podman in docker-compat mode. We don't need to know which.
check_docker() {
	_docker_kind="absent"
	_docker_status="missing"

	if [[ -d "/Applications/Docker.app" ]]; then
		_docker_kind="desktop"
	elif command -v docker >/dev/null 2>&1; then
		_docker_kind="cli-only"
	else
		return
	fi

	if docker info >/dev/null 2>&1; then
		_docker_status="ok"
	else
		_docker_status="not-running"
	fi
}

# check_docker_compose — verifies `docker compose` (v2 plugin) is available.
# Docker Desktop bundles it; standalone `docker` brew formula does not. The
# `docker-compose` brew formula installs the v2 plugin (despite the hyphenated
# name) and registers it so `docker compose` works.
# Sets _compose_status: ok | missing
check_docker_compose() {
	if docker compose version >/dev/null 2>&1; then
		_compose_status="ok"
	else
		_compose_status="missing"
	fi
}

# --- HTTP / JSON helpers ------------------------------------------------------
# `sonar_curl` and `sonar_curl_basic` are invoked via `$(...)` so callers can
# capture the response body. That command substitution runs the function in a
# subshell, which means any variable the function tries to set in the parent
# (like `_http_status`) gets discarded. We work around that by writing the
# status code to a known file the parent can read. Callers invoke
# `_load_http_status` after `resp=$(sonar_curl ...)` to populate `_http_status`
# in their own shell.
_HTTP_STATUS_FILE="${TMPDIR:-/tmp}/.bootstrap_http_status.$$"

_load_http_status() {
	_http_status="$(cat "$_HTTP_STATUS_FILE" 2>/dev/null || true)"
}

# Call Sonar API with token in HTTP Basic (Sonar convention: token as username,
# empty password). Echoes the response body. Writes the HTTP status code to
# $_HTTP_STATUS_FILE — call `_load_http_status` afterwards to populate
# `$_http_status` in the parent shell.
sonar_curl() {
	local method="$1" url="$2"
	shift 2
	local body
	body=$(mktemp)
	trap 'rm -f "$body"' RETURN
	curl -sS -o "$body" -w '%{http_code}' \
		-u "${SONAR_TOKEN}:" \
		-X "$method" "$url" "$@" >"$_HTTP_STATUS_FILE"
	cat "$body"
}

# Basic-auth variant — used during initial SonarQube admin bootstrap before any
# token exists. Username:password pair passed as $1.
sonar_curl_basic() {
	local auth="$1" method="$2" url="$3"
	shift 3
	local body
	body=$(mktemp)
	trap 'rm -f "$body"' RETURN
	curl -sS -o "$body" -w '%{http_code}' \
		-u "$auth" \
		-X "$method" "$url" "$@" >"$_HTTP_STATUS_FILE"
	cat "$body"
}

# Wait until URL returns the expected status string for /api/system/status.
# Args: url, timeout-seconds.
wait_for_sonar_up() {
	local url="$1" timeout="${2:-300}" elapsed=0 step=3 status
	while ((elapsed < timeout)); do
		status=$(curl -sS "$url/api/system/status" 2>/dev/null | jq -r '.status // empty')
		if [[ "$status" == "UP" ]]; then
			ok "SonarQube is UP"
			return 0
		fi
		dim "  …waiting for SonarQube (status=${status:-starting}, ${elapsed}s/${timeout}s)"
		sleep "$step"
		elapsed=$((elapsed + step))
	done
	die "SonarQube did not become UP within ${timeout}s"
}

# --- Sonar Quality Gate helpers -----------------------------------------------
# Creates the Zero Tolerance Quality Gate on Sonar (Cloud or QE).
#
# Outputs:
#   _gate_id       — id of the created/existing custom gate (empty if fallback)
#   _gate_created  — "true" if Zero Tolerance gate exists and conditions are set,
#                    "false" if we had to fall back to the default 'Sonar way'
#                    (typically because the SonarCloud Free plan disallows
#                    custom gates — see
#                    https://docs.sonarsource.com/sonarqube-cloud/administering-sonarcloud/managing-subscription/subscription-plans).
#
# Args:
#   $1 — sonar host URL (e.g. https://sonarcloud.io or http://localhost:9000)
#   $2 — organization key (SonarCloud only; pass empty string for SonarQube)
create_zero_tolerance_gate() {
	local host="$1" org="$2"
	local org_arg=""
	[[ -n "$org" ]] && org_arg="&organization=$(printf %s "$org" | jq -sRr @uri)"

	_gate_id=""
	_gate_created="false"

	info "Creating 'Zero Tolerance' Quality Gate…"
	local resp
	resp=$(sonar_curl POST \
		"$host/api/qualitygates/create?name=Zero%20Tolerance${org_arg}")
	_load_http_status

	case "$_http_status" in
	200 | 201)
		_gate_id=$(printf '%s' "$resp" | jq -r '.id')
		_gate_created="true"
		ok "Created gate id=$_gate_id"
		;;
	400)
		# Likely "already exists" — look it up by name.
		dim "  Gate already exists, looking up id…"
		resp=$(sonar_curl GET "$host/api/qualitygates/search${org_arg:+?$org_arg#/}")
		_load_http_status
		# search response shape varies between versions; try both
		_gate_id=$(printf '%s' "$resp" | jq -r '.qualitygates[]? | select(.name=="Zero Tolerance") | .id // empty' | head -n1)
		[[ -n "$_gate_id" ]] || die "Could not resolve existing gate id"
		_gate_created="true"
		ok "Found existing gate id=$_gate_id"
		;;
	403)
		# SonarCloud Free plan disallows custom Quality Gates (Team/Enterprise
		# feature). Fall back to the default 'Sonar way' gate — weaker than
		# Zero Tolerance but still a credible baseline.
		warn "Insufficient privileges to create a custom Quality Gate."
		warn "This is the expected response on the SonarCloud Free plan, where"
		warn "custom Quality Gates require a Team or Enterprise subscription."
		warn "See: https://docs.sonarsource.com/sonarqube-cloud/administering-sonarcloud/managing-subscription/subscription-plans"
		warn ""
		warn "Falling back to the built-in 'Sonar way' Quality Gate. Its coverage"
		warn "threshold is 80% on new code, not the 90% the Zero Tolerance standard"
		warn "calls for. The CI 'coverage-floor' step (in the bootstrap-generated"
		warn "workflow) enforces the 90% bar on every PR independent of SonarCloud,"
		warn "so the standard is preserved — no further action needed here."
		_gate_created="false"
		return 0
		;;
	*)
		die "Quality Gate create failed (HTTP $_http_status): $resp"
		;;
	esac

	# Conditions to add: metric, operator, error-threshold
	local conditions=(
		"new_coverage:LT:90"
		"new_code_smells:GT:0"
		"new_bugs:GT:0"
		"new_vulnerabilities:GT:0"
		"new_security_hotspots_reviewed:LT:100"
		"new_reliability_rating:GT:1"
		"new_security_rating:GT:1"
		"new_maintainability_rating:GT:1"
		"new_security_review_rating:GT:1"
		"new_duplicated_lines_density:GT:3"
	)
	local c metric op err
	for c in "${conditions[@]}"; do
		IFS=':' read -r metric op err <<<"$c"
		resp=$(sonar_curl POST \
			"$host/api/qualitygates/create_condition" \
			--data-urlencode "gateId=$_gate_id" \
			${org:+--data-urlencode "organization=$org"} \
			--data-urlencode "metric=$metric" \
			--data-urlencode "op=$op" \
			--data-urlencode "error=$err")
		_load_http_status
		case "$_http_status" in
		200 | 201) dim "  + $metric $op $err" ;;
		400) dim "  · $metric (already present)" ;;
		*) warn "  ? $metric (HTTP $_http_status): $resp" ;;
		esac
	done
	ok "Quality Gate conditions configured"
}

# Assigns the named gate to a project.
# Args: host, org (or empty), project-key, gate-name
#
# Outputs:
#   _gate_assigned — "true" if the assignment succeeded, "false" on a 403
#                    soft-fail (SonarCloud Free plan blocks custom-gate
#                    assignment even when the gate itself exists). On any
#                    other non-2xx status the function dies as before.
assign_gate_to_project() {
	local host="$1" org="$2" project="$3" gate="$4" resp
	_gate_assigned="false"
	info "Assigning gate '$gate' to project '$project'…"
	resp=$(sonar_curl POST "$host/api/qualitygates/select" \
		--data-urlencode "gateName=$gate" \
		--data-urlencode "projectKey=$project" \
		${org:+--data-urlencode "organization=$org"})
	_load_http_status
	case "$_http_status" in
	200 | 204)
		_gate_assigned="true"
		ok "Gate assigned"
		;;
	403)
		# SonarCloud Free plan: assigning custom Quality Gates to projects is
		# paywalled (Team/Enterprise feature) even when gate creation is
		# permitted under the org's admin token. Fall back: leave the project
		# on the default `Sonar way` gate. The CI `coverage-floor` step (added
		# by the bootstrap templates) is the real 90% enforcement on free, so
		# missing the custom assignment is not a hard failure.
		warn "Could not assign custom gate to project (HTTP 403)."
		warn "On SonarCloud Free this is expected — custom-gate assignment is paywalled."
		warn "Project will use the default 'Sonar way' gate; the CI coverage-floor"
		warn "step enforces the 90% new-code coverage bar regardless."
		;;
	*)
		die "Gate assignment failed (HTTP $_http_status): $resp"
		;;
	esac
}
