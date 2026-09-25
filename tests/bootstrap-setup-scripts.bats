#!/usr/bin/env bats
#
# #1769 — Step 4.5 runs one setup script per tool, each under its own trigger,
# instead of the two visibility-split automation scripts it retires.
# Each script runs here against stubbed gh / snyk / docker / curl (plus the
# macOS-only security and the prompts), and the stubs' call log is the oracle:
# the expected calls are the issue's Scope table, never read back from the
# script under test.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/bootstrap/scripts"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  SETUP_TMPL="$REPO_ROOT/development/skills/bootstrap/templates/common/SETUP.md.tmpl"
  NEW_SCRIPTS=(setup-sonarcloud.sh setup-sonarqube.sh register-runner.sh setup-snyk.sh enable-github-security.sh)
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  STAGE="$BATS_TEST_TMPDIR/scripts"
  W="$BATS_TEST_TMPDIR/repo"
  CALLS="$BATS_TEST_TMPDIR/external-calls.log"
  SNYK_STATE="$BATS_TEST_TMPDIR/snyk-authed"
  INT_COUNT="$BATS_TEST_TMPDIR/int-count"
  mkdir -p "$STUB_BIN" "$STAGE" "$W"
  : > "$CALLS"
  export CALLS SNYK_STATE INT_COUNT
}

# Stage a copy of the scripts whose lib.sh answers every prompt without a TTY:
# ask_yn with $1 (yes|no), ask_secret with a fixed SonarCloud user token.
stage_scripts() {
  local answer="${1:-yes}" s
  for s in "${NEW_SCRIPTS[@]}" lib.sh; do
    cp "$SCRIPTS/$s" "$STAGE/"
  done
  if [ "$answer" = yes ]; then
    printf '%s\n' 'ask_yn() { return 0; }' >> "$STAGE/lib.sh"
  else
    printf '%s\n' 'ask_yn() { return 1; }' >> "$STAGE/lib.sh"
  fi
  printf '%s\n' 'ask_secret() { printf -v "$2" "%s" "${ASK_SECRET-sonar-user-token}"; }' >> "$STAGE/lib.sh"
}

# Every external command a script could reach, stubbed to log into $CALLS. Pass
# the names to leave OUT (to prove a tool is required).
stubs() {
  local skip=" $* " c
  ln -sf "$(command -v jq)" "$STUB_BIN/jq"
  for c in gh snyk docker curl security openssl open uname; do
    [[ "$skip" == *" $c "* ]] && continue
    "stub_$c"
  done
}

# Knobs: GH_EMPTY (a substring whose query answers nothing) and GH_FAIL (a
# substring whose call exits 1).
stub_gh() {
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >> "$CALLS"
case "$*" in *"${GH_FAIL:-@none@}"*) exit 1 ;; *"${GH_EMPTY:-@none@}"*) exit 0 ;; esac
case "$*" in
  *defaultBranchRef*) echo main ;;
  *nameWithOwner*) echo acme/app ;;
  *releases/latest*) echo v2.320.0 ;;
  *registration-token*) echo reg-tok ;;
esac
exit 0
EOF
  chmod +x "$STUB_BIN/gh"
}

# `snyk config get api` answers only once `snyk auth` has run (or the test
# pre-authenticates by touching $SNYK_STATE).
stub_snyk() {
  cat > "$STUB_BIN/snyk" <<'EOF'
#!/bin/sh
echo "snyk $*" >> "$CALLS"
case "$*" in
  "auth --auth-type=token") [ -n "$SNYK_AUTH_NOOP" ] || : > "$SNYK_STATE" ;;
  "config get api") [ -e "$SNYK_STATE" ] && echo snyk-tok || exit 2 ;;
  "config get org") [ -n "$SNYK_NO_ORG" ] || echo "${SNYK_ORG:-acme}" ;;
esac
exit 0
EOF
  chmod +x "$STUB_BIN/snyk"
}

stub_docker() {
  printf '#!/bin/sh\necho "docker $* @$PWD" >> "$CALLS"\nexit 0\n' > "$STUB_BIN/docker"
  chmod +x "$STUB_BIN/docker"
}

stub_open() {
  printf '#!/bin/sh\necho "open $*" >> "$CALLS"\nexit 0\n' > "$STUB_BIN/open"
  chmod +x "$STUB_BIN/open"
}

stub_openssl() {
  printf '#!/bin/sh\necho "openssl $*" >> "$CALLS"\necho stubpwstubpwstubpwstubpwstubpwstubpw\n' > "$STUB_BIN/openssl"
  chmod +x "$STUB_BIN/openssl"
}

# An empty Keychain — every lookup misses — unless KEYCHAIN_PW holds a stored
# password; every add is logged.
stub_security() {
  cat > "$STUB_BIN/security" <<'EOF'
#!/bin/sh
echo "security $*" >> "$CALLS"
case "$1" in
  find-generic-password) [ -n "$KEYCHAIN_PW" ] || exit 44; echo "$KEYCHAIN_PW" ;;
esac
exit 0
EOF
  chmod +x "$STUB_BIN/security"
}

# uname -m answers $UNAME_M (arm64 by default), so the arch mapping is pinned
# whatever the host's CPU.
stub_uname() {
  printf '#!/bin/sh\n[ "$1" = -m ] && { echo "${UNAME_M:-arm64}"; exit 0; }\nexec /usr/bin/uname "$@"\n' > "$STUB_BIN/uname"
  chmod +x "$STUB_BIN/uname"
}

