#!/usr/bin/env bats
#
# #1671 — branch-protection.sh, preflight.sh and Step 4.5's interim bridge take
# the RESOLVED toolchain (--static-analysis / --vulnerabilities), never
# --visibility. The oracle is #1670's D1 context rule and its D4 table of eight
# combinations, restated below as literal sets: the expected values are the
# issue's, never read back from the script under test.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/bootstrap/scripts"
  PROTECT="$SCRIPTS/branch-protection.sh"
  PREFLIGHT="$SCRIPTS/preflight.sh"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  GOLDEN="$REPO_ROOT/tests/fixtures/branch-protection-golden"
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  # the fixture repo branch-protection.sh probes for on-disk workflows
  W="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$W/.github/workflows"
  CALLS="$BATS_TEST_TMPDIR/external-calls.log"
  : > "$CALLS"
  export CALLS
}

# gh answers the repo and a token; curl records each --data payload, one
# compact JSON document per line, so the first line is the protection PUT.
protection_stubs() {
  CURL_DATA="$BATS_TEST_TMPDIR/curl-data.txt"
  : > "$CURL_DATA"
  export CURL_DATA
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "auth token") echo "stub-token" ;;
esac
exit 0
EOF
  cat > "$STUB_BIN/curl" <<'EOF'
#!/bin/sh
prev=""
for a in "$@"; do
  if [ "$prev" = "--data" ]; then
    printf '%s' "$a" | jq -c . >> "$CURL_DATA" 2>/dev/null || printf '%s\n' "$a" >> "$CURL_DATA"
  fi
  prev="$a"
done
echo "200"
exit 0
EOF
  chmod +x "$STUB_BIN/gh" "$STUB_BIN/curl"
}

# The required contexts of the protection PUT, one per line, sorted.
put_contexts() {
  head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts[]' | LC_ALL=C sort
}

# The #1670 D4 table. Fixture: python + Dockerfile.
# row | static_analysis | vulnerabilities | code_scanning
D4_ROWS=(
  "1 sonarcloud snyk codeql"
  "2 sonarcloud snyk none"
  "3 sonarcloud trivy codeql"
  "4 sonarcloud trivy none"
  "5 sonarqube trivy none"
  "6 sonarqube snyk none"
  "7 sonarcloud trivy none"
  "8 sonarcloud snyk none"
)

# A D4 row's context set, one per line, sorted — the table's literal column.
d4_contexts() {
  local b="test-and-coverage semgrep pre-commit license-fs image"
  case "$1" in
    1) printf '%s\n' $b sonarcloud "analyze (python)" ;;
    2) printf '%s\n' $b sonarcloud ;;
    3) printf '%s\n' $b sonarcloud trivy-fs "analyze (python)" ;;
    4) printf '%s\n' $b sonarcloud trivy-fs ;;
    5) printf '%s\n' $b sonarqube trivy-fs ;;
    6) printf '%s\n' $b sonarqube ;;
    7) printf '%s\n' $b sonarcloud trivy-fs ;;
    8) printf '%s\n' $b sonarcloud ;;
  esac | LC_ALL=C sort
}

# Run branch-protection.sh for one D4 row: --has-codeql true exactly when the
# row's code_scanning is codeql, as Step 4b passes it.
protect_row() {
  local sa="$1" v="$2" cs="$3" codeql=false
  [ "$cs" = codeql ] && codeql=true
  (cd "$W" && env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --static-analysis "$sa" --vulnerabilities "$v" --has-dockerfile true \
    --has-codeql "$codeql" --codeql-languages python --default-branch main)
}

# branch-protection.sh in the fixture repo, with the given flags verbatim.
protect_in_fixture() {
  (cd "$W" && env PATH="$STUB_BIN:$PATH" bash "$PROTECT" "$@")
}

# --- AC1 / AC5: no visibility, from any source ---------------------------------------

@test "#1671 AC1: --visibility exits 1 on both scripts, naming both toolchain flags, with or without other flags" {
  protection_stubs
  local s
  for s in "$PROTECT" "$PREFLIGHT"; do
    # alone …
    run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$s" --visibility public
    [ "$status" -eq 1 ]
    contains "$stderr" '--static-analysis'
    contains "$stderr" '--vulnerabilities'
    # … after a complete, otherwise-valid toolchain (no alias beside the new flags) …
    run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$s" \
      --static-analysis sonarcloud --vulnerabilities snyk --visibility private
    [ "$status" -eq 1 ]
    contains "$stderr" '--static-analysis'
    contains "$stderr" '--vulnerabilities'
    # … and before one, on the IaC path too, where the toolchain is never read
    run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$s" \
      --visibility public --iac-only true
    [ "$status" -eq 1 ]
    contains "$stderr" '--static-analysis'
  done
  # refused before any external call: no rule was ever PUT
  [ ! -s "$CURL_DATA" ]
}

