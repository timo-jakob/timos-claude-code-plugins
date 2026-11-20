# Protection needs — one assessment per product, and every Feature checked against it

Date: 2026-11-20. Status: draft for maintainer approval. One epic that extends
the product layer umbrella
([`2026-11-18-product-layer-umbrella-design.md`](2026-11-18-product-layer-umbrella-design.md))
as its project 10. It is the first piece of the "governance and risk" place in
the Intent & Synthesis part of the delivery loop; others may follow.

Items marked **(my call)** were decided by the author of this document, not by
the maintainer; they are open to correction at review.

## Intent and why

Before a product is built, its owner should know how bad it would be if its
information leaked, was falsified, was unavailable or was lost — and how much of
each the business can tolerate. That is a business impact analysis, and its
result is the product's **protection needs**: a level per class of protection.
The level is what justifies effort later: how much isolation, how much
redundancy, how often a backup.

The family today has no notion of it. Risk is weighed only at the end, on a
finished diff. A Feature is defined, made ready and built without anyone asking
which information it touches or what that information needs. Where an
assessment exists at all, it sits in a document no tool reads.

The maintainer works with two such assessments that do not agree in form: one
rates the whole product on a scale with measurable guide values and includes
data loss as a class; the other rates individual assets, reasons carefully about
how ratings combine, and has neither data loss nor guide values. He wants **one
consistent way**, and decided its corner points:

- The analysis is **always for the whole product**. A component gets no rating
  of its own; it is assessed by its impact on the whole.
- Levels have **names, not numbers**, and there are four of them.
- **Data loss** is a class of its own beside confidentiality, integrity and
  availability.

## Goals

1. An owner declares the scale once — the classes, the named levels and what
   each level means in measurable terms — and every product assessed against it
   uses the same one.
2. Each product has exactly one protection-needs assessment, kept with its
   charter, with a dated log of changes.
3. The product's rating is derived from the kinds of information it holds, by
   stated rules, and every deviation from those rules is justified in writing.
4. Each component states what it contributes to the product's rating instead of
   carrying a rating of its own.
5. A target the owner has decided — a recovery time, a maximum loss — can never
   be weaker than the product's level allows, and a check says so.
6. `/product:assess-protection-needs` produces and updates the assessment in an
   interview; the human decides every rating.
7. A Feature names the kinds of information it touches. A kind the assessment
   does not know stops the Feature until the assessment is updated, and what
   the levels demand reaches the story as non-functional requirements.

## Non-goals

- A scale shipped by the family. The owner declares theirs; the family ships
  the method and the checks. Every example here and in the docs is invented.
- Threat modelling and risk treatment. This epic establishes how much
  protection is needed, not what threatens it or which measures answer it.
- Mapping levels to technical measures. That belongs to the architect's linked
  documents and is a later epic.
- Weighting review findings by level, and deriving monitoring targets from the
  availability level. Later epics; this one produces what they will read.
- Privacy records, subprocessor lists, certification evidence.
- Rating a component, a repo or a single Feature on its own.

## Anti-goals (a failure even if it works)

- A rating an agent proposed is written down without a human having decided it.
- A Feature that brings a new kind of information into the product is built
  before anyone has rated that kind.
- Two assessments of one product that can disagree.
- A decided target weaker than the level it serves, unnoticed.
- A component rated in isolation, so that the sum of the parts contradicts the
  whole.
- Damage scenarios of a real product published by accident because the
  assessment was written into a public repository.
- A scale with a hole in it: a damage amount or a duration that belongs to no
  level, so that two people rate the same thing differently.

## Approaches considered

**What is rated.** (a) The whole product; (b) each component; (c) each asset,
with no product-level result. **Chosen: (a)**, by the maintainer. A rating per
part makes no sense to him, and the parts can be assessed by their impact on
the whole. The asset view of (c) is kept as the *reasoning* for the product's
rating, and (b)'s concern is kept as each component's *contribution*.

**The scale.** (a) Numbered levels; (b) named levels. **Chosen: (b)**, by the
maintainer, with four levels and with data loss as a fourth class. The family
hard-codes neither the names nor the count nor the classes: it reads them from
the owner's scheme (my call, following the styleguide precedent).

**Where the assessment lives.** (a) A section inside an existing security
document; (b) its own product document. **Chosen: (b)** (my call): one file
with one contract can be validated, looked up and rendered like the charter,
and other documents link to it instead of carrying a second table.

**Where a component's contribution is written.** (a) In each component's repo;
(b) centrally, in the product's assessment. **Chosen: (b)** (my call): the
analysis is for the whole product, so it is read and changed in one place.

**No scheme declared.** (a) Fall back to a built-in scale; (b) do nothing.
**Chosen: (b)** (my call): a scale carries money amounts and durations that are
company policy. A repo whose linked documents declare no scheme is unaffected
by everything here.

## Design

### 1. The protection scheme (`protection-scheme/v1`)

