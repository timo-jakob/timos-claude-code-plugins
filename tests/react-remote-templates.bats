#!/usr/bin/env bats
#
# Structural tests for the remote overlay templates (#1125, epic #1122), rendered
# the way bootstrap SKILL.md §3k.9 instructs. The remote is a sibling tree to
# react-shell/ (#1124) and react-canvas/ (#1939) with one subtree per shape, page
# and widget, and renders after §3k.6, sharing no path with any layer beneath it.
#
# This suite pins each shape's file set, the key content, the line width, the
# layering, §3k.9's wording, and each entry.test.ts case title. router.ts and
# manifest.ts are TYPE-CHECKED with `tsc --noEmit --strict` against the
# mfe-contract/v1 index.d.ts — tsc is the declared bats dependency
# tests/mfe-contract.bats pins. Running the Vitest cases against a rendered,
# installed tree is #1063's job: nothing under bats installs npm packages.
#
# ANCHOR FORM: headings and quoted tokens only, never `path:line` (#1189).

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  JS="$REPO_ROOT/development/skills/bootstrap/templates/languages/javascript"
  RM="$JS/react-remote"
  DTS="$JS/mfe-contract/index.d.ts"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  MAINT="$REPO_ROOT/MAINTAINING.md"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$OUT"
}

# Each shape's four templates, at their deploy relpaths, `LC_ALL=C sort` order.
PAGE_FILES=(
  src/remote/entry.test.ts
  src/remote/entry.tsx
  src/remote/router.ts
  vite.remote.config.ts
)
WIDGET_FILES=(
  src/remote/entry.test.ts
  src/remote/entry.tsx
  src/remote/manifest.ts
  vite.remote.config.ts
)

