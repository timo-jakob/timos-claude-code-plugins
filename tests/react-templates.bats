#!/usr/bin/env bats
#
# Structural tests for the React overlay templates (#957, epic #686). These files
# are rendered into a React app the way bootstrap SKILL.md §3k.5 instructs. The
# React configs SUPERSEDE the layer beneath them — the base javascript configs, or
# §3k's contract-consumer variants — so each must keep every essential of that
# layer AND add the React wiring. The ESLint pairs are checked line by line
# against the lower layer's own template, so a change to the base or consumer
# config that forgets its React variant reds this suite; the Vitest pairs, whose
# mergeConfig wrapper re-indents every line, are checked by token.
#
# Really building, linting or running the rendered tree is out of scope: nothing
# under bats installs npm packages. That is the render-and-build smoke check's
# job (#1063); this suite pins the file set, its key content and its line width.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  JS="$TEMPLATES/languages/javascript"
  RX="$JS/react"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$OUT"
}

# The seventeen template sources, repo-relative to the react/ overlay: #957's six,
# the four React Query binding files (#958, SKILL.md §3k.6) and the seven WebUI
# gate files (#1946). Sorted as `LC_ALL=C sort` orders them.
REACT_FILES=(
  .github/workflows/webui-quality-noop.yml.tmpl
  .github/workflows/webui-quality.yml.tmpl
  contract-consumer/eslint.config.js
  contract-consumer/vitest.config.ts
  eslint.config.js
  gitignore
  lighthouserc.json
  src/Greeting.test.tsx
  src/api/hooks.test.tsx
  src/api/hooks.ts
  src/api/index.ts
  src/test/a11y-canary.test.tsx
  src/test/query-wrapper.tsx
  src/test/setup.ts
  tests/e2e/playwright.config.ts
  tests/e2e/smoke.spec.ts
  vitest.config.ts
)

# The WebUI gate files §3k.5 renders in BOTH variants (#1946), as its render
# blocks list them. `gitignore` is merged, never rendered, so it is not here.
WEBUI_FILES=(
  src/test/a11y-canary.test.tsx
  tests/e2e/playwright.config.ts
  tests/e2e/smoke.spec.ts
  lighthouserc.json
  .github/workflows/webui-quality.yml.tmpl
  .github/workflows/webui-quality-noop.yml.tmpl
)

# The binding set, as §3k.6 renders it.
BINDING_FILES=(
  src/api/hooks.ts
  src/api/index.ts
  src/api/hooks.test.tsx
  src/test/query-wrapper.tsx
)

# Render one variant exactly as §3k.5 lists it: "consumer" or "plain".
render_variant() {
  local prefix=languages/javascript/react f webui=()
  local cfg="$prefix"
  [ "$1" = consumer ] && cfg="$prefix/contract-consumer"
  for f in "${WEBUI_FILES[@]}"; do webui+=("$prefix/$f"); done
  zsh "$RENDER" --templates "$TEMPLATES" --out "$OUT/$1" \
    --project-name "Demo" --default-branch "main" \
    "$cfg/eslint.config.js" "$cfg/vitest.config.ts" \
    "$prefix/src/test/setup.ts" "$prefix/src/Greeting.test.tsx" "${webui[@]}"
}

# Every code line of the lower layer $1 must appear verbatim in the React variant
# $2. Blank lines and `//` comment lines are skipped: the header banners differ
# by design, and a comment carries no behaviour.
assert_keeps_every_line() {
  local lower="$1" react="$2" line trimmed n=0
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in '' | '//'*) continue ;; esac
    n=$((n + 1))
    grep -qxF -- "$line" "$react" || { echo "MISSING FROM ${react##*/}: $line"; return 1; }
  done < "$lower"
  # a lower layer that yielded no code lines would make this vacuous
  [ "$n" -gt 5 ] || { echo "only $n code lines read from $lower"; return 1; }
}

# `$2` occurs in file `$1` as a fixed string, naming both on a miss.
has() {
  grep -qF -- "$2" "$1" || { echo "missing in ${1#"$REPO_ROOT"/}: $2"; return 1; }
}

