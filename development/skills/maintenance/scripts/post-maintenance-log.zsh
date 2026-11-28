#!/usr/bin/env zsh
# Post one scheduled run's maintenance-run/v1 record as a comment on the repo's
# standing Maintenance log issue (#3215), and write the comment's URL back into
# the record. ARCHITECTURE.md, *Maintenance run record (`maintenance-run/v1`)*,
# is the record's contract.
#
# Usage:
#   post-maintenance-log.zsh <record.json>
#
# The issue is the repo's open issue titled exactly `Maintenance log` and
# labelled `maintenance-log`, the lowest-numbered when there are several. With
# none, the label is created when missing and the issue is opened, once; later
# runs find and reuse it. This script never closes the issue.
#
# The comment names the outcome, the run's start, end and duration, the reason
# when there is one, and then every non-empty list of the record — per concern,
# then the bug lists. Empty lists are left out. Every title, note and reason is
# escaped, so a pipe, a backtick or a bracket in it stays literal text.
#
# stdout: the comment's URL.
#
# Exit codes:
#   0  the comment posted and its URL written to the record's log_comment_url
#   1  GitHub unreachable, or any other gh or jq failure: gh or jq missing, the
#      issue not listable or not creatable, the comment not posted, or the
#      record not rewritable after the comment posted (stderr says which). The
#      record is left as it was, log_comment_url `null` included
#   2  usage: not exactly one argument, or a file that is not a
#      maintenance-run/v1 record with a repo

set -uo pipefail

die() { print -u2 "post-maintenance-log.zsh: $1"; exit "${2:-1}"; }

(( $# == 1 )) || { print -u2 "usage: post-maintenance-log.zsh <record.json>"; exit 2; }
record_file="$1"

command -v jq >/dev/null 2>&1 || die "jq not found"
jq -e -s 'length == 1 and (.[0] | type == "object" and .schema == "maintenance-run/v1"
    and (.repo | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")))' "$record_file" >/dev/null 2>&1 ||
  die "$record_file is not a maintenance-run/v1 record" 2
command -v gh >/dev/null 2>&1 || die "gh not found"

repo="$(jq -r .repo "$record_file")"
title="Maintenance log"

issues="$(gh issue list --repo "$repo" --state open --label maintenance-log --limit 100 \
  --json number,title 2>/dev/null)" || die "cannot list $repo's issues (GitHub unreachable?)"
number="$(jq -r --arg t "$title" '[.[]? | select(.title == $t) | .number] | sort | first // empty' \
  <<<"$issues" 2>/dev/null)"

if [[ -z "$number" ]]; then
  gh label create maintenance-log --repo "$repo" --color 0e8a16 \
    --description "The standing log of scheduled maintenance runs" >/dev/null 2>&1 || true
  intro="One comment per scheduled maintenance run. The maintenance pipeline opened this issue and never closes it."
  url="$(gh issue create --repo "$repo" --title "$title" --label maintenance-log --body "$intro" 2>/dev/null)" ||
    die "cannot open the Maintenance log issue in $repo"
  number="${${url//[[:space:]]/}##*/}"
  [[ "$number" == <-> ]] || die "gh issue create printed no issue URL"
fi

body="$(jq -r '
  def md: tostring | gsub("[\r\n]+"; " ") | gsub("(?<c>[\\\\`*_\\[\\]<>|#~])"; "\\\(.c)");
  def entry:
    (if .number == null then "" elif (.url | type == "string" and test("^https://[^\\s()<>]+$"))
       then "[#\(.number)](\(.url)) " else "#\(.number) " end)
    + (.title | md) + (if .note == null or .note == "" then "" else " — " + (.note | md) end);
  def section($label; $items): if ($items | length) == 0 then empty
    else "\($label):\n" + ([$items[] | "- " + entry] | join("\n")) end;
  def duration: ((.ended_at | fromdateiso8601) - (.started_at | fromdateiso8601)) as $s
    | if $s < 0 then "" else " (\($s / 3600 | floor)h \($s % 3600 / 60 | floor)m)" end;
  [["merged", "Merged"], ["opened", "Opened"], ["waiting", "Waiting for a human"],
   ["parked", "Parked"], ["deferred", "Deferred"]] as $cl
  | [["analysed", "Analysed"], ["awaiting_confirmation", "Awaiting confirmation"], ["fixed", "Fixed"],
     ["not_a_bug", "Not a bug"], ["not_eligible", "Not eligible"], ["not_reproducing", "Not reproducing"]] as $bl
  | . as $r
  | [ ($r.concerns | to_entries[] | .key as $k | .value as $v
        | [$cl[] | section(.[1]; $v[.[0]] // [])] | select(length > 0)
        | "#### \($k)\n\n" + join("\n\n")),
      ([$bl[] | section(.[1]; $r.bugs[.[0]] // [])] | select(length > 0) | "#### Bugs\n\n" + join("\n\n")) ] as $parts
  | "**Maintenance run: \(.outcome)**, \(.started_at) to \(.ended_at)\(try duration catch "")\n"
    + (if .reason == null or .reason == "" then "" else "\nReason: \(.reason | md)\n" end)
    + "\n" + (if ($parts | length) == 0 then "Nothing merged, opened, waiting, parked or deferred, and no bug handled."
              else $parts | join("\n\n") end)
' "$record_file")" || die "jq could not render the comment"

comment="$(gh issue comment "$number" --repo "$repo" --body "$body" 2>/dev/null)" ||
  die "cannot comment on $repo#$number (GitHub unreachable?)"
comment_url="$(print -r -- "$comment" | grep -Eo 'https://[^[:space:]]+' | tail -n 1)"
[[ -n "$comment_url" ]] || die "gh issue comment printed no URL"

unwritten="comment posted ($comment_url) but cannot rewrite $record_file"
tmp="$(mktemp "${record_file:h}/.${record_file:t}.XXXXXX" 2>/dev/null)" || die "$unwritten"
trap 'rm -f -- "$tmp"' EXIT
jq --arg u "$comment_url" '.log_comment_url = $u' "$record_file" > "$tmp" && mv -f -- "$tmp" "$record_file" ||
  die "$unwritten"
trap - EXIT
print -r -- "$comment_url"
