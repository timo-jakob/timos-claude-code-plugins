#!/usr/bin/env bats
#
# Tests for render.zsh — the deterministic bootstrap template renderer (#546).
# Before it, every bootstrap session hand-wrote its own renderer from the
# SKILL.md prose, each with fresh bugs (the tick-server-simulator session's
# flagged the intentional {{PYTHON_VERSION}} default in the unconditional
# pre-commit CI job as an error). These tests pin the spec in one place:
# the placeholder table, the conditional-block stripping rules, the loud
# leftover-placeholder failure, and byte-identical reruns.
#
# `run !` (negated assertions that must fail the test regardless of position)
# needs bats >= 1.5.0; declare it so BW02 doesn't warn on every use.
bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  REAL_TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  T="$BATS_TEST_TMPDIR/templates"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$T" "$OUT"
}

# --- argument handling --------------------------------------------------------

@test "render: no args -> usage (exit 2)" {
  run zsh "$SCRIPT"
  [ "$status" -eq 2 ]
  contains "$output" "usage:"
}

@test "render: missing file list -> usage (exit 2)" {
  run zsh "$SCRIPT" --templates "$T" --out "$OUT"
  [ "$status" -eq 2 ]
}

@test "render: unknown flag -> usage (exit 2)" {
  echo "x" > "$T/a.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --frobnicate yes a.tmpl
  [ "$status" -eq 2 ]
  contains "$output" "unknown flag"
}

@test "render: nonexistent template -> error naming it (exit 1)" {
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" missing.tmpl
  [ "$status" -eq 1 ]
  contains "$output" "template not found"
}

# --- substitution + output mapping ---------------------------------------------

@test "render: substitutes placeholders and strips the .tmpl suffix" {
  printf 'name: {{PROJECT_NAME}} on {{DEFAULT_BRANCH}}\nslug: {{PROJECT_SLUG}}\n' > "$T/f.yml.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --project-name demo --project-slug o/r f.yml.tmpl
  [ "$status" -eq 0 ]
  [ -f "$OUT/f.yml" ]
  [ "$(sed -n 1p "$OUT/f.yml")" = "name: demo on main" ]
  [ "$(sed -n 2p "$OUT/f.yml")" = "slug: o/r" ]
}

@test "render: creates nested output directories mirroring the relpath" {
  mkdir -p "$T/public/.github/workflows"
  echo "branch: {{DEFAULT_BRANCH}}" > "$T/public/.github/workflows/q.yml.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" public/.github/workflows/q.yml.tmpl
  [ "$status" -eq 0 ]
  [ -f "$OUT/public/.github/workflows/q.yml" ]
}

@test "render: PYTHON_VERSION defaults to 3.12 even when python is not detected (#546 regression)" {
  # The unconditional pre-commit CI job uses {{PYTHON_VERSION}} outside any
  # PYTHON block — the ad-hoc renderer this script replaces flagged that as
  # a leftover instead of applying the SKILL.md table's default.
  printf 'python-version: "{{PYTHON_VERSION}}"\ncompact: py{{PYTHON_VERSION_COMPACT}}\n' > "$T/f.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --languages "java" f.tmpl
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$OUT/f")" = 'python-version: "3.12"' ]
  [ "$(sed -n 2p "$OUT/f")" = "compact: py312" ]
}

@test "render: explicit --python-version drives the compact form too" {
  echo 'v={{PYTHON_VERSION}} c={{PYTHON_VERSION_COMPACT}}' > "$T/f.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --python-version 3.13 f.tmpl
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/f")" = "v=3.13 c=313" ]
}

@test "render: JAVA_VERSION and COVERAGE_THRESHOLD defaults apply" {
  echo 'j={{JAVA_VERSION}} t={{COVERAGE_THRESHOLD}}' > "$T/f.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" f.tmpl
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/f")" = "j=21 t=90" ]
}

@test "render: CODEQL_LANGUAGES is mapped from --languages (javascript -> javascript-typescript)" {
  # Comma+space join (#781): the value sits in a YAML flow sequence, where a
  # bare comma is a yamllint `commas` error on the rendered workflow.
  echo 'langs: [{{CODEQL_LANGUAGES}}]' > "$T/f.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --languages "javascript python" f.tmpl
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/f")" = "langs: [javascript-typescript, python]" ]
}

@test "render: #781 a stripped end-of-file block leaves no trailing blank line" {
  # yamllint's empty-lines rule rejects a blank final line at ERROR level, so
  # trailing blanks are dropped entirely, not collapsed to one.
  printf 'key: value\n\n# --- DOCKER-START ---\ndocker: bits\n# --- DOCKER-END ---\n' > "$T/f.yml.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" f.yml.tmpl
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$OUT/f.yml")" = "key: value" ]
}

@test "render: explicit --codeql-languages overrides the mapping" {
  echo '{{CODEQL_LANGUAGES}}' > "$T/f.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --languages "python" --codeql-languages "go,swift" f.tmpl
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/f")" = "go,swift" ]
}

@test "render: SECURITY_CONTACT_BLOCK with an email renders the email block" {
  printf 'head\n{{SECURITY_CONTACT_BLOCK}}\ntail\n' > "$T/s.md.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --security-contact-email sec@example.org s.md.tmpl
  [ "$status" -eq 0 ]
  grep -q 'Email \*\*sec@example.org\*\*' "$OUT/s.md"
  run ! grep -q 'SECURITY_CONTACT_BLOCK' "$OUT/s.md"
}

