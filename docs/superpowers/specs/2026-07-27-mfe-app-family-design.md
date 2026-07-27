# Micro-frontend app family — design

Supersedes §2 of `2026-07-10-webui-plugin-family-design.md`, which treated
Angular and React as co-equal whole-app frameworks and named Module Federation
as the blessed micro-frontend mechanism. Both positions are reversed here.

## 1. Context and goals

The plugin family serves backend repos well. Its WebUI story was designed
before the target platform shape was settled, and drifted: the earlier design
mirrored the `development-java` + `development-spring` layering onto
`development-javascript` + `development-angular` / `development-react`, which
quietly assumed that a browser UI is *one app built with one framework*.

That assumption no longer holds. The default UI shape is a SPA shell whose
content is split across independently deployable micro-frontends. Once that is
true, the framework question stops being "which of two frameworks does this app
use" and becomes "what contract does the shell use to load a remote" — a
different question with different consequences.

This design settles that contract, states the positions it rests on, and records
what happens to the issues written against the superseded ones.

**Goals.** One blessed UI composition contract, enforceable mechanically. UI
deployables that obey the same polyrepo rules as backend deployables. No new
pinning or promotion machinery where existing machinery already works.

**Non-goals.** Server-side rendering. Cross-MFE shared runtime state beyond the
context the shell passes in. Angular tooling (see §2.2).

## 2. The family position

These are this family's own positions, stated with their rationale so a reader
can disagree with them explicitly.

### 2.1 Every browser UI is a SPA shell; substantial UI splits into micro-frontends in one of two shapes

The shell owns the outer route table, the application chrome, and session and
auth acquisition. A micro-frontend then takes one of exactly two shapes:

- **Route-owned page** — owns a route subtree end-to-end and runs its own nested
  router beneath it. **This is the default**: it is the shape with the smallest
  host↔remote surface, and the one to reach for unless the product genuinely
  needs the other.
- **Canvas widget** — occupies a slot on a host-owned canvas that the user
  arranges. It owns no route, carries per-instance configuration, and has a size
  the user can change.

Both shapes use the same contract (§3). A slot is an element, so the canvas
imports a widget's module and calls `mount(el, ctx)` exactly as a router does
for a page; the widget shape adds fields to the context rather than a second
mechanism.

*Rationale.* This makes the UI obey the same rule as the backend: one deployable
per bounded context, independently releasable, held together by a contract
rather than by a coordinated release. `ARCHITECTURE.md` already names "micro-UI"
as a first-class deployable artifact; this makes that real rather than
aspirational.

Two shapes rather than one is a deliberate exception to the family's
one-good-default preference, and it is earned: a dashboard the user composes
from a widget gallery is a real product shape that route ownership cannot
express — a widget has no URL to own. Collapsing it into route ownership would
either forbid the product or force widgets to fake routes they do not have. The
cost is contained because the two shapes share a mechanism and differ only in
what the context carries; a third shape would not get the same welcome.

### 2.2 React + TypeScript is the default for any browser UI

Angular is not scaffolded. An existing Angular asset may participate by
exporting the same contract (§3), but the family builds no Angular-specific
tooling until such an asset actually exists.

*Rationale.* One framework, one blessed path — the family's standing preference
for a single good default over a menu. A second framework's tooling (templates,
review panel, upgrade agent) is speculative cost until something real needs it;
the contract in §3 is framework-agnostic at the boundary, so admitting Angular
later costs a plugin, not a redesign.

### 2.3 The MFE contract is an exported mount function over an import-map-resolved ES module

A remote's entry module exports `mount(el, ctx)` and `unmount(el)`. The shell
resolves the module through an import map and calls it. Module Federation is
explicitly rejected.

*Rationale.* What federation adds is a build plugin, a runtime container
protocol, and a shared-scope negotiation whose misconfiguration surfaces at
runtime rather than at build. What it buys is deduplication of shared
dependencies — and how much that is worth depends entirely on the shape.

**Under route ownership it is worth little.** One remote is mounted at a time,
so the duplication costs roughly one framework runtime per route transition,
from an immutable bundle that caches indefinitely.

