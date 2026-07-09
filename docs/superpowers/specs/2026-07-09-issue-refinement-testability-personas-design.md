# Design: outside-in testability in issue refinement (epic #573) + persona registry epic

Date: 2026-07-09
Status: approved in brainstorming session; this spec drives the GitHub issue
surgery (epic #573 refinement) and the filing of the new personas epic.

## Problem

Epic #573 (AI-assisted issue refinement) as originally filed is type-blind: it
judges acceptance criteria, scope, dependencies, and contradictions, but says
nothing about **how the delivered surface will be exercised from the outside**.
Meanwhile the acceptance-testing epic (#241–#244) builds the execution half —
deploy the built artifact, exercise it via CLI/REST/Web UI in CI, Approver
judges representativeness — with nothing upstream defining *which* test cases
that stage should run.

The guiding conviction: **defining the issue is more work than implementing
it, and that is the point.** The better the story is specified — use case,
personas, outside-in test cases — the fewer defects reach the product.

## The traceability chain

> refinement defines test cases → implementation writes them into
> `tests/acceptance/` → CI executes them against the deployed artifact (#243)
> → the Approver judges whether the changed surface was exercised (#244)

Epic #573 (refined) owns the entry point of that chain. #239's type-aware
Definition of Ready is absorbed by this refinement; its non-overlapping parts
are extracted into standalone issues and #239 is closed as superseded.

## Decisions (brainstormed and approved)

| Decision | Choice |
|---|---|
| Test-case modeling | **Hybrid**: test cases live structured in the story-spec block AND are spun out as separate linked `test-case` issues; story is READY only when both exist |
| Test lifecycle | **Same PR as the story**: resolve-issue implements feature + acceptance tests together; PR closes story + test-case issues |
| Gate strictness | **Tests hard, personas advisory**: use case + test cases + spun-out issues hard-fail readiness for surface-touching stories; missing personas only warn |
| #239 fate | **Close as superseded**; extract issue forms/status labels and the backlog audit command first |
| Persona kinds | **Full spectrum**: end-user, operator, api-consumer, negative, adversarial |
| Persona registry form | **`docs/personas.md` + machine block** (`personas/v1`), prose human-authoritative — same pattern as story-spec/v1 |
| Persona workflow | **Mirror refine-issue**: interactive skill `/development:define-personas` conducts; `persona-definer` agent is the per-turn pure function |
| Persona lifecycle | **Pull-based**: staleness surfaces where personas are consumed (gate/refine-issue route the human back to define-personas); no background machinery |

## Part 1 — Refinement of epic #573

### 1.1 Gate: `story-readiness` gains check 5, interface-aware

The gate classifies the story's **runtime surface**: `rest` | `grpc` |
`web-ui` | `cli` | `none` (the same taxonomy #242 uses at bootstrap, so the
definition layer and the CI layer speak one language). For stories touching a
surface, check 5 **outside-in testability** hard-requires:

- a **use-case description** concrete enough to derive realistic test data
  (actor, goal, representative data);
- **test cases defined** in the story-spec covering happy path, corner cases,
  and error cases, in the surface's native tooling (curl for REST, grpcurl for
  gRPC, Playwright for Web UI, CLI invocation for cli);
- the **spun-out `test-case` issues exist** and are linked from the spec.

Personas are **advisory**: a missing/ill-fitting persona reference produces a
warning in the verdict, never a fail (many valid stories — internal APIs,
operational work — are persona-less). Stories with no runtime surface (docs,
chores, refactors, library-internal) skip check 5 entirely; proportionality is
what protects the existing backlog from a mass flip to NEEDS_REFINEMENT.

Verdict JSON grows: `surface`, `checks.outside_in_testable`, `advisories[]`.

### 1.2 Schema: `story-spec/v1` grows (still v1 — #574 has not shipped)

New fields:

- `interface_surfaces` — list of the surfaces the story touches
- `use_case` — actor, goal, representative-data sketch
- `personas` — persona **ids** referencing the target repo's `personas/v1`
  registry (advisory; may be empty)
- `test_cases[]` — each entry: `id`, `kind` (`happy` | `corner` | `error`),
  a given/when/then or request → expected-response shape, `tooling`
  (`curl` | `grpcurl` | `playwright` | `cli`), and — after spin-out — the
  linked `issue` number

Dependencies stay **out** of the block (native `blockedBy` is canonical, per
the existing #574 decision).

### 1.3 Refinement flow: refiner drafts, human curates

`issue-refiner` (#575) drafts the expensive parts by mining the repo —
OpenAPI/proto specs, existing acceptance tests, the persona registry — so the
human curates instead of authors. `refine-issue` (#576) gains one step after
the human approves the rewrite: **spin out one `test-case`-labeled issue per
integration test case** (body generated from its spec entry, referencing the
story), then write the spec block with the issue links, then re-gate
(including check 5).

### 1.4 Implementation: same-PR lifecycle

`resolve-issue` (#577) picks up the story **plus its linked test-case issues
in one run**: the PR implements the feature and the acceptance tests into the
`tests/acceptance/{rest,grpc,web,cli}/` conventions (#243) and closes story +
test-case issues together (`Closes #N` per issue). No `blockedBy` between
story and test-case issues — same-PR closure makes ordering moot.

### 1.5 Epic surgery

- **#573 body**: scope + explicit relationship statement (defines what #243
  executes and #244 judges; supersedes #239; personas epic is a sibling — the
  persona advisory check is delivered by that epic's consumption-wiring child).
- **#574–#577**: scope grows in place (clearly-marked extension sections).
- **Two new children**:
  - (A) interface-aware gate check + surface taxonomy (story-readiness check 5)
  - (B) `test-case` issue convention + spin-out mechanics in refine-issue
- **#239**: extract (a) bootstrap issue forms + status-label state machine and
  (b) `/development:issues audit` backlog readiness report into standalone
  issues; close #239 as superseded.

## Part 2 — New epic: persona registry

### 2.1 Motivation

The refined #573 makes personas an advisory readiness input and the source of
realistic test data — but nothing owns creating them. A hand-written one-off
file lacks elicitation quality (Socratic questioning, full-spectrum coverage,
data traits) and the machine-readable form agents need.

### 2.2 The artifact: `personas/v1`

`docs/personas.md` in the target repo — prose human-authoritative, plus a
`<details>`-collapsed `personas/v1` JSON block. Per persona:

- stable `id`, `name`
- `kind` — `end-user` | `operator` | `api-consumer` | `negative` | `adversarial`
- role, goals, **failure costs** (what going wrong costs this person),
  technical proficiency, usage context
- **`data_traits`** — realistic value shapes this persona produces; what
  refine-issue mines to generate representative curl/grpcurl/Playwright
  payloads instead of `foo`/`bar`
- block-level `provenance` (generated-by + prose hash) for staleness detection

Registry conventions baked into the schema docs: 3–7 personas, one primary per
surface, no demographic fluff — every field must be able to change a design or
test decision. Adversarial personas let refinement derive security/malformed-
input corner cases; api-consumer personas cover services whose "user" is
another team's developer.

### 2.3 Workflow: skill conducts, agent thinks

- **`persona-definer` agent** — per-turn pure function:
  `(repo evidence + registry-so-far + human reply)` → `(candidate personas,
  Socratic questions, draft registry update)`. Mines README, docs, existing
  issues, API specs, UI routes to *propose*; interrogates the human to extract
  tacit knowledge ("who do you optimize for if forced to choose?", "what is
  this persona's most expensive mistake?", "what would they actually paste
  into this field?").
- **`/development:define-personas` skill** — interactive conductor, create +
  update modes; relays human ↔ agent each turn; write-back is human-approved
  (the skill edits `docs/personas.md` in the working tree; the change lands
  via the normal PR flow).

### 2.4 Consumption and lifecycle

`story-spec/v1.personas` references registry ids. `story-readiness`'s advisory
check validates the references (id exists; registry block consistent with its
prose). `refine-issue` consumes `data_traits` when drafting test cases and
routes the human to `/development:define-personas` when a needed persona is
missing or ill-fitting — that pull-based path is the whole staleness
mechanism. Bootstrap seeding of a starter registry is out of scope (possible
follow-up).

### 2.5 Children

1. `personas/v1` schema + registry format (ARCHITECTURE.md contract)
2. `persona-definer` agent
3. `/development:define-personas` skill
4. Consumption wiring — story-readiness advisory validation + refine-issue
   integration (cross-depends on #574 and #576)
5. End-to-end validation + docs (ai-doc-organizer test bed)

Dependency order: 1 → (2, 4) → 3 → 5.

## Out of scope

- Bootstrap seeding of persona registries (follow-up).
- Executing the acceptance tests (that is #243) and judging them (#244).
- Fully-async comment-driven refinement (unchanged from #573).
