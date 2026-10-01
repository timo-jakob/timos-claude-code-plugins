#!/usr/bin/env zsh
# round-handoff.zsh — write and read the review loop's round handoff and
# verdict files, validated against round-handoff/v1 and round-verdict/v1
# (#1934, epic #1933).
#
# Epic #1933 moves each review round's heavy work — the panel, the decided
# pass, the fix — into fresh subagents, so the conductor's context never holds
# reviewer output, findings or diffs. The conductor hands a job over as a
# HANDOFF file and reads back a small VERDICT file; this script is the only
# door both go through, so a subagent that writes a malformed verdict is caught
# at the boundary rather than steering the conductor. ARCHITECTURE.md
# (*Round handoff and verdict contracts*) states both contracts; this header
# restates only what the code needs to be read.
#
# Files, both inside the loop's --work-dir, never in the repository:
#   <work-dir>/handoff-<N>-<kind>.json   kind ∈ panel | fix | decide
#   <work-dir>/verdict-<N>-<kind>.json
#
# ONE validator serves the writers and the readers, so nothing a reader would
# refuse can ever be written. It checks, stopping at the first failure:
#   - the schema, kind, mode (panel handoff) and trigger (fix handoff);
#   - key presence: every listed field is a required key, and an "or null"
#     field must be present WITH null — omitting it is a missing field. The one
#     exception is the fix handoff's changelist / gate_log: each is required and
#     non-null under its own trigger, absent or null under the other;
#   - no key the contract does not list for that kind;
#   - types: round an integer >= 1 (and, on read, equal to the file name's N,
#     with the name's kind equal to the object's), counts non-negative
#     integers, rule2_mandatory a bool, carry_entries items with string file,
#     dimension and title, the panel's base a non-empty string, every path
#     field absolute (worktree_root, on every kind, included — #2018);
#   - the conditional rules: carry_entries non-empty exactly in the carry
#     modes; a cause exactly when outcome is not ok; not_applicable on a panel
#     verdict only; the per-kind nullability rules;
#   - containment: every non-null work-dir path field, after :A resolution
#     (`..` and symlinks), lies strictly under the work-dir, and a handoff's own
#     work_dir :A-equals the directory the file sits in. A verdict carries no
#     work_dir, so its work-dir is the one it is written to (--work-dir) or read
#     from (the file's directory).
#
# Pure function of its input and the filesystem: no GitHub, no git.
#
# Exit codes:
#   0 — ok: a writer printed the absolute path it wrote, a reader the object.
#   2 — usage error (unknown subcommand or flag, a dangling flag, a --work-dir
#       that is not a directory).
#   3 — contract rejection, a missing or unreadable --file and invalid writer
#       input included: exactly one `round-handoff:` reason on stderr, nothing
#       written and nothing printed.
#   1 — internal failure (jq missing, the atomic write failed).
#
# Usage:
#   round-handoff.zsh write-handoff --work-dir DIR   < object.json
#   round-handoff.zsh write-verdict --work-dir DIR   < object.json
#   round-handoff.zsh read-handoff  --file FILE
#   round-handoff.zsh read-verdict  --file FILE

emulate -L zsh
set -euo pipefail

usage() {
  print -u2 -r -- "usage: round-handoff.zsh write-handoff|write-verdict --work-dir DIR  < object.json"
  print -u2 -r -- "       round-handoff.zsh read-handoff|read-verdict --file FILE"
  print -u2 -r -- "exit 0 ok, 2 usage, 3 contract rejection, 1 internal."
}
reject() { print -u2 -r -- "round-handoff: $1"; exit 3; }

(( $# >= 1 )) || { usage; exit 2; }
local cmd="$1"; shift
local family="" io=""
case "$cmd" in
  write-handoff) family=handoff io=write ;;
  write-verdict) family=verdict io=write ;;
  read-handoff)  family=handoff io=read ;;
  read-verdict)  family=verdict io=read ;;
  -h|--help) usage; exit 0 ;;
  *) print -u2 -r -- "round-handoff.zsh: unknown subcommand: $cmd"; usage; exit 2 ;;
esac

