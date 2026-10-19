#!/usr/bin/env bats
#
# Structural tests for the React shell overlay templates (#1124, epic #1122),
# rendered into a React app the way bootstrap SKILL.md §3k.7 instructs. The shell
# is a sibling tree to react/ (#957) and renders after §3k.6, sharing no path with
# any layer beneath it.
#
# This suite pins the file set, the key content, the line width, the layering,
# §3k.7's wording, and each loader.test.ts and auth.test.ts case title. The six
# framework-free modules are TYPE-CHECKED with `tsc --noEmit --strict` against the
# mfe-contract/v1 index.d.ts, and auth.ts (#1326) also against a type-only
# oidc-client-ts stand-in — tsc is the declared bats dependency tests/mfe-contract.bats pins.
# Running the Vitest cases against a rendered, installed tree is #1063's job:
# nothing under bats installs npm packages.
#
# ANCHOR FORM: headings and quoted tokens only, never `path:line` (#1189).

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  JS="$REPO_ROOT/development/skills/bootstrap/templates/languages/javascript"
  SH="$JS/react-shell"
  DTS="$JS/mfe-contract/index.d.ts"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  MAINT="$REPO_ROOT/MAINTAINING.md"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$OUT"
}

# The twelve shell templates, each at its deploy relpath, `LC_ALL=C sort` order.
SHELL_FILES=(
  public/auth-config.json
  public/importmap.json
  src/shell/Chrome.tsx
  src/shell/Shell.tsx
  src/shell/auth.test.ts
  src/shell/auth.ts
  src/shell/context.ts
  src/shell/import-map.ts
  src/shell/loader.test.ts
  src/shell/loader.ts
  src/shell/navigation.ts
  src/shell/routes.ts
)

# The six modules that need no React, so tsc can check them with no install —
# auth.ts against the type-only oidc-client-ts stand-in (#1326).
FRAMEWORK_FREE=(routes navigation import-map loader context auth)
OIDC_SHIM_REL=tests/fixtures/react-shell/oidc-client-ts.d.ts

# Claim reads the shell must never make: role, permission or scope claims, which
# would turn a display-only claim into a client-side authorization input (#1326).
FORBIDDEN_CLAIMS='\broles\b|\bpermissions?\b|realm_access|resource_access|\b(user|profile|claims|token)\??\.(scopes?|scp)\b'

render_shell() {
  zsh "$RENDER" --templates "$SH" --out "$1" --project-slug Acme-Corp/demo "${SHELL_FILES[@]}"
}

collapse() {
  tr -s '[:space:]' ' ' | sed 's/[[:space:]]*$//'
}

# --- the template tree --------------------------------------------------------

@test "shell: the template tree contains exactly the twelve blessed files" {
  local listed
  listed="$(cd "$SH" && find . -type f | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')"
  [ "$listed" = "${SHELL_FILES[*]} " ]
}

@test "shell: the set renders with --project-slug, each file at its relpath, no placeholder left" {
  run render_shell "$OUT"
  [ "$status" -eq 0 ]
  local f
  for f in "${SHELL_FILES[@]}"; do [ -f "$OUT/$f" ]; done
  run grep -rlE '\{\{[A-Z_]+\}\}' "$OUT"
  [ "$status" -eq 1 ]
  # the scope is the lowercased owner, the contract's scope-derivation rule
  contains "$(cat "$OUT/src/shell/loader.ts")" 'from "@acme-corp/mfe-contract";'
}

@test "shell: no template source line is longer than the prettier printWidth of 120" {
  [ "$(jq -r .printWidth "$JS/.prettierrc.json")" = "120" ]
  local f long
  for f in "${SHELL_FILES[@]}"; do
    long="$(python3 -c '
import sys
for n, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    if len(line.rstrip("\n")) > 120:
        print(f"{n}: {len(line.rstrip(chr(10)))}")
' "$SH/$f")"
    [ -z "$long" ] || { echo "$f over 120: $long"; false; }
  done
}

