# The C4 architecture docs

Every bootstrapped repo carries **C4 architecture documentation** under
`docs/architecture/` — a System Context diagram and a Container diagram, written
as Mermaid blocks in Markdown. This page explains the design decisions behind
that choice. For the exact rules a diagram must follow, see the contract in
[`ARCHITECTURE.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md);
to *do* something, see the how-to guides on
[adopting](../how-to/adopt-c4-architecture-docs.md) and
[amending](../how-to/amend-a-c4-diagram.md) diagrams.

## Who the diagrams are for

Two audiences, equally. Human contributors get an orientation to the system
without reading the whole codebase. And **Claude** reads `docs/architecture/`
before a structural change instead of re-deriving the system shape from scratch
every session — the diagrams are required agent reading, not decoration. That
second audience is why keeping them *true* matters more than drawing them well.

## Why Context and Container, but never Code

The [C4 model](https://c4model.com/) has four levels; this family requires the
top two and forbids the bottom one:

- **Context** and **Container** are **required**. They are the levels that stay
  stable enough to maintain and that answer the questions a newcomer or an agent
  actually asks — who uses the system, and what are its deployable parts.
- **Component** is **optional**. A component diagram for a genuinely intricate
  subsystem can earn its place, but it is never required, because most repos
  don't have a subsystem that needs one.
- **Code** level is **never** authored. A code-level C4 diagram just duplicates
  the source and rots the moment the source changes — it is negative value.

The precise policy is normative and lives in the contract; the reasoning above is
why it reads the way it does.

## Why Mermaid-in-Markdown, not a modelling tool

A dedicated C4 modelling tool (Structurizr and friends) was considered and
declined. Mermaid C4 blocks in Markdown win on the axes that matter here:

- They **render natively on GitHub** and through the docs site's Material +
  `superfences` pipeline, so a reader sees the diagram wherever the Markdown
  lives — no export step, no separate viewer.
- They add **zero repo tooling**: no modelling application, no diagram compiler,
  nothing to install or pin.
- They are **Claude-authorable** as plain text, which is what makes "update the
  diagram in the same PR as the code" realistic rather than aspirational.

### The honest cost

That choice has a real downside, stated plainly because pretending otherwise
would mislead. `superfences` renders Mermaid **client-side** — the fence is
emitted as a div and drawn in the browser — so `mkdocs build --strict` **never
parses the diagram body**. The strict build proves the page compiles, is in the
nav, and links resolve; it does **not** and **cannot** tell you the Mermaid is
valid or that it renders on GitHub. There is deliberately no Mermaid linter (it
would reintroduce the tooling this choice removed).

So diagram *validity* rests elsewhere: on the **parseable declared-container
shape** the contract pins (#790). The Container diagram's `Container(...)` entries
follow a strict per-line form that a small parser reads without a Mermaid engine —
and that same parse is the machine-checkable signal the pipeline compares against
the code. A diagram whose containers can't be parsed is the failure the shape
catches; a non-rendering block is caught by a human, not a gate.

## Why seed *and* maintain, never seed alone

The failure mode this whole machinery exists to prevent is **seeded-then-
abandoned** docs: a diagram generated once at bootstrap, never updated, quietly
drifting until it actively misleads. Seeding a diagram without a mechanism to keep
it true would have manufactured exactly that.

So the family treats "keep the diagram true" as three linked steps, not one:

1. **Seed** the diagrams at bootstrap, from the detected structure.
2. **Keep them current in the same PR** as a structural change — the diagram is
   part of the change, triggered by the working-tree structural detection, not
   filed as a follow-up that never comes.
3. **Report drift in maintenance** as a
   [`c4_drift` finding](../reference/c4-drift-findings.md), owned by the
   `development-docs` plugin, so a diagram that slips out of sync surfaces as
   normal maintenance work rather than rotting silently.

A diagram is only worth having if it is trustworthy, and it is only trustworthy if
something keeps it honest. That is the whole design.
