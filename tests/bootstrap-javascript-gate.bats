#!/usr/bin/env bats
#
# #2513 — the JavaScript gate command (platform contract §12), the model the Go
# gate set under #2122. The Makefile's `check` target runs scripts/javascript-gate.zsh.
# These cases render the REAL templates through render.zsh and drive the
# rendered gate script with stubbed npx, npm, node and gate tools, so each
# stage's selection, skip notice and failure is exercised without Node or the
# network. The npx stub refuses any call to a JavaScript tool that lacks
# --no-install, so a gate that could download an unpinned tool reds here.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  # a git hook or `rebase --exec` exports these, and `git -C` does not override
  # them: the fixture repos' init/add would land in the REAL index
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  JS_TMPL="$TEMPLATES/languages/javascript"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  ZSH="$(command -v zsh)"
  STUB="$BATS_TEST_TMPDIR/stub-bin"
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$STUB"
  : > "$CALLS"
  # the real yq, which the yq stub runs for everything but --version (mikefarah's, which the
  # contract semver checker reads the specs with)
  REAL_YQ="$(type -P yq)"
  export CALLS REAL_YQ
  write_stubs
}

# Every tool the gate and `make setup` call, as a logging stub whose verdict an
# env var sets. npx dispatches on the tool it runs; only the shared
# contracts-lint checker's pinned Spectral may run without --no-install.
write_stubs() {
  cat > "$STUB/npx" <<'EOF'
#!/bin/sh
echo "npx $*" >> "$CALLS"
case "$1 ${2:-}" in
  "--yes @stoplight/spectral-cli@"*) exit "${SPECTRAL_RC:-0}" ;;
esac
if [ "$1" != --no-install ]; then
  echo "NPX WITHOUT --no-install: $*" >> "$CALLS"
  exit 99
fi
shift
case "$1" in
  prettier) exit "${PRETTIER_RC:-0}" ;;
  eslint)
    case " $* " in
      *" --max-warnings=0 "*) exit "${ESLINT_RC:-0}" ;;
    esac
    echo "ESLINT WITHOUT --max-warnings=0" >> "$CALLS"
    exit 97 ;;
  tsc) exit "${TSC_RC:-0}" ;;
  vitest)
    if [ -z "${VITEST_NO_LCOV:-}" ]; then mkdir -p coverage; echo 'TN:' > coverage/lcov.info; fi
    exit "${VITEST_RC:-0}" ;;
esac
exit 0
EOF
  cat > "$STUB/npm" <<'EOF'
#!/bin/sh
echo "npm $*" >> "$CALLS"
exit "${NPM_RC:-0}"
EOF
  cat > "$STUB/node" <<'EOF'
#!/bin/sh
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
  cat > "$STUB/yq" <<'EOF'
#!/bin/sh
echo "yq $*" >> "$CALLS"
[ "$1" = --version ] && { echo "yq (https://github.com/mikefarah/yq/) version v${YQ_VERSION_OUT:-4.44.3}"; exit 0; }
exec "$REAL_YQ" "$@"
EOF
  # classifies a contract diff as $OASDIFF_CLASS says (breaking, additive or editorial), as
  # tests/check-contracts-semver.bats' oasdiff stub does
  cat > "$STUB/oasdiff" <<'EOF'
#!/bin/sh
echo "oasdiff $*" >> "$CALLS"
case "$1" in
  --version) echo "oasdiff version ${OASDIFF_VERSION_OUT:-1.11.7}" ;;
  breaking) [ "${OASDIFF_CLASS:-editorial}" = breaking ] && echo '[{"level":3}]' || echo '[]' ;;
  diff) [ "${OASDIFF_CLASS:-editorial}" = additive ] && echo '{"paths":{"/x":1}}' || echo '{}' ;;
  *) echo '[]' ;;
esac
exit 0
EOF
  # a SKIP list in the environment is logged on a line of its own
  cat > "$STUB/pre-commit" <<'EOF'
#!/bin/sh
echo "pre-commit $*" >> "$CALLS"
if [ -n "${SKIP:-}" ]; then echo "pre-commit SKIP=$SKIP" >> "$CALLS"; fi
exit "${PRECOMMIT_RC:-0}"
EOF
  cat > "$STUB/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$CALLS"
exit 1
EOF
  # pandoc in docker: a run writes the manual it was asked for into the directory mounted at /out
  cat > "$STUB/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$CALLS"
case " $* " in
  *" --entrypoint "*) echo "LaTeX Warning: There were undefined references."; exit 0 ;;
esac
out="" target="" prev=""
for a in "$@"; do
  case "$prev" in
    -v) case "$a" in *:/out) out="${a%:/out}" ;; esac ;;
    -o) target="${a#/out/}" ;;
  esac
  prev="$a"
