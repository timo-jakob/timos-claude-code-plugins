#!/usr/bin/env zsh
# fail-first.zsh — the falsifying test of a bug fix, run before and after the
# fix, and the evidence that it failed first (#3213).
#
# A confirmed bug carries a bug-spec/v1 block (ARCHITECTURE.md, *Bug spec
# contract*) naming the test that fails on the current code. resolve-issue
# (reference/fail-first.md) writes that test before any fix, records its result
# at the branch base, fixes the bug, records it again and opens a PR only when
# `check` passes. ARCHITECTURE.md (*Fail-first evidence*) states the contract;
# this script is its implementation.
#
# Usage:
#   fail-first.zsh spec [--body-file <file>]
#       Read an issue body (--body-file, else stdin) and print the falsifying
#       test its bug spec names: {"path", "name", "command"}. The command is
#       trusted only when the prose's last line, which bug-spec.zsh render
#       writes, is exactly Falsifying test: `<command>`, and the prose's hash
#       still matches the block: the prose is what a code owner confirmed,
#       while the JSON block sits outside the hash.
#   fail-first.zsh record --phase <before|after> --sha <commit> --out <file>
#       [--log <file>] -- <command…>
#       Run the command from the current directory and append one JSON line,
#       {phase, sha, command, exit, at}, to <file>. `command` is the argv, as
#       an array. The command's stdout and stderr go to --log (appended), else
#       are discarded. Whatever the command exits, this records it and exits 0.
#   fail-first.zsh check --base <sha> <file>
#       Exit 0 when the last `before` record is at --base with a non-zero exit
#       and a later `after` record exits 0 for the same command.
#   fail-first.zsh render <file>
#       Print the PR body's **Bug evidence** section from the last `before`
#       record and the last `after` record after it.
#
# Exit codes:
#   spec    0 printed · 1 the body carries no bug spec (nothing here applies)
#           · 4 a bug spec this run cannot fix from, stderr `fail-first: <reason>`
#           with reason unreadable-spec, spec-prose-edited, not-a-bug,
#           no-falsifying-test or command-not-in-prose
#   record  0 recorded, whatever the command exited
#   check   0 fail-first holds · 1 it does not, stderr `fail-first: <reason>`
#           with reason no-before, before-passed, before-not-at-base, no-after,
#           after-failed or command-differs
#   render  0 printed · 1 no `before` record with a later `after` record
#   all     2 usage · 3 runtime: jq missing, an unreadable or malformed record
#           file, an unwritable --out or --log, the spec reader failing

emulate -L zsh
set -uo pipefail
setopt extendedglob

me="fail-first"
spec_reader="${0:A:h}/../../maintenance/scripts/bug-spec.zsh"
START='<!-- bug-spec:prose:start -->'
END='<!-- bug-spec:end -->'

usage() {
  print -u2 "usage: fail-first.zsh spec [--body-file <file>]"
  print -u2 "       fail-first.zsh record --phase <before|after> --sha <commit> --out <file> [--log <file>] -- <command…>"
  print -u2 "       fail-first.zsh check --base <sha> <file>"
  print -u2 "       fail-first.zsh render <file>"
  exit 2
}

die() { print -u2 -r -- "$me: $2"; exit "$1" }