@test "shell: the six framework-free modules pass tsc --noEmit --strict against the contract" {
  render_shell "$OUT"
  local m inc=()
  for m in "${FRAMEWORK_FREE[@]}"; do inc+=("src/shell/$m.ts"); done
  jq -n --arg dts "$DTS" --arg oidc "$REPO_ROOT/$OIDC_SHIM_REL" --args '{compilerOptions: {strict: true,
      noEmit: true, target: "ES2022", module: "ESNext", moduleResolution: "Bundler", lib: ["ES2022", "DOM"],
      types: [], verbatimModuleSyntax: true, erasableSyntaxOnly: true,
      paths: {"@acme-corp/mfe-contract": [$dts], "oidc-client-ts": [$oidc]}}, files: $ARGS.positional}' \
    "${inc[@]}" > "$OUT/tsconfig.json"
  run jq -e '.compilerOptions | has("skipLibCheck") | not' "$OUT/tsconfig.json"
  [ "$status" -eq 0 ]
  run tsc -p "$OUT" --noEmit --strict
  [ "$status" -eq 0 ]
}

@test "shell: the type check reds on a module that breaks the contract (non-vacuity)" {
  render_shell "$OUT"
  sed -i.bak 's/kind: "page",/kind: "widget",/' "$OUT/src/shell/context.ts"
  grep -q 'kind: "widget",' "$OUT/src/shell/context.ts"
  jq -n --arg dts "$DTS" --arg oidc "$REPO_ROOT/$OIDC_SHIM_REL" '{compilerOptions: {strict: true, noEmit: true,
      target: "ES2022", module: "ESNext", moduleResolution: "Bundler", lib: ["ES2022", "DOM"], types: [],
      paths: {"@acme-corp/mfe-contract": [$dts], "oidc-client-ts": [$oidc]}}, files: ["src/shell/context.ts"]}' \
    > "$OUT/tsconfig.json"
  run tsc -p "$OUT" --noEmit --strict
  [ "$status" -ne 0 ]
  contains "$output" "src/shell/context.ts"
  contains "$output" "error TS2322: Type '\"widget\"' is not assignable to type '\"page\"'."
}

# --- key content --------------------------------------------------------------

@test "shell: routes.ts exports ShellRoute, an empty default table and a segment-boundary matchRoute" {
  local f
  f="$(collapse < "$SH/src/shell/routes.ts")"
  contains "$f" 'export interface ShellRoute { /** The path prefix the remote owns, e.g. "/orders". */ prefix: string;'
  contains "$f" 'specifier: string;'
  contains "$f" 'label: string; }'
  contains "$f" 'export const routes: readonly ShellRoute[] = [];'
  contains "$f" 'export function matchRoute(pathname: string, table: readonly ShellRoute[]): ShellRoute | null {'
  contains "$f" 'const hit = prefix === "/" || pathname === prefix || pathname.startsWith(`${prefix}/`);'
  contains "$f" 'if (hit && prefix.length > bestLength) {'
}

@test "shell: navigation.ts pushes then notifies, and subscribe fires on popstate and unsubscribes" {
  local f
  f="$(collapse < "$SH/src/shell/navigation.ts")"
  contains "$f" 'export function navigate(path: string): void { window.history.pushState(null, "", path); notify(); }'
  contains "$f" 'export function subscribe(cb: Listener): () => void {'
  contains "$f" 'window.addEventListener("popstate", notify);'
  contains "$f" 'window.removeEventListener("popstate", notify);'
}

@test "shell: context.ts builds every PageContext field from ShellCapabilities, with the static defaults" {
  local c a
  c="$(collapse < "$SH/src/shell/context.ts")"
  a="$(collapse < "$SH/src/shell/auth.ts")"
  contains "$c" 'export interface ShellCapabilities { auth: AuthContext; flags: FlagContext; theme: ThemeTokens; }'
  contains "$c" 'flags: { isEnabled: () => false, variant: () => undefined }, theme: Object.freeze({}),'
  contains "$c" 'auth: capabilities.auth, flags: capabilities.flags, theme: capabilities.theme, signal, kind: "page", basePath, onNavigate,'
  contains "$c" 'auth: createAuthContext(),'
  contains "$a" 'export function createAuthContext(): AuthContext { return pageAuth().context; }'
  contains "$a" 'Object.freeze({ sub: "", displayName: "", tenantId: "" })'
}

