# Interactive review-loop escalation — design

**Date:** 2026-07-21
**Status:** Approved (brainstorm), ready for implementation plan
**Skill touched:** `development/skills/resolve-issue`
**Related:** epic #557; issues #562 (loop state machine), #564 (typed
escalation), and #586/#587 (interactive precheck remediation — the pattern
this reuses)

## Problem

The local pre-push review loop (`resolve-story-loop.zsh`) runs
review→fix→test rounds up to a hard budget (`MAX_REVIEW_ROUNDS=3`). When the
budget is spent with blockers still open, it exits `BUDGET_EXHAUSTED` (exit 13);
when a blocker survives two consecutive rounds unchanged it exits
`ESCALATE_NO_CONVERGENCE` (exit 12). In **both** cases the skill layer posts one
typed GitHub issue comment (`build-escalation.zsh`), applies the
`needs-human-decision` label, pushes the branch (no PR), and **stops**. The human
must leave the session, read the comment, reply on the issue thread, and re-run
`/development:resolve-issue <N>`.

When a human is already driving the run interactively, that async round-trip is
pure friction: the person who could grant "just two more rounds" or supply the
one missing constraint is *right there*, but the loop dead-ends and makes them
context-switch to GitHub.

## Goal

When a human is present, turn `BUDGET_EXHAUSTED` and `ESCALATE_NO_CONVERGENCE`
into an **in-session interactive extension**: summarize what's left, offer to
grant more rounds (two at a time), let the human supply guidance or ask Claude
questions before deciding, and keep the human in control with a soft guardrail
against an unproductive infinite loop. Autonomous runs are completely unchanged.

## Non-goals (v1)

- **Interactive "waive this blocker right now."** Dropping a stuck blocker to a
  logged suggestion and proceeding to open a PR with a recorded human override
  means teaching the consolidator / PR path about human waivers — a meatier
  change. In v1, "waive" remains an option inside the **Stop** terminal's
  existing typed comment (which already lists Waive / Triage / Split). Live
  interactive waive is a deliberate fast-follow.
- **`ESCALATE_CONFLICT` and `ESCALATE_AMBIGUOUS`.** "Grant more rounds" does not
  help a reviewer conflict or an unresolved repo type; they keep today's
  comment-and-stop.
- **Any change to autonomous / epic / maintenance behaviour.** They cannot
  prompt without hanging; they keep the exact current escalation.

## Core architectural principle