**Under the canvas shape it is worth a great deal**, and this is the case that
nearly falsified this position: a dashboard mounts many widgets *concurrently*,
so N widget types shipping their own framework copy is N runtimes in one
document, paid on first paint. That is a real cost, not a rounding error.

It does not rescue federation, because **import maps already solve it natively**.
A widget builds with the framework as an external, the import map pins exactly
one framework URL, and every widget resolves to it — dependency sharing with no
container protocol, no negotiation, and no plugin. The trade is explicit and
visible in one file: shared dependencies are pinned in the import map, and
everything a widget wants to upgrade independently simply stays bundled. That is
the same trade federation makes, made declaratively and inspected in one place
instead of negotiated at runtime.

So we reject federation as unearned complexity for both shapes, **not** as
forced coupling — a distinction worth stating precisely, because the sloppier
version of this argument is wrong. Modern federation can be configured to share
nothing and to interoperate across bundlers, so it does not *inherently* stop a
remote upgrading on its own schedule. But a mechanism whose one real benefit we
can obtain from the module loader we are already using is one we should not
adopt.

## 3. The contract — `mfe-contract/v1`

Published as a **types-only** npm package, `@org/mfe-contract`. Types-only keeps
it a build-time dependency, so it satisfies the rule that no repo depends on
another repo while still giving both sides one definition to compile against.

```ts
/** Given to every micro-frontend, whichever shape it takes. */
export interface MfeContext {
  /** Identity and a token accessor. Never a raw long-lived secret. */
  auth: AuthContext;
  /** Feature-flag evaluation. A capability, not a named vendor SDK. */
  flags: FlagContext;
  /** Tenant theme tokens, so a remote is white-labelled without a rebuild. */
  theme: ThemeTokens;
  /** The shell cancels an in-flight mount (route or slot changed during load). */
  signal: AbortSignal;
}

/** A route-owned page additionally receives its route delegation. */
export interface PageContext extends MfeContext {
  /** Route prefix the shell has delegated; the remote's router mounts here. */
  basePath: string;
  /** The remote asks the shell to change the outer URL. */
  onNavigate(path: string): void;
}

/** A canvas widget additionally receives its instance state. */
export interface WidgetContext extends MfeContext {
  /** This instance's saved configuration, already validated by the host
      against the manifest's schema. Opaque to the host otherwise. */
  config: unknown;
  /** Current size in grid units — semantic, not pixels. */
  size: GridSize;
  /** Called when the user resizes the widget. Pixels are the widget's own
      business (observe the container); this reports GRID units, which cannot
      be derived from pixels on a responsive grid. */
  onResize(cb: (size: GridSize) => void): () => void;
}

/** The shape a remote's entry module must satisfy. */
export interface MfeModule {
  mount(el: HTMLElement, ctx: PageContext | WidgetContext): void | Promise<void>;
  unmount(el: HTMLElement): void | Promise<void>;
  /** Widgets only: declared before load, so a gallery can list and validate
      an instance without mounting it. */
  manifest?: WidgetManifest;
}
```

**Feature flags and theming are capabilities, not vendors.** `FlagContext` and
`ThemeTokens` are declared as interfaces the host satisfies, so the contract
never pins a specific flag SDK or theming implementation. Both are platform-wide
guarantees — a remote that cannot evaluate a flag cannot honour entitlements,
and one that cannot read theme tokens cannot be white-labelled — so leaving them
out would force every remote to reach for a global, which is exactly the
coupling this contract exists to prevent.

Three details this sketch deliberately leaves to #1123, because they need their
own acceptance criteria rather than a design-doc assertion: the exact shape of
`AuthContext` (what identity claims are exposed, and whether the token accessor
is sync or async); the precise semantics a remote must honour when `signal`
aborts mid-mount — specifically whether `unmount` is still called for a mount
that never completed; and **where a widget's manifest is published**. The last
one is a genuine trade-off rather than an oversight: publishing it as a module
export keeps it in lockstep with the code but forces a gallery to load every
widget's module just to render a catalog, while publishing it as catalog
metadata lists cheaply but can drift from the module it describes. Which wins
depends on how the catalog is served, so #1123 decides it.

