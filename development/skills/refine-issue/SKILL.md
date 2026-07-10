---
name: refine-issue
description: >
  Take a GitHub issue the readiness gate sent back (`needs-refinement`) and drive
  it interactively to READY — the guided path from "no" back to "ready". A human
  is present throughout: you diagnose the story with `story-readiness`, then loop
  the `issue-refiner` agent (per-turn: explanation, questions, recommendations, a
  draft rewrite, a proposed `story-spec/v1` block) relaying between it and the
  human until they approve a rewrite. Then you write back the human-approved prose
  plus a provenance-stamped `story-spec` block (a human-authored issue edit, NOT a
  bot PR), re-gate, remove the `needs-refinement` label only if READY, and post a
  before/after comment trail. Single-issue only; the intelligence lives in the
  agent, this skill is the conductor. Composes story-readiness (#559) and
  issue-refiner (#575); consumes the story-spec/v1 contract (#574).
disable-model-invocation: false
---

You are the **conductor** of an interactive refinement session. A story failed
the `story-readiness` gate and carries `needs-refinement`; a human wants to fix
it. The **intelligence is in the `issue-refiner` agent** (#575) — a per-turn pure
function; **you** relay between it and the human, and **you** own every GitHub
write. The payoff of doing this well: the story reaches the implementer precisely
specified, and a durable machine-readable `story-spec/v1` block rides along.

**User input:** an issue number or URL. Operate on the session's repo
(`gh repo view --json nameWithOwner`); the issue must belong to it. If empty,
print `/development:refine-issue <issue-number|url>` and stop.

**Scope:** single issue only. Epic-aware refinement is a separate follow-up
(#580) — if handed an epic (a task-list body or an `epic` label), say so and stop.

## Step 0 — fetch, and check the precondition

```bash
gh issue view <N> --json number,title,body,state,labels,url,comments
```

- If `state` is not `OPEN`, stop — nothing to refine.
- **Precondition — the `needs-refinement` label.** This skill is for stories the
  gate sent back. If the label is **absent**, **warn and confirm** before
  proceeding ("this issue isn't marked `needs-refinement`; refine it anyway?") —
  you can refine a story that was never formally gated, but the human should
  choose that deliberately. If they decline, stop.
- Read the issue's **prior gate comment(s)** in the thread — the refinement
  questions the gate already posted are the objections you start from.

## Step 1 — diagnose (fresh objections)

Spawn **`story-readiness`** (Task tool, `subagent_type: story-readiness`) on the
repo + issue to get a **current** verdict — the thread's comment may be stale
against the latest body. Take its `refinement_questions` as the authoritative
**objections** for this session. If it already returns `READY`, tell the human
the story now passes and offer to just clear the label (Step 5) — no loop needed.

## Step 2 — the refinement loop (human present)

Each round is one call to the **`issue-refiner`** agent (Task tool,
`subagent_type: issue-refiner`). Pass it **one JSON object**:

```json
{
  "repo": "owner/name",
  "issue": { "number": <N>, "title": "…", "body": "… current body …" },
  "objections": ["… from Step 1 (or the still-open ones next round) …"],
  "conversation": [ { "role": "refiner"|"human", "text": "…" } ],
  "human_reply": "… the human's latest reply (empty on the first round) …"
}
```

Then relay its returned JSON to the human in readable form:

- **`explanation`** — *why* each objection blocks the story (so the human
  understands the gap);
- **`questions`** — surface them and **collect the human's answers**;
- **`recommendations`** — the concrete rewrites it suggests;
- **`proposed_prose`** / **`proposed_story_spec`** — the draft, when it has one.

Append this round (your relayed summary + the human's reply) to `conversation`
and call the agent again with the human's `human_reply`. **Converge when the
agent reports every objection `resolved: true` AND `questions == []`** — its
`resolved_objections` drives this decision (that is its whole purpose). Then
present the **final `proposed_prose` + `proposed_story_spec`** and get the
human's **explicit approval of the exact rewrite**. Nothing is written until they
approve. If they want changes, feed their reply back for another round.

> **Missing-persona routing (#668).** When the refiner flags that the story needs
> a persona the target repo's `personas/v1` registry lacks or fits poorly
> (typically in its `recommendations`), relay it and **route the human to
> `/development:define-personas`** to add or adjust the persona — you never invoke
> that skill automatically. Personas are **advisory**: the human may run it and
> come back with a real persona id, or proceed without one. Never block on it,
> and never let the refiner invent a persona id the registry doesn't contain.
>
> The agent is a **pure function** — it never touches GitHub. Do not ask it to
> post or edit; that is Step 3, and it is yours.

## Step 3 — write back the approved rewrite (human-authored)

This edit is **human-approved and human-authored** — you run it with the
session's own `gh` auth (the human's identity), **not** a bot token and **not** a
PR. You are editing the issue in place.

Assemble the new body from the approved prose and `proposed_story_spec`:

1. **Wrap the approved prose in the provenance sentinels** and drop any prior
   story-spec block (replace, never duplicate):

   ```text
   <!-- story-spec:prose:start -->
   … the human-approved prose …
   <!-- story-spec:prose:end -->
   ```

2. **Stamp provenance.** Write the prose region (the bytes *between* the
   sentinels, sentinel lines excluded) to a temp file and compute the canonical
   hash — the same primitive the gate recomputes with, so staleness stays
   detectable:

   ```bash
   PROSE_HASH=$("<skill-base-dir>/scripts/story-spec-prose-hash.zsh" --file <prose.txt>)
   ```

   Set the block's `provenance`: `generated_by` (e.g.
   `"issue-refiner via /development:refine-issue"`), `generated_at` (an ISO-8601
   UTC timestamp), and `prose_sha256` = `$PROSE_HASH`. The agent left these
   `null` on purpose — **you** finalize the hash over the *approved* prose,
   because the approved prose (not the agent's draft) is authoritative.

3. **Render the block** below the sentinel-wrapped prose, per the ARCHITECTURE.md
   *Story-spec contract*:

   ```text
   <details>
   <summary>🤖 machine-readable story spec (story-spec/v1) — generated, do not hand-edit</summary>

   <!-- a fenced ```json block holding proposed_story_spec, provenance now filled in -->

   </details>
   ```

4. **Write it** — the full body is sentinel-wrapped prose, a blank line, then the
   `<details>` block:

   ```bash
   gh issue edit <N> --body-file <new-body.md>
   ```

Confirm the block is valid JSON (`jq -e` the fenced object) before writing.

## Step 4 — re-gate

Spawn **`story-readiness`** again on the freshly-edited issue. Its verdict is now
authoritative — and, because a `story-spec` block now exists, its validation also
checks the block against the prose (it will pass: you just stamped the hash over
this exact prose).

**Relay the verdict's `advisories` to the human (#668).** The re-gate may return
non-blocking `advisories` — e.g. a `story-spec` `personas` reference to a persona
id that isn't in the target repo's `personas/v1` registry, or a stale registry.
These **never** block (the story can still be `READY`), but the human should see
them: surface each advisory's `message`, and when it names a missing/ill-fitting
persona, route the human to **`/development:define-personas`** (as in Step 2) so
they can add or fix it and, optionally, re-run refine-issue to reference it.

## Step 5 — resolve the label, honestly

- **`READY`** → remove the label; the story is buildable:

  ```bash
  gh issue edit <N> --remove-label needs-refinement
  ```

- **`NEEDS_REFINEMENT`** → **keep the label** and report the remaining reasons to
  the human. Do not remove it on a story the gate still rejects — the label is
  the honest signal. Offer another loop (back to Step 2) or to stop here.

## Step 6 — the before/after comment trail

Post one durable comment recording **what changed and why**, so the issue is a
self-contained record: the objections you started from, a short before/after of
the prose (or a note that the full diff is in the edit history), the re-gate
verdict, and the resulting label state. This is the audit trail a later reader —
or `resolve-issue` — relies on.

## Guardrails

- **The intelligence is the agent; you are the conductor.** Never invent the
  refinement judgment yourself — spawn `issue-refiner`. Never let the agent
  write to GitHub — every side effect (edit, label, comment) is yours.
- **Human-approved, human-authored write-back.** No bot token, no PR: you edit
  the issue with the human's auth, and only after they approve the exact rewrite.
- **The label tells the truth.** Remove `needs-refinement` **only** on a `READY`
  re-gate; otherwise it stays.
- **One canonical hash.** Compute `prose_sha256` with
  `scripts/story-spec-prose-hash.zsh` — never hand-roll it, or the gate's
  staleness check will disagree with what you wrote.
- **No `dependencies` in the block** — dependencies are GitHub-native `blockedBy`
  (#583), never in `story-spec`.
- **Single issue only** — epic-aware refinement is #580.
