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

### 2.1 Every browser UI is a SPA shell; substantial UI splits into route-owned micro-frontends

The shell owns the outer route table, the application chrome, and session and
auth acquisition. Each micro-frontend owns a route subtree end-to-end and runs
its own nested router beneath it.

*Rationale.* This makes the UI obey the same rule as the backend: one deployable
per bounded context, independently releasable, held together by a contract
rather than by a coordinated release. `ARCHITECTURE.md` already names "micro-UI"
as a first-class deployable artifact; this makes that real rather than
aspirational. Route ownership — as opposed to widget embedding — is what keeps
the contract between shell and remote small enough to enforce: a base path, a
session, and a navigation callback.

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

*Rationale.* Under route ownership only one remote is mounted at a time, so the
shared framework runtime that federation exists to deduplicate buys us very
little — the cost it saves is roughly one framework runtime per route
transition, served from an immutable bundle that caches indefinitely. What it
adds is a build plugin, a runtime container protocol, and a shared-scope
negotiation whose misconfiguration surfaces at runtime rather than at build.

We reject it as unearned complexity for this shape, not as forced coupling —
a distinction worth stating precisely, because the sloppier version of this
argument is wrong. Modern federation can be configured to share nothing and to
interoperate across bundlers, so it does not *inherently* stop a remote
upgrading React on its own schedule. But a mechanism we would deliberately
configure into inertness is one we should not adopt at all.

## 3. The contract — `mfe-contract/v1`

Published as a **types-only** npm package, `@org/mfe-contract`. Types-only keeps
it a build-time dependency, so it satisfies the rule that no repo depends on
another repo while still giving both sides one definition to compile against.

```ts
export interface MfeContext {
  /** Route prefix the shell has delegated; the remote's router mounts here. */
  basePath: string;
  /** Identity and a token accessor. Never a raw long-lived secret. */
  auth: AuthContext;
  /** The remote asks the shell to change the outer URL. */
  onNavigate(path: string): void;
  /** The shell cancels an in-flight mount (route changed during load). */
  signal: AbortSignal;
}

/** The shape a remote's entry module must satisfy. */
export interface MfeModule {
  mount(el: HTMLElement, ctx: MfeContext): void | Promise<void>;
  unmount(el: HTMLElement): void | Promise<void>;
}
```

Two details this sketch deliberately leaves to A1, because they need their own
acceptance criteria rather than a design-doc assertion: the exact shape of
`AuthContext` (what identity claims are exposed, and whether the token accessor
is sync or async), and the precise semantics a remote must honour when `signal`
aborts mid-mount — specifically whether `unmount` is still called for a mount
that never completed.

**Why a function boundary rather than a custom element.** With route ownership
the shell must hand each remote real context — a session, a base path, a
navigation callback. Custom elements carry that less directly: attributes are
strings, so anything structured travels by property assignment or
`CustomEvent`. That is workable and can be typed, but it is hand-rolled per
element rather than falling out of a signature. The decisive objection is
different and unavoidable: `customElements.define` is a process-global
registration that throws on a duplicate tag name, so a shell loading two
versions of the same remote — which route ownership permits during a rollout —
is a hard failure rather than a graceful one.

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

A plain standalone SPA is simply a shell with zero remotes. There is
deliberately no third archetype: the same template tree serves both, so the
"small app" case costs no extra machinery and can grow remotes without a
rewrite.

### 4.2 Remote (micro-UI)

A React app whose entry module exports the contract, built into a container that
serves its own immutable, content-hashed assets. It runs a nested router beneath
the `basePath` the shell passes and delegates outward navigation through
`onNavigate`.

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

**Module Federation (`@module-federation/vite`).** Rejected per §2.3: it couples
remotes to the shell's bundler and shared-dependency versions, moving version
conflicts into production, which is precisely the failure the shape exists to
prevent. Its dedup benefit is small under route ownership.

**Custom elements + import maps.** A genuine contender, and the standards-based
option. Rejected because `customElements.define` is a process-global
registration that throws on a duplicate tag name, making two live versions of a
remote a hard failure; the context-passing ergonomics are a secondary cost.
Retained as the natural answer *if* the family ever needs to embed into host
pages it does not control — that would be a new position, filed as such.

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
| #1123 | `mfe-contract/v1` — signature, `MfeContext`, the types-only package, versioning rules |
| #1124 | Shell repo shape — outer router, chrome, auth acquisition, remote loader, import-map injection |
| #1125 | Remote repo shape — mount/unmount entry, nested router under `basePath`, asset container |
| #1126 | `check-mfe-conformance.zsh` + CI gate (§6) |
| #1127 | Bootstrap shape question — "browser UI? shell or remote?" (the surviving part of #1043) |
| #1128 | Composition-repo UI integration — gateway routes, import map as the single pin, cross-MFE E2E, `/info` live-version assertions |

```text
#1059 ──→ #1123 (contract) ──┬─→ #1124 (shell) ──┐
                             └─→ #1125 (remote) ─┼─→ #1126 (conformance)
                                                 └─→ #1128 (UI integration) ←── #687
#1127 (bootstrap shape question) — no blockers
```

Issue #1059 lands first: it is the position the rest rests on. The contract
(#1123) follows, since both repo shapes compile against it. The shell (#1124)
and remote (#1125) are independent of each other, and both also wait on #957
(the common React overlay they layer onto). Conformance (#1126) and UI
integration (#1128) each wait on both shapes; #1128 additionally waits on #687.
The bootstrap shape question (#1127) carries no blockers at all — it selects a
shape rather than rendering one, so it can start immediately.
