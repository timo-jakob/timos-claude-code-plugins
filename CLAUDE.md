# CLAUDE.md

Repo-wide rules for Claude Code sessions in this repository. Architecture and
schema contracts live in ARCHITECTURE.md; template maintenance in MAINTAINING.md.

## Read `docs/architecture/` before structural changes

Before a **structural** change — adding, removing, or renaming a service,
container, datastore, message broker, or external integration — read
[`docs/architecture/`](docs/architecture/) first: this repo's C4 diagrams
(System Context and Containers, as Mermaid blocks) are the authoritative picture
of the deployable units and how they connect. **Keep it true in the same PR** —
a change that adds, removes, or renames any of the above, or changes what talks
to what, updates `docs/architecture/` alongside the code, not as a follow-up;
the maintenance pipeline flags drift between the declared containers and reality.

## Definition of "green CI" on a PR

A PR is **GREEN** when, after all checks have settled (none pending), **zero
checks are in the `fail` bucket** of `gh pr checks --json name,state,bucket`.

- **CANCELLED checks are neutral, never failures.** The Approver gate's
  `approve`/`approver-gate` jobs are cancelled by design on every run (the
  `pull_request`-triggered run is superseded by the `check_suite` run, #190).
  Counting the `cancel` bucket as failure flips every green Approver PR to
  NOT-GREEN.
- A genuinely-cancelled *required* check is enforced by branch protection
  (auto-merge simply won't fire) — not by this verdict.
- The authoritative implementation is
  `development/skills/maintenance/scripts/merge-pr-cycle.zsh` (`_await_settle`).
  Use it instead of hand-rolling `gh pr checks` parsing; if you must judge
  greenness ad hoc, apply the same rules.

## Pillars are stated once — link `docs/explanation/philosophy.md`, never restate

The family's six pillars live in
[`docs/explanation/philosophy.md`](docs/explanation/philosophy.md), one H2 per
pillar with a stable anchor (`#pillar-1` … `#pillar-6`). When a docs page, a
skill, an agent or an issue justifies a decision with a pillar, link that
anchor and do not paraphrase the pillar's wording — state once, link
everywhere (#1432).

**Link it in the form that resolves from where you are writing**, since a
relative path is resolved against the linking file. The `#pillar-N` fragment
is live on the published site and in `manual.pdf`; GitHub's renderer ignores
it, so anywhere read on github.com the link lands at the top of the page:

- from a page in `docs/explanation/`: `philosophy.md#pillar-N`;
- from any other page under `docs/`, the path relative to that page —
  `../explanation/philosophy.md#pillar-N` from a bucket subdirectory such as
  `docs/how-to/`, `explanation/philosophy.md#pillar-N` from `docs/index.md`;
- from a repo-root file (`README.md`, `ARCHITECTURE.md`, this file):
  `docs/explanation/philosophy.md#pillar-N`;
- from anywhere that is none of those — a skill, an agent, a bootstrap
  template or a GitHub issue, which are read detached from this repo (an
  installed plugin's cache, a generated repo, an issue body) where no relative
  path to `docs/` resolves — the
  absolute repo URL
  `https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/docs/explanation/philosophy.md`,
  and **name the pillar in the surrounding prose** ("pillar 5"), because that
  link carries no anchor a reader can follow.

**What "the pillar's wording" means:** a pillar's italic one-liner, its
**Statement** and its **Why** are worded only on the philosophy page — **in the
contexts above**, do not reproduce or paraphrase them. The H2 title may be used
as link text, adapted only in capitalisation to fit the sentence.

**These are deliberately exempt**, and none of them is ever edited to satisfy
this rule:

- a position's own rationale in `ARCHITECTURE.md` — however it is marked,
  whether an inline *Rationale:* or a `**Rationale.**` paragraph — which may
  argue the underlying principle in its own words. Where a position has its own
  `tests/*-position*.bats` suite its rationale is pinned clause-by-clause there
  and changes with that suite; where it has none, change it as ordinary prose;
- this repo's own statement of purpose — `README.md`'s *Why* and
  `docs/explanation/motivation.md`'s *Motivation*. Those predate the pillars
  and are the prose they were distilled from, not a copy of them;
- anything historical: dated records under `docs/superpowers/` and every
  fixture under `tests/fixtures/`, where a rewrite would falsify the record or
  mutate a test's input;
- a needle in `tests/*.bats` that quotes a pillar's wording in order to pin it.
  Reproduction there is the guard on this rule, not a breach of it — rewriting
  one deletes the check that would have caught the breach.
