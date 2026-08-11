# shellcheck shell=bash
# Shared helpers for the Node ops-api acceptance cases (#936).
#
# Sourced by tests/acceptance/rest/*.bats and tests/acceptance/cli/*.bats.
#
# The directive above is mandatory, not decoration: this is a shebang-LESS
# library that bats `load`s, so shellcheck cannot infer the dialect and would
# report SC2148 (error) and read every `local` as POSIX-sh. ARCHITECTURE.md's
# "Exception — the bats suite" and .pre-commit-config.yaml's header both state the
# rule for this artifact class.

# OPS_SCRUB — the `env -u` flags that clear every variable the payload READS.
#
# Two cases here are claims about a variable being UNSET
# (tc-error-missing-git-sha-fails-fast, tc-happy-version-falls-back-to-package-json),
# and this repo's own docs tell adopters to export $GIT_SHA at build time — so a
# developer or CI shell that has one silently defeats them: the first boots
# instead of refusing, the second reports the wrong version. An inherited
# OTEL_EXPORTER_OTLP_PROTOCOL of "http/json" TOGETHER WITH an inherited endpoint
# is a hard startup throw, which would red the whole suite for a reason that has
# nothing to do with the change. (The protocol alone throws nothing —
# newOtlpExporter returns early when no endpoint is set — which is why all four
# variables are scrubbed as one unit rather than the protocol on its own.)
#
# An ARRAY rather than a string the callers word-split: `env $(fn)` is the shape
# SC2046 flags, and silencing that warning would trade a real quoting guard for
# one convenience. Each caller's own `VAR=value` arguments are expanded AFTER
# these flags, so they still win.
#
# (A comment line may not BEGIN with the word shellcheck — the linter parses that
# as a directive and errors out on the prose, SC1073.)
OPS_SCRUB=(
  -u GIT_SHA -u BUILD_VERSION -u OPS_PORT
  -u OTEL_EXPORTER_OTLP_ENDPOINT -u OTEL_EXPORTER_OTLP_METRICS_ENDPOINT
  -u OTEL_EXPORTER_OTLP_PROTOCOL -u OTEL_EXPORTER_OTLP_METRICS_PROTOCOL
)

# ops_provision — build the sandbox. Called ONCE per file from setup_file, and
# allowed to fail the whole file: a missing toolchain must be loud, never skipped.
#
# `--suite` is what gives each test FILE its own sandbox directory. Provisioning
# prunes `src/` and `dist/` before recompiling, so a shared directory means the
# rest suite's prune can land while the cli suite's fixtures are executing
# `node dist/main.js` — a module-not-found crash that reads as a payload
# regression. The provisioner prints the directory it chose, and that value (not
# a second, independently recomputed path) is what the tests use.
ops_provision() {
  local root
  root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)" || return 1
  OPS_SANDBOX_DIR="$(zsh "$root/tests/acceptance/lib/node-ops-sandbox.zsh" \
    --suite "$BATS_TEST_FILENAME")" || return 1
  [ -n "$OPS_SANDBOX_DIR" ] || {
    echo "node-ops-sandbox.zsh printed no sandbox path" >&2
    return 1
  }
  export OPS_SANDBOX_DIR
}

# ops_sandbox — per-test paths. Deliberately does NOT re-provision: setup_file
# already did, and re-running the tsc build per test would multiply the suite's
# runtime by the test count for no signal.
ops_sandbox() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck disable=SC2034  # read by the .bats files that `load` this library
  CHECKER="$REPO_ROOT/development/skills/bootstrap/templates/common/scripts/check-ops-conformance.zsh"
  # The checker is handed to four tests; guard it here rather than letting a
  # rename surface as `zsh: no such file` in three of them and as a PASSING
  # negative assertion in the fourth.
  [ -f "$CHECKER" ] || {
    echo "checker not found: $CHECKER" >&2
    return 1
  }
  # From setup_file's provisioner, never recomputed here: the sandbox path is
  # per-suite, and two independent derivations of it are two things that can drift.
  SANDBOX="${OPS_SANDBOX_DIR:-}"
  [ -n "$SANDBOX" ] || {
    echo "OPS_SANDBOX_DIR is unset — setup_file's ops_provision did not run" >&2
    return 1
  }
  # The build artifact, not just the directory: a sandbox whose tsc step failed
  # would otherwise surface as one confusing "fixture did not come up" failure per
  # test in the file.
  [ -f "$SANDBOX/dist/main.js" ] || {
    echo "sandbox build artifact missing: $SANDBOX/dist/main.js — provisioning failed" >&2
    return 1
  }
  # Set here rather than in each starter, so it is defined in the TEST's shell.
  # `run` and `$(…)` both execute in a SUBSHELL, so a variable a helper assigns
  # there never reaches the assertions below it — which is exactly how an empty
  # $OPS_LOG turns a real failure into `grep: : No such file or directory`.
  OPS_LOG="$BATS_TEST_TMPDIR/ops.log"
  PORT="$(ops_port)" || return 1
  BASE="http://127.0.0.1:$PORT"
}