# --- the auth module (#1326) --------------------------------------------------

@test "auth: auth.ts is a public PKCE client holding tokens in memory, with no iframe renew" {
  local a
  a="$(collapse < "$SH/src/shell/auth.ts")"
  contains "$a" 'import { InMemoryWebStorage, UserManager, WebStorageStateStore, type INavigator, type User } from "oidc-client-ts";'
  contains "$a" 'response_type: "code",'
  contains "$a" 'redirectTarget: "top",'
  # tokens in memory; the PKCE code_verifier and state in sessionStorage for the round-trip
  contains "$a" 'userStore: new WebStorageStateStore({ store: new InMemoryWebStorage() }),'
  contains "$a" 'stateStore: new WebStorageStateStore({ store: window.sessionStorage }),'
  contains "$a" 'automaticSilentRenew: false, monitorSession: false,'
  lacks "$a" 'silent_redirect_uri'
  lacks "$a" 'localStorage'
  lacks "$a" 'indexedDB'
  lacks "$a" 'document.cookie'
  # renewal rotates the refresh token; without one, or when it is refused, the top-level redirect re-acquires
  contains "$a" 'const renewed = current.refresh_token === undefined ? null : await users.signinSilent().catch(() => null); if (signedOut) return; if (renewed === null) { session = undefined; await signIn(); return; } hold(renewed);'
  contains "$a" 'const RENEW_MARGIN_S = 30;'
  contains "$a" 'if (user === null) await signIn();'
  contains "$a" 'if (current !== null && left !== undefined && left <= RENEW_MARGIN_S) { renewal ??= renew(current).finally(() => {'
  # the callback leaves its URL before it is handled, then returns to the starting page and re-matches the router
  contains "$a" 'if (window.location.pathname === config.redirectPath) {'
  contains "$a" 'const callback = window.location.href; window.history.replaceState(null, "", "/"); const signedIn = await users.signinRedirectCallback(callback); hold(signedIn); window.history.replaceState(null, "", returnPath(signedIn.state)); window.dispatchEvent(new PopStateEvent("popstate"));'
  # after a reload: a top-level redirect, no prompt parameter
  contains "$a" 'await users.signinRedirect({ state: `${pathname}${search}${hash}` });'
  lacks "$a" 'prompt'
}

@test "auth: no client secret appears anywhere in the shell tree" {
  # auth.test.ts names the parameter only to assert the provider never receives one
  run grep -rniE --exclude=auth.test.ts 'client_?secret' "$SH"
  [ "$status" -eq 1 ]
  [ "$(jq -r 'keys_unsorted | map(select(test("secret"; "i"))) | length' "$SH/public/auth-config.json")" = "0" ]
}

@test "auth: public/auth-config.json ships the four provider fields as empty placeholders" {
  [ "$(jq -c . "$SH/public/auth-config.json")" = '{"issuer":"","clientId":"","redirectPath":"","scope":""}' ]
  local a
  a="$(collapse < "$SH/src/shell/auth.ts")"
  contains "$a" 'const response = await fetch("/auth-config.json");'
  contains "$a" 'const CONFIG_FIELDS = ["issuer", "clientId", "redirectPath", "scope"] as const;'
  contains "$a" 'if (typeof value !== "string" || value === "") throw new Error(`/auth-config.json: ${key} is not set`);'
  contains "$a" 'manager ??= loadConfig().then('
}

