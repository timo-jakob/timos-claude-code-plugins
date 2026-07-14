# The target-repo docs stack

Every repo bootstrapped by `/development:bootstrap` is born with an end-user
documentation stack — the same machinery this repo's own docs site runs on,
proven here first (epic
[#744](https://github.com/timo-jakob/timos-claude-code-plugins/issues/744)) and
then templated for target repos (epic
[#745](https://github.com/timo-jakob/timos-claude-code-plugins/issues/745)).
This page explains what gets installed, how publication works, and — the part
that makes it more than a scaffold — how the pipelines keep the docs alive
afterwards.

The design conviction behind it: **seeded docs rot unless the machinery that
ships features also ships their documentation.** So the stack is two things at
once — a publication pipeline, and a lifecycle discipline wired into the
family's issue-to-PR flow.

## What bootstrap installs

A bootstrapped repo gets the full [Diátaxis](https://diataxis.fr/) tree and the
toolchain around it:

| Artifact | Job |
| --- | --- |
| `docs/` tree (`index.md` MOC + `tutorials/`, `how-to/`, `reference/`, `explanation/`, `architecture/`) | The Diátaxis skeleton, seeded with the project name; `architecture/` is a placeholder until the C4 epic (#746) |
| `docs/how-to/use-the-<surface>.md` | One how-to stub per **detected interface** (cli / rest / web-ui) — a CLI-only project gets no REST stub |
| `mkdocs.yml` | MkDocs-Material config; its `nav:` is the single source of structure for the site **and** the manuals |
| `.github/workflows/docs.yml` | The PR gate: `mkdocs build --strict` + a pandoc PDF/ePub build |
| `.github/workflows/docs-deploy.yml` | GitHub Pages deploy on the default branch |
| `.github/workflows/docs-publish.yml` | Rolling `docs-latest` pre-release (PDF/ePub) + OCI docs image on the default branch |
| `Dockerfile.docs`, `requirements-docs.txt`, `scripts/docs-nav-to-chapters.zsh` | The image recipe, the pinned CI-only toolchain, and the nav→chapters converter the manuals build with |

Two properties are deliberate:

- **No app dependencies.** The whole toolchain is CI-side (`pip install -r
  requirements-docs.txt` happens in the workflow); nothing lands in the
  project's own dependency tree.
- **Path-conditional workflows.** The docs checks trigger only on the docs
  surface (`docs/**`, `mkdocs.yml`, the pins, the workflow files), so an app PR
  is never blocked by docs machinery — and the docs checks are never required
  branch-protection contexts.

**Already-bootstrapped repos aren't left behind.** The bootstrap's State-D
gap-fill detects the missing docs artifacts on a re-run and adopts the whole
stack idempotently — re-running immediately after finds nothing to do. That is
how a repo bootstrapped before the docs stack existed acquires it.

## How publication works

One merge to the default branch fans out into three publication channels, all
driven by the same build:

1. **The PR gate first** (`docs.yml`): the site must build with
   `mkdocs build --strict` — a broken internal link or a page missing from the
   nav *fails the check* — and pandoc must produce `manual.pdf` +
   `manual.epub` from the same nav order. Docs that don't compile don't merge.
2. **GitHub Pages** (`docs-deploy.yml`): the browsable HTML site, rebuilt and
   redeployed on every docs-touching merge.
3. **`docs-latest` pre-release + OCI image** (`docs-publish.yml`): the same
   build refreshes a rolling GitHub pre-release carrying the PDF/ePub manuals,
   and pushes `ghcr.io/<owner>/<repo>-docs` — an nginx image serving the built
   site with the manuals under `/downloads/`, so `docker run` gives a fully
   offline docs bundle.

The `nav:` in `mkdocs.yml` is the only structural authority:
`scripts/docs-nav-to-chapters.zsh` derives the manuals' chapter order from it,
so the site and the PDF/ePub can never disagree about structure.

## How the docs stay maintained

The strict gate stops docs from *breaking*, but not from *silently lagging the
product*. That job belongs to the lifecycle wiring in the family's pipelines —
deliberately mechanical, no NLP "freshness" heuristics:

- **At refinement time — visibility.** When `/development:refine-issue` walks
  an epic, each ready child's summary line notes the docs pages the story will
  likely touch (the refiner's `expected_docs_pages`), so docs impact is on the
  table before anything is built.
- **At build time — enforcement.** When `/development:resolve-issue` builds a
  story whose classified surface is anything other than `none`, the feature PR
  **must also add or update the matching `docs/` page** — planned mechanically
  from the story-spec (`plan-user-docs.zsh` maps each surface to its how-to
  page), seeded from the story's `use_case`, and gated by the same
  `mkdocs build --strict` before the PR opens. Feature and documentation land
  in one PR and can't drift apart — the same discipline the family applies to
  acceptance tests.
- **What a story author contributes:** a concrete `use_case` during
  refinement. That single field is what turns the docs step from boilerplate
  into a real, example-carrying page update.

For the practical authoring steps in a target repo, see
[Write docs in a bootstrapped repo](../how-to/write-docs-in-a-target-repo.md).
