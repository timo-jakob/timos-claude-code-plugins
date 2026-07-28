#!/usr/bin/env bats
#
# Behavioral tests for validate-telemetry.zsh (#1003, epic #740 child (a)): the
# `telemetry/v1` contract validator.
#
# The point of the contract is the CLOSED envelope / OPEN payload split, so the
# tests that matter most are the pair proving the boundary in both directions:
# an unknown key at the top level is a violation, the same key inside `payload`
# is not.
#
# Violations are asserted on their FULL documented text, not a bare field name:
# the generic "missing envelope key(s): X" message also contains the field name,
# so a substring check would pass even when the validator reported the wrong
# violation. Exit codes are asserted exactly — 1 = contract violation,
# 2 = usage, 3 = internal.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh"
  ZSH_BIN="$(command -v zsh)"
  VALID='{"schema":"telemetry/v1","kind":"run","run_id":"review-loop-1720000000-8f3a","parent_run_id":null,"ts":1720000000,"repo":"timo-jakob/widget","repo_type":"python","pipeline":"review-loop","issue":123,"pr":456,"outcome":"success","wall_s":312,"tokens":null,"payload":{"rounds":2}}'
  F="$BATS_TEST_TMPDIR/stream.jsonl"
}


# Mutate the valid record with a jq expression, then validate it.
#
# --require-records is load-bearing, not decoration: without it, a jq filter that
# ERRORS (a typo, a version difference) writes nothing, the validator sees an
# empty stream, and every `status -eq 0` assertion below passes without a record
# ever having been validated. With it, "jq produced nothing" exits 1 loudly.
# The negative assertions are guarded differently — each pins the violation TEXT,
# which an empty-stream failure could never produce.
check() { run bash -c "set -o pipefail; printf '%s\n' '$VALID' | jq -c '$1' | zsh '$S' - --require-records"; }

# ------------------------------------------------------------------ baseline

@test "a contract-valid record passes silently" {
  check '.'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the FIRST line of a stream is actually validated" {
  # Regression guard: with `jq -R` but no `-n`, jq consumes line 1 as `.` and an
  # `inputs`-based program silently skips it — every single-record stream would
  # then pass vacuously, which is the exact opposite of a gate.
  echo "$VALID" | jq -c '.outcome = "nope"' > "$F"
  run zsh "$S" "$F"
  [ "$status" -eq 1 ]
  contains "$output" "line 1"
}

# --------------------------------------------------- closed envelope / open payload

@test "an unknown TOP-LEVEL key is rejected — the envelope is closed" {
  check '.rounds = 3'
  [ "$status" -eq 1 ]
  contains "$output" "unknown top-level key(s): rounds (the envelope is closed; put pipeline detail in payload)"
}

@test "unknown keys INSIDE payload are accepted — the payload is open" {
  check '.payload = {"anything":[1,{"deeply":{"nested":true}}],"a key with spaces":null}'
  [ "$status" -eq 0 ]
}

@test "a missing envelope key is reported by name" {
  check 'del(.tokens)'
  [ "$status" -eq 1 ]
  contains "$output" "missing envelope key(s): tokens"
}

@test "several missing keys are all named in one message" {
  check 'del(.tokens, .pr, .repo_type)'
  [ "$status" -eq 1 ]
  # the joined text in envelope-key order, and genuinely ONE line
  contains "$output" "missing envelope key(s): repo_type, pr, tokens"
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]
}

@test "payload must be an object" {
  check '.payload = []'
  [ "$status" -eq 1 ]
  contains "$output" "payload must be an object"
  check '.payload = "text"'
  [ "$status" -eq 1 ]
  contains "$output" "payload must be an object"
}

# --------------------------------------------------------------------- enums

@test "a wrong schema value is rejected" {
  check '.schema = "telemetry/v0"'
  [ "$status" -eq 1 ]
  contains "$output" 'schema must be "telemetry/v1" (got: telemetry/v0)'
}

