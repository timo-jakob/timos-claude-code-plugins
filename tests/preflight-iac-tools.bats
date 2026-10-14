#!/usr/bin/env bats
#
# preflight.sh --iac-only (#1605) — the §3l IaC path's local toolchain.
#
# Two claims, tested apart:
#
#   * THE LIST. preflight's `iac_brews` array is exactly the gate's toolchain: the
#     tools the bootstrapped scripts/k8s-gate.zsh refuses to run without (its
#     `require_tool` lines) plus the standalone `kustomize` it prefers, and
#     exactly the tools kubernetes-ci.yml pins (tests/iac-tools.zsh --print-pins
#     reads those pins). Three sources, one set — a tool added to the gate but not
#     to the preflight leaves every local `make lint` refusing on a tool
#     bootstrap never offered to install.
#   * THE BEHAVIOUR. With --iac-only kubernetes the script really checks that set plus
#     gh/jq/git and nothing from the language-app batch — observed from its own
#     per-tool report lines, with uname, brew and gh stubbed so it runs anywhere.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PREFLIGHT="$REPO_ROOT/development/skills/bootstrap/scripts/preflight.sh"
  GATE_TMPL="$REPO_ROOT/development/skills/bootstrap/templates/iac/scripts/k8s-gate.zsh.tmpl"
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  # the host's own parallel and yq must not answer for the stubs: Ubuntu CI
  # apt-installs GNU parallel into /usr/bin, and a runner image can ship a yq there.
  # HIDE_BIN shadows both with a command that fails, ahead of /usr/bin; anything the
  # stub brew installs lands in STUB_BIN, ahead of HIDE_BIN
  HIDE_BIN="$BATS_TEST_TMPDIR/hide-bin"
  mkdir -p "$HIDE_BIN"
  printf '#!/bin/sh\nexit 127\n' > "$HIDE_BIN/parallel"
  printf '#!/bin/sh\nexit 127\n' > "$HIDE_BIN/yq"
  chmod +x "$HIDE_BIN/parallel" "$HIDE_BIN/yq"
  TEST_PATH="$STUB_BIN:$HIDE_BIN:/usr/bin:/bin"
  # preflight probes the cwd for a .claude-plugin marker; keep it out of this repo
  cd "$BATS_TEST_TMPDIR"
}

# The `iac_brews` array of a preflight script, one tool per line, sorted.
iac_brews_of() {
  sed -n 's/^iac_brews=(\(.*\))$/\1/p' "$1" | tr ' ' '\n' | awk 'NF' | LC_ALL=C sort
}

# The three-way agreement, on the preflight script given: a count of seven, and
# the array equal to the gate's `require_tool` names plus kustomize and to the
# first column of the workflow pins. A pins read that fails yields an empty list,
# which cannot equal a seven-tool array — fail-closed.
iac_lists_agree() {
  local brews gate pins
  brews="$(iac_brews_of "$1")"
  gate="$({ awk '$1 == "require_tool" { print $2 }' "$GATE_TMPL"; printf 'kustomize\n'; } | LC_ALL=C sort)"
  pins="$(zsh "$REPO_ROOT/tests/iac-tools.zsh" --print-pins | awk '{ print $1 }' | LC_ALL=C sort)"
  [ "$(printf '%s\n' "$brews" | awk 'NF' | wc -l | tr -d ' ')" -eq 7 ] || return 1
  [ "$brews" = "$gate" ] || return 1
  [ "$brews" = "$pins" ]
}

@test "preflight's iac_brews, the gate script's required tools plus kustomize, and the workflow pins are one set of seven (#1605)" {
  run iac_lists_agree "$PREFLIGHT"
  [ "$status" -eq 0 ]
}

