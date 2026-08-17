#!/usr/bin/env bats
#
# Behavioural tests for scripts/check-styleguide-pin.zsh (#689 AC 8).
#
# That script is the only thing between a dead styleguide pin and every
# bootstrapped repo's contracts-lint, and its whole value rests on ONE polarity
# decision: a pin that resolves but loads no rules must FAIL. Spectral with no
# rules reports "0 problems", so an "expect the lint to fail" check would go
# green on a completely broken pin. The script therefore asserts POSITIVELY that
# every org rule id in its roster fires at error severity — and that assertion is
# what these tests pin.
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
  stub_npx_all_rules
  PATH="$STUB_BIN:$PATH"

  # Canary for the derived stub: the payload is read out of the script, so a
  # parse that silently yielded nothing would feed every case an empty finding
  # set — turning the happy path into the "loads NO rules" case and the
  # over-fire cases into false greens. Literal, so growing the roster is a
  # deliberate edit here and not an automatic re-target.
  [ "$(roster_ids | grep -c .)" -eq 15 ]
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
      printf 'for a in "$@"; do if [ "$a" = "$want" ]; then printf %%s "%s"; exit 0; fi; done\n' "$1"
      printf 'printf %%s 404\n'
    else
      printf 'printf %%s "%s"\n' "$1"
    fi
  } > "$STUB_BIN/curl"
  chmod +x "$STUB_BIN/curl"
}

# stub_npx <nonconforming-json> [conforming-json] — spectral's --format json.
# The script lints the non-conforming fixture first, then the conforming one, so
# the stub keys off the path it is handed.
stub_npx() {
  # `${2-[]}`, NOT `${2:-[]}`: the colon form substitutes on unset OR null, so an
  # explicitly-empty second argument would become the literal `[]` before the
  # guard below could see it — making that guard unreachable and silently
  # turning a failed `findings` call into "the conforming fixture produced zero
  # findings". Omitting the argument still yields `[]`, so every caller is
  # unaffected.
  local nc="$1" c="${2-[]}"
  # The choke point for every findings() caller. findings() returns non-zero on
  # a broken roster, but every call site passes it as `stub_npx "$(findings …)"`
  # — a command substitution in ARGUMENT position, whose status is discarded,
  # and bats runs no `pipefail`. So the guards inside findings() only made it
  # return EMPTY, and an empty payload here writes a zero-byte nc.json: the
  # checker's require_json then reports "spectral produced no parseable JSON"
  # and the case reds pointing at spectral instead of at the stale stub.
  # Guarding here closes all six call sites at once and cannot be forgotten by
  # a future caller, which per-site assignments could.
  # BOTH slots, though only `nc` is fed by findings() today: `c` defaults to
  # `[]`, so this guard is unreachable for every current call and changes no
  # behaviour. It closes the slot for the next caller — a future over-fire case
  # written as `stub_npx "$(findings 0)" "$(findings 0 org-x)"` would otherwise
  # write a zero-byte c.json on a stale omit id, and red pointing at the
  # checker's conforming lane rather than at the stale stub.
  [ -n "$nc" ] || { echo "stub_npx: empty non-conforming payload" >&2; return 1; }
  [ -n "$c" ]  || { echo "stub_npx: empty conforming payload" >&2; return 1; }
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
    printf '  */nonconforming/openapi.yaml) cat "%s"; exit 1 ;;\n' "$BATS_TEST_TMPDIR/nc.json"
    printf '  */conforming/openapi.yaml) cat "%s"; exit 0 ;;\n' "$BATS_TEST_TMPDIR/c.json"
    printf 'esac; done\nprintf %%s "[]"\n'
  } > "$STUB_BIN/npx"
  chmod +x "$STUB_BIN/npx"
}

