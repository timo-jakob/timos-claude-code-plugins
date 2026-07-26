#!/usr/bin/env bats
#
# Behavioral tests for build-refine-telemetry-record.zsh (#579, epic #573 —
# retrofitted onto the shared `telemetry/v1` contract by epic #740 child (c),
# issue #1005).
#
# The contract after the retrofit is a SPLIT: this script builds only the
# refine-issue `payload`, and `emit-telemetry.zsh` owns the envelope and the
# sink. So these tests pin two things that a copy-adapted builder would blur:
#
#   1. the payload shape is EXACTLY the five bespoke keys, with no envelope key
#      leaking back in (an `issue`/`ts`/`wall_s` at payload level would validate
#      — payload is OPEN — and quietly shadow the real envelope field), and
#   2. end to end through the real emitter, the emitted record validates, lands
#      in the SHARED default sink, carries a non-null `repo` and a numeric
#      `wall_s`, and embeds the payload UNMODIFIED (asserted by equality, not by
#      sampling a couple of fields — the validator cannot catch a mangled
#      payload, because `payload` is OPEN by design).
#
# stdout vs stderr is pinned deliberately: SKILL.md Step 7 redirects the
# builder's STDOUT into the payload file, so anything advisory printed there
# would corrupt a payload while the builder still exited 0 — and the caller's
# `|| echo` advisory would reduce the resulting lost record to one line. Hence `build_split` / `build_split_to`
# and the `[ -z "$output" ]` assertions on every failure path. The single
# documented exception is the pty test, where a pty inherently merges the two
# streams onto the terminal it allocates.
#
# Exit codes are asserted EXACTLY: the script documents 2 = usage (caller error,
# including a bad --state operand PATH) and 1 = internal (a readable state that
# cannot be turned into a payload), and a regression that collapses the two
# would otherwise ship green.
#
# NOTE: the integration tests point --repo-dir at BATS_TEST_TMPDIR, so the suite
# never writes into this repo's own .claude/telemetry sink.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/refine-issue/scripts/build-refine-telemetry-record.zsh"
  E="$REPO_ROOT/development/scripts/telemetry/emit-telemetry.zsh"
  V="$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh"
  ZSH_BIN="$(command -v zsh)"
  ST="$BATS_TEST_TMPDIR/state.json"

  # Shared by every test whose regression mode is a HANG rather than a failure.
  TO=""
  if command -v timeout >/dev/null 2>&1; then TO="timeout 10"
  elif command -v gtimeout >/dev/null 2>&1; then TO="gtimeout 10"; fi

  # Pin git away from the host's config so `git remote get-url` (the emitter's
  # repo derivation) can't be reshaped by a global url.insteadOf rewrite.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

  RD="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$RD"
  git init -q "$RD"
}
put() { printf '%s' "$1" > "$ST"; }

# stdout and stderr kept apart: $output is the payload, $stderr the diagnostics.
build_split() { run --separate-stderr zsh "$S" "$@"; }
# Same, but BOUNDED, for the branches whose regression mode is a HANG. The bound
# must be real on both lanes: $TO is empty on macOS CI (no coreutils, so neither
# timeout nor gtimeout exists), and `< /dev/null` only defuses READ-shaped hangs
# — the regression these tests name is a busy `while` loop that consumes no
# stdin, which /dev/null bounds not at all. So prefer an in-process python bound
# (python3 is on both lanes), falling back to $TO and then to a bare run.
_bounded() {  # bounds $@ at 10s, exiting 124 on timeout — like timeout(1)
  # subprocess.run(timeout=) KILLS the child before raising. An alarm that only
  # os._exit()s the parent would leave the child holding the write end of bats'
  # `output="$(…)"` capture pipe, so `run` would block anyway — the bound has to
  # kill, not just exit. Probe python by EXECUTING it: macOS ships an
  # /usr/bin/python3 stub that satisfies `command -v` and then fails.
  if python3 -c 'pass' >/dev/null 2>&1; then
    python3 -c 'import subprocess,sys
try:
    rc = subprocess.run(sys.argv[1:], stdin=subprocess.DEVNULL, timeout=10).returncode
except subprocess.TimeoutExpired:
    sys.exit(124)
sys.exit(rc if rc >= 0 else 128 - rc)' "$@"
  else
    $TO "$@" < /dev/null
  fi
}
build_split_to() { run --separate-stderr _bounded zsh "$S" "$@"; }

# bash 3.2 (macOS `/bin/bash`) does not apply errexit to a failing `[[ ... ]]`,
# so one mid-test is silently ignored there — while bash >= 4 catches it, making
# the same assertion mean different things on the two CI legs. These helpers are
# ordinary commands, so they fail wherever they appear, on every bash.
assert_eq() {  # $1 = actual, $2 = expected, $3 = label
  [ "$1" = "$2" ] || { printf 'expected %s = %s, got %s\n' "$3" "$2" "$1" >&2; return 1; }
}
assert_contains() {  # $1 = haystack, $2 = needle
  case "$1" in *"$2"*) return 0 ;; esac
  printf 'expected output to contain %s, got: %s\n' "$2" "$1" >&2; return 1
}
PAYLOAD_KEYS='["objections_raised","objections_resolved","park_type","risk_classification","rounds"]'

READY='{"rounds":3,"objections_raised":4,"objections_resolved":4,"outcome":"refined-ready","risk_classification":"low"}'
PARKED='{"rounds":1,"objections_raised":2,"objections_resolved":0,"outcome":"parked","park_type":"needs-decision","risk_classification":"normal"}'

# --- the payload shape (AC1) -------------------------------------------------

