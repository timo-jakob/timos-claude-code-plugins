#!/usr/bin/env bats
#
# Structural tests for the contract-consumer templates (#727, slice 2 of #683).
# These files are rendered into a consuming repo the way SKILL.md §3k instructs;
# the guarantee here is that the installed set is coherent: an ACL with a hard
# ESLint boundary, MSW wired into vitest, a drift gate that fails on a stale
# committed client, and a regenerate-and-commit-back workflow. The two config
# files SUPERSEDE the base slice-1 ones, so they must keep the base essentials
# AND add the consumer wiring — asserted here so a base-config change that
# forgets the consumer variant is caught.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  CC="$TEMPLATES/languages/javascript/contract-consumer"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$OUT"
}

render_workflows() {
  zsh "$RENDER" --templates "$TEMPLATES" --out "$OUT" \
    --project-name "Demo" --default-branch "main" \
    languages/javascript/contract-consumer/.github/workflows/contracts-drift.yml.tmpl \
    languages/javascript/contract-consumer/.github/workflows/contracts-regen.yml.tmpl
}

@test "contract-consumer: the blessed file set is present" {
  [ -f "$CC/src/api/client.ts" ]
  [ -f "$CC/src/api/index.ts" ]
  [ -f "$CC/src/api/client.test.ts" ]
  [ -f "$CC/src/test/msw-setup.ts" ]
  [ -f "$CC/eslint.config.js" ]
  [ -f "$CC/vitest.config.ts" ]
  [ -f "$CC/.github/workflows/contracts-drift.yml.tmpl" ]
  [ -f "$CC/.github/workflows/contracts-regen.yml.tmpl" ]
}

@test "contract-consumer: the ACL public surface re-exports the client, not generated code" {
  grep -q 'from "./client"' "$CC/src/api/index.ts"
  # index.ts must never IMPORT/re-export from the generated tree (comments may
  # mention it; an import statement referencing generated/ is the violation).
  run ! grep -qE 'from ["'\''][^"'\'']*generated' "$CC/src/api/index.ts"
}

@test "contract-consumer: app code imports the ACL through src/api, and the ACL is the seam" {
  # The sample test imports from the ACL barrel (./index), never generated/.
  grep -q 'from "./index"' "$CC/src/api/client.test.ts"
  run ! grep -qE 'from ["'\''][^"'\'']*generated' "$CC/src/api/client.test.ts"
}

@test "contract-consumer: ESLint boundary forbids importing the generated client outside src/api" {
  grep -q 'no-restricted-imports' "$CC/eslint.config.js"
  # BOTH patterns: the barrel import AND the nested deep import (the shape the
  # ACL itself uses, ./generated/orders/orders). Dropping the /** variant would
  # let every deep import through the boundary.
  grep -q '"\*\*/api/generated"' "$CC/eslint.config.js"
  grep -q '"\*\*/api/generated/\*\*"' "$CC/eslint.config.js"
  # The rule exempts the two layers that legitimately reach into generated/: the
  # ACL (src/api/**) and the MSW harness (src/test/**). The harness MUST be
  # exempt — it imports the generated mock handlers and the scaffold ships it, so
  # a missing exemption would make the scaffold fail its own lint gate.
  grep -q 'ignores: \["src/api/\*\*", "src/test/\*\*"\]' "$CC/eslint.config.js"
  # The severity is bound to THIS rule and is "error" (fails CI), not "warn".
  # A whole-file grep for "error" would pass on the base no-unused-vars rule, so
  # anchor to the line immediately after the boundary rule opens.
  run grep -A1 '"no-restricted-imports": \[' "$CC/eslint.config.js"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"error"'* ]]
}

