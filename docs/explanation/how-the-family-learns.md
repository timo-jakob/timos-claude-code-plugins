# How the family learns

The workflow pages describe a single run: one issue refined, one story resolved, one repository bootstrapped, one
maintenance pass. This chapter is about what sits above the runs:

- **positions** — the decisions about *what* the family should build, stated before anything builds them;
- **telemetry** — what every run records about how it went;
- **the self-improvement loop** — how that evidence turns into a better version of the plugins.

Parts of all three are not built yet. Each section says what ships today and what is still planned, with the issue
that tracks it, so you can tell a mechanism from an intention.

## Positions: what the family should do {#learn-positions}

A **position** is an architectural decision stated in the family's own words, with its rationale, before — and
independently of — any machinery that implements it. Positions are the concrete form of the second pillar,
[Never asks "how"](philosophy.md#pillar-2): a story is refined and built *against* them, so the question is settled
once for every repository instead of being answered again in each one.

Each position lives in a section of `ARCHITECTURE.md`, and each has its own bats suite that pins the stance clause by
clause, so it cannot be softened by an edit that nobody noticed.

| Position | The stance, in short | What delivers it today | What is still open |
| --- | --- | --- | --- |
| Messaging (#1060) | NATS JetStream as the event backbone; every event a CloudEvents 1.0 envelope; at-least-once delivery, idempotent consumers, a transactional outbox | Nothing yet — a stated position no plugin scaffolds | All of the machinery; currently unscheduled |
| Browser UI (#1059) | A SPA shell with micro-frontends; React and TypeScript by default; a `mount`/`unmount` contract over import maps | The `mfe-contract/v1` contract (#1123) | The shell, remote and conformance halves (#1124–#1126) |
| Deployment (#1189) | The infrastructure repo is the only path to the cluster; immutable image references, never mutable tags | A required check in every bootstrapped repo that fails a direct-to-cluster deploy (#1206); kube-linter flags `latest` | The ko publish path (#1208); plane-per-namespace and secrets have no enforcer yet |
| Identity (#1186) | OIDC at the edge with Keycloak, PKCE for browser flows; tenant and roles as validated JWT claims | The position and its tests | The realizations (#1321–#1326), the security reviewer's deepening (#1327), and the API-proxy template that still contradicts it (#1328) |

**How a position reaches a repository.** There is no single path; each position uses whichever fits:

- a **bootstrap template** when a service cannot comply without boilerplate — the direct-to-cluster deploy check is one;
- a **review dimension** when a violation is visible in a diff — resilience is one;
- a **maintenance advisor** that audits an existing repository against it, such as the ops-surface conformance check;
- **refinement**, which scores each recommended answer on consistency with the repository and its positions;
- the **Approver**, which reads the review dimensions' findings for the PR it approves.

**What is planned.** Today the positions are sections of a long document, found by reading it. A machine-readable
`positions/v1` registry (#1626) would let refinement, review and maintenance query them directly. Some intentions have
no position at all yet: whitelabelling is one theme-token field in the micro-frontend contract that no repository
renders (#1899), and internationalisation has no position, template or issue.

## Telemetry: what every run records {#learn-telemetry}

Every pipeline writes **one record per run ending** — not one per run, and never one per review round. A run that
escalates, is granted more rounds and finishes writes two: one for each ending.

| Pipeline | When it writes |
| --- | --- |
| review loop | At each terminal exit: converged, converged with residue, escalated, failed |
| refine-issue | Once per issue refined; an epic walk writes one per child |
| resolve-issue | Once per story that reaches the dependency precheck; an epic writes one per invocation, linked to its children |
| maintenance | Once per run that passes discovery |
| bootstrap | Once, at whichever ending it reaches, into the *target* repository |
| story pre-flight | The size pre-flight's verdict: pass, stop or overridden |

**The envelope.** Every record shares one closed envelope, `telemetry/v1`: a `run_id` that joins related records, the
`pipeline`, the `repo` and its type, the `issue` and `pr`, an `outcome` of `success`, `parked`, `escalated` or
`failed`, the wall-clock time, and an open `payload` each pipeline fills with its own measures — rounds, findings per
round, how many were fixed or waived, gate times per step.

**Where it goes, and what it leaves out.** Records are appended to `.claude/telemetry/telemetry.jsonl` in the
repository, which is git-ignored. Nothing is sent anywhere: the emitter speaks no network protocol. No code, no diffs
and no prose are recorded — not even a finding's title. Token counts stay empty rather than estimated, and the stream
is lossy on purpose: a telemetry failure never fails a run, so the sink undercounts. It is evidence, not an audit log.
[Pipeline telemetry](pipeline-telemetry.md) explains each of these choices.

**Reading it.** `rollup-telemetry.zsh` summarises a sink per pipeline — run count, outcome mix, mean rounds, mean
wall-clock, escalation rate — and withholds any figure it cannot compute honestly. `validate-telemetry.zsh` checks
records against the envelope. The review loop's progress line uses past records to estimate how long a running step
has left. [Read your pipeline telemetry](../how-to/read-pipeline-telemetry.md) walks through all three.

**Across repositories.** This repository ships a reference Grafana dashboard and a manifest of the envelope fields
each panel reads, kept honest by CI. The Grafana stack itself, its data source and its hosting live in a separate
reporting repository — [The Grafana hand-off](telemetry-grafana-handoff.md) explains the split.

**What it is for.** The numbers change how the family behaves. The review loop's budget is the example: runs that took
one, three, three, three, six and ten rounds to converge are why the budget is five rounds rather than three.

**What is planned.** Some pipelines still have no record — the acceptance stage and the Approver (#741). Records
about what happens *after* a PR opens — whether it merged, how many CI rounds it took to go green, what the Approver
said, whether it was reverted — are designed but not built (#742); today the only such enrichment records a promoted
suggestion.

## The self-improvement loop {#learn-self-improvement-loop}

The family is developed with itself. Its own issues are refined with `/development:refine-issue`, built with
`/development:resolve-issue`, and maintained with `/development:maintenance` — and what those runs reveal is how the
next version gets better. This is the sixth pillar, [The AI owns a self-optimising loop](philosophy.md#pillar-6), and
it is the least finished of the six.

![The self-improvement loop: runs produce evidence, evidence becomes issues, issues become a release, and the release
changes the next runs](diagrams/improvement-loop.svg)

| Stage | What happens | Today |
| --- | --- | --- |
| **Run** | The workflows run on target repositories and on this repository itself; this repository's own C4 docs, for example, are checked by the same rules it ships | Automated |
| **Evidence — telemetry** | One record per run ending, as above | Automated, best-effort |
| **Evidence — session logs** | `scripts/capture-session-log.zsh` bundles a run's transcript and its subagents' transcripts into one archive that is handed back for analysis | Manual: captured on request |
| **Evidence — issues** | Review residue is filed as follow-up issues; maintenance keeps one debt issue per scanner; a non-converging run escalates with a typed comment | Automated |
| **Analysis** | Someone reads the evidence and decides what to change | Manual today; a retrospective skill, a self-assessment scorecard and eval suites are planned (#1624) |
| **Improvement issue** | The change is filed as an issue on this repository — and so are the gaps between a stated position and what is delivered | Residue and debt issues automated; the rest by hand |
| **Refine and resolve** | The issue goes through the same workflows as any other | Automated; a human approves plugin PRs |
| **Release** | Each change bumps its plugin's version and marketplace entry; CI checks the two agree | Bump by the agent or by hand; the check is automated |
| **Pickup** | Locally, `scripts/refresh-local-install.zsh` reinstalls the released plugins. In a bootstrapped repository, generated files carry a provenance marker; maintenance reports which ones have drifted from the current templates, and a monthly workflow keeps a tracking issue open while they do | Detection automated; applying the fix is manual |

The gap in the middle is the one that matters: today the loop *captures* runs, but a person still assesses them and
decides what to change. Closing that gap — assessment, learning, and proof that a change actually helped — is the
purpose of #1624. [Maintain this repo](../how-to/maintain-this-repo.md) describes how a captured run is fed back today.