@test "an outcome outside the enum is rejected, and every enum value passes" {
  check '.outcome = "merged"'
  [ "$status" -eq 1 ]
  contains "$output" "outcome must be success|parked|escalated|failed (got: merged)"
  for o in success parked escalated failed; do
    check ".outcome = \"$o\""
    [ "$status" -eq 0 ]
  done
}

@test "an unknown kind is rejected; both valid kinds pass" {
  check '.kind = "sideways"'
  [ "$status" -eq 1 ]
  contains "$output" "kind must be run|enrichment (got: sideways)"
  check '.kind = "run"'
  [ "$status" -eq 0 ]
  check '.kind = "enrichment" | .wall_s = null'
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------- wall_s

@test "wall_s is required on a run record" {
  check '.wall_s = null'
  [ "$status" -eq 1 ]
  contains "$output" 'wall_s is required on kind "run" and must be a non-negative integer'
}

@test "wall_s of the wrong type is rejected on a run" {
  check '.wall_s = "312"'
  [ "$status" -eq 1 ]
  contains "$output" 'wall_s is required on kind "run"'
}

@test "the enrichment arm of wall_s accepts ONLY null — it is a run measure" {
  # A non-null enrichment wall_s would double-count run time for any consumer
  # summing the column without filtering `kind`.
  check '.kind = "enrichment" | .wall_s = null'
  [ "$status" -eq 0 ]
  check '.kind = "enrichment" | .wall_s = 12'
  [ "$status" -eq 1 ]
  contains "$output" 'wall_s must be null on kind "enrichment"'
  lacks "$output" 'required on kind "run"'
  check '.kind = "enrichment" | .wall_s = "12"'
  [ "$status" -eq 1 ]
  contains "$output" 'wall_s must be null on kind "enrichment"'
}

# --------------------------------------------------------------------- types

@test "nullable string fields accept null and a string, and reject a number" {
  for f in parent_run_id repo_type; do
    check ".$f = null";    [ "$status" -eq 0 ]
    check ".$f = \"str\""; [ "$status" -eq 0 ]
    check ".$f = 5"
    [ "$status" -eq 1 ]
    contains "$output" "$f must be a string or null"
  done
}

@test "nullable count fields accept null and a count, and reject a string" {
  for f in issue pr tokens; do
    check ".$f = null"; [ "$status" -eq 0 ]
    check ".$f = 7";    [ "$status" -eq 0 ]
    check ".$f = \"7\""
    [ "$status" -eq 1 ]
    contains "$output" "$f must be a non-negative integer or null"
  done
}

@test "counts must be non-negative integers — floats and negatives are drift" {
  # The emitter can only ever produce non-negative integers, so a float or a
  # negative means some other producer drifted. A bare type check would pass it.
  check '.wall_s = -3'
  [ "$status" -eq 1 ]
  contains "$output" 'wall_s is required on kind "run"'
  check '.wall_s = 1.5'
  [ "$status" -eq 1 ]
  contains "$output" 'wall_s is required on kind "run"'
  check '.ts = 1720000000.5'
  [ "$status" -eq 1 ]
  contains "$output" "ts must be a non-negative integer (unix seconds)"
  check '.issue = -1'
  [ "$status" -eq 1 ]
  contains "$output" "issue must be a non-negative integer or null"
  check '.tokens = 2.25'
  [ "$status" -eq 1 ]
  contains "$output" "tokens must be a non-negative integer or null"
}

@test "required string fields must be non-empty AND actually strings" {
  # Both halves of `(type == "string") and (length > 0)` matter. jq's `length`
  # is polymorphic — `5 | length` is 5, `["x"] | length` is 1, both truthy — so
  # dropping the type half would let a numeric or array join key validate clean,
  # the same class of hole as the `index` subsequence one guarded above.
  for f in run_id repo pipeline; do
    check ".$f = \"\""
    [ "$status" -eq 1 ]
    contains "$output" "$f must be a non-empty string"
    check ".$f = 12345"
    [ "$status" -eq 1 ]
    contains "$output" "$f must be a non-empty string"
    check ".$f = [\"x\"]"
    [ "$status" -eq 1 ]
    contains "$output" "$f must be a non-empty string"
    # a boolean must be a VIOLATION (exit 1), not a jq crash (exit 3)
    check ".$f = true"
    [ "$status" -eq 1 ]
    contains "$output" "$f must be a non-empty string"
  done
}

@test "ts must be a number" {
  check '.ts = "1720000000"'
  [ "$status" -eq 1 ]
  contains "$output" "ts must be a non-negative integer (unix seconds)"
}

@test "a non-object record is rejected" {
  run bash -c "echo '[1,2,3]' | zsh '$S' -"
  [ "$status" -eq 1 ]
  contains "$output" "record is not a JSON object"
}

# ------------------------------------------------------- stream-level handling

@test "a malformed line is REPORTED, not silently skipped" {
  printf '%s\nthis is not json\n' "$VALID" > "$F"
  run zsh "$S" "$F"
  [ "$status" -eq 1 ]
  contains "$output" "line 2: not valid JSON"
}

@test "a malformed line does not blind the rest of the stream" {
  { printf '%s\n' "$VALID"; echo 'garbage'
    echo "$VALID" | jq -c '.outcome = "nope"'; } > "$F"
  run zsh "$S" "$F"
  [ "$status" -eq 1 ]
  contains "$output" "line 2: not valid JSON"
  contains "$output" "line 3: outcome must be"
}

@test "the reported line number points at the offending record" {
  { printf '%s\n' "$VALID"; printf '%s\n' "$VALID"
    echo "$VALID" | jq -c '.outcome = "nope"'; } > "$F"
  run zsh "$S" "$F"
  [ "$status" -eq 1 ]
  contains "$output" "line 3"
  lacks "$output" "line 1"
  lacks "$output" "line 2"
}

@test "line numbers stay true across skipped blank lines" {
  # Blank lines are skipped as content but still counted, so a report points at
  # the real file line a human would open the sink to.
  { printf '%s\n' "$VALID"; printf '\n\n'
    echo "$VALID" | jq -c '.outcome = "nope"'; } > "$F"
  run zsh "$S" "$F"
  [ "$status" -eq 1 ]
  contains "$output" "line 4"
  lacks "$output" "line 2"
  lacks "$output" "line 3"
}

@test "a final line without a trailing newline is still validated" {
  printf '%s\n' "$VALID" > "$F"
  echo "$VALID" | jq -c '.outcome = "nope"' | tr -d '\n' >> "$F"
  run zsh "$S" "$F"
  [ "$status" -eq 1 ]
  contains "$output" "line 2"
}

@test "blank lines alone are tolerated — a trailing newline is not corruption" {
  printf '%s\n\n\n' "$VALID" > "$F"
  run zsh "$S" "$F" --require-records
  [ "$status" -eq 0 ]
}

@test "a multi-record stream passes when every line is valid" {
  { printf '%s\n' "$VALID"
    echo "$VALID" | jq -c '.pipeline = "refine-issue" | .outcome = "parked"'
    echo "$VALID" | jq -c '.kind = "enrichment" | .wall_s = null'; } > "$F"
  run zsh "$S" "$F" --require-records
  [ "$status" -eq 0 ]
}

@test "one bad record among many fails the whole stream" {
  { printf '%s\n' "$VALID"
    echo "$VALID" | jq -c 'del(.repo)'
    printf '%s\n' "$VALID"; } > "$F"
  run zsh "$S" "$F"
  [ "$status" -eq 1 ]
  contains "$output" "line 2"
}

# ------------------------------------------------------------- empty streams

@test "an empty stream is vacuously valid" {
  : > "$F"
  run zsh "$S" "$F"
  [ "$status" -eq 0 ]
}

@test "--require-records turns an empty stream into a failure" {
  # "Every line is valid" over zero lines is the right answer for "is this data
  # conformant?" and the wrong one for "did my pipeline emit?" — a retrofit that
  # silently wrote nothing would otherwise pass this gate green.
  : > "$F"
  run zsh "$S" "$F" --require-records
  [ "$status" -eq 1 ]
  contains "$output" "no records in the stream"
}

@test "--require-records is satisfied by a blank-line-only stream having no records" {
  printf '\n\n\n' > "$F"
  run zsh "$S" "$F" --require-records
  [ "$status" -eq 1 ]
}

@test "--require-records passes on a stream that has records" {
  printf '%s\n' "$VALID" > "$F"
  run zsh "$S" "$F" --require-records
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------- invocation

@test "reading from a FILE, an explicit -, and the no-arg default all agree" {
  printf '%s\n' "$VALID" > "$F"
  # --require-records on every arm: "read nothing" must not masquerade as agreement
  run zsh "$S" "$F" --require-records;                     [ "$status" -eq 0 ]
  run bash -c "cat '$F' | zsh '$S' - --require-records";   [ "$status" -eq 0 ]
  # the documented default: no argument at all means stdin
  run bash -c "cat '$F' | zsh '$S' --require-records";     [ "$status" -eq 0 ]
}

@test "the no-arg stdin default reports violations too" {
  echo "$VALID" | jq -c '.outcome = "nope"' > "$F"
  run bash -c "cat '$F' | zsh '$S'"
  [ "$status" -eq 1 ]
  contains "$output" "line 1: outcome must be"
}

@test "a second FILE operand is rejected rather than silently ignored" {
  # `validate-telemetry.zsh *.jsonl` must not validate only the last file and
  # exit 0 while an earlier one violates the contract.
  printf '%s\n' "$VALID" > "$F"
  local bad="$BATS_TEST_TMPDIR/bad.jsonl"
  echo "$VALID" | jq -c '.outcome = "nope"' > "$bad"
  run zsh "$S" "$bad" "$F"
  [ "$status" -eq 2 ]
  contains "$output" "only one input may be given"
}

@test "a directory operand is a usage error, not an internal read failure" {
  run zsh "$S" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  contains "$output" "is a directory"
}

@test "an absent file is a usage error, distinct from a contract violation" {
  run zsh "$S" "$BATS_TEST_TMPDIR/does-not-exist.jsonl"
  [ "$status" -eq 2 ]
  contains "$output" "no such file"
}

@test "an unreadable regular file is a usage error, not an internal one" {
  [ "$(id -u)" -ne 0 ] || skip "chmod proves nothing as root"
  printf '%s\n' "$VALID" > "$F"
  chmod 000 "$F"
  run zsh "$S" "$F"
  [ "$status" -eq 2 ]
  contains "$output" "file not readable"
}

@test "a streamable non-regular file (process substitution) is accepted" {
  # The directory guard must not also block <(…), which is the natural way to
  # pipe an emitter straight into the validator.
  printf '%s\n' "$VALID" > "$F"
  run zsh -c "zsh '$S' <(cat '$F') --require-records"
  [ "$status" -eq 0 ]
  # …and content really flows through the FIFO, not merely past the guard
  run zsh -c "zsh '$S' <(echo '$VALID' | jq -c '.outcome = \"nope\"') --require-records"
  [ "$status" -eq 1 ]
  contains "$output" "line 1: outcome must be"
}

@test "an unknown flag is rejected" {
  run zsh "$S" --bogus
  [ "$status" -eq 2 ]
  contains "$output" "unknown flag: --bogus"
}

@test "--help prints usage and exits 0" {
  run zsh "$S" --help
  [ "$status" -eq 0 ]
  starts_with "$output" "usage:"
  contains "$output" "validate-telemetry.zsh"
}

@test "a missing jq is an internal error, distinct from a violation" {
  printf '%s\n' "$VALID" > "$F"
  run env PATH="$BATS_TEST_TMPDIR/empty-path" "$ZSH_BIN" "$S" "$F"
  [ "$status" -eq 3 ]
  contains "$output" "jq not found on PATH"
}

# ------------------------------------------------- enum type-confusion guard

@test "an ARRAY-valued kind or outcome is rejected, not matched as a subsequence" {
  # jq's index() does SUBARRAY search when handed an array, so
  # ["run","enrichment"] | index(["run"]) == 0 (truthy) and an array-valued kind
  # once sailed through the enum check entirely. Worse, such a record then fails
  # the `kind == "run"` test in the wall_s rule and took the laxer enrichment
  # arm, so {"kind":["run"],"wall_s":null} validated completely clean.
  check '.kind = ["run"] | .wall_s = null'
  [ "$status" -eq 1 ]
  contains "$output" "kind must be run|enrichment"

  check '.outcome = ["success"]'
  [ "$status" -eq 1 ]
  contains "$output" "outcome must be"

  # a consecutive subsequence is the sneakiest shape
  check '.outcome = ["parked","escalated"]'
  [ "$status" -eq 1 ]
  contains "$output" "outcome must be success|parked|escalated|failed"

  # objects and numbers must fail the same way. `| .wall_s = null` matters:
  # without it the wall_s rule also fires and this assertion would pass even
  # with the kind enum check deleted entirely.
  check '.kind = {"run":true} | .wall_s = null'
  [ "$status" -eq 1 ]
  contains "$output" "kind must be run|enrichment"
  check '.outcome = 1'
  [ "$status" -eq 1 ]
  contains "$output" "outcome must be success|parked|escalated|failed"
}

@test "the check helper itself is non-vacuous" {
  # A jq filter that yields NOTHING must fail the helper rather than pass it —
  # otherwise every positive assertion in this file could be a silent no-op.
  check 'empty'
  [ "$status" -eq 1 ]
  contains "$output" "no records in the stream"
}

# --------------------------------------------------------- reporting breadth

@test "every violation on one record is reported, not just the first" {
  # A regression to `first` / `.[0]` would still pass every single-violation
  # test here while hiding half the problems in a real drifted stream.
  check '.outcome = "merged" | .ts = "nope" | .repo = ""'
  [ "$status" -eq 1 ]
  contains "$output" "outcome must be"
  contains "$output" "ts must be"
  contains "$output" "repo must be a non-empty string"
  [ "$(printf '%s' "$output" | grep -c '')" -eq 3 ]
}

@test "whitespace-only lines are skipped like empty ones" {
  # The skip predicate has two halves; the blank-line tests above exercise only
  # the zero-length one, leaving the ^\s*$ regex unguarded.
  { printf '%s\n' "$VALID"; printf ' \n\t\n'
    echo "$VALID" | jq -c '.outcome = "nope"'; } > "$F"
  run zsh "$S" "$F"
  [ "$status" -eq 1 ]
  contains "$output" "line 4"
  lacks "$output" "line 2"
  lacks "$output" "line 3"
}

@test "a whitespace-only stream counts as having no records" {
  printf ' \n\t\n' > "$F"
  run zsh "$S" "$F" --require-records
  [ "$status" -eq 1 ]
  contains "$output" "no records in the stream"
}

# ------------------------------------------------------------- open pipeline

@test "an unconventional pipeline value is ACCEPTED — it is an open identifier" {
  # The validator enforces only "non-empty string" here. A regression adding a
  # conventional-values enum — the likeliest drift, since kind and outcome have
  # enums right beside it — would reject every new pipeline's telemetry.
  check '.pipeline = "some.new_Pipeline-9"'
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------- more usage

@test "the '-' arm of the duplicate-input guard also rejects" {
  # If this arm regressed, `validate sink.jsonl -` would drop the FILE, read an
  # often-empty stdin and exit 0 while the sink violated the contract.
  printf '%s\n' "$VALID" > "$F"
  local bad="$BATS_TEST_TMPDIR/bad.jsonl"
  echo "$VALID" | jq -c '.outcome = "nope"' > "$bad"
  run zsh "$S" "$bad" -
  [ "$status" -eq 2 ]
  contains "$output" "only one input may be given"
  run zsh "$S" - "$bad"
  [ "$status" -eq 2 ]
  run bash -c "cat '$F' | zsh '$S' - -"
  [ "$status" -eq 2 ]
}

@test "a jq that exists but fails is an internal error, not a violation" {
  # The realistic modern form of the failure: a bad jq version, an OOM, or a
  # future syntax error in the embedded program. It must stay distinguishable
  # from exit 1, or a consumer reads a broken toolchain as bad data.
  local stub="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 1\n' > "$stub/jq"
  chmod +x "$stub/jq"
  printf '%s\n' "$VALID" > "$F"
  run env PATH="$stub:$PATH" "$ZSH_BIN" "$S" "$F"
  [ "$status" -eq 3 ]
  contains "$output" "failed to read the stream"
}

@test "the validator is executable and runs by bare path" {
  [ -x "$S" ]
  run "$S" --help
  [ "$status" -eq 0 ]
  starts_with "$output" "usage:"
}

# --------------------------------------------------------------- streams

@test "violations go to STDOUT and the empty-stream diagnostic to STDERR" {
  # A regression that printed violations on stderr would break every consumer
  # that pipes or redirects this script's stdout, while leaving exit codes intact.
  echo "$VALID" | jq -c '.outcome = "nope"' > "$F"
  run --separate-stderr zsh "$S" "$F"
  [ "$status" -eq 1 ]
  contains "$output" "line 1: outcome must be"     # violations on stdout
  [ -z "$stderr" ]

  : > "$F"
  run --separate-stderr zsh "$S" "$F" --require-records
  [ "$status" -eq 1 ]
  [ -z "$output" ]                                  # and NO "line N:" lines
  contains "$stderr" "no records in the stream"

  printf '%s\n' "$VALID" > "$F"
  run --separate-stderr zsh "$S" "$F" --require-records
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "--require-records is honoured before the operand too" {
  # The documented usage puts the flag last, but callers naturally write it
  # first; a regression in the arg loop would exit 2 for them.
  printf '%s\n' "$VALID" > "$F"
  run zsh "$S" --require-records "$F"
  [ "$status" -eq 0 ]
  : > "$F"
  run zsh "$S" --require-records "$F"
  [ "$status" -eq 1 ]
  contains "$output" "no records in the stream"
}

@test "every non-object JSON scalar is reported as a non-object record" {
  # `null` in particular must report "not a JSON object", never "not valid JSON".
  for lit in 'null' '5' '"a string"' 'true' '[1,2,3]'; do
    printf '%s\n' "$lit" > "$F"
    run zsh "$S" "$F"
    [ "$status" -eq 1 ]
    contains "$output" "record is not a JSON object"
    lacks "$output" "not valid JSON"
  done
}

# ------------------------------------------------- violation-set precision

@test "a bad or missing kind reports ONE violation, not a spurious wall_s one" {
  # The wall_s rule keys on kind == "run", so before it was scoped to a VALID
  # kind, any other kind also drew `wall_s must be null on kind "enrichment"` —
  # a complaint about a kind the record never had.
  check '.kind = "sideways"'
  [ "$status" -eq 1 ]
  contains "$output" "kind must be run|enrichment (got: sideways)"
  lacks "$output" "wall_s must be null"
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]

  check 'del(.kind)'
  [ "$status" -eq 1 ]
  contains "$output" "missing envelope key(s): kind"
  lacks "$output" "wall_s must be null"
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]
}

@test "a value containing a newline stays on ONE violation line" {
  # `tostring` would render an embedded \n as a real newline, splitting one
  # violation across two physical lines and breaking the documented shape.
  check '.schema = "a\nb"'
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]
  contains "$output" 'schema must be "telemetry/v1"'
  contains "$output" 'got: a\nb'

  # The carriage-return arm of the same two-branch gsub. A raw CR adds no line,
  # so only asserting the ESCAPE TEXT can catch its removal — a line count can't.
  check '.schema = "a\rb"'
  [ "$status" -eq 1 ]
  contains "$output" 'got: a\rb'

  # both at once
  check '.schema = "a\r\nb"'
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]
  contains "$output" 'got: a\r\nb'
}