# The checker's own EXPECTED_RULES roster, read out of the script.
#
# DERIVED, not restated. This payload was a literal list of the eight v1 ids, and
# every case below that feeds "a healthy pin" had to be re-typed when #944 grew
# the roster to fifteen — ten cases failed at once, each for the same reason. A
# restated stub also rots in the dangerous direction: it decays into "the pin
# enforces everything the stub bothered to list", so a rule dropped from the
# script AND from the stub reads as a healthy pin forever.
#
# What stops that from making these cases vacuous is that the asserted COUNTS
# below stay literal (15, and 1-of-15), plus the roster_size canary in setup:
# growing the roster is still a deliberate edit in this file. The roster's
# IDENTITY is pinned independently — "the checker's rule roster accounts for
# EVERY published rule" compares it to the ruleset via yq.
#
# Parsed, not sourced: the script runs on source (it has no main guard), so
# sourcing it here would execute the real checker instead of reading its array.
# Comments and blanks are dropped, exactly as that union test does it, so the
# `# newly minted in styleguide-v2.0.0` grouping comment is not read as an id.
roster_ids() {
  # The precondition is checked here rather than left to the pipeline's status:
  # this is a four-stage pipeline and returns its LAST stage's status, so a
  # renamed or deleted script makes the FIRST sed exit 2 while roster_ids still
  # returns 0 (the trailing sed reads empty stdin and succeeds). Without this,
  # a missing file surfaces one line later as findings()'s "roster parsed
  # empty", pointing debugging at EXPECTED_RULES instead of at setup()'s copy.
  [ -f "$W/scripts/check-styleguide-pin.zsh" ] \
    || { echo "roster_ids: checker script missing from the fixture tree" >&2; return 1; }
  sed -n '/^EXPECTED_RULES=(/,/^)/p' "$W/scripts/check-styleguide-pin.zsh" \
    | sed '1d;$d' | tr -d ' \t' | sed '/^$/d; /^#/d'
}

# findings <severity> [omit-id] — the roster rendered as spectral `--format json`
# output. The omit slot is how the "a single dropped rule is named" case builds a
# roster with exactly one id missing without hand-listing the other fourteen.
#
# Guarded at every stage, because awk prints a well-formed `[]` on EMPTY input
# (BEGIN/END run with zero records) and bats sets no `pipefail` — so a renamed
# script, a broken slice, or an over-broad filter would each hand the stub a
# valid-looking empty payload instead of failing. An empty payload is not a
# neutral stub: it is precisely the "pin loads NO rules" scenario, so it would
# turn the happy path and both over-fire cases green for the wrong reason.
findings() {
  local sev="$1" omit="${2:-}" ids
  ids="$(roster_ids)" || return 1
  [ -n "$ids" ] || { echo "findings: roster parsed empty" >&2; return 1; }

  if [ -n "$omit" ]; then
    # A rename in EXPECTED_RULES would otherwise make the filter a silent no-op,
    # handing back a FULL healthy roster. The case would still red — but on the
    # checker's exit code, pointing debugging at the script instead of at the
    # stale id here.
    printf '%s\n' "$ids" | grep -qxF -- "$omit" \
      || { echo "findings: omit id '$omit' is not in the roster" >&2; return 1; }
    # `--`: a future omit value beginning with `-` would otherwise be parsed as
    # a grep option.
    ids="$(printf '%s\n' "$ids" | grep -vxF -- "$omit")"
  fi

  printf '%s\n' "$ids" | awk -v s="$sev" '
    BEGIN { printf "[" }
    { printf "%s{\"code\":\"%s\",\"severity\":%s}", (NR > 1 ? "," : ""), $0, s }
    END { printf "]" }'
}

stub_npx_all_rules() { stub_npx "$(findings 0)"; }

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
# child. Be precise about what that buys: the `exec` below hands the script to
# its own `#!/usr/bin/env zsh` shebang, which starts a THIRD shell that sources
# /etc/zshenv again, after the re-pin. So this closes the ~/.zshenv hazard (the
# observed one) but not a system-wide /etc/zshenv that prepends unconditionally.
# Stock macOS ships no /etc/zshenv and the Docker lane has none, so there is no
# reachable escape on a supported host — but the guarantee is narrower than
# "after every startup file has had its say".
check() {
  run env ZDOTDIR="$BATS_TEST_TMPDIR" zsh -f -c \
    'PATH="$1"; shift; exec "$@"' -- "$STUB_BIN:$PATH" "$W/scripts/check-styleguide-pin.zsh"
}

@test "happy path: a live pin enforcing every rule exits 0" {
  check
  [ "$status" -eq 0 ]
  contains "$output" "all 15 org rules at error severity"
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
  contains "$output" "did not enforce 15 of 15"
  contains "$output" "fired: <none>"
}