@test "auth: a remote sees only getAccessToken and frozen claims, and only auth.ts calls the provider" {
  local a f
  a="$(collapse < "$SH/src/shell/auth.ts")"
  contains "$a" 'const context: AuthContext = Object.freeze({ getAccessToken, get claims(): AuthClaims { return claims; }, });'
  contains "$a" 'return Object.freeze({ sub: profile.sub, displayName: text(profile.name) || text(profile.preferred_username), tenantId: tenantOf(profile.organization), });'
  contains "$a" 'return keys.length === 1 ? keys[0] : ""; } return text(organization); }'
  # no other shell source imports the OIDC client or reaches the provider (auth.test.ts drives auth.ts)
  for f in $(cd "$SH" && find . -type f -name '*.ts*' | sed 's#^\./##'); do
    [ "$f" = src/shell/auth.ts ] && continue
    [ "$f" = src/shell/auth.test.ts ] && continue
    run grep -nE 'oidc-client-ts|UserManager|signinRedirect|signinSilent|signoutRedirect|/auth-config\.json' "$SH/$f"
    [ "$status" -eq 1 ] || { echo "$f reaches the provider: $output"; false; }
  done
}

@test "auth: signOut discards the tokens before it sends the top-level page to the end-session endpoint" {
  local a
  a="$(collapse < "$SH/src/shell/auth.ts")"
  contains "$a" 'const signOut = async (): Promise<void> => { signedOut = true; const idToken = user?.id_token; user = null; claims = NO_CLAIMS;'
  contains "$a" 'await users.removeUser(); await users.signoutRedirect({ id_token_hint: idToken });'
  contains "$a" 'if (signedOut) throw new Error("signed out");'
}

@test "auth: no shell source reads a role, permission or scope claim" {
  run grep -rnE "$FORBIDDEN_CLAIMS" "$SH"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "auth: the claim guard fires on each forbidden shape (non-vacuity)" {
  local line
  for line in 'if (user.profile.roles) {' 'const p = claims.permissions;' 'token.realm_access' \
      'x.resource_access' 'if (user.scope.includes("admin"))' 'const s = profile.scopes;' 'token?.scp'; do
    printf '%s\n' "$line" | grep -qE "$FORBIDDEN_CLAIMS" || { echo "guard missed: $line"; false; }
  done
  # the config's own scope field is not a claim read
  run grep -qE "$FORBIDDEN_CLAIMS" <<< 'scope: config.scope,'
  [ "$status" -eq 1 ]
}

@test "auth: the oidc-client-ts stand-in declares only types, and the type check reds without it (non-vacuity)" {
  local shim="$REPO_ROOT/$OIDC_SHIM_REL"
  [ -f "$shim" ]
  run grep -nE '^export (const|function|let|var) ' "$shim"
  [ "$status" -eq 1 ]
  render_shell "$OUT"
  jq -n --arg dts "$DTS" '{compilerOptions: {strict: true, noEmit: true, target: "ES2022", module: "ESNext",
      moduleResolution: "Bundler", lib: ["ES2022", "DOM"], types: [],
      paths: {"@acme-corp/mfe-contract": [$dts]}}, files: ["src/shell/auth.ts"]}' > "$OUT/tsconfig.json"
  run tsc -p "$OUT" --noEmit --strict
  [ "$status" -ne 0 ]
  contains "$output" "oidc-client-ts"
}

@test "shell: import-map.ts fetches /importmap.json once and names an unknown specifier" {
  local f
  f="$(collapse < "$SH/src/shell/import-map.ts")"
  contains "$f" 'const response = await fetch("/importmap.json");'
  contains "$f" 'cached ??= fetchImportMap().catch((error: unknown) => { cached = undefined; throw error; });'
  contains "$f" 'throw new Error(`unknown remote specifier: ${specifier}`);'
  [ "$(jq -c . "$SH/public/importmap.json")" = '{"imports":{}}' ]
}

@test "shell: loader.ts imports with @vite-ignore and follows the ordered procedure" {
  local f
  f="$(collapse < "$SH/src/shell/loader.ts")"
  contains "$f" 'export const importRemote: ImportRemote = (url) => import(/* @vite-ignore */ url);'
  # (a) a fresh controller's signal goes into the context
  contains "$f" 'const controller = new AbortController(); const ctx = buildContext(controller.signal);'
  # (b) an import that settles after the abort is never mounted
  contains "$f" 'if (controller.signal.aborted) return; // (b)'
  # (c) unmount at most once, after the attempt settled; a lone mount rejection unmounts and shows the fallback
  contains "$f" 'unmounted ??= Promise.resolve() .then(() => remote?.unmount(outlet)) .catch(() => undefined)'
  contains "$f" '.catch(() => undefined) .then(() => outlet.replaceChildren()); return unmounted;'
  contains "$f" 'controller.abort(); await settled; if (mountCalled) await unmountOnce();'
  contains "$f" 'await unmountOnce(); showFallback(outlet);'
  # (d) the next attempt is queued behind the previous one's leave()
  contains "$f" 'this.queue = this.queue.then(async () => { if (this.current !== null) await this.current.leave();'
  # the same prefix remounts nothing
  contains "$f" 'if (prefix === this.currentPrefix) return this.queue;'
}

