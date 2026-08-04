## 2. Plugin decomposition

Three new plugins, layered exactly like `development-java` +
`development-spring`:

```text
development-javascript   ← language: TypeScript + JavaScript (combined)
development-angular      ← topic: composes with development-javascript
development-react        ← topic: composes with development-javascript
```

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

### development-angular / development-react (topic plugins)

Framework idioms and framework-specific maintenance only; everything
JS/TS-generic stays in the language plugin.

- **Angular:** standalone components, signals, strict templates, Angular
  CLI/esbuild. Its framework-upgrade agent is built on **`ng update` and
  its versioned migration schematics** — the direct analog of
  `spring-boot-upgrade`, and more mechanical than anything the family has
  for Spring.
- **React:** hooks rules, one blessed data-fetching/state default
  (TanStack Query for server state), Vite SPA as the default shape.
- **Framework binding for generated API clients:** Angular
  `HttpClient`-based client vs. React Query hooks — the topic plugin owns
  the binding; the language plugin owns the generation.
- **WebUI-generic concerns** (a11y auditing, Playwright, Lighthouse
  budgets) live **in each framework topic for now**. A shared
  `development-webui` layer is factored out only if a third framework
  arrives. Two copies are cheaper than a fourth plugin.

### Angular vs. React: a bootstrap-time recommendation, not an open menu

Bootstrap asks 3–4 questions and recommends one; the user can override.

| Signal | Points to |
| --- | --- |
| Form/CRUD-heavy business app, long-lived, larger team, org wants enforced conventions | **Angular** — DI, router, forms, i18n in the box; the framework itself enforces one blessed path |
| Highly custom design-driven UI; design-system component library; embedding / micro-frontend into existing pages | **React** — composition model and ecosystem fit custom UX work |
| Tie | Angular for internal business apps; React for consumer-facing custom UX |

**Build order: React first, Angular second.**

> **Amended 2026-07-22** (epic #682): originally "Angular first, React
> second". Reversed while designing the target platform architecture — it
> is micro-frontend-based, which the decision table above itself points at
> React. Consequences: the recommendation heuristic ships with the *second*
> framework topic (#685, Angular) since it needs both to exist, and the
> blessed MFE app shape (Module Federation host/remote repo shapes) is
> scoped as #954, a #686 follow-up; Vite SPA remains React's default shape.

## 3. Contract flow — versioned spec artifact, consumer generates