done
echo manual > "$out/$target"
exit 0
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
    ls cp mv uname date sort wc cut tee find xargs jq; do
    case " $* " in *" $t "*) continue ;; esac
    if p="$(type -P "$t")"; then ln -s "$p" "$dir/$t"; fi
  done
  echo "$dir"
}

# Render the JavaScript gate set into <dir> through the real renderer, default
# branch `trunk` so nothing can pass by assuming `main`.
render_js() {
  local dir="$1"; shift
  "$ZSH" "$RENDER" --templates "$JS_TMPL" --out "$dir" --primary javascript --default-branch trunk "$@" \
    Makefile.tmpl scripts/javascript-gate.zsh.tmpl
}

# node_modules as `make setup` leaves it: every devDependency the gate runs, and an
# install record no older than package-lock.json. Untracked, as .gitignore says.
install_modules() {
  local b
  mkdir -p "$R/node_modules/.bin" "$R/node_modules/@vitest/coverage-v8"
  for b in prettier eslint tsc vitest; do
    printf '#!/bin/sh\nexit 0\n' > "$R/node_modules/.bin/$b"
    chmod +x "$R/node_modules/.bin/$b"
  done
  echo '{}' > "$R/node_modules/.package-lock.json"
}

# A rendered TypeScript repo on branch `feat`, whose `trunk` is pushed to a bare
# remote, so origin/trunk exists. <vulnerabilities> is .maintenance.yml's declared tool.
js_repo() {
  local vulns="${1:-trivy}"
  git init -q --bare -b trunk "$REMOTE"
  git init -q -b trunk "$R"
  git -C "$R" config user.email gate@example.invalid
  git -C "$R" config user.name gate
  git -C "$R" config commit.gpgsign false
  render_js "$R" >/dev/null
  printf '{\n  "name": "dashboard-service",\n  "private": true\n}\n' > "$R/package.json"
  printf '{\n  "name": "dashboard-service",\n  "lockfileVersion": 3\n}\n' > "$R/package-lock.json"
  printf '{\n  "compilerOptions": { "strict": true }\n}\n' > "$R/tsconfig.json"
  mkdir -p "$R/src"
  printf 'export const total = (a: number, b: number): number => a + b;\n' > "$R/src/total.ts"
  printf 'primary: javascript\ntools:\n  static_analysis: sonarcloud\n  vulnerabilities: %s\n  code_scanning: none\n' \
    "$vulns" > "$R/.maintenance.yml"
  cp "$JS_TMPL/gitignore" "$R/.gitignore"
  # bootstrap renders the real checker; a logging stub stands in for it here
  printf '#!/bin/sh\necho "no-cluster-deploy $*" >> "$CALLS"\nexit "${NCD_RC:-0}"\n' \
    > "$R/scripts/check-no-cluster-deploy.zsh"
  # the shared contracts-lint and docs checkers stages 11 and 13 call, as bootstrap renders them
  cp "$TEMPLATES/common/scripts/check-contracts-lint.zsh" "$TEMPLATES/common/scripts/check-docs.zsh" \
    "$R/scripts/"
  git -C "$R" add -A
  git -C "$R" commit -q -m base
  git -C "$R" remote add origin "$REMOTE"
  git -C "$R" push -q origin trunk
  git -C "$R" checkout -q -b feat
  install_modules
}

# A contract spec at <dir>/openapi.yaml whose version triangle holds: info.version
# <version>, servers URL major <major>.
mkspec() {
  mkdir -p "$R/$1"
  printf 'openapi: 3.1.0\ninfo:\n  title: T\n  version: "%s"\nservers:\n  - url: /v%s\npaths: {}\n' \
    "$2" "$3" > "$R/$1/openapi.yaml"
}

