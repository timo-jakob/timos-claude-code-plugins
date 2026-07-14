#!/usr/bin/env bats
#
# Tests for render.zsh — the deterministic bootstrap template renderer (#546).
# Before it, every bootstrap session hand-wrote its own renderer from the
# SKILL.md prose, each with fresh bugs (the tick-server-simulator session's
# flagged the intentional {{PYTHON_VERSION}} default in the unconditional
# pre-commit CI job as an error). These tests pin the spec in one place:
# the placeholder table, the conditional-block stripping rules, the loud
# leftover-placeholder failure, and byte-identical reruns.

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
  [[ "$output" == *"usage:"* ]]
}

@test "render: missing file list -> usage (exit 2)" {
  run zsh "$SCRIPT" --templates "$T" --out "$OUT"
  [ "$status" -eq 2 ]
}

@test "render: unknown flag -> usage (exit 2)" {
  echo "x" > "$T/a.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --frobnicate yes a.tmpl
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "render: nonexistent template -> error naming it (exit 1)" {
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" missing.tmpl
  [ "$status" -eq 1 ]
  [[ "$output" == *"template not found"* ]]
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

@test "render: CODEQL_LANGUAGES is mapped from --languages (typescript -> javascript-typescript)" {
  echo 'langs: [{{CODEQL_LANGUAGES}}]' > "$T/f.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --languages "typescript python" f.tmpl
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/f")" = "langs: [javascript-typescript,python]" ]
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
  ! grep -q 'SECURITY_CONTACT_BLOCK' "$OUT/s.md"
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
  ! grep -q 'python: yes' "$OUT/b.yml"
  ! grep -q 'PYTHON-START' "$OUT/b.yml"
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
  ! grep -q 'linux: yes' "$OUT/l"
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
  ! grep -q 'spm: yes' "$OUT/n"
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
  ! grep -q 'spm' "$OUT/n"
  ! grep -q 'SWIFT' "$OUT/n"
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
  ! grep -q 'plugin: yes' "$OUT/c"
}

@test "render: PRIVATE block follows --visibility" {
  printf '# --- PRIVATE-START ---\npriv: yes\n# --- PRIVATE-END ---\n' > "$T/p.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --visibility private p.tmpl
  [ "$status" -eq 0 ]
  grep -q 'priv: yes' "$OUT/p"
}

@test "render: DOCKER block follows --docker" {
  printf '# --- DOCKER-START ---\ndocker: yes\n# --- DOCKER-END ---\n' > "$T/d.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" --docker false d.tmpl
  [ "$status" -eq 0 ]
  ! grep -q 'docker: yes' "$OUT/d"
}

@test "render: unknown block tag fails loudly with file:line" {
  printf 'a\n# --- MYSTERY-START ---\nx\n# --- MYSTERY-END ---\n' > "$T/u.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" u.tmpl
  [ "$status" -eq 1 ]
  [[ "$output" == *"u.tmpl:2"* ]]
  [[ "$output" == *"MYSTERY"* ]]
}

@test "render: unterminated block fails loudly" {
  printf '# --- JAVA-START ---\nx\n' > "$T/u.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" u.tmpl
  [ "$status" -eq 1 ]
  [[ "$output" == *"unterminated"* ]]
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
  [[ "$output" == *"{{PROJECT_KEY}}"* ]]
  [[ "$output" == *"unsubstituted placeholders"* ]]
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
    public/.github/workflows/quality-public.yml.tmpl
  [ "$status" -eq 0 ]
  Q="$OUT/public/.github/workflows/quality-public.yml"
  # the #546-reported case: the unconditional pre-commit job got the default
  grep -q 'python-version: "3.12"' "$Q"
  # java kept, other language lanes stripped
  grep -q 'JAVA-START' "$Q"
  ! grep -q 'PYTHON-START' "$Q"
  ! grep -q 'TYPESCRIPT-START' "$Q"
  # docker lane kept, with the #547 split intact
  grep -q 'push-and-sign:' "$Q"
  # no uppercase placeholder survives
  ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$Q"
}

@test "render: real pre-commit template for a non-plugin java repo drops the CLAUDE-PLUGIN hooks" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --languages "java" common/.pre-commit-config.yaml.tmpl
  [ "$status" -eq 0 ]
  P="$OUT/common/.pre-commit-config.yaml"
  ! grep -q 'CLAUDE-PLUGIN' "$P"
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
    # concatenated single-file shape: core then overlay, no leftovers
    cat "$CORE" "$OVERLAY" > "$BATS_TEST_TMPDIR/policy-$lang.md"
    ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$BATS_TEST_TMPDIR/policy-$lang.md"
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
  ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$A"
}

@test "render: acceptance.yml without --acceptance-interfaces fails the leftover check (#697)" {
  # No default for {{ACCEPTANCE_INTERFACES}} — omitting the flag must trip the
  # loud leftover-placeholder failure, so the workflow is never rendered with an
  # empty interface set.
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --default-branch main \
    common/.github/workflows/acceptance.yml.tmpl
  [ "$status" -eq 1 ]
  [[ "$output" == *"ACCEPTANCE_INTERFACES"* ]]
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
  ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$A"
}

@test "render: cli acceptance smoke test substitutes the entry point (#698)" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --cli-entry-point "aido" \
    languages/python/tests/acceptance/cli/test_smoke.py.tmpl
  [ "$status" -eq 0 ]
  S="$OUT/languages/python/tests/acceptance/cli/test_smoke.py"
  grep -q 'ENTRY_POINT = "aido"' "$S"
  ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$S"
  # valid Python
  python3 -m py_compile "$S"
}

@test "render: cli smoke test without --cli-entry-point fails the leftover check (#698)" {
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    languages/python/tests/acceptance/cli/test_smoke.py.tmpl
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLI_ENTRY_POINT"* ]]
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
  ! grep -q "SURFACE_REST" "$OUT/m.md"
  ! grep -q "use-the-rest-api" "$OUT/m.md"
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
  ! grep -q "use-the-rest-api.md" "$OUT/nav.yml"
}

@test "render: #766 no --acceptance-interfaces -> every SURFACE block is stripped" {
  printf '# --- SURFACE_CLI-START ---\nx\n# --- SURFACE_CLI-END ---\n# --- SURFACE_GRPC-START ---\ny\n# --- SURFACE_GRPC-END ---\nkeep\n' > "$T/s.tmpl"
  run zsh "$SCRIPT" --templates "$T" --out "$OUT" s.tmpl
  [ "$status" -eq 0 ]
  ! grep -qE '^(x|y)$' "$OUT/s"
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
  [[ "$output" == *"PAGES_URL"* ]]
}
