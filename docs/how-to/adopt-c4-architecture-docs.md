# Adopt C4 architecture docs on an existing repo

**Goal:** give a repo that was bootstrapped before the C4 machinery (or never
seeded its diagrams) a working `docs/architecture/` with a Context and a
Container diagram, seeded from the code and kept true by the pipeline.

If you are bootstrapping a **new** repo, seeding runs automatically — you can
skip straight to [Amend a C4 diagram](amend-a-c4-diagram.md) when the pipeline
later reports drift. This page is the **State-D adoption** path for a repo that
already exists.

## Before you start

- The repo has the docs site (an `mkdocs.yml` at the root). If not, adopt the
  docs stack first — see [The target-repo docs
  stack](../explanation/target-repo-docs-stack.md).
- You can run the family's bootstrap scripts against the repo.

## 1. Detect the containers

The seeder reads what the repo actually builds — Dockerfiles, compose services,
build images — via `detect-stack.sh`, and writes a Context + Container diagram
from it. Run the seeding step; it produces:

- `docs/architecture/c4-context.md` — the system landscape (a `C4Context` block).
- `docs/architecture/c4-container.md` — the deployable units (a `C4Container`
  block whose `Container` / `ContainerDb` / `ContainerQueue` entries are the
  **declared** set).

## 2. Read the detection verdict — and fill gaps by hand

Detection reports a **`detection_confidence`** of either `complete` or
`inconclusive`:

- **`complete`** — the verdict is definite: the detector either resolved the
  container-ish evidence it found, or found no container evidence at all (the
  marketplace/library case below). The seeded Container diagram reflects it;
  review the labels and technologies and refine the prose.
- **`inconclusive`** — the detector saw container-ish evidence it could **not**
  resolve into a definite set (an unusual build, an indirect image reference).
  **Seeding does not guess.** Treat the seeded diagram as a starting point and
  **add the missing containers by hand** against the declared-container shape
  (see [Amend a C4 diagram](amend-a-c4-diagram.md)). Never leave an
  `inconclusive` gap unfilled and never fabricate a container to make it look
  complete — on an `inconclusive` detection the pipeline deliberately
  **suppresses** the "declared but not detected" direction of drift (see the
  [`c4_drift` reference](../reference/c4-drift-findings.md)), and a container
  detection never saw can't surface as "detected but not declared" either, so a
  gap you leave will simply stay invisible.

A **marketplace or library repo** with no Dockerfile/compose surface is a normal
case: the detector finds little or nothing, and the containers you care about are
declared by hand. That is expected, not a failure.

## 3. Register the pages and check the build

Both pages must be in `mkdocs.yml`'s `nav:` (under an `Architecture` section) and
linked from the `docs/index.md` MOC — an unregistered page fails the strict
build. Then run the docs gate:

```bash
pip install -r requirements-docs.txt
mkdocs build --strict
```

The strict build proves the pages compile, every page is in the nav, and internal
links resolve. It does **not** validate the Mermaid diagram body — see [The C4
architecture docs](../explanation/c4-architecture-docs.md) for why, and what does
guarantee a diagram is machine-readable.

## 4. Commit — the diagrams are now maintained

Commit the two pages with the nav/MOC registration. From here the pipeline keeps
them true: a structural change updates the diagram in the **same PR**, and
maintenance reports any drift as a [`c4_drift`
finding](../reference/c4-drift-findings.md). You never seed again.

The diagram shape and level policy are defined once, in the contract — see
[`ARCHITECTURE.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md).
