# Review-loop step mode — transparent in-session rounds — design

**Date:** 2026-07-23
**Status:** Approved design, pre-implementation
**Issue:** #971
**Builds on:** the local pre-push review loop (epic #557: findings schema
\#558, dispatch #560, consolidation #561, state machine #562, dossier #563,
telemetry #566), the `--resume` interactive extension (#912/#913), and the
enriched escalation summary (#969)

## 1. Context and problem

`resolve-story-loop.zsh` is the review loop's deterministic state machine; its
model-driven steps (run the review panel, apply the fix pass) are injected as
shell hook commands (`--review-cmd`, `--fix-cmd`). A shell hook can only be
"model-driven" by shelling out to a headless `claude -p` — and SKILL.md §3.5
plus the script header explicitly bless that wiring.

Two real epic runs show what that costs:

- **Session `8fae8373` (epic #964, child #965)** followed the documented wiring:
  three hook scripts invoking headless `claude -p`, the whole loop run as one
  background Bash task. The driving session's UI showed only
  `Task Output … (ctrl+o to expand)` while rounds 1–7 ran invisibly for many
  minutes. Zero in-flight transparency.
- **Session `2e743f4f` (issue #969)** improvised the transparent alternative:
  the review panel ran **in-session via the Agent tool** (the visible
  "5 background agents launched" tree, one named agent per dimension), findings
  were serialized to `prepared/findings-round-N.json`, and the loop was invoked
  once per round with `--review-cmd 'cp … "$REVIEW_FINDINGS"'` +
  `--fix-cmd 'false'` + `--resume`, with fixes applied in-session between
  invocations.

The transparent pattern works — the `--resume` machinery already supports it —
but it is an undocumented contortion that one session discovered and another
did not. Whether the user can see anything during a multi-round loop is
currently luck.

**Goal:** make the transparent wiring the first-class, mandated path — no
headless `claude` anywhere in the loop — and give the user two live progress
views: narration in the conversation and a tail-able progress file.

**Non-goals:** transparency for other resolve-issue phases (readiness gates,
epic sequencing — out of scope by decision); removing hook mode (it stays as
the bats-testable seam); any change to the #558 findings schema, #561
consolidation semantics, or the escalation/dossier contracts.

## 2. Design overview

One new script mode, one new non-terminal status, one new progress artifact,
and a rewritten SKILL.md §3.5 protocol. Everything else — dispatch,
consolidation, non-convergence carry, resume repair, escalation, dossier —
is reused unchanged.

## 3. Script contract — step mode

### 3.1 Invocation

New flag: `--findings-file PATH`, mutually exclusive with `--review-cmd` and
`--fix-cmd` (mixing them is a usage error, exit 2; providing neither
`--findings-file` nor `--review-cmd` without `--no-review` stays the existing
usage error). All other flags (`--repo`, `--base`, `--max-rounds`,
`--status-file`, `--work-dir`, `--issue`, `--telemetry-file`, `--test-cmd`,
`--resume`) keep their meaning. As with hook mode, callers pass an explicit
`--work-dir` and `--status-file`.

### 3.2 One invocation = one round

A step-mode invocation processes exactly one round and exits:

1. Per-round dispatch plan (unchanged — including the `ESCALATE_AMBIGUOUS`
   typed escalation on rc 3, #912).
2. Validate and consume the findings file: a present, non-empty file must
   parse as JSON (the #558 aggregate array); a missing or empty file is
   treated as "no findings", consistent with hook mode. It is copied to the round's `findings_path` from
   the dispatch plan, so downstream artifacts land where hook mode puts them.
3. `scope-findings` → consolidate (with `--prev` on resume) → append the
   round's changelist and history line, exactly as today.
4. Decide the round's fate:

   | Round outcome              | Status                    | Exit |
   |----------------------------|---------------------------|------|
   | no blockers                | `CONVERGED`               | 0    |
   | surviving conflict         | `ESCALATE_CONFLICT`       | 11   |
   | blocker survived 2 rounds  | `ESCALATE_NO_CONVERGENCE` | 12   |
   | blockers on last round     | `BUDGET_EXHAUSTED`        | 13   |
   | blockers, budget remaining | **`AWAITING_FIX`** (new)  | **20** |

`AWAITING_FIX` is the only new contract state. It means: the session applies
the blockers' fixes in-session, re-runs the full gate, runs the next round's
review panel, and re-invokes the loop with `--resume` and the new
`--findings-file`. Its status JSON has the same shape as every other status
(`status`, `rounds`, `history`, `round_changelists`, `final_changelist` = this
round's changelist), so existing readers parse it; the terminal-only consumers
(`build-escalation.zsh`, `build-dossier.zsh`) are simply never invoked on it
per SKILL.md.

Round numbering: a fresh step-mode run is round 1; `--resume` continues at
last-completed + 1 using the existing accumulator/repair logic (#913 kill-window
truncation included) — step mode adds no new resume states.

### 3.3 `--test-cmd` placement

In step mode the fix pass happens between invocations, so the gate that guards
it moves with it: when `--test-cmd` is given, a `--resume` invocation runs it
**first**, before consuming the findings file. Red means the prior round's fix
broke the tree → status `ERROR`, exit 1 — the same "red after fix is an
operational abort, never a verdict" semantics as today, kept deterministic in
the state machine rather than trusted to narration. A fresh (non-resume)
step-mode run does not run `--test-cmd`: step 3's gate already ran green before
the loop started, per SKILL.md.

### 3.4 Telemetry and wall clock

Telemetry keeps its "one JSONL record per loop" meaning, where a step-mode loop
spans several invocations: records are appended **only on terminal statuses**
(`CONVERGED`, `ESCALATE_*`, `BUDGET_EXHAUSTED`, `ERROR`, `SKIPPED`), never on
`AWAITING_FIX`. So that the terminal record reports the whole loop's wall
clock, a fresh run writes epoch seconds to `$work_dir/.t0`; the terminal invocation
prefers `.t0` over its own start time when computing `--wall-s`. (A missing
`.t0` — e.g. a pre-existing hook-mode work-dir — falls back to the invocation's
own start, as today. Hook mode itself is unaffected; single invocation = whole
loop.) Reporting only the last round's wall clock would be a
confident-but-wrong figure; `.t0` exists to avoid exactly that.

### 3.5 Hook mode and the headless escape hatch

Hook mode (`--review-cmd`/`--fix-cmd`/`--test-cmd` in its current placement)
keeps working byte-for-byte — it is the seam the bats suite drives the state
machine through, and existing tests must pass unmodified. What changes is the
documentation: the header comment's "(or a headless `claude -p`)" is deleted
and replaced by step mode as the canonical wiring, with hook mode described as
the test seam.

## 4. Progress file — `<work-dir>/progress.md`

The loop itself appends one block per round, in **both** modes, right after
consolidation (and a final line when a terminal status is reached):

```markdown
## Round 2 — blockers remain (14:32:07)
- blockers: 3 (new: 1, carried: 2), conflicts: 0, suggestions: 4
- by dimension: prose_logic 2, tests 1
- next: fix pass, then resume
```

- The new/carried split is derived from the consolidator's per-blocker
  `non_converging` stamps (#913). When any blocker in the changelist lacks the
  stamp (a pre-#913 producer), the line degrades to totals only — no label
  rather than a confident wrong one, matching the #913 guard philosophy already
  applied in `build-escalation.zsh`.
- Terminal blocks name the status and, for escalations, the reasons
  (`escalation_reasons`), so the file alone tells the story of the run.
- The file lives in the work-dir (already excluded from review scope via the
  work-dir prefix filter, #909/#911) and is append-only, so `tail -f` from a
  second terminal follows the loop live and the file survives the session.
- Failures writing progress.md are non-fatal (like telemetry): transparency
  must never abort a run.

## 5. SKILL.md §3.5 — the mandated protocol

The "you provide three hooks" instructions are replaced by the step-mode
protocol:

1. **Panel in-session:** get the dispatch plan (`review-dispatch.zsh plan`),
   spawn the panel skill's reviewers **in-session via the Agent tool** — the
   user-visible agent tree — and aggregate their findings into a #558-schema
   JSON file in the loop's prepared-findings location.
2. **Loop per round:** invoke `resolve-story-loop.zsh` with `--findings-file`
   (plus `--resume` from round 2, `--test-cmd` as the full gate, and the
   always-explicit `--work-dir`/`--status-file`). **At loop start, tell the
   user the progress.md path** ("follow along with `tail -f <path>`").
3. **On `AWAITING_FIX`:** narrate the round summary **in the conversation** in
   the same fixed format progress.md uses (round, blockers new/carried,
   dimensions, what happens next), apply the blockers' fixes in-session
   (visible Edits), re-run the full gate, run the next round's panel, resume.
4. **On terminal statuses:** unchanged — `CONVERGED` proceeds to step 4
   (commit); escalations and `BUDGET_EXHAUSTED` follow the existing escalation
   / interactive-extension path, composing with #969's enriched summary. The
   interactive extension's re-invocation ("resume with `--resume` on the same
   work-dir") now naturally uses step mode.

Two explicit prohibitions, stated in the skill:

- **No headless `claude`** (`claude -p` / `--print`) for any model-driven loop
  step — review, fix, or consolidation-adjacent work.
- **No long-lived background task spanning rounds** — each loop invocation is a
  short foreground step; the model-driven work between invocations happens
  in-session where the user can see it.

## 6. Documentation

- `docs/explanation/review-loop.md`: update the flow description to step mode,
  add a short "why step mode" section (the two-session evidence: opacity of the
  headless wiring vs the visible in-session pattern), and describe progress.md.
- Script header comment: rewritten per §3.5 above.
- SKILL.md: §3.5 rewritten; the escalation/interactive-extension section gets
  only the small touch-ups §5 point 4 implies (wording, not behaviour).

## 7. Testing (TDD, bats)

New cases (new file `tests/resolve-story-loop-step.bats`, or appended to the
existing suite — implementer's choice; existing hook-mode tests must pass
unmodified):

- Fresh step-mode round with blockers → exit 20, `status: AWAITING_FIX`,
  history + changelists each gained one line, progress.md block written.
- `--resume` + next findings file → consolidation carries `--prev`
  (non-convergence detection spans invocations).
- Converged / conflict / non-convergence / budget-exhausted paths through step
  mode → same statuses and exit codes as hook mode.
- Usage errors: `--findings-file` mixed with `--review-cmd` or `--fix-cmd`;
  neither given without `--no-review`.
- Missing/empty findings file → treated as no findings → `CONVERGED`.
- `--test-cmd` red at the start of a `--resume` invocation → `ERROR`, exit 1;
  green → round proceeds. Fresh run: `--test-cmd` not executed.
- Telemetry: no record on `AWAITING_FIX`; exactly one on the terminal
  invocation; `--wall-s` computed from `.t0` when present.
- progress.md: new/carried split rendered when stamps present; totals-only when
  a blocker lacks the stamp; terminal block written; write failure non-fatal.

## 8. Process

- Tracking issue: #971 (`Closes #971` in the implementation PR body).
- `development` plugin version bump (minor — new script mode + skill contract)
  in `development/.claude-plugin/plugin.json` and
  `.claude-plugin/marketplace.json`, in lockstep.
- PR body per the repo template (Type/Summary/Test plan).
- This spec lands first as its own docs PR (branch
  `docs/971-review-loop-step-mode-spec`); implementation follows on its own
  branch off fresh `origin/main`.