@test "react: the template tree contains exactly the seventeen blessed files" {
  local expected actual
  expected="$(printf '%s\n' "${REACT_FILES[@]}")"
  # .DS_Store is Finder litter, not a template (the kubernetes skeleton false red)
  actual="$(cd "$RX" && find . -type f ! -name .DS_Store | sed 's|^\./||' | LC_ALL=C sort)"
  [ "$actual" = "$expected" ] || { printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual"; false; }
}

@test "react: both variants render cleanly, each file where §3k.5 says, unchanged" {
  local v f src
  for v in plain consumer; do
    run render_variant "$v"
    # render.zsh exits non-zero on any leftover {{PLACEHOLDER}}: this status is
    # the placeholder guard, and the grep below repeats it with render.zsh's regex
    [ "$status" -eq 0 ] || { echo "render $v: $output"; false; }
    run grep -rqE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$OUT/$v"
    [ "$status" -eq 1 ]
    for f in src/test/setup.ts src/Greeting.test.tsx src/test/a11y-canary.test.tsx \
      tests/e2e/playwright.config.ts tests/e2e/smoke.spec.ts lighthouserc.json; do
      cmp -s "$OUT/$v/languages/javascript/react/$f" "$RX/$f" || { echo "$v: $f differs from source"; false; }
    done
    # the two workflows lose .tmpl and carry the default branch; nothing else changes
    for f in webui-quality webui-quality-noop; do
      diff <(sed 's/{{DEFAULT_BRANCH}}/main/g' "$RX/.github/workflows/$f.yml.tmpl") \
        "$OUT/$v/languages/javascript/react/.github/workflows/$f.yml" || { echo "$v: $f.yml"; false; }
    done
    # nothing renders into the deployed-UI acceptance spine (#702)
    run find "$OUT/$v" -path '*tests/acceptance*'
    [ -z "$output" ] || { echo "$v rendered under tests/acceptance: $output"; false; }
    src="$RX"
    [ "$v" = consumer ] && src="$RX/contract-consumer"
    for f in eslint.config.js vitest.config.ts; do
      cmp -s "$OUT/$v/${src#"$TEMPLATES"/}/$f" "$src/$f" || { echo "$v: $f differs from source"; false; }
    done
  done
}

@test "react: the plain eslint variant keeps EVERY line of the base config (supersede invariant)" {
  assert_keeps_every_line "$JS/eslint.config.js" "$RX/eslint.config.js"
}

@test "react: the consumer+React eslint variant keeps EVERY line of the consumer config" {
  assert_keeps_every_line "$JS/contract-consumer/eslint.config.js" "$RX/contract-consumer/eslint.config.js"
  # the ACL boundary stays an ERROR, bound to that rule rather than any "error"
  run grep -A1 '"no-restricted-imports": \[' "$RX/contract-consumer/eslint.config.js"
  [ "$status" -eq 0 ]
  contains "$output" '"error"'
}

@test "react: the line-subset check reds on a lower-layer line the React variant lacks (non-vacuity)" {
  local base="$BATS_TEST_TMPDIR/base.js"
  cp "$JS/eslint.config.js" "$base"
  printf '      "prefer-const": "error",\n' >> "$base"
  run assert_keeps_every_line "$base" "$RX/eslint.config.js"
  [ "$status" -eq 1 ]
  contains "$output" '"prefer-const": "error",'
}

@test "react: both eslint variants register and scope the React layer" {
  local f
  for f in "$RX/eslint.config.js" "$RX/contract-consumer/eslint.config.js"; do
    has "$f" 'import reactHooks from "eslint-plugin-react-hooks";'
    has "$f" 'import reactRefresh from "eslint-plugin-react-refresh";'
    has "$f" 'import globals from "globals";'
    has "$f" 'plugins: { "react-hooks": reactHooks, "react-refresh": reactRefresh },'
    has "$f" '"react-hooks/rules-of-hooks": "error",'
    has "$f" '"react-hooks/exhaustive-deps": "warn",'
    has "$f" '"react-refresh/only-export-components": ["warn", { allowConstantExport: true }],'
    # the React block's own files glob: the line right above its browser globals
    run grep -B1 -F 'languageOptions: { globals: globals.browser },' "$f"
    [ "$status" -eq 0 ]
    contains "$output" 'files: ["**/*.ts", "**/*.tsx"],'
    # the family banner the known-predecessor rule tells a family file apart by
    starts_with "$(head -n1 "$f")" '// Flat ESLint config'
  done
}

@test "react: the plain vitest variant keeps EVERY base essential and adds React" {
  local base="$JS/vitest.config.ts" f="$RX/vitest.config.ts" token
  for token in 'provider: "v8",' 'reporter: ["text", "lcov"],' 'defineConfig'; do
    has "$base" "$token"
    has "$f" "$token"
  done
  has "$f" 'environment: "jsdom",'
  has "$f" 'setupFiles: ["./src/test/setup.ts"],'
  # the plain variant must not start an MSW server the repo does not have
  run grep -qF 'msw-setup' "$f"
  [ "$status" -eq 1 ]
}

@test "react: the consumer+React vitest variant keeps MSW first and every consumer essential" {
  local cc="$JS/contract-consumer/vitest.config.ts" f="$RX/contract-consumer/vitest.config.ts" token
  for token in './src/test/msw-setup.ts' 'exclude: ["src/api/generated/**"],' \
    'provider: "v8",' 'reporter: ["text", "lcov"],' 'defineConfig'; do
    has "$cc" "$token"
    has "$f" "$token"
  done
  # MSW's setup module is listed BEFORE the React one, in the one setupFiles array
  has "$f" 'setupFiles: ["./src/test/msw-setup.ts", "./src/test/setup.ts"],'
  has "$f" 'environment: "jsdom",'
  # the setup file it names is the one §3k actually ships
  [ -f "$JS/contract-consumer/src/test/msw-setup.ts" ]
}

@test "react: both vitest variants mergeConfig over ./vite.config, the app config first" {
  local f
  for f in "$RX/vitest.config.ts" "$RX/contract-consumer/vitest.config.ts"; do
    has "$f" 'import { configDefaults, defineConfig, mergeConfig } from "vitest/config";'
    has "$f" 'import viteConfig from "./vite.config";'
    # viteConfig is the FIRST argument, so the test block overrides it
    run grep -A1 -xF 'export default mergeConfig(' "$f"
    [ "$status" -eq 0 ]
    ends_with "$output" '  viteConfig,'
  done
}

@test "react: the setup module registers the jest-dom matchers and unmounts after each test" {
  local f="$RX/src/test/setup.ts"
  has "$f" 'import "@testing-library/jest-dom/vitest";'
  has "$f" 'import { afterEach, expect } from "vitest";'
  grep -qxF 'afterEach(() => cleanup());' "$f"
}

@test "react: the example test renders a component it defines and queries it by role" {
  local t="$RX/src/Greeting.test.tsx"
  has "$t" 'import { render, screen } from "@testing-library/react";'
  # self-contained: the component is defined in the test file, never Vite's App
  grep -qE '^function Greeting\(' "$t"
  has "$t" 'render(<Greeting name="Ada" />);'
  run grep -qE 'from "\./App"|<App' "$t"
  [ "$status" -eq 1 ]
  has "$t" 'expect(screen.getByRole("heading", { name: "Hello, Ada!" })).toBeInTheDocument();'
}

@test "react: no template source line is longer than the prettier printWidth of 120" {
  [ "$(jq -r .printWidth "$JS/.prettierrc.json")" = "120" ]
  # characters, not bytes: an em dash in a comment is one column, and under
  # LC_ALL=C a byte-counting awk would false-red on it
  local f long
  for f in "${REACT_FILES[@]}"; do
    long="$(python3 -c '
import sys
for n, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    if len(line.rstrip("\n")) > 120:
        print(f"{n}: {len(line.rstrip(chr(10)))}")
' "$RX/$f")"
    [ -z "$long" ] || { echo "$f over 120: $long"; false; }
  done
}

# --- the bootstrap step (SKILL.md §3k.5) ---------------------------------------

# The step's text, whitespace-collapsed, bounded by the next ### heading. The
# terminator is asserted by every caller: a sed range whose end never matches
# prints to EOF, and needles would then pass on prose from anywhere after it.
react_step() {
  sed -n '/^### 3k\.5\. React overlay/,/^### /p' "$SKILL" | tr -s '[:space:]' ' '
}

STEP_END='### 3k.6. React Query binding (a React repo consuming a spec — #958) '

@test "react: SKILL.md carries the React step right after §3k, gated on the #956 marker" {
  local section k r l
  section="$(react_step)"
  [ -n "$section" ]
  ends_with "$section" "$STEP_END"
  k="$(grep -n '^### 3k\. ' "$SKILL" | cut -d: -f1)"
  r="$(grep -n '^### 3k\.5\. ' "$SKILL" | cut -d: -f1)"
  l="$(grep -n '^### 3l\. ' "$SKILL" | cut -d: -f1)"
  matches "$k" '^[0-9]+$'
  matches "$r" '^[0-9]+$'
  matches "$l" '^[0-9]+$'
  [ "$k" -lt "$r" ]
  [ "$r" -lt "$l" ]
  # the trigger points at the one authoritative recipe rather than restating it
  contains "$section" 'react-marker:begin'
  contains "$section" '(#956)'
  [ "$(grep -c '^# react-marker:begin$' "$REPO_ROOT/development/skills/maintenance/SKILL.md")" -eq 1 ]
  contains "$section" 'npm create vite@latest <app> -- --template react-ts'
}

@test "react: SKILL.md's React step states every trigger and prerequisite outcome" {
  local section
  section="$(react_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" '**exit 1** (no match) → No marker → skip this step entirely (the common case);'
  contains "$section" '**exit 2** (`react-marker: UNEVALUATED`, `jq` not on PATH) → **not** a no-match'
  contains "$section" 'In State D a marker match is an **adoption gap** when any of these holds: `src/test/setup.ts` is missing, or the on-disk `eslint.config.js` or `vitest.config.ts` is not the React variant the selection table below picks'
  contains "$section" 'The step works on the **repository root** only.'
  contains "$section" 'record a Step 5 item naming the `npm create vite` prerequisite'
  contains "$section" 'the root has **no Vite config** — none of `vite.config.ts`, `vite.config.mts`, `vite.config.js` or `vite.config.mjs`'
  contains "$section" 'That includes a monorepo whose React app lives in a sub-package'
  contains "$section" 'the Vite config **exports a function**'
  contains "$section" '**Does the overlay apply?** It applies exactly when the marker recipe exits 0 **and** neither skip above holds. Decide it once, in Step 2, **before §3d renders anything**'
  contains "$section" 'and §3k to decide whether it defers its whole config pair to this step. When it does not apply, nothing is deferred and those files are ordinary on-disk files to every step.'
  contains "$section" '*consumer+React if §3k'"'"'s machinery will be present, else plain React*'
  contains "$section" 'a §4c-class change the plan approval covers'
}

@test "react: SKILL.md's React step pins the variant table and both render blocks" {
  local section
  section="$(react_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" 'which `orval.config.ts` and `src/test/msw-setup.ts` **both** on disk show'
  contains "$section" '| present (`orval.config.ts` and `src/test/msw-setup.ts` exist) | `react/contract-consumer/eslint.config.js` → `eslint.config.js`, `react/contract-consumer/vitest.config.ts` → `vitest.config.ts` |'
  contains "$section" '| absent (§3k skipped, stopped, aborted, or not a consumer) | `react/eslint.config.js` → `eslint.config.js`, `react/vitest.config.ts` → `vitest.config.ts` |'
  contains "$section" '# §3k machinery present → the consumer+React pair "<skill-base-dir>/scripts/render.zsh" \ --templates "<skill-base-dir>/templates" --out "<staging-dir>" \ --project-name "<name>" --default-branch "<branch>" \ languages/javascript/react/contract-consumer/eslint.config.js \ languages/javascript/react/contract-consumer/vitest.config.ts \ languages/javascript/react/src/test/setup.ts \ languages/javascript/react/src/Greeting.test.tsx'
  contains "$section" '# §3k machinery absent → the plain React pair "<skill-base-dir>/scripts/render.zsh" \ --templates "<skill-base-dir>/templates" --out "<staging-dir>" \ --project-name "<name>" --default-branch "<branch>" \ languages/javascript/react/eslint.config.js \ languages/javascript/react/vitest.config.ts \ languages/javascript/react/src/test/setup.ts \ languages/javascript/react/src/Greeting.test.tsx'
}

@test "react: SKILL.md's React step installs first and renders nothing on a failed install" {
  local section
  section="$(react_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" '**Install first, render second.**'
  contains "$section" 'first **snapshot `package.json` and the lockfile**'
  contains "$section" \
    'npm i -D vitest jsdom @testing-library/react @testing-library/dom @testing-library/jest-dom'
  contains "$section" 'npm i -D eslint-plugin-react-hooks eslint-plugin-react-refresh globals'
  contains "$section" '**only if absent**'
  contains "$section" '**If either `npm i -D` exits non-zero**, render nothing from this step: restore `package.json` and the lockfile **from that snapshot** (never from `HEAD`, which would also drop §3k'"'"'s edits), leave the `eslint.config.js` and `vitest.config.ts` already on disk untouched, and record a Step 5 checklist item quoting the failed command.'
  contains "$section" 'If §3k deferred its pair to this step, abort §3k'"'"'s scaffold as the next paragraph says.'
  contains "$section" 'sees the adoption gaps — §3k'"'"'s and this step'"'"'s — and adds the whole overlay.'
}

@test "react: SKILL.md's React step aborts §3k's scaffold when a deferred §3k does not get its pair" {
  local section
  section="$(react_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" 'Resolve both files'"'"' rule-3 prompts (below) **before** rendering either.'
  contains "$section" 'If §3k deferred and this step will not end with the consumer+React pair on disk for **both** files — an install failed, or either prompt resolved to skip — abort §3k'"'"'s scaffold exactly as §3k'"'"'s own overwrite-skip abort does: discard the ACL/MSW files and workflows, commit the seeded `orval.config.ts` and its transformer, and name the abort in the Step 5 item.'
  contains "$section" 'so if the install succeeded, render the **plain React** pair under the same rules instead.'
  contains "$section" 'Because §3k wrote neither config, no committed config names the discarded `src/test/msw-setup.ts`.'
  contains "$section" 'The prompt answers given against the consumer+React diff do **not** carry over to the plain pair: a file whose prompt resolved to skip **stays skipped**, with its skip consequences below (for `vitest.config.ts`, `src/test/setup.ts`, the example test and the WebUI gate set withheld); a file whose prompt resolved to overwrite gets a **fresh** rule-3 prompt showing the plain React diff, since that consent was for different content; a known predecessor of the plain variant is overwritten without a prompt.'
}

@test "react: SKILL.md's React step states the per-variant known-predecessor rule and its skips" {
  local section
  section="$(react_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" '**only when it is a known predecessor of the variant being rendered**'
  contains "$section" 'for **either** variant: the §3d base template **byte for byte**, or (for `eslint.config.js`) an **unmodified create-vite `eslint.config.js`** as fingerprinted below;'
  contains "$section" 'for the **consumer+React** variant only, additionally: the §3k consumer template or the plain React template, byte for byte.'
  contains "$section" 'The plain React variant never overwrites the consumer template'
  contains "$section" "**idempotency rule 3's diff prompt**"
  contains "$section" 'keep the user'"'"'s file and record a Step 5 item naming the React layers it lacks'
  contains "$section" '**and render neither `src/test/setup.ts` nor the example test**'
  contains "$section" 'leave the oxlint files in place'
}

@test "react: SKILL.md states the create-vite fingerprint element by element" {
  local section
  section="$(react_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" 'the stock file create-vite 8 and earlier generate for `react-ts`, recognised by content and compared ignoring whitespace and quote style.'
  contains "$section" '**no** family header comment'
  contains "$section" 'it imports `eslint-plugin-react-refresh`'
  contains "$section" 'these elements and nothing else'
  contains "$section" '- imports of `@eslint/js`, `globals`, `eslint-plugin-react-hooks`, `eslint-plugin-react-refresh`, `typescript-eslint`, and `defineConfig` + `globalIgnores` from `eslint/config`;'
  contains "$section" '- `export default defineConfig([...])` holding `globalIgnores(['"'"'dist'"'"'])` and one block with `files: ['"'"'**/*.{ts,tsx}'"'"']`, whose `extends` lists `js.configs.recommended`, `tseslint.configs.recommended`, `reactHooks.configs.flat.recommended` and `reactRefresh.configs.vite`, and whose `languageOptions` are `ecmaVersion: 2020` and `globals: globals.browser`.'
}

# §3d's JavaScript note and §3k's rules, each collapsed and bounded by its own
# end address, so a needle cannot pass on §3k.5's text. The end is asserted by
# every caller, for the same reason as react_step's.
section_between() {
  sed -n "/$1/,/$2/p" "$SKILL" | tr -s '[:space:]' ' '
}

@test "react: §3d and §3k defer the React predecessors to §3k.5 only when the overlay applies" {
  local d k
  d="$(section_between '^- \*\*JavaScript contract-consumer note' '^### 3e\. ')"
  ends_with "$d" '### 3e. Claude Approver artifacts (when `--claude-approver true`) '
  contains "$d" '**When the React overlay applies** (§3k.5'"'"'s *Does the overlay apply?* check), §3d leaves an on-disk unmodified create-vite `eslint.config.js` (the fingerprint §3k.5 states) or plain React template untouched, without a prompt'
  contains "$d" 'When the overlay does not apply they are ordinary on-disk files and take rule 3 as usual.'
  k="$(section_between '^### 3k\. ' '^### 3k\.5\. ')"
  ends_with "$k" '### 3k.5. React overlay (a JS/TS repo carrying the React marker — #957) '
  contains "$k" '**When the React overlay applies** (§3k.5'"'"'s *Does the overlay apply?* check), §3k **defers the pair**: it writes **neither** `eslint.config.js` nor `vitest.config.ts` — whatever each file on disk is — and completes everything else, and §3k.5 renders the consumer+React pair over both itself. When a deferred §3k does not end with that pair on disk (§3k.5'"'"'s install fails, or its rule-3 prompt on either file resolves to skip), §3k.5 aborts this scaffold as the skip below does (see §3k.5). No prompt here, and no abort of its own.'
  contains "$k" 'when the React overlay applies, defer the pair to §3k.5 as above'
  contains "$k" 'a seeded `orval.config.ts` with the ACL/MSW scaffold absent is an adoption gap too.'
}

# --- the React Query binding (#958, SKILL.md §3k.6) -----------------------------

@test "binding: all four binding templates exist at their react/ relpaths and render unchanged" {
  local f args=()
  for f in "${BINDING_FILES[@]}"; do
    [ -f "$RX/$f" ] || { echo "missing: react/$f"; false; }
    args+=("languages/javascript/react/$f")
  done
  run zsh "$RENDER" --templates "$TEMPLATES" --out "$OUT/binding" \
    --project-name "Demo" --default-branch "main" "${args[@]}"
  [ "$status" -eq 0 ] || { echo "render: $output"; false; }
  for f in "${BINDING_FILES[@]}"; do
    cmp -s "$OUT/binding/languages/javascript/react/$f" "$RX/$f" || { echo "$f differs from source"; false; }
  done
}

@test "binding: the React barrel composes over #727's — keeps ./client, adds ./hooks, no generated import" {
  local f="$RX/src/api/index.ts" line trimmed n=0
  grep -qxF 'export * from "./client";' "$f"
  grep -qxF 'export * from "./hooks";' "$f"
  # every code line of the consumer barrel survives in the React one
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in '' | '//'*) continue ;; esac
    n=$((n + 1))
    grep -qxF -- "$line" "$f" || { echo "MISSING: $line"; false; }
  done < "$JS/contract-consumer/src/api/index.ts"
  [ "$n" -ge 1 ]
  run grep -qE 'from "[^"]*generated' "$f"
  [ "$status" -eq 1 ]
}

