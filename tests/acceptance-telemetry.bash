# shellcheck shell=bash
# acceptance-telemetry.bash — shared setup for the acceptance-telemetry
# collector suites (#1230): tests/collect-acceptance-telemetry.bats and
# tests/acceptance/cli/acceptance-telemetry.bats. Puts the fake gh
# (tests/fixtures/acceptance-telemetry/gh-stub.zsh) first on PATH, points it at a
# per-test COPY of a fixture scenario, and keeps the user-level telemetry
# default out of the real ~/.claude.
#
# After at_setup:
#   COLLECT  the collector       BUILDER   the payload builder
#   EMITTER  the real emitter    VALIDATE  the validator
#   FX       the scenario copy the fake gh serves (empty until use_scenario)
#   GH_LOG   one line per gh invocation (absent until gh is called)
#   T        a sink file path    ATF       the committed fixture root
#   REPO     timo-jakob/ai-doc-organizer

# The globals it sets are read by the suites that load this file.
# shellcheck disable=SC2034
at_setup() {  # $1 = the repo root
  local root="$1"
  export HOME="$BATS_TEST_TMPDIR/home"  # the user-level telemetry default stays out of the real ~/.claude (#1972)
  mkdir -p "$HOME"
  ATF="$root/tests/fixtures/acceptance-telemetry"
  COLLECT="$root/development/scripts/telemetry/collect-acceptance-telemetry.zsh"
  BUILDER="$root/development/scripts/telemetry/build-acceptance-telemetry-record.zsh"
  EMITTER="$root/development/scripts/telemetry/emit-telemetry.zsh"
  VALIDATE="$root/development/scripts/telemetry/validate-telemetry.zsh"
  REPO="timo-jakob/ai-doc-organizer"
  local bin="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$bin"
  cp "$ATF/gh-stub.zsh" "$bin/gh"
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
  export GH_FIXTURES="$BATS_TEST_TMPDIR/fx" GH_LOG="$BATS_TEST_TMPDIR/gh.log" GH_JUNIT_DIR="$ATF/junit"
  FX="$GH_FIXTURES"
  mkdir -p "$FX"
  T="$BATS_TEST_TMPDIR/sink/acceptance.jsonl"
  unset ACCEPTANCE_TELEMETRY_EMITTER_BIN GH_STUB_LEAK
}

# use_scenario NAME… — copy each committed scenario into the served fixture dir.
use_scenario() {
  local s
  for s in "$@"; do cp "$ATF/$s"/* "$FX/"; done
}

# fx_edit FILE JQ — rewrite one served fixture JSON in place.
fx_edit() {
  jq "$2" "$FX/$1" > "$FX/$1.new" && mv "$FX/$1.new" "$FX/$1"
}

# collect [ARGS…] — run the collector for $REPO into $T, stderr kept apart.
collect() {
  run --separate-stderr zsh "$COLLECT" --repo "$REPO" --telemetry-file "$T" "$@"
}

# fail_emit_on N — make the emitter exit 3 on its Nth invocation (and only then),
# delegating every other call to the real emitter.
fail_emit_on() {
  local stub="$BATS_TEST_TMPDIR/emit-stub.zsh" count="$BATS_TEST_TMPDIR/emit-count"
  printf '0\n' > "$count"
  printf '%s\n' '#!/usr/bin/env zsh' \
    "n=\$(( \$(<'$count') + 1 )); print \$n > '$count'" \
    "if (( n == $1 )); then print -ru2 -- 'emit-telemetry: cannot append to sink: stubbed failure'; exit 3; fi" \
    "exec zsh '$EMITTER' \"\$@\"" > "$stub"
  chmod +x "$stub"
  export ACCEPTANCE_TELEMETRY_EMITTER_BIN="$stub"
}

# lines FILE — the number of lines in FILE (0 when it does not exist).
lines() {
  if [ -e "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi
}
