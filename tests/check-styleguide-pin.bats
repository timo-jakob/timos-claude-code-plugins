#!/usr/bin/env bats
#
# Behavioural tests for scripts/check-styleguide-pin.zsh (#689 AC 8).
#
# That script is the only thing between a dead styleguide pin and every
# bootstrapped repo's contracts-lint, and its whole value rests on ONE polarity
# decision: a pin that resolves but loads no rules must FAIL. Spectral with no
# rules reports "0 problems", so an "expect the lint to fail" check would go
# green on a completely broken pin. The script therefore asserts POSITIVELY that
# all eight org rule ids fire at error severity — and that assertion is what
# these tests pin.
#
# The script is EXECUTED against fixture trees, never grepped: a grep cannot
# tell an arm that fires from one that is unreachable, and the failure mode that
# matters here is a vacuous pass. `npx` and `curl` are replaced by stubs on PATH
# (the tests/no-cluster-deploy.bats pattern) so no case touches the network —
# these run in the default gate, which must stay offline and deterministic.
#
# The live pin IS exercised, but by CI: .github/workflows/styleguide-pin.yml.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  W="$BATS_TEST_TMPDIR/repo"
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
  : > "$ARGV_LOG"
  mkdir -p "$W/scripts" "$W/development/skills/bootstrap/templates/common" \
    "$W/tests/fixtures/api-styleguide/nonconforming" \
    "$W/tests/fixtures/api-styleguide/conforming" \
    "$STUB_BIN"

  # The script resolves its own repo root as ${0:A:h:h}, so copying it into
  # $W/scripts/ re-roots every path it reads at the fixture tree.
  cp "$REPO_ROOT/scripts/check-styleguide-pin.zsh" "$W/scripts/"

  shim "https://cdn.jsdelivr.net/gh/example/styleguide-fixture@styleguide-v1.0.0/styleguide/spectral/ruleset.yaml"
  printf 'openapi: 3.1.0\n' > "$W/tests/fixtures/api-styleguide/nonconforming/openapi.yaml"
  printf 'openapi: 3.1.0\n' > "$W/tests/fixtures/api-styleguide/conforming/openapi.yaml"

  stub_curl 200
  stub_npx_all_eight
  PATH="$STUB_BIN:$PATH"
}

# shim <url> — write the fixture shim with the given extends member.
shim() {
  printf 'extends:\n  - %s\n' "$1" > "$W/development/skills/bootstrap/templates/common/.spectral.yaml"
}

# stub_curl <http-code> [only-for-url] — the pin fetch reports this status.
# Records its argv so a case can assert WHAT was probed: without that, a script
# that ignored the shim and fetched a hardcoded URL would pass every case here,
# defeating the "extracted from the shim, never hardcoded" claim the script makes.
stub_curl() {
  # The expected URL goes through a FILE, and every interpolated path is emitted
  # inside double quotes — same reasoning as stub_npx below: a value containing
  # an apostrophe would close the generated script's quoting mid-line, and a
  # tmpdir containing a space would word-split the redirect, either of which
  # reads as a defect in the checker rather than in this stub.
  printf '%s' "${2:-}" > "$BATS_TEST_TMPDIR/expect-url"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> "%s"\n' "$ARGV_LOG"
    if [ -n "${2:-}" ]; then
      # Answer the given code ONLY for the expected URL; anything else 404s.
      printf 'want="$(cat "%s")"\n' "$BATS_TEST_TMPDIR/expect-url"
      printf 'for a in "$@"; do if [ "$a" = "$want" ]; then printf %%s %s; exit 0; fi; done\n' "$1"
      printf 'printf %%s 404\n'
    else
      printf 'printf %%s %s\n' "$1"
    fi
  } > "$STUB_BIN/curl"
  chmod +x "$STUB_BIN/curl"
}

# stub_npx <nonconforming-json> [conforming-json] — spectral's --format json.
# The script lints the non-conforming fixture first, then the conforming one, so
# the stub keys off the path it is handed.
stub_npx() {
  local nc="$1" c="${2:-[]}"
  # Payloads go through FILES, never through the generated script's quoting: a
  # payload containing an apostrophe would otherwise close the single-quote
  # wrapper mid-script, and the resulting breakage would look like a defect in
  # the checker rather than in this stub.
  printf '%s' "$nc" > "$BATS_TEST_TMPDIR/nc.json"
  printf '%s' "$c" > "$BATS_TEST_TMPDIR/c.json"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> "%s"\n' "$ARGV_LOG"
    printf 'for a in "$@"; do case "$a" in\n'
    printf '  *nonconforming*) cat "%s"; exit 1 ;;\n' "$BATS_TEST_TMPDIR/nc.json"
    printf '  */conforming/*) cat "%s"; exit 0 ;;\n' "$BATS_TEST_TMPDIR/c.json"
    printf 'esac; done\nprintf %%s "[]"\n'
  } > "$STUB_BIN/npx"
  chmod +x "$STUB_BIN/npx"
}