# ops_port — a per-test port from an EXPLICIT per-file band.
#
# BATS_TEST_NUMBER restarts at 1 in every file, so the index alone would give the
# rest suite's test 1 and the cli suite's test 1 the same port — and the README's
# own invocation runs both files in one command. Under `--jobs` (or the #243 tier
# this is written for) one fixture wins the bind and the other's serve() rejects
# with EADDRINUSE, which reads as a payload regression. A per-file band also
# restores the leaked-process signal the per-test port is for: a listener left
# behind by the sibling suite can no longer answer this one's requests.
#
# The band is a REGISTERED CONSTANT, not a hash of $BATS_TEST_FILENAME. A hash
# collides — and because it hashes an absolute path, whether it collides depends
# on where the repo happens to be checked out, so the flake it reintroduces is
# exactly the EADDRINUSE this function exists to prevent AND is unreproducible on
# another machine. An unregistered file fails loudly instead of silently sharing.
ops_port() {
  local key band
  key="$(basename "$(dirname "$BATS_TEST_FILENAME")")/$(basename "$BATS_TEST_FILENAME")"
  case "$key" in
    rest/ops-api-node.bats) band=0 ;;
    cli/ops-api-node.bats) band=1 ;;
    *)
      echo "ops_port: no port band registered for '$key' — add one here before adding an acceptance file" >&2
      return 1
      ;;
  esac
  # The stride is 100, so a file would have to grow past 99 tests to spill into
  # its neighbour. Say so rather than letting it happen silently.
  if [ "$BATS_TEST_NUMBER" -gt 99 ]; then
    echo "ops_port: '$key' has more than 99 tests — widen the stride below" >&2
    return 1
  fi
  echo $(( 9500 + band * 100 + BATS_TEST_NUMBER ))
}

# ops_start <scenario> [VAR=value ...] — start the fixture and block until it
# answers, setting OPS_PID. Returns non-zero (with the log on stderr) if it never
# comes up, so a startup regression fails the test rather than timing out in curl.
#
# It does NOT set BASE/PORT/OPS_LOG — `ops_sandbox` owns those, and deliberately,
# because a starter running in a subshell could not export them into the test's
# shell. Call ops_sandbox from `setup` before any ops_start.
ops_start() {
  local scenario="$1"; shift
  # BEFORE launching anything: the port must be ours. The readiness poll below
  # cannot tell our fixture from someone else's listener, so without this a
  # fixture leaked by an interrupted run answers the very first probe, ops_start
  # returns 0, and every assertion then runs against a STALE process — the
  # previous run's scenario, the previous run's compiled payload. When the
  # scenario happens to match, that is a green acceptance result about a build
  # that is not in the working tree.
  require_port_free "$PORT" "the fixture's own management port" || return 1
  # Two details here are load-bearing, and both cause the SAME symptom — the suite
  # hangs with every test already passed:
  #
  #   * `exec`, so $! is the NODE process. Backgrounding a `cd X && env … node …`
  #     compound gives you the PID of the wrapping SUBSHELL, and killing that
  #     leaves node orphaned but alive — while bats waits for every descendant.
  #   * `3>&-`, because bats keeps its own status pipe on fd 3 and a long-lived
  #     background process inherits it; bats then blocks waiting for that pipe to
  #     close. Closing fd 3 for the fixture is the documented fix.
  #
  # The script argument is ABSOLUTE even though we just `cd`'d into the sandbox.
  # `pgrep -f` matches a process's argv, and node-ops-sandbox.zsh refuses to prune
  # a sandbox a fixture is running out of by grepping for exactly this path — a
  # relative `dist/main.js` never appears in argv, so the guard would silently
  # never match. The `cd` stays: it is what makes the payload's package.json walk
  # find the sandbox manifest.
  ( cd "$SANDBOX" && exec env "${OPS_SCRUB[@]}" "$@" SCENARIO="$scenario" OPS_PORT="$PORT" \
      node "$SANDBOX/dist/main.js" > "$OPS_LOG" 2>&1 3>&- ) &
  OPS_PID=$!
  for _ in $(seq 1 80); do
    if curl -fsS -o /dev/null --max-time 2 "$BASE/health/live" 2>/dev/null; then
      # Something answered — but the precheck above only proved the port was free
      # BEFORE we launched. Confirm the answer is coming from the child we
      # started, not from a process that grabbed the port in between.
      kill -0 "$OPS_PID" 2>/dev/null && return 0
      echo "something else is serving port $PORT — our fixture is already gone" >&2
      ops_dump_log
      return 1
    fi
    # A process that has already exited will never come up — report immediately
    # rather than burning the whole timeout on it.
    kill -0 "$OPS_PID" 2>/dev/null || break
    sleep 0.25
  done
  # Name a port clash for what it is. Without this the single most likely
  # ENVIRONMENT fault — something else already on $PORT — is reported in the same
  # words as a payload startup regression, and the reader debugs the wrong thing.
  if [ -s "${OPS_LOG:-}" ] && grep -q 'EADDRINUSE' "$OPS_LOG"; then
    echo "port $PORT is already in use — this is a PORT CLASH, not a payload failure" >&2
    echo "(a leaked fixture from an interrupted run, or another process on that port)" >&2
  fi
  echo "fixture did not come up (scenario=$scenario, port=$PORT):" >&2
  ops_dump_log
  return 1
}

