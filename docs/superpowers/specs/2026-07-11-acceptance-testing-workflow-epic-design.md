# Acceptance-test workflow — epic decomposition design (2026-07-11)

## Context

The "acceptance-testing" work has lived as an **informal prose chain** —
`#241 (approver policy core, CLOSED) → #242 (interface detection) → #243
(acceptance-test workflow) → Approver consumption` — with **no umbrella epic
issue and no GitHub-native `blockedBy` relationships** between the pieces.

**#243 is too big to be one story.** It bundles at least six independent
pieces: a deploy stage, three distinct per-interface exercise harnesses
(`cli` / `rest` / `web-ui`, each different tooling), a report/artifact contract,
bootstrap template rendering, and end-to-end validation. It fails the
`story-readiness` gate's **"scope bounded"** check — the textbook "should have
been an epic."

**It blocks real work.** `#696` (a child of epic #573, the refinement epic)
depends on `#243` for the `tests/acceptance/…` convention + the CI stage that
runs it — so #243 gates the tail of #573.

## Decisions (approved 2026-07-11)

| Decision | Choice |
|---|---|
| Is #243 an epic? | **Yes** — decompose it. |
| v1 interface scope | **cli-first thin slice** — spine + `cli` harness + e2e, proven on ai-doc-organizer's CLI. `rest`/`web-ui` deferred. |
| Structure | **Promote #243 into the epic**; its parts become child issues. `#242` stays a declared prerequisite. |
| Deferred pieces | Grouped under a **new follow-up epic**, so they're tracked together and #243 closes cleanly after v1. |
| cli "deploy" | For a `cli` surface the "test system" is just running the built entry point against fixtures — **no service-container deploy needed**. The service-container/compose deploy is deferred with rest/web-ui (which need long-running services). |

## Epic A — #243, promoted: "acceptance-test workflow" (v1, cli-first)

`#243` is rewritten from a single story into an epic. `blockedBy #242`
(interface detection).

**Children (v1):**

1. **Spine + report contract.** The reusable structure every interface plugs
   into: `acceptance.yml.tmpl` skeleton rendered by bootstrap, the
   `acceptance (<interface>)` check name, and the `acceptance-report` artifact
   contract (JUnit XML). This is the artifact the Approver-consumption follow-up
   later reads.
2. **cli harness.** The `tests/acceptance/cli/` convention + the exercise step
   (run the built entry point against fixture inputs, assert exit codes +
   output) + a green-but-minimal smoke skeleton bootstrap renders. Depends on
   the spine.
3. **e2e validation.** Verify end-to-end on ai-doc-organizer's CLI: PR builds
   image → the cli acceptance stage runs → smoke passes → check green. Depends
   on the spine + cli harness. (Mirrors the #669/#581 validation-child pattern.)

**Intra-epic order:** spine → cli harness → e2e.

## Epic B — new follow-up epic: "acceptance-test workflow — rest/web-ui + Approver consumption"

Holds the deferred pieces together. `blockedBy` Epic A's **spine** child (the
reusable structure + report contract everything below builds on).

**Children:**

1. **deploy-as-service-container mechanism.** The reusable deploy stage
   (build/reuse the image → start it as a service container / compose stack =
   the ephemeral test system) that long-running interfaces need. Depends on the
   spine.
2. **rest harness.** Contract tests against `http://localhost:<port>`
   (`tests/acceptance/rest/`, e.g. schemathesis against the OpenAPI spec +
   explicit contract cases). Depends on the deploy mechanism + spine.
3. **web-ui harness.** Playwright/cucumber headless against the served UI
   (`tests/acceptance/web/`). Depends on the deploy mechanism + spine.
4. **Approver consumes `acceptance-report`.** The Approver reads the
   `acceptance-report` artifact as interface-level test evidence (the pattern
   #241 forward-referenced). Depends on the spine's report contract.

## Dependency graph (GitHub-native `blockedBy`, #583)

- `#243 (Epic A) blockedBy #242`.
- Epic A children: `cli-harness blockedBy spine`; `e2e blockedBy spine, cli-harness`.
- `#696 (epic #573)` — **re-pointed**: change its blocker from `#243` (the whole
  epic) to the **spine + cli-harness** children, so #696 unblocks as soon as
  those two merge, not when the entire epic closes.
- `Epic B blockedBy Epic-A spine`; Epic B children: `deploy-mechanism blockedBy
  spine`; `rest/web-ui blockedBy deploy-mechanism, spine`; `approver-consumption
  blockedBy spine`.

## Out of scope / notes

- **Runner-local deployment only** (service containers / compose). External test
  environments are out of scope (unchanged from #243's original note).
- **`library` interface** renders no acceptance workflow (unchanged).
- The Approver-gate's all-green wait (#232) picks up the new `acceptance (…)`
  check automatically — no Approver workflow change to *produce* the evidence;
  *consuming* it is Epic B's Approver child.
- Test bed: **ai-doc-organizer** (`cli` + `web-ui` per #242). v1 exercises its
  `cli`; `web-ui` validation lands with Epic B's web-ui harness.

## Issues (created 2026-07-11)

**Epic A — #243** (rewritten from a story into an epic), `blockedBy #242`:

| Child | Issue | blockedBy |
|---|---|---|
| Spine + report contract | **#697** | #242 (via the epic) |
| cli harness | **#698** | #697 |
| cli e2e validation | **#699** | #697, #698 |

**Epic B — #704** (new follow-up epic), `blockedBy #697`:

| Child | Issue | blockedBy |
|---|---|---|
| deploy-as-service-container | **#700** | #697 |
| rest harness | **#701** | #700, #697 |
| web-ui harness | **#702** | #700, #697 |
| Approver consumes `acceptance-report` | **#703** | #697 |

**Cross-epic:** `#696` (epic #573) re-pointed from `#243` to **#697 + #698** —
so the refinement epic's tail unblocks when the spine + cli harness merge, not
when the whole acceptance epic closes.