# All eight ids at severity 0 — the shape a healthy pin produces.
ALL_EIGHT='[{"code":"operation-operationId","severity":0},{"code":"operation-operationId-unique","severity":0},{"code":"info-description","severity":0},{"code":"operation-description","severity":0},{"code":"operation-tags","severity":0},{"code":"org-deprecated-operation-has-sunset","severity":0},{"code":"org-resource-naming","severity":0},{"code":"org-problem-json-errors","severity":0}]'

stub_npx_all_eight() { stub_npx "$ALL_EIGHT"; }

# stub_npx_stderr <message> — spectral "runs" but writes only to stderr, the
# shape an npx/registry failure produces (empty stdout + a diagnostic).
stub_npx_stderr() {
  printf '%s' "$1" > "$BATS_TEST_TMPDIR/err.txt"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> "%s"\n' "$ARGV_LOG"
    printf 'cat "%s" >&2\n' "$BATS_TEST_TMPDIR/err.txt"
    printf 'exit 1\n'
  } > "$STUB_BIN/npx"
  chmod +x "$STUB_BIN/npx"
}

# `zsh -f` with a neutral ZDOTDIR: zsh sources ~/.zshenv even for non-interactive
# scripts, and a maintainer whose zshenv prepends /opt/homebrew/bin would put the
# REAL curl and npx ahead of $STUB_BIN — quietly pulling this suite onto the
# network and making the 404 case pass for the wrong reason.
#
# `-f` does NOT skip /etc/zshenv (nothing does), so PATH is re-pinned INSIDE the
# child, after every startup file has had its say. A host whose /etc/zshenv
# prepends paths (nix-darwin does) would otherwise still escape the stubs.
check() {
  run env ZDOTDIR="$BATS_TEST_TMPDIR" zsh -f -c \
    'PATH="$1"; shift; exec "$@"' -- "$STUB_BIN:$PATH" "$W/scripts/check-styleguide-pin.zsh"
}

@test "happy path: a live pin enforcing all eight rules exits 0" {
  check
  [ "$status" -eq 0 ]
  contains "$output" "all 8 org rules at error severity"
  contains "$output" "conforming fixture: 0 error findings"
}

@test "the probe follows the SHIM, and is not a hardcoded URL" {
  # The script's central claim is that the pin is "extracted from the shim rather
  # than hardcoded, so this check can never pass against a version the shim does
  # not actually ship". Without inspecting argv, a script that fetched a constant
  # URL would satisfy every other case here.
  local pin="https://cdn.jsdelivr.net/gh/example/styleguide-fixture@styleguide-v2.3.4/styleguide/spectral/ruleset.yaml"
  shim "$pin"
  stub_curl 200 "$pin"      # 200 for THIS url only; anything else 404s
  check
  [ "$status" -eq 0 ]
  run cat "$ARGV_LOG"
  contains "$output" "$pin"
}

@test "spectral is invoked through the shim, at the EXACT pinned CLI version" {
  # A drift from @6.16.3 to a floating @6 is the thing the script's own header
  # forbids — a spectral minor can retire an inherited spectral:oas rule and move
  # this check's goalposts with no commit here.
  check
  [ "$status" -eq 0 ]
  run cat "$ARGV_LOG"
  contains "$output" "@stoplight/spectral-cli@6.16.3"
  # Suffix, not "$W/…": the script resolves its own location with ${0:A}, which
  # yields the PHYSICAL path (/private/var/… on macOS) while $W holds the
  # symlinked form (/var/…), so a full-path needle never matches.
  contains "$output" "--ruleset /"
  contains "$output" "/repo/development/skills/bootstrap/templates/common/.spectral.yaml"
}

@test "a missing shim is a TOOLING failure (exit 2), not a conformance verdict" {
  # Without its own guard the script falls through to the pin extraction and
  # reports "expected exactly 1 jsDelivr pin … found 0" at exit 1 — a verdict
  # about a file that does not exist.
  rm "$W/development/skills/bootstrap/templates/common/.spectral.yaml"
  check
  [ "$status" -eq 2 ]
  contains "$output" "shim not found"
}

