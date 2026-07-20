#!/usr/bin/env bash
# preflight.sh — verify the local toolchain is ready for bootstrap automation
# and offer to brew-install anything missing.
#
# Usage:
#   preflight.sh --visibility public|private \
#                --languages "swift javascript python go" \
#                --has-dockerfile true|false \
#                [--assume-yes]
#
# Exits 0 if all required tools are present (or installed during this run).
# Exits non-zero if a required tool is missing and could not be installed.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# --- parse args ---------------------------------------------------------------
VISIBILITY=""
LANGUAGES=""
HAS_DOCKERFILE="false"
ASSUME_YES="false"
CLAUDE_APPROVER="false"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--visibility)
		VISIBILITY="$2"
		shift 2
		;;
	--languages)
		LANGUAGES="$2"
		shift 2
		;;
	--has-dockerfile)
		HAS_DOCKERFILE="$2"
		shift 2
		;;
	--assume-yes)
		ASSUME_YES="true"
		shift
		;;
	--claude-approver)
		CLAUDE_APPROVER="$2"
		shift 2
		;;
	*) die "Unknown argument: $1" ;;
	esac
done

[[ "$VISIBILITY" =~ ^(public|private)$ ]] || die "--visibility must be public or private"

# --- preconditions ------------------------------------------------------------
require_macos
require_brew

# --- assemble required formulas ----------------------------------------------
# Always required
required_brews=(
	"gh"            # GitHub CLI — auth, secrets, branch protection, runner token
	"jq"            # JSON parsing in scripts
	"git"           # already there on macOS, but pin it
	"pre-commit"    # hook framework
	"gitleaks"      # secret scanning
	"semgrep"       # cross-language SAST
	"sonar-scanner" # Sonar CLI
)

# Path-specific
case "$VISIBILITY" in
public)
	required_brews+=("snyk-cli") # provides the `snyk` binary
	;;
private)
	required_brews+=("trivy")
	;;
esac

# Language-specific
for lang in $LANGUAGES; do
	case "$lang" in
	swift) required_brews+=("swiftlint" "swiftformat") ;;
	python) required_brews+=("ruff") ;;
	go) required_brews+=("golangci-lint") ;;
	javascript) : ;; # eslint is per-project via npm
	esac
done

# Casks: Docker is handled separately via check_docker (three-way detection
# between Docker Desktop, CLI-only setups like Colima, and absent), so we
# don't list it here.
required_casks=()

# --- check what's missing -----------------------------------------------------
# A tool counts as "present" if it's on PATH OR installed via brew. This
# avoids false positives when jq/git come from Xcode Command Line Tools or
# pre-commit / semgrep were installed via pip/pipx historically.
info "Checking required tools…"
missing_brews=()
for pkg in "${required_brews[@]}"; do
	# The brew formula name occasionally differs from the binary name. The map
	# below covers the special cases; everything else uses the formula name as
	# the binary name.
	bin="$pkg"
	case "$pkg" in
	snyk-cli) bin="snyk" ;;
	sonar-scanner) bin="sonar-scanner" ;;
	golangci-lint) bin="golangci-lint" ;;
	esac
	if command -v "$bin" >/dev/null 2>&1 || brew list --formula "$pkg" >/dev/null 2>&1; then
		ok "$pkg"
	else
		warn "$pkg — missing"
		missing_brews+=("$pkg")
	fi
done

