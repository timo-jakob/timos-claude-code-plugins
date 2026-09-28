#!/usr/bin/env bats
#
# mfe-contract/v1 — the shell↔remote mount contract (#1123, epic #1122).
#
# The contract ships as a bootstrap template under
# development/skills/bootstrap/templates/languages/javascript/mfe-contract/ —
# a TYPES-ONLY npm package — and ARCHITECTURE.md's `mfe-contract/v1` section is
# its normative home. This suite pins both halves:
#
#   * the package: exactly three published files, the package.json fields that
#     make it types-only, and the three decisions (AuthContext shape, the abort
#     rule, the manifest as a module export) on the types they govern;
#   * the compiler's verdict: the worked examples under examples/ type-check
#     with `tsc --noEmit --strict`, AND the deliberately non-conforming remote's
#     `@ts-expect-error` pins are each live. tsc itself fails on an unused
#     `@ts-expect-error`, so a green run already proves every pinned violation
#     is rejected; the stripped-copy test below additionally proves the pins are
#     what carry that — without them the same tree must fail, once per pin — so
#     the check cannot pass vacuously (e.g. over an `include` that matched
#     nothing);
#   * the record: the ARCHITECTURE.md section, and the identity position's #1326
#     bullet pointing at it while still citing the design doc.
#
# `tsc` is a DECLARED test dependency, exact-pinned in tests/Dockerfile and
# .github/workflows/script-tests.yml. It is called unguarded on purpose: a skip
# would silently drop the only check that the contract compiles.
#
# ANCHOR FORM: headings and quoted tokens only, never `path:line` (#1189).

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PKG="$REPO_ROOT/development/skills/bootstrap/templates/languages/javascript/mfe-contract"
  DTS="$PKG/index.d.ts"
  PKG_JSON="$PKG/package.json"
  README="$PKG/README.md"
  EXAMPLES="$PKG/examples"
  NON_CONFORMING="$EXAMPLES/non-conforming-remote.ts"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  MFE_SPEC="$REPO_ROOT/docs/superpowers/specs/2026-07-27-mfe-app-family-design.md"
  DOCKERFILE="$BATS_TEST_DIRNAME/Dockerfile"
  WORKFLOW="$REPO_ROOT/.github/workflows/script-tests.yml"
}

# Collapse a region to one line (same shape as the position suites), so a pin
# survives re-wrapping.
collapse() {
  tr -s '[:space:]' ' ' | sed 's/[[:space:]]*$//'
}

# FILE contains the literal (single-line) string. `_assert_args` guards a
# dropped second argument, since `grep -qF ''` matches every non-empty file.
file_has() {
  _assert_args "$#" "${2-}" || return 2
  grep -qF -e "$2" -- "$1"
}

# A `@ts-expect-error` DIRECTIVE line — not prose that merely mentions one.
EXPECT_ERROR_RE='^[[:space:]]*// @ts-expect-error'

# Strip JSDoc markers — `/**`, ` */` and each line's leading ` * ` — so a pin
# reads the prose a reader sees rather than the comment syntax around it.
strip_jsdoc() {
  sed -e 's#^[[:space:]]*/\*\*##' -e 's#^[[:space:]]*\*/##' -e 's#^[[:space:]]*\*[[:space:]]\{0,1\}##'
}

# The JSDoc block directly above `export interface NAME`, stripped and collapsed.
doc_of() {
  awk -v name="$1" '
    /^\/\*\*/ { buf = "" }
    { buf = buf $0 "\n" }
    $0 ~ "^export interface " name "( |\\{)" { printf "%s", buf; exit }
  ' "$DTS" | strip_jsdoc | collapse
}

# The body of one top-level `export interface NAME … }` block in index.d.ts.
interface_body() {
  awk -v name="$1" '
    $0 ~ "^export interface " name "( |\\{)" { f = 1 }
    f { print }
    f && /^}/ { exit }
  ' "$DTS"
}

# The body of index.d.ts with every comment removed — member declarations only,
# so a negative pin cannot be tripped by (or hidden behind) the doc comments
# that legitimately DISCUSS tokens and roles.
declarations() {
  declarations_of < "$DTS"
}

# Strip comments from stdin in ONE left-to-right pass, so whichever opener comes
# first wins: a `//` inside a block comment is part of that block, a `/*` inside
# a line comment is part of that line, and only the comment TEXT goes — a
# declaration sharing a line with a comment survives.
declarations_of() {
  perl -0pe 's{/\*.*?\*/|//[^\n]*}{}gs'
}

