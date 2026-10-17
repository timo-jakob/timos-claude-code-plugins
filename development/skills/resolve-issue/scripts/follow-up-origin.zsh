#!/usr/bin/env zsh
# follow-up-origin.zsh — the follow-up-origin/v1 record: a machine-readable link
# from a pipeline-filed follow-up issue to its source story, its slice and the
# source story's PR (issue #2581, epic #2582).
#
# Why: the pipeline files some follow-ups itself — split children (#2578) and the
# fix pass's parked findings (reference/review-loop/exit-20-awaiting-fix.md) —
# and they used to link their source, if at all, only in prose. #2588 refines
# each one unattended from its source story's context, which it can only do if
# it can read, by machine, where the follow-up came from and which slice it
# covers. The record lives in ONE comment on the follow-up, never in its body:
# #2588's refinement rewrites the body.
#
# A pure helper: it makes no GitHub calls. The caller posts, finds and edits the
# comment; this script renders, parses and updates its text.
#
# The comment it renders:
#
#   Filed by /development:resolve-issue from #<source>, PR #<pr>.
#   (or: Filed by /development:resolve-issue from #<source>; PR not opened yet.)
#
#   <!-- follow-up-origin/v1 -->
#   ```json
#   { "schema": "follow-up-origin/v1", "kind": ..., "source": {...},
#     "pr": ..., "seam" | "finding": {...} }
#   ```
#
# The record:
#   schema   "follow-up-origin/v1"
#   kind     "split-child" | "parked-finding"
#   source   {"repo": "owner/name", "issue": N}
#   pr       the SOURCE story's PR number, or null
#   seam     split-child only: {"child": i, "of": n, "criteria": ["...", ...]},
#            the source's acceptance criteria assigned to this child, verbatim
#   finding  parked-finding only: {"file", "line", "dimension", "title",
#            "round"}, the identity consolidate-findings uses (line may be null)
# Exactly one of seam and finding is set, matching kind.
#
# Modes:
#   render --kind K --repo R --source N (--seam FILE | --finding FILE) [--pr P]
#       Print the comment body. FILE holds the seam or finding object as JSON.
#   parse
#       Read a comment body on stdin; print its record as one compact JSON line.
#   set-pr --pr P
#       Read an origin comment on stdin; print it with `pr` set to P. When `pr`
#       already equals P the output is the input, byte for byte, so a re-run
#       changes nothing. A different, already-set PR is refused, and so is any
#       split-child record: a split child's source story is split before it is
#       implemented and never gets a PR of its own.
#   parked-issues --progress FILE
#       Print the issue numbers named by FILE's `- parked: <title> -> #<issue>`
#       notes (a work-dir progress.md), one per line, deduplicated, first seen
#       first.
#
# Exit codes: 0 success · 1 no record (parse, set-pr) or no parked note
#             (parked-issues) · 2 invalid input, usage error or refused update

emulate -L zsh
setopt nounset pipefail extendedglob

readonly SCHEMA="follow-up-origin/v1"
readonly MARKER="<!-- follow-up-origin/v1 -->"

_die() { print -u2 -- "follow-up-origin: $1"; exit "${2:-2}" }

# A dangling value flag must not reach `shift 2` (zsh refuses the shift and the
# loop would spin); record-grant.zsh guards its parser the same way.
_need_val() {   # $1 = flag, $2 = remaining argc, $3 = the candidate value
  (( $2 >= 2 )) || _die "$1 requires a value"
  [[ -n "$3" && "$3" != --* ]] || _die "$1 requires a value"
}

_posint() { [[ "$1" == <1-> && "$1" != 0* ]] }

command -v jq >/dev/null 2>&1 || _die "jq is required" 2