# ops_dump_log — show the fixture's output, or say why there is none.
#
# The redirection that creates $OPS_LOG is attached to the exec'd command, so a
# failed `cd "$SANDBOX"` short-circuits before the file exists — and a bare `cat`
# would then print "No such file or directory" in place of the diagnosis.
ops_dump_log() {
  if [ -s "${OPS_LOG:-}" ]; then
    cat "$OPS_LOG" >&2
  else
    echo "(no fixture output — did the sandbox directory disappear?)" >&2
  fi
}

# ops_terminate_within <seconds> — SIGTERM the fixture and ASSERT it exits
# CLEANLY inside that budget. `ops_stop` below only cleans up.
#
# What it proves: the process was alive, took SIGTERM, and exited with status 0
# within the budget. A `close()` that rejects (the payload propagates that), a
# `provider.shutdown()` that throws, or a handler that never resolves each fail
# it — and none of them is visible to the teardown, which SIGKILLs after a second
# and discards the result.
#
# What it does NOT prove: that `server.closeIdleConnections()` is present. That
# was measured on Node 26 — `server.close()` already releases idle keep-alive
# sockets there, so the drain finishes in 0s with the call deleted. The payload
# keeps it for runtimes where close() waits instead, and the STRUCTURAL needle in
# tests/ops-api-language-payloads.bats is what guards it. Do not read this helper
# as covering that.
#
# Leaves OPS_PID cleared on success, so the teardown's ops_stop is then a no-op.
ops_terminate_within() {
  local budget="$1" waited=0 ticks rc
  [ -n "${OPS_PID:-}" ] || {
    echo "ops_terminate_within: nothing running" >&2
    return 1
  }
  # A `kill … || true` here would swallow "no such process", the first kill -0
  # below would fail, and the function would report a clean drain for a fixture
  # that had already crashed — a green verdict on a SIGTERM never delivered.
  kill -0 "$OPS_PID" 2>/dev/null || {
    echo "ops_terminate_within: the fixture was already gone before SIGTERM" >&2
    ops_dump_log
    return 1
  }
  kill -TERM "$OPS_PID" || {
    echo "ops_terminate_within: could not signal $OPS_PID" >&2
    return 1
  }
  ticks=$(( budget * 20 ))
  while [ "$waited" -lt "$ticks" ]; do
    kill -0 "$OPS_PID" 2>/dev/null || {
      # The EXIT STATUS is half the verdict. The fixture's handler is
      # `void running.close().then(() => process.exit(0))`, so a close() that
      # rejects (the payload propagates that) or a provider.shutdown() that
      # throws leaves an unhandled rejection and a non-zero exit — a drain that
      # did NOT complete cleanly, which `wait … || true` would report as success.
      rc=0
      wait "$OPS_PID" 2>/dev/null || rc=$?
      OPS_PID=""
      [ "$rc" -eq 0 ] || {
        echo "fixture exited $rc on SIGTERM — the drain did not complete cleanly" >&2
        ops_dump_log
        return 1
      }
      return 0
    }
    sleep 0.05
    waited=$(( waited + 1 ))
  done
  echo "fixture did not exit within ${budget}s of SIGTERM — the graceful drain did not complete" >&2
  ops_dump_log
  return 1
}

