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
load assertions

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
  contains "$output" '"error"'
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

# --- consumer deprecation surface (#707) -------------------------------------

@test "contract-consumer #707: the blessed deprecation files are present" {
  [ -f "$CC/orval-deprecation-transformer.mjs" ]
  [ -f "$CC/fixtures/deprecated-openapi.yaml" ]
}

@test "contract-consumer #707: ESLint enables no-deprecated (warn) with typed linting SCOPED to src" {
  E="$CC/eslint.config.js"
  # The rule requires type information — the config must enable projectService,
  # or no-deprecated silently does nothing.
  grep -q '"@typescript-eslint/no-deprecated": "warn"' "$E"
  grep -q 'projectService: true' "$E"
  # warn, not error
  run ! grep -q '"@typescript-eslint/no-deprecated": "error"' "$E"
  # Typed linting MUST be scoped to src/** — a repo-wide projectService errors on
  # the root config files the base tsconfig (include: src/**) doesn't cover.
  grep -qE 'files: \["src/\*\*/\*\.ts", "src/\*\*/\*\.tsx"\]' "$E"
}

@test "contract-consumer #707: the transformer SOURCE carries its load-bearing literals (node-free backstop)" {
  # Runs everywhere (no node): catches a dropped x-sunset in the notice, a
  # reworded notice, or a removed guard — the regressions the node test would
  # catch only where node runs.
  T="$CC/orval-deprecation-transformer.mjs"
  grep -qF 'Deprecated; scheduled for removal after ${sunset}' "$T"
  grep -qF '"Deprecated."' "$T"
  # the guards that stop it corrupting a real spec must exist
  grep -qF 'op.deprecated !== true' "$T"
  grep -q 'HTTP_METHODS' "$T"
}

@test "contract-consumer #707: seeded orval.config.ts wires the transformer to a file that ships" {
  WORK="$BATS_TEST_TMPDIR/depseed"
  mkdir -p "$WORK"
  printf '{ "name": "x", "dependencies": { "@acme/orders-api-spec": "2.4.0" } }\n' > "$WORK/package.json"
  run zsh "$REPO_ROOT/development/skills/bootstrap/scripts/seed-orval-targets.zsh" "$WORK"
  [ "$status" -eq 0 ]
  grep -q 'transformer: "./orval-deprecation-transformer.mjs"' "$WORK/orval.config.ts"
  grep -q 'useDeprecatedOperations: true' "$WORK/orval.config.ts"
  # The transformer path the config references MUST resolve to a shipped template
  # (guards against a rename on one side only — a dangling transformer reference).
  ref=$(grep -oE 'transformer: "\./[^"]+"' "$WORK/orval.config.ts" | sed -E 's/.*"\.\/([^"]+)"/\1/')
  [ -n "$ref" ]
  [ -f "$CC/$ref" ]
}

@test "contract-consumer #707: the fixture spec has a deprecated op with x-sunset and an ACTIVE op (structural)" {
  F="$CC/fixtures/deprecated-openapi.yaml"
  grep -q 'operationId: getOrders' "$F"
  grep -q 'x-sunset:' "$F"
  grep -q 'operationId: getHealth' "$F"
  # Structure-aware: the /health operation must NOT be deprecated. Prefer yq;
  # fall back to a block-scoped grep (the /health path block up to the next
  # top-level path) so this is not the fragile positional check it replaces.
  if command -v yq >/dev/null 2>&1; then
    [ "$(yq -r '.paths["/health"].get.deprecated' "$F")" = "null" ]
    [ "$(yq -r '.paths["/orders"].get.deprecated' "$F")" = "true" ]
  else
    run ! grep -q 'deprecated: true' <(awk '/^  \/health:/{f=1} f&&/^  \/[a-z]/&&!/\/health:/{f=0} f' "$F")
  fi
}

@test "contract-consumer #707: the transformer maps deprecated+x-sunset and guards every edge (node)" {
  # node is a DECLARED test dependency (tests/Dockerfile + script-tests.yml install
  # it) — a hard failure, not a silent skip, so a node-less runner is loud, and the
  # transformer's behavior is verified in the canonical suite.
  command -v node >/dev/null 2>&1 || { echo "node is required for the #707 transformer test"; false; }
  T="$CC/orval-deprecation-transformer.mjs"
  DRIVER="$BATS_TEST_TMPDIR/drive.mjs"
  cat > "$DRIVER" <<JS
import transform from "$T";
const spec = { paths: {
  // path item with path-item-level non-operation keys (must be untouched)
  "/orders": { parameters: [{ name: "x" }], summary: "Orders",
    get: { deprecated: true, "x-sunset": "2026-12-31", description: "Returns all orders." } },
  "/health": { get: { description: "Liveness probe." } },
  "/legacy": { get: { deprecated: true, description: "No sunset here." } },
  "/reffed": { \$ref: "#/paths/x" },
}};
const out = transform(spec);
console.log(JSON.stringify({
  dep: out.paths["/orders"].get.description,
  active: out.paths["/health"].get.description,
  activeDeprecated: out.paths["/health"].get.deprecated ?? null,
  noSunset: out.paths["/legacy"].get.description,
  pathParams: out.paths["/orders"].parameters,
  pathSummary: out.paths["/orders"].summary,
  reffed: out.paths["/reffed"],
  idempotent: transform(out).paths["/orders"].get.description,
  idempotentLegacy: transform(out).paths["/legacy"].get.description,
}));
JS
  run node "$DRIVER"
  [ "$status" -eq 0 ]
  # deprecated + x-sunset -> sunset date carried into the description
  echo "$output" | jq -e '.dep | test("Deprecated; scheduled for removal after 2026-12-31")' >/dev/null
  echo "$output" | jq -e '.dep | test("Returns all orders")' >/dev/null
  # AC2: active op fully untouched — description AND no injected deprecated/notice
  [ "$(jq -r '.active' <<<"$output")" = "Liveness probe." ]
  echo "$output" | jq -e '.activeDeprecated == null' >/dev/null
  echo "$output" | jq -e '.active | test("Deprecated") | not' >/dev/null
  # deprecated WITHOUT x-sunset -> a bare deprecation notice, no date
  echo "$output" | jq -e '.noSunset | test("^Deprecated\\.")' >/dev/null
  # path-item-level keys (parameters, summary) and a $ref path item are untouched
  echo "$output" | jq -e '.pathParams == [{ "name": "x" }]' >/dev/null
  [ "$(jq -r '.pathSummary' <<<"$output")" = "Orders" ]
  echo "$output" | jq -e '.reffed == { "$ref": "#/paths/x" }' >/dev/null
  # idempotent — re-running double-prefixes NEITHER the sunset nor the bare case
  [ "$(jq -r '.dep' <<<"$output")" = "$(jq -r '.idempotent' <<<"$output")" ]
  [ "$(jq -r '.noSunset' <<<"$output")" = "$(jq -r '.idempotentLegacy' <<<"$output")" ]
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
