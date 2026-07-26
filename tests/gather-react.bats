#!/usr/bin/env bats
#
# Behavioral tests for gather-react-findings.zsh (epic #686, #956): the React topic
# gather. v0.1 emits an intentionally EMPTY tool universe on the v2 gather contract
# (tooling_configured / findings_by_tool / coverage / notes), mirroring
# tests/gather-docs.bats.
#
# The emptiness is the contract under test, not an absence of behaviour: topic
# support is gated on gather-script PRESENCE, so this script existing and exiting 0
# is exactly what moves `react` from unsupported_topics into supported_topics. A
# non-empty `notes` is required so an empty payload reads as the positive statement
# "this topic has no tools yet" rather than as a crash.
#
# No `git init` here: unlike the docs gather (which shells out to detect-stack),
# this script never touches git, so a repo fixture would only import the host's
# global git config without any assertion behind it.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-react-findings.zsh"
  W="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$W"
}

# a minimal React fixture repo
react_fixture() {
  jq -n '{name: "app", dependencies: {react: "19.0.0"}}' > "$W/package.json"
}
gather() { zsh "$GATHER" "$W"; }

@test "the gather script exists and is executable (topic support is gated on its presence)" {
  [ -f "$GATHER" ]
  [ -x "$GATHER" ]
}

@test "a React fixture yields a well-formed v2 payload and exit 0" {
  react_fixture
  run gather
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
}

@test "tooling_configured is an empty OBJECT (the deliberate v0.1 empty tool universe)" {
  react_fixture
  run gather
  [ "$status" -eq 0 ]
  # == {} already excludes an array, null or a missing key (jq -e exits 1 on false)
  echo "$output" | jq -e '.tooling_configured == {}' >/dev/null
}

@test "findings_by_tool is an empty OBJECT" {
  react_fixture
  run gather
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings_by_tool == {}' >/dev/null
}

@test "coverage is null (a topic has no test suite of its own)" {
  react_fixture
  run gather
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.coverage == null' >/dev/null
}

@test "notes is NON-empty and explains the empty universe, so it never reads as a crash" {
  react_fixture
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.notes | length')" -gt 0 ]
  notes="$(echo "$output" | jq -r '.notes | join(" ")')"
  contains "$notes" 'empty by design'
  # pins the builder's map(select(length > 0)): without it printf's trailing
  # newline yields a trailing "" element, which every other notes assertion
  # (length > 0, join substrings, type checks) happily accepts
  echo "$output" | jq -e 'all(.notes[]; length > 0)' >/dev/null
}

@test "notes names the slices that add tools (#957-#960), so a reader knows what fills it" {
  react_fixture
  run gather
  [ "$status" -eq 0 ]
  notes="$(echo "$output" | jq -r '.notes | join(" ")')"
  contains "$notes" '#957'
  contains "$notes" '#958'
  contains "$notes" '#959'
  contains "$notes" '#960'
}

@test "the payload carries exactly the four v2 gather keys (order-independent)" {
  react_fixture
  run gather
  [ "$status" -eq 0 ]
  # sorted, so reordering the jq -n template is not a spurious failure; the real
  # contract is 'exactly these four keys', which consumers read by name
  [ "$(echo "$output" | jq -r 'keys | join(",")')" = "coverage,findings_by_tool,notes,tooling_configured" ]
}

@test "the payload is byte-identical on a React and a NON-React repo — the marker gates dispatch, not the gather" {
  # the gather makes no detection claim, so it must not differ per repo shape.
  # comparing whole normalised payloads (not three fields) also covers `notes`,
  # the one free-form field where repo-dependent text could creep in.
  react_fixture
  run gather
  [ "$status" -eq 0 ]
  react_payload="$(echo "$output" | jq -S -c '.')"

  rm -f "$W/package.json"
  printf '# readme\n' > "$W/README.md"
  run gather
  [ "$status" -eq 0 ]
  bare_payload="$(echo "$output" | jq -S -c '.')"

  [ "$react_payload" = "$bare_payload" ]
}

@test "defaults to the current directory when no repo path is given" {
  # NOTE: while the tool universe is empty the payload is repo-independent, so this
  # can only catch argument handling that ERRORS (e.g. a bare $1 under set -u).
  # Strengthen it when #957-#960 make the payload repo-dependent.
  react_fixture
  cd "$W"
  run zsh "$GATHER"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
}