@test "render: SECURITY_CONTACT_BLOCK with empty email renders the no-email fallback" {
  printf '{{SECURITY_CONTACT_BLOCK}}\n' > "$T/s.md.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --security-contact-email "" s.md.tmpl
  [ "$status" -eq 0 ]
  grep -q 'No email channel is configured' "$OUT/s.md"
}

# --- conditional blocks ---------------------------------------------------------

make_blocky() {
  cat > "$T/b.yml.tmpl" <<'EOF'
top: 1
# --- PYTHON-START ----------------------------------------------------------
python: yes
# --- PYTHON-END ------------------------------------------------------------
# --- JAVA-START --------------------------------------------------------------
java: yes
# --- JAVA-END ----------------------------------------------------------------
bottom: 1
EOF
}

@test "render: strips a block whose language is not detected, keeps the detected one WITH markers" {
  make_blocky
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --languages "java" b.yml.tmpl
  [ "$status" -eq 0 ]
  run ! grep -q 'python: yes' "$OUT/b.yml"
  run ! grep -q 'PYTHON-START' "$OUT/b.yml"
  grep -q 'java: yes' "$OUT/b.yml"
  grep -q 'JAVA-START' "$OUT/b.yml"
  grep -q 'JAVA-END' "$OUT/b.yml"
}

@test "render: LINUX_TESTS kept for java, stripped for swift-only" {
  printf '# --- LINUX_TESTS-START ---\nlinux: yes\n# --- LINUX_TESTS-END ---\n' > "$T/l.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --languages "java" l.tmpl
  [ "$status" -eq 0 ]
  grep -q 'linux: yes' "$OUT/l"
  rm -rf "$OUT"; mkdir -p "$OUT"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --languages "swift" l.tmpl
  [ "$status" -eq 0 ]
  run ! grep -q 'linux: yes' "$OUT/l"
}

@test "render: nested SWIFT_SWIFTPM/SWIFT_XCODE resolve inside a kept SWIFT block" {
  cat > "$T/n.tmpl" <<'EOF'
# --- SWIFT-START ---
swift: yes
# --- SWIFT_SWIFTPM-START ---
spm: yes
# --- SWIFT_SWIFTPM-END ---
# --- SWIFT_XCODE-START ---
xcode: yes
# --- SWIFT_XCODE-END ---
# --- SWIFT-END ---
EOF
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --languages "swift" --swift-build-system xcode n.tmpl
  [ "$status" -eq 0 ]
  grep -q 'swift: yes' "$OUT/n"
  grep -q 'xcode: yes' "$OUT/n"
  run ! grep -q 'spm: yes' "$OUT/n"
}

@test "render: a stripped outer block swallows its inner markers entirely" {
  cat > "$T/n.tmpl" <<'EOF'
# --- SWIFT-START ---
# --- SWIFT_SWIFTPM-START ---
spm: yes
# --- SWIFT_SWIFTPM-END ---
# --- SWIFT-END ---
after: yes
EOF
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --languages "java" n.tmpl
  [ "$status" -eq 0 ]
  run ! grep -q 'spm' "$OUT/n"
  run ! grep -q 'SWIFT' "$OUT/n"
  grep -q 'after: yes' "$OUT/n"
}

@test "render: CLAUDE-PLUGIN (hyphen) marker matches the CLAUDE_PLUGIN table entry" {
  printf '# --- CLAUDE-PLUGIN-START ---\nplugin: yes\n# --- CLAUDE-PLUGIN-END ---\n' > "$T/c.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --claude-plugin true c.tmpl
  [ "$status" -eq 0 ]
  grep -q 'plugin: yes' "$OUT/c"
  rm -rf "$OUT"; mkdir -p "$OUT"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --claude-plugin false c.tmpl
  [ "$status" -eq 0 ]
  run ! grep -q 'plugin: yes' "$OUT/c"
}

@test "render: #1670 PUBLIC block follows --visibility, and PRIVATE is no longer a tag" {
  printf '# --- PUBLIC-START ---\npub: yes\n# --- PUBLIC-END ---\n' > "$T/p.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" p.tmpl
  [ "$status" -eq 0 ]
  grep -q 'pub: yes' "$OUT/p"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --visibility private p.tmpl
  [ "$status" -eq 0 ]
  run ! grep -q 'pub: yes' "$OUT/p"
  # the retired tag now fails loudly, like any unknown tag
  printf '# --- PRIVATE-START ---\npriv: yes\n# --- PRIVATE-END ---\n' > "$T/q.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --visibility private q.tmpl
  [ "$status" -eq 1 ]
  contains "$output" "unknown block tag 'PRIVATE'"
}

@test "render: #1670 each per-tool tag is kept iff its tool is resolved, and all strip with no toolchain flag" {
  local tag
  for tag in SONARCLOUD SONARQUBE SELF_HOSTED SNYK TRIVY CODEQL; do
    printf 'a: 1\n# --- %s-START ---\nkept: %s\n# --- %s-END ---\n' "$tag" "$tag" "$tag" > "$T/$tag.tmpl"
  done
  local -a files=(SONARCLOUD.tmpl SONARQUBE.tmpl SELF_HOSTED.tmpl SNYK.tmpl TRIVY.tmpl CODEQL.tmpl)
  kept() {
    local k="" t
    for t in SONARCLOUD SONARQUBE SELF_HOSTED SNYK TRIVY CODEQL; do
      if grep -q "kept: $t" "$OUT/$t"; then k="$k $t"; fi
    done
    printf '%s' "${k# }"
  }
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --visibility public \
    --static-analysis sonarcloud --vulnerabilities snyk --code-scanning codeql "${files[@]}"
  [ "$status" -eq 0 ]
  [ "$(kept)" = "SONARCLOUD SNYK CODEQL" ]
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --visibility private \
    --static-analysis sonarqube --vulnerabilities trivy --code-scanning none "${files[@]}"
  [ "$status" -eq 0 ]
  [ "$(kept)" = "SONARQUBE SELF_HOSTED TRIVY" ]
  # the §3l IaC path passes no toolchain: every tool block strips, nothing fails
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" "${files[@]}"
  [ "$status" -eq 0 ]
  [ "$(kept)" = "" ]
  grep -qx 'a: 1' "$OUT/SNYK"
}