@test "#1671 AC5: neither script holds a visibility variable or looks visibility up" {
  local s
  for s in "$PROTECT" "$PREFLIGHT"; do
    run ! grep -nE 'VISIBILITY|visibility[A-Za-z_]*=' "$s"
    # no gh lookup, no .maintenance.yml read
    run ! grep -nE 'json[^#]*visibility|isPrivate|\.maintenance\.yml' "$s"
    # the one `--visibility` arm is the refusal: its next line dies
    [ "$(grep -c -- '--visibility)' "$s")" -eq 1 ]
    grep -A2 -- '--visibility)' "$s" | grep -q 'die "--visibility is no longer accepted'
  done
}

@test "#1671: a missing or out-of-set toolchain value is refused off the IaC path" {
  protection_stubs
  local s
  for s in "$PROTECT" "$PREFLIGHT"; do
    run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$s" --vulnerabilities snyk
    [ "$status" -eq 1 ]
    contains "$stderr" '--static-analysis must be sonarcloud or sonarqube'
    run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$s" --static-analysis sonarcloud
    [ "$status" -eq 1 ]
    contains "$stderr" '--vulnerabilities must be snyk or trivy'
    run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$s" \
      --static-analysis sonarcloud --vulnerabilities grype
    [ "$status" -eq 1 ]
    contains "$stderr" '--vulnerabilities must be snyk or trivy'
    run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$s" \
      --static-analysis public --vulnerabilities snyk
    [ "$status" -eq 1 ]
    contains "$stderr" '--static-analysis must be sonarcloud or sonarqube'
    # near misses pin both regex anchors and the case, as --iac-only's truex/xtrue/True do
    local v
    for v in sonarcloudx xsonarqube SonarCloud; do
      run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$s" --static-analysis "$v" --vulnerabilities snyk
      [ "$status" -eq 1 ]
      contains "$stderr" '--static-analysis must be sonarcloud or sonarqube'
    done
    for v in snykx xtrivy Snyk; do
      run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$s" --static-analysis sonarcloud --vulnerabilities "$v"
      [ "$status" -eq 1 ]
      contains "$stderr" '--vulnerabilities must be snyk or trivy'
    done
    # a flag with no value is named, never `$2: unbound variable`
    for v in --static-analysis --vulnerabilities; do
      run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$s" "$v"
      [ "$status" -eq 1 ]
      contains "$stderr" "$v must be"
      lacks "$stderr" 'unbound variable'
    done
  done
  [ ! -s "$CURL_DATA" ]
}

# --- AC2: the eight D4 rows, as sets ----------------------------------------------------

@test "#1671 AC2: every D4 row requires exactly its D4 context set (codeql.yml on disk, no #1206 pair)" {
  protection_stubs
  touch "$W/.github/workflows/codeql.yml"
  local row n sa v cs
  for row in "${D4_ROWS[@]}"; do
    read -r n sa v cs <<< "$row"
    : > "$CURL_DATA"
    run protect_row "$sa" "$v" "$cs"
    [ "$status" -eq 0 ] || { echo "row $n exited $status: $output"; return 1; }
    [ "$(put_contexts)" = "$(d4_contexts "$n")" ] ||
      { echo "row $n: got [$(put_contexts | paste -sd, -)] want [$(d4_contexts "$n" | paste -sd, -)]"; return 1; }
  done
}

@test "#1671 AC2: with both #1206 halves on disk, every D4 row adds exactly no-cluster-deploy" {
  protection_stubs
  touch "$W/.github/workflows/codeql.yml" "$W/.github/workflows/no-cluster-deploy.yml"
  mkdir -p "$W/scripts"
  touch "$W/scripts/check-no-cluster-deploy.zsh"
  local row n sa v cs want
  for row in "${D4_ROWS[@]}"; do
    read -r n sa v cs <<< "$row"
    : > "$CURL_DATA"
    run protect_row "$sa" "$v" "$cs"
    [ "$status" -eq 0 ]
    want="$({ d4_contexts "$n"; echo no-cluster-deploy; } | LC_ALL=C sort)"
    [ "$(put_contexts)" = "$want" ] || { echo "row $n: got [$(put_contexts | paste -sd, -)]"; return 1; }
  done
}

@test "#1671 AC2: no Dockerfile drops image and nothing else (the per-stack half of D1)" {
  protection_stubs
  cd "$W"
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" --static-analysis sonarcloud \
    --vulnerabilities snyk --has-dockerfile false --has-codeql false --default-branch main
  [ "$status" -eq 0 ]
  # the use case's row 8: private, python, no Dockerfile
  [ "$(put_contexts)" = "$(printf '%s\n' license-fs pre-commit semgrep sonarcloud test-and-coverage)" ]
}

# --- AC3: the analyze contexts ---------------------------------------------------------

