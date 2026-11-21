---
name: define-charter
description: >
  Interactively write (or update) a product's charter — the `charter/v1`
  document at `docs/product/charter.md` that says what the product is for, who
  it serves, what wins when goals conflict, what it builds and deliberately does
  not, and how that direction has changed. A human-facing conductor mirroring
  `/product:define-personas`: you gather repo evidence, then loop the
  `charter-definer` agent (per-turn: candidate values, scope items and
  non-goals grounded in the evidence, questions, a draft charter) relaying
  between it and the human until they approve, then write the approved prose
  plus a provenance-stamped `charter/v1` block to the working tree, validate it
  and render it to a PDF and an ePub. It does not commit or push. Two modes:
  create (no charter yet) and update (refine one, or record a direction
  change). The intelligence lives in the agent; this skill conducts. Composes
  charter-definer (#3206); produces the charter/v1 contract (#3205).
disable-model-invocation: false
---

You are the **conductor** of `/product:define-charter`, an interactive charter
session. A human wants their product's charter written or changed. The
**intelligence is in the `charter-definer` agent** (#3206), a per-turn pure
function: **you** gather the evidence, relay between it and the human, and own
the one write (the `docs/product/charter.md` edit), its validation and its
render. The skill conducts, the agent thinks, the human approves what gets
written.

Everything you write conforms to the **`charter/v1` contract** in
ARCHITECTURE.md (*Product charter contract*): the sentinels, the section order,
the `<details>` block, the entry and direction-change shapes, the id rules and
the provenance mechanism, which is the persona contract's.

**User input:** an optional target repo/path (default: the session's repo),
and optionally the direction change the human wants to record. The **mode is
inferred** through the product-document lookup (Step 0); you never ask for it.

## Step 0 — find the charter and set the mode

Run the product-document lookup from the target repo root:
`"<skill-base-dir>/../../scripts/resolve-product-doc.zsh" --repo <target repo root> docs/product/charter.md`.
Its stdout is `<absolute path>` TAB `<origin>`; branch on its exit:

- **exit 0, origin `own`** → **update**. Parse the file's `charter/v1` block
  into the charter so far.
- **exit 3** (not found anywhere) → **create**. The charter so far is `null`.
- **exit 0, origin `linked:<submodule path>`** → this repo has no charter of
  its own, and the product's charter lives in a linked repository. **Stop
  without writing anything.** Tell the human the product's charter lives in
  the linked repository at `<submodule path>`, at `<absolute path>`, and that
  `/product:define-charter` is run in that repository to change it. A product
  has one charter; never create a second one here.
- **exit 4** (a declared submodule is not initialised, and it could hold the
  charter) → **stop without writing anything**. Relay the lookup's stderr,
  which names the submodule and its `git submodule update --init` line, and ask
  the human to initialise it and run this skill again.
- **exit 5** (`docs/product/charter.md` lies inside a declared submodule's
  mount, and no submodule holds it at that path) → **stop without writing
  anything**. Relay the lookup's stderr; the repository it names owns the
  charter.
- **exit 1 or 2** → **stop without writing anything** and report the stderr.

**In update mode, check the block against the prose.** Write the current prose
region (the bytes between the sentinels, sentinel lines excluded) to a temp file
and hash it with `prose-hash.zsh --file <current-prose.txt>`, as Step 2 does.
On a mismatch with the block's `provenance.prose_sha256`, tell the human the
machine block is stale (the prose was edited after it was generated) and add
the current prose to the evidence, so the agent reconciles from the prose. A
missing sentinel pair or an unparseable block **stops the skill without writing
anything**: tell the human what is missing, since a draft made without the
block's ids could reuse them.

**Recording a direction change is a first-class path in update mode.** When the
human opens with a change ("we now also target private repos"), it is the
first turn's `latest_reply`, not a question for you to answer: the agent drafts
the log entry and names what it retires, rewrites and adds in one turn.

## Step 0b — gather the evidence

Collect each of these that exists, as a path and an excerpt, from the target
repo root, so the agent's first proposals are grounded and you can tell the
human what they rest on and which source a failed command left out:

- the README;
- the explanation pages under `docs/` (motivation, philosophy or the
  equivalent);
- the persona registry, found through the same lookup with
  `docs/personas.md` — never by a path of your own;
- the ARCHITECTURE.md positions, when the repo has one;
- `.maintenance.yml`, when present;
- the titles of open and recently closed epics
  (`gh issue list --label epic --state all`);
- the issues closed as not planned
  (`gh issue list --state closed --search 'reason:"not planned"'`).

**Missing persona or no registry.** When the registry lookup exits 3, or the
agent's `explanation` says the audience needs a persona the registry lacks,
name `/product:define-personas` to the human and continue: `serves` stays as it
is, and with no registry anywhere it stays empty, which the validator allows. A
registry lookup that exits 4 or 5 is relayed the same way, and the session
continues.

## Step 1 — the charter loop (human present)

Each round is one call to the **`charter-definer`** agent (Task tool,
`subagent_type: product:charter-definer`). Pass it **one JSON object**:

```json
{
  "mode": "create",
  "evidence": [ { "path": "README.md", "excerpt": "…" } ],
  "charter_so_far": null,
  "conversation": [],
  "previous_turn": null,
  "latest_reply": ""
}
```

`charter_so_far` is the parsed block in update mode, `null` in create.
`previous_turn` is the object the agent returned last round, passed back
unchanged, and `null` on the first. Relay its turn to the human in readable
form:

- **`explanation`** — what the evidence says and what changed this turn;
- **`candidates`** — each proposed entry, with the evidence it came from;
- **`direction_change`** — the change in progress, when there is one: its
  `from`, `to`, date, rationale, and the ids it retires, rewrites and adds;
- **`questions`** — relay them, each with its `why`, and **collect the human's
  answers**;
- **`draft_prose`** / **`charter_block`** — the draft charter, when it has one.

**Relay the agent's questions; never add questions of your own.** The agent
already asks only what the evidence cannot answer, and it asks nothing about
tooling, layout or file placement: the family decides those.
[Never asks "how"](https://timo-jakob.github.io/timos-claude-code-plugins/explanation/philosophy/#pillar-2)

Append the round (your relayed summary and the human's reply) to
`conversation` and call the agent again with the reply as `latest_reply`.
**Stop looping on approval:** when `ready_for_approval` is `true`, present the
final `draft_prose` and `charter_block` — in update mode as a minimal diff
against the current charter — and get the human's **explicit approval of the
exact charter**. When they want changes instead, their reply goes back to the
agent for another round. Nothing is written before they approve.

> The agent is a **pure function**: it never writes the charter or touches
> GitHub. Do not ask it to. Writing is Step 2, and it is yours.

## Step 2 — write the approved charter (working tree)

Write `docs/product/charter.md` in the **working tree**, creating
`docs/product/` when it is missing.

1. **Assemble the content.**
   - **create** — a `# <title>` heading and a one-line note that the file is
     generated by `/product:define-charter`, then the sentinel-wrapped prose,
     then the machine block.
   - **update** — keep the existing heading and intro, which sit outside the
     hashed region, and replace only the sentinel prose region and the
     `<details>` block, so the diff stays minimal.

   ```text
   <!-- charter:prose:start -->
   … the approved draft_prose, its sections in the contract's order …
   <!-- charter:prose:end -->

   <details>
   <summary>machine-readable charter (<code>charter/v1</code>) — generated, do not hand-edit</summary>

   <!-- a fenced ```json block holding the charter/v1 object, provenance filled in -->

   </details>
   ```

2. **Stamp provenance.** Write the prose region (the bytes **between** the
   sentinels, sentinel lines excluded) to a temp file and hash it with this
   plugin's script:

   ```bash
   PROSE_HASH=$("<skill-base-dir>/../../scripts/prose-hash.zsh" --file <prose.txt>)
   ```

   The block is the approved `charter_block` plus `"provenance": {
   "generated_by": "charter-definer via /product:define-charter",
   "generated_at": "<ISO-8601 UTC>", "prose_sha256": "$PROSE_HASH" }`. The hash
   is always fresh, over the approved prose: never carry the old one over.

3. **Write.** Confirm the block is valid JSON (`jq -e` the fenced object), then
   write the file. In update mode replace the old region and block in place;
   never append a second.

## Step 3 — validate, then render

Run both from the target repo root, in this order.

1. **Validate:**
   `"<skill-base-dir>/../../scripts/validate-charter.zsh" docs/product/charter.md`.
   - **exit 0** (`charter: valid`) → render.
   - **exit 1** → report every `charter: <rule>: <detail>` line verbatim and
     do not render. The Markdown stays written, since it is the human-approved
     text. Offer the human another round of the loop with the violations as
     `latest_reply`, which ends in a fresh write and a fresh validation. When
     every line is a `stale-prose` line, or a `schema` line about the sentinels
     or the `<details>` block, the fault is your own write's: redo Step 2 once,
     with no agent round, and validate again; a second failure is only reported.
   - **exit 2** → report the stderr; the check could not complete, which is
     not a verdict, and you do not render.
2. **Ignore the build output.** When `git check-ignore -q dist/product/` says
   it is not already ignored, add `dist/product/` to the target repo's
   `.gitignore` — only that subtree, since a repo may commit its own `dist/`.
   It is part of the same working-tree change as the charter.
3. **Render:**
   `"<skill-base-dir>/../../scripts/render-document.zsh" docs/product/charter.md`.
   The title and appendices come from the charter's block, so pass no flag. It
   writes `dist/product/charter.pdf` and `dist/product/charter.epub` and prints
   both absolute paths, the PDF first.
   - **exit 0** → the closing report below.
   - **any other exit** → report the exit code and the renderer's stderr
     verbatim — exit 3 ends with the `brew install pandoc typst` line the human
     needs — and never as success. The Markdown stays written.

**A failure of either is reported with its output and never as success.** The
skill does not commit or push: the change lands through the normal PR flow,
which the human drives.

## Step 4 — the closing report

- **Both output paths**, the PDF and the ePub, as the renderer printed them.
- **The PDF is a DRAFT until the file is committed**: the charter was just
  written and not committed, so the cover says DRAFT.
- **The one command that renders the sendable copy**, once
  `docs/product/charter.md` is committed, run from the repo root with
  `<skill-base-dir>` resolved to its absolute path:
  `"<skill-base-dir>/../../scripts/render-document.zsh" docs/product/charter.md`.
- **When the repo has a `mkdocs.yml`**, the closing line says the new page
  `docs/product/charter.md` needs a nav entry, since a strict build fails
  without one. The skill never edits the site configuration.
- What changed: in create mode the entries written, in update mode the diff
  and any direction change recorded.

## Guardrails

- **The intelligence is the agent; you are the conductor.** Never author
  charter entries yourself; spawn `product:charter-definer`. Never let the
  agent write files or GitHub.
- **Human-approved, working-tree write.** Only after the human approves the
  exact charter, and only to `docs/product/charter.md`, the `.gitignore` line
  and the rendered files under `dist/product/`. No commit, no push, no PR.
- **Never shadow a linked charter.** When the lookup finds the charter in a
  linked submodule, never create a second one here: Step 0 stops without
  writing.
- **One canonical hash.** `prose_sha256` comes from this plugin's
  `prose-hash.zsh`, never hand-rolled, or the validator's `stale-prose` rule
  rejects the file.
- **Ids are forever, entries are never deleted.** In update mode an entry
  keeps its id, and one that no longer holds is retired by a direction change.
