#!/usr/bin/env bats
#
# Structural tests for the JavaScript/TypeScript toolchain templates (#729,
# slice 1 of #683). These files are copied verbatim into a bootstrapped repo
# (they carry no {{PLACEHOLDER}}s), so the guarantee here is that the *source*
# set is the blessed one: flat ESLint config (not the legacy .eslintrc), a
# Prettier config at the repo-wide width 120, vitest+v8 coverage, strict TS,
# and Node 24 pinned. One default per decision — see the maintenance SKILL.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  JS="$REPO_ROOT/development/skills/bootstrap/templates/languages/javascript"
}

@test "js-toolchain: the blessed files are present" {
  [ -f "$JS/eslint.config.js" ]
  [ -f "$JS/.prettierrc.json" ]
  [ -f "$JS/vitest.config.ts" ]
  [ -f "$JS/tsconfig.json" ]
  [ -f "$JS/.nvmrc" ]
}

@test "js-toolchain: flat ESLint config only — the legacy .eslintrc is gone" {
  [ ! -e "$JS/.eslintrc.json" ]
  [ ! -e "$JS/.eslintrc.js" ]
  [ ! -e "$JS/.eslintrc.cjs" ]
  # flat config exports a default and uses the typescript-eslint helper
  grep -q "export default" "$JS/eslint.config.js"
  grep -q "typescript-eslint" "$JS/eslint.config.js"
}

@test "js-toolchain: Prettier width is the repo-wide 120" {
  [ "$(jq -r .printWidth "$JS/.prettierrc.json")" = "120" ]
}

@test "js-toolchain: coverage is vitest + v8 provider" {
  grep -q 'provider: "v8"' "$JS/vitest.config.ts"
}

@test "js-toolchain: TypeScript config is strict" {
  [ "$(jq -r .compilerOptions.strict "$JS/tsconfig.json")" = "true" ]
}

@test "js-toolchain: Node is pinned to the 24 LTS line" {
  [ "$(tr -d '[:space:]' < "$JS/.nvmrc")" = "24" ]
}