@test "#1671 AC3: --has-codeql false drops every analyze context in every row" {
  protection_stubs
  touch "$W/.github/workflows/codeql.yml"
  local row n sa v cs
  for row in "${D4_ROWS[@]}"; do
    read -r n sa v cs <<< "$row"
    : > "$CURL_DATA"
    run protect_row "$sa" "$v" none
    [ "$status" -eq 0 ]
    run ! grep -q '^analyze' <<< "$(put_contexts)"
    # positive control: the PUT happened and carried the rest of the set
    grep -qx test-and-coverage <<< "$(put_contexts)"
  done
}

@test "#1671 AC3: --has-codeql true without codeql.yml on disk requires no analyze context and warns" {
  protection_stubs
  local row n sa v cs out
  for row in "${D4_ROWS[@]}"; do
    read -r n sa v cs <<< "$row"
    : > "$CURL_DATA"
    run protect_row "$sa" "$v" codeql
    [ "$status" -eq 0 ]
    out="$output"
    run ! grep -q '^analyze' <<< "$(put_contexts)"
    contains "$out" 'codeql.yml is absent'
    contains "$out" 'NOT requiring any'
  done
  # positive control: the same call WITH the workflow on disk does require it
  touch "$W/.github/workflows/codeql.yml"
  : > "$CURL_DATA"
  run protect_row sonarcloud snyk codeql
  grep -qx 'analyze (python)' <<< "$(put_contexts)"
  lacks "$output" 'codeql.yml is absent'
}

@test "#1671: --has-codeql true with codeql.yml on disk but no --codeql-languages requires no analyze context and warns" {
  protection_stubs
  touch "$W/.github/workflows/codeql.yml"
  run protect_in_fixture --static-analysis sonarcloud --vulnerabilities snyk \
    --has-dockerfile true --has-codeql true --default-branch main
  [ "$status" -eq 0 ]
  contains "$output" '--codeql-languages was not provided'
  run ! grep -q '^analyze' <<< "$(put_contexts)"
  # the rest of row 1 still came through
  [ "$(put_contexts)" = "$(d4_contexts 2)" ]
}

@test "#1671: every CodeQL language becomes its own analyze context" {
  protection_stubs
  touch "$W/.github/workflows/codeql.yml"
  run protect_in_fixture --static-analysis sonarcloud --vulnerabilities trivy \
    --has-dockerfile true --has-codeql true --codeql-languages "python javascript go" --default-branch main
  [ "$status" -eq 0 ]
  local want
  want="$({ d4_contexts 4; printf '%s\n' "analyze (python)" "analyze (javascript)" "analyze (go)"; } | LC_ALL=C sort)"
  [ "$(put_contexts)" = "$want" ]
}

@test "#1671: the ko lane provides image only when ko-image.yml is on disk, and says so otherwise" {
  protection_stubs
  # ko without its workflow: no image, and the fail-open is visible
  run protect_in_fixture --static-analysis sonarcloud --vulnerabilities snyk \
    --has-dockerfile false --has-ko true --has-codeql false --default-branch main
  [ "$status" -eq 0 ]
  contains "$output" '.ko.yaml was detected but .github/workflows/ko-image.yml is absent'
  run ! grep -qx image <<< "$(put_contexts)"
  # with it: image is required
  touch "$W/.github/workflows/ko-image.yml"
  : > "$CURL_DATA"
  run protect_in_fixture --static-analysis sonarcloud --vulnerabilities snyk \
    --has-dockerfile false --has-ko true --has-codeql false --default-branch main
  [ "$status" -eq 0 ]
  grep -qx image <<< "$(put_contexts)"
  # both lanes at once: one image context, and the collision is named
  : > "$CURL_DATA"
  run protect_in_fixture --static-analysis sonarcloud --vulnerabilities snyk \
    --has-dockerfile true --has-ko true --has-codeql false --default-branch main
  [ "$status" -eq 0 ]
  [ "$(put_contexts | grep -cx image)" -eq 1 ]
  contains "$output" 'Both a Dockerfile and a root .ko.yaml were detected'
}

# --- AC4: rows 1 and 5 are today's defaults, byte for byte as sets ------------------

@test "#1671 AC4: rows 1 and 5 produce exactly the pre-change golden context lists" {
  protection_stubs
  touch "$W/.github/workflows/codeql.yml"
  run protect_row sonarcloud snyk codeql
  [ "$status" -eq 0 ]
  [ "$(put_contexts)" = "$(LC_ALL=C sort "$GOLDEN/row1-public-contexts.txt")" ]
  : > "$CURL_DATA"
  run protect_row sonarqube trivy none
  [ "$status" -eq 0 ]
  [ "$(put_contexts)" = "$(LC_ALL=C sort "$GOLDEN/row5-private-contexts.txt")" ]
}

# --- AC6 / AC7: preflight follows the tools ------------------------------------------