@test "a refined-ready run yields a payload of EXACTLY the five bespoke keys, and nothing on stderr (AC1)" {
  put "$READY"
  build_split --state "$ST"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]                                       # stdout IS the payload file
  assert_eq "$(printf '%s' "$output" | grep -c '')" 1 "line count"
  echo "$output" | jq -e '.' >/dev/null                  # valid JSON
  assert_eq "$(echo "$output" | jq -c 'keys')" "$PAYLOAD_KEYS" "payload keys"
  assert_eq "$(echo "$output" | jq '.rounds')" 3 ".rounds"
  assert_eq "$(echo "$output" | jq '.objections_raised')" 4 ".objections_raised"
  assert_eq "$(echo "$output" | jq '.objections_resolved')" 4 ".objections_resolved"
  assert_eq "$(echo "$output" | jq -r '.risk_classification')" "low" ".risk_classification"
  # present-with-null, not absent, and not the STRING "null"
  echo "$output" | jq -e 'has("park_type") and .park_type == null' >/dev/null
}

@test "no envelope key leaks into the payload, even from a stale pre-retrofit state (AC1)" {
  # The realistic leak is a caller handing over a state that still carries the
  # v0 envelope fields — exactly what the retrofit's transition period produces.
  put '{"outcome":"parked","rounds":1,"ts":1720000000,"issue":579,"wall_s":42,"pipeline":"refine-issue","repo":"o/n","tokens":10,"schema":"telemetry/v1"}'
  build_split --state "$ST"
  [ "$status" -eq 0 ]
  # `payload` is OPEN, so a stray envelope key would validate and silently
  # shadow the real field. The exact key set proves they were DROPPED, not
  # merely "not added".
  assert_eq "$(echo "$output" | jq -c 'keys')" "$PAYLOAD_KEYS" "payload keys"
  assert_eq "$(echo "$output" | jq -c '
    ["schema","kind","run_id","parent_run_id","ts","repo","repo_type",
     "pipeline","issue","pr","outcome","wall_s","tokens"] as $env
    | [ keys[] | select(. as $k | $env | index($k)) ]')" \
    '[]' "envelope keys present in the payload"
}

@test "a parked run keeps park_type in the payload (AC1)" {
  put "$PARKED"
  build_split --state "$ST"
  [ "$status" -eq 0 ]
  assert_eq "$(echo "$output" | jq -c 'keys')" "$PAYLOAD_KEYS" "payload keys"
  assert_eq "$(echo "$output" | jq -r '.park_type')" "needs-decision" ".park_type"
  assert_eq "$(echo "$output" | jq '.objections_resolved')" 0 ".objections_resolved"
}

@test "missing fields default to 0 / null WITHOUT dropping their keys" {
  put '{"outcome":"parked"}'
  build_split --state "$ST"
  [ "$status" -eq 0 ]
  # the key set is the point: `jq -r '.k'` prints "null" for an ABSENT key too,
  # so without this a builder that emitted four keys would ship green here.
  assert_eq "$(echo "$output" | jq -c 'keys')" "$PAYLOAD_KEYS" "payload keys"
  assert_eq "$(echo "$output" | jq '.rounds')" 0 ".rounds"
  assert_eq "$(echo "$output" | jq '.objections_raised')" 0 ".objections_raised"
  echo "$output" | jq -e 'has("park_type") and .park_type == null' >/dev/null
  echo "$output" | jq -e 'has("risk_classification") and .risk_classification == null' >/dev/null
}

# NB: no backticks in a @test description — bats eval()s the description to
# resolve variable references, so a backtick becomes command substitution.
@test "reads state from stdin, both bare and via an explicit --state dash" {
  put "$READY"
  for form in bare dash; do
    if [ "$form" = bare ]; then
      run zsh -c 'zsh "$1" < "$2"' _ "$S" "$ST"
    else
      run zsh -c 'zsh "$1" --state - < "$2"' _ "$S" "$ST"
    fi
    [ "$status" -eq 0 ] || { echo "$form: expected 0, got $status: $output"; return 1; }
    assert_eq "$(echo "$output" | jq -c 'keys')" "$PAYLOAD_KEYS" "$form payload keys"
    assert_eq "$(echo "$output" | jq '.rounds')" 3 "$form .rounds"
  done
}

@test "--print-outcome works on stdin too (the mode Step 7 calls first)" {
  put "$READY"
  run zsh -c 'zsh "$1" --print-outcome < "$2"' _ "$S" "$ST"
  [ "$status" -eq 0 ]
  assert_eq "$output" "success" "mapped outcome"
}

# --- the outcome mapping (AC3) -----------------------------------------------

@test "--print-outcome maps refined-ready to the envelope enum success (AC3)" {
  put "$READY"
  build_split --state "$ST" --print-outcome
  [ "$status" -eq 0 ]
  assert_eq "$output" "success" "mapped outcome"
  [ -z "$stderr" ]
}

@test "--print-outcome maps parked to the envelope enum parked (AC3)" {
  put "$PARKED"
  build_split --state "$ST" --print-outcome
  [ "$status" -eq 0 ]
  assert_eq "$output" "parked" "mapped outcome"
}

@test "--print-outcome emits ONLY the mapped outcome, never the payload (AC3)" {
  put "$READY"
  build_split --state "$ST" --print-outcome
  [ "$status" -eq 0 ]
  assert_eq "$(printf '%s' "$output" | grep -c '')" 1 "line count"
  assert_eq "$output" "success" "exact stdout"   # a leaked payload would fail this
}

@test "--print-outcome still rejects an unknown outcome (mapping never guesses, AC3)" {
  put '{"outcome":"bogus"}'
  build_split --state "$ST" --print-outcome
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "unknown outcome"
}

# --- preserved input validation (AC2) ----------------------------------------

@test "an unknown outcome is rejected (exit 1, AC2)" {
  put '{"outcome":"bogus"}'
  build_split --state "$ST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "unknown outcome"
}

@test "a missing outcome is rejected (exit 1, AC2)" {
  put '{"rounds":2}'
  build_split --state "$ST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "outcome is required"
}

@test "invalid state JSON is rejected (exit 1, AC2)" {
  put '{not json'
  build_split --state "$ST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "single JSON object"
}

@test "a zero-byte state file is exit 1 with EMPTY stdout, never a silent empty payload (AC2)" {
  # jq over an empty input emits nothing and exits 0, so without the
  # single-object gate Step 7 would write an EMPTY payload file at exit 0, the
  # emitter would reject it (usage 2), and the `|| echo` advisory would swallow it.
  : > "$ST"
  build_split --state "$ST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "single JSON object"
}

