#!/usr/bin/env zsh
# pre-dispatch-runtime-upgrade.zsh — language-specific pre-flight for
# `swift-runtime-upgrade` agent runs.
#
# Owned by the development-swift plugin. Invoked by the language-agnostic
# orchestrator (`/development:maintenance` Phase 8) only when a plan entry
# has `agent == "swift-runtime-upgrade"` — so the orchestrator stays free
# of swiftly / Xcode-toolchain knowledge.
#
# Two subcommands:
#
#   detect <to_version>
#     Probe whether a Swift toolchain matching the target version (major or
#     major.minor, e.g. "6" or "6.1") is locally available — the PATH `swift`
#     first, then swiftly-managed toolchains, then /Library/Developer/
#     Toolchains bundles. Prints a JSON line on stdout; exit 0 iff found.
#       found:    {"has_toolchain": true,  "found_at": "<path|swift on PATH>"}
#       missing:  {"has_toolchain": false, "found_at": null}
#
#   install <to_version>
#     Install the target toolchain via swiftly (the official toolchain
#     manager) when present. Exits 0 on success; exits 1 with guidance when
#     swiftly isn't installed (Xcode/toolchain installs need the user).
#     Re-run `detect` afterwards to confirm.
#
# Usage:
#   pre-dispatch-runtime-upgrade.zsh detect  6.1
#   pre-dispatch-runtime-upgrade.zsh install 6.1

set -e

usage() {
  print -- "usage: $0 detect|install <to_version>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
local subcmd="$1"
local to_version="$2"

# A version "matches" when it equals the target or extends it at a dot
# boundary — target 6.1 matches 6.1 and 6.1.2 but not 6.10; target 6
# matches any 6.x.
version_matches() {
  local got="$1" want="$2"
  [[ "$got" == "$want" || "$got" == "$want".* ]]
}

case "$subcmd" in
  detect)
    # NOTE: every loop-used variable is declared here, NOT inside the loops.
    # zsh's `local name` (no assignment) on an already-declared local PRINTS
    # the variable (the #234 leak pattern) — a second loop iteration would
    # pollute the JSON-only stdout contract.
    local has_toolchain="" found_at="" ver="" installed="" v="" tc="" tcv=""

    # 1. PATH `swift` — the common case (Xcode-bundled or swiftly-selected).
    if command -v swift >/dev/null 2>&1; then
      ver="$(swift --version 2>/dev/null | grep -oE 'Swift version [0-9.]+' | grep -oE '[0-9.]+' | head -n1 || true)"
      if [[ -n "$ver" ]] && version_matches "$ver" "$to_version"; then
        has_toolchain="yes"
        found_at="swift on PATH ($ver)"
      fi
    fi

    # 2. swiftly-managed toolchains (~/.swiftly or SWIFTLY_HOME_DIR).
    if [[ -z "$has_toolchain" ]] && command -v swiftly >/dev/null 2>&1; then
      installed="$(swiftly list 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || true)"
      for v in ${(f)installed}; do
        if version_matches "$v" "$to_version"; then
          has_toolchain="yes"
          found_at="swiftly toolchain $v"
          break
        fi
      done
    fi

    # 3. Xcode-style toolchain bundles (org.swift.*).
    if [[ -z "$has_toolchain" ]]; then
      for tc in /Library/Developer/Toolchains/swift-*.xctoolchain(N) \
                "$HOME"/Library/Developer/Toolchains/swift-*.xctoolchain(N); do
        tcv="$(print -- "${tc:t}" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"
        if [[ -n "$tcv" ]] && version_matches "$tcv" "$to_version"; then
          has_toolchain="yes"
          found_at="$tc"
          break
        fi
      done
    fi

    if [[ -n "$has_toolchain" ]]; then
      print -- "{\"has_toolchain\": true, \"found_at\": \"${found_at}\"}"
      exit 0
    fi
    print -- '{"has_toolchain": false, "found_at": null}'
    exit 1
    ;;

  install)
    if command -v swiftly >/dev/null 2>&1; then
      swiftly install "$to_version"
      exit 0
    fi
    print -- "swiftly is not installed — a Swift toolchain install needs the user." >&2
    print -- "Options: install swiftly (https://www.swift.org/install/) and re-run," >&2
    print -- "or update Xcode to a version bundling Swift $to_version." >&2
    exit 1
    ;;

  *)
    usage
    ;;
esac