render_shape() {
  local shape="$1" out="$2"
  shift 2
  zsh "$RENDER" --templates "$RM/$shape" --out "$out" --project-slug Acme-Corp/demo "$@"
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

@test "remote: the template tree holds exactly a page and a widget subtree, four files each" {
  [ "$(cd "$RM" && find . -mindepth 1 -maxdepth 1 | LC_ALL=C sort | tr '\n' ' ')" = './page ./widget ' ]
  local listed
  listed="$(cd "$RM/page" && find . -type f | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')"
  [ "$listed" = "${PAGE_FILES[*]} " ]
  listed="$(cd "$RM/widget" && find . -type f | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')"
  [ "$listed" = "${WIDGET_FILES[*]} " ]
}

@test "remote: both shapes render with --project-slug, each file at its relpath, no placeholder left" {
  run render_shape page "$OUT/page" "${PAGE_FILES[@]}"
  [ "$status" -eq 0 ]
  run render_shape widget "$OUT/widget" "${WIDGET_FILES[@]}"
  [ "$status" -eq 0 ]
  local f
  for f in "${PAGE_FILES[@]}"; do [ -f "$OUT/page/$f" ]; done
  for f in "${WIDGET_FILES[@]}"; do [ -f "$OUT/widget/$f" ]; done
  run grep -rlE '\{\{[A-Z_]+\}\}' "$OUT"
  [ "$status" -eq 1 ]
  contains "$(cat "$OUT/page/src/remote/entry.tsx")" 'from "@acme-corp/mfe-contract";'
  # the widget's manifest id is the app's slug
  contains "$(cat "$OUT/widget/src/remote/manifest.ts")" 'id: "Acme-Corp/demo",'
}

@test "remote: no template source line is longer than the prettier printWidth of 120" {
  [ "$(jq -r .printWidth "$JS/.prettierrc.json")" = "120" ]
  local f long
  for f in $(cd "$RM" && find . -type f | sed 's#^\./##'); do
    long="$(python3 -c '
import sys
for n, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    if len(line.rstrip("\n")) > 120:
        print(f"{n}: {len(line.rstrip(chr(10)))}")
' "$RM/$f")"
    [ -z "$long" ] || { echo "$f over 120: $long"; false; }
  done
}

@test "remote: router.ts and manifest.ts pass tsc --noEmit --strict against the contract" {
  render_shape page "$OUT" src/remote/router.ts
  render_shape widget "$OUT" src/remote/manifest.ts
  tsconfig_for "$OUT" src/remote/router.ts src/remote/manifest.ts
  run jq -e '.compilerOptions | has("skipLibCheck") | not' "$OUT/tsconfig.json"
  [ "$status" -eq 0 ]
  run tsc -p "$OUT" --noEmit --strict
  [ "$status" -eq 0 ]
}

@test "remote: the type check reds on a manifest field the contract does not have" {
  render_shape widget "$OUT" src/remote/manifest.ts
  sed -i.bak 's/contractMajor: 1,/contractVersion: 1,/' "$OUT/src/remote/manifest.ts"
  tsconfig_for "$OUT" src/remote/manifest.ts
  run tsc -p "$OUT" --noEmit --strict
  [ "$status" -ne 0 ]
  contains "$output" "'contractVersion' does not exist in type 'WidgetManifest'"
}

# --- key content: both entries ------------------------------------------------

@test "remote: both entries type mount and unmount from the contract, reject the other shape and stop on abort" {
  local shape f other
  for shape in page widget; do
    f="$(collapse < "$RM/$shape/src/remote/entry.tsx")"
    run grep -cE '^import type \{[^}]*MfeModule[^}]*\} from "@\{\{NPM_SCOPE\}\}/mfe-contract";$' \
      "$RM/$shape/src/remote/entry.tsx"
    [ "$output" = "1" ]
    contains "$f" 'export const mount: MfeModule["mount"] = async (el, ctx) => {'
    contains "$f" "if (ctx.kind !== \"$shape\") throw new Error(\`this remote is a $shape; it cannot mount as a \${ctx.kind}\`);"
    contains "$f" 'if (ctx.signal.aborted) return;'
    contains "$f" 'export const unmount: MfeModule["unmount"] = (el) => {'
    contains "$f" 'const state = mounted.get(el); mounted.delete(el);'
    contains "$f" 'state?.root?.unmount();'
    # the state is registered before anything is created that unmount must undo
    other="$(awk '/mounted\.set\(el, state\)/{print NR; exit}' "$RM/$shape/src/remote/entry.tsx")"
    matches "$other" '^[0-9]+$'
    [ "$other" -lt "$(awk '/createRoot\(el\)/{print NR; exit}' "$RM/$shape/src/remote/entry.tsx")" ]
  done
}

# --- key content: the page ----------------------------------------------------

@test "remote: the page router strips basePath at a segment boundary and prefixes every path it produces" {
  local f
  f="$(collapse < "$RM/page/src/remote/router.ts")"
  contains "$f" 'export function createRemoteRouter(basePath: string, onNavigate: PageContext["onNavigate"]): RemoteRouter {'
  contains "$f" 'if (pathname === base || pathname === `${base}/`) return "/";'
  contains "$f" 'if (pathname.startsWith(`${base}/`)) return pathname.slice(base.length); return null;'
  contains "$f" 'if (path === "/") return base === "" ? "/" : base; return `${base}${path}`;'
  contains "$f" 'subscribe(cb: (local: string) => void): () => void;'
}

@test "remote: the page router pushes state inside basePath and hands any other path to onNavigate" {
  local f
  f="$(collapse < "$RM/page/src/remote/router.ts")"
  contains "$f" 'const local = toLocal(path.replace(/[?#].*$/, "")); if (local === null) { onNavigate(path); return; } window.history.pushState(null, "", path); notify(local);'
  contains "$f" 'window.addEventListener("popstate", onPopState);'
  contains "$f" 'window.removeEventListener("popstate", onPopState); subscribers.clear();'
  # it never writes the location: the only history write is the in-prefix pushState
  run grep -cE 'location\.(assign|replace|href *=)|location *=|replaceState' "$RM/page/src/remote/router.ts"
  [ "$output" = "0" ]
  [ "$(grep -c '\.pushState(' "$RM/page/src/remote/router.ts")" -eq 1 ]
  # an in-app link click hands the router a local path (no origin), query and fragment kept
  contains "$(collapse < "$RM/page/src/remote/entry.tsx")" 'const { pathname, search, hash } = event.currentTarget; router.navigate(`${pathname}${search}${hash}`);'
  # the in-app link is wired to that handler, so a click goes through the router
  contains "$(collapse < "$RM/page/src/remote/entry.tsx")" '<a href={router.toOuter("/")} onClick={follow}>'
  # only a plain primary click is intercepted; a modified or non-primary click is left to the browser
  contains "$(collapse < "$RM/page/src/remote/entry.tsx")" 'const modified = event.metaKey || event.ctrlKey || event.shiftKey || event.altKey; if (event.button !== 0 || modified || event.defaultPrevented) return; event.preventDefault();'
  # unmount disposes the router, which removes the popstate listener
  contains "$(collapse < "$RM/page/src/remote/entry.tsx")" 'state?.root?.unmount(); state?.router.dispose();'
}

# --- key content: the widget --------------------------------------------------

@test "remote: the widget manifest declares contract major 1, an object schema and ordered size bounds" {
  local f
  f="$(collapse < "$RM/widget/src/remote/manifest.ts")"
  contains "$f" 'export const manifest: WidgetManifest = { id: "{{PROJECT_SLUG}}", contractMajor: 1, configSchema: { type: "object",'
  contains "$f" 'min: { cols: 1, rows: 1 }, max: { cols: 4, rows: 3 }, default: { cols: 2, rows: 1 },'
  # min <= default <= max in each axis, read from the template itself
  run python3 -c '
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
size = {k: tuple(map(int, re.search(k + r": \{ cols: (\d+), rows: (\d+) \}", src).groups())) for k in ("min", "default", "max")}
sys.exit(0 if all(size["min"][i] <= size["default"][i] <= size["max"][i] for i in (0, 1)) else 1)
' "$RM/widget/src/remote/manifest.ts"
  [ "$status" -eq 0 ]
}

@test "remote: the widget entry re-exports the manifest and evaluating it has no side effect" {
  local f
  f="$RM/widget/src/remote/entry.tsx"
  contains "$(collapse < "$f")" 'import { manifest } from "./manifest"; export { manifest };'
  # no top-level statement but imports, exports and declarations
  run grep -nvE '^(import|export|const|function|interface|type|//|/\*| |\}|\)|$)' "$f"
  [ "$status" -eq 1 ]
}

@test "remote: the widget narrows its config, re-renders on resize without a remount, and never touches the URL" {
  local f
  f="$(collapse < "$RM/widget/src/remote/entry.tsx")"
  contains "$f" 'function isWidgetConfig(value: unknown): value is WidgetConfig {'
  contains "$f" 'if (!isWidgetConfig(config)) throw new Error(`invalid ${manifest.id} config`);'
  contains "$f" 'state.unsubscribe = ctx.onResize((size) => root.render(<Widget config={config} size={size} />));'
  contains "$f" 'root.render(<Widget config={config} size={ctx.size} />);'
  contains "$f" 'state?.unsubscribe?.(); state?.root?.unmount();'
  run grep -cwE 'history|location' "$RM/widget/src/remote/entry.tsx"
  [ "$output" = "0" ]
}

# --- key content: the build ---------------------------------------------------

@test "remote: both builds emit an unhashed dist/remote.js and hash everything under dist/assets/" {
  local shape f
  for shape in page widget; do
    f="$(collapse < "$RM/$shape/vite.remote.config.ts")"
    contains "$f" 'outDir: "dist",'
    contains "$f" 'lib: { entry: "src/remote/entry.tsx", formats: ["es"], fileName: () => "remote.js", },'
    contains "$f" 'chunkFileNames: "assets/[name]-[hash].js", assetFileNames: "assets/[name]-[hash][extname]",'
  done
  contains "$(collapse < "$RM/widget/vite.remote.config.ts")" \
    'external: ["react", "react/jsx-runtime", "react-dom", "react-dom/client"],'
  run grep -c 'external' "$RM/page/vite.remote.config.ts"
  [ "$output" = "0" ]
}

# --- layering -----------------------------------------------------------------

# Every lower layer's deploy paths: §3d's base files, §3k's contract-consumer tree,
# and §3k.5/§3k.6's react tree.
lower_layer_paths() {
  local f
  for f in .nvmrc .prettierrc.json eslint.config.js tsconfig.json vitest.config.ts; do echo "$f"; done
  (cd "$JS/contract-consumer" && find . -type f | sed 's#^\./##; s#\.tmpl$##')
  (cd "$JS/react" && find . -type f ! -name gitignore | sed 's#^\./##; s#^contract-consumer/##; s#\.tmpl$##')
}

@test "remote: rendering either shape onto the §3d/§3k/§3k.5/§3k.6 layers leaves every one of their files byte-identical" {
  local shape app p before after files
  for shape in page widget; do
    app="$BATS_TEST_TMPDIR/app-$shape"
    mkdir -p "$app"
    while IFS= read -r p; do
      mkdir -p "$app/$(dirname "$p")"
      printf 'lower layer: %s\n' "$p" > "$app/$p"
    done < <(lower_layer_paths)
    [ "$(find "$app" -type f | wc -l | tr -d ' ')" -gt 20 ]
    before="$(cd "$app" && find . -type f -exec shasum {} + | LC_ALL=C sort)"
    files="$(cd "$RM/$shape" && find . -type f | sed 's#^\./##')"
    # shellcheck disable=SC2086
    render_shape "$shape" "$app" $files
    after="$(cd "$app" && find . -type f ! -path './src/remote/*' ! -path './vite.remote.config.ts' \
      -exec shasum {} + | LC_ALL=C sort)"
    [ "$before" = "$after" ]
    run comm -12 <(printf '%s\n' $files | LC_ALL=C sort) <(lower_layer_paths | LC_ALL=C sort -u)
    [ -z "$output" ]
    # the Vite-owned files stay the app's own
    for p in package.json vite.config.ts index.html src/main.tsx; do
      run printf '%s\n' $files
      lacks "$output" "$p"
    done
  done
}

# --- the bootstrap step (SKILL.md §3k.9) --------------------------------------

remote_step() {
  sed -n '/^### 3k\.9\. Remote overlay/,/^### /p' "$SKILL" | tr -s '[:space:]' ' '
}

STEP_END='### 3l. Infrastructure-as-code repos (no application language) — #1154 '

@test "remote: SKILL.md carries §3k.9 after the shell steps, before §3l" {
  local section c r l
  section="$(remote_step)"
  ends_with "$section" "$STEP_END"
  c="$(grep -n '^### 3k\.8\. ' "$SKILL" | cut -d: -f1)"
  r="$(grep -n '^### 3k\.9\. ' "$SKILL" | cut -d: -f1)"
  l="$(grep -n '^### 3l\. ' "$SKILL" | cut -d: -f1)"
  matches "$c" '^[0-9]+$'
  matches "$r" '^[0-9]+$'
  matches "$l" '^[0-9]+$'
  [ "$c" -lt "$r" ]
  [ "$r" -lt "$l" ]
}

@test "remote: §3k.9 runs on an explicit remote reply, which drops the shell and canvas plan lines" {
  local section
  section="$(remote_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" 'Run this step after §3k.6 when §3k.5'"'"'s overlay applies (its *Does the overlay apply?* check) **and** either the user replied `remote: page` or `remote: widget` to §3k.7'"'"'s Step 2 plan line, or — in State D — `src/remote/entry.tsx` is on disk and another file of its shape is missing (the adoption gap below).'
  contains "$section" 'That reply is the selection until the shell-or-remote recommender (#1127) lands'
  contains "$section" '**Choosing a remote drops the §3k.7 and §3k.8 plan lines**'
  contains "$section" 'React remote overlay: <page|widget> (#1125)'
  contains "$section" 'With neither a `remote:` reply nor that adoption gap this step does not run'
  contains "$(sed -n '/^### 3k\.7\. Shell overlay/,/^### /p' "$SKILL" | tr -s '[:space:]' ' ')" \
    'React shell overlay (default shape) — reply `remote: page` or `remote: widget` to scaffold a remote instead (#1125)'
  contains "$(sed -n '/^### 3k\.7\. Shell overlay/,/^### /p' "$SKILL" | tr -s '[:space:]' ' ')" \
    'A `remote: page` or `remote: widget` reply drops it too, with §3k.8'"'"'s line, and adds §3k.9'"'"'s instead; §3k.9 also refuses a repo carrying both shape markers.'
}

@test "remote: §3k.9 names both shape markers, gap-fills only on the remote marker, and refuses both markers" {
  local section
  section="$(remote_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" '**Shape markers — `src/remote/entry.tsx` and `src/remote/manifest.ts`.**'
  contains "$section" '`src/remote/entry.tsx` marks a repo as a remote, and `src/remote/manifest.ts` additionally marks the widget shape'
  contains "$section" 'the step is an **adoption gap** only when the remote marker is present and another file of its shape is missing'
  contains "$section" 'A repo with no `src/remote/entry.tsx` is never offered a remote in State D, and a repo carrying it is never offered the shell.'
  contains "$section" '**Both markers — refuse.** A repo carrying both `src/shell/loader.ts` and `src/remote/entry.tsx` renders neither overlay'
  contains "$section" 'records a Step 5 item naming both files and the conflict'
  contains "$section" 'Step 2 checks this before any of the three plan lines is shown, and refuses a `remote:` reply on a repo carrying `src/shell/loader.ts` the same way.'
}

@test "remote: §3k.9 installs the contract first and renders nothing on a failed install" {
  local section
  section="$(remote_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" '**Install first, render second.** Snapshot `package.json` and the lockfile'
  contains "$section" 'npm i -D @<scope>/mfe-contract'
  contains "$section" 'Skip the install when `package.json` already lists the package.'
  contains "$section" 'restore both files from the snapshot, render nothing, and record a Step 5 item naming `@<scope>/mfe-contract` and the publishing story, #1899.'
  contains "$section" 'means running this step'"'"'s install, render and `build:remote` edit by hand.'
  contains "$section" 'a non-zero `render.zsh` exit takes the failed install'"'"'s branch above — restore both files, render nothing, record a Step 5 item — and the run carries on.'
  contains "$section" 'On either failure the `build:remote` edit below is not offered.'
}

@test "remote: §3k.9's render blocks list each shape's templates and withhold the test without the setup module" {
  local section f
  section="$(remote_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" '--templates "<skill-base-dir>/templates/languages/javascript/react-remote/page"'
  contains "$section" '--templates "<skill-base-dir>/templates/languages/javascript/react-remote/widget"'
  contains "$section" '--project-slug "<owner/repo>"'
  local page widget
  page="$(sed -n '/react-remote\/page"/,/^```/p' "$SKILL" | tr -s '[:space:]' ' ')"
  widget="$(sed -n '/react-remote\/widget"/,/^```/p' "$SKILL" | tr -s '[:space:]' ' ')"
  for f in "${PAGE_FILES[@]}"; do contains "$page" " $f"; done
  for f in "${WIDGET_FILES[@]}"; do contains "$widget" " $f"; done
  lacks "$page" 'manifest.ts'
  lacks "$widget" 'router.ts'
  contains "$section" 'so no `{{PLACEHOLDER}}` survives'
  contains "$section" '**Withhold `src/remote/entry.test.ts`** unless `src/test/setup.ts` is on disk'
  contains "$section" 'Record every file this step writes under the `react_overlay` telemetry step key'
  contains "$(cat "$SKILL")" '| `react_overlay` | 3k.5. React overlay, 3k.7. Shell overlay, 3k.8. Canvas overlay, and 3k.9. Remote overlay |'
}

@test "remote: §3k.9 composes with the layers beneath it, and its one Vite-owned edit adds build:remote" {
  local section
  section="$(remote_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" '§3d → §3k → §3k.5 → §3k.6 → **this step**; §3k.7 and §3k.8 do not run in a remote.'
  contains "$section" 'this step leaves every file §3d, §3k, §3k.5 and §3k.6 rendered byte-identical.'
  contains "$section" 'An on-disk remote file that differs from its template takes **idempotency rule 3'"'"'s diff prompt**, never a blind overwrite.'
  contains "$section" '**The one Vite-owned edit — a §4c-class confirmed edit of `package.json`.** It adds a `build:remote` script, `vite build -c vite.remote.config.ts`'
  contains "$section" 'which builds `src/remote/entry.tsx` to the unhashed `dist/remote.js` the gateway serves and every other chunk and asset under `dist/assets/` with a content hash in its name.'
  contains "$section" 'The widget build keeps `react`, `react/jsx-runtime`, `react-dom` and `react-dom/client` external, for §3k.8'"'"'s import map to resolve; the page build bundles its own React, since the shell mounts one page remote at a time.'
  contains "$section" '**Idempotent skip** when `package.json` already has a `build:remote` script.'
  contains "$section" '**Confirm before editing**: show the diff and ask; the plan approval alone does not cover it.'
  contains "$section" 'On a failed edit, a decline or no answer, restore the pre-edit snapshot and record a Step 5 TODO naming the `build:remote` script to add by hand.'
  contains "$section" 'No other Vite-owned file is written — `vite.config.ts`, `index.html` and `src/main.tsx` stay the app'"'"'s own'
}

# --- the Vitest cases ---------------------------------------------------------

@test "remote: each shape's entry.test.ts holds a case for each entry, router, widget and leak criterion" {
  local f title
  f="$RM/page/src/remote/entry.test.ts"
  [ -f "$f" ]
  for title in \
    'mount rejects a widget context and renders nothing' \
    'mount stops its work once ctx.signal aborts' \
    'unmount is idempotent, safe on a partial mount, and leaves 0 child nodes' \
    'after unmount the popstate listener is removed and listener calls balance' \
    'toLocal strips basePath at a path-segment boundary' \
    'every path the router produces is prefixed with basePath, never the origin root' \
    'a modified link click is left to the browser and calls neither pushState nor onNavigate' \
    'navigate inside basePath calls history.pushState and notifies subscribers' \
    'navigate outside basePath calls onNavigate and neither pushState nor a location write' \
    'subscribe fires on popstate and its unsubscribe stops it'; do
    grep -qF -- "it(\"$title\"" "$f" || { echo "missing page case: $title"; return 1; }
  done
  f="$RM/widget/src/remote/entry.test.ts"
  [ -f "$f" ]
  for title in \
    'the manifest has contractMajor 1, an object configSchema and min <= default <= max' \
    'entry.tsx re-exports the manifest, and evaluating it only defines its exports' \
    'mount rejects a page context and renders nothing' \
    'mount stops its work once ctx.signal aborts' \
    'mount narrows ctx.config and rejects a config that fails the narrowing' \
    'mount renders for ctx.size and re-renders on onResize without a remount' \
    'the widget neither reads nor writes history or location' \
    'unmount calls the onResize unsubscribe, is idempotent, and leaves 0 child nodes'; do
    grep -qF -- "it(\"$title\"" "$f" || { echo "missing widget case: $title"; return 1; }
  done
}

@test "remote: each shape lints under the React config: no unused _ bindings, entry opts out of fast refresh" {
  local shape
  for shape in page widget; do
    # no-unused-vars exempts only `_` arguments, so a destructured `_` rename is an error
    run grep -cE '[a-zA-Z]+: _[a-zA-Z]+[,} ]' "$RM/$shape/src/remote/entry.test.ts"
    [ "$output" = "0" ]
    run head -n 1 "$RM/$shape/src/remote/entry.tsx"
    [ "$output" = '/* eslint-disable react-refresh/only-export-components -- this module'"'"'s exports are' ]
  done
}

# --- the record ---------------------------------------------------------------

@test "remote: ARCHITECTURE.md and MAINTAINING.md document the tree, trigger, markers and layering" {
  local arch maint
  arch="$(collapse < "$ARCH")"
  maint="$(collapse < "$MAINT")"
  contains "$arch" '**The remote overlay (#1125).**'
  contains "$arch" '`development/skills/bootstrap/templates/languages/javascript/react-remote/`'
  contains "$arch" 'its **shape markers** are `src/remote/entry.tsx` and, for a widget, `src/remote/manifest.ts`'
  contains "$arch" '§3d → §3k → §3k.5 → §3k.6 → §3k.9'
  contains "$maint" '**The remote overlay** (#1125, SKILL.md §3k.9) is a sibling tree'
  contains "$maint" 'Keep `src/remote/entry.tsx` and `src/remote/manifest.ts` as the shape markers'
}
