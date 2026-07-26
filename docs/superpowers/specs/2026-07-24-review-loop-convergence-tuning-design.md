# Review-loop convergence tuning + human-curated suggestion promotion

**Date:** 2026-07-24
**Status:** Design approved; epic filed
**Provenance:** telemetry analysis — `.claude/telemetry/review-loop.jsonl` (14 records, 6 distinct
issues) and `refine-issue.jsonl` (9 records)

## Motivation

Two findings from the recorded review-loop telemetry:

1. **The 3-round default escalates the hard tail prematurely.** Rounds-to-converge across
   the 6 distinct issues were 1, 3, 3, 3, 6, 10 — median 3, but two issues (#976→6, #969→10)
   exceeded 3. Because the round cap is an *upper bound* (the loop stops the moment blocking
   findings reach 0), raising it is **free for the four easy issues** — they still converge
   early — and only affects the hard tail, where a larger initial budget means **fewer human
   approval round-trips** (e.g. #969 drops from 3 grants to 2). Convergence is also
   **non-monotonic** (blocking findings rise again in later rounds as fixes surface new
   problems — #969 went 9→4→3→2→**3**→2→1→**3**→2→0), so a longer leash before escalating
   reduces *premature* escalations of runs that would have self-resolved.

2. **Suggestions are logged but never acted on.** In telemetry, `waived` is mechanically
   *"every distinct Low/Suggestion finding"* (`build-telemetry-record.zsh`, the `waived` field;
   `consolidate-findings.zsh` (the severity-bucket comment) — "Low is logged in `suggestions`, never blocks"). A
   Suggestion is "waived" the instant it is surfaced because Suggestions are non-blocking by
   definition. There is no mechanism for a human to say "actually, do this one." The
   suggestion volume is dead data.

## Guardrail — quality unchanged

- Suggestions remain **non-blocking by default**. Nothing is auto-promoted.
- Promotion is **human-opt-in only**; autonomous/headless runs are **unchanged** (converge as
  today, suggestions waived).
- Existing severity standards, the full-suite gate every round, and every genuine escalation
  are untouched. This change adds an opt-in polish phase and tunes two budget numbers — it
  does not relax any bar.

## Changes

### Child 1 — round-budget + increment tuning (do first)

- `MAX_REVIEW_ROUNDS` `3 → 5` (`resolve-story-loop.zsh` (the `MAX_REVIEW_ROUNDS` constant)).
- Human-approved extension increment `+2 → +3` (prose: `SKILL.md` — the
  `--resume`, ceiling raised by 2 line AND every `+2` in the AskUserQuestion
  grant options;
  `docs/explanation/review-loop.md:76`).
- `--max-rounds` flag still overrides. Soft-cap of 5 grants stays as a *nudge* (not a hard
  stop); note the raised theoretical ceiling (5 + 5×3 = 20 rounds) but do not tighten it here.
- Keep all restatements consistent: `ARCHITECTURE.md` (the review-loop
  "Constants live at the top" line, and the loop-flow restatement below it);
  `docs/explanation/review-loop.md:52`.

### Child 2 — human-curated suggestion promotion (after Child 1)

New interactive branch on the **`CONVERGED`** exit of the initial blocking phase, gated on
*human present AND ≥1 waived suggestion*:

1. Render the waived suggestions as a numbered list (title · `file:line` · dimension).
2. **Multi-select** which to promote (0..N) — `AskUserQuestion` `multiSelect` for ≤4,
   chunked / numbered-reply fallback for larger sets. *(Superseded during implementation —
   the shipped rule is at most **3** suggestions per question so the fourth option carries a
   labelled decline; see SKILL.md step 3.)*
3. Selected suggestions are promoted to blocking via a **promotion overlay in the
   consolidator** (mechanism A). *(Superseded during implementation — the spec said "any
   finding whose identity key `[file,line,dimension,title]` is in the promoted set"; the
   shipped rule deliberately is NOT exact key equality: candidates are gathered on
   `file`+`dimension`+line proximity and the verdict is title identity, so a promoted item
   survives its own fix shifting the line. See ARCHITECTURE.md's promotion-overlay bullet.)*
   The matched finding is severity-bumped to `WARNING` during consolidation for the
   sub-loop. The existing fix→review→converge loop then runs **unchanged**, so regressions
   from fixing a suggestion are caught exactly like any other blocker. (This reuses the
   identity-matching from epic #979 / child #983.)
4. The promotion phase passes **no `--max-rounds` override**: it inherits the loop's own
   `MAX_REVIEW_ROUNDS` (5 since Child 1) and the same `+3`-per-human-approval extension
   machinery as the blocking phase. *(Superseded during implementation — the spec proposed a
   second 3-round budget constant; the shipped rule is deliberately one number for both
   phases. See ARCHITECTURE.md "Review-loop state machine" and `SKILL.md` step 5.)*
5. **One-shot:** new suggestions surfacing during the sub-loop are waived, not re-prompted.
   New *blockers* (regressions) are gated normally.
6. Sub-loop converges → final `CONVERGED`. If it cannot clear the promoted items, it escalates
   via the existing rules (the human opted into making them blocking).

Headless/autonomous: the branch is skipped entirely; the run converges with all suggestions
waived, exactly as today. The loop script stays non-interactive — all interaction is
orchestrated in `SKILL.md`, mirroring the existing interactive-extension precedent
(`SKILL.md`, *Interactive extension*) and the dependency-precheck `AskUserQuestion` precedent (`SKILL.md:120`).

### Child 3 — promotion telemetry (after Child 2)

> **Superseded during implementation (#995).** This section proposed four new
> payload fields — `suggestions_waived`, `suggestions_promoted`,
> `suggestion_rounds`, `suggestion_phase_status`. None shipped: the phase-1 run
> record is already on disk before the prompt is shown, so it *cannot* carry
> facts the human has not yet supplied. **ARCHITECTURE.md's "The
> suggestion-promotion enrichment (#995)" section is authoritative**; what
> follows records the shipped shape.

The offered-vs-promoted pair is an **append-only `kind: "enrichment"` record**
joined to the phase-1 run by `run_id`, emitted by `SKILL.md` once the human's
multi-select answer is known, with payload
`{event: "suggestion_promotion", suggestions_offered, suggestions_promoted}`.
`kind: "enrichment"` already exists in the contract, so nothing changes in the
envelope, the validator, or the `kind` enum. The schema doc (ARCHITECTURE.md's
telemetry/v1 section) gains exactly one rule — every enrichment must carry a
non-empty `payload.event` — which a *second* enrichment kind makes load-bearing. The join key reaches `SKILL.md`
through a `<work-dir>/.telemetry-run-id` sidecar the loop writes on every
terminal exit that emits a record; an absent or empty sidecar means **no
enrichment**, never a minted id.

Two markers go into the **run** payload instead:

- `promotion_phase` — an always-present boolean, `true` exactly when the
  invocation carried **or adopted** a promoted set (an adopting `--resume`
  counts) — i.e. when it is the promotion sub-loop. The promotion sub-loop is a fresh invocation
  with its own `.t0`, so without this it forms its own `(repo, issue, ts)` group
  and inflates both published rates; the two documented **rate** recipes
  therefore carry `select(.payload.promotion_phase != true)`. The mean-rounds
  and escalation-breakdown cuts deliberately keep it.
- `findings_by_round[].promoted` — the round's human-promoted blockers, a
  **subset** of `by_severity.Warning`, derived from the per-item `promoted: true`
  stamp the overlay now applies.

`suggestions_waived` is not added: the existing `waived` already owns "distinct
Low findings this loop logged", and `suggestions_offered` equals it by
construction against the loop's **final** terminal record (`>=` against an
earlier record of an extended loop — the union grows monotonically; see
ARCHITECTURE.md). `suggestion_rounds` and `suggestion_phase_status` are not added
either — the sub-loop emits its own run record carrying both, keyed by
`promotion_phase`.

Respect the three-copy severity-derivation lockstep — see the comment above
`findings_by_round` in `build-telemetry-record.zsh`, and change
`render-progress-block.zsh` and `build-escalation.zsh` together. Update `ARCHITECTURE.md` telemetry section and
`tests/build-telemetry-record.bats`. This finally yields data on **whether humans act on
suggestions** — the question that motivated the feature.

## Dependencies

Linear chain: Child 1 ← Child 2 ← Child 3. Child 2 tunes-adjacent machinery Child 1 owns;
Child 3 emits from the mechanism Child 2 builds.

## Out of scope

- Auto-promotion heuristics (no ML/rules picking suggestions for the human).
- Changing the soft-cap grant count or the escalation taxonomy.
- Re-prompting / multi-round suggestion curation (explicitly one-shot).
- Any change to autonomous-pipeline behavior.