@test "a whitespace-only state file is exit 1 with EMPTY stdout (AC2)" {
  printf '   \n\n' > "$ST"
  build_split --state "$ST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "single JSON object"
}

@test "regression: concatenated JSON documents are rejected (one payload per run, AC2)" {
  put '{"outcome":"parked"} {}'
  build_split --state "$ST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "single JSON object"
}

@test "a well-formed NON-OBJECT state is rejected (the gate's type conjunct, AC2)" {
  # The gate is `length == 1 and (.[0] | type == "object")`. Every other
  # rejection fixture trips the length half or a parse error, so without this
  # the type conjunct could be dropped and still ship green — and the fallout
  # is a misdiagnosis ("outcome is required" for a structurally wrong input).
  # `[{...}]` is the realistic slip: a caller that ran `jq -s` on its state.
  for s in '[{"outcome":"parked"}]' '"parked"' '42' 'null' 'true'; do
    put "$s"
    build_split --state "$ST"
    [ "$status" -eq 1 ] || { echo "state $s: expected 1, got $status"; return 1; }
    [ -z "$output" ] || { echo "state $s: stdout not empty"; return 1; }
    assert_contains "$stderr" "single JSON object" \
      || { echo "state $s: wrong diagnostic"; return 1; }
  done
}

@test "out-of-enum park_type / risk_classification ride through verbatim (this builder polices neither)" {
  # The header documents closed value sets but deliberately does NOT validate
  # them — pipeline detail is the payload's business. Pin the choice, so a later
  # change that starts rejecting or null-coercing them is visible.
  put '{"outcome":"parked","park_type":"bogus","risk_classification":"catastrophic"}'
  build_split --state "$ST"
  [ "$status" -eq 0 ]
  assert_eq "$(echo "$output" | jq -c 'keys')" "$PAYLOAD_KEYS" "payload keys"
  assert_eq "$(echo "$output" | jq -r '.park_type')" "bogus" ".park_type"
  assert_eq "$(echo "$output" | jq -r '.risk_classification')" "catastrophic" ".risk_classification"
}

@test "regression: a string-typed count is coerced to a number (AC2)" {
  put '{"outcome":"parked","rounds":"3","objections_raised":"2"}'
  build_split --state "$ST"
  [ "$status" -eq 0 ]
  assert_eq "$(echo "$output" | jq '.rounds')" 3 ".rounds"
  echo "$output" | jq -e '.rounds | type == "number"' >/dev/null
  echo "$output" | jq -e '.objections_raised | type == "number"' >/dev/null
}

@test "a non-numeric count that cannot be parsed still coerces to 0 (AC2)" {
  put '{"outcome":"parked","rounds":"many"}'
  build_split --state "$ST"
  [ "$status" -eq 0 ]
  assert_eq "$(echo "$output" | jq '.rounds')" 0 ".rounds"
}

# --- the --state operand policy (exit 2: a caller path mistake) --------------

@test "a nonexistent --state path is a usage error (exit 2), distinguishable from broken JSON" {
  build_split --state "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "build-refine-telemetry-record: --state file does not exist"
}

@test "a directory as --state is a usage error (exit 2) named for what it is" {
  build_split --state "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "build-refine-telemetry-record: --state is a directory"
}

@test "an unreadable --state file is a usage error (exit 2), not a misreported JSON error" {
  put "$READY"
  chmod 000 "$ST"
  if [ -r "$ST" ]; then skip "running as a user that bypasses file permissions"; fi
  build_split --state "$ST"
  chmod 644 "$ST"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "build-refine-telemetry-record: --state file not readable"
}

@test "a process-substitution --state operand still works (the FIFO idiom the emitter keeps)" {
  run zsh -c 'zsh "$1" --state <(printf "%s" "$2")' _ "$S" "$READY"
  [ "$status" -eq 0 ]
  assert_eq "$(echo "$output" | jq -c 'keys')" "$PAYLOAD_KEYS" "payload keys"
}

# --- the retired envelope flags and the argument loop ------------------------

@test "the retired envelope flags are now usage errors (the emitter owns them)" {
  put "$READY"
  for flag in --issue --ts --wall-s; do
    build_split --state "$ST" "$flag" 1
    [ "$status" -eq 2 ] || { echo "flag $flag: expected 2, got $status"; return 1; }
    [ -z "$output" ] || { echo "flag $flag: stdout not empty"; return 1; }
    assert_contains "$stderr" "build-refine-telemetry-record: unknown flag" \
      || { echo "flag $flag: wrong diagnostic"; return 1; }
  done
}

@test "an unknown flag is a usage error (exit 2)" {
  put "$READY"
  build_split --state "$ST" --bogus x
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "build-refine-telemetry-record: unknown flag"
}

@test "a positional argument is a usage error (exit 2), never a fall-through to stdin" {
  # The realistic caller slip is `build-… /tmp/refine-state.json` — forgetting
  # --state, which Step 7's template makes easy. If this arm were dropped the
  # script would fall through to the stdin read and hang under Step 7's `|| echo`.
  put "$READY"
  build_split_to "$ST"
  [ "$status" -ne 124 ]
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "build-refine-telemetry-record: unexpected argument"
}

@test "regression: a dangling trailing flag is a usage error and does not hang" {
  # A bare `shift 2` with $# < 2 fails without consuming and spins forever —
  # and Step 7's `|| echo` cannot rescue a process that never exits.
  put "$READY"
  build_split_to --state
  [ "$status" -ne 124 ]           # 124 == timeout fired == it hung
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "build-refine-telemetry-record: --state requires a value"
}

