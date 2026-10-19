#!/usr/bin/env bats
#
# Structural tests for the canvas overlay templates (#1939, epic #1122), rendered
# into a shell the way bootstrap SKILL.md §3k.8 instructs. The canvas is a sibling
# tree to react-shell/ (#1124) and renders after §3k.7, sharing no path with any
# layer beneath it.
#
# This suite pins the file set, the key content, the line width, the layering,
# §3k.8's wording, and each canvas.test.ts case title. canvas.ts, store.ts,
# validate.ts and widgets.ts are TYPE-CHECKED with `tsc --noEmit --strict` against
# the mfe-contract/v1 index.d.ts — tsc is the declared bats dependency
# tests/mfe-contract.bats pins. Running the Vitest cases against a rendered,
# installed tree is #1063's job: nothing under bats installs npm packages.
#
# ANCHOR FORM: headings and quoted tokens only, never `path:line` (#1189).

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  JS="$REPO_ROOT/development/skills/bootstrap/templates/languages/javascript"
  CV="$JS/react-canvas"
  SH="$JS/react-shell"
  DTS="$JS/mfe-contract/index.d.ts"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  MAINT="$REPO_ROOT/MAINTAINING.md"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$OUT"
}

# The eleven canvas templates, each at its deploy relpath, `LC_ALL=C sort` order.
CANVAS_FILES=(
  src/canvas/WidgetCanvas.tsx
  src/canvas/canvas.test.ts
  src/canvas/canvas.ts
  src/canvas/shared/react-dom-client.ts
  src/canvas/shared/react-dom.ts
  src/canvas/shared/react-jsx-runtime.ts
  src/canvas/shared/react.ts
  src/canvas/store.ts
  src/canvas/validate.ts
  src/canvas/widgets.ts
  vite.shared.config.ts
)

# The four modules that need no React, so tsc can check them with no install.
FRAMEWORK_FREE=(canvas store validate widgets)

render_canvas() {
  zsh "$RENDER" --templates "$SH" --out "$1" --project-slug Acme-Corp/demo \
    $(cd "$SH" && find . -type f | sed 's#^\./##')
  zsh "$RENDER" --templates "$CV" --out "$1" --project-slug Acme-Corp/demo "${CANVAS_FILES[@]}"
}

collapse() {
  tr -s '[:space:]' ' ' | sed 's/[[:space:]]*$//'
}

tsconfig_for() {
  local out="$1"
  shift
  jq -n --arg dts "$DTS" --args '{compilerOptions: {strict: true, noEmit: true, target: "ES2022",
      module: "ESNext", moduleResolution: "Bundler", lib: ["ES2022", "DOM"], types: [],
      verbatimModuleSyntax: true, erasableSyntaxOnly: true,
      paths: {"@acme-corp/mfe-contract": [$dts]}}, files: $ARGS.positional}' "$@" > "$out/tsconfig.json"
}

# --- the template tree --------------------------------------------------------

@test "canvas: the template tree contains exactly the eleven blessed files, and react-shell/ keeps its ten" {
  local listed
  listed="$(cd "$CV" && find . -type f | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')"
  [ "$listed" = "${CANVAS_FILES[*]} " ]
  [ "$(cd "$SH" && find . -type f | wc -l | tr -d ' ')" -eq 10 ]
}

@test "canvas: the set renders with --project-slug, each file at its relpath, no placeholder left" {
  run render_canvas "$OUT"
  [ "$status" -eq 0 ]
  local f
  for f in "${CANVAS_FILES[@]}"; do [ -f "$OUT/$f" ]; done
  run grep -rlE '\{\{[A-Z_]+\}\}' "$OUT"
  [ "$status" -eq 1 ]
  contains "$(cat "$OUT/src/canvas/canvas.ts")" 'from "@acme-corp/mfe-contract";'
  # the store's key is the app's slug
  contains "$(cat "$OUT/src/canvas/store.ts")" 'createLocalStorageStore("Acme-Corp/demo")'
}

