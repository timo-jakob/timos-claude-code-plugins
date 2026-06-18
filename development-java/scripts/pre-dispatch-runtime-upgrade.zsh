#!/usr/bin/env zsh
# pre-dispatch-runtime-upgrade.zsh — language-specific pre-flight for
# `java-runtime-upgrade` agent runs.
#
# Owned by the development-java plugin. Invoked by the language-agnostic
# orchestrator (`/development:maintenance` Phase 8) only when a plan entry
# has `agent == "java-runtime-upgrade"` — so the orchestrator stays free
# of /usr/libexec/java_home / SDKMAN / Homebrew knowledge.
#
# Two subcommands:
#
#   detect <to_version>
#     Probe whether a JDK of the target MAJOR version is locally available
#     (macOS java_home → SDKMAN → Homebrew openjdk@N → PATH `java`). Prints
#     a JSON line on stdout; exit 0 iff found.
#       found:    {"has_jdk": true,  "found_at": "<home|cmd>"}
#       missing:  {"has_jdk": false, "found_at": null}
#
#   install <to_version>
#     Install the target JDK via Homebrew (openjdk@<N>). Exits 0 on success.
#     Re-run `detect` afterwards to confirm.
#
# Usage:
#   pre-dispatch-runtime-upgrade.zsh detect  25
#   pre-dispatch-runtime-upgrade.zsh install 25

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
    local has_jdk="" found_at=""

    # macOS: java_home resolves an installed JDK by major version. NOTE its
    # `-v N` is a "best match", not an exact filter — with only JDK 26 present
    # it returns 26 (exit 0) even for `-v 21`. So verify the returned JDK's
    # actual major version equals the target before trusting it.
    if [[ -x /usr/libexec/java_home ]]; then
      local jh jhver
      jh="$(/usr/libexec/java_home -v "$to_version" 2>/dev/null || true)"
      if [[ -n "$jh" && -x "$jh/bin/java" ]]; then
        jhver="$("$jh/bin/java" -version 2>&1 | head -n1 | grep -oE '[0-9]+' | head -n1 || true)"
        if [[ "$jhver" == "$to_version" ]]; then
          has_jdk="yes"
          found_at="$jh"
        fi
      fi
    fi

    # SDKMAN-managed candidates (e.g. ~/.sdkman/candidates/java/25-tem).
    if [[ -z "$has_jdk" && -d "${SDKMAN_DIR:-$HOME/.sdkman}/candidates/java" ]]; then
      local cand
      cand="$(/bin/ls -1 "${SDKMAN_DIR:-$HOME/.sdkman}/candidates/java" 2>/dev/null \
        | grep -E "^${to_version}([.-]|$)" | head -n1 || true)"
      if [[ -n "$cand" && -x "${SDKMAN_DIR:-$HOME/.sdkman}/candidates/java/$cand/bin/java" ]]; then
        has_jdk="yes"
        found_at="${SDKMAN_DIR:-$HOME/.sdkman}/candidates/java/$cand"
      fi
    fi

    # Homebrew openjdk@<N> (Apple Silicon then Intel prefixes).
    if [[ -z "$has_jdk" ]]; then
      local b
      for b in "/opt/homebrew/opt/openjdk@${to_version}" "/usr/local/opt/openjdk@${to_version}"; do
        if [[ -x "$b/bin/java" ]]; then
          has_jdk="yes"
          found_at="$b"
          break
        fi
      done
    fi

    # PATH `java` whose major version matches.
    if [[ -z "$has_jdk" ]] && command -v java >/dev/null 2>&1; then
      local ver
      # `java -version` prints to stderr; first number is the major (9+).
      ver="$(java -version 2>&1 | head -n1 | grep -oE '[0-9]+' | head -n1 || true)"
      if [[ "$ver" == "$to_version" ]]; then
        has_jdk="yes"
        found_at="$(command -v java)"
      fi
    fi

    if [[ -n "$has_jdk" ]]; then
      print -- "{\"has_jdk\":true,\"found_at\":\"${found_at}\"}"
      exit 0
    else
      print -- "{\"has_jdk\":false,\"found_at\":null}"
      exit 1
    fi
    ;;

  install)
    if ! command -v brew >/dev/null 2>&1; then
      print -- "{\"installed\":false,\"reason\":\"brew not on PATH\"}" >&2
      exit 3
    fi
    brew install "openjdk@${to_version}"
    print -- "{\"installed\":true,\"formula\":\"openjdk@${to_version}\"}"
    ;;

  *)
    usage
    ;;
esac
