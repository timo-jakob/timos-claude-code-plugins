# Authoring guide — where docs go

This repo's documentation follows [Diátaxis](https://diataxis.fr/): four modes
that answer four different reader needs. Putting a page in the right bucket is
the single most important authoring decision — it's what keeps the docs usable
as they grow. This guide gives the placement rule for each bucket, plus the
mechanics (nav, links, the generated reference) specific to this repo.

## The one question that decides placement

Ask **what the reader is doing when they open the page**:

| The reader wants to… | Bucket | Directory |
| --- | --- | --- |
| **learn** by doing a complete, guided exercise | Tutorial | `docs/tutorials/` |
| **accomplish a specific task** they already understand | How-to | `docs/how-to/` |
| **look something up** (exact, exhaustive) | Reference | `docs/reference/` |
| **understand** why something is the way it is | Explanation | `docs/explanation/` |

If a page is trying to do two of these at once, split it — that's the usual
sign it's in the wrong bucket.

## Per-bucket rules

### Tutorials (`docs/tutorials/`) — learning-oriented

A tutorial takes a beginner from nothing to a working result along a path you
guarantee works. It is *learning*, not *doing a task*: concrete, linear, no
detours or alternatives.

- **Do:** one continuous worked example; state prerequisites up front; show the
  expected output at each step.
- **Don't:** branch into options, explain design rationale, or list every flag.
- **Example here:** [Getting started](../tutorials/getting-started.md) — bootstrap
  a project, run maintenance, resolve an issue, in one pass.

### How-to guides (`docs/how-to/`) — task-oriented

A how-to answers "how do I *X*?" for a reader who already knows what X is. One
page per job, titled as the task.

- **Do:** start from the goal; give the minimal steps; assume competence.
- **Don't:** teach concepts from scratch (link to Explanation instead).
- **Examples here:** [Adopt the Approver](adopt-the-approver.md),
  [Maintain this repo](maintain-this-repo.md), [Contribute](contributing.md),
  and this guide.

### Reference (`docs/reference/`) — information-oriented

Reference is for looking things up: exact, complete, consistent, and dry. The
reader arrives knowing what they want and leaves with the precise detail.

- **Do:** describe *what is*, exhaustively and consistently; use tables.
- **Don't:** motivate, persuade, or walk through a task.
- **Generated vs. hand-written:** the command and agent listings
  ([Commands](../reference/commands.md), [Agents](../reference/agents.md)) are
  **generated from skill/agent frontmatter** and diff-checked in CI (#757) —
  **never hand-edit them**; change the source frontmatter and regenerate with
  `scripts/generate-docs-reference.py`. The [Plugin overview](../reference/plugins.md)
  is the hand-written narrative counterpart.

### Explanation (`docs/explanation/`) — understanding-oriented

Explanation is discursive: it gives background, rationale, and the shape of
decisions. It's what you read on the sofa, not at the keyboard.

- **Do:** discuss *why*, weigh alternatives, admit trade-offs.
- **Don't:** give step-by-step instructions or exhaustive parameter lists.
- **Examples here:** [Motivation & current gaps](../explanation/motivation.md),
  [Why per-language plugins?](../explanation/why-per-language-plugins.md),
  [The Claude Approver](../explanation/claude-approver.md).

### Architecture (`docs/architecture/`)

C4 architecture diagrams (Mermaid) live here — a specialized reference. Delivered
by documentation epic 3/3 ([#746](https://github.com/timo-jakob/timos-claude-code-plugins/issues/746));
today it holds a placeholder.

## Mechanics specific to this repo

- **Add every new page to the nav.** `mkdocs build --strict` fails on a page
  that isn't in `mkdocs.yml`'s `nav:` (the `omitted_files` validation). Add your
  page under the right section when you create it.
- **Links are checked strictly.** A broken internal link fails the build. Links
  *out* of `docs/` (to repo-root `ARCHITECTURE.md`, per-plugin docs, scripts)
  are written as **absolute repo URLs**, not relative paths — relative links
  that escape `docs/` don't resolve in the built site. Links *within* `docs/`
  stay relative.
- **Line length is 120** (markdownlint MD013); tables and code blocks are
  exempt. A long URL only passes if it sits at the **end of the line** with no
  trailing text.
- **Root contracts stay put.** `ARCHITECTURE.md` and `MAINTAINING.md` remain at
  the repo root (skills, memories, and `CLAUDE.md` reference those paths); the
  docs site links to them rather than moving them.
- **Preview locally:** `pip install -r requirements-docs.txt` then
  `mkdocs serve` (or `mkdocs build --strict` to run the gate).

## Quick decision checklist

1. What is the reader *doing*? → picks the bucket (table above).
2. Is it a listing derivable from frontmatter? → it's **generated**; edit the
   source, not the page.
3. New page → add it to `mkdocs.yml` `nav:`.
4. Run `mkdocs build --strict` before pushing.
