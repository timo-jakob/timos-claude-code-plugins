#!/usr/bin/env bats
#
# #2122 — the Go gate command (platform contract §12). Bootstrap renders a Go
# repository one gate: the Makefile's `check` target runs scripts/go-gate.zsh,
# and go-ci.yml's single `gate` job and hooks/pre-push both run the recorded
# gate command. These cases render the REAL templates through render.zsh and
# drive the rendered gate script with stubbed tools, so each stage's selection,
# skip notice and failure is exercised without a Go toolchain or the network.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  GO_TMPL="$TEMPLATES/languages/go"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  HOOKS_SCRIPT="$REPO_ROOT/development/skills/bootstrap/scripts/install-iac-hooks.zsh"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  ZSH="$(command -v zsh)"
  STUB="$BATS_TEST_TMPDIR/stub-bin"
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$STUB"
  : > "$CALLS"
  # the real yq, which `go tool yq` stands in for (mikefarah's, as the tests above use)
  REAL_YQ="$(type -P yq)"
  export CALLS REAL_YQ
  write_stubs
}

# Every tool the gate and `make setup` call, as a logging stub whose verdict an
# env var sets. `go` covers `go test` and every `go tool …` the gate runs:
# `go tool yq` runs the real yq, and `go tool oasdiff` classifies a contract
# diff as $OASDIFF_CLASS says (breaking, additive or editorial), as
# tests/check-contracts-semver.bats' oasdiff stub does.
write_stubs() {
  cat > "$STUB/go" <<'EOF'
#!/bin/sh
echo "go $*" >> "$CALLS"
if [ "$1" = tool ]; then
  if [ "$2" = -n ]; then
    [ "$3" = "${GO_TOOL_MISSING:-}" ] && { echo "go: no such tool \"$3\"" >&2; exit 2; }
    exit 0
  fi
  case "$2 ${3:-}" in
    "buf lint") exit "${BUF_LINT_RC:-0}" ;;
    "buf breaking") exit "${BUF_BREAKING_RC:-0}" ;;
    "buf generate")
      if [ -n "${BUF_GEN_FILE:-}" ]; then printf '%s\n' "$BUF_GEN_CONTENT" > "$BUF_GEN_FILE"; fi
      exit "${BUF_GEN_RC:-0}" ;;
    "oasdiff breaking") [ "${OASDIFF_CLASS:-editorial}" = breaking ] && echo '[{"level":3}]' || echo '[]'; exit 0 ;;
    "oasdiff diff") [ "${OASDIFF_CLASS:-editorial}" = additive ] && echo '{"paths":{"/x":1}}' || echo '{}'; exit 0 ;;
    "oasdiff "*) echo '[]'; exit 0 ;;
  esac
  case "$2" in
    gocover-cobertura) cat; exit 0 ;;
    govulncheck) exit "${GOVULN_RC:-0}" ;;
    yq) shift 2; exec "$REAL_YQ" "$@" ;;
  esac
fi
if [ "$1" = list ]; then
  printf '%s' "${GO_PACKAGES-example.invalid/app}"
  exit "${GO_LIST_RC:-0}"
fi
if [ "$1" = test ]; then
  echo "mode: atomic" > coverage.out
  exit "${GO_TEST_RC:-0}"
fi
exit 0
EOF
  cat > "$STUB/golangci-lint" <<'EOF'
#!/bin/sh
echo "golangci-lint $*" >> "$CALLS"
case "$1" in
  fmt) printf '%s' "${FMT_DIFF:-}"; exit "${FMT_RC:-0}" ;;
  run) exit "${LINT_RC:-0}" ;;
  version) echo "golangci-lint has version 2.12.2 built with go1.25"; exit 0 ;;
esac
exit 0
EOF
  cat > "$STUB/diff-cover" <<'EOF'
#!/bin/sh
echo "diff-cover $*" >> "$CALLS"
exit "${DIFFCOVER_RC:-0}"
EOF
  # the license scan's verdict is its own, so a license finding can fail alone
  cat > "$STUB/trivy" <<'EOF'
#!/bin/sh
echo "trivy $*" >> "$CALLS"
[ "$1" = --version ] && { echo "Version: ${TRIVY_VERSION_OUT:-0.72.0}"; exit 0; }
case " $* " in
  *" --scanners license "*) exit "${TRIVY_LICENSE_RC:-0}" ;;
esac
exit "${TRIVY_RC:-0}"
EOF
  cat > "$STUB/gitleaks" <<'EOF'
#!/bin/sh
echo "gitleaks $*" >> "$CALLS"
[ "$1" = version ] && { echo "${GITLEAKS_VERSION_OUT:-8.30.1}"; exit 0; }
exit "${GITLEAKS_RC:-0}"
EOF
  # a SKIP list in the environment is logged on a line of its own
  cat > "$STUB/pre-commit" <<'EOF'
#!/bin/sh
echo "pre-commit $*" >> "$CALLS"
if [ -n "${SKIP:-}" ]; then echo "pre-commit SKIP=$SKIP" >> "$CALLS"; fi
exit "${PRECOMMIT_RC:-0}"
EOF
  cat > "$STUB/node" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat > "$STUB/npx" <<'EOF'
#!/bin/sh
echo "npx $*" >> "$CALLS"
exit "${SPECTRAL_RC:-0}"
EOF
  cat > "$STUB/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$CALLS"
exit 1
EOF
  # pandoc in docker: a run writes the manual it was asked for into the directory mounted at
  # /out and prints $PANDOC_LOG for the PDF; the probe reports its dangling link unless
  # $PROBE_SILENT is set
  cat > "$STUB/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$CALLS"
case " $* " in
  *" --entrypoint "*)
    [ -n "${PROBE_SILENT:-}" ] || echo "LaTeX Warning: There were undefined references."
    exit "${PROBE_RC:-0}" ;;
esac
out="" target="" prev=""
for a in "$@"; do
  case "$prev" in
    -v) case "$a" in *:/out) out="${a%:/out}" ;; esac ;;
    -o) target="${a#/out/}" ;;
  esac
  prev="$a"
done
[ -n "${PANDOC_NO_OUTPUT:-}" ] || echo manual > "$out/$target"
[ "$target" = manual.pdf ] && printf '%s\n' "${PANDOC_LOG:-}"
exit "${PANDOC_RC:-0}"
EOF
  # `make setup`'s venv installs, and the docs stage's: a venv whose pip reports the pinned
  # diff-cover and pre-commit versions, and logs an install
  cat > "$STUB/python3" <<'EOF'
#!/bin/sh
echo "python3 $*" >> "$CALLS"
if [ "$1 $2" = "-m venv" ]; then
  mkdir -p "$3/bin"
  cat > "$3/bin/pip" <<'PIP'
#!/bin/sh
case "$1 ${2:-}" in
  "show diff-cover") echo "Version: 10.2.0" ;;
  "show pre-commit") echo "Version: ${PIP_PRE_COMMIT_VERSION:-4.3.0}" ;;
  install*) echo "pip $*" >> "$CALLS"; exit "${PIP_INSTALL_RC:-0}" ;;
esac
exit 0
PIP
  printf '#!/bin/sh\necho "diff-cover $*" >> "$CALLS"\nexit "${DIFFCOVER_RC:-0}"\n' > "$3/bin/diff-cover"
  printf '#!/bin/sh\necho "mkdocs $*" >> "$CALLS"\nexit "${MKDOCS_RC:-0}"\n' > "$3/bin/mkdocs"
  chmod +x "$3/bin/pip" "$3/bin/diff-cover" "$3/bin/mkdocs"