One data file in the documents a repo links (umbrella project 4, #3198), beside
the owner's human-readable policy. It declares:

- **classes** — each with an id, a name and a **guide kind**: none, or a
  duration. In the maintainer's scheme the four classes are confidentiality,
  integrity, availability and data loss; availability's guide is the tolerable
  downtime and data loss's is the tolerable loss period.
- **levels** — an ordered list, lowest first, each with an id and a name.
- **per class and level** — the criteria as text, an optional upper bound on
  the damage amount, and for a class with a guide kind the tolerable duration.

Rules a validator enforces:

- **No holes.** Within a class, each level's damage bound is higher than the
  one before and the top level is unbounded; durations get stricter level by
  level. A value on a boundary belongs to the lower level. An owner whose
  written policy leaves a gap between two levels closes it when writing the
  scheme.
- Every class has an entry for every level.
- Ids are unique and stable; a level or class is never renamed in place once an
  assessment uses it.

**Where it is found (my call).** By the same lookup as a product document: in
the repo itself, else in the first linked submodule that has it. So a scheme may
sit in the product's own docs repository or in a separate policy repository
that one links. Its **version** is the commit of whichever repository holds it,
and an assessment records that version.

**When the scheme moves on (my call).** The validator always checks an
assessment against the scheme as it is now, never against an old version. When
the recorded version differs from the current one, a still-valid assessment is
reported as **stale**: the meaning of a level may have changed, so a human
re-confirms it by running the skill in update mode, which records a change
entry and the new version. Stale is a stop for Features (section 4).

### 2. The assessment document (`protection-needs/v1`)

**File:** `docs/product/protection-needs.md`, found by the product-document
lookup: in the repo itself, else in the first linked submodule that has it. One
per product, like the charter.

**Layout:** the same two-layer shape as `charter/v1` — prose a human owns,
fenced by sentinel comments, and a generated JSON mirror with a prose hash.

**Prose sections, in this order:**

1. **Summary** — the product's rating, one line per class, and the one or two
   judgements that decided it.
2. **Scope** — what the product is, and its components.
3. **Kinds of information** — one entry per kind: what it is, its level in
   each class, and for each level one sentence saying what would happen.
4. **The product's rating** — per class, the level and how it follows.
5. **Components** — what each contributes.
6. **Decided targets** — values the owner has committed to.
7. **Changes** — the dated log, newest first.

**The block:**

- `schema`, `provenance`, and `scheme` (the pinned version of the scheme used).
- `components[]` — id and name. The agent proposes them from what it can read
  — the member list of a composition workspace, a C4 container diagram — and
  the human confirms them. No parser is involved and no diagram is required: a
  product with nothing to split is one component **(my call)**.
- `kinds[]` — stable id, name, and per class a `level` and a `scenario`.
- `rating` — per class: `level`, `derivation` (`highest` | `raised` |
  `lowered`) and, unless `highest`, a `justification`.
- `contributions[]` — per component: `handles` (kind ids) and per class one of
  `breaks`, `degrades` or `none`, with a one-line reason. The question asked is
  the same in every class: *if this component alone failed or was compromised,
  what happens to the product's need in this class?* `breaks` — the need is
  no longer met (for confidentiality: information at the product's level is
  exposed; for data loss: data at that level is gone); `degrades` — the
  product is worse but the need holds; `none` — it does not matter.
- `targets[]` — class, value, and where it was decided.
- `changes[]` — id, date, what changed, why, and evidence.

**Rules the contract states and a validator enforces:**

- **Highest wins.** A class's product level is the highest level any kind has
  in that class, unless the derivation says otherwise.
- **Raising and lowering need a reason.** `raised` is for aggregation: many
  records of a harmless kind in one place are not harmless. `lowered` is for
  distribution: no single place holds enough to matter. Either without a
  justification is invalid, and a `lowered` rating may sit at most one level
  below the highest **(my call)**.
- **Coverage.** Every kind is handled by at least one component; every listed
  component has a contribution; every id resolves.
- **Someone carries each need.** For a class whose product level is above the
  lowest, at least one component must be `breaks`. A product whose need nobody
  can break has the wrong rating or the wrong contributions **(my call)**.
- **Targets are at least as strict as the level.** A decided duration longer
  than the level's tolerable duration is invalid.
- **Nothing is deleted.** A kind or component that leaves is marked retired,
  and a change entry names it. A kind may be retired only when the product no
  longer holds it anywhere, archives and backups included; retired entries
  take no part in the rules above. As with the charter, the validator is a
  single-file check; a rating edited in place with no change entry is guarded
  by the agent and the PR diff.
- The JSON mirror matches the prose hash.

### 3. `/product:assess-protection-needs` and the `protection-assessor` agent

The family's usual split: the agent is a function of one turn that proposes and
asks, and writes nothing; the skill owns every write. The session is attended.

**Where it runs.** In the repository that holds the product's documents: the
repo itself for a single-repo product, the shared docs repository for a
multi-repo one — as with the charter. There the other repos are not at hand, so
the skill accepts further directories to read as evidence (checkouts of the
member repos, the composition repo). Without them the agent works from the
documents and the interview **(my call)**.

**Clean stops,** each naming its reason: no scheme found; the scheme is
invalid; a linked repository is not initialised.

**Evidence the agent reads:** the charter and personas, data models and
migrations, API specifications, the architecture diagrams or the workspace
members, and any security or privacy document the repo or its linked documents
carry.

**How the agent behaves:**

- It proposes kinds of information from the evidence, each with levels and
  scenarios drawn from the scheme's own criteria, and says what each proposal
  rests on.
- It challenges rather than confirms: a kind the evidence shows but the human
  did not name; personal data rated at the lowest level; many tenants' or many
  users' data in one store with no aggregation argument; an availability level
  no component is said to break.
- It never decides. Every level in the written document was confirmed by the
  human in the session.
- In update mode it proposes the change-log entry for every rating it changes.

**Ending:** the human approves the draft. The skill writes the file, validates
it, renders it to PDF and ePub with the house renderer, and prints both paths.
It does not commit or push.

**A public repository.** An assessment contains damage scenarios. When the repo
it would be written into is public, the skill says so and asks for explicit
confirmation before writing; for a product with a private shared docs
repository it says to run the skill there instead **(my call)**.

### 4. Features and the assessment

This part needs the product stage and the technical stage (umbrella project
5, #3199). It is split along that line **(my call)**: the product stage knows what
a Feature is about, but only the technical stage knows which components a
story changes.

**In the product stage (`product`).** A Feature's definition lists the kinds of
information it reads, writes or exposes, by id — or says explicitly that it
touches none. The agent proposes the list from the Feature's text and the
assessment. The definition then carries the **product's rating** and its guide
values, with the assessment's version: the analysis is for the whole product,
so that is what a Feature is defined against. Two stops:

- a kind the assessment does not have;
- an assessment that is missing, invalid or stale.

**In the technical stage (`development`).** When a Feature is split into
stories, each story names the components it changes. Two more stops:

- a component that would handle a kind it is not listed as handling;
- a change that would alter a component's contribution — for example, a
  component whose failure only degraded the product now being required for it
  to work.

For each story a script then narrows the product's rating to the components it
changes: the product's level and guide values where a component `breaks`; "must
not worsen" where it `degrades`; nothing where it is `none`. The result is
written into the story's non-functional requirements.

Every stop sends the human to `/product:assess-protection-needs`. Nothing is
rated on the spot and nothing is assumed — the umbrella's "no charter, no
guessing" rule applied to protection needs.

**Two plugins, one script.** The validators and the narrowing script live in
`product`; the technical stage uses byte-identical copies under a comparison
test, as the family does for the hash script. Neither plugin needs the other
installed.

**When this is active.** Only where the lookup finds a scheme. There, a missing
assessment is itself a stop that offers to create one.

### 5. Tests, docs

- The two validators and the requirement derivation are scripts with bats
  suites; the contracts are documented in `ARCHITECTURE.md`.
- The agent's behaviour is judged on an invented reference product with
  `/development-claude-plugin:test`, outside the per-PR suite: it must propose
  the kinds the fixture's evidence shows, raise the aggregation question the
  fixture is built to provoke, and write no level the scripted human did not
  confirm.
- Docs: a how-to for declaring a scheme, a how-to for assessing a product,
  reference pages for the two contracts, and an explanation page on the method
  — filed under Intent & Synthesis in the manual's planned grouping.

## Constraints

- macOS + Homebrew only for running the skill.
- This repo is public. No real scheme, amount, duration or scenario is copied
  into docs, tests, fixtures or examples; everything illustrating the mechanism
  is invented.
- The family hard-codes no class, no level name and no level count.
- `product` must work with `development` not installed.
- zsh for new scripts; anything checkable is a script with bats tests, not
  prose in a skill.
- Repos with no declared scheme behave exactly as today.

## Delivery

One epic under the product super-epic (#3194). Depends on #3195 (the lookup,
the charter pattern, the renderer) and #3198 (the linked documents the scheme
lives in); children 5 and 6 also on #3199. Children, in order:

1. The `protection-scheme/v1` contract and its validator.
2. The `protection-needs/v1` contract and its validator.
3. The `protection-assessor` agent and its reference product.
4. `/product:assess-protection-needs`.
5. The product stage: a Feature's kinds, the product's rating in its
   definition, and the two product-stage stops.
6. The technical stage: the two component stops and the per-story
   requirements.
7. How-to, reference and explanation pages.

## Left to the builder

- File name and format of the scheme file; field names of both contracts beyond
  those named here.
- How durations and amounts are written and compared.
- Where the derived requirements sit inside a story's definition.
- Child-story boundaries, if the size check asks for a further split.

## To verify first (the design assumes these)

- The product stage (project 5) lets a Feature's definition carry a list of
  information kinds in a form a script can read, and offers a place for an
  extra stop.
- The technical stage (project 5) records which components a story changes,
  or can be made to.
- Repository visibility can be read without extra permissions in every setup
  the skill runs in; where it cannot, the skill asks instead of assuming.