# The negative pins' patterns — ONE copy, used by the pin and by its
# anti-vacuity control, so the two cannot drift apart. A member name ENDING in
# the word, so camelCase compounds (`userRoles`, `sessionToken`) match too.
ROLE_MEMBER_RE='[A-Za-z]*([Rr]oles?|[Pp]ermissions?|[Ss]copes?)\??:'
TOKEN_MEMBER_RE='[A-Za-z]*([Tt]oken|[Jj]wt)\??:'
# Anything that could bring an outside type into index.d.ts: an import or
# re-export statement, an inline `import('…')` type, a require, or a
# triple-slash reference.
IMPORT_RE='^[[:space:]]*(import|export .* from)[[:space:]]|import\(|require\(|^[[:space:]]*///[[:space:]]*<reference'

MFE_HEADING='### The `mfe-contract/v1` contract (#1123)'
MFE_NEXT='### React bootstrap overlay — React composes onto the javascript tier (#957)'

mfe_section() {
  sed -n '/^### The .mfe-contract.v1. contract/,/^### /p' "$ARCH" | collapse
}

identity_section() {
  sed -n '/^### Identity and authorization/,/^### /p' "$ARCH" | collapse
}

typescript_pin_dockerfile() {
  sed -n 's/^ARG TYPESCRIPT_VERSION=//p' "$DOCKERFILE"
}

# --- the package is types-only ------------------------------------------------

@test "the package directory holds exactly index.d.ts, package.json and README.md outside examples/" {
  local listed
  listed="$(cd "$PKG" && find . -mindepth 1 -maxdepth 1 ! -name examples | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')"
  [ "$listed" = "README.md index.d.ts package.json " ]
  [ -d "$EXAMPLES" ]
}

@test "package.json declares types + files:[index.d.ts] and no main, exports or dependencies" {
  run jq -e '
    .types == "index.d.ts"
    and .files == ["index.d.ts"]
    and (has("main") | not)
    and (has("exports") | not)
    and (has("dependencies") | not)
    and (has("peerDependencies") | not)
    and (.version | startswith("1."))
    and .type == "module"
  ' "$PKG_JSON"
  [ "$status" -eq 0 ]
}

@test "the package is named @{{NPM_SCOPE}}/mfe-contract" {
  run jq -r .name "$PKG_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = '@{{NPM_SCOPE}}/mfe-contract' ]
}

@test "the scope rule — lowercased owner of {{PROJECT_SLUG}} — is documented with a mixed-case example" {
  local readme arch
  readme="$(collapse < "$README")"
  contains "$readme" 'the **owner** part of the GitHub `owner/repo` slug, **lowercased**'
  contains "$readme" 'The owner `Acme-Corp` of `Acme-Corp/composition` therefore publishes `@acme-corp/mfe-contract`.'
  arch="$(mfe_section)"
  contains "$arch" '`<scope>` — the template'"'"'s `{{NPM_SCOPE}}` — is the **owner** part of `{{PROJECT_SLUG}}`, **lowercased**'
  contains "$arch" 'the owner `Acme-Corp` publishes `@acme-corp/mfe-contract`'
}

@test "index.d.ts imports nothing — no vendor flag or theming SDK type can appear" {
  run grep -cE "$IMPORT_RE" "$DTS"
  [ "$output" = 0 ]
  # anti-vacuity: the pattern fires on each shape it exists to catch
  local shape
  for shape in "import type { Client } from 'flag-sdk';" "  flags: import('flag-sdk').Client;" \
    '/// <reference types="theme-sdk" />' "const sdk = require('flag-sdk');"; do
    printf '%s\n' "$shape" | grep -qE "$IMPORT_RE" || { echo "IMPORT_RE misses: $shape" >&2; return 1; }
  done
}

# --- the types ----------------------------------------------------------------

@test "index.d.ts defines every contract type" {
  local name
  for name in MfeContext PageContext WidgetContext MfeModule AuthContext GridSize WidgetManifest FlagContext; do
    grep -qE "^export interface $name( |\\{)" "$DTS" || { echo "missing interface $name" >&2; return 1; }
  done
  file_has "$DTS" 'export type ThemeTokens = Readonly<Record<string, string>>;'
}