@test "an empty or flag-shaped --state value is a usage error (exit 2), never a stdin read" {
  # _need_val's SECOND arm. Without it, `--state ""` falls through to
  # state_file="" -> the stdin branch -> a hang; `--state --print-outcome`
  # would exit 2 on the operand check with the wrong message.
  put "$READY"
  for v in "" --print-outcome; do
    build_split_to --state "$v"
    [ "$status" -ne 124 ] || { echo "hung on --state '$v'"; return 1; }
    [ "$status" -eq 2 ] || { echo "--state '$v': expected 2, got $status"; return 1; }
    [ -z "$output" ] || { echo "--state '$v': stdout not empty"; return 1; }
    assert_contains "$stderr" "build-refine-telemetry-record: --state requires a non-empty value" \
      || { echo "--state '$v': wrong diagnostic"; return 1; }
  done
}

@test "no --state with a terminal stdin refuses (exit 2) instead of blocking forever" {
  # Reachable when a maintainer runs the script by hand. Allocate the pty with
  # python3, NOT script(1): script has two incompatible flavours (BSD
  # `script FILE CMD...` vs util-linux `script -c CMD FILE`), both of which exit
  # 0 on the wrong form, and util-linux's runs the command through an extra
  # $SHELL -c layer that would expand a `$?` in the child's command string
  # before the child ever starts. python3 is present on both CI lanes
  # (script-tests.yml apt-installs it on ubuntu; macos-latest ships it), and
  # pty.spawn returns the child's REAL status, so no EXIT= echo is needed and
  # no external timeout is required — the guard under test is what stops the
  # hang, and python3 exits as soon as the child does.
  # The 10s bound is enforced IN-PROCESS, not by timeout(1): the macOS CI lane
  # installs no coreutils, so $TO is empty there and an external bound would be
  # inert on exactly the platform where a regressed guard would hang the job to
  # its ceiling instead of failing in seconds.
  python3 -c 'pass' >/dev/null 2>&1 || skip "no working python3 to allocate a pty"
  # pty.fork (not spawn) so the handler can KILL the child: exiting only the
  # parent would leave a busy-looping orphan for the rest of the CI job.
  run python3 -c 'import pty,sys,os,signal
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], sys.argv[1:])
def _t(*_):
    os.kill(pid, signal.SIGKILL); os._exit(124)
signal.signal(signal.SIGALRM, _t); signal.alarm(10)
out = b""
try:
    while True:
        b_ = os.read(fd, 1024)
        if not b_: break
        out += b_
except OSError:
    pass
sys.stdout.write(out.decode(errors="replace"))
st = os.waitpid(pid, 0)[1]
sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + os.WTERMSIG(st))' "$ZSH_BIN" "$S"
  [ "$status" -ne 124 ] || { echo "hung on a terminal stdin"; return 1; }
  [ "$status" -eq 2 ]                         # the documented usage code
  assert_contains "$output" "stdin is a terminal"
}

@test "-h / --help exits 0 with usage on stdout, nothing on stderr, and no payload" {
  for f in -h --help; do
    build_split "$f"
    [ "$status" -eq 0 ] || { echo "$f: expected 0, got $status"; return 1; }
    [ -z "$stderr" ] || { echo "$f: stderr not empty: $stderr"; return 1; }
    assert_contains "$output" "usage:" || { echo "$f: missing usage banner"; return 1; }
    assert_contains "$output" "--print-outcome" \
      || { echo "$f: --print-outcome no longer documented"; return 1; }
    # Assert the CONTRACT, not "the whole blob isn't JSON" — feeding the banner
    # plus a leaked payload to jq fails on the banner's first token either way,
    # so that form would pass even when a payload leaked. Look for the keys.
    for k in rounds objections_raised park_type; do
      case "$output" in
        *"\"$k\""*) echo "$f: payload key $k leaked into --help output"; return 1 ;;
      esac
    done
  done
}

@test "the builder is executable and runs by bare path (Step 7 invokes it as \$BUILDER)" {
  # Step 7 runs "$BUILDER" directly, so a lost exec bit breaks it in production
  # while `zsh "$S"` keeps the whole suite green — the family pins this guard
  # in telemetry-emit.bats, telemetry-validate.bats, gather-go.bats and others.
  [ -x "$S" ]
  put "$READY"
  run "$S" --state "$ST" --print-outcome
  [ "$status" -eq 0 ]
  assert_eq "$output" "success" "bare-path outcome"
}

@test "a missing jq is the documented internal error (exit 1), not a JSON complaint" {
  put "$READY"
  mkdir -p "$BATS_TEST_TMPDIR/empty-path"
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/empty-path" "$ZSH_BIN" "$S" --state "$ST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "jq not found on PATH"
}

# --- end to end through the real emitter (AC4-AC7) ---------------------------

# Build the payload and emit it exactly as SKILL.md Step 7 does.
emit_run() {  # $1 = state JSON, $2 = wall seconds, $3.. = extra emitter flags
  local state="$1" wall="$2"; shift 2
  put "$state"
  local payload="$BATS_TEST_TMPDIR/payload.json" outcome
  # return the REAL status: a hardcoded 1 would make the fail-closed test's
  # "exactly 1" assertion vacuous (a missing zsh (127) or a usage 2 would pass).
  outcome="$(zsh "$S" --state "$ST" --print-outcome)" || return $?
  zsh "$S" --state "$ST" > "$payload" || return $?
  # --ts mirrors Step 7, which always passes the run's start stamp. Callers may
  # override it by passing their own --ts in "$@" (the emitter takes the last).
  zsh "$E" --pipeline refine-issue --kind run --outcome "$outcome" \
    --repo-dir "$RD" --ts 1720000000 --issue 579 --wall-s "$wall" \
    --payload "$payload" "$@"
}

@test "ts is the caller's pinned RUN-START stamp, not emission time (AC: --ts)" {
  # The retrofit moved `ts` onto the emitter's --ts, and both SKILL.md and
  # ARCHITECTURE.md make run-START semantics a contract of this change. Without
  # this, a change that stamped emission time would skew every lead-time query
  # on the stream and still ship green.
  run emit_run "$READY" 90
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ts | type == "number"' >/dev/null
  assert_eq "$(echo "$output" | jq '.ts')" 1720000000 ".ts (pinned run start)"
}