@test "shell: Chrome.tsx renders header, nav and main, and a plain click navigates without a reload" {
  local f
  f="$(collapse < "$SH/src/shell/Chrome.tsx")"
  contains "$f" '<header> <nav aria-label="Main">'
  contains "$f" '<main> <div ref={outletRef} data-shell-outlet="" /> {children} </main>'
  contains "$f" 'if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return; event.preventDefault(); navigate(path);'
  contains "$f" '{route.label}'
}

@test "shell: Shell.tsx takes capabilities as its one injection point and renders children when nothing matches" {
  local f
  f="$(collapse < "$SH/src/shell/Shell.tsx")"
  contains "$f" 'capabilities: ShellCapabilities;'
  contains "$f" '(route, signal) => createPageContext(latest.current.capabilities, signal, route.prefix, navigate),'
  contains "$f" 'loaderRef.current ??= new RouteLoader('
  contains "$f" 'const mine = ++generation; if (route !== null) setShowChildren(false);'
  contains "$f" 'if (active && mine === generation && route === null) setShowChildren(true);'
  contains "$f" '{showChildren ? children : null}'
}

# --- layering -----------------------------------------------------------------

# Every lower layer's deploy paths: §3d's base files, §3k's contract-consumer
# tree, and §3k.5/§3k.6's react tree (its contract-consumer/ pair lands at root).
lower_layer_paths() {
  local f
  for f in .nvmrc .prettierrc.json eslint.config.js tsconfig.json vitest.config.ts; do echo "$f"; done
  (cd "$JS/contract-consumer" && find . -type f | sed 's#^\./##; s#\.tmpl$##')
  (cd "$JS/react" && find . -type f ! -name gitignore | sed 's#^\./##; s#^contract-consumer/##; s#\.tmpl$##')
}

@test "shell: rendering onto the §3d/§3k/§3k.5/§3k.6 layers leaves every one of their files byte-identical" {
  local app="$BATS_TEST_TMPDIR/app" p before after
  mkdir -p "$app"
  while IFS= read -r p; do
    mkdir -p "$app/$(dirname "$p")"
    printf 'lower layer: %s\n' "$p" > "$app/$p"
  done < <(lower_layer_paths)
  [ "$(find "$app" -type f | wc -l | tr -d ' ')" -gt 20 ]
  before="$(cd "$app" && find . -type f -exec shasum {} + | LC_ALL=C sort)"
  render_shell "$app"
  after="$(cd "$app" && find . -type f ! -path './src/shell/*' ! -path './public/importmap.json' \
    -not -path './public/auth-config.json' -exec shasum {} + | LC_ALL=C sort)"
  [ "$before" = "$after" ]
  # no shell target shares a path with a lower layer, and none is Vite-owned
  run comm -12 <(printf '%s\n' "${SHELL_FILES[@]}" | LC_ALL=C sort) <(lower_layer_paths | LC_ALL=C sort -u)
  [ -z "$output" ]
  local f
  for f in index.html src/main.tsx src/App.tsx vite.config.ts package.json; do
    run printf '%s\n' "${SHELL_FILES[@]}"
    lacks "$output" "$f"
  done
}

# --- the bootstrap step (SKILL.md §3k.7) --------------------------------------

shell_step() {
  sed -n '/^### 3k\.7\. Shell overlay/,/^### /p' "$SKILL" | tr -s '[:space:]' ' '
}

STEP_END='### 3k.8. Canvas overlay (a widget canvas on the shell — #1939) '