# The docs sources bootstrap renders, with the real chapter-order script.
docs_sources() {
  mkdir -p "$R/docs" "$R/scripts/pandoc"
  printf 'site_name: Dashboard Service\nrepo_name: "acme/dashboard-service"\n' > "$R/mkdocs.yml"
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

# A TypeScript change on the branch, so the coverage floor has changed lines to judge.
ts_change() {
  printf 'export const half = (n: number): number => n / 2;\n' > "$R/src/half.ts"
  commit_all
}

# The rendered gate in the fixture repo, with the stubs first on PATH.
gate() {
  (cd "$R" && env PATH="$STUB:$PATH" "$ZSH" scripts/javascript-gate.zsh "$@")
}

# The same gate with VAR=value stub verdicts in its environment.
gate_with() {
  (cd "$R" && env PATH="$STUB:$PATH" "$@" "$ZSH" scripts/javascript-gate.zsh)
}

# The gate on PATH <dir> alone.
gate_on() {
  bash -c 'cd "$1" && env PATH="$2" "$3" scripts/javascript-gate.zsh' _ "$R" "$1" "$ZSH"
}

# The stage lines (entry, skip and passed) the gate printed, joined by `|`.
stage_lines() {
  # a checker's own `linting <specs>` line names paths, so it is no stage line
  grep -E '^javascript-gate: ([a-z -]+$|skip )' <<< "$1" | sed 's/ — .*//' | tr '\n' '|'
}

# --- rendering and the Makefile -------------------------------------------------

@test "#2513: a JavaScript render emits the Makefile and an executable gate script on the rendered base" {
  local out="$BATS_TEST_TMPDIR/out"
  run render_js "$out"
  [ "$status" -eq 0 ]
  [ -f "$out/Makefile" ]
  [ -x "$out/scripts/javascript-gate.zsh" ]
  run ! grep -rqE '\{\{[A-Z][A-Z0-9_]*\}\}' "$out"
  grep -qx 'base="origin/trunk"' "$out/scripts/javascript-gate.zsh"
  run ! grep -q 'origin/main' "$out/scripts/javascript-gate.zsh"
}

@test "#2513: the Makefile carries check, hooks, setup, fmt, lint, typecheck and test, and check runs only the gate" {
  local out="$BATS_TEST_TMPDIR/out" t
  render_js "$out"
  for t in check hooks setup fmt lint typecheck test; do
    grep -qE "^$t:" "$out/Makefile" || { echo "no $t target"; return 1; }
  done
  run make --no-print-directory -n -C "$out" check
  [ "$status" -eq 0 ]
  [ "$output" = 'zsh scripts/javascript-gate.zsh' ] || { echo "$output"; false; }
  run make --no-print-directory -n -C "$out" hooks
  [ "$output" = 'git config core.hooksPath hooks' ]
  grep -qx 'setup: hooks' "$out/Makefile"
  run make --no-print-directory -n -C "$out" lint
  [ "$output" = 'npx --no-install eslint --max-warnings=0 .' ]
  run make --no-print-directory -n -C "$out" test
  [ "$output" = 'npx --no-install vitest run --coverage' ]
  run make --no-print-directory -n -C "$out" fmt
  [ "$output" = "$(printf 'npx --no-install prettier --write .\nnpx --no-install eslint --fix .')" ]
}

@test "#2513: make typecheck takes tsc --build for a solution-style tsconfig.json and tsc --noEmit otherwise" {
  local out="$BATS_TEST_TMPDIR/out"
  render_js "$out"
  printf '#!/bin/sh\necho "npx $*" >> "$CALLS"\n' > "$STUB/npx"
  printf '{ "compilerOptions": {} }\n' > "$out/tsconfig.json"
  run env PATH="$STUB:$PATH" make --no-print-directory -C "$out" typecheck
  [ "$status" -eq 0 ]
  printf '{ "files": [], "references": [{ "path": "./tsconfig.app.json" }] }\n' > "$out/tsconfig.json"
  run env PATH="$STUB:$PATH" make --no-print-directory -C "$out" typecheck
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "$(printf 'npx --no-install tsc --noEmit\nnpx --no-install tsc --build')" ]
}

