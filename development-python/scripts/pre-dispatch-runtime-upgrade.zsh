#!/usr/bin/env zsh
# pre-dispatch-runtime-upgrade.zsh — language-specific pre-flight for
# `python-runtime-upgrade` agent runs.
#
# Owned by the development-python plugin. Invoked by the
# language-agnostic orchestrator (`/development:maintenance` Phase 8)
# only when a plan entry has `agent == "python-runtime-upgrade"` — so
# the orchestrator stays free of Homebrew / uv / interpreter-path
# knowledge.
#
# Two subcommands:
#
#   detect <to_version>
#     Probe whether the target Python interpreter is locally available
#     (PATH → Homebrew prefix → uv-managed). Prints a JSON line on
#     stdout; exit 0 iff found.
#       found:     {"has_py": true,  "found_at": "<path|cmd|uv-managed>"}
#       missing:   {"has_py": false, "found_at": null}
#
#   install <to_version>
#     Install the target interpreter via Homebrew. Exits 0 on success.
#     Re-run `detect` afterwards to confirm.
#
# Usage:
#   pre-dispatch-runtime-upgrade.zsh detect  3.14
#   pre-dispatch-runtime-upgrade.zsh install 3.14

set -e

usage() {
  print -- "usage: $0 detect|install <to_version>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
local subcmd="$1"
local to_version="$2"

case "$subcmd" in
  detect)
    local has_py="" found_at=""
    # PATH first
    if command -v "python${to_version}" >/dev/null 2>&1; then
      has_py="yes"
      found_at="$(command -v "python${to_version}")"
    # Homebrew prefix (Apple Silicon default)
    elif [[ -x "/opt/homebrew/bin/python${to_version}" ]]; then
      has_py="yes"
      found_at="/opt/homebrew/bin/python${to_version}"
    # Homebrew prefix (Intel default)
    elif [[ -x "/usr/local/bin/python${to_version}" ]]; then
      has_py="yes"
      found_at="/usr/local/bin/python${to_version}"
    # uv-managed interpreters
    elif command -v uv >/dev/null 2>&1 && uv python find "${to_version}" >/dev/null 2>&1; then
      has_py="yes"
      found_at="uv-managed"
    fi

    if [[ -n "$has_py" ]]; then
      print -- "{\"has_py\":true,\"found_at\":\"${found_at}\"}"
      exit 0
    else
      print -- "{\"has_py\":false,\"found_at\":null}"
      exit 1
    fi
    ;;

  install)
    if ! command -v brew >/dev/null 2>&1; then
      print -- "{\"installed\":false,\"reason\":\"brew not on PATH\"}" >&2
      exit 3
    fi
    brew install "python@${to_version}"
    print -- "{\"installed\":true,\"formula\":\"python@${to_version}\"}"
    ;;

  *)
    usage
    ;;
esac
