#!/usr/bin/env bats
#
# Behavioural tests for the contract semver gate wrapper (#693) —
# templates/common/.github/scripts/check-contracts-semver.sh. The gate enforces
# the version triangle and an oasdiff bump-classification (breaking -> major,
# additive -> at least minor, editorial -> any; old majors frozen). oasdiff is
# not in the plugin's macOS toolchain, so a STUB oasdiff on PATH returns the
# classification each test wants (via $OASDIFF_CLASS) — this exercises the gate's
# DECISION logic (triangle, semver bump compare, frozen rule, class->bump match).
# The real-oasdiff integration is exercised by the workflow in CI.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATE="$REPO_ROOT/development/skills/bootstrap/templates/common/.github/scripts/check-contracts-semver.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
  cd "$WORK"
  git init -q
  git config user.email t@example.com
  git config user.name tester

  # Stub oasdiff: honours $OASDIFF_CLASS (breaking|additive|editorial, default
  # editorial). `breaking` returns a non-empty array iff breaking; `diff`
  # (cosmetics excluded) returns a non-empty object iff additive.
  local stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  cat > "$stub/oasdiff" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  --version) echo "oasdiff stub" ;;
  breaking) [[ "${OASDIFF_CLASS:-editorial}" == "breaking" ]] && echo '[{"level":3}]' || echo '[]' ;;
  diff) [[ "${OASDIFF_CLASS:-editorial}" == "additive" ]] && echo '{"paths":{"/x":1}}' || echo '{}' ;;
  *) echo '[]' ;;
esac
EOS
  chmod +x "$stub/oasdiff"
  PATH="$stub:$PATH"
}

# mkspec <dir> <info.version> <servers-major-digits>
mkspec() {
  mkdir -p "$1"
  cat > "$1/openapi.yaml" <<EOF
openapi: 3.1.0
info:
  title: T
  version: "$2"
servers:
  - url: /v$3
paths: {}
EOF
}

run_gate() { run bash "$GATE" --base-ref HEAD --output "$WORK/findings.json"; }

@test "#693 gate: no contracts/ -> passes (exit 0)" {
  git commit -q --allow-empty -m base
  run_gate
  [ "$status" -eq 0 ]
}

@test "#693 gate: additive change with a MINOR bump passes" {
  mkspec contracts/v1 "1.0.0" 1
  git add -A && git commit -qm base
  mkspec contracts/v1 "1.1.0" 1
  OASDIFF_CLASS=additive run_gate
  [ "$status" -eq 0 ]
}

@test "#693 gate: additive change shipped as a PATCH is rejected" {
  mkspec contracts/v1 "1.0.0" 1
  git add -A && git commit -qm base
  mkspec contracts/v1 "1.0.1" 1
  OASDIFF_CLASS=additive run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.violations[]' "$WORK/findings.json" | grep -c 'at least a MINOR')" -eq 1 ]
}

@test "#693 gate: an in-place breaking change to the newest major is rejected (ship a new major)" {
  mkspec contracts/v1 "1.0.0" 1
  git add -A && git commit -qm base
  mkspec contracts/v1 "1.1.0" 1
  OASDIFF_CLASS=breaking run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.violations[]' "$WORK/findings.json" | grep -c 'never an in-place edit')" -eq 1 ]
}

@test "#1330 gate: the ops leg names the OPS family in the ship-a-new-major message" {
  # contracts-semver runs a SECOND time with --contracts-dir contracts/ops, so
  # this message fires on exactly the edit #1330 forbids (an in-place breaking
  # change to the newest ops major). It hardcoded `contracts/` — telling the
  # author to create a business-API major the repo does not have, and leaving the
  # real remedy (contracts/ops/v3/) unstated. The sibling removed-major message
  # already interpolated $CONTRACTS_DIR, which is why this read as an oversight.
  mkspec contracts/ops/v2 "2.0.0" 2
  git add -A && git commit -qm base
  mkspec contracts/ops/v2 "2.1.0" 2
  OASDIFF_CLASS=breaking run bash "$GATE" --base-ref HEAD \
    --contracts-dir contracts/ops --output "$WORK/findings.json"
  [ "$status" -eq 1 ]
  run jq -r '.violations[]' "$WORK/findings.json"
  [ "$status" -eq 0 ]
  case "$output" in
    *"contracts/ops/v3/"*) ;;
    *) printf 'expected contracts/ops/v3/ in: %s\n' "$output" >&2; return 1 ;;
  esac
  # …and never the business family, which is what the bug produced.
  case "$output" in
    *"directory contracts/v3/"*) printf 'named the WRONG family: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "#693 gate: version triangle — info.version major must match the vN directory" {
  # a 2.0.0 spec sitting in contracts/v1/ (servers /v1) — the classic in-place
  # breaking edit that a major bump can't rescue, because the directory is v1
  mkspec contracts/v1 "1.0.0" 1
  git add -A && git commit -qm base
  mkspec contracts/v1 "2.0.0" 1
  OASDIFF_CLASS=editorial run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.violations[]' "$WORK/findings.json" | grep -c 'disagrees with directory')" -ge 1 ]
}

