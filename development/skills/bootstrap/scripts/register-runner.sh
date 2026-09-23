#!/usr/bin/env bash
# register-runner.sh — Step 4.5's self-hosted GitHub Actions runner, run iff
# resolve-tools.zsh resolved self_hosted_runner=true:
#   1. Download the latest runner release for this Mac's architecture
#      (skipped when $RUNNER_DIR already holds one)
#   2. Register it against this repository with a short-lived token
#   3. Install and start it as a launchd service
#
# Usage:
#   register-runner.sh            (RUNNER_DIR overrides ~/actions-runner)
#
# Run from the target repo's working dir: the repository is `gh repo view`'s.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

[[ $# -eq 0 ]] || die "Unknown argument: $1"

# Fail fast with a preflight pointer. (`launchctl`, which svc.sh drives, ships
# with macOS.)
require_tools curl gh

RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner}"

echo
info "═══ Self-hosted GitHub Actions runner ═══"

if ! ask_yn "Register a self-hosted runner on this machine now?"; then
	warn "Skipping runner registration — workflows on 'self-hosted' won't run until you do this."
	dim "See infra/github-runner/README.md for manual steps."
	exit 0
fi

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
[[ -n "$REPO" ]] || die "Could not resolve this repository (gh repo view)"

if [[ -d "$RUNNER_DIR" && -f "$RUNNER_DIR/svc.sh" ]]; then
	warn "Runner directory already exists at $RUNNER_DIR — skipping download."
else
	mkdir -p "$RUNNER_DIR"
	ARCH=$(uname -m)
	case "$ARCH" in
	arm64) RUNNER_OS_ARCH="osx-arm64" ;;
	x86_64) RUNNER_OS_ARCH="osx-x64" ;;
	*) die "Unsupported architecture: $ARCH" ;;
	esac
	# Fetch the latest runner version from GitHub releases.
	info "Fetching latest runner release info…"
	RUNNER_VERSION=$(gh api repos/actions/runner/releases/latest --jq .tag_name | sed 's/^v//')
	[[ -n "$RUNNER_VERSION" ]] || die "Could not resolve the latest runner release"
	RUNNER_TARBALL="actions-runner-${RUNNER_OS_ARCH}-${RUNNER_VERSION}.tar.gz"
	info "Downloading runner $RUNNER_VERSION ($RUNNER_OS_ARCH)…"
	curl -fsSL -o "$RUNNER_DIR/$RUNNER_TARBALL" \
		"https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TARBALL}"
	(cd "$RUNNER_DIR" && tar xzf "$RUNNER_TARBALL" && rm "$RUNNER_TARBALL")
	ok "Runner extracted to $RUNNER_DIR"
fi

# Get a registration token (short-lived, single-use).
info "Requesting registration token…"
REG_TOKEN=$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)
[[ -n "$REG_TOKEN" ]] || die "Could not retrieve registration token"

info "Configuring runner…"
(cd "$RUNNER_DIR" && ./config.sh \
	--url "https://github.com/$REPO" \
	--token "$REG_TOKEN" \
	--name "$(hostname -s)-sonarqube" \
	--labels "self-hosted,macOS,sonarqube" \
	--unattended \
	--replace)

info "Installing as a launchd service…"
(cd "$RUNNER_DIR" && ./svc.sh install && ./svc.sh start)
ok "Runner installed and started ($RUNNER_DIR)"
