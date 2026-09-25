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
#   * THE BEHAVIOUR. With --iac-only true the script really checks that set plus
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

@test "preflight --iac-only true checks gh, jq, git and the gate's tools, and nothing from the language-app batch (#1605)" {
  preflight_stubs
  run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
    --languages "" --has-dockerfile false --iac-only true --assume-yes
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
    --static-analysis sonarqube --vulnerabilities trivy --languages "" --has-dockerfile false --iac-only true --assume-yes </dev/null
  [ "$status" -eq 0 ]
  lacks "$output" 'Checking Docker'
  # …nor does one that carries a tooling Dockerfile
  run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
    --languages "" --has-dockerfile true --iac-only true --assume-yes </dev/null
  [ "$status" -eq 0 ]
  lacks "$output" 'Checking Docker'
}

@test "preflight --iac-only true adds no language or claude-plugin tools, whatever --languages and the cwd say (#1605)" {
  preflight_stubs
  # the language loop and the .claude-plugin -> parallel block only add a tool when
  # their input asks for one, so give them both: three languages and the marker
  mkdir -p .claude-plugin
  printf '{}\n' > .claude-plugin/marketplace.json
  run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
    --languages "swift python go" --has-dockerfile false --iac-only true --assume-yes
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

@test "preflight --iac-only true reports a yq that is not mikefarah's v4 as missing, and accepts mikefarah's (#1637)" {
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
      --languages "" --has-dockerfile false --iac-only true --assume-yes
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
      --languages "" --has-dockerfile false --iac-only true --assume-yes
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
    --languages "" --has-dockerfile false --iac-only true --assume-yes
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

@test "preflight without --iac-only still checks the language-app batch, and a bad --iac-only value is refused (#1605)" {
  preflight_stubs
  run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
    --static-analysis sonarcloud --vulnerabilities snyk --languages "" --has-dockerfile false --assume-yes
  [ "$status" -eq 0 ]
  local checked
  checked="$(checked_tools "$output")"
  contains $'\n'"$checked"$'\n' $'\npre-commit\n'
  contains $'\n'"$checked"$'\n' $'\nsnyk-cli\n'
  lacks $'\n'"$checked"$'\n' $'\nhelm\n'
  # an EXPLICIT false — what Step 4.5 passes on every language repo — is the same path
  run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" \
    --static-analysis sonarcloud --vulnerabilities snyk --languages "" --has-dockerfile false --iac-only false --assume-yes
  [ "$status" -eq 0 ]
  checked="$(checked_tools "$output")"
  contains $'\n'"$checked"$'\n' $'\npre-commit\n'
  lacks $'\n'"$checked"$'\n' $'\nhelm\n'
  # a value merely CONTAINING a valid token is refused too — `truex` pins the end
  # anchor, `xtrue` the start anchor, `True` the case — like the exact `== "true"`
  # the validation guards
  local v
  for v in yes truex xtrue True; do
    run --separate-stderr env PATH="$TEST_PATH" bash "$PREFLIGHT" --iac-only "$v"
    [ "$status" -eq 1 ]
    contains "$stderr" '--iac-only must be true or false'
  done
}