# uname answers Darwin, brew reports every formula present (so nothing is
# installed and the run is non-interactive), gh is authenticated, and docker
# answers every probe — logging each call, so a Docker check is observable.
preflight_stubs() {
  printf '#!/bin/sh\necho Darwin\n' > "$STUB_BIN/uname"
  printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/brew"
  printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/gh"
  printf '#!/bin/sh\necho "docker $*" >> "$CALLS"\nexit 0\n' > "$STUB_BIN/docker"
  # the IaC list's yq must be mikefarah's v4, and a host yq must not answer for it
  printf '#!/bin/sh\necho "yq (https://github.com/mikefarah/yq/) version v4.44.3"\n' > "$STUB_BIN/yq"
  chmod +x "$STUB_BIN/uname" "$STUB_BIN/brew" "$STUB_BIN/gh" "$STUB_BIN/docker" "$STUB_BIN/yq"
}

# The tools a preflight run CHECKED, one per line, sorted: the name on each
# `✓ <tool>` / `✓ <tool> (<variant>)` / `! <tool> — missing` line of the tool
# loop, colour codes removed. A line with any other shape — `✓ gh is
# authenticated`, which follows directly when nothing is installed — ends it.
checked_tools() {
  printf '%s\n' "$1" | sed $'s/\e\\[[0-9;]*m//g' | awk '
    /Checking required tools/ { on = 1; next }
    on && !(($1 == "✓" || $1 == "!") && (NF == 2 || $3 ~ /^(—|\()/)) { exit }
    on { print $2 }
  ' | LC_ALL=C sort
}

run_preflight() {
  (cd "$W" && env PATH="$STUB_BIN:/usr/bin:/bin" bash "$PREFLIGHT" --languages "" "$@" </dev/null)
}

@test "#1671 AC6: --vulnerabilities snyk requires snyk-cli and not trivy, whatever the Dockerfile or analyser" {
  preflight_stubs
  local sa df checked
  for sa in sonarcloud sonarqube; do
    for df in true false; do
      run --separate-stderr run_preflight --static-analysis "$sa" --vulnerabilities snyk --has-dockerfile "$df"
      [ "$status" -eq 0 ]
      checked="$(checked_tools "$output")"
      grep -qx snyk-cli <<< "$checked"
      run ! grep -qx trivy <<< "$checked"
    done
  done
}

@test "#1671 AC6: --vulnerabilities trivy requires trivy and not snyk-cli, whatever the Dockerfile or analyser" {
  preflight_stubs
  local sa df checked
  for sa in sonarcloud sonarqube; do
    for df in true false; do
      run --separate-stderr run_preflight --static-analysis "$sa" --vulnerabilities trivy --has-dockerfile "$df"
      [ "$status" -eq 0 ]
      checked="$(checked_tools "$output")"
      grep -qx trivy <<< "$checked"
      run ! grep -qx snyk-cli <<< "$checked"
    done
  done
}

@test "#1671 AC7: row 8 (sonarcloud + snyk) without a Dockerfile runs no Docker-daemon check" {
  preflight_stubs
  run --separate-stderr run_preflight --static-analysis sonarcloud --vulnerabilities snyk --has-dockerfile false
  [ "$status" -eq 0 ]
  lacks "$output" 'Checking Docker'
  [ ! -s "$CALLS" ]
}

@test "#1671: the Docker check runs exactly when sonarqube, trivy or a Dockerfile asks for it" {
  preflight_stubs
  local sa v df want
  for sa in sonarcloud sonarqube; do
    for v in snyk trivy; do
      for df in true false; do
        : > "$CALLS"
        run --separate-stderr run_preflight --static-analysis "$sa" --vulnerabilities "$v" --has-dockerfile "$df"
        [ "$status" -eq 0 ]
        want=no
        [ "$sa" = sonarqube ] || [ "$v" = trivy ] || [ "$df" = true ] && want=yes
        if [ "$want" = yes ]; then
          contains "$output" 'Checking Docker'
          # sonarqube reaches exactly today's needs_docker block: daemon + compose
          grep -qx 'docker info' "$CALLS"
          grep -qx 'docker compose version' "$CALLS"
        else
          lacks "$output" 'Checking Docker'
          [ ! -s "$CALLS" ]
        fi
      done
    done
  done
}


# --- AC9: the interim automate-*.sh bridge ----------------------------------------------

# Every external command either script could reach first, stubbed to log. Pass
# the names to leave OUT (to prove a tool is, or is not, required).
automate_stubs() {
  local c skip=" $* "
  for c in gh docker curl snyk security open openssl launchctl jq; do
    [[ "$skip" == *" $c "* ]] && continue
    if [ "$c" = jq ]; then
      ln -sf "$(command -v jq)" "$STUB_BIN/jq"
      continue
    fi
    printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\nexit 0\n' "$c" > "$STUB_BIN/$c"
    chmod +x "$STUB_BIN/$c"
  done
}

# Run an automate-*.sh with its project flags and the given extra ones, on a
# PATH that holds the stubs and nothing but the base system.
run_automate() {
  local s="$1"
  shift
  local -a base=(--project-key k --project-name n --default-branch main --has-dockerfile false)
  [ "$s" = automate-public.sh ] && base+=(--org-key o)
  # from the fixture: both scripts take REPO_ROOT from $(pwd)
  cd "$W"
  run --separate-stderr env PATH="$STUB_BIN:/usr/bin:/bin" bash "$SCRIPTS/$s" "${base[@]}" "$@" </dev/null
}

@test "#1671 AC9: each automate-*.sh refuses a missing or out-of-set toolchain flag, naming it, before any external call" {
  automate_stubs
  local s
  for s in automate-public.sh automate-private.sh; do
    run_automate "$s" --vulnerabilities snyk
    [ "$status" -eq 1 ]
    contains "$stderr" '--static-analysis must be sonarcloud or sonarqube'
    run_automate "$s" --static-analysis sonarcloud
    [ "$status" -eq 1 ]
    contains "$stderr" '--vulnerabilities must be snyk or trivy'
    run_automate "$s" --static-analysis sonarcloud --vulnerabilities grype
    [ "$status" -eq 1 ]
    contains "$stderr" '--vulnerabilities must be snyk or trivy'
    run_automate "$s" --static-analysis private --vulnerabilities snyk
    [ "$status" -eq 1 ]
    contains "$stderr" '--static-analysis must be sonarcloud or sonarqube'
    # near misses pin both regex anchors and the case
    local v
    for v in sonarcloudx xsonarqube SonarCloud; do
      run_automate "$s" --static-analysis "$v" --vulnerabilities snyk
      [ "$status" -eq 1 ]
      contains "$stderr" '--static-analysis must be sonarcloud or sonarqube'
    done
    for v in snykx xtrivy Snyk; do
      run_automate "$s" --static-analysis sonarcloud --vulnerabilities "$v"
      [ "$status" -eq 1 ]
      contains "$stderr" '--vulnerabilities must be snyk or trivy'
    done
    # Step 4b's signing value is validated with the toolchain, not passed on blind
    for v in yes truex xfalse True; do
      run_automate "$s" --static-analysis sonarcloud --vulnerabilities snyk --require-signed-commits "$v"
      [ "$status" -eq 1 ]
      contains "$stderr" '--require-signed-commits must be true or false'
    done
    # a flag with no value at all is named too, not an `unbound variable`
    for v in --static-analysis --vulnerabilities --require-signed-commits; do
      run_automate "$s" "$v"
      [ "$status" -eq 1 ]
      contains "$stderr" "$v must be"
      lacks "$stderr" 'unbound variable'
    done
  done
  # none of the refusals reached gh, docker, curl, snyk, the Keychain or a browser
  [ ! -s "$CALLS" ]
}

@test "#1671: each automate-*.sh refuses, by name, the analyser it does not set up — before any external call" {
  automate_stubs
  run_automate automate-public.sh --static-analysis sonarqube --vulnerabilities trivy
  [ "$status" -eq 1 ]
  contains "$stderr" 'sonarqube is not automated by automate-public.sh'
  run_automate automate-private.sh --static-analysis sonarcloud --vulnerabilities snyk
  [ "$status" -eq 1 ]
  contains "$stderr" 'sonarcloud is not automated by automate-private.sh'
  contains "$stderr" "SETUP.md's SonarCloud section"
  [ ! -s "$CALLS" ]
}

@test "#1671: automate-public.sh requires snyk exactly when the resolved vulnerabilities tool is snyk" {
  # no snyk on this PATH (preflight installs snyk-cli for snyk only). The script
  # runs from a copy whose lib.sh answers the SONAR_TOKEN prompt empty, so a run
  # that gets past require_tools ends at "Empty token" and never reads /dev/tty
  automate_stubs snyk
  cp "$SCRIPTS/automate-public.sh" "$SCRIPTS/lib.sh" "$BATS_TEST_TMPDIR/"
  printf '%s\n' 'ask_secret() { printf -v "$2" "%s" ""; }' >> "$BATS_TEST_TMPDIR/lib.sh"
  local sc
  for sc in true false; do
    SCRIPTS="$BATS_TEST_TMPDIR" run_automate automate-public.sh --static-analysis sonarcloud --vulnerabilities trivy \
      --require-signed-commits "$sc"
    [ "$status" -eq 1 ]
    contains "$stderr" 'Empty token'
    lacks "$stderr" 'Required tool(s) not on PATH'
    lacks "$stderr" 'must be'
  done
  SCRIPTS="$BATS_TEST_TMPDIR" run_automate automate-public.sh --static-analysis sonarcloud --vulnerabilities snyk
  [ "$status" -eq 1 ]
  contains "$stderr" 'Required tool(s) not on PATH: snyk'
}

@test "#1671: automate-private.sh accepts sonarqube with either vulnerabilities tool" {
  # the fixture has no infra/sonarqube, so an accepted toolchain stops at the
  # compose-file check — past validation and require_tools, before any external call
  automate_stubs
  local v sc
  for v in trivy snyk; do
    # …and both of Step 4b's signing values pass validation too
    for sc in true false; do
      run_automate automate-private.sh --static-analysis sonarqube --vulnerabilities "$v" --require-signed-commits "$sc"
      [ "$status" -eq 1 ]
      contains "$stderr" 'docker-compose.yml — has bootstrap finished generating files?'
      lacks "$stderr" 'must be'
      lacks "$stderr" 'is not automated'
    done
  done
  [ ! -s "$CALLS" ]
}

# Every Snyk CALL (a snyk subcommand, the SNYK_TOKEN secret, the Snyk API helper),
# at any indent, that no `if [[ "$VULNERABILITIES" == "snyk" ]]` THEN-arm covers.
# A guard's else/elif arm is the non-snyk path, so it is scanned like unguarded
# code; a guard left unclosed prints UNCLOSED rather than silencing the rest.
# Shared by the test below and its MUTATION check so the two cannot drift.
SNYK_SCAN_AWK='
  /^[[:space:]]*#/ { next }
  /if \[\[ "\$VULNERABILITIES" == "snyk" \]\]; then/ {
    match($0, /^[[:space:]]*/); ind[++d] = substr($0, 1, RLENGTH); inelse[d] = 0; next
  }
  d > 0 && $0 ~ ("^" ind[d] "(else|elif)([[:space:];]|$)") { inelse[d] = 1; next }
  d > 0 && $0 ~ ("^" ind[d] "fi([[:space:];#]|$)") { d--; next }
  {
    guarded = 0
    for (i = 1; i <= d; i++) if (!inelse[i]) guarded = 1
    if (!guarded && tolower($0) ~ /snyk (auth|config|monitor|test|container|code|iac)|snyk_token|snyk_api/) print FNR ": " $0
  }
  END { if (d > 0) print "UNCLOSED" }'

@test "#1671: automate-public.sh calls Snyk only inside a --vulnerabilities snyk branch" {
  local f="$SCRIPTS/automate-public.sh" outside
  # the guarded section really holds the Snyk steps
  awk '/^if \[\[ "\$VULNERABILITIES" == "snyk" \]\]; then$/ { on = 1; next } on && /^else$/ { exit } on { print }' "$f" |
    grep -q 'snyk auth --auth-type=token'
  outside="$(awk "$SNYK_SCAN_AWK" "$f")"
  [ -z "$outside" ] || { echo "$outside"; return 1; }
  grep -q '\[\[ "\$VULNERABILITIES" == "snyk" \]\] && public_tools+=(snyk)' "$f"
}

@test "MUTATION: the Snyk scan reports a Snyk call in a guard's else (trivy) arm, and an unclosed guard" {
  local f="$BATS_TEST_TMPDIR/sample.sh"
  printf '%s\n' 'if [[ "$VULNERABILITIES" == "snyk" ]]; then' '	snyk auth --auth-type=token' 'else' \
    '	snyk config get api' 'fi' > "$f"
  run awk "$SNYK_SCAN_AWK" "$f"
  [ "$output" = "4: 	snyk config get api" ]
  printf '%s\n' 'if [[ "$VULNERABILITIES" == "snyk" ]]; then' '	snyk auth --auth-type=token' > "$f"
  run awk "$SNYK_SCAN_AWK" "$f"
  [ "$output" = "UNCLOSED" ]
}

@test "#1671 AC9: each automate-*.sh forwards both toolchain values unchanged to its branch-protection.sh call" {
  local s call v
  for s in automate-public.sh automate-private.sh; do
    # the whole continued invocation, from the script name to its last line
    call="$(awk '/"\$SCRIPT_DIR\/branch-protection.sh"/ { on = 1 } on { print } on && !/\\$/ { exit }' "$SCRIPTS/$s")"
    [ -n "$call" ]
    contains "$call" '--static-analysis "$STATIC_ANALYSIS"'
    contains "$call" '--vulnerabilities "$VULNERABILITIES"'
    contains "$call" '--require-signed-commits "$REQUIRE_SIGNED_COMMITS"'
    lacks "$call" '--visibility'
    # assigned only by the default and the parser — anywhere on a line, and by
    # no read / printf -v / declare / export form — never re-derived later
    for v in STATIC_ANALYSIS VULNERABILITIES REQUIRE_SIGNED_COMMITS; do
      [ "$(grep -cE "(^|[^A-Za-z0-9_])$v=" "$SCRIPTS/$s")" -eq 2 ] ||
        { echo "$s assigns $v outside the default + parser"; return 1; }
      run ! grep -nE "(read[^#]*[[:space:]]$v([[:space:]]|$)|printf -v $v|(declare|export|typeset)[^#]*[[:space:]]$v=)" "$SCRIPTS/$s"
    done
  done
}

@test "#1671 AC9: Step 4.5's two automate-*.sh invocations in SKILL.md pass both toolchain flags" {
  local s block
  for s in automate-public.sh automate-private.sh; do
    block="$(awk -v s="scripts/$s\"" 'index($0, s) { on = 1 } on { print } on && !/\\$/ { exit }' "$SKILL")"
    [ -n "$block" ]
    contains "$block" '--static-analysis "<static_analysis from resolve-tools.zsh>"'
    contains "$block" '--vulnerabilities "<vulnerabilities from resolve-tools.zsh>"'
    contains "$block" '--require-signed-commits "<Step 4b'"'"'s signing value>"'
  done
}