# curl answers the Sonar, Snyk and runner-download endpoints the way their APIs
# do, honouring -o and -w, and logs "curl <METHOD> <url> [<form fields>…]".
# The analysis token and the admin token differ, so a swap between them shows.
# Credentials are logged last, as auth=<user:pw> and hdr=<Authorization header>.
# Knobs: SONAR_VALID, SONAR_ORGS, ORGS_CODE, GATE_CODE (400 answers the gate
# search with id 7), SELECT_CODE, PROJECT_CREATE (exists|clash), CHANGE_PW_CODE,
# TOKEN_EMPTY, ADMIN_TOKEN_EMPTY, INT_MISSING (answers with no GitHub
# integration that many times; the count lives in $INT_COUNT) and IMPORT_CODE.
stub_curl() {
  cat > "$STUB_BIN/curl" <<'EOF'
#!/bin/sh
out="" method=GET url="" w="" fields="" cred=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -w) w="$2"; shift 2 ;;
    --data-urlencode | --data) fields="$fields $2"; shift 2 ;;
    -u) cred="$cred auth=$2"; shift 2 ;;
    -H) case "$2" in Authorization*) cred="$cred hdr=$2" ;; esac; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "curl $method $url$fields$cred" >> "$CALLS"
code=200 body='{}'
case "$method $url" in
  *api/authentication/validate) body="{\"valid\":${SONAR_VALID:-true}}" ;;
  *api/organizations/search*)
    orgs='[{"key":"acme-github"}]'
    [ -n "$SONAR_ORGS" ] && orgs="$SONAR_ORGS"
    code="${ORGS_CODE:-200}" body="{\"organizations\":$orgs}" ;;
  *api/qualitygates/create\?*) code="${GATE_CODE:-200}" body='{"id":"42"}' ;;
  *api/qualitygates/search*) body='{"qualitygates":[{"name":"Zero Tolerance","id":"7"}]}' ;;
  *api/qualitygates/select) code="${SELECT_CODE:-204}" body='' ;;
  *api/system/status) body='{"status":"UP"}' ;;
  *api/users/change_password) code="${CHANGE_PW_CODE:-204}" body='' ;;
  *api/projects/create)
    case "$PROJECT_CREATE" in
      exists) code=400 body='{"errors":[{"msg":"Project key already exists"}]}' ;;
      clash) code=400 body='{"errors":[{"msg":"Malformed key"}]}' ;;
    esac ;;
  *api/user_tokens/generate)
    if [ -n "$TOKEN_EMPTY" ]; then body='{"token":""}'
    else case "$fields" in
      *PROJECT_ANALYSIS_TOKEN*) body='{"token":"tok-analysis"}' ;;
      *) [ -n "$ADMIN_TOKEN_EMPTY" ] && body='{"token":""}' || body='{"token":"tok-admin"}' ;;
    esac; fi ;;
  *api/user_tokens/revoke) code=204 body='' ;;
  "GET https://api.snyk.io/v1/orgs") body='{"orgs":[{"slug":"acme","id":"org-1"}]}' ;;
  *org/org-1/integrations)
    n=$(cat "$INT_COUNT" 2>/dev/null || echo 0)
    if [ "$n" -lt "${INT_MISSING:-0}" ]; then echo $((n + 1)) > "$INT_COUNT"; body='{}'
    else body='{"github":"int-9"}'; fi ;;
  *integrations/int-9/import) code="${IMPORT_CODE:-201}" ;;
  *actions/runner/releases/download/*) cp "$RUNNER_FIXTURE" "$out"; out="" body="" ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
[ -n "$w" ] && printf "$(printf '%s' "$w" | sed "s/%{http_code}/$code/")"
exit 0
EOF
  chmod +x "$STUB_BIN/curl"
}

# Run a staged script from the fixture repo, on a PATH of the stubs and the base
# system only.
run_setup() {
  local s="$1"
  shift
  cd "$W"
  run --separate-stderr env PATH="$STUB_BIN:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR" \
    bash "$STAGE/$s" "$@" </dev/null
}

# Run a staged script with <tool>'s stub removed and no system bin dir on PATH,
# so the host's own copy cannot stand in for it.
run_without() {
  local tool="$1" s="$2" mini="$BATS_TEST_TMPDIR/mini-bin"
  shift 2
  rm -f "$STUB_BIN/$tool"
  mkdir -p "$mini"
  ln -sf "$(command -v dirname)" "$mini/dirname"
  cd "$W"
  run --separate-stderr env PATH="$STUB_BIN:$mini" "$(command -v bash)" "$STAGE/$s" "$@" </dev/null
}

@test "#1769: each setup script requires its tools before any external call" {
  stage_scripts yes
  local case tool s
  for case in docker:setup-sonarqube.sh jq:setup-sonarcloud.sh curl:register-runner.sh gh:enable-github-security.sh; do
    tool="${case%%:*}" s="${case#*:}"
    stubs
    : > "$CALLS"
    case "$s" in
      setup-sonarqube.sh) run_without "$tool" "$s" --project-key k --project-name n ;;
      setup-sonarcloud.sh) run_without "$tool" "$s" --project-key k --org-key o --project-name n ;;
      enable-github-security.sh) run_without "$tool" "$s" --visibility public ;;
      *) run_without "$tool" "$s" ;;
    esac
    [ "$status" -eq 1 ] || { echo "$s ran without $tool"; return 1; }
    contains "$stderr" "Required tool(s) not on PATH: $tool"
    [ ! -s "$CALLS" ]
  done
}

# --- setup-sonarcloud.sh ---------------------------------------------------------------

@test "#1769 AC4: setup-sonarcloud.sh validates the token, resolves the org slug, sets the gate and stores SONAR_TOKEN" {
  stage_scripts yes
  stubs
  printf 'sonar.projectKey=k\nsonar.organization=acme\n' > "$W/sonar-project.properties"
  run_setup setup-sonarcloud.sh --project-key k --org-key acme --project-name n
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  local log
  log="$(cat "$CALLS")"
  contains "$log" 'open https://sonarcloud.io/projects/create'
  contains "$log" 'curl GET https://sonarcloud.io/api/authentication/validate auth=sonar-user-token:'
  contains "$log" 'curl GET https://sonarcloud.io/api/organizations/search?member=true'
  # no org is keyed exactly `acme`, so the -github variant is taken, and the
  # properties follow it
  grep -qx 'sonar.organization=acme-github' "$W/sonar-project.properties"
  contains "$log" 'curl POST https://sonarcloud.io/api/qualitygates/create?name=Zero%20Tolerance&organization=acme-github'
  contains "$log" 'metric=new_coverage op=LT error=90'
  contains "$log" 'curl POST https://sonarcloud.io/api/qualitygates/select gateName=Zero Tolerance projectKey=k organization=acme-github auth=sonar-user-token:'
  contains "$output" 'Zero Tolerance custom gate (created + assigned)'
  # both secret scopes
  contains "$log" 'gh secret set SONAR_TOKEN -b sonar-user-token'
  contains "$log" 'gh secret set SONAR_TOKEN --app dependabot -b sonar-user-token'
  # nothing that belongs to another script
  lacks "$log" 'snyk '
  lacks "$log" 'docker '
  lacks "$log" 'SONAR_HOST_URL'
  lacks "$log" 'vulnerability-alerts'
}

@test "#1769: setup-sonarcloud.sh prefers the org keyed exactly as the owner, and opens no browser when declined" {
  stage_scripts no
  stubs
  printf 'sonar.organization=acme\n' > "$W/sonar-project.properties"
  SONAR_ORGS='[{"key":"acme-github"},{"key":"acme"}]' run_setup setup-sonarcloud.sh --project-key k --org-key acme --project-name n
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  grep -qx 'sonar.organization=acme' "$W/sonar-project.properties"
  contains "$output" 'Org slug matches: acme'
  grep -q 'qualitygates/create?name=Zero%20Tolerance&organization=acme auth=' "$CALLS"
  run ! grep -q '^open ' "$CALLS"
}

@test "#1769: setup-sonarcloud.sh falls back to Sonar way on a 403 gate create, and still stores SONAR_TOKEN" {
  stage_scripts yes
  stubs
  GATE_CODE=403 run_setup setup-sonarcloud.sh --project-key k --org-key acme --project-name n
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  contains "$output" 'Sonar way (Free-plan fallback'
  run ! grep -q 'api/qualitygates/select' "$CALLS"
  grep -q 'gh secret set SONAR_TOKEN -b sonar-user-token' "$CALLS"
}

@test "#1769: setup-sonarcloud.sh stores no secret for an invalid token or an unmatched org" {
  stage_scripts yes
  stubs
  SONAR_VALID=false run_setup setup-sonarcloud.sh --project-key k --org-key acme --project-name n
  [ "$status" -eq 1 ]
  contains "$stderr" 'Token validation failed'
  SONAR_ORGS='[{"key":"other"}]' run_setup setup-sonarcloud.sh --project-key k --org-key acme --project-name n
  [ "$status" -eq 1 ]
  contains "$stderr" "No SonarCloud org matches 'acme' or 'acme-github'"
  run ! grep -q 'gh secret set' "$CALLS"
}

@test "#1769: setup-sonarcloud.sh stops on an empty token paste or a failed org search" {
  stage_scripts yes
  stubs
  ASK_SECRET= run_setup setup-sonarcloud.sh --project-key k --org-key acme --project-name n
  [ "$status" -eq 1 ]
  contains "$stderr" 'Empty token'
  run ! grep -q -e '^curl' -e 'gh secret set' "$CALLS"
  ORGS_CODE=500 run_setup setup-sonarcloud.sh --project-key k --org-key acme --project-name n
  [ "$status" -eq 1 ]
  contains "$stderr" 'Could not enumerate SonarCloud orgs (HTTP 500)'
  run ! grep -q 'gh secret set' "$CALLS"
}

@test "#1769: setup-sonarcloud.sh reports a paywalled assignment, reuses an existing gate, and stops on a gate error" {
  stage_scripts yes
  stubs
  SELECT_CODE=403 run_setup setup-sonarcloud.sh --project-key k --org-key acme --project-name n
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  contains "$output" 'Zero Tolerance gate exists but unassigned (Free-plan paywall)'
  : > "$CALLS"
  GATE_CODE=400 run_setup setup-sonarcloud.sh --project-key k --org-key acme --project-name n
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  grep -q 'create_condition gateId=7 ' "$CALLS"
  : > "$CALLS"
  GATE_CODE=500 run_setup setup-sonarcloud.sh --project-key k --org-key acme --project-name n
  [ "$status" -eq 1 ]
  contains "$stderr" 'Quality Gate create failed (HTTP 500)'
  run ! grep -q 'gh secret set' "$CALLS"
}

@test "#1769: setup-sonarcloud.sh refuses a missing or unknown flag before any external call" {
  stage_scripts yes
  stubs
  run_setup setup-sonarcloud.sh --org-key o --project-name n
  [ "$status" -eq 1 ]
  contains "$stderr" '--project-key required'
  run_setup setup-sonarcloud.sh --project-key k --project-name n
  [ "$status" -eq 1 ]
  contains "$stderr" '--org-key required'
  run_setup setup-sonarcloud.sh --project-key k --org-key o
  [ "$status" -eq 1 ]
  contains "$stderr" '--project-name required'
  run_setup setup-sonarcloud.sh --project-key k --org-key
  [ "$status" -eq 1 ]
  contains "$stderr" '--org-key requires a value'
  lacks "$stderr" 'unbound variable'
  run_setup setup-sonarcloud.sh --project-key k --org-key o --project-name n --bogus
  [ "$status" -eq 1 ]
  contains "$stderr" 'Unknown argument: --bogus'
  [ ! -s "$CALLS" ]
}

# --- setup-sonarqube.sh ----------------------------------------------------------------

sonarqube_fixture() {
  mkdir -p "$W/infra/sonarqube"
  : > "$W/infra/sonarqube/docker-compose.yml"
}

@test "#1769 AC4: setup-sonarqube.sh starts SonarQube, keeps the admin password in the Keychain, and stores both secrets" {
  stage_scripts yes
  stubs
  sonarqube_fixture
  run_setup setup-sonarqube.sh --project-key k --project-name n
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  local log
  log="$(cat "$CALLS")"
  contains "$log" "docker compose up -d @$W/infra/sonarqube"
  contains "$log" 'curl GET http://localhost:9000/api/system/status'
  # the Keychain miss is looked up once, then one password is stored (#1789)
  [ "$(grep -c '^security find-generic-password ' "$CALLS")" -eq 1 ]
  grep -qx 'security find-generic-password -s sonarqube-local-admin -a admin -w' "$CALLS"
  [ "$(grep -c '^security add-generic-password ' "$CALLS")" -eq 1 ]
  # the one generated password is both stored and set
  contains "$log" 'security add-generic-password -U -s sonarqube-local-admin -a admin -w stubpwstubpwstubpwstubpwstub'
  contains "$log" 'curl POST http://localhost:9000/api/users/change_password login=admin previousPassword=admin password=stubpwstubpwstubpwstubpwstub auth=admin:admin'
  contains "$log" 'curl POST http://localhost:9000/api/projects/create project=k name=n auth=admin:stubpwstubpwstubpwstubpwstub'
  # the gate is driven by the admin token, which can change gates
  contains "$log" 'api/qualitygates/create?name=Zero%20Tolerance auth=tok-admin:'
  contains "$log" 'api/qualitygates/select gateName=Zero Tolerance projectKey=k auth=tok-admin:'
  contains "$output" 'Zero Tolerance custom gate (created + assigned)'
  contains "$log" 'type=PROJECT_ANALYSIS_TOKEN projectKey=k'
  contains "$log" 'gateName=Zero Tolerance projectKey=k'
  # the short-lived admin token is the one revoked, never the analysis token
  contains "$log" 'curl POST http://localhost:9000/api/user_tokens/revoke name=bootstrap-admin-'
  grep -q 'user_tokens/revoke name=bootstrap-admin-[0-9]* auth=admin:stubpwstubpwstubpwstubpwstub$' "$CALLS"
  lacks "$log" 'revoke name=k-analysis-'
  # the analysis token is the one stored, never the admin token
  contains "$log" 'gh secret set SONAR_TOKEN -b tok-analysis'
  contains "$log" 'gh secret set SONAR_TOKEN --app dependabot -b tok-analysis'
  lacks "$log" '-b tok-admin'
  contains "$log" 'gh secret set SONAR_HOST_URL -b http://localhost:9000'
  contains "$log" 'gh secret set SONAR_HOST_URL --app dependabot -b http://localhost:9000'
  # the generated password never reaches stdout or stderr
  lacks "$output" 'stubpwstubpw'
  lacks "$stderr" 'stubpwstubpw'
  # the runner is register-runner.sh's; the GitHub toggles enable-github-security.sh's
  lacks "$log" 'registration-token'
  lacks "$log" 'vulnerability-alerts'
}

@test "#1769: setup-sonarqube.sh reuses a Keychain password without printing it, and honours --sonar-host" {
  stage_scripts yes
  stubs
  sonarqube_fixture
  KEYCHAIN_PW=stored-pw-4711 run_setup setup-sonarqube.sh --project-key k --project-name n \
    --sonar-host http://sq.example:9000
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  local log
  log="$(cat "$CALLS")"
  contains "$output" 'Reusing admin password from Keychain'
  lacks "$output" 'stored-pw-4711'
  lacks "$stderr" 'stored-pw-4711'
  # one lookup, for the stored entry, and its value is the one used (#1789)
  [ "$(grep -c '^security find-generic-password ' "$CALLS")" -eq 1 ]
  grep -qx 'security find-generic-password -s sonarqube-local-admin -a admin -w' "$CALLS"
  contains "$log" 'curl POST http://sq.example:9000/api/projects/create project=k name=n auth=admin:stored-pw-4711'
  lacks "$log" 'add-generic-password'
  lacks "$log" 'change_password'
  contains "$log" 'curl GET http://sq.example:9000/api/system/status'
  contains "$log" 'gh secret set SONAR_HOST_URL -b http://sq.example:9000'
  contains "$log" 'gh secret set SONAR_HOST_URL --app dependabot -b http://sq.example:9000'
}

@test "#1769: setup-sonarqube.sh accepts an existing project and refuses any other 400" {
  stage_scripts yes
  stubs
  sonarqube_fixture
  PROJECT_CREATE=exists run_setup setup-sonarqube.sh --project-key k --project-name n
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  contains "$output" 'Project already exists'
  : > "$CALLS"
  PROJECT_CREATE=clash run_setup setup-sonarqube.sh --project-key k --project-name n
  [ "$status" -eq 1 ]
  contains "$stderr" 'Project create failed (HTTP 400)'
  run ! grep -q 'gh secret set' "$CALLS"
}

@test "#1769: setup-sonarqube.sh stores no secret when the password change or a token mint fails" {
  stage_scripts yes
  stubs
  sonarqube_fixture
  CHANGE_PW_CODE=401 run_setup setup-sonarqube.sh --project-key k --project-name n
  [ "$status" -eq 1 ]
  contains "$stderr" "security delete-generic-password -s 'sonarqube-local-admin' -a admin"
  CHANGE_PW_CODE=500 run_setup setup-sonarqube.sh --project-key k --project-name n
  [ "$status" -eq 1 ]
  contains "$stderr" 'Password change failed (HTTP 500)'
  TOKEN_EMPTY=1 run_setup setup-sonarqube.sh --project-key k --project-name n
  [ "$status" -eq 1 ]
  contains "$stderr" 'Empty analysis token in response'
  ADMIN_TOKEN_EMPTY=1 run_setup setup-sonarqube.sh --project-key k --project-name n
  [ "$status" -eq 1 ]
  contains "$stderr" 'Empty admin token in response'
  run ! grep -q 'gh secret set' "$CALLS"
}

@test "#1769: setup-sonarqube.sh stops at a missing compose file or a bad flag, before any external call" {
  stage_scripts yes
  stubs
  run_setup setup-sonarqube.sh --project-key k --project-name n
  [ "$status" -eq 1 ]
  contains "$stderr" 'docker-compose.yml — has bootstrap finished generating files?'
  run_setup setup-sonarqube.sh --project-name n
  [ "$status" -eq 1 ]
  contains "$stderr" '--project-key required'
  run_setup setup-sonarqube.sh --project-key k
  [ "$status" -eq 1 ]
  contains "$stderr" '--project-name required'
  run_setup setup-sonarqube.sh --project-key k --project-name n --sonar-host
  [ "$status" -eq 1 ]
  contains "$stderr" '--sonar-host requires a value'
  run_setup setup-sonarqube.sh --project-key k --project-name n --bogus
  [ "$status" -eq 1 ]
  contains "$stderr" 'Unknown argument: --bogus'
  [ ! -s "$CALLS" ]
}

# --- register-runner.sh ----------------------------------------------------------------

# A release tarball whose config.sh and svc.sh log like the stubs.
runner_release() {
  local rel="$BATS_TEST_TMPDIR/release" f
  mkdir -p "$rel"
  for f in config.sh svc.sh; do
    printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n' "$f" > "$rel/$f"
    chmod +x "$rel/$f"
  done
  RUNNER_FIXTURE="$BATS_TEST_TMPDIR/runner.tar.gz"
  tar -czf "$RUNNER_FIXTURE" -C "$rel" config.sh svc.sh
  export RUNNER_FIXTURE
  export RUNNER_DIR="$BATS_TEST_TMPDIR/actions-runner"
}

@test "#1769 AC4: register-runner.sh downloads, registers and installs the runner as a launchd service" {
  stage_scripts yes
  stubs
  runner_release
  UNAME_M=arm64 run_setup register-runner.sh
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  local log
  log="$(cat "$CALLS")"
  contains "$log" 'gh api repos/actions/runner/releases/latest --jq .tag_name'
  contains "$log" 'curl GET https://github.com/actions/runner/releases/download/v2.320.0/actions-runner-osx-arm64-2.320.0.tar.gz'
  contains "$log" 'gh api -X POST repos/acme/app/actions/runners/registration-token --jq .token'
  contains "$log" 'config.sh --url https://github.com/acme/app --token reg-tok'
  contains "$log" '-sonarqube --labels self-hosted,macOS,sonarqube --unattended --replace'
  # installed before it is started
  [ "$(grep -n 'svc.sh install' "$CALLS" | cut -d: -f1)" -lt "$(grep -n 'svc.sh start' "$CALLS" | cut -d: -f1)" ]
  [ ! -e "$RUNNER_DIR/actions-runner-osx-arm64-2.320.0.tar.gz" ]
}

@test "#1769: register-runner.sh defaults to ~/actions-runner" {
  stage_scripts yes
  stubs
  runner_release
  unset RUNNER_DIR
  run_setup register-runner.sh
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ -x "$BATS_TEST_TMPDIR/home/actions-runner/config.sh" ]
  grep -q 'config.sh --url https://github.com/acme/app' "$CALLS"
}

@test "#1769: register-runner.sh maps x86_64 to osx-x64 and refuses any other architecture" {
  stage_scripts yes
  stubs
  runner_release
  UNAME_M=x86_64 run_setup register-runner.sh
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  grep -q 'releases/download/v2.320.0/actions-runner-osx-x64-2.320.0.tar.gz' "$CALLS"
  rm -rf "$RUNNER_DIR"
  : > "$CALLS"
  UNAME_M=aarch64 run_setup register-runner.sh
  [ "$status" -eq 1 ]
  contains "$stderr" 'Unsupported architecture: aarch64'
  run ! grep -q 'config.sh' "$CALLS"
}

@test "#1769: register-runner.sh reuses a downloaded runner instead of downloading again" {
  stage_scripts yes
  stubs
  runner_release
  mkdir -p "$RUNNER_DIR"
  tar -xzf "$RUNNER_FIXTURE" -C "$RUNNER_DIR"
  run_setup register-runner.sh
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  contains "$output" 'Runner directory already exists'
  run ! grep -q 'releases/' "$CALLS"
  grep -q 'config.sh --url https://github.com/acme/app --token reg-tok' "$CALLS"
  grep -q 'svc.sh install' "$CALLS"
}

@test "#1769: register-runner.sh configures nothing without a runner version or a registration token" {
  stage_scripts yes
  stubs
  runner_release
  GH_EMPTY=releases/latest run_setup register-runner.sh
  [ "$status" -eq 1 ]
  contains "$stderr" 'Could not resolve the latest runner release'
  rm -rf "$RUNNER_DIR"
  GH_EMPTY=registration-token run_setup register-runner.sh
  [ "$status" -eq 1 ]
  contains "$stderr" 'Could not retrieve registration token'
  run ! grep -q 'config.sh' "$CALLS"
}

@test "#1769: register-runner.sh declined, or given an argument, registers nothing" {
  stage_scripts no
  stubs
  run_setup register-runner.sh
  [ "$status" -eq 0 ]
  contains "$output" 'Skipping runner registration'
  run_setup register-runner.sh --bogus
  [ "$status" -eq 1 ]
  contains "$stderr" 'Unknown argument: --bogus'
  [ ! -s "$CALLS" ]
}

# --- setup-snyk.sh ---------------------------------------------------------------------

@test "#1769 AC2/AC4: setup-snyk.sh authenticates in token mode, stores SNYK_TOKEN in both scopes, and imports the repo" {
  stage_scripts yes
  stubs
  run_setup setup-snyk.sh
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  local log
  log="$(cat "$CALLS")"
  contains "$log" 'snyk auth --auth-type=token'
  contains "$log" 'gh secret set SNYK_TOKEN -b snyk-tok'
  contains "$log" 'gh secret set SNYK_TOKEN --app dependabot -b snyk-tok'
  contains "$log" 'curl GET https://api.snyk.io/v1/org/org-1/integrations hdr=Authorization: token snyk-tok'
  contains "$output" 'Import job accepted by Snyk (HTTP 201)'
  lacks "$output" 'Unexpected response'
  contains "$log" 'curl POST https://api.snyk.io/v1/org/org-1/integrations/int-9/import'
  # the import names this repository and its default branch
  contains "$(tr -d ' \n' < "$CALLS")" '{"target":{"owner":"acme","name":"app","branch":"main"}}'
  # the two manual Snyk UI steps are printed, not skipped
  contains "$output" 'Manual step: enable Snyk auto-Fix-PRs'
  contains "$output" 'Manual step: configure Snyk PR status checks'
  # nothing Sonar's
  lacks "$log" 'SONAR_TOKEN'
}

@test "#1769: setup-snyk.sh reuses an existing Snyk login instead of re-authenticating" {
  stage_scripts yes
  stubs
  : > "$SNYK_STATE"
  run_setup setup-snyk.sh
  [ "$status" -eq 0 ]
  contains "$output" 'Snyk already authenticated'
  run ! grep -q 'snyk auth' "$CALLS"
  grep -q 'gh secret set SNYK_TOKEN -b snyk-tok' "$CALLS"
}

@test "#1769: setup-snyk.sh declined auth, an argument, or no snyk CLI stores nothing" {
  stage_scripts no
  stubs
  run_setup setup-snyk.sh
  [ "$status" -eq 1 ]
  contains "$stderr" 'Snyk auth declined'
  run ! grep -q -e 'snyk auth' -e 'gh secret set' "$CALLS"
  : > "$CALLS"
  run_setup setup-snyk.sh --bogus
  [ "$status" -eq 1 ]
  contains "$stderr" 'Unknown argument: --bogus'
  rm "$STUB_BIN/snyk"
  run_setup setup-snyk.sh
  [ "$status" -eq 1 ]
  contains "$stderr" 'Required tool(s) not on PATH: snyk'
  [ ! -s "$CALLS" ]
}

@test "#1769: setup-snyk.sh stores nothing when auth leaves no token" {
  stage_scripts yes
  stubs
  SNYK_AUTH_NOOP=1 run_setup setup-snyk.sh
  [ "$status" -eq 1 ]
  contains "$stderr" 'Could not read Snyk API token from local config'
  run ! grep -q 'gh secret set' "$CALLS"
}

@test "#1769: setup-snyk.sh re-asks for a missing GitHub integration, up to three times" {
  stage_scripts yes
  stubs
  INT_MISSING=2 run_setup setup-snyk.sh
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(grep -c '^open https://app.snyk.io/org/acme/manage/integrations' "$CALLS")" -eq 2 ]
  grep -q 'integrations/int-9/import' "$CALLS"
  : > "$CALLS"
  rm -f "$INT_COUNT"
  INT_MISSING=99 run_setup setup-snyk.sh
  [ "$status" -eq 1 ]
  contains "$stderr" 'still missing after 3 attempts'
  [ "$(grep -c '^open https://app.snyk.io/org/acme/manage/integrations' "$CALLS")" -eq 3 ]
  run ! grep -q '/import' "$CALLS"
}

@test "#1769: setup-snyk.sh falls back to the first listed org, and refuses a slug no org has" {
  stage_scripts yes
  stubs
  SNYK_NO_ORG=1 run_setup setup-snyk.sh
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  grep -q 'curl POST https://api.snyk.io/v1/org/org-1/integrations/int-9/import' "$CALLS"
  : > "$CALLS"
  SNYK_ORG=nobody run_setup setup-snyk.sh
  [ "$status" -eq 1 ]
  contains "$stderr" "Could not resolve Snyk org ID for slug 'nobody'"
  run ! grep -q '/import' "$CALLS"
}

@test "#1769: setup-snyk.sh treats an already-imported or unexpected import status as non-fatal" {
  stage_scripts yes
  stubs
  IMPORT_CODE=202 run_setup setup-snyk.sh
  [ "$status" -eq 0 ]
  contains "$output" 'Import job accepted by Snyk (HTTP 202)'
  IMPORT_CODE=409 run_setup setup-snyk.sh
  [ "$status" -eq 0 ]
  contains "$output" 'Project was already imported (HTTP 409)'
  IMPORT_CODE=500 run_setup setup-snyk.sh
  [ "$status" -eq 0 ]
  contains "$output" 'Unexpected response from Snyk import (HTTP 500)'
}

# --- enable-github-security.sh ---------------------------------------------------------

@test "#1769 AC5: enable-github-security.sh --visibility public enables all four feature groups" {
  stage_scripts yes
  stubs
  run_setup enable-github-security.sh --visibility public
  [ "$status" -eq 0 ]
  local log
  log="$(cat "$CALLS")"
  contains "$log" 'gh api --silent -X PUT repos/acme/app/vulnerability-alerts'
  contains "$log" 'gh api --silent -X PUT repos/acme/app/automated-security-fixes'
  contains "$log" 'gh api -X PATCH repos/acme/app -F security_and_analysis[secret_scanning][status]=enabled -F security_and_analysis[secret_scanning_push_protection][status]=enabled'
  contains "$log" 'gh api --silent -X PUT repos/acme/app/private-vulnerability-reporting'
  lacks "$output" 'GitHub Advanced Security'
}

@test "#1769 AC5: enable-github-security.sh --visibility private enables only the Dependabot toggles and prints the GHAS note" {
  stage_scripts yes
  stubs
  run_setup enable-github-security.sh --visibility private
  [ "$status" -eq 0 ]
  local log
  log="$(cat "$CALLS")"
  contains "$log" 'repos/acme/app/vulnerability-alerts'
  contains "$log" 'repos/acme/app/automated-security-fixes'
  lacks "$log" 'secret_scanning'
  lacks "$log" 'private-vulnerability-reporting'
  contains "$output" 'require GitHub Advanced Security on private repos'
}

@test "#1769: enable-github-security.sh warns on a failed toggle and still runs the rest" {
  stage_scripts yes
  stubs
  GH_FAIL=vulnerability-alerts run_setup enable-github-security.sh --visibility public
  [ "$status" -eq 0 ]
  contains "$output" 'Dependabot alerts: enable call returned non-zero'
  grep -q 'automated-security-fixes' "$CALLS"
  grep -q 'private-vulnerability-reporting' "$CALLS"
  : > "$CALLS"
  GH_FAIL='-X PATCH' run_setup enable-github-security.sh --visibility public
  [ "$status" -eq 0 ]
  contains "$output" 'Secret scanning: enable call failed'
  grep -q 'private-vulnerability-reporting' "$CALLS"
  : > "$CALLS"
  GH_FAIL=automated-security-fixes run_setup enable-github-security.sh --visibility public
  [ "$status" -eq 0 ]
  contains "$output" 'Automated security fixes: enable call returned non-zero'
  grep -q -- '-X PATCH repos/acme/app' "$CALLS"
  grep -q 'private-vulnerability-reporting' "$CALLS"
  : > "$CALLS"
  GH_FAIL=private-vulnerability-reporting run_setup enable-github-security.sh --visibility public
  [ "$status" -eq 0 ]
  contains "$output" 'PVR: enable call returned non-zero'
}

@test "#1769: enable-github-security.sh refuses a bad flag or an unresolvable repo before any toggle" {
  stage_scripts yes
  stubs
  local v
  for v in '' internal Public publicx; do
    run_setup enable-github-security.sh --visibility "$v"
    [ "$status" -eq 1 ]
    contains "$stderr" '--visibility must be public or private'
  done
  run_setup enable-github-security.sh --visibility
  [ "$status" -eq 1 ]
  contains "$stderr" '--visibility must be public or private'
  lacks "$stderr" 'unbound variable'
  run_setup enable-github-security.sh
  [ "$status" -eq 1 ]
  run_setup enable-github-security.sh --visibility public --bogus
  [ "$status" -eq 1 ]
  contains "$stderr" 'Unknown argument: --bogus'
  [ ! -s "$CALLS" ]
  GH_EMPTY=nameWithOwner run_setup enable-github-security.sh --visibility public
  [ "$status" -eq 1 ]
  contains "$stderr" 'Could not resolve this repository'
  run ! grep -q 'vulnerability-alerts' "$CALLS"
}

# --- the retirement, repo-wide ---------------------------------------------------------

@test "#1769 AC4: the retired scripts are gone, and no setup script calls branch-protection.sh" {
  # built from pieces so AC6's sweep does not find its own needles here
  local a="automate-" s
  [ ! -e "$SCRIPTS/${a}public.sh" ]
  [ ! -e "$SCRIPTS/${a}private.sh" ]
  for s in "${NEW_SCRIPTS[@]}"; do
    [ -x "$SCRIPTS/$s" ]
    run ! grep -n 'branch-protection' "$SCRIPTS/$s"
  done
}

@test "#1769 AC6: no reference to the retired script names survives outside docs/superpowers/ and tests/fixtures/" {
  # built from pieces so this file's own needles cannot match themselves
  local a="automate-" hits rc=0
  hits="$(cd "$REPO_ROOT" && git grep -n -e "${a}public.sh" -e "${a}private.sh" -- . \
    ':!docs/superpowers' ':!tests/fixtures')" || rc=$?
  # 1 is "no match"; anything else (128: not a git checkout) proves nothing
  [ "$rc" -le 1 ] || { echo "git grep exited $rc"; return 1; }
  [ -z "$hits" ] || { echo "$hits"; return 1; }
}

# --- Step 4.5 in SKILL.md --------------------------------------------------------------

# The Per-tool automation table's trigger cell for one script.
trigger_of() {
  awk -v s="| \`$1\` |" 'index($0, s) == 1 { n = split($0, c, "|"); print c[n - 1]; exit }' "$SKILL" |
    sed 's/^ *//; s/ *$//'
}

