#!/usr/bin/env bats
#
# Behavioral tests for tests/iac-tools.zsh (#1199) — the script that resolves the
# PINNED toolchain tests/kubernetes-ci-fixtures.bats executes the bootstrapped
# kubernetes-ci workflow with.
#
# WHY THIS FILE MATTERS MORE THAN A HELPER'S TESTS USUALLY DO. This script is the
# seam that decides what "green" means for the whole real-tool harness. If it
# reads the wrong selector, accepts a loosely-matching version, or hands back a
# path that stops resolving once the harness `cd`s into a fixture copy, then
# every verdict in kubernetes-ci-fixtures.bats is measured with an unpinned tool
# — and the suite reports a green it did not earn. A silent mismeasurement is
# exactly the class the pinning exists to prevent, so the pinning itself needs
# tests.
#
# EVERY TEST HERE IS OFFLINE. The one path that would reach the network (a tool
# absent, or present at the wrong version) is exercised with a `curl` stub that
# fails, so the assertion is about WHICH tools the script decided to fetch —
# never about a download succeeding. Nothing in this file touches the real cache.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/tests/iac-tools.zsh"
  TMPL="$REPO_ROOT/development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl"
  BIN="$BATS_TEST_TMPDIR/bin"
  STUB="$BATS_TEST_TMPDIR/stub"
  CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export CURL_LOG
  mkdir -p "$BIN" "$STUB"
  : > "$CURL_LOG"
  # the platform leaf the script derives, computed here the same way so the
  # default-path test asserts against a derivation rather than a hardcoded pair
  case "$(uname -s)" in Darwin) OS=darwin ;; Linux) OS=linux ;; *) OS=unsupported ;; esac
  case "$(uname -m)" in arm64|aarch64) ARCH=arm64 ;; x86_64|amd64) ARCH=amd64 ;; *) ARCH=unsupported ;; esac
}

# The script prints its bin dir through zsh's `:A`, which resolves symlinks — and
# on macOS $BATS_TEST_TMPDIR lives under /var, a symlink to /private/var. So the
# expected value has to be resolved the same way; comparing against the
# unresolved path would fail on macOS and pass on Linux, which is precisely the
# platform-dependent assertion this suite's conventions exist to prevent.
resolved() {
  (cd "$1" && pwd -P)
}

# A template copy the tests are free to mutate — never the shipped one.
tmpl_copy() {
  cp "$TMPL" "$BATS_TEST_TMPDIR/tmpl.yml"
  printf '%s' "$BATS_TEST_TMPDIR/tmpl.yml"
}

# Fake binaries reporting exactly the pinned versions, so `have` is satisfied and
# nothing is fetched. The versions come from --print-pins rather than being
# restated, so this helper cannot drift from the script it is testing.
fake_toolchain() {
  local tool want probe pins
  # ASSIGNED first, then fed to the loop. `done <<< "$(…)"` puts the command
  # substitution in a REDIRECTION, whose status bash discards — so a failing
  # --print-pins would silently create zero fake binaries and every caller would
  # then resolve for real, over the network, in a file whose header promises it
  # never does.
  pins="$(zsh "$SCRIPT" --print-pins)"
  [ -n "$pins" ]
  while read -r tool want; do
    [ -n "$tool" ] || continue
    case "$tool" in
      helm)        probe="v${want}+gdeadbee" ;;
      kustomize)   probe="v${want}" ;;
      kubeconform) probe="v${want}" ;;
      kube-linter) probe="${want}" ;;
      kyverno)     probe="Version: ${want}" ;;
      yq)          probe="yq (https://github.com/mikefarah/yq/) version v${want}" ;;
      *) return 1 ;;
    esac
    printf '#!/bin/sh\necho "%s"\n' "$probe" > "$BIN/$tool"
    chmod +x "$BIN/$tool"
  done <<< "$pins"
}