### 3.1 The widget half of the contract

A widget carries state a page does not. These are decided here:

- **Configuration is host-validated, widget-opaque.** A widget declares a config
  schema in its manifest; the host validates a saved instance against it and
  passes it as `config`. The host never interprets the contents. This keeps
  invalid configuration from reaching a widget at all, and keeps the host from
  needing to understand any widget's domain.
- **Size is declared as constraints, not a fixed value.** The manifest declares
  minimum, maximum and default extent in grid units. The user may resize within
  those bounds, so the declared value bounds the instance rather than fixing it.
- **Responsiveness splits by unit.** Pixels are the widget's own business — it
  observes its container, and the contract carries no pixel dimensions. Grid
  units *are* in the contract, because on a responsive grid they cannot be
  derived from pixels, and a widget legitimately renders differently at 1×1
  versus 4×2 regardless of the pixels either happens to occupy.
- **Resize does not remount; reconfiguration does.** Resizing is continuous and
  user-driven, so remounting on it would destroy widget state and flicker on
  every drag step — hence `onResize`. Changing configuration is discrete,
  deliberate and rare, so it remounts, which keeps the contract at two functions
  instead of adding an `update` path with its own lifecycle rules. If a real
  widget proves remount-on-reconfigure unacceptable, an `update` call is the
  documented next step — but it must earn its place.

**Why a function boundary rather than a custom element.** The shell must hand
each remote real context — session, flags, theme, and then either route
delegation or instance configuration and size. Custom elements carry that less
directly: attributes are strings, so anything structured travels by property
assignment or `CustomEvent`. That is workable and can be typed, but it is
hand-rolled per element rather than falling out of a signature — and the widget
shape makes the payload larger, not smaller, so the gap widens rather than
narrows. The decisive objection is different and unavoidable:
`customElements.define` is a process-global registration that throws on a
duplicate tag name, so a host loading two versions of the same remote — which a
rollout permits in either shape — is a hard failure rather than a graceful one.

The cost, stated plainly: this is a family convention rather than a web
standard, so the family owns documenting and versioning it. The `v1` in the
package name is what makes that cost bounded.

**Contract versioning.** The major version of `@org/mfe-contract` is the
compatibility boundary between a shell and the remotes it can load. A shell
declares the major it implements; a remote declares the major it targets. A
mismatch is a conformance failure (§6), not a runtime surprise.

## 4. Repo shapes

Bootstrap scaffolds two shapes. Both are React + TypeScript, and both follow the
family's standing rule that **bootstrap augments an existing repo and never
scaffolds an app from zero** — the documented entry point remains
`npm create vite@latest`, with the family's configuration layered on top.

### 4.1 Shell

The SPA. Owns the outer router, the chrome, auth acquisition, the import map,
and the remote loader that resolves a route to a module and calls `mount`.

A shell that hosts canvas widgets additionally owns the **canvas**: the
responsive grid, drag-and-drop placement, resize within each widget's declared
bounds, and persistence of the instances and their layout. That persistence is
the host application's concern, not the contract's — the contract only hands a
widget its already-validated configuration and current size.

A plain standalone SPA is simply a shell with zero remotes. There is
deliberately no third archetype: the same template tree serves all of these, so
the "small app" case costs no extra machinery and can grow remotes without a
rewrite.

### 4.2 Remote (micro-UI)

A React app whose entry module exports the contract, built into a container that
serves its own immutable, content-hashed assets. In its **page** shape it runs a
nested router beneath the `basePath` the shell passes and delegates outward
navigation through `onNavigate`. In its **widget** shape it owns no route, reads
its instance configuration from the context, and adapts to the grid size it is
given — publishing a manifest so a gallery can list and validate it before it is
ever mounted.

### 4.3 Container path