@test "render: #1670 a toolchain value outside its set, or a rejected combination, is a usage error" {
  printf 'x: 1\n' > "$T/x.tmpl"
  local flag bad want
  for flag in --static-analysis --vulnerabilities --code-scanning; do
    case "$flag" in
    --static-analysis) bad=sonarcube want="sonarcloud | sonarqube" ;;
    --vulnerabilities) bad=snik want="snyk | trivy" ;;
    --code-scanning) bad=cdoeql want="codeql | none" ;;
    esac
    run zsh "$SCRIPT" --templates "$T" --out "$OUT" "$flag" "$bad" x.tmpl
    [ "$status" -eq 2 ]
    contains "$output" "$flag must be one of $want, got: $bad"
    [ ! -e "$OUT/x" ]
  done
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --visibility public --static-analysis sonarqube x.tmpl
  [ "$status" -eq 2 ]
  contains "$output" "public + sonarqube is never rendered"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --visibility private --code-scanning codeql x.tmpl
  [ "$status" -eq 2 ]
  contains "$output" "private + codeql is never rendered"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --visibility internal x.tmpl
  [ "$status" -eq 2 ]
  contains "$output" "--visibility must be public or private"
  [ ! -e "$OUT/x" ]
}

@test "render: #1670 RUNNER, SWIFT_RUNNER and SAST_GATE derive from the toolchain, and only from a passed flag" {
  printf 'r: {{RUNNER}}\ns: {{SWIFT_RUNNER}}\ng: {{SAST_GATE}}\n' > "$T/d.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --visibility private \
    --static-analysis sonarqube --vulnerabilities trivy --code-scanning none d.tmpl
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/d")" = "$(printf 'r: self-hosted\ns: [self-hosted, macos]\ng: the required `semgrep` check')" ]
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --languages python --static-analysis sonarcloud \
    --vulnerabilities snyk --code-scanning codeql d.tmpl
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/d")" = "$(printf 'r: ubuntu-latest\ns: macos-latest\ng: CodeQL'"'"'s required `analyze (<lang>)` checks')" ]
  # codeql with no CodeQL language to analyse: no analyze leg exists, so semgrep gates
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --languages "" --static-analysis sonarcloud \
    --vulnerabilities snyk --code-scanning codeql d.tmpl
  [ "$status" -eq 0 ]
  [ "$(sed -n 3p "$OUT/d")" = 'g: the required `semgrep` check' ]
  # no toolchain: never a guessed runner — the leftover check names each one
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" d.tmpl
  [ "$status" -eq 1 ]
  contains "$output" "{{RUNNER}}"
  contains "$output" "{{SWIFT_RUNNER}}"
  contains "$output" "{{SAST_GATE}}"
  # nor from part of the toolchain, whichever flag is missing: a partial one would
  # strip the missing tool's blocks
  local -a all=(--static-analysis sonarcloud --vulnerabilities snyk --code-scanning none)
  local i
  for i in 0 2 4; do
    run zsh "$SCRIPT" --templates "$T" --out "$OUT" "${all[@]:0:i}" "${all[@]:i+2}" d.tmpl
    [ "$status" -eq 1 ]
    contains "$output" "{{RUNNER}}"
  done
}

@test "render: #1670 REQUIRED_CONTEXTS lists D1's contexts plus no-cluster-deploy, one bullet each" {
  printf 'before\n{{REQUIRED_CONTEXTS}}\nafter\n' > "$T/c.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --languages "python javascript" --docker true \
    --static-analysis sonarcloud --vulnerabilities trivy --code-scanning codeql c.tmpl
  [ "$status" -eq 0 ]
  local want
  want="$(printf 'before\n'; printf '  - `%s`\n' test-and-coverage sonarcloud trivy-fs semgrep license-fs \
    pre-commit no-cluster-deploy 'analyze (python)' 'analyze (javascript-typescript)' image; printf 'after')"
  [ "$(cat "$OUT/c")" = "$want" ]
  # snyk has no CI job, codeql none has no analyze leg, no Dockerfile no image
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --languages python --visibility private \
    --static-analysis sonarqube --vulnerabilities snyk --code-scanning none c.tmpl
  [ "$status" -eq 0 ]
  [ "$(grep -c '^  - ' "$OUT/c")" -eq 6 ]
  run ! grep -qE 'trivy-fs|analyze|image' "$OUT/c"
  grep -qx '  - `sonarqube`' "$OUT/c"
  # without the full toolchain it is never guessed — whichever flag is missing
  local -a all=(--static-analysis sonarqube --vulnerabilities snyk --code-scanning none)
  local i
  for i in 0 2 4; do
    run zsh "$SCRIPT" --templates "$T" --out "$OUT" --languages python --visibility private \
      "${all[@]:0:i}" "${all[@]:i+2}" c.tmpl
    [ "$status" -eq 1 ]
    contains "$output" "{{REQUIRED_CONTEXTS}}"
  done
}

