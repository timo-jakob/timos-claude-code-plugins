# @{{NPM_SCOPE}}/mfe-contract — `mfe-contract/v1`

The shell↔remote mount contract for micro-frontends, as a **types-only** package.
A SPA shell and every remote it loads compile against the same `index.d.ts`, so a
shell can load a remote it was not built with, and a remote can redeploy without
the shell changing.

The normative statement of this contract is the `mfe-contract/v1` section of the
family's
[ARCHITECTURE.md](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md).
This README covers what a consumer needs to use the package.

## What it ships

`index.d.ts`, and nothing else at install time. There is no runtime code, so the
package is a build-time dependency only: depending on it never makes one repo
depend on another at runtime.

- `MfeModule` — what a remote's entry module exports: `mount(el, ctx)`,
  `unmount(el)` and, for a widget, `manifest`, as **named** exports. The
  module's namespace is the `MfeModule`; a default export is never read.
- `PageContext` (`kind: 'page'`) and `WidgetContext` (`kind: 'widget'`), both
  extending `MfeContext` (`auth`, `flags`, `theme`, `signal`). Narrow `ctx` on
  `ctx.kind`; no cast is needed.
- `AuthContext` (with its `AuthClaims`), `FlagContext`, `ThemeTokens`,
  `GridSize` and `WidgetManifest`.

Three rules are part of the contract, not advice. `index.d.ts` states each one,
with its rationale, on the type it governs:

1. **Identity.** `AuthContext` has an async `getAccessToken()` and display-only
   claims (`sub`, `displayName`, `tenantId`). It has no token field and no roles
   or permissions.
2. **Abort.** The shell always calls `unmount(el)` after any `mount` attempt,
   whether it settled, rejected or was aborted through `ctx.signal`, and it
   calls it once that `mount` has settled. `unmount` must be idempotent and safe
   on a partial mount, and `mount` must stop its work and settle once it
   observes the abort.
3. **Manifest.** A widget publishes its manifest as the `manifest` export, and
   evaluating an entry module has no side effect beyond defining its exports.

## Package name

The package is named `@<scope>/mfe-contract`, where `<scope>` is the **owner**
part of the GitHub `owner/repo` slug, **lowercased** — npm scopes are lowercase
only. The owner `Acme-Corp` of `Acme-Corp/composition` therefore publishes
`@acme-corp/mfe-contract`.

## Versioning

The package's semver **major** is the `v1` in `mfe-contract/v1`, and it is the
compatibility boundary between a shell and the remotes it can load.

- A **shell** declares the major it implements, as its dependency range on this
  package (`^1`).
- A **remote** declares the major it targets the same way. A widget also states
  it at runtime as `WidgetManifest.contractMajor`, so a gallery can refuse an
  incompatible widget before mounting it.
- **Adding an optional member** is a **minor** bump: every existing shell and
  remote still satisfies the contract.
- **Adding a required member, or narrowing a type**, is a **major** bump: it
  breaks code that compiled against the previous major. So is **any other
  change to a declared type** — removing a member, widening a type, adding a
  `kind`. Only an added optional member is minor.
- A shell and a remote on different majors are incompatible. No build sees
  both dependency ranges, so for a page the two majors are compared by
  conformance (#1126) — until that lands, nothing compares them. A gallery
  refuses a widget whose `contractMajor` it does not implement.

## Examples

`examples/` holds a worked shell, a page remote and a widget remote, plus a
deliberately non-conforming remote whose errors are pinned with
`// @ts-expect-error`. They are type-checked with `tsc --noEmit --strict` and are
not published.