# Every interface's WHOLE declared body, exactly — an added member, required or
# optional, fails here whatever it is called (the examples' object literals
# catch only required members of the types they build).
@test "every contract interface declares exactly its members, with kind as the discriminant" {
  pin_body() {
    local got
    got="$(interface_body "$1" | declarations_of | collapse)"
    [ "$got" = "$2" ] || { printf '%s body drifted:\n  got:  %s\n  want: %s\n' "$1" "$got" "$2" >&2; return 1; }
  }
  pin_body MfeContext 'export interface MfeContext { auth: AuthContext; flags: FlagContext; theme: ThemeTokens; signal: AbortSignal; }'
  pin_body PageContext "export interface PageContext extends MfeContext { kind: 'page'; basePath: string; onNavigate(path: string): void; }"
  pin_body WidgetContext "export interface WidgetContext extends MfeContext { kind: 'widget'; config: unknown; size: GridSize; onResize(cb: (size: GridSize) => void): () => void; }"
  pin_body MfeModule 'export interface MfeModule { mount(el: HTMLElement, ctx: PageContext | WidgetContext): void | Promise<void>; unmount(el: HTMLElement): void | Promise<void>; manifest?: WidgetManifest; }'
  pin_body GridSize 'export interface GridSize { cols: number; rows: number; }'
  pin_body WidgetManifest 'export interface WidgetManifest { id: string; contractMajor: number; configSchema: object; size: { min: GridSize; max: GridSize; default: GridSize; }; }'
  pin_body FlagContext 'export interface FlagContext { isEnabled(key: string): boolean; variant(key: string): string | undefined; }'
}

# --- decision 1: AuthContext ----------------------------------------------------

@test "AuthContext: async token accessor, display-only claims, no token field, no roles or permissions" {
  local auth claims all
  # The WHOLE declared bodies, exactly: any added member — a `jwt` field, a
  # `hasPermission()` check — fails here whatever it is called.
  auth="$(interface_body AuthContext | declarations_of | collapse)"
  claims="$(interface_body AuthClaims | declarations_of | collapse)"
  [ "$auth" = 'export interface AuthContext { getAccessToken(): Promise<string>; readonly claims: AuthClaims; }' ]
  [ "$claims" = 'export interface AuthClaims { readonly sub: string; readonly displayName: string; readonly tenantId: string; }' ]
  # Negative pins over every DECLARATION in the file (comments stripped): the
  # doc comment legitimately says "no token field" and "no role or permission".
  all="$(declarations)"
  run matches "$all" "$ROLE_MEMBER_RE"
  [ "$status" -eq 1 ]
  run matches "$all" "$TOKEN_MEMBER_RE"
  [ "$status" -eq 1 ]
}

@test "the negative pins' detectors FIRE on a declaration that breaks them (anti-vacuity)" {
  local decl
  for decl in '  readonly roles: string[];' '  userRoles?: readonly string[];' \
    '  readonly roles: string[]; /* legacy */' $'  // see /*\n  readonly roles: string[];\n  /** x */'; do
    run matches "$(printf '%s\n' "$decl" | declarations_of)" "$ROLE_MEMBER_RE"
    [ "$status" -eq 0 ] || { echo "ROLE_MEMBER_RE misses: $decl" >&2; return 1; }
  done
  for decl in '  accessToken?: string;' '  sessionToken: string;' '  jwt: string;'; do
    run matches "$(printf '%s\n' "$decl" | declarations_of)" "$TOKEN_MEMBER_RE"
    [ "$status" -eq 0 ] || { echo "TOKEN_MEMBER_RE misses: $decl" >&2; return 1; }
  done
}

@test "AuthContext's doc comment cites the identity position (#1186) and its three rules" {
  local doc
  doc="$(doc_of AuthContext)"
  contains "$doc" 'ARCHITECTURE.md'
  contains "$doc" '#1186'
  contains "$doc" 'The shell owns auth acquisition for the whole page (#1326)'
  contains "$doc" 'holds the token in memory only'
  contains "$doc" 'No claim here drives a client-side authorization decision'
}

# --- decisions 2 and 3: abort rule, manifest export ------------------------------

@test "MfeModule's doc comment states the abort rule and its rationale" {
  local doc
  doc="$(doc_of MfeModule)"
  contains "$doc" 'The module'"'"'s namespace IS the `MfeModule`: `mount`, `unmount` and, for a widget, `manifest` are named exports, and the shell reads them from the imported module itself — never from a default export.'
  contains "$doc" 'The shell ALWAYS calls `unmount(el)` after any `mount` attempt'
  contains "$doc" 'whether that mount resolved, rejected, or was aborted through `ctx.signal`'
  contains "$doc" 'and it calls it once that `mount` has settled'
  contains "$doc" '`unmount` must be idempotent and safe on a partial mount'
  contains "$doc" '`mount` must stop its work and settle once it observes the abort'
  contains "$doc" 'has still attached DOM and subscriptions'
}