@test "shell: SKILL.md carries §3k.7 right after §3k.6, before §3l" {
  local section b s l
  section="$(shell_step)"
  ends_with "$section" "$STEP_END"
  b="$(grep -n '^### 3k\.6\. ' "$SKILL" | cut -d: -f1)"
  s="$(grep -n '^### 3k\.7\. ' "$SKILL" | cut -d: -f1)"
  l="$(grep -n '^### 3l\. ' "$SKILL" | cut -d: -f1)"
  matches "$b" '^[0-9]+$'
  matches "$s" '^[0-9]+$'
  matches "$l" '^[0-9]+$'
  [ "$b" -lt "$s" ]
  [ "$s" -lt "$l" ]
}

@test "shell: §3k.7 states the trigger, the droppable plan line, the marker and its State D gap" {
  local section
  section="$(shell_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" 'Run this step after §3k.6 when §3k.5'"'"'s overlay applies'
  contains "$section" 'React UI shape: shell (default) — reply `remote: page` or `remote: widget` to scaffold a remote instead (#1127)'
  contains "$section" 'A dropped line — only the user dropping Q7'"'"'s plan line — skips the step entirely: not an error, no Step 5 item.'
  contains "$section" 'Exit 3 is not a dropped line and follows its per-reason rules above: no shape to choose; a `shape-marker` repo'"'"'s own State D adoption gap still applies; and `conflicting-markers` is §3k.9'"'"'s refusal, with its Step 5 item.'
  contains "$section" '**Shape marker — `src/shell/loader.ts`.**'
  contains "$section" 'the step is an **adoption gap** only when the marker is present and another shell file is missing'
  contains "$section" 'A React repo with no `src/shell/loader.ts` is offered the shell in State D only through Q7'"'"'s recommendation'
}

@test "shell: §3k.7 installs the contract first and renders nothing on a failed install" {
  local section
  section="$(shell_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" '**Install first, render second.**'
  contains "$section" 'npm i -D @<scope>/mfe-contract'
  contains "$section" 'restore both files from the snapshot, render nothing, and record a Step 5 item naming `@<scope>/mfe-contract` and the publishing story, #1899.'
  contains "$section" 'Snapshot `package.json` and the lockfile, then install the contract package'
  contains "$section" 'its scope being the owner part of the repository slug, lowercased'
  contains "$section" 'Skip the install when `package.json` already lists the package.'
  contains "$section" 'No marker lands, so a plain re-run offers the shell again through Q7'"'"'s plan line;'
  contains "$section" 'the item says that approving it adds the shell once #1899 has published `@<scope>/mfe-contract`.'
  lacks "$section" 'a plain re-run will not add the shell'
  contains "$section" 'a non-zero `render.zsh` exit takes the failed install'"'"'s branch above'
  contains "$section" 'and the run carries on. On either failure the `src/main.tsx` edit below is not offered.'
  contains "$section" '**Withhold `src/shell/loader.test.ts`** — drop it from the list — unless §3k.5 ended'
  contains "$section" 'unless §3k.5 ended with its setup module, `src/test/setup.ts`, on disk, and record a Step 5 item'
  contains "$section" 'Record every file this step writes under the `react_overlay` telemetry step key (*Keep the run'"'"'s facts as you go*). Each file lands'
  contains "$(cat "$SKILL")" '| `react_overlay` | 3k.5. React overlay, 3k.7. Shell overlay, 3k.8. Canvas overlay, 3k.9. Remote overlay, and 3k.10. MFE conformance |'
}

@test "shell: §3k.7's render block lists every shell template and passes --project-slug" {
  local section f
  section="$(shell_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" '--templates "<skill-base-dir>/templates/languages/javascript/react-shell"'
  contains "$section" '--project-slug "<owner/repo>"'
  for f in "${SHELL_FILES[@]}"; do contains "$section" " $f"; done
  contains "$section" 'so no `{{PLACEHOLDER}}` survives'
  contains "$section" 'Each file lands at its own relpath — `src/shell/…` and `public/importmap.json` (`{ "imports": {} }`, the local-development map; each environment serves its own `/importmap.json`, #1128).'
  contains "$section" 'running `src/shell/loader.test.ts` and `src/shell/auth.test.ts` against a rendered tree is the render-and-build smoke check'"'"'s job (#1063).'
  contains "$section" 'An on-disk shell file that differs from its template takes **idempotency rule 3'"'"'s diff prompt**, never a blind overwrite.'
}