Both shapes build to a **static asset bundle with no Node process at runtime**,
so the blessed Node service container image is the wrong base for them. The
canonical UI container is an asset server behind a gateway path. This is why
`#1062` (canonical container path for bootstrapped Node repos) must cover the
static-asset case, not only the Node service case.

## 5. Pinning and composition — one pin, not two

The import map maps a bare specifier to a **stable gateway path**:

```text
"orders-ui"  ->  /ui/orders/remote.js
```

Which build sits behind that path is decided by the **container image tag pinned
in the composition repo's `.claude-workspace.yaml`**, exactly as for a backend
member.

*Rationale.* The alternative — pinning an immutable versioned CDN URL in the
import map — introduces a second version pin that must be kept in step with the
image tag, with no mechanism keeping them honest. Reusing the image tag means
the existing machinery already governs UI versioning: workspace pinning,
Renovate tag bumps, and the promotion flow, all unchanged. The asset server is
responsible for serving content-hashed assets behind that stable entry path so
cache correctness does not depend on the entry URL changing.

**Shared dependencies keep the one-pin rule.** §2.3 has the import map pin a
single framework URL so concurrently-mounted widgets do not each ship their own
copy. That URL must be served by *something* pinned, or it reintroduces exactly
the second version pin this section rejects. **The shell serves it**: shared
dependencies are assets of the shell's own container, so their version is the
shell's image tag, already pinned in `.claude-workspace.yaml` like any other
member. One pin, still. The consequence is worth stating plainly — upgrading a
shared framework is a *shell* release that every widget resolving to it takes at
once, which is the coordinated part of the trade and the reason to share as few
dependencies as possible.

**Live-version assertion.** UI members expose the `ops-api` `/info` surface like
any other member, so a composition E2E can assert *which MFE versions are
actually live* in an environment — the same assertion it already makes of
backends.

## 6. Conformance

Mechanically checkable, mirroring the shipped `check-ops-conformance.zsh`:

- the built bundle's entry module exports `mount` and `unmount`, with the
  expected arity;
- the remote declares an `@org/mfe-contract` major the shell supports;
- the container serves that entry at its gateway path.

A contract nothing checks is a contract that drifts. This is what makes §3
enforceable rather than documentation.

## 7. Considered and rejected

**Module Federation (`@module-federation/vite`).** Rejected per §2.3 as unearned
complexity, because its one real benefit is available from the module loader we
already use. Under route ownership one remote is mounted at a time, so the
shared runtime it deduplicates saves little. Under the canvas shape many widgets
mount concurrently and the saving is genuinely large — but an import map pins a
single shared framework URL and obtains it natively, with no plugin, no
container protocol, and no shared-scope negotiation that fails at runtime rather
than at build. Note what this argument does *not* claim: modern federation can
be configured to share nothing and to interoperate across bundlers, so it does
not inherently prevent a remote from upgrading on its own schedule. It is
rejected because we can already get what it offers, not because it forces
coupling.

**Custom elements + import maps.** A genuine contender, and the standards-based
option. Rejected because `customElements.define` is a process-global
registration that throws on a duplicate tag name, making two live versions of a
remote a hard failure; the context-passing ergonomics are a secondary cost.
Retained as the natural answer *if* the family ever needs to embed into host
pages it does not control — that would be a new position, filed as such.