missing_casks=()
if [[ ${#required_casks[@]} -gt 0 ]]; then
	for pkg in "${required_casks[@]}"; do
		case "$pkg" in
		docker)
			if [[ -d "/Applications/Docker.app" ]] || command -v docker >/dev/null 2>&1; then
				ok "$pkg (cask)"
			else
				warn "$pkg (cask) — missing"
				missing_casks+=("$pkg")
			fi
			;;
		*)
			if brew list --cask "$pkg" >/dev/null 2>&1; then
				ok "$pkg (cask)"
			else
				warn "$pkg (cask) — missing"
				missing_casks+=("$pkg")
			fi
			;;
		esac
	done
fi

# --- offer to install --------------------------------------------------------
if [[ ${#missing_brews[@]} -gt 0 || ${#missing_casks[@]} -gt 0 ]]; then
	echo
	info "The following will be installed via brew:"
	[[ ${#missing_brews[@]} -gt 0 ]] && printf '  • %s\n' "${missing_brews[@]}"
	[[ ${#missing_casks[@]} -gt 0 ]] && printf '  • %s (cask)\n' "${missing_casks[@]}"
	echo

	if [[ "$ASSUME_YES" == "true" ]] || ask_yn "Proceed with install?"; then
		[[ ${#missing_brews[@]} -gt 0 ]] && brew install "${missing_brews[@]}"
		if [[ ${#missing_casks[@]} -gt 0 ]]; then
			for c in "${missing_casks[@]}"; do
				brew install --cask "$c"
			done
		fi
		ok "Installed missing packages"
	else
		die "Required packages not installed. Re-run preflight after installing manually."
	fi
fi

# --- gh authentication --------------------------------------------------------
if gh auth status >/dev/null 2>&1; then
	ok "gh is authenticated"
else
	warn "gh is not authenticated"
	if ask_yn "Run 'gh auth login' now?"; then
		gh auth login
	else
		die "gh authentication required for automation. Run 'gh auth login' and retry."
	fi
fi

# --- docker (private path or any project with a Dockerfile) ------------------
needs_docker="false"
if [[ "$VISIBILITY" == "private" || "$HAS_DOCKERFILE" == "true" ]]; then
	needs_docker="true"
fi

if [[ "$needs_docker" == "true" ]]; then
	echo
	info "Checking Docker…"
	check_docker

	case "$_docker_status" in
	ok)
		ok "Docker is installed ($_docker_kind) and running"
		;;

	not-running)
		case "$_docker_kind" in
		desktop)
			warn "Docker Desktop is installed but the daemon is not running"
			info "Launching Docker.app…"
			open -a Docker
			for i in {1..30}; do
				sleep 2
				docker info >/dev/null 2>&1 && break
				dim "  …waiting for Docker ($((i * 2))s)"
			done
			docker info >/dev/null 2>&1 ||
				die "Docker Desktop did not become ready. Launch it manually, complete first-run setup, and re-run preflight."
			ok "Docker Desktop is running"
			;;
		cli-only)
			die "The docker CLI is on PATH but the daemon isn't running. Start your daemon (e.g. 'colima start' / 'orb start' / 'podman machine start') and re-run preflight."
			;;
		esac
		;;

	missing)
		echo
		info "Docker is required (for SonarQube container ${VISIBILITY:++ }${VISIBILITY:+image scanning}) but not installed."
		cat <<'EOF'

Choose how to install Docker:
  1) Install Docker Desktop via Homebrew  (brew install --cask docker)
     Recommended for most users. Free for personal use; check Docker's
     license if you're at a company with >250 employees or >$10M revenue.

  2) I'll install Docker Desktop manually from docker.com
     Same product, manual .dmg install. Useful if you've already started
     the download or want to inspect the installer.

  3) I'll set up an alternative myself  (Colima, OrbStack, Rancher Desktop,
     Podman, ...). I just need the `docker` CLI on PATH and a running daemon
     when I re-run preflight.

EOF
		[[ -t 0 ]] || die "Docker missing and stdin isn't a TTY — install Docker, then re-run preflight."
		read -r -p "Choose [1/2/3]: " docker_choice
		case "$docker_choice" in
		1)
			if [[ "$ASSUME_YES" == "true" ]] || ask_yn "Install Docker Desktop via brew now?"; then
				brew install --cask docker
				warn "Docker Desktop installed. Launch it once from /Applications, complete first-run setup (license + permissions), then re-run preflight."
				exit 2
			else
				die "Docker install declined."
			fi
			;;
		2)
			info "Download Docker Desktop from https://www.docker.com/products/docker-desktop/"
			info "After installation completes and Docker is running, re-run preflight."
			exit 2
			;;
		3)
			info "Install your preferred Docker setup (e.g. 'brew install colima' + 'colima start')."
			info "When the 'docker' CLI is on PATH and the daemon is running, re-run preflight."
			exit 2
			;;
		*)
			die "Invalid choice: $docker_choice"
			;;
		esac
		;;
	esac

	# --- docker compose plugin ------------------------------------------------
	check_docker_compose
	case "$_compose_status" in
	ok)
		ok "docker compose plugin available"
		;;
	missing)
		warn "docker compose plugin not found"
		case "$_docker_kind" in
		desktop)
			# Should be impossible — Desktop bundles it. Suggest reinstall.
			die "Docker Desktop is installed but 'docker compose version' fails. Reinstall Docker Desktop or update to the latest version."
			;;
		cli-only)
			if [[ "$ASSUME_YES" == "true" ]] || ask_yn "Install the compose plugin via 'brew install docker-compose'?"; then
				brew install docker-compose
				check_docker_compose
				[[ "$_compose_status" == "ok" ]] || die "compose plugin still not available after install. Check brew output."
				ok "docker-compose installed"
			else
				die "docker compose required. Install it and re-run preflight."
			fi
			;;
		esac
		;;
	esac
fi

# --- Claude Apps preflight (when --claude-approver true) ---------------------
# Verifies the two Claude GitHub Apps are registered locally
# (apps.json + Keychain entries). When missing, offers to run
# register-claude-apps.zsh now so bootstrap doesn't fail mid-flow.
if [[ "$CLAUDE_APPROVER" == "true" ]]; then
	echo
	info "Claude Apps preflight (—claude-approver true)…"

	command -v python3 >/dev/null 2>&1 ||
		die "python3 required for the Claude Apps manifest flow. Install via Xcode Command Line Tools (xcode-select --install) or 'brew install python'."

	CLAUDE_APPS_CONFIG="${HOME}/.config/claude-plugins/apps.json"
	apps_ready=true
	for app in claude-approver claude-maintenance; do
		key="${app//-/_}"
		if [[ ! -f "$CLAUDE_APPS_CONFIG" ]] ||
			! jq -e --arg key "$key" '.[$key].app_id' "$CLAUDE_APPS_CONFIG" >/dev/null 2>&1; then
			apps_ready=false
			break
		fi
		if ! security find-generic-password -s "claude-plugins.${app}" -a "private-key" -w >/dev/null 2>&1; then
			apps_ready=false
			break
		fi
	done

	if $apps_ready; then
		ok "Both Claude Apps registered locally (apps.json + Keychain)"
	else
		warn "Claude Apps not yet registered on this machine."
		warn "  Bootstrap will need both Apps before --claude-approver true can install them on the repo."
		if [[ "$ASSUME_YES" == "true" ]] || ask_yn "Run register-claude-apps.zsh now?"; then
			"$SCRIPT_DIR/register-claude-apps.zsh"
		else
			die "Aborted. Run $SCRIPT_DIR/register-claude-apps.zsh, then re-run preflight + bootstrap."
		fi
	fi
fi

echo
ok "Preflight complete — system is ready for automation"