@test "a rejected state leaves the shared sink untouched (fail closed)" {
  # The chain must fail CLOSED: a builder that rejects the state must stop the
  # emitter running at all, so no half-record and no empty payload can land.
  # EXACT 1 (the builder's internal class), not merely non-zero — a missing zsh
  # or a vanished jq would satisfy `-ne 0` and hide a broken harness. And assert
  # the sink DIRECTORY is absent: the emitter mkdir -p's it before appending, so
  # an existing directory proves the chain got that far.
  run emit_run '{"outcome":"bogus"}' 90
  [ "$status" -eq 1 ]
  [ ! -d "$RD/.claude/telemetry" ]
  run emit_run '' 90
  [ "$status" -eq 1 ]
  [ ! -d "$RD/.claude/telemetry" ]
}

@test "the emitted record validates against the contract (AC6)" {
  run emit_run "$READY" 90
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/one.jsonl"
  run zsh "$V" "$BATS_TEST_TMPDIR/one.jsonl" --require-records
  [ "$status" -eq 0 ]
}

@test "the payload rides along UNMODIFIED — asserted by equality, not by sampling (AC1/AC6)" {
  # The validator cannot catch a mangled payload (payload is OPEN by design), so
  # a dropped key or a re-encoded number would otherwise ship green.
  run emit_run "$READY" 90
  [ "$status" -eq 0 ]
  assert_eq "$(echo "$output" | jq -cS '.payload')" \
    "$(jq -cS '.' "$BATS_TEST_TMPDIR/payload.json")" "payload round-trip"
  assert_eq "$(echo "$output" | jq -c '.payload | keys')" "$PAYLOAD_KEYS" "emitted payload keys"
}

@test "the parked path also embeds the exact five-key payload (AC1)" {
  run emit_run "$PARKED" 12
  [ "$status" -eq 0 ]
  assert_eq "$(echo "$output" | jq -cS '.payload')" \
    "$(jq -cS '.' "$BATS_TEST_TMPDIR/payload.json")" "payload round-trip"
  assert_eq "$(echo "$output" | jq -c '.payload | keys')" "$PAYLOAD_KEYS" "emitted payload keys"
}

@test "the record carries a non-null repo derived by the emitter (AC4)" {
  git -C "$RD" remote add origin https://github.com/timo-jakob/widget.git
  run emit_run "$READY" 90
  [ "$status" -eq 0 ]
  assert_eq "$(echo "$output" | jq -r '.repo')" "timo-jakob/widget" ".repo"
  echo "$output" | jq -e '.repo | type == "string" and length > 0' >/dev/null
}

@test "repo falls back to the directory basename, so it is never null (AC4)" {
  run emit_run "$READY" 90      # no origin remote configured
  [ "$status" -eq 0 ]
  assert_eq "$(echo "$output" | jq -r '.repo')" "repo" ".repo (basename fallback)"
}

@test "wall_s round-trips as a number, never null (AC5)" {
  run emit_run "$READY" 90
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.wall_s | type == "number"' >/dev/null
  assert_eq "$(echo "$output" | jq '.wall_s')" 90 ".wall_s"
}

@test "a zero-second run emits wall_s 0, not null (AC5)" {
  run emit_run "$PARKED" 0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.wall_s | type == "number"' >/dev/null
  assert_eq "$(echo "$output" | jq '.wall_s')" 0 ".wall_s"
}

@test "the envelope carries the pipeline linkage fields" {
  run emit_run "$PARKED" 12
  [ "$status" -eq 0 ]
  assert_eq "$(echo "$output" | jq -r '.pipeline')" "refine-issue" ".pipeline"
  assert_eq "$(echo "$output" | jq -r '.kind')" "run" ".kind"
  assert_eq "$(echo "$output" | jq '.issue')" 579 ".issue"
  assert_eq "$(echo "$output" | jq -r '.outcome')" "parked" ".outcome"
  echo "$output" | jq -e 'has("tokens") and .tokens == null' >/dev/null   # never guessed
  assert_eq "$(echo "$output" | jq -r '.schema')" "telemetry/v1" ".schema"
  # both documented as deliberately null on this stream (no stack detection; the
  # epic walk emits no parent record) — the validator accepts a string in either
  echo "$output" | jq -e 'has("repo_type") and .repo_type == null' >/dev/null
  echo "$output" | jq -e 'has("parent_run_id") and .parent_run_id == null' >/dev/null
}

@test "the parked run's park_type survives into the payload end to end" {
  run emit_run "$PARKED" 12
  [ "$status" -eq 0 ]
  assert_eq "$(echo "$output" | jq -r '.payload.park_type')" "needs-decision" ".payload.park_type"
  assert_eq "$(echo "$output" | jq '.payload.rounds')" 1 ".payload.rounds"
}

@test "a refined-ready run lands as outcome=success on the envelope (AC3)" {
  run emit_run "$READY" 30
  [ "$status" -eq 0 ]
  assert_eq "$(echo "$output" | jq -r '.outcome')" "success" ".outcome"
}

@test "the default sink is the SHARED .claude/telemetry/telemetry.jsonl (AC7)" {
  run emit_run "$READY" 90
  [ "$status" -eq 0 ]
  [ -f "$RD/.claude/telemetry/telemetry.jsonl" ]
  [ ! -e "$RD/.claude/telemetry/refine-issue.jsonl" ]   # the retired per-pipeline sink
  assert_eq "$(wc -l < "$RD/.claude/telemetry/telemetry.jsonl" | tr -d ' ')" 1 "sink lines"
  assert_eq "$(jq -r '.pipeline' "$RD/.claude/telemetry/telemetry.jsonl")" "refine-issue" "sink .pipeline"
}

@test "appending N runs yields N well-formed lines in the shared sink" {
  emit_run "$READY" 10 >/dev/null
  emit_run "$PARKED" 20 >/dev/null
  local sink="$RD/.claude/telemetry/telemetry.jsonl"
  assert_eq "$(wc -l < "$sink" | tr -d ' ')" 2 "sink lines"
  assert_eq "$(jq -s 'length' "$sink")" 2 "parsed records"
  assert_eq "$(jq -s -r '[.[].outcome] | join(",")' "$sink")" "success,parked" "outcomes"
  run zsh "$V" "$sink" --require-records
  [ "$status" -eq 0 ]
}