@test "canvas: no template source line is longer than the prettier printWidth of 120" {
  [ "$(jq -r .printWidth "$JS/.prettierrc.json")" = "120" ]
  local f long
  for f in "${CANVAS_FILES[@]}"; do
    long="$(python3 -c '
import sys
for n, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    if len(line.rstrip("\n")) > 120:
        print(f"{n}: {len(line.rstrip(chr(10)))}")
' "$CV/$f")"
    [ -z "$long" ] || { echo "$f over 120: $long"; false; }
  done
}

@test "canvas: canvas.ts, store.ts, validate.ts and widgets.ts pass tsc --noEmit --strict against the contract" {
  render_canvas "$OUT"
  local m inc=()
  for m in "${FRAMEWORK_FREE[@]}"; do inc+=("src/canvas/$m.ts"); done
  tsconfig_for "$OUT" "${inc[@]}"
  run jq -e '.compilerOptions | has("skipLibCheck") | not' "$OUT/tsconfig.json"
  [ "$status" -eq 0 ]
  run tsc -p "$OUT" --noEmit --strict
  [ "$status" -eq 0 ]
}

@test "canvas: the type check reds on a module that reads a field the contract does not have" {
  render_canvas "$OUT"
  sed -i.bak 's/manifest\.contractMajor !== CONTRACT_MAJOR/manifest.contractVersion !== CONTRACT_MAJOR/' \
    "$OUT/src/canvas/validate.ts"
  tsconfig_for "$OUT" src/canvas/validate.ts
  run tsc -p "$OUT" --noEmit --strict
  [ "$status" -ne 0 ]
  contains "$output" "error TS2339: Property 'contractVersion' does not exist on type 'WidgetManifest'."
}

# --- key content --------------------------------------------------------------

@test "canvas: canvas.ts exports the layout model and the pure, non-mutating operations" {
  local f
  f="$(collapse < "$CV/src/canvas/canvas.ts")"
  contains "$f" 'export interface CanvasLayout { version: 1; instances: WidgetInstance[]; }'
  contains "$f" 'export interface WidgetInstance { id: string;'
  contains "$f" 'config: unknown; position: GridPosition; size: GridSize; }'
  local op
  for op in addInstance removeInstance moveInstance resizeInstance reconfigureInstance; do
    contains "$f" "export function $op("
  done
  contains "$f" 'export const CONTRACT_MAJOR = 1;'
}

@test "canvas: the grid has 12, 8 and 4 columns and a narrow span never changes the saved size" {
  local f
  f="$(collapse < "$CV/src/canvas/canvas.ts")"
  contains "$f" 'if (width >= 1024) return 12; if (width >= 640) return 8; return 4;'
  contains "$f" 'return Math.min(size.cols, columns);'
}

@test "canvas: a move snaps and rejects an overlap or a drop off the grid; a resize clamps and rejects an overlap" {
  local f
  f="$(collapse < "$CV/src/canvas/canvas.ts")"
  contains "$f" 'if (position.col < 0 || position.row < 0 || position.col + size.cols > columns) return false;'
  contains "$f" 'const snapped = { col: Math.round(position.col), row: Math.round(position.row) };'
  contains "$f" 'if (instance === undefined || !fits(layout, snapped, instance.size, columns, id)) return layout;'
  contains "$f" 'const maxCols = Math.min(bounds.max.cols, columns - instance.position.col); if (maxCols < bounds.min.cols) return layout;'
  contains "$f" 'cols: clamp(Math.round(size.cols), bounds.min.cols, maxCols),'
  contains "$f" 'if (size.cols > columns) throw new RangeError('
  contains "$f" 'rows: clamp(Math.round(size.rows), bounds.min.rows, bounds.max.rows),'
  contains "$f" 'if (!fits(layout, instance.position, clamped, columns, id)) return layout;'
}

