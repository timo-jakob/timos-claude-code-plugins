# Composition deploy-test — two-epic design (2026-07-11)

> **Angular references superseded (#1059).** The Dependencies section names
> `#685` — the `development-angular` topic — among the prerequisites that
> produce real images. The family no longer builds it: React + TypeScript is the
> single browser-UI default and Angular is not scaffolded. **Read `#685` there as
> `#686`**, the one remaining framework topic; deleting it outright would leave
> the line with no UI-image prerequisite, which is not what it intends. Nothing
> else in this document depends on the reversed two-framework plan. Positions:
> `ARCHITECTURE.md`; design:
> [`2026-07-27-mfe-app-family-design.md`](2026-07-27-mfe-app-family-design.md).

Tracking epics: **#719** (docker-compose, first) and **#720** (Kubernetes,
second). Both build on **#687** (`development-composition` repo type) and **#688**
(ops-api). Downstream of **#682** (WebUI family) and **#717** (split-frontend).

## Context

Frontend and backend live in separate repos that never depend on each other
(#682, #717). Per-repo acceptance (#704) tests each repo's *own* interface in
isolation — it structurally cannot see **integration**: gateway routing,
auth/CORS, FE↔BE wiring, served-major/lifecycle behaviour. #687 already defines a
per-constellation **composition repo** as the one place they meet, with a thin
Playwright smoke through the gateway. This design takes #687's underspecified
"k8s or compose manifests" one-liner and turns the deploy-test into two properly
scoped epics — **compose first, k8s second** — on top of #687 as the shared
foundation.

## Decisions (approved 2026-07-11)

| Decision | Choice | Rationale |
|---|---|---|
| Reconcile with #687 | **#687 stays the foundation**; two *new* epics layer on top | #687's repo type + `.claude-workspace.yaml` + maintenance are shared; each deploy target is its own bounded epic |
| Deployment input | **One target-neutral `deploy-spec`** per repo; composition owns the renderers | Producers stay deploy-target-agnostic (compose vs k8s is the composition repo's concern) |
| Publication | **`deploy-spec` rides with the image** as an OCI artifact bound to the digest (ORAS) | Pin the image → inherently have its descriptor; zero image↔descriptor skew; "repo unavailable" is a non-issue |
| Test depth | **Thin integration smoke** (deploy → health → gateway E2E → assert `/info`) | The composed-path bugs single-repo tests can't see; per-service contract fuzz stays #704's job (no duplication) |
| Where it runs | **Ephemeral in the composition repo's CI**, gating the Renovate image-tag bump | Hermetic, cheap, no env drift; matches #687's "bump → E2E gate". Promotion stays #687's promote workflow |
| Compose scale | **Single instance** | Compose can't schedule replicas meaningfully |
| k8s scale | **`scalable: true` services at `replicas: 2` (min 2 pods)** | Surfaces shared-state races / non-idempotent handlers / sticky-session reliance a single instance hides; declared singletons stay at 1 |

## The backbone — one artifact, one data flow

Every member repo's build attaches a **target-neutral `deploy-spec`** to its
image (OCI artifact, bound to the digest): ports, env schema, probe paths
(→ #688 `/health`,`/info`), backing-service needs (db/broker/cache), resource
hints, and a **`scalable: true|false`** flag. The `development-composition`
plugin (#687) owns the renderers that compile `deploy-spec`s into a running
stack.

```text
backend/frontend repo ─build─→ image :tag ⊕ deploy-spec (OCI attached) → registry
composition repo (#687): .claude-workspace.yaml pins member image tags (N FE + N BE)
  CI on a Renovate tag-bump PR:
    pull images + attached deploy-specs   (never touches member repos)
    render → {compose | k8s}  (+ ephemeral backing services per deploy-spec)
    wait /health ready → thin Playwright E2E through the gateway → assert /info
    green → bump merges;  red → integration breakage caught in one place
```

**No repo depends on a repo.** The composition repo reads only published
artifacts — pinned image tags + their attached deploy-specs + published API
contracts. Repo-availability is irrelevant: the registry has everything, which is
exactly what satisfies the "get proper documentation when the repo isn't
available" requirement.

**Disjunct-testing guarantee (holds by construction).** The frontend tests
against MSW mocks generated from its pinned spec; the backend tests its own
contract via #704. Neither imports the other. They meet *only* in the composition
repo. Splitting ai-doc-organizer (#717) therefore yields two repos testable fully
independently, with integration verified in one separate place.

## Epic 1 — docker-compose deploy-test (#719, first)

Ephemeral compose smoke in the composition repo's CI, everything at single
instance. Children:

- **(a)** Versioned **`deploy-spec` schema** + **producer emission** — each
  language/topic plugin's build attaches its deploy-spec to the image via ORAS on
  push; includes the `scalable` flag. *Shared foundation; the k8s epic reuses
  schema + producer.*
- **(b)** `deploy-spec` → **docker-compose renderer** in `development-composition`,
  incl. ephemeral backing services.
- **(c)** **Ephemeral compose deploy-test harness** — bring up the stack,
  health-gate on `/health`, thin gateway Playwright E2E, assert `/info`; wire as
  the composition repo's Renovate-bump CI gate.
- **(d)** **User-facing documentation** — the composition repo type + how the
  compose deploy-test works.
- **(e)** **Validation** — split ai-doc-organizer (#717) → constellation →
  compose deploy-test green (capstone).

## Epic 2 — Kubernetes deploy-test (#720, second)

Reuses #719's schema, producer, and harness pattern; adds the k8s renderer, an
ephemeral cluster, and the scalability check. Children:

- **(a)** `deploy-spec` → **k8s manifest renderer** (honours `scalable` →
  `replicas: 2`).
- **(b)** **Ephemeral k8s test system** — kind/k3d in CI + deploy-test harness
  (readiness probes, gateway E2E) running scalable services at **≥2 pods**.
- **(c)** **Backing services on k8s** (ephemeral, per deploy-spec).
- **(d)** **User-facing documentation** — the k8s deploy-test + the 2-pod guarantee.
- **(e)** **Validation** — ai-doc-organizer constellation deploys green on k8s with
  the backend at 2 pods.

### Why 2 pods

A single instance hides a whole bug class: in-memory session/cache not
externalized, non-idempotent handlers, sticky-session reliance, leader-election
gaps, shared-state races. Running `scalable: true` services at 2 pods and driving
the gateway E2E against the multi-pod stack surfaces them. A declared singleton
(`scalable: false`) is exempted explicitly, so the assertion applies only where
horizontal scaling is actually claimed.

## Dependencies & sequencing

- **#719 blocked by:** #687, #688; needs real images from #682 (#683/#685/#684a);
  ai-doc validation (1e) needs #717.
- **#720 blocked by:** #719 (schema + producer + harness pattern) and #687; same
  upstreams as #719.
- Overall order: **#682 → #717 → #719 (compose) → #720 (k8s) → (future) infra
  load-testing epic.**

## Out of scope — future work

Deeper infrastructure testing — **load/stress, soak, chaos, autoscaling
behaviour** — is a separate future epic on the composition repo, to be
brainstormed after #720. This design deliberately caps the scalability check at
"2 pods, does the integrated path still work"; performance characterization is
not attempted here.

## Acceptance (umbrella, both epics)

- [ ] Each member repo's build attaches a versioned `deploy-spec` (incl.
      `scalable`) to its image as an OCI artifact; the composition repo consumes it
      without touching the member repo.
- [ ] #719: a Renovate image-tag bump renders a compose stack in CI, health-gates
      it, runs a thin gateway E2E + `/info` assertion, and gates the bump.
- [ ] #720: the same on an ephemeral k8s cluster, with `scalable: true` services
      at ≥2 pods and singletons exempted.
- [ ] Per-service contract fuzzing is **not** re-run here (stays #704).
- [ ] User-facing documentation exists for both deploy-tests.
- [ ] Both validated by composing the split ai-doc-organizer (#717).
- [ ] The load/stress/chaos future epic is recorded as out-of-scope follow-up.
