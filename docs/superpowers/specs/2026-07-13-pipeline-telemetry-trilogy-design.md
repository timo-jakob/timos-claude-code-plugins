# Pipeline telemetry trilogy — telemetry/v1 contract, full instrumentation, downstream-outcome enrichment

**Date:** 2026-07-13
**Supersedes:** epic #592 (review-loop observability) and its children #593–#597.
**Relation:** consumes nothing from the WebUI chain (#682/#683); fully parallel to it.

## Motivation

Epic #592 was filed when the review loop (#566) was the only telemetry stream.
That is no longer true: refine-issue telemetry (#579, shipped #735) was built by
copy-adapting the review-loop builder — same sink convention
(`.claude/telemetry/*.jsonl`, git-ignored), same envelope-ish fields
(`ts, issue, wall_s, tokens:null`), duplicated zsh/jq scaffolding, **no shared
contract**. Every future stream (resolve-issue, maintenance, bootstrap,
acceptance, approver) would copy-adapt again and drift further.

Meanwhile the consumers have been clarified. Telemetry serves **all three** of:

1. **A human** glancing at a repo's pipeline health.
2. **A cross-repo reporting repo** (separate, owner-created) running **Grafana**
   over many repos' telemetry.
3. **The plugin self-improvement loop** (the #414 session-log handoff's
   structured sibling): deciding budgets, review depth, where refinement stalls.

And the measures have been challenged: today's records capture **process
counters** (rounds, findings fixed/waived, objections resolved) but say nothing
about **outcomes** (did the PR merge? how many CI rounds to green? what did the
Approver say? was it reverted?) or **cost** (`tokens` is a null placeholder,
`wall_s` optional). Convergence rate measures the loop's churn, not whether the
work was good or cheap.

This design replaces #592 with **three sequenced epics** (the #722/#723/#724
pattern): contract + retrofit → instrument everything → enrich with downstream
outcomes.

## Decisions (settled in brainstorming, 2026-07-13)

| Decision | Choice |
|---|---|
| Primary consumer | All three (human, cross-repo Grafana, self-improvement) — the contract is the deliverable |
| Reach | Versioned contract; **every** pipeline instrumented (epic 2) |
| Grafana path | JSONL → cross-repo sink directory → the **separate reporting repo** runs Grafana (compose stack + file-reading datasource). Zero new deps in the plugins; skills stay offline-safe |
| Human reports | Drop CSV (#595) + HTML one-pager (#596) as superseded by Grafana; keep a **thin jq rollup** as the infrastructure-free glance |
| Measures | Process counters **plus downstream outcomes**, via append-only enrichment records (epic 3). `tokens` stays best-effort/null until reliably measurable — never guessed |
| Local sink | **One file per repo**: `.claude/telemetry/telemetry.jsonl` (fields discriminate); cross-repo sink mode `DIR/<repo-slug>.jsonl` (as built — see below) |
| GitHub packaging | **Close #592 superseded**; file 3 fresh epics chained with native blocked-by (#583) |

Constraints carried over from #592 and repo policy: no third-party
dependencies in the plugins (zsh + `jq`, stdlib-only `python3` escape hatch);
records self-identify by `repo`; the cross-repo output directory is the hand-off
point to the reporting repo; reported numbers must be reliable or withheld.

## The `telemetry/v1` contract

One JSON object per line (JSONL), two kinds, one versioned envelope:

```jsonc
{
  "schema": "telemetry/v1",
  "kind": "run",                        // "run" | "enrichment"
  "run_id": "review-loop-1752403000-8f3a", // <pipeline>-<epoch>-<4 hex rand>; the join key
  "parent_run_id": null,                // e.g. a review-loop run inside a resolve-issue run
  "ts": 1752403000,                     // unix seconds
  "repo": "owner/name",                 // remote-derived; basename fallback (from #593)
  "repo_type": "python",                // nullable (claude-plugin repos, etc.)
  "pipeline": "review-loop",            // OPEN identifier [A-Za-z0-9._-]+, not a closed
                                        // enum. Conventional: review-loop | refine-issue |
                                        // resolve-issue | maintenance | approve |
                                        // bootstrap | acceptance | …
  "issue": 123,                         // nullable linkage
  "pr": 456,                            // nullable linkage
  "outcome": "success",                 // success | parked | escalated | failed
  "wall_s": 312,                        // REQUIRED on run records (no longer optional)
  "tokens": null,                       // best-effort; null until the harness exposes it
  "payload": { }                        // pipeline-specific detail (schema owned per pipeline)
}
```

Rules:

- **The envelope is closed; `payload` is open.** Everything bespoke
  (`rounds`, `findings_by_round`, `fixed`, `waived`, `objections_*`,
  `park_type`, `risk_classification`, …) moves into `payload`. The top-level
  `outcome` enum stays at 4 values so cross-pipeline dashboards can group on
  it; pipeline-specific detail (e.g. *which* park type) lives in `payload`.
- **`wall_s` is required** on `kind: "run"` records and **`null` on
  enrichments** — it is a run measure, and both the emitter and the validator
  enforce that. `tokens` remains nullable and is never estimated (reliability
  rule).
- **`run_id`** is `<pipeline>-<epoch>-<4 hex rand>`; `parent_run_id` links
  nested runs (review-loop inside resolve-issue).
- **Every `kind: "enrichment"` record carries a non-empty `payload.event`**
  naming which enrichment it is — conventionally `pr_outcome` (epic 3 below) or
  `suggestion_promotion` (#995). `kind` says *that* a record is an enrichment;
  `event` says *which* one, and each pass's work-finding scan joins on its own
  event. The validator does **not** enforce it (`payload` is open by design), so
  it is a rule each emitting pass keeps.
- **Emission is shared code, not convention.** One emit script + one contract
  validator at `development/scripts/telemetry/` (new plugin-level shared home,
  referenced by skills via the family's `<skill-base-dir>` placeholder —
  `<skill-base-dir>/../../scripts/telemetry/emit-telemetry.zsh`), bats-tested. The two
  existing builders (`build-telemetry-record.zsh`,
  `build-refine-telemetry-record.zsh`) are replaced by thin per-pipeline
  payload builders feeding the shared emitter.
- **Legacy records** (no `schema` field) are handled by a v0→v1 jq adapter in
  the rollup; no file migration is performed.
- **Versioning:** breaking envelope changes bump to `telemetry/v2`; `payload`
  evolution is per-pipeline and non-breaking by definition.

### Sink layout

- **Local default:** `<repo-dir>/.claude/telemetry/telemetry.jsonl` (git-ignored).
  One stream; `pipeline`/`kind` fields discriminate. The old per-pipeline
  files remain readable as legacy, and stop being written once children (b)/(c)
  retrofit the two streams.
- **Cross-repo sink mode:** `--telemetry-dir DIR` → append to `DIR/<repo-slug>.jsonl`
  (no cross-repo clobbering; the reporting repo globs `*.jsonl`). Precedence:
  `--telemetry-file` > `--telemetry-dir` > local default (as #593 specified).
  **As built (child (d), #1006)** the filename is `<owner>-<name>` only in the
  normal case; in general it is a *sanitized, case-folded* projection of the
  resolved `repo` — which is itself only `owner/name` in the normal case, since
  the basename fallback and a caller-supplied `--repo` are equally possible
  sources. That projection is deliberately **many-to-one**,
  so it is not a per-repo-file guarantee: a consumer groups by the record's
  `repo` field, never by filename. The emitter alone accepts the flag — no
  pipeline forwards it yet. ARCHITECTURE.md's *Cross-repo sink mode* bullet is
  the normative statement of both the slug rules and that open gap.

## Epic 1 — contract + retrofit + Grafana-ready hand-off

Children:

- **(a)** `telemetry/v1` schema doc (ARCHITECTURE.md section) + shared emitter +
  contract validator scripts + bats.
- **(b)** Retrofit **review-loop**: payload builder over the shared emitter;
  `repo` field; existing loop bats stay green.
- **(c)** Retrofit **refine-issue**: same.
- **(d)** `--telemetry-dir` cross-repo sink support, stream-generic (absorbs #593's
  scope beyond the review loop). **As built (#1006) this is the *emitter's*
  capability only**: it is stream-generic in the sense that any pipeline's
  records can go to a cross-repo directory, not in the sense that any pipeline
  *forwards* the flag — none does. Per-pipeline forwarding is unclaimed by any
  filed child and belongs naturally to epic 2; ARCHITECTURE.md's *Cross-repo
  sink mode* bullet is normative on that gap.
- **(e)** **Thin rollup** (reshapes #594): a jq summary over any stream —
  per-pipeline run counts, outcome mix, mean rounds/wall, escalation rate —
  filterable by `--repo`/`--pipeline`. CLI-only, no HTML/CSV.
- **(f)** **Grafana hand-off contract**: a doc defining exactly what the
  reporting repo ingests (the cross-repo sink directory, the glob, the envelope, the join),
  plus one **reference Grafana dashboard JSON** committed here as that repo's
  starting point. The Grafana stack itself is the reporting repo's concern —
  out of scope here.
- **(g)** User-facing docs (absorbs #597).

Closes when both existing streams emit v1 and the rollup reads them.

## Epic 2 — instrument every pipeline

One child per pipeline, each deciding its **relevant `payload`** against the
settled contract (the envelope is fixed; only payload design is open per child):

- **resolve-issue (story)** — outcome, PR link, validation result,
  child `run_id`s of nested review-loop runs (`parent_run_id` from their side).
- **resolve-issue (epic mode)** — children resolved, parallel vs sequential,
  holistic end-to-end test result.
- **maintenance orchestrator** — findings by tool/source, groups planned,
  PRs opened/merged, ci-fixer rounds, escalations.
- **bootstrap** — mode (fresh / State-D gap-fill), languages detected,
  steps completed/skipped.
- **acceptance stage** — interface, pass/fail counts, report artifact link.
- **approver** — verdict, confidence, risk-register size, PR type.
  **Known constraint, decided in that child:** approver agents live in the
  language plugins, which cannot reference the development plugin's shared
  scripts (cross-plugin paths don't resolve at install time). Options: vendor
  the tiny emitter per plugin, or defer approver telemetry.

Blocked by epic 1 (needs the contract + shared emitter).

## Epic 3 — downstream-outcome enrichment

Run records are written before their PR's fate is known. Enrichment is
**event-sourced**: never rewrite a line; append `kind: "enrichment"` records
joined by `run_id`.

- **Mechanism:** an enrichment pass (skill or script; `/loop`-able, on-demand)
  scans run records with `pr != null` that lack a **`success`** enrichment
  record **of its own `payload.event`**, queries `gh` for settled facts, and appends one enrichment record per
  run whose **`payload`** carries `event: "pr_outcome"` (the required enrichment
  qualifier — see below), `merged` (bool), `merge_ts`,
  `ci_rounds_to_green`, `approver_verdict`, `reverted`. Those are payload keys,
  not envelope keys — the envelope is closed at 14, so a top-level reading would
  be rejected by the shared validator.
  Keying the scan on a *successful* enrichment is what makes a `failed` one
  retryable: a transient `gh` error must not permanently mark the run enriched.
  The `payload.event` qualifier became load-bearing with #995: the review-loop
  sink now also carries a `suggestion_promotion` enrichment (same `kind`, same
  `pipeline`, `outcome: "success"`), so an unqualified predicate would read it
  as *this run's PR facts are settled* and orphan them permanently. Name this
  pass's own event and filter on it.
- **Not-yet-settled runs are SKIPPED, not enriched.** A run whose PR is still
  open gets **no** enrichment record. Because enrichment is append-only and the
  scan predicate is "lacks a `success` enrichment record **of its own
  `payload.event`**", writing a `success` record early would mark the run
  enriched forever and permanently lose the
  merge and CI facts it was waiting for. **An open PR is the only skip
  condition**: once the PR is merged or closed the run counts as settled and is
  enriched on the next scan. `reverted` is captured *as of enrichment time* — a
  revert landing later is out of scope for this mechanism (a future revert sweep
  would append a further enrichment record, never rewrite one), so waiting on one
  is not a reason to defer. Nulls are for facts `gh` cannot settle at enrichment
  time, not a licence to postpone enrichment indefinitely.
- **Reliability rule applied:** `reverted` is `true` only on an explicit
  revert-commit match referencing the squashed PR; otherwise `null` — never
  inferred. Same for any field `gh` can't settle: null, not guessed.
- **Consumers:** the rollup and the reference dashboard learn the
  `run_id` join (run × enrichment).

Blocked by epic 2 (needs PR-linked records across pipelines to have anything
worth enriching — review-loop/refine-issue runs alone rarely carry `pr`).

## GitHub restructuring

- **Close #592** with a superseded-by comment linking the three new epics and
  this spec.
- **Close #593, #594, #597** folded into epic 1's children (a)/(d)/(e)/(g)
  with pointer comments; **close #595 (CSV), #596 (HTML one-pager)** as
  superseded by the Grafana path + thin rollup.
- **File 3 fresh epics** titled in the trilogy convention
  (`Epic: pipeline telemetry (1/3) — …`), `epic`-labeled, chained with
  GitHub-native blocked-by (#583): 1 → 2 → 3.
- Epic 1 is runnable immediately and stays the parallel quick-win track next
  to the #683 chain.

## Out of scope

- The cross-repo reporting repo itself (Grafana stack, provisioning,
  aggregation service) — separate, owner-created; this trilogy defines its
  ingestion contract and reference dashboard only.
- Real-time/push metrics (OTLP/Prometheus at emit time) — rejected: adds a
  network + infra dependency to every CLI skill run.
- Token-cost measurement — the `tokens` field stays reserved until the harness
  exposes a reliable number.
- Session-log handoff (#414) — a separate, Claude-facing channel; unchanged.

## Risks

- **Schema churn after epic 2 starts:** mitigated by the closed envelope /
  open payload split — pipeline children can't break the envelope.
- **Cross-plugin sharing for the approver:** acknowledged above; decided in
  that child, not silently assumed.
- **Legacy jq one-liners break** (per-pipeline file paths + renamed fields):
  accepted; the stream-generic rollup replaces them and ships in the same epic
  as the retrofit.
