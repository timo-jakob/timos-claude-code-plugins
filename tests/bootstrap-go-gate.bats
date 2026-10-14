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
  export CALLS
  write_stubs
}

# Every tool the gate and `make setup` call, as a logging stub whose verdict an
# env var sets. `go` covers `go test` and every `go tool …` the gate runs.
write_stubs() {
  cat > "$STUB/go" <<'EOF'
#!/bin/sh
echo "go $*" >> "$CALLS"
if [ "$1" = tool ]; then
  case "$2 ${3:-}" in
    "buf lint") exit "${BUF_LINT_RC:-0}" ;;
    "buf breaking") exit "${BUF_BREAKING_RC:-0}" ;;
    "buf generate")
      if [ -n "${BUF_GEN_FILE:-}" ]; then printf '%s\n' "$BUF_GEN_CONTENT" > "$BUF_GEN_FILE"; fi
      exit "${BUF_GEN_RC:-0}" ;;
  esac
  case "$2" in
    gocover-cobertura) cat; exit 0 ;;
    govulncheck) exit "${GOVULN_RC:-0}" ;;
  esac
fi
if [ "$1" = list ]; then
  printf '%s' "${GO_PACKAGES-example.invalid/app}"
  exit 0
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
  cat > "$STUB/trivy" <<'EOF'
#!/bin/sh
echo "trivy $*" >> "$CALLS"
exit "${TRIVY_RC:-0}"
EOF
  cat > "$STUB/pre-commit" <<'EOF'
#!/bin/sh
echo "pre-commit $*" >> "$CALLS"
exit 0
EOF
  # `make setup`'s diff-cover install: a venv whose pip reports the pinned version
  cat > "$STUB/python3" <<'EOF'
#!/bin/sh
echo "python3 $*" >> "$CALLS"
if [ "$1 $2" = "-m venv" ]; then
  mkdir -p "$3/bin"
  printf '#!/bin/sh\n[ "$1" = show ] && echo "Version: 10.2.0"\nexit 0\n' > "$3/bin/pip"
  printf '#!/bin/sh\necho "diff-cover $*" >> "$CALLS"\nexit "${DIFFCOVER_RC:-0}"\n' > "$3/bin/diff-cover"
  chmod +x "$3/bin/pip" "$3/bin/diff-cover"
fi
exit 0
EOF
  chmod +x "$STUB"/*
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
  git -C "$R" add -A
  git -C "$R" commit -q -m base
  git -C "$R" remote add origin "$REMOTE"
  git -C "$R" push -q origin trunk
  git -C "$R" checkout -q -b feat
}

# Commit every change in the fixture repo on its current branch.
commit_all() {
  git -C "$R" add -A
  git -C "$R" commit -q -m "${1:-change}"
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
  [ "$(yq -r '.jobs.gate.steps[-1].run' "$out/.github/workflows/go-ci.yml")" = 'make check' ]
  rm -rf "$out"
  render_go "$out" --gate-command 'make check-ci'
  [ "$(yq -r '.jobs.gate.steps[-1].run' "$out/.github/workflows/go-ci.yml")" = 'make check-ci' ]
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
  [ "$(yq -r '.jobs.gate.steps | length' "$wf")" = 5 ]
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
  grep -q '^trivy fs --config trivy.yaml --scanners vuln .$' "$CALLS"
  run ! grep -q '^diff-cover' "$CALLS"
  run ! grep -q '^go tool buf' "$CALLS"
}

@test "#2122: tools.vulnerabilities none skips the vulnerability stage with a notice, and snyk runs govulncheck alone" {
  go_repo none
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  contains "$output" 'go-gate: skip vulnerabilities — tools.vulnerabilities is none'
  run ! grep -qE '^(go tool govulncheck|trivy)' "$CALLS"
  rm -rf "$R" "$REMOTE"
  : > "$CALLS"
  go_repo snyk
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  grep -q '^go tool govulncheck ./...$' "$CALLS"
  run ! grep -q '^trivy' "$CALLS"
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

@test "#2122: a go.mod with no Go package yet passes with one skip notice and runs no tool" {
  go_repo none
  run --separate-stderr gate_with GO_PACKAGES=
  [ "$status" -eq 0 ]
  contains "$output" 'go-gate: skip every stage — no Go package yet'
  run ! grep -q 'golangci-lint' "$CALLS"
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

@test "#2122: a base branch that is not fetched fails the tests stage and names git fetch" {
  go_repo none
  git -C "$R" update-ref -d refs/remotes/origin/trunk
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  contains "$stderr" 'go-gate: FAIL coverage floor — origin/trunk is not a commit here; run git fetch origin'
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
  contains "$block" 'Of the steps above, only the `pre-commit` install offer applies, since `hooks/pre-commit` calls it; Step 4a.5 runs as on every other language path.'
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
  contains "$block" 'The gate runs them as `go tool <name>`, so `go.mod` is their one pin. Skip this when there is no `go.mod` yet, and name the three commands in the final report.'
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
  contains "$block" '(unless Step 4a'"'"'s gate ran a stage, not `skip every stage`, and its install-iac-hooks.zsh exited 0 or found the hook already wired) Run `make setup`'
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
