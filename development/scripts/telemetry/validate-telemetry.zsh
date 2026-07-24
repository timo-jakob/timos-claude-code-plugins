#!/usr/bin/env zsh
# validate-telemetry.zsh — the `telemetry/v1` contract validator (epic #740,
# child (a) — issue #1003).
#
# A contract nobody checks is a convention, and conventions drift — which is
# exactly how the two pre-contract streams diverged. This validates a JSONL
# stream against the CLOSED envelope: the `schema` literal, exactly the 14
# documented top-level keys, correct types (with `run_id` / `repo` / `pipeline`
# required to be NON-EMPTY strings), the `kind` and `outcome` enums,
# non-negative-integer numerics, and `wall_s` — required on runs, null on
# enrichments.
#
# `payload` is OPEN by design: any keys inside it are accepted. Unknown keys at
# the TOP level are rejected — that boundary is the whole point of the split.
#
# Usage:
#   validate-telemetry.zsh [FILE|-] [--require-records]
#                                        # FILE defaults to - (stdin)
#
#     --require-records  exit 1 when the stream contains NO RECORDS instead of 0
#                        (blank and whitespace-only lines do not count, so a
#                        byte-non-empty file of blanks still fails). Without it
#                        a record-less stream is vacuously valid ("every line is
#                        valid" over zero lines), which is the right answer for
#                        "is this data conformant?" but the WRONG one for "did
#                        my pipeline actually emit?" — a retrofit whose emit
#                        step silently wrote nothing would otherwise pass this
#                        gate green. Callers asserting that emission HAPPENED
#                        should pass this flag.
#
# Output: nothing on success. On a contract violation, one line per VIOLATION on
# stdout — a single record breaking several rules reports several lines:
#   line <N>: <violation>
# The --require-records no-records failure is the exception: it exits 1 with a
# single diagnostic on stderr and no `line <N>:` lines at all.
#
# Exit codes (shared taxonomy with emit-telemetry.zsh, so the same class of
# failure means the same number in both):
#   0  every line valid (and, with --require-records, at least one record)
#   1  contract violation — at least one record breaks the envelope, or the
#      stream was empty under --require-records
#   2  usage — caller error: unknown flag, more than one input, an operand that
#      is a directory, missing, or unreadable
#   3  internal — environment/tool failure: jq missing, or a read failure while
#      streaming (after the pre-flight operand checks passed)

emulate -L zsh
setopt nounset pipefail

# Mirror the emitter: ignore SIGPIPE so `validate … | head -5` cannot kill the
# shell with 141 before the contractual exit code is returned.
trap '' PIPE

