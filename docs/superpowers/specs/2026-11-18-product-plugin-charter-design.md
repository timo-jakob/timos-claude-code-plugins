# Project 1 — the `product` plugin, the product charter, and the PDF + ePub renderer

Date: 2026-11-18. Status: draft for maintainer approval. Part of
[the product-layer umbrella](2026-11-18-product-layer-umbrella-design.md).

Items marked **(my call)** were decided by the author of this document, not by
the maintainer; they are open to correction at review.

## Intent and why

The maintainer's direction has changed several times and nothing records it.
Examples he gave:

- from *open source first* (SonarCloud only for public repos, toolchain derived
  from visibility) to *private and commercial repos too* (any known tool is
  allowed, including paid SonarCloud on private repos);
- from *detect and decide for the user* to *a good default that can be
  overridden* (the Approver model is a default per repo type, overridable);
- from *no configuration file in the repo* to *an optional `.maintenance.yml`*
  — never required, present only to override or declare;
- plain review suggestions dropped; panels report only what blocks (#3121,
  #3122).

Old issues still assume the earlier direction, and a tool cannot tell, because
the current direction is unwritten. This project writes it down — once, in a
form tools can read and colleagues can be sent — and gives the family a place
(the `product` plugin) for everything product-side that follows.

The reader of the rendered document is a **colleague or stakeholder judging the
direction**. So the document is a *charter* (decisions, non-goals, what is
deliberately not built), not a pitch.

## Goals

1. A `product` plugin exists in the marketplace and `define-personas` lives in it.
2. `/product:define-charter` interviews a human and writes `docs/product/charter.md`
   in any repo: human-readable prose plus a machine-readable `charter/v1` block.
3. The charter carries a **dated, append-only log of direction changes**, and
   recording a new change is a first-class path of the skill.
4. Every clause a later tool may need to cite (a value, a scope item, a
   non-goal, a direction change) has a **stable id**.
5. One renderer turns product documents into **both PDF and ePub**, always, in
   one house style, with no styling options.
6. After this project the maintainer can run the skill on this repo and hold a
   charter PDF he would send to a colleague unedited.

## Non-goals

- Issue types, idea capture and the board; backlog grooming; linked reference documents; the
  refinement split; roadmap and prioritisation (projects 2–6).
- Diagrams in rendered documents (Mermaid or otherwise) — deferred to the
  roadmap project, which needs them.
- Publishing rendered files from CI, or attaching them to releases.
- Running locally on anything but macOS + Homebrew.
- Translating documents; theming; per-repo branding.
- Changing the `personas/v1` schema or where `docs/personas.md` lives.
- Authoring this repo's own charter content — that is the maintainer's first
  *use* of the skill, done interactively after the build, not a build story.

## Anti-goals (a failure even if it works)

- The rendered PDF and the Markdown can disagree.
- The charter in this repo restates a pillar's wording (the repo rule: stated
  once in `docs/explanation/philosophy.md`, linked everywhere).