@test "a closed-early stdout still returns the contractual exit 1, not 141" {
  # The validator installs `trap '' PIPE` so `validate … | head -5` — the idiom
  # its own header cites — returns 1 rather than being killed with 141. The
  # emitter's twin guard has a test; this is its counterpart.
  { echo "$VALID" | jq -c '.outcome = "nope"'
    echo "$VALID" | jq -c '.ts = "nope"'; } > "$F"
  run bash -c "set -o pipefail; zsh '$S' '$F' | head -0; exit \${PIPESTATUS[0]}"
  [ "$status" -eq 1 ]

  # and with stdout hard-closed, exercising the best-effort violations print
  run bash -c "zsh '$S' '$F' >&-"
  [ "$status" -eq 1 ]
}

@test "several unknown top-level keys are all named in one message" {
  check '.a = 1 | .b = 2'
  [ "$status" -eq 1 ]
  contains "$output" "unknown top-level key(s): a, b"
}

@test "a null payload is rejected like any other non-object" {
  check '.payload = null'
  [ "$status" -eq 1 ]
  contains "$output" "payload must be an object"
}

@test "-h is accepted as well as --help" {
  run zsh "$S" -h
  [ "$status" -eq 0 ]
  starts_with "$output" "usage:"
}

@test "the count: sentinel split survives a violation containing that literal" {
  # The trailing `count:<N>` sentinel is split off with ${raw##*count:} /
  # ${raw%count:*}. Flipping either to the other greediness would truncate the
  # report at the FIRST sentinel, silently dropping later violations.
  { echo "$VALID" | jq -c '.schema = "count:9"'
    echo "$VALID" | jq -c '.outcome = "nope"'; } > "$F"
  run zsh "$S" "$F"
  [ "$status" -eq 1 ]
  contains "$output" "line 1:"
  contains "$output" "line 2:"
  [ "$(printf '%s' "$output" | grep -c '')" -eq 2 ]

  # a clean record whose payload merely mentions the sentinel must still pass
  echo "$VALID" | jq -c '.payload = {"note":"count:3"}' > "$F"
  run zsh "$S" "$F" --require-records
  [ "$status" -eq 0 ]
}

