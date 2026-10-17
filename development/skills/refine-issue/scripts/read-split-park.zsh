#!/usr/bin/env zsh
# read-split-park.zsh — read resolve-issue's size pre-flight park off an issue,
# so /development:refine-issue sees why it was sent the story (#2602, epic #2582).
#
# resolve-issue §2(b) parks a story whose plan stopped the size pre-flight: it
# adds the `needs-split` label and posts a `size pre-flight: SPLIT — <triggers +
# counts>; …` comment, and since #2602 that comment ends with a hidden
# `<!-- size-preflight-inventory/v1: {"files":[…]} -->` marker holding the plan
# inventory that stopped. refine-issue's own size check sees only the story's
# DECLARED inventory, which the readiness gate already passed, so without this
# reader the human is sent to a skill that cannot see the objection.
#
# The decision, in this order:
#   - the `needs-split` LABEL is the switch: without it there is no objection
#     (reason `no-label`), whatever the comments say;
#   - the NEWEST size pre-flight comment is the evidence: the last comment whose
#     body begins `size pre-flight: SPLIT` or `size pre-flight: OVERRIDDEN`.
#       SPLIT       → an objection (reason `split`);
#       OVERRIDDEN  → none, the label looks stale (reason `stale-overridden`);
#       none at all → none, the label looks stale (reason `stale-no-comment`).
#   - the newest SPLIT comment's v1 marker supplies the inventory. A missing
#     marker, a marker of another version, or a payload that is not one JSON
#     object with a `files` array gives `inventory: null` — the fallback.
#     Only a v1 marker whose payload does not parse writes a note on stderr.
#
# Input: `gh issue view <N> --json labels,comments` output, from --file or stdin.
#
# Output: one JSON object on stdout, exit 0:
#   { "objection": true|false,
#     "reason": "split"|"no-label"|"stale-overridden"|"stale-no-comment",
#     "summary": "<the SPLIT line after `size pre-flight: SPLIT — `>"|null,
#     "inventory": { "files": [...], ... }|null }
# `summary` and `inventory` are null unless the reason is `split`.
#
# A pure function of its input: no GitHub calls, no writes.
#
# Exit codes:
#   0 — read; the decision is on stdout.
#   2 — usage error (an unknown or dangling flag, a missing or unreadable
#       --file, no --file with a terminal on stdin). Nothing on stdout.
#   3 — runtime error: input that is not one JSON object with `labels` and
#       `comments` arrays, or jq missing. Nothing on stdout.

emulate -L zsh
setopt nounset pipefail

_die() { print -u2 -- "read-split-park: $1"; exit "${2:-3}" }

local file=""
while (( $# )); do
  case "$1" in
    --file)
      (( $# >= 2 )) && [[ -n "${2:-}" && "${2:-}" != --* ]] || _die "--file requires a value" 2
      file="$2"; shift 2 ;;
    -h|--help) print -u2 -- "usage: read-split-park.zsh [--file <gh-issue-view.json>]  (else stdin)"; exit 0 ;;
    *) _die "unknown argument: $1" 2 ;;
  esac
done
if [[ -n "$file" ]]; then
  [[ -f "$file" && -r "$file" ]] || _die "cannot read --file $file" 2
else
  [[ ! -t 0 ]] || _die "no --file and stdin is a terminal" 2
fi
command -v jq >/dev/null 2>&1 || _die "jq is required"

local input
if [[ -n "$file" ]]; then
  input="$(<"$file")" || _die "cannot read --file $file" 2
else
  input="$(cat)" || _die "cannot read stdin"
fi
print -r -- "$input" | jq -e -s 'length == 1 and (.[0] | type == "object")
    and (.[0].labels | type == "array") and (.[0].comments | type == "array")' >/dev/null 2>&1 \
  || _die "input is not one JSON object with labels and comments arrays (gh issue view --json labels,comments)"

# The decision; the marker payload is returned raw, and parsed below so a bad
# one can be noted on stderr without failing the read. The "p" flag lets `.`
# cross a newline, so a payload that spans lines is still captured.
local decided
decided="$(print -r -- "$input" | jq -c '
  def name: if type == "object" then (.name // "") else tostring end;
  def body: if type == "object" then (.body // "") else tostring end;
  ([.labels[] | name] | index("needs-split") != null) as $labelled
  | ([.comments[] | body
      | select(startswith("size pre-flight: SPLIT") or startswith("size pre-flight: OVERRIDDEN"))]
     | last) as $newest
  | if ($labelled | not) then {objection: false, reason: "no-label", summary: null, raw: null}
    elif $newest == null then {objection: false, reason: "stale-no-comment", summary: null, raw: null}
    elif ($newest | startswith("size pre-flight: OVERRIDDEN")) then
      {objection: false, reason: "stale-overridden", summary: null, raw: null}
    else
      {objection: true, reason: "split",
       summary: ($newest | split("\n")[0] | sub("^size pre-flight: SPLIT( — )?"; "")),
       raw: ([$newest | match("<!-- size-preflight-inventory/v1: (.*?) -->"; "p") | .captures[0].string] | first)}
    end')" || _die "could not read the labels and comments"

local raw inventory="null"
raw="$(jq -r '.raw // empty' <<< "$decided")"
if [[ -n "$raw" ]]; then
  # -s: a payload of two JSON documents is not one object, so it falls back too.
  if jq -e -s 'length == 1 and (.[0] | type == "object" and (.files | type == "array"))' <<< "$raw" >/dev/null 2>&1; then
    inventory="$(jq -c . <<< "$raw")"
  else
    inventory="null"
    print -u2 -- "read-split-park: the SPLIT comment's size-preflight-inventory/v1 marker is not one JSON object with a files array; falling back to its triggers and counts"
  fi
fi
jq -c --argjson inv "$inventory" 'del(.raw) + {inventory: (if .objection then $inv else null end)}' <<< "$decided"