@test "#2513: every non-npm gate tool is pinned once in the Makefile, and no npm-native tool is pinned there" {
  local make="$JS_TMPL/Makefile.tmpl" gate="$JS_TMPL/scripts/javascript-gate.zsh.tmpl" v
  for v in DIFF_COVER_VERSION PRE_COMMIT_VERSION TRIVY_VERSION GITLEAKS_VERSION YQ_VERSION OASDIFF_VERSION; do
    [ "$(grep -c "^$v := v\{0,1\}[0-9][0-9.]*\$" "$make")" -eq 1 ] || { echo "$v is not pinned once"; return 1; }
  done
  # the gate names no version of anything, and pins no Spectral or pandoc of its own (#2640)
  run grep -nE '_VERSION|==[0-9]|@[0-9]+\.[0-9]|spectral_cli|pandoc_image|spectral-cli@|pandoc/extra' "$gate"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  # no newest-major selector of its own: the shared checker selects
  run grep -nE 'sort -V|v\[0-9\]' "$gate"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  # the npm-native tools are pinned by package.json and package-lock.json alone
  run grep -inE '(prettier|eslint|typescript|vitest|coverage-v8)[@=_ -]*v?[0-9]+\.[0-9]' "$make"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  # every JavaScript tool in the gate runs through npx --no-install, never bare and never --yes
  run grep -nE '^[^#]*npx( |$)' "$gate"
  [ "$status" -eq 0 ]
  lacks "$(grep -vE 'npx --no-install ' <<< "$output")" 'npx'
  run grep -nE "^([^#]*[;&|(])?[[:space:]]*(prettier|eslint|tsc|vitest)[[:space:]]" "$gate"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "#2513: the Makefile's YQ_VERSION equals no-cluster-deploy.yml's pin, and MAINTAINING.md names the site" {
  local make_pin wf_pin
  make_pin="$(sed -n 's/^YQ_VERSION := //p' "$JS_TMPL/Makefile.tmpl")"
  wf_pin="$(sed -n 's/^ *YQ_VERSION: //p' "$TEMPLATES/common/.github/workflows/no-cluster-deploy.yml.tmpl")"
  [ -n "$make_pin" ] && [ -n "$wf_pin" ]
  [ "$make_pin" = "$wf_pin" ] || { echo "Makefile pins $make_pin, no-cluster-deploy.yml pins $wf_pin"; false; }
  grep -qF 'templates/languages/javascript/Makefile.tmpl' "$REPO_ROOT/MAINTAINING.md"
}

@test "#2513: the Makefile's OASDIFF_VERSION equals contracts-semver.yml's pin" {
  local make_pin wf_pin
  make_pin="$(sed -n 's/^OASDIFF_VERSION := //p' "$JS_TMPL/Makefile.tmpl")"
  wf_pin="$(sed -n 's/^ *OASDIFF_VERSION: "\(.*\)"$/\1/p' "$TEMPLATES/common/.github/workflows/contracts-semver.yml.tmpl")"
  [ -n "$make_pin" ] && [ -n "$wf_pin" ]
  [ "$make_pin" = "$wf_pin" ] || { echo "Makefile pins $make_pin, contracts-semver.yml pins $wf_pin"; false; }
}

@test "#2513: make setup runs npm ci when package.json exists, then installs each stale gate tool at its pin" {
  local out="$BATS_TEST_TMPDIR/setup"
  render_js "$out" >/dev/null
  git -C "$out" init -q
  echo '{}' > "$out/package.json"
  # every tool reports a stale version, so each is installed; the stub curl fails each download
  run env PATH="$STUB:$PATH" TRIVY_VERSION_OUT=0.1.0 PIP_PRE_COMMIT_VERSION=4.0.0 \
    make --no-print-directory -C "$out" setup
  [ "$status" -ne 0 ]
  [ "$(sed -n 1p "$CALLS")" = 'npm ci' ]
  contains "$output" 'make setup: installing pre-commit 4.3.0'
  grep -q '^pip install --quiet pre-commit==4.3.0$' "$CALLS"
  contains "$output" 'make setup: installing trivy v0.72.0'
  grep -q '^curl .*aquasecurity/trivy/v0.72.0/contrib/install.sh$' "$CALLS"
  : > "$CALLS"
  run env PATH="$STUB:$PATH" GITLEAKS_VERSION_OUT=8.0.0 make --no-print-directory -C "$out" setup
  [ "$status" -ne 0 ]
  contains "$output" 'make setup: installing gitleaks v8.30.1'
  : > "$CALLS"
  run env PATH="$STUB:$PATH" YQ_VERSION_OUT=4.0.0 make --no-print-directory -C "$out" setup
  [ "$status" -ne 0 ]
  contains "$output" 'make setup: installing yq 4.44.3'
  grep -qE '^curl .*mikefarah/yq/releases/download/v4\.44\.3/yq_(linux|darwin)_(amd64|arm64)$' "$CALLS"
  : > "$CALLS"
  run env PATH="$STUB:$PATH" OASDIFF_VERSION_OUT=1.0.0 make --no-print-directory -C "$out" setup
  [ "$status" -ne 0 ]
  contains "$output" 'make setup: installing oasdiff 1.11.7'
  grep -qE '^curl .*oasdiff/releases/download/v1\.11\.7/oasdiff_1\.11\.7_(linux_(amd64|arm64)|darwin_all)\.tar\.gz$' "$CALLS"
  # at the pinned versions nothing is downloaded, and without package.json npm is never called
  rm "$out/package.json"
  : > "$CALLS"
  run env PATH="$STUB:$PATH" make --no-print-directory -C "$out" setup
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run ! grep -qE '^(curl|npm)' "$CALLS"
}

# --- the gate: stage order and skip notices -------------------------------------

@test "#2513: with every stub green and every path changed, stages 1-13 print in order, then passed" {
  js_repo trivy
  semver_checker
  mkspec contracts/v1 1.0.0 1
  mkspec contracts/ops/v1 1.0.0 1
  printf 'extends: []\n' > "$R/.spectral.yaml"
  printf 'repos: []\n' > "$R/.pre-commit-config.yaml"
  docs_sources
  printf 'export const half = (n: number): number => n / 2;\n' > "$R/src/half.ts"
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  [ "$(stage_lines "$output")" = \
    'javascript-gate: format|javascript-gate: lint|javascript-gate: typecheck|javascript-gate: tests|javascript-gate: coverage floor|javascript-gate: vulnerabilities|javascript-gate: secrets|javascript-gate: no cluster deploy|javascript-gate: license|javascript-gate: pre-commit|javascript-gate: contracts lint|javascript-gate: contracts semver|javascript-gate: docs|javascript-gate: passed|' ] ||
    { echo "$output"; false; }
  grep -qx 'npx --no-install prettier --check .' "$CALLS"
  grep -qx 'npx --no-install eslint --max-warnings=0 .' "$CALLS"
  grep -qx 'npx --no-install tsc --noEmit' "$CALLS"
  grep -qx 'npx --no-install vitest run --coverage' "$CALLS"
  grep -qx 'diff-cover coverage/lcov.info --compare-branch=origin/trunk --fail-under=90' "$CALLS"
  grep -qx 'trivy fs --config trivy.yaml --scanners vuln,secret,misconfig .' "$CALLS"
  grep -qx 'gitleaks git --no-banner --redact --log-opts=origin/trunk..HEAD .' "$CALLS"
  grep -qx 'trivy fs --config trivy.yaml --scanners license .' "$CALLS"
  # the npx stub refused nothing, and the gate never installed a package
  run ! grep -qE 'WITHOUT' "$CALLS"
  run ! grep -qE '^npm ' "$CALLS"
}

@test "#2513: the gate never runs npm ci or npm install, even with node_modules missing" {
  js_repo none
  rm -rf "$R/node_modules"
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  contains "$stderr" 'javascript-gate: FAIL format — node_modules is missing or older than package-lock.json; run make setup'
  run ! grep -qE '^npm ' "$CALLS"
}

@test "#2513: without tsconfig.json typecheck prints a skip notice and tsc never runs" {
  js_repo none
  git -C "$R" rm -q tsconfig.json
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  contains "$output" 'javascript-gate: skip typecheck — no tsconfig.json'
  run ! grep -q 'tsc' "$CALLS"
}

@test "#2513: a tsconfig.json declaring references takes tsc --build, a plain one tsc --noEmit" {
  js_repo none
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  grep -qx 'npx --no-install tsc --noEmit' "$CALLS"
  run ! grep -q 'tsc --build' "$CALLS"
  printf '{\n  "files": [],\n  "references": [{ "path": "./tsconfig.app.json" }]\n}\n' > "$R/tsconfig.json"
  commit_all
  : > "$CALLS"
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  grep -qx 'npx --no-install tsc --build' "$CALLS"
  run ! grep -q 'tsc --noEmit' "$CALLS"
  run --separate-stderr gate_with TSC_RC=2
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL typecheck' ]
}

@test "#2513: with no JavaScript file changed the coverage floor prints a skip notice and diff-cover never runs" {
  js_repo none
  echo notes > "$R/NOTES.md"
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  contains "$output" 'javascript-gate: skip coverage floor — no JavaScript file changed against origin/trunk'
  run ! grep -q '^diff-cover' "$CALLS"
  # a deleted file alone is no changed line to cover
  publish_base
  git -C "$R" rm -q src/total.ts
  commit_all
  : > "$CALLS"
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  contains "$output" 'javascript-gate: skip coverage floor — no JavaScript file changed against origin/trunk'
  # every listed extension counts as JavaScript
  for ext in js jsx ts tsx mjs cjs; do
    git -C "$R" reset -q --hard origin/trunk
    echo 'export {};' > "$R/src/x.$ext"
    commit_all
    : > "$CALLS"
    run --separate-stderr gate
    [ "$status" -eq 0 ]
    grep -q '^diff-cover ' "$CALLS" || { echo "*.$ext did not run the floor"; return 1; }
  done
}

@test "#2513: without package.json stages 1-5 print a skip notice, npx never runs, and the rest run" {
  js_repo trivy
  git -C "$R" rm -q package.json package-lock.json
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  for s in format lint typecheck tests 'coverage floor'; do
    contains "$output" "javascript-gate: skip $s — no package.json yet"
  done
  run ! grep -q '^npx' "$CALLS"
  grep -qx 'trivy fs --config trivy.yaml --scanners vuln,secret,misconfig .' "$CALLS"
  grep -q '^gitleaks git ' "$CALLS"
  grep -qx 'no-cluster-deploy ' "$CALLS"
}

@test "#2513: with no change under contracts/ or docs/, stages 10-13 print skip notices and the checkers never run" {
  js_repo none
  run --separate-stderr gate
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  contains "$output" 'javascript-gate: skip pre-commit — no .pre-commit-config.yaml'
  contains "$output" 'javascript-gate: skip contracts lint — no change under contracts/, to .spectral.yaml or to its checker against origin/trunk'
  contains "$output" 'javascript-gate: skip contracts semver — no change under contracts/ or to its checker against origin/trunk'
  contains "$output" 'javascript-gate: skip docs — no change to the docs sources or to its checker against origin/trunk'
  run ! grep -qE '^(npx --yes|oasdiff|docker|mkdocs|pre-commit)' "$CALLS"
}

@test "#2513: tools.vulnerabilities none or snyk skips the vulnerability stage, and license and secrets still run" {
  js_repo none
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  contains "$output" 'javascript-gate: skip vulnerabilities — tools.vulnerabilities is none'
  run ! grep -q '^trivy fs .* --scanners vuln' "$CALLS"
  grep -qx 'trivy fs --config trivy.yaml --scanners license .' "$CALLS"
  grep -q '^gitleaks git ' "$CALLS"
  rm -rf "$R" "$REMOTE"
  : > "$CALLS"
  js_repo snyk
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  contains "$output" 'javascript-gate: skip vulnerabilities — tools.vulnerabilities is snyk, which runs outside the gate'
  run ! grep -q '^trivy fs .* --scanners vuln' "$CALLS"
  grep -qx 'trivy fs --config trivy.yaml --scanners license .' "$CALLS"
  grep -q '^gitleaks git ' "$CALLS"
  # no declaration at all is a skip with its own notice, never a silent one
  rm "$R/.maintenance.yml"
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ]
  contains "$output" 'javascript-gate: skip vulnerabilities — .maintenance.yml declares no tools.vulnerabilities: trivy'
}