@test "a missing required tool is exit 2, naming the tool" {
  # PATH holds ONLY the stub dir, so jq/node are absent. zsh is invoked by
  # ABSOLUTE path — it does not need to be on PATH itself, and putting its
  # directory there would drag jq back in on a host where they share one.
  local zsh_bin; zsh_bin="$(command -v zsh)"
  run env ZDOTDIR="$BATS_TEST_TMPDIR" PATH="$STUB_BIN" "$zsh_bin" -f "$W/scripts/check-styleguide-pin.zsh"
  [ "$status" -eq 2 ]
  contains "$output" "jq is required but not on PATH"
}

@test "THE case this script exists for: pin resolves but loads NO rules -> exit 1" {
  # HTTP 200 and an empty finding set — exactly what a ruleset that failed to
  # load produces. An "expect failures" check would read this as success.
  stub_npx '[]'
  check
  [ "$status" -eq 1 ]
  contains "$output" "did not enforce 8 of 8"
  contains "$output" "fired: <none>"
}

@test "rules DEMOTED to warn are not accepted as enforcement" {
  # severity 1 = warn. Downstream repos would enforce nothing while a
  # severity-agnostic check reported all eight ids present.
  stub_npx '[{"code":"operation-operationId","severity":1},{"code":"operation-operationId-unique","severity":1},{"code":"info-description","severity":1},{"code":"operation-description","severity":1},{"code":"operation-tags","severity":1},{"code":"org-deprecated-operation-has-sunset","severity":1},{"code":"org-resource-naming","severity":1},{"code":"org-problem-json-errors","severity":1}]'
  check
  [ "$status" -eq 1 ]
  contains "$output" "did not enforce 8 of 8"
}

@test "a single dropped rule is named, and the survivors are listed" {
  stub_npx '[{"code":"operation-operationId","severity":0},{"code":"operation-operationId-unique","severity":0},{"code":"info-description","severity":0},{"code":"operation-description","severity":0},{"code":"operation-tags","severity":0},{"code":"org-deprecated-operation-has-sunset","severity":0},{"code":"org-resource-naming","severity":0}]'
  check
  [ "$status" -eq 1 ]
  contains "$output" "did not enforce 1 of 8"
  contains "$output" "org-problem-json-errors"
}

@test "a 404 pin fails with the HTTP status, not with eight absent rules" {
  stub_curl 404
  check
  [ "$status" -eq 1 ]
  contains "$output" "pin did not resolve (HTTP 404)"
}

@test "an unreachable CDN reports 000 rather than passing" {
  stub_curl 000
  check
  [ "$status" -eq 1 ]
  contains "$output" "pin did not resolve (HTTP 000)"
}

@test "a shim with no pin fails WITH its diagnostic, not silently" {
  # Regression net for the pipefail trap: `PIN_URL="$(grep … | head -1)"` under
  # set -e aborted before the guard could speak, giving a red run with an empty
  # log. The message is the assertion, not the exit code.
  printf 'extends: []\n' > "$W/development/skills/bootstrap/templates/common/.spectral.yaml"
  check
  [ "$status" -eq 1 ]
  contains "$output" "expected exactly 1 jsDelivr pin"
  # The COUNT is what distinguishes this from the two-pin case below; without it
  # a miscounting regression keeps both green while misdiagnosing the cause.
  contains "$output" "found 0"
}

@test "a FLOATING major tag is rejected — the one pin the story forbids" {
  shim "https://cdn.jsdelivr.net/gh/example/styleguide-fixture@styleguide-v1/styleguide/spectral/ruleset.yaml"
  check
  [ "$status" -eq 1 ]
  contains "$output" "not an exact styleguide-vX.Y.Z tag"
}

@test "a retired pin left in a comment does not shadow the live one" {
  {
    printf '# was: https://cdn.jsdelivr.net/gh/example/styleguide-fixture@styleguide-v0.9.0/styleguide/spectral/ruleset.yaml\n'
    printf 'extends:\n  - https://cdn.jsdelivr.net/gh/example/styleguide-fixture@styleguide-v1.0.0/styleguide/spectral/ruleset.yaml\n'
  } > "$W/development/skills/bootstrap/templates/common/.spectral.yaml"
  check
  [ "$status" -eq 0 ]
  contains "$output" "@styleguide-v1.0.0"
  lacks "$output" "@styleguide-v0.9.0"
}

@test "TWO live pins is a defect, not a first-one-wins" {
  printf 'extends:\n  - https://cdn.jsdelivr.net/gh/example/styleguide-fixture@styleguide-v1.0.0/styleguide/spectral/ruleset.yaml\n  - https://cdn.jsdelivr.net/gh/example/styleguide-fixture@styleguide-v2.0.0/styleguide/spectral/ruleset.yaml\n' \
    > "$W/development/skills/bootstrap/templates/common/.spectral.yaml"
  check
  [ "$status" -eq 1 ]
  contains "$output" "expected exactly 1 jsDelivr pin"
  contains "$output" "found 2"
}