fi
exit 0
EOF
  chmod +x "$STUB"/*
}

# A directory to put alone on PATH: the stubs and the system tools the gate runs,
# without any tool named in <tool>…, so a test can take a tool the host has away.
path_without() {
  local dir="$BATS_TEST_TMPDIR/path-without" p t
  rm -rf "$dir"
  mkdir -p "$dir"
  for p in "$STUB"/*; do
    t="${p##*/}"
    case " $* " in *" $t "*) continue ;; esac
    ln -s "$p" "$dir/$t"
  done
  for t in git awk sed grep cat mktemp rm chmod mkdir env sh bash zsh tr head tail dirname basename \
    ls cp mv uname date sort wc cut tee find xargs jq yq; do
    case " $* " in *" $t "*) continue ;; esac
    if p="$(type -P "$t")"; then ln -s "$p" "$dir/$t"; fi
  done
  echo "$dir"
}

# Render the Go gate set into <dir> through the real renderer, default branch
# `trunk` so nothing can pass by assuming `main`. Further flags follow.
render_go() {
  local dir="$1"; shift
  "$ZSH" "$RENDER" --templates "$GO_TMPL" --out "$dir" --primary go --default-branch trunk "$@" \
    Makefile.tmpl scripts/go-gate.zsh.tmpl hooks/pre-commit.tmpl hooks/pre-push.tmpl \
    .github/workflows/go-ci.yml.tmpl
}

# A rendered Go repo on branch `feat`, whose `trunk` is pushed to a bare remote,
# so origin/trunk exists. <vulnerabilities> is .maintenance.yml's declared tool.
go_repo() {
  local vulns="${1:-trivy}"
  git init -q --bare -b trunk "$REMOTE"
  git init -q -b trunk "$R"
  git -C "$R" config user.email gate@example.invalid
  git -C "$R" config user.name gate
  git -C "$R" config commit.gpgsign false
  render_go "$R" >/dev/null
  printf 'module example.invalid/app\n\ngo 1.25\n' > "$R/go.mod"
  printf 'package main\n\nfunc main() {}\n' > "$R/main.go"
  printf 'primary: go\ntools:\n  static_analysis: sonarcloud\n  vulnerabilities: %s\n  code_scanning: none\n' \
    "$vulns" > "$R/.maintenance.yml"
  printf '.tools/\ncoverage.out\ncoverage.xml\n' > "$R/.gitignore"
  # bootstrap renders the real checker; a logging stub stands in for it here, and one case
  # below runs the real one
  mkdir -p "$R/scripts"
  printf '#!/bin/sh\necho "no-cluster-deploy $*" >> "$CALLS"\nexit "${NCD_RC:-0}"\n' \
    > "$R/scripts/check-no-cluster-deploy.zsh"
  git -C "$R" add -A
  git -C "$R" commit -q -m base
  git -C "$R" remote add origin "$REMOTE"
  git -C "$R" push -q origin trunk
  git -C "$R" checkout -q -b feat
}

# A contract spec at <dir>/openapi.yaml whose version triangle holds: info.version
# <version>, servers URL major <major>.
mkspec() {
  mkdir -p "$R/$1"
  printf 'openapi: 3.1.0\ninfo:\n  title: T\n  version: "%s"\nservers:\n  - url: /v%s\npaths: {}\n' \
    "$2" "$3" > "$R/$1/openapi.yaml"
}

# The docs sources bootstrap renders, with the real chapter-order script: a site
# named Dashboard Service whose nav holds one page.
docs_sources() {
  mkdir -p "$R/docs" "$R/scripts/pandoc"
  printf 'site_name: Dashboard Service\nrepo_name: "acme/dashboard-service" # the repository\n' > "$R/mkdocs.yml"
  printf 'nav:\n  - Home: index.md\n' >> "$R/mkdocs.yml"
  printf '# Dashboard Service\n' > "$R/docs/index.md"
  printf 'mkdocs-material==9.5.0\n' > "$R/requirements-docs.txt"
  cp "$TEMPLATES/common/scripts/docs-nav-to-chapters.zsh" "$R/scripts/"
}

# The real contract semver checker, which bootstrap renders with a contract surface.
semver_checker() {
  mkdir -p "$R/.github/scripts"
  cp "$TEMPLATES/common/.github/scripts/check-contracts-semver.sh" "$R/.github/scripts/"
}

# Commit every change in the fixture repo on its current branch.
commit_all() {
  git -C "$R" add -A
  git -C "$R" commit -q -m "${1:-change}"
}

# Make the fixture's current commit origin/trunk too, so the next change is the only one
# the branch adds.
publish_base() {
  git -C "$R" push -q origin HEAD:trunk
  git -C "$R" fetch -q origin
}

# The rendered gate in the fixture repo, with the stubs first on PATH.
gate() {
  (cd "$R" && env PATH="$STUB:$PATH" "$ZSH" scripts/go-gate.zsh "$@")
}

# The same gate with VAR=value stub verdicts in its environment.
gate_with() {
  (cd "$R" && env PATH="$STUB:$PATH" "$@" "$ZSH" scripts/go-gate.zsh)
}

# --- rendering ------------------------------------------------------------------

@test "#2122: a fresh Go render emits the Makefile, the gate script, both hooks and go-ci.yml — and no Taskfile" {
  local out="$BATS_TEST_TMPDIR/out"
  run render_go "$out"
  [ "$status" -eq 0 ]
  [ -f "$out/Makefile" ]
  [ -x "$out/scripts/go-gate.zsh" ]
  [ -x "$out/hooks/pre-commit" ]
  [ -x "$out/hooks/pre-push" ]
  [ -f "$out/.github/workflows/go-ci.yml" ]
  [ ! -e "$GO_TMPL/Taskfile.yml" ]
  [ ! -e "$out/Taskfile.yml" ]
  run ! grep -rqE '\{\{[A-Z][A-Z0-9_]*\}\}' "$out"
  # the hooks: pre-commit is the framework's pre-commit stage, pre-push is the gate
  [ "$(sed -n 2p "$out/hooks/pre-commit")" = 'exec pre-commit run --hook-stage pre-commit' ]
  grep -qxF '{ make check; } </dev/null || exit 1' "$out/hooks/pre-push"
  # the rendered base ref, never a hard-coded main
  grep -qx 'base="origin/trunk"' "$out/scripts/go-gate.zsh"
  run ! grep -q 'origin/main' "$out/scripts/go-gate.zsh"
}

@test "#2122: the Makefile carries check, hooks and setup, and check runs only the gate script" {
  local out="$BATS_TEST_TMPDIR/out" t
  render_go "$out"
  for t in check hooks setup fmt lint test generate build image; do
    grep -qE "^$t:" "$out/Makefile" || { echo "no $t target"; return 1; }
  done
  run make --no-print-directory -n -C "$out" check
  [ "$status" -eq 0 ]
  [ "$output" = 'zsh scripts/go-gate.zsh' ] || { echo "$output"; false; }
  run make --no-print-directory -n -C "$out" hooks
  [ "$output" = 'git config core.hooksPath hooks' ]
  # setup wires the hooks first
  grep -qx 'setup: hooks' "$out/Makefile"
}