@test "MfeModule.manifest's doc comment records the module-export decision and its rationale" {
  local body
  body="$(interface_body MfeModule | strip_jsdoc | collapse)"
  contains "$body" 'published as a module export'
  contains "$body" 'there is no second artifact that can drift'
  contains "$body" 'a gallery loads each widget'"'"'s entry module to read its manifest'
  contains "$body" 'evaluating it has no side effect beyond defining its exports'
}

@test "README documents the semver major as the shell↔remote compatibility boundary" {
  local readme
  readme="$(collapse < "$README")"
  contains "$readme" 'The package'"'"'s semver **major** is the `v1` in `mfe-contract/v1`, and it is the compatibility boundary between a shell and the remotes it can load.'
  contains "$readme" 'A **shell** declares the major it implements'
  contains "$readme" 'A **remote** declares the major it targets'
  contains "$readme" '`WidgetManifest.contractMajor`'
  contains "$readme" '**Adding an optional member** is a **minor** bump'
  contains "$readme" '**Adding a required member, or narrowing a type**, is a **major** bump'
  contains "$readme" 'So is **any other change to a declared type** — removing a member, widening a type, adding a `kind`. Only an added optional member is minor.'
  contains "$readme" 'A shell and a remote on different majors are incompatible.'
  contains "$readme" 'No build sees both dependency ranges, so for a page the two majors are compared by conformance (#1126) — until that lands, nothing compares them.'
  contains "$readme" 'A gallery refuses a widget whose `contractMajor` it does not implement.'
}

@test "README states the three contract rules" {
  local readme
  readme="$(collapse < "$README")"
  contains "$readme" 'as **named** exports. The module'"'"'s namespace is the `MfeModule`; a default export is never read.'
  contains "$readme" '1. **Identity.** `AuthContext` has an async `getAccessToken()` and display-only claims (`sub`, `displayName`, `tenantId`). It has no token field and no roles or permissions.'
  contains "$readme" '2. **Abort.** The shell always calls `unmount(el)` after any `mount` attempt, whether it settled, rejected or was aborted through `ctx.signal`, and it calls it once that `mount` has settled. `unmount` must be idempotent and safe on a partial mount, and `mount` must stop its work and settle once it observes the abort.'
  contains "$readme" '3. **Manifest.** A widget publishes its manifest as the `manifest` export, and evaluating an entry module has no side effect beyond defining its exports.'
}

# --- the compiler's verdict ----------------------------------------------------

@test "the tsc on PATH is the exact version both rosters pin" {
  local pin
  pin="$(typescript_pin_dockerfile)"
  matches "$pin" '^[0-9]+\.[0-9]+\.[0-9]+$'
  # every workflow leg that installs tsc pins exactly this version: as many
  # literal `TYPESCRIPT_VERSION: <pin>` env lines as install lines, and no env
  # line naming anything else
  local installs pinned envs
  installs="$(grep -cF 'typescript@${TYPESCRIPT_VERSION}' "$WORKFLOW")"
  pinned="$(awk -v p="$pin" '$1 == "TYPESCRIPT_VERSION:" && $2 == p' "$WORKFLOW" | wc -l | tr -d ' ')"
  envs="$(awk '$1 == "TYPESCRIPT_VERSION:"' "$WORKFLOW" | wc -l | tr -d ' ')"
  [ "$installs" -ge 1 ]
  [ "$pinned" -eq "$installs" ]
  [ "$envs" -eq "$pinned" ]
  # both rosters say why the dependency exists
  file_has "$DOCKERFILE" 'tests/mfe-contract.bats'
  file_has "$WORKFLOW" 'tests/mfe-contract.bats'
  run tsc --version
  [ "$status" -eq 0 ]
  [ "$output" = "Version $pin" ]
}

@test "the worked examples type-check with tsc --noEmit --strict, index.d.ts included" {
  # every example is in the checked set, and skipLibCheck would stop tsc
  # checking index.d.ts itself
  run jq -e '.include == ["*.ts"] and (has("exclude") | not) and (has("files") | not)
    and (.compilerOptions | has("skipLibCheck") | not)' "$EXAMPLES/tsconfig.json"
  [ "$status" -eq 0 ]
  run tsc -p "$EXAMPLES" --noEmit --strict
  [ "$status" -eq 0 ]
}