@test "binding: hooks.ts re-exports the generated hooks and declares no wrapping hook" {
  local f="$RX/src/api/hooks.ts"
  # exactly the hook the example test imports, from client.ts's generated module
  grep -qxF 'export { useGetOrders } from "./generated/orders/orders";' "$f"
  # every generated module client.ts reads, so a target rename reaches both
  local p n=0
  while IFS= read -r p; do
    n=$((n + 1))
    grep -qF -- "$p" "$f" || { echo "hooks.ts lacks the client.ts import $p"; false; }
  done < <(grep -oE 'from "\./generated/[^"]+"' "$JS/contract-consumer/src/api/client.ts")
  # an import-style change in client.ts must not turn the loop vacuous
  [ "$n" -ge 2 ]
  # the one domain-mapped seam §3k.6 documents, a `select` mapper rather than a hook
  grep -qE '^export function selectOrderSummaries\(' "$f"
  # a wrapper, exported inline or by name, would swallow the @deprecated warning
  run grep -qE '^(export )?(default )?(async )?(function|const|let|var) use' "$f"
  [ "$status" -eq 1 ]
}

@test "binding: the no-wrapper check reds on a wrapping hook (non-vacuity)" {
  local f="$BATS_TEST_TMPDIR/hooks.ts"
  cp "$RX/src/api/hooks.ts" "$f"
  printf 'function useOrders() {\n  return useGetOrders();\n}\nexport { useOrders };\n' >> "$f"
  run grep -qE '^(export )?(default )?(async )?(function|const|let|var) use' "$f"
  [ "$status" -eq 0 ]
  cp "$RX/src/api/hooks.ts" "$f"
  printf 'export default function useOrders() {\n  return useGetOrders();\n}\n' >> "$f"
  run grep -qE '^(export )?(default )?(async )?(function|const|let|var) use' "$f"
  [ "$status" -eq 0 ]
}