@test "MUTATION: dropping or misspelling helm in iac_brews breaks the three-way agreement (#1605)" {
  local dropped="$BATS_TEST_TMPDIR/preflight-no-helm.sh" misspelt="$BATS_TEST_TMPDIR/preflight-hlem.sh"
  sed 's/^iac_brews=(helm /iac_brews=(/' "$PREFLIGHT" > "$dropped"
  sed 's/^iac_brews=(helm /iac_brews=(hlem /' "$PREFLIGHT" > "$misspelt"
  # each mutation must have bitten (exactly 1 = the files differ)
  run cmp -s "$PREFLIGHT" "$dropped"
  [ "$status" -eq 1 ]
  run cmp -s "$PREFLIGHT" "$misspelt"
  [ "$status" -eq 1 ]
  # the count guard catches the drop; the equality catches a same-size change
  run iac_lists_agree "$dropped"
  [ "$status" -eq 1 ]
  run iac_lists_agree "$misspelt"
  [ "$status" -eq 1 ]
}

# Stubs that let preflight.sh run end to end on any host: uname answers Darwin,
# brew reports every formula absent and records what it is asked to install, gh
# is authenticated.
preflight_stubs() {
  printf '#!/bin/sh\necho Darwin\n' > "$STUB_BIN/uname"
  cat > "$STUB_BIN/brew" <<'EOF'
#!/bin/sh
case "$1" in
  list) exit 1 ;;
  install)
    shift
    printf '%s\n' "$@" >> "$BREW_INSTALLS"
    # installing yq or parallel puts mikefarah's yq or GNU parallel into this stub
    # directory — unless one of that name is already there
    for f in "$@"; do
      if [ "$f" = yq ] && [ ! -e "$(dirname "$0")/yq" ]; then
        printf '#!/bin/sh\necho "yq (https://github.com/mikefarah/yq/) version v4.44.3"\n' > "$(dirname "$0")/yq"
        chmod +x "$(dirname "$0")/yq"
      fi
      if [ "$f" = parallel ] && [ ! -e "$(dirname "$0")/parallel" ]; then
        printf '#!/bin/sh\necho "GNU parallel 20240822"\n' > "$(dirname "$0")/parallel"
        chmod +x "$(dirname "$0")/parallel"
      fi
    done
    ;;
esac
exit 0
EOF
  printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/uname" "$STUB_BIN/brew" "$STUB_BIN/gh"
  BREW_INSTALLS="$BATS_TEST_TMPDIR/brew-installs"
  : > "$BREW_INSTALLS"
  export BREW_INSTALLS
}

# The tools a preflight run CHECKED, one per line, sorted: the name on each
# `✓ <tool>` / `! <tool> — missing` line of the tool loop, colour codes removed.
# A `done` flag rather than `exit`: awk keeps draining its input, so sed never
# writes into a closed pipe (#1797).
checked_tools() {
  printf '%s\n' "$1" | sed $'s/\e\\[[0-9;]*m//g' | awk '
    done { next }
    /Checking required tools/ { on = 1; next }
    on && !($1 == "✓" || $1 == "!") { on = 0; done = 1; next }
    on { print $2 }
  ' | LC_ALL=C sort
}

@test "preflight --iac-only kubernetes checks gh, jq, git and the gate's tools, and nothing from the language-app batch (#1605)" {
  preflight_stubs
  run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
    --languages "" --has-dockerfile false --iac-only kubernetes --assume-yes
  [ "$status" -eq 0 ]
  local checked expected t
  checked="$(checked_tools "$output")"
  expected="$({ printf '%s\n' gh jq git; iac_brews_of "$PREFLIGHT"; } | LC_ALL=C sort)"
  [ "$(printf '%s\n' "$checked" | awk 'NF' | wc -l | tr -d ' ')" -eq 10 ]
  [ "$checked" = "$expected" ]
  for t in pre-commit gitleaks semgrep sonar-scanner snyk-cli; do
    lacks $'\n'"$checked"$'\n' $'\n'"$t"$'\n'
    lacks $'\n'"$(cat "$BREW_INSTALLS")"$'\n' $'\n'"$t"$'\n'
  done
  # positive control: the stub did record this run's installs, so the lacks above
  # are not passing on an empty file
  contains $'\n'"$(cat "$BREW_INSTALLS")"$'\n' $'\nhelm\n'
  # an IaC repo needs no Docker even when handed a toolchain that would (sonarqube,
  # trivy): with no docker on PATH and no TTY, the Docker check would exit non-zero
  run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
    --static-analysis sonarqube --vulnerabilities trivy --languages "" --has-dockerfile false --iac-only kubernetes --assume-yes </dev/null
  [ "$status" -eq 0 ]
  lacks "$output" 'Checking Docker'
  # …nor does one that carries a tooling Dockerfile
  run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
    --languages "" --has-dockerfile true --iac-only kubernetes --assume-yes </dev/null
  [ "$status" -eq 0 ]
  lacks "$output" 'Checking Docker'
}