# Validate a record (JSON on $1); print a reason and return 1 when it is not one.
# Fails closed: validity is the filter's positive "ok", so an empty input, a jq
# failure or anything else that does not print exactly "ok" is a reason.
_check_record() {
  local out
  [[ -n "${1//[[:space:]]/}" ]] || { print -r -- "the record is empty"; return 1 }
  out="$(jq -er --arg schema "$SCHEMA" '
    def posint: type == "number" and . == floor and . >= 1;
    def str: type == "string" and length > 0;
    if type != "object" then "the record is not a JSON object"
    elif .schema != $schema then "schema is not \($schema)"
    elif (.kind | IN("split-child", "parked-finding")) | not then "kind must be split-child or parked-finding"
    elif (.source | type) != "object" then "source must be an object"
    elif (.source.repo | (type == "string" and test("^[^/ ]+/[^/ ]+$"))) | not then "source.repo must be owner/name"
    elif (.source.issue | posint) | not then "source.issue must be a positive integer"
    elif (.pr == null or (.pr | posint)) | not then "pr must be a positive integer or null"
    elif .kind == "split-child" and has("finding") then "a split-child record carries no finding"
    elif .kind == "parked-finding" and has("seam") then "a parked-finding record carries no seam"
    elif .kind == "split-child" and ((.seam | type) != "object") then "a split-child record needs a seam"
    elif .kind == "parked-finding" and ((.finding | type) != "object") then "a parked-finding record needs a finding"
    elif .kind == "split-child" and ((.seam.child | posint) and (.seam.of | posint) and .seam.child <= .seam.of | not)
      then "seam.child and seam.of must be positive integers with child <= of"
    elif .kind == "split-child" and ((.seam.criteria | type == "array" and length > 0 and all(.[]; str)) | not)
      then "seam.criteria must be a non-empty array of strings"
    elif .kind == "parked-finding" and ((.finding.file | str) and (.finding.dimension | str) and (.finding.title | str) | not)
      then "finding.file, finding.dimension and finding.title must be non-empty strings"
    elif .kind == "parked-finding" and ((.finding.line == null or (.finding.line | posint)) | not)
      then "finding.line must be a positive integer or null"
    elif .kind == "parked-finding" and ((.finding.round | posint) | not) then "finding.round must be a positive integer"
    else "ok" end
  ' <<< "$1" 2>/dev/null)" || out=""
  [[ "$out" == ok ]] && return 0
  print -r -- "${out:-the record is not a single valid JSON value}"
  return 1
}

# Print the comment body for a record (JSON on $1), keys in contract order.
_render_record() {
  local rec="$1" line pretty
  line="$(jq -r '"Filed by /development:resolve-issue from #\(.source.issue)"
    + (if .pr == null then "; PR not opened yet." else ", PR #\(.pr)." end)' <<< "$rec")" || return 1
  pretty="$(jq '{schema, kind, source: {repo: .source.repo, issue: .source.issue}, pr}
    + (if .kind == "split-child"
       then {seam: {child: .seam.child, of: .seam.of, criteria: .seam.criteria}}
       else {finding: {file: .finding.file, line: .finding.line, dimension: .finding.dimension,
                       title: .finding.title, round: .finding.round}} end)' <<< "$rec")" || return 1
  print -r -- "$line"
  print -r -- ""
  print -r -- "$MARKER"
  print -r -- '```json'
  print -r -- "$pretty"
  print -r -- '```'
}

# The record in comment text $1, on stdout. Returns 1 when there is no marker,
# 2 when the marker is there but no valid record follows it.
_extract_record() {
  local body="$1" json reason
  if ! print -r -- "$body" | grep -qxF -- "$MARKER"; then
    return 1
  fi
  # the first ```json fence after the marker, up to its closing fence
  json="$(print -r -- "$body" | awk -v m="$MARKER" '
    !seen && $0 == m { seen = 1; next }
    seen && !open && $0 == "```json" { open = 1; next }
    open && $0 == "```" { done = 1; exit }
    open { print }
    END { if (!done) exit 3 }
  ')" || { print -u2 -- "follow-up-origin: the marker is not followed by a closed json fence"; return 2 }
  jq -e . <<< "$json" >/dev/null 2>&1 || { print -u2 -- "follow-up-origin: the record after the marker is not JSON"; return 2 }
  reason="$(_check_record "$json")"
  [[ -z "$reason" ]] || { print -u2 -- "follow-up-origin: invalid record: $reason"; return 2 }
  jq -c . <<< "$json"
}

# All of stdin, byte for byte, into $REPLY. Never through $(...): a command
# substitution strips trailing newlines, and set-pr promises the input back
# unchanged.
_slurp() {
  local s
  s="$(cat; print -n x)" || return 1
  REPLY="${s%x}"
}