# A curl that RECORDS its argv and then fails, so the "must fetch" branch is
# observable without a network round-trip — and so the URL it was asked for is
# assertable. Recording matters: every per-tool asset-name quirk (helm's nested
# member path, kube-linter's suffix-less amd64 name, kyverno's x86_64 spelling,
# yq's bare binary) lives in the URL, and a discarded argv leaves all four
# exercised only by a real download on whichever platform you happen to be on.
stub_failing_curl() {
  cat > "$STUB/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CURL_LOG"
exit 22
EOF
  chmod +x "$STUB/curl"
}

# Force a specific platform, so the arch-dependent URL legs are reachable on any
# host. The script resolves the platform with `uname -s` / `uname -m`.
stub_uname() {
  cat > "$STUB/uname" <<EOF
#!/bin/sh
case "\$1" in -s) echo $1 ;; -m) echo $2 ;; esac
EOF
  chmod +x "$STUB/uname"
}

# One pinned version read out of the template, guarded so it can never be the
# empty string. Returns non-zero (which errexit catches at the call site) rather
# than letting an unmatched selector become a silently-passing needle.
tmpl_pin() {
  local v
  v="$(yq -r "$1" "$TMPL")" || return 1
  [ -n "$v" ] || return 1
  [ "$v" != "null" ] || return 1
  printf '%s' "$v"
}

# A PATH holding ONLY the named commands, as symlinks to the real ones. This is
# how a genuinely-absent tool is tested: `PATH="$STUB"` alone also hides `zsh`,
# so the script never runs and the 127 masquerades as the guard firing.
#
# `--print-pins` reaches its answer with just zsh + grep + yq (the curl check and
# the platform resolution both sit below it), which is exactly the property these
# tests exist to pin.
minimal_path() {
  local dir="$BATS_TEST_TMPDIR/minimal" cmd resolved_cmd
  rm -rf "$dir"
  mkdir -p "$dir"
  for cmd in "$@"; do
    resolved_cmd="$(command -v "$cmd")"
    [ -n "$resolved_cmd" ]
    ln -s "$resolved_cmd" "$dir/$cmd"
  done
  printf '%s' "$dir"
}

# ---------------------------------------------------------------------------
# --print-pins — the single source the harness asserts against
# ---------------------------------------------------------------------------

@test "--print-pins reports all six tools, reading four of them from the template (#1199)" {
  run zsh "$SCRIPT" --print-pins
  [ "$status" -eq 0 ]
  # The four the template installs, asserted against the template itself rather
  # than restated — that equivalence is the whole reason the script reads them.
  #
  # Each expected value is EXTRACTED AND GUARDED first, never inlined into the
  # needle. `yq -r` prints nothing and exits 0 for a selector that matches no
  # node, so `contains "$output" "kubeconform $(yq …)"` would collapse to the
  # needle `"kubeconform "` — a substring of the very line it is checking. All
  # four cross-checks would then pass having compared the script's pin against
  # nothing, and this is the ONLY place they are compared: the selectors here
  # are an independent restatement of the script's, so a rename applied to
  # this copy is caught by nothing else.
  local want
  want="$(tmpl_pin '.jobs.schema.steps[] | select(.name == "install kubeconform") | .env.KUBECONFORM_VERSION')"
  contains "$output" "kubeconform $want"
  want="$(tmpl_pin '.jobs.lint.steps[] | select(.name == "install kube-linter") | .env.KUBE_LINTER_VERSION')"
  contains "$output" "kube-linter $want"
  want="$(tmpl_pin '.jobs.policy.env.KYVERNO_VERSION')"
  contains "$output" "kyverno $want"
  want="$(tmpl_pin '.jobs.argocd.steps[] | select(.name == "install yq") | .env.YQ_VERSION')"
  contains "$output" "yq $want"
  # and the two that exist nowhere but this script. Unanchored: `matches` takes
  # an ERE and bash's `=~` does not read `\n` as a newline, so a `(^|\n)` prefix
  # would only ever match the FIRST line — passing for helm and failing for
  # every tool after it, for a reason that has nothing to do with the pins.
  matches "$output" 'helm [0-9]+\.[0-9]+\.[0-9]+'
  matches "$output" 'kustomize [0-9]+\.[0-9]+\.[0-9]+'
  # exactly six lines: a seventh tool nobody installs, or a dropped one, both
  # break the harness's own count guard silently otherwise
  run bash -c "zsh '$SCRIPT' --print-pins | grep -c ."
  [ "$output" = "6" ]
}