@test "preflight --iac-only kubernetes adds no language or claude-plugin tools, whatever --languages and the cwd say (#1605)" {
  preflight_stubs
  # the language loop and the .claude-plugin -> parallel block only add a tool when
  # their input asks for one, so give them both: three languages and the marker
  mkdir -p .claude-plugin
  printf '{}\n' > .claude-plugin/marketplace.json
  run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
    --languages "swift python go" --has-dockerfile false --iac-only kubernetes --assume-yes
  [ "$status" -eq 0 ]
  local checked expected t
  checked="$(checked_tools "$output")"
  expected="$({ printf '%s\n' gh jq git; iac_brews_of "$PREFLIGHT"; } | LC_ALL=C sort)"
  [ "$checked" = "$expected" ]
  for t in swiftlint swiftformat ruff golangci-lint parallel; do
    lacks $'\n'"$(cat "$BREW_INSTALLS")"$'\n' $'\n'"$t"$'\n'
  done
  # positive control: the same inputs without --iac-only DO add them, so the lacks
  # above are not passing on inputs that add nothing
  : > "$BREW_INSTALLS"
  run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
    --static-analysis sonarcloud --vulnerabilities snyk --languages "swift python go" --has-dockerfile false --assume-yes
  [ "$status" -eq 0 ]
  for t in swiftlint swiftformat ruff golangci-lint parallel; do
    contains $'\n'"$(cat "$BREW_INSTALLS")"$'\n' $'\n'"$t"$'\n'
  done
}

@test "preflight --iac-only opentofu checks exactly gh jq git opentofu tflint trivy conftest, and no Docker (#2425)" {
  preflight_stubs
  run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
    --languages "" --has-dockerfile true --iac-only opentofu --assume-yes </dev/null
  [ "$status" -eq 0 ]
  local checked t
  checked="$(checked_tools "$output")"
  # the exact set, written out: a tool added to or dropped from tofu_brews reds this
  [ "$checked" = "$(printf '%s\n' conftest gh git jq opentofu tflint trivy | LC_ALL=C sort)" ]
  # and none of the kubernetes gate's tools: the two topics' toolchains stay apart
  for t in helm kustomize kubeconform kube-linter kyverno yq; do
    lacks $'\n'"$checked"$'\n' $'\n'"$t"$'\n'
  done
  contains $'\n'"$(cat "$BREW_INSTALLS")"$'\n' $'\nconftest\n'
  # a tooling Dockerfile does not pull in the Docker check on the IaC path
  lacks "$output" 'Checking Docker'
}

@test "preflight --iac-only opentofu adds no language or claude-plugin tools, whatever --languages and the cwd say (#2425)" {
  preflight_stubs
  mkdir -p .claude-plugin
  printf '{}\n' > .claude-plugin/marketplace.json
  run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
    --languages "swift python go" --has-dockerfile false --iac-only opentofu --assume-yes
  [ "$status" -eq 0 ]
  local t
  [ "$(checked_tools "$output")" = "$(printf '%s\n' conftest gh git jq opentofu tflint trivy | LC_ALL=C sort)" ]
  for t in pre-commit gitleaks semgrep sonar-scanner snyk-cli swiftlint swiftformat ruff golangci-lint parallel; do
    lacks $'\n'"$(cat "$BREW_INSTALLS")"$'\n' $'\n'"$t"$'\n'
  done
  contains $'\n'"$(cat "$BREW_INSTALLS")"$'\n' $'\nopentofu\n'
}