@test "#2513: the pre-commit stage skips the hooks stages 1, 2, 6 and 7 already run, and a hook failure fails it" {
  js_repo none
  printf 'repos: []\n' > "$R/.pre-commit-config.yaml"
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  contains "$output" 'javascript-gate: pre-commit'
  grep -qx 'pre-commit run --all-files' "$CALLS"
  grep -qx 'pre-commit SKIP=gitleaks,trivy-fs,eslint,prettier' "$CALLS"
  run --separate-stderr gate_with PRECOMMIT_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'javascript-gate: FAIL pre-commit'
}

# --- the gate: failures ---------------------------------------------------------

@test "#2513: a Prettier diff fails format naming make fmt, and no later stage runs" {
  js_repo none
  run --separate-stderr gate_with PRETTIER_RC=1
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL format — run make fmt' ]
  lacks "$output" 'javascript-gate: lint'
  run ! grep -qE 'eslint|^gitleaks' "$CALLS"
}

@test "#2513: a single ESLint warning fails lint, and eslint received --max-warnings=0" {
  js_repo none
  run --separate-stderr gate_with ESLINT_RC=1
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL lint' ]
  grep -qx 'npx --no-install eslint --max-warnings=0 .' "$CALLS"
  run ! grep -q 'ESLINT WITHOUT' "$CALLS"
}