@test "rules DEMOTED to warn are not accepted as enforcement" {
  # severity 1 = warn. Downstream repos would enforce nothing while a
  # severity-agnostic check reported every id present.
  #
  # The payload is pinned as well as the verdict. The checker's diagnostic for a
  # fully-demoted roster is `fired: <none>`, byte-identical to the empty-payload
  # case above — so without this, the one case that proves the SEVERITY filter
  # works would also pass on an empty stub, which is the failure mode findings()
  # guards against. Asserting fifteen warn-severity entries arrived separates
  # "fifteen findings, all warn" from "no findings at all".
  local warned; warned="$(findings 1)"
  [ "$(jq 'length' <<<"$warned")" -eq 15 ]
  [ "$(jq '[.[] | select(.severity == 1)] | length' <<<"$warned")" -eq 15 ]
  stub_npx "$warned"
  check
  [ "$status" -eq 1 ]
  contains "$output" "did not enforce 15 of 15"
}

@test "the roster is matched by IDENTITY, not by count" {
  # Every other failure case varies only the CARDINALITY of the finding set: 0
  # of 15 (empty, demoted) or 14 of 15 (one dropped). Since the stub is derived
  # from EXPECTED_RULES, the ids it emits are always a SUBSET of the roster, so
  # nothing here ever hands the checker a right-sized set of the WRONG ids.
  #
  # That leaves one regression invisible: replacing the per-id membership loop
  # with a cardinality comparison (`(( ${#fired} == ${#EXPECTED_RULES} ))`) would
  # keep this entire suite green — while a pin that resolved and fired fifteen
  # rules that are not the org rules got reported as conformant. That is the
  # script's own headline failure mode wearing a different coat, so it is worth
  # one case of its own.
  # Captured FIRST, transformed second. Piping findings() into sed would make it
  # a non-final pipeline stage, so the substitution takes sed's status (always 0)
  # and discards findings()'s own guards — the one construct tests/assertions.bash
  # singles out as status-destroying. As a bare assignment, a findings() failure
  # aborts under errexit with its own message as the last thing printed.
  local swapped
  swapped="$(findings 0 org-problem-json-errors)"
  swapped="$(printf '%s' "$swapped" \
    | sed 's/\]$/,{"code":"totally-unrelated-rule","severity":0}]/')"
  # Canary: fifteen findings, so ONLY identity distinguishes this from healthy.
  [ "$(jq 'length' <<<"$swapped")" -eq 15 ]
  stub_npx "$swapped"
  check
  [ "$status" -eq 1 ]
  contains "$output" "did not enforce 1 of 15"
  contains "$output" "org-problem-json-errors"
}

@test "a single dropped rule is named, and the survivors are listed" {
  stub_npx "$(findings 0 org-problem-json-errors)"
  check
  [ "$status" -eq 1 ]
  contains "$output" "did not enforce 1 of 15"
  contains "$output" "org-problem-json-errors"
}

@test "membership is EXACT: the prefix half of the operationId pair is not covered by its sibling" {
  # The roster carries one id that is a strict PREFIX of another —
  # operation-operationId and operation-operationId-unique — which is the only
  # place a substring membership test differs from an exact one. Every other
  # case here drops org-problem-json-errors or injects an unrelated id, neither
  # of which is a substring of anything, so replacing the script's exact
  # `${fired[(Ie)$rule]}` lookup with a substring scan (`grep -q "$rule"`, or
  # `[[ " ${fired[*]} " == *"$rule"* ]]`) passes every one of them — while
  # reporting a pin as conformant that stopped firing operation-operationId and
  # kept only -unique. That is the script's own headline scenario: its header
  # names "a spectral minor can retire or rename an inherited spectral:oas rule".
  stub_npx "$(findings 0 operation-operationId)"   # -unique SURVIVES in the payload
  check
  [ "$status" -eq 1 ]
  contains "$output" "did not enforce 1 of 15"
  # EXACT equality on the missing-id list, deliberately not a bare `contains`:
  # the surviving `-unique` id appears in the `fired:` line, so
  # `contains "$output" "operation-operationId"` is satisfied even when the
  # checker names the WRONG id as missing — which is precisely the substring
  # confusion this case exists to detect, so a substring assertion could not
  # detect it.
  #
  # Not `matches … '…operation-operationId[[:space:]]*$'` either: `$` in bash's
  # `[[ =~ ]]` anchors to end of STRING, and $output is the whole multi-line
  # run, so that pattern can never match however correct the checker is.
  # Extracting the list and comparing it whole is both anchor-free and stricter
  # — it also proves no OTHER id went missing.
  local missing_ids
  missing_ids="$(printf '%s\n' "$output" | sed -n 's/.*missing at error severity: //p')"
  [ "$missing_ids" = "operation-operationId" ]
  contains "$output" "operation-operationId-unique"
}

