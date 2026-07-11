# development-javascript — epic decomposition design (2026-07-11)

Tracking epic: **#683** (promoted from a single issue). Part of epic **#682**.
Builds on the WebUI family design
(`2026-07-10-webui-plugin-family-design.md` §2); this doc adds the slice
decomposition, ordering, and the settled toolchain calls.

## Context

`development-javascript` is the **WebUI foundation**: every topic plugin (Angular
is #685, React is #686) and every Node service needs the same JS/TS language
layer, and the split-frontend (#717) and composition deploy-test (#719) epics
depend on its contract-consumer output. Its surface mirrors `development-python` /
`development-java` (#296) / `development-swift` (#297) — 17-agent-scale — **plus**
two things those don't have: contract-consumer generation and library mode. That
makes it too big for one issue, so #683 is promoted to an epic of slices,
mirroring the #296/#297 slice pattern.

## Decisions (approved 2026-07-11)

| Decision | Choice | Rationale |
|---|---|---|
| #683 shape | **Epic of slices** | 17-agent-scale surface + JS-specific extras; too big for one issue |
| Slice ordering | **Front-load contract-consumer (slice 2)** ahead of review/maintenance | #685/#717/#719 depend on it; review/maintenance/approver are plugin-completeness nothing downstream blocks on |
| Package manager | **npm** | Ships with Node, zero-install; polyrepo has no monorepo-workspace pressure favouring pnpm |
| Test + coverage | **vitest + v8** | Modern, ESM-native, jest-compatible |
| Lint + format | **ESLint flat + Prettier @120** | Topic plugins need framework ESLint rules (angular-eslint / react-hooks); Biome not at parity |
| Contract-consumer generator | **orval** | One tool: typed client **+ generated MSW mocks** (+ framework bindings the topic plugins invoke later) — matches "generated mocks" requirement and "minimize options" |
| TS + JS | **Combined in one plugin** | ARCHITECTURE.md special case |

### Why orval over the alternatives

The design requires *generated* MSW mock handlers. `openapi-typescript` +
`openapi-fetch` is leaner and very popular but leaves MSW handlers **hand-written**
against the generated types — against the requirement. `openapi-generator`
(typescript-fetch) is mature but **JVM-based**, dragging Java into the JS
toolchain. orval generates the typed client **and** MSW handlers (with mock data)
from one config, and its framework modes are exactly what #685/#686 invoke for the
binding layer — so one blessed tool spans generation + mocks + (later) framework
binding.

## Slice decomposition

Ordering: **1 → 2 → (3, 4, 5) → 6 → 7**, with a docs/ARCHITECTURE cross-cut.

### Slice 1 — Foundation (MVP)

Plugin scaffold (`plugin.json` + `.claude-plugin/marketplace.json` entry),
detection (`package.json` / `tsconfig.json`), the blessed-toolchain decisions
baked in, the **format_lint** agent (ESLint + Prettier), and bootstrap wiring to
install the JS toolchain on a detected repo. Outcome: the plugin exists, detects a
JS/TS repo, and formats/lints it.

### Slice 2 — Contract-consumer machinery (front-loaded, critical path)

orval generates a typed TS client **+ MSW mock handlers** from a pinned OpenAPI
spec **npm package** (the machine channel from #684). Generated code is
**committed** under `src/api/generated/` so a Renovate spec-bump PR diff shows the
API-surface change; app code never imports it directly — a thin hand-written
**anti-corruption layer** in `src/api/` wraps it. The language plugin owns
*generation*; the framework *binding* (Angular `HttpClient` vs React Query hooks)
is #685/#686's. **Unblocks #685, #717, #719.**

### Slice 3 — Review panel

The five standard dimensions (bug-hunter, security, performance, code-quality,
tests) + `/development-javascript:review`.

### Slice 4 — Maintenance core

Maintenance dispatcher + maintenance-planner + sonar-triage + code_scanning-triage
(CodeQL javascript + Scorecard) + coverage-improver, conforming to the dispatch
contract.

### Slice 5 — Vendor-PR + upgrades

dependabot / renovate / snyk_prs triage, major-upgrade agent, **Node**
runtime-upgrade agent (Dockerfile `FROM node:X`, `.nvmrc`, CI matrix — same
cascade pattern as python-runtime-upgrade), ci-fixer.

### Slice 6 — Approver

`/development-javascript:approve` + the approver agent, synthesising over slices
3–5 (needs them present).

### Slice 7 — Library mode (lowest priority)

`api-extractor` public-API gate for published packages; design-system repos =
library mode + visual-regression expectations. Only some repos are libraries, so
this is last.

### Cross-cut — docs

User-facing documentation per slice + the ARCHITECTURE.md plugin-family tree entry
flipped from "future" to shipped.

## Dependencies & sequencing

- **Within the epic:** slice 1 gates all; slice 2 depends only on slice 1 and is
  pulled ahead of 3–6.
- **Downstream:** slice 2 unblocks #685 (Angular binding), #717 (split-frontend UI
  repo consuming the contract), #719 (composition — real FE images).
- **Upstream:** none hard — #683 is the foundation. #684(a)'s npm spec-package
  publication is what slice 2 consumes, so slice 2's *validation* wants a real
  published spec (from #684(a)) but the generation tooling can be built against a
  fixture spec first.
- Overall family order: **#683 (this) → #685/#686 → #684 → #717 → #719 → #720 →
  #722–#724.**

## Acceptance (umbrella)

- [ ] Plugin scaffold + marketplace entry; orchestrator detection dispatches to it.
- [ ] orval generation produces a committed typed client + MSW handlers from a
      pinned spec package, wrapped by an anti-corruption layer.
- [ ] Review panel, maintenance dispatcher + planner, approver, and Node
      runtime-upgrade agent present and conforming to the dispatch contract.
- [ ] Library mode (api-extractor) gate available.
- [ ] ARCHITECTURE.md updated (tree entry no longer "future"); user docs exist.
- [ ] #683 stays open as the tracker and closes only when all slices close.