@test "#693 gate: version triangle — servers major must match the vN directory" {
  mkspec contracts/v1 "1.0.0" 2
  git add -A && git commit -qm base
  mkspec contracts/v1 "1.0.1" 2
  OASDIFF_CLASS=editorial run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.violations[]' "$WORK/findings.json" | grep -c 'servers major')" -ge 1 ]
}

@test "#693 gate: a frozen (non-newest) major rejects an additive in-place edit" {
  mkspec contracts/v1 "1.0.0" 1
  mkspec contracts/v2 "2.0.0" 2
  git add -A && git commit -qm base
  # a REAL additive change to the frozen v1 (a new operation), not deprecation
  mkspec contracts/v1 "1.1.0" 1
  yq -i '.paths."/new".get.operationId = "getNew"' contracts/v1/openapi.yaml
  OASDIFF_CLASS=additive run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.violations[]' "$WORK/findings.json" | grep -c 'frozen')" -ge 1 ]
}

@test "#693 gate: a frozen major accepts an editorial (patch) edit" {
  mkspec contracts/v1 "1.0.0" 1
  mkspec contracts/v2 "2.0.0" 2
  git add -A && git commit -qm base
  mkspec contracts/v1 "1.0.1" 1   # patch/editorial edit to frozen v1
  OASDIFF_CLASS=editorial run_gate
  [ "$status" -eq 0 ]
}

@test "#693 gate: adding a brand-new major (absent at base) is allowed" {
  mkspec contracts/v1 "1.0.0" 1
  git add -A && git commit -qm base
  mkspec contracts/v2 "2.0.0" 2   # new major, absent at HEAD
  OASDIFF_CLASS=editorial run_gate
  [ "$status" -eq 0 ]
}

@test "#693 gate: an info.version downgrade is rejected" {
  mkspec contracts/v1 "1.2.0" 1
  git add -A && git commit -qm base
  mkspec contracts/v1 "1.1.0" 1
  OASDIFF_CLASS=editorial run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.violations[]' "$WORK/findings.json" | grep -c 'went backwards')" -eq 1 ]
}

@test "#693 gate: newest major evolves (additive + MINOR) while a frozen sibling is untouched -> passes" {
  mkspec contracts/v1 "1.0.0" 1
  mkspec contracts/v2 "2.0.0" 2
  git add -A && git commit -qm base
  mkspec contracts/v2 "2.1.0" 2   # additive change to the NEWEST major, v1 untouched
  OASDIFF_CLASS=additive run_gate
  [ "$status" -eq 0 ]
  # the untouched frozen v1 must NOT be forced to bump / classified
  [ "$(jq -r '.violations | length' "$WORK/findings.json")" -eq 0 ]
}

@test "#693 gate: an in-place breaking edit to a FROZEN major is rejected" {
  mkspec contracts/v1 "1.0.0" 1
  mkspec contracts/v2 "2.0.0" 2
  git add -A && git commit -qm base
  mkspec contracts/v1 "1.1.0" 1   # breaking edit to the FROZEN v1
  OASDIFF_CLASS=breaking run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.violations[]' "$WORK/findings.json" | grep -c 'frozen')" -ge 1 ]
}

@test "#693 gate: an editorial change with NO bump is rejected (would never republish)" {
  mkspec contracts/v1 "1.0.0" 1
  git add -A && git commit -qm base
  # edit content but leave info.version at 1.0.0 (stub says editorial)
  cat > contracts/v1/openapi.yaml <<'EOF'
openapi: 3.1.0
info:
  title: T CHANGED
  version: "1.0.0"
servers:
  - url: /v1
paths: {}
EOF
  OASDIFF_CLASS=editorial run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.violations[]' "$WORK/findings.json" | grep -c 'requires at least a PATCH')" -eq 1 ]
}

@test "#693 gate: a spec missing info.version is a triangle violation" {
  # base == head (unchanged); the triangle check runs unconditionally
  mkdir -p contracts/v1
  cat > contracts/v1/openapi.yaml <<'EOF'
openapi: 3.1.0
info:
  title: T
servers:
  - url: /v1
paths: {}
EOF
  git add -A && git commit -qm base
  OASDIFF_CLASS=editorial run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.violations[]' "$WORK/findings.json" | grep -c 'missing info.version')" -eq 1 ]
}

