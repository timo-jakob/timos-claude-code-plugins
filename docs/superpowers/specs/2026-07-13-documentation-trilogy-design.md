# Documentation trilogy — Diátaxis docs machinery, target-repo docs lifecycle, C4 architecture docs

**Date:** 2026-07-13
**Relation:** independent of the WebUI chain (#682/#683) and the pipeline-telemetry
trilogy (#740–#742) — a third parallel track. Epic B/C touch the bootstrap
surface, so they coordinate (not block) with WebUI bootstrap work.

## Motivation

The plugin family's complexity has outgrown its documentation. Today:

- **This repo:** README.md is 845 lines / 14 sections doing three jobs at once
  (motivation + user guide + feature inventory); ARCHITECTURE.md is 1,900
  lines / 26 sections of contributor/Claude-facing contract; five per-plugin
  doc files sit scattered in `*/docs/`; ARCHITECTURE.md contains **dangling
  references** (`docs/CLAUDE-APPS.md`, `docs/ACCEPTANCE-CLI-VALIDATION.md` —
  neither exists). Docs drift has already started, and nothing gates it.
- **Target repos:** bootstrap ships CLAUDE.md / CONTRIBUTING.md / SETUP.md —
  contributor plumbing. Zero end-user documentation, zero architecture
  documentation.
- **Epics:** nearly every recent epic (#717, #719/#720, #722–#724, #740–#742)
  carries a "user-facing documentation" child with no defined place for that
  content to land.

Three audiences need three things: the **plugin developer** needs structured
maintainer docs; the **plugin user** (and the users of repos built with the
plugins) needs browsable/downloadable end-user manuals; **Claude itself** needs
machine-readable architecture context (C4) in every repo it works on.

## Decisions (settled in brainstorming, 2026-07-13)

| Decision | Choice |
|---|---|
| Doc structure | **Diátaxis** (tutorials / how-to / reference / explanation) **+ MOC index** (`docs/index.md` links every doc), identical shape in every repo |
| HTML toolchain | **MkDocs-Material** (nav from the tree, search, dark mode, mermaid via superfences) — CI-only dependency |
| PDF/ePub toolchain | **pandoc**, chapter order derived from the mkdocs nav (single source of structure); pinned official `pandoc/latex` container in CI |
| Publication | **GitHub Pages** (browsing) + **rolling `docs-latest` pre-release** (PDF/ePub assets) + **OCI image** to GHCR (`<repo>-docs`, nginx-alpine, offline/portable bundle) |
| C4 tooling | **Mermaid C4 blocks in Markdown** under `docs/architecture/` — renders natively on GitHub and in MkDocs, zero repo tooling, Claude-authorable. Context + Container required; Component optional |
| C4 lifecycle | **Bootstrap seeds + pipelines maintain**: resolve-issue updates C4 in the same PR (risk-gated), maintenance gains a `c4_drift` finding source, CLAUDE.md points agents at it |
| Packaging | **Trilogy A → B → C**, native blocked-by chained; machinery is built in this repo (A) before bootstrap templates it for target repos (B); C renders through B's site |

Constraints: no third-party dependencies in the plugins themselves (all doc
tooling is CI-side); path-conditional workflows (docs builds must not block
app PRs); every template change in B/C bumps the development plugin version.

## The shared foundation

### Tree (every repo)

```text
docs/
  index.md          ← the MOC: every doc linked, grouped by reader intent
  tutorials/        ← learning-oriented
  how-to/           ← task-oriented, one page per job
  reference/        ← lookup: commands, agents, schemas, config
  explanation/      ← concepts and rationale
  architecture/     ← C4 home (epic C; placeholder until then)
```

### Pipeline (built once in A, templated in B)

- **PR gate:** `mkdocs build --strict` + pandoc build success + internal link
  check. Docs that don't compile don't merge — this mechanically catches the
  dangling-reference class found in ARCHITECTURE.md.
- **On main:** deploy Pages; refresh the rolling `docs-latest` pre-release
  with `manual.pdf` + `manual.epub`; build + push
  `ghcr.io/<owner>/<repo>-docs` (nginx-alpine serving the built site; the
  PDF/ePub sit under `/downloads/` inside the site, so the image adds no
  logic beyond static serving).
- **Path-conditional** on `docs/**`, `mkdocs.yml` (and the workflow file
  itself), per the app-vs-container check-separation policy.
- The nav→chapters converter is a small zsh script (repo scripting
  conventions); pandoc/mkdocs run only in CI.

### Root files in this repo

README.md shrinks to a landing page (what / why / install / links into the
docs site). **ARCHITECTURE.md and MAINTAINING.md stay at repo root
untouched** — skills, memories, and CLAUDE.md reference those paths; the docs
site links to them instead of moving them.

## Epic A — docs machinery + this repo's docs (1/3)

- **(a)** Diátaxis skeleton + MOC + README slim-down + content migration
  (mined from README/ARCHITECTURE; fix the two dangling references).
- **(b)** mkdocs + Material config + strict-build PR gate.
- **(c)** pandoc PDF/ePub build + nav→chapters zsh script.
- **(d)** GitHub Pages deploy.
- **(e)** `docs-latest` rolling pre-release assets + OCI docs image to GHCR.
- **(f)** **Generated reference pages** — per-plugin command/agent reference
  generated from skill/agent frontmatter (name, description, tools, model),
  so the reference section cannot drift from the code (the version-sync
  precedent, applied to docs).
- **(g)** Authoring guide (Diátaxis placement rules, one page per how-to) +
  MAINTAINING.md update.

Acceptance (umbrella): docs site live on Pages; PDF/ePub downloadable; OCI
image runnable (`docker run` → browsable docs incl. downloads); strict gate
red on a broken link; reference pages regenerate from frontmatter.

## Epic B — target-repo docs machinery (2/3)

- **(a)** Bootstrap templates: `docs/` skeleton seeded with project name +
  detected surfaces, `mkdocs.yml.tmpl`, `docs.yml` workflow template (same
  gates + Pages/assets/OCI publication); State-D reconcile adopts docs into
  already-bootstrapped repos idempotently.
- **(b)** **resolve-issue same-PR user-docs step** (the deep child):
  story-readiness already classifies each story's surface
  (rest/grpc/web-ui/cli/none); when surface ≠ none, the feature PR must also
  update `docs/` (how-to or reference), seeded from the story-spec's
  `use_case`. Mirrors the same-PR test-case lifecycle (#737): target-repo
  docs are born maintained, not seeded-then-abandoned.
- **(c)** refine-issue epic summaries note which docs pages children will
  touch (small; may fold into (b) at filing time).
- **(d)** End-user docs about the docs stack itself (what bootstrap installs,
  how to write pages, how publication works).
- **(e)** Capstone validation on **ai-doc-organizer** (the family test bed).

**Out of scope (explicit):** a fuzzy maintenance "docs freshness" checker.
The mechanism is the strict CI gate + the same-PR discipline of (b) — no
speculative NLP drift detection.

## Epic C — C4 architecture docs (3/3)

- **(a)** Conventions doc: `docs/architecture/c4-context.md`,
  `c4-container.md`, optional `c4-component-<area>.md`; Mermaid C4 style
  rules; Context + Container required, Component optional.
- **(b)** Bootstrap seeding: a generator analyzes the repo (services,
  Dockerfiles, deps, contracts) and writes the initial Context + Container
  diagrams; State-D path included.
- **(c)** resolve-issue same-PR C4 update, **risk-gated**: a story classified
  `elevated` (architecture-touching) requires the PR to revisit
  `docs/architecture/`.
- **(d)** Maintenance `c4_drift` finding source: mechanical comparison of
  declared containers vs detected reality (Dockerfiles, compose services,
  main dependencies); findings dispatch like any other tool's.
- **(e)** CLAUDE.md(.tmpl) pointer: `docs/architecture/` is required reading
  for agents before structural changes — the Claude-facing half.
- **(f)** Dogfood: this plugin repo gets its own C4 (system landscape: the
  plugins, the GitHub Apps, target repos, the future reporting repo).
- **(g)** Capstone validation on ai-doc-organizer.
- **(h)** User-facing docs.

## Sequencing + GitHub packaging

- Trilogy chained with GitHub-native blocked-by (#583): **A → B → C**.
  B templates only machinery A has proven; C renders through B's site and
  touches the bootstrap surface B just changed.
- Epic A is immediately runnable — independent of #683/#729 and #740; a third
  parallel track.
- Titles follow the trilogy convention: `Epic: documentation (1/3 … 3/3)`.
- The pending "user-facing documentation" children of other epics remain in
  their epics; their content lands in the Diátaxis tree once A merges.
- B and C bump the development plugin version (template changes must reach
  installs).

## Out of scope (trilogy-wide)

- **Release notes / release engineering** — a separate future epic
  (conventional-commit-driven releases: release-please manifest mode for this
  repo's per-plugin versions, bootstrap-templated release automation for
  target repos, nebula-release remaining the Java answer). Today this repo
  has zero tags/releases and no CHANGELOG; the docs site's only touchpoint is
  rendering a changelog page when a CHANGELOG.md exists — a one-line hook,
  no dependency in either direction.
- Moving ARCHITECTURE.md / MAINTAINING.md out of repo root (reference
  breakage outweighs tidiness).
- A maintenance docs-freshness/NLP-drift checker (see epic B).
- Constellation-level C4 in composition repos (#687 territory; revisit when
  the composition plugin exists).
- Versioned docs (mike/multi-version Pages) — one live version until a real
  need appears.

## Risks

- **Content migration is judgment work** — mining 2,700 lines of README/
  ARCHITECTURE into Diátaxis pages is A(a)'s bulk; mitigated by migrating in
  waves (skeleton + highest-value pages first).
- **Bootstrap surface contention** — B/C touch bootstrap while WebUI epics
  (#682) also do; sequential PRs off fresh main (house rule) contain it.
- **Generated reference staleness inversion** — generation must run in CI
  (regenerate + diff-check), not by hand, or the generated pages become the
  new drift surface.