# ops_stop — stop whatever ops_start launched. Safe to call when nothing ran.
#
# SIGTERM first, so a fixture that drains cleanly is not killed for no reason.
# This is CLEANUP, not an assertion: it deliberately ignores the outcome, because
# bats waits for every descendant and a fixture that failed to drain would
# otherwise hang the suite with all tests already passed. The SIGKILL fallback
# bounds that at a second. The drain itself is asserted by
# `ops_terminate_within` above, in a test that says so.
ops_stop() {
  [ -n "${OPS_PID:-}" ] || return 0
  kill "$OPS_PID" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$OPS_PID" 2>/dev/null || break
    sleep 0.05
  done
  kill -9 "$OPS_PID" 2>/dev/null || true
  wait "$OPS_PID" 2>/dev/null || true
  OPS_PID=""
}

# ops_run_expect_exit <scenario> [VAR=value ...] — run the fixture to COMPLETION,
# setting OPS_STATUS to its exit code and leaving its output in $OPS_LOG. For the
# startup-failure cases, where nothing is ever supposed to bind.
#
# Call it DIRECTLY, never through `run` or `$(…)`: both run in a subshell, so
# OPS_STATUS would be assigned in a shell the assertions never see.
#
# It is BOUNDED. Running it in the foreground would be simpler, but the whole
# point of these two cases is that the fixture must REFUSE to start — so if the
# payload regresses in exactly the direction under test, it binds and serves
# forever and the suite hangs with no output and no timeout. A bounded wait turns
# that regression into the red test it should be.
ops_run_expect_exit() {
  local scenario="$1"; shift
  # Same precheck as ops_start, for a sharper reason: these cases assert a
  # NON-ZERO exit, and an occupied port produces one for an EADDRINUSE reason
  # that has nothing to do with the claim — so the status assertion would pass
  # while the message grep and the port check red, handing the reader two
  # confusing symptoms instead of "port clash".
  require_port_free "$PORT" "the port the fixture must refuse to bind" || return 1
  OPS_STATUS=0
  ( cd "$SANDBOX" && exec env "${OPS_SCRUB[@]}" "$@" SCENARIO="$scenario" OPS_PORT="$PORT" \
      node "$SANDBOX/dist/main.js" > "$OPS_LOG" 2>&1 3>&- ) &
  local pid=$!
  for _ in $(seq 1 80); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "fixture did NOT exit (scenario=$scenario) — it was supposed to refuse to start:" >&2
    ops_dump_log
    return 1
  fi
  # shellcheck disable=SC2034  # asserted by the .bats files that `load` this library
  wait "$pid" 2>/dev/null || OPS_STATUS=$?
  # A non-zero exit is what these cases assert, so an EADDRINUSE one would look
  # like a pass on the status line. Name it here too, for the same reason
  # ops_start does.
  if [ -s "${OPS_LOG:-}" ] && grep -q 'EADDRINUSE' "$OPS_LOG"; then
    echo "port $PORT is already in use — the fixture exited on a PORT CLASH, not on the startup check under test" >&2
  fi
}

# The three response readers. Each still PRINTS its value and leaves the verdict
# to the caller's assertion — but each also says so when curl itself failed.
#
# Without that, a fixture that dies after ops_start returned (an uncaught
# rejection, an OOM kill) surfaces as `[ "000" = "200" ]`, or — worse, for
# http_body — as `jq -r .build.version <<< ""`, which prints nothing and exits 0,
# making a dead fixture indistinguishable from a service that served a body
# without that field. The log holding the actual reason is never shown. They
# still fail closed either way; this is about naming the cause.
ops_curl_failed() {
  echo "curl rc=$1 for $2 — the fixture may have died mid-test" >&2
  ops_dump_log
}

# http_code <url> — the response status alone.
http_code() {
  local rc=0 out
  out="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1")" || rc=$?
  [ "$rc" -eq 0 ] || ops_curl_failed "$rc" "$1"
  printf '%s' "$out"
}

# http_body <url> — the response body alone.
http_body() {
  local rc=0 out
  out="$(curl -s --max-time 5 "$1")" || rc=$?
  [ "$rc" -eq 0 ] || ops_curl_failed "$rc" "$1"
  printf '%s' "$out"
}

