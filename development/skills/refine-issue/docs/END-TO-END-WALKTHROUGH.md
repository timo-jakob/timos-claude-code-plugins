# End-to-end walkthrough: `needs-refinement` → `story-spec` → resolved PR

This is the documented reference run for epic
[#573](https://github.com/timo-jakob/timos-claude-code-plugins/issues/573) (the
AI-assisted refinement loop). It traces **one** surface-touching story through
every stage — the readiness gate, interactive refinement, the interface-aware
check 5, test-case spin-out, re-gating, and `resolve-issue`'s same-PR
implementation — showing the machine-readable artifact at each hop. A fresh
reader can follow it to run the workflow; it is also the validation artifact for
[#581](https://github.com/timo-jakob/timos-claude-code-plugins/issues/581).

Every primitive named below is a real, tested script under
`development/skills/{refine-issue,resolve-issue}/scripts/` — plus the shared
`development/scripts/telemetry/`, the cross-skill home the `telemetry/v1` emitter
lives in — and the walkthrough uses them exactly as the skills do.

---

## The example story

An underspecified REST feature, filed as a plain issue:

> **Title:** Add a job-filing endpoint
> **Body:** Dispatchers need to file jobs from the depot floor. Add an endpoint.

## Stage 1 — the gate says "not ready"

`/development:resolve-issue` (or the epic pre-flight) spawns `story-readiness`.
The story touches a `rest` surface but has no acceptance criteria, no `use_case`,
and no test cases, so **check 5 (outside-in testability, #670)** fails:

```json
{
  "issue": 900,
  "verdict": "NEEDS_REFINEMENT",
  "risk": "normal",
  "surface": ["rest"],
  "checks": {
    "acceptance_testable": false, "scope_bounded": true,
    "dependencies_resolved": true, "no_contradictions": true,
    "outside_in_testable": false
  },
  "refinement_questions": [
    "This REST story defines no test cases — add a happy path (POST /jobs -> 201), a corner case, and an error case (oversized payload -> 413).",
    "Give a concrete use_case: which actor, what goal, and representative request data?"
  ]
}
```

The skill posts the questions, applies `needs-refinement`, and stops. **No code
is written on a story the gate can't trust.**

## Stage 2 — guided refinement (`/development:refine-issue 900`)

A human runs `refine-issue`. It re-diagnoses with the gate, then loops the
`issue-refiner` agent — relaying its explanation / questions / recommendations
and collecting the human's answers — until every objection is resolved. The human
approves the rewrite: prose plus a proposed `story-spec/v1` block whose
`interface_surfaces` is `["rest"]`, with a concrete `use_case` and outside-in
`test_cases` (each `issue` still `null` — the links come next):

```json
{
  "schema": "story-spec/v1",
  "acceptance_criteria": ["POST /jobs files a job in under 200 ms", "a 40 KB note is rejected, no partial write"],
  "interface_surfaces": ["rest"],
  "use_case": { "actor": "dana-dispatcher", "goal": "file a job from the depot floor", "data_sketch": "job_ref JOB-2291, site 'Müller & Sons'" },
  "test_cases": [
    { "id": "tc-happy-file-job",   "kind": "happy", "shape": "POST /jobs {job_ref, site_name} -> 201", "tooling": "curl", "issue": null },
    { "id": "tc-error-oversized",  "kind": "error", "shape": "POST /jobs with a 40 KB note -> 413",    "tooling": "curl", "issue": null }
  ]
}
```

Realistic data (`Müller & Sons`, not `foo`) is mined from the repo's persona
registry (`personas/v1`, epic
[#664](https://github.com/timo-jakob/timos-claude-code-plugins/issues/664),
docs child #669) — personas are **advisory**, never a hard fail.

### Test-case spin-out (#671)

Before writing the block back, `refine-issue` (Step 2.5) reconciles the
`test_cases[]` into linked `test-case` issues:

```console
$ test-case-spinout.zsh --repo owner/app --story 900 --spec approved-spec.json
test-case-spinout.zsh: created #901 ← tc-happy-file-job
test-case-spinout.zsh: created #902 ← tc-error-oversized
[{"id":"tc-happy-file-job",...,"issue":901},{"id":"tc-error-oversized",...,"issue":902}]
```

The reconciled array (now carrying `issue: 901` / `902`) is spliced into the
block, which is written back with a provenance hash over the approved prose. The
spin-out is idempotent on re-refinement — a dropped case closes its orphaned
issue with a comment.

### Re-gate + telemetry

`refine-issue` re-runs `story-readiness` on the edited issue. Now check 5 passes
(concrete `use_case`, happy+error test cases in `curl`, both spun-out issues
exist and are linked), so the verdict is `READY` and the `needs-refinement` label
is cleared. One `telemetry/v1` record is appended to the shared sink
`.claude/telemetry/telemetry.jsonl`, which bootstrap git-ignores (#579,
retrofitted onto the contract by #1005). The envelope comes from the shared
`emit-telemetry.zsh`, the five bespoke fields from
`build-refine-telemetry-record.zsh` as the `payload`, and the run's
`refined-ready` ending narrows onto the envelope's `success`. (The stream
is deliberately **lossy** — Step 7 skips the record rather than fabricate an
unmeasured `wall_s`, count, outcome or park type.)

To read these records back, see
[Read your pipeline telemetry](https://timo-jakob.github.io/timos-claude-code-plugins/how-to/read-pipeline-telemetry/);
for what is and is not collected, and why, see
[Pipeline telemetry](https://timo-jakob.github.io/timos-claude-code-plugins/explanation/pipeline-telemetry/).

```json
{"schema":"telemetry/v1","kind":"run","run_id":"refine-issue-1720000000-8f3a","parent_run_id":null,"ts":1720000000,"repo":"owner/app","repo_type":null,"pipeline":"refine-issue","issue":900,"pr":null,"outcome":"success","wall_s":180,"tokens":null,"payload":{"rounds":2,"objections_raised":2,"objections_resolved":2,"park_type":null,"risk_classification":"normal"}}
```

> **Can't converge in one sitting?** `refine-issue` takes a **typed parked exit**
> (#578) — `needs-decision` / `split-recommended` / `deferred` — that records the
> open questions + conversation in a machine-findable comment (`build-parked-comment.zsh`)
> and keeps the label; a later run resumes from it (`read-parked-state.zsh`),
> and telemetry records the envelope's `outcome: "parked"` with the specific
> `park_type` in the `payload`.
>
> **A halted epic with several parked children?** `refine-issue` pointed at the
> epic walks each `needs-refinement` child through this same flow
> (`list-refinement-children.zsh`, #580), then posts an epic-level summary.

## Stage 3 — `resolve-issue` consumes the block (#577) + same-PR tests (#696)

Now `/development:resolve-issue 900` implements it. Step 0b re-gates (the block is
fresh and consistent — the gate guaranteed it), then Step 2 extracts the block as
its authoritative structured interface:

```console
$ gh issue view 900 --json body -q .body | read-story-spec.zsh
{"schema":"story-spec/v1","acceptance_criteria":[...],"test_cases":[{...,"issue":901},{...,"issue":902}]}
```

`acceptance_criteria` / `testable_checks` drive validation; `scope_boundaries`
bound the change. Because the block carries **linked** `test_cases[]`, the
same-PR test-case lifecycle (#696) plans an acceptance test per case:

```console
$ read-story-spec.zsh --file body.md | plan-acceptance-tests.zsh
[{"issue":901,"id":"tc-happy-file-job","kind":"happy","tooling":"curl","dir":"tests/acceptance/rest"},
 {"issue":902,"id":"tc-error-oversized","kind":"error","tooling":"curl","dir":"tests/acceptance/rest"}]
```

resolve-issue writes the feature **and** one acceptance test per case under
`tests/acceptance/rest/` (the #243 convention; representative data from
`use_case` + persona `data_traits`), validates the whole suite, and opens a
bot-authored PR whose body closes the story and both test-case issues together:

```text
Closes #900
Closes #901
Closes #902
```

Feature and its acceptance tests land in one PR — they can never drift. A story
with **no** linked test cases (older / no-surface) falls back cleanly to a
feature-only PR.

---

## The chain, end to end

| Stage | Skill / primitive | Artifact |
| --- | --- | --- |
| Gate says no | `story-readiness` (#559, #670) | `NEEDS_REFINEMENT` + check-5 questions, `surface: ["rest"]` |
| Refine | `refine-issue` + `issue-refiner` (#575/#576) | human-approved prose + proposed `story-spec/v1` |
| Spin out | `test-case-spinout.zsh` (#671) | linked `test-case` issues #901/#902 |
| Re-gate | `story-readiness` (#574 validation) | `READY`, label cleared |
| Telemetry | `build-refine-telemetry-record.zsh` → `emit-telemetry.zsh` (#579, #1005) | one `telemetry/v1` record |
| Consume | `read-story-spec.zsh` (#577) | the block as structured input |
| Same-PR tests | `plan-acceptance-tests.zsh` (#696) | acceptance tests + joint `Closes #N` |

Definition is more work than implementation — and that is the point: the better
the story is specified, the fewer defects reach the product. See
[ARCHITECTURE.md](../../../../ARCHITECTURE.md) → *Story-spec contract*,
*Test-case issue convention*, and *Persona registry contract* for the field-level
schemas these stages exchange.