@test "the over-fire guard fires: a conforming fixture with an error fails" {
  # One stub call, not two: the earlier `stub_npx_all_eight` here was overwritten
  # by the next line, and deleting the wrong one would have silently turned this
  # case into a duplicate of the happy path.
  stub_npx '[{"code":"operation-operationId","severity":0},{"code":"operation-operationId-unique","severity":0},{"code":"info-description","severity":0},{"code":"operation-description","severity":0},{"code":"operation-tags","severity":0},{"code":"org-deprecated-operation-has-sunset","severity":0},{"code":"org-resource-naming","severity":0},{"code":"org-problem-json-errors","severity":0}]' \
    '[{"code":"org-resource-naming","severity":0}]'
  check
  [ "$status" -eq 1 ]
  contains "$output" "conforming fixture produced 1 error finding"
}

@test "a MISSING conforming fixture is exit 2, never a silent green" {
  # It previously defaulted to `[]` -> "0 error findings" -> exit 0, disabling
  # the over-fire guard entirely while reporting success.
  rm "$W/tests/fixtures/api-styleguide/conforming/openapi.yaml"
  check
  [ "$status" -eq 2 ]
  contains "$output" "fixture not found"
}

@test "warn-severity findings on the conforming fixture are TOLERATED — only errors over-fire" {
  # The over-fire guard counts `select(.severity == 0)`. Every other case feeds
  # the conforming lane either [] or a severity-0 finding, so the FILTER itself
  # is never exercised in the direction that matters: dropping it keeps the whole
  # suite green while the live workflow reddens on the real conforming fixture,
  # which inherits spectral:oas warnings it does not control.
  stub_npx "$ALL_EIGHT" '[{"code":"info-contact","severity":1},{"code":"oas3-api-servers","severity":2}]'
  check
  [ "$status" -eq 0 ]
  contains "$output" "conforming fixture: 0 error findings"
}

@test "unparseable output on the CONFORMING fixture is exit 2 too, and says which" {
  # The second require_json guard is unreached by every other case (they corrupt
  # only the non-conforming payload), yet it is the one the script's own comment
  # says stops a crashed spectral from printing "0 error findings" and exiting 0.
  stub_npx "$ALL_EIGHT" 'not json at all'
  check
  [ "$status" -eq 2 ]
  contains "$output" "for the conforming fixture"
}

@test "spectral's stderr is surfaced on the tooling-failure path" {
  # The whole SPECTRAL_ERR mechanism (mktemp, the 2> redirect, the trap ordering)
  # exists so an npx/registry outage is distinguishable from a genuinely empty
  # lint. Nothing asserted it, so it could be deleted with only a lost diagnostic.
  stub_npx_stderr 'npm ERR! 404 Not Found - @stoplight/spectral-cli'
  check
  [ "$status" -eq 2 ]
  contains "$output" "npm ERR! 404 Not Found"
}

@test "unparseable spectral output is a TOOLING failure (exit 2), not a verdict" {
  stub_npx 'not json at all'
  check
  [ "$status" -eq 2 ]
  contains "$output" "no parseable JSON"
  # WHICH fixture is the diagnostic's whole value — without this both
  # require_json branches satisfy the same needle.
  contains "$output" "for the non-conforming fixture"
}

@test "the checker's rule roster matches the published ruleset exactly" {
  # Four copies of the eight ids exist (script, this suite's fixtures, the
  # ruleset, the acceptance lane). This binds the two that decide whether a real
  # regression is caught: adding a ninth org rule without extending the script
  # would leave it proving eight-of-nine forever, green.
  # Parsed, not sourced: the script runs on source (it has no main guard), so a
  # `source && print` form captures its OUTPUT, not its array — non-empty garbage
  # that then satisfies any "did we get something" guard.
  local expected actual
  expected="$(sed -n '/^EXPECTED_RULES=(/,/^)/p' \
    "$REPO_ROOT/scripts/check-styleguide-pin.zsh" | sed '1d;$d' | tr -d ' ' | sort)"
  actual="$(yq -r '.rules | keys | .[]' "$REPO_ROOT/styleguide/spectral/ruleset.yaml" | sort)"
  # Canary: a slice that captured nothing would compare "" to "" on a broken
  # ruleset read and pass.
  [ "$(printf '%s\n' "$expected" | wc -l | tr -d ' ')" = "8" ]
  [ "$expected" = "$actual" ]
}