@test "shell: §3k.7's only Vite-owned edit is the confirmed main.tsx wrap" {
  local section
  section="$(shell_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" '**The one Vite-owned edit — a §4c-class confirmed edit of `src/main.tsx`.**'
  contains "$section" 'It wraps `<App />` in the shell, with the capabilities created once at module scope:'
  contains "$section" '<Shell capabilities={capabilities}><App /></Shell>'
  contains "$section" '**Confirm before editing**: show the diff and ask; the plan approval alone does not cover it.'
  contains "$section" '**Snapshot `src/main.tsx` first.**'
  contains "$section" '**Idempotent skip** when `src/main.tsx` already imports `Shell`.'
  contains "$section" 'restore the pre-edit snapshot and record a Step 5 TODO naming the lines that edit would have added, to add by hand.'
  contains "$section" '**It composes with §3k.6'"'"'s `QueryClientProvider` edit in either order**'
  contains "$section" 'No other Vite-owned file is written — `index.html` included.'
}

@test "shell: §3k.7 installs oidc-client-ts, withholds auth.test.ts with loader.test.ts, and wires signIn (#1326)" {
  local section
  section="$(shell_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" 'npm i oidc-client-ts # runtime: src/shell/auth.ts'"'"'s OIDC client (#1326)'
  contains "$section" '`oidc-client-ts` installs only after the contract package is in place, so a failed contract install never reaches it;'
  contains "$section" 'never reaches it; it follows the same skip rule, and **if its install fails,'
  contains "$section" '**if its install fails, restore both files from the snapshot, render nothing, and record a Step 5 item naming `oidc-client-ts`**'
  contains "$section" '`src/shell/auth.test.ts` needs the same wiring and is withheld, with its own Step 5 item, under the same rule.'
  contains "$section" '`public/auth-config.json` is the auth module'"'"'s provider config, with the issuer, client id, redirect path and scopes as empty placeholders and no secret field.'
  contains "$section" 'import { signIn } from "./shell/auth";'
  contains "$section" 'signIn().catch((error: unknown) => console.error("sign-in failed:", error));'
  contains "$section" 'Without it, nothing completes the callback.'
  contains "$section" 'Each environment serves its own `/auth-config.json` behind the gateway (#1128), and the shell refuses to sign in while a field is empty.'
  contains "$section" 'When this step ends with the template'"'"'s placeholder `public/auth-config.json` on disk, whether it was just written or skipped as identical, record a Step 5 item to set `issuer`, `clientId`, `redirectPath` and `scope` for local development, and to have each environment serve its own `/auth-config.json` behind the gateway (#1128).'
  contains "$section" 'Record no such item when the user kept their own differing file at idempotency rule 3'"'"'s diff prompt, or when a failed install or render left the file unwritten.'
  contains "$section" 'The `signIn()` call starts the page'"'"'s sign-in at load (#1326): it completes the provider'"'"'s callback on the redirect path, and otherwise sends the top-level page to the provider.'
  contains "$section" 'When it imports `Shell` but not `signIn` — a shell bootstrapped before #1326 — offer the `signIn` import and call as their own edit'
  contains "$section" '`auth.ts` against a type-only `oidc-client-ts` stand-in'
}

