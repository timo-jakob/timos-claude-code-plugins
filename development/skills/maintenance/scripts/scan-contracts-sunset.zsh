#!/usr/bin/env zsh
# scan-contracts-sunset.zsh — report the per-major sunset state of the per-major
# contracts/ layout (issue #708, epic #684).
#
# A sunset date nobody enforces is a comment. This is the enforcement primitive:
# it reads each live major's spec (contracts/vN/openapi.{yaml,yml,json}) and
# reports whether that MAJOR carries a major-level sunset date and whether that
# date has passed — i.e. the major should already have been retired but is still
# served. The language gathers (gather-java-findings.sh, gather-spring-findings.zsh)
# turn an expired entry into a `sunset-passed` maintenance finding; the advisors
# then recommend the (destructive) retirement path.
#
# MAJOR-level sunset is the root `x-sunset` (or `info.x-sunset`) of the major's
# spec — the whole major is dying. That is distinct from the OPERATION-level
# `x-sunset` the deprecation convention (#695) puts on a single dying operation:
# one operation sunsetting does not retire the major.
#
# Output: a JSON array on stdout, one object per major that declares a sunset —
#   [{"major":"v1","spec":"contracts/v1/openapi.yaml",
#     "sunset":"2026-01-01","expired":true}, ...]
# sorted numerically by major. Majors with no sunset are omitted. A repo with no
# contracts/vN/ layout emits [].
#
# Usage:
#   scan-contracts-sunset.zsh [--repo <dir>] [--today YYYY-MM-DD]
#
#   --today makes the comparison deterministic (tests pin it); it defaults to
#   the real current date.
#
# Exit: 0 always on a well-formed run (an empty array is a valid answer);
#       2 on a usage error; 3 when a required tool (yq/jq) is missing.
emulate -L zsh
setopt err_exit nounset pipefail

repo="."
today=""

while (( $# > 0 )); do
    case "$1" in
    --repo)
        [[ $# -ge 2 ]] || { print -u2 -- "scan-contracts-sunset.zsh: --repo needs a value"; exit 2 }
        repo="$2"; shift 2 ;;
    --today)
        [[ $# -ge 2 ]] || { print -u2 -- "scan-contracts-sunset.zsh: --today needs a value"; exit 2 }
        today="$2"; shift 2 ;;
    -h|--help)
        print -- "usage: scan-contracts-sunset.zsh [--repo <dir>] [--today YYYY-MM-DD]"; exit 0 ;;
    *)
        print -u2 -- "scan-contracts-sunset.zsh: unknown flag: $1"; exit 2 ;;
    esac
done

for tool in yq jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        print -u2 -- "scan-contracts-sunset.zsh: required tool not found: $tool"
        exit 3
    }
done

# The documented sunset boundary is end-of-day UTC, so the "today" we compare
# against must be the UTC date — a local date flips the verdict by up to a day
# either side of the boundary on non-UTC hosts.
[[ -n "$today" ]] || today="$(date -u +%Y-%m-%d)"
[[ "$today" == [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ]] || {
    print -u2 -- "scan-contracts-sunset.zsh: --today must be YYYY-MM-DD (got '$today')"
    exit 2
}
# A missing repo dir is a usage error, not "no sunsets" — an enforcement tool
# must not answer a typo'd path with a clean empty verdict.
[[ -d "$repo" ]] || {
    print -u2 -- "scan-contracts-sunset.zsh: --repo is not a directory: $repo"
    exit 2
}

cd "$repo"
[[ -d contracts ]] || { print -- "[]"; exit 0 }

# Collect "<major>\t<sunset>" for every major that declares a major-level sunset.
typeset -a rows=()
typeset -A seen_major
typeset spec major sunset
while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    major="${spec:h:t}"                       # contracts/v1/openapi.yaml -> v1
    [[ "$major" == v<-> ]] || continue        # canonical vN dirs only
    # One object per major: a dir carrying two spec spellings (openapi.yaml AND
    # openapi.yml) must not yield two entries — the callers key findings on the
    # major, so duplicates would collide on an identical key. First spec wins,
    # deterministically (the input is sorted).
    [[ -n "${seen_major[$major]:-}" ]] && continue
    # Root-level x-sunset first, then info.x-sunset. `// ""` keeps a missing key
    # from becoming the literal "null".
    sunset="$(yq -r '(.["x-sunset"] // .info["x-sunset"]) // ""' "$spec" 2>/dev/null || true)"
    [[ "$sunset" == "null" ]] && sunset=""
    [[ -n "$sunset" ]] || continue
    # Require an ISO-8601 date prefix: that is the lexical compare's
    # precondition, and it keeps a malformed value (a mapping, an embedded tab
    # or newline) from corrupting the tab-packed row below.
    sunset="${sunset%%$'\n'*}"
    [[ "$sunset" == [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]* ]] || continue
    seen_major[$major]=1
    rows+=("${major}	${sunset}	${spec}")
done < <( (find contracts -maxdepth 2 -type f \
    \( -name 'openapi.yaml' -o -name 'openapi.yml' -o -name 'openapi.json' \) 2>/dev/null || true) |
    sort -t v -k2,2n )

(( ${#rows[@]} > 0 )) || { print -- "[]"; exit 0 }

# An ISO-8601 date compares chronologically as a string, so a plain lexical test
# on the first 10 chars handles both a bare date and a full RFC 3339 timestamp.
typeset -a objs=()
typeset m rest sdate spath expired
for row in "${rows[@]}"; do
    m="${row%%	*}"
    rest="${row#*	}"
    sdate="${rest%%	*}"
    spath="${rest#*	}"
    if [[ "${sdate:0:10}" < "$today" ]]; then expired="true"; else expired="false"; fi
    objs+=("$(jq -n --arg major "$m" --arg spec "$spath" --arg sunset "$sdate" \
        --argjson expired "$expired" \
        '{major: $major, spec: $spec, sunset: $sunset, expired: $expired}')")
done

printf '%s\n' "${objs[@]}" | jq -s '.'