@test "preflight --iac-only opentofu counts a non-Homebrew tofu on PATH as the opentofu formula (#2425)" {
  # the formula is `opentofu` but its binary is `tofu`: without the map entry a
  # tofu from tenv, mise or a tarball reads as missing and is brew-installed again
  preflight_stubs
  printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/tofu"
  chmod +x "$STUB_BIN/tofu"
  run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
    --languages "" --has-dockerfile false --iac-only opentofu --assume-yes </dev/null
  [ "$status" -eq 0 ]
  lacks $'\n'"$(cat "$BREW_INSTALLS")"$'\n' $'\nopentofu\n'
}

@test "preflight --iac-only kubernetes reports a yq that is not mikefarah's v4 as missing, and accepts mikefarah's (#1637)" {
  preflight_stubs
  local v
  # a yq that is not mikefarah's v4 — kislyuk's python-yq, or mikefarah v3 — is
  # reported missing and installed; an install that leaves it first on PATH (the
  # stub brew adds no yq over an existing one) then fails rather than reporting ready
  for v in 'yq 3.4.3' 'yq version 3.4.1'; do
    : > "$BREW_INSTALLS"
    printf '#!/bin/sh\necho "%s"\n' "$v" > "$STUB_BIN/yq"
    chmod +x "$STUB_BIN/yq"
    run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
      --languages "" --has-dockerfile false --iac-only kubernetes --assume-yes
    [ "$status" -ne 0 ]
    contains "$output" 'yq — missing (mikefarah v4 required'
    contains "$output" "if Homebrew's python-yq is installed, 'brew unlink python-yq' before installing"
    contains $'\n'"$(cat "$BREW_INSTALLS")"$'\n' $'\nyq\n'
    contains "$stderr" 'is still not mikefarah'"'"'s v4 after install'
    contains "$stderr" "run 'brew link yq' and remove the other yq"
  done
  # both spellings mikefarah's v4 prints satisfy it, and neither is reinstalled
  for v in 'yq (https://github.com/mikefarah/yq/) version v4.44.3' 'yq version 4.20.2'; do
    : > "$BREW_INSTALLS"
    printf '#!/bin/sh\necho "%s"\n' "$v" > "$STUB_BIN/yq"
    chmod +x "$STUB_BIN/yq"
    run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
      --languages "" --has-dockerfile false --iac-only kubernetes --assume-yes
    [ "$status" -eq 0 ]
    contains "$output" 'yq (mikefarah v4)'
    lacks $'\n'"$(cat "$BREW_INSTALLS")"$'\n' $'\nyq\n'
  done
}

@test "preflight's post-install yq re-check finds the yq the install put earlier on PATH, not the python-yq behind it (#1637)" {
  preflight_stubs
  # python-yq sits LATER on PATH than the stub directory — but ahead of HIDE_BIN and
  # the host, so it is the yq the first check finds; the stub brew installs mikefarah's
  # yq into the earlier stub directory, so a re-check that reused the first lookup
  # would fail
  local late="$BATS_TEST_TMPDIR/late-bin"
  mkdir -p "$late"
  printf '#!/bin/sh\necho "yq 3.4.3"\n' > "$late/yq"
  chmod +x "$late/yq"
  run --separate-stderr env PATH="$STUB_BIN:$late:$HIDE_BIN:/usr/bin:/bin" bash "$PREFLIGHT" \
    --languages "" --has-dockerfile false --iac-only kubernetes --assume-yes
  [ "$status" -eq 0 ]
  contains "$output" 'yq — missing (mikefarah v4 required'
  contains $'\n'"$(cat "$BREW_INSTALLS")"$'\n' $'\nyq\n'
  [ -x "$STUB_BIN/yq" ]
  lacks "$stderr" 'still not mikefarah'
}