local work_dir_arg="" file_arg=""
while (( $# > 0 )); do
  case "$1" in
    --work-dir|--file)
      (( $# >= 2 )) && [[ -n "$2" ]] \
        || { print -u2 -r -- "round-handoff.zsh: $1 needs a value"; exit 2; }
      if [[ "$1" == --work-dir ]]; then work_dir_arg="$2"; else file_arg="$2"; fi
      shift 2 ;;
    *) print -u2 -r -- "round-handoff.zsh: unknown arg: $1"; exit 2 ;;
  esac
done
if [[ "$io" == write ]]; then
  [[ -n "$work_dir_arg" && -z "$file_arg" ]] \
    || { print -u2 -r -- "round-handoff.zsh: $cmd takes --work-dir DIR (and no --file)"; exit 2; }
  [[ -d "$work_dir_arg" ]] \
    || { print -u2 -r -- "round-handoff.zsh: --work-dir is not a directory: $work_dir_arg"; exit 2; }
else
  [[ -n "$file_arg" && -z "$work_dir_arg" ]] \
    || { print -u2 -r -- "round-handoff.zsh: $cmd takes --file FILE (and no --work-dir)"; exit 2; }
fi

command -v jq >/dev/null 2>&1 || { print -u2 -r -- "round-handoff.zsh: jq not found on PATH"; exit 1; }

# The validator. Prints ONE object: {"error": "<reason>"} on the first failed
# check, else {"error": null, "work_dir": <the handoff's work_dir or null>,
# "contained": [<non-null work-dir path fields>]}, which the shell then resolves
# with :A. Each check is a generator that emits a reason or nothing, and
# first() stops at the first one — so a later check may rely on the types an
# earlier one established.
local -r VALIDATOR='
def isint: type == "number" and . == floor;
def nonneg: isint and . >= 0;
def abs: type == "string" and startswith("/");
def str: type == "string" and length > 0;
def has_all($ks): . as $o | [$ks[] | select(. as $k | $o | has($k) | not)];

def panel_causes: ["dimension-not-run", "render-failed", "fix-verification-null",
  "fix-verification-unreadable", "carry-unconfirmed", "plan-failed",
  "wrong-worktree-root", "empty-excerpt", "story-diff-empty", "not-applicable",
  "no-agent-tool"];

def handoff_checks:
  (if .schema != "round-handoff/v1" then "unknown schema: \(.schema | tojson)" else empty end),
  (if .kind | IN("panel", "fix", "decide") | not then "unknown kind: \(.kind | tojson)" else empty end),
  (if .kind != "panel" then empty
   elif has("mode") | not then "missing field: mode"
   elif .mode | IN("round", "carry-redispatch", "carry-repair") | not then "unknown mode: \(.mode | tojson)"
   else empty end),
  (if .kind != "fix" then empty
   elif has("trigger") | not then "missing field: trigger"
   elif .trigger | IN("awaiting-fix", "gate-red") | not then "unknown trigger: \(.trigger | tojson)"
   else empty end),
  ( ["schema", "kind", "round", "tree_id", "work_dir", "status_file"] as $common
    | { panel: ["mode", "delta_base", "carried_finding_ids", "carry_entries", "worktree_root", "base"],
        fix: ["trigger", "grant", "guidance", "rule2_mandatory", "profile_fix_rules", "worktree_root"],
        decide: ["aggregate_findings_file", "worktree_root", "retired_file"] }[.kind] as $own
    | ( if .kind == "fix" then (if .trigger == "awaiting-fix" then ["changelist"] else ["gate_log"] end) else [] end ) as $trig
    | ( if .kind == "fix" then ["changelist", "gate_log"] else [] end ) as $optional
    | (has_all($common + $own + $trig) | if length > 0 then "missing field: \(.[0])" else empty end),
      (.kind as $k | ($common + $own + $optional) as $listed | [keys[] | select(IN($listed[]) | not)]
        | if length > 0 then "unlisted key for kind \($k): \(.[0])" else empty end) ),
  (if (.round | isint and . >= 1) | not then "round is not an integer >= 1: \(.round | tojson)" else empty end),
  (if (.tree_id | str) | not then "tree_id is not a non-empty string" else empty end),
  (if (.work_dir | abs) | not then "work_dir is not an absolute path" else empty end),
  (if (.status_file | abs) | not then "status_file is not an absolute path" else empty end),
  # Every kind carries worktree_root (#2018): the tree a subagent works in,
  # never its cwd. It names the story tree, so it is not a work-dir path.
  (if (.worktree_root | abs) | not then "worktree_root is not an absolute path" else empty end),
  ( select(.kind == "panel")
    | (if (.base | str) | not then "base is not a non-empty string" else empty end),
      (if .delta_base != null and (.delta_base | str | not) then "delta_base is not a string or null" else empty end),
      (if (.carried_finding_ids | type == "array" and all(.[]; type == "string")) | not
         then "carried_finding_ids is not an array of strings" else empty end),
      (if (.carry_entries | type == "array") | not then "carry_entries is not an array"
       elif any(.carry_entries[]; (type == "object" and (.file | str) and (.dimension | str) and (.title | str)) | not)
         then "carry_entries item lacks string file, dimension and title"
       elif any(.carry_entries[]; (keys - ["file", "dimension", "title"]) | length > 0)
         then "carry_entries item has an unlisted key"
       else empty end),
      (if .mode == "round" and (.carry_entries | length) > 0 then "carry_entries is non-empty in mode round"
       elif .mode != "round" and (.carry_entries | length) == 0 then "carry_entries is empty in mode \(.mode)"
       else empty end) ),
  ( select(.kind == "fix")
    | (if .grant != null and ((.grant | type == "object" and (keys == ["rounds", "severity_bar"])
            and (.rounds | isint and . >= 1) and (.severity_bar | str)) | not)
         then "grant is not {rounds, severity_bar} or null" else empty end),
      (if .guidance != null and (.guidance | type != "string") then "guidance is not a string or null" else empty end),
      (if (.rule2_mandatory | type) != "boolean" then "rule2_mandatory is not a bool" else empty end),
      (if .profile_fix_rules != null and (.profile_fix_rules | str | not)
         then "profile_fix_rules is not a string or null" else empty end),
      (if .trigger == "awaiting-fix" then
         (if (.changelist | abs) | not then "changelist is not an absolute path (required on awaiting-fix)"
          elif .gate_log != null then "gate_log is set on trigger awaiting-fix" else empty end)
       else
         (if (.gate_log | abs) | not then "gate_log is not an absolute path (required on gate-red)"
          elif .changelist != null then "changelist is set on trigger gate-red" else empty end)
       end) ),
  ( select(.kind == "decide")
    | (if (.aggregate_findings_file | abs) | not then "aggregate_findings_file is not an absolute path" else empty end),
      (if (.retired_file | abs) | not then "retired_file is not an absolute path" else empty end) );

def verdict_checks:
  (if .schema != "round-verdict/v1" then "unknown schema: \(.schema | tojson)" else empty end),
  (if .kind | IN("panel", "fix", "decide") | not then "unknown kind: \(.kind | tojson)" else empty end),
  ( ["schema", "kind", "round", "outcome", "cause"] as $common
    | { panel: ["aggregate_findings_file", "carry_accounting_file", "carry_lines_file", "findings_count"],
        fix: ["fix_applied", "files_changed"],
        decide: ["decided_red", "decided_green", "malformed", "ran_commands_file"] }[.kind] as $own
    | (has_all($common + $own) | if length > 0 then "missing field: \(.[0])" else empty end),
      (.kind as $k | ($common + $own) as $listed | [keys[] | select(IN($listed[]) | not)]
        | if length > 0 then "unlisted key for kind \($k): \(.[0])" else empty end) ),
  (if (.round | isint and . >= 1) | not then "round is not an integer >= 1: \(.round | tojson)" else empty end),
  (if .outcome | IN("ok", "failed", "not_applicable") | not then "unknown outcome: \(.outcome | tojson)"
   elif .outcome == "not_applicable" and .kind != "panel" then "outcome not_applicable on kind \(.kind)"
   else empty end),
  ({ panel: panel_causes, fix: ["cannot-fix"], decide: ["wrong-worktree-root"] }[.kind] as $causes
   | if .outcome == "ok" and .cause != null then "cause is set on outcome ok"
     elif .outcome != "ok" and .cause == null then "cause is missing on outcome \(.outcome)"
     elif .cause != null and (.cause | IN($causes[]) | not)
       then "unknown cause for kind \(.kind): \(.cause | tojson)"
     else empty end),
  ( select(.kind == "panel")
    | (if .outcome == "ok" then
         (if (.aggregate_findings_file | abs) | not then "aggregate_findings_file is not an absolute path on outcome ok"
          elif (.findings_count | nonneg) | not then "findings_count is not a non-negative integer on outcome ok"
          else empty end)
       else
         (if .aggregate_findings_file != null then "aggregate_findings_file is set on outcome \(.outcome)"
          elif .findings_count != null then "findings_count is set on outcome \(.outcome)"
          else empty end)
       end),
      (if .carry_accounting_file != null and (.carry_accounting_file | abs | not)
         then "carry_accounting_file is not an absolute path or null"
       elif .carry_lines_file != null and (.carry_lines_file | abs | not)
         then "carry_lines_file is not an absolute path or null"
       elif (.carry_accounting_file == null) != (.carry_lines_file == null)
         then "carry_lines_file and carry_accounting_file are not null together"
       else empty end) ),
  ( select(.kind == "fix")
    | (if (.fix_applied | type) != "boolean" then "fix_applied is not a bool"
       elif (.files_changed | nonneg) | not then "files_changed is not a non-negative integer"
       elif .outcome != "ok" and (.fix_applied or .files_changed != 0)
         then "a cannot-fix verdict must carry fix_applied false and files_changed 0"
       else empty end) ),
  ( select(.kind == "decide")
    | (if .outcome == "ok" then
         (if ([.decided_red, .decided_green, .malformed] | all(nonneg)) | not
            then "decided_red, decided_green and malformed are not non-negative integers on outcome ok"
          elif (.ran_commands_file | abs) | not then "ran_commands_file is not an absolute path on outcome ok"
          else empty end)
       else
         (if [.decided_red, .decided_green, .malformed, .ran_commands_file] | any(. != null)
            then "decided_red, decided_green, malformed and ran_commands_file are not null on outcome \(.outcome)"
          else empty end)
       end) );

def contained:
  if .schema == "round-handoff/v1" then
    (if .kind == "decide" then [.aggregate_findings_file] else [] end)
  else
    [.aggregate_findings_file, .carry_accounting_file, .carry_lines_file, .ran_commands_file]
  end | map(select(. != null));

if type != "object" then {error: "not a JSON object"}
else
  (first(if $family == "handoff" then handoff_checks else verdict_checks end) // null) as $e
  | if $e != null then {error: $e}
    else {error: null, work_dir: (if $family == "handoff" then .work_dir else null end), contained: contained}
    end
end
'

# The raw input, from stdin (writers) or --file (readers).
local raw="" src_dir=""
if [[ "$io" == write ]]; then
  raw="$(cat)"
  src_dir="${work_dir_arg:A}"
else
  [[ -f "$file_arg" && -r "$file_arg" ]] || reject "file missing or unreadable: $file_arg"
  raw="$(<"$file_arg")"
  src_dir="${file_arg:A:h}"
fi

# -s: a stream of several documents is refused, not validated as its last one.
print -r -- "$raw" | jq -se 'length == 1' >/dev/null 2>&1 \
  || reject "input is not exactly one valid JSON document"

local result
result="$(print -r -- "$raw" | jq -c --arg family "$family" "$VALIDATOR")" \
  || { print -u2 -r -- "round-handoff.zsh: validator failed"; exit 1; }

local err
err="$(print -r -- "$result" | jq -r '.error // empty')"
[[ -z "$err" ]] || reject "$err"

local obj_kind obj_round
obj_kind="$(print -r -- "$raw" | jq -r '.kind')"
obj_round="$(print -r -- "$raw" | jq -r '.round')"
local name="${family}-${obj_round}-${obj_kind}.json"

# On read, the file name must be the one the object would be written under.
if [[ "$io" == read && "${file_arg:t}" != "$name" ]]; then
  reject "file name ${file_arg:t} does not match its round and kind (expected $name)"
fi

# A handoff's own work_dir must be the directory it sits in (or is written to).
local declared_wd
declared_wd="$(print -r -- "$result" | jq -r '.work_dir // empty')"
if [[ -n "$declared_wd" && "${declared_wd:A}" != "$src_dir" ]]; then
  reject "work_dir $declared_wd is not the directory the file is in ($src_dir)"
fi

# Containment: every work-dir path field resolves strictly under the work-dir.
local p
for p in "${(@f)$(print -r -- "$result" | jq -r '.contained[]')}"; do
  [[ -n "$p" ]] || continue
  [[ "${p:A}" == "$src_dir"/?* ]] || reject "path resolves outside the work-dir: $p"
done

if [[ "$io" == read ]]; then
  print -r -- "$raw" | jq -c .
  exit 0
fi

# Atomic write: a temp file in the same directory, then a rename over the target.
local target="$src_dir/$name" tmp
tmp="$(mktemp "$src_dir/.${name}.XXXXXX")" \
  || { print -u2 -r -- "round-handoff.zsh: cannot create a temp file in $src_dir"; exit 1; }
if ! print -r -- "$raw" | jq -c . > "$tmp" || ! mv -f "$tmp" "$target"; then
  rm -f "$tmp"
  print -u2 -r -- "round-handoff.zsh: could not write $target"
  exit 1
fi
print -r -- "$target"