@test "binding: the test QueryClient disables retries behind a QueryClientProvider" {
  local f="$RX/src/test/query-wrapper.tsx"
  has "$f" 'import { QueryClient, QueryClientProvider } from "@tanstack/react-query";'
  has "$f" '<QueryClientProvider client={client}>'
  grep -qE '^export function QueryWrapper\(' "$f"
  # one client per render, so no cached data leaks between tests
  has "$f" 'const [client] = useState(createTestQueryClient);'
  grep -qxF '      queries: { retry: false, refetchOnWindowFocus: false },' "$f"
}

@test "binding: the example test drives a hook through the ACL barrel, never the generated client" {
  local t="$RX/src/api/hooks.test.tsx"
  grep -qE '^import \{[^}]*\buseGetOrders\b[^}]*\} from "\./index";$' "$t"
  has "$t" 'import { QueryWrapper } from "../test/query-wrapper";'
  has "$t" '{ wrapper: QueryWrapper }'
  has "$t" '{ query: { select: selectOrderSummaries } }'
  has "$t" 'expect(await screen.findByRole("status")).toHaveTextContent(/^\d+ orders$/);'
  run grep -qE 'from "[^"]*generated' "$t"
  [ "$status" -eq 1 ]
  # the harness it relies on is #727's MSW setup, which fails unmocked requests,
  # started by the consumer+React vitest config
  has "$JS/contract-consumer/src/test/msw-setup.ts" 'onUnhandledRequest: "error"'
  has "$RX/contract-consumer/vitest.config.ts" './src/test/msw-setup.ts'
}