@test "render: DOCKER block follows --docker" {
  printf '# --- DOCKER-START ---\ndocker: yes\n# --- DOCKER-END ---\n' > "$T/d.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --docker false d.tmpl
  [ "$status" -eq 0 ]
  run ! grep -q 'docker: yes' "$OUT/d"
}

@test "render: #1604 --gate-command defaults to make lint, and an explicit value replaces it verbatim" {
  printf 'run: {{GATE_COMMAND}}\n' > "$T/g.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" g.tmpl
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/g")" = "run: make lint" ]
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --gate-command 'make a && make b' g.tmpl
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/g")" = "run: make a && make b" ]
}

@test "render: #1604 a BLANK or multi-line --gate-command is a usage error that writes nothing" {
  # a blank command renders a gate that runs nothing — green on every PR — and a
  # newline breaks the workflow's `run: |` block
  printf 'run: {{GATE_COMMAND}}\n' > "$T/g.tmpl"
  local bad
  for bad in '' ' ' $'make lint\nmake more'; do
    run zsh "$SCRIPT" --templates "$T" --out "$OUT" --gate-command "$bad" g.tmpl
    [ "$status" -eq 2 ]
    contains "$output" "--gate-command needs a non-blank, single-line value"
    [ ! -e "$OUT/g" ]
  done
}

@test "render: #1604 KUBERNETES block follows --primary kubernetes" {
  printf 'a: 1\n# --- KUBERNETES-START ---\ngate: yes\n# --- KUBERNETES-END ---\n' > "$T/k.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --primary kubernetes k.tmpl
  [ "$status" -eq 0 ]
  grep -qx 'gate: yes' "$OUT/k"
  # an EXACT match only: another primary, a prefix of `kubernetes`, and no
  # --primary at all each strip it
  local primary
  for primary in --primary=python --primary=kubernetes-operator none; do
    if [ "$primary" = none ]; then
      run zsh "$SCRIPT" --templates "$T" --out "$OUT" k.tmpl
    else
      run zsh "$SCRIPT" --templates "$T" --out "$OUT" --primary "${primary#--primary=}" k.tmpl
    fi
    [ "$status" -eq 0 ]
    run ! grep -q 'gate: yes' "$OUT/k"
    # the rest of the file still rendered, so the strip is a decision, not a blank file
    grep -qx 'a: 1' "$OUT/k"
  done
}

@test "render: #1604 the real .maintenance.yml.tmpl records gate: only on the kubernetes primary" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" --primary kubernetes \
    common/.maintenance.yml.tmpl
  [ "$status" -eq 0 ]
  [ "$(yq -r '.gate' "$OUT/common/.maintenance.yml")" = "make lint" ]
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" --primary python --languages python \
    --static-analysis sonarcloud --vulnerabilities snyk --code-scanning codeql \
    common/.maintenance.yml.tmpl
  [ "$status" -eq 0 ]
  [ "$(yq -r '.primary' "$OUT/common/.maintenance.yml")" = "python" ]
  run ! grep -q '^gate:' "$OUT/common/.maintenance.yml"
  run ! grep -q 'KUBERNETES' "$OUT/common/.maintenance.yml"
}

# --- #1651: the declared toolchain in .maintenance.yml's tools: block -------------

@test "render: #1651 the toolchain flags fill .maintenance.yml's tools: block exactly" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" --primary java --languages java \
    --static-analysis sonarcloud --vulnerabilities snyk --code-scanning none \
    common/.maintenance.yml.tmpl
  [ "$status" -eq 0 ]
  [ "$(yq -o=json -I=0 '.tools' "$OUT/common/.maintenance.yml")" = \
    '{"static_analysis":"sonarcloud","vulnerabilities":"snyk","code_scanning":"none"}' ]
  run ! grep -qE '\{\{(STATIC_ANALYSIS|VULNERABILITIES|CODE_SCANNING)\}\}' "$OUT/common/.maintenance.yml"
}

@test "render: #1651 a language-path render that forgot a toolchain flag trips the leftover check" {
  # each of the three in turn: none has a default to fall back on
  local -a all=(--static-analysis sonarcloud --vulnerabilities snyk --code-scanning codeql)
  local i
  for i in 0 2 4; do
    local -a flags=("${all[@]:0:i}" "${all[@]:i+2}")
    run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" --primary java --languages java \
      "${flags[@]}" common/.maintenance.yml.tmpl
    [ "$status" -eq 1 ]
    local omitted="${all[i]#--}"
    omitted="${omitted//-/_}"
    contains "$output" "{{$(printf '%s' "$omitted" | tr '[:lower:]' '[:upper:]')}}"
  done
}

@test "render: #1651 a blank toolchain flag is a usage error that writes nothing" {
  # a blank value would render `code_scanning: ` — a null that records nothing
  printf 'cs: {{CODE_SCANNING}}\n' > "$T/c.tmpl"
  local flag
  for flag in --static-analysis --vulnerabilities --code-scanning; do
    run zsh "$SCRIPT" --templates "$T" --out "$OUT" "$flag" ' ' c.tmpl
    [ "$status" -eq 2 ]
    contains "$output" "$flag needs a non-blank value"
    [ ! -e "$OUT/c" ]
  done
}

