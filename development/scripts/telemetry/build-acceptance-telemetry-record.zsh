#!/usr/bin/env zsh
# build-acceptance-telemetry-record.zsh — build the acceptance `payload` for ONE
# `telemetry/v1` record: one settled `acceptance (<interface>)` check run (epic
# #741, child (e) — issue #1230).
#
# A PAYLOAD builder, per ARCHITECTURE.md's *Per-pipeline telemetry
# instrumentation* conventions: it emits no envelope key (the envelope is
# emit-telemetry.zsh's), and it owns the conclusion → outcome mapping behind
# --print-outcome, so the mapping is tested code. It is PURE: one job JSON and
# the JUnit report files in, the payload out — no clock, no git, no network.
# collect-acceptance-telemetry.zsh is its caller, and the only thing that talks
# to GitHub.
#
# Inputs:
#   --job FILE        the GitHub Actions job object, as `GET
#                     /repos/{o}/{r}/actions/runs/{run}/jobs` returns it — read:
#                     id (the check-run id), name (`acceptance (<interface>)`),
#                     status (must be `completed`), conclusion, head_sha,
#                     started_at, completed_at.
#   --junit FILE      a JUnit XML file of the leg's `acceptance-report-<interface>`
#                     artifact; repeat it for every XML file the artifact holds.
#                     Omitted → the report could not be read: every count,
#                     `harness` and `report_artifact` are null.
#   --artifact-name NAME / --artifact-url URL
#                     the artifact the --junit files came from; required with
#                     --junit, rejected without it. URL must be the API artifact
#                     URL (https://…/actions/artifacts/<id>) — never a signed
#                     download URL, so one carrying a query string is refused.
#
# JUnit is read at the <testsuite> level — total = Σ tests, failed =
# Σ (failures + errors), skipped = Σ skipped (an absent failures / errors /
# skipped attribute is 0), passed = total − failed − skipped — summed over the
# innermost <testsuite> elements only, so a nesting suite's aggregate is never
# counted twice. A report that is not well-formed XML, that has no <testsuite>
# or no <testcase>, or whose `tests` is absent or not an integer could not be
# read: its counts, `harness` and `report_artifact` are null, never guessed.
#
# harness: "skeleton" when every <testcase> is name="spine-skeleton-smoke"
# classname="acceptance.<interface>" (the spine marker, #697/#710); "real" when
# any other testcase is present; null when the report could not be read.
#
# REFUSED (exit 1, nothing on stdout): inconsistent counts — a negative count,
# or passed + failed + skipped != total (failures + errors + skipped above
# tests) — and a job that is not one settled acceptance check run (not
# completed, no conclusion, a name that is not `acceptance (<interface>)`, a
# non-positive id, an empty head_sha, unreadable or reversed timestamps).
#
# Outcome (--print-outcome): success → success; failure, timed_out,
# startup_failure → failed; skipped, cancelled, neutral, action_required, stale
# → parked; any other conclusion → failed (the catch-all). `escalated` is never
# produced.
#
# Usage:
#   build-acceptance-telemetry-record.zsh --job FILE
#     [--junit FILE]... [--artifact-name NAME --artifact-url URL] [--print-outcome]
#
# Exit codes: 0 ok · 2 usage (an unknown/dangling flag, a positional, a missing
# --job, an artifact flag without --junit or the reverse, a URL that is not an
# API artifact URL, an operand that is a directory, missing or unreadable) ·
# 1 refused or internal (a job that breaks a rule, inconsistent counts, an input
# that is not one JSON object, jq or awk missing).

emulate -L zsh
setopt nounset pipefail

local P=build-acceptance-telemetry-record
local usage="usage: build-acceptance-telemetry-record.zsh --job FILE
         [--junit FILE]... [--artifact-name NAME --artifact-url URL] [--print-outcome]
  --job            the GitHub Actions job JSON of one acceptance (<interface>) check run
  --junit          a JUnit XML file of its acceptance-report-<interface> artifact (repeatable)
  --artifact-name  the artifact's name (with --junit)
  --artifact-url   the artifact's API URL, https://…/actions/artifacts/<id> (with --junit)
  --print-outcome  print the envelope outcome instead of the payload"

_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || { print -ru2 -- "$P: $1 requires a value"; exit 2 }
  [[ -n "$3" && "$3" != --* ]] || { print -ru2 -- "$P: $1 requires a non-empty value"; exit 2 }
}