# http_ctype <url> — the response content type alone.
http_ctype() {
  local rc=0 out
  out="$(curl -s -o /dev/null -w '%{content_type}' --max-time 5 "$1")" || rc=$?
  [ "$rc" -eq 0 ] || ops_curl_failed "$rc" "$1"
  printf '%s' "$out"
}

# port_is_closed <port> — nothing is LISTENING there. Used for the four
# "no second listener" assertions, which are claims about ABSENCE.
#
# The verdict is the CONNECTION, never the HTTP status. `curl -f` exits 22 on any
# 4xx, and every listener this suite probes answers 404 on `/` — the ops surface's
# own catch-all does, and the OTel Prometheus exporter serves only /metrics — so a
# `-f`-based check would report a live second listener as "closed" and every one
# of these assertions would pass through exactly the regression it targets.
# curl exit 7 is "couldn't connect"; anything else means something answered.
port_is_closed() {
  local rc=0
  curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$1/" 2>/dev/null || rc=$?
  [ "$rc" -eq 7 ]
}

# checker_passed <checker-output> <endpoint> — the checker reported PASS for that
# one endpoint.
#
# A named helper rather than an inline `[[ $out == *…* ]]`: the repo's
# inert-assertion guard (#1011) flags a bare `[[ ]]` in a test body because it
# passes even when false, and a named function is the sanctioned fix.
#
# The trailing `[[:space:]]` is load-bearing: without it `/health` would also
# match the `/health/live` and `/health/ready` lines, so three of the five
# endpoint assertions would be satisfied by a single line and the test would stay
# green with two endpoints unchecked. Leading whitespace is tolerated because the
# checker indents and column-aligns its report, and pinning that alignment would
# red this suite on a cosmetic change to the checker's output.
checker_passed() {
  printf '%s\n' "$1" | grep -qE "^[[:space:]]*$2[[:space:]]+PASS([[:space:]]|\$)"
}

# checker_failed <checker-output> <reason-substring> — the checker rejected the
# service FOR THAT REASON.
#
# A bare `[ "$status" -ne 0 ]` is not this assertion: it is equally satisfied by
# exit 127 (the checker was renamed), by the checker's exit-2 usage/tooling class
# (no jq, no curl), and by "service unreachable" — none of which prove the verdict
# under test. Callers pair this with `[ "$status" -eq 1 ]`, the checker's
# documented conformance-failure code, so the tooling class is excluded too.
#
# Matched LITERALLY (grep -F): the checker's messages carry quotes, parentheses
# and slashes, all of which a regex would reinterpret.
checker_failed() {
  printf '%s\n' "$1" | grep -qF -- "$2"
}

# require_port_free <port> <what-binds-it> — fail with an ENVIRONMENT diagnosis
# when a fixed, machine-global port is already occupied.
#
# Some absence assertions cannot be salted per test: the OTel Prometheus
# exporter's default is 9464 wherever it runs, so `port_is_closed 9464` is only
# meaningful on a host where nothing else holds it. Without this precheck an
# unrelated local service turns that case red in the same words as a genuine
# regression. Call it from setup_file, so the diagnosis appears once.
require_port_free() {
  port_is_closed "$1" && return 0
  echo "port $1 is already occupied on this host, so the '$2' absence check cannot run." >&2
  echo "Stop whatever is bound there (it is not this fixture — nothing has started yet) and re-run." >&2
  return 1
}

# not_our_ops_surface <port> <expected-git-sha> — our ops surface is NOT reachable
# there.
#
# The honest form of the "not on the app port" claim. A bare `port_is_closed 8080`
# says "nothing on this machine listens on 8080", which is a statement about the
# HOST: the fixture binds exactly one port, so no payload regression can ever make
# 8080 answer, while any local dev server, container publish or JVM makes it fail.
# This asserts what the case actually means — whatever may be listening there, it
# is not this service's build data — so it stays falsifiable for the payload and
# immune to unrelated processes.
not_our_ops_surface() {
  local body sha
  port_is_closed "$1" && return 0
  body="$(curl -s --max-time 2 "http://127.0.0.1:$1/info" 2>/dev/null || true)"
  # Something answered but served no body — whatever it is, it is not an ops
  # surface, so the claim holds.
  [ -n "$body" ] || return 0
  sha="$(jq -r '.build.git_sha // empty' <<< "$body" 2>/dev/null || true)"
  [ "$sha" != "$2" ]
}
