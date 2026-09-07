#!/usr/bin/env bats
#
# Unit coverage for tests/marker-find-stub.bash (#1393) — the shared
# failing-find fixture three suites load. `marker_find` below drives the stub
# with the marker recipes' own operand shape, since the intercept keys on the
# `kustomization.yml` spelling inside it.
#
# WHY THIS FILE EXISTS. The helper's happy path is exercised by every caller
# (kubernetes-topic-marker, gather-kubernetes, detect-stack), and each of them
# asserts the `fired` marker — but all of them build into a fresh directory that
# is not yet on PATH, so the helper's own contract is never reached from there:
# none of the three refusals, the executable-not-function resolution, the
# rebuild clearing the marker, the output-preserving shape of the intercept,
# nor the `%q` interpolation a space-bearing path needs. Each of those is a
# mutation the whole suite passes without this file (e.g. `type -P` back to
# `command -v`, the self-directory guard deleted, the `DIR required` usage
# exit downgraded to 0, `%q` back to `%s`, the real find dropped from the
# intercept), and each degrades the fixture from "refuses visibly" to "execs
# itself in a loop" — or from "a walk that died after printing" to "a walk
# that printed nothing", which is a different branch of every ladder it
# feeds. So they are pinned here, against the helper alone.

bats_require_minimum_version 1.5.0

load assertions
load marker-find-stub

setup() {
  LIB="$BATS_TEST_DIRNAME/marker-find-stub.bash"
  D="$BATS_TEST_TMPDIR/stub"
  W="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$W/charts/app"
  printf 'apiVersion: v2\nname: app\nversion: 0.1.0\n' > "$W/charts/app/Chart.yaml"
}

# the marker recipes' own operand shape — the intercept keys on the
# `kustomization.yml` spelling inside it, and the fixture's Chart.yaml is what
# the preserved output then names
marker_find() { find "$@" \( -name Chart.yaml -o -name kustomization.yaml -o -name kustomization.yml -o -name Kustomization \) ! -type d -print; }

# the built stub, driven directly — never from the same shell that built it, so
# an exec loop would surface as a status rather than hang the suite
@test "a delegated find works through the stub, and the marker stays absent" {
  failing_marker_find_stub "$D"
  [ -x "$D/find" ]
  run env "PATH=$D:$PATH" find "$W" -name '*.yaml'
  [ "$status" -eq 0 ]
  contains "$output" 'charts/app/Chart.yaml'
  [ ! -f "$D/fired" ]
}

@test "the marker-shaped invocation exits 1, KEEPS its output, names itself on stderr and writes the marker" {
  failing_marker_find_stub "$D"
  run --separate-stderr env "PATH=$D:$PATH" bash -c "$(declare -f marker_find); marker_find '$W'"
  [ "$status" -eq 1 ]
  # the walk's real output survives — the intercept is "died after printing",
  # not "printed nothing", and every caller's hit-stands / truncated-list
  # branch depends on that shape
  contains "$output" 'charts/app/Chart.yaml'
  contains "$stderr" 'stub: marker find failed'
  [ -f "$D/fired" ]
}

@test "a Chart.yaml-only find is DELEGATED — the key is kustomization.yml, not Chart.yaml" {
  # detect-stack.sh's detection_confidence probe finds `-name 'Chart.yaml'`
  # ahead of the marker block; a stub keyed on Chart.yaml would intercept that
  # probe first, write `fired` from the wrong find, and fail its pipeline
  failing_marker_find_stub "$D"
  run env "PATH=$D:$PATH" find "$W" -name Chart.yaml
  [ "$status" -eq 0 ]
  contains "$output" 'charts/app/Chart.yaml'
  [ ! -f "$D/fired" ]
}

@test "a DIR containing a space still delegates and still writes its marker (%q)" {
  local d="$BATS_TEST_TMPDIR/stub dir"
  failing_marker_find_stub "$d"
  run env "PATH=$d:$PATH" find "$W" -name '*.yaml'
  [ "$status" -eq 0 ]
  run env "PATH=$d:$PATH" bash -c "$(declare -f marker_find); marker_find '$W'"
  [ "$status" -eq 1 ]
  contains "$output" 'charts/app/Chart.yaml'
  [ -f "$d/fired" ]
}