@test "#1671: every --require-signed-commits in SKILL.md takes Step 4b's one signing value, which never defaults an unreadable setting to false" {
  # the script clears the requirement on anything but `true`, so every site —
  # Step 4b, State D's gap-fill, Step 4.5's two re-applies — derives the value once
  local joined
  joined="$(tr -s '[:space:]' ' ' < "$SKILL")"
  # the one normative statement: the live setting counts, only a known "no rule"
  # is false, and every unreadable state asks
  contains "$joined" "\`true\` when \`--signed-commits\` was passed at invocation or \`github_state.branch_protection.required_signatures\` is \`true\`;"
  contains "$joined" "no rule exists yet (\`branch_protection.state\` is \`missing\`, or there is no \`github_state\`)"
  contains "$joined" "the field is \`null\`, or \`state\` is \`forbidden\` or \`unknown\`"
  contains "$joined" 'passed, **ask the user** whether signed commits are required'
  # Step 4b's own block takes it too
  local block
  block="$(awk -v s="scripts/branch-protection.sh\" \\\\" 'index($0, s) { on = 1 } on { print } on && !/\\$/ { exit }' "$SKILL")"
  contains "$block" "--require-signed-commits \"<Step 4b's signing value — below>\""
  # State D's gap-fill points at it rather than restating it
  contains "$joined" "\`--require-signed-commits\` with *Step 4b's signing value*"
  # and no site still derives it from the invocation flag alone
  lacks "$joined" 'true if --signed-commits was passed at invocation, else false'
}