# Whether a trigger cell holds for a resolved toolchain (resolve-tools.zsh's
# key=value lines in $RESOLVED, plus $APPROVER). An unknown trigger fails.
trigger_holds() {
  local t="$1" k v
  case "$t" in
    'every non-IaC repo') return 0 ;;
    '`--claude-approver` resolved `true` and an Approver-capable language resolves'*) [ "$APPROVER" = true ]; return ;;
  esac
  k="$(printf '%s' "$t" | sed -nE 's/^`([a-z_]+)` is `([a-z]+)`.*/\1/p')"
  v="$(printf '%s' "$t" | sed -nE 's/^`([a-z_]+)` is `([a-z]+)`.*/\2/p')"
  [ -n "$k" ] || { echo "unknown trigger: $t" >&2; return 2; }
  grep -qx "$k=$v" <<< "$RESOLVED"
}

# The Step 4.5 scripts that run for a visibility and toolchain, one per line.
step45_runs() { # <visibility> <static_analysis> <vulnerabilities> <approver>
  local s t rc
  RESOLVED="$(cd "$BATS_TEST_TMPDIR" && zsh "$SCRIPTS/resolve-tools.zsh" --visibility "$1" \
    --maintenance-file "$BATS_TEST_TMPDIR/none.yml" --static-analysis "$2" --vulnerabilities "$3" \
    --code-scanning none)"
  [ -n "$RESOLVED" ] || return 1
  APPROVER="$4"
  for s in "${NEW_SCRIPTS[@]}" install-claude-apps.zsh; do
    t="$(trigger_of "$s")"
    [ -n "$t" ] || { echo "no Step 4.5 row for $s" >&2; return 1; }
    rc=0
    trigger_holds "$t" || rc=$?
    [ "$rc" -le 1 ] || return 1
    [ "$rc" -eq 0 ] && echo "$s"
  done
  return 0
}

