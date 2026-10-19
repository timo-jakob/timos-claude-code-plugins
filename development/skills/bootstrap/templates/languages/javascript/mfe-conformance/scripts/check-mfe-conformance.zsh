#!/usr/bin/env zsh
# check-mfe-conformance.zsh — verify a built micro-frontend remote conforms to
# mfe-contract/v1, in one command (epic #1122, design §5–§6; issue #1126).
#
# A contract nothing checks drifts. This is the remote's side of the check:
#
#   major     — the remote's declared `@*/mfe-contract` dependency (or
#               devDependency) in --package resolves to exactly one major, and
#               that major equals --shell-major, the major the shell (or, for a
#               widget, the canvas host) implements. No build sees both ranges,
#               so the shell's major is an explicit input, never looked up.
#   evaluate  — the built entry (--entry, normally dist/remote.js) evaluates
#               under node. The contract's entry-module rule — evaluating an
#               entry has no side effect beyond defining its exports — is what
#               makes importing it here safe. An entry that never finishes
#               evaluating (a top-level await that never settles, or a
#               process.exit() call) fails this check, not as a tooling error.
#               --timeout bounds evaluation as well as the served fetch, so an
#               await kept pending by a live handle fails here too, never hangs.
#   exports   — `mount` is a function taking 2 parameters and `unmount` one
#               taking 1. Skipped when the entry throws on evaluation. The
#               arity is Function.length, which a default value or a rest
#               parameter lowers, so an entry must declare `mount(el, ctx)` and
#               `unmount(el)` as plain parameters.
#   manifest  — a widget (src/remote/manifest.ts beside --package, #1125's
#               widget marker) also exports `manifest`, whose contractMajor
#               equals both the declared package major and --shell-major.
#   served    — only with --base-url: GET <base-url>/remote.js answers 200 with
#               a JavaScript content type and a body byte-identical to --entry.
#
# Every failure is reported, not only the first, each as an `::error::` line on
# stderr naming its check. Exit 0 when the remote conforms, 1 when it does not,
# 2 for a usage or tooling error (a missing flag or file, a non-integer
# --shell-major, node, jq or curl not found).
#
# MFE_NODE and MFE_CURL override the node and curl binaries — tests stub curl on
# PATH, the same convention as check-ops-conformance.zsh's OPS_CURL.
#
# Bootstrap installs it at scripts/check-mfe-conformance.zsh and wires it as the
# `mfe-conformance` workflow (SKILL.md §3k.10). Source template:
# development/skills/bootstrap/templates/languages/javascript/mfe-conformance/scripts/check-mfe-conformance.zsh
emulate -L zsh
setopt pipe_fail no_unset extended_glob

NODE="${MFE_NODE:-node}"
CURL="${MFE_CURL:-curl}"
TIMEOUT=10

usage() {
  print -u2 -- "usage: check-mfe-conformance.zsh --entry <dist/remote.js> --package <package.json>"
  print -u2 -- "         --shell-major <n> [--base-url <url>] [--timeout <seconds>]"
  exit 2
}

ENTRY="" PACKAGE="" SHELL_MAJOR="" BASE=""
while (( $# > 0 )); do
  case "$1" in
    --entry|--package|--shell-major|--base-url|--timeout)
      (( $# >= 2 )) || { print -u2 -- "missing value for $1"; usage; }
      case "$1" in
        --entry) ENTRY="$2" ;;
        --package) PACKAGE="$2" ;;
        --shell-major) SHELL_MAJOR="$2" ;;
        --base-url) BASE="$2" ;;
        --timeout) TIMEOUT="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage ;;
    *) print -u2 -- "unexpected argument: $1"; usage ;;
  esac
done

[[ -n "$ENTRY" ]] || { print -u2 -- "missing --entry"; usage; }
[[ -n "$PACKAGE" ]] || { print -u2 -- "missing --package"; usage; }
[[ -n "$SHELL_MAJOR" ]] || { print -u2 -- "missing --shell-major"; usage; }
[[ "$SHELL_MAJOR" =~ ^[0-9]+$ ]] || {
  print -u2 -- "invalid --shell-major: '$SHELL_MAJOR' (want a whole number)"
  usage
}
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || {
  print -u2 -- "invalid --timeout: '$TIMEOUT' (want a whole number of seconds)"
  usage
}
[[ -f "$ENTRY" ]] || { print -u2 -- "::error:: --entry file not found: $ENTRY"; exit 2; }
[[ -f "$PACKAGE" ]] || { print -u2 -- "::error:: --package file not found: $PACKAGE"; exit 2; }
BASE="${BASE%/}"   # tolerate a trailing slash

