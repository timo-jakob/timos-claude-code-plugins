# Intensive infra testing — three-epic design (2026-07-11)

Tracking epics: **#722** (load/perf harness + SLO gate, first), **#723**
(autoscaling verification), **#724** (chaos/resilience). All build on **#720**
(k8s deploy-test) and **#688** (ops-api telemetry); downstream of **#682**,
**#717**, **#719**.

## Context

The composition deploy-tests (#719 compose, #720 k8s) prove the composed system
*works* — a thin integration smoke, per-PR, hermetic, seconds long. They say
nothing about whether it is **fast enough, scales, or survives failure.** That is
a genuinely different kind of testing: **non-hermetic, expensive, minutes-to-hours
long, noisy numbers**, run against a realer environment on a schedule rather than
on every PR. It is also several distinct disciplines. Rather than one oversized
epic, this design splits it into **three**, built in order.

## Decisions (approved 2026-07-11)

| Decision | Choice | Rationale |
|---|---|---|
| Decomposition | **Three epics** — load/perf (1), autoscaling (2), chaos (3) | Load/stress/spike/soak are *profiles* of one harness; autoscaling needs a load source; chaos is separate tooling. Distinct scopes |
| First epic | **Load/perf harness + SLO gate** | The foundation the other two lean on (both want load running) |
| SLO declaration | **Per-service, rides with the image** (a `perf-spec` sibling to `deploy-spec`, or a `perf:` block within it) | The producer owns its own performance envelope; it travels with the exact image build |
| Load scenario declaration | **In the composition repo** | Cross-service journeys through the gateway are a constellation concern one service can't express |
| Load generator | **k6** | Its `thresholds` *are* the SLO gate (declare → assert in one mechanism); JS matches the family; native Prometheus/OTLP output aligns with #688 |
| Where it runs | **Realer k8s target, scheduled (nightly) + on-demand — NOT per-PR** | kind/k3d in a CI runner can't produce trustworthy load numbers |
| Primary gate | **SLO-threshold** (perf envelope → k6 thresholds); regression-vs-baseline is a separate child | Threshold is a clean boolean; baseline/trend is noisier and secondary |

## Shared backbone

- **Per-service SLO envelope** (`perf-spec`): target RPS, latency p95/p99, error
  budget — published with the image as an OCI artifact, same pattern as
  `deploy-spec`. Read by the harness without touching the repo.
- **Composition-repo workload model**: cross-service journeys, traffic mix, ramp
  profiles (load / stress / spike / soak).
- **k6** compiles the per-service envelope into `thresholds`; a breach fails the
  run. k6 client-side metrics (latency percentiles, throughput, error rate *as
  experienced through the gateway*) are the primary assertion surface; server-side
  #688 `/metrics` + OTLP enrich for diagnosis.
- **Realer k8s target**, reusing #720's render/deploy pointed at a capable
  cluster; scheduled + on-demand.

## Epic 1 — load/perf harness + SLO gate (#722, first)

Load / stress / spike / soak as **profiles** of one k6 harness. Children:

- **(a)** `perf-spec` SLO-envelope schema + producer emission (ORAS, with the
  image). *Shared foundation.*
- **(b)** Composition-repo workload model + the load/stress/spike/soak profiles.
- **(c)** k6 harness in `development-composition`: compile envelope → thresholds,
  run profiles, collect k6 + #688 metrics, emit a report.
- **(d)** Target-environment provisioning + scheduled/on-demand trigger.
- **(e)** Regression-vs-baseline trend gate (store baseline, compare) — secondary
  to the SLO gate.
- **(f)** User-facing documentation.
- **(g)** Validation on the split ai-doc-organizer constellation (#717).

## Epic 2 — autoscaling verification (#723)

Verify the system scales automatically under load. Reuses #722's k6 as the load
source. Children:

- **(a)** HPA scaffolding in the k8s renderer + declared scaling bounds (min/max
  replicas, target metric — CPU and/or a custom #688 metric) extending the
  `scalable` model.
- **(b)** Scale-**up** under load — pods grow to meet demand.
- **(c)** **SLO holds during** the scale event (error budget bounded while pods
  warm).
- **(d)** Scale-**down** + **no thrash** (stabilization/cooldown respected).
- **(e)** Docs. **(f)** Validation on ai-doc-organizer (#717).

Out of scope: cluster/node-pool autoscaling — pod-level (HPA) only.

## Epic 3 — chaos/resilience (#724)

Inject faults **while load runs** (#722); assert graceful degradation + recovery.
Children:

- **(a)** Chaos tooling selection + wiring (candidates: Chaos Mesh / LitmusChaos
  for pod+network faults; Toxiproxy for backing-service latency/errors).
- **(b)** Fault scenario library: **pod kill** (survivable at ≥2 pods per #720),
  **backing-service fault** (latency/errors → assert degradation, not cascade),
  **network partition/latency**.
- **(c)** Resilience assertions under load: error budget stays bounded during the
  fault; recovery to baseline SLO within a **declared** window.
- **(d)** Docs. **(e)** Validation on ai-doc-organizer (#717).

Out of scope: region/zone failover, data-durability/backup-restore.

## Dependencies & sequencing

- **#722 blocked by:** #720 (k8s render/deploy), #688 (telemetry); needs #682
  images; ai-doc validation needs #717.
- **#723 blocked by:** #722 (load source) + #720 (`scalable` flag).
- **#724 blocked by:** #720 (≥2 pods so pod-kill survives) + #722 (load source).
- Overall order: **#682 → #717 → #719 (compose) → #720 (k8s) → #722 (load/perf)
  → #723 (autoscaling) → #724 (chaos).**

## Open items flagged for review

- **Target environment mechanism** (child #722-d): a persistent capable cluster vs
  a provisioned-per-run beefier ephemeral env is left to that child; the design
  only fixes that it is *not* the per-PR kind/k3d cluster.
- **perf-spec vs deploy-spec**: sibling artifact or a `perf:` block within
  `deploy-spec` — decided at #722-a implementation.

## Acceptance (umbrella, all three)

- [ ] A service publishes its SLO envelope (`perf-spec`) with its image; the
      composition repo consumes it without touching the repo.
- [ ] #722: k6 runs load/stress/spike/soak profiles against a realer k8s target on
      a schedule; the per-service SLO envelope gates via k6 thresholds; a report is
      produced.
- [ ] #723: under #722's load, HPA scales up, the SLO holds, and pods scale back
      down without thrash — for services that declare autoscaling bounds.
- [ ] #724: faults injected under load keep the error budget bounded and the
      system recovers within the declared window.
- [ ] Each epic has user-facing documentation and is validated on the split
      ai-doc-organizer constellation.