*Re-examined when §2.1 widened to canvas widgets (#1134), since widgets are the
shape custom elements suit best.* The re-examination cuts both ways and is worth
stating rather than glossing. **For them:** a widget is component-shaped, and
declarative placement in markup reads more naturally than an imperative mount
call. **Against them:** the widget context is *larger* than a page's — flags,
theme, validated configuration and grid size on top of the session — and every
one of those travels worse through attributes and properties than through a
typed argument, so the ergonomic gap widens exactly where widgets live. The
decisive objection is untouched by the widening: duplicate registration is a
hard failure in either shape. Net, the case against is stronger for widgets than
it was for pages, not weaker.

**Build-time composition via npm packages.** Simplest toolchain and best type
safety, but the shell must rebuild and redeploy for any remote change. That is a
coordinated release across repos, which `ARCHITECTURE.md` classifies as not
stable. Rejected.

**Server-side / edge composition.** Adds a runtime composition component and an
SSR story the family does not otherwise need. Rejected as unnecessary for a SPA
shell.

**CDN-pinned versioned bundles.** Rejected per §5: a second version pin with
nothing enforcing agreement with the image tag.

## 8. Issue disposition

### Closed — the position no longer supports them

| Issues | Reason |
| --- | --- |
| #685, #1037–#1042 | Angular deferred; nothing scaffolds Angular (§2.2). |
| #1043, #1049–#1057 | A framework recommender is dead weight when one framework is supported. |
| #954 | Module Federation framing; a rewrite would retain nothing (§7). |

### Rewritten

| Issue | Change |
| --- | --- |
| #1059 | Becomes the position issue for §2 — SPA shell + route-owned MFEs, React default, mount contract — into `ARCHITECTURE.md` and spec §2, each with rationale. |
| #957 | Retitled off "blessed Vite SPA app repo" to the **common React overlay**. Its content (jsdom test pyramid, testing-library setup, hooks ESLint overlay, compose-don't-clobber layering) is shape-neutral and survives; shape-specific templates move to A2/A3. |
| #1062 | Extended to cover the static-asset container serving a shell or remote at its gateway path (§4.3). |
| #960 | Its "duplicated into Angular later" out-of-scope note is moot. |

### Unchanged

These are orthogonal to the composition mechanism and carry over untouched:

- React plugin capabilities — #958, #959
- API lifecycle and ops tail — #687, #689, #936, #937, #944
- Supporting machinery — #702, #1063, #1071, #1072

Of those, #687, #689 and #936 are ready to build as they stand.

## 9. Epic structure and sequencing

**#682 is rescoped, not closed.** Its four closed children — #683 (JavaScript
foundation), #684 (API lifecycle), #688 (ops surface), #935 (Java ops-api) — are
exactly the non-UI foundation, which is what it actually delivered. It is
retitled to that scope and keeps #687, #689, #936, #937, #944. The UI work moves
out.

**#686 (`development-react` topic plugin) keeps its scope but changes position** —
detached from #682, it is now a standalone top-level epic — with #957
(rescoped), plus #958, #959 and #960. Its children concern the React plugin's
capabilities, which are orthogonal to how MFEs compose.

**A new epic — MFE composition (#1122)** — holds the new domain. Filed
2026-07-27:

| Child | Scope |
| --- | --- |
| #1134 | **Correction** — widen §2.1 to canvas widgets; add flags, theme, config and size to the context. Blocks the three below. |
| #1123 | `mfe-contract/v1` — signature, the context types, the widget manifest, the types-only package, versioning rules |
| #1124 | Shell repo shape — outer router, chrome, auth acquisition, remote loader, import-map injection, and the widget canvas |
| #1125 | Remote repo shape — mount/unmount entry, page and widget shapes, asset container |
| #1126 | `check-mfe-conformance.zsh` + CI gate (§6) |
| #1127 | Bootstrap shape question — "browser UI? shell or remote?" (the surviving part of #1043) |
| #1128 | Composition-repo UI integration — gateway routes, import map as the single pin, cross-MFE E2E, `/info` live-version assertions |

```text
#1059 ──┐
        ├─→ #1123 (contract) ──┬─→ #1124 (shell + canvas) ──┐
#1134 ──┘                      └─→ #1125 (remote)  ─────────┼─→ #1126 (conformance)
  (correction — also blocks                                 └─→ #1128 (UI integration) ←── #687
   #1124 and #1125 directly)
#1127 (bootstrap shape question) — no blockers
```

Issue #1059 lands first: it is the position the rest rests on. The contract
(#1123) follows, since both repo shapes compile against it. The shell (#1124)
and remote (#1125) are independent of each other, and both also wait on #957
(the common React overlay they layer onto). Conformance (#1126) waits on the
contract and both shapes; UI integration (#1128) waits on both shapes and
additionally on #687. The bootstrap shape question (#1127) carries no blockers
at all — it selects a shape rather than rendering one, so it can start
immediately.
