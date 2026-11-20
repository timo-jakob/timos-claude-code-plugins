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
  the skill does not push), then renders it to a PDF and an ePub. Two modes:
  create (no registry yet) and update (refine an existing one — e.g. routed
  here from refine-issue for a missing persona). The intelligence lives in the
  agent; this skill conducts. Composes persona-definer (#666); produces the
  personas/v1 contract (#665).
disable-model-invocation: false
---

You are the **conductor** of `/product:define-personas`, an interactive
persona-definition session. A human
wants their repo's persona registry built or refined. The **intelligence is in
the `persona-definer` agent** (#666) — a per-turn pure function; **you** relay
between it and the human, and **you** own the one write (the `docs/personas.md`
edit). This mirrors `/development:refine-issue`: the skill conducts, the agent
thinks, the human approves what gets written.

Everything you assemble conforms to the **`personas/v1` contract** in
ARCHITECTURE.md (*Persona registry contract*) — the file layout, the per-persona
schema, the five kinds, the conventions, and the provenance mechanism.

**User input:** an optional target repo/path (default: the session's repo). The
**mode is inferred**: `update` if the repo's own `docs/personas.md` already
exists, else `create` — unless the registry lives in a linked submodule, which
stops the skill (Step 0).

## Step 0 — gather evidence and set the mode

- **Determine the mode — find the registry first.** Run the product-document
  lookup from the target repo root:
  `"<skill-base-dir>/../../scripts/resolve-product-doc.zsh" --repo <target repo root> docs/personas.md`.
  Its stdout is `<absolute path>` TAB `<origin>`; branch on its exit:
  - **exit 0, origin `own`** → **update**; parse that file's `personas/v1`
    block into the registry-so-far (the personas array).
  - **exit 3** (not found anywhere) → **create**, registry-so-far is empty.
  - **exit 0, origin `linked:<submodule path>`** → this repo has no registry
    of its own, so this would be create mode, and the product's registry
    already lives in a linked repository. **Stop without writing anything.**
    Tell the human: the product's persona registry lives in the linked
    repository at `<submodule path>`, at `<absolute path>`; run
    `/product:define-personas` in that repository to change it.
  - **exit 4** (a declared submodule is not initialised, and it could hold the
    registry) → **stop without writing anything**. Relay the lookup's stderr,
    which names the submodule and its `git submodule update --init` line, and
    ask the human to initialise it and run this skill again.
  - **exit 5** (`docs/personas.md` lies inside a declared submodule's mount,
    and no submodule holds it at that path) → **stop without writing
    anything**. Relay the lookup's stderr, which names the submodule and the
    registry's path inside it; that repository owns the registry.
  - **exit 1 or 2** → **stop without writing anything** and report the stderr.
- **In update mode, check the block against the prose.** Write the current
  prose region (the bytes between the sentinels, sentinel lines excluded) to a
  temp file and hash it with the same `prose-hash.zsh` as Step 2
  (`--file <current-prose.txt>`). Compare the result to the block's
  `provenance.prose_sha256`. On a mismatch, tell the human the machine block is
  stale (the prose was edited after it was generated), and pass the current
  prose to the agent as `registry_prose` so it reconciles from the prose rather
  than the block. On a match, `registry_prose` is `null`. A missing sentinel
  pair or an unparseable block counts as a mismatch: pass the whole file as
  `registry_prose` with registry-so-far empty, and Step 2 rewrites the whole
  file as in create.
- **Gather repo evidence** the agent will mine — confirm what's available so you
  can tell the human what the first proposals are grounded in: README/docs,
  OpenAPI/proto specs, UI routes, existing issues, and the runtime surfaces the
  repo exposes.

## Step 1 — the definition loop (human present)

Each round is one call to the **`persona-definer`** agent (Task tool,
`subagent_type: product:persona-definer`). Pass it **one JSON object**:

```json
{
  "repo": "owner/name",
  "mode": "create" | "update",
  "registry_so_far": { "personas": [ … existing personas/v1 objects, [] in create … ] },
  "registry_prose": "… the current prose region when Step 0 found the block stale, else null …",
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
`[]`, `persona_count` is 3–7, and the human approves — or the human explicitly
confirms a deliberate exception to a convention; record that exception in the
prose and proceed to final approval.** The coverage signal is advice, not a
precondition for writing — the agent drives it (that is its purpose). Then present the **final `draft_prose` +
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
     file, or the diff bloats and human-authored intro/conventions text is lost
     — unless Step 0 found no sentinel pair or an unparseable block: then
     compose the whole file as in create, heading and intro included.

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
   hash with this plugin's `prose-hash.zsh` — a byte-identical copy of the
   primitive the `story-readiness` gate recomputes with, so its persona-staleness
   advisory stays accurate:

   ```bash
   PROSE_HASH=$("<skill-base-dir>/../../scripts/prose-hash.zsh" --file <prose.txt>)
   ```

   Build the `personas/v1` object: `{ "schema": "personas/v1", "provenance": {
   "generated_by": "persona-definer via /product:define-personas",
   "generated_at": "<ISO-8601 UTC>", "prose_sha256": "$PROSE_HASH" }, "personas":
   [ … draft_personas … ] }`. The agent left provenance unset on purpose — **you**
   finalize the hash over the *approved* prose (its prose was a draft; the
   approved prose is authoritative).

3. **Validate then write.** Confirm the block is valid JSON (`jq -e` the fenced
   object), then write `docs/personas.md`. In **update** mode, replace the prior
   sentinel-region + machine block in place, or rewrite the whole file per
   step 1's exception (never append a second).

4. **Report.** Tell the human the file was written to the working tree, summarize
   what changed (create: N personas; update: the diff), and that the change lands
   via the normal PR flow (commit + PR) — this skill does not push.

## Step 3 — render the registry (PDF + ePub)

Right after the write, render the registry from the target repo root, so the
human has a copy to send. The registry's machine block carries no title, so
pass one:

```bash
"<skill-base-dir>/../../scripts/render-document.zsh" --title "<repo name> — Personas" docs/personas.md
```

`<repo name>` is the target repo's name (the root directory's name). The
renderer writes `dist/product/personas.pdf` and `dist/product/personas.epub`
and prints both absolute paths, the PDF first.

- **`dist/` is build output.** Before rendering, add `dist/` to the target
  repo's `.gitignore` when `git check-ignore -q dist/` says it is not already
  ignored — part of the same working-tree change as the registry, never
  committed by this skill.
- **exit 0** → report both paths. The file was just written and not committed,
  so the cover says **DRAFT**: this copy is the preview. The sendable copy comes
  from running the same command once the registry is committed.
- **Any other exit** → the registry write stands, but the render failed: report
  the exit code and the renderer's stderr verbatim — exit 3 ends with the
  `brew install pandoc typst` line the human needs — and never as success. No
  PDF or ePub was written.

## Guardrails

- **The intelligence is the agent; you are the conductor.** Never author personas
  yourself — spawn `product:persona-definer`. Never let the agent write files or GitHub.
- **Human-approved, working-tree write.** Only after the human approves the exact
  registry, and only to `docs/personas.md` in the working tree — plus Step 3's
  `dist/` line in `.gitignore` and the rendered files under `dist/product/` —
  no commit, no push, no PR (that is the normal flow the human drives
  afterward).
- **Never shadow a linked registry.** When the lookup finds the registry in a
  linked submodule, never create a second one in this repo: Step 0 stops
  without writing.
- **One canonical hash.** Compute `prose_sha256` with this plugin's
  `prose-hash.zsh` — never hand-roll it, or the gate's persona
  staleness advisory (#668) will disagree with what you wrote.
- **`id` is forever.** In update mode, a revised persona keeps its `id` —
  `story-spec/v1.personas` references it; never rename or reuse an id.
- **Advise, don't gatekeep.** Enforce the conventions (3–7, one primary per
  surface, no demographic fluff, `data_traits` for input-producers), but the human
  owns the registry — record a deliberate exception rather than blocking it.