# Line number of the first line of FILE containing the literal NEEDLE.
line_of() {
  awk -v needle="$2" 'index($0, needle) { print NR; exit }' "$1"
}

@test "the worked shell unmounts on every path: rejected, aborted in flight, and settled" {
  local shell
  shell="$(collapse < "$EXAMPLES/shell.ts")"
  # a rejected mount unmounts at once
  contains "$shell" '.then(() => remote.mount(el, ctx)) .catch(async (err: unknown) => { await unmountOnce(); throw err; });'
  # teardown exists before the mount settles, and aborts, waits, then unmounts
  contains "$shell" 'const teardown = async () => { controller.abort(); await settled.catch(() => {}); await unmountOnce(); };'
  contains "$shell" 'return { settled, teardown };'
  # at most once, and a synchronous throw is recorded before it happens
  contains "$shell" 'const unmountOnce = () => (unmounted ??= Promise.resolve().then(() => remote.unmount(el)));'
  # both context builders hand the remote the signal teardown aborts
  [ "$(grep -c 'signal: controller.signal' "$EXAMPLES/shell.ts")" -eq 2 ]
  # ...and hand attempt() that same controller, so teardown aborts that signal
  [ "$(grep -cE 'return attempt\(remote, (outlet|slot), ctx, controller\);' "$EXAMPLES/shell.ts")" -eq 2 ]
  # a widget targeting another major is refused before anything mounts
  contains "$shell" "if (!manifest || manifest.contractMajor !== 1) { throw new Error('not a mfe-contract/v1 widget'); }"
  [ "$(line_of "$EXAMPLES/shell.ts" 'manifest.contractMajor !== 1')" -lt "$(line_of "$EXAMPLES/shell.ts" 'return attempt(remote, slot')" ]
  # each remote's module NAMESPACE is its MfeModule — named exports, no default
  contains "$shell" 'export const workedRemotes: MfeModule[] = [ordersPage, ordersSummary];'
}

@test "the worked remotes narrow on ctx.kind, register cleanup before their first await, and honour the abort" {
  local f
  file_has "$EXAMPLES/page-remote.ts" "if (ctx.kind !== 'page')"
  file_has "$EXAMPLES/page-remote.ts" 'ctx.onNavigate('
  file_has "$EXAMPLES/widget-remote.ts" "if (ctx.kind !== 'widget')"
  file_has "$EXAMPLES/widget-remote.ts" 'ctx.onResize('
  # manifest is optional on MfeModule, so the namespace check cannot see it go
  file_has "$EXAMPLES/widget-remote.ts" 'export const manifest: WidgetManifest = {'
  for f in "$EXAMPLES/page-remote.ts" "$EXAMPLES/widget-remote.ts"; do
    # the abort is checked straight after the first await, and the fetch is
    # handed the signal, so an aborted mount stops rather than renders
    contains "$(collapse < "$f")" 'await ctx.auth.getAccessToken(); if (ctx.signal.aborted) return;'
    file_has "$f" 'signal: ctx.signal,'
    # unmount is idempotent and safe on a partial mount
    file_has "$f" 'cleanups.get(el)?.();'
    file_has "$f" 'cleanups.delete(el);'
    # cleanup is registered BEFORE the first await, so an aborted mount is
    # still fully unmountable
    [ "$(line_of "$f" 'cleanups.set(el')" -lt "$(line_of "$f" 'await ')" ]
  done
}

@test "the non-conforming remote's pins are load-bearing: stripped, tsc fails once per pin" {
  local copy pins errors
  copy="$BATS_TEST_TMPDIR/mfe-contract"
  cp -R "$PKG" "$copy"
  pins="$(grep -cE "$EXPECT_ERROR_RE" "$NON_CONFORMING")"
  # the exact roster: no unmount, two unnarrowed members, roles, permissions,
  # a token field, a sync token, a sizeless manifest, an unadmitted kind
  [ "$pins" -eq 9 ]
  grep -vE "$EXPECT_ERROR_RE" "$NON_CONFORMING" > "$copy/examples/non-conforming-remote.ts"
  run tsc -p "$copy/examples" --noEmit --strict
  [ "$status" -ne 0 ]
  # every error is in the non-conforming file, and there is one per stripped pin
  errors="$(printf '%s\n' "$output" | grep -c 'error TS')"
  [ "$errors" -eq "$pins" ]
  [ "$(printf '%s\n' "$output" | grep 'error TS' | grep -vc 'non-conforming-remote.ts')" -eq 0 ]
}

