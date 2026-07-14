# Write docs in a bootstrapped repo

How to add or update a documentation page in a repo that carries the
bootstrap-installed docs stack (`docs/` tree + `mkdocs.yml` + the docs
workflows). For what that stack is and why it exists, see
[The target-repo docs stack](../explanation/target-repo-docs-stack.md).

## 1. Pick the bucket

Ask what the reader is *doing* when they open the page — the
[Diátaxis](https://diataxis.fr/) question:

| The reader wants to… | Put the page in |
| --- | --- |
| learn by a guided exercise | `docs/tutorials/` |
| accomplish a task they understand | `docs/how-to/` — one page per job |
| look something up (exact, exhaustive) | `docs/reference/` |
| understand why | `docs/explanation/` |

A page doing two of these at once should be split. The per-surface pages
seeded by bootstrap (`docs/how-to/use-the-cli.md`, `use-the-rest-api.md`,
`use-the-web-ui.md`) are how-to guides: extend the matching one when your
change alters how that surface is used, or add a sibling page named for the
job when it deserves its own "How do I …?".

## 2. Write the page

- Title it as the reader's goal (how-to) or the thing described (reference).
- Use **representative data** in examples — real-looking names, IDs, and
  payloads from the feature's actual use case, never `foo`/`bar`.
- Link to other docs pages with relative paths; link *out* of `docs/` (to
  repo-root files or code) with absolute repo URLs.

## 3. Register the page — the strict build insists

Every page must appear in **both**:

- `mkdocs.yml` → `nav:` — `mkdocs build --strict` fails on an unlisted page
  (and on a nav entry whose file doesn't exist), and the PDF/ePub chapter
  order derives from this list;
- `docs/index.md` — the MOC that keeps every page reachable from one place.

## 4. Verify locally before pushing

Use the repo's pinned toolchain (CI-side only — don't add it to the app's
dependencies):

```bash
python3 -m venv .venv-docs && .venv-docs/bin/pip install -r requirements-docs.txt
.venv-docs/bin/mkdocs build --strict   # the exact PR-gate check
.venv-docs/bin/mkdocs serve            # live preview at http://127.0.0.1:8000
```

A green `--strict` build locally is the same bar the `docs` PR check applies.

## 5. Ship it with the change it documents

Docs ride the **same PR** as the feature they describe — that's the family's
same-PR docs discipline, and for stories resolved via
`/development:resolve-issue` it happens automatically when the story's surface
is not `none`. Your part as a story author is upstream: give the story a
concrete **`use_case`** during refinement — that's what the automated docs
step seeds the page's example from. A standalone docs improvement (fixing or
extending pages without a code change) is a normal PR; the strict gate is the
only extra hurdle.