@test "#1769 AC1: #1670 row 8 (private, sonarcloud + snyk) runs no register-runner.sh and no setup-sonarqube.sh" {
  local runs
  runs="$(step45_runs private sonarcloud snyk false)"
  [ "$runs" = "$(printf '%s\n' setup-sonarcloud.sh setup-snyk.sh enable-github-security.sh)" ] ||
    { echo "$runs"; return 1; }
}

@test "#1769 AC2: setup-snyk.sh runs for snyk whatever the visibility, and never for trivy" {
  local vis sa
  for vis in public private; do
    sa=sonarcloud
    grep -qx setup-snyk.sh <<<"$(step45_runs "$vis" "$sa" snyk false)"
    run ! grep -qx setup-snyk.sh <<<"$(step45_runs "$vis" "$sa" trivy false)"
  done
  grep -qx setup-snyk.sh <<<"$(step45_runs private sonarqube snyk false)"
  run ! grep -qx setup-snyk.sh <<<"$(step45_runs private sonarqube trivy false)"
  # and no Dockerfile clause narrows the trigger
  contains "$(trigger_of setup-snyk.sh)" 'whatever the visibility or Dockerfile'
}

@test "#1769: a private SonarQube repo runs the SonarQube script and the runner, not SonarCloud's" {
  local runs
  runs="$(step45_runs private sonarqube trivy false)"
  [ "$runs" = "$(printf '%s\n' setup-sonarqube.sh register-runner.sh enable-github-security.sh)" ] ||
    { echo "$runs"; return 1; }
}