(( $# >= 1 )) || usage
mode="$1"; shift
[[ "$mode" == (spec|record|check|render) ]] || usage

command -v jq >/dev/null 2>&1 || die 3 "jq not found on PATH"

is_sha() { [[ "$1" == [0-9a-f](#c7,64) ]] }

# The records of <file>, one JSON array; exit 3 on a file that is not JSON
# Lines of record objects.
read_records() {
  [[ -f "$1" && -r "$1" ]] || die 3 "cannot read: $1"
  jq -se '
    if all(type == "object" and (.phase | IN("before", "after")) and (.sha | type == "string")
           and (.command | type == "array" and length > 0 and all(type == "string"))
           and (.exit | type == "number") and (.at | type == "string")) then . else error("bad record") end' \
    -- "$1" 2>/dev/null \
    || die 3 "not a fail-first record file: $1"
}

# The pair `check` and `render` judge: {before, after}, each the record or null.
# `before` is the last before record; `after` the last after record that follows it.
pair() {
  print -r -- "$1" | jq -c '
    (to_entries | map(select(.value.phase == "before")) | last) as $b
    | if $b == null then {before: null, after: null}
      else {before: $b.value,
            after: (to_entries | map(select(.key > $b.key and .value.phase == "after")) | last | .value? // null)}
      end'
}

case "$mode" in
# ---- spec -------------------------------------------------------------------
spec)
  body_file=""
  while (( $# > 0 )); do
    case "$1" in
      --body-file) (( $# >= 2 )) && [[ -n "$2" ]] || usage; body_file="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ -n "$body_file" ]]; then
    [[ -f "$body_file" && -r "$body_file" ]] || die 3 "cannot read: $body_file"
    body="$(cat -- "$body_file")"
  else
    body="$(cat)"
  fi
  [[ -x "$spec_reader" || -r "$spec_reader" ]] || die 3 "the bug-spec reader is missing: $spec_reader"
  spec="$(print -r -- "$body" | zsh "$spec_reader" read 2>/dev/null)"
  case $? in
    0) ;;
    # a spec region ends the body, so a sentinel merely quoted earlier is no spec
    1) [[ "$body" == *"$START"*"$END"[[:space:]]# ]] \
         && die 4 "unreadable-spec (the body holds a bug spec bug-spec.zsh cannot read)"
       exit 1 ;;
    *) die 3 "the bug-spec reader failed" ;;
  esac
  [[ "$(print -r -- "$spec" | jq -r '(.block.provenance.prose_sha256 // "") == .prose_sha256')" == true ]] \
    || die 4 "spec-prose-edited (the prose no longer matches its hash)"
  [[ "$(print -r -- "$spec" | jq -r '.block.verdict')" == bug ]] || die 4 "not-a-bug"
  print -r -- "$spec" | jq -e '.block.falsifying_test | type == "object"
      and (.path | type == "string" and test("\\S")) and (.name | type == "string" and test("\\S"))
      and (.command | type == "string" and test("\\S"))' >/dev/null 2>&1 \
    || die 4 "no-falsifying-test (the spec names no runnable test)"
  cmd="$(print -r -- "$spec" | jq -r '.block.falsifying_test.command')"
  prose="$(print -r -- "$spec" | jq -r '.prose // ""')"
  prose="${prose%%[[:space:]]#}"
  [[ "${prose##*$'\n'}" == "Falsifying test: \`$cmd\`" ]] \
    || die 4 "command-not-in-prose (the test's command is not the one the confirmed prose's last line names)"
  print -r -- "$spec" | jq -c '.block.falsifying_test | {path, name, command}'
  ;;

# ---- record -----------------------------------------------------------------
record)
  phase="" sha="" out="" log=""
  while (( $# > 0 )); do
    case "$1" in
      --phase) (( $# >= 2 )) || usage; phase="$2"; shift 2 ;;
      --sha) (( $# >= 2 )) || usage; sha="$2"; shift 2 ;;
      --out) (( $# >= 2 )) && [[ -n "$2" ]] || usage; out="$2"; shift 2 ;;
      --log) (( $# >= 2 )) && [[ -n "$2" ]] || usage; log="$2"; shift 2 ;;
      --) shift; break ;;
      *) usage ;;
    esac
  done
  [[ "$phase" == (before|after) ]] && is_sha "$sha" && [[ -n "$out" ]] && (( $# >= 1 )) || usage
  { : >> "$out" } 2>/dev/null || die 3 "cannot write: $out"
  if [[ -n "$log" ]]; then
    { : >> "$log" } 2>/dev/null || die 3 "cannot write: $log"
    "$@" >> "$log" 2>&1 < /dev/null
  else
    "$@" > /dev/null 2>&1 < /dev/null
  fi
  rc=$?
  # the argv as a JSON array, NUL-separated so no word is ever read as a jq option
  line="$(print -rN -- "$@" | jq -cRs --arg p "$phase" --arg s "$sha" --argjson e "$rc" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{phase: $p, sha: $s, command: (split("\u0000") | .[:-1]), exit: $e, at: $at}')" \
    || die 3 "could not build the record"
  print -r -- "$line" >> "$out" || die 3 "cannot write: $out"
  ;;

# ---- check ------------------------------------------------------------------
check)
  base="" file=""
  while (( $# > 0 )); do
    case "$1" in
      --base) (( $# >= 2 )) || usage; base="$2"; shift 2 ;;
      -*) usage ;;
      *) [[ -z "$file" ]] || usage; file="$1"; shift ;;
    esac
  done
  is_sha "$base" && [[ -n "$file" ]] || usage
  recs="$(read_records "$file")" || exit 3
  p="$(pair "$recs")" || exit 3
  reason="$(print -r -- "$p" | jq -r --arg base "$base" '
    if .before == null then "no-before"
    elif .before.exit == 0 then "before-passed"
    elif .before.sha != $base then "before-not-at-base"
    elif .after == null then "no-after"
    elif .after.exit != 0 then "after-failed"
    elif .after.command != .before.command then "command-differs"
    else "" end')" || exit 3
  [[ -z "$reason" ]] || die 1 "$reason"
  ;;

# ---- render -----------------------------------------------------------------
render)
  (( $# == 1 )) && [[ "$1" != -* ]] || usage
  recs="$(read_records "$1")" || exit 3
  p="$(pair "$recs")" || exit 3
  [[ "$(print -r -- "$p" | jq -r '.before != null and .after != null')" == true ]] \
    || die 1 "nothing to render: no before record with a later after record"
  print -r -- "$p" | jq -r '
    # a word is shown bare when it needs no quoting, else single-quoted
    def shown: map(if test("^[A-Za-z0-9_./=:,+@%-]+$") then . else @sh end) | join(" ");
    (.before.command | shown) as $cmd
    | ([$cmd | scan("`+") | length] | max // 0) as $run
    | ("`" * ([$run + 1, 3] | max)) as $fence
    | "## Bug evidence",
      "",
      "The falsifying test fails on the code before the fix and passes with it.",
      "",
      "| Phase | Commit | Exit | Recorded at |",
      "| --- | --- | --- | --- |",
      "| before the fix | `\(.before.sha)` | \(.before.exit) | \(.before.at) |",
      "| with the fix | `\(.after.sha)` | \(.after.exit) | \(.after.at) |",
      "",
      "The command, run from the repository root both times:",
      "",
      "\($fence)text",
      $cmd,
      $fence'
  ;;
esac