@test "#2513: a tsc error fails typecheck, and a failing Vitest run fails tests" {
  js_repo none
  run --separate-stderr gate_with TSC_RC=2
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL typecheck' ]
  run --separate-stderr gate_with VITEST_RC=1
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL tests' ]
}

@test "#2513: a passing Vitest run that leaves no coverage/lcov.info fails tests naming the reporter" {
  js_repo none
  # a report from an earlier run must not stand in for this one
  mkdir -p "$R/coverage"
  echo 'TN:' > "$R/coverage/lcov.info"
  run --separate-stderr gate_with VITEST_NO_LCOV=1
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL tests — no coverage/lcov.info; add "lcov" to vitest.config.ts coverage.reporter' ]
}

@test "#2513: a missing @vitest/coverage-v8 fails tests naming npm i -D before Vitest runs" {
  js_repo none
  rm -rf "$R/node_modules/@vitest/coverage-v8"
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL tests — @vitest/coverage-v8 is not installed; add it with npm i -D @vitest/coverage-v8, then run make setup' ]
  run ! grep -q 'vitest run' "$CALLS"
}

@test "#2513: changed JavaScript lines below 90% fail the coverage floor against origin/trunk" {
  js_repo none
  ts_change
  run --separate-stderr gate_with DIFFCOVER_RC=1
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL coverage floor — changed JavaScript lines are below 90% covered against origin/trunk' ]
  grep -qx 'diff-cover coverage/lcov.info --compare-branch=origin/trunk --fail-under=90' "$CALLS"
}