@test "#1769 AC5: Step 4.5 runs install-claude-apps.zsh iff --claude-approver resolved true (and an Approver-capable language resolves)" {
  grep -qx install-claude-apps.zsh <<<"$(step45_runs public sonarcloud snyk true)"
  run ! grep -qx install-claude-apps.zsh <<<"$(step45_runs public sonarcloud snyk false)"
  local block
  block="$(sed -n '/^### Per-tool automation/,/^### `--claude-plugin true` extension/p' "$SKILL")"
  contains "$block" '"<skill-base-dir>/scripts/install-claude-apps.zsh"'
  contains "$block" '"<skill-base-dir>/scripts/enable-github-security.sh" --visibility "<public|private>"'
}

@test "MUTATION: the trigger evaluator rejects a trigger it does not know" {
  RESOLVED='static_analysis=sonarcloud'
  APPROVER=false
  run trigger_holds 'on Tuesdays'
  [ "$status" -eq 2 ]
  run trigger_holds '`static_analysis` is `sonarqube`'
  [ "$status" -eq 1 ]
  run trigger_holds '`static_analysis` is `sonarcloud` — public or private'
  [ "$status" -eq 0 ]
}

# --- SETUP.md.tmpl ---------------------------------------------------------------------

@test "#1769 AC7: SETUP.md.tmpl §4 says Step 4b applies branch-protection.sh, not the automation scripts" {
  local s4
  s4="$(sed -n '/^## 4\. GitHub branch protection/,/^## 5\./p' "$SETUP_TMPL" | tr -s '[:space:]' ' ')"
  [ -n "$s4" ]
  contains "$s4" "Bootstrap's Step 4b applies it for you"
  lacks "$s4" 'The automation scripts above invoke it automatically'
}

@test "#1769 AC8: the §2 setup-sonarcloud.sh callout sits inside SONARCLOUD and outside any PUBLIC wrapper" {
  # walk the template's markers: the callout line must see SONARCLOUD open and
  # PUBLIC closed
  run awk '
    /<!-- --- SONARCLOUD-START --- -->/ { cloud = 1 }
    /<!-- --- SONARCLOUD-END --- -->/ { cloud = 0 }
    /<!-- --- PUBLIC-START --- -->/ { pub = 1 }
    /<!-- --- PUBLIC-END --- -->/ { pub = 0 }
    index($0, "`<skill-base-dir>/scripts/setup-sonarcloud.sh`") { n++; print cloud + 0, pub + 0 }
    END { if (n != 1) print "count", n }' "$SETUP_TMPL"
  [ "$status" -eq 0 ]
  [ "$output" = "1 0" ]
}