local src="-" src_seen="" require_records=""
local usage="usage: validate-telemetry.zsh [FILE|-] [--require-records]"

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h|--help) print -r -- "$usage"; exit 0 ;;
  --require-records) require_records=1; shift ;;
  -) # stdin, spelled explicitly — still only ONE input
    [[ -z "$src_seen" ]] || {
      print -u2 -- "validate-telemetry: only one input may be given
$usage"; exit 2 }
    src="-"; src_seen=1; shift ;;
  -*) print -u2 -- "validate-telemetry: unknown flag: $1"; exit 2 ;;
  *) # A second operand would be SILENTLY IGNORED otherwise — and the natural
     # `validate-telemetry.zsh *.jsonl` glob would then validate only the last
     # file and exit 0 while an earlier one violated the contract.
    [[ -z "$src_seen" ]] || {
      print -u2 -- "validate-telemetry: only one input may be given (got extra: $1)
$usage"; exit 2 }
    src="$1"; src_seen=1; shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || {
  print -u2 -- "validate-telemetry: jq not found on PATH"; exit 3 }

if [[ "$src" != "-" ]]; then
  # A DIRECTORY satisfies -r and would fall through to `cat`, surfacing as an
  # internal read failure rather than the usage error it is. Everything else
  # streamable stays allowed — notably the /dev/fd FIFOs that make
  # `validate-telemetry.zsh <(emit-telemetry.zsh …)` work.
  [[ ! -d "$src" ]] || {
    print -u2 -- "validate-telemetry: is a directory, not a telemetry stream: $src"; exit 2 }
  [[ -e "$src" ]] || {
    print -u2 -- "validate-telemetry: no such file: $src"; exit 2 }
  [[ -r "$src" ]] || {
    print -u2 -- "validate-telemetry: file not readable: $src"; exit 2 }
fi

# One jq program over the whole stream. `--raw-input` keeps malformed lines
# reportable (a `fromjson?` failure is a violation, not a crash). -n makes the
# program run ONCE so `inputs` sees EVERY line — without it jq consumes line 1
# as `.` and `inputs` would silently skip it.
#
# The record count is emitted as a trailing `count:<N>` line so --require-records
# can distinguish "no violations" from "no records" in a single pass.
local raw
raw=$(
  if [[ "$src" == "-" ]]; then cat; else cat -- "$src"; fi \
  | jq -R -r -n '
    # the CLOSED envelope: exactly these 14 keys, no more, no fewer
    def envelope_keys: ["schema","kind","run_id","parent_run_id","ts","repo",
                        "repo_type","pipeline","issue","pr","outcome","wall_s",
                        "tokens","payload"];
    def outcomes: ["success","parked","escalated","failed"];
    def kinds: ["run","enrichment"];

    # Enum membership MUST require a string first. the jq `index` builtin does SUBARRAY
    # search when handed an array, so `["run","enrichment"] | index(["run"])`
    # returns 0 — truthy — and an array-valued `kind` would sail through the
    # enum check. Worse, such a record then fails the `kind == "run"` test in
    # the wall_s rule and takes the laxer enrichment arm, so
    # {"kind":["run"],"wall_s":null} would validate completely clean.
    def in_enum($vals): (type == "string") and (. as $v | $vals | index($v) != null);

    # A record value echoed back into a violation may contain literal newlines,
    # which would split one violation across two physical lines and break the
    # documented "one line per violation" shape for anything counting them.
    def show: tostring | gsub("\n"; "\\n") | gsub("\r"; "\\r");

    # The emitter can only ever produce non-negative integers here, so a float
    # or a negative is drift from some other producer — exactly what this gate
    # exists to catch. A bare `type == "number"` would wave it through.
    def is_count: (type == "number") and (. == floor) and (. >= 0);
    def is_nullable_count: (. == null) or is_count;
    def is_nullable_str: (. == null) or (type == "string");
    def nonempty_str: (type == "string") and (length > 0);

    def check($r):
      [
        (if ($r | type) != "object" then "record is not a JSON object" else empty end),

        (if ($r | type) == "object" then
          ( (envelope_keys - ($r | keys)) as $missing
            | if ($missing | length) > 0
              then "missing envelope key(s): " + ($missing | join(", "))
              else empty end ),
          ( (($r | keys) - envelope_keys) as $unknown
            | if ($unknown | length) > 0
              then "unknown top-level key(s): " + ($unknown | map(show) | join(", "))
                   + " (the envelope is closed; put pipeline detail in payload)"
              else empty end ),

          (if ($r | has("schema")) and ($r.schema != "telemetry/v1")
           then "schema must be \"telemetry/v1\" (got: " + ($r.schema | show) + ")"
           else empty end),

          (if ($r | has("kind")) and (($r.kind | in_enum(kinds)) | not)
           then "kind must be run|enrichment (got: " + ($r.kind | show) + ")"
           else empty end),

          (if ($r | has("outcome")) and (($r.outcome | in_enum(outcomes)) | not)
           then "outcome must be success|parked|escalated|failed (got: "
                + ($r.outcome | show) + ")"
           else empty end),

          (if ($r | has("run_id")) and (($r.run_id | nonempty_str) | not)
           then "run_id must be a non-empty string" else empty end),
          (if ($r | has("repo")) and (($r.repo | nonempty_str) | not)
           then "repo must be a non-empty string" else empty end),
          (if ($r | has("pipeline")) and (($r.pipeline | nonempty_str) | not)
           then "pipeline must be a non-empty string" else empty end),

          (if ($r | has("ts")) and (($r.ts | is_count) | not)
           then "ts must be a non-negative integer (unix seconds)" else empty end),

          (if ($r | has("parent_run_id")) and (($r.parent_run_id | is_nullable_str) | not)
           then "parent_run_id must be a string or null" else empty end),
          (if ($r | has("repo_type")) and (($r.repo_type | is_nullable_str) | not)
           then "repo_type must be a string or null" else empty end),

          (if ($r | has("issue")) and (($r.issue | is_nullable_count) | not)
           then "issue must be a non-negative integer or null" else empty end),
          (if ($r | has("pr")) and (($r.pr | is_nullable_count) | not)
           then "pr must be a non-negative integer or null" else empty end),
          (if ($r | has("tokens")) and (($r.tokens | is_nullable_count) | not)
           then "tokens must be a non-negative integer or null" else empty end),

          # wall_s is a RUN measure: required on runs, and null on enrichments
          # (a non-null enrichment wall_s would double-count run time for any
          # consumer that summed the column without filtering `kind`).
          # Only judge wall_s once `kind` is known-good. NB: no apostrophes in
          # this jq program — it lives inside a single-quoted shell string, so
          # one would terminate it. Otherwise a record with kind "sideways" (or
          # no kind at all) collects a spurious complaint about a kind it never
          # had, on top of the real one.
          (if ($r | has("wall_s")) and ($r.kind | in_enum(kinds)) then
             (if ($r.kind == "run") then
                (if ($r.wall_s | is_count) | not
                 then "wall_s is required on kind \"run\" and must be a non-negative integer"
                 else empty end)
              else
                (if $r.wall_s != null
                 then "wall_s must be null on kind \"enrichment\" (it is a run measure)"
                 else empty end)
              end)
           else empty end),

          (if ($r | has("payload")) and (($r.payload | type) != "object")
           then "payload must be an object" else empty end)
         else empty end)
      ];

    # Blank lines are skipped as CONTENT but still occupy their index in
    # [ inputs ], so `.key + 1` stays the true file line — a trailing newline on
    # an append-only sink is normal and must not read as corruption.
    [ inputs ] as $lines
    | ( [ $lines[] | select(length > 0 and (test("^\\s*$") | not)) ] | length ) as $count
    | ( $lines
        | to_entries[]
        | select(.value | length > 0 and (test("^\\s*$") | not))
        | (.key + 1) as $n
        | .value as $line
        # `fromjson?` yields EMPTY on a malformed line, which would make that
        # line vanish from the report instead of failing it. Collecting into an
        # array turns "no parse" into an observable empty array.
        | ([$line | fromjson?]) as $parsed
        | if ($parsed | length) == 0 then
            "line \($n): not valid JSON"
          else
            (check($parsed[0]) | .[] | "line \($n): \(.)")
          end ),
      "count:\($count)"
  '
) || {
  print -u2 -- "validate-telemetry: failed to read the stream"; exit 3 }

# split the trailing count line off the violations
local count="${raw##*count:}"
local violations="${raw%count:*}"
violations="${violations%$'\n'}"

if [[ -n "$violations" ]]; then
  # best-effort: a closed stdout must not turn the documented exit 1 into 141
  print -r -- "$violations" 2>/dev/null
  exit 1
fi

if [[ -n "$require_records" && "$count" == "0" ]]; then
  print -u2 -- "validate-telemetry: no records in the stream (--require-records)"
  exit 1
fi

exit 0