# §3k.6's text, whitespace-collapsed and bounded by the next ### heading, whose
# terminator every caller asserts (see react_step).
binding_step() {
  sed -n '/^### 3k\.6\. React Query binding/,/^### /p' "$SKILL" | tr -s '[:space:]' ' '
}

BINDING_END='### 3l. Infrastructure-as-code repos (no application language) — #1154 '

@test "binding: SKILL.md carries the §3k.6 step after §3k and §3k.5, rendering all four relpaths" {
  local section k r b l f
  section="$(binding_step)"
  ends_with "$section" "$BINDING_END"
  k="$(grep -n '^### 3k\. ' "$SKILL" | cut -d: -f1)"
  r="$(grep -n '^### 3k\.5\. ' "$SKILL" | cut -d: -f1)"
  b="$(grep -n '^### 3k\.6\. ' "$SKILL" | cut -d: -f1)"
  l="$(grep -n '^### 3l\. ' "$SKILL" | cut -d: -f1)"
  matches "$k" '^[0-9]+$'
  matches "$r" '^[0-9]+$'
  matches "$b" '^[0-9]+$'
  matches "$l" '^[0-9]+$'
  [ "$k" -lt "$r" ]
  [ "$r" -lt "$b" ]
  [ "$b" -lt "$l" ]
  contains "$section" '"<skill-base-dir>/scripts/render.zsh"'
  for f in "${BINDING_FILES[@]}"; do
    contains "$section" "languages/javascript/react/$f"
  done
}

@test "binding: SKILL.md's §3k.6 trigger is the React marker AND a §3k seeder exit 0, passing --client react-query" {
  local section
  section="$(binding_step)"
  ends_with "$section" "$BINDING_END"
  contains "$section" '**Trigger — a conjunction.** Run this step only when **both** hold:'
  contains "$section" 'the **React marker** (#956) matches and the overlay applies — §3k.5'"'"'s *Does the overlay apply?* check, decided once in Step 2'
  contains "$section" 'the **§3k seeder exited 0** — the repo is a contract consumer'
  contains "$section" 'seed-orval-targets.zsh" --plan --client react-query "<repo-path>"'
  contains "$section" 'seed-orval-targets.zsh" --client react-query "<repo-path>"'
  contains "$section" '**Only this step passes it**: Angular and plain-TS consumers keep the seeder'"'"'s default `client: "fetch"`.'
  # its two skips: silent when either half is simply absent, reported when §3k fell short
  contains "$section" 'skips the step entirely: there are no generated hooks to bind, and it is **not an error** — no Step 5 item.'
  contains "$section" 'Skip it too, **with** a Step 5 item naming what is missing, when §3k'"'"'s machinery is absent after all'
  # §3k's own seeder runs point here, so the flag is not stated only downstream
  local k
  k="$(section_between '^### 3k\. ' '^### 3k\.5\. ')"
  ends_with "$k" '### 3k.5. React overlay (a JS/TS repo carrying the React marker — #957) '
  contains "$k" 'add `--client react-query` to this run **and** to the Step 3 run below'
}