@test "a REAL find living on a space-bearing PATH entry still delegates and still intercepts (%q)" {
  # the other two %q sites: the real find's path is interpolated twice — in the
  # intercept branch and on the exec line — and the DIR test above cannot reach
  # either, because the host's real find (`type -P find`) has no space in its
  # path. Resolve `type -P find` through a shim in a directory with a space,
  # so an interpolation that regressed to %s word-splits it — on the exec line
  # every delegated find becomes a 127; in the intercept branch the status
  # stays 1 but the preserved output is lost, which the output assertion below
  # catches.
  local bin="$BATS_TEST_TMPDIR/real bin" realfind
  realfind="$(type -P find)"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$realfind" > "$bin/find"
  chmod +x "$bin/find"
  run bash -c 'PATH="$3:$PATH"; source "$1"; failing_marker_find_stub "$2"' _ "$LIB" "$D" "$bin"
  [ "$status" -eq 0 ]
  local exec_line
  exec_line="$(tail -n 1 "$D/find")"
  contains "$exec_line" 'real\ bin/find'
  # delegated: the exec-line %q
  run env "PATH=$D:$bin:$PATH" find "$W" -name '*.yaml'
  [ "$status" -eq 0 ]
  contains "$output" 'charts/app/Chart.yaml'
  # intercepted: the intercept-branch %q, output preserved
  run env "PATH=$D:$bin:$PATH" bash -c "$(declare -f marker_find); marker_find '$W'"
  [ "$status" -eq 1 ]
  contains "$output" 'charts/app/Chart.yaml'
  [ -f "$D/fired" ]
}

@test "a rebuild clears a marker left by an earlier run" {
  failing_marker_find_stub "$D"
  run env "PATH=$D:$PATH" bash -c "$(declare -f marker_find); marker_find '$W'"
  [ -f "$D/fired" ]
  failing_marker_find_stub "$D"
  [ ! -f "$D/fired" ]
}

@test "the builder refuses when DIR is already on PATH, and leaves the stub alone" {
  failing_marker_find_stub "$D"
  local before
  before="$(cat "$D/find")"
  # a fresh shell: PATH carries the built stub BEFORE the builder runs, which is
  # the ordering the helper forbids — `type -P find` now resolves to the stub
  run --separate-stderr bash -c 'PATH="$2:$PATH"; source "$1"; failing_marker_find_stub "$2"' _ "$LIB" "$D"
  [ "$status" -eq 1 ]
  contains "$stderr" 'activate the stub AFTER building it'
  [ "$(cat "$D/find")" = "$before" ]
}

@test "the builder resolves an EXECUTABLE find, not a same-named function" {
  # `command -v find` would print the bare word `find` here, and the generated
  # `exec find "$@"` would then resolve back to the stub through the prepended
  # PATH. `type -P` ignores the function; the exec line must name a real path.
  run bash -c 'find() { :; }; source "$1"; failing_marker_find_stub "$2"' _ "$LIB" "$D"
  [ "$status" -eq 0 ]
  local exec_line
  exec_line="$(tail -n 1 "$D/find")"
  starts_with "$exec_line" 'exec /'
}

@test "the builder refuses with no executable find on PATH" {
  run --separate-stderr bash -c 'PATH="$3"; source "$1"; failing_marker_find_stub "$2"' _ "$LIB" "$D" "$BATS_TEST_TMPDIR/empty"
  [ "$status" -eq 1 ]
  contains "$stderr" 'no executable find on PATH'
  [ ! -e "$D/find" ]
}

@test "the builder refuses a missing DIR with a usage status" {
  run --separate-stderr failing_marker_find_stub ""
  [ "$status" -eq 2 ]
  contains "$stderr" 'DIR required'
}