@test "a 404 pin fails with the HTTP status, not with a roster of absent rules" {
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
  # One stub call, not two: the earlier `stub_npx_all_rules` here was overwritten
  # by the next line, and deleting the wrong one would have silently turned this
  # case into a duplicate of the happy path.
  stub_npx "$(findings 0)" '[{"code":"org-resource-naming","severity":0}]'
  check
  [ "$status" -eq 1 ]
  contains "$output" "conforming fixture produced 1 error finding"
}

@test "a MISSING non-conforming fixture is exit 2, never a conformance verdict" {
  # The script loops over BOTH fixtures; only the conforming half was covered.
  # Narrowing that loop makes a deleted non-conforming fixture surface as "did
  # not enforce 15 of 15" at exit 1 — blaming the pin for a missing file, the
  # misdiagnosis the 1-vs-2 split exists to prevent.
  rm "$W/tests/fixtures/api-styleguide/nonconforming/openapi.yaml"
  check
  [ "$status" -eq 2 ]
  contains "$output" "fixture not found"
  contains "$output" "/nonconforming/openapi.yaml"
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
  stub_npx "$(findings 0)" '[{"code":"info-contact","severity":1},{"code":"oas3-api-servers","severity":2}]'
  check
  [ "$status" -eq 0 ]
  contains "$output" "conforming fixture: 0 error findings"
}

@test "unparseable output on the CONFORMING fixture is exit 2 too, and says which" {
  # The second require_json guard is unreached by every other case (they corrupt
  # only the non-conforming payload), yet it is the one the script's own comment
  # says stops a crashed spectral from printing "0 error findings" and exiting 0.
  stub_npx "$(findings 0)" 'not json at all'
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
  # The LABEL must be contiguous with the message. A bare `contains "npm ERR!"`
  # is satisfied by the stub's stderr leaking straight through to the script's
  # own stderr, which bats merges into $output — so it passes with the
  # `2>"$SPECTRAL_ERR"` redirect DELETED and the whole mechanism dead. This
  # needle is true only when the script itself surfaced the text.
  contains "$output" "spectral stderr: npm ERR! 404 Not Found"
}