@test "binding: SKILL.md installs react-query in §3k's activation and names §3k.6's State-D adoption gap" {
  local section k
  section="$(binding_step)"
  ends_with "$section" "$BINDING_END"
  k="$(section_between '^### 3k\. ' '^### 3k\.5\. ')"
  ends_with "$k" '### 3k.5. React overlay (a JS/TS repo carrying the React marker — #957) '
  # before `npm run generate`, so a failed install takes §3k's own abort
  contains "$k" 'npm i @tanstack/react-query # React overlay applies only — §3k.6'"'"'s binding'
  contains "$k" '**If an `npm i`, `npm ci` or `npm run generate` fails**'
  contains "$k" 'Record a **prominent Step 5 follow-up** quoting the command that failed; when it is the spec package that cannot be resolved'
  contains "$k" '§3k.6 applies the same rewrite to its binding files'
  contains "$section" 'In State D the binding is an **adoption gap** when the trigger holds, every `orval.config.ts` target is `client: "react-query"`, and `src/api/hooks.ts` is missing'
  contains "$section" 'snapshot `package.json`, the lockfile and `src/api/generated/` as §3k.5 snapshots its install, install `@tanstack/react-query` when `package.json` lacks it, then `npm ci && npm run generate` and commit its output with the binding; if either fails, restore all three from that snapshot (never from `HEAD`), render nothing, and record a Step 5 item quoting the failed command.'
}

@test "binding: SKILL.md's §3k.6 documents the prerequisites, the provider edit and the idempotency caveat" {
  local section
  section="$(binding_step)"
  ends_with "$section" "$BINDING_END"
  contains "$section" 'npm i @tanstack/react-query # runtime: the binding itself'
  contains "$section" 'npm i -D @testing-library/react # the component/hook test harness'
  contains "$section" '**The app-level provider — a §4c-class confirmed edit in `src/main.tsx`.**'
  contains "$section" '<QueryClientProvider client={queryClient}><App /></QueryClientProvider>'
  contains "$section" '**Idempotent skip** when `src/main.tsx` already mounts a `QueryClientProvider`.'
  contains "$section" '**Confirm before editing**: show the diff and ask; the plan approval alone does not cover it.'
  contains "$section" 'restore the pre-edit snapshot and record a Step 5 TODO'
  contains "$section" '**Idempotency caveat — the flag only shapes a fresh seed.**'
  contains "$section" 'if any target is not `"react-query"`, render **nothing** from this step'
  contains "$section" '*flip `client:` to `"react-query"` by hand in each target of `orval.config.ts`, re-run `npm run generate`'
  contains "$section" '`null` when an existing config is left untouched'
  contains "$section" 'and the JSON `"client"` is then `null`'
  contains "$section" 'Outside State D'"'"'s adoption gap (above), this step installs neither.'
  contains "$section" 're-export (and import in the test) the hook orval generated for the operation `client.ts`'"'"'s seam calls, and keep `selectOrderSummaries` in step with that seam'
  contains "$section" '**Layer ordering — `src/api/index.ts` joins the compose-don'"'"'t-clobber list.**'
  contains "$section" 'Overwrite the on-disk `src/api/index.ts` without a prompt only when it is §3k'"'"'s barrel template byte for byte'
  contains "$section" 'keep the user'"'"'s barrel, **withhold `src/api/hooks.test.tsx`** (it imports the hook through the barrel)'
}

@test "binding: SKILL.md's §3k.6 states the deprecation pass condition and defers its execution to #1063" {
  local section
  section="$(binding_step)"
  ends_with "$section" "$BINDING_END"
  contains "$section" '`hooks.ts` **re-exports** that hook'
  contains "$section" '`npx eslint src` reports `@typescript-eslint/no-deprecated` on the line in the component that calls `useGetOrders()`'
  contains "$section" 'It is **executed under #1063**.'
}

# --- the WebUI gates (#1946, SKILL.md §3k.5) ------------------------------------

WQ="webui-quality.yml.tmpl"
WQN="webui-quality-noop.yml.tmpl"

@test "webui: both §3k.5 render blocks list every WebUI gate file, and each exists" {
  local section block body f
  section="$(react_step)"
  ends_with "$section" "$STEP_END"
  for block in '# §3k machinery present → the consumer+React pair' '# §3k machinery absent → the plain React pair'; do
    # the block runs from its comment to the closing fence
    body="${section#*"$block"}"
    body="${body%%\`\`\`*}"
    for f in "${WEBUI_FILES[@]}"; do
      [ -f "$RX/$f" ] || { echo "missing: react/$f"; false; }
      contains "$body" "languages/javascript/react/$f"
    done
  done
  contains "$section" 'axe-core @playwright/test @lhci/cli'
}

@test "webui: lighthouserc.json gates only the two byte budgets, at error, with filesystem upload" {
  local rc="$RX/lighthouserc.json"
  jq -e . "$rc" > /dev/null
  [ "$(jq -r '.ci.assert.assertions | keys | join(",")' "$rc")" \
    = "resource-summary:script:size,resource-summary:total:size" ]
  [ "$(jq -c '.ci.assert.assertions["resource-summary:script:size"]' "$rc")" = '["error",{"maxNumericValue":307200}]' ]
  [ "$(jq -c '.ci.assert.assertions["resource-summary:total:size"]' "$rc")" = '["error",{"maxNumericValue":512000}]' ]
  # nothing else can gate: no preset, no budget file, no Web Vitals assertion
  [ "$(jq '.ci.assert | has("preset")' "$rc")" = false ]
  [ "$(jq '.ci.assert | has("budgetsFile")' "$rc")" = false ]
  run grep -qE 'largest-contentful-paint|total-blocking-time|cumulative-layout-shift|budget\.json|"preset"' "$rc"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.ci.upload.target' "$rc")" = filesystem ]
  # measured against vite preview on the root route
  [ "$(jq -r '.ci.collect.url | join(",")' "$rc")" = "http://localhost:4173/" ]
  contains "$(jq -r '.ci.collect.startServerCommand' "$rc")" 'npm run preview -- --port 4173'
}