@test "--print-pins installs nothing and needs no network (#1199)" {
  # it is a pure question about the template, so it must answer with a curl that
  # cannot work and an empty bin dir
  stub_failing_curl
  run env PATH="$STUB:$PATH" zsh "$SCRIPT" --print-pins --bin-dir "$BIN"
  [ "$status" -eq 0 ]
  lacks "$output" 'fetching'
  run bash -c "ls -A '$BIN'"
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# Reading the pins out of the template
# ---------------------------------------------------------------------------

@test "a missing version key is a typed failure, one per pin (#1199)" {
  # all four, not one exemplar: each is a separate selector into a separate job,
  # and a wrong one would silently pin a version nothing installs
  local t
  t="$(tmpl_copy)"

  yq -i 'del(.jobs.schema.steps[] | select(.name == "install kubeconform") | .env.KUBECONFORM_VERSION)' "$t"
  run zsh "$SCRIPT" --template "$t" --print-pins
  [ "$status" -eq 1 ]
  contains "$output" 'could not read KUBECONFORM_VERSION'

  t="$(tmpl_copy)"
  yq -i 'del(.jobs.lint.steps[] | select(.name == "install kube-linter") | .env.KUBE_LINTER_VERSION)' "$t"
  run zsh "$SCRIPT" --template "$t" --print-pins
  [ "$status" -eq 1 ]
  contains "$output" 'could not read KUBE_LINTER_VERSION'

  t="$(tmpl_copy)"
  yq -i 'del(.jobs.policy.env.KYVERNO_VERSION)' "$t"
  run zsh "$SCRIPT" --template "$t" --print-pins
  [ "$status" -eq 1 ]
  contains "$output" 'could not read KYVERNO_VERSION'

  t="$(tmpl_copy)"
  yq -i 'del(.jobs.argocd.steps[] | select(.name == "install yq") | .env.YQ_VERSION)' "$t"
  run zsh "$SCRIPT" --template "$t" --print-pins
  [ "$status" -eq 1 ]
  contains "$output" 'could not read YQ_VERSION'
}

@test "a version key set to null is refused, not spliced into a URL (#1199)" {
  # `yq -r` prints the STRING "null" for an absent key, which is non-empty — the
  # exact defect the script's guard exists for, and one a bare -n check misses
  local t
  t="$(tmpl_copy)"
  yq -i '(.jobs.policy.env.KYVERNO_VERSION) = null' "$t"
  # pin the MUTATION first: both tmpl_env guards (`-n` and `!= "null"`) produce
  # the same exit and the same message, so without this the test would pass
  # whether yq wrote a literal `null` — the branch this test is named for — or
  # an empty scalar, which the `-n` guard above it catches instead
  run yq -r '.jobs.policy.env.KYVERNO_VERSION' "$t"
  [ "$output" = "null" ]
  run zsh "$SCRIPT" --template "$t" --print-pins
  [ "$status" -eq 1 ]
  contains "$output" 'could not read KYVERNO_VERSION'
}

@test "a step name matching twice is refused rather than yielding two lines (#1199)" {
  # reading by step name is what keeps an inserted step from shifting the lookup;
  # a DUPLICATED name defeats that differently — two lines pass the -n/!= null
  # guard and then splice a newline into the download URL
  local t
  t="$(tmpl_copy)"
  yq -i '.jobs.lint.steps += [{"name": "install kube-linter", "run": "true", "env": {"KUBE_LINTER_VERSION": "9.9.9"}}]' "$t"
  run zsh "$SCRIPT" --template "$t" --print-pins
  [ "$status" -eq 1 ]
  contains "$output" 'matched more than one value'
}

# ---------------------------------------------------------------------------
# Usage taxonomy — 2 is the caller's mistake, 1 is a resolution failure
# ---------------------------------------------------------------------------

@test "flags that need a value, and unknown flags, exit 2 (#1199)" {
  run zsh "$SCRIPT" --bin-dir
  [ "$status" -eq 2 ]
  contains "$output" '--bin-dir needs a non-empty value'

  run zsh "$SCRIPT" --bin-dir ''
  [ "$status" -eq 2 ]

  run zsh "$SCRIPT" --template
  [ "$status" -eq 2 ]
  contains "$output" '--template needs a non-empty value'

  run zsh "$SCRIPT" --frobnicate
  [ "$status" -eq 2 ]
  contains "$output" 'unknown argument: --frobnicate'
}

@test "a caller-supplied template that does not exist is a usage error (2) (#1199)" {
  run zsh "$SCRIPT" --template "$BATS_TEST_TMPDIR/nope.yml" --print-pins
  [ "$status" -eq 2 ]
  contains "$output" 'workflow template not found'
}

@test "a missing DEFAULT template is a resolution failure (1), not a usage error (#1199)" {
  # the caller passed nothing wrong — the tree is not the one the script was
  # written against. Flattening the two would leave a wrapper unable to tell
  # "I called it wrong" from "this checkout is broken".
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere/tests"
  cp "$SCRIPT" "$BATS_TEST_TMPDIR/elsewhere/tests/iac-tools.zsh"
  run zsh "$BATS_TEST_TMPDIR/elsewhere/tests/iac-tools.zsh" --print-pins
  [ "$status" -eq 1 ]
  contains "$output" 'default path'
}

@test "the yq precondition is a typed exit 1, and checks the FLAVOUR not just presence (#1199)" {
  # These two guards are the first thing a developer on a fresh machine hits,
  # and they are pure diagnostics: delete either and the same failure re-surfaces
  # as 'could not read KUBECONFORM_VERSION' — sending the reader at a template
  # whose key is perfectly present.
  local bare
  bare="$(minimal_path zsh grep)"
  run env PATH="$bare" zsh "$SCRIPT" --print-pins
  [ "$status" -eq 1 ]
  contains "$output" 'mikefarah yq is required'

  # present but the WRONG yq: Debian/Ubuntu's `yq` is kislyuk's python-yq, a
  # different query language. A bare `command -v` would accept it.
  printf '#!/bin/sh\necho "yq 3.4.3"\n' > "$bare/yq"
  chmod +x "$bare/yq"
  run env PATH="$bare" zsh "$SCRIPT" --print-pins
  [ "$status" -eq 1 ]
  contains "$output" 'not mikefarah'
}

@test "curl is required only once something is actually downloaded (#1199)" {
  # --print-pins is documented as a pure question about the template that works
  # offline and on a platform the toolchain does not publish for. A curl
  # precondition ahead of it would break that contract for a query that
  # downloads nothing — and the failing-curl stub cannot catch it, because that
  # curl EXISTS.
  local nocurl
  nocurl="$(minimal_path zsh grep yq)"
  run env PATH="$nocurl" zsh "$SCRIPT" --print-pins
  [ "$status" -eq 0 ]
  contains "$output" 'kyverno '
  lacks "$output" 'curl is required'

  # ...but a real resolve does need it, and says so rather than failing later
  # with a download error
  run env PATH="$nocurl" zsh "$SCRIPT" --bin-dir "$BIN"
  [ "$status" -eq 1 ]
  contains "$output" 'curl is required'
}

@test "the pin sweep MAINTAINING.md documents still finds both constants (#1199)" {
  # MAINTAINING.md's quarterly inventory greps this script for the two pins that
  # exist nowhere else. Rewriting the line as `typeset`, indenting it, or moving
  # the pair into an array makes that command print NOTHING — which reads exactly
  # like "no pins to check", the failure the inventory exists to prevent.
  local pins helm_v kustomize_v
  pins="$(zsh "$SCRIPT" --print-pins)"
  helm_v="$(printf '%s\n' "$pins" | awk '$1 == "helm" { print $2 }')"
  kustomize_v="$(printf '%s\n' "$pins" | awk '$1 == "kustomize" { print $2 }')"
  [ -n "$helm_v" ]
  [ -n "$kustomize_v" ]
  run grep -n -E "^local (helm|kustomize)_v=" "$SCRIPT"
  [ "$status" -eq 0 ]
  contains "$output" "$helm_v"
  contains "$output" "$kustomize_v"
  # and MAINTAINING.md really does document that command
  run grep -F 'grep -n -E "^local (helm|kustomize)_v=" tests/iac-tools.zsh' "$REPO_ROOT/MAINTAINING.md"
  [ "$status" -eq 0 ]
}

@test "--help prints the usage header without resolving anything (#1199)" {
  stub_failing_curl
  run env PATH="$STUB:$PATH" zsh "$SCRIPT" --help
  [ "$status" -eq 0 ]
  contains "$output" '--print-pins'
  contains "$output" '--bin-dir'
  lacks "$output" 'fetching'
}

# ---------------------------------------------------------------------------
# Where the binaries land
# ---------------------------------------------------------------------------

@test "--bin-dir is taken exactly as given, with no os-arch leaf appended (#1199)" {
  fake_toolchain
  # curl stubbed to fail even though nothing should need it: that is what turns
  # "it happened not to fetch" into an assertion. Without it a regression in the
  # version probe would download the real toolchain and this test would STILL
  # pass, since the fetch and the post-install verification both succeed.
  stub_failing_curl
  run env PATH="$STUB:$PATH" zsh "$SCRIPT" --bin-dir "$BIN"
  [ "$status" -eq 0 ]
  lacks "$output" 'fetching'
  [ "$output" = "$(resolved "$BIN")" ]
  # the leaf belongs to the DEFAULT only — a caller naming a directory means
  # that directory, not a parent to hang a platform leaf off
  lacks "$output" "/$OS-$ARCH"
}

@test "the default hangs an os-arch leaf off the cache root, so host and container share it (#1199)" {
  # the property the Docker leg depends on: one mounted cache root, darwin and
  # linux binaries side by side rather than overwriting each other
  [ "$OS" != "unsupported" ]
  [ "$ARCH" != "unsupported" ]
  stub_failing_curl
  run env PATH="$STUB:$PATH" IAC_TOOLS_CACHE="$BATS_TEST_TMPDIR/cache" zsh "$SCRIPT" --print-pins
  [ "$status" -eq 0 ]
  # --print-pins answers before the platform is resolved, so drive the real path
  # with a pre-populated cache leaf instead
  mkdir -p "$BATS_TEST_TMPDIR/cache/$OS-$ARCH"
  BIN="$BATS_TEST_TMPDIR/cache/$OS-$ARCH" fake_toolchain
  run env PATH="$STUB:$PATH" IAC_TOOLS_CACHE="$BATS_TEST_TMPDIR/cache" zsh "$SCRIPT"
  [ "$status" -eq 0 ]
  lacks "$output" 'fetching'
  [ "$output" = "$(resolved "$BATS_TEST_TMPDIR/cache/$OS-$ARCH")" ]
  ends_with "$output" "/$OS-$ARCH"
}

@test "a relative bin dir is made absolute before it is printed (#1199)" {
  # the harness puts this on PATH and then cd's into the fixture copy, where a
  # relative entry resolves against THAT directory and matches nothing — so
  # every tool call would silently fall through to the host's binaries
  fake_toolchain
  stub_failing_curl
  # PATH inside the inner shell too — the stub is useless if only the outer one
  # sees it, which is how this test could quietly reach the network
  run env PATH="$STUB:$PATH" bash -c "cd '$BATS_TEST_TMPDIR' && zsh '$SCRIPT' --bin-dir bin"
  [ "$status" -eq 0 ]
  lacks "$output" 'fetching'
  starts_with "$output" '/'
  [ "$output" = "$(resolved "$BIN")" ]
}

# ---------------------------------------------------------------------------
# Idempotence and the version probe
# ---------------------------------------------------------------------------

@test "a warm cache resolves offline and fetches nothing (#1199)" {
  # what makes it safe to call from setup_file on every suite run, and what the
  # CI pre-warm step relies on
  fake_toolchain
  stub_failing_curl
  run env PATH="$STUB:$PATH" zsh "$SCRIPT" --bin-dir "$BIN"
  [ "$status" -eq 0 ]
  lacks "$output" 'fetching'
}

@test "a tool at the WRONG version is refetched, not accepted (#1199)" {
  fake_toolchain
  printf '#!/bin/sh\necho "Version: 0.0.1"\n' > "$BIN/kyverno"
  chmod +x "$BIN/kyverno"
  stub_failing_curl
  run env PATH="$STUB:$PATH" zsh "$SCRIPT" --bin-dir "$BIN"
  [ "$status" -eq 1 ]
  contains "$output" 'fetching kyverno'
  # and only kyverno: the other five were already right, so a probe that had
  # regressed to "always refetch" would show up here
  lacks "$output" 'fetching helm'
  lacks "$output" 'fetching kube-linter'
}

@test "the version probe is anchored — 1.13.40 does not satisfy a 1.13.4 pin (#1199)" {
  # the claim iac-tools.zsh's own comment makes, made executable. A substring
  # match would accept this binary and every fixture verdict would then be
  # measured with a tool nobody pinned.
  local want
  want="$(zsh "$SCRIPT" --print-pins | awk '$1 == "kyverno" { print $2 }')"
  [ -n "$want" ]
  fake_toolchain
  printf '#!/bin/sh\necho "Version: %s0"\n' "$want" > "$BIN/kyverno"
  chmod +x "$BIN/kyverno"
  stub_failing_curl
  run env PATH="$STUB:$PATH" zsh "$SCRIPT" --bin-dir "$BIN"
  [ "$status" -eq 1 ]
  contains "$output" 'fetching kyverno'
}

@test "a cold resolve reports EVERY tool it could not get, not just the first (#1199)" {
  # the keep-going loop: a developer offline should learn the whole story in one
  # run rather than one tool per attempt
  stub_failing_curl
  run env PATH="$STUB:$PATH" zsh "$SCRIPT" --bin-dir "$BIN"
  [ "$status" -eq 1 ]
  local tool
  for tool in helm kustomize kubeconform kube-linter kyverno yq; do
    contains "$output" "fetching $tool"
  done
  # the TYPED diagnostics, both shapes — without them a failed fetch surfaces as
  # tar's raw stderr and the URL that was actually requested is invisible
  contains "$output" 'download or extraction failed: https://'
  contains "$output" 'download failed: https://'
  # and nothing was left behind. The staging directories/files live INSIDE the
  # bin dir (so the install is an atomic rename), which is a bind-mounted,
  # actions/cache-persisted directory — leaked partial downloads would be
  # uploaded and restored forever.
  run bash -c "ls -A '$BIN'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "each tool's download URL matches its own asset-naming quirk, per platform (#1199)" {
  # Four quirks, each called out in the script as a trap and each previously
  # exercised only by a real download on the host's own platform — so
  # linux/arm64 (the Docker leg on an Apple Silicon host, the documented default
  # local run) and darwin/amd64 were covered by nothing at all.
  local plat os arch karch suffix want pins
  pins="$(zsh "$SCRIPT" --print-pins)"
  [ -n "$pins" ]
  for plat in "Darwin arm64 darwin arm64" "Darwin x86_64 darwin amd64" \
              "Linux aarch64 linux arm64" "Linux x86_64 linux amd64"; do
    set -- $plat
    stub_uname "$1" "$2"
    os="$3"; arch="$4"
    stub_failing_curl
    : > "$CURL_LOG"
    rm -rf "$BIN"; mkdir -p "$BIN"
    run env PATH="$STUB:$PATH" zsh "$SCRIPT" --bin-dir "$BIN"
    [ "$status" -eq 1 ]
    run cat "$CURL_LOG"
    [ "$status" -eq 0 ]

    # helm: nested member, and the tarball name carries os-arch
    want="$(printf '%s\n' "$pins" | awk '$1 == "helm" { print $2 }')"
    contains "$output" "https://get.helm.sh/helm-v${want}-${os}-${arch}.tar.gz"
    # kustomize: the tag is URL-escaped (kustomize%2Fv…)
    want="$(printf '%s\n' "$pins" | awk '$1 == "kustomize" { print $2 }')"
    contains "$output" "kustomize%2Fv${want}/kustomize_v${want}_${os}_${arch}.tar.gz"
    # kubeconform: the common os-arch shape
    want="$(printf '%s\n' "$pins" | awk '$1 == "kubeconform" { print $2 }')"
    # the version segment too — without it `want` is computed and thrown away,
    # and a copy-paste splicing another tool's version into this URL (the
    # realistic mutation across six near-identical fetch_tar calls) stays green
    # offline and only surfaces as a 404 on the first cold cache
    contains "$output" "download/v${want}/kubeconform-${os}-${arch}.tar.gz"
    # kube-linter: architecture as a SUFFIX, and OMITTED entirely for amd64
    want="$(printf '%s\n' "$pins" | awk '$1 == "kube-linter" { print $2 }')"
    suffix=""
    if [ "$arch" = "arm64" ]; then suffix="_arm64"; fi
    contains "$output" "download/v${want}/kube-linter-${os}${suffix}.tar.gz"
    # kyverno: amd64 spelled x86_64
    want="$(printf '%s\n' "$pins" | awk '$1 == "kyverno" { print $2 }')"
    karch="$arch"
    if [ "$arch" = "amd64" ]; then karch=x86_64; fi
    contains "$output" "kyverno-cli_v${want}_${os}_${karch}.tar.gz"
    # yq: a bare binary, not a tarball
    want="$(printf '%s\n' "$pins" | awk '$1 == "yq" { print $2 }')"
    contains "$output" "download/v${want}/yq_${os}_${arch}"
  done
}

@test "a download that succeeds but reports the WRONG version is refused (#1199)" {
  # The post-install re-check — the guard against a re-cut release or a redirect
  # serving something else — is unreachable with a failing curl, so nothing
  # exercised it. A tool that installs cleanly and then reports the wrong
  # version is exactly the silently-unpinned case the whole script exists to
  # prevent.
  #
  # yq takes the bare-binary path (fetch_bin), so a curl stub that writes an
  # executable to the -o target reproduces a fully successful download.
  fake_toolchain
  rm -f "$BIN/yq"
  cat > "$STUB/curl" <<'EOF'
#!/bin/sh
# find the -o target and write a binary that reports a version nobody pinned
out=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$out" ] || exit 22
printf '#!/bin/sh\necho "yq (https://github.com/mikefarah/yq/) version v9.9.9"\n' > "$out"
exit 0
EOF
  chmod +x "$STUB/curl"
  run env PATH="$STUB:$PATH" zsh "$SCRIPT" --bin-dir "$BIN"
  [ "$status" -eq 1 ]
  # the script's own typed message, binding the tool, the install path and the
  # verdict in one needle. A bare `contains "$output" 'yq'` would be satisfied by
  # the `fetching yq …` line printed long before the post-install check, so it
  # would hold even if the message named a different tool or none at all.
  # `resolved`, because the script prints its `:A`-normalised bin dir and
  # $BATS_TEST_TMPDIR lives under macOS's /var -> /private/var symlink
  contains "$output" "yq at $(resolved "$BIN")/yq does not report version"
}

@test "the IaC docs name no version literal — --print-pins is the only list (#1199)" {
  # The drift class this replaced: four documents used to restate the six pinned
  # versions in prose, none asserted, so bumping a template pin left them telling
  # the next reader to reproduce at the old version and to treat a red there as a
  # regression. They now point at --print-pins, which cannot drift. This is the
  # executable half of the guard MAINTAINING.md documents.
  # The pattern tolerates the two shapes a reintroduction would most likely
  # take, because these documents write tool names in backticks by convention
  # and releases are routinely written v-prefixed: `kube-linter` 0.7.6 and
  # kube-linter v0.7.6 both have to be caught, or the guard is narrower than its
  # own title. And the file list is the SAME GLOB MAINTAINING.md sweeps, not four
  # hardcoded paths — a fifth fixture variant must not be swept by the documented
  # command while going unasserted here.
  local pattern="(helm|kustomize|kubeconform|kube-linter|kyverno|yq)[\`'\"]?[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+"
  # the glob is expanded HERE, by the test body's own shell — never inside a
  # `bash -c "…$pattern…"`, where the backtick in the character class would be
  # read as command substitution and silently gut the pattern
  local docs=("$REPO_ROOT"/tests/README.md "$REPO_ROOT"/tests/fixtures/kubernetes-repo*/README.md)
  # ...and the glob really did reach the documents, so a renamed fixture tree
  # cannot make this test pass by matching nothing
  [ "${#docs[@]}" -ge 4 ]

  # A POSITIVE CONTROL, because everything below asserts a NEGATIVE. Without it
  # a pattern narrowed to `(helm)`, or one that lost `[[:space:]]+`, would match
  # nothing and the sweep would stay green — the guard silently retired, which
  # is the drift it exists to catch. Both shapes the pattern is widened for are
  # exercised here.
  printf '%s\n' 'kube-linter 0.7.6' '`kube-linter` v0.7.6' > "$BATS_TEST_TMPDIR/control.md"
  run grep -c -E "$pattern" "$BATS_TEST_TMPDIR/control.md"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]

  run grep -rn -E "$pattern" "${docs[@]}"
  # grep exits 1 when nothing matches — which is the passing case here
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  # and MAINTAINING.md still documents the same guard, so the two cannot drift
  # apart. Match the phrase itself rather than a neighbouring word: the sentence
  # is wrapped across comment lines, so a line-oriented grep for the lead-in
  # returns a line the needle is not on.
  run grep -F 'must print NOTHING' "$REPO_ROOT/MAINTAINING.md"
  [ "$status" -eq 0 ]
  # ...and the sweep it documents is the same pattern this test enforces
  # The documented sweep must be the same rule this test enforces. Compared as
  # two FRAGMENTS rather than the whole pattern: MAINTAINING.md carries it inside
  # a double-quoted shell string, so its source text escapes the backtick and the
  # double quote, while `$pattern` here is already expanded — a whole-pattern
  # `grep -F` would compare two different spellings of the same regex and fail
  # for a reason that has nothing to do with drift. These two fragments are
  # byte-identical in both files.
  # both fragments are asserted to be in MAINTAINING.md AND in this test's own
  # $pattern — pinning them only on one side would let this copy drift freely
  contains "$pattern" '(helm|kustomize|kubeconform|kube-linter|kyverno|yq)'
  contains "$pattern" '[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+'
  run grep -F '(helm|kustomize|kubeconform|kube-linter|kyverno|yq)' "$REPO_ROOT/MAINTAINING.md"
  [ "$status" -eq 0 ]
  run grep -F '[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+' "$REPO_ROOT/MAINTAINING.md"
  [ "$status" -eq 0 ]
}

@test "an unsupported OS is refused with a typed message (#1199)" {
  # `uname` is stubbed rather than the check restated, so this exercises the
  # script's own branch
  printf '#!/bin/sh\ncase "$1" in -s) echo Plan9 ;; -m) echo x86_64 ;; esac\n' > "$STUB/uname"
  chmod +x "$STUB/uname"
  run env PATH="$STUB:$PATH" zsh "$SCRIPT" --bin-dir "$BIN"
  [ "$status" -eq 1 ]
  contains "$output" "unsupported OS 'Plan9'"
}

@test "an unsupported architecture is refused with a typed message (#1199)" {
  printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo vax ;; esac\n' > "$STUB/uname"
  chmod +x "$STUB/uname"
  run env PATH="$STUB:$PATH" zsh "$SCRIPT" --bin-dir "$BIN"
  [ "$status" -eq 1 ]
  contains "$output" "unsupported architecture 'vax'"
}