@test "runs sharing one pinned ts still get distinct run_ids (join key integrity)" {
  # --ts must be PINNED: without it the emitter stamps date +%s per call, so the
  # ids would differ by their timestamp component alone and this would pass even
  # if the random suffix were a constant — the very regression it targets.
  local sink="$RD/.claude/telemetry/telemetry.jsonl" i
  for i in 1 2 3 4 5 6 7 8; do emit_run "$READY" 1 >/dev/null; done
  assert_eq "$(jq -s '[.[].ts] | unique | length' "$sink")" 1 "shared ts"
  # >= 7 of 8, not 8 of 8: the suffix is 16 bits, so demanding zero collisions
  # is a real ~1-in-4000 intermittent red on a suite that runs on every PR and
  # both CI lanes. One legitimate collision is tolerated; the regression this
  # targets (a ts-derived suffix) collapses all 8 to a single id. Do NOT
  # "tighten" this back to equality. Mirrors tests/telemetry-emit.bats.
  local uniq; uniq="$(jq -s '[.[].run_id] | unique | length' "$sink")"
  [ "$uniq" -ge 7 ] || { echo "expected >= 7 distinct run_ids of 8, got $uniq"; return 1; }
}

# --- Step 7's prose IS the caller — pin it against the executable contract ----

# The review-loop sibling's caller is a script (resolve-story-loop.zsh) covered
# by tests/resolve-story-loop.bats. refine-issue's caller is SKILL.md Step 7:
# prose a model executes, wrapped in `{ … } || echo`, so drift is invisible at
# runtime AND in CI. A prose revert restoring --issue/--ts/--wall-s on the
# BUILDER would make it exit 2 (unit-tested above) and the record would simply
# never be written, with only a one-line advisory to show for it. These tests
# are the same doc/executable guard tests/review-loop-budget-consistency.bats
# and tests/docs-topic-marker.bats apply, and script-tests.yml already lists
# SKILL.md as a trigger path so the suite gates it.
skill_step7() {
  local out
  out="$(sed -n '/^## Step 7 /,/^## /p' "$REPO_ROOT/development/skills/refine-issue/SKILL.md")"
  # Without this, the two NEGATIVE guard tests below pass vacuously the moment
  # the heading is renamed or the section moves — they stop guarding at exactly
  # the moment prose drifts hardest.
  [ -n "$out" ] || { echo "Step 7 section not found in SKILL.md" >&2; return 1; }
  printf '%s\n' "$out"
}
# Step 7's ```bash fence ONLY. Asserting against the whole section is how a
# `rounds:` assertion ends up satisfied by a prose sentence rather than by the
# state jq — every code-shaped assertion belongs here, not in skill_step7.
skill_step7_code() {
  local section out
  section="$(skill_step7)" || return 1
  # exactly ONE fence, or the range below could span two and let a condition
  # extraction pair an `if` from one with a `]]; then` from another.
  [ "$(printf '%s\n' "$section" | grep -c '^```bash')" -eq 1 ] \
    || { echo "Step 7 must contain exactly one bash fence" >&2; return 1; }
  out="$(printf '%s\n' "$section" | sed -n '/^```bash/,/^```$/p')"
  [ -n "$out" ] || { echo "Step 7 bash fence not found in SKILL.md" >&2; return 1; }
  # shape assertions: a closing fence with trailing whitespace would defeat the
  # range and silently drag the PROSE bullets in — re-opening the very hole this
  # helper exists to close.
  [ "$(printf '%s\n' "$out" | head -1)" = '```bash' ] \
    && [ "$(printf '%s\n' "$out" | tail -1)" = '```' ] \
    || { echo "Step 7's bash fence is not cleanly delimited" >&2; return 1; }
  printf '%s\n' "$out"
}
# Step 0's fence is indented inside a list item, hence the leading ` *`.
skill_step0_code() {
  local out
  # Step 0 has SEVERAL fences; take the INDENTED stamp block only (two spaces,
  # inside the bullet) and stop at its first close, or the range concatenates
  # the others and an assertion can resolve against the wrong one.
  # awk, not sed: BSD sed rejects `q` inside a brace block, and we need to stop
  # at the FIRST close so the other fences are not concatenated in.
  out="$(skill_step0 | awk '/^  ```bash/{f=1} f{print} f&&/^  ```$/&&!/bash/{exit}')"
  [ -n "$out" ] || { echo "Step 0 stamp fence not found in SKILL.md" >&2; return 1; }
  case "$out" in
    *'T0='*) ;;
    *) echo "Step 0's stamp fence does not stamp T0" >&2; return 1 ;;
  esac
  printf '%s\n' "$out"
}
skill_step0() {
  local out
  out="$(sed -n '/^## Step 0 /,/^## /p' "$REPO_ROOT/development/skills/refine-issue/SKILL.md")"
  [ -n "$out" ] || { echo "Step 0 section not found in SKILL.md" >&2; return 1; }
  printf '%s\n' "$out"
}