@test "#2122: a recorded gate command reaches go-ci.yml and hooks/pre-push verbatim; the default is make check" {
  local out="$BATS_TEST_TMPDIR/out"
  render_go "$out"
  [ "$(yq -r '.jobs.gate.steps[4].run' "$out/.github/workflows/go-ci.yml")" = 'make check' ]
  rm -rf "$out"
  render_go "$out" --gate-command 'make check-ci'
  [ "$(yq -r '.jobs.gate.steps[4].run' "$out/.github/workflows/go-ci.yml")" = 'make check-ci' ]
  grep -qxF '{ make check-ci; } </dev/null || exit 1' "$out/hooks/pre-push"
}

@test "#2122: go-ci.yml is one job, gate, on every pull_request, with full history, setup, then the gate command" {
  local out="$BATS_TEST_TMPDIR/out" wf
  render_go "$out"
  wf="$out/.github/workflows/go-ci.yml"
  [ "$(yq -r '.jobs | keys | join(",")' "$wf")" = gate ]
  # reported as the bare context `gate`: no name, matrix or reusable workflow
  [ "$(yq -r '.jobs.gate | has("name") or has("strategy") or has("uses")' "$wf")" = false ]
  # a bare pull_request trigger: no filter that would leave a PR without `gate`
  [ "$(yq -r '.on | has("pull_request")' "$wf")" = true ]
  [ "$(yq '.on.pull_request | tag' "$wf")" = '!!null' ]
  [ "$(yq -r '.jobs.gate.steps[0].uses' "$wf")" = 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' ]
  [ "$(yq -r '.jobs.gate.steps[0].with["fetch-depth"]' "$wf")" = 0 ]
  [ "$(yq -r '.jobs.gate.steps[1].with["go-version-file"]' "$wf")" = go.mod ]
  # make check runs a zsh script, and ubuntu-latest ships no zsh
  contains "$(yq -r '.jobs.gate.steps[2].run' "$wf")" 'sudo apt-get install -y --no-install-recommends zsh'
  [ "$(yq -r '.jobs.gate.steps[3].run' "$wf")" = 'make setup' ]
  [ "$(yq -r '.jobs.gate.steps[4].run' "$wf")" = 'make check' ]
  # the gate command, then only the two upload steps (#2614)
  [ "$(yq -r '.jobs.gate.steps | length' "$wf")" = 7 ]
  [ "$(yq -r '.jobs.gate.steps[5].uses' "$wf")" = 'actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9' ]
  [ "$(yq -r '.jobs.gate.steps[6].uses' "$wf")" = 'actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9' ]
  if command -v yamllint >/dev/null 2>&1; then
    run yamllint -c "$REPO_ROOT/.yamllint" --strict "$wf"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  fi
}

@test "#2122: the gate's Go tools run through go tool, and golangci-lint and diff-cover are pinned in one place" {
  local gate="$GO_TMPL/scripts/go-gate.zsh.tmpl"
  grep -q 'go tool buf lint' "$gate"
  grep -q 'go tool buf breaking' "$gate"
  grep -q 'go tool buf generate' "$gate"
  grep -q 'go tool gocover-cobertura -ignore-gen-files' "$gate"
  grep -q 'go tool govulncheck' "$gate"
  # no bare invocation of a go-tool-pinned binary outside a comment
  # (command position: a line start, or after ; & | or a subshell's paren)
  run grep -E "^([^#]*[;&|(])?[[:space:]]*(buf|govulncheck|gocover-cobertura)[[:space:]]" "$gate"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  # each version is defined exactly once, in the Makefile, which make setup and CI both run
  [ "$(grep -c '^GOLANGCI_LINT_VERSION := v' "$GO_TMPL/Makefile.tmpl")" -eq 1 ]
  [ "$(grep -c '^DIFF_COVER_VERSION := ' "$GO_TMPL/Makefile.tmpl")" -eq 1 ]
  run ! grep -rlE 'GOLANGCI_LINT_VERSION :=|DIFF_COVER_VERSION :=|diff-cover==[0-9]' \
    "$GO_TMPL/scripts" "$GO_TMPL/hooks" "$GO_TMPL/.github"
  # CI installs through make setup and pins no version of its own
  run ! grep -qiE 'golangci-lint|diff-cover' "$GO_TMPL/.github/workflows/go-ci.yml.tmpl"
}

@test "#2614: trivy, gitleaks, pre-commit, Spectral and pandoc are each pinned once; oasdiff and yq run through go tool" {
  local gate="$GO_TMPL/scripts/go-gate.zsh.tmpl" make="$GO_TMPL/Makefile.tmpl"
  [ "$(grep -c '^TRIVY_VERSION := v' "$make")" -eq 1 ]
  [ "$(grep -c '^GITLEAKS_VERSION := v' "$make")" -eq 1 ]
  [ "$(grep -c '^PRE_COMMIT_VERSION := [0-9]' "$make")" -eq 1 ]
  [ "$(grep -c '^spectral_cli="@stoplight/spectral-cli@[0-9][0-9.]*"$' "$gate")" -eq 1 ]
  [ "$(grep -c '^pandoc_image="pandoc/extra:[0-9][0-9.]*"$' "$gate")" -eq 1 ]
  # the gate names no version of any of them anywhere else, and neither do the hooks or CI
  run ! grep -rlE 'TRIVY_VERSION :=|GITLEAKS_VERSION :=|PRE_COMMIT_VERSION :=|pre-commit==[0-9]' \
    "$GO_TMPL/scripts" "$GO_TMPL/hooks" "$GO_TMPL/.github"
  [ "$(grep -c 'spectral-cli@' "$gate")" -eq 1 ]
  [ "$(grep -c 'pandoc/extra' "$gate")" -eq 1 ]
  run ! grep -rlE 'spectral-cli@|pandoc/extra' "$GO_TMPL/.github" "$GO_TMPL/hooks" "$make"
  # Spectral and pandoc run from the pins, never a literal
  grep -q 'npx --yes "$spectral_cli" lint --ruleset .spectral.yaml --fail-severity error' "$gate"
  [ "$(grep -c '"$pandoc_image"' "$gate")" -eq 3 ]
  # oasdiff and yq: shims that run go tool, and no bare invocation of either outside a comment
  grep -qF "printf '#!/bin/sh\nexec go tool %s \"\$@\"\n' \"\$t\"" "$gate"
  grep -qx 'for t in oasdiff yq; do' "$gate"
  run grep -E "^([^#]*[;&|(])?[[:space:]]*(oasdiff|yq)[[:space:]]" "$gate"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "#2614: make setup installs trivy, gitleaks and pre-commit whatever tools.vulnerabilities declares" {
  local v out="$BATS_TEST_TMPDIR/setup"
  render_go "$out" >/dev/null
  git -C "$out" init -q
  # no install guard reads .maintenance.yml any more
  run ! grep -q 'VULNERABILITIES' "$out/Makefile"
  for v in trivy snyk none; do
    printf 'primary: go\ntools:\n  vulnerabilities: %s\n' "$v" > "$out/.maintenance.yml"
    rm -rf "$out/.tools"
    : > "$CALLS"
    # every tool reports a stale version, so each is installed; the stub curl fails the download
    run env PATH="$STUB:$PATH" TRIVY_VERSION_OUT=0.1.0 PIP_PRE_COMMIT_VERSION=4.0.0 \
      make --no-print-directory -C "$out" setup
    [ "$status" -ne 0 ]
    contains "$output" 'make setup: installing trivy v0.72.0'
    grep -q '^curl .*aquasecurity/trivy/v0.72.0/contrib/install.sh$' "$CALLS"
    contains "$output" 'make setup: installing pre-commit 4.3.0'
    grep -q '^pip install --quiet pre-commit==4.3.0$' "$CALLS"
    [ -L "$out/.tools/bin/pre-commit" ]
    run env PATH="$STUB:$PATH" GITLEAKS_VERSION_OUT=8.0.0 make --no-print-directory -C "$out" setup
    [ "$status" -ne 0 ]
    contains "$output" 'make setup: installing gitleaks v8.30.1'
    grep -qE '^curl .*gitleaks/releases/download/v8\.30\.1/gitleaks_8\.30\.1_(linux|darwin)_(x64|arm64)\.tar\.gz$' "$CALLS"
  done
  # at the pinned versions nothing is downloaded
  : > "$CALLS"
  run env PATH="$STUB:$PATH" make --no-print-directory -C "$out" setup
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run ! grep -q '^curl' "$CALLS"
}

# --- the gate script: stage selection and skip notices --------------------------

@test "#2122: with no proto inputs and no Go change, the gate passes and prints a skip notice for each skipped stage" {
  go_repo trivy
  echo docs > "$R/README.md"
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  contains "$output" 'go-gate: skip proto — no buf.yaml'
  contains "$output" 'go-gate: skip generation — no buf.gen.yaml'
  contains "$output" 'go-gate: skip coverage floor — no Go file changed against origin/trunk'
  ends_with "$output" 'go-gate: passed'
  grep -q '^golangci-lint fmt --diff$' "$CALLS"
  grep -q '^golangci-lint run$' "$CALLS"
  grep -q '^go test -race -coverprofile=coverage.out -covermode=atomic ./...$' "$CALLS"
  grep -q '^go tool govulncheck ./...$' "$CALLS"
  grep -q '^trivy fs --config trivy.yaml --scanners vuln,secret,misconfig .$' "$CALLS"
  run ! grep -q '^diff-cover' "$CALLS"
  run ! grep -q '^go tool buf' "$CALLS"
}

@test "#2614: the source-only stages run after vulnerabilities in order, and the path-gated ones print a skip notice" {
  go_repo trivy
  echo docs > "$R/README.md"
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  # stage lines in order, each path-gated stage skipping with its reason
  [ "$(grep -o '^go-gate: [a-z -]*' <<< "$output" | sed -n '/vulnerabilities/,$p' | tr '\n' '|')" = \
    'go-gate: vulnerabilities|go-gate: secrets|go-gate: no cluster deploy|go-gate: license|go-gate: skip pre-commit |go-gate: skip contracts lint |go-gate: skip contracts semver |go-gate: skip docs |go-gate: passed|' ]
  contains "$output" 'go-gate: skip pre-commit — no .pre-commit-config.yaml'
  contains "$output" 'go-gate: skip contracts lint — no change under contracts/ or to .spectral.yaml against origin/trunk'
  contains "$output" 'go-gate: skip contracts semver — no change under contracts/ or to its checker against origin/trunk'
  contains "$output" 'go-gate: skip docs — no change to the docs sources against origin/trunk'
  grep -qx 'gitleaks git --no-banner --redact --log-opts=origin/trunk..HEAD .' "$CALLS"
  grep -qx 'no-cluster-deploy ' "$CALLS"
  grep -qx 'trivy fs --config trivy.yaml --scanners license .' "$CALLS"
  run ! grep -qE '^(npx|docker|mkdocs|pre-commit)' "$CALLS"
}

@test "#2122/#2614: tools.vulnerabilities none skips the vulnerability stage, snyk runs govulncheck alone, and the license and secrets stages run under all three" {
  go_repo none
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  contains "$output" 'go-gate: skip vulnerabilities — tools.vulnerabilities is none'
  run ! grep -qE '^(go tool govulncheck|trivy fs .* --scanners vuln)' "$CALLS"
  grep -qx 'trivy fs --config trivy.yaml --scanners license .' "$CALLS"
  grep -q '^gitleaks git ' "$CALLS"
  rm -rf "$R" "$REMOTE"
  : > "$CALLS"
  go_repo snyk
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  grep -q '^go tool govulncheck ./...$' "$CALLS"
  run ! grep -q '^trivy fs .* --scanners vuln' "$CALLS"
  grep -qx 'trivy fs --config trivy.yaml --scanners license .' "$CALLS"
  grep -q '^gitleaks git ' "$CALLS"
  rm -rf "$R" "$REMOTE"
  : > "$CALLS"
  go_repo trivy
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  grep -qx 'trivy fs --config trivy.yaml --scanners license .' "$CALLS"
  grep -q '^gitleaks git ' "$CALLS"
}

@test "#2614: a committed secret, a cluster deploy, a license finding and a pre-commit hook failure each fail the gate" {
  go_repo snyk
  run --separate-stderr gate_with GITLEAKS_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL secrets — gitleaks found a secret in a commit on origin/trunk..HEAD'
  run --separate-stderr gate_with NCD_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL no cluster deploy — see the checker'"'"'s message above'
  run --separate-stderr gate_with TRIVY_LICENSE_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL license — trivy fs --scanners license'
  # with a pre-commit config the stage runs every hook over every file, but the two scans
  # the secrets and vulnerability stages already run
  printf 'repos: []\n' > "$R/.pre-commit-config.yaml"
  commit_all
  : > "$CALLS"
  run --separate-stderr gate
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  contains "$output" 'go-gate: pre-commit'
  grep -qx 'pre-commit run --all-files' "$CALLS"
  grep -qx 'pre-commit SKIP=gitleaks,trivy-fs' "$CALLS"
  run --separate-stderr gate_with PRECOMMIT_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL pre-commit'
}

@test "#2614: a missing gitleaks or pre-commit fails its stage naming make setup" {
  local p
  go_repo none
  printf 'repos: []\n' > "$R/.pre-commit-config.yaml"
  commit_all
  p="$(path_without gitleaks)"
  run --separate-stderr bash -c 'cd "$1" && env PATH="$2" "$3" scripts/go-gate.zsh' _ "$R" "$p" "$ZSH"
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL secrets — gitleaks is not installed; run make setup'
  p="$(path_without pre-commit)"
  run --separate-stderr bash -c 'cd "$1" && env PATH="$2" "$3" scripts/go-gate.zsh' _ "$R" "$p" "$ZSH"
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL pre-commit — pre-commit is not installed; run make setup'
  p="$(path_without trivy)"
  run --separate-stderr bash -c 'cd "$1" && env PATH="$2" "$3" scripts/go-gate.zsh' _ "$R" "$p" "$ZSH"
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL license — trivy is not installed; run make setup'
}

@test "#2614: the real no-cluster-deploy checker, reaching yq through go tool, fails the gate on a workflow that deploys to a cluster" {
  go_repo none
  cp "$TEMPLATES/common/scripts/check-no-cluster-deploy.zsh" "$R/scripts/"
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  # the checker called yq by name, and the shim ran the go.mod-pinned one
  grep -q '^go tool yq ' "$CALLS"
  mkdir -p "$R/.github/workflows"
  printf 'on: push\njobs:\n  deploy:\n    runs-on: ubuntu-latest\n    steps:\n      - run: kubectl apply -f k8s/\n' \
    > "$R/.github/workflows/deploy.yml"
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  contains "$stderr" 'deploy.yml'
  contains "$stderr" 'go-gate: FAIL no cluster deploy — see the checker'"'"'s message above'
}

@test "#2614: a missing jq or go tool yq fails the no cluster deploy stage naming it" {
  local p
  go_repo none
  p="$(path_without jq)"
  run --separate-stderr bash -c 'cd "$1" && env PATH="$2" "$3" scripts/go-gate.zsh' _ "$R" "$p" "$ZSH"
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL no cluster deploy — jq is not installed'
  lacks "$stderr" 'make setup'
  run --separate-stderr gate_with GO_TOOL_MISSING=yq
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL no cluster deploy — go tool yq is missing; go get -tool adds it'
}

# --- contracts ------------------------------------------------------------------

@test "#2614: a contract change lints the newest major of each family with the pinned Spectral, and a Spectral error fails" {
  go_repo none
  semver_checker
  mkspec contracts/v1 1.0.0 1
  mkspec contracts/ops/v1 1.0.0 1
  printf 'extends: []\n' > "$R/.spectral.yaml"
  commit_all
  publish_base
  mkspec contracts/v2 2.0.0 2
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  contains "$output" 'go-gate: linting contracts/v2/openapi.yaml contracts/ops/v1/openapi.yaml'
  grep -qx 'npx --yes @stoplight/spectral-cli@6.15.0 lint --ruleset .spectral.yaml --fail-severity error contracts/v2/openapi.yaml contracts/ops/v1/openapi.yaml' "$CALLS"
  run --separate-stderr gate_with SPECTRAL_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL contracts lint — spectral'
  # a .spectral.yaml change alone runs the stage too
  git -C "$R" reset -q --hard origin/trunk
  printf 'extends: [spectral:oas]\n' > "$R/.spectral.yaml"
  commit_all
  : > "$CALLS"
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  grep -q '^npx --yes @stoplight/spectral-cli@6.15.0 lint ' "$CALLS"
}

@test "#2614: a newest vN directory without openapi.yaml fails the contracts lint stage loudly" {
  go_repo none
  mkspec contracts/v1 1.0.0 1
  commit_all
  publish_base
  mkdir -p "$R/contracts/v2"
  printf 'openapi: 3.1.0\n' > "$R/contracts/v2/openapi.yml"
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: contracts/v2/ is the newest major of contracts but has no openapi.yaml'
  contains "$stderr" 'go-gate: FAIL contracts lint — the newest contract major has no openapi.yaml'
  run ! grep -q '^npx' "$CALLS"
}

@test "#2614: the contracts semver stage writes both findings files, and an in-place breaking change fails it" {
  go_repo none
  semver_checker
  mkspec contracts/v1 1.0.0 1
  mkspec contracts/ops/v1 1.0.0 1
  commit_all
  publish_base
  # an additive change shipped as a minor bump passes, and writes both findings files
  mkspec contracts/v1 1.1.0 1
  commit_all
  run --separate-stderr gate_with OASDIFF_CLASS=additive
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  contains "$output" 'go-gate: contracts semver'
  # the checker called oasdiff by name, and the shim ran the go.mod-pinned one
  grep -q '^go tool oasdiff ' "$CALLS"
  [ "$(jq -r '.violations | length' "$R/contracts-semver-findings.json")" = 0 ]
  [ "$(jq -r '.violations | length' "$R/contracts-ops-semver-findings.json")" = 0 ]
  # the same change classified breaking is an in-place breaking change to a live major
  rm -f "$R"/contracts-*semver-findings.json
  run --separate-stderr gate_with OASDIFF_CLASS=breaking
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL contracts semver — see the checker'"'"'s messages above, and the findings files it wrote'
  jq -r '.violations[]' "$R/contracts-semver-findings.json" | grep -q 'never an in-place edit'
  # the ops half still ran and wrote its file after the business half failed
  [ -f "$R/contracts-ops-semver-findings.json" ]
}

@test "#2614: a failing ops half alone fails the contracts semver stage — the two exit codes are OR'd" {
  go_repo none
  semver_checker
  mkspec contracts/v1 1.0.0 1
  mkspec contracts/ops/v1 1.0.0 1
  commit_all
  publish_base
  # retiring the live ops major fails the ops half, while the business half passes
  git -C "$R" rm -rq contracts/ops
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL contracts semver'
  [ "$(jq -r '.violations | length' "$R/contracts-semver-findings.json")" = 0 ]
  [ "$(jq -r '.violations | length' "$R/contracts-ops-semver-findings.json")" -gt 0 ]
}

@test "#2614: a contract change with no checker on disk fails naming it, and a missing node fails naming the tool" {
  local p
  go_repo none
  mkspec contracts/v1 1.0.0 1
  commit_all
  p="$(path_without node)"
  run --separate-stderr bash -c 'cd "$1" && env PATH="$2" "$3" scripts/go-gate.zsh' _ "$R" "$p" "$ZSH"
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL contracts lint — node is not installed'
  lacks "$stderr" 'make setup'
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL contracts semver — .github/scripts/check-contracts-semver.sh is missing; re-run /development:bootstrap'
}

# --- docs -----------------------------------------------------------------------

@test "#2614: a docs change builds the site strictly and both manuals with the pinned pandoc image, titled from mkdocs.yml" {
  go_repo none
  docs_sources
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  contains "$output" 'go-gate: docs'
  grep -qx 'pip install --quiet -r requirements-docs.txt' "$CALLS"
  grep -qE '^mkdocs build --strict --site-dir /.+/site$' "$CALLS"
  grep -q '^docker run --rm .* pandoc/extra:3.5 --pdf-engine=xelatex --toc -V fontsize=11pt --metadata title=Dashboard Service --metadata author=acme/dashboard-service --lua-filter=scripts/pandoc/break-long-tokens.lua --include-in-header=scripts/pandoc/manual-header.tex -o /out/manual.pdf docs/index.md$' "$CALLS"
  grep -q '^docker run --rm .* pandoc/extra:3.5 --toc --metadata title=Dashboard Service --metadata author=acme/dashboard-service -o /out/manual.epub docs/index.md$' "$CALLS"
  grep -q '^docker run --rm --entrypoint sh pandoc/extra:3.5 -c ' "$CALLS"
  # the site and the manuals are built outside the repository: the tree stays clean
  [ -z "$(git -C "$R" status --porcelain --untracked-files=all -- . ':!.tools')" ]
  # once the docs are on the base branch, the stage skips
  publish_base
  : > "$CALLS"
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  contains "$output" 'go-gate: skip docs — no change to the docs sources against origin/trunk'
  run ! grep -qE '^(mkdocs|docker)' "$CALLS"
}

@test "#2614: a strict mkdocs warning, a missing glyph, an unresolved reference, a missing manual and a blind probe each fail the docs stage" {
  go_repo none
  docs_sources
  commit_all
  run --separate-stderr gate_with MKDOCS_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL docs — mkdocs build --strict'
  run --separate-stderr gate_with PANDOC_LOG='[WARNING] Missing character: There is no ≥ in font lmroman10-regular'
  [ "$status" -eq 1 ]
  contains "$stderr" 'Missing character: There is no ≥'
  contains "$stderr" 'go-gate: FAIL docs — xelatex dropped the characters above from manual.pdf'
  run --separate-stderr gate_with PANDOC_LOG='LaTeX Warning: There were undefined references.'
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL docs — manual.pdf has unresolved references'
  run --separate-stderr gate_with PROBE_SILENT=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL docs — pandoc no longer reports undefined references'
  run --separate-stderr gate_with PROBE_RC=125
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL docs — the pandoc probe container failed'
  run --separate-stderr gate_with PANDOC_NO_OUTPUT=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL docs — a manual was not produced'
  run --separate-stderr gate_with PANDOC_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL docs — pandoc manual.pdf'
}

@test "#2614: a docs change with no mkdocs.yml skips the docs stage, and a missing python3 or docker fails it naming the tool" {
  local p
  go_repo none
  mkdir -p "$R/docs"
  echo notes > "$R/docs/notes.md"
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  contains "$output" 'go-gate: skip docs — no mkdocs.yml'
  docs_sources
  commit_all
  p="$(path_without python3)"
  run --separate-stderr bash -c 'cd "$1" && env PATH="$2" "$3" scripts/go-gate.zsh' _ "$R" "$p" "$ZSH"
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL docs — python3 is not installed'
  p="$(path_without docker)"
  run --separate-stderr bash -c 'cd "$1" && env PATH="$2" "$3" scripts/go-gate.zsh' _ "$R" "$p" "$ZSH"
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL docs — docker is not installed'
  lacks "$stderr" 'make setup'
}

# --- CI uploads -----------------------------------------------------------------

@test "#2614: the gate job uploads the contract semver findings and the coverage reports, always, and an absent file is no error" {
  local out="$BATS_TEST_TMPDIR/out" wf s
  render_go "$out"
  wf="$out/.github/workflows/go-ci.yml"
  s='.jobs.gate.steps[5]'
  [ "$(yq -r "$s.if" "$wf")" = 'always()' ]
  [ "$(yq -r "$s.with.name" "$wf")" = 'contracts-semver-${{ github.event.pull_request.number || github.sha }}' ]
  [ "$(yq -r "$s.with.path" "$wf")" = "$(printf 'contracts-semver-findings.json\ncontracts-ops-semver-findings.json')" ]
  [ "$(yq -r "$s.with[\"if-no-files-found\"]" "$wf")" = ignore ]
  s='.jobs.gate.steps[6]'
  [ "$(yq -r "$s.if" "$wf")" = 'always()' ]
  [ "$(yq -r "$s.with.name" "$wf")" = coverage-reports ]
  [ "$(yq -r "$s.with.path" "$wf")" = "$(printf 'coverage.out\ncoverage.xml')" ]
  [ "$(yq -r "$s.with[\"if-no-files-found\"]" "$wf")" = ignore ]
  # the artifact name the Approver reads is the one contracts-semver.yml uploads
  grep -qF 'name: contracts-semver-${{ github.event.pull_request.number || github.sha }}' \
    "$TEMPLATES/common/.github/workflows/contracts-semver.yml.tmpl"
}

@test "#2122: a format diff, a lint finding, a failing test, a govulncheck and a trivy finding each fail the gate" {
  go_repo none
  run --separate-stderr gate_with FMT_DIFF='--- a/main.go'
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL format — run make fmt'
  run --separate-stderr gate_with FMT_RC=3
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL format'
  run --separate-stderr gate_with LINT_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL lint'
  run --separate-stderr gate_with GO_TEST_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL tests'
  rm -rf "$R" "$REMOTE"
  go_repo snyk
  run --separate-stderr gate_with GOVULN_RC=3
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL vulnerabilities — govulncheck'
  rm -rf "$R" "$REMOTE"
  go_repo trivy
  run --separate-stderr gate_with TRIVY_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL vulnerabilities — trivy fs'
}

# --- proto and generation -------------------------------------------------------

@test "#2122: on a repo with buf.yaml, a buf lint violation and a breaking change against origin/trunk each fail the gate" {
  go_repo none
  printf 'version: v2\n' > "$R/buf.yaml"
  commit_all
  git -C "$R" push -q origin feat:trunk
  git -C "$R" fetch -q origin
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  grep -q '^go tool buf breaking --against .git#branch=origin/trunk$' "$CALLS"
  run --separate-stderr gate_with BUF_LINT_RC=100
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL proto — buf lint'
  run --separate-stderr gate_with BUF_BREAKING_RC=100
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL proto — buf breaking against origin/trunk'
}

@test "#2122: when the base branch has no buf.yaml, buf lint runs and the breaking check prints a skip notice" {
  go_repo none
  printf 'version: v2\n' > "$R/buf.yaml"
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  contains "$output" 'go-gate: skip proto breaking check — origin/trunk has no buf.yaml yet'
  grep -q '^go tool buf lint$' "$CALLS"
  run ! grep -q '^go tool buf breaking' "$CALLS"
}

@test "#2122: a hand-edited or uncommitted generated file, or a failing buf generate, fails the generation stage" {
  go_repo none
  # a quoted out: value with a trailing comment still names gen
  printf 'version: v2\nplugins:\n  - local: protoc-gen-go\n    out: "gen" # generated\n' > "$R/buf.gen.yaml"
  mkdir -p "$R/gen"
  echo 'hand edited' > "$R/gen/api.pb.go"
  commit_all
  run --separate-stderr gate_with BUF_GEN_FILE="$R/gen/api.pb.go" BUF_GEN_CONTENT='generated'
  [ "$status" -eq 1 ]
  contains "$stderr" 'gen/api.pb.go'
  contains "$stderr" 'go-gate: FAIL generation — committed generated code does not match the protos'
  # committed exactly as generated: no drift
  echo generated > "$R/gen/api.pb.go"
  commit_all regenerate
  run --separate-stderr gate_with BUF_GEN_FILE="$R/gen/api.pb.go" BUF_GEN_CONTENT='generated'
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  grep -q '^go tool buf generate$' "$CALLS"
  # a file already dirty under the generated path before the run, which buf generate leaves alone, is not drift
  echo scratch > "$R/gen/notes.txt"
  run --separate-stderr gate_with BUF_GEN_FILE="$R/gen/api.pb.go" BUF_GEN_CONTENT='generated'
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  rm "$R/gen/notes.txt"
  run --separate-stderr gate_with BUF_GEN_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL generation — buf generate'
  # generated code that was never committed is drift too
  run --separate-stderr gate_with BUF_GEN_FILE="$R/gen/new.pb.go" BUF_GEN_CONTENT='generated'
  [ "$status" -eq 1 ]
  contains "$stderr" 'gen/new.pb.go'
  # a single-quoted out: value names gen too
  printf "version: v2\nplugins:\n  - local: protoc-gen-go\n    out: 'gen'\n" > "$R/buf.gen.yaml"
  commit_all single-quoted
  run --separate-stderr gate_with BUF_GEN_FILE="$R/gen/api.pb.go" BUF_GEN_CONTENT='drifted'
  [ "$status" -eq 1 ]
  contains "$stderr" 'gen/api.pb.go'
}

@test "#2122: a go.mod with no Go package yet skips the Go stages but still runs the source-only ones" {
  go_repo trivy
  printf 'version: v2\n' > "$R/buf.yaml"
  printf 'version: v2\nplugins:\n  - local: protoc-gen-go\n    out: gen\n' > "$R/buf.gen.yaml"
  commit_all
  run --separate-stderr gate_with GO_PACKAGES=
  [ "$status" -eq 0 ]
  contains "$output" 'go-gate: skip format — no Go package yet'
  contains "$output" 'go-gate: skip govulncheck — no Go package yet'
  grep -qx 'trivy fs --config trivy.yaml --scanners vuln,secret,misconfig .' "$CALLS"
  grep -q '^go tool buf lint$' "$CALLS"
  grep -q '^go tool buf generate$' "$CALLS"
  run ! grep -q 'golangci-lint' "$CALLS"
  run ! grep -q '^go test' "$CALLS"
  grep -q '^gitleaks git ' "$CALLS"
}

@test "#2614: a failing go list ./... fails the gate rather than skipping the Go stages" {
  go_repo none
  run --separate-stderr gate_with GO_LIST_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL go list ./...'
  lacks "$output" 'no Go package yet'
}

# --- the coverage floor ---------------------------------------------------------

@test "#2122: changed Go lines below 90% fail the floor, compared against origin/trunk" {
  go_repo none
  printf 'package main\n\nfunc f() int { return 1 }\n' > "$R/f.go"
  commit_all
  run --separate-stderr gate_with DIFFCOVER_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL coverage floor — changed Go lines are below 90% covered against origin/trunk'
  grep -q '^diff-cover coverage.xml --compare-branch=origin/trunk --fail-under=90$' "$CALLS"
  run --separate-stderr gate
  [ "$status" -eq 0 ]
}

@test "#2122: a base branch that is not fetched fails the gate before its first stage and names git fetch" {
  go_repo none
  git -C "$R" update-ref -d refs/remotes/origin/trunk
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL base branch — origin/trunk is not a commit here; run git fetch origin'
}

@test "#2122: a missing gate tool fails naming make setup; an unknown argument exits 2; --help prints the header" {
  local nolint="$BATS_TEST_TMPDIR/nolint"
  go_repo none
  mkdir -p "$nolint"
  cp "$STUB/go" "$STUB/diff-cover" "$nolint/"
  # no golangci-lint anywhere on this PATH: the stub dir without it, and the system dirs
  run --separate-stderr bash -c 'cd "$1" && env PATH="$2:/usr/bin:/bin" "$3" scripts/go-gate.zsh' _ "$R" "$nolint" "$ZSH"
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL format — golangci-lint is not installed; run make setup'
  run --separate-stderr gate --bogus
  [ "$status" -eq 2 ]
  contains "$stderr" 'go-gate: unknown argument: --bogus'
  run gate --help
  [ "$status" -eq 0 ]
  starts_with "$output" "go-gate.zsh — this Go repository's gate MECHANISM (#2122)"
}

# --- hooks ----------------------------------------------------------------------

@test "#2122: install-iac-hooks.zsh wires a Go repo's hooks/ without running the gate, and refuses a non-executable pre-commit" {
  go_repo none
  run --separate-stderr env PATH="$STUB:$PATH" "$ZSH" "$HOOKS_SCRIPT" --repo "$R"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$output" = 'install-iac-hooks: core.hooksPath=hooks' ]
  [ "$(git -C "$R" config --get core.hooksPath)" = hooks ]
  # wiring never runs the gate, so a gate that does not pass yet cannot fail it
  run ! grep -qE '^(golangci-lint|go |diff-cover)' "$CALLS"
  chmod a-x "$R/hooks/pre-commit"
  run --separate-stderr env PATH="$STUB:$PATH" "$ZSH" "$HOOKS_SCRIPT" --repo "$R"
  [ "$status" -eq 5 ]
  contains "$stderr" 'install-iac-hooks: hooks/pre-commit is not executable in'
}

@test "#2122: after make setup on a fresh clone, hooks/pre-push refuses a push the gate fails, and lets a green one through" {
  local clone="$BATS_TEST_TMPDIR/clone"
  go_repo none
  git clone -q "$REMOTE" "$clone"
  git -C "$clone" config user.email gate@example.invalid
  git -C "$clone" config user.name gate
  git -C "$clone" config commit.gpgsign false
  run --separate-stderr env PATH="$STUB:$PATH" make -C "$clone" setup
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  [ "$(git -C "$clone" config --get core.hooksPath)" = hooks ]
  [ -x "$clone/.tools/bin/diff-cover" ]
  git -C "$clone" checkout -q -b feat
  echo change > "$clone/NOTES.md"
  git -C "$clone" add NOTES.md
  env PATH="$STUB:$PATH" git -C "$clone" commit -q -m change
  # hooks/pre-commit ran the framework's pre-commit stage
  grep -q '^pre-commit run --hook-stage pre-commit$' "$CALLS"
  run --separate-stderr env PATH="$STUB:$PATH" LINT_RC=1 git -C "$clone" push -q origin feat
  [ "$status" -ne 0 ]
  contains "$stderr" 'go-gate: FAIL lint'
  run ! git -C "$REMOTE" rev-parse -q --verify refs/heads/feat
  # the same push with a green gate goes through: the refusal above was the hook's
  run --separate-stderr env PATH="$STUB:$PATH" git -C "$clone" push -q origin feat
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  git -C "$REMOTE" rev-parse -q --verify refs/heads/feat
  # after the gate, the hook hands the push to the framework's pre-push stage
  grep -q '^pre-commit hook-impl --config=.pre-commit-config.yaml --hook-type=pre-push ' "$CALLS"
}

# --- drift ----------------------------------------------------------------------

@test "#2122: the drift detector reads a marked Go gate file and leaves an unmarked hooks/ file to its owner" {
  local drift="$REPO_ROOT/development/skills/maintenance/scripts/detect-template-drift.zsh" repo="$BATS_TEST_TMPDIR/drift"
  mkdir -p "$repo/hooks" "$repo/scripts"
  # unmarked: the consumer's own hook and script, never a finding
  printf '#!/bin/sh\nexit 0\n' > "$repo/hooks/pre-commit"
  printf '#!/usr/bin/env zsh\n' > "$repo/scripts/go-gate.zsh"
  run zsh "$drift" "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
  # marked from languages/go/ with a stale hash: each is drift
  printf '#!/bin/sh\n# claude-bootstrap: rendered from languages/go/hooks/pre-commit.tmpl @ v1.0.0 sha256:0\n' \
    > "$repo/hooks/pre-commit"
  printf '#!/bin/sh\n# claude-bootstrap: rendered from languages/go/hooks/pre-push.tmpl @ v1.0.0 sha256:0\n' \
    > "$repo/hooks/pre-push"
  printf '#!/usr/bin/env zsh\n# claude-bootstrap: rendered from languages/go/scripts/go-gate.zsh.tmpl @ v1.0.0 sha256:0\n' \
    > "$repo/scripts/go-gate.zsh"
  run zsh "$drift" "$repo"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[] | select(.severity == "drifted") | .file] | sort | join(",")' <<< "$output")" = 'hooks/pre-commit,hooks/pre-push,scripts/go-gate.zsh' ]
}

# --- prose ----------------------------------------------------------------------

@test "#2122: SKILL.md Step 4a wires a Go primary through install-iac-hooks.zsh, gate first, never install-precommit-hooks.zsh" {
  local block
  block="$(sed -n '/^\*\*A Go primary is the exception to \*Every other path\* (#2122)/,/^### 4a\.5\./p' "$SKILL" | tr -s '[:space:]' ' ')"
  ends_with "$block" '### 4a.5. Normalize pre-existing files: `pre-commit run --all-files` until clean '
  contains "$block" 'run `install-iac-hooks.zsh` as the top of this step shows, under the same rule: run the resolved gate command (`make check` unless `.maintenance.yml` records another) first'
  contains "$block" 'when it fails, skip the script and the final report names `make setup`, which wires the hooks and then installs the gate'"'"'s tools'
  contains "$block" 'Skip the script too while `pre-commit` is not on PATH'
  contains "$block" 'Unless the hook was already wired, a red gate never blocks bootstrap or Step 4e'"'"'s push'
  contains "$block" '**Never run `install-precommit-hooks.zsh` on a Go primary:**'
  contains "$block" 'Of the steps above, only the `pre-commit` install offer applies, since `hooks/pre-commit` calls it; Step 4a.5 runs as on every other language path, but before that gate run, whose `pre-commit` stage would otherwise fail on the files 4a.5 normalizes.'
}

@test "#2122: no Taskfile or task test reference is left in bootstrap SKILL.md, the Go templates, development-go, its marketplace entry or plugins.md" {
  local -a files=(
    "$SKILL"
    "$REPO_ROOT/development-go/.claude-plugin/plugin.json"
    "$REPO_ROOT/development-go/skills/resolve-profile/SKILL.md"
    "$REPO_ROOT/docs/reference/plugins.md"
  )
  local f
  while IFS= read -r f; do files+=("$f"); done < <(find "$GO_TMPL" -type f)
  # non-vacuous: every named file exists, and the Go template tree is walked
  [ "${#files[@]}" -gt 8 ]
  for f in "${files[@]}"; do
    [ -f "$f" ] || { echo "missing: $f"; return 1; }
    if grep -qiE 'taskfile|task test|go-task' "$f"; then echo "Taskfile reference in $f"; return 1; fi
  done
  run jq -r '.plugins[] | select(.name == "development-go") | .description' "$REPO_ROOT/.claude-plugin/marketplace.json"
  [ -n "$output" ]
  lacks "$output" 'Taskfile'
  contains "$output" 'make check'
}

@test "#2122: SKILL.md §3d renders the Go gate with the recorded gate command and pins the gate's Go tools with go get -tool" {
  local block row
  block="$(sed -n '/^- \*\*Go only (#875, #2122):\*\*/,/^- \*\*JavaScript contract-consumer note/p' "$SKILL" | tr -s '[:space:]' ' ')"
  ends_with "$block" '- **JavaScript contract-consumer note (#727):** render the base '
  contains "$block" 'the pre-commit GO block (golangci-lint only; the coverage floor is the gate'"'"'s test stage, #2122)'
  contains "$block" 'every file through `render.zsh` with `--primary go` and — when `.maintenance.yml` records a `gate:` — that value as `--gate-command`'
  contains "$block" 'A `Makefile` already on disk goes to the idempotency reviewer, as on §3l, and so does any of the four files below already on disk.'
  contains "$block" '`iac/` → `languages/go/`, the plugin-owned set → `go-ci.yml`, `scripts/go-gate.zsh`, `hooks/pre-commit` and `hooks/pre-push`, and a `Makefile` merge that appends the `check`, `hooks` and `setup` targets and the variables they read when absent'
  contains "$block" 'Step 4 requires its `gate` context in addition to the existing Go contexts.'
  contains "$block" '`go get -tool github.com/bufbuild/buf/cmd/buf@latest` only when `buf.yaml` or `buf.gen.yaml` is present'
  contains "$block" '`go get -tool github.com/mikefarah/yq/v4@latest`, plus'
  contains "$block" '`go get -tool github.com/oasdiff/oasdiff@latest` only when §3i renders the contracts machinery'
  contains "$block" 'The gate runs them as `go tool <name>`, and reaches the checker scripts that call `yq` and `oasdiff` by name through shims, so `go.mod` is their one pin.'
  # the quality workflows' Go coverage step is a go tool consumer too, and names this fix (#2864)
  contains "$block" '`make test` and the quality workflows'"'"' Go coverage step run `go tool gocover-cobertura` too, and that step fails with this `go get -tool` command as its fix when the directive is missing (#2864).'
  contains "$block" 'Skip this when there is no `go.mod` yet, and name the commands in the final report.'
  # the Makefile pins every installed gate tool, whatever tools.vulnerabilities declares (#2614)
  contains "$block" 'gate'"'"'s installed non-Go tools are pinned (golangci-lint, diff-cover, trivy, gitleaks and pre-commit, whatever `tools.vulnerabilities` declares'
  contains "$block" 'stages 1–13 in order'
  contains "$block" 'whose two `if: always()` upload steps keep the contract semver findings (`contracts-semver-<pr>`) and the coverage reports (`coverage-reports`) the gate wrote'
  # §3a: a Go primary records gate:, and tools: like every non-IaC primary
  row="$(sed -n '/^- `\.maintenance\.yml` (render/,/^- `LICENSE`/p' "$SKILL" | tr -s '[:space:]' ' ')"
  contains "$row" 'On the §3l IaC path and a Go primary (#2122) it records `gate:`, the gate command (#1604)'
  contains "$row" 'Off §3l (Go too) it records `tools:` (#1651).'
  row="$(grep -F '| `{{GATE_COMMAND}}` |' "$SKILL")"
  contains "$row" 'Pass a recorded value via `render.zsh --gate-command`; without the flag render.zsh applies the same per-primary default itself'
  # Step 3.6 stamps the four rendered gate files
  grep -qF '| `.github/workflows/go-ci.yml` | `languages/go/.github/workflows/go-ci.yml.tmpl` (Go primary only, #2122) |' "$SKILL"
  grep -qF '| `scripts/go-gate.zsh` | `languages/go/scripts/go-gate.zsh.tmpl` (Go primary only) |' "$SKILL"
  grep -qF '| `hooks/pre-push` | `languages/go/hooks/pre-push.tmpl` (Go primary only) |' "$SKILL"
  grep -qF '| `hooks/pre-commit` | `languages/go/hooks/pre-commit.tmpl` (Go primary only) |' "$SKILL"
}

@test "#2122: Step 5's Go checklist names make setup for unwired hooks and the skipped go get -tool pins" {
  local block
  block="$(sed -n '/^For a \*\*Go primary\*\* (#2122) the checklist adds/,/^For the \*\*IaC path\*\*/p' "$SKILL" | tr -s '[:space:]' ' ')"
  starts_with "$block" 'For a **Go primary** (#2122) the checklist adds'
  contains "$block" '(unless Step 4a'"'"'s gate ran its Go stages, not `skip format — no Go package yet`, and its install-iac-hooks.zsh exited 0 or found the hook already wired) Run `make setup`'
  contains "$block" '(only when Step 4a found core.hooksPath already `hooks` and the gate failing) The pre-push hook IS wired'
  contains "$block" '(only when §3d skipped the `go get -tool` pins, as on a repo with no `go.mod` yet) Pin the gate'"'"'s Go tools'
}

@test "#2122: the Go resolve profile runs the recorded gate command before §6's push and never bypasses the hook" {
  local gate
  gate="$(sed -n '/^## Gate$/,/^## Version bump$/p' "$REPO_ROOT/development-go/skills/resolve-profile/SKILL.md" | tr -s '[:space:]' ' ')"
  ends_with "$gate" '## Version bump '
  contains "$gate" '**Run the recorded gate command once before §6'"'"'s push, only when the repo carries `hooks/pre-push`.**'
  contains "$gate" 'Treat its red as a §3 red: fix it, and never reach for `--no-verify`.'
  contains "$gate" 'report the missing tool and its remedy, and stop — `make setup` for the gate'"'"'s `not installed; run make setup` failure, and for go'"'"'s `no such tool` error the `go get -tool` command bootstrap §3d names for it: the run does not install a toolchain to get past its own gate.'
  contains "$gate" '**Do not reach for open-pr'"'"'s coverage guard instead:** its `--lang` arms are python, java and swift'
  lacks "$gate" 'coverage-floor-go'
}