@test "render: #1651 the §3l IaC path renders no tools: block and needs no toolchain flag" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" --primary kubernetes --languages "" \
    common/.maintenance.yml.tmpl
  [ "$status" -eq 0 ]
  [ "$(yq -r '.tools' "$OUT/common/.maintenance.yml")" = null ]
  run ! grep -q 'TOOLCHAIN' "$OUT/common/.maintenance.yml"
}

@test "render: #1651 TOOLCHAIN block is kept for every primary but kubernetes, and with no --primary" {
  printf 'a: 1\n# --- TOOLCHAIN-START ---\ntools: yes\n# --- TOOLCHAIN-END ---\n' > "$T/t.tmpl"
  local primary
  for primary in python java claude-plugin kubernetes-operator; do
    run zsh "$SCRIPT" --templates "$T" --out "$OUT" --primary "$primary" t.tmpl
    [ "$status" -eq 0 ]
    grep -qx 'tools: yes' "$OUT/t"
  done
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" t.tmpl
  [ "$status" -eq 0 ]
  grep -qx 'tools: yes' "$OUT/t"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --primary kubernetes t.tmpl
  [ "$status" -eq 0 ]
  run ! grep -q 'tools: yes' "$OUT/t"
  grep -qx 'a: 1' "$OUT/t"
}