@test "#2513: a failing Spectral run fails contracts lint through the shared checker" {
  js_repo none
  semver_checker
  mkspec contracts/v1 1.0.0 1
  printf 'extends: []\n' > "$R/.spectral.yaml"
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  contains "$output" 'javascript-gate: linting contracts/v1/openapi.yaml'
  grep -q '^npx --yes @stoplight/spectral-cli@[0-9.]* lint --ruleset .spectral.yaml --fail-severity error contracts/v1/openapi.yaml$' "$CALLS"
  run --separate-stderr gate_with SPECTRAL_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'javascript-gate: FAIL contracts lint — spectral'
}

@test "#2513: the gate maps the shared checkers' exits: 3 skips contracts lint, another code is named, a missing one names bootstrap" {
  js_repo none
  semver_checker
  mkdir -p "$R/contracts/schemas"
  echo '{}' > "$R/contracts/schemas/pet.json"
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  contains "$output" $'javascript-gate: contracts lint\njavascript-gate: skip contracts lint — no contracts/vN/openapi.yaml'
  printf '#!/bin/sh\nexit 4\n' > "$R/scripts/check-contracts-lint.zsh"
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL contracts lint — scripts/check-contracts-lint.zsh exited 4' ]
  rm "$R/scripts/check-contracts-lint.zsh"
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL contracts lint — scripts/check-contracts-lint.zsh is missing; re-run /development:bootstrap' ]
}

@test "#2513: the contracts semver stage writes both findings files, and a failing half fails it" {
  js_repo none
  semver_checker
  mkspec contracts/v1 1.0.0 1
  mkspec contracts/ops/v1 1.0.0 1
  commit_all
  publish_base
  mkspec contracts/v1 1.1.0 1
  commit_all
  run --separate-stderr gate_with OASDIFF_CLASS=additive
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  contains "$output" 'javascript-gate: contracts semver'
  [ "$(jq -r '.violations | length' "$R/contracts-semver-findings.json")" = 0 ]
  [ "$(jq -r '.violations | length' "$R/contracts-ops-semver-findings.json")" = 0 ]
  # retiring the live ops major fails the ops half alone: the two exit codes are OR'd
  git -C "$R" rm -rq contracts/ops
  commit_all
  run --separate-stderr gate_with OASDIFF_CLASS=additive
  [ "$status" -eq 1 ]
  contains "$stderr" 'javascript-gate: FAIL contracts semver — see the checker'"'"'s messages above, and the findings files it wrote'
  [ "$(jq -r '.violations | length' "$R/contracts-semver-findings.json")" = 0 ]
  [ "$(jq -r '.violations | length' "$R/contracts-ops-semver-findings.json")" -gt 0 ]
  # retiring the live main major, with contracts/ops restored, fails the main half alone
  git -C "$R" checkout -q HEAD~1 -- contracts/ops
  git -C "$R" rm -rq contracts/v1
  commit_all
  run --separate-stderr gate_with OASDIFF_CLASS=additive
  [ "$status" -eq 1 ]
  contains "$stderr" 'javascript-gate: FAIL contracts semver — see the checker'"'"'s messages above, and the findings files it wrote'
  [ "$(jq -r '.violations | length' "$R/contracts-semver-findings.json")" -gt 0 ]
  [ "$(jq -r '.violations | length' "$R/contracts-ops-semver-findings.json")" = 0 ]
}

@test "#2513: a docs change builds through the shared docs checker, and its failure fails the docs stage" {
  js_repo none
  docs_sources
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  contains "$output" 'javascript-gate: docs'
  grep -qE '^mkdocs build --strict --site-dir /.+/site$' "$CALLS"
  run --separate-stderr gate_with MKDOCS_RC=1
  [ "$status" -eq 1 ]
  contains "$stderr" 'javascript-gate: FAIL docs — mkdocs build --strict'
}