@test "only the LAST five stderr lines are surfaced" {
  # Pins the `tail -n 5` half of the mechanism: without it the diagnostic would
  # dump an entire npm log into the CI output.
  stub_npx_stderr 'FIRST-LINE-MARKER
two
three
four
five
LAST-LINE-MARKER'
  check
  [ "$status" -eq 2 ]
  contains "$output" "LAST-LINE-MARKER"
  lacks "$output" "FIRST-LINE-MARKER"
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

# The rules that exist in the working-tree ruleset but are NOT yet reachable
# THROUGH THE PIN, because the tag carrying them has not been cut.
#
# This list is the release window made explicit, and it is empty in the steady
# state — which is where the tree stands now. #944 shipped as two PRs for a
# structural reason: the checker asserts that every id in EXPECTED_RULES fires at
# error severity through the CURRENT pin, and styleguide-v1.0.0 did not carry
# #944's seven. Adding them to EXPECTED_RULES in PR-A would have failed the gate
# against a ruleset that was perfectly correct — a dead-pin failure with no dead
# pin. PR-B cut styleguide-v2.0.0, bumped the three pin sites, moved those seven
# into EXPECTED_RULES and emptied this list, so the assertion below is exact
# equality again from that commit on.
#
# PENDING_UNTIL_VERSION is the branch SELECTOR: the test below opens the window
# exactly when the shim's tag equals it. So its correct value depends on which
# state you are in, and the two are opposites — say both, because stating either
# one unconditionally licenses the wrong edit in the other state:
#
#   * Window CLOSED (now): it must LAG the shim's pin. A value equal to the
#     current pin re-opens the window and demands parked ids that no longer
#     exist.
#   * Window OPEN (a PR-A): it must EQUAL the pin at that moment. Leaving it
#     lagging takes the closed arm, which asserts an EMPTY parked list and reds
#     during a legitimately open window — and the cheapest-looking repair is to
#     move the parked ids into EXPECTED_RULES early, which fails
#     check-styleguide-pin.zsh against a perfectly correct ruleset. That is the
#     "dead-pin failure with no dead pin" the two-PR split exists to prevent.
#
# PR-B closes the window by moving the PIN past this constant, not by moving the
# constant.
#
# OPENING THE NEXT WINDOW IS THREE EDITS, NOT TWO. Move this constant forward to
# whatever the pin is at that moment, park that window's ids below — and
# RE-TARGET the open-window branch of "the release window CLOSES when the shim's
# pin moves", which asserts the parked set by literal count AND by literal name
# against #944's seven. Both are deliberate (a count alone would accept a
# hand-edited constant re-opening the window against some other id set), so
# neither self-updates. Miss the third edit and that test reds as a bare bracket
# comparison with no message, whose cheapest-looking repair is to delete the
# by-name assertion — removing the guard this design exists for.
#
# Deliberately spelled WITHOUT the `styleguide-v` prefix. The repo forces the pin
# to be quoted in three files at once and reds unless they all agree, which makes
# a repo-wide `s/styleguide-v1.0.0/styleguide-v2.0.0/g` the natural way to bump
# it — and that sweep would rewrite this constant too, silently RETARGETING the
# window instead of closing it, leaving eight of fifteen rules verified through
# the pin while every downstream repo enforced all fifteen. Storing only the
# number means the sweep cannot reach it, so the test reds and asks for a
# deliberate edit.
PENDING_UNTIL_VERSION="1.0.0"
PENDING_PIN_RULES=()

@test "the checker's rule roster accounts for EVERY published rule" {
  # Four copies of the ids exist (script, this suite's fixtures, the ruleset, the
  # acceptance lane). This binds the two that decide whether a real regression is
  # caught: adding a rule to the ruleset without extending the script would leave
  # it proving eight-of-fifteen forever, green.
  #
  # The union — not a subset test — is what keeps that protection during a
  # release window. A subset test would pass with a new rule declared nowhere;
  # here a new rule must land in EXPECTED_RULES or be named above as pending, and
  # either way a human wrote it down.
  # Parsed, not sourced: the script runs on source (it has no main guard), so a
  # `source && print` form captures its OUTPUT, not its array — non-empty garbage
  # that then satisfies any "did we get something" guard.
  # Blank lines and comments are dropped from the slice: PR-B grows this array
  # from 8 entries to 15, and a `# newly minted` grouping comment between the
  # groups is the natural way to write that. Left in, it enters the list as an
  # element and the union below fails as a bare `[` with no explanation.
  local expected actual accounted n_expected
  expected="$(sed -n '/^EXPECTED_RULES=(/,/^)/p' \
    "$REPO_ROOT/scripts/check-styleguide-pin.zsh" \
    | sed '1d;$d' | tr -d ' \t' | sed '/^$/d; /^#/d' | sort)"
  actual="$(yq -r '.rules | keys | .[]' "$REPO_ROOT/styleguide/spectral/ruleset.yaml" | sort)"

  # Canary: a slice that captured nothing would compare "" to "" on a broken
  # ruleset read and pass.
  #
  # A literal since PR-B, not the `-ge 8` floor it carried during the release
  # window. That floor existed so PR-B would not owe a third edit in a third
  # file while the roster grew — but it also ACCEPTS a tree in which PR-B's
  # seven ids were reverted back out of EXPECTED_RULES, which is exactly the
  # regression the rest of this file pins with a literal 15. The window is
  # closed, so the canary names the real number again.
  n_expected="$(printf '%s\n' "$expected" | grep -c . || true)"
  [ "$n_expected" -eq 15 ]

  accounted="$(printf '%s\n' "$expected" "${PENDING_PIN_RULES[@]}" | grep -c . || true)"
  [ "$accounted" -eq "$(printf '%s\n' "$actual" | grep -c . || true)" ]
  [ "$(printf '%s\n' "$expected" "${PENDING_PIN_RULES[@]}" | sed '/^$/d' | sort)" = "$actual" ]

  # …and the two lists must be DISJOINT. Without this an id left in both after a
  # sloppy PR-B would still satisfy the union while the checker's own roster had
  # silently stopped growing.
  #
  # A temp file rather than a process substitution: tests/api-styleguide-ruleset.bats
  # records this suite's own experience of `<(…)` failing only under
  # run-gate.zsh's parallel runner, with an unattributable "line 0" error.
  #
  # Explicitly conditional on an OPEN window. `grep -Fxf` on an empty pattern
  # file matches nothing, so with the window closed this assertion passes for
  # any EXPECTED_RULES whatsoever — it is vacuous rather than protective, and
  # reading it as a live guard overstates what the steady state proves. The
  # branch says so out loud instead of leaving a reader to work it out.
  if [ "${#PENDING_PIN_RULES[@]}" -gt 0 ]; then
    local pending="$BATS_TEST_TMPDIR/pending.txt"
    printf '%s\n' "${PENDING_PIN_RULES[@]}" | sed '/^$/d' | sort > "$pending"
    local overlap
    overlap="$(printf '%s\n' "$expected" | grep -Fxf "$pending" || true)"
    [ -z "$overlap" ]
  fi
}

@test "the release window CLOSES when the shim's pin moves" {
  # The union test above is satisfied by ANY partition of the fifteen ids —
  # including the post-PR-B state where the shim has been bumped but the seven
  # were never moved into EXPECTED_RULES. Nothing else in the suite reads the
  # shim's version, so without this the window has no closing condition: the
  # checker would report "all 8 org rules enforced through the pin" forever
  # while #944's entire payload went unverified through it. That is the
  # script's own silent-failure class — "a pin that resolves but enforces
  # nothing" — reduced from 0-of-8 to 7-of-15 and therefore invisible.
  local shim tag
  shim="$REPO_ROOT/development/skills/bootstrap/templates/common/.spectral.yaml"
  [ -f "$shim" ]
  run yq -r '.extends[0]' "$shim"
  [ "$status" -eq 0 ]
  tag="$(printf '%s\n' "$output" \
    | sed -n 's|.*@\(styleguide-v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)/.*|\1|p')"
  # Canary: a shim whose pin stopped matching the expected shape would otherwise
  # take the else-branch below and demand an empty list for the wrong reason.
  [ -n "$tag" ]

  if [ "$tag" = "styleguide-v$PENDING_UNTIL_VERSION" ]; then
    # Window OPEN: every id #944 added is parked, none has leaked into the
    # checker's roster early (the disjointness test above covers the overlap).
    # Asserted BY NAME, not by count: a count alone would accept a hand-edited
    # constant re-opening the window against some other set of seven ids.
    [ "${#PENDING_PIN_RULES[@]}" -eq 7 ]
    run bash -c 'printf "%s\n" "$@" | sort | tr "\n" " "' _ "${PENDING_PIN_RULES[@]}"
    [ "$output" = "org-deprecation-sunset-headers org-idempotency-key-on-post-patch org-no-bespoke-correlation-headers org-pagination-cursor-params org-pagination-envelope org-pagination-no-offset-params org-retry-after-on-throttled " ]
  else
    # Window CLOSED: the pin moved, so the roster must be whole and the parked
    # list empty. Exact equality, not the open-window floor.
    [ "${#PENDING_PIN_RULES[@]}" -eq 0 ]
    local expected actual
    expected="$(sed -n '/^EXPECTED_RULES=(/,/^)/p' \
      "$REPO_ROOT/scripts/check-styleguide-pin.zsh" \
      | sed '1d;$d' | tr -d ' \t' | sed '/^$/d; /^#/d' | sort)"
    actual="$(yq -r '.rules | keys | .[]' "$REPO_ROOT/styleguide/spectral/ruleset.yaml" | sort)"
    [ "$expected" = "$actual" ]
  fi
}