@test "Step 7 invokes the builder with only its supported flags (#1005 contract)" {
  local step7 code; step7="$(skill_step7)"; code="$(skill_step7_code)"
  # the path ASSIGNMENT, not just the uses: the uses hold for any value of
  # BUILDER, correct or dangling, and a dangling one loses every record behind
  # the `|| echo` advisory with the whole suite still green.
  assert_contains "$code" 'BUILDER="<skill-base-dir>/scripts/build-refine-telemetry-record.zsh"'
  # the OUTCOME capture as a whole joint: asserting the two halves separately
  # lets the capture be renamed while both needles still match.
  assert_contains "$code" 'OUTCOME="$("$BUILDER" --state "$STATE" --print-outcome)"'
  assert_contains "$code" '"$BUILDER" --state "$STATE" > "$PAYLOAD"'
  # wall_s must be DERIVED, never stamped: `WALL_S=$(date +%s)` would emit an
  # absolute epoch as the duration on every record, and validate.
  assert_contains "$code" 'WALL_S=$(( $(date +%s) - 10#$T0 ))'
  assert_contains "$code" '(( WALL_S >= 0 )) || WALL_S=0'
  # BOTH cleanup sites: the bare needle also matches the mktemp-failure arm
  # (`rm -f … 2>/dev/null`), so deleting the post-emission cleanup — the one
  # that runs on every recorded run — would otherwise stay green.
  assert_contains "$code" 'rm -f "$STATE" "$PAYLOAD" 2>/dev/null'
  assert_eq "$(printf '%s\n' "$code" | grep -c '^ *rm -f "\$STATE" "\$PAYLOAD"$')" 1 "post-emission cleanup"
  assert_contains "$code" 'STATE=$(mktemp) || STATE=""'
  assert_contains "$code" 'PAYLOAD=$(mktemp) || PAYLOAD=""'
  # the branch POLARITY, not just its arms: rewritten `-n … &&`, every SUCCESSFUL
  # allocation would take the "no temp file" arm and no record would ever build,
  # with all 56 tests here still green (they drive the builder/emitter directly,
  # never the fence). The outer `cond` extraction is column-0-anchored and skips
  # this indented `if` entirely.
  assert_contains "$code" 'if [[ -z "$STATE" || -z "$PAYLOAD" ]]; then'
  # the three retired envelope flags must never reappear on a $BUILDER line —
  # the builder rejects them (exit 2) and the record would be lost silently
  local line
  while IFS= read -r line; do
    case "$line" in
      *'$BUILDER'*--issue*|*'$BUILDER'*--ts*|*'$BUILDER'*--wall-s*)
        echo "retired envelope flag on a \$BUILDER line: $line"; return 1 ;;
    esac
  done <<< "$step7"
}

@test "Step 7 passes the emitter every envelope field this stream owns (#1005 contract)" {
  local code flag; code="$(skill_step7_code)"
  # the FULL relative idiom, not just the basename: a wrong depth is a dangling
  # reference that fails at runtime and is swallowed by the `|| echo` advisory
  assert_contains "$code" '"<skill-base-dir>/../../scripts/telemetry/emit-telemetry.zsh"'
  # --issue is the linkage the validator will NOT catch: dropped, `issue` is
  # null, the record still validates and lands, and every refine-issue record
  # silently loses its join to the story it refined.
  for flag in "--pipeline refine-issue" "--kind run" '--outcome "$OUTCOME"' \
              '--repo-dir "$REPO_ROOT"' '--ts "$T0"' '--issue <N>' \
              '--wall-s "$WALL_S"' '--payload "$PAYLOAD"'; do
    assert_contains "$code" "$flag" || { echo "missing emitter flag: $flag"; return 1; }
  done
}

@test "Step 7's emission is never fatal — the { … } || echo wrapper survives (#1005)" {
  # The one Step 7 property whose loss breaks the RUN rather than the telemetry:
  # unwrapped (or `&&`), any emitter hiccup — a full disk, an unappendable sink,
  # a missing jq — would fail the refinement session itself.
  # Against the FENCE: Step 7's prose spells the idiom too (`{ … } || echo
  # <advisory>`), so a section-wide needle passes with the real wrapper deleted.
  local code line; code="$(skill_step7_code)"
  assert_contains "$code" '} || echo "telemetry not recorded for this run (see stderr)'
  # and never the `&&` form, which would fail the RUN on any emitter hiccup
  while IFS= read -r line; do
    case "$line" in
      *'} &&'*) echo "the emission chain must be || not &&: $line"; return 1 ;;
    esac
  done <<< "$code"
}

@test "Step 0 stamps T0 at RUN START, so ts is not emission time (#1005)" {
  # Step 7 passing --ts "$T0" is pinned above, but that is only half the
  # contract: if the T0 assignment migrated into Step 7, --ts would still be
  # there, all the other consistency tests would pass, and `ts` would silently
  # become emission time with wall_s ~0 on every record.
  local code0 code7; code0="$(skill_step0_code)"; code7="$(skill_step7_code)"
  assert_contains "$code0" 'T0=$(date +%s)'
  assert_contains "$code0" 'REPO_ROOT="$(git rev-parse --show-toplevel'
  # the six-variable reset exists so an epic-walk child cannot inherit the
  # previous child's values — a hazard Step 7's guard CANNOT catch, because
  # inherited values are set, merely wrong.
  local v
  for v in STATE_OUTCOME PARK_TYPE RISK ROUNDS RAISED RESOLVED; do
    assert_contains "$code0" "$v=\"\"" || { echo "Step 0 no longer resets $v"; return 1; }
  done
  # `T0=$(date +%s)` prints nothing and each Bash call is a fresh shell, so this
  # echo is the ONLY path by which T0/REPO_ROOT reach Step 7 many tool calls
  # later. Drop it and the guard rejects every run — 100% of the stream lost
  # behind a one-line advisory. Assert the JOINT spelling: a needle on the
  # prefix alone survives both values being dropped from the echo.
  assert_contains "$code0" 'echo "carry into Step 7: T0=$T0 REPO_ROOT=$REPO_ROOT"'
  # any ASSIGNMENT to T0, not just the $(date spelling — T0=$EPOCHSECONDS would
  # silently turn ts into emission time with every other test still passing.
  local line
  while IFS= read -r line; do
    case "$line" in
      *'${T0:'*|*'"$T0"'*|*'10#$T0'*|*T0_RE*) continue ;;
      *T0=*) echo "T0 must be stamped in Step 0, not Step 7: $line"; return 1 ;;
    esac
  done <<< "$code7"
}

