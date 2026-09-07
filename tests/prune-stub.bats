#!/usr/bin/env bats
#
# Unit coverage for tests/prune-stub.bash (#1428) — the shared failing-grep
# fixture three suites load.
#
# WHY THIS FILE EXISTS. The helper's happy path is exercised by every caller
# (kubernetes-topic-marker, gather-kubernetes, detect-stack), and each of them
# asserts the `fired` marker — but all of them build into a fresh directory that
# is not yet on PATH, so the helper's own contract is never reached from there:
# neither refusal, the rebuild clearing the marker, nor the `%q` interpolation a
# space-bearing directory needs. Each of those is a mutation the whole suite
# passes without this file (`type -P` back to `command -v`, the self-directory
# guard deleted, `%q` back to `%s`), and each degrades the fixture from "refuses
# visibly" to "execs itself in a loop" in a future caller. So they are pinned
# here, against the helper alone.

bats_require_minimum_version 1.5.0

load assertions
load prune-stub

setup() {
  LIB="$BATS_TEST_DIRNAME/prune-stub.bash"
  D="$BATS_TEST_TMPDIR/stub"
}

# the built stub, driven directly — never from the same shell that built it, so
# an exec loop would surface as a status rather than hang the suite
@test "a delegated grep works through the stub, and the marker stays absent" {
  failing_prune_grep_stub "$D"
  [ -x "$D/grep" ]
  run env "PATH=$D:$PATH" grep -c x "$BATS_TEST_DIRNAME/prune-stub.bash"
  [ "$status" -eq 0 ]
  [ ! -f "$D/fired" ]
}

@test "the /templates/ invocation exits 2, names itself on stderr and writes the marker" {
  failing_prune_grep_stub "$D"
  run --separate-stderr env "PATH=$D:$PATH" grep -v -e /node_modules/ -e /templates/ </dev/null
  [ "$status" -eq 2 ]
  contains "$stderr" 'stub: prune filter failed'
  [ -f "$D/fired" ]
}

@test "a DIR containing a space still delegates and still writes its marker (%q)" {
  local d="$BATS_TEST_TMPDIR/stub dir"
  failing_prune_grep_stub "$d"
  run env "PATH=$d:$PATH" grep -c x "$BATS_TEST_DIRNAME/prune-stub.bash"
  [ "$status" -eq 0 ]
  run env "PATH=$d:$PATH" grep -v -e /templates/ </dev/null
  [ "$status" -eq 2 ]
  [ -f "$d/fired" ]
}

@test "a rebuild clears a marker left by an earlier run" {
  failing_prune_grep_stub "$D"
  run env "PATH=$D:$PATH" grep -v -e /templates/ </dev/null
  [ -f "$D/fired" ]
  failing_prune_grep_stub "$D"
  [ ! -f "$D/fired" ]
}

@test "the builder refuses when DIR is already on PATH, and leaves the stub alone" {
  failing_prune_grep_stub "$D"
  local before
  before="$(cat "$D/grep")"
  # a fresh shell: PATH carries the built stub BEFORE the builder runs, which is
  # the ordering the helper forbids — `type -P grep` now resolves to the stub
  run --separate-stderr bash -c 'PATH="$2:$PATH"; source "$1"; failing_prune_grep_stub "$2"' _ "$LIB" "$D"
  [ "$status" -eq 1 ]
  contains "$stderr" 'activate the stub AFTER building it'
  [ "$(cat "$D/grep")" = "$before" ]
}

@test "the builder resolves an EXECUTABLE grep, not a same-named function" {
  # `command -v grep` would print the bare word `grep` here, and the generated
  # `exec grep "$@"` would then resolve back to the stub through the prepended
  # PATH. `type -P` ignores the function; the exec line must name a real path.
  run bash -c 'grep() { :; }; source "$1"; failing_prune_grep_stub "$2"' _ "$LIB" "$D"
  [ "$status" -eq 0 ]
  local exec_line
  exec_line="$(tail -n 1 "$D/grep")"
  starts_with "$exec_line" 'exec /'
}

@test "the builder refuses with no executable grep on PATH" {
  run --separate-stderr bash -c 'PATH="$3"; source "$1"; failing_prune_grep_stub "$2"' _ "$LIB" "$D" "$BATS_TEST_TMPDIR/empty"
  [ "$status" -eq 1 ]
  contains "$stderr" 'no executable grep on PATH'
  [ ! -e "$D/grep" ]
}

@test "the builder refuses a missing DIR with a usage status" {
  run --separate-stderr failing_prune_grep_stub ""
  [ "$status" -eq 2 ]
  contains "$stderr" 'DIR required'
}