# --- AC10: the IaC path neither requires nor reads the toolchain --------------------------

stage_iac_workflow() {
  cp "$REPO_ROOT/development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl" \
    "$W/.github/workflows/kubernetes-ci.yml"
}

# The IaC preflight set: gh, jq, git and the script's own iac_brews, sorted.
iac_expected() {
  { printf '%s\n' gh jq git; sed -n 's/^iac_brews=(\(.*\))$/\1/p' "$PREFLIGHT" | tr ' ' '\n'; } |
    awk 'NF' | LC_ALL=C sort
}

@test "#1671 AC10: --iac-only true with neither toolchain flag behaves as today on both scripts" {
  protection_stubs
  stage_iac_workflow
  cd "$W"
  run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --has-dockerfile false --has-codeql false --iac-only true --default-branch main
  [ "$status" -eq 0 ]
  [ "$(put_contexts)" = "gate" ]
  preflight_stubs
  run --separate-stderr run_preflight --has-dockerfile true --iac-only true --assume-yes
  [ "$status" -eq 0 ]
  [ "$(checked_tools "$output")" = "$(iac_expected)" ]
  lacks "$output" 'Checking Docker'
}

@test "#1671 AC10: under --iac-only true a passed toolchain — even an out-of-set one — is neither validated nor read" {
  protection_stubs
  stage_iac_workflow
  local sa v
  for sa in sonarqube bogus; do
    for v in snyk grype; do
      : > "$CURL_DATA"
      run --separate-stderr protect_in_fixture --static-analysis "$sa" --vulnerabilities "$v" \
        --has-dockerfile false --has-codeql false --iac-only true --default-branch main
      [ "$status" -eq 0 ] || { echo "branch-protection $sa/$v: $stderr"; return 1; }
      lacks "$stderr" 'must be'
      [ "$(put_contexts)" = "gate" ]
    done
  done
  preflight_stubs
  for sa in sonarqube bogus; do
    for v in snyk grype; do
      run --separate-stderr run_preflight --static-analysis "$sa" --vulnerabilities "$v" \
        --has-dockerfile false --iac-only true --assume-yes
      [ "$status" -eq 0 ] || { echo "preflight $sa/$v: $stderr"; return 1; }
      lacks "$stderr" 'must be'
      # the IaC set exactly: snyk-cli is never added, and no Docker check runs
      [ "$(checked_tools "$output")" = "$(iac_expected)" ]
      lacks "$output" 'Checking Docker'
    done
  done
}