@test "Step 7's required-variable guard is present and correctly scoped (#1005)" {
  # The guard IS the "lossy, never fabricated" mechanism (ARCHITECTURE.md): drop
  # it and an unset T0 yields a ~56-year wall_s that validates and lands.
  local code cond; code="$(skill_step7_code)"
  cond="$(printf '%s\n' "$code" | sed -n '/^if \[\[/,/\]\]; then$/p' | tr -d '\\' | tr -s ' \n' ' ')"
  [ -n "$cond" ] || { echo "Step 7's guard condition not found"; return 1; }
  # Both regexes are HOISTED to variables: an unquoted `(a|b)` / `{n,m}` on a
  # `=~` RHS is a bash-only spelling, and this fence runs under whichever shell
  # the session uses. Pin the patterns AND their use.
  assert_contains "$code" "T0_RE='^[0-9]{1,18}\$'"
  assert_contains "$code" "PARK_RE='^(needs-decision|split-recommended|deferred)\$'"
  # The WHOLE condition, by EQUALITY. Substring needles are polarity-blind:
  # `"${T0:-}" =~ $T0_RE` matches both the real `! … =~ …` and an inverted
  # `… =~ …`, so dropping a single `!` inverts the guard — every WELL-FORMED
  # run is then skipped and the entire stream dies behind the one-line advisory
  # with the suite green. Equality also pins the `||` separators, the parked
  # pairing's `&&`, and the `-z "${REPO_ROOT:-}"` conjunct no needle covered.
  assert_eq "$cond" 'if [[ ! "${T0:-}" =~ $T0_RE || -z "${REPO_ROOT:-}" || ! -d "${REPO_ROOT:-/nonexistent}" || -z "${STATE_OUTCOME:-}" || ! "${ROUNDS:-}" =~ ^[0-9]+$ || ! "${RAISED:-}" =~ ^[0-9]+$ || ! "${RESOLVED:-}" =~ ^[0-9]+$ || ( "${STATE_OUTCOME:-}" == "parked" && ! "${PARK_TYPE:-}" =~ $PARK_RE ) ]]; then ' "Step 7 guard condition"
  # RISK must NEVER be guarded: it is null by contract whenever Step 1 produced
  # no verdict, so ANY spelling of a RISK guard suppresses good records. Scope
  # this to the guard's own condition — RISK legitimately appears later in the
  # fence as `--arg risk "${RISK:-}"`.
  case "$cond" in
    *RISK*) echo "RISK must not be in the guard — it is nullable by contract"; return 1 ;;
  esac
  # the guard's OWN advisory, on the guard's own line — not one of the two other
  # "telemetry not recorded" advisories in the same section
  local line found=0
  while IFS= read -r line; do
    case "$line" in
      *echo*"a Step 0 stamp, the run outcome"*) found=1 ;;
    esac
  done <<< "$code"
  [ "$found" -eq 1 ] || { echo "the guard's own skip advisory is missing"; return 1; }
}

@test "Step 7's state jq carries exactly the six keys the builder reads (#1005)" {
  # The joint of the split. The builder DEFAULTS every missing key (0/null), so
  # a renamed or dropped key here does not fail — it silently emits a payload of
  # zeros that validates (payload is OPEN) and lands in the shared sink.
  # Pin the BINDINGS, not just the names: `--arg rounds "$RAISED"` keeps every
  # name present, mislabels every record, and validates (payload is OPEN).
  local code b; code="$(skill_step7_code)"
  for b in '--arg rounds "$ROUNDS"' '--arg raised "$RAISED"' \
           '--arg resolved "$RESOLVED"' '--arg outcome "$STATE_OUTCOME"' \
           '--arg park_type "${PARK_TYPE:-}"' '--arg risk "${RISK:-}"'; do
    assert_contains "$code" "$b" || { echo "state jq binding missing/rewired: $b"; return 1; }
  done
  # the FULL if-expressions: stopping at the condition lets the else-arms be
  # swapped (`else $risk end` under park_type), which mislabels every record and
  # still validates, because `payload` is OPEN by design.
  for b in 'rounds: ($rounds|tonumber)' 'objections_raised: ($raised|tonumber)' \
           'objections_resolved: ($resolved|tonumber)' 'outcome: $outcome' \
           'park_type: (if $park_type == "" then null else $park_type end)' \
           'risk_classification: (if $risk == "" then null else $risk end)'; do
    assert_contains "$code" "$b" || { echo "state jq mapping missing/rewired: $b"; return 1; }
  done
  # and that the state jq actually writes the file the builder is then handed
  assert_contains "$code" '> "$STATE"'
}

@test "Step 7 writes to the SHARED sink — no per-pipeline override survives (#1005)" {
  local step7; step7="$(skill_step7)"
  # --telemetry-file would route this stream back off the shared sink; the only
  # legitimate refine-issue.jsonl mention is the "records written before this
  # retrofit" note, which names it as legacy rather than as a target.
  # positive: the section must NAME the shared sink, not merely omit an override
  assert_contains "$step7" ".claude/telemetry/telemetry.jsonl"
  case "$step7" in
    *--telemetry-file*) echo "Step 7 must not override the shared sink"; return 1 ;;
  esac
  # Scan LINE BY LINE: matching the whole section would let the redirection in
  # the jq/builder chain pair with the legacy note further down and false-fire.
  local line
  while IFS= read -r line; do
    case "$line" in
      *refine-issue.jsonl*)
        case "$line" in
          *'>'*) echo "Step 7 still writes the retired per-pipeline sink: $line"; return 1 ;;
        esac ;;
    esac
  done <<< "$step7"
}

@test "the builder writes NO files — the emitter owns the sink (the split's core claim)" {
  # build_split runs with the cwd bats was invoked from, which is this repo's
  # root and holds a real .claude/telemetry/telemetry.jsonl. So a regression
  # re-adding a relative sink write to the BUILDER would append to the
  # maintainer's own telemetry file with every other test still green. Run it
  # from an isolated cwd and assert it creates nothing at all.
  mkdir -p "$BATS_TEST_TMPDIR/iso"
  put "$READY"
  run zsh -c 'cd "$1" && zsh "$2" --state "$3"' _ "$BATS_TEST_TMPDIR/iso" "$S" "$ST"
  [ "$status" -eq 0 ]
  assert_eq "$(echo "$output" | jq -c 'keys')" "$PAYLOAD_KEYS" "payload keys"
  assert_eq "$(find "$BATS_TEST_TMPDIR/iso" -mindepth 1 | wc -l | tr -d ' ')" 0 "files created by the builder"
}