@test "canvas: store.ts keys <app>:canvas:v1, loads anything else as empty, and extends ShellCapabilities" {
  local f
  f="$(collapse < "$CV/src/canvas/store.ts")"
  contains "$f" 'export interface CanvasStore { load(): Promise<CanvasLayout>; save(layout: CanvasLayout): Promise<void>; }'
  contains "$f" 'export type CanvasCapabilities = ShellCapabilities & { canvasStore: CanvasStore };'
  contains "$f" 'const key = `${app}:canvas:v1`;'
  contains "$f" 'candidate.version === 1 && Array.isArray(candidate.instances)'
  contains "$f" 'return isLayout(parsed) ? parsed : emptyLayout(); } catch { return emptyLayout(); }'
}

@test "canvas: validate.ts supports exactly the JSON-Schema subset and fails closed on any other keyword" {
  local f k
  f="$(collapse < "$CV/src/canvas/validate.ts")"
  for k in type properties required enum const minimum maximum minLength maxLength items additionalProperties; do
    contains "$f" "\"$k\","
  done
  contains "$f" 'if (!SUPPORTED.has(keyword)) return { ok: false, reason: "unsupported", path, keyword };'
  contains "$f" 'if (schema.additionalProperties !== undefined && schema.additionalProperties !== false) {'
  contains "$f" 'if (manifest.contractMajor !== CONTRACT_MAJOR) {'
  contains "$f" 'return `This widget'"'"'s config fails "${result.rule}" at ${result.path}.`;'
}

@test "canvas: WidgetCanvas.tsx saves once per commit, reuses the shell loader per slot, and never remounts on resize" {
  local f
  f="$(collapse < "$CV/src/canvas/WidgetCanvas.tsx")"
  contains "$f" 'store.save(next).then( () => setNotice(null), () => setNotice(NOT_SAVED_NOTICE), );'
  contains "$f" 'loader: new RouteLoader(outlet, (_route, signal) => context(signal), load)'
  contains "$f" 'kind: "widget", config: state.config, get size() { return state.size; },'
  contains "$f" 'return reason === null ? remote : reasonModule(reason);'
  contains "$f" 'for (const cb of slot.subscribers) cb(resized);'
  contains "$f" '}, [instance.id, instance.specifier, configKey]);'
  contains "$f" 'await slots.current.get(id)?.loader.show(null); slots.current.delete(id);'
  contains "$f" 'slot.size = resized;'
  contains "$f" 'useEffect(() => () => void slotRef.current?.loader.show(null), []);'
  contains "$f" 'const onGrid = instance.position.col + instance.size.cols <= columns;'
  contains "$f" 'const col = Math.min(instance.position.col, columns - span);'
  contains "$f" ': { gridColumn: `span ${span}`, gridRow: `span ${instance.size.rows}` };'
}