@test "#2513: a change to any one trigger path alone runs its stage: contracts lint, contracts semver, docs" {
  js_repo none
  semver_checker
  docs_sources
  commit_all
  local pair
  for pair in 'contracts lint|.spectral.yaml' 'contracts lint|scripts/check-contracts-lint.zsh' \
    'contracts semver|.github/scripts/check-contracts-semver.sh' 'docs|docs/index.md' 'docs|mkdocs.yml' \
    'docs|requirements-docs.txt' 'docs|scripts/docs-nav-to-chapters.zsh' 'docs|scripts/pandoc/x' \
    'docs|scripts/check-docs.zsh'; do
    publish_base
    mkdir -p "$R/$(dirname "${pair#*|}")"
    echo '# touched' >> "$R/${pair#*|}"
    commit_all
    run --separate-stderr gate
    printf '%s\n' "$output" | grep -qx "javascript-gate: ${pair%%|*}" || { echo "$pair: $output $stderr"; false; }
  done
}

@test "#2513: a committed secret, a cluster deploy, a license finding and a trivy finding each fail the gate" {
  js_repo trivy
  run --separate-stderr gate_with GITLEAKS_RC=1
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL secrets — gitleaks found a secret in a commit on origin/trunk..HEAD' ]
  run --separate-stderr gate_with NCD_RC=1
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL no cluster deploy — see the checker'"'"'s message above' ]
  run --separate-stderr gate_with TRIVY_LICENSE_RC=1
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL license — trivy fs --scanners license' ]
  run --separate-stderr gate_with TRIVY_RC=1
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL vulnerabilities — trivy fs' ]
}

@test "#2513: a yarn.lock or pnpm-lock.yaml with no package-lock.json fails before stage 1, naming the file and npm" {
  js_repo none
  git -C "$R" rm -q package-lock.json
  touch "$R/yarn.lock"
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL format — no package-lock.json, but a yarn.lock; npm is the supported package manager' ]
  lacks "$output" 'javascript-gate: format'
  run ! grep -q '^npx' "$CALLS"
  git -C "$R" rm -q yarn.lock
  touch "$R/pnpm-lock.yaml"
  commit_all
  run --separate-stderr gate
  [ "$stderr" = 'javascript-gate: FAIL format — no package-lock.json, but a pnpm-lock.yaml; npm is the supported package manager' ]
  git -C "$R" rm -q pnpm-lock.yaml
  commit_all
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL format — no package-lock.json; npm is the supported package manager' ]
}

@test "#2513: a package-lock.json newer than node_modules/.package-lock.json fails naming make setup" {
  js_repo none
  touch -t 202001010000 "$R/node_modules/.package-lock.json"
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL format — node_modules is missing or older than package-lock.json; run make setup' ]
  run ! grep -q '^npx' "$CALLS"
}

@test "#2513: a missing devDependency names npm i -D, a missing make setup tool names make setup, a missing machine tool names it" {
  local p
  js_repo none
  rm "$R/node_modules/.bin/eslint"
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL lint — eslint is not installed; add it with npm i -D eslint, then run make setup' ]
  install_modules
  rm "$R/node_modules/.bin/tsc"
  run --separate-stderr gate
  [ "$stderr" = 'javascript-gate: FAIL typecheck — tsc is not installed; add it with npm i -D typescript, then run make setup' ]
  install_modules
  ts_change
  p="$(path_without diff-cover)"
  run --separate-stderr gate_on "$p"
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL coverage floor — diff-cover is not installed; run make setup' ]
  p="$(path_without node)"
  run --separate-stderr gate_on "$p"
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL format — node is not installed' ]
  p="$(path_without npm)"
  run --separate-stderr gate_on "$p"
  [ "$stderr" = 'javascript-gate: FAIL format — npm is not installed' ]
  p="$(path_without yq)"
  run --separate-stderr gate_on "$p"
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL no cluster deploy — yq is not installed; run make setup' ]
  p="$(path_without gitleaks)"
  run --separate-stderr gate_on "$p"
  [ "$stderr" = 'javascript-gate: FAIL secrets — gitleaks is not installed; run make setup' ]
}

@test "#2513: a base branch that is not fetched fails the gate before its first stage and names git fetch" {
  js_repo none
  git -C "$R" update-ref -d refs/remotes/origin/trunk
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL base branch — origin/trunk is not a commit here, or HEAD shares no history with it; run git fetch origin' ]
  [ -z "$output" ]
  # a base with no merge base, as a shallow or unrelated fetch leaves it, fails the same way
  git -C "$R" update-ref refs/remotes/origin/trunk "$(git -C "$R" commit-tree -m orphan "$(git -C "$R" mktree </dev/null)")"
  run --separate-stderr gate
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL base branch — origin/trunk is not a commit here, or HEAD shares no history with it; run git fetch origin' ]
}

@test "#2513: an unknown argument exits 2, and --help prints the header" {
  js_repo none
  run --separate-stderr gate --bogus
  [ "$status" -eq 2 ]
  [ "$stderr" = 'javascript-gate: unknown argument: --bogus' ]
  run gate --help
  [ "$status" -eq 0 ]
  starts_with "$output" "javascript-gate.zsh — this JavaScript repository's gate MECHANISM (#2513)"
  contains "$output" 'Exit codes: 0 every stage passed'
}