@test "preflight dies when a non-GNU parallel is still first on PATH after install, and passes once GNU parallel is (#1605)" {
  preflight_stubs
  # parallel is only required for a claude-plugin repo
  mkdir -p .claude-plugin
  printf '{}\n' > .claude-plugin/marketplace.json
  printf '#!/bin/sh\necho "parallel from moreutils"\nexit 1\n' > "$STUB_BIN/parallel"
  chmod +x "$STUB_BIN/parallel"
  run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
    --static-analysis sonarcloud --vulnerabilities snyk --languages "" --has-dockerfile false --assume-yes
  [ "$status" -ne 0 ]
  contains "$output" 'parallel — missing (GNU parallel required'
  contains $'\n'"$(cat "$BREW_INSTALLS")"$'\n' $'\nparallel\n'
  contains "$stderr" 'is still not GNU parallel after install'
  # with no other parallel in the way, the installed GNU parallel satisfies the re-check
  rm "$STUB_BIN/parallel"
  : > "$BREW_INSTALLS"
  run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
    --static-analysis sonarcloud --vulnerabilities snyk --languages "" --has-dockerfile false --assume-yes
  [ "$status" -eq 0 ]
  contains $'\n'"$(cat "$BREW_INSTALLS")"$'\n' $'\nparallel\n'
  lacks "$stderr" 'still not GNU parallel'
}

# The language-app tool sets, written out (#1639): an exact set catches a tool
# dropped from preflight.sh's lists AND one silently added to them, which a
# contains/lacks spot check cannot. Sorted the way checked_tools sorts.
LANG_APP_BATCH='gh git gitleaks jq pre-commit semgrep snyk-cli sonar-scanner'
POLYGLOT_BATCH='gh git gitleaks golangci-lint jq parallel pre-commit ruff semgrep sonar-scanner swiftformat swiftlint trivy'

# A docker stub that records each call and succeeds, so a toolchain that needs
# the Docker daemon (sonarqube, trivy) passes check_docker and
# check_docker_compose on any host instead of reaching the no-TTY install prompt.
docker_stub() {
  DOCKER_CALLS="$BATS_TEST_TMPDIR/docker-calls"
  : > "$DOCKER_CALLS"
  export DOCKER_CALLS
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$DOCKER_CALLS"\nexit 0\n' > "$STUB_BIN/docker"
  chmod +x "$STUB_BIN/docker"
}

# The tools one run of the preflight script $1 checked, space-joined, for the
# args after it. The run must exit 0; its stdout is kept in
# $BATS_TEST_TMPDIR/last-run.out (a path, since this runs inside `$(…)`).
checked_set() {
  local p="$1"
  shift
  env PATH="$TEST_PATH" bash "$p" "$@" --assume-yes </dev/null > "$BATS_TEST_TMPDIR/last-run.out" 2>/dev/null || return 1
  checked_tools "$(cat "$BATS_TEST_TMPDIR/last-run.out")" | tr '\n' ' ' | sed 's/ $//'
}

# The three exact-set checks, each on the preflight script given, so the
# MUTATION test below runs the very checks the tests run. A sonarqube or trivy
# run refuses to start without the docker stub on PATH.
language_batch_exact() {
  local p="$1"
  shift
  [ "$(checked_set "$p" --static-analysis sonarcloud --vulnerabilities snyk --languages "" --has-dockerfile false "$@")" = "$LANG_APP_BATCH" ]
}
sonarqube_batch_exact() {
  [ -x "$STUB_BIN/docker" ] || return 1
  [ "$(checked_set "$1" --static-analysis sonarqube --vulnerabilities snyk --languages "" --has-dockerfile false)" = "$LANG_APP_BATCH" ]
}
polyglot_exact() {
  [ -x "$STUB_BIN/docker" ] || return 1
  # a repo of its own holds the .claude-plugin marker, so no other run sees it
  local repo="$BATS_TEST_TMPDIR/polyglot-repo"
  mkdir -p "$repo/.claude-plugin"
  printf '{}\n' > "$repo/.claude-plugin/marketplace.json"
  [ "$(cd "$repo" && checked_set "$1" --static-analysis sonarcloud --vulnerabilities trivy --languages "swift python go javascript" --has-dockerfile false)" = "$POLYGLOT_BATCH" ]
}