@test "auth: auth.test.ts holds a case for each auth criterion" {
  local f title
  f="$SH/src/shell/auth.test.ts"
  [ -f "$f" ]
  for title in \
    'signs in with the authorization-code flow and PKCE as a public client, with no client secret' \
    'after sign-in and the callback no storage area holds a token' \
    'the callback removes the PKCE code_verifier and state from sessionStorage' \
    'the callback returns to the page that started the sign-in' \
    'after a reload the shell re-acquires by a top-level redirect instead of restoring a token' \
    'an expiring token is renewed with the refresh token, and the rotated refresh token stays in memory' \
    'renewal never runs a hidden-iframe silent renew' \
    'fetches /auth-config.json once per page load and reads issuer, clientId, redirectPath and scope' \
    'an unset /auth-config.json field rejects getAccessToken instead of redirecting' \
    'the shipped /auth-config.json placeholder is rejected, never sent to a provider' \
    'the AuthContext a remote receives exposes only getAccessToken and frozen display-only claims' \
    'signOut drops the tokens, so a handed-out getAccessToken rejects, then ends the provider session'; do
    grep -qF -- "it(\"$title\"" "$f" || { echo "missing case: $title"; return 1; }
  done
  [ "$(grep -c '^  it("' "$f")" -eq 12 ]
}

# --- the Vitest cases ---------------------------------------------------------

@test "shell: loader.test.ts holds a case for each loader, onNavigate, leak and zero-remotes criterion" {
  local f title
  f="$SH/src/shell/loader.test.ts"
  [ -f "$f" ]
  for title in \
    '(a) entering a route builds a fresh signal and imports the resolved module' \
    '(b) leaving before the import settles aborts and never mounts or unmounts' \
    '(c) leaving after mount aborts, waits for mount to settle, then unmounts exactly once' \
    '(c) a mount that rejects on its own is unmounted once and the outlet shows the fallback' \
    'an import that fails shows the fallback and calls no unmount' \
    '(d) the next route waits for the previous attempt, so a stale remote is never mounted' \
    'after unmount the outlet has 0 child nodes and window listener calls balance' \
    'onNavigate to another prefix tears down the current remote and mounts the matched one' \
    'onNavigate within the same prefix remounts nothing' \
    "onNavigate to no route renders the shell's children after teardown" \
    "navigating from no route to a remote route hides the shell's children" \
    'a no-route resolve that lands after a newer remote navigation leaves the children hidden' \
    'with zero routes the shell renders its children and never fetches /importmap.json or imports'; do
    grep -qF -- "it(\"$title\"" "$f" || { echo "missing case: $title"; return 1; }
  done
}

# --- the record ---------------------------------------------------------------

@test "shell: ARCHITECTURE.md and MAINTAINING.md document the tree, trigger, marker and layering" {
  local arch maint
  arch="$(collapse < "$ARCH")"
  maint="$(collapse < "$MAINT")"
  contains "$arch" '**The shell overlay (#1124).**'
  contains "$arch" '`development/skills/bootstrap/templates/languages/javascript/react-shell/`'
  contains "$arch" 'Its **shape marker** is `src/shell/loader.ts`'
  contains "$arch" 'It **renders after §3k.6**: §3d → §3k → §3k.5 → §3k.6 → §3k.7'
  contains "$maint" '**The shell overlay** (#1124, SKILL.md §3k.7) is a sibling tree'
  contains "$maint" 'Keep `src/shell/loader.ts` as the shape marker'
}

@test "auth: ARCHITECTURE.md records the auth module and MAINTAINING.md the stand-in rule" {
  local arch maint
  arch="$(collapse < "$ARCH")"
  maint="$(collapse < "$MAINT")"
  contains "$arch" '**The shell'"'"'s auth module (#1326).** `src/shell/auth.ts` realizes the identity position'"'"'s browser half and is the page'"'"'s **only token acquirer**.'
  contains "$arch" 'Its user store is in memory, so a reload re-acquires through a top-level redirect that the provider'"'"'s session answers, and no token is ever restored from storage.'
  contains "$arch" 'automatic silent renew and session monitoring are off and no `silent_redirect_uri` is configured, so no hidden iframe ever runs.'
  contains "$arch" '`signOut()` discards the tokens first, so a context already handed out rejects'
  contains "$arch" '`src/main.tsx` calls `signIn()` once at page load, the call that completes the callback.'
  contains "$maint" 'the suite type-checks `auth.ts` against `tests/fixtures/react-shell/oidc-client-ts.d.ts`'
  contains "$maint" 'copy that member'"'"'s signature into the stand-in from the real package'"'"'s types, narrowing it and never widening it.'
}