@test "#1671 AC10: the §3l IaC-path invocations in SKILL.md pass neither toolchain flag" {
  # Step 4b's and Step 4.5's shared blocks mark both flags as omitted there …
  local s block
  for s in branch-protection.sh preflight.sh; do
    block="$(awk -v s="scripts/$s\" \\\\" 'index($0, s) { on = 1 } on { print } on && !/\\$/ { exit }' "$SKILL")"
    [ -n "$block" ]
    contains "$block" '--static-analysis "<static_analysis from resolve-tools.zsh — OMIT on the §3l IaC path>"'
    contains "$block" '--vulnerabilities "<vulnerabilities from resolve-tools.zsh — OMIT on the §3l IaC path>"'
  done
  # … and the three IaC-path sites say so: §3l's Step 4b call, State D's gap-fill
  # and the Step 4.5 preflight note
  grep -qF '`branch-protection.sh` with `--iac-only true` and neither toolchain flag' "$SKILL"
  # joined, since the prose wraps wherever its paragraph does
  local joined
  joined="$(tr -s '[:space:]' ' ' < "$SKILL" | sed 's/ > / /g')"
  contains "$joined" '**On the §3l path pass neither toolchain flag**'
  contains "$joined" '**with `--iac-only true` and neither toolchain flag**'
}

