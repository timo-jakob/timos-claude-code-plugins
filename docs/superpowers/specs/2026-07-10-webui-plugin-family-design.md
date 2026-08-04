# WebUI plugin family, API lifecycle, and cross-repo composition — design

> **§2 superseded (2026-07-27), rewritten (#1059).** The framework decision
> table, its tie-break rule, and the Module Federation micro-frontend shape this
> document originally carried are reversed by
> `2026-07-27-mfe-app-family-design.md`, which is authoritative for every
> browser-UI position. §2 below is rewritten to record only what survives and
> point there; §1's gap list, §8's epic ordering, and §9's rejected alternatives
> carry matching annotations where they named the reversed mechanism, and §6's
> frontend test-stack row drops its Angular entry. **§§3–5 and §7 are
> unaffected.**

**Date:** 2026-07-10
**Status:** Approved design, pre-implementation
**Builds on:** ARCHITECTURE.md "Polyrepo, contracts, and the cross-repo big
picture"; issue #174 (contract artifacts + breaking-change detectors)

## 1. Context and goals

The plugin family serves backend repos well (Python, Java/Spring, Swift) but
has no WebUI story. The target project shape is already defined in
ARCHITECTURE.md: many small repos, each independently deployable, held
together by stable published contracts — DDD bounded contexts, polyrepo by
default. This design fills three gaps:

1. **WebUI plugins** — TypeScript/JavaScript as a language plugin, with the
   browser framework as a topic plugin on top of it. (This document originally
   proposed *two* framework topics chosen by a recommendation heuristic; §2
   records the single-default position that replaced it.)
2. **Contract lifecycle** — how a frontend repo consumes a backend's
   OpenAPI contract with zero drift risk and **zero repo-to-repo
   dependencies** (a hard rule: a repo may depend on published, versioned
   artifacts, never on another repo).
3. **Cross-repo integration testing and production composition** — where
   frontend and backend meet, given that neither repo may know the other.

Constraints carried throughout:

- **API-first**: specs are authored before implementations and are the
  authoritative artifact.
- **Strict API semantic versioning** — enforced mechanically, not by
  convention.
- **Minimize options, one good default** per decision; options are
  maintenance + expertise cost.
- **gRPC internal, REST external**: frontends consume REST/OpenAPI only.
  No grpc-web path in v1.
- The org runs an **API management platform** (Apigee-style): gateway,
  developer portal, all API versions published with documentation.

## 2. Plugin decomposition

> **This section was rewritten by #1059.** It originally proposed Angular and
> React as co-equal framework topics chosen by a bootstrap-time recommendation
> heuristic, and named Module Federation as the blessed micro-frontend
> mechanism. Both are reversed. The browser-UI positions — SPA shell plus
> micro-frontends, React + TypeScript as the single default, and a
> `mount(el, ctx)` / `unmount(el)` contract over an import-map-resolved ES
> module with Module Federation rejected — live in
> [`2026-07-27-mfe-app-family-design.md`](2026-07-27-mfe-app-family-design.md)
> §2 and §3, and are summarised as family positions in `ARCHITECTURE.md`.
> What follows is the plugin decomposition that survives them.

Two plugins, layered exactly like `development-java` + `development-spring`:

```text
development-javascript   ← language: TypeScript + JavaScript (combined)
development-react        ← topic: composes with development-javascript
```

There is no `development-angular`. Angular is not scaffolded; an existing
Angular asset participates by exporting the same MFE contract, and a second
framework topic is built only if such an asset actually exists — at which
point the boundary is already framework-agnostic, so it costs a plugin rather
than a redesign.

### development-javascript (language plugin, the foundation)

Mirrors `development-python` / `development-java` structurally:

- **Bootstrap detection:** `package.json` / `tsconfig.json`.
- **Blessed toolchain (one default each):** npm (ships with Node), vitest
  (+ v8 coverage), ESLint flat config + Prettier at 120 columns.
- **Review panel:** bug-hunter, security, performance, code-quality, tests
  — same five dimensions as the other languages.
- **Maintenance dispatcher:** format_lint (ESLint + Prettier), sonarcloud,
  code_scanning (CodeQL javascript + Scorecard), coverage, and the
  vendor-PR sources (dependabot / renovate / snyk_prs) with a
  major-upgrade agent.
- **Runtime-upgrade agent:** "runtime" = the Node version (Dockerfile
  `FROM node:X`, `.nvmrc`, CI matrix), same cascade pattern as
  python-runtime-upgrade.
- **Approver:** same synthesis-layer pattern as the other languages.
- **Contract-consumer machinery lives here, not in the UI topics:**
  generating a typed client + mocks from a pinned OpenAPI spec is TS
  tooling that a Node service consuming another service needs just as much
  as a browser app does.
- **Library mode** (per ARCHITECTURE.md): `api-extractor` public-API gate
  for published packages; the design-system repo case is library mode plus
  visual-regression expectations.

### development-react (topic plugin)

Framework idioms and framework-specific maintenance only; everything
JS/TS-generic stays in the language plugin.

- **React:** hooks rules, one blessed data-fetching/state default
  (TanStack Query for server state), Vite as the default build.
- **Framework binding for generated API clients:** React Query hooks — the
  topic plugin owns the binding; the language plugin owns the generation.
- **WebUI-generic concerns** (a11y auditing, Playwright, Lighthouse
  budgets) live **in the framework topic for now**. A shared
  `development-webui` layer is factored out only if a second framework
  topic ever arrives — which, per the single-default position, requires a
  real Angular asset to serve first.

### Framework choice: a single default, not a recommendation heuristic

Bootstrap asks nothing about the framework. React + TypeScript is the default
for any browser UI, and the SPA shell + micro-frontend shape is the default
composition. Bootstrap's remaining UI question is *which repo shape to
scaffold* — **shell or remote** — not which framework to use; that axis is
gone. A remote is then a route-owned page or a canvas widget, but that is a
variant under one contract and one template tree, not a third scaffold choice.
See the 2026-07-27 design for the shapes and the contract they share.

## 3. Contract flow — versioned spec artifact, consumer generates

The producer owns the contract; the consumer owns its own generated code.
No repo depends on a repo — only on published, versioned artifacts.

```text
backend repo: contracts/v2/openapi.yaml   (authored spec-first)
   CI gates: impl-matches-spec (per live major) + oasdiff semver gate
   CI on release:
     ├─ publish @acme/orders-api-spec@2.4.0 to npm    ← machine channel
     └─ publish spec 2.4.0 + docs to APIM portal      ← governance channel
        (+ deploy/update the API proxy for that version)

frontend repo: package.json → @acme/orders-api-spec: 2.4.0
   build: generate typed TS client + MSW mock handlers from the spec
   Renovate bumps 2.4.0 → 2.5.0 → PR diff shows the API surface change
```

Decisions and rationale:

- **The backend repo's `contracts/` is the single source of truth.** The
  APIM platform is a *second publication target* fed from the same file in
  the same CI step — the governance/human channel (portal, rendered docs
  per version, API products/keys/quotas). The plugins never need a
  docs-site story for APIs; the publish step feeds the portal.
- **npm is the machine channel** because it gives pinning in
  `package.json`, Renovate bump PRs, and hermetic builds. Fetching specs
  from APIM at build time would couple builds to infrastructure
  availability and has no Renovate story.
- **The consumer generates its own client** (rejected: backend publishes a
  generated TS client — that puts frontend toolchain in the backend repo
  and weakens the bounded-context boundary). Generated client code is
  **committed**, so a Renovate spec-bump PR's diff shows exactly what
  changed in the API surface — reviewable by human and Approver.
- **DDD layering scaffolded by the plugin:** generated code in
  `src/api/generated/`, wrapped by a thin hand-written domain layer in
  `src/api/` — the anti-corruption layer between bounded contexts, and the
  seam where MSW mocks plug in.
- **The generated client targets the gateway**, not the service. Base URL,
  version path segment, and key handling come from the spec's `servers:`
  block, authored by the backend as part of the contract. The frontend
  never knows a service's real address.
- **Gateway config is code, in the backend repo:** Apigee-style proxy
  definitions (config-as-code bundles) live next to the spec they expose;
  bootstrap gains an optional `apim/` directory + deploy workflow step.
  Repos without APIM skip it — the npm channel alone delivers the full
  drift guarantee. Org-level APIM platform infrastructure is out of scope
  for the plugin family.
- **Drift is structurally impossible, not policed:** the frontend can only
  ever see a published, versioned, backward-compat-gated spec.

## 4. API versioning, multi-major serving, deprecation

### 4.1 Strict semver, enforced mechanically

The API version lives in three places that must agree — the spec's
`info.version`, the npm spec-package version, and the URL major in
`servers:` (`/v2/`). CI enforces the triangle plus bump correctness:
**oasdiff classifies every spec diff (breaking / additive / editorial) and
the build fails unless the version bump matches** — breaking → major,
additive → minor, editorial → patch.

Because APIM serves all versions concurrently, a breaking change is
**never an in-place edit** — it is a new major published alongside
(`/v1/` and `/v2/` both live), and the old major gets a sunset date.
Consumers migrate on their own schedule via a Renovate major-bump PR.

### 4.2 Multiple live majors via an in-service anti-corruption layer

Default pattern: the service **natively implements only the newest
major**; each older supported major is served by an adapter layer that
translates old-shape requests onto the new domain and back. One codebase,
N majors live, no forked business logic.

- `contracts/` is per-major: `contracts/v1/openapi.yaml`,
  `contracts/v2/openapi.yaml`. Old majors are frozen — oasdiff allows
  patch/editorial changes only; the newest evolves.
- The impl-matches-spec drift gate runs **per live major**; the adapter
  pattern is what makes that affordable.
- Each major publishes its own npm version line (`1.x`, `2.x`), so
  Renovate serves both consumer populations natively.

### 4.3 Deprecation lifecycle: active → deprecated (sunset date) → retired

Every transition is mechanical:

- **In the spec:** `deprecated: true` on operations/versions plus
  `x-sunset: <date>` — deprecation is itself a contract change, versioned
  and published; the APIM portal renders it.
- **At runtime:** the service/gateway emits the standard `Deprecation`
  (RFC 9745) and `Sunset` (RFC 8594) HTTP headers.
- **Consumer side:** the client generator maps `deprecated: true` to
  TypeScript `@deprecated`, so every frontend call site of a dying
  operation gets an ESLint warning the moment the Renovate bump lands —
  migration pressure with zero coordination.
- **Producer side:** a maintenance finding (later a CI gate) fires when a
  major is past its sunset date but still served. Retirement deletes the
  adapter and its spec; the gateway returns 410 for the retired major.
- The minimum deprecation window is a policy knob recorded in
  CONTRACTS.md (default: 6 months), surfaced as a maintenance finding when
  violated.

## 5. Standardized operations surface (`ops-api`)

Every backend service exposes one org-standard ops surface, defined as a
**shared, versioned OpenAPI fragment** — itself a contract artifact, so
"standardised" is testable, not aspirational:

- **`/info`** — build version, git SHA, and **which API majors are served
  with their lifecycle state + sunset dates**. Makes the deprecation
  machinery observable; the composition repo's E2E asserts the right
  versions are live. **Minimal by contract** — never framework/server/OS/
  dependency versions (an information-disclosure surface).
- **`/health`** — human/dashboard-facing **aggregate** health (not a probe
  target).
- **`/health/live`** — Kubernetes **liveness** (process only, dependency-
  free — a failing liveness restarts the pod, so it must never check a
  dependency or a transient outage becomes a restart storm).
- **`/health/ready`** — Kubernetes **readiness** (dependency checks live
  here — a failing readiness sheds traffic without a restart).
- **`/metrics`** — Prometheus/OpenMetrics format (see below).

> **Amended 2026-07-23** (issue #688 review): the original design lumped
> `/health` as "liveness/readiness". Split into a human aggregate plus
> distinct `/health/live` and `/health/ready`, because one endpoint cannot
> drive both K8s probes without the liveness-checks-dependencies anti-pattern.

**Trust boundary — an internal management surface, not per-endpoint auth.**
The whole surface is served on a separate **management port**, never the
public app port, so `/info`'s build data is unreachable externally with no
per-endpoint auth (auth is a poor fit for probes the kubelet must reach
cheaply). The service provides the *seam* (the management port + minimal
`/info` + distinct probes); the **deployment layer** — the composition
repo, epics #687/#719/#720 — draws the *boundary*: a `NetworkPolicy`
restricting the management port to the kubelet + monitoring namespace, a
`Service`/`Ingress` exposing only the app port, and the liveness/readiness
probe wiring. Reserve
in-cluster confidentiality (mTLS/mesh) for when the threat model needs it.

**Telemetry decision — OpenTelemetry only, at the instrumentation layer:**

- **Instrumentation:** OTel SDK + OTel semantic conventions, exclusively.
  This is the "one standardised way" — one vocabulary across all
  languages, and it covers traces + logs without a second system.
- **Export:** OTLP push to a collector is the primary pipeline. The
  ops-api `/metrics` pull endpoint is a **mandatory compatibility
  surface** served by the same SDK's Prometheus exporter (config flag,
  zero extra code). It earns its place three ways: it is curl-able (E2E
  and conformance checks need no collector), local dev needs no
  collector, and Prometheus scraping remains the Kubernetes lingua
  franca. Developers make zero choices.

Per the language-first principle: Spring gets the surface via
Actuator/Micrometer (mostly config — a management port, health probes,
base-path/path remaps, `micrometer-registry-prometheus`, an `InfoContributor`
— plus a small custom health representation, since Actuator's `/actuator/health`
returns `{"status":"UP"}` and the fragment requires `{"status":"ok"}`;
Micrometer maps to OTel semantic conventions) — `spring-config-advisor` gains a
conforms-to-ops-api check that states these specifics. Every other language
plugin owns its canonical implementation of the same fragment. Ops endpoints
stay internal — never published as APIM products.

## 6. Testing — disjoint by construction

| Repo | Tests | Needs the other side? |
| --- | --- | --- |
| Backend | Unit + per-major spec-conformance (drift gate; optionally schemathesis) + testcontainers | Never |
| Frontend | Unit/component (vitest + testing-library) + integration against **MSW handlers generated from the pinned spec version** | Never |
| Composition | Thin Playwright smoke suite over composed released images, **through the gateway** (the production path) — critical user journeys only | The only place both meet |

## 7. Composition repo — a new repo type

Per constellation (≈ bounded context): one small repo owning production
composition. It depends only on published container images — the
no-repo-depends-on-repo rule holds everywhere.

```text
orders-composition repo:
  deploy/          k8s or compose manifests; images pinned by tag
                   frontend: ghcr.io/acme/orders-ui:2.3.1
                   backend:  ghcr.io/acme/orders-api:1.5.0
  e2e/             thin Playwright smoke suite vs. the composed stack
  Renovate bumps a tag → E2E gates the PR → merge deploys
```

This becomes a **`development-composition` topic plugin**: bootstrap
templates for manifests + Renovate docker config + the E2E harness + a
promote-to-prod workflow; maintenance handles tag-bump triage.
`.maintenance.yml` gets `primary: composition`. The repo is also the
natural home for the `.claude-workspace.yaml` constellation manifest
(ARCHITECTURE.md leverage-stack item 3): which repos belong, their roles,
where their contracts live.

Per-API gateway proxy config does **not** live here (it lives with its
producer, §3); the composition repo only decides which app versions
compose an environment.

## 8. Epic map and sequencing

Each epic is independently shippable.

1. **`development-javascript`** — the language foundation; largest epic;
   mirrors the existing language plugins.
2. **API lifecycle** — spec publish (npm + APIM), semver triangle gate,
   per-major `contracts/` layout + ACL pattern, deprecation
   headers/gates, Spectral socket. Overlaps/absorbs parts of #174.
3. **`development-react`** (the framework topic — see §2). The MFE
   composition work is its own epic, built to the 2026-07-27 contract; the
   Module-Federation-shaped follow-up this list used to name is superseded
   along with the mechanism.
4. **`development-composition`** (composition repo type).
5. **Standardized ops surface** — the `ops-api` fragment + per-language
   canonical implementations + OTel defaults.
6. **API styleguide** — separate, later. The enforcement vehicle is a
   **Spectral ruleset** linting `contracts/` in CI; bootstrap installs
   Spectral with a minimal starter ruleset in epic 2, and the styleguide
   epic later replaces the ruleset content without touching the pipeline.

## 9. Considered and rejected

- **Single `development-webui` plugin owning both frameworks** — breaks
  the one-framework-one-topic convention (Spring precedent); grows large.
  (Moot since #1059: there is one framework topic. Kept as the record of
  what was weighed when two were still on the table.)
- **Module Federation as the micro-frontend mechanism, and custom elements
  as the alternative contract** — both rejected with reasons in
  [`2026-07-27-mfe-app-family-design.md`](2026-07-27-mfe-app-family-design.md)
  §2.3 and its rejected-alternatives section, which supersede this
  document's original §2 on the point.
- **Skipping the language layer** (all TS tooling inside each framework
  topic) — duplicates ~90% of tooling; leaves Node services/CLIs
  unserved.
- **Backend publishes a generated TS client** — backend repo absorbs
  frontend toolchain; consumer can't shape its own client/mocks; weaker
  bounded-context separation.
- **Separate contract repo per constellation** — purest API-first but adds
  a repo per constellation and a three-way sync; the producer-owned
  `contracts/` + published artifact achieves the same guarantees.
- **Fetching specs from APIM at build time** — couples builds to infra
  availability; no Renovate story.
- **Pact-style consumer-driven contract tests** — the published-spec +
  oasdiff mechanism delivers the guarantee with far less machinery (no
  broker, no verification builds). Revisit only if multiple consumers
  must prove which API subset they use.
- **grpc-web for frontends** — violates the "gRPC internal, REST
  external" policy.
- **Push-only (OTLP-only) metrics** — invisible to curl-based conformance
  and smoke tests; local dev would need a collector; k8s scraping
  ubiquity lost.
- **E2E inside the frontend repo against a real backend image** — the
  frontend repo absorbs backend runtime knowledge (env vars, DB
  fixtures), blurring the bounded-context line; prod composition still
  needs a home.