@test "#693 gate: a spec with no /vN servers url is a triangle violation" {
  # base == head (unchanged), so the bump check is skipped; the triangle check
  # runs for every head major regardless and must flag the bad servers url
  mkdir -p contracts/v1
  cat > contracts/v1/openapi.yaml <<'EOF'
openapi: 3.1.0
info:
  title: T
  version: "1.0.0"
servers:
  - url: https://api.example.com/
paths: {}
EOF
  git add -A && git commit -qm base
  OASDIFF_CLASS=editorial run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.violations[]' "$WORK/findings.json" | grep -c 'no /vN major segment')" -eq 1 ]
}

@test "#693 gate: deleting a major that was live at base is rejected (retirement is #708)" {
  mkspec contracts/v1 "1.0.0" 1
  mkspec contracts/v2 "2.0.0" 2
  git add -A && git commit -qm base
  rm -rf contracts/v1
  OASDIFF_CLASS=editorial run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.violations[]' "$WORK/findings.json" | grep -c 'removed')" -ge 1 ]
}

@test "#693 gate: missing --base-ref exits 2 (usage)" {
  run bash "$GATE"
  [ "$status" -eq 2 ]
}

@test "#693 gate: an unresolvable base ref fails closed (exit 2)" {
  mkspec contracts/v1 "1.0.0" 1
  git add -A && git commit -qm base
  run bash "$GATE" --base-ref does-not-exist --output "$WORK/findings.json"
  [ "$status" -eq 2 ]
}

# write a v<major> spec with one operation; pass a 4th arg to mark it deprecated
mkspec_op() {
  mkdir -p "contracts/v$3"
  {
    printf 'openapi: 3.1.0\ninfo:\n  title: T\n  version: "%s"\nservers:\n  - url: /v%s\npaths:\n  /w:\n    get:\n      operationId: getW\n' "$1" "$3"
    if [[ -n "${4:-}" ]]; then
      printf '      deprecated: true\n      x-sunset: "2026-12-31"\n'
    fi
    printf '      responses:\n        "200":\n          description: ok\n'
  } > "contracts/v$3/openapi.yaml"
}

@test "#695 gate: deprecating a FROZEN major (deprecated + x-sunset, minor bump) is allowed" {
  mkspec_op "1.0.0" x 1          # v1 operation, not deprecated
  mkspec_op "2.0.0" x 2          # v2 newest
  git add -A && git commit -qm base
  mkspec_op "1.1.0" x 1 deprecate  # deprecate frozen v1 with a minor bump
  OASDIFF_CLASS=additive run_gate
  [ "$status" -eq 0 ]
}

@test "#695 gate: deprecating a frozen major still needs at least a MINOR bump (not patch)" {
  mkspec_op "1.0.0" x 1
  mkspec_op "2.0.0" x 2
  git add -A && git commit -qm base
  mkspec_op "1.0.1" x 1 deprecate  # deprecation shipped as a PATCH
  OASDIFF_CLASS=additive run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.violations[]' "$WORK/findings.json" | grep -c 'at least a MINOR')" -eq 1 ]
}

@test "#695 gate: a NON-deprecation additive change to a frozen major is still rejected" {
  mkspec_op "1.0.0" x 1
  mkspec_op "2.0.0" x 2
  git add -A && git commit -qm base
  # a real additive change to frozen v1 (not deprecation) — the stub says additive
  mkspec contracts/v1 "1.1.0" 1  # replaces v1 with a different (non-deprecation) shape
  OASDIFF_CLASS=additive run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.violations[]' "$WORK/findings.json" | grep -c 'frozen')" -ge 1 ]
}

@test "#693 gate: an oasdiff tool error fails CLOSED (exit 3), not silently editorial" {
  mkspec contracts/v1 "1.0.0" 1
  git add -A && git commit -qm base
  mkspec contracts/v1 "1.1.0" 1   # a changed major, so classify() runs
  local boom="$BATS_TEST_TMPDIR/oasdiff-boom"
  printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 1\n' > "$boom"
  chmod +x "$boom"
  run bash "$GATE" --base-ref HEAD --oasdiff "$boom" --output "$WORK/findings.json"
  [ "$status" -eq 3 ]
}

@test "#693 gate: findings.json has the {violations, majors} shape on a clean pass" {
  mkspec contracts/v1 "1.0.0" 1
  git add -A && git commit -qm base
  mkspec contracts/v1 "1.0.1" 1
  OASDIFF_CLASS=editorial run_gate
  [ "$status" -eq 0 ]
  [ "$(jq -r '.violations | length' "$WORK/findings.json")" -eq 0 ]
  [ "$(jq -r '.majors[]' "$WORK/findings.json")" = "v1" ]
}