- The skill asks its human "how" questions — tooling, layout, file placement.
  See [Never asks "how"](../../explanation/philosophy.md#pillar-2).
- A direction change can be recorded by silently rewriting an old value, leaving
  no trace that the direction was ever different.
- The renderer grows options. One look.

## Approaches considered

**Where the product skills live.** (a) A new `product` plugin; (b) inside
`development`. **Chosen: (a)**, by the maintainer — different roles, installable
on its own. He also chose to move `define-personas` into it rather than leave it
behind.

**What "no longer wanted" is judged against** (the reason this project is
first). (a) A written charter produced before grooming; (b) the groomer
interviews the maintainer per theme as it goes. **Chosen: (a)**, by the
maintainer — every close can cite a clause, and the answer is not asked again
next time.

**How the PDF is made.** (a) pandoc + Typst; (b) HTML printed by headless
Chrome; (c) pandoc + xelatex as `manual.pdf` uses. **Chosen: (a)**, by the
maintainer on the author's recommendation — two small Homebrew installs, one
template file, identical output on every machine so CI can test it. (b) varies
with the Chrome version; (c) needs a multi-gigabyte install and is hard to make
look good. The maintainer added: output is **always both PDF and ePub**.

## Design

### 1. The `product` plugin

- Directory `product/` at the repo root, with `.claude-plugin/plugin.json`, an
  entry in `.claude-plugin/marketplace.json`, starting at version `0.1.0`.
- The name is deliberately not `development-*`. It is neither a language plugin
  nor a topic plugin: it has no gather script, no maintenance dispatcher, no
  resolve profile, no review panel, and the maintenance orchestrator's discovery
  must not pick it up.
- ARCHITECTURE.md gains a short section saying what `product` owns and that it
  is outside the language/topic model.

### 2. Moving `define-personas`

- `development/skills/define-personas/` → `product/skills/define-personas/`;
  `development/agents/persona-definer.md` → `product/agents/persona-definer.md`.
  The command becomes `/product:define-personas`, the agent type
  `product:persona-definer`.
- **No alias is left in `development`** (my call — one blessed path; the only
  installed base is the maintainer). Every reference is updated in the same
  change: `refine-issue`, `issue-refiner`, `story-readiness`, README,
  ARCHITECTURE.md, the `docs/` pages, the SDLC diagram (`sdlc.mmd` and its
  `.svg`), `docs/personas.md`, and `tests/persona-derivations.bats`.
- `provenance.generated_by` strings written from now on name the new command.
  Existing registries with the old string stay valid; the string is
  informational and no validator may reject the old value.
- `development` now points at a command in another plugin. Where
  `refine-issue` routes a human to define a missing persona, it names
  `/product:define-personas` and says in one line that it ships in the `product`
  plugin. Nothing in `development` fails when `product` is absent: persona
  checks were advisory before and stay advisory.
- `define-personas` gains one step: after its write, it renders the registry
  through the renderer (section 5).
- `define-personas` today computes its prose hash with a script inside
  `development` (`refine-issue/scripts/story-spec-prose-hash.zsh`). Installed
  plugins live in separate directories, so that path breaks after the move.
  `product` gets **its own copy** of the hash script, and a test pins the two
  copies byte-identical (my call — it keeps `product` installable without
  `development`, which moving or sharing the script would not).

### 3. The charter document and the `charter/v1` contract

**File:** `docs/product/charter.md` in the target repo (my call on the path;
`docs/personas.md` stays where it is).

**Layout:** the same two-layer shape as `personas/v1` — prose is
human-authoritative and fenced by sentinel comments; a collapsed `<details>`
holds a generated JSON mirror with the same provenance and staleness mechanism
(`prose_sha256` over the fenced prose). The contract is written into
ARCHITECTURE.md beside the persona contract and reuses its provenance section
rather than restating it.

**Prose sections, in this order:**

1. **Summary** — at most one page; the only part some readers will read.
2. **Purpose and background** — what the product is for and why it exists.
3. **Who it serves** — two or three sentences plus the persona ids, linking the
   registry. Personas are never redefined here.
4. **Values** — what wins when goals conflict.
5. **What we build** — scope, as a short list of capabilities.
6. **What we deliberately don't build** — non-goals, each with its reason.
7. **Direction changes** — the dated log, newest first.

**The block** (field names are the builder's to finalise; the content is not):

- `schema: "charter/v1"`, `provenance` (as personas).
- `title` and `appendices` (repo-relative Markdown paths, may be empty) — what
  the renderer needs, so a charter can be re-rendered from the file alone.
- `purpose`, `background` — text.
- `serves` — persona ids; each must exist in the repo's registry if there is one.
- `values[]`, `scope[]`, `non_goals[]` — each entry has a stable `id`, a
  `status` (`active` or `retired`), and **either** a `statement` (+ `rationale`
  for non-goals) **or** a `ref`: a link to where the repo already states it,
  with the link's title. Never both.
- `direction_changes[]` — each has `id`, `date` (ISO), `from`, `to`,
  `rationale`, `affects` (ids of the values / scope items / non-goals it
  introduced, changed or retired), and `evidence` (issue or PR references, may
  be empty).

**Rules the contract states and a validator enforces:**

- Ids are unique, and never reused or renumbered. Shape (my call): `V-<n>`,
  `S-<n>`, `NG-<n>`, `DC-<yyyy>-<mm>-<n>`.
- An entry is never deleted. A value or non-goal that no longer holds becomes
  `retired`, and a direction change must name it in `affects`. The validator
  checks this within one file: every `retired` entry is named by some change.
- Every id in `affects` and `serves` resolves.
- A `ref` path resolves in the repo.
- The JSON mirror matches the prose hash (the existing staleness check).

The validator is a **single-file check** (my call). It cannot see an active
entry reworded in place with no direction change; catching that would mean
comparing against the file's history, which is a different tool. That case is
guarded by the agent (which always proposes a log entry when it changes an
entry's meaning) and by the PR diff a human approves. A history-aware check can
follow if the single-file one proves too weak.

**The `ref` form exists for repos that already state their principles.** In this
repo every value is a `ref` to a pillar anchor in
`docs/explanation/philosophy.md`, with the pillar's H2 title as its text, which
is exactly what the repo's pillar rule permits. A repo with no such page writes
`statement`s. So that a stakeholder's PDF is not a list of bare links, the
charter may declare **appendices** — other Markdown files of the repo rendered
after it in the same PDF and ePub (my call). Here: the philosophy page and the
persona registry. The appendix is the page itself, rendered; nothing is copied
into the charter's source.

### 4. `/product:define-charter` and the `charter-definer` agent

Named *charter* rather than *vision* to match the document it writes (my call).

Same split as `define-personas`: the **skill conducts** and owns the single
write; the **agent thinks**, as a pure function of one turn returning JSON, with
no file or GitHub writes.

**Modes, inferred:** `create` when `docs/product/charter.md` is absent, else
`update`.

**Evidence the skill gathers and hands the agent:** README, `docs/` explanation
pages (motivation, philosophy or equivalent), the persona registry,
ARCHITECTURE.md positions when present, `.maintenance.yml` when present, titles
of open and recently closed epics, and issues closed as *not planned* (these are
past "no longer wanted" decisions and the best evidence of non-goals and
direction changes).

**Each turn the agent returns:** a draft of the prose; candidate entries it
inferred from evidence, each marked with the evidence it came from; questions
for the human; and the proposed `charter/v1` block.

**What the agent asks about:** purpose, audience, values in conflict, what is
out and why, and what has changed. It challenges rather than transcribes — for
example, when the evidence shows open epics that contradict a stated non-goal,
it says so and asks which one is true. It asks nothing about tooling, layout or
file placement.

**Direction changes are a first-class path.** In `update` mode the human can
open with a change ("we now also target private repos"). The agent then, in one
turn, drafts the log entry, proposes which existing entries it retires or
rewrites and which new ones it adds, and shows the result. In `create` mode the
agent also mines history for changes that already happened and proposes them as
back-dated entries for the human to confirm; it never invents a date — an entry
whose date the evidence does not give is asked about.

**Ending:** the human approves the draft. The skill then writes
`docs/product/charter.md`, runs the validator, and renders (section 5). It does
not commit or push; the change lands through the normal PR flow, as
`define-personas` does. If validation or rendering fails, the skill says so
with the failing output and does not report success — the Markdown stays
written, since it is the human-approved text.

**One product, many repos.** A charter exists once per product. The skill
always writes into the repo it is run in, at the one path above — so for a
product spread over several repos, it is run in the shared docs repository, and
the implementing repos see the result through their link to it (a submodule).
Run in a repo that has no charter of its own but links one, the skill does not
create a second: it names where the product's charter lives and stops (my call).
The same holds for `/product:define-personas`.

So that later tools find the documents the same way everywhere, the `product`
plugin ships one small lookup script: a product document is taken from the repo
itself when present, else from the first linked submodule that carries it at the
same relative path. It needs no configuration. This project uses it for the
stop above and for the charter's persona check; the groomer (project 3) and the
development-side persona readers (project 4) adopt it later.

**No charter, no guessing.** The plugin states one rule for every product skill
that needs the charter: when the lookup finds none, the skill offers to start
`/product:define-charter` then and there — or, in a repo that links a shared
docs repository, says to run it there — and does not proceed on an assumed
direction. This project ships the rule and the lookup; `define-personas` does
not need a charter and is unaffected.

**Persona gap:** if the charter's *Who it serves* needs a persona the registry
lacks, or there is no registry, the skill names `/product:define-personas` and
continues; `serves` may be empty and the validator allows that when no registry
exists.

### 5. The renderer

One script, `product/scripts/render-document.zsh` (zsh, per the repo's scripting
convention), used by every product skill and callable by hand.

**In:** one Markdown file. Title and appendices are read from its machine block
when it has one (`charter/v1`), and can be passed as arguments for a document
that has none (the persona registry). **Out, always both:** `<name>.pdf` and
`<name>.epub` in `dist/product/` at the target repo's
root (my call). The script prints both absolute paths. `dist/` is build output:
the calling skill adds it to `.gitignore` when it is not already ignored, as
part of the same working-tree change.

**Toolchain:** pandoc with Typst as its PDF engine and one Typst template; pandoc
alone for ePub with one stylesheet. Template and stylesheet ship in
`product/templates/`. Both tools come from Homebrew. When either is missing or
too old, the script exits non-zero with the exact `brew install` line and writes
nothing — no fallback engine, no partial output. The builder establishes the
minimum pandoc and Typst versions and the script checks them.

**What the rendering does:**

- A cover page (title, repo name, date, version line), a table of contents, the
  Summary on its own page.
- Values, non-goals and direction changes are visually distinct from running
  text (callouts; the log reads as a dated list or table). How the Markdown
  marks them so both outputs can style them is the builder's choice, with one
  constraint: the source stays readable as plain Markdown on github.com.
- The machine block (`<details>` with the JSON mirror) and the sentinel comments
  never appear in the output.
- Links between the main file and its appendices work inside the PDF and ePub;
  links to anything else in the repo become absolute repo URLs when the repo has
  a remote, and plain text otherwise.
- A footer stamps each page with the source commit's short SHA and date. When
  the source file has uncommitted changes the cover says **DRAFT**. A sent PDF
  can always be traced to the text it came from. Because the skill renders
  right after writing and never commits, its own output is always a DRAFT — the
  preview. The sendable copy comes from running the script once on the committed
  file (`render-document.zsh docs/product/charter.md`), which needs no other
  arguments; the how-to page says so (my call — no extra skill mode).
- The cover's version line is the newest direction-change id plus the short SHA
  (my call).
- Fonts ship with the template or with Typst itself; nothing depends on fonts
  installed on the machine. This is what makes macOS and CI output match.
- Input containing a diagram block (Mermaid) fails with a message naming the
  block — never a silently ugly page. Diagrams arrive with the roadmap project.

**No options** beyond the inputs above: no theme, no paper size, no font choice.
A4.

### 6. Tests, CI, docs

- bats suites for the renderer (missing tool, too-old tool, both files produced,
  machine block absent from output, DRAFT marker, diagram refusal, appendix
  link) and for the charter validator (each rule above, including a retired
  entry no change names).
- The ubuntu `script-tests` job installs pandoc and Typst at pinned versions so
  these suites run there rather than skip.
- The new contract prose in ARCHITECTURE.md is pinned the way other contracts
  are; the repo's existing sweep and figure conventions (MAINTAINING.md) apply.
- `docs/reference/` (plugins, commands, agents) lists the new plugin, both
  skills and both agents; one how-to page covers "write and send your product
  charter"; `mkdocs.yml` nav gains it. The C4 container diagram is unaffected —
  no deployable unit is added.
- The skill never edits a target repo's site configuration. When the repo has a
  `mkdocs.yml`, it ends by telling the human that the new page needs a nav entry
  (a strict build fails without one). In this repo the charter **is published
  on the docs site** beside the persona registry (my call); its nav entry is
  added in the PR that adds the charter itself, since a nav entry cannot precede
  the file.

## Constraints

- macOS + Homebrew for local use; CI on ubuntu must still run the tests.
- Line length 120; zsh for new scripts; plugin version bumps in `plugin.json`
  and `marketplace.json` per change.
- This repo is public: the charter and every example in docs and fixtures are
  written in the family's own words. A user's linked docs repository may be
  private; nothing from one is ever copied here, and every fixture that
  exercises the lookup is invented.
- The pillar rule in CLAUDE.md binds every file this project adds.

## Delivery

An epic in this repo with children built by `/development:resolve-issue`, in
this order because they collide on `marketplace.json` and ARCHITECTURE.md:

1. `product` plugin skeleton + ARCHITECTURE.md section.
2. Move `define-personas` and `persona-definer`; update every reference.
3. Renderer script, template, stylesheet, tests, CI tool install.
4. `charter/v1` contract in ARCHITECTURE.md + validator + tests.
5. `charter-definer` agent.
6. `/product:define-charter` skill; render step added to `define-personas`.
7. Docs pages and nav.

Then, outside the epic: the maintainer runs `/product:define-charter` here. The
four direction changes listed under *Intent* are its first log entries.

## Left to the builder

- Exact JSON field names and the validator's implementation.
- The Typst template and ePub stylesheet design, within "one house style a
  stakeholder would call professional"; the maintainer judges the first
  rendered charter and may ask for one revision round of the look.
- How callouts are marked in Markdown (within the readability constraint).
- Minimum tool versions; which fonts are bundled (licence must allow
  redistribution).
- Child-story boundaries, if the size check asks for a further split.