**The zsh loop never becomes interactive.** All prompting happens in the
*conducting session* (the human's `/development:resolve-issue` run), between loop
invocations. The loop stays a headless, deterministic, testable state machine —
we only make it **resumable**. This preserves the reason the loop exists (a
testable core behind model-driven hooks) and keeps autonomous runs safe by
construction: a headless driver simply never enters the interactive branch.

## Design

### 1. Scope & trigger

The interactive branch fires only when **both** hold:

1. loop status ∈ {`BUDGET_EXHAUSTED`, `ESCALATE_NO_CONVERGENCE`}, and
2. the run is **interactive** — the same human-present determination that §0a's
   dependency-precheck remediation already uses (a human invoked
   `/development:resolve-issue` directly, vs. an epic/maintenance-driven run).

Every other case is untouched:

- `ESCALATE_CONFLICT` (11), `ESCALATE_AMBIGUOUS` (10) → today's typed comment.
- Any of the four exits under an **autonomous** run → today's typed comment +
  `needs-human-decision` label + pushed branch, no PR.

### 2. Resumable loop (`resolve-story-loop.zsh`)

Add a `--resume` flag. It reuses the **shared `--work-dir` as its state** — no
new state file or serialization format is introduced:

- read `history.jsonl` for the last completed round → continue at `round + 1`;
- read the last line of `changelists.jsonl` → seed `prev_changelist`, so
  **non-convergence detection spans the extension** (a blocker that was already
  present in the final pre-extension round and survives the first extension round
  still trips `ESCALATE_NO_CONVERGENCE`);
- honour the raised `--max-rounds` (previous ceiling + 2);
- keep **appending** to the same `history.jsonl` / `changelists.jsonl` — never
  truncate or re-run already-completed rounds.

"Grant +2 rounds" is therefore: re-invoke the loop with the **same** `--work-dir`,
`--resume`, and `--max-rounds <old + 2>`. Same invocation shape as today, with
the correctness of a true continue. `--resume` requires an existing, non-empty
`history.jsonl` in the work-dir; without one it is a usage error (exit 2) rather
than silently starting a fresh round 1.

Exit codes and status JSON are unchanged — a resumed run can itself exit
`CONVERGED`, `BUDGET_EXHAUSTED`, or `ESCALATE_NO_CONVERGENCE` again, and the
conducting session treats that exit identically to a first-pass exit.

### 3. Interactive escalation branch (skill layer, §3.5 of SKILL.md)

On a gated exit, instead of jumping straight to the comment:

1. **Summarize** the remaining blockers and the per-round history in the
   conversation. Drive it from the same status JSON `build-escalation.zsh`
   already parses, via a new `--format summary` mode on that script, so the
   conversational rendering and the eventual comment rendering can never drift.
2. **`AskUserQuestion`**, type-tailored:
   - `BUDGET_EXHAUSTED`: *Grant +2 rounds* · *Grant +2 with guidance* · *Stop*.
   - `ESCALATE_NO_CONVERGENCE`: *Give guidance & retry (+2)* — the primary lever,
     since extra rounds alone will not move a stuck blocker — · *Stop*.
   - The built-in **"Other"** escape hatch is where the human **asks Claude a
     question** ("why is this stuck?", "show me the diff for that file"). Claude
     answers from the changelist / dossier and **re-presents the same menu**.
     Q&A never consumes a grant.
3. On **grant** → resume the loop (§2). On the next exhaustion, re-summarize and
   re-offer. On **Stop / decline** (including the "Other" hatch used to bail) →
   fall back to today's `build-escalation` terminal exactly as it is now
   (comment + label + pushed branch, no PR).

### 4. Guidance channel — post to issue, re-read

When the human supplies guidance, Claude **posts it as an issue comment** (the
durable single source of truth — it survives a dead session and is auditable),
then resumes the loop with a `--fix-cmd` that **re-reads the issue's comments**
as fix context — the same mechanism the readiness gate and escalation already
rely on. No new environment-variable side channel is introduced. The comment is
tagged (e.g. an HTML marker) so the audit trail distinguishes human guidance from
the automated escalation comment.

### 5. Soft cap

Track grants **in-session** (a simple counter in the conducting run). After
**~5 grants (~10 extra rounds)**, or on any extension round that produces **zero
net blocker reduction**, Claude warns — "this isn't converging; the diff may need
rethinking" — and nudges toward Stop / Split *before* re-offering. It never
hard-stops on the human; the human stays in control and can still choose to
extend.

### 6. User documentation (explicit deliverable)

There is no user-facing page today that explains the review loop. Add a Diátaxis
**explanation** page — `docs/explanation/review-loop.md` — wired into
`mkdocs.yml` nav, that covers, in plain language for someone running
`/development:resolve-issue`:

- what the local pre-push review loop does (review → fix → test, diff-scoped),
  and why it runs before any PR is opened;
- the round budget and what "converged" means (zero **blockers**; Low
  suggestions are logged, not looped);
- the escalation types the human may see, and specifically **the new interactive
  extension**: a walkthrough of exactly what the prompt looks like, what "grant
  +2", "give guidance", and "ask a question" do, the soft cap, and what happens
  on Stop (the typed issue comment + how to resume later);
- how autonomous/epic runs differ (they post the comment and stop — no prompt).

The `/development:resolve-issue` reference entry and any escalation-comment prose
that describes the old always-async behaviour are updated to match.

## Components changed

| Component | Change |
|---|---|
| `scripts/resolve-story-loop.zsh` | Add `--resume` (work-dir-as-state continue; +2 ceiling; append, don't truncate). |
| `scripts/build-escalation.zsh` | Add `--format summary` (conversational render sharing the comment's data path). |
| `skills/resolve-issue/SKILL.md` | New interactive-escalation branch in §3.5, gated to interactive + {BUDGET_EXHAUSTED, NO_CONVERGENCE}; the grant/guidance/Q&A/soft-cap loop; unchanged autonomous + other-exit paths. |
| `docs/explanation/review-loop.md` (new) + `mkdocs.yml` | User documentation of the loop and interactive escalation. |
| `docs/reference/commands.md` / relevant reference prose | Update the resolve-issue description to mention the interactive extension. |

## Testing

Per this repo's "plugin scripts ARE code — test them" rule:

- **bats** for the new `resolve-story-loop.zsh --resume` path (extend
  `tests/resolve-story-loop.bats`): resumes at `last_round + 1`; carries
  `prev_changelist` so an extension round can trip `ESCALATE_NO_CONVERGENCE`;
  respects the `+2` ceiling; appends to history/changelists rather than
  truncating; `--resume` with no prior history is a usage error.
- **bats** for `build-escalation.zsh --format summary` (extend
  `tests/build-escalation.bats`): the summary render carries the same
  blockers / round history as the comment render for each gated status.
- The skill-layer interaction is prose (reviewed via the plugin review panel);
  its one testable seam — the work-dir resume handoff — is covered by the loop
  bats above.

## Rollout / safety

- Autonomous safety is structural: the interactive branch is unreachable without
  a human present, so epic/maintenance runs cannot hang.
- No schema or exit-code changes to the loop → no downstream consumer breaks.
- The `--resume` continue reuses existing work-dir artifacts, so a resumed run is
  a strict extension of a prior run's state, not a re-derivation.