command -v "$NODE" >/dev/null 2>&1 || { print -u2 -- "::error:: '$NODE' not found on PATH"; exit 2; }
command -v jq >/dev/null 2>&1 || { print -u2 -- "::error:: 'jq' not found on PATH"; exit 2; }
if [[ -n "$BASE" ]]; then
  command -v "$CURL" >/dev/null 2>&1 || { print -u2 -- "::error:: '$CURL' not found on PATH"; exit 2; }
fi
jq -e 'type == "object"' "$PACKAGE" >/dev/null 2>&1 || {
  print -u2 -- "::error:: --package is not a JSON object: $PACKAGE"
  exit 2
}

typeset -a failures
fail() { failures+=("$*"); print -u2 -- "::error:: $*"; }

# The widget marker sits beside the package (#1125): src/remote/manifest.ts.
IS_WIDGET=0
[[ -f "${PACKAGE:h}/src/remote/manifest.ts" ]] && IS_WIDGET=1

# ---- major: the declared @*/mfe-contract range -------------------------------
# A range resolves to one major only in these shapes: an optional ^, ~, = or v,
# then N, N.M or N.M.P where M and P may be x, X or *, then an optional
# prerelease. Anything else — *, >=1, 1 || 2, 1 - 2, a tag, a workspace: or
# file: spec — spans majors or names none, and is non-conforming.
DECLARED_MAJOR=""
check_declared_major() {
  local -a deps
  deps=( ${(f)"$(jq -r '[(.dependencies // {}), (.devDependencies // {})] | add
      | to_entries[] | select(.key | test("^@[^/]+/mfe-contract$")) | "\(.key)\t\(.value)"' "$PACKAGE" 2>/dev/null)"} )
  if (( ${#deps} == 0 )); then
    fail "major: $PACKAGE declares no @*/mfe-contract dependency"
    return
  fi
  if (( ${#deps} > 1 )); then
    local -a names
    local d
    for d in $deps; do names+=("${d%%$'\t'*}"); done
    fail "major: $PACKAGE declares more than one mfe-contract package: ${(j:, :)names}"
    return
  fi
  local name="${deps[1]%%$'\t'*}" range="${deps[1]#*$'\t'}" bare
  bare="${${range##[[:space:]]#}%%[[:space:]]#}"
  bare="${bare#[\^~=v]}"
  if [[ ! "$bare" =~ '^[0-9]+(\.([0-9]+|[xX*])){0,2}(-[0-9A-Za-z.-]+)?$' ]]; then
    fail "major: $name range '$range' does not resolve to exactly one major"
    return
  fi
  DECLARED_MAJOR="${bare%%[^0-9]*}"
  if [[ "$DECLARED_MAJOR" != "$SHELL_MAJOR" ]]; then
    fail "major: the remote declares $name major $DECLARED_MAJOR ('$range'), the shell implements major $SHELL_MAJOR"
  fi
}

# ---- evaluate / exports / manifest: import the entry under node --------------
# The probe prints one JSON line behind the MFE_PROBE sentinel — {error} when
# evaluation throws, otherwise each export's presence, type and arity, plus the
# manifest's contractMajor — and exits once it is written, so an entry's own
# stdout or an open handle it leaves behind never decides the result. An unref'd
# deadline of --timeout seconds (argv[2]) reports {deadline} when the import has
# not settled by then; being unref'd, it leaves the no-handle exit-13 path as is.
PROBE='
import { pathToFileURL } from "node:url";
const report = (r) => process.stdout.write("\nMFE_PROBE " + JSON.stringify(r) + "\n", () => process.exit(0));
const describe = (v) => v === undefined ? { present: false }
  : { present: true, type: typeof v, length: typeof v === "function" ? v.length : null };
const limit = Number(process.argv[2]);
if (limit > 0) setTimeout(() => report({ deadline: limit }), limit * 1000).unref();
let mod;
try {
  mod = await import(pathToFileURL(process.argv[1]).href);
} catch (e) {
  report({ error: String(e && e.message ? e.message : e) });
}
if (mod) {
  const m = mod.manifest;
  report({
    mount: describe(mod.mount),
    unmount: describe(mod.unmount),
    manifest: describe(m),
    contractMajor: m && typeof m === "object" && "contractMajor" in m ? m.contractMajor : null,
  });
}
'

check_entry() {
  local raw out="" err rc
  local -a probed
  raw="$("$NODE" --input-type=module -e "$PROBE" "${ENTRY:A}" "$TIMEOUT" 2>/dev/null)"
  rc=$?
  probed=( ${(M)${(f)raw}:#MFE_PROBE *} )
  (( ${#probed} > 0 )) && out="${probed[-1]#MFE_PROBE }"
  # No result means the entry never finished evaluating — a top-level await that
  # never settles (node exit 13) or a process.exit() — so the remote is at fault.
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$out"; then
    fail "evaluate: $ENTRY did not finish evaluating (node exit $rc)"
    return
  fi
  if [[ -n "$(jq -r '.deadline // empty' <<< "$out")" ]]; then
    fail "evaluate: $ENTRY did not finish evaluating within ${TIMEOUT}s"
    return
  fi
  err="$(jq -r '.error // empty' <<< "$out")"
  if [[ -n "$err" ]]; then
    fail "evaluate: $ENTRY throws on evaluation: $err"
    return
  fi

  local name want present type len
  for name want in mount 2 unmount 1; do
    present="$(jq -r ".${name}.present" <<< "$out")"
    type="$(jq -r ".${name}.type // empty" <<< "$out")"
    len="$(jq -r ".${name}.length // empty" <<< "$out")"
    if [[ "$present" != "true" ]]; then
      fail "exports: $ENTRY has no '$name' export"
    elif [[ "$type" != "function" ]]; then
      fail "exports: '$name' is a $type, not a function"
    elif [[ "$len" != "$want" ]]; then
      fail "arity: '$name' takes $len parameter(s), expected $want"
    fi
  done

  (( IS_WIDGET )) || return 0
  if [[ "$(jq -r '.manifest.present' <<< "$out")" != "true" ]]; then
    fail "manifest: $ENTRY is a widget entry with no 'manifest' export"
    return
  fi
  local cmajor
  cmajor="$(jq -r 'if (.contractMajor | type) == "number" then .contractMajor | tostring else "" end' <<< "$out")"
  if [[ -z "$cmajor" ]]; then
    fail "manifest: manifest.contractMajor is missing or not a number"
  elif [[ "$cmajor" != "$SHELL_MAJOR" || ( -n "$DECLARED_MAJOR" && "$cmajor" != "$DECLARED_MAJOR" ) ]]; then
    fail "manifest: manifest.contractMajor is $cmajor, the package declares major ${DECLARED_MAJOR:-unknown}" \
      "and the host implements major $SHELL_MAJOR"
  fi
}

# ---- served: GET <base-url>/remote.js -------------------------------------------
check_served() {
  local url="$BASE/remote.js" body meta rc code ctype
  body="$(mktemp)"
  meta="$("$CURL" -sS -m "$TIMEOUT" -o "$body" -w '%{http_code}\t%{content_type}' "$url" 2>/dev/null)"
  rc=$?
  if (( rc == 2 || rc == 3 )); then
    rm -f "$body"
    print -u2 -- "::error:: curl could not use the request for '$url' (rc $rc) — check --base-url"
    exit 2
  fi
  if (( rc != 0 )); then
    rm -f "$body"
    fail "served: /remote.js unreachable at $url"
    return
  fi
  code="${meta%%$'\t'*}"
  ctype="${meta#*$'\t'}"
  if [[ "$code" != "200" ]]; then
    fail "served: /remote.js answered HTTP $code, expected 200"
  else
    case "${ctype:l}" in
      text/javascript*|application/javascript*|application/x-javascript*|text/ecmascript*|application/ecmascript*) ;;
      *) fail "served: /remote.js (HTTP $code) has content type '$ctype', expected JavaScript" ;;
    esac
    cmp -s "$body" "$ENTRY" || fail "served: /remote.js (HTTP $code) differs from $ENTRY"
  fi
  rm -f "$body"
}

check_declared_major
check_entry
[[ -n "$BASE" ]] && check_served

if (( ${#failures} > 0 )); then
  print -u2 -- "mfe conformance FAILED: ${#failures} problem(s) in $ENTRY"
  exit 1
fi

print -- "mfe conformance PASSED for $ENTRY (contract major $SHELL_MAJOR)"
print -- "  major     PASS"
print -- "  exports   PASS"
(( IS_WIDGET )) && print -- "  manifest  PASS"
[[ -n "$BASE" ]] && print -- "  served    PASS"
exit 0