@test "contract-consumer: the eslint variant keeps EVERY base slice-1 essential (supersede invariant)" {
  # The consumer config REPLACES the base one, so it must carry all of the base's
  # essentials — asserted so a base-config change that forgets the consumer
  # variant is caught. Each token is a load-bearing part of the base config.
  local base="$TEMPLATES/languages/javascript/eslint.config.js"
  for token in \
    'export default tseslint.config(' \
    'js.configs.recommended' \
    'tseslint.configs.recommended' \
    '"no-unused-vars": "off"' \
    '@typescript-eslint/no-unused-vars' \
    'argsIgnorePattern: "^_"' \
    '@typescript-eslint/no-explicit-any' \
    'dist/'; do
    # each essential exists in the BASE (guards this list against base drift)…
    grep -qF "$token" "$base" || { echo "NOT IN BASE: $token"; false; }
    # …and must be preserved in the consumer variant
    grep -qF "$token" "$CC/eslint.config.js" || { echo "MISSING FROM CONSUMER: $token"; false; }
  done
}

@test "contract-consumer: vitest variant wires MSW and keeps EVERY base essential" {
  grep -q 'setupFiles: \["./src/test/msw-setup.ts"\]' "$CC/vitest.config.ts"
  # generated code is excluded from coverage
  grep -q 'src/api/generated' "$CC/vitest.config.ts"
  local base="$TEMPLATES/languages/javascript/vitest.config.ts"
  for token in 'provider: "v8"' 'reporter: \["text", "lcov"\]' 'defineConfig'; do
    grep -qE "$token" "$base" || { echo "NOT IN BASE: $token"; false; }
    grep -qE "$token" "$CC/vitest.config.ts" || { echo "MISSING FROM CONSUMER: $token"; false; }
  done
}

@test "contract-consumer: msw-setup starts a server from the generated handlers with no backend" {
  grep -q 'setupServer' "$CC/src/test/msw-setup.ts"
  grep -q 'from "msw/node"' "$CC/src/test/msw-setup.ts"
  # unhandled requests must ERROR — an unmocked call is a hidden backend need
  grep -q 'onUnhandledRequest: "error"' "$CC/src/test/msw-setup.ts"
  grep -q 'server.listen' "$CC/src/test/msw-setup.ts"
}

@test "contract-consumer: drift workflow regenerates then fails on a dirty generated tree" {
  render_workflows
  W="$OUT/languages/javascript/contract-consumer/.github/workflows/contracts-drift.yml"
  [ -f "$W" ]
  grep -q 'npm run generate' "$W"
  grep -q 'git diff --exit-code -- src/api/generated/' "$W"
  # least privilege: the drift gate only reads
  grep -q 'contents: read' "$W"
  # path-conditional (never a required context)
  grep -q 'paths:' "$W"
}

@test "contract-consumer: regen workflow commits the regenerated client back to the PR branch" {
  render_workflows
  W="$OUT/languages/javascript/contract-consumer/.github/workflows/contracts-regen.yml"
  [ -f "$W" ]
  grep -q 'npm run generate' "$W"
  grep -q 'contents: write' "$W"
  grep -q 'git push' "$W"
  # only pushes when regeneration actually changed something
  grep -q 'git diff --quiet -- src/api/generated/' "$W"
  # forks (no write access) are skipped
  grep -q 'head.repo.full_name == github.repository' "$W"
  # the push-back lands ONLY if it checks out the PR branch ref with a write
  # token — without these the commit-back targets a detached HEAD and silently
  # fails.
  grep -qF 'ref: ${{ github.event.pull_request.head.ref }}' "$W"
  grep -qF 'token: ${{ secrets.GITHUB_TOKEN }}' "$W"
}

@test "contract-consumer: workflows render with no leftover placeholders and valid DEFAULT_BRANCH" {
  render_workflows
  for w in contracts-drift contracts-regen; do
    W="$OUT/languages/javascript/contract-consumer/.github/workflows/$w.yml"
    # Template placeholders are {{UPPER_CASE}}; GitHub Actions ${{ … }}
    # expressions (lowercase, $-prefixed) are legitimate and must survive.
    run ! grep -qE '\{\{[A-Z_]+\}\}' "$W"
    grep -q 'branches: \["main"\]' "$W"
  done
}
