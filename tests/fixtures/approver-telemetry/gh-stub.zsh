#!/usr/bin/env zsh
# gh-stub.zsh — a fake `gh` for the approver-telemetry collector suites (#1231).
# Installed as `gh` on PATH by tests/approver-telemetry.bash. It answers only
# `gh api [--paginate] repos/<o>/<r>/<endpoint>[?query]` from the fixture
# directory $GH_FIXTURES, keyed by endpoint:
#
#   …/pulls?…&page=1           pulls
#   …/pulls?…&page=<N>, N > 1  pulls-p<N> — `[]` when there is no such file
#   …/pulls/<n>/reviews        reviews-<n>
#
#   <key>.status   an HTTP status: print gh's `gh: <reason> (HTTP <code>)` on
#                  stderr and exit 1, as the real gh does.
#   <key>.json     the JSON answer. A string "@ago:<N>d" anywhere in it becomes
#                  the ISO-8601 UTC time N days before now, so a committed
#                  fixture never ages out of the collector's 30-day window.
#   none of these  HTTP 404.
#
# Every invocation's arguments are appended, one line, to $GH_LOG. With
# GH_STUB_LEAK=1 every call also prints, on stderr, the token in GH_TOKEN —
# what a careless collector could echo.

emulate -L zsh
setopt nounset pipefail

print -r -- "$*" >> "${GH_LOG:-/dev/null}"

local target="" a=""
for a in "$@"; do [[ "$a" == repos/* ]] && target="$a"; done
[[ "$1" == api && -n "$target" ]] || { print -ru2 -- "gh-stub: unsupported call: $*"; exit 2 }
local query=""
[[ "$target" == *\?* ]] && query="${target#*\?}"
target="${target%%\?*}"

local key="" page=1
case "$target" in
repos/*/*/pulls)
  [[ "&$query" =~ '&page=([0-9]+)' ]] && page="${match[1]}"
  if (( page == 1 )); then key=pulls; else key="pulls-p$page"; fi ;;
repos/*/*/pulls/*/reviews) key="reviews-${${target%/reviews}##*/}" ;;
esac
[[ -n "$key" ]] || { print -ru2 -- "gh-stub: unknown endpoint: $target"; exit 2 }

[[ "${GH_STUB_LEAK:-}" == 1 ]] && print -ru2 -- "Authorization: token ${GH_TOKEN:-}"

local fx="$GH_FIXTURES"
_http() {  # $1 = status code
  local reason="Error"
  case "$1" in
  404) reason="Not Found" ;; 500) reason="Internal Server Error" ;;
  502) reason="Bad Gateway" ;; 503) reason="Service Unavailable" ;;
  esac
  print -ru2 -- "gh: $reason (HTTP $1)"
  exit 1
}

[[ -f "$fx/$key.status" ]] && _http "$(cat -- "$fx/$key.status")"
if [[ ! -f "$fx/$key.json" ]]; then
  [[ "$key" == pulls-p* ]] && { print -r -- '[]'; exit 0 }
  _http 404
fi
jq -c 'walk(if type == "string" and test("^@ago:[0-9]+d$")
             then (now - ((ltrimstr("@ago:") | rtrimstr("d") | tonumber) * 86400) | floor | todate)
             else . end)' < "$fx/$key.json"
