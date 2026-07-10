---
name: define-personas
description: >
  Interactively define (or update) a repo's persona registry — the `personas/v1`
  artifact at `docs/personas.md` that says who actually uses each surface and what
  they type into it. A human-facing conductor mirroring `/development:refine-issue`:
  you gather repo evidence, then loop the `persona-definer` agent (per-turn:
  candidate personas grounded in the repo, Socratic questions, a draft registry
  update) relaying between it and the human until they approve, then write back
  the human-approved prose plus a provenance-stamped `personas/v1` block to
  `docs/personas.md` in the working tree (the change lands via the normal PR flow;
  the skill does not push). Two modes: create (no registry yet) and update
  (refine an existing one — e.g. routed here from refine-issue for a missing
  persona). The intelligence lives in the agent; this skill conducts. Composes
  persona-definer (#666); produces the personas/v1 contract (#665).
disable-model-invocation: false
---

You are the **conductor** of an interactive persona-definition session. A human
wants their repo's persona registry built or refined. The **intelligence is in
the `persona-definer` agent** (#666) — a per-turn pure function; **you** relay
between it and the human, and **you** own the one write (the `docs/personas.md`
edit). This mirrors `/development:refine-issue`: the skill conducts, the agent
thinks, the human approves what gets written.

Everything you assemble conforms to the **`personas/v1` contract** in
ARCHITECTURE.md (*Persona registry contract*) — the file layout, the per-persona
schema, the five kinds, the conventions, and the provenance mechanism.

**User input:** an optional target repo/path (default: the session's repo). The
**mode is inferred**: `update` if `docs/personas.md` already exists, else
`create`.

## Step 0 — gather evidence and set the mode

- **Determine the mode.** If `docs/personas.md` (relative to the target repo
  root) exists → **update**; parse its `personas/v1` block into the
  registry-so-far (the personas array). Else → **create**, registry-so-far is
  empty.
- **Gather repo evidence** the agent will mine — confirm what's available so you
  can tell the human what the first proposals are grounded in: README/docs,
  OpenAPI/proto specs, UI routes, existing issues, and the runtime surfaces the
  repo exposes.

## Step 1 — the definition loop (human present)

Each round is one call to the **`persona-definer`** agent (Task tool,
`subagent_type: persona-definer`). Pass it **one JSON object**:

```json
{
  "repo": "owner/name",
  "mode": "create" | "update",
  "registry_so_far": { "personas": [ … existing personas/v1 objects, [] in create … ] },
  "conversation": [ { "role": "definer"|"human", "text": "…" } ],
  "human_reply": "… the human's latest reply (empty on the first round) …"
}
```

Relay its returned JSON to the human in readable form:

- **`candidates`** — the proposed personas this round (grounded in the evidence);
- **`questions`** — surface them and **collect the human's answers**;
- **`recommendations`** — the concrete additions/sharpenings it suggests;
- **`coverage`** — where the registry stands: each surface's primary, kinds
  present / still to confirm, and `persona_count`;
- **`draft_prose`** / **`draft_personas`** — the draft registry, when it has one.

Append this round (your relayed summary + the human's reply) to `conversation`
and call the agent again with the human's `human_reply`. **Converge when
`coverage` shows every surface has exactly one primary, `kinds_to_confirm` is
`[]`, `persona_count` is 3–7, and the human approves** — the agent drives this
signal (that is its purpose). Then present the **final `draft_prose` +
`draft_personas`** and get the human's **explicit approval of the exact
registry**. In **update** mode, show a **minimal diff** against the current
`docs/personas.md` (what personas/fields change), not a wall of unchanged text.
Nothing is written until they approve; if they want changes, feed their reply
back for another round.

> The agent is a **pure function** — it never writes `docs/personas.md` or
> touches GitHub. Do not ask it to. Writing is Step 2, and it is yours.

## Step 2 — write back the approved registry (working tree, human-approved)

Assemble `docs/personas.md` per the *Persona registry contract* and write it to
the **working tree** — you do **not** commit or push; the change lands via the
normal PR flow.

1. **Assemble the content — differently per mode**, so an update stays a minimal
   diff (AC2):

   - **create** — compose the whole file: a `# Personas` heading + a short intro
     (what the file is, how to regenerate it, the conventions), then the
     sentinel-wrapped persona prose (the human-approved `draft_prose`), then the
     machine block (below).
   - **update** — **preserve the existing heading and intro** (a human may have
     customized them, and they sit *outside* the hashed region), and surgically
     **replace only** the sentinel prose region and the `<details>` machine block
     with the approved prose + regenerated block. Do not regenerate the whole
     file, or the diff bloats and human-authored intro/conventions text is lost.

   The block layout, either way:

   ```text
   <!-- personas:prose:start -->
   … the human-approved persona sections (one per persona) …
   <!-- personas:prose:end -->

   <details>
   <summary>🤖 machine-readable personas (<code>personas/v1</code>) — generated, do not hand-edit</summary>

   <!-- a fenced ```json block holding the personas/v1 object, provenance filled in -->

   </details>
   ```

2. **Stamp provenance.** Write the prose region (the bytes **between** the
   sentinels, sentinel lines excluded) to a temp file and compute the canonical
   hash with the shared primitive — the same one the `story-readiness` gate
   recomputes with, so its persona-staleness advisory stays accurate:

   ```bash
   PROSE_HASH=$("<skill-base-dir>/../refine-issue/scripts/story-spec-prose-hash.zsh" --file <prose.txt>)
   ```

   Build the `personas/v1` object: `{ "schema": "personas/v1", "provenance": {
   "generated_by": "persona-definer via /development:define-personas",
   "generated_at": "<ISO-8601 UTC>", "prose_sha256": "$PROSE_HASH" }, "personas":
   [ … draft_personas … ] }`. The agent left provenance unset on purpose — **you**
   finalize the hash over the *approved* prose (its prose was a draft; the
   approved prose is authoritative).

3. **Validate then write.** Confirm the block is valid JSON (`jq -e` the fenced
   object), then write `docs/personas.md`. In **update** mode, replace the prior
   sentinel-region + machine block in place (never append a second).

4. **Report.** Tell the human the file was written to the working tree, summarize
   what changed (create: N personas; update: the diff), and that the change lands
   via the normal PR flow (commit + PR) — this skill does not push.

## Guardrails

- **The intelligence is the agent; you are the conductor.** Never author personas
  yourself — spawn `persona-definer`. Never let the agent write files or GitHub.
- **Human-approved, working-tree write.** Only after the human approves the exact
  registry, and only to `docs/personas.md` in the working tree — no commit, no
  push, no PR (that is the normal flow the human drives afterward).
- **One canonical hash.** Compute `prose_sha256` with the shared
  `story-spec-prose-hash.zsh` — never hand-roll it, or the gate's persona
  staleness advisory (#668) will disagree with what you wrote.
- **`id` is forever.** In update mode, a revised persona keeps its `id` —
  `story-spec/v1.personas` references it; never rename or reuse an id.
- **Advise, don't gatekeep.** Enforce the conventions (3–7, one primary per
  surface, no demographic fluff, `data_traits` for input-producers), but the human
  owns the registry — record a deliberate exception rather than blocking it.
