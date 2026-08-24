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

C4 architecture diagrams (Mermaid) live here — a specialized reference: a System
Context and a Container diagram, seeded from the code and kept true by the
pipeline. See [The C4 architecture docs](../explanation/c4-architecture-docs.md)
for the why and [Amend a C4 diagram](amend-a-c4-diagram.md) for the how.

## Mechanics specific to this repo

- **Register every new page in three places.** `mkdocs build --strict` fails on
  a page that isn't in `mkdocs.yml`'s `nav:` (the `omitted_files` validation) —
  but that is the *only* one it catches. The `docs/index.md` MOC entry and the
  bucket's own `index.md` entry can both be dropped with the site still building
  green, so several suites pin all three (see `tests/telemetry-user-docs.bats`).
  Add all three when you create the page.
- **Links are checked strictly.** A broken internal link fails the build. Links
  *out* of `docs/` (to repo-root `ARCHITECTURE.md`, per-plugin docs, scripts)
  are written as **absolute repo URLs**, not relative paths — relative links
  that escape `docs/` don't resolve in the built site. Links *within* `docs/`
  stay relative.
- **Every heading an in-page (`#…`) link targets needs an explicit id.** The
  site and `manual.pdf` slugify headings differently — python-markdown's `toc`
  strips a `.`, pandoc's `auto_identifiers` keeps it, and pandoc additionally
  drops everything before the first letter — so a link written for one renderer
  can dangle in the other. Don't try to predict which headings diverge: put the
  anchor MkDocs **already publishes** on the heading itself.

  ```markdown
  ### Check your own `contracts-lint.yml` first {#check-your-own-contracts-lintyml-first}
  ```

  **Read that anchor before you write the id, never guess it.** Read it from the
  page *as published* — the live site's ¶ permalink beside the heading, or a
  build of the page as it stands on `main`:

  ```bash
  mkdocs build
  grep -o 'id="[^"]*"' site/how-to/adopt-the-api-styleguide/index.html | grep -v '"__'
  ```

  Paste it verbatim. Reading it *after* you have added your guess just shows the
  guess back to you, and an id that differs from the published one keeps the site
  build green while quietly breaking every existing bookmark and inbound link —
  the one outcome writing the id explicitly is meant to avoid. A heading that
  does not exist on `main` yet has no anchor to preserve, so any id is safe
  there. The pandoc job fails on an unresolved reference, so a missing id shows
  up as a red `docs` check.
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
3. New page → add it to `mkdocs.yml` `nav:`, the `docs/index.md` MOC, **and**
   the bucket's `index.md` (only the first is caught by the strict build).
4. Run `mkdocs build --strict` before pushing.