local job_file="" art_name="" art_url="" print_outcome=0
typeset -a junit_files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  --job) _need_val "$1" $# "${2:-}"; job_file="$2"; shift 2 ;;
  --junit) _need_val "$1" $# "${2:-}"; junit_files+=("$2"); shift 2 ;;
  --artifact-name) _need_val "$1" $# "${2:-}"; art_name="$2"; shift 2 ;;
  --artifact-url) _need_val "$1" $# "${2:-}"; art_url="$2"; shift 2 ;;
  --print-outcome) print_outcome=1; shift ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  -*) print -ru2 -- "$P: unknown flag: $1"; exit 2 ;;
  *) print -ru2 -- "$P: unexpected argument: $1"; exit 2 ;;
  esac
done

[[ -n "$job_file" ]] || { print -ru2 -- "$P: --job is required"; print -ru2 -- "$usage"; exit 2 }
if (( ${#junit_files} )); then
  [[ -n "$art_name" && -n "$art_url" ]] || {
    print -ru2 -- "$P: --junit needs --artifact-name and --artifact-url"; exit 2 }
  # The API artifact URL, never the signed download URL its zip endpoint
  # redirects to: that one carries a temporary credential in its query string.
  [[ "$art_url" =~ '^https://[^?#[:space:]]+/actions/artifacts/[0-9]+$' ]] || {
    print -ru2 -- "$P: --artifact-url must be an API artifact URL (https://…/actions/artifacts/<id>)"; exit 2 }
else
  [[ -z "$art_name" && -z "$art_url" ]] || {
    print -ru2 -- "$P: --artifact-name and --artifact-url describe a --junit report; none was given"; exit 2 }
fi

_check_operand() {  # $1 = flag, $2 = path
  [[ ! -d "$2" ]] || { print -ru2 -- "$P: $1 is a directory: $2"; exit 2 }
  [[ -e "$2" ]] || { print -ru2 -- "$P: $1 file does not exist: $2"; exit 2 }
  [[ -r "$2" ]] || { print -ru2 -- "$P: $1 file not readable: $2"; exit 2 }
}
_check_operand --job "$job_file"
local f=""
for f in "${junit_files[@]}"; do _check_operand --junit "$f"; done

command -v jq >/dev/null 2>&1 || { print -ru2 -- "$P: jq not found on PATH"; exit 1 }
command -v awk >/dev/null 2>&1 || { print -ru2 -- "$P: awk not found on PATH"; exit 1 }

local job=""
job="$(<"$job_file")" || { print -ru2 -- "$P: failed to read --job: $job_file"; exit 1 }
print -r -- "$job" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 \
  || { print -ru2 -- "$P: --job must be a single JSON object"; exit 1 }

# --- the job: rules, interface, outcome ---------------------------------------

local jres=""
jres="$(jq -c -n --argjson j "$job" '
  def ts: if type == "string" then (try fromdateiso8601 catch null) else null end;
  ($j.name | if type == "string" then (capture("^acceptance \\((?<i>.+)\\)$").i // null) else null end) as $iface
  | ($j.started_at | ts) as $s
  | ($j.completed_at | ts) as $e
  | [ (select(($j.id | type == "number" and . == floor and . >= 1) | not)
        | "id must be a positive integer (the check-run id)"),
      (select($iface == null) | "name must be \"acceptance (<interface>)\""),
      (select($j.status != "completed") | "status must be \"completed\" (the check run has not settled)"),
      (select(($j.conclusion | type == "string" and length > 0) | not)
        | "conclusion must be a non-empty string"),
      (select(($j.head_sha | type == "string" and length > 0) | not)
        | "head_sha must be a non-empty string"),
      (select($s == null) | "started_at must be an ISO-8601 UTC timestamp"),
      (select($e == null) | "completed_at must be an ISO-8601 UTC timestamp"),
      (select($s != null and $e != null and $e < $s) | "completed_at is before started_at")
    ] as $errs
  | if ($errs | length) > 0 then {errors: $errs} else
      {interface: $iface, conclusion: $j.conclusion, check_run_id: $j.id, head_sha: $j.head_sha,
       outcome: (if $j.conclusion == "success" then "success"
                 elif ($j.conclusion | IN("failure", "timed_out", "startup_failure")) then "failed"
                 elif ($j.conclusion | IN("skipped", "cancelled", "neutral", "action_required", "stale")) then "parked"
                 else "failed" end)}
    end
')" || { print -ru2 -- "$P: failed to evaluate the job"; exit 1 }

if [[ "$(print -r -- "$jres" | jq -r 'has("errors")')" == "true" ]]; then
  print -r -- "$jres" | jq -r --arg p "$P" '.errors[] | "\($p): job refused — \(.)"' >&2
  exit 1
fi

local iface=""
iface="$(print -r -- "$jres" | jq -r '.interface')"

# --- the JUnit report ---------------------------------------------------------
# A well-formedness check plus attribute reader in POSIX awk (BSD awk, mawk and
# gawk alike), so no XML tool is a dependency. The document is split on "<" —
# in well-formed XML a "<" only ever opens markup, or sits inside a comment,
# CDATA section or processing instruction, which are re-joined until their
# terminator. Tags are closed by the first ">" outside a quoted attribute value,
# and the element stack must balance to exactly one root. Output: one
# `S<TAB>tests<TAB>failures<TAB>errors<TAB>skipped` line per innermost
# <testsuite> (an absent attribute prints empty), one `C<TAB>name<TAB>classname`
# line per <testcase>, or `BAD<TAB>reason` and status 1.
local junit_awk='
function bad(r) { print "BAD\t" r; exit 1 }
function ws(x) { return x !~ /[^ \t\r\n]/ }
function text(x) { if (depth == 0 && !ws(x)) bad("text outside the root element") }
function dec(x) {
  gsub(/&lt;/, "<", x); gsub(/&gt;/, ">", x); gsub(/&quot;/, "\"", x)
  gsub(/&apos;/, q, x); gsub(/&amp;/, "\\&", x); gsub(/[\t\r\n]/, " ", x)
  return x
}
function attrs(t,   rest, m, k, v) {
  split("", A)
  rest = t
  while (match(rest, ARE)) {
    m = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    k = m; sub(/^[ \t\r\n]+/, "", k); sub(/[ \t\r\n]*=.*$/, "", k)
    v = m; sub(/^[^=]*=[ \t\r\n]*/, "", v); v = substr(v, 2, length(v) - 2)
    A[k] = dec(v)
  }
}
function tag_end(p,   i, n, c, qq) {
  n = length(p); qq = ""
  for (i = 1; i <= n; i++) {
    c = substr(p, i, 1)
    if (qq != "") { if (c == qq) qq = ""; continue }
    if (c == "\"" || c == q) { qq = c; continue }
    if (c == ">") return i
  }
  return 0
}
function join_until(term, label,   j) {
  while (index(p, term) == 0) { i++; if (i > n) bad("unterminated " label); p = p "<" P[i] }
  j = index(p, term)
  text(substr(p, j + length(term)))
}
function open_el(name, t) {
  attrs(t)
  if (name == "testsuite") {
    if (sd > 0) child[sd] = 1
    sd++; child[sd] = 0; suites++
    st[sd] = A["tests"]; sf[sd] = A["failures"]; se[sd] = A["errors"]; ss[sd] = A["skipped"]
  } else if (name == "testcase") {
    cases++
    print "C\t" A["name"] "\t" A["classname"]
  }
}
function close_el(name) {
  if (name == "testsuite") {
    if (!child[sd]) print "S\t" st[sd] "\t" sf[sd] "\t" se[sd] "\t" ss[sd]
    sd--
  }
}
# Lines are joined with a space, never "\n": BSD awk split() on a one-character
# separator also splits at every newline, which would cut tags apart.
{ doc = doc $0 " " }
END {
  NAME = "[A-Za-z_:][-A-Za-z0-9_:.]*"
  ARE = "[ \t\r\n]" NAME "[ \t\r\n]*=[ \t\r\n]*(\"[^\"]*\"|" q "[^" q "]*" q ")"
  n = split(doc, P, "<")
  if (substr(P[1], 1, 3) == "\357\273\277") P[1] = substr(P[1], 4)
  depth = 0; root = 0; sd = 0; suites = 0; cases = 0
  text(P[1])
  for (i = 2; i <= n; i++) {
    p = P[i]
    if (substr(p, 1, 3) == "!--") { join_until("-->", "comment"); continue }
    if (substr(p, 1, 8) == "![CDATA[") {
      if (depth == 0) bad("CDATA outside the root element")
      join_until("]]>", "CDATA section"); continue
    }
    if (substr(p, 1, 1) == "?") { join_until("?>", "processing instruction"); continue }
    if (substr(p, 1, 1) == "!") {
      j = index(p, ">"); if (j == 0 || depth > 0) bad("malformed declaration")
      text(substr(p, j + 1)); continue
    }
    j = tag_end(p)
    if (j == 0) bad("unterminated tag")
    t = substr(p, 1, j - 1); rest = substr(p, j + 1)
    if (substr(t, 1, 1) == "/") {
      name = substr(t, 2); sub(/[ \t\r\n]+$/, "", name)
      if (depth == 0 || stack[depth] != name) bad("mismatched closing tag")
      close_el(name); depth--
    } else {
      self = (substr(t, length(t), 1) == "/")
      if (self) t = substr(t, 1, length(t) - 1)
      name = t; sub(/[ \t\r\n].*$/, "", name)
      if (name !~ ("^" NAME "$")) bad("malformed tag")
      if (depth == 0 && root) bad("more than one root element")
      root = 1
      open_el(name, substr(t, length(name) + 1))
      if (self) close_el(name)
      else { depth++; stack[depth] = name }
    }
    text(rest)
  }
  if (depth != 0) bad("unclosed element")
  if (!root) bad("no root element")
  if (suites == 0) bad("no testsuite")
  if (cases == 0) bad("no testcase")
}'

# Each count accumulates over every innermost suite of every file. `readable`
# drops to 0 on the first file the parser rejects or a non-integer count.
local -i readable=$(( ${#junit_files} > 0 )) total=0 failed=0 skipped=0 neg=0
local skeleton=1 parsed="" tag="" a="" b="" c="" d="" v=""
local int_re='^-?[0-9]+$'
for f in "${junit_files[@]}"; do
  (( readable )) || break
  parsed="$(LC_ALL=C awk -v q="'" "$junit_awk" < "$f" 2>/dev/null)" || { readable=0; break }
  # A doubled tab makes tab a plain separator, so an empty field (an absent
  # attribute) keeps its place instead of collapsing into its neighbour.
  while IFS=$'\t\t' read -r tag a b c d; do
    case "$tag" in
    S)
      [[ "$a" =~ $int_re ]] || { readable=0; break }
      for v in "$b" "$c" "$d"; do
        [[ -z "$v" || "$v" =~ $int_re ]] || { readable=0; break 2 }
      done
      [[ -n "$b" ]] || b=0; [[ -n "$c" ]] || c=0; [[ -n "$d" ]] || d=0
      # 18 digits keeps zsh's 64-bit arithmetic exact; a longer count is noise.
      # A negative count is flagged and refused below, so only magnitudes sum.
      for v in "$a" "$b" "$c" "$d"; do
        (( ${#v} <= 18 )) || { readable=0; break 2 }
        [[ "$v" == -* ]] && neg=1
      done
      total+=$(( 10#${a#-} ))
      failed+=$(( 10#${b#-} + 10#${c#-} ))
      skipped+=$(( 10#${d#-} ))
      ;;
    C)
      [[ "$a" == "spine-skeleton-smoke" && "$b" == "acceptance.$iface" ]] || skeleton=0
      ;;
    esac
  done <<< "$parsed"
done

local -i passed=$(( total - failed - skipped ))
if (( readable && neg )); then
  print -ru2 -- "$P: report refused — a <testsuite> carries a negative count"
  exit 1
fi
if (( readable && passed < 0 )); then
  print -ru2 -- "$P: report refused — passed + failed + skipped != total (failures + errors $failed and skipped $skipped exceed tests $total)"
  exit 1
fi

if (( print_outcome )); then
  print -r -- "$jres" | jq -r '.outcome'
  exit 0
fi

local tests_json='{"passed":null,"failed":null,"skipped":null,"total":null}'
local art_json='null' harness_json='null'
if (( readable )); then
  tests_json="{\"passed\":$passed,\"failed\":$failed,\"skipped\":$skipped,\"total\":$total}"
  art_json="$(jq -c -n --arg n "$art_name" --arg u "$art_url" '{name: $n, url: $u}')"
  if (( skeleton )); then harness_json='"skeleton"'; else harness_json='"real"'; fi
fi

jq -c -n --argjson r "$jres" --argjson tests "$tests_json" --argjson art "$art_json" \
  --argjson harness "$harness_json" '
  {interface: $r.interface, conclusion: $r.conclusion, tests: $tests,
   report_artifact: $art, harness: $harness, check_run_id: $r.check_run_id,
   head_sha: $r.head_sha}' || { print -ru2 -- "$P: failed to build the payload"; exit 1 }