@test "webui: the canary expects at least one violation, through the family matcher" {
  local c="$RX/src/test/a11y-canary.test.tsx" s="$RX/src/test/setup.ts"
  has "$c" 'import axe from "axe-core";'
  has "$c" 'render(<img src="/logo.svg" />);'
  has "$c" 'expect(results.violations.length).toBeGreaterThanOrEqual(1);'
  has "$c" 'expect(results).not.toHaveNoViolations();'
  # the matcher is family-owned, built on bare axe-core, and registered in setup.ts
  has "$s" 'import type { AxeResults } from "axe-core";'
  grep -qxF 'expect.extend({' "$s"
  grep -qxF '  toHaveNoViolations(results: AxeResults) {' "$s"
  has "$s" 'pass: violations.length === 0,'
  # the type augmentation the canary's matcher call needs under `tsc -b`, in
  # Vitest 5's two-parameter shape
  grep -qxF 'declare module "vitest" {' "$s"
  grep -qxF '  interface Matchers<R, T> {' "$s"
  grep -qxF '    toHaveNoViolations: () => R;' "$s"
  # no wrapper package is imported anywhere in the overlay (comments may name them)
  run grep -rlE 'from "(vitest|jest)-axe' "$RX"
  [ "$status" -eq 1 ]
}

@test "webui: both vitest variants exclude tests/e2e/** on top of Vitest's defaults" {
  local f
  for f in "$RX/vitest.config.ts" "$RX/contract-consumer/vitest.config.ts"; do
    grep -qxF '      exclude: [...configDefaults.exclude, "tests/e2e/**"],' "$f" \
      || { echo "no tests/e2e exclude in ${f#"$REPO_ROOT"/}"; false; }
  done
}

@test "webui: the Playwright harness serves vite preview on 4173 from tests/e2e, never tests/acceptance" {
  local p="$RX/tests/e2e/playwright.config.ts"
  has "$p" 'command: "npm run preview -- --port 4173 --strictPort",'
  has "$p" 'url: "http://localhost:4173",'
  has "$p" 'baseURL: "http://localhost:4173",'
  has "$RX/tests/e2e/smoke.spec.ts" 'await page.goto("/");'
  # the smoke's two assertions ARE the test: React mounted, and nothing threw
  has "$RX/tests/e2e/smoke.spec.ts" 'page.on("pageerror", (error) => pageErrors.push(error));'
  has "$RX/tests/e2e/smoke.spec.ts" 'await expect(page.locator("#root")).not.toBeEmpty();'
  has "$RX/tests/e2e/smoke.spec.ts" 'expect(pageErrors).toEqual([]);'
  # specs are collected next to the config, and no code line points at the
  # acceptance spine (a comment may name it, to say it is off limits)
  has "$p" 'testDir: ".",'
  run grep -rhE 'tests/acceptance' "$RX/tests" "$RX/.github"
  run grep -vE '^[[:space:]]*(//|#)' <<< "$output"
  [ -z "$output" ] || { echo "code line names tests/acceptance: $output"; false; }
  [ ! -e "$RX/tests/acceptance" ]
}

@test "webui: the workflow runs the two named gates, and the noop reports the same names on the inverse paths" {
  local w="$RX/.github/workflows/$WQ" n="$RX/.github/workflows/$WQN" real noop ignored
  real="$(yq -r '.jobs[].name' "$w" | LC_ALL=C sort)"
  noop="$(yq -r '.jobs[].name' "$n" | LC_ALL=C sort)"
  [ "$real" = "$(printf '%s\n' 'e2e (playwright)' 'lighthouse (budgets)')" ] || { echo "real: $real"; false; }
  [ "$noop" = "$real" ] || { printf 'noop:\n%s\nreal:\n%s\n' "$noop" "$real"; false; }
  # the noop triggers on exactly the paths the real workflow ignores, and those
  # are the quality workflows' own paths-ignore
  ignored="$(yq -r '.on.pull_request.paths-ignore[]' "$w")"
  [ -n "$ignored" ]
  [ "$(yq -r '.on.push.paths-ignore[]' "$w")" = "$ignored" ]
  [ "$(yq -r '.on.pull_request.paths[]' "$n")" = "$ignored" ]
  [ "$(yq -r '.on.pull_request.paths-ignore[]' "$TEMPLATES/public/.github/workflows/quality-public.yml.tmpl")" = "$ignored" ]
  # each job does the work its name promises
  has "$w" 'run: npx playwright install --with-deps chromium'
  has "$w" 'run: npx playwright test -c tests/e2e/playwright.config.ts'
  has "$w" 'run: npx lhci autorun'
  [ "$(yq -r '.permissions.contents' "$w")" = read ]
}

@test "webui: the React gitignore fragment ignores the Playwright and Lighthouse output" {
  local g="$RX/gitignore" e
  for e in playwright-report/ test-results/ .lighthouseci/; do
    grep -qxF "$e" "$g" || { echo "gitignore lacks $e"; false; }
  done
  # merged by §3k.5, like any language fragment
  contains "$(react_step)" 'Merge `react/gitignore` into `.gitignore`'
}