@test "preflight without --iac-only still checks the language-app batch, and a bad --iac-only value is refused (#1605)" {
  preflight_stubs
  # exactly the eight tools, for both spellings of the language-app path (#1639)
  language_batch_exact "$PREFLIGHT"
  # an EXPLICIT false — what Step 4.5 passes on every language repo — is the same path
  language_batch_exact "$PREFLIGHT" --iac-only false
  # a value merely CONTAINING a valid token is refused too — `kubernetesx` pins
  # the end anchor, `xkubernetes` the start anchor, `Kubernetes` the case — like
  # the exact `== "kubernetes"` the validation guards. The refusal's wording is
  # pinned once, in tests/iac-only-enum.bats; this asserts only the refusal.
  local v
  for v in yes kubernetesx xkubernetes Kubernetes; do
    run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" --iac-only "$v"
    [ "$status" -eq 1 ]
    contains "$stderr" '--iac-only must be'
  done
}

@test "preflight with sonarqube checks the same eight tools and checks Docker instead of adding a formula (#1639)" {
  preflight_stubs
  docker_stub
  sonarqube_batch_exact "$PREFLIGHT"
  contains "$(cat "$BATS_TEST_TMPDIR/last-run.out")" 'Checking Docker'
  contains $'\n'"$(cat "$DOCKER_CALLS")"$'\n' $'\ninfo\n'
  contains $'\n'"$(cat "$DOCKER_CALLS")"$'\n' $'\ncompose version\n'
}

@test "preflight with trivy, four languages and the claude-plugin marker checks exactly thirteen tools (#1639)" {
  preflight_stubs
  docker_stub
  polyglot_exact "$PREFLIGHT"
}

@test "MUTATION: each tool dropped from or added to the language-app lists is caught by its exact-set check (#1639)" {
  preflight_stubs
  docker_stub
  # a mutated COPY of preflight.sh, with the lib.sh it sources beside it
  mutant() {
    local dir="$BATS_TEST_TMPDIR/mutant-$1"
    mkdir -p "$dir"
    cp "$REPO_ROOT/development/skills/bootstrap/scripts/lib.sh" "$dir/lib.sh"
    case "$1" in
    sonarqube-formula)
      awk '/^[[:space:]]*# Language-specific$/ { print "\t[[ \"$STATIC_ANALYSIS\" == sonarqube ]] && required_brews+=(\"sonarqube-extra\")" } { print }' \
        "$PREFLIGHT" > "$dir/preflight.sh" ;;
    javascript-eslint)
      sed 's/javascript) : ;;/javascript) required_brews+=("eslint") ;;/' "$PREFLIGHT" > "$dir/preflight.sh" ;;
    sonar-scanner)
      # added for either analyser, not listed (#2121): drop that line
      sed '/required_brews+=("sonar-scanner")/d' "$PREFLIGHT" > "$dir/preflight.sh" ;;
    *)
      # (a)-(f): one tool deleted from the always-required list
      sed "/^[[:space:]]*\"$1\"[[:space:]]*#/d" "$PREFLIGHT" > "$dir/preflight.sh" ;;
    esac
    printf '%s\n' "$dir/preflight.sh"
  }
  local m check copy
  # control: an UNMUTATED copy passes, so a red below is the mutation, not the copy
  copy="$(mutant unmutated-control)"
  language_batch_exact "$copy"
  for m in gh:language_batch_exact jq:language_batch_exact git:language_batch_exact \
    gitleaks:language_batch_exact semgrep:language_batch_exact sonar-scanner:language_batch_exact \
    sonarqube-formula:sonarqube_batch_exact javascript-eslint:polyglot_exact; do
    check="${m#*:}"
    copy="$(mutant "${m%%:*}")"
    # the mutation took effect: exactly 1 means the files differ
    run cmp -s "$PREFLIGHT" "$copy"
    [ "$status" -eq 1 ]
    run "$check" "$copy"
    [ "$status" -ne 0 ]
  done
}