# --- AC8: no --visibility invocation anywhere -------------------------------------------

# The sweep, shared by the AC8 test and its MUTATION check so the two cannot
# drift: a command is joined across `\` continuations, so a flag on a later line
# of a multi-line invocation is attributed to it; each hit prints FILE:LINE.
SWEEP_AWK='
  FNR == 1 { cmd = ""; start = 0 }
  {
    if (cmd == "") start = FNR
    cmd = cmd " " $0
    if ($0 ~ /\\$/) next
    if (cmd ~ /(branch-protection|preflight)\.sh|\$PROTECT|\$PREFLIGHT/ && cmd ~ /--visibility/) print FILENAME ":" start
    cmd = ""
  }'

@test "#1671 AC8: no tracked invocation of branch-protection.sh or preflight.sh passes --visibility" {
  # This file is the one exclusion: its AC1 test must pass the refused flag to
  # prove the refusal. The two scripts' own refusal arms name the flag they refuse.
  local files hits
  files="$(cd "$REPO_ROOT" && git ls-files -- . ':!docs/superpowers' ':!tests/fixtures' \
    ':!tests/bootstrap-toolchain-protection.bats')"
  # the sweep must actually have something to sweep — an empty listing (no .git,
  # a pathspec typo) would otherwise pass vacuously
  [ "$(printf '%s\n' "$files" | grep -c .)" -gt 100 ]
  grep -qx 'development/skills/bootstrap/SKILL.md' <<< "$files"
  hits="$(cd "$REPO_ROOT" && printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 awk "$SWEEP_AWK" |
    grep -vE '^development/skills/bootstrap/scripts/(branch-protection|preflight)\.sh:' || true)"
  [ -z "$hits" ] || { echo "$hits"; return 1; }
}

@test "#1671 AC8: SETUP.md.tmpl 3g's re-run command passes the toolchain and the CodeQL languages" {
  local block
  # from the heading through its fenced block's closing fence
  block="$(awk '/^### What if the rule is too strict\?/ { on = 1 } on { print } on && /^```/ { if (++n == 2) exit }' \
    "$REPO_ROOT/development/skills/bootstrap/templates/common/SETUP.md.tmpl")"
  contains "$block" 'branch-protection.sh'
  contains "$block" '--static-analysis <sonarcloud|sonarqube>'
  contains "$block" '--vulnerabilities <snyk|trivy>'
  contains "$block" '--codeql-languages'
  contains "$block" '--has-ko'
  contains "$block" '--iac-only false'
  contains "$block" 'pass --iac-only true'
  lacks "$block" '--visibility'
}

@test "MUTATION: the AC8 sweep catches a --visibility on a continuation line of a branch-protection.sh call" {
  # the sweep's reason to join continuations: prove the SHARED program bites on
  # the multi-line shape, and stays quiet on the same call without the flag
  local f="$BATS_TEST_TMPDIR/sample.md"
  printf '%s\n' '"<dir>/scripts/branch-protection.sh" \' '  --visibility public \' '  --default-branch main' > "$f"
  run awk "$SWEEP_AWK" "$f"
  [ "$output" = "$f:1" ]
  printf '%s\n' '"<dir>/scripts/branch-protection.sh" \' '  --static-analysis sonarcloud \' '  --default-branch main' > "$f"
  run awk "$SWEEP_AWK" "$f"
  [ -z "$output" ]
}