@test "render: #1651 a declare-nothing .maintenance.yml is today's file plus the appended tools: block" {
  local vis sa v cs
  for vis in public private; do
    if [ "$vis" = public ]; then sa=sonarcloud v=snyk cs=codeql; else sa=sonarqube v=trivy cs=none; fi
    run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" --primary python --languages python \
      --visibility "$vis" --static-analysis "$sa" --vulnerabilities "$v" --code-scanning "$cs" \
      common/.maintenance.yml.tmpl
    [ "$status" -eq 0 ]
    # the pre-#1651 render, byte for byte, then the block holding the visibility default
    [ "$(cat "$OUT/common/.maintenance.yml")" = "# Declares this repo's PRIMARY type for /development:maintenance.
# The primary stack gets the full pipeline (its app-grade gates: coverage floor,
# dependency upgrades, ...); everything else detected is AUXILIARY and gets a
# mechanical/lint-level treatment only. See ARCHITECTURE.md \"Primary / auxiliary
# model\" in the development plugin family.
primary: python
# --- TOOLCHAIN-START ---
# The quality toolchain /development:bootstrap resolved (#1651). A recorded value wins on every
# re-run: static_analysis sonarcloud | sonarqube, vulnerabilities snyk | trivy, code_scanning codeql | none.
tools:
  static_analysis: $sa
  vulnerabilities: $v
  code_scanning: $cs
# --- TOOLCHAIN-END ---" ]
  done
}

@test "render: #1670 an IaC-path render (no toolchain flags) of SETUP.md and the pre-commit config still succeeds" {
  # §3l renders SETUP.md with --primary kubernetes and no toolchain: its §4 list
  # sits in the TOOLCHAIN block, and every tool block strips
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" --primary kubernetes --languages "" \
    --project-name demo --project-slug acme/demo --project-key acme_demo --org-key acme \
    common/SETUP.md.tmpl common/.pre-commit-config.yaml.tmpl
  [ "$status" -eq 0 ]
  # (§2a Scorecard stays: it is PUBLIC-scoped, and §3l keeps scorecard.yml)
  run ! grep -qE '^## (2|2b|3)\. ' "$OUT/common/SETUP.md"
  run ! grep -q 'trivy-fs' "$OUT/common/.pre-commit-config.yaml"
}

@test "render: #1604 the output carries the template's executable bit, in both directions" {
  mkdir -p "$T/hooks"
  printf '#!/bin/sh\ntrue\n' > "$T/hooks/x.tmpl"
  chmod 0755 "$T/hooks/x.tmpl"
  printf 'notes\n' > "$T/notes.md.tmpl"
  chmod 0644 "$T/notes.md.tmpl"
  # a stale executable output from an earlier render must not keep its bit
  printf 'old\n' > "$OUT/notes.md"
  chmod 0755 "$OUT/notes.md"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" hooks/x.tmpl notes.md.tmpl
  [ "$status" -eq 0 ]
  [ -x "$OUT/hooks/x" ]
  [ ! -x "$OUT/notes.md" ]
  [ "$(cat "$OUT/notes.md")" = "notes" ]
}

@test "render: #1632 the shipped check-ops-conformance.zsh template renders executable" {
  # the resilience READMEs run scripts/check-ops-conformance.zsh by path, so the
  # real template must carry the bit the mirror above copies onto the output
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    common/scripts/check-ops-conformance.zsh
  [ "$status" -eq 0 ]
  [ -x "$OUT/common/scripts/check-ops-conformance.zsh" ]
}

@test "render: #1604 an IaC-shaped tag keep_block was never taught still fails loudly" {
  # KUBERNETES was ADDED to the keep-rules; the loud failure for every other tag stays
  printf '# --- IAC-START ---\nx\n# --- IAC-END ---\n' > "$T/i.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --primary kubernetes i.tmpl
  [ "$status" -eq 1 ]
  contains "$output" "unknown block tag 'IAC'"
}

@test "render: unknown block tag fails loudly with file:line" {
  printf 'a\n# --- MYSTERY-START ---\nx\n# --- MYSTERY-END ---\n' > "$T/u.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" u.tmpl
  [ "$status" -eq 1 ]
  contains "$output" "u.tmpl:2"
  contains "$output" "MYSTERY"
}

@test "render: unterminated block fails loudly" {
  printf '# --- JAVA-START ---\nx\n' > "$T/u.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" u.tmpl
  [ "$status" -eq 1 ]
  contains "$output" "unterminated"
}

@test "render: 3+ blank lines left by adjacent stripped blocks collapse to one" {
  printf 'a\n\n# --- PYTHON-START ---\np\n# --- PYTHON-END ---\n\n# --- GO-START ---\ng\n# --- GO-END ---\n\nb\n' > "$T/g.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --languages "java" g.tmpl
  [ "$status" -eq 0 ]
  # a, one blank, b — never two-plus consecutive blanks
  max=$(awk 'BEGIN{b=0;m=0} /^$/{b++; if(b>m)m=b; next} {b=0} END{print m}' "$OUT/g")
  [ "$max" -le 1 ]
  grep -q '^a$' "$OUT/g"
  grep -q '^b$' "$OUT/g"
}

@test "render: an existing double blank line without stripping is preserved" {
  printf 'a\n\n\nb\n' > "$T/g.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" g.tmpl
  [ "$status" -eq 0 ]
  [ "$(printf 'a\n\n\nb\n')" = "$(cat "$OUT/g")" ]
}

# --- leftover-placeholder check --------------------------------------------------

@test "render: surviving {{UPPERCASE}} placeholder -> exit 1 listing file and name" {
  echo 'key: {{PROJECT_KEY}}' > "$T/f.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" f.tmpl
  [ "$status" -eq 1 ]
  contains "$output" "{{PROJECT_KEY}}"
  contains "$output" "unsubstituted placeholders"
}

@test "render: GitHub \${{ }} expressions and docker-metadata literals are not flagged" {
  cat > "$T/f.yml.tmpl" <<'EOF'
a: ${{ secrets.GITHUB_TOKEN }}
b: ${{ github.base_ref }}
c: type=semver,pattern={{version}}
d: type=semver,pattern={{major}}.{{minor}}
e: type=raw,value=latest,enable={{is_default_branch}}
f: --format '{{json .SBOM}}'
EOF
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" f.yml.tmpl
  [ "$status" -eq 0 ]
  grep -q '{{version}}' "$OUT/f.yml"
  grep -q '\${{ secrets.GITHUB_TOKEN }}' "$OUT/f.yml"
}

# --- determinism + real templates -------------------------------------------------

@test "render: reruns are byte-identical (acceptance: deterministic across sessions)" {
  mkdir -p "$BATS_TEST_TMPDIR/o1" "$BATS_TEST_TMPDIR/o2"
  args=(--templates "$REAL_TEMPLATES"
    --project-name tick --project-slug o/tick --project-key o_tick --org-key o
    --languages "java" --docker true --security-contact-email ""
    --static-analysis sonarcloud --vulnerabilities snyk --code-scanning codeql
    public/.github/workflows/quality-public.yml.tmpl
    common/.github/SECURITY.md.tmpl
    common/.pre-commit-config.yaml.tmpl)
  zsh "$SCRIPT" --out "$BATS_TEST_TMPDIR/o1" "${args[@]}"
  zsh "$SCRIPT" --out "$BATS_TEST_TMPDIR/o2" "${args[@]}"
  diff -r "$BATS_TEST_TMPDIR/o1" "$BATS_TEST_TMPDIR/o2"
}

@test "render: real quality-public.yml.tmpl for a java+docker repo renders clean" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --project-name tick --project-slug o/tick --project-key o_tick --org-key o \
    --languages "java" --docker true \
    --static-analysis sonarcloud --vulnerabilities snyk --code-scanning codeql \
    public/.github/workflows/quality-public.yml.tmpl
  [ "$status" -eq 0 ]
  Q="$OUT/public/.github/workflows/quality-public.yml"
  # the #546-reported case: the unconditional pre-commit job got the default
  grep -q 'python-version: "3.12"' "$Q"
  # java kept, other language lanes stripped
  grep -q 'JAVA-START' "$Q"
  run ! grep -q 'PYTHON-START' "$Q"
  run ! grep -q 'JAVASCRIPT-START' "$Q"
  # docker lane kept, with the #547 split intact
  grep -q 'push-and-sign:' "$Q"
  # no uppercase placeholder survives
  run ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$Q"
}

@test "render: real quality-public.yml.tmpl for a go repo keeps the GO coverage-floor block (#875)" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --project-name svc --project-slug o/svc --project-key o_svc --org-key o \
    --languages "go" \
    --static-analysis sonarcloud --vulnerabilities snyk --code-scanning codeql \
    public/.github/workflows/quality-public.yml.tmpl
  [ "$status" -eq 0 ]
  Q="$OUT/public/.github/workflows/quality-public.yml"
  # GO lane kept with -race + the coverage-floor step (#874/#875), others stripped.
  grep -q 'Test (Go, -race)' "$Q"
  grep -q 'go test -race ./\.\.\. -coverprofile=coverage.out' "$Q"
  grep -q 'Coverage floor — 90% on new code (Go)' "$Q"
  grep -q 'gocover-cobertura' "$Q"
  run ! grep -q 'PYTHON-START' "$Q"
  run ! grep -q 'JAVA-START' "$Q"
  run ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$Q"
}

