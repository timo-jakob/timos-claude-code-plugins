#!/usr/bin/env zsh
# gh-stub.zsh — a fake `gh` for the acceptance-telemetry collector suites
# (#1230). Installed as `gh` on PATH by tests/acceptance-telemetry.bash. It
# answers only `gh api [--paginate] repos/<o>/<r>/<endpoint>[?query]` from the
# fixture directory $GH_FIXTURES, keyed by endpoint:
#
#   …/actions/workflows/acceptance.yml/runs   runs
#   …/actions/runs/<id>/jobs                  jobs-<id>
#   …/actions/runs/<id>/artifacts             artifacts-<id>
#   …/actions/artifacts/<id>/zip              zip-<id>
#   repos/<o>/<r> (the repo itself)           repo — answers 200 unless
#                                             repo.status is present
#
#   <key>.status   an HTTP status: print gh's `gh: <reason> (HTTP <code>)` on
#                  stderr and exit 1, as the real gh does.
#   <key>.json     the JSON answer. A string "@ago:<N>d" anywhere in it becomes
#                  the ISO-8601 UTC time N days before now, so a committed
#                  fixture never ages out of the collector's 30-day window.
#   zip-<id>.junit one file name per line, from $GH_JUNIT_DIR: the zip answer
#                  is an archive of those files. zip-<id>.raw is served verbatim.
#   none of these  HTTP 404.
#
# Every invocation's arguments are appended, one line, to $GH_LOG. With
# GH_STUB_LEAK=1 a zip request also prints, on stderr, the signed download URL
# the real endpoint redirects to and the token in GH_TOKEN — what a careless
# collector could echo.

emulate -L zsh
setopt nounset pipefail

print -r -- "$*" >> "${GH_LOG:-/dev/null}"

local target="" a=""
for a in "$@"; do [[ "$a" == repos/* ]] && target="$a"; done
[[ "$1" == api && -n "$target" ]] || { print -ru2 -- "gh-stub: unsupported call: $*"; exit 2 }
target="${target%%\?*}"

local key=""
case "$target" in
*/actions/workflows/acceptance.yml/runs) key=runs ;;
*/actions/runs/*/jobs) key="jobs-${${target%/jobs}##*/}" ;;
*/actions/runs/*/artifacts) key="artifacts-${${target%/artifacts}##*/}" ;;
*/actions/artifacts/*/zip) key="zip-${${target%/zip}##*/}" ;;
repos/*/*) [[ "${target//[^\/]/}" == // ]] && key=repo ;;
esac
[[ -n "$key" ]] || { print -ru2 -- "gh-stub: unknown endpoint: $target"; exit 2 }

local fx="$GH_FIXTURES"
if [[ "$key" == zip-* && "${GH_STUB_LEAK:-}" == 1 ]]; then
  print -ru2 -- "Location: https://results-receiver.actions.githubusercontent.com/artifact/blob?sig=fakesigfakesig&se=2026-10-14"
  print -ru2 -- "Authorization: token ${GH_TOKEN:-}"
fi

_http() {  # $1 = status code
  local reason="Error"
  case "$1" in
  404) reason="Not Found" ;; 410) reason="Gone" ;; 500) reason="Internal Server Error" ;;
  502) reason="Bad Gateway" ;; 503) reason="Service Unavailable" ;;
  esac
  print -ru2 -- "gh: $reason (HTTP $1)"
  exit 1
}

[[ -f "$fx/$key.status" ]] && _http "$(cat -- "$fx/$key.status")"

# The repo itself answers 200 unless repo.status says otherwise (#2560).
[[ "$key" == repo ]] && { print -r -- '{"full_name":"stub"}'; exit 0 }

if [[ "$key" == zip-* ]]; then
  if [[ -f "$fx/$key.raw" ]]; then cat -- "$fx/$key.raw"; exit 0; fi
  [[ -f "$fx/$key.junit" ]] || _http 404
  local stage="" n=""
  stage=$(mktemp -d) || exit 1
  typeset -a members=()
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    cp -- "$GH_JUNIT_DIR/$n" "$stage/$n" || exit 1
    members+=("$n")
  done < "$fx/$key.junit"
  (cd "$stage" && python3 -I -m zipfile -c archive.zip "${members[@]}") || exit 1
  cat -- "$stage/archive.zip"
  rm -rf -- "$stage"
  exit 0
fi

[[ -f "$fx/$key.json" ]] || _http 404
jq -c 'walk(if type == "string" and test("^@ago:[0-9]+d$")
             then (now - ((ltrimstr("@ago:") | rtrimstr("d") | tonumber) * 86400) | floor | todate)
             else . end)' < "$fx/$key.json"
