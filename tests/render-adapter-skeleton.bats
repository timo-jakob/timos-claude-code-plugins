#!/usr/bin/env bats
#
# Integration test for the multi-major anti-corruption adapter skeleton (#694) —
# render the REAL template the way SKILL.md §3j instructs (once per OLD major via
# --api-major) and prove the per-major substitution produces a coherent Java stub.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$OUT"
  TMPL="languages/java/src/api/OldMajorAdapter.java.tmpl"
}

@test "#694 adapter: renders per OLD major with --api-major (v1 -> V1MajorAdapter, package api.v1)" {
  run zsh "$RENDER" --templates "$TEMPLATES" --out "$OUT" \
    --project-name "Demo Project" --api-major v1 "$TMPL"
  [ "$status" -eq 0 ]
  local f="$OUT/languages/java/src/api/OldMajorAdapter.java"
  [ -f "$f" ]
  grep -q '^package api.v1;' "$f"
  grep -q 'public class V1MajorAdapter' "$f"
  grep -q 'V1Api' "$f"                 # implements the generated interface
  grep -q 'contracts/v1/openapi.yaml' "$f"
  grep -q 'Demo Project' "$f"          # {{PROJECT_NAME}} substituted
}

@test "#694 adapter: a second major renders with its own class/package (v2 -> V2MajorAdapter)" {
  zsh "$RENDER" --templates "$TEMPLATES" --out "$OUT" \
    --project-name "Demo Project" --api-major v2 "$TMPL"
  local f="$OUT/languages/java/src/api/OldMajorAdapter.java"
  grep -q '^package api.v2;' "$f"
  grep -q 'public class V2MajorAdapter' "$f"
}

@test "#694 adapter: no {{PLACEHOLDER}} survives the render (API_MAJOR + API_MAJOR_UPPER resolved)" {
  zsh "$RENDER" --templates "$TEMPLATES" --out "$OUT" \
    --project-name "Demo Project" --api-major v1 "$TMPL"
  run ! grep -REn '\{\{[A-Z_]+\}\}' "$OUT"
}

@test "#694 adapter: documents the deferred per-major generator-drift (java-openapi/spring-api)" {
  zsh "$RENDER" --templates "$TEMPLATES" --out "$OUT" \
    --project-name "Demo Project" --api-major v1 "$TMPL"
  local f="$OUT/languages/java/src/api/OldMajorAdapter.java"
  grep -qi 'openapi-generator' "$f"
  grep -qi 'fails the build' "$f"
}

@test "#694 adapter: render.zsh rejects a malformed --api-major (not vN)" {
  run zsh "$RENDER" --templates "$TEMPLATES" --out "$OUT" \
    --project-name "Demo Project" --api-major V1 "$TMPL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--api-major must be vN"* ]]
}