@test "webui: a non-React JS bootstrap renders neither webui-quality workflow" {
  local n_all n_step args=() f
  # only the React overlay holds them …
  run find "$TEMPLATES" -name 'webui-quality*' ! -path "$RX/*"
  [ -z "$output" ] || { echo "outside react/: $output"; false; }
  # … only §3k.5 names them in SKILL.md …
  n_all="$(grep -c 'webui-quality' "$SKILL")"
  n_step="$(sed -n '/^### 3k\.5\. React overlay/,/^### 3k\.6\. /p' "$SKILL" | grep -c 'webui-quality')"
  [ "$n_all" -gt 0 ]
  [ "$n_all" -eq "$n_step" ] || { echo "webui-quality named outside §3k.5 ($n_all vs $n_step)"; false; }
  # … and rendering the whole javascript tree minus the React overlay yields none
  # (mfe-contract/ is left out: its {{NPM_SCOPE}} comes from the composition step,
  # which render.zsh has no flag for)
  while IFS= read -r f; do args+=("languages/javascript/$f"); done < <(
    cd "$JS" && find . -type f ! -path './react/*' ! -path './mfe-contract/*' ! -name .DS_Store \
      | sed 's|^\./||' | LC_ALL=C sort)
  [ "${#args[@]}" -gt 10 ]
  run zsh "$RENDER" --templates "$TEMPLATES" --out "$OUT/non-react" \
    --project-name "Demo" --default-branch "main" "${args[@]}"
  [ "$status" -eq 0 ] || { echo "render: $output"; false; }
  run find "$OUT/non-react" -name 'webui-quality*'
  [ -z "$output" ]
}

@test "webui: the over-budget fixture lives in tests/fixtures/react-webui and is in no render list" {
  [ -f "$REPO_ROOT/tests/fixtures/react-webui/over-budget.zsh" ]
  # never a template, and never a render argument (an indented path line)
  run find "$TEMPLATES" -path '*react-webui*'
  [ -z "$output" ]
  run grep -nE '^  [^ ]*react-webui' "$SKILL"
  [ "$status" -eq 1 ] || { echo "render-list line: $output"; false; }
  contains "$(react_step)" 'under `tests/fixtures/react-webui/` and is never in a render list'
}

@test "webui: the over-budget fixture writes an incompressible ballast the app must load" {
  local fx="$REPO_ROOT/tests/fixtures/react-webui/over-budget.zsh" app="$BATS_TEST_TMPDIR/app"
  # usage error without an app
  run zsh "$fx"
  [ "$status" -eq 2 ]
  contains "$output" 'usage: over-budget.zsh <app-dir>'
  mkdir -p "$app/src"
  printf 'console.log("app");\n' > "$app/src/main.tsx"
  run zsh "$fx" "$app"
  [ "$status" -eq 0 ]
  # over the 300 KiB script budget even after gzip: random bytes do not compress
  [ "$(wc -c < "$app/src/ballast.ts")" -gt 614400 ]
  [ "$(gzip -c "$app/src/ballast.ts" | wc -c)" -gt 307200 ]
  [ "$(grep -c 'from "./ballast"' "$app/src/main.tsx")" -eq 1 ]
  # and USES it, so the bundler cannot tree-shake the side-effect-free module
  [ "$(grep -c 'BALLAST.length' "$app/src/main.tsx")" -eq 1 ]
  # idempotent: a second run never imports or uses it twice
  run zsh "$fx" "$app"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'from "./ballast"' "$app/src/main.tsx")" -eq 1 ]
  [ "$(grep -c 'BALLAST.length' "$app/src/main.tsx")" -eq 1 ]
}

@test "webui: SETUP.md §4 and the consistency agent name both required contexts" {
  local setup="$TEMPLATES/common/SETUP.md.tmpl" agent="$REPO_ROOT/development/agents/bootstrap-config-consistency.md"
  has "$setup" '**React (§3k.5):** `e2e (playwright)` and `lighthouse (budgets)` are required **only when the React overlay is rendered**'
  has "$setup" '`webui-quality-noop.yml`'
  has "$setup" 'are **both** on disk (with either absent, `branch-protection.sh` omits both contexts'
  has "$agent" '`.github/workflows/webui-quality.yml` and its'
  has "$agent" 'are in `checks` exactly when **both** `webui-quality*.yml` files will be'
  has "$agent" 'on disk — planned this run **or already there**'
  has "$agent" 'or, for a job that reports under its `name:` (the React'
  has "$agent" 'the same two job names as the real workflow'
}

@test "webui: §3k.5 states the gates' adoption gap, required contexts and budgets, the budgets read from lighthouserc.json" {
  local section script total
  section="$(react_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" 'So is a missing `.github/workflows/webui-quality.yml` or `.github/workflows/webui-quality-noop.yml` — a React app bootstrapped before the WebUI gates (#1946), or one that lost the noop.'
  contains "$section" '**The two jobs are required contexts:** `branch-protection.sh` adds `e2e (playwright)` and `lighthouse (budgets)` whenever **both** `.github/workflows/webui-quality.yml` and its noop are on disk'
  # the prose budgets are the JSON's, so neither can drift alone
  script="$(jq -r '.ci.assert.assertions["resource-summary:script:size"][1].maxNumericValue' "$RX/lighthouserc.json")"
  total="$(jq -r '.ci.assert.assertions["resource-summary:total:size"][1].maxNumericValue' "$RX/lighthouserc.json")"
  matches "$script" '^[0-9]+$'
  matches "$total" '^[0-9]+$'
  contains "$section" "fails the build above $script bytes of script or $total bytes in total; LCP/TBT/CLS are collected, never asserted"
}

@test "webui: §3k.5 withholds the gate set on a vitest.config.ts skip, and the canary alone on a setup.ts skip" {
  local section
  section="$(react_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" '**Withhold the whole WebUI gate set with them**: the a11y canary, `tests/e2e/playwright.config.ts`, `tests/e2e/smoke.spec.ts`, `lighthouserc.json` and both `webui-quality*.yml` workflows.'
  contains "$section" 'with the workflows absent `branch-protection.sh` requires neither WebUI context.'
  contains "$section" '**except the a11y canary whenever `src/test/setup.ts` does not end up as the variant'"'"'s template** (its own prompt resolved to skip)'
  contains "$section" 'drop the withheld paths from the list before running it.'
  # a pre-#1946 app's family files reach that skip branch through a prompt, not an overwrite
  contains "$section" 'Neither is a known predecessor, so each takes the rule-3 prompt below, whose diff is exactly those additions; a skip withholds the gates as the skip paragraph below says.'
}
