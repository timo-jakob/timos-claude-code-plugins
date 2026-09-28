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

# The six template sources, repo-relative to the react/ overlay.
REACT_FILES=(
  contract-consumer/eslint.config.js
  contract-consumer/vitest.config.ts
  eslint.config.js
  src/Greeting.test.tsx
  src/test/setup.ts
  vitest.config.ts
)

# Render one variant exactly as §3k.5 lists it: "consumer" or "plain".
render_variant() {
  local prefix=languages/javascript/react
  local cfg="$prefix"
  [ "$1" = consumer ] && cfg="$prefix/contract-consumer"
  zsh "$RENDER" --templates "$TEMPLATES" --out "$OUT/$1" \
    --project-name "Demo" --default-branch "main" \
    "$cfg/eslint.config.js" "$cfg/vitest.config.ts" \
    "$prefix/src/test/setup.ts" "$prefix/src/Greeting.test.tsx"
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

@test "react: the template tree contains exactly the six blessed files" {
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
    for f in src/test/setup.ts src/Greeting.test.tsx; do
      cmp -s "$OUT/$v/languages/javascript/react/$f" "$RX/$f" || { echo "$v: $f differs from source"; false; }
    done
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
    has "$f" 'import { defineConfig, mergeConfig } from "vitest/config";'
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
  has "$f" 'import { afterEach } from "vitest";'
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

STEP_END='### 3l. Infrastructure-as-code repos (no application language) — #1154 '

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
  contains "$section" 'The prompt answers given against the consumer+React diff do **not** carry over to the plain pair: a file whose prompt resolved to skip **stays skipped**, with its skip consequences below (for `vitest.config.ts`, `src/test/setup.ts` and the example test withheld); a file whose prompt resolved to overwrite gets a **fresh** rule-3 prompt showing the plain React diff, since that consent was for different content; a known predecessor of the plain variant is overwritten without a prompt.'
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
