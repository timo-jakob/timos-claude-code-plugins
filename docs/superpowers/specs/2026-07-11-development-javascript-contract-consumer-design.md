# development-javascript slice 2 — contract-consumer machinery design (2026-07-11)

> **Angular references superseded (#1059).** This document was written when the
> family planned two framework topics and names an Angular `HttpClient` binding
> owned by a `development-angular` topic (#685). Both are reversed: React +
> TypeScript is the single browser-UI default, Angular is not scaffolded, and
> there is no second binding to own. Read every `#685` / Angular-binding mention
> below as historical. The contract-consumer machinery itself is unaffected — it
> was always framework-agnostic; only the count of bindings downstream changed.
> Positions: `ARCHITECTURE.md`; design:
> [`2026-07-27-mfe-app-family-design.md`](2026-07-27-mfe-app-family-design.md).

Tracking issue: **#727**. Slice 2 of epic **#683**; part of **#682**. The
front-loaded, critical-path slice — **#685, #717, #719 depend on it.**

## Context

With frontend and backend in separate repos that never depend on each other, the
consumer must talk to the producer through the producer's **published, versioned
OpenAPI contract** — a pinned `*-api-spec` npm package (the #684 machine channel)
— with **zero drift risk** and **zero repo-to-repo dependency**. This slice builds
the `development-javascript` capability that scaffolds exactly that in a consuming
repo. It is **framework-agnostic**: it owns *generation*; the Angular `HttpClient`
/ React Query *binding* is the topic plugins' job (#685/#686).

## Decisions (approved 2026-07-11)

| Concern | Choice | Rationale |
|---|---|---|
| What to generate from | **Convention seeds an editable `orval.config.ts`** — detect `*-api-spec` deps, scaffold a target per spec; config is authoritative thereafter | Zero-friction common case (matches #684 naming) without a new manifest or hidden magic |
| Generator | **orval** → typed client + generated MSW handlers | One tool covers client + mocks (+ later framework bindings) |
| Base client | **`fetch`** | Zero-dependency; interceptor-style concerns live in the ACL, not a client lib |
| Generated code | **Committed** under `src/api/generated/` | A spec-bump PR diff shows the API-surface change — reviewable by human + Approver |
| Drift gate | CI runs `orval`; **fails if `git diff` on `src/api/generated/` is dirty** | Makes "committed == pinned spec" mechanical, not policed |
| Bump regeneration | **CI regenerate-and-commit-back** on a spec-bump PR | Portable across Renovate hosting + hand bumps; keeps the one-PR "version + API change" story |
| Anti-corruption layer | **ESLint boundary rule** (no import of `src/api/generated/*` outside `src/api/`) + **minimal hand-written ACL starter** | Boundary is a hard gate; a curated seam, not an auto-generated mirror (which would defeat the ACL) |
| MSW test wiring | **Wired into vitest `setupServer` by default**; browser `setupWorker` opt-in | Operationalizes the disjunct-testing guarantee — FE tests run with no backend |

## Data flow

```text
backend repo → publishes @scope/orders-api-spec@2.4.0 (npm, #684 machine channel)
consumer repo:
  package.json pins @scope/orders-api-spec: 2.4.0
  orval.config.ts   ← seeded by convention from the *-api-spec dep (editable)
  npm run generate  → src/api/generated/  (typed fetch client + MSW handlers)   [committed]
  src/api/          ← hand-written anti-corruption layer (configured client + mappings)
  app code imports  → src/api/   (ESLint forbids reaching into generated/)
  vitest setup      → MSW setupServer(generated handlers)   → tests run, no backend

CI:
  drift gate:  orval → `git diff --exit-code src/api/generated/`   (fail if dirty)
Renovate bumps 2.4.0 → 2.5.0:
  CI regenerate-and-commit-back → PR shows the version bump + the regenerated API diff
```

## Boundaries

| Unit | Does | Depends on |
|---|---|---|
| detection/seed | Finds `*-api-spec` deps, seeds `orval.config.ts` targets | package.json, #684 naming |
| generation | Runs orval → committed client + MSW under `src/api/generated/` | orval, the pinned spec |
| drift gate | CI regenerate + `git diff` clean; regenerate-and-commit-back on bumps | CI, orval |
| ACL | ESLint boundary rule + `src/api/` starter | ESLint flat config, generated client |
| test wiring | vitest setup starts MSW with generated handlers | vitest, MSW |

The framework *binding* is explicitly out of scope here (owned by #685/#686), so
the boundary between "generation" (this slice) and "binding" (topic plugins) is
clean.

## Acceptance criteria

- [ ] Detecting a pinned `*-api-spec` dependency seeds an `orval.config.ts` target
      (multiple specs → multiple targets); the config is editable.
- [ ] `orval` generates a **committed** typed `fetch` client + MSW handlers under
      `src/api/generated/`.
- [ ] The **drift gate** fails CI when generated code is stale vs the pinned spec,
      passes when in sync.
- [ ] A spec-package bump PR triggers **CI regenerate-and-commit-back**; the PR
      diff shows the API-surface change alongside the version bump.
- [ ] The **ESLint boundary rule** fails on any import of `src/api/generated/*`
      from outside `src/api/`.
- [ ] A **minimal ACL starter** exists in `src/api/`; app code imports from there.
- [ ] The **vitest setup** starts MSW with the generated handlers; a sample test
      exercises the client with **no backend running**.
- [ ] Generation is **framework-agnostic**; binding is left to #685/#686.

## Dependencies

- **Blocked by #683 slice 1** (foundation — plugin scaffold, detection, blessed
  toolchain, vitest + ESLint wiring). Slice 1 is currently a checklist item in
  #683.
- *Validation* wants a real published spec from **#684(a)**; the tooling can be
  built + tested against a fixture spec first.
- **Unblocks #685** (framework binding), **#717** (split-frontend UI repo consuming
  the contract), **#719** (composition — real FE images).