@test "canvas: widgets.ts ships an empty table and the canvas adds no DnD or validator dependency" {
  local f imports
  f="$(collapse < "$CV/src/canvas/widgets.ts")"
  contains "$f" 'export const widgets: readonly CanvasWidget[] = [];'
  imports="$(cd "$CV/src/canvas" && grep -ho 'from "[^"]*"' WidgetCanvas.tsx canvas.ts store.ts validate.ts widgets.ts \
    | LC_ALL=C sort -u | tr '\n' ' ')"
  [ "$imports" = 'from "../shell/context" from "../shell/import-map" from "../shell/loader" from "./canvas" from "./store" from "./validate" from "./widgets" from "@{{NPM_SCOPE}}/mfe-contract" from "react" ' ]
}

@test "canvas: the shell's loader takes a slot-agnostic context" {
  local f
  f="$(collapse < "$SH/src/shell/loader.ts")"
  contains "$f" 'export type RemoteContext = PageContext | WidgetContext;'
  contains "$f" 'buildContext: (signal: AbortSignal) => RemoteContext,'
  contains "$f" 'buildContext: (route: ShellRoute, signal: AbortSignal) => RemoteContext,'
}

@test "canvas: vite.shared.config.ts builds the four shared specifiers into public/shared/" {
  local f e
  f="$(collapse < "$CV/vite.shared.config.ts")"
  contains "$f" 'outDir: "public/shared",'
  contains "$f" 'formats: ["es"],'
  for e in react react-jsx-runtime react-dom react-dom-client; do
    contains "$f" "src/canvas/shared/$e.ts\","
  done
  contains "$f" 'fileName: (_format, name) => `${name}.js`,'
  contains "$(collapse < "$CV/src/canvas/shared/react.ts")" 'useState,'
  contains "$(collapse < "$CV/src/canvas/shared/react-jsx-runtime.ts")" 'export const { Fragment, jsx, jsxs } = runtime;'
  contains "$(collapse < "$CV/src/canvas/shared/react-dom-client.ts")" 'export const { createRoot, hydrateRoot } = client;'
}

# --- layering -----------------------------------------------------------------

# Every lower layer's deploy paths: §3d's base files, §3k's contract-consumer tree,
# §3k.5/§3k.6's react tree, and §3k.7's shell tree.
lower_layer_paths() {
  local f
  for f in .nvmrc .prettierrc.json eslint.config.js tsconfig.json vitest.config.ts; do echo "$f"; done
  (cd "$JS/contract-consumer" && find . -type f | sed 's#^\./##; s#\.tmpl$##')
  (cd "$JS/react" && find . -type f ! -name gitignore | sed 's#^\./##; s#^contract-consumer/##; s#\.tmpl$##')
  (cd "$SH" && find . -type f | sed 's#^\./##')
}

@test "canvas: rendering onto the §3d/§3k/§3k.5/§3k.6/§3k.7 layers leaves every one of their files byte-identical" {
  local app="$BATS_TEST_TMPDIR/app" p before after
  mkdir -p "$app"
  while IFS= read -r p; do
    mkdir -p "$app/$(dirname "$p")"
    printf 'lower layer: %s\n' "$p" > "$app/$p"
  done < <(lower_layer_paths)
  [ "$(find "$app" -type f | wc -l | tr -d ' ')" -gt 30 ]
  before="$(cd "$app" && find . -type f -exec shasum {} + | LC_ALL=C sort)"
  zsh "$RENDER" --templates "$CV" --out "$app" --project-slug Acme-Corp/demo "${CANVAS_FILES[@]}"
  after="$(cd "$app" && find . -type f ! -path './src/canvas/*' ! -path './vite.shared.config.ts' \
    -exec shasum {} + | LC_ALL=C sort)"
  [ "$before" = "$after" ]
  run comm -12 <(printf '%s\n' "${CANVAS_FILES[@]}" | LC_ALL=C sort) <(lower_layer_paths | LC_ALL=C sort -u)
  [ -z "$output" ]
  local f
  for f in index.html src/main.tsx package.json .gitignore vite.config.ts; do
    run printf '%s\n' "${CANVAS_FILES[@]}"
    lacks "$output" "$f"
  done
}

# --- the bootstrap step (SKILL.md §3k.8) --------------------------------------

canvas_step() {
  sed -n '/^### 3k\.8\. Canvas overlay/,/^### /p' "$SKILL" | tr -s '[:space:]' ' '
}

STEP_END='### 3l. Infrastructure-as-code repos (no application language) — #1154 '

@test "canvas: SKILL.md carries §3k.8 right after §3k.7, before §3l" {
  local section s c l
  section="$(canvas_step)"
  ends_with "$section" "$STEP_END"
  s="$(grep -n '^### 3k\.7\. ' "$SKILL" | cut -d: -f1)"
  c="$(grep -n '^### 3k\.8\. ' "$SKILL" | cut -d: -f1)"
  l="$(grep -n '^### 3l\. ' "$SKILL" | cut -d: -f1)"
  matches "$s" '^[0-9]+$'
  matches "$c" '^[0-9]+$'
  matches "$l" '^[0-9]+$'
  [ "$s" -lt "$c" ]
  [ "$c" -lt "$l" ]
}

@test "canvas: §3k.8 is offered only on a shell, opt-in with a default of no, with its marker and State D gap" {
  local section
  section="$(canvas_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" 'Offer this step only when the shell'"'"'s marker, `src/shell/loader.ts`, is already on disk or §3k.7'"'"'s plan line is kept.'
  contains "$section" 'It is **opt-in**'
  contains "$section" 'React canvas overlay: add the widget canvas to this shell? (default: no, #1939)'
  contains "$section" 'Anything but an explicit yes skips the step entirely'
  contains "$section" '**Shape marker — `src/canvas/canvas.ts`.**'
  contains "$section" 'the step is an **adoption gap** only when that marker is present and another canvas file is missing'
  contains "$section" 'A shell with no `src/canvas/canvas.ts` is never offered the canvas in State D.'
}

@test "canvas: §3k.8's render block lists every canvas template and withholds the test without the setup module" {
  local section f
  section="$(canvas_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" '--templates "<skill-base-dir>/templates/languages/javascript/react-canvas"'
  contains "$section" '--project-slug "<owner/repo>"'
  for f in "${CANVAS_FILES[@]}"; do contains "$section" " $f"; done
  contains "$section" 'so no `{{PLACEHOLDER}}` survives'
  contains "$section" 'a non-zero `render.zsh` exit — or no `src/shell/loader.ts` on disk after §3k.7 — renders nothing, records a Step 5 item, and the run carries on without the edits below.'
  contains "$section" '**Withhold `src/canvas/canvas.test.ts`** unless `src/test/setup.ts` is on disk, exactly as §3k.7 withholds `src/shell/loader.test.ts`, and record a Step 5 item naming it.'
  contains "$section" 'The canvas needs no install of its own: the contract package is §3k.7'"'"'s, and React is the app'"'"'s.'
  contains "$section" 'The component lives in `WidgetCanvas.tsx`, never `Canvas.tsx`: beside the `canvas.ts` marker the two names differ only in case'
  # and no two canvas templates may collide on a case-insensitive filesystem
  [ "$(printf '%s\n' "${CANVAS_FILES[@]}" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sort | uniq -d)" = "" ]
  contains "$section" 'Record every file this step writes under the `react_overlay` telemetry step key'
  contains "$section" 'running `src/canvas/canvas.test.ts` against a rendered tree is the render-and-build smoke check'"'"'s job (#1063).'
}

@test "canvas: §3k.8 composes with the layers beneath it and may update only the shell's loader" {
  local section
  section="$(canvas_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" '§3d → §3k → §3k.5 → §3k.6 → §3k.7 → **this step**'
  contains "$section" 'Each slot runs `src/shell/loader.ts`'"'"'s ordered procedure, whose context type is slot-agnostic (`RemoteContext`, a page or a widget context).'
  contains "$section" 'except the three confirmed edits and the `.gitignore` line below, and the `src/shell/loader.ts` update above.'
  contains "$section" 'when the on-disk `src/shell/loader.ts` differs from the `react-shell/` template, re-render it with §3k.7'"'"'s `render.zsh` command and take **idempotency rule 3'"'"'s diff prompt**'
  contains "$section" 'Settle that prompt before any canvas file is written: a declined loader diff writes no canvas file and takes the render-failure branch below.'
  contains "$section" 'An on-disk canvas file that differs from its template takes **idempotency rule 3'"'"'s diff prompt**, never a blind overwrite.'
}

@test "canvas: §3k.8's three confirmed edits build, map and render the shared dependencies" {
  local section e
  section="$(canvas_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" 'Append the `public/shared/` line to `.gitignore` unless that line is already there; the plan approval covers it.'
  contains "$section" 'Each edit below is **confirmed before it is made** (show the diff and ask; the plan approval alone does not cover it), and on a failed edit, a decline or no answer the file'
  contains "$section" 'the file is **restored from its pre-edit snapshot** and a Step 5 TODO names the edit to make by hand'
  contains "$section" 'into the gitignored `public/shared/`, so the dev server and the production build serve the same `/shared/<name>.js` paths and the shared modules'"'"' version is the shell image'"'"'s own — one pin.'
  contains "$section" 'add a `build:shared` script, `vite build -c vite.shared.config.ts`, chained from `predev` and `prebuild`'
  contains "$section" 'or run as `npm run build:shared` ahead of the existing command, joined by `&&`'
  contains "$section" '**`src/main.tsx`** — extend the shell'"'"'s capabilities with the store and render the canvas beside `<App />` inside `<Shell>`:'
  contains "$section" 'Skipped when `build:shared` already exists.'
  contains "$section" 'insert one inline `<script type="importmap">` before the first `<script type="module">`'
  for e in 'react` → `/shared/react.js' 'react/jsx-runtime` → `/shared/react-jsx-runtime.js' \
    'react-dom` → `/shared/react-dom.js' 'react-dom/client` → `/shared/react-dom-client.js'; do
    contains "$section" "$e"
  done
  contains "$section" 'Skipped only when an existing import map already maps all four. When an import map exists but lacks some of them, add the missing entries to that same map instead — still a confirmed edit, and never a second import map.'
  contains "$section" '<Shell capabilities={capabilities}><App /><Canvas capabilities={capabilities} /></Shell>'
  contains "$section" 'const capabilities = withCanvasStore(defaultCapabilities());'
  contains "$section" 'Skipped when `src/main.tsx` already imports `Canvas`.'
  contains "$section" 'It composes with §3k.6'"'"'s `QueryClientProvider` edit in either order and goes inside §3k.7'"'"'s `<Shell>`: when `src/main.tsx` renders no `<Shell>` (that edit declined or failed), this edit is not offered and its Step 5 TODO is recorded.'
}

# --- the Vitest cases ---------------------------------------------------------

@test "canvas: canvas.test.ts holds a case for each persistence, grid, add/remove, validation, isolation and leak criterion" {
  local f title
  f="$CV/src/canvas/canvas.test.ts"
  [ -f "$f" ]
  for title in \
    'a missing, unparseable or non-version-1 entry loads as an empty canvas' \
    'after a reload every instance keeps its specifier, config, position and size' \
    'the canvas saves once per committed change and never during a drag' \
    'a rejected load or save shows its notice, and a rejected save keeps the in-memory layout' \
    'the grid has 12, 8 and 4 columns, and a narrow span changes neither the saved size nor onResize' \
    'a drop snaps to whole cells and a drop onto another instance or off the grid is rejected' \
    'resize clamps to the manifest bounds and the right edge, and rejects an overlap' \
    'a resize end calls onResize once with the new size and never remounts' \
    "adding places the manifest's default size at the first free row-major position with config {}" \
    'removing tears the slot down, then drops the instance from the layout' \
    'validation supports the subset and fails closed on any other keyword' \
    'an invalid config stays in the layout unmounted, its slot naming the path and rule' \
    'an instance targeting another contract major stays unmounted, its slot naming both majors' \
    'reconfigure unmounts, then remounts with the new config' \
    'an import failure, a missing manifest or a rejecting mount shows the fallback in that slot only' \
    'after a slot unmounts it has 0 child nodes and window listener calls balance'; do
    grep -qF -- "it(\"$title\"" "$f" || { echo "missing case: $title"; return 1; }
  done
}

# --- the record ---------------------------------------------------------------

@test "canvas: ARCHITECTURE.md and MAINTAINING.md document the tree, trigger, marker, layering and import map" {
  local arch maint
  arch="$(collapse < "$ARCH")"
  maint="$(collapse < "$MAINT")"
  contains "$arch" '**The canvas overlay (#1939).**'
  contains "$arch" '`development/skills/bootstrap/templates/languages/javascript/react-canvas/`'
  contains "$arch" 'its **shape marker** is `src/canvas/canvas.ts`'
  contains "$arch" '§3d → §3k → §3k.5 → §3k.6 → §3k.7 → §3k.8'
  contains "$arch" 'It owns the **shared-dependency import map**'
  contains "$maint" '**The canvas overlay** (#1939, SKILL.md §3k.8) is a sibling tree'
  contains "$maint" 'Keep `src/canvas/canvas.ts` as the shape marker'
}