@test "render: real ko-image.yml.tmpl renders clean with DEFAULT_BRANCH substituted (#875)" {
  # Pass a non-default branch so the assertion proves the caller-supplied
  # --default-branch actually flows into {{DEFAULT_BRANCH}}, rather than merely
  # coinciding with render.zsh's built-in 'main' default.
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --project-name svc --project-slug o/svc --project-key o_svc --org-key o \
    --languages "go" --default-branch trunk \
    languages/go/.github/workflows/ko-image.yml.tmpl
  [ "$status" -eq 0 ]
  K="$OUT/languages/go/.github/workflows/ko-image.yml"
  grep -q 'name: ko-image' "$K"
  grep -q 'branches: \["trunk"\]' "$K"          # caller's --default-branch propagated
  grep -q 'ko build --sbom=spdx' "$K"
  grep -q 'cosign sign --yes' "$K"
  grep -q 'ko_decision' "$K"                    # path-conditional on .ko.yaml
  # GHCR repo name is lowercased before ko push (a mixed-case owner would break
  # the publish otherwise) — lock the fix in.
  grep -q "tr '\[:upper:\]' '\[:lower:\]'" "$K"
  run ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$K"
}

@test "render: real ko-base-digest-refresh.yml.tmpl renders clean (#876)" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --project-name svc --project-slug o/svc --project-key o_svc --org-key o \
    --languages "go" --default-branch trunk \
    languages/go/.github/workflows/ko-base-digest-refresh.yml.tmpl
  [ "$status" -eq 0 ]
  K="$OUT/languages/go/.github/workflows/ko-base-digest-refresh.yml"
  grep -q 'name: ko-base-digest-refresh' "$K"
  grep -q 'schedule:' "$K"                          # scheduled, not PR-triggered
  grep -q 'defaultBaseImage:' "$K"                  # reads the .ko.yaml pin
  grep -q 'imagetools inspect' "$K"                 # resolves the current digest
  grep -q -- '--base "trunk"' "$K"                   # caller's --default-branch propagated
  run ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$K"
}

@test "render: real pre-commit template for a go repo keeps the coverage-floor-go hook (#875)" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --languages "go" common/.pre-commit-config.yaml.tmpl
  [ "$status" -eq 0 ]
  P="$OUT/common/.pre-commit-config.yaml"
  grep -q 'id: golangci-lint' "$P"
  grep -q 'id: coverage-floor-go' "$P"
  grep -q -- '-- "\*.go"' "$P"                  # diff guard keyed on Go files
  run ! grep -q 'coverage-floor-swift' "$P"     # other languages' hooks stripped
  run ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$P"
}

@test "render: real pre-commit template for a non-plugin java repo drops the CLAUDE-PLUGIN hooks" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --languages "java" common/.pre-commit-config.yaml.tmpl
  [ "$status" -eq 0 ]
  P="$OUT/common/.pre-commit-config.yaml"
  run ! grep -q 'CLAUDE-PLUGIN' "$P"
  grep -q 'JAVA-START' "$P"
}

@test "render: --approver-lang substitutes {{APPROVER_LANG}} (#241)" {
  echo 'skill: /development-{{APPROVER_LANG}}:approve agent: {{APPROVER_LANG}}-approver' > "$T/f.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --approver-lang python f.tmpl
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/f")" = "skill: /development-python:approve agent: python-approver" ]
}

@test "render: real approver-policy core + overlay render clean for all three languages (#241)" {
  for lang in python java swift; do
    rm -rf "$OUT"; mkdir -p "$OUT"
    run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" --approver-lang "$lang" \
      common/approver-policy-core.md.tmpl \
      "languages/$lang/approver-policy-overlay.md.tmpl"
    [ "$status" -eq 0 ]
    CORE="$OUT/common/approver-policy-core.md"
    OVERLAY="$OUT/languages/$lang/approver-policy-overlay.md"
    grep -q "approver-policy: core" "$CORE"
    grep -q "approver-policy: overlay ($lang)" "$OVERLAY"
    grep -q "/development-$lang:approve" "$CORE"
    # the #788 live-state metadata re-verification rule must survive renders
    grep -q "live state governs" "$CORE"
    grep -q "tool failure, never a contradiction" "$CORE"
    # concatenated single-file shape: core then overlay, no leftovers
    cat "$CORE" "$OVERLAY" > "$BATS_TEST_TMPDIR/policy-$lang.md"
    run ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$BATS_TEST_TMPDIR/policy-$lang.md"
    grep -q "suggested_agent" "$BATS_TEST_TMPDIR/policy-$lang.md"
  done
}

@test "render: real acceptance.yml spine renders a matrix leg per interface (#697)" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --default-branch main --acceptance-interfaces "cli, web-ui" \
    common/.github/workflows/acceptance.yml.tmpl
  [ "$status" -eq 0 ]
  A="$OUT/common/.github/workflows/acceptance.yml"
  # matrix over the passed interfaces -> check surfaces as `acceptance (<iface>)`
  grep -q 'interface: \[cli, web-ui\]' "$A"
  grep -qE '^\s+acceptance:' "$A"
  # report contract: acceptance-report-<interface> artifact, JUnit XML
  grep -q 'name: acceptance-report-${{ matrix.interface }}' "$A"
  grep -q 'if: always()' "$A"
  grep -q 'testsuites' "$A"
  # no uppercase placeholder survives
  run ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$A"
}

@test "render: acceptance.yml without --acceptance-interfaces fails the leftover check (#697)" {
  # No default for {{ACCEPTANCE_INTERFACES}} — omitting the flag must trip the
  # loud leftover-placeholder failure, so the workflow is never rendered with an
  # empty interface set.
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --default-branch main \
    common/.github/workflows/acceptance.yml.tmpl
  [ "$status" -eq 1 ]
  contains "$output" "ACCEPTANCE_INTERFACES"
}