# --- the record -----------------------------------------------------------------

@test "ARCHITECTURE.md has the mfe-contract/v1 section, bounded by the heading that follows it" {
  local section
  file_has "$ARCH" "$MFE_HEADING"
  section="$(mfe_section)"
  [ -n "$section" ]
  starts_with "$section" "$MFE_HEADING"
  ends_with "$section" "$MFE_NEXT"
  contains "$section" 'This section is the **normative home** of the shell↔remote mount contract'
}

@test "the section states the types, the three decisions, the scope rule and the versioning rule" {
  local section
  section="$(mfe_section)"
  # the types — every member the index.d.ts tests pin, so the normative text
  # and the published types cannot drift apart unnoticed
  contains "$section" 'interface MfeModule { mount(el: HTMLElement, ctx: PageContext | WidgetContext): void | Promise<void>; unmount(el: HTMLElement): void | Promise<void>; manifest?: WidgetManifest; // widgets only }'
  contains "$section" 'interface MfeContext { auth: AuthContext; flags: FlagContext; theme: ThemeTokens; signal: AbortSignal }'
  contains "$section" "interface PageContext extends MfeContext { kind: 'page'; basePath: string; onNavigate(path: string): void }"
  contains "$section" "interface WidgetContext extends MfeContext { kind: 'widget'; config: unknown; // host-validated against manifest.configSchema, opaque to the host size: GridSize; onResize(cb: (size: GridSize) => void): () => void; // returns the unsubscribe function }"
  contains "$section" 'interface GridSize { cols: number; rows: number }'
  contains "$section" 'interface WidgetManifest { id: string; contractMajor: number; configSchema: object; // configSchema is a JSON Schema size: { min: GridSize; max: GridSize; default: GridSize }; }'
  contains "$section" 'interface FlagContext { isEnabled(key: string): boolean; variant(key: string): string | undefined }'
  contains "$section" 'type ThemeTokens = Readonly<Record<string, string>>;'
  contains "$section" 'interface AuthContext { getAccessToken(): Promise<string>; readonly claims: AuthClaims }'
  contains "$section" 'interface AuthClaims { readonly sub: string; readonly displayName: string; readonly tenantId: string }'
  # the artifact, with its rationale
  contains "$section" 'with no `main`, no runtime `exports` and no `dependencies`'
  contains "$section" 'types-only keeps it a build-time dependency'
  # the three decisions, each with its rationale
  contains "$section" 'a remote'"'"'s entry-module **namespace** is its `MfeModule`: `mount`, `unmount` and a widget'"'"'s `manifest` are **named** exports, read from what `import()` resolves to, never from a default export.'
  contains "$section" '**The three decisions.**'
  contains "$section" 'and no token field, no roles and no permissions.**'
  contains "$section" 'Claims are the server'"'"'s authorization input and never drive a client-side authorization decision'
  contains "$section" '**The shell always calls `unmount(el)` after any `mount` attempt**'
  contains "$section" 'and it calls it once that `mount` has settled.'
  contains "$section" '`mount` must stop its work and settle once it observes the abort.'
  contains "$section" 'a mount that never completed has still attached DOM and subscriptions'
  contains "$section" '**A widget'"'"'s manifest is published as a module export, `MfeModule.manifest`.**'
  contains "$section" 'evaluating it has no side effect beyond defining its exports'
  # the two rules, and what the section leaves to other children
  contains "$section" '**The scope-derivation rule.**'
  contains "$section" '**The versioning rule.**'
  contains "$section" 'Adding an **optional** member is a **minor** bump; adding a **required** member or **narrowing** a type is a **major** bump, and so is **any other change to a declared type**'
  contains "$section" 'Only an added optional member is minor.'
  contains "$section" '**What this section does not build.**'
}

@test "the section links the template path and the design doc, and both resolve" {
  local section
  section="$(mfe_section)"
  contains "$section" "(${PKG#"$REPO_ROOT/"}/)"
  [ -d "$PKG" ]
  contains "$section" "(${MFE_SPEC#"$REPO_ROOT/"})"
  [ -f "$MFE_SPEC" ]
}

@test "the identity position's #1326 bullet points at the section and still cites the design doc" {
  local section
  section="$(identity_section)"
  contains "$section" '**#1326** — the SPA shell owns session and auth acquisition'
  # the heading text, from the SAME constant the section test pins
  contains "$section" "*${MFE_HEADING#'### '}* section above"
  contains "$section" "${MFE_SPEC#"$REPO_ROOT/"}"
}