@test "a non-directory path is a usage error (exit 2) with NO payload on stdout" {
  run --separate-stderr zsh "$GATHER" "$W/does-not-exist"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'not a directory'
}

@test "a FILE passed as the repo path is also a usage error (exit 2) with NO payload on stdout" {
  printf 'x\n' > "$W/afile"
  run --separate-stderr zsh "$GATHER" "$W/afile"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'not a directory'
}

@test "a missing jq is the documented RUNTIME error (exit 3), not a silent empty payload" {
  # the script's own guard: without this test, deleting `command -v jq` would
  # redden nothing, and the failure would surface as a bare set -e abort
  react_fixture
  stub="$BATS_TEST_TMPDIR/nojq"
  mkdir -p "$stub"
  zsh_bin="$(command -v zsh)"
  run --separate-stderr env PATH="$stub" "$zsh_bin" "$GATHER" "$W"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'jq not found'
}

@test "extra arguments are a usage error (exit 2)" {
  react_fixture
  run --separate-stderr zsh "$GATHER" "$W" extra
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'too many arguments'
}

@test "an explicitly EMPTY argument is a usage error, not a silent fallback to the cwd" {
  # guards the deliberate ${1-.} vs ${1:-.} choice: a regression to ${1:-.} would
  # make '' succeed against the orchestrator's cwd with nothing reddening
  run --separate-stderr zsh "$GATHER" ""
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'empty repo path'
}

@test "a FAILING jq is mapped onto exit 3, not allowed to abort with jq's own status 2" {
  # the header's stated reason for the mapping: jq's own 2 would be
  # indistinguishable from this script's documented 'not a directory' usage error
  react_fixture
  stub="$BATS_TEST_TMPDIR/badjq"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 2\n' > "$stub/jq"
  chmod +x "$stub/jq"
  zsh_bin="$(command -v zsh)"
  run --separate-stderr env PATH="$stub:$PATH" "$zsh_bin" "$GATHER" "$W"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  # name the specific guard: a bare 'jq failed' matches BOTH mappings and so cannot
  # tell which one fired (this stub fails every call, so it is the notes builder)
  contains "$stderr" 'jq failed building notes'
}

@test "a jq that fails only on the PAYLOAD call is also mapped onto exit 3" {
  # the second mapping, reachable only with a selective stub — the all-failing stub
  # above dies at the notes builder and never reaches it
  react_fixture
  real_jq="$(command -v jq)"
  stub="$BATS_TEST_TMPDIR/selectivejq"
  mkdir -p "$stub"
  cat > "$stub/jq" <<EOF
#!/bin/sh
case "\$*" in
  *--argjson*) exit 2 ;;
  *) exec "$real_jq" "\$@" ;;
esac
EOF
  chmod +x "$stub/jq"
  zsh_bin="$(command -v zsh)"
  run --separate-stderr env PATH="$stub:$PATH" "$zsh_bin" "$GATHER" "$W"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'jq failed emitting the payload'
}

@test "an unenterable repo directory is exit 3 (the documented 'could not be entered' cause)" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  locked="$BATS_TEST_TMPDIR/locked"
  mkdir -p "$locked"
  chmod 000 "$locked"
  run --separate-stderr zsh "$GATHER" "$locked"
  chmod 755 "$locked"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'cannot enter'
}

@test "notes is an ARRAY OF STRINGS (a bare string would satisfy length and join)" {
  react_fixture
  run gather
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.notes | type == "array"' >/dev/null
  echo "$output" | jq -e 'all(.notes[]; type == "string")' >/dev/null
}

@test "the payload goes to STDOUT, with nothing on stderr on the happy path" {
  react_fixture
  run --separate-stderr gather
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.' >/dev/null
}

@test "runs via its own shebang (the orchestrator's test -x partition implies direct execution)" {
  react_fixture
  run "$GATHER" "$W"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
}

@test "a repo path containing a space is handled (quoting regression guard on cd)" {
  spaced="$BATS_TEST_TMPDIR/my repo"
  mkdir -p "$spaced"
  jq -n '{name: "app", dependencies: {react: "19.0.0"}}' > "$spaced/package.json"
  run zsh "$GATHER" "$spaced"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
}