@test "render: acceptance.yml single interface renders a one-leg matrix (#697)" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --default-branch main --acceptance-interfaces "cli" \
    common/.github/workflows/acceptance.yml.tmpl
  [ "$status" -eq 0 ]
  grep -q 'interface: \[cli\]' "$OUT/common/.github/workflows/acceptance.yml"
}

@test "render: acceptance.yml wires the cli exercise into the spine (#698)" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --default-branch main --python-version 3.13 --acceptance-interfaces "cli" \
    common/.github/workflows/acceptance.yml.tmpl
  [ "$status" -eq 0 ]
  A="$OUT/common/.github/workflows/acceptance.yml"
  # cli leg installs the package and runs pytest -> JUnit into acceptance-report/
  grep -q "if: matrix.interface == 'cli'" "$A"
  grep -q 'python-version: "3.13"' "$A"
  grep -q 'pytest tests/acceptance/cli/' "$A"
  grep -q -- '--junitxml="acceptance-report/acceptance-cli.xml"' "$A"
  run ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$A"
}

@test "render: cli acceptance smoke test substitutes the entry point (#698)" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --cli-entry-point "aido" \
    languages/python/tests/acceptance/cli/test_smoke.py.tmpl
  [ "$status" -eq 0 ]
  S="$OUT/languages/python/tests/acceptance/cli/test_smoke.py"
  grep -q 'ENTRY_POINT = "aido"' "$S"
  run ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$S"
  # valid Python
  python3 -m py_compile "$S"
}

@test "render: cli smoke test without --cli-entry-point fails the leftover check (#698)" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    languages/python/tests/acceptance/cli/test_smoke.py.tmpl
  [ "$status" -eq 1 ]
  contains "$output" "CLI_ENTRY_POINT"
}

@test "render: static file without placeholders or blocks passes through unchanged" {
  printf 'plain: file\nno: templating\n' > "$T/static.yml"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" static.yml
  [ "$status" -eq 0 ]
  diff "$T/static.yml" "$OUT/static.yml"
}

# --- #766 docs machinery: markdown markers, SURFACE_* tags, PAGES_URL ---------

@test "render: #766 markdown HTML-comment block is stripped when its tag does not apply" {
  printf '# T\n\n<!-- --- SURFACE_REST-START --- -->\n- [REST](use-the-rest-api.md)\n<!-- --- SURFACE_REST-END --- -->\nafter\n' > "$T/m.md.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" m.md.tmpl
  [ "$status" -eq 0 ]
  run ! grep -q "SURFACE_REST" "$OUT/m.md"
  run ! grep -q "use-the-rest-api" "$OUT/m.md"
  grep -q "after" "$OUT/m.md"
}

@test "render: #766 markdown HTML-comment block is kept (markers retained) when its tag applies" {
  printf '<!-- --- SURFACE_CLI-START --- -->\n- [CLI](use-the-cli.md)\n<!-- --- SURFACE_CLI-END --- -->\n' > "$T/m.md.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --acceptance-interfaces "cli" m.md.tmpl
  [ "$status" -eq 0 ]
  grep -q "use-the-cli.md" "$OUT/m.md"
  grep -q "SURFACE_CLI-START" "$OUT/m.md"
}

@test "render: #766 SURFACE tags follow --acceptance-interfaces (kept + stripped in one file)" {
  cat > "$T/nav.yml.tmpl" <<'TMPL'
nav:
# --- SURFACE_CLI-START ---
  - cli: how-to/use-the-cli.md
# --- SURFACE_CLI-END ---
# --- SURFACE_REST-START ---
  - rest: how-to/use-the-rest-api.md
# --- SURFACE_REST-END ---
# --- SURFACE_WEB_UI-START ---
  - web: how-to/use-the-web-ui.md
# --- SURFACE_WEB_UI-END ---
TMPL
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --acceptance-interfaces "cli, web-ui" nav.yml.tmpl
  [ "$status" -eq 0 ]
  grep -q "use-the-cli.md" "$OUT/nav.yml"
  grep -q "use-the-web-ui.md" "$OUT/nav.yml"
  run ! grep -q "use-the-rest-api.md" "$OUT/nav.yml"
}

@test "render: #766 no --acceptance-interfaces -> every SURFACE block is stripped" {
  printf '# --- SURFACE_CLI-START ---\nx\n# --- SURFACE_CLI-END ---\n# --- SURFACE_GRPC-START ---\ny\n# --- SURFACE_GRPC-END ---\nkeep\n' > "$T/s.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" s.tmpl
  [ "$status" -eq 0 ]
  run ! grep -qE '^(x|y)$' "$OUT/s"
  grep -q "keep" "$OUT/s"
}

@test "render: #766 PAGES_URL derives from --project-slug" {
  printf 'site_url: {{PAGES_URL}}\n' > "$T/mk.yml.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --project-slug "owner/some-repo" mk.yml.tmpl
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/mk.yml")" = "site_url: https://owner.github.io/some-repo/" ]
}

@test "render: #766 PAGES_URL without --project-slug survives to the leftover check" {
  printf 'site_url: {{PAGES_URL}}\n' > "$T/mk.yml.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" mk.yml.tmpl
  [ "$status" -eq 1 ]
  contains "$output" "PAGES_URL"
}