(( $# >= 1 )) || _die "usage: follow-up-origin.zsh render|parse|set-pr|parked-issues ..."
local mode="$1"; shift

case "$mode" in
  render)
    local kind="" repo="" src="" seam_file="" finding_file="" pr=""
    while (( $# )); do
      case "$1" in
        --kind)    _need_val "$1" $# "${2:-}"; kind="$2"; shift 2 ;;
        --repo)    _need_val "$1" $# "${2:-}"; repo="$2"; shift 2 ;;
        --source)  _need_val "$1" $# "${2:-}"; src="$2"; shift 2 ;;
        --seam)    _need_val "$1" $# "${2:-}"; seam_file="$2"; shift 2 ;;
        --finding) _need_val "$1" $# "${2:-}"; finding_file="$2"; shift 2 ;;
        --pr)      _need_val "$1" $# "${2:-}"; pr="$2"; shift 2 ;;
        *) _die "render: unknown argument: $1" ;;
      esac
    done
    [[ -n "$src" ]] || _die "render: --source is required"
    _posint "$src" || _die "render: --source must be a positive issue number (got '$src')"
    [[ -n "$repo" ]] || _die "render: --repo is required"
    [[ "$repo" == [^/\ ]##/[^/\ ]## ]] || _die "render: --repo must be owner/name (got '$repo')"
    [[ -z "$pr" ]] || _posint "$pr" || _die "render: --pr must be a positive PR number (got '$pr')"
    local payload_file="" payload_key=""
    case "$kind" in
      split-child)
        [[ -z "$finding_file" ]] || _die "render: --kind split-child takes --seam, not --finding"
        [[ -n "$seam_file" ]] || _die "render: --kind split-child requires --seam"
        payload_file="$seam_file" payload_key="seam" ;;
      parked-finding)
        [[ -z "$seam_file" ]] || _die "render: --kind parked-finding takes --finding, not --seam"
        [[ -n "$finding_file" ]] || _die "render: --kind parked-finding requires --finding"
        payload_file="$finding_file" payload_key="finding" ;;
      "") _die "render: --kind is required" ;;
      *) _die "render: --kind must be split-child or parked-finding (got '$kind')" ;;
    esac
    [[ -f "$payload_file" && -r "$payload_file" ]] || _die "render: cannot read --$payload_key $payload_file"
    local rec reason
    rec="$(jq -c --arg schema "$SCHEMA" --arg kind "$kind" --arg repo "$repo" \
           --argjson src "$src" --argjson pr "${pr:-null}" --arg key "$payload_key" \
           '{schema: $schema, kind: $kind, source: {repo: $repo, issue: $src}, pr: $pr} + {($key): .}' \
           -- "$payload_file" 2>/dev/null)" || _die "render: --$payload_key $payload_file is not JSON"
    [[ -n "$rec" ]] || _die "render: --$payload_key $payload_file is empty"
    reason="$(_check_record "$rec")"
    [[ -z "$reason" ]] || _die "render: $reason"
    _render_record "$rec" || _die "render: could not render the record" 2
    ;;

  parse)
    (( $# == 0 )) || _die "parse takes no arguments (the comment body is read on stdin)"
    local body rc=0 out
    _slurp || _die "parse: could not read stdin"
    body="$REPLY"
    out="$(_extract_record "$body")" || rc=$?
    case $rc in
      0) print -r -- "$out" ;;
      1) print -u2 -- "follow-up-origin: no $MARKER marker in the comment"; exit 1 ;;
      *) exit 2 ;;
    esac
    ;;

  set-pr)
    local pr=""
    while (( $# )); do
      case "$1" in
        --pr) _need_val "$1" $# "${2:-}"; pr="$2"; shift 2 ;;
        *) _die "set-pr: unknown argument: $1" ;;
      esac
    done
    [[ -n "$pr" ]] || _die "set-pr: --pr is required"
    _posint "$pr" || _die "set-pr: --pr must be a positive PR number (got '$pr')"
    local body rec rc=0 cur kind
    _slurp || _die "set-pr: could not read stdin"
    body="$REPLY"
    rec="$(_extract_record "$body")" || rc=$?
    case $rc in
      0) ;;
      1) print -u2 -- "follow-up-origin: no $MARKER marker in the comment"; exit 1 ;;
      *) exit 2 ;;
    esac
    kind="$(jq -r .kind <<< "$rec")"
    [[ "$kind" != split-child ]] || _die "set-pr: refusing a split-child record — its source story is split before implementation and never gets a PR"
    cur="$(jq -r '.pr // ""' <<< "$rec")"
    if [[ "$cur" == "$pr" ]]; then
      print -rn -- "$body"
      exit 0
    fi
    [[ -z "$cur" ]] || _die "set-pr: the record already names PR #$cur; refusing to replace it with #$pr"
    _render_record "$(jq -c --argjson pr "$pr" '.pr = $pr' <<< "$rec")" || _die "set-pr: could not render the record" 2
    ;;

  parked-issues)
    local progress=""
    while (( $# )); do
      case "$1" in
        --progress) _need_val "$1" $# "${2:-}"; progress="$2"; shift 2 ;;
        *) _die "parked-issues: unknown argument: $1" ;;
      esac
    done
    [[ -n "$progress" ]] || _die "parked-issues: --progress is required"
    [[ -f "$progress" && -r "$progress" ]] || _die "parked-issues: cannot read --progress $progress"
    local out
    out="$(awk '
      /^- parked: .* -> #[0-9]+[[:space:]]*$/ {
        n = $0; sub(/[[:space:]]+$/, "", n); sub(/.* -> #/, "", n)
        if (!(n in seen)) { seen[n] = 1; print n }
      }' < "$progress")" || _die "parked-issues: could not read --progress $progress"
    [[ -n "$out" ]] || { print -u2 -- "follow-up-origin: no '- parked:' note in $progress"; exit 1 }
    print -r -- "$out"
    ;;

  *) _die "unknown mode '$mode' (render | parse | set-pr | parked-issues)" ;;
esac
