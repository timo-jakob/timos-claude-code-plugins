#!/usr/bin/env zsh
# pre-dispatch-runtime-upgrade.zsh — language-specific pre-flight for
# `go-runtime-upgrade` agent runs.
#
# Owned by the development-go plugin. Invoked by the language-agnostic
# orchestrator (`/development:maintenance` Phase 8) only when a plan entry
# has `agent == "go-runtime-upgrade"` — so the orchestrator stays free of
# Go-toolchain knowledge.
#
# Go-specific note: unlike Swift (swiftly) or a pinned `FROM golang:` image,
# the Go toolchain is largely self-managing. With `GOTOOLCHAIN=auto` (the
# default) or an `<name>+auto` mode, the `go` command TRANSPARENTLY DOWNLOADS
# the toolchain named by a `go`/`toolchain` directive on first use — so the
# target is effectively available (fetched on demand). The OTHER modes do NOT
# fetch the go.mod-directed toolchain: `path` / `<name>+path` search $PATH only,
# `local` uses just the installed toolchain, and a bare pinned `goX.Y.Z` forces
# exactly that version (a NEWER go.mod directive then fails the build rather than
# fetching — a bare pin only ever downloads its OWN version). So we report
# available iff the installed `go version` already matches OR the mode is
# auto/*+auto.
#
# Two subcommands:
#
#   detect <to_version>
#     Probe whether the target Go version (major.minor, e.g. "1.24") is
#     available — the installed `go version`, OR auto-downloadable because
#     GOTOOLCHAIN != local. Prints a JSON line on stdout; exit 0 iff available.
#       found:    {"has_toolchain": true,  "found_at": "<how>"}
#       missing:  {"has_toolchain": false, "found_at": null}
#
#   install <to_version>
#     With GOTOOLCHAIN auto the toolchain installs itself on first build, so
#     there is nothing to pre-install — exit 0. Under GOTOOLCHAIN=local, a
#     toolchain install needs the user; exit 1 with guidance.
#
# Usage:
#   pre-dispatch-runtime-upgrade.zsh detect  1.24
#   pre-dispatch-runtime-upgrade.zsh install 1.24

set -e

usage() {
  print -- "usage: $0 detect|install <to_version>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
local subcmd="$1"
local to_version="$2"

# A version "matches" when it equals the target or extends it at a dot
# boundary — target 1.24 matches 1.24 and 1.24.2 but not 1.240; target 1
# matches any 1.x.
version_matches() {
  local got="$1" want="$2"
  [[ "$got" == "$want" || "$got" == "$want".* ]]
}

case "$subcmd" in
  detect)
    # Declare every variable up front — a bare `local name` on an
    # already-declared local PRINTS it in zsh (the #234 leak), which would
    # pollute the JSON-only stdout contract.
    local has_toolchain="" found_at="" ver="" toolchain_mode=""

    if command -v go >/dev/null 2>&1; then
      ver="$(go version 2>/dev/null | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 | sed 's/^go//' || true)"
      # GOTOOLCHAIN governs whether `go` may fetch a different toolchain.
      # Only `auto` and `<name>+auto` DOWNLOAD on demand. `path` / `<name>+path`
      # search $PATH only (never download); `local` uses just the installed one;
      # a bare pinned `goX.Y.Z` forces exactly that version (a newer go.mod
      # directive then FAILS the build rather than fetching). So availability is:
      #   installed `go` already matches  → available
      #   mode is auto / *+auto           → available (download on first build)
      #   otherwise                        → NOT available here (skip mode)
      toolchain_mode="$(go env GOTOOLCHAIN 2>/dev/null || true)"

      if [[ -n "$ver" ]] && version_matches "$ver" "$to_version"; then
        has_toolchain="yes"
        found_at="go on PATH ($ver)"
      elif [[ "$toolchain_mode" == "auto" || "$toolchain_mode" == *+auto ]]; then
        has_toolchain="yes"
        found_at="go auto-download (GOTOOLCHAIN=$toolchain_mode)"
      fi
    fi

    if [[ -n "$has_toolchain" ]]; then
      print -- "{\"has_toolchain\": true, \"found_at\": \"${found_at}\"}"
      exit 0
    fi
    print -- '{"has_toolchain": false, "found_at": null}'
    exit 1
    ;;

  install)
    local toolchain_mode=""
    if command -v go >/dev/null 2>&1; then
      toolchain_mode="$(go env GOTOOLCHAIN 2>/dev/null || true)"
      if [[ "$toolchain_mode" == "auto" || "$toolchain_mode" == *+auto ]]; then
        # Nothing to do — under an auto mode the first `go build`/`go test` in
        # the worktree fetches the toolchain the bumped go.mod directive names.
        print -- "GOTOOLCHAIN=$toolchain_mode — Go fetches the target toolchain on first build; nothing to pre-install." >&2
        exit 0
      fi
    fi
    # local / path / a bare pinned goX.Y.Z (or 'go' absent) never auto-download.
    print -- "GOTOOLCHAIN=${toolchain_mode:-<unset>} (or 'go' is absent) — a Go $to_version toolchain install needs the user." >&2
    print -- "Options: install Go $to_version (https://go.dev/dl/) and re-run," >&2
    print -- "or set GOTOOLCHAIN=auto so 'go' downloads it on demand." >&2
    exit 1
    ;;

  *)
    usage
    ;;
esac