# ------------------------------------------- --print-envelope-keys (#1008)
#
# The query mode that makes the validator the AUTHORITATIVE key list, so the
# hand-off contract page and its dashboard tests read the 14 names from the
# enforcer instead of copying them. These arms are the acceptance tests for
# test-case issues #1105 (happy), #1106 (corner) and #1107 (error).
#
# The list is deliberately NOT hard-coded here either — this file asserts the
# mode's SHAPE and its self-consistency with the validator's own enforcement.
# Pinning the names here would recreate, inside the test suite, the second
# source of truth the flag exists to remove.

@test "tc-happy-print-envelope-keys: prints a 14-element JSON array on stdout and exits 0 (#1105)" {
  run --separate-stderr zsh "$S" --print-envelope-keys
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  run bash -c "zsh '$S' --print-envelope-keys | jq -e 'type == \"array\" and length == 14
                and (map(type == \"string\" and length > 0) | all)'"
  [ "$status" -eq 0 ]
}

@test "tc-happy-print-envelope-keys: the printed keys are the ones actually ENFORCED (#1105)" {
  # The whole point of the flag: a record built from exactly the printed keys
  # must validate, and dropping any one of them must be reported as missing. A
  # printed list that had drifted from `def envelope_keys` would fail here.
  local built="$BATS_TEST_TMPDIR/built.jsonl"
  zsh "$S" --print-envelope-keys \
    | jq -c --argjson v "$VALID" '. as $k | reduce $k[] as $key ({}; .[$key] = $v[$key])' \
    > "$built"
  run zsh "$S" "$built" --require-records
  [ "$status" -eq 0 ]

  # Guard the list before iterating it: an empty one would make this half of the
  # test prove nothing. (The sibling suite adopted the same convention for every
  # loop — the guard belongs with the loop it protects, not in another test.)
  local keys key
  keys="$(zsh "$S" --print-envelope-keys | jq -r '.[]')"
  [ "$(printf '%s' "$keys" | grep -c '')" -eq 14 ]
  while IFS= read -r key; do
    echo "$VALID" | jq -c --arg k "$key" 'del(.[$k])' > "$F"
    run zsh "$S" "$F"
    [ "$status" -eq 1 ]
    contains "$output" "missing envelope key(s): $key"
  done <<< "$keys"
}

@test "tc-happy-print-envelope-keys: the mode reads no input at all (#1105)" {
  # A query mode that consumed stdin would hang a caller running it inside a
  # pipeline, and would quietly swallow data the caller still needed. The
  # downstream `cat` proves the bytes were left unread rather than discarded.
  run bash -c "printf 'untouched\n' | { zsh '$S' --print-envelope-keys >/dev/null; cat; }"
  [ "$status" -eq 0 ]
  [ "$output" = "untouched" ]
}

@test "tc-corner-print-envelope-keys-repeated: repeating the flag is idempotent, not additive (#1106)" {
  run zsh "$S" --print-envelope-keys --print-envelope-keys
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]
  run bash -c "zsh '$S' --print-envelope-keys --print-envelope-keys | jq -e 'length == 14'"
  [ "$status" -eq 0 ]
}

@test "tc-error-print-envelope-keys-with-input: a FILE operand is a usage error (#1107)" {
  # `… --print-envelope-keys sink.jsonl` means "validate sink.jsonl". Printing
  # keys and exiting 0 over an unvalidated stream would be a false green.
  printf '%s\n' "$VALID" > "$F"
  run --separate-stderr zsh "$S" --print-envelope-keys "$F"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "--print-envelope-keys reads no input"
  contains "$stderr" "usage:"
}

@test "tc-error-print-envelope-keys-with-input: operand order does not change the verdict (#1107)" {
  # Exit 2 alone proves too little — it is the shared code for EVERY usage error,
  # so a regression routing the reversed order into "only one input may be given"
  # or "unknown flag" would keep these green while the title became false. Pin
  # the message, which is the actual claim: the post-loop conflict check makes
  # order irrelevant.
  printf '%s\n' "$VALID" > "$F"
  run --separate-stderr zsh "$S" "$F" --print-envelope-keys
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "--print-envelope-keys reads no input"
  run --separate-stderr zsh "$S" - --print-envelope-keys
  [ "$status" -eq 2 ]
  contains "$stderr" "--print-envelope-keys reads no input"
}

@test "tc-error-print-envelope-keys-with-input: --require-records is a usage error too (#1107)" {
  # It asserts something about a stream, and this mode reads no stream.
  run --separate-stderr zsh "$S" --print-envelope-keys --require-records
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "--require-records is meaningless"
  run --separate-stderr zsh "$S" --require-records --print-envelope-keys
  [ "$status" -eq 2 ]
  contains "$stderr" "--require-records is meaningless"
}

@test "--print-envelope-keys reports a missing jq as an internal error, not an empty list" {
  # The failure mode this guards is silent and downstream: if the mode ever
  # exited 0 while printing nothing, tests/telemetry-grafana-dashboard.bats's
  # envelope_keys() would hand its loops an EMPTY list and several assertions
  # there would pass vacuously. So the contract is "never exit 0 with no array".
  local empty="$BATS_TEST_TMPDIR/empty-path"
  mkdir -p "$empty"
  run --separate-stderr env PATH="$empty" "$ZSH_BIN" "$S" --print-envelope-keys
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "jq not found on PATH"
}

@test "--print-envelope-keys reports a FAILING jq as exit 3 with no output" {
  # The `|| { … exit 3 }` guard on the print itself. Drop it and a broken jq
  # yields exit 0 plus an empty stdout — the false green described above.
  local stub="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 1\n' > "$stub/jq"
  chmod +x "$stub/jq"
  run --separate-stderr env PATH="$stub:$PATH" "$ZSH_BIN" "$S" --print-envelope-keys
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "failed to print the envelope keys"
}

@test "--print-envelope-keys is documented in the script's own usage block" {
  run zsh "$S" --help
  [ "$status" -eq 0 ]
  contains "$output" "--print-envelope-keys"
}
